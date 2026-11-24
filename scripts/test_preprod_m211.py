"""M2.11: final local verification of the pre-production build device. Fake keys and files only.

No Gradle, no Flutter build, no Firebase. The only real processes started are this Python interpreter, Node
(read-only guards on fake files) and PowerShell (recovery procedure on a temporary fake repository).
"""
import contextlib
import hashlib
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_preprod as bp  # noqa: E402
from test_build_preprod import PROD_KEY, PROD_MAPS, REPO, TEST_KEY, Base, good_defines  # noqa: E402
from test_gradle_maps_review import new_value  # noqa: E402

ACCENTED = 'dépôt é àç ñ avec espaces'
POWERSHELL = shutil.which('powershell')
NODE = shutil.which('node')

# The documented recovery procedure, as a script so that it can be exercised on a fake repository.
# ASCII only (Windows PowerShell 5.1). It never uses Git to change files and stops on anything unexpected.
RECOVERY_PS1 = textwrap.dedent(r'''
    param([string]$Root, [switch]$SkipGit)
    $ErrorActionPreference = 'Stop'
    Set-Location -LiteralPath $Root
    $dir = 'build\az-preprod-recovery'
    $maps = 'lib\constants\maps_key.dart'
    $partial = "$maps.az-partial"
    $native = 'android\app\src\debug\google-services.json'
    function Hash($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    if (-not (Test-Path -LiteralPath $dir)) { Write-Output 'NOTHING_TO_RECOVER'; exit 0 }
    $backup = Join-Path $dir 'maps_key.dart.original'
    $state = Join-Path $dir 'state.json'
    if (-not (Test-Path -LiteralPath $backup)) { Write-Output 'STOP: no backup file'; exit 3 }
    $saved = $null
    if (Test-Path -LiteralPath $state) {
        try { $saved = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json } catch { $saved = $null }
    }
    if ($saved -and $saved.original_sha256) {
        if ((Hash $backup) -ne $saved.original_sha256) { Write-Output 'STOP: backup does not match the saved hash'; exit 3 }
        $cur = Hash $maps
        if ($cur -ne $saved.original_sha256 -and $cur -ne $saved.test_sha256) { Write-Output 'STOP: maps_key.dart is neither the original nor the test version'; exit 3 }
    } else {
        # No usable state file (missing, empty or truncated): interrupted between the backup and the state
        # file, so the swap never started and maps_key.dart must still equal the backup.
        if ((Hash $backup) -ne (Hash $maps)) { Write-Output 'STOP: no state file and maps_key.dart differs from the backup'; exit 3 }
    }
    Copy-Item -LiteralPath $backup -Destination $maps -Force
    if ((Hash $maps) -ne (Hash $backup)) { Write-Output 'STOP: restore not verified'; exit 3 }
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    if (Test-Path -LiteralPath $native) { Remove-Item -LiteralPath $native }
    Remove-Item -LiteralPath $dir -Recurse
    if (-not $SkipGit) {
        $status = git status --porcelain -- lib/constants/maps_key.dart
        if ($status) { Write-Output 'STOP: Git still reports a change on maps_key.dart'; exit 3 }
    }
    Write-Output 'RECOVERED'
''')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class UnicodePathsTest(Base):
    """1. Spaces and accented characters in every path the engine touches."""

    def setUp(self):
        super().setUp()
        accented_root = Path(self.tmp.name) / ACCENTED / 'repo é'
        shutil.copytree(self.root, accented_root)
        self.root = accented_root
        patch = mock.patch.object(bp, 'ROOT', self.root)
        patch.start(); self.addCleanup(patch.stop)
        self.maps = self.root / 'lib/constants/maps_key.dart'
        self.native = self.root / 'android/app/src/debug/google-services.json'
        self.recovery = self.root / 'build/az-preprod-recovery'
        self.work = Path(self.tmp.name) / ACCENTED / 'config é'
        self.work.mkdir(parents=True)
        # The scratch folder (key file, defines) is created under an accented temporary directory too.
        self.accented_tmp = Path(self.tmp.name) / ACCENTED / 'tmp é'
        self.accented_tmp.mkdir()
        previous = tempfile.tempdir
        tempfile.tempdir = str(self.accented_tmp)
        self.addCleanup(setattr, tempfile, 'tempdir', previous)

    def test_check_only_with_accented_and_spaced_paths(self):
        config, gs = self.files()
        code, out, err = self.check(config, gs)
        self.assertEqual(code, 0, err)
        self.assertNotIn(TEST_KEY, out + err)

    def test_build_refuses_before_any_change_when_no_ascii_location_exists(self):
        """M2.12: accented temp folder AND accented repository path -> refused, nothing touched."""
        _, gs = self.files()
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'),                 mock.patch.object(bp.subprocess, 'call') as call:
            with self.assertRaisesRegex(bp.PreprodError, 'ASCII-only'):
                bp.build(good_defines(), gs, 11, node_checks=False)
        call.assert_not_called()
        self.assertEqual(self.maps.read_text(), PROD_MAPS)
        self.assertFalse(self.recovery.exists())
        self.assertFalse(self.native.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows command-line quoting')
    def test_real_process_receives_the_exact_argument_and_can_open_the_file(self):
        """The Python -> process boundary on Windows (list2cmdline quoting), with a real child process."""
        key_file = self.accented_tmp / 'dossier é espaces' / 'maps_test_key.txt'
        key_file.parent.mkdir()
        key_file.write_text(TEST_KEY, encoding='utf-8')
        argument = f'--android-project-arg=azTestMapsKeyFile={key_file}'
        code = ('import sys,io,pathlib;'
                'sys.stdout.reconfigure(encoding="utf-8");'
                'a=sys.argv[1];p=pathlib.Path(a.split("=",2)[2]);'
                'print(a==sys.argv[2], p.read_text(encoding="utf-8")==sys.argv[3])')
        result = subprocess.run([sys.executable, '-c', code, argument, argument, TEST_KEY],
                                capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.stdout.strip(), 'True True', result.stderr)

    @unittest.skipUnless(NODE, 'Node.js not installed')
    def test_real_node_guards_read_accented_paths(self):
        config, gs = self.files()
        prepared = self.work / 'defines é.json'
        prepared.write_text(json.dumps(bp.prepare_defines(good_defines())), encoding='utf-8')
        result = subprocess.run([NODE, str(REPO / 'test-env/verify-isolation.js'), '--defines', str(prepared),
                                 '--google-services', str(gs), '--require-preprod'],
                                cwd=REPO, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)
        apk_dir = self.work / 'apk é'
        apk_dir.mkdir()
        (apk_dir / 'a.bin').write_bytes(b'nothing')
        reference = self.work / 'maps é.dart'
        reference.write_text(PROD_MAPS, encoding='utf-8')
        result = subprocess.run([NODE, str(REPO / 'test-env/check-no-prod-maps-key.js'), str(reference), str(apk_dir)],
                                cwd=REPO, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        (apk_dir / 'leak.bin').write_bytes(PROD_KEY.encode())
        result = subprocess.run([NODE, str(REPO / 'test-env/check-no-prod-maps-key.js'), str(reference), str(apk_dir)],
                                cwd=REPO, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(PROD_KEY, result.stdout + result.stderr)

    @unittest.skipUnless(POWERSHELL, 'PowerShell not available')
    def test_wrapper_check_only_with_accented_google_services_path(self):
        d = json.loads((REPO / 'test-env/dart-defines.test.json').read_text(encoding='utf-8-sig')) \
            if (REPO / 'test-env/dart-defines.test.json').exists() else None
        if d is None:
            self.skipTest('local test-env/dart-defines.test.json not present')
        native = {'project_info': {'project_id': d['FIREBASE_PROJECT_ID'], 'project_number': d['FIREBASE_MESSAGING_SENDER_ID']},
                  'client': [{'client_info': {'mobilesdk_app_id': d['FIREBASE_ANDROID_APP_ID'],
                                              'android_client_info': {'package_name': bp.PACKAGE}},
                              'api_key': [{'current_key': d['FIREBASE_ANDROID_API_KEY']}]}]}
        folder = self.accented_tmp / 'dossier é avec espaces'
        folder.mkdir()
        gs = folder / 'google-services é.json'
        gs.write_text(json.dumps(native), encoding='utf-8')
        result = subprocess.run([POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                 str(REPO / 'test-env/build-test-apk.ps1'), '-GoogleServices', str(gs),
                                 '-CheckOnly', '-MapsDisabled'],
                                capture_output=True, text=True, encoding='utf-8', errors='replace', cwd=REPO)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('validation PASS', output)
        for secret in (d['FIREBASE_ANDROID_API_KEY'], d['FIREBASE_ANDROID_APP_ID']):
            self.assertNotIn(secret, output)


class AmbientPropertyTest(unittest.TestCase):
    """2. An ambient azTestMapsKeyFile property under --maps-disabled."""

    def ambient_sources(self, repo=REPO, env=None, home=None):
        """Read-only diagnostic: where could Gradle find the property without a -P on the command line?"""
        env = os.environ if env is None else env
        found = [f'env:{name}' for name in env if name.lower().startswith('org_gradle_project_aztest')]
        gradle_home = Path(env.get('GRADLE_USER_HOME') or (home or Path.home() / '.gradle'))
        for path in (repo / 'android/gradle.properties', repo / 'gradle.properties', gradle_home / 'gradle.properties'):
            if path.is_file() and 'azTestMapsKey' in path.read_text(encoding='utf-8', errors='replace'):
                found.append(f'file:{path.name}')
        if 'azTestMapsKey' in env.get('GRADLE_OPTS', ''):
            found.append('env:GRADLE_OPTS')
        return found

    def test_no_ambient_property_on_this_machine(self):
        self.assertEqual(self.ambient_sources(), [])

    def test_diagnostic_detects_ambient_sources_in_fake_locations(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / 'home'; home.mkdir()
            (home / 'gradle.properties').write_text('azTestMapsKeyFile=C:/x/old.txt\n')
            repo = Path(folder) / 'repo'; (repo / 'android').mkdir(parents=True)
            (repo / 'android/gradle.properties').write_text('azTestMapsKey=AIzaOLD\n')
            found = self.ambient_sources(repo, {'ORG_GRADLE_PROJECT_azTestMapsKeyFile': 'x'}, home)
            self.assertEqual(sorted(found), ['env:ORG_GRADLE_PROJECT_azTestMapsKeyFile', 'file:gradle.properties',
                                             'file:gradle.properties'])

    def test_current_engine_does_not_neutralise_an_ambient_key_file(self):
        """Documents the residual risk: --maps-disabled passes only an empty azTestMapsKey."""
        files = {'AMBIENT': 'OLD-AMBIENT-KEY'}
        props = {'azTestSuffix': '.test', 'azTestMapsKey': '', 'azTestMapsKeyFile': 'AMBIENT'}
        self.assertEqual(new_value(props, {}, files), 'OLD-AMBIENT-KEY')

    def test_python_only_mitigation_would_work_without_touching_gradle(self):
        """Proposed (not applied): in --maps-disabled mode also pass an EMPTY key file; a -P value wins over ambient ones."""
        files = {'AMBIENT': 'OLD-AMBIENT-KEY', 'EMPTY': ''}
        props = {'azTestSuffix': '.test', 'azTestMapsKey': '', 'azTestMapsKeyFile': 'EMPTY'}
        self.assertEqual(new_value(props, {}, files), '')

    def test_ambient_property_never_applies_to_production(self):
        props = {'azTestMapsKeyFile': 'AMBIENT', 'azTestMapsKey': 'X'}
        self.assertEqual(new_value(props, {'MAPS_API_KEY': 'LOCAL'}, {'AMBIENT': 'OLD'}), 'LOCAL')


class BuildCacheFactsTest(unittest.TestCase):
    """3. Static facts about the local Gradle build cache (nothing is read from cache entries)."""

    def test_project_enables_the_local_build_cache(self):
        text = (REPO / 'android/gradle.properties').read_text(encoding='utf-8')
        self.assertIn('org.gradle.caching=true', text)
        self.assertIn('org.gradle.daemon=false', text)
        self.assertNotIn('configuration-cache', text.replace('# ', ''))

    def test_no_key_literal_in_the_repository_scripts(self):
        for name in ('scripts/build_preprod.py', 'test-env/build-test-apk.ps1', 'test-env/check-no-prod-maps-key.js',
                     'android/app/build.gradle.kts'):
            self.assertNotRegex((REPO / name).read_text(encoding='utf-8-sig'), r'AIza[0-9A-Za-z_-]{20,}')


class FailureInjectionTest(Base):
    """5. Cleanup and failure scenarios, one fault per stage."""

    def run_build(self, **kwargs):
        _, gs = self.files()
        out = io.StringIO()

        def ok_call(command, **kw):
            apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(b'x')
            return 0

        error = None
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', side_effect=kwargs.pop('call', ok_call)), \
                mock.patch.object(bp, 'audit_apk', side_effect=kwargs.pop('audit', None)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                bp.build(good_defines(), gs, 11, node_checks=kwargs.pop('node_checks', False))
            except BaseException as exc:  # noqa: BLE001 - the point is to classify every outcome
                error = exc
        return error, out.getvalue()

    def pristine(self):
        # An EMPTY recovery folder may remain (harmless: it holds no backup or state, the next run is not blocked).
        recovery_clean = not self.recovery.exists() or not any(self.recovery.iterdir())
        return (not self.native.exists() and recovery_clean and self.maps.read_text() == PROD_MAPS
                and not Path(str(self.maps) + '.az-partial').exists() and bp.recovery_state(self.maps) is None)

    def recoverable(self):
        """Nothing lost: the original exists in the backup and the state says where maps_key.dart stands."""
        backup = self.recovery / 'maps_key.dart.original'
        return backup.exists() and backup.read_text() == PROD_MAPS and bp.recovery_state(self.maps) is not None

    def secrets_absent(self, text):
        self.assertNotIn(TEST_KEY, text); self.assertNotIn(PROD_KEY, text)

    def test_every_stage_failure_that_happens_after_the_swap_restores_everything(self):
        stages = {
            'flutter fails': dict(call=lambda *a, **k: 1),
            'flutter raises': dict(call=mock.Mock(side_effect=RuntimeError('boom'))),
            'interrupt': dict(call=mock.Mock(side_effect=KeyboardInterrupt())),
            'apk missing': dict(call=lambda *a, **k: 0),
            'audit fails': dict(audit=bp.PreprodError('audit'), node_checks=True),
        }
        for name, kwargs in stages.items():
            with self.subTest(name):
                error, log = self.run_build(**kwargs)
                self.assertIsNotNone(error)
                self.assertTrue(self.pristine(), name)
                self.secrets_absent(log + str(error))

    def test_isolation_guard_failure_restores(self):
        self.isolation.side_effect = bp.PreprodError('guard')
        error, _ = self.run_build(node_checks=True)
        self.assertIsInstance(error, bp.PreprodError)
        self.assertTrue(self.pristine())

    def test_native_file_copy_failure_restores(self):
        real = shutil.copyfile

        def copy(source, destination, *a, **k):
            if str(destination).endswith('google-services.json'):
                Path(destination).write_text('partial')  # a half-written native file must not survive
                raise OSError('disk')
            return real(source, destination, *a, **k)

        with mock.patch.object(bp.shutil, 'copyfile', copy):
            error, _ = self.run_build()
        self.assertIsInstance(error, OSError)
        self.assertTrue(self.pristine())

    def test_key_file_write_failure_restores(self):
        real_chmod = os.chmod
        calls = []

        def chmod(path, mode):
            calls.append(path)
            if len(calls) == 2:
                raise OSError('chmod')
            real_chmod(path, mode)

        with mock.patch.object(bp.os, 'chmod', chmod):
            error, log = self.run_build()
        self.assertIsInstance(error, OSError)
        self.assertTrue(self.pristine())
        self.secrets_absent(log)

    def test_swap_failure_restores_from_the_backup(self):
        real = bp.atomic_copy
        calls = []

        def flaky(source, destination):
            calls.append(1)
            if len(calls) == 1:
                raise OSError('swap')
            real(source, destination)

        with mock.patch.object(bp, 'atomic_copy', flaky):
            error, _ = self.run_build()
        self.assertIsInstance(error, OSError)
        self.assertTrue(self.pristine())

    def test_backup_verification_failure_leaves_nothing_behind(self):
        real = bp.sha256
        calls = []

        def lying(path):
            calls.append(1)
            return 'deadbeef' if len(calls) == 2 else real(path)  # 1st: original, 2nd: backup

        with mock.patch.object(bp, 'sha256', lying):
            error, _ = self.run_build()
        self.assertIsInstance(error, bp.PreprodError)
        self.assertTrue(self.pristine())

    def test_restore_failure_keeps_a_recoverable_identifiable_state(self):
        real = bp.atomic_copy
        calls = []

        def failing_restore(source, destination):
            calls.append(1)
            if len(calls) == 2:
                raise OSError('restore')
            real(source, destination)

        with mock.patch.object(bp, 'atomic_copy', failing_restore):
            error, log = self.run_build()
        self.assertIsInstance(error, OSError)
        self.assertTrue(self.recoverable())
        self.assertIn('TEST version', bp.recovery_state(self.maps))
        self.secrets_absent(log)

    def test_state_file_write_failure_never_leaves_an_empty_state_json(self):
        """M2.12: state.json is written atomically. maps_key.dart is untouched; only the backup remains (the next run
        refuses, fail-safe, and the documented procedure clears it)."""
        real_dump = bp.json.dump
        calls = []

        def dump(obj, stream, *a, **k):
            calls.append(1)
            if len(calls) == 2:  # 1st: defines, 2nd: state
                raise OSError('state')
            return real_dump(obj, stream, *a, **k)

        with mock.patch.object(bp.json, 'dump', dump):
            error, _ = self.run_build()
        self.assertIsInstance(error, OSError)
        self.assertEqual(self.maps.read_text(), PROD_MAPS)  # nothing lost, original intact
        self.assertTrue((self.recovery / 'maps_key.dart.original').exists())  # leftover
        self.assertFalse((self.recovery / 'state.json').exists())  # never an empty/partial state.json
        self.assertFalse((self.recovery / 'state.json.az-partial').exists())  # our incomplete file was removed
        self.assertIn('incomplete', bp.recovery_state(self.maps))
        again, _ = self.run_build()
        self.assertIn('Recovery required', str(again))  # fail-safe refusal, nothing deleted
        self.assertEqual(self.maps.read_text(), PROD_MAPS)


@unittest.skipUnless(POWERSHELL, 'PowerShell not available')
class RecoveryProcedureTest(Base):
    """4. Hard kills at three points, then the documented procedure on the fake repository."""

    def kill_child(self, patch_lines):
        _, gs = self.files()
        script = textwrap.dedent(f'''
            import os, sys
            from pathlib import Path
            from unittest import mock
            sys.dont_write_bytecode = True
            sys.path.insert(0, {str(Path(bp.__file__).parent)!r})
            import build_preprod as bp
            bp.ROOT = Path({str(self.root)!r})
            counter = []
            real_replace = os.replace
            real_dump = bp.json.dump
            def second_dump(obj, stream, *a, **k):
                counter.append(1)
                if len(counter) == 2:
                    os._exit(9)
                return real_dump(obj, stream, *a, **k)
            def second_replace(a, b):
                counter.append(1)
                if len(counter) == 3:
                    os._exit(9)
                real_replace(a, b)
            patches = [mock.patch.object(bp, 'check_tools', return_value='x'),
                       mock.patch.object(bp, 'git_porcelain', return_value=''),
                       mock.patch.object(bp.shutil, 'which', return_value='flutter')]
            {patch_lines}
            for p in patches: p.start()
            bp.build({good_defines()!r}, Path({str(gs)!r}), 11, node_checks=False)
        ''')
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, timeout=60,
                                env=self.killed_child_env())
        self.assertEqual(result.returncode, 9, result.stderr)

    def run_procedure(self):
        script = self.root.parent / 'recover.ps1'
        script.write_text(RECOVERY_PS1, encoding='ascii')
        result = subprocess.run([POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
                                 '-Root', str(self.root), '-SkipGit'], capture_output=True, text=True)
        return result.returncode, result.stdout.strip(), result.stderr

    def assert_after_procedure(self):
        code, out, err = self.run_procedure()
        self.assertEqual((code, out), (0, 'RECOVERED'), err)
        self.assertEqual(self.maps.read_text(), PROD_MAPS)
        self.assertFalse(self.recovery.exists())
        self.assertFalse(self.native.exists())
        self.assertFalse(Path(str(self.maps) + '.az-partial').exists())
        # A new build can start again.
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'):
            bp.preflight()

    def test_killed_during_the_flutter_step(self):
        self.kill_child("patches.append(mock.patch.object(bp.subprocess, 'call', side_effect=lambda *a, **k: os._exit(9)))")
        self.assertTrue(self.native.exists() and 'test' in self.maps.read_text())
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'):
            with self.assertRaisesRegex(bp.PreprodError, 'Recovery required'):
                bp.preflight()
        self.assert_after_procedure()

    def test_killed_between_backup_and_state_file(self):
        self.kill_child("patches.append(mock.patch.object(bp.json, 'dump', second_dump))")
        self.assertEqual(self.maps.read_text(), PROD_MAPS)  # swap never started
        self.assertTrue((self.recovery / 'maps_key.dart.original').exists())
        self.assertFalse((self.recovery / 'state.json').exists())  # atomic write: never an empty state.json
        self.assertTrue((self.recovery / 'state.json.az-partial').exists())  # the interrupted write is identifiable
        self.assertIn('incomplete', bp.recovery_state(self.maps))
        self.assert_after_procedure()

    def test_killed_in_the_middle_of_the_restore(self):
        # os.replace calls: 1 = state.json, 2 = swap, 3 = restore (killed after the partial copy, before the replace).
        self.kill_child("patches.append(mock.patch.object(bp.os, 'replace', second_replace))\n"
                        "            patches.append(mock.patch.object(bp.subprocess, 'call', side_effect=lambda *a, **k: 1))")
        self.assertTrue(Path(str(self.maps) + '.az-partial').exists())
        self.assertIn('test', self.maps.read_text())
        self.assert_after_procedure()

    def test_procedure_stops_on_an_unknown_modification(self):
        self.kill_child("patches.append(mock.patch.object(bp.subprocess, 'call', side_effect=lambda *a, **k: os._exit(9)))")
        self.maps.write_text('const something = "edited by hand";\n')
        code, out, _ = self.run_procedure()
        self.assertEqual(code, 3); self.assertIn('STOP', out)
        self.assertEqual(self.maps.read_text(), 'const something = "edited by hand";\n')  # untouched
        self.assertTrue((self.recovery / 'maps_key.dart.original').exists())

    def test_procedure_stops_when_the_backup_was_tampered_with(self):
        self.kill_child("patches.append(mock.patch.object(bp.subprocess, 'call', side_effect=lambda *a, **k: os._exit(9)))")
        (self.recovery / 'maps_key.dart.original').write_text('tampered')
        code, out, _ = self.run_procedure()
        self.assertEqual(code, 3); self.assertIn('STOP', out)
        self.assertTrue(self.native.exists())  # nothing deleted when the procedure stops


if __name__ == '__main__':
    unittest.main()
