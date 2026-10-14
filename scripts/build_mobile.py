"""Validated release builds. Never print Firebase configuration values."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IOS_FIELDS = {
    'FIREBASE_IOS_API_KEY': 'API_KEY',
    'FIREBASE_IOS_APP_ID': 'GOOGLE_APP_ID',
    'FIREBASE_MESSAGING_SENDER_ID': 'GCM_SENDER_ID',
    'FIREBASE_PROJECT_ID': 'PROJECT_ID',
    'FIREBASE_STORAGE_BUCKET': 'STORAGE_BUCKET',
    'FIREBASE_IOS_BUNDLE_ID': 'BUNDLE_ID',
}


def positive_int(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError('must be a positive integer') from error
    if number < 1:
        raise argparse.ArgumentTypeError('must be a positive integer')
    return number


def validate(values, platform, source):
    required = set(IOS_FIELDS) if platform == 'ios' else {
        'FIREBASE_ANDROID_API_KEY', 'FIREBASE_ANDROID_APP_ID',
        'FIREBASE_MESSAGING_SENDER_ID', 'FIREBASE_PROJECT_ID',
        'FIREBASE_STORAGE_BUCKET',
    }
    for name in sorted(required):
        if not isinstance(values.get(name), str) or not values[name].strip():
            raise ValueError(f'Missing Firebase parameter: {name}')
    if values['FIREBASE_PROJECT_ID'] != 'az-express-b0469':
        raise ValueError('Firebase project mismatch')
    if platform == 'ios' and values['FIREBASE_IOS_BUNDLE_ID'] != 'com.azexpress.app':
        raise ValueError('Firebase bundle ID mismatch')
    # Refuse a restored options file with a different configuration contract.
    block = re.search(r'static const FirebaseOptions\s+' + platform +
                      r'\s*=\s*FirebaseOptions\((.*?)\n\s*\);', source, re.S)
    names = set(re.findall(r"String\.fromEnvironment\(\s*['\"]([^'\"]+)",
                           block.group(1) if block else ''))
    if names != required:
        raise ValueError('firebase_options.dart does not match the validated variable contract')


def build_command(flutter, target, defines, export_options=None, build_number=None):
    command = [flutter, 'build', target, '--release',
               f'--dart-define-from-file={defines}']
    if build_number is not None:
        if target != 'ipa':
            raise ValueError('A build-number override is supported only for IPA builds.')
        command.append(f'--build-number={build_number}')
    if export_options:
        command.append(f'--export-options-plist={export_options.resolve()}')
    return command


def configuration(platform, path):
    if platform == 'ios':
        with path.open('rb') as stream:
            native = plistlib.load(stream)
        return {key: native.get(field, '') for key, field in IOS_FIELDS.items()}
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['apk', 'appbundle', 'ipa'])
    parser.add_argument('--config', type=Path)
    parser.add_argument('--export-options', type=Path)
    parser.add_argument('--build-number', type=positive_int)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if args.build_number is not None and args.target != 'ipa':
        parser.error('--build-number is supported only for IPA builds.')
    platform = 'ios' if args.target == 'ipa' else 'android'
    path = args.config or ROOT / ('ios/Runner/GoogleService-Info.plist'
                                 if platform == 'ios' else '.env')
    try:
        values = configuration(platform, path)
        validate(values, platform, (ROOT / 'lib/firebase_options.dart').read_text())
    except ValueError as error:
        # JSON/plist errors can contain input; only our validation errors are safe.
        if type(error) is ValueError:
            parser.exit(2, str(error) + '\n')
        parser.exit(2, 'Invalid Firebase configuration file.\n')
    except Exception:
        parser.exit(2, 'Unable to read Firebase configuration.\n')
    if args.check_only:
        print(f'Firebase {platform}: validation PASS (values hidden).')
        return 0
    flutter = shutil.which('flutter')
    if not flutter:
        parser.exit(2, 'Flutter not found.\n')
    if platform == 'ios' and (not args.export_options or not args.export_options.is_file()):
        parser.exit(2, 'Existing IPA export options are required.\n')
    # Outside the checkout and Hosting. TemporaryDirectory cleans up on failure.
    with tempfile.TemporaryDirectory(prefix='az-firebase-') as folder:
        defines = Path(folder) / 'defines.json'
        with defines.open('x', encoding='utf-8') as stream:
            os.chmod(defines, 0o600)
            json.dump(values, stream)
        command = build_command(
            flutter, args.target, defines, args.export_options, args.build_number)
        return subprocess.call(command, cwd=ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
