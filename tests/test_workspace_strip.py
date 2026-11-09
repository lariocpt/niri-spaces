"""Unit tests for niri-workspace-strip: settings, schemes, ordering and the
reorder action. No desktop, no display: only the pure logic around the IPC
boundary is exercised here — the GTK painting and the pointer drag need a
live session and were verified there.

The idx fields are 1-based, exactly as niri's workspaces query reports them,
and they are the numbers the chips show and reorder accepts.
"""
from pathlib import Path
import json
import runpy
import tempfile
import unittest

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'niri-workspace-strip'))


def ws(ident, idx, name=None, focused=False, window=None):
    return dict(id=ident, idx=idx, name=name, output='eDP-1', is_urgent=False,
                is_active=focused, is_focused=focused, active_window_id=window)


def patch_module(name, value):
    """runpy.run_path returns a dict that is not the functions' __globals__;
    patch the real globals dict they share (same trick as the colors tests).
    Returns a cleanup restoring the previous binding."""
    globals_dict = helper['sort_workspaces'].__globals__
    sentinel = object()
    original = globals_dict.get(name, sentinel)

    globals_dict[name] = value

    def cleanup():
        if original is sentinel:
            del globals_dict[name]
        else:
            globals_dict[name] = original
    return cleanup


class ConfigTestCase(unittest.TestCase):
    """Shared plumbing: every settings/scheme lookup points at a temp dir."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        directory = self.tmp.name
        self.addCleanup(patch_module('config_dir', lambda: Path(directory)))

    def write_settings(self, data):
        Path(self.tmp.name, 'settings.json').write_text(json.dumps(data))


class SettingsTests(ConfigTestCase):
    def test_defaults(self):
        # No file at all: disabled, 30px, flush corner.
        self.assertEqual(helper['settings'](), (False, 30, 0))

    def test_enabled_and_custom_geometry(self):
        self.write_settings({'workspace_strip': True,
                             'workspace_strip_height': 48,
                             'workspace_strip_margin_top': 26})
        self.assertEqual(helper['settings'](), (True, 48, 26))

    def test_string_toggle_is_rejected(self):
        self.write_settings({'workspace_strip': 'yes'})
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_height_out_of_range_is_rejected(self):
        for bad in (helper['MIN_HEIGHT'] - 1, helper['MAX_HEIGHT'] + 1, True):
            self.write_settings({'workspace_strip': True, 'workspace_strip_height': bad})
            with self.assertRaises(ValueError):
                helper['settings']()

    def test_margin_out_of_range_is_rejected(self):
        self.write_settings({'workspace_strip': True,
                             'workspace_strip_margin_top': helper['MAX_MARGIN_TOP'] + 1})
        with self.assertRaises(ValueError):
            helper['settings']()

    def test_negative_margin_is_rejected(self):
        self.write_settings({'workspace_strip': True, 'workspace_strip_margin_top': -1})
        with self.assertRaises(ValueError):
            helper['settings']()


class SchemeTests(ConfigTestCase):
    def test_settings_schemes_are_normalized_and_keyed_by_name(self):
        self.write_settings({'workspace_color_schemes': [
            {'name': 'grape', 'background': '#100010', 'ring_active': '#ff00ff'}]})
        schemes = helper['color_schemes']()
        self.assertEqual(sorted(schemes), ['grape'])
        grape = schemes['grape']
        self.assertEqual(grape['ring_active'], '#ff00ff')
        # A missing accent falls back to the background, never to empty.
        self.assertEqual(grape['border'], '#100010')

    def test_builtin_fallback_matches_the_color_watcher_palette(self):
        # No settings file: the strip reads the watcher's SCHEMES so the two
        # tools cannot drift; if the watcher is uninstalled the error names
        # both escape hatches.
        try:
            schemes = helper['color_schemes']()
        except ValueError as error:
            self.assertIn('workspace_color_schemes', str(error))
            self.assertIn('niri-workspace-colors', str(error))
        else:
            colors = runpy.run_path(str(Path(__file__).resolve().parents[1]
                                        / 'niri-workspace-colors'))
            names = {s['name'] for s in colors['SCHEMES']}
            self.assertEqual(set(schemes), names)

    def test_scheme_requires_a_name(self):
        self.write_settings({'workspace_color_schemes': [{'background': '#111'}]})
        with self.assertRaises(ValueError):
            helper['color_schemes']()

    def test_scheme_for_prefers_the_watchers_record_then_the_name(self):
        table = {'sunset': {'name': 'sunset', 'background': '#100',
                            'ring_active': '#f80'}}
        # The watcher's assignment for the id wins over any name.
        self.assertIs(helper['scheme_for'](ws(4, 2, name='sunset'),
                                           {'4': 'sunset'}, table),
                      table['sunset'])
        # An unmanaged workspace that merely bears the name still colors.
        self.assertIs(helper['scheme_for'](ws(4, 2, name='sunset'), {}, table),
                      table['sunset'])
        # An assignment to a scheme that no longer exists is not fatal.
        self.assertIsNone(helper['scheme_for'](ws(4, 2, name='gone'),
                                               {'4': 'missing'}, table))
        # A nameless workspace is the machine theme: no scheme.
        self.assertIsNone(helper['scheme_for'](ws(4, 2), {}, table))

    def test_color_assignments_are_read_as_strings(self):
        Path(self.tmp.name, helper['COLOR_STATE_NAME']).write_text(json.dumps(
            {'assignments': {5: 'grape', '6': 'mint'}, 'cursor': 0}))
        self.assertEqual(helper['read_color_assignments'](),
                         {'5': 'grape', '6': 'mint'})

    def test_broken_state_file_is_no_assignments(self):
        Path(self.tmp.name, helper['COLOR_STATE_NAME']).write_text('{not json')
        self.assertEqual(helper['read_color_assignments'](), {})


class OrderingTests(unittest.TestCase):
    def test_chips_follow_displayed_index_not_creation_order(self):
        # niri reports in creation order; the chips must read 1..n left to
        # right exactly as niri's own numbering shows them.
        live = [ws(6, 3, name='purple'), ws(1, 1), ws(5, 2, name='yellow')]
        self.assertEqual([w['idx'] for w in helper['sort_workspaces'](live)], [1, 2, 3])
        self.assertEqual([w['id'] for w in helper['sort_workspaces'](live)], [1, 5, 6])

    def test_workspaces_query_sorts(self):
        # workspaces takes the IPC call as its (default) argument, so the
        # test injects the fake the same way the daemon would inject msg.
        payload = json.dumps([ws(6, 2, name='purple'), ws(1, 1)])
        got = helper['workspaces'](request=lambda *_args: payload)
        self.assertEqual([w['idx'] for w in got], [1, 2])


class ReorderTests(unittest.TestCase):
    def test_drag_emits_one_reference_move(self):
        # The exact wire form verified against niri 26.04: move chip i onto
        # column j. The name (the color) travels with the workspace.
        self.assertEqual(
            helper['reorder_args'](3, 5),
            ['action', 'move-workspace-to-index', '5', '--reference', '3'])

    def test_same_position_is_a_refused_no_op(self):
        with self.assertRaises(ValueError):
            helper['reorder_args'](4, 4)

    def test_reference_lookup_uses_the_displayed_index(self):
        live = [ws(1, 1), ws(5, 2, name='yellow'), ws(6, 3, name='purple')]
        self.assertEqual(helper['reorder_reference'](live, 2)['id'], 5)
        self.assertIsNone(helper['reorder_reference'](live, 9))

    def stub_live(self, live):
        self.addCleanup(patch_module('msg', helper['msg']))
        patch_module('msg', lambda *_args: '')
        self.addCleanup(patch_module('workspaces', helper['workspaces']))
        patch_module('workspaces', lambda request=None: list(live))
        self.addCleanup(patch_module('settings', helper['settings']))
        patch_module('settings', lambda: (True, 30, 0))

    def test_cmd_reorder_moves_the_workspace_at_from(self):
        calls = []
        self.stub_live([ws(1, 1), ws(5, 2, name='yellow'), ws(6, 3, name='purple')])
        patch_module('msg', lambda *args: calls.append(list(args)) or '')
        helper['cmd_reorder'](2, 3)
        self.assertEqual(calls, [['action', 'move-workspace-to-index',
                                  '3', '--reference', '2']])

    def test_cmd_reorder_refuses_an_empty_slot(self):
        self.stub_live([ws(1, 1), ws(5, 2, name='yellow')])
        with self.assertRaises(SystemExit) as caught:
            helper['cmd_reorder'](7, 1)
        self.assertIn('no workspace at index 7', str(caught.exception))

    def test_cmd_reorder_refuses_to_move_a_workspace_onto_itself(self):
        self.stub_live([ws(1, 1), ws(5, 2, name='yellow')])
        with self.assertRaises(SystemExit) as caught:
            helper['cmd_reorder'](2, 2)
        self.assertIn('already at that position', str(caught.exception))


class ChipGeometryTests(unittest.TestCase):
    def test_constants_keep_chips_clickable(self):
        # The chip box is a widget-level size request (CSS min-width proved
        # unreliable on labels); it must stay wide enough for two digits.
        self.assertGreaterEqual(helper['CHIP_WIDTH'], 32)
        self.assertLessEqual(helper['MIN_HEIGHT'], helper['DEFAULT_HEIGHT'])
        self.assertLessEqual(helper['DEFAULT_HEIGHT'], helper['MAX_HEIGHT'])


if __name__ == '__main__':
    unittest.main()
