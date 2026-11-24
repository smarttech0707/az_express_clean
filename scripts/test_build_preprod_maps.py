"""M2.9 tests (F4, F7): Google Maps key handling of build_preprod.py. Fake keys only, no Firebase, no real build."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_preprod as bp  # noqa: E402
from test_build_preprod import (  # noqa: E402
    PROD_KEY, PROD_MAPS, REPO, TEST_KEY, Base, good_defines)

NODE = shutil.which('node')
NODE_SCRIPT = REPO / 'test-env/check-no-prod-maps-key.js'


def defines_without_test_key():
    d = good_defines()
    del d['TEST_MAPS_API_KEY']
    return d


class MapsKeyValidationTest(Base):
    """C1-C5: production key identification and test key rules."""

    def check_with(self, defines, *extra):
        config, gs = self.files(defines)
        return self.check(config, gs, *extra)

    def test_valid_test_key_accepted(self):
        code, out, err = self.check_with(good_defines())
        self.assertEqual(code, 0, err)

    def test_absent_test_key_refused_unless_maps_explicitly_disabled(self):
        code, _, err = self.check_with(defines_without_test_key())
        self.assertEqual(code, 2); self.assertIn('--maps-disabled', err)
        code, _, err = self.check_with(defines_without_test_key(), '--maps-disabled')
        self.assertEqual(code, 0, err)
        d = good_defines(); d['TEST_MAPS_API_KEY'] = ''
        self.assertEqual(self.check_with(d)[0], 2)

    def test_maps_disabled_with_a_key_is_ambiguous_and_refused(self):
        code, _, err = self.check_with(good_defines(), '--maps-disabled')
        self.assertEqual(code, 2); self.assertIn('conflicts', err)

    def test_invalid_or_production_test_key_refused(self):
        for value in ('short', 'AIza' + 'x' * 34, 'AIza' + 'x' * 36, 'BIza' + 'x' * 35, 'AIza' + 'x' * 34 + ' ', 12345):
            d = good_defines(); d['TEST_MAPS_API_KEY'] = value
            code, _, err = self.check_with(d)
            self.assertEqual(code, 2, repr(value))
        d = good_defines(); d['TEST_MAPS_API_KEY'] = PROD_KEY
        code, _, err = self.check_with(d)
        self.assertEqual(code, 2); self.assertIn('production Google Maps key', err)

    def test_original_without_key_cannot_bypass_the_check(self):
        self.maps.write_text("const String kMapsApiKey = '';\n")
        code, _, err = self.check_with(good_defines())
        self.assertEqual(code, 2); self.assertIn('no production Google Maps key', err)
        code, _, err = self.check_with(defines_without_test_key(), '--maps-disabled')
        self.assertEqual(code, 2)  # --maps-disabled does not relax the identification of the production key

    def test_ambiguous_or_unexpected_original_refused(self):
        other = 'AIza' + 'Q' * 35
        for text in (f"a='{PROD_KEY}'; b='{other}';", f"a='{PROD_KEY}Z';", "a='AIzaSHORTSHORTSHORTSHORT';",
                     f"a='{PROD_KEY}'; b='AIzaSHORTSHORTSHORTSHORT';"):
            self.maps.write_text(text)
            code, _, err = self.check_with(good_defines())
            self.assertEqual(code, 2, text)
            self.assertTrue('ambiguous' in err or 'no production' in err, err)

    def test_build_is_refused_before_any_change_when_key_unidentifiable(self):
        self.maps.write_text('nothing here')
        _, gs = self.files()
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call') as call:
            with self.assertRaises(bp.PreprodError):
                bp.build(good_defines(), gs, 11)
        call.assert_not_called()
        self.assertEqual(self.maps.read_text(), 'nothing here')
        self.assertFalse(self.recovery.exists())
        self.assertFalse(self.native.exists())

    def test_secrets_never_in_validation_output(self):
        outputs = []
        for defines, extra in ((good_defines(), ()), (defines_without_test_key(), ()),
                               ({**good_defines(), 'TEST_MAPS_API_KEY': PROD_KEY}, ()),
                               ({**good_defines(), 'TEST_MAPS_API_KEY': 'AIza-bad'}, ())):
            _, out, err = self.check_with(defines, *extra)
            outputs.append(out + err)
        self.maps.write_text(f"a='{PROD_KEY}'; b='AIza{'Q' * 35}';")
        _, out, err = self.check_with(good_defines())
        outputs.append(out + err)
        for text in outputs:
            self.assertNotIn(PROD_KEY, text); self.assertNotIn(TEST_KEY, text); self.assertNotIn('QQQQ', text)


class MapsKeyBuildTest(Base):
    """F7 (C6-C9): the test key is never in the visible command line; temporary files are cleaned."""

    def run_build(self, maps_disabled=False, defines=None, exit_code=0):
        _, gs = self.files()
        seen = {}

        def fake_call(command, **kwargs):
            seen['command'] = list(command)
            for arg in command:
                if arg.startswith('--android-project-arg=azTestMapsKeyFile='):
                    key_file = Path(arg.split('=', 2)[2])
                    seen['key_file'] = key_file
                    seen['key_file_content'] = key_file.read_text(encoding='utf-8')
                    seen['key_file_mode'] = key_file.stat().st_mode & 0o777
            seen['maps_swapped_during'] = 'test' in self.maps.read_text()
            define_arg = [a for a in command if a.startswith('--dart-define-from-file=')][0]
            seen['defines_file'] = Path(define_arg.split('=', 1)[1])
            seen['defines'] = json.loads(seen['defines_file'].read_text())
            if exit_code == 0:
                apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
                apk.parent.mkdir(parents=True, exist_ok=True)
                apk.write_bytes(b'x')
            return exit_code

        out, err = io.StringIO(), io.StringIO()
        error = None
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', side_effect=fake_call), \
                mock.patch.object(bp, 'audit_apk'), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                bp.build(defines or good_defines(), gs, 11, node_checks=False, maps_disabled=maps_disabled)
            except bp.PreprodError as exc:
                error = exc
        return seen, error, out.getvalue() + err.getvalue()

    def assert_clean(self, seen):
        self.assertFalse(self.native.exists())
        self.assertFalse(self.recovery.exists())  # backup and state removed once the restore is proven
        self.assertEqual(self.maps.read_text(), PROD_MAPS)  # maps_key.dart restored
        if 'key_file' in seen:
            self.assertFalse(seen['key_file'].exists())  # secret file removed with the scratch folder
        self.assertFalse(seen['defines_file'].exists())

    def test_test_key_is_not_in_the_command_line_but_reaches_gradle_through_a_file(self):
        seen, error, log = self.run_build()
        self.assertIsNone(error)
        joined = ' '.join(seen['command'])
        self.assertNotIn(TEST_KEY, joined); self.assertNotIn(PROD_KEY, joined)
        self.assertEqual([a for a in seen['command'] if a.startswith('--android-project-arg=azTestMapsKey=')],
                         ['--android-project-arg=azTestMapsKey='])  # legacy property forced empty
        self.assertEqual(seen['key_file_content'], TEST_KEY)  # Gradle can read it while the build runs
        if os.name != 'nt':
            self.assertEqual(seen['key_file_mode'], 0o600)
        self.assertTrue(seen['maps_swapped_during'])
        self.assert_clean(seen)

    def test_maps_disabled_passes_no_key_only_empty_properties(self):
        """M2.12: both properties are explicit and empty (the key file holds nothing), so no ambient value can leak in."""
        seen, error, _ = self.run_build(maps_disabled=True, defines=defines_without_test_key())
        self.assertIsNone(error)
        self.assertEqual(sorted(a.split('=', 2)[1] for a in seen['command'] if 'MapsKey' in a),
                         ['azTestMapsKey', 'azTestMapsKeyFile'])
        self.assertEqual([a for a in seen['command'] if a.startswith('--android-project-arg=azTestMapsKey=')],
                         ['--android-project-arg=azTestMapsKey='])
        self.assertEqual(seen['key_file_content'], '')  # an EMPTY file: Gradle reads "" (no Maps key)
        self.assertNotIn('TEST_MAPS_API_KEY', seen['defines'])
        self.assert_clean(seen)  # the empty file is removed too

    def test_cleanup_after_failure(self):
        seen, error, log = self.run_build(exit_code=1)
        self.assertIsNotNone(error)
        self.assert_clean(seen)
        self.assertNotIn(TEST_KEY, log); self.assertNotIn(PROD_KEY, log); self.assertNotIn(TEST_KEY, str(error))

    def test_secrets_absent_from_all_build_output(self):
        for kwargs in ({}, {'exit_code': 1}):
            _, error, log = self.run_build(**kwargs)
            self.assertNotIn(TEST_KEY, log + str(error)); self.assertNotIn(PROD_KEY, log + str(error))

    def test_restore_of_maps_key_is_still_verified(self):
        real_copy = bp.atomic_copy
        calls = []

        def corrupt_restore(source, destination):
            calls.append(source)
            if len(calls) == 2:
                Path(destination).write_text('corrupted')
            else:
                real_copy(source, destination)

        with mock.patch.object(bp, 'atomic_copy', corrupt_restore):
            _, _, log = self.run_build()
        self.assertIn('restore not verified', log)
        self.assertEqual((self.recovery / 'maps_key.dart.original').read_text(), PROD_MAPS)
        self.assertTrue((self.recovery / 'state.json').exists())
        self.assertNotIn(TEST_KEY, log); self.assertNotIn(PROD_KEY, log)


class ApkScanTest(unittest.TestCase):
    def test_python_scan_finds_key_in_utf8_and_utf16_and_refuses_empty(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(bp.PreprodError, 'could not be analysed'):
                bp.scan_for_key(folder, PROD_KEY)
            (Path(folder) / 'a.bin').write_bytes(b'\x00junk' + TEST_KEY.encode())
            bp.scan_for_key(folder, PROD_KEY)  # only the test key present: accepted
            (Path(folder) / 'b.bin').write_bytes(PROD_KEY.encode('utf-16-le'))
            with self.assertRaisesRegex(bp.PreprodError, 'present in the APK') as context:
                bp.scan_for_key(folder, PROD_KEY)
            self.assertNotIn(PROD_KEY, str(context.exception))
            (Path(folder) / 'b.bin').write_bytes(b'pre' + PROD_KEY.encode() + b'post')
            with self.assertRaises(bp.PreprodError):
                bp.scan_for_key(folder, PROD_KEY)

    def test_audit_apk_refuses_an_apk_containing_the_production_key(self):
        import zipfile
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / 'a.apk'
            with zipfile.ZipFile(apk, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('assets/x.bin', b'..' + PROD_KEY.encode() + b'..')
            done = subprocess.CompletedProcess([], 0, stdout=f"package: name='{bp.PACKAGE}'", stderr='')
            with mock.patch.object(bp.subprocess, 'run', return_value=done), mock.patch.object(bp, 'run') as node:
                with self.assertRaisesRegex(bp.PreprodError, 'present in the APK'):
                    bp.audit_apk(apk, Path('gs.json'), Path('backup.dart'), 'aapt2', PROD_KEY)
            node.assert_not_called()


@unittest.skipUnless(NODE, 'Node.js not installed')
class NodeCheckTest(unittest.TestCase):
    """The real check-no-prod-maps-key.js on fake files: fail closed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.target = self.dir / 'apk'
        self.target.mkdir()
        (self.target / 'clean.bin').write_bytes(b'nothing')

    def reference(self, text):
        path = self.dir / 'maps_key.dart'
        path.write_text(text, encoding='utf-8')
        return path

    def run_node(self, reference, *targets):
        result = subprocess.run([NODE, str(NODE_SCRIPT), str(reference), *map(str, targets or [self.target])],
                                capture_output=True, text=True, timeout=60)
        self.assertNotIn(PROD_KEY, result.stdout + result.stderr)
        self.assertNotIn('AIza', result.stdout + result.stderr)
        return result

    def test_clean_artifact_accepted(self):
        result = self.run_node(self.reference(PROD_MAPS))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_key_present_refused_in_utf8_and_utf16(self):
        reference = self.reference(PROD_MAPS)
        (self.target / 'leak.bin').write_bytes(b'x' + PROD_KEY.encode() + b'y')
        self.assertEqual(self.run_node(reference).returncode, 1)
        (self.target / 'leak.bin').write_bytes(PROD_KEY.encode('utf-16-le'))
        self.assertEqual(self.run_node(reference).returncode, 1)

    def test_reference_without_key_refused_not_skipped(self):
        result = self.run_node(self.reference("const String kMapsApiKey = '';\n"))
        self.assertEqual(result.returncode, 1); self.assertIn('REFUS', result.stderr)

    def test_ambiguous_references_refused(self):
        for text in (f"a='{PROD_KEY}'; b='AIza{'Q' * 35}';", f"a='{PROD_KEY}Z';", "a='AIzaSHORTSHORTSHORTSHORT';"):
            self.assertEqual(self.run_node(self.reference(text)).returncode, 1, text)

    def test_unreadable_reference_and_empty_targets_refused(self):
        self.assertEqual(self.run_node(self.dir / 'absent.dart').returncode, 1)
        empty = self.dir / 'empty'
        empty.mkdir()
        self.assertEqual(self.run_node(self.reference(PROD_MAPS), empty).returncode, 1)
        self.assertEqual(self.run_node(self.reference(PROD_MAPS), self.dir / 'absent').returncode, 1)


class GradleStaticTest(unittest.TestCase):
    """Static checks of the shared Gradle file (it cannot be compiled without a build)."""

    path = REPO / 'android/app/build.gradle.kts'

    def test_key_file_branch_is_test_only_and_production_branch_unchanged(self):
        raw = self.path.read_bytes()
        text = raw.decode('utf-8')
        self.assertEqual(raw.count(b'\r'), raw.count(b'\n'))  # CRLF kept on every line
        start = text.index('manifestPlaceholders["MAPS_API_KEY"]')
        block = text[start:text.index('}\r\n', text.index('else localProperties') - 5)]
        self.assertIn('hasProperty("azTestSuffix")', block)
        self.assertIn('azTestMapsKeyFile', block)
        self.assertIn('azTestMapsKey")', block)  # historical scripts still work
        self.assertIn('else localProperties.getProperty("MAPS_API_KEY", "")', block)
        self.assertLess(block.index('azTestMapsKeyFile'), block.index('else localProperties'))
        self.assertEqual(text.count('{'), text.count('}'))
        self.assertEqual(text.count('('), text.count(')'))
        self.assertNotIn('AIza', text)

    def test_no_key_written_in_wrapper_or_engine(self):
        for path in (REPO / 'scripts/build_preprod.py', REPO / 'test-env/build-test-apk.ps1',
                     REPO / 'test-env/check-no-prod-maps-key.js'):
            self.assertNotRegex(path.read_text(encoding='utf-8-sig'), r'AIza[0-9A-Za-z_-]{20,}')

    def test_wrapper_exposes_maps_disabled_explicitly(self):
        text = (REPO / 'test-env/build-test-apk.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('[switch]$MapsDisabled', text)
        self.assertIn("'--maps-disabled'", text)


if __name__ == '__main__':
    unittest.main()
