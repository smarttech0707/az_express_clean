"""Offline tests for build_preprod.py: fake configuration only, no Firebase, no real build."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_preprod as bp  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
NUM = bp.PROJECT_NUMBER
APP_ID = f'1:{NUM}:android:fakefakefake'
KEY = 'FAKE-API-KEY'
PROD_KEY = 'AIza' + 'P' * 35  # fake, same shape as a Google API key
TEST_KEY = 'AIza' + 'T' * 35
PROD_MAPS = f"const String kMapsApiKey = '{PROD_KEY}';\n"
REAL_GIT_PORCELAIN = bp.git_porcelain  # captured before Base replaces it with a fake


def good_defines():
    return {
        'FIREBASE_PROJECT_ID': bp.PROJECT_ID, 'FIREBASE_ANDROID_APP_ID': APP_ID,
        'FIREBASE_ANDROID_API_KEY': KEY, 'FIREBASE_MESSAGING_SENDER_ID': NUM,
        'FIREBASE_STORAGE_BUCKET': f'{bp.PROJECT_ID}.firebasestorage.app',
        'AZ_REQUIRED_FIREBASE_PROJECT': bp.PROJECT_ID, 'DISABLE_FCM': True,
        'DELIVERY_PROOFS_UI': True, 'TEST_MAPS_API_KEY': TEST_KEY,
    }


def good_native():
    return {
        'project_info': {'project_id': bp.PROJECT_ID, 'project_number': NUM,
                         'storage_bucket': f'{bp.PROJECT_ID}.firebasestorage.app'},
        'client': [{'client_info': {'mobilesdk_app_id': APP_ID,
                                    'android_client_info': {'package_name': bp.PACKAGE}},
                    'api_key': [{'current_key': KEY}]}],
    }


def system_scratch_folders():
    """Names of the az-preprod-* scratch folders currently in the system temp folder (read-only)."""
    return {p.name for p in Path(tempfile.gettempdir()).glob('az-preprod-*') if p.is_dir()}


class Base(unittest.TestCase):
    """Temporary repository root; Git, tool probing and Node guards are replaced by fakes."""

    def setUp(self):
        self.system_scratch_before = system_scratch_folders()
        self.addCleanup(self.assert_no_scratch_left)  # registered first, so it runs after tmp.cleanup
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        (self.root / 'lib/constants').mkdir(parents=True)
        (self.root / 'test-env/lib').mkdir(parents=True)
        shutil.copyfile(REPO / 'test-env/lib/guards.js', self.root / 'test-env/lib/guards.js')
        (self.root / 'pubspec.yaml').write_text('version: 1.0.10+11\n')
        self.maps = self.root / 'lib/constants/maps_key.dart'
        self.maps.write_text(PROD_MAPS)
        (self.root / 'lib/constants/maps_key_test.dart').write_text('const test = "";\n')
        (self.root / '.env').write_text('{}')
        self.work = Path(self.tmp.name) / 'cfg'
        self.work.mkdir()
        self.native = self.root / 'android/app/src/debug/google-services.json'
        self.recovery = self.root / 'build/az-preprod-recovery'
        self.git = mock.Mock(return_value='')
        self.tools = mock.Mock(return_value='/fake/aapt2')
        self.isolation = mock.Mock()
        for patch in (mock.patch.object(bp, 'ROOT', self.root),
                      mock.patch.object(bp, 'git_porcelain', self.git),
                      mock.patch.object(bp, 'check_tools', self.tools),
                      mock.patch.object(bp, 'run_isolation', self.isolation)):
            patch.start()
            self.addCleanup(patch.stop)

    def assert_no_scratch_left(self):
        """Every temporary folder this test made is gone: own tree removed, nothing new in the system temp."""
        self.assertFalse(Path(self.tmp.name).exists(), 'test temporary folder not removed')
        leaked = system_scratch_folders() - self.system_scratch_before
        self.assertEqual(leaked, set(), 'az-preprod-* scratch folders left in the system temp folder')

    def killed_child_env(self):
        """Environment for a child that is killed with os._exit (its `finally` never runs): its temp folder is
        inside this test's own tree, so the scratch folder it abandons is removed with the test, never in the
        shared system temp folder."""
        child_temp = Path(self.tmp.name) / 'child-temp'
        child_temp.mkdir(exist_ok=True)
        return {**os.environ, 'TEMP': str(child_temp), 'TMP': str(child_temp), 'TMPDIR': str(child_temp)}

    def files(self, defines=None, native=None):
        config, gs = self.work / 'defines.json', self.work / 'google-services.json'
        config.write_text(json.dumps(good_defines() if defines is None else defines))
        gs.write_text(json.dumps(good_native() if native is None else native))
        return config, gs

    def check(self, config, gs, *extra, target='apk'):
        out, err = io.StringIO(), io.StringIO()
        code = None
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = bp.main([target, '--config', str(config), '--google-services', str(gs), '--check-only', *extra])
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue(), err.getvalue()

    def refused(self, defines=None, native=None, expect=None):
        config, gs = self.files(defines, native)
        code, out, err = self.check(config, gs)
        self.assertEqual(code, 2, out + err)
        self.assertNotIn(KEY, out + err)
        self.assertNotIn(NUM, out + err)
        if expect:
            self.assertIn(expect, err)


class ValidationTest(Base):
    def test_01_correct_preprod_config_accepted(self):
        config, gs = self.files()
        code, out, err = self.check(config, gs)
        self.assertEqual(code, 0, err)
        self.assertIn('APP_BUILD_NUMBER=11', out)
        self.assertNotIn(KEY, out)

    def test_02_production_project_refused(self):
        d = good_defines(); d['FIREBASE_PROJECT_ID'] = 'az-express-b0469'
        self.refused(d, expect='production')
        n = good_native(); n['project_info']['project_id'] = 'az-express-b0469'
        self.refused(native=n, expect='production')
        d = good_defines(); d['FIREBASE_STORAGE_BUCKET'] = 'az-express-b0469.firebasestorage.app'
        self.refused(d)
        d = good_defines(); d['FIREBASE_PROJECT_ID'] = 'az-express-clean'
        self.refused(d)

    def test_03_wrong_project_number_refused(self):
        d = good_defines(); d['FIREBASE_MESSAGING_SENDER_ID'] = '123456789012'
        self.refused(d, expect='project number')
        d = good_defines(); d['FIREBASE_MESSAGING_SENDER_ID'] = '697217052961'
        self.refused(d)

    def test_04_project_id_missing_refused(self):
        d = good_defines(); del d['FIREBASE_PROJECT_ID']
        self.refused(d, expect='FIREBASE_PROJECT_ID')
        n = good_native(); del n['project_info']['project_id']
        self.refused(native=n, expect='project_id')
        n = good_native(); del n['project_info']
        self.refused(native=n)

    def test_05_inconsistent_project_number_refused(self):
        n = good_native(); n['project_info']['project_number'] = '123456789012'
        self.refused(native=n, expect='project_number')
        n = good_native(); del n['project_info']['project_number']
        self.refused(native=n)

    def test_06_wrong_package_refused(self):
        n = good_native(); n['client'][0]['client_info']['android_client_info']['package_name'] = 'com.azexpress.app'
        self.refused(native=n, expect=bp.PACKAGE)
        n = good_native(); n['client'].append(n['client'][0])
        self.refused(native=n, expect='exactly one')

    def test_07_invalid_build_number_refused(self):
        for text in ('version: 1.0.10\n', 'version: 1.0.10+0\n', 'version: 1.0.10+abc\n',
                     'version: 1.0.10+2100000001\n', 'version: 1.0.10+-5\n'):
            (self.root / 'pubspec.yaml').write_text(text)
            config, gs = self.files()
            self.assertEqual(self.check(config, gs)[0], 2, text)
        d = good_defines(); d['APP_BUILD_NUMBER'] = '9'
        self.refused(d)

    def test_08_missing_files_refused(self):
        config, gs = self.files()
        self.assertEqual(self.check(self.work / 'absent.json', gs)[0], 2)
        self.assertEqual(self.check(config, self.work / 'absent.json')[0], 2)
        self.assertEqual(self.check(config, config)[0], 2)

    def test_09_real_env_and_production_native_file_refused(self):
        _, gs = self.files()
        code, _, err = self.check(self.root / '.env', gs)
        self.assertEqual(code, 2); self.assertIn('.env', err)
        copy = self.work / '.env'
        copy.write_text(json.dumps(good_defines()))
        self.assertEqual(self.check(copy, gs)[0], 2)
        config, _ = self.files()
        prod_native = self.root / 'android/app/google-services.json'
        prod_native.parent.mkdir(parents=True)
        prod_native.write_text(json.dumps(good_native()))
        self.assertEqual(self.check(config, prod_native)[0], 2)

    def test_10_release_aab_ipa_web_refused(self):
        config, gs = self.files()
        for target in ('appbundle', 'ipa', 'web', 'release'):
            code, _, err = self.check(config, gs, target=target)
            self.assertEqual(code, 2); self.assertIn('debug APK', err)
        code, _, err = self.check(config, gs, '--release')
        self.assertEqual(code, 2); self.assertIn('debug APK', err)

    def test_11_fcm_not_disabled_refused(self):
        for value in (False, 'false', 0, None):
            d = good_defines(); d['DISABLE_FCM'] = value
            self.refused(d, expect='DISABLE_FCM')

    def test_12_dart_native_inconsistency_refused(self):
        d = good_defines(); d['FIREBASE_ANDROID_APP_ID'] = f'1:{NUM}:android:other'
        self.refused(d, expect='app IDs')
        d = good_defines(); d['FIREBASE_ANDROID_API_KEY'] = 'OTHER-KEY'
        self.refused(d, expect='API keys')
        d = good_defines(); d['AZ_REQUIRED_FIREBASE_PROJECT'] = 'other'
        self.refused(d, expect='AZ_REQUIRED')
        d = good_defines(); d['SOMETHING_ELSE'] = '1'
        self.refused(d, expect='unexpected key')

    def test_13_check_only_builds_nothing(self):
        config, gs = self.files()
        with mock.patch.object(bp.subprocess, 'call') as call, mock.patch.object(bp.shutil, 'which') as which:
            code, _, err = self.check(config, gs)
        self.assertEqual(code, 0, err)
        call.assert_not_called(); which.assert_not_called()
        # M2.8 (F5): check-only now also proves the tools and runs the Node isolation guard (maps not swapped).
        self.tools.assert_called_once()
        self.assertFalse(self.isolation.call_args.kwargs['maps_swapped'])

    def test_14_check_only_fails_when_a_tool_is_missing(self):
        self.tools.side_effect = bp.PreprodError('Refused: aapt2 not found')
        config, gs = self.files()
        code, _, err = self.check(config, gs)
        self.assertEqual(code, 2); self.assertIn('aapt2', err)

    def test_15_check_only_fails_when_node_guard_fails(self):
        self.isolation.side_effect = bp.PreprodError('A build step failed')
        config, gs = self.files()
        self.assertEqual(self.check(config, gs)[0], 2)


class ProductionMarkersTest(Base):
    def test_markers_come_from_guards_js_and_include_floor(self):
        markers = bp.production_markers()
        self.assertTrue(set(bp.FORBIDDEN) <= markers)
        self.assertIn('c645fe608310b5f6ea4e60', markers)  # app ID fragment only guards.js knows

    def test_app_id_fragment_of_production_refused(self):
        n = good_native(); n['client'][0]['client_info']['mobilesdk_app_id'] = '1:1:android:c645fe608310b5f6ea4e60'
        d = good_defines(); d['FIREBASE_ANDROID_APP_ID'] = '1:1:android:c645fe608310b5f6ea4e60'
        self.refused(d, n, expect='production')

    def test_fails_closed_without_guards_js(self):
        (self.root / 'test-env/lib/guards.js').write_text('module.exports = {};')
        self.refused(expect='guards.js')
        (self.root / 'test-env/lib/guards.js').unlink()
        self.refused(expect='guards.js')

    def test_real_guards_js_still_parses(self):
        with mock.patch.object(bp, 'ROOT', REPO):
            self.assertTrue(set(bp.FORBIDDEN) <= bp.production_markers())


class Aapt2Test(unittest.TestCase):
    """A: aapt2 must be usable before Gradle runs; no warning-only path."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdk = Path(self.tmp.name) / 'sdk'
        self.env = {'ANDROID_HOME': str(self.sdk)}

    def tool(self, version, name='aapt2.exe'):
        path = self.sdk / 'build-tools' / version / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'x')
        path.chmod(0o755)
        return path

    def done(self, code=0, out='Android Asset Packaging Tool'):
        return subprocess.CompletedProcess([], code, stdout=out, stderr='')

    def test_present_newest_version_wins(self):
        self.tool('9.0.0'); newest = self.tool('34.0.0'); self.tool('33.0.1')
        self.assertEqual(Path(bp.find_aapt2(self.env)), newest)
        with mock.patch.object(bp.subprocess, 'run', return_value=self.done()):
            self.assertEqual(Path(bp.check_tools(self.env)), newest)

    def test_absent_is_refused(self):
        self.assertIsNone(bp.find_aapt2(self.env))
        with self.assertRaisesRegex(bp.PreprodError, 'aapt2 not found'):
            bp.check_tools(self.env)
        (self.sdk / 'build-tools').mkdir(parents=True)
        with self.assertRaisesRegex(bp.PreprodError, 'aapt2 not found'):
            bp.check_tools(self.env)

    def test_invalid_path_is_refused(self):
        (self.sdk / 'build-tools/35.0.0/aapt2.exe').mkdir(parents=True)  # a directory, not a tool
        with self.assertRaisesRegex(bp.PreprodError, 'not an executable file'):
            bp.check_tools(self.env)

    def test_execution_impossible_is_refused(self):
        self.tool('35.0.0')
        for error in (OSError('cannot run'), subprocess.TimeoutExpired('aapt2', 1)):
            with mock.patch.object(bp.subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(bp.PreprodError, 'could not be executed'):
                    bp.check_tools(self.env)

    def test_tool_that_runs_badly_is_refused(self):
        self.tool('35.0.0')
        for result in (self.done(code=1), self.done(out='')):
            with mock.patch.object(bp.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(bp.PreprodError, 'did not run correctly'):
                    bp.check_tools(self.env)

    def test_node_missing_is_refused_with_a_clear_message(self):
        self.tool('35.0.0')
        def fake(command, **kwargs):
            if command[0] == 'node':
                raise FileNotFoundError('node')
            return self.done()
        with mock.patch.object(bp.subprocess, 'run', side_effect=fake):
            with self.assertRaisesRegex(bp.PreprodError, 'Node.js could not be executed'):
                bp.check_tools(self.env)

    def test_run_wraps_missing_executable(self):
        with mock.patch.object(bp.subprocess, 'call', side_effect=FileNotFoundError('node')):
            with self.assertRaisesRegex(bp.PreprodError, 'could not be executed'):
                bp.run(['node', 'x'])

    def test_build_is_blocked_before_any_change_when_aapt2_is_missing(self):
        root = Path(self.tmp.name) / 'repo'
        (root / 'lib/constants').mkdir(parents=True)
        maps = root / 'lib/constants/maps_key.dart'
        maps.write_text(PROD_MAPS)
        (root / 'lib/constants/maps_key_test.dart').write_text('x')
        with mock.patch.object(bp, 'ROOT', root), mock.patch.object(bp, 'find_aapt2', return_value=None), \
                mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call') as call:
            with self.assertRaisesRegex(bp.PreprodError, 'aapt2 not found'):
                bp.build(good_defines(), root / 'gs.json', 11)
        call.assert_not_called()
        self.assertEqual(maps.read_text(), PROD_MAPS)
        self.assertFalse((root / 'build').exists())
        self.assertFalse((root / 'android').exists())

    def apk(self):
        path = Path(self.tmp.name) / 'app-debug.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('AndroidManifest.xml', 'x')
        return path

    def test_package_verification_errors_are_blocking(self):
        apk = self.apk()
        gs, backup = Path(self.tmp.name) / 'gs.json', Path(self.tmp.name) / 'backup.dart'
        for effect in (OSError('x'), subprocess.TimeoutExpired('aapt2', 1)):
            with mock.patch.object(bp.subprocess, 'run', side_effect=effect):
                with self.assertRaisesRegex(bp.PreprodError, 'failed to run'):
                    bp.audit_apk(apk, gs, backup, 'aapt2', PROD_KEY, TEST_KEY)
        with mock.patch.object(bp.subprocess, 'run', return_value=self.done(code=1)):
            with self.assertRaisesRegex(bp.PreprodError, 'returned an error'):
                bp.audit_apk(apk, gs, backup, 'aapt2', PROD_KEY, TEST_KEY)
        with mock.patch.object(bp.subprocess, 'run', return_value=self.done(out="package: name='com.azexpress.app'")):
            with self.assertRaisesRegex(bp.PreprodError, 'package is not'):
                bp.audit_apk(apk, gs, backup, 'aapt2', PROD_KEY, TEST_KEY)
        with mock.patch.object(bp.subprocess, 'run', return_value=self.done(out='')):
            with self.assertRaisesRegex(bp.PreprodError, 'package is not'):
                bp.audit_apk(apk, gs, backup, 'aapt2', PROD_KEY, TEST_KEY)

    def test_correct_package_then_runs_the_node_audits(self):
        apk = self.apk()
        with mock.patch.object(bp.subprocess, 'run', return_value=self.done(out=f"package: name='{bp.PACKAGE}' versionCode='11'")), \
                mock.patch.object(bp, 'run') as run:
            bp.audit_apk(apk, Path('gs.json'), Path('backup.dart'), 'aapt2', PROD_KEY, TEST_KEY)
        self.assertEqual(run.call_count, 2)
        audit_command = run.call_args_list[1].args[0]
        self.assertEqual(audit_command[0:2], ['node', 'test-env/audit-apk-content.js'])

    def test_correct_package_passes_the_test_maps_key_through_a_file_not_argv(self):
        apk = self.apk()
        seen = {}

        def fake_run(command, **kwargs):
            if command[1] == 'test-env/audit-apk-content.js':
                seen['command'] = command
                # Read now: the key file lives in a TemporaryDirectory that is removed as soon as
                # audit_apk's `with` block exits, right after this call.
                seen['key_contents'] = Path(command[4]).read_text(encoding='utf-8')

        with mock.patch.object(bp.subprocess, 'run', return_value=self.done(out=f"package: name='{bp.PACKAGE}' versionCode='11'")), \
                mock.patch.object(bp, 'run', side_effect=fake_run):
            bp.audit_apk(apk, Path('gs.json'), Path('backup.dart'), 'aapt2', PROD_KEY, TEST_KEY)
        audit_command = seen['command']
        # 4 arguments: node, script, extracted-folder, google-services ; the key file is the 5th.
        self.assertEqual(len(audit_command), 5)
        self.assertEqual(Path(audit_command[4]).name, 'test_maps_key.txt')
        self.assertEqual(seen['key_contents'], TEST_KEY)
        self.assertNotIn(TEST_KEY, ' '.join(audit_command))


class BuildTest(Base):
    def run_build(self, exit_code=0, make_apk=True, effect=None, node_checks=False):
        _, gs = self.files()
        seen = {}

        def fake_call(command, **kwargs):
            seen['command'] = command
            seen['native_present'] = self.native.is_file()
            seen['maps_swapped'] = 'test' in self.maps.read_text()
            seen['backup'] = (self.recovery / 'maps_key.dart.original').read_text()
            seen['state'] = json.loads((self.recovery / 'state.json').read_text())
            define_arg = [a for a in command if a.startswith('--dart-define-from-file=')][0]
            seen['defines'] = json.loads(Path(define_arg.split('=', 1)[1]).read_text())
            if effect:
                raise effect
            if make_apk:
                apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
                apk.parent.mkdir(parents=True, exist_ok=True)
                apk.write_bytes(b'x')
            return exit_code

        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', side_effect=fake_call), \
                mock.patch.object(bp, 'audit_apk'):
            try:
                bp.build(good_defines(), gs, 11, node_checks=node_checks)
                error = None
            except (bp.PreprodError, KeyboardInterrupt, RuntimeError) as exc:
                error = exc
        return seen, error

    def assert_restored(self):
        self.assertFalse(self.native.exists())
        self.assertFalse(self.recovery.exists())
        self.assertEqual(self.maps.read_text(), PROD_MAPS)
        self.assertFalse(Path(str(self.maps) + '.az-partial').exists())

    def test_build_command_and_cleanup(self):
        seen, error = self.run_build()
        self.assertIsNone(error)
        command = seen['command']
        self.assertEqual(command[1:4], ['build', 'apk', '--debug'])
        self.assertNotIn('--release', command)
        self.assertIn('--dart-define=APP_BUILD_NUMBER=11', command)
        self.assertIn('--android-project-arg=azTestSuffix=.test', command)
        self.assertTrue(seen['native_present'] and seen['maps_swapped'])
        self.assertIs(seen['defines']['DISABLE_FCM'], True)
        self.assertEqual(seen['defines']['AZ_REQUIRED_FIREBASE_PROJECT'], bp.PROJECT_ID)
        self.assertNotIn('APP_BUILD_NUMBER', seen['defines'])
        self.assert_restored()

    def test_backup_and_state_exist_before_the_swap_is_used(self):
        original = bp.hashlib.sha256(self.maps.read_bytes()).hexdigest()  # bytes: write_text may translate newlines
        seen, _ = self.run_build()
        self.assertEqual(seen['backup'], PROD_MAPS)
        self.assertEqual(seen['state']['original_sha256'], original)
        self.assertNotEqual(seen['state']['original_sha256'], seen['state']['test_sha256'])

    def test_failure_exception_and_interrupt_restore_everything(self):
        for kwargs in ({'exit_code': 1, 'make_apk': False}, {'effect': RuntimeError('boom')},
                       {'effect': KeyboardInterrupt()}):
            _, error = self.run_build(**kwargs)
            self.assertIsNotNone(error, kwargs)
            self.assert_restored()

    def test_node_guard_failure_restores_and_does_not_start_flutter(self):
        self.isolation.side_effect = bp.PreprodError('A build step failed')
        _, gs = self.files()
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call') as call:
            with self.assertRaises(bp.PreprodError):
                bp.build(good_defines(), gs, 11)
        call.assert_not_called()
        self.assert_restored()
        self.assertTrue(self.isolation.call_args.kwargs['maps_swapped'])

    def test_locally_modified_maps_key_is_refused_and_untouched(self):
        self.maps.write_text('const local = "my local change";\n')
        self.git.return_value = ' M lib/constants/maps_key.dart'
        _, error = self.run_build()
        self.assertIsInstance(error, bp.PreprodError)
        self.assertIn('local changes', str(error))
        self.assertEqual(self.maps.read_text(), 'const local = "my local change";\n')
        self.assertFalse(self.recovery.exists())
        self.assertFalse(self.native.exists())

    def test_git_failure_refuses_the_build(self):
        for effect in (OSError('no git'), subprocess.TimeoutExpired('git', 1)):
            with mock.patch.object(bp.subprocess, 'run', side_effect=effect):
                with self.assertRaisesRegex(bp.PreprodError, 'Git could not be run'):
                    REAL_GIT_PORCELAIN('lib/constants/maps_key.dart')
        with mock.patch.object(bp.subprocess, 'run', return_value=subprocess.CompletedProcess([], 128, '', '')):
            with self.assertRaisesRegex(bp.PreprodError, 'Git could not check'):
                REAL_GIT_PORCELAIN('lib/constants/maps_key.dart')

    def test_real_git_repository_untracked_clean_modified(self):
        repo = Path(self.tmp.name) / 'gitrepo'
        (repo / 'lib/constants').mkdir(parents=True)
        file = repo / 'lib/constants/maps_key.dart'
        file.write_text(PROD_MAPS)
        git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid']
        subprocess.run(['git', 'init', '-q'], cwd=repo, check=True)
        with mock.patch.object(bp, 'ROOT', repo):
            self.assertTrue(REAL_GIT_PORCELAIN('lib/constants/maps_key.dart').startswith('??'))
            subprocess.run(['git', 'add', '.'], cwd=repo, check=True)
            subprocess.run(git + ['commit', '-q', '-m', 'x'], cwd=repo, check=True)
            self.assertEqual(REAL_GIT_PORCELAIN('lib/constants/maps_key.dart'), '')
            file.write_text('changed')
            self.assertTrue(REAL_GIT_PORCELAIN('lib/constants/maps_key.dart').startswith('M'))

    def test_leftover_native_file_is_refused_and_kept(self):
        self.native.parent.mkdir(parents=True)
        self.native.write_text('{}')
        _, error = self.run_build()
        self.assertIsInstance(error, bp.PreprodError)
        self.assertIn('already exists', str(error))
        self.assertTrue(self.native.exists())
        self.assertFalse(self.recovery.exists())

    def test_incomplete_recovery_states_are_refused_and_never_deleted(self):
        self.recovery.mkdir(parents=True)
        backup, state = self.recovery / 'maps_key.dart.original', self.recovery / 'state.json'
        partial = Path(str(self.maps) + '.az-partial')
        for make in (lambda: backup.write_text('b'), lambda: state.write_text('{}'), lambda: partial.write_text('p')):
            for old in (backup, state, partial):
                old.unlink(missing_ok=True)
            make()
            before = {p: p.read_text() for p in (backup, state, partial) if p.exists()}
            _, error = self.run_build()
            self.assertIsInstance(error, bp.PreprodError)
            self.assertIn('Recovery required', str(error))
            self.assertEqual({p: p.read_text() for p in (backup, state, partial) if p.exists()}, before)
            self.assertEqual(self.maps.read_text(), PROD_MAPS)
            self.assertFalse(self.native.exists())

    def test_recovery_state_is_identifiable(self):
        self.recovery.mkdir(parents=True)
        (self.recovery / 'maps_key.dart.original').write_text(PROD_MAPS)
        digest = lambda path: bp.hashlib.sha256(Path(path).read_bytes()).hexdigest()
        (self.recovery / 'state.json').write_text(json.dumps(
            {'original_sha256': digest(self.maps),
             'test_sha256': digest(self.root / 'lib/constants/maps_key_test.dart')}))
        self.assertIn('equals the saved original', bp.recovery_state(self.maps))
        shutil.copyfile(self.root / 'lib/constants/maps_key_test.dart', self.maps)
        self.assertIn('TEST version', bp.recovery_state(self.maps))
        self.maps.write_text('something else')
        self.assertIn('neither', bp.recovery_state(self.maps))
        (self.recovery / 'state.json').write_text('not json')
        self.assertIn('unreadable', bp.recovery_state(self.maps))

    def test_failed_restore_keeps_backup_and_state(self):
        real_copy = bp.atomic_copy
        calls = []

        def corrupt_second(source, destination):
            calls.append(source)
            if len(calls) == 2:  # the restore
                Path(destination).write_text('corrupted restore')
            else:
                real_copy(source, destination)

        err = io.StringIO()
        with mock.patch.object(bp, 'atomic_copy', corrupt_second), contextlib.redirect_stderr(err):
            self.run_build()
        self.assertIn('restore not verified', err.getvalue())
        self.assertEqual((self.recovery / 'maps_key.dart.original').read_text(), PROD_MAPS)
        self.assertTrue((self.recovery / 'state.json').exists())

    def test_hard_kill_leaves_an_identifiable_recoverable_state(self):
        """A real process is killed with os._exit (no `finally`): nothing is deleted, the next run refuses."""
        _, gs = self.files()
        script = textwrap.dedent(f'''
            import os, sys
            from pathlib import Path
            from unittest import mock
            sys.dont_write_bytecode = True
            sys.path.insert(0, {str(Path(bp.__file__).parent)!r})
            import build_preprod as bp
            bp.ROOT = Path({str(self.root)!r})
            with mock.patch.object(bp, 'check_tools', return_value='x'), \\
                    mock.patch.object(bp, 'git_porcelain', return_value=''), \\
                    mock.patch.object(bp.shutil, 'which', return_value='flutter'), \\
                    mock.patch.object(bp.subprocess, 'call', side_effect=lambda *a, **k: os._exit(7)):
                bp.build({good_defines()!r}, Path({str(gs)!r}), 11, node_checks=False)
        ''')
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, timeout=60,
                                env=self.killed_child_env())
        self.assertEqual(result.returncode, 7, result.stderr)
        backup, state = self.recovery / 'maps_key.dart.original', self.recovery / 'state.json'
        self.assertTrue(backup.exists() and state.exists() and self.native.exists())
        self.assertIn('TEST', bp.recovery_state(self.maps))
        self.assertEqual(backup.read_text(), PROD_MAPS)
        # A new run refuses and deletes nothing.
        _, error = self.run_build()
        self.assertIn('Recovery required', str(error))
        self.assertTrue(backup.exists() and state.exists() and self.native.exists())
        self.assertIn('test', self.maps.read_text())
        # Documented manual recovery (copy, no Git command) returns the exact original.
        shutil.copyfile(backup, self.maps)
        self.assertEqual(self.maps.read_text(), PROD_MAPS)
        self.assertIn('equals the saved original', bp.recovery_state(self.maps))


class WrapperTest(unittest.TestCase):
    ps1 = REPO / 'test-env/build-test-apk.ps1'

    def test_wrapper_delegates_and_keeps_bom(self):
        raw = self.ps1.read_bytes()
        self.assertTrue(raw.startswith(b'\xef\xbb\xbf'))
        text = raw.decode('utf-8-sig')
        self.assertIn('scripts\\build_preprod.py', text)
        for forbidden in ('flutter build', 'verify-isolation', 'get-app-build-number', 'maps_key', 'az-express-b0469'):
            self.assertNotIn(forbidden, text, forbidden)

    def test_wrapper_checks_that_python_launcher_exists(self):
        text = self.ps1.read_text(encoding='utf-8-sig')
        self.assertIn('Get-Command py', text)
        self.assertLess(text.index('Get-Command py'), text.index('py @engineArgs'))
        self.assertTrue(all(ord(c) < 128 for c in text))


if __name__ == '__main__':
    unittest.main()
