"""Regression tests using Niri 26.04-shaped IPC fixtures; no desktop needed."""
import copy
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch
import json
import os
import signal
import tempfile
import time

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'niri-terminal-pairs'))


def window(ident, column=1, row=1, app='work-plain-terminal', workspace=1, floating=False):
    return dict(id=ident, app_id=app, workspace_id=workspace,
                is_floating=floating,
                layout=dict(pos_in_scrolling_layout=[column, row]))


def opened(w):
    return {'WindowOpenedOrChanged': {'window': w}}


class Events(unittest.TestCase):
    def setUp(self):
        self.tracker = helper['OpenedWindows']()
        self.tracker.observe({'WindowsChanged': {'windows': [window(1)]}}, 0)

    def test_existing_windows_and_title_changes_ignored(self):
        self.assertEqual(self.tracker.observe(opened(window(1)), .1), [])

    def test_new_terminal_only_once(self):
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), .1), [2])
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), .2), [])

    def test_delayed_app_id(self):
        self.assertEqual(self.tracker.observe(opened(window(2, 2, app=None)), .1), [])
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), .2), [2])

    def test_delayed_layout(self):
        w = window(2, 2)
        w['layout']['pos_in_scrolling_layout'] = None
        self.assertEqual(self.tracker.observe(opened(w), .1), [])
        event = {'WindowLayoutsChanged': {'changes': [[2, window(2, 2)['layout']]]}}
        self.assertEqual(self.tracker.observe(event, .2), [2])

    def test_expired_metadata_not_paired_later(self):
        self.tracker.observe(opened(window(2, 2, app=None)), .1)
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), 2), [])

    def test_floating_window_not_paired_when_manually_tiled(self):
        self.tracker.observe(opened(window(2, 2, floating=True)), .1)
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), .2), [])

    def test_nonterminal_ignored(self):
        self.assertEqual(self.tracker.observe(opened(window(2, 2, app='browser')), .1), [])
        self.assertEqual(self.tracker.pending, {})

    def test_closed_pending_and_reused_id(self):
        self.tracker.observe(opened(window(2, 2, app=None)), .1)
        self.tracker.observe({'WindowClosed': {'id': 2}}, .2)
        self.assertNotIn(2, self.tracker.pending)
        self.assertEqual(self.tracker.observe(opened(window(2, 2)), .3), [2])

    def test_snapshot_required(self):
        self.assertEqual(helper['OpenedWindows']().observe(opened(window(2)), 0), [])


class Pairing(unittest.TestCase):
    def test_third_starts_column_fourth_joins_it(self):
        windows = [window(1), window(2, row=2), window(3, 2)]
        self.assertIsNone(helper['partner'](windows[-1], windows))
        windows.append(window(4, 3))
        self.assertEqual(helper['partner'](windows[-1], windows)['id'], 3)

    def test_workspace_nonterminal_and_floating_excluded(self):
        for old in (window(1, workspace=2), window(1, app='browser'), window(1, floating=True)):
            with self.subTest(old=old):
                self.assertIsNone(helper['partner'](window(2, 2), [old, window(2, 2)]))

    def test_terminal_apps_with_default_foot_ids_are_excluded(self):
        for app in ('foot', 'footclient'):
            w = window(2, 2, app=app)
            self.assertFalse(helper['terminal'](w))
            self.assertIsNone(helper['partner'](w, [window(1), w]))
            self.assertIsNone(helper['partner'](window(2, 2), [window(1, app=app), window(2, 2)]))

    def test_no_pair_if_new_window_already_in_stack(self):
        windows = [window(1), window(2, 2), window(3, 2, 2)]
        self.assertIsNone(helper['partner'](windows[-1], windows))

    def request(self, snapshots, fail_action=False):
        calls = []
        def request(*args):
            calls.append(args)
            if args == ('--json', 'windows'):
                return json.dumps(snapshots.pop(0))
            if fail_action:
                raise subprocess.TimeoutExpired('niri', 3)
            return ''
        return calls, request

    def test_success_uses_ids_and_resets_both(self):
        calls, request = self.request([[window(1), window(2, 2)],
                                       [window(1), window(2, row=2)]])
        self.assertTrue(helper['pair'](2, request))
        self.assertIn(('action', 'consume-or-expel-window-left', '--id', '2'), calls)
        self.assertEqual(calls[-2:], [('action', 'reset-window-height', '--id', '1'),
                                      ('action', 'reset-window-height', '--id', '2')])

    def test_failed_move_never_toggles_again_or_resets(self):
        before = [window(1), window(2, 2)]
        calls, request = self.request([copy.deepcopy(before) for _ in range(4)])
        with patch('time.sleep'):
            self.assertFalse(helper['pair'](2, request))
        self.assertEqual(len([c for c in calls if c[0] == 'action']), 1)

    def test_disappearing_window_leaves_heights_alone(self):
        calls, request = self.request([[window(1), window(2, 2)], [window(1)]])
        self.assertFalse(helper['pair'](2, request))
        self.assertEqual(len([c for c in calls if c[0] == 'action']), 1)

    def test_unexpected_third_member_leaves_heights_alone(self):
        calls, request = self.request([[window(1), window(2, 2)],
                                       [window(1), window(2, row=2), window(3, row=3)]])
        self.assertFalse(helper['pair'](2, request))
        self.assertEqual(len([c for c in calls if c[0] == 'action']), 1)

    def test_action_timeout_is_not_retried(self):
        calls, request = self.request([[window(1), window(2, 2)]], fail_action=True)
        with self.assertRaises(subprocess.TimeoutExpired):
            helper['pair'](2, request)
        self.assertEqual(len([c for c in calls if c[0] == 'action']), 1)

    def test_unrelated_window_does_not_trigger_actions(self):
        calls, request = self.request([[window(1), window(2, 2, app='browser')]])
        self.assertFalse(helper['pair'](2, request))
        self.assertEqual(calls, [('--json', 'windows')])


class Lifecycle(unittest.TestCase):
    def check_cleanup(self, close_stdout):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'niri'
            fake.write_text("#!/usr/bin/env python3\n"
                            "import os, time, pathlib\n"
                            "pathlib.Path(os.environ['PID_FILE']).write_text(str(os.getpid()))\n"
                            + ("os.close(1)\n" if close_stdout else
                               "import json; print(json.dumps(dict(WindowsChanged=dict(windows=[]))), flush=True)\n")
                            + "time.sleep(30)\n")
            fake.chmod(0o755)
            pidfile = Path(directory) / 'child.pid'
            env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'],
                       XDG_RUNTIME_DIR=directory, NIRI_SOCKET='fixture', PID_FILE=str(pidfile), NIRI_SPACES_TERMINAL_PAIRS='1')
            proc = subprocess.Popen(['python3', str(Path(__file__).resolve().parents[1] / 'niri-terminal-pairs')],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 3
                while not pidfile.exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(pidfile.exists())
                if not close_stdout:
                    proc.send_signal(signal.SIGTERM)
                _, stderr = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 1 if close_stdout else 0, stderr)
                self.assertFalse(Path('/proc', pidfile.read_text()).exists(), 'event listener left behind')
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate()

    def test_sigterm_reaps_listener(self):
        self.check_cleanup(False)

    def test_closed_stdout_does_not_wait_forever(self):
        self.check_cleanup(True)


if __name__ == '__main__':
    unittest.main()
