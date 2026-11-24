import 'package:az_express/screens/admin/admin_mfa_security.dart';
import 'package:az_express/screens/admin/admin_otp_page.dart'
    show
        AdminEnrollmentSecret,
        prepareAdminEnrollmentSession,
        adminOtpErrorMessage;
import 'package:az_express/web/admin_auth_service.dart';
import 'package:az_express/web/pages/admin/web_admin_dashboard.dart'
    show firestoreStreamErrorMessage, firestoreStreamErrorIcon;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Correction MFA TOTP Web — tests ciblés.
///
/// `AdminAuthService` appelle directement `FirebaseAuth.instance` /
/// `FirebaseFirestore.instance` (pas d'injection de dépendance) ; sans
/// émulateur Firebase ni bibliothèque de mock (aucune des deux n'est
/// disponible ici sans ajouter une dépendance, ce que la mission interdit),
/// un test ne peut PAS exercer un enrôlement ou une connexion réels de bout
/// en bout. Ce fichier teste donc exactement ce que `AdminAuthService`
/// délègue à une logique pure et partagée avec le flux mobile
/// (`admin_mfa_security.dart`, `admin_otp_page.dart`), dans les scénarios
/// Web demandés — sans jamais prétendre qu'un appel Firebase réel a réussi.
void main() {
  const sms = AdminEnrolledFactor(
    kind: AdminSecondFactor.sms,
    enrollmentId: 'sms-enrollment-1',
    label: '+225 07 ** ** 97',
  );
  const totp = AdminEnrolledFactor(
    kind: AdminSecondFactor.totp,
    enrollmentId: 'totp-enrollment-1',
    label: 'Authenticator Admin AZ Express',
  );

  group('1. Connexion admin avec TOTP uniquement', () {
    test('un seul facteur TOTP enrôlé : utilisé directement, aucun choix',
        () {
      final resolution = resolveAdminSecondFactor([totp]);
      expect(resolution.allowed, isTrue);
      expect(resolution.requiresChoice, isFalse);
      expect(resolution.single?.kind, AdminSecondFactor.totp);
      expect(resolution.single?.enrollmentId, 'totp-enrollment-1');
    });
  });

  group('2. Enrôlement d\'un administrateur sans facteur', () {
    // `AdminAuthService._beginEnrollment` délègue entièrement à
    // `prepareAdminEnrollmentSession`, sans jamais vérifier de téléphone :
    // c'est exactement le correctif attendu (voir groupe 8).
    test('sans mot de passe disponible : refus explicite, aucun réseau appelé',
        () async {
      var reauthCalled = false;
      var sessionCalled = false;
      await expectLater(
        prepareAdminEnrollmentSession<String>(
          secret: null,
          reauthenticate: (_) async => reauthCalled = true,
          getSession: () async {
            sessionCalled = true;
            return 'session';
          },
        ),
        throwsA(isA<FirebaseAuthException>()
            .having((e) => e.code, 'code', 'missing-enrollment-password')),
      );
      expect(reauthCalled, isFalse);
      expect(sessionCalled, isFalse);
    });

    test('mot de passe disponible : réauthentification puis session obtenues',
        () async {
      String? reauthPassword;
      var sessionCalled = false;
      final secret = AdminEnrollmentSecret('mot-de-passe-admin');
      final session = await prepareAdminEnrollmentSession<String>(
        secret: secret,
        reauthenticate: (password) async => reauthPassword = password,
        getSession: () async {
          sessionCalled = true;
          return 'session-mfa';
        },
      );
      expect(reauthPassword, 'mot-de-passe-admin');
      expect(sessionCalled, isTrue);
      expect(session, 'session-mfa');
      // Le mot de passe n'est consommé qu'une seule fois, jamais réutilisable.
      expect(secret.consume(), isNull);
    });
  });

  group('3 et 4. Validation locale du code TOTP avant tout appel réseau', () {
    test('code correct (format) accepté localement', () {
      expect(validateAdminTotpCode('123456'), isNull);
    });

    test('code incorrect (format) refusé localement, sans appel réseau', () {
      for (final code in ['', '12a456', '12345', '1234567']) {
        expect(validateAdminTotpCode(code), isNotNull, reason: code);
      }
    });

    test(
        'NON VÉRIFIÉ ICI : la validation réelle d\'un code TOTP auprès de '
        'Identity Platform (TotpMultiFactorGenerator.getAssertionForEnrollment '
        '/ getAssertionForSignIn) exige un compte Firebase réel ou un '
        'émulateur — ni l\'un ni l\'autre n\'est sollicité par ce fichier.',
        () {}, skip: true);
  });

  group('5. Compte avec SMS uniquement', () {
    test('un seul facteur SMS enrôlé : flux SMS historique préservé', () {
      final resolution = resolveAdminSecondFactor([sms]);
      expect(resolution.allowed, isTrue);
      expect(resolution.requiresChoice, isFalse);
      expect(resolution.single?.kind, AdminSecondFactor.sms);
    });
  });

  group('6. Compte avec TOTP et SMS', () {
    test('un choix est demandé, TOTP toujours présenté en premier', () {
      for (final factors in [
        [sms, totp],
        [totp, sms],
      ]) {
        final resolution = resolveAdminSecondFactor(factors);
        expect(resolution.requiresChoice, isTrue);
        expect(resolution.single, isNull);
        expect(resolution.available.length, 2);
        expect(resolution.available.first.kind, AdminSecondFactor.totp);
      }
    });
  });

  group('7. Administrateur non autorisé', () {
    test('rôle inconnu refusé', () {
      expect(
          validateAdminRecord({'role': 'client', 'isActive': true}).allowed,
          isFalse);
    });

    test('compte désactivé refusé même avec un rôle super valide', () {
      expect(
          validateAdminRecord({'role': 'super', 'isActive': false}).allowed,
          isFalse);
    });

    test('document administrateur absent refusé', () {
      expect(validateAdminRecord(null).allowed, isFalse);
    });

    test('sous-admin sans permissions valides refusé', () {
      expect(
          validateAdminRecord({
            'role': 'sub',
            'isActive': true,
            'permissions': ['permission-inexistante'],
          }).allowed,
          isFalse);
    });
  });

  group(
      '8. Absence de numéro de téléphone pour un compte TOTP-only '
      '(régression du correctif Web)', () {
    test(
        'prepareAdminEnrollmentSession ne dépend d\'aucun numéro de '
        'téléphone : seul le mot de passe conditionne l\'enrôlement TOTP',
        () async {
      // Avant le correctif, `AdminAuthService.signIn()` refusait l'enrôlement
      // avec « 2FA obligatoire : aucun téléphone Admin configuré. » dès que
      // `admin['phone']` était vide. La fonction partagée utilisée par le
      // nouveau flux Web n'a et n'a jamais eu de paramètre téléphone : un
      // compte sans numéro peut s'enrôler en TOTP comme n'importe quel autre.
      final session = await prepareAdminEnrollmentSession<String>(
        secret: AdminEnrollmentSecret('mot-de-passe-sans-telephone'),
        reauthenticate: (_) async {},
        getSession: () async => 'session-totp-only',
      );
      expect(session, 'session-totp-only');
    });

    test(
        'resolveAdminSecondFactor([totp]) ne lit ni n\'exige de téléphone pour '
        'un facteur déjà enrôlé', () {
      final resolution = resolveAdminSecondFactor([totp]);
      expect(resolution.single?.kind, AdminSecondFactor.totp);
      // AdminEnrolledFactor ne transporte même pas de champ téléphone pour
      // un facteur TOTP : `label` est le nom d'affichage de l'enrôlement.
      expect(totp.label, 'Authenticator Admin AZ Express');
    });
  });

  group('9. Navigation vers le tableau de bord', () {
    test(
        'NON VÉRIFIÉ ICI : la redirection `webRouter` '
        '(lib/web/web_router.dart) lit `AdminAuthService.instance.isAdmin`, '
        'lui-même mis à `true` uniquement après `_completeWithAssertion` '
        '(rôle revalidé après succès MFA). Vérifier ce câblage de bout en '
        'bout exige un test de widget avec GoRouter + Firebase simulés, '
        'non disponible sans dépendance supplémentaire.',
        () {}, skip: true);

    test(
        'WebAdminAuthResult.success n\'est construit qu\'après validation du '
        'rôle, jamais avant (revue de code, pas un test dynamique)', () {
      // Vérification statique du contrat de la classe valeur elle-même :
      // aucun chemin ne peut produire `success: true` avec `challengeRequired`
      // ou `error` renseignés simultanément.
      const success = WebAdminAuthResult.success();
      const challenge = WebAdminAuthResult.challenge();
      const failure = WebAdminAuthResult.failure('erreur');

      expect(success.success, isTrue);
      expect(success.challengeRequired, isFalse);
      expect(success.error, isNull);

      expect(challenge.success, isFalse);
      expect(challenge.challengeRequired, isTrue);
      expect(challenge.error, isNull);

      expect(failure.success, isFalse);
      expect(failure.challengeRequired, isFalse);
      expect(failure.error, 'erreur');
    });
  });

  group('10. Gestion des erreurs et sessions expirées', () {
    test('session-expired traduit en français, sans détail technique', () {
      final message = adminMfaErrorMessage('session-expired');
      expect(message, contains('expiré'));
      expect(message, isNot(contains('Exception')));
    });

    test('requires-recent-login (enrôlement) demande une reconnexion', () {
      final message = adminOtpErrorMessage('requires-recent-login');
      expect(message, contains('Reconnectez-vous'));
    });

    test('missing-enrollment-password (mot de passe non disponible)', () {
      final message = adminOtpErrorMessage('missing-enrollment-password');
      expect(message, contains('Reconnectez-vous'));
    });

    test(
        'adminOtpErrorMessage retombe sur adminMfaErrorMessage pour les codes '
        'communs (pas de divergence mobile/Web)', () {
      for (final code in [
        'invalid-verification-code',
        'too-many-requests',
        'unsupported-second-factor',
      ]) {
        expect(adminOtpErrorMessage(code), adminMfaErrorMessage(code));
      }
    });

    test('aucun message d\'erreur Web ne doit jamais contenir un secret', () {
      const secretKey = 'JBSWY3DPEHPK3PXP';
      for (final code in ['totp-challenge-timeout', 'session-expired']) {
        expect(adminOtpErrorMessage(code), isNot(contains(secretKey)));
        expect(adminOtpErrorMessage(code), isNot(contains('otpauth')));
      }
    });
  });

  group('11. Alignement des rôles Web (correction P0)', () {
    // `isWebSuperAdmin` est la restriction temporaire Web ajoutée par la
    // correction P0 : tant que les règles Firestore des collections du
    // tableau de bord Web exigent `isAdmin()` strict (role == 'super'),
    // seul un administrateur `super` doit pouvoir atteindre le tableau de
    // bord Web. `validateAdminRecord` (logique mobile partagée, inchangée)
    // continue d'accepter `super` et `sub` : c'est délibéré, Android n'est
    // pas affecté par cette restriction.
    test('administrateur super : autorisé par les deux contrôles', () {
      final admin = {'role': 'super', 'isActive': true};
      expect(validateAdminRecord(admin).allowed, isTrue);
      expect(isWebSuperAdmin(admin), isTrue);
    });

    test(
        'sous-administrateur avec permissions valides : autorisé côté mobile, '
        'rejeté côté restriction Web', () {
      final admin = {
        'role': 'sub',
        'isActive': true,
        'permissions': ['livreurs'],
      };
      expect(validateAdminRecord(admin).allowed, isTrue,
          reason: 'Android ne doit jamais être affecté par la restriction Web');
      expect(isWebSuperAdmin(admin), isFalse,
          reason: 'Le Web doit refuser ce même compte tant que les règles '
              'Firestore des collections affichées exigent role == super');
    });

    test('document administrateur absent : refusé par les deux contrôles',
        () {
      expect(validateAdminRecord(null).allowed, isFalse);
      expect(isWebSuperAdmin(null), isFalse);
    });

    test('rôle manquant ou invalide : refusé par la restriction Web', () {
      expect(isWebSuperAdmin({'isActive': true}), isFalse);
      expect(isWebSuperAdmin({'role': 'client', 'isActive': true}), isFalse);
    });
  });

  group('12. Messages d\'erreur Firestore du tableau de bord Web (correction P0)',
      () {
    // Objectif de la correction : un refus de permission ne doit jamais être
    // présenté comme une liste vide, et le message ne doit jamais fuiter de
    // détail technique brut (code Firebase, stacktrace).
    test('permission-denied : message explicite, pas de détail technique',
        () {
      final error =
          FirebaseException(plugin: 'firestore', code: 'permission-denied');
      final message = firestoreStreamErrorMessage(error);
      expect(message, contains('Accès refusé'));
      expect(message, isNot(contains('permission-denied')));
      expect(firestoreStreamErrorIcon(error), Icons.lock_outline_rounded);
    });

    test('unavailable / network-request-failed : message réseau dédié', () {
      for (final code in [
        'unavailable',
        'deadline-exceeded',
        'network-request-failed',
      ]) {
        final error = FirebaseException(plugin: 'firestore', code: code);
        expect(firestoreStreamErrorMessage(error), contains('Connexion'));
        expect(firestoreStreamErrorIcon(error), Icons.wifi_off_rounded);
      }
    });

    test('erreur non reconnue ou non Firebase : message générique sûr', () {
      expect(firestoreStreamErrorMessage(Exception('boom')),
          isNot(contains('boom')));
      expect(firestoreStreamErrorMessage(null), isNotEmpty);
    });
  });
}
