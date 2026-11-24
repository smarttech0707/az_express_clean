"""Android DEBUG build bound to the Firebase pre-production project only. Never prints configuration values.

Engine behind test-env/build-test-apk.ps1. Independent from build_mobile.py (production), whose
APP_BUILD_NUMBER helpers are imported read-only so there is a single source of truth.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mobile  # noqa: E402  (read-only reuse of the validated build-number rules)

ROOT = Path(__file__).resolve().parents[1]
PROJECT_ID = 'az-express-preprod'
PROJECT_NUMBER = '306761725053'
PACKAGE = 'com.azexpress.app.test'
# Production identifiers (current, legacy, project number) must appear nowhere in the inputs.
FORBIDDEN = ('az-express-b0469', 'az-express-clean', '697217052961')
REQUIRED = ('FIREBASE_PROJECT_ID', 'FIREBASE_ANDROID_APP_ID', 'FIREBASE_ANDROID_API_KEY',
            'FIREBASE_MESSAGING_SENDER_ID', 'FIREBASE_STORAGE_BUCKET')
# Closed list: an unexpected key could smuggle another environment into the build.
ALLOWED = set(REQUIRED) | {'AZ_REQUIRED_FIREBASE_PROJECT', 'DISABLE_FCM', 'DELIVERY_PROOFS_UI',
                           'DELIVERY_SMS_UI', 'TEST_MAPS_API_KEY'}
MAPS_RELATIVE = 'lib/constants/maps_key.dart'
TOOL_TIMEOUT = 60
# A Google API key is "AIza" + 35 characters. Anything looser is treated as ambiguous and refused.
MAPS_KEY_STRICT = re.compile(r'AIza[0-9A-Za-z_-]{35}')
MAPS_KEY_LOOSE = re.compile(r'AIza[0-9A-Za-z_-]{20,}')


def recovery_dir():
    # Inside the (gitignored) build folder, next to the checkout: an identifiable place that is not the temp folder.
    # The original is also recoverable from Git because a build starts only when maps_key.dart is clean.
    return ROOT / 'build' / 'az-preprod-recovery'


class PreprodError(Exception):
    """Fixed-text refusal; the message never contains a configuration value."""


def load_json(path, label):
    try:
        data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except FileNotFoundError:
        raise PreprodError(f'{label}: file not found.') from None
    except Exception:
        raise PreprodError(f'{label}: unreadable or invalid JSON.') from None
    if not isinstance(data, dict):
        raise PreprodError(f'{label}: JSON object expected.')
    return data


def check_paths(config, google_services):
    config, google_services = Path(config).resolve(), Path(google_services).resolve()
    if config == (ROOT / '.env').resolve() or config.name.lower() == '.env' or config.name.lower().startswith('.env.'):
        raise PreprodError('Refused: the real .env (production configuration) cannot be used.')
    if google_services == (ROOT / 'android/app/google-services.json').resolve():
        raise PreprodError('Refused: android/app/google-services.json is the production file.')
    if config == google_services:
        raise PreprodError('Refused: --config and --google-services must be different files.')


def production_markers():
    """FORBIDDEN plus the identifiers of test-env/lib/guards.js (single source of truth, fail closed)."""
    try:
        source = (ROOT / 'test-env/lib/guards.js').read_text(encoding='utf-8')
        block = re.search(r'const PRODUCTION\s*=\s*Object\.freeze\(\{(.*?)\}\);', source, re.S).group(1)
        parsed = {item.lower() for item in re.findall(r"'([^']+)'", block)}
    except Exception:
        raise PreprodError('Unable to read the production identifiers of test-env/lib/guards.js.') from None
    if not set(FORBIDDEN[:2]) <= parsed:
        raise PreprodError('test-env/lib/guards.js does not list the production project IDs.')
    return set(FORBIDDEN) | parsed


def validate(defines, native, raw_texts):
    markers = production_markers()
    for text in raw_texts:
        lowered = text.lower()
        if any(item in lowered for item in markers):
            raise PreprodError('Refused: reference to the production Firebase project.')
    unknown = set(defines) - ALLOWED
    if unknown:
        raise PreprodError('Refused: unexpected key in the configuration file.')
    for name in REQUIRED:
        if not isinstance(defines.get(name), str) or not defines[name].strip():
            raise PreprodError(f'Missing Firebase parameter: {name}')
    if 'APP_BUILD_NUMBER' in defines:
        raise PreprodError('APP_BUILD_NUMBER must not be set in the configuration file.')
    if defines['FIREBASE_PROJECT_ID'] != PROJECT_ID:
        raise PreprodError(f'Refused: FIREBASE_PROJECT_ID must be {PROJECT_ID}.')
    if defines.get('AZ_REQUIRED_FIREBASE_PROJECT', PROJECT_ID) != PROJECT_ID:
        raise PreprodError('Refused: AZ_REQUIRED_FIREBASE_PROJECT conflicts with the pre-production project.')
    # FCM must stay off: test accounts must never hold real push tokens.
    fcm = defines.get('DISABLE_FCM', True)
    if not (fcm is True or fcm == 'true'):
        raise PreprodError('Refused: DISABLE_FCM must be true.')
    if defines['FIREBASE_MESSAGING_SENDER_ID'] != PROJECT_NUMBER:
        raise PreprodError('Refused: FIREBASE_MESSAGING_SENDER_ID is not the pre-production project number.')
    if PROJECT_ID not in defines['FIREBASE_STORAGE_BUCKET']:
        raise PreprodError('Refused: storage bucket does not belong to the pre-production project.')
    info = native.get('project_info')
    info = info if isinstance(info, dict) else {}
    if not info.get('project_id'):
        raise PreprodError('Refused: google-services.json has no project_id.')
    if info['project_id'] != PROJECT_ID:
        raise PreprodError('Refused: google-services.json project_id differs from the pre-production project.')
    if str(info.get('project_number', '')) != PROJECT_NUMBER:
        raise PreprodError('Refused: google-services.json project_number is missing or inconsistent.')
    clients = native.get('client')
    if not isinstance(clients, list) or len(clients) != 1 or not isinstance(clients[0], dict):
        raise PreprodError('Refused: google-services.json must contain exactly one Android client.')
    client = clients[0]
    client_info = client.get('client_info') if isinstance(client.get('client_info'), dict) else {}
    package = (client_info.get('android_client_info') or {}).get('package_name')
    if package != PACKAGE:
        raise PreprodError(f'Refused: Android package must be {PACKAGE}.')
    if client_info.get('mobilesdk_app_id') != defines['FIREBASE_ANDROID_APP_ID']:
        raise PreprodError('Refused: Dart and native Firebase app IDs differ.')
    keys = [k.get('current_key') for k in client.get('api_key', []) if isinstance(k, dict)]
    if defines['FIREBASE_ANDROID_API_KEY'] not in keys:
        raise PreprodError('Refused: Dart and native Firebase API keys differ.')


def production_maps_key(source):
    """The one Google Maps key of lib/constants/maps_key.dart, or a refusal (fail closed, never printed).

    If the production key cannot be identified reliably, the post-build leak check could not work, so
    the build is blocked instead of being assumed safe.
    """
    strict, loose = set(MAPS_KEY_STRICT.findall(source)), set(MAPS_KEY_LOOSE.findall(source))
    if not loose:
        raise PreprodError('Refused: no production Google Maps key could be identified in lib/constants/maps_key.dart.')
    if len(strict) != 1 or len(loose) != 1 or next(iter(strict)) != next(iter(loose)):
        raise PreprodError('Refused: the production Google Maps key is ambiguous or has an unexpected form.')
    return next(iter(strict))


def validate_test_maps_key(defines, production_key, maps_disabled):
    """Maps are either explicitly disabled or given a valid test key distinct from production."""
    key = defines.get('TEST_MAPS_API_KEY')
    if maps_disabled:
        if key:
            raise PreprodError('Refused: --maps-disabled conflicts with TEST_MAPS_API_KEY.')
        return None
    if not key:
        raise PreprodError('Refused: no test Google Maps key (set TEST_MAPS_API_KEY, or pass --maps-disabled).')
    if not isinstance(key, str) or not MAPS_KEY_STRICT.fullmatch(key):
        raise PreprodError('Refused: TEST_MAPS_API_KEY is not a valid Google API key.')
    if key == production_key:
        raise PreprodError('Refused: TEST_MAPS_API_KEY is the production Google Maps key.')
    return key


def scan_for_key(folder, key):
    """Independent byte-level check (UTF-8 and UTF-16) that a key is absent from an extracted APK."""
    needles = [key.encode('utf-8'), key.encode('utf-16-le')]
    scanned = 0
    for path in Path(folder).rglob('*'):
        if path.is_file():
            scanned += 1
            data = path.read_bytes()
            if any(needle in data for needle in needles):
                raise PreprodError('The production Google Maps key is present in the APK.')
    if not scanned:
        raise PreprodError('The APK content could not be analysed.')


def prepare_defines(defines):
    return {**defines, 'AZ_REQUIRED_FIREBASE_PROJECT': PROJECT_ID, 'DISABLE_FCM': True}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, **kwargs):
    try:
        code = subprocess.call(command, cwd=ROOT, **kwargs)
    except OSError:
        raise PreprodError('A required tool could not be executed (is Node.js installed and on PATH?).') from None
    if code != 0:
        raise PreprodError('A build step failed (see its output above).')


def git_porcelain(relative):
    """`git status --porcelain` of one path. Fails closed: any Git error refuses the build."""
    try:
        result = subprocess.run(['git', 'status', '--porcelain', '--', relative], cwd=ROOT,
                                capture_output=True, text=True, timeout=TOOL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise PreprodError('Git could not be run to check lib/constants/maps_key.dart.') from None
    if result.returncode != 0:
        raise PreprodError('Git could not check the state of lib/constants/maps_key.dart.')
    return result.stdout.strip()


def sdk_roots(env):
    roots = [env.get('ANDROID_HOME'), env.get('ANDROID_SDK_ROOT')]
    if env.get('LOCALAPPDATA'):
        roots.append(str(Path(env['LOCALAPPDATA']) / 'Android/Sdk'))
    return [Path(root) for root in roots if root]


def find_aapt2(env=None):
    """Newest aapt2 found in the Android SDK build-tools, or None."""
    def version(path):
        return tuple(int(part) if part.isdigit() else 0 for part in re.split(r'[.\-]', path.parent.name))
    found = []
    for root in sdk_roots(os.environ if env is None else env):
        tools = root / 'build-tools'
        if tools.is_dir():
            found += [p for name in ('aapt2.exe', 'aapt2') for p in tools.glob(f'*/{name}')]
    return str(max(found, key=version)) if found else None


def check_tools(env=None):
    """Blocking check that the APK package CAN be verified (aapt2) and that Node can run the guards.

    Returns the aapt2 path. A missing or unusable tool is a refusal, never a warning: the
    package check of the finished APK must not be skippable.
    """
    aapt2 = find_aapt2(env)
    if not aapt2:
        raise PreprodError('Refused: aapt2 not found in the Android SDK build-tools (set ANDROID_HOME); '
                           'the APK package could not be verified.')
    if not Path(aapt2).is_file() or not os.access(aapt2, os.X_OK):
        raise PreprodError('Refused: the aapt2 path is not an executable file.')
    for command, label in (([aapt2, 'version'], 'aapt2'), (['node', '--version'], 'Node.js')):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=TOOL_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            raise PreprodError(f'Refused: {label} could not be executed.') from None
        if result.returncode != 0 or not (result.stdout + result.stderr).strip():
            raise PreprodError(f'Refused: {label} did not run correctly.')
    return aapt2


def run_isolation(defines_file, google_services, maps_swapped):
    command = ['node', 'test-env/verify-isolation.js', '--defines', str(defines_file),
               '--google-services', str(google_services), '--require-preprod']
    if maps_swapped:
        command.append('--maps-swapped')
    run(command)


def audit_apk(apk, google_services, maps_backup, aapt2, production_key, test_maps_key):
    try:
        result = subprocess.run([aapt2, 'dump', 'badging', str(apk)], capture_output=True, text=True,
                                timeout=TOOL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise PreprodError('The APK package could not be verified (aapt2 failed to run).') from None
    if result.returncode != 0:
        raise PreprodError('The APK package could not be verified (aapt2 returned an error).')
    if not re.search(r"^package: name='" + re.escape(PACKAGE) + "'", result.stdout, re.M):
        raise PreprodError(f'The APK package is not {PACKAGE}.')
    with tempfile.TemporaryDirectory(prefix='az-apk-audit-') as folder:
        with zipfile.ZipFile(apk) as archive:
            archive.extractall(folder)
        scan_for_key(folder, production_key)  # independent of the Node check below
        run(['node', 'test-env/check-no-prod-maps-key.js', str(maps_backup), folder])
        # The test Maps key reaches the audit script through a 0600 file (removed with the scratch
        # folder), never on the command line: same channel discipline as the Gradle key injection.
        with tempfile.TemporaryDirectory(prefix='az-apk-audit-key-') as key_scratch:
            key_file = Path(key_scratch) / 'test_maps_key.txt'
            with key_file.open('x', encoding='utf-8') as stream:
                os.chmod(key_file, 0o600)
                stream.write(test_maps_key or '')
            run(['node', 'test-env/audit-apk-content.js', folder, str(google_services), str(key_file)])


def atomic_copy(source, destination):
    """The destination is never left half written: copy beside it, then replace in one step."""
    destination = Path(destination)
    partial = destination.with_name(destination.name + '.az-partial')
    shutil.copyfile(source, partial)
    os.replace(partial, destination)


def recovery_state(maps_file):
    """Fixed-text description of an incomplete previous build (never deletes anything)."""
    folder = recovery_dir()
    backup, state = folder / 'maps_key.dart.original', folder / 'state.json'
    partial = Path(str(maps_file) + '.az-partial')
    partial_state = folder / 'state.json.az-partial'
    if not (backup.exists() or state.exists() or partial.exists() or partial_state.exists()):
        return None
    if not (backup.exists() and state.exists()) or partial_state.exists():
        return 'recovery state is incomplete (backup or state file missing, or a state write was interrupted)'
    try:
        saved = json.loads(state.read_text(encoding='utf-8'))
        current = sha256(maps_file)
    except Exception:
        return 'recovery state is unreadable'
    if current == saved.get('original_sha256'):
        return 'maps_key.dart currently equals the saved original'
    if current == saved.get('test_sha256'):
        return 'maps_key.dart is currently the TEST version (swapped)'
    return 'maps_key.dart matches neither the original nor the test version (possible local modification)'


def ascii_scratch_parent():
    """Parent folder for the scratch directory: None (system temp) when its path is ASCII-only.

    The temporary Maps key file path is handed to Gradle through Flutter, so it must survive that
    chain: with a non-ASCII temp path the scratch folder goes to <repo>/build (gitignored) instead,
    and the build is refused if no ASCII-only location exists.
    """
    if tempfile.gettempdir().isascii():
        return None
    fallback = ROOT / 'build'
    if not str(fallback).isascii():
        raise PreprodError('Refused: neither the system temp folder nor the repository path is ASCII-only; '
                           'the temporary Maps key file needs an ASCII-only path.')
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def write_state_atomically(state, content):
    """state.json is created complete or not at all: write beside it, flush to disk, then rename."""
    partial = state.with_name(state.name + '.az-partial')
    try:
        with partial.open('x', encoding='utf-8') as stream:
            json.dump(content, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(partial, state)
    except BaseException:
        partial.unlink(missing_ok=True)  # our own incomplete file; never an existing state.json
        raise


def preflight():
    """Everything that can refuse a build, checked before any file is touched."""
    maps_file = ROOT / MAPS_RELATIVE
    flutter = shutil.which('flutter')
    if not flutter:
        raise PreprodError('Flutter not found.')
    aapt2 = check_tools()
    state = recovery_state(maps_file)
    if state:
        raise PreprodError('Recovery required: a previous pre-production build was interrupted ('
                           + state + '). Nothing was deleted; see docs/ACCOUNT_DELETION_M2_8_PREPROD_HARDENING.md.')
    if (ROOT / 'android/app/src/debug/google-services.json').exists():
        raise PreprodError('android/app/src/debug/google-services.json already exists (interrupted build?): check, then remove it.')
    if not (ROOT / 'lib/constants/maps_key_test.dart').is_file():
        raise PreprodError('lib/constants/maps_key_test.dart not found.')
    if git_porcelain(MAPS_RELATIVE):
        raise PreprodError('Refused: lib/constants/maps_key.dart has local changes or is untracked; '
                           'resolve it first (a build only starts from a clean file).')
    return flutter, aapt2


def maps_keys(defines, maps_disabled):
    """(production key, test key or None) read from the clean maps_key.dart; refuses when unreliable."""
    try:
        source = (ROOT / MAPS_RELATIVE).read_text(encoding='utf-8')
    except OSError:
        raise PreprodError('lib/constants/maps_key.dart could not be read.') from None
    production_key = production_maps_key(source)
    return production_key, validate_test_maps_key(defines, production_key, maps_disabled)


def build(defines, google_services, build_number, node_checks=True, maps_disabled=False):
    flutter, aapt2 = preflight()
    production_key, test_key = maps_keys(defines, maps_disabled)
    target = ROOT / 'android/app/src/debug/google-services.json'
    maps_file = ROOT / MAPS_RELATIVE
    maps_test = ROOT / 'lib/constants/maps_key_test.dart'
    folder = recovery_dir()
    backup, state = folder / 'maps_key.dart.original', folder / 'state.json'
    scratch_parent = ascii_scratch_parent()  # may refuse: still before any file is touched
    native_created = swapped = False
    try:
        with tempfile.TemporaryDirectory(prefix='az-preprod-', dir=scratch_parent) as scratch:
            defines_file = Path(scratch) / 'defines.json'
            with defines_file.open('x', encoding='utf-8') as stream:
                os.chmod(defines_file, 0o600)
                json.dump(prepare_defines(defines), stream)
            original_hash = sha256(maps_file)
            # 1) Verified backup first; the state file is written only after the backup is proven identical.
            folder.mkdir(parents=True, exist_ok=True)
            with backup.open('xb') as stream:
                stream.write(maps_file.read_bytes())
            if sha256(backup) != original_hash:
                backup.unlink()  # our own partial copy; maps_key.dart has not been touched yet
                raise PreprodError('The maps_key.dart backup could not be verified.')
            write_state_atomically(state, {'version': 1, 'original_sha256': original_hash,
                                           'test_sha256': sha256(maps_test),
                                           'started': time.strftime('%Y-%m-%dT%H:%M:%S')})
            swapped = True
            atomic_copy(maps_test, maps_file)
            target.parent.mkdir(parents=True, exist_ok=True)
            native_created = True  # preflight proved the file did not exist: any file there is ours
            shutil.copyfile(google_services, target)
            if node_checks:
                run_isolation(defines_file, target, maps_swapped=True)
            command = [flutter, 'build', 'apk', '--debug', f'--dart-define-from-file={defines_file}',
                       f'--dart-define=APP_BUILD_NUMBER={build_number}',
                       '--android-project-arg=azTestSuffix=.test',
                       # Always present and empty: it holds no secret, and as a command-line property it
                       # overrides any ambient azTestMapsKey (gradle.properties, environment), so --maps-disabled
                       # can never pick up an old key.
                       '--android-project-arg=azTestMapsKey=']
            # The key reaches Gradle through a 0600 file in the scratch folder (removed with it), so it never
            # appears in the command line. With --maps-disabled the file is EMPTY: as a command-line property
            # it overrides any ambient azTestMapsKeyFile, and Gradle then reads "" (no Maps key).
            # -P properties are the only channel Gradle receives (ORG_GRADLE_PROJECT_* is not forwarded).
            key_file = Path(scratch) / 'maps_test_key.txt'
            with key_file.open('x', encoding='utf-8') as stream:
                os.chmod(key_file, 0o600)
                stream.write(test_key or '')
            command.append(f'--android-project-arg=azTestMapsKeyFile={key_file}')
            run(command)
            apk = ROOT / 'build/app/outputs/flutter-apk/app-debug.apk'
            if not apk.is_file():
                raise PreprodError('APK not found after the build.')
            if node_checks:
                audit_apk(apk, google_services, backup, aapt2, production_key, test_key)
            print(f'Pre-production debug APK: {apk}')
    finally:
        if native_created and target.exists():
            target.unlink()
        if swapped:
            # Restore from the verified backup; delete the backup/state only once the restore is proven.
            atomic_copy(backup, maps_file)
            if sha256(maps_file) == original_hash:
                backup.unlink()
                state.unlink()
                try:
                    folder.rmdir()
                except OSError:
                    pass
            else:
                print('ERROR: maps_key.dart restore not verified; the backup and state file were kept in '
                      'build/az-preprod-recovery.', file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='only "apk" (debug) is supported')
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--google-services', type=Path, required=True)
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--maps-disabled', action='store_true',
                        help='explicitly build without Google Maps (no test key); otherwise TEST_MAPS_API_KEY is required')
    parser.add_argument('--check-only', action='store_true',
                        help='validate the configuration, the tools and the Node isolation guard; build nothing')
    args = parser.parse_args(argv)
    if args.target != 'apk' or args.release:
        parser.exit(2, 'Refused: only a debug APK for pre-production is supported (no release, AAB, IPA or web).\n')
    try:
        check_paths(args.config, args.google_services)
        defines = load_json(args.config, '--config')
        native = load_json(args.google_services, '--google-services')
        validate(defines, native, [args.config.read_text(encoding='utf-8-sig'),
                                   args.google_services.read_text(encoding='utf-8-sig')])
        build_number = build_mobile.resolve_build_number(
            None, (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'))
        maps_keys(defines, args.maps_disabled)
    except PreprodError as error:
        parser.exit(2, f'{error}\n')
    except ValueError as error:
        if type(error) is ValueError:
            parser.exit(2, f'{error}\n')
        parser.exit(2, 'Invalid configuration.\n')
    except Exception:
        parser.exit(2, 'Unable to read the configuration.\n')
    try:
        if args.check_only:
            check_tools()
            with tempfile.TemporaryDirectory(prefix='az-preprod-check-') as scratch:
                defines_file = Path(scratch) / 'defines.json'
                defines_file.write_text(json.dumps(prepare_defines(defines)), encoding='utf-8')
                run_isolation(defines_file, args.google_services, maps_swapped=False)
            print(f'Pre-production {PROJECT_ID}: validation PASS (values hidden). APP_BUILD_NUMBER={build_number}.')
            return 0
        build(defines, args.google_services, build_number, maps_disabled=args.maps_disabled)
    except PreprodError as error:
        parser.exit(2, f'{error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
