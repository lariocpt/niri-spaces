"""Settings are validated before starting a watcher or touching session state."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'niri-terminal-pairs'


class Settings(unittest.TestCase):
    def run_helper(self, config=None, override=None, args=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            if config is not None:
                (root / 'settings.json').write_text(json.dumps(config))
            env = dict(os.environ, NIRI_SPACES_DIR=directory)
            for key in ('NIRI_SOCKET', 'XDG_RUNTIME_DIR', 'NIRI_SPACES_TERMINAL_PAIRS'):
                env.pop(key, None)
            if override is not None:
                env['NIRI_SPACES_TERMINAL_PAIRS'] = override
            before = sorted(p.name for p in root.iterdir())
            result = subprocess.run([str(HELPER), *args], env=env, text=True, capture_output=True)
            self.assertEqual(before, sorted(p.name for p in root.iterdir()))
            return result

    def test_default_and_explicit_off_exit_without_a_session(self):
        for config in (None, {'terminal_pairs': False}):
            result = self.run_helper(config)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('disabled', result.stderr)

    def test_check_enabled_with_custom_ids_is_nonmutating(self):
        result = self.run_helper({'terminal_pairs': True, 'terminal_app_ids': ['my-shell']}, args=['--check'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('enabled', result.stderr)

    def test_invalid_settings_refused_before_session_access(self):
        for config in ({'terminal_pairs': 'false'}, {'terminal_app_ids': []},
                       {'terminal_app_ids': 'foot'}, {'terminal_app_ids': [4]}):
            result = self.run_helper(config, args=['--check'])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('invalid settings', result.stderr)

    def test_environment_can_disable_configured_watcher(self):
        result = self.run_helper({'terminal_pairs': True}, override='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('disabled', result.stderr)

    def test_environment_can_enable_and_invalid_override_is_refused(self):
        result = self.run_helper(override='1', args=['--check'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('enabled', result.stderr)
        self.assertNotEqual(self.run_helper(override='yes', args=['--check']).returncode, 0)

    def test_enabled_requires_a_live_session(self):
        result = self.run_helper({'terminal_pairs': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Run inside Niri', result.stderr)
