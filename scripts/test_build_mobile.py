import unittest
import plistlib
import tempfile
from pathlib import Path
from build_mobile import IOS_FIELDS, build_command, configuration, validate


class ValidationTest(unittest.TestCase):
    def setUp(self):
        self.values = {name: 'test-value' for name in IOS_FIELDS}
        self.values['FIREBASE_PROJECT_ID'] = 'az-express-b0469'
        self.values['FIREBASE_IOS_BUNDLE_ID'] = 'com.azexpress.app'
        self.source = 'static const FirebaseOptions ios = FirebaseOptions(\n' + ''.join(
            f" field: String.fromEnvironment('{name}'),\n" for name in IOS_FIELDS
        ) + ');'

    def test_valid(self):
        validate(self.values, 'ios', self.source)

    def test_plist_mapping(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.plist'
            path.write_bytes(plistlib.dumps({field: self.values[key]
                                            for key, field in IOS_FIELDS.items()}))
            self.assertEqual(configuration('ios', path), self.values)

    def test_android_contract(self):
        values = {key: value for key, value in self.values.items()
                  if not key.startswith('FIREBASE_IOS')}
        values.update(FIREBASE_ANDROID_API_KEY='test', FIREBASE_ANDROID_APP_ID='test')
        source = 'static const FirebaseOptions android = FirebaseOptions(\n' + ''.join(
            f" field: String.fromEnvironment('{name}'),\n" for name in values
        ) + ');'
        validate(values, 'android', source)
        with self.assertRaises(ValueError):
            validate({**values, 'FIREBASE_ANDROID_APP_ID': ''}, 'android', source)

    def test_each_missing_value_rejected(self):
        for key in IOS_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate({**self.values, key: ''}, 'ios', self.source)

    def test_wrong_identity(self):
        for key in ['FIREBASE_PROJECT_ID', 'FIREBASE_IOS_BUNDLE_ID']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate({**self.values, key: 'wrong'}, 'ios', self.source)

    def test_wrong_restored_source_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.values, 'ios', 'static const FirebaseOptions ios = FirebaseOptions();')


class BuildCommandTest(unittest.TestCase):
    def test_ipa_build_number_override(self):
        command = build_command(
            'flutter', 'ipa', Path('defines.json'), Path('export.plist'), 12)
        self.assertIn('--build-number=12', command)
        self.assertIn('--export-options-plist=' + str(Path('export.plist').resolve()), command)

    def test_android_command_does_not_override_build_number(self):
        command = build_command('flutter', 'apk', Path('defines.json'))
        self.assertFalse(any(arg.startswith('--build-number=') for arg in command))

    def test_build_number_override_is_ipa_only(self):
        with self.assertRaisesRegex(ValueError, 'only for IPA'):
            build_command('flutter', 'apk', Path('defines.json'), build_number=12)


if __name__ == '__main__':
    unittest.main()
