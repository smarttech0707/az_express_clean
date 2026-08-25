import 'package:az_express/screens/admin/admin_otp_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('inscription prépare la session après ré-authentification', () async {
    final calls = <String>[];
    final secret = AdminEnrollmentSecret('mot-de-passe-temporaire');

    final session = await prepareAdminEnrollmentSession<String>(
      secret: secret,
      reauthenticate: (password) async {
        calls.add('reauth:$password');
      },
      getSession: () async {
        calls.add('session');
        return 'session-mfa';
      },
    );

    expect(session, 'session-mfa');
    expect(calls, ['reauth:mot-de-passe-temporaire', 'session']);
    expect(secret.isAvailable, isFalse);
  });

  test('absence du mot de passe produit une erreur explicite', () async {
    await expectLater(
      prepareAdminEnrollmentSession<String>(
        secret: null,
        reauthenticate: (_) async {},
        getSession: () async => 'interdit',
      ),
      throwsA(
        isA<FirebaseAuthException>().having(
          (error) => error.code,
          'code',
          'missing-enrollment-password',
        ),
      ),
    );
    expect(
      adminOtpErrorMessage('missing-enrollment-password'),
      contains('Reconnectez-vous'),
    );
  });

  test('un code SMS expiré indique de recommencer la connexion', () {
    expect(adminOtpErrorMessage('session-expired'), contains('expiré'));
    expect(
      adminOtpErrorMessage('session-expired'),
      contains('Recommencez la connexion admin'),
    );
  });

  test('requires-recent-login affiche une action claire', () {
    expect(
      adminOtpErrorMessage('requires-recent-login'),
      contains('Reconnectez-vous avec votre mot de passe'),
    );
  });

  test('le mot de passe temporaire n’est jamais écrit sur disque', () async {
    const password = 'secret-qui-ne-doit-pas-etre-persiste';
    final secret = AdminEnrollmentSecret(password);
    await prepareAdminEnrollmentSession<String>(
      secret: secret,
      reauthenticate: (_) async {},
      getSession: () async => 'session',
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), isEmpty);
    expect(secret.isAvailable, isFalse);
  });
}
