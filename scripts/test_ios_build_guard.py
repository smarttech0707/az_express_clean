import contextlib
import io
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

import ios_build_guard as guard


def make_ipa(folder, build='20', bundle='com.azexpress.app', version='1.0.10',
             name='app.ipa', binary=True):
    info = {'CFBundleIdentifier': bundle, 'CFBundleVersion': build,
            'CFBundleShortVersionString': version}
    data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)
    path = Path(folder) / name
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('Payload/Runner.app/Info.plist', data)
    return path


def write_pubspec(folder, version='1.0.10+11'):
    path = Path(folder) / 'pubspec.yaml'
    path.write_text(f'name: az_express\nversion: {version}\n', encoding='utf-8')
    return path


def fake_run(stdout='', returncode=0, stderr=''):
    def run(command, **kwargs):
        run.command = command
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)
    return run


class BuildNumberTest(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(guard.parse_build_number(' 20 '), 20)

    def test_absent_or_invalid_values_are_refused(self):
        for value in (None, '', '  ', '0', '020', '-3', '1.5', '20a', 'abc', '2 0'):
            with self.subTest(value=value), self.assertRaises(guard.GuardError):
                guard.parse_build_number(value)

    def test_no_masking_workaround_remains(self):
        self.assertFalse(hasattr(guard, 'readable'))


CREDS = {name: 'x' for name in guard.CREDENTIALS}


def env(**extra):
    return {**CREDS, 'APP_STORE_APPLE_ID': '123456', **extra}


class LatestBuildTest(unittest.TestCase):
    def test_parse_latest_ignores_log_noise(self):
        self.assertEqual(guard.parse_latest('Fetching...\nDone\n17\n'), 17)
        # Format réel de codemagic-cli-tools 0.70.2 : le numéro seul sur stdout.
        self.assertEqual(guard.parse_latest('17\n'), 17)
        self.assertIsNone(guard.parse_latest('1.2.3\n'))
        self.assertIsNone(guard.parse_latest('Fetching...\n'))
        self.assertIsNone(guard.parse_latest(''))

    def test_equal_or_lower_candidate_is_refused_with_suggestion(self):
        for candidate in (15, 14):
            with self.subTest(candidate=candidate):
                with self.assertRaises(guard.GuardError) as raised:
                    guard.check_candidate(candidate, 15)
                self.assertIn('16', str(raised.exception))

    def test_higher_candidate_is_accepted(self):
        guard.check_candidate(16, 15)
        guard.check_candidate(1, None)

    def test_lookup_uses_all_versions_and_the_apple_id(self):
        run = fake_run('Log\n17\n')
        latest = guard.latest_from_app_store(run=run, environ=env())
        self.assertEqual(latest, 17)
        # Superset App Store + TestFlight, et non la seule version la plus haute.
        self.assertEqual(run.command[:2], ['app-store-connect', 'get-latest-build-number'])
        self.assertIn('--all-versions', run.command)
        self.assertNotIn('get-latest-testflight-build-number', run.command)
        self.assertEqual(run.command[-1], '123456')

    def test_lookup_requires_apple_id(self):
        for environ in (dict(CREDS), env(APP_STORE_APPLE_ID='abc')):
            with self.assertRaises(guard.GuardError):
                guard.latest_from_app_store(run=fake_run('17'), environ=environ)

    def test_cli_decides_when_credentials_are_not_in_the_environment(self):
        # Les identifiants peuvent être fournis autrement que par l'environnement
        # visible du script : c'est la réponse du CLI qui fait foi.
        run = fake_run('17\n')
        self.assertEqual(guard.latest_from_app_store(
            run=run, environ={'APP_STORE_APPLE_ID': '1'}), 17)

    def test_cli_failure_names_missing_credentials_but_never_values(self):
        secret = 'TOPSECRETVALUE'
        environ = {'APP_STORE_APPLE_ID': '1', 'APP_STORE_CONNECT_PRIVATE_KEY': secret}
        with self.assertRaises(guard.GuardError) as raised:
            guard.latest_from_app_store(run=fake_run('', 2, 'invalid'), environ=environ)
        message = str(raised.exception)
        self.assertIn('APP_STORE_CONNECT_ISSUER_ID', message)
        self.assertNotIn('APP_STORE_CONNECT_PRIVATE_KEY', message)
        self.assertNotIn(secret, message)

    def test_failure_summary_drops_usage_and_colors(self):
        stderr = ('usage: app-store-connect ' + 'x' * 500 + '\n'
                  '\x1b[31mapp-store-connect: error: argument --private-key: invalid\x1b[0m\n')
        summary = guard.failure_summary(stderr)
        self.assertEqual(summary, 'app-store-connect: error: argument --private-key: invalid')

    def test_preflight_logs_presence_never_values(self):
        secret = 'TOPSECRETVALUE'
        with contextlib.redirect_stdout(io.StringIO()) as output:
            guard.preflight(environ={**env(IOS_BUILD_NUMBER='20'),
                                     'APP_STORE_CONNECT_PRIVATE_KEY': secret},
                            run=fake_run('15\n'))
        text = output.getvalue()
        self.assertIn('APP_STORE_CONNECT_PRIVATE_KEY : présent', text)
        self.assertNotIn(secret, text)

    def test_lookup_failures_stop_the_build(self):
        environ = env()
        with self.assertRaises(guard.GuardError):
            guard.latest_from_app_store(run=fake_run('', 1, 'Unauthorized'), environ=environ)
        with self.assertRaises(guard.GuardError):
            guard.latest_from_app_store(run=fake_run('no number'), environ=environ)

        def missing(*args, **kwargs):
            raise FileNotFoundError
        with self.assertRaises(guard.GuardError):
            guard.latest_from_app_store(run=missing, environ=environ)

        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired('app-store-connect', 120)
        with self.assertRaises(guard.GuardError):
            guard.latest_from_app_store(run=timeout, environ=environ)


class PreflightTest(unittest.TestCase):
    def run_preflight(self, environ, stdout='15\n'):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = guard.preflight(environ=environ, run=fake_run(stdout))
        return result, output.getvalue()

    def test_available_number_passes_and_is_printed(self):
        result, text = self.run_preflight(env(IOS_BUILD_NUMBER='20', CM_COMMIT='abc123'))
        self.assertEqual(result, 0)
        self.assertIn('Build demandé (IOS_BUILD_NUMBER) : 20', text)
        self.assertIn('abc123', text)

    def test_number_already_used_stops(self):
        with self.assertRaises(guard.GuardError):
            self.run_preflight(env(IOS_BUILD_NUMBER='15'))

    def test_number_below_latest_stops(self):
        with self.assertRaises(guard.GuardError):
            self.run_preflight(env(IOS_BUILD_NUMBER='9'))

    def test_missing_or_invalid_number_stops(self):
        for value in (None, 'abc', '020'):
            with self.assertRaises(guard.GuardError):
                self.run_preflight(env(**({} if value is None else {'IOS_BUILD_NUMBER': value})))

    def test_app_store_failure_stops_even_with_valid_number(self):
        with self.assertRaises(guard.GuardError):
            with contextlib.redirect_stdout(io.StringIO()):
                guard.preflight(environ=env(IOS_BUILD_NUMBER='99'),
                                run=fake_run('', 1, 'Unauthorized'))

    def test_no_way_to_skip_the_app_store_check(self):
        with self.assertRaises(guard.GuardError):
            self.run_preflight({'IOS_BUILD_NUMBER': '99', 'ASC_BUILD_CHECK': 'skip'})


class VerifyIpaTest(unittest.TestCase):
    def verify(self, folder, expected='20', **ipa):
        make_ipa(folder, **ipa)
        pubspec = write_pubspec(folder)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = guard.verify_ipa(expected, folder, pubspec=pubspec,
                                      environ={'CM_COMMIT': 'abc123', 'CM_BRANCH': 'branche'})
        return result, output.getvalue()

    def test_matching_ipa_passes_and_prints_version_build_and_commit(self):
        with tempfile.TemporaryDirectory() as folder:
            result, text = self.verify(folder)
        self.assertEqual(result, 0)
        self.assertIn('1.0.10', text)
        self.assertIn('CFBundleVersion) : 20', text)
        self.assertIn('abc123', text)

    def test_xml_plist_is_read_too(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.verify(folder, binary=False)[0], 0)

    def test_build_mismatch_stops(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(guard.GuardError) as raised:
                self.verify(folder, expected='21', build='20')
        self.assertIn('Envoi à Apple interdit', str(raised.exception))

    def test_wrong_bundle_or_version_stops(self):
        for ipa in ({'bundle': 'com.example.other'}, {'version': '1.0.9'}):
            with self.subTest(ipa=ipa), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(guard.GuardError):
                    self.verify(folder, **ipa)

    def test_zero_or_two_ipas_stop(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(guard.GuardError):
                guard.verify_ipa('20', folder, pubspec=write_pubspec(folder))
            make_ipa(folder, name='a.ipa')
            make_ipa(folder, name='b.ipa')
            with self.assertRaises(guard.GuardError):
                guard.verify_ipa('20', folder, pubspec=write_pubspec(folder))

    def test_absent_expected_number_stops(self):
        with tempfile.TemporaryDirectory() as folder:
            make_ipa(folder)
            with self.assertRaises(guard.GuardError):
                guard.verify_ipa(None, folder, pubspec=write_pubspec(folder))


class PubspecTest(unittest.TestCase):
    def test_real_pubspec_has_a_version(self):
        name, _ = guard.pubspec_version(guard.ROOT / 'pubspec.yaml')
        self.assertRegex(name, r'^\d+\.\d+\.\d+$')


if __name__ == '__main__':
    unittest.main()
