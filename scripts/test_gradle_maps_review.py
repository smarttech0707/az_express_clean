"""M2.10: review tests for the Maps-key change in android/app/build.gradle.kts. No Gradle, no build, fake keys only.

The Kotlin cannot be executed here, so two things are checked instead:
  * the Kotlin text itself (exactly which lines differ from HEAD, and that the production branch is untouched);
  * a decision-table MODEL of the placeholder expression, compared before/after, plus the arguments the Python
    engine really generates.
"""
import contextlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_preprod as bp  # noqa: E402
from test_build_preprod import PROD_KEY, TEST_KEY, Base, good_defines  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
GRADLE = REPO / 'android/app/build.gradle.kts'
CRLF, LF = bytes([13, 10]), bytes([10])
START = b'        // Build de test : JAMAIS la cl'


def head_version():
    # Git stores LF (core.autocrlf=true); the working copy is CRLF. Compare both as CRLF.
    result = subprocess.run(['git', 'show', 'HEAD:android/app/build.gradle.kts'], cwd=REPO, capture_output=True)
    return result.stdout.replace(CRLF, LF).replace(LF, CRLF) if result.returncode == 0 else None


def split_block(raw):
    """(before, block, after) around the manifestPlaceholders statement (comment lines included)."""
    start = raw.index(START)
    end_marker = b'localProperties.getProperty("MAPS_API_KEY", "")\r\n'
    end = raw.index(end_marker, start) + len(end_marker)
    return raw[:start], raw[start:end], raw[end:]


# --- Decision-table models of the Kotlin expression (hand transliteration, checked against the text below) ---
def old_value(props, local):
    if 'azTestSuffix' in props:
        return props.get('azTestMapsKey', '')
    return local.get('MAPS_API_KEY', '')


def read_text_trim(files, path):
    if path not in files:
        raise FileNotFoundError(path)  # Kotlin File.readText() on a missing file
    return files[path].strip()  # Kotlin String.trim(): whitespace only (a BOM would stay)


def new_value(props, local, files):
    if 'azTestSuffix' in props:
        key_file = props.get('azTestMapsKeyFile')
        if key_file is not None:
            return read_text_trim(files, key_file)
        return props.get('azTestMapsKey', '')
    return local.get('MAPS_API_KEY', '')


class KotlinTextReviewTest(unittest.TestCase):
    def setUp(self):
        self.new = GRADLE.read_bytes()
        self.old = head_version()
        if self.old is None:
            self.skipTest('git show HEAD unavailable')

    def test_everything_outside_the_placeholder_statement_is_byte_identical_to_head(self):
        old_before, _, old_after = split_block(self.old)
        new_before, _, new_after = split_block(self.new)
        self.assertEqual(new_before, old_before)  # applicationId, signing, minSdk, versionCode... untouched
        self.assertEqual(new_after, old_after)    # buildTypes, release signing, sourceSets... untouched

    def test_only_the_expected_lines_changed(self):
        _, old_block, _ = split_block(self.old)
        _, new_block, _ = split_block(self.new)
        removed = [l for l in old_block.split(b'\r\n') if l not in new_block.split(b'\r\n')]
        self.assertEqual([l.strip() for l in removed if l.strip()], [
            b'// explicitement fournie par -PazTestMapsKey).',
            b'if (project.hasProperty("azTestSuffix")) (project.findProperty("azTestMapsKey") as String? ?: "")',
            # Same production call; only the closing brace of the new test block now precedes it.
            b'else localProperties.getProperty("MAPS_API_KEY", "")',
        ])
        # The production expression and the condition literally survive.
        self.assertIn(b'else localProperties.getProperty("MAPS_API_KEY", "")', new_block)
        self.assertIn(b'hasProperty("azTestSuffix")', new_block)

    def test_line_endings_and_encoding_unchanged(self):
        self.assertEqual(self.new.count(b'\r'), self.new.count(b'\n'))
        self.assertEqual(self.old.count(b'\r'), self.old.count(b'\n'))
        self.assertFalse(self.new.startswith(b'\xef\xbb\xbf'))
        self.new.decode('utf-8')

    def test_model_matches_the_kotlin_text_token_order(self):
        _, block, _ = split_block(self.new)
        text = block.decode('utf-8')
        tokens = ['manifestPlaceholders["MAPS_API_KEY"] =', 'if (project.hasProperty("azTestSuffix")) {',
                  'val testMapsKeyFile = project.findProperty("azTestMapsKeyFile") as String?',
                  'if (testMapsKeyFile != null) project.file(testMapsKeyFile).readText().trim()',
                  'else (project.findProperty("azTestMapsKey") as String? ?: "")',
                  '} else localProperties.getProperty("MAPS_API_KEY", "")']
        positions = [text.index(t) for t in tokens]
        self.assertEqual(positions, sorted(positions))
        # Delimiters balance inside the statement and a value is produced on every path.
        for open_, close in ('{}', '()'):
            self.assertEqual(text.count(open_), text.count(close))

    def test_test_only_property_is_read_only_inside_the_test_branch(self):
        text = self.new.decode('utf-8')
        first_use = text.index('azTestMapsKeyFile")')
        self.assertGreater(first_use, text.index('hasProperty("azTestSuffix")) {'))
        self.assertLess(first_use, text.index('} else localProperties'))
        self.assertEqual(text.count('azTestMapsKeyFile")'), 1)


class ProductionBeforeAfterModelTest(unittest.TestCase):
    LOCALS = ({}, {'MAPS_API_KEY': 'LOCAL-PROD-KEY'})
    FILES = {'F': ' \ufeffNOT-TRIMMED\n', 'G': ' TEST-KEY \r\n', 'EMPTY': '  \n'}

    def combos(self):
        for suffix in (False, True):
            for key_file in (None, 'G'):
                for legacy in (None, 'LEGACY'):
                    for local in self.LOCALS:
                        props = {}
                        if suffix:
                            props['azTestSuffix'] = '.test'
                        if key_file:
                            props['azTestMapsKeyFile'] = key_file
                        if legacy is not None:
                            props['azTestMapsKey'] = legacy
                        yield props, local

    def test_production_value_identical_before_and_after_for_every_combination(self):
        checked = 0
        for props, local in self.combos():
            if 'azTestSuffix' not in props:
                self.assertEqual(new_value(props, local, self.FILES), old_value(props, local), props)
                checked += 1
        self.assertEqual(checked, 8)

    def test_production_never_uses_test_properties_even_if_set(self):
        for props, local in self.combos():
            if 'azTestSuffix' not in props:
                self.assertEqual(new_value(props, local, self.FILES), local.get('MAPS_API_KEY', ''))

    def test_test_mode_without_file_property_unchanged(self):
        for props, local in self.combos():
            if 'azTestSuffix' in props and 'azTestMapsKeyFile' not in props:
                self.assertEqual(new_value(props, local, self.FILES), old_value(props, local))

    def test_test_mode_never_falls_back_to_the_local_production_key(self):
        for props, local in self.combos():
            if 'azTestSuffix' in props:
                self.assertNotEqual(new_value(props, local, self.FILES), 'LOCAL-PROD-KEY')

    def test_file_property_semantics(self):
        props = {'azTestSuffix': '.test', 'azTestMapsKeyFile': 'G'}
        self.assertEqual(new_value(props, {}, self.FILES), 'TEST-KEY')  # trimmed; file wins over the legacy property
        self.assertEqual(new_value({**props, 'azTestMapsKey': 'LEGACY'}, {}, self.FILES), 'TEST-KEY')
        self.assertEqual(new_value({**props, 'azTestMapsKeyFile': 'EMPTY'}, {}, self.FILES), '')  # blank: maps silently off
        with self.assertRaises(FileNotFoundError):  # absent file: configuration fails, no silent fallback
            new_value({**props, 'azTestMapsKeyFile': 'MISSING'}, {}, self.FILES)
        self.assertTrue(new_value({**props, 'azTestMapsKeyFile': 'F'}, {}, self.FILES).startswith('\ufeff'))

    def test_command_line_property_overrides_an_ambient_one(self):
        # Gradle gives -P precedence over gradle.properties / environment: the empty legacy property
        # passed by the engine keeps --maps-disabled at '' even if an old value exists elsewhere.
        self.assertEqual(new_value({'azTestSuffix': '.test', 'azTestMapsKey': ''}, {}, {}), '')


class GeneratedArgumentsTest(Base):
    def build_command(self, defines, maps_disabled):
        _, gs = self.files(defines)
        seen = {}

        def fake_call(command, **kwargs):
            seen['command'] = list(command)
            seen['native'] = self.native.is_file()
            for arg in command:
                if arg.startswith('--android-project-arg=azTestMapsKeyFile='):
                    seen['file_text'] = Path(arg.split('=', 2)[2]).read_bytes()
            define_arg = [a for a in command if a.startswith('--dart-define-from-file=')][0]
            seen['defines'] = json.loads(Path(define_arg.split('=', 1)[1]).read_text())
            apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(b'x')
            return 0

        out = io.StringIO()
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', side_effect=fake_call), mock.patch.object(bp, 'audit_apk'), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            bp.build(defines, gs, 11, node_checks=False, maps_disabled=maps_disabled)
        return seen, out.getvalue()

    def test_key_file_argument_shape_and_content(self):
        seen, log = self.build_command(good_defines(), maps_disabled=False)
        args = [a for a in seen['command'] if a.startswith('--android-project-arg=')]
        names = sorted(a.split('=', 2)[1] for a in args)
        self.assertEqual(names, ['azTestMapsKey', 'azTestMapsKeyFile', 'azTestSuffix'])
        file_arg = [a for a in args if 'azTestMapsKeyFile' in a][0]
        self.assertNotIn(TEST_KEY, file_arg)
        self.assertEqual(seen['file_text'], TEST_KEY.encode('utf-8'))  # exact bytes, no BOM, no newline
        self.assertFalse(seen['file_text'].startswith(b'\xef\xbb\xbf'))
        self.assertNotIn(TEST_KEY, log); self.assertNotIn(PROD_KEY, log)

    def test_windows_style_paths_split_at_the_first_equals_only(self):
        for path in (r'C:\Users\Jean Dupont\AppData\Local\Temp\az-preprod-x\maps_test_key.txt',
                     r'C:\Users\a=b\Temp\k.txt', r'\\server\share\k.txt'):
            arg = f'--android-project-arg=azTestMapsKeyFile={path}'
            option, name, value = arg.split('=', 2)
            self.assertEqual((name, value), ('azTestMapsKeyFile', path))

    def test_maps_disabled_chain_passes_no_key_and_keeps_every_other_guard(self):
        d = good_defines(); del d['TEST_MAPS_API_KEY']
        seen, log = self.build_command(d, maps_disabled=True)
        command = seen['command']
        self.assertEqual(sorted(a.split('=', 2)[1] for a in command if 'MapsKey' in a),
                         ['azTestMapsKey', 'azTestMapsKeyFile'])
        self.assertEqual(seen['file_text'], b'')  # M2.12: empty key file, overrides any ambient azTestMapsKeyFile
        self.assertNotIn('TEST_MAPS_API_KEY', seen['defines'])
        self.assertIn('--android-project-arg=azTestSuffix=.test', command)
        self.assertEqual(command[1:4], ['build', 'apk', '--debug'])
        self.assertEqual(seen['defines']['AZ_REQUIRED_FIREBASE_PROJECT'], bp.PROJECT_ID)
        self.assertIs(seen['defines']['DISABLE_FCM'], True)
        self.assertNotIn(PROD_KEY, ' '.join(command) + log)

    def test_maps_disabled_does_not_relax_firebase_separation(self):
        d = good_defines(); del d['TEST_MAPS_API_KEY']
        for change in ({'FIREBASE_PROJECT_ID': 'az-express-b0469'}, {'FIREBASE_MESSAGING_SENDER_ID': '123'},
                       {'DISABLE_FCM': False}, {'AZ_REQUIRED_FIREBASE_PROJECT': 'other'}):
            config, gs = self.files({**d, **change})
            code, _, err = self.check(config, gs, '--maps-disabled')
            self.assertEqual(code, 2, change)
        n_bad = {'project_info': {'project_id': 'az-express-b0469', 'project_number': bp.PROJECT_NUMBER}, 'client': []}
        config, gs = self.files(d, n_bad)
        self.assertEqual(self.check(config, gs, '--maps-disabled')[0], 2)
        config, gs = self.files(d)
        self.assertEqual(self.check(config, gs, '--maps-disabled')[0], 0)
        self.assertFalse(self.isolation.call_args.kwargs['maps_swapped'])  # Node guard still runs

    def test_maps_disabled_build_still_runs_the_isolation_guard_with_the_swapped_maps_file(self):
        d = good_defines(); del d['TEST_MAPS_API_KEY']
        self.build_command(d, maps_disabled=True)
        # node_checks=False above skips it; run once with checks to prove the call is made for this mode.
        _, gs = self.files(d)
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', return_value=0) as call, mock.patch.object(bp, 'audit_apk'):
            apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(b'x')
            bp.build(d, gs, 11, node_checks=True, maps_disabled=True)
        self.assertTrue(self.isolation.call_args.kwargs['maps_swapped'])
        self.assertEqual(call.call_count, 1)

    def test_key_file_failure_modes_never_print_the_key(self):
        # Engine-side refusals for invalid/missing keys, with fake keys: nothing sensitive in any output.
        for value in ('AIza-short', PROD_KEY, 'AIza' + 'Z' * 36):
            d = good_defines(); d['TEST_MAPS_API_KEY'] = value
            config, gs = self.files(d)
            code, out, err = self.check(config, gs)
            self.assertEqual(code, 2)
            self.assertNotIn(PROD_KEY, out + err); self.assertNotIn('ZZZZ', out + err)


class WrapperPathTest(unittest.TestCase):
    def test_wrapper_maps_switch_and_no_key_parameter(self):
        text = (REPO / 'test-env/build-test-apk.ps1').read_text(encoding='utf-8-sig')
        self.assertIn("if ($MapsDisabled) { $engineArgs += '--maps-disabled' }", text)
        code = ' '.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
        for forbidden in ('MapsKey', 'AIza', 'TEST_MAPS_API_KEY', 'local.properties'):
            self.assertNotIn(forbidden, code, forbidden)


if __name__ == '__main__':
    unittest.main()
