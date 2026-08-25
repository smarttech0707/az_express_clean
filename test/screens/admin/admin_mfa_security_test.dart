import 'package:az_express/screens/admin/admin_mfa_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contrôle du rôle après MFA', () {
    test('accepte un super Admin valide', () {
      expect(
        validateAdminRecord({'role': 'super', 'isActive': true}).allowed,
        isTrue,
      );
    });

    test('accepte un sous-Admin actif', () {
      expect(
        validateAdminRecord({
          'role': 'sub',
          'isActive': true,
          'permissions': <String>[],
        }).allowed,
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
      expect(
        validateAdminRecord({'role': 'client', 'isActive': true}).allowed,
        isFalse,
      );
    });

    test('rejette un rôle absent', () {
      expect(validateAdminRecord({'isActive': true}).allowed, isFalse);
    });

    test('rejette un sous-Admin sans isActive explicite', () {
      expect(
        validateAdminRecord({'role': 'sub', 'permissions': []}).allowed,
        isFalse,
      );
    });

    test('rejette un sous-Admin sans permissions valides', () {
      expect(
        validateAdminRecord({'role': 'sub', 'isActive': true}).allowed,
        isFalse,
      );
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

  group('garde réactive du dashboard', () {
    const valid = {'role': 'super', 'isActive': true};

    test('ferme après signOut', () {
      expect(
          isAdminSessionValid(
              currentUid: null,
              isAnonymous: false,
              expectedUid: 'a1',
              adminData: valid),
          isFalse);
    });
    test('ferme si la session devient anonyme', () {
      expect(
          isAdminSessionValid(
              currentUid: 'a1',
              isAnonymous: true,
              expectedUid: 'a1',
              adminData: valid),
          isFalse);
    });
    test('ferme si isActive devient false', () {
      expect(
          isAdminSessionValid(
              currentUid: 'a1',
              isAnonymous: false,
              expectedUid: 'a1',
              adminData: {...valid, 'isActive': false}),
          isFalse);
    });
    test('ferme si le document Admin est supprimé', () {
      expect(
          isAdminSessionValid(
              currentUid: 'a1',
              isAnonymous: false,
              expectedUid: 'a1',
              adminData: null),
          isFalse);
    });
  });

  test('la navigation finale ne peut se produire qu’une fois', () {
    final guard = SingleNavigationGuard();
    expect(guard.acquire(), isTrue);
    expect(guard.acquire(), isFalse);
  });
}
