"""Regression tests for niri-session-snapshot's rule engine.

Every rule reads live process state through Proc, which is rooted at
$NS_PROC_ROOT so these tests can build a fake /proc tree in a tempdir and
point it there. No desktop, no IPC, no launching.
"""
from pathlib import Path
import json
import os
import runpy
import tempfile
import unittest

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'niri-session-snapshot'))

Proc = helper['Proc']
rule_for = helper['rule_for']
build_snapshot = helper['build_snapshot']
vscode_folder = helper['vscode_folder']


class FakeProc(unittest.TestCase):
    """Base: builds a fake /proc from a spec of {pid: (cmdline, comm, cwd, children)}."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'proc'
        self.root.mkdir()

    def add_pid(self, pid, cmdline, comm=None, cwd=None, children=()):
        d = self.root / str(pid)
        d.mkdir(parents=True, exist_ok=True)
        (d / 'cmdline').write_bytes(('\0'.join(cmdline) + '\0').encode())
        (d / 'comm').write_text((comm or cmdline[0]) + '\n')
        if cwd is not None:
            # readlink does not require the target to exist, so the fake cwd
            # can be the literal logical path the test asserts on.
            (d / 'cwd').symlink_to(cwd)
        task = d / 'task' / str(pid)
        task.mkdir(parents=True, exist_ok=True)
        (task / 'children').write_text(' '.join(str(c) for c in children) + '\n')
        return d

    def proc(self):
        return Proc(root=self.root)

    def window(self, app_id, pid=None, title=None, ws_id=1):
        return {'id': 100, 'app_id': app_id, 'pid': pid, 'title': title,
                'workspace_id': ws_id, 'layout': {}, 'is_floating': False}


class BrowserRules(FakeProc):
    def test_chrome_profile_and_urls_from_cmdline(self):
        self.add_pid(100, [
            '/opt/google/chrome/chrome', '--ozone-platform-hint=auto',
            '--profile-directory=Profile\\ 2', 'https://example.com/a',
            '--enable-features=Foo', 'http://localhost:3000',
        ])
        rule, cmd, group, reason = rule_for(
            self.window('google-chrome', 100), self.proc())
        self.assertEqual(rule, 'browser')
        self.assertEqual(group, 'browser:100')
        self.assertIsNone(reason)
        self.assertEqual(cmd[0], '/opt/google/chrome/chrome')
        self.assertIn('--ozone-platform=wayland', cmd)
        self.assertIn('--new-window', cmd)
        self.assertIn('--profile-directory=Profile\\ 2', cmd)
        self.assertEqual([a for a in cmd if a.startswith('http')],
                         ['https://example.com/a', 'http://localhost:3000'])
        self.assertNotIn('--enable-features=Foo', cmd)

    def test_stale_pid_falls_back_to_plain_launch(self):
        # X11-forwarded windows can report a pid that already exited.
        rule, cmd, group, reason = rule_for(
            self.window('brave-origin', 999999), self.proc())
        self.assertEqual(rule, 'browser')
        self.assertEqual(cmd, ['brave-origin', '--ozone-platform=wayland', '--new-window'])

    def test_same_pid_groups_into_one_launch(self):
        self.add_pid(200, ['brave-origin'])
        wins = [self.window('brave-origin', 200, title=f't{i}') for i in range(3)]
        groups = {rule_for(w, self.proc())[2] for w in wins}
        self.assertEqual(groups, {'browser:200'})

    def test_pwa_windows_are_skipped(self):
        rule, cmd, group, reason = rule_for(
            self.window('chrome-gbchcmhmhahfdphkhkmpfmihenigjmpp-Profile_2', 5), self.proc())
        self.assertEqual(rule, 'skip')
        self.assertIn('PWA', reason)


class VscodeRules(FakeProc):
    def test_single_group_plain_code(self):
        wins = [self.window('com.microsoft.VSCode', 77, title='a.py - proj - Visual Studio Code')]
        rule, cmd, group, reason = rule_for(wins[0], self.proc())
        self.assertEqual((rule, cmd, group, reason), ('vscode', ['code'], 'vscode', None))

    def test_title_folder_extraction(self):
        self.assertEqual(vscode_folder('main.rs - kavia-cms - Visual Studio Code'), 'kavia-cms')
        self.assertEqual(vscode_folder('index.md - docs (Workspace) - Visual Studio Code'), 'docs')
        self.assertIsNone(vscode_folder('no editor here'))


class TerminalRules(FakeProc):
    def test_foot_with_direct_tui_child(self):
        # Confirmed live shape: `foot -e micro file` -> micro is the direct child.
        self.add_pid(301, ['micro', '/tmp/x.md'], comm='micro',
                     cwd='/home/u/project')
        self.add_pid(300, ['foot', '--app-id=term-teal', '-e', 'micro', '/tmp/x.md'],
                     comm='foot', children=[301])
        rule, cmd, group, reason = rule_for(
            self.window('term-teal', 300), self.proc())
        self.assertEqual(rule, 'terminal')
        self.assertEqual(cmd, ['foot', '--app-id=term-teal',
                               '--working-directory=/home/u/project',
                               '-e', 'micro', '/tmp/x.md'])

    def test_shell_grandchild_tui(self):
        # Confirmed live shape: plain foot -> sh -> micro.
        self.add_pid(400, ['foot'], comm='foot', children=[401])
        self.add_pid(401, ['/usr/bin/zsh'], comm='zsh', cwd='/home/u/repo',
                     children=[402])
        self.add_pid(402, ['yazi', '/home/u/repo'], comm='yazi', cwd='/home/u/repo')
        rule, cmd, _g, _r = rule_for(self.window('foot', 400), self.proc())
        self.assertEqual(rule, 'terminal')
        self.assertEqual(cmd, ['foot', '--app-id=foot',
                               '--working-directory=/home/u/repo',
                               '-e', 'yazi', '/home/u/repo'])

    def test_plain_shell_restores_shell_at_cwd(self):
        self.add_pid(500, ['foot'], comm='foot', children=[501])
        self.add_pid(501, ['/usr/bin/zsh'], comm='zsh', cwd='/home/u/notes')
        rule, cmd, _g, _r = rule_for(self.window('foot', 500), self.proc())
        self.assertEqual(cmd, ['foot', '--app-id=foot',
                               '--working-directory=/home/u/notes'])

    def test_unknown_tui_under_shell_is_not_guessed(self):
        self.add_pid(600, ['foot'], comm='foot', children=[601])
        self.add_pid(601, ['bash'], comm='bash', cwd='/home/u', children=[602])
        self.add_pid(602, ['htop'], comm='htop', cwd='/home/u')
        rule, cmd, _g, _r = rule_for(self.window('foot', 600), self.proc())
        self.assertEqual(cmd, ['foot', '--app-id=foot', '--working-directory=/home/u'])
        self.assertNotIn('htop', cmd)

    def test_color_terminal_o_flags_survive(self):
        self.add_pid(700, ['foot', '-o', 'colors=[colors]', '--app-id=term-purple',
                           '-o', 'csd-enabled=false'], comm='foot', children=[])
        rule, cmd, _g, _r = rule_for(self.window('term-purple', 700), self.proc())
        self.assertEqual(cmd[:5], ['foot', '-o', 'colors=[colors]', '-o', 'csd-enabled=false'])
        self.assertIn('--app-id=term-purple', cmd)

    def test_non_foot_terminal_is_skipped(self):
        self.add_pid(800, ['xterm'], comm='xterm')
        rule, _c, _g, reason = rule_for(self.window('xterm', 800), self.proc())
        self.assertEqual(rule, 'skip')
        self.assertIn('xterm', reason)


class AppRules(FakeProc):
    def test_slack_prefers_work_slack_helper(self):
        rule, cmd, _g, reason = rule_for(self.window('Slack', 900), self.proc())
        self.assertEqual(rule, 'slack')
        self.assertIsNone(reason)
        self.assertTrue(cmd[0].endswith('work-slack') or cmd[0] == 'slack')

    def test_sublime_plain(self):
        rule, cmd, _g, _r = rule_for(
            self.window('sublime_text', None, title='file.py — Sublime Text'), self.proc())
        self.assertEqual((rule, cmd), ('sublime', ['sublime_text']))

    def test_gram_unique_title_resolves(self):
        projects = Path(self.tmp.name) / 'Projects'
        (projects / 'lario' / 'niri-spaces').mkdir(parents=True)
        rule, cmd, _g, _r = rule_for(
            self.window('app.liten.Gram', 950, title='niri-spaces'),
            self.proc(), {'projects_root': projects})
        self.assertEqual(rule, 'gram')
        self.assertEqual(cmd, ['gram', '-n', str(projects / 'lario' / 'niri-spaces')])

    def test_gram_ambiguous_title_falls_back(self):
        projects = Path(self.tmp.name) / 'Projects'
        (projects / 'a' / 'app').mkdir(parents=True)
        (projects / 'b' / 'app').mkdir(parents=True)
        rule, cmd, _g, _r = rule_for(
            self.window('app.liten.Gram', 951, title='app'),
            self.proc(), {'projects_root': projects})
        self.assertEqual(cmd, ['gram'])

    def test_gram_missing_title_falls_back(self):
        rule, cmd, _g, _r = rule_for(
            self.window('app.liten.Gram', 952, title=None),
            self.proc(), {'projects_root': Path(self.tmp.name)})
        self.assertEqual(cmd, ['gram'])

    def test_unknown_app_is_skipped_not_guessed(self):
        rule, cmd, _g, reason = rule_for(self.window('org.videolan.VLC', 990), self.proc())
        self.assertEqual((rule, cmd), ('skip', None))
        self.assertIn('VLC', reason)

    def test_window_without_app_id_is_skipped(self):
        rule, _c, _g, reason = rule_for(self.window(None, 991), self.proc())
        self.assertEqual(rule, 'skip')
        self.assertIn('app_id', reason)


class SnapshotShape(FakeProc):
    def test_build_snapshot_orders_and_records(self):
        self.add_pid(1000, ['brave-origin', '--profile-directory=Default'])
        workspaces = [
            {'id': 2, 'idx': 2, 'name': 'work-slack', 'output': 'DP-1', 'is_focused': False},
            {'id': 1, 'idx': 1, 'name': 'teal', 'output': 'eDP-1', 'is_focused': True},
        ]
        windows = [
            {'id': 10, 'app_id': 'Slack', 'pid': 1, 'title': 'Slack', 'workspace_id': 2,
             'layout': {'pos_in_scrolling_layout': [0, 0], 'tile_size': [960, 1000]},
             'is_floating': False},
            {'id': 11, 'app_id': 'brave-origin', 'pid': 1000, 'title': 'tabs',
             'workspace_id': 1,
             'layout': {'pos_in_scrolling_layout': [1, 0], 'tile_size': [1440, 1000]},
             'is_floating': False},
            {'id': 12, 'app_id': 'mystery', 'pid': 2, 'title': '?', 'workspace_id': 1,
             'layout': {}, 'is_floating': True},
            {'id': 13, 'app_id': 'ghost', 'pid': 3, 'title': 'scratch',
             'workspace_id': 99, 'layout': {}, 'is_focused': False},
        ]
        outputs = [{'name': 'DP-1', 'width': 1920}, {'name': 'eDP-1', 'width': 2880}]
        doc = build_snapshot(workspaces, windows, outputs, self.proc())
        self.assertEqual(doc['version'], 1)
        self.assertEqual([w['name'] for w in doc['workspaces']], ['teal', 'work-slack'])
        teal = doc['workspaces'][0]
        self.assertTrue(teal['focused'])
        # Half of 2880 is 1440: the browser column is half the monitor.
        browser = next(w for w in teal['windows'] if w['app_id'] == 'brave-origin')
        self.assertEqual(browser['width'], 0.5)
        self.assertEqual(browser['column'], 1)
        mystery = next(w for w in teal['windows'] if w['app_id'] == 'mystery')
        self.assertTrue(mystery['floating'])
        self.assertIsNotNone(mystery['skip_reason'])
        # Window on an unknown workspace (scratch) is not placed anywhere.
        self.assertNotIn('ghost', json.dumps(doc))

    def test_write_and_read_roundtrip(self):
        doc = {'version': 1, 'workspaces': []}
        state = Path(self.tmp.name) / 'state'
        old = os.environ.get('XDG_STATE_HOME')
        os.environ['XDG_STATE_HOME'] = str(state)
        try:
            helper['write_snapshot'](doc)
            path = helper['snapshot_path']()
            self.assertTrue(path.exists())
            mode = path.stat().st_mode & 0o777
            self.assertEqual(mode, 0o600)
            self.assertEqual(json.loads(path.read_text()), doc)
        finally:
            if old is None:
                del os.environ['XDG_STATE_HOME']
            else:
                os.environ['XDG_STATE_HOME'] = old


class SettingsValidation(unittest.TestCase):
    def _settings(self, payload):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / 'settings.json'
        if payload is not None:
            path.write_text(json.dumps(payload))
        old = os.environ.get('NIRI_SPACES_DIR')
        os.environ['NIRI_SPACES_DIR'] = tmp.name
        try:
            return helper['settings']()
        finally:
            if old is None:
                del os.environ['NIRI_SPACES_DIR']
            else:
                os.environ['NIRI_SPACES_DIR'] = old

    def test_defaults_off(self):
        self.assertEqual(self._settings(None), (False, 2))
        self.assertEqual(self._settings({}), (False, 2))

    def test_enabled_and_debounce(self):
        self.assertEqual(self._settings({'session_snapshot': True,
                                         'session_snapshot_debounce': 5}), (True, 5))

    def test_invalid_values_raise(self):
        for bad in ({'session_snapshot': 'yes'},
                    {'session_snapshot_debounce': 0},
                    {'session_snapshot_debounce': 61},
                    {'session_snapshot_debounce': True},
                    {'session_snapshot_debounce': 2.5}):
            with self.assertRaises(ValueError):
                self._settings(bad)


if __name__ == '__main__':
    unittest.main()
