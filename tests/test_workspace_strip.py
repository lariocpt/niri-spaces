"""Unit tests for niri-workspace-strip: settings, schemes, ordering and the
reorder action. No desktop, no display: only the pure logic around the IPC
boundary is exercised here — the GTK painting and the pointer drag need a
live session and were verified there.

The idx fields are 1-based, exactly as niri's workspaces query reports them,
and they are the numbers the chips show and reorder accepts.
"""
from pathlib import Path
import json
import os
import runpy
import tempfile
import unittest
from unittest.mock import patch

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'niri-workspace-strip'))


def ws(ident, idx, name=None, focused=False, window=None, output='eDP-1'):
    return dict(id=ident, idx=idx, name=name, output=output, is_urgent=False,
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
        # No file at all: disabled, 30px, top edge, centered, no margin.
        self.assertEqual(helper['settings'](), (False, 30, 'top', 'center', 0))

    def test_enabled_and_custom_geometry(self):
        self.write_settings({'workspace_strip': True,
                             'workspace_strip_height': 48,
                             'workspace_strip_position': 'bottom',
                             'workspace_strip_align': 'right',
                             'workspace_strip_margin': 26})
        self.assertEqual(helper['settings'](), (True, 48, 'bottom', 'right', 26))

    def test_legacy_margin_top_is_still_honored(self):
        # 0.5.x configs only knew a top margin; the generically renamed key
        # wins when both are present.
        self.write_settings({'workspace_strip': True,
                             'workspace_strip_margin_top': 26})
        self.assertEqual(helper['settings']()[4], 26)
        self.write_settings({'workspace_strip': True,
                             'workspace_strip_margin_top': 26,
                             'workspace_strip_margin': 4})
        self.assertEqual(helper['settings']()[4], 4)

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
        for bad in (-1, helper['MAX_MARGIN'] + 1):
            self.write_settings({'workspace_strip': True, 'workspace_strip_margin': bad})
            with self.assertRaises(ValueError):
                helper['settings']()

    def test_position_and_align_are_enumerated(self):
        self.write_settings({'workspace_strip': True, 'workspace_strip_position': 'middle'})
        with self.assertRaises(ValueError):
            helper['settings']()
        self.write_settings({'workspace_strip': True, 'workspace_strip_align': 'justify'})
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
            # The daemon assigns from the full pool (classic + extra schemes),
            # so the chips must know the full pool too.
            names = ({s['name'] for s in colors['SCHEMES']}
                     | {s['name'] for s in colors['EXTRA_SCHEMES']})
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
        patch_module('settings', lambda: (True, 30, 'top', 'center', 0))

    def capture_msg(self):
        calls = []
        patch_module('msg', lambda *args: calls.append(list(args)) or '')
        return calls

    def test_cmd_reorder_aims_the_monitor_then_moves(self):
        # Index actions resolve against the FOCUSED monitor, so the CLI aims
        # at the target's screen first; the move itself is the reference
        # form verified against niri 26.04, and the name (the color) travels
        # with the workspace.
        self.stub_live([ws(1, 1), ws(5, 2, name='yellow'), ws(6, 3, name='purple')])
        calls = self.capture_msg()
        helper['cmd_reorder'](2, 3)
        self.assertEqual(calls, [
            ['action', 'focus-monitor', 'eDP-1'],
            ['action', 'move-workspace-to-index', '3', '--reference', '2']])

    def test_cmd_reorder_reads_the_focused_monitor_when_indexes_repeat(self):
        # Both screens number a workspace 2: an unqualified FROM means the
        # focused monitor's workspace 2, never the other one.
        self.stub_live([ws(1, 1), ws(5, 2, name='yellow'),
                        ws(9, 2, name='teal', focused=True, output='HDMI-A-1'),
                        ws(10, 3, output='HDMI-A-1')])
        calls = self.capture_msg()
        helper['cmd_reorder'](2, 3)
        self.assertEqual(calls, [
            ['action', 'focus-monitor', 'HDMI-A-1'],
            ['action', 'move-workspace-to-index', '3', '--reference', '2']])

    def test_cmd_reorder_with_an_explicit_output(self):
        self.stub_live([ws(1, 1, focused=True), ws(5, 2, name='yellow'),
                        ws(9, 1, output='HDMI-A-1'),
                        ws(10, 2, name='teal', output='HDMI-A-1')])
        calls = self.capture_msg()
        helper['cmd_reorder'](2, 1, 'HDMI-A-1')
        self.assertEqual(calls, [
            ['action', 'focus-monitor', 'HDMI-A-1'],
            ['action', 'move-workspace-to-index', '1', '--reference', '2']])

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


class GroupingTests(unittest.TestCase):
    """One strip per monitor: the per-monitor grouping is the whole basis
    of the layout, and niri's numbering restarts at 1 on every screen."""

    def test_workspaces_group_per_monitor_and_keep_their_numbering(self):
        live = [ws(1, 2), ws(2, 1),
                ws(3, 2, output='HDMI-A-1'), ws(4, 1, output='HDMI-A-1')]
        groups = helper['group_by_output'](live)
        self.assertEqual(sorted(groups), ['HDMI-A-1', 'eDP-1'])
        self.assertEqual([w['id'] for w in groups['eDP-1']], [2, 1])
        self.assertEqual([w['id'] for w in groups['HDMI-A-1']], [4, 3])

    def test_duplicate_indexes_never_share_a_row(self):
        # The duplicate-"1" chips bug: two monitors each had a workspace 1
        # and one strip drew both. Grouping must keep them apart.
        live = [ws(1, 1, focused=True), ws(2, 1, output='HDMI-A-1')]
        for group in helper['group_by_output'](live).values():
            self.assertEqual([w['idx'] for w in group], [1])
            self.assertEqual(len(group), 1)

    def test_focused_output_reads_the_focused_workspace(self):
        self.assertIsNone(helper['focused_output']([ws(1, 1)]))
        self.assertEqual(
            helper['focused_output']([ws(1, 1), ws(2, 1, focused=True, output='HDMI-A-1')]),
            'HDMI-A-1')


class FakeRect:
    def __init__(self, x, y, width, height):
        self.x, self.y, self.width, self.height = x, y, width, height


class FakeMonitor:
    """The three GdkMonitor getters assign_monitors consults."""

    def __init__(self, geometry=None, manufacturer=None, model=None):
        self._geometry, self._manufacturer, self._model = geometry, manufacturer, model

    def get_geometry(self):
        return self._geometry

    def get_manufacturer(self):
        return self._manufacturer

    def get_model(self):
        return self._model


class MonitorAssignmentTests(unittest.TestCase):
    """Output set -> GdkMonitor for any number and kind of screens: nothing
    in the mapping may know what eDP or HDMI mean specifically."""

    @staticmethod
    def outputs(*specs):
        out = {}
        for name, make, model, logical in specs:
            info = {'name': name}
            if make is not None:
                info['make'] = make
            if model is not None:
                info['model'] = model
            if logical is not None:
                info['logical'] = dict(zip(('x', 'y', 'width', 'height'), logical))
            out[name] = info
        return out

    def test_layout_geometry_matches_whatever_the_order(self):
        outputs = self.outputs(('eDP-1', 'Japan Display Inc.', 'GPD1001H',
                                (4267, 373, 1706, 1066)),
                               ('HDMI-A-1', 'Samsung Electric Company', 'U28E590',
                                (2560, 480, 1706, 960)))
        # GDK's list order differs and its rounding is a step off niri's:
        # the rectangles still identify each display uniquely.
        monitors = [FakeMonitor(FakeRect(2560, 480, 1707, 960)),
                    FakeMonitor(FakeRect(4267, 373, 1707, 1067))]
        mapping = helper['assign_monitors'](outputs, monitors)
        self.assertEqual(mapping, {'eDP-1': monitors[1], 'HDMI-A-1': monitors[0]})

    def test_identical_models_at_different_places_each_get_their_own(self):
        # Two same-model screens share one EDID identity, and GTK 3 offers
        # no connector name to break the tie: the layout geometry must, and
        # it says exactly which monitor is which.
        outputs = self.outputs(('DP-1', 'ACME', 'X1', (0, 0, 1920, 1080)),
                               ('DP-2', 'ACME', 'X1', (1920, 0, 1920, 1080)))
        monitors = [FakeMonitor(FakeRect(1920, 0, 1920, 1080), 'ACME', 'X1'),
                    FakeMonitor(FakeRect(0, 0, 1920, 1080), 'ACME', 'X1')]
        mapping = helper['assign_monitors'](outputs, monitors)
        self.assertIs(mapping['DP-1'], monitors[1])
        self.assertIs(mapping['DP-2'], monitors[0])

    def test_edid_identity_is_the_fallback_when_geometry_disagrees(self):
        # A screen whose geometry GDK reports outside niri's rounding step
        # (or not at all): make+model, handed out one-to-one, still maps
        # both identical models without double-booking one.
        outputs = self.outputs(('DP-1', 'ACME', 'X1', None), ('DP-2', 'ACME', 'X1', None))
        monitors = [FakeMonitor(FakeRect(0, 0, 800, 600), 'ACME', 'X1'),
                    FakeMonitor(FakeRect(800, 0, 1280, 1024), 'ACME', 'X1')]
        mapping = helper['assign_monitors'](outputs, monitors)
        self.assertEqual(len(mapping), 2)
        self.assertIsNot(mapping['DP-1'], mapping['DP-2'])

    def test_screen_without_any_identity_matches_when_alone(self):
        # A panel reporting no EDID and no usable geometry still gets its
        # strip — but only while it is unambiguous: one output, one monitor.
        outputs = self.outputs(('LVDS-1', None, None, None))
        monitors = [FakeMonitor(FakeRect(0, 0, 1024, 768), 'OTHER', 'Z9')]
        self.assertEqual(helper['assign_monitors'](outputs, monitors),
                         {'LVDS-1': monitors[0]})

    def test_unmappable_output_is_left_unmapped_not_guessed_at(self):
        # GDK has enumerated one monitor while niri reports two with known
        # but different identities (a hotplug mid-flight): the outputs must
        # not guess-share the one screen.
        outputs = self.outputs(('DP-1', 'ACME', 'X1', (0, 0, 1920, 1080)),
                               ('DP-2', 'ACME', 'X2', (1920, 0, 1920, 1080)))
        monitors = [FakeMonitor(FakeRect(0, 0, 1920, 1080), 'ACME', 'X1')]
        self.assertEqual(helper['assign_monitors'](outputs, monitors),
                         {'DP-1': monitors[0]})

    def test_geometry_beyond_the_rounding_step_is_not_a_match(self):
        # Two places 100px apart are two displays; only a rounding step of
        # a few pixels is "the same rectangle" to niri and GDK.
        rect = FakeRect(0, 0, 1920, 1080)
        self.assertTrue(helper['geometry_matches'](
            {'x': 0, 'y': 0, 'width': 1921, 'height': 1081}, rect))
        self.assertFalse(helper['geometry_matches'](
            {'x': 100, 'y': 0, 'width': 1920, 'height': 1080}, rect))
        self.assertFalse(helper['geometry_matches'](None, rect))


class DragRowTests(unittest.TestCase):
    """The drag's row arithmetic — which slot holds what, how wide the row
    is — is pure computation; the GTK painting only draws its answer."""

    def make_strip(self, n=3):
        strip = helper['MonitorStrip']('eDP-1', None, None, None, None)
        strip.group = [ws(i, i) for i in range(1, n + 1)]
        return strip

    def test_plain_row_is_the_group_untouched(self):
        strip = self.make_strip()
        self.assertEqual(strip.row_layout(), [(w, False) for w in strip.group])
        self.assertEqual(strip.width(), 3 * helper['CHIP_WIDTH'])

    def test_press_without_motion_is_not_a_drag(self):
        strip = self.make_strip()
        strip.drag = {'ws': strip.group[0], 'x0': 4, 'y0': 4, 'moved': False, 'gap': 0}
        self.assertEqual(strip.row_layout(), [(w, False) for w in strip.group])
        self.assertEqual(strip.width(), 3 * helper['CHIP_WIDTH'])

    def test_lifted_chip_travels_and_the_row_keeps_every_slot(self):
        strip = self.make_strip()
        strip.drag = {'ws': strip.group[0], 'x0': 0, 'y0': 0, 'moved': True, 'gap': 2}
        row = strip.row_layout()
        self.assertEqual(len(row), 3)  # a chip lifts, it never vanishes
        self.assertEqual([(w['id'], gap) for w, gap in row],
                         [(2, False), (3, False), (1, True)])
        self.assertEqual(strip.width(), 3 * helper['CHIP_WIDTH'] + helper['GAP_EXTRA'])

    def test_gap_opens_at_exactly_one_slot(self):
        strip = self.make_strip()
        source = strip.group[1]
        for gap in range(3):
            strip.drag = {'ws': source, 'x0': 0, 'y0': 0, 'moved': True, 'gap': gap}
            row = strip.row_layout()
            self.assertEqual([pos for pos, (w, is_gap) in enumerate(row) if is_gap], [gap])
            self.assertEqual([w['id'] for w, is_gap in row if not is_gap], [1, 3])

    def test_slot_at_clamps_events_outside_the_row(self):
        # During a pointer grab motions arrive far outside the window; the
        # hit test must saturate at the first/last slot, never return None.
        strip = self.make_strip()
        strip.slots = [(0, 44, 0), (44, 88, 1), (88, 132, 2)]
        self.assertEqual(strip.slot_at(-500), 0)
        self.assertEqual(strip.slot_at(60), 1)
        self.assertEqual(strip.slot_at(9999), 2)


class ChipGeometryTests(unittest.TestCase):
    def test_constants_keep_chips_clickable(self):
        # The chip box is a widget-level size request (CSS min-width proved
        # unreliable on labels); it must stay wide enough for two digits.
        self.assertGreaterEqual(helper['CHIP_WIDTH'], 32)
        self.assertLessEqual(helper['MIN_HEIGHT'], helper['DEFAULT_HEIGHT'])
        self.assertLessEqual(helper['DEFAULT_HEIGHT'], helper['MAX_HEIGHT'])


class WaybarSuppressionTests(unittest.TestCase):
    """The strip is the fallback workspace row: it stays out of the way while
    the waybar itself draws the niri/workspaces module, and runs whenever the
    bar shows no chips (no bar, other modules only, or a broken config)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = patch.dict(os.environ, dict(os.environ,
                                              XDG_CONFIG_HOME=self.tmp.name))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.waybar_dir = Path(self.tmp.name, 'waybar')
        self.waybar_dir.mkdir()
        self.waybar_config = self.waybar_dir / 'config'

    def write_config(self, data):
        self.waybar_config.write_text(data)

    def test_no_waybar_config_runs_the_strip(self):
        self.assertFalse(helper['waybar_shows_workspaces']())

    def test_config_directory_without_file_runs_the_strip(self):
        self.assertFalse(helper['waybar_shows_workspaces']())

    def test_module_on_any_edge_suppresses(self):
        for edge in ('top', 'bottom', 'left', 'right', 'center'):
            with self.subTest(edge=edge):
                self.write_config(json.dumps(
                    {'modules-' + edge: ['niri/workspaces', 'clock']}))
                self.assertTrue(helper['waybar_shows_workspaces']())

    def test_other_modules_only_do_not_suppress(self):
        self.write_config(json.dumps({
            'layer': 'top', 'position': 'top',
            'modules-left': ['niri/window'],
            'modules-center': ['work/custom-chips'],
            'modules-right': ['network', 'clock', 'tray']}))
        self.assertFalse(helper['waybar_shows_workspaces']())

    def test_unparseable_config_does_not_suppress(self):
        # A broken config means the bar shows no chips at all.
        self.write_config('this is not json {')
        self.assertFalse(helper['waybar_shows_workspaces']())

    def test_non_list_modules_entry_does_not_suppress(self):
        # The JSON parsed but the shape is wrong: not a module list.
        self.write_config(json.dumps({'modules-top': 'niri/workspaces'}))
        self.assertFalse(helper['waybar_shows_workspaces']())

    def test_home_fallback_when_xdg_unset(self):
        env = {k: v for k, v in os.environ.items() if k != 'XDG_CONFIG_HOME'}
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        home = Path(self.tmp.name, 'home')
        (home / '.config' / 'waybar').mkdir(parents=True)
        (home / '.config' / 'waybar' / 'config').write_text(json.dumps(
            {'modules-bottom': ['niri/workspaces']}))

        class FakePath(Path):
            @staticmethod
            def home():
                return home

        self.addCleanup(patch_module('Path', FakePath))
        self.assertTrue(helper['waybar_shows_workspaces']())


if __name__ == '__main__':
    unittest.main()
