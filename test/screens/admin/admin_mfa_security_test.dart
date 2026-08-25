import 'package:az_express/screens/admin/admin_mfa_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contrôle du rôle après MFA', () {
    test('accepte un super Admin valide', () {
      expect(validateAdminRecord({'role': 'super'}).allowed, isTrue);
    });

    test('accepte un sous-Admin actif', () {
      expect(
        validateAdminRecord({'role': 'sub', 'isActive': true}).allowed,
        isTrue,
      );
    });

    test('rejette un sous-Admin désactivé', () {
      expect(
        validateAdminRecord({'role': 'sub', 'isActive': false}).allowed,
        isFalse,
      );
    });

    test('rejette un document Admin absent', () {
      expect(validateAdminRecord(null).allowed, isFalse);
    });

    test('rejette un rôle inconnu', () {
      expect(validateAdminRecord({'role': 'client'}).allowed, isFalse);
    });
  });

  group('erreurs Firebase MFA visibles', () {
    test('code incorrect', () {
      expect(adminMfaErrorMessage('invalid-verification-code'),
          contains('incorrect'));
    });

    test('code expiré', () {
      expect(adminMfaErrorMessage('session-expired'), contains('expiré'));
    });

    test('plusieurs tentatives', () {
      expect(adminMfaErrorMessage('too-many-requests'), contains('tentatives'));
    });

    test('configuration Android non autorisée', () {
      expect(adminMfaErrorMessage('app-not-authorized'), contains('Android'));
    });
  });

  test('la navigation finale ne peut se produire qu’une fois', () {
    final guard = SingleNavigationGuard();
    expect(guard.acquire(), isTrue);
    expect(guard.acquire(), isFalse);
  });
}
