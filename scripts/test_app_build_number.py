"""APP_BUILD_NUMBER must be a strictly positive integer everywhere it is produced.

Covers scripts/build_mobile.py (Python) and scripts/get-app-build-number.ps1 + run.ps1 (PowerShell).
No Flutter, Firebase or network is used; configuration files are fake.
"""
import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build_mobile

REPO = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which('powershell') or shutil.which('pwsh')
FAKE_ANDROID = {
    'FIREBASE_ANDROID_API_KEY': 'fake', 'FIREBASE_ANDROID_APP_ID': 'fake',
    'FIREBASE_MESSAGING_SENDER_ID': 'fake', 'FIREBASE_PROJECT_ID': 'az-express-b0469',
    'FIREBASE_STORAGE_BUCKET': 'fake',
}
INVALID_NUMBERS = ['0', '-5', 'abc', '1.5', '', ' ', '2100000001', '99999999999999999999']


class ResolveBuildNumberTest(unittest.TestCase):
    def test_valid_values(self):
        self.assertEqual(build_mobile.resolve_build_number(None, 'version: 1.0.10+11\n'), 11)
        self.assertEqual(build_mobile.resolve_build_number(1, ''), 1)
        self.assertEqual(build_mobile.resolve_build_number(
            build_mobile.MAX_BUILD_NUMBER, ''), build_mobile.MAX_BUILD_NUMBER)

    def test_invalid_overrides(self):
        for value in [0, -5, 'abc', True, 1.5, build_mobile.MAX_BUILD_NUMBER + 1]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build_mobile.resolve_build_number(value, 'version: 1.0.10+11\n')

    def test_invalid_or_absent_pubspec_number(self):
        for text in ['', 'name: x\n', 'version: 1.0.10\n', 'version: 1.0.10+0\n', 'version: 1.0.10+-5\n',
                     'version: 1.0.10+abc\n', 'version: 1.0.10+2100000001\n', 'version: 1.0.10+\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                build_mobile.resolve_build_number(None, text)


class CommandLineTest(unittest.TestCase):
    """Exit codes of build_mobile.main() with a temporary repository root and a fake configuration."""

    def run_main(self, args, pubspec='name: x\nversion: 1.0.10+11\n'):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'lib').mkdir()
            shutil.copy(REPO / 'lib' / 'firebase_options.dart', root / 'lib' / 'firebase_options.dart')
            if pubspec is not None:
                (root / 'pubspec.yaml').write_text(pubspec, encoding='utf-8')
            config = root / 'config.json'
            config.write_text(json.dumps(FAKE_ANDROID), encoding='utf-8')
            out, err = io.StringIO(), io.StringIO()
            argv = ['build_mobile.py', *args, '--config', str(config)]
            with mock.patch.object(build_mobile, 'ROOT', root), mock.patch.object(sys, 'argv', argv), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = build_mobile.main()
                except SystemExit as exit_:
                    code = exit_.code
            return code, out.getvalue(), err.getvalue()

    def test_valid_build_is_accepted(self):
        code, out, _ = self.run_main(['apk', '--check-only'])
        self.assertEqual(code, 0)
        self.assertIn('APP_BUILD_NUMBER=11', out)

    def test_valid_ipa_override_is_accepted(self):
        # --check-only on ipa reads the plist; override logic is covered by resolve_build_number tests.
        self.assertEqual(build_mobile.resolve_build_number(42, 'version: 1.0.10+11\n'), 42)

    def test_invalid_build_number_option_exits_2(self):
        for value in INVALID_NUMBERS:
            with self.subTest(value=value):
                code, out, _ = self.run_main(['ipa', '--check-only', '--build-number', value])
                self.assertEqual(code, 2)
                self.assertNotIn('PASS', out)

    def test_absent_or_invalid_pubspec_number_exits_2(self):
        for pubspec in [None, 'name: x\n', 'version: 1.0.10\n', 'version: 1.0.10+0\n',
                        'version: 1.0.10+-5\n', 'version: 1.0.10+abc\n']:
            with self.subTest(pubspec=pubspec):
                code, out, _ = self.run_main(['apk', '--check-only'], pubspec=pubspec)
                self.assertEqual(code, 2)
                self.assertNotIn('PASS', out)

    def test_android_build_number_option_is_refused(self):
        code, _, _ = self.run_main(['apk', '--check-only', '--build-number', '12'])
        self.assertEqual(code, 2)


@unittest.skipUnless(POWERSHELL, 'PowerShell not available')
class PowerShellHelperTest(unittest.TestCase):
    def helper(self, pubspec):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'pubspec.yaml'
            if pubspec is not None:
                path.write_text(pubspec, encoding='utf-8')
            done = subprocess.run(
                [POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                 str(REPO / 'scripts' / 'get-app-build-number.ps1'), '-PubspecPath', str(path)],
                capture_output=True, text=True, timeout=60)
            return done.returncode, done.stdout.strip()

    def test_valid(self):
        self.assertEqual(self.helper('version: 1.0.10+11\n'), (0, '11'))
        self.assertEqual(self.helper('version: 1.0.10+2100000000\n'), (0, '2100000000'))

    def test_invalid_or_absent(self):
        for pubspec in [None, '', 'name: x\n', 'version: 1.0.10\n', 'version: 1.0.10+0\n',
                        'version: 1.0.10+-5\n', 'version: 1.0.10+abc\n', 'version: 1.0.10+2100000001\n',
                        'version: 1.0.10+99999999999999999999\n']:
            with self.subTest(pubspec=pubspec):
                code, out = self.helper(pubspec)
                self.assertEqual(code, 1)
                self.assertEqual(out, '')

    def run_script(self, pubspec, env_content, *args):
        """run.ps1 copied next to a temporary pubspec, executed with -DryRun (nothing is launched)."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'scripts').mkdir()
            shutil.copy(REPO / 'run.ps1', root / 'run.ps1')
            shutil.copy(REPO / 'scripts' / 'get-app-build-number.ps1', root / 'scripts' / 'get-app-build-number.ps1')
            (root / 'pubspec.yaml').write_text(pubspec, encoding='utf-8')
            (root / '.env').write_text(env_content, encoding='utf-8')
            done = subprocess.run(
                [POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'run.ps1'),
                 '-DryRun', *args], cwd=root, capture_output=True, text=True, timeout=60)
            return done.returncode, done.stdout

    def test_run_script_injects_valid_number(self):
        code, out = self.run_script('version: 1.0.10+11\n', '{"A":"b"}')
        self.assertEqual(code, 0)
        self.assertIn('--dart-define=APP_BUILD_NUMBER=11', out)
        code, out = self.run_script('version: 1.0.10+11\n', '{"A":"b"}', '-Device', 'R9PN', '-release')
        self.assertEqual(code, 0)
        self.assertIn('run -d R9PN --dart-define-from-file=.env --dart-define=APP_BUILD_NUMBER=11 --release', out)

    def test_run_script_refuses_invalid_numbers(self):
        for pubspec in ['version: 1.0.10+0\n', 'version: 1.0.10+-5\n', 'version: 1.0.10+abc\n', 'version: 1.0.10\n']:
            with self.subTest(pubspec=pubspec):
                code, out = self.run_script(pubspec, '{"A":"b"}')
                self.assertNotEqual(code, 0)
                self.assertNotIn('DRYRUN', out)

    def test_run_script_refuses_number_in_env(self):
        code, out = self.run_script('version: 1.0.10+11\n', '{"APP_BUILD_NUMBER":"5"}')
        self.assertNotEqual(code, 0)
        self.assertNotIn('DRYRUN', out)


if __name__ == '__main__':
    unittest.main()
