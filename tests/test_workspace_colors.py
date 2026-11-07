"""Regression tests for niri-workspace-colors using Niri 26.04-shaped IPC
fixtures; no desktop needed.

The idx fields throughout are 1-based, exactly as niri's workspaces query and
event stream report them (src/ipc/server.rs builds them as ws_idx + 1), and
the same number is what the workspace-reference actions accept.
"""
from pathlib import Path
import json
import os
import random
import runpy
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'niri-workspace-colors'))


def ws(ident, idx, name=None, window=None, focused=False):
    return dict(id=ident, idx=idx, name=name, output='eDP-1', is_urgent=False,
                is_active=focused, is_focused=focused, active_window_id=window)


def changed(*workspaces):
    return {'WorkspacesChanged': {'workspaces': list(workspaces)}}


_MISSING = object()


def patch_module(name, value):
    """Patch a key of the runpy module's real globals dict and return a
    cleanup. runpy.run_path returns a dict that is NOT the __globals__ of the
    functions it defines, so patching it has no effect on them; every function
    of the run shares the real globals dict, which we reach through any one."""
    globals_dict = helper['read_include_entries'].__globals__
    original = globals_dict.get(name, _MISSING)
    globals_dict[name] = value

    def cleanup():
        if original is _MISSING:
            globals_dict.pop(name, None)
        else:
            globals_dict[name] = original
    return cleanup


class FakeNiri:
    """Records every niri msg call; serves canned snapshots to the query."""

    def __init__(self, snapshots=None):
        self.calls = []
        self.snapshots = list(snapshots or [])

    def request(self, *args):
        self.calls.append(args)
        if args == ('--json', 'workspaces'):
            return json.dumps(self.query())
        return ''

    def query(self):
        if not self.snapshots:
            raise AssertionError('no canned snapshot left for %r' % (self.calls[-1],))
        return self.snapshots.pop(0)


class ReconcileCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.include = root / 'niri' / helper['INCLUDE_NAME']
        self.include.parent.mkdir(parents=True)
        patcher = patch.dict(os.environ, dict(os.environ,
                                              NIRI_SPACES_DIR=str(root / 'cfg')))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(patch_module('include_path', lambda: self.include))
        self.fake = FakeNiri()
        self.reconciler = helper['Reconciler'](
            helper['SCHEMES'], 'sequential', helper['load_state'](),
            request=self.fake.request, query=self.fake.query,
            validator=lambda text: True)
        self.reconciler.writer = lambda entries: self.include.write_text(
            helper['render_include'](entries))

    def tearDown(self):
        self._tmp.cleanup()

    def entries(self):
        return helper['read_include_entries']()

    def new_workspace_events(self):
        """Event 1 holds only the pre-existing workspace; event 2 adds the
        newcomer, which is exactly when a scheme may be assigned."""
        self.reconciler.observe(changed(ws(1, 1, window=10)))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2)))


class Startup(ReconcileCase):
    def test_existing_workspaces_are_excluded_and_untouched(self):
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, window=11)))
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(helper['load_state']()['excluded'], ['1', '2'])
        self.assertEqual(self.entries(), set())

    def test_managed_workspace_surviving_with_state_is_kept(self):
        state = helper['load_state']()
        state['assignments'] = {'2': 'teal'}
        helper['save_state'](state)
        self.reconciler.state = state
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal', window=11)))
        self.assertEqual(helper['load_state']()['assignments'], {'2': 'teal'})
        self.assertEqual(self.entries(), {'teal'})

    def test_empty_ghost_from_include_is_unnamed_and_pruned(self):
        # After a reboot the include file still names workspaces; niri creates
        # them empty. The one with no state record is a ghost: unname it and
        # drop its entry so the next reload removes the name entirely.
        self.include.write_text(helper['render_include']({'teal': helper['SCHEMES'][0]}))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.assertIn(('action', 'unset-workspace-name', '2'), self.fake.calls)
        self.assertEqual(self.entries(), set())
        self.assertNotIn('2', helper['load_state']()['assignments'])

    def test_state_file_loss_adopts_windowed_workspace_not_ghost(self):
        self.include.write_text(helper['render_include'](
            {'teal': helper['SCHEMES'][0], 'purple': helper['SCHEMES'][1]}))
        self.reconciler.observe(changed(
            ws(1, 1, 'teal', window=10), ws(2, 2, 'purple')))
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {'1': 'teal'})
        self.assertIn(('action', 'unset-workspace-name', '2'), self.fake.calls)
        self.assertEqual(self.entries(), {'teal'})

    def test_excluded_workspace_renamed_to_scheme_name_is_adopted(self):
        # The user named their own workspace "teal": on the next helper start
        # it is re-adopted rather than un-named, so its colors keep working.
        state = helper['load_state']()
        state['excluded'] = ['2']
        helper['save_state'](state)
        self.reconciler.state = state
        self.reconciler.observe(changed(ws(2, 2, 'teal')))
        self.assertEqual(helper['load_state']()['assignments'], {'2': 'teal'})
        self.assertEqual(self.entries(), {'teal'})

    def test_dead_excluded_ids_are_pruned(self):
        state = helper['load_state']()
        state['excluded'] = ['7', '9']
        helper['save_state'](state)
        self.reconciler.state = state
        self.reconciler.observe(changed(ws(1, 1, window=10)))
        self.assertEqual(helper['load_state']()['excluded'], ['1'])


class Lifecycle(ReconcileCase):
    def test_new_workspace_gets_first_scheme_then_entry(self):
        self.new_workspace_events()
        self.assertIn(('action', 'set-workspace-name', 'teal', '--workspace', '2'),
                      self.fake.calls)
        # The rename lands in the next event; the entry is written then, while
        # the workspace bears the name.
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {'2': 'teal'})
        self.assertEqual(state['pending'], {})
        self.assertEqual(self.entries(), {'teal'})
        text = self.include.read_text()
        self.assertIn('workspace "teal"', text)
        self.assertIn('background-color "#2b3a42"', text)

    def test_entry_never_written_before_rename_confirmed(self):
        self.new_workspace_events()
        self.assertEqual(self.entries(), set(),
                         'the entry must not exist before the rename lands')

    def test_next_workspaces_get_distinct_schemes(self):
        self.new_workspace_events()
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal'),
                                        ws(3, 3)))
        self.assertIn(('action', 'set-workspace-name', 'purple', '--workspace', '3'),
                      self.fake.calls)
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal'),
                                        ws(3, 3, 'purple')))
        self.assertEqual(self.entries(), {'teal', 'purple'})

    def test_destroyed_workspace_prunes_assignment_and_entry(self):
        self.new_workspace_events()
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.reconciler.observe(changed(ws(1, 1, window=10)))
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {})
        self.assertEqual(self.entries(), set())

    def test_user_renamed_workspace_is_handed_back(self):
        self.new_workspace_events()
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'mail')))
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {})
        self.assertIn('2', state['excluded'])
        self.assertEqual(self.entries(), set())

    def test_hand_back_workspace_never_renamed_again(self):
        self.new_workspace_events()
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'mail')))
        # ws3 is brand new: with the cursor at position 1 it receives purple.
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'mail'),
                                        ws(3, 3)))
        # The rename of ws3 lands in the next event, which confirms it.
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'mail'),
                                        ws(3, 3, 'purple')))
        state = helper['load_state']()
        self.assertEqual(state['excluded'], ['1', '2'])
        self.assertEqual(state['assignments'], {'3': 'purple'})
        self.assertEqual(self.entries(), {'purple'})
        # ws2 was renamed exactly once (to its original scheme) and never
        # again after the hand-back.
        self.assertEqual(self.fake.calls, [
            ('action', 'set-workspace-name', 'teal', '--workspace', '2'),
            ('action', 'set-workspace-name', 'purple', '--workspace', '3'),
        ])

    def test_rename_held_by_user_workspace_is_given_up_not_stolen(self):
        # ws2's rename to "teal" is ignored because the user names their own
        # workspace "teal" before the confirmation: the helper must give up,
        # never un-naming the user's workspace.
        self.reconciler.observe(changed(ws(1, 1, window=10)))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2)))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2),
                                        ws(4, 4, 'teal', window=20)))
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {})
        self.assertEqual(sorted(state['excluded']), ['1', '2', '4'])
        self.assertEqual(self.fake.calls,
                         [('action', 'set-workspace-name', 'teal', '--workspace', '2')])
        self.assertEqual(self.entries(), set())

    def test_unconfirmable_rename_is_given_up_after_two_attempts(self):
        self.reconciler.observe(changed(ws(1, 1, window=10)))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2)))
        # The rename never lands and nobody holds the name: one retry, then
        # the workspace is handed back untouched.
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2)))
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2)))
        state = helper['load_state']()
        self.assertEqual(state['pending'], {})
        self.assertIn('2', state['excluded'])
        self.assertEqual(state['assignments'], {})
        renames = [c for c in self.fake.calls
                   if c[:2] == ('action', 'set-workspace-name')]
        self.assertEqual(len(renames), 2)

    def test_config_reload_failure_forces_rewrite(self):
        self.new_workspace_events()
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.assertEqual(len(self.reconciler.writes), 1)
        # The file is intact and matches, but niri reports a failed reload:
        # the entries are rewritten from state anyway so the two reconverge.
        self.reconciler.observe({'ConfigLoaded': {'failed': True}})
        self.reconciler.observe(changed(ws(1, 1, window=10), ws(2, 2, 'teal')))
        self.assertEqual(len(self.reconciler.writes), 2)
        self.assertEqual(self.entries(), {'teal'})


class RandomAssignment(ReconcileCase):
    def test_picked_schemes_are_free_and_unique_per_pass(self):
        self.reconciler.assignment = 'random'
        self.reconciler.observe(changed(ws(1, 1, 'teal', window=10)))
        self.reconciler.observe(changed(ws(1, 1, 'teal', window=10),
                                        ws(2, 2), ws(3, 3)))
        schemes = [c[2] for c in self.fake.calls
                   if c[:2] == ('action', 'set-workspace-name')]
        self.assertEqual(len(schemes), 2)
        self.assertNotIn('teal', schemes)
        self.assertEqual(len(set(schemes)), 2)

    def test_exhausted_palette_is_handed_back_not_stolen(self):
        # All eight schemes are held by pre-existing (re-adopted) workspaces;
        # a ninth cannot get a distinct name. The fallback pick is ignored by
        # niri, the held workspace must never be un-named, and the newcomer
        # is handed back unnamed.
        self.reconciler.assignment = 'random'
        taken = [ws(i + 1, i + 1, s['name'], window=i)
                 for i, s in enumerate(helper['SCHEMES'])]
        self.reconciler.observe(changed(*taken))
        self.reconciler.observe(changed(*taken, ws(99, 9)))
        self.reconciler.observe(changed(*taken, ws(99, 9)))
        state = helper['load_state']()
        self.assertNotIn('99', state['assignments'])
        self.assertIn('99', state['excluded'])
        self.assertEqual(state['assignments'],
                         {str(i + 1): s['name'] for i, s in enumerate(helper['SCHEMES'])})
        self.assertFalse(any(c[:2] == ('action', 'unset-workspace-name')
                             for c in self.fake.calls))
        self.assertEqual(self.entries(),
                         {s['name'] for s in helper['SCHEMES']})


class OneShot(ReconcileCase):
    def managed(self, cursor):
        state = helper['load_state']()
        state['assignments'] = {'2': 'teal', '3': 'purple'}
        state['excluded'] = ['1']
        state['cursor'] = cursor
        helper['save_state'](state)
        self.reconciler.state = state

    def test_recolor_by_index_swaps_entry_in_one_write(self):
        self.managed(cursor=2)
        before = [ws(1, 1, window=10), ws(2, 2, 'teal', window=11), ws(3, 3, 'purple')]
        after = [ws(1, 1, window=10), ws(2, 2, 'neon', window=11), ws(3, 3, 'purple')]
        self.fake.snapshots = [before, after]
        helper['one_shot'](self.reconciler, 'recolor', '2')
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {'2': 'neon', '3': 'purple'})
        self.assertEqual(self.entries(), {'neon', 'purple'},
                         'the old name must be gone and the new one present at once')
        # The text written to the file is exactly what was validated before
        # the rename, so a reload can never see a name without its bearer.
        self.assertEqual(self.include.read_text(), self.reconciler._prevalidated)

    def test_recolor_by_name(self):
        self.managed(cursor=3)
        before = [ws(1, 1, window=10), ws(2, 2, 'teal', window=11), ws(3, 3, 'purple')]
        after = [ws(1, 1, window=10), ws(2, 2, 'yellow', window=11), ws(3, 3, 'purple')]
        self.fake.snapshots = [before, after]
        helper['one_shot'](self.reconciler, 'recolor', 'teal')
        self.assertEqual(helper['load_state']()['assignments'],
                         {'2': 'yellow', '3': 'purple'})

    def test_recolor_all_managed_workspaces(self):
        self.managed(cursor=4)
        before = [ws(2, 2, 'teal', window=11), ws(3, 3, 'purple', window=12)]
        after = [ws(2, 2, 'green', window=11), ws(3, 3, 'maroon', window=12)]
        self.fake.snapshots = [before, after]
        helper['one_shot'](self.reconciler, 'recolor', None)
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {'2': 'green', '3': 'maroon'})
        self.assertEqual(self.entries(), {'green', 'maroon'})

    def test_clear_unnames_managed_workspaces_and_drops_entries(self):
        self.managed(cursor=0)
        before = [ws(1, 1, window=10), ws(2, 2, 'teal', window=11), ws(3, 3, 'purple')]
        after = [ws(1, 1, window=10), ws(2, 2, window=11), ws(3, 3, window=12)]
        self.fake.snapshots = [before, after]
        helper['one_shot'](self.reconciler, 'clear', None)
        state = helper['load_state']()
        self.assertEqual(state['assignments'], {})
        self.assertEqual(state['pending'], {})
        self.assertIn(('action', 'unset-workspace-name', '2'), self.fake.calls)
        self.assertIn(('action', 'unset-workspace-name', '3'), self.fake.calls)
        self.assertNotIn(('action', 'unset-workspace-name', '1'), self.fake.calls)
        self.assertEqual(self.entries(), set())

    def test_queued_command_runs_against_fresh_snapshot(self):
        self.managed(cursor=2)
        before = [ws(1, 1, window=10), ws(2, 2, 'teal', window=11),
                  ws(3, 3, 'purple')]
        after = [ws(1, 1, window=10), ws(2, 2, 'neon', window=11),
                 ws(3, 3, 'purple')]
        self.fake.snapshots = [before, after]
        state = helper['load_state']()
        state['command'] = {'op': 'recolor', 'ref': '2'}
        helper['save_state'](state)
        self.reconciler.state = state
        self.reconciler.started = True
        self.reconciler.apply_command()
        self.assertIsNone(helper['load_state']()['command'])
        self.assertEqual(helper['load_state']()['assignments'],
                         {'2': 'neon', '3': 'purple'})
        self.assertEqual(self.entries(), {'neon', 'purple'})


class Settings(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.settings = root / 'settings.json'
        patcher = patch.dict(os.environ, dict(os.environ, NIRI_SPACES_DIR=str(root)))
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self._tmp.cleanup()

    def set(self, text):
        self.settings.write_text(text)

    def test_defaults(self):
        enabled, assignment, schemes = helper['settings']()
        self.assertFalse(enabled)
        self.assertEqual(assignment, 'random')
        self.assertEqual(len(schemes), 8)
        names = {s['name'] for s in schemes}
        # The classic families the feature is named for.
        self.assertTrue({'teal', 'purple', 'neon', 'yellow'} <= names)

    def test_enabled(self):
        self.set('{"workspace_colors": true}')
        enabled, assignment, schemes = helper['settings']()
        self.assertTrue(enabled)
        self.assertEqual(assignment, 'random')
        self.assertEqual(len(schemes), 8)

    def test_nonbool_enabled_rejected(self):
        self.set('{"workspace_colors": "yes"}')
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_bad_assignment_rejected(self):
        self.set('{"workspace_color_assignment": "shuffle"}')
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_sequential_assignment_accepted(self):
        self.set('{"workspace_color_assignment": "sequential"}')
        self.assertEqual(helper['settings']()[1], 'sequential')

    def test_custom_schemes_are_normalized(self):
        self.set('{"workspace_color_schemes": [{"name": "ink", "background": "#101418"}]}')
        _, _, schemes = helper['settings']()
        self.assertEqual(schemes[0]['ring_active'], '#101418')
        self.assertEqual(schemes[0]['shadow'], '#101418')

    def test_duplicate_scheme_names_rejected(self):
        self.set('{"workspace_color_schemes": '
                 '[{"name": "a", "background": "#111111"}, '
                 ' {"name": "a", "background": "#222222"}]}')
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_quoted_scheme_name_rejected(self):
        self.set('{"workspace_color_schemes": [{"name": "a\\"b", "background": "#111111"}]}')
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_bad_hex_rejected(self):
        self.set('{"workspace_color_schemes": [{"name": "a", "background": "red"}]}')
        with self.assertRaises(ValueError):
            helper['settings']()


class Render(unittest.TestCase):
    def test_header_only_when_empty(self):
        self.assertEqual(helper['render_include']({}), helper['HEADER'])

    def test_layout_part_fields(self):
        text = helper['render_include']({'teal': helper['SCHEMES'][0]})
        self.assertIn('workspace "teal" {', text)
        self.assertIn('background-color "#2b3a42"', text)
        self.assertIn('focus-ring { active-color "#2fd8c2"; inactive-color "#3d5260"; }', text)
        self.assertIn('border { inactive-color "#3d5260"; }', text)
        self.assertIn('shadow { color "#1e243088"; }', text)
        self.assertIn('tab-indicator { active-color "#2fd8c2"; inactive-color "#3d5260"; }', text)

    def test_roundtrip_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'workspace-colors.kdl'
            self.addCleanup(patch_module('include_path', lambda: path))
            entries = {'teal': helper['SCHEMES'][0], 'neon': helper['SCHEMES'][2]}
            path.write_text(helper['render_include'](entries))
            self.assertEqual(helper['read_include_entries'](), {'teal', 'neon'})
            path.write_text(helper['HEADER'])
            self.assertEqual(helper['read_include_entries'](), set())


class PickScheme(unittest.TestCase):
    schemes = helper['SCHEMES']

    def test_sequential_skips_taken_and_advances_cursor(self):
        name, cursor = helper['pick_scheme']('sequential', self.schemes, {'teal'}, 0)
        self.assertEqual(name, 'purple')
        self.assertEqual(cursor, 2)

    def test_sequential_wraps_when_all_taken(self):
        name, cursor = helper['pick_scheme'](
            'sequential', self.schemes, {s['name'] for s in self.schemes}, 0)
        self.assertEqual(name, 'teal')
        self.assertEqual(cursor, 1)

    def test_random_stays_within_free_set(self):
        free = {'teal', 'purple', 'neon'}
        taken = {s['name'] for s in self.schemes} - free
        for _ in range(50):
            name, _ = helper['pick_scheme'](
                'random', self.schemes, taken, 0, rng=random.Random(1))
            self.assertIn(name, free)


class MainCli(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        (root / 'rt').mkdir()
        niri = root / 'niri'
        niri.write_text('#!/bin/sh\necho "$0 $@" >> "%s"\n' % (root / 'niri-calls.log'))
        niri.chmod(0o755)
        env = dict(os.environ, NIRI_SPACES_DIR=str(root / 'cfg'),
                   HOME=str(root), XDG_RUNTIME_DIR=str(root / 'rt'),
                   PATH=str(root) + os.pathsep + os.environ['PATH'])
        patcher = patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.root = root
        self.addCleanup(patch_module('include_path',
                                     lambda: root / '.config' / 'niri' / helper['INCLUDE_NAME']))

    def tearDown(self):
        self._tmp.cleanup()

    def run_main(self, *argv, **env):
        patcher = patch.dict(os.environ, dict(os.environ, **env))
        patcher.start()
        self.addCleanup(patcher.stop)
        with patch.object(sys, 'argv', ['niri-workspace-colors', *argv]):
            try:
                helper['main']()
                return 0
            except SystemExit as exit:
                return exit.code if isinstance(exit.code, int) else 1

    def test_check_validates_without_niri_or_writes(self):
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{"workspace_colors": true}')
        self.assertEqual(self.run_main('--check'), 0)
        self.assertFalse((self.root / 'niri-calls.log').exists())
        self.assertFalse((self.root / '.config' / 'niri' / helper['INCLUDE_NAME']).exists())

    def test_check_rejects_bad_settings(self):
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{"workspace_colors": 1}')
        self.assertEqual(self.run_main('--check'), 1)

    def test_check_disabled_reports_disabled(self):
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{}')
        self.assertEqual(self.run_main('--check'), 0)

    def test_disabled_daemon_exits_quietly(self):
        # `niri-spaces start` launches the helper regardless of the toggle:
        # when the feature is off the daemon must end normally (exit 0)
        # without talking to niri or touching the include file.
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{}')
        self.assertEqual(self.run_main(NIRI_SOCKET='fixture'), 0)
        self.assertFalse((self.root / 'niri-calls.log').exists())
        self.assertFalse((self.root / '.config' / 'niri' / helper['INCLUDE_NAME']).exists())

    def test_daemon_refused_outside_niri(self):
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{"workspace_colors": true}')
        self.assertEqual(self.run_main(NIRI_SOCKET=''), 1)

    def test_disabled_feature_refuses_commands(self):
        (self.root / 'cfg').mkdir(parents=True)
        (self.root / 'cfg' / 'settings.json').write_text('{}')
        self.assertEqual(self.run_main('recolor', '2'), 1)


LIFECYCLE_FAKE = (
    "#!/usr/bin/env python3\n"
    "import os, sys, time, pathlib, json\n"
    "pathlib.Path(os.environ['PID_FILE']).write_text(str(os.getpid()))\n"
    "if 'event-stream' not in sys.argv:\n"
    "    sys.exit(0)\n"
)


def lifecycle_fake(close_stdout):
    # The event is built here and embedded as a string literal, so the fake
    # script can never contain unbalanced parentheses of its own.
    event = json.dumps({'WorkspacesChanged': {'workspaces': [
        {'id': 1, 'idx': 1, 'name': None, 'output': 'eDP-1',
         'is_urgent': False, 'is_active': True, 'is_focused': True,
         'active_window_id': 1}]}})
    if close_stdout:
        return LIFECYCLE_FAKE + "os.close(1)\ntime.sleep(30)\n"
    return LIFECYCLE_FAKE + "print(" + repr(event) + ", flush=True)\n" \
        + "time.sleep(30)\n"


def _reap_process(proc):
    """Terminate a Popen if needed and close its pipes (no ResourceWarning)."""
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    for stream in (proc.stdout, proc.stderr, proc.stdin):
        if stream is not None:
            stream.close()


class LifecycleSubprocess(unittest.TestCase):
    def check(self, close_stdout):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'niri'
            fake.write_text(lifecycle_fake(close_stdout))
            fake.chmod(0o755)
            (root / 'cfg' / 'settings.json').parent.mkdir(parents=True)
            (root / 'cfg' / 'settings.json').write_text('{"workspace_colors": true}')
            (root / 'rt').mkdir()
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       HOME=str(root), XDG_RUNTIME_DIR=str(root / 'rt'),
                       NIRI_SOCKET='fixture', PID_FILE=str(root / 'child.pid'),
                       NIRI_SPACES_DIR=str(root / 'cfg'))
            script = Path(__file__).resolve().parents[1] / 'niri-workspace-colors'
            proc = subprocess.Popen(['python3', str(script)],
                                    env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not (root / 'child.pid').exists() and proc.poll() is None \
                        and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue((root / 'child.pid').exists())
                if not close_stdout:
                    proc.send_signal(signal.SIGTERM)
                _, stderr = proc.communicate(timeout=15)
                self.assertEqual(proc.returncode, 1 if close_stdout else 0, stderr)
                self.assertFalse(Path('/proc', (root / 'child.pid').read_text()).exists(),
                                 'event listener left behind')
            finally:
                _reap_process(proc)

    def test_sigterm_reaps_listener(self):
        self.check(False)

    def test_closed_stdout_exits_and_reaps_listener(self):
        self.check(True)

    def test_second_instance_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'niri'
            fake.write_text(LIFECYCLE_FAKE + "time.sleep(30)\n")
            fake.chmod(0o755)
            (root / 'cfg' / 'settings.json').parent.mkdir(parents=True)
            (root / 'cfg' / 'settings.json').write_text('{"workspace_colors": true}')
            (root / 'rt').mkdir()
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       HOME=str(root), XDG_RUNTIME_DIR=str(root / 'rt'),
                       NIRI_SOCKET='fixture', PID_FILE=str(root / 'child.pid'),
                       NIRI_SPACES_DIR=str(root / 'cfg'))
            script = str(Path(__file__).resolve().parents[1] / 'niri-workspace-colors')
            first = subprocess.Popen(['python3', script], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True)
            second = None
            try:
                deadline = time.monotonic() + 5
                while not (root / 'child.pid').exists() and first.poll() is None \
                        and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue((root / 'child.pid').exists())
                second = subprocess.run(['python3', script], env=env,
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(second.returncode, 0, second.stderr)
                self.assertIn('already running', second.stderr)
            finally:
                _reap_process(first)


if __name__ == '__main__':
    unittest.main()
