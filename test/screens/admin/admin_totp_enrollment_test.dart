import 'package:az_express/screens/admin/admin_mfa_security.dart';
import 'package:flutter_test/flutter_test.dart';

/// TOTP Admin — phase 1 (saisie manuelle de la clé, pas de QR code).
///
/// Le SMS reste pleinement supporté ; TOTP devient un second facteur
/// alternatif, prioritaire parce qu'il ne dépend d'aucun réseau opérateur
/// (incident Firebase Phone Auth `INTERNAL (13) / Error code: 39`).
///
/// Ces tests sont purs : aucune dépendance à Firebase Auth, aucun appareil,
/// aucun réseau. Ils exercent les décisions qui précèdent tout appel réseau —
/// validation du code, sélection du facteur, messages d'erreur.
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

  group('Validation locale du code TOTP (avant tout appel réseau)', () {
    test('code vide refusé', () {
      final error = validateAdminTotpCode('');
      expect(error, isNotNull);
      expect(error, contains('6 chiffres'));
    });

    test('code uniquement composé d\'espaces refusé', () {
      expect(validateAdminTotpCode('      '), isNotNull);
    });

    test('code non numérique refusé', () {
      for (final code in ['12a456', 'abcdef', '12 456', '12-456', '１２３４５６']) {
        final error = validateAdminTotpCode(code);
        expect(error, isNotNull, reason: 'code refusé attendu : $code');
        expect(error, contains('chiffres'));
      }
    });

    test('moins de 6 chiffres refusé', () {
      for (final code in ['1', '12345']) {
        expect(validateAdminTotpCode(code), isNotNull, reason: code);
      }
    });

    test('plus de 6 chiffres refusé', () {
      for (final code in ['1234567', '123456789012']) {
        expect(validateAdminTotpCode(code), isNotNull, reason: code);
      }
    });

    test('exactement 6 chiffres accepté', () {
      expect(validateAdminTotpCode('123456'), isNull);
      expect(validateAdminTotpCode('000000'), isNull,
          reason: 'un code TOTP peut légitimement valoir 000000');
      expect(validateAdminTotpCode(' 654321 '), isNull,
          reason: 'les espaces autour du code sont tolérés');
    });

    test('la longueur exigée reste celle d\'Identity Platform', () {
      expect(kAdminTotpCodeLength, 6);
    });

    test('les messages de refus sont en français et sans détail technique', () {
      for (final code in ['', 'abcdef', '123']) {
        final error = validateAdminTotpCode(code)!;
        expect(error, isNot(contains('Exception')));
        expect(error, isNot(contains('firebase')));
        expect(error, isNot(contains('TOTP')));
        expect(error.endsWith('.'), isTrue, reason: 'phrase complète : $error');
      }
    });
  });

  group('Sélection du second facteur', () {
    test('TOTP seul : utilisé directement, aucun choix demandé', () {
      final resolution = resolveAdminSecondFactor([totp]);
      expect(resolution.allowed, isTrue);
      expect(resolution.requiresChoice, isFalse);
      expect(resolution.single?.kind, AdminSecondFactor.totp);
      expect(resolution.single?.enrollmentId, 'totp-enrollment-1');
    });

    test('SMS seul : flux SMS historique préservé, aucun choix demandé', () {
      final resolution = resolveAdminSecondFactor([sms]);
      expect(resolution.allowed, isTrue);
      expect(resolution.requiresChoice, isFalse);
      expect(resolution.single?.kind, AdminSecondFactor.sms);
      expect(resolution.single?.enrollmentId, 'sms-enrollment-1');
    });

    test('SMS + TOTP : un choix est demandé, TOTP présenté en premier', () {
      for (final factors in [
        [sms, totp],
        [totp, sms],
      ]) {
        final resolution = resolveAdminSecondFactor(factors);
        expect(resolution.allowed, isTrue);
        expect(resolution.requiresChoice, isTrue);
        expect(resolution.single, isNull,
            reason: 'aucun facteur ne doit être choisi à la place de l\'Admin');
        expect(resolution.available.length, 2);
        expect(resolution.available.first.kind, AdminSecondFactor.totp,
            reason: 'TOTP d\'abord : indépendant du réseau SMS');
      }
    });

    test('aucun facteur : refus explicite unsupported-second-factor', () {
      final resolution = resolveAdminSecondFactor(const []);
      expect(resolution.allowed, isFalse);
      expect(resolution.errorCode, 'unsupported-second-factor');
      expect(resolution.single, isNull);
      expect(resolution.available, isEmpty);
    });

    test('facteur sans identifiant d\'enrôlement ignoré', () {
      // Un hint sans `uid` exploitable ne permettrait pas
      // `getAssertionForSignIn` : il ne doit jamais être proposé.
      const broken = AdminEnrolledFactor(
        kind: AdminSecondFactor.totp,
        enrollmentId: '   ',
      );
      final resolution = resolveAdminSecondFactor([broken, sms]);
      expect(resolution.requiresChoice, isFalse);
      expect(resolution.single?.kind, AdminSecondFactor.sms);

      final onlyBroken = resolveAdminSecondFactor([broken]);
      expect(onlyBroken.allowed, isFalse);
      expect(onlyBroken.errorCode, 'unsupported-second-factor');
    });

    test(
        'une panne SMS (Error 39) ne bloque pas l\'Admin dès qu\'un facteur TOTP existe',
        () {
      // Le SMS peut être injoignable côté opérateur : la sélection reste
      // possible et TOTP est proposé en tête, donc un chemin de connexion
      // subsiste sans aucun envoi de SMS.
      final resolution = resolveAdminSecondFactor([sms, totp]);
      expect(resolution.allowed, isTrue);
      expect(resolution.available.first.kind, AdminSecondFactor.totp);

      // Et si seul TOTP est enrôlé, aucun challenge SMS n'est même envisagé.
      final totpOnly = resolveAdminSecondFactor([totp]);
      expect(totpOnly.single?.kind, AdminSecondFactor.totp);
    });
  });

  group('Messages d\'erreur TOTP', () {
    const expectations = <String, String>{
      'invalid-verification-code': 'Code incorrect',
      'totp-challenge-timeout': 'expiré',
      'requires-recent-login': 'Reconnectez-vous',
      'maximum-second-factor-count-exceeded': 'Nombre maximal',
      'unsupported-second-factor': 'Aucun second facteur',
    };

    expectations.forEach((code, fragment) {
      test('$code est traduit en français', () {
        final message = adminMfaErrorMessage(code);
        expect(message, contains(fragment));
        expect(message, isNot(contains(code)),
            reason: 'le code technique ne doit jamais être montré');
      });
    });

    test('aucun message ne divulgue de détail technique Firebase', () {
      for (final code in expectations.keys) {
        final message = adminMfaErrorMessage(code);
        for (final leak in ['Firebase', 'Exception', 'INTERNAL', 'null']) {
          expect(message, isNot(contains(leak)), reason: '$code → $message');
        }
      }
    });

    test('un code inconnu reste générique sans exposer de pile', () {
      final message = adminMfaErrorMessage('totp-unknown-failure-xyz');
      expect(message, contains('double authentification'));
      expect(message, isNot(contains('Exception')));
    });
  });

  group('Aucune fuite de secret', () {
    test('un secret TOTP n\'apparaît jamais dans un message utilisateur', () {
      // Forme réaliste d'une clé Identity Platform (base32).
      const secretKey = 'JBSWY3DPEHPK3PXP';
      final messages = <String>[
        ...['', 'abc', '123', '1234567'].map((c) => validateAdminTotpCode(c)!),
        validateAdminTotpCode(secretKey) ?? '',
        adminMfaErrorMessage('totp-challenge-timeout'),
        adminMfaErrorMessage('invalid-verification-code'),
        adminMfaErrorMessage('maximum-second-factor-count-exceeded'),
      ];
      for (final message in messages) {
        expect(message, isNot(contains(secretKey)));
        expect(message, isNot(contains('otpauth')));
      }
    });

    test('aucun code saisi n\'est réinjecté dans le message de refus', () {
      const code = '987654';
      final error = validateAdminTotpCode('$code$code');
      expect(error, isNotNull);
      expect(error, isNot(contains(code)),
          reason: 'le code ne doit jamais être réaffiché ni journalisé');
    });

    test('la clé n\'est pas acceptée comme code (longueur et alphabet)', () {
      expect(validateAdminTotpCode('JBSWY3DPEHPK3PXP'), isNotNull);
    });
  });

  group('Non-régression du flux SMS', () {
    test('les messages SMS historiques sont inchangés', () {
      expect(adminMfaErrorMessage('invalid-phone-number'),
          contains('numéro Admin'));
      expect(adminMfaErrorMessage('session-expired'), contains('expiré'));
      expect(adminMfaErrorMessage('quota-exceeded'), contains('Quota SMS'));
      expect(adminMfaErrorMessage('missing-verification-id'),
          contains('Aucun challenge'));
    });

    test('le contrôle du rôle Admin reste la dernière barrière', () {
      // Inchangé par TOTP : même après une assertion acceptée, un rôle
      // invalide refuse l'accès.
      expect(validateAdminRecord({'role': 'client', 'isActive': true}).allowed,
          isFalse);
      expect(validateAdminRecord({'role': 'super', 'isActive': false}).allowed,
          isFalse);
      expect(validateAdminRecord({'role': 'super', 'isActive': true}).allowed,
          isTrue);
    });
  });
}
