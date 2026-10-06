import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/auth/forgot_password_page.dart';

/// Récupération de mot de passe Client / Livreur — correctif du 2026-10-06.
///
/// Firebase Phone Auth est en échec sur le projet (`INTERNAL (13) /
/// Error code: 39`), ce qui casse le canal SMS. `sendPasswordResetEmail` passe
/// par un autre service Identity Toolkit et n'est pas affecté : pour Client et
/// Livreur, qui disposent tous deux d'une adresse e-mail RÉELLE validée à
/// l'inscription, le lien e-mail est donc le seul canal fonctionnel.
///
/// L'écran proposait déjà les deux canaux, mais `_bySms = true` faisait
/// atterrir l'utilisateur sur le canal cassé. Le défaut est désormais
/// l'e-mail, et le canal SMS est masqué pour le livreur (voir
/// [smsRecoveryAvailable] pour la raison exacte).
///
/// Ces tests ne touchent ni Firebase, ni réseau : l'écran n'instancie
/// `FirebaseAuth` qu'au moment d'une soumission, jamais au `build`.
void main() {
  Future<void> pumpPage(WidgetTester tester, AccountRecoveryRole role) async {
    await tester.pumpWidget(MaterialApp(
      home: ForgotPasswordPage(role: role),
    ));
    await tester.pump();
  }

  group('Disponibilité du canal SMS par rôle', () {
    test('le client conserve le canal SMS', () {
      expect(smsRecoveryAvailable(AccountRecoveryRole.client), isTrue);
    });

    test('le livreur n\'a pas de canal SMS', () {
      // Le chemin SMS du livreur aboutirait à `resetAccountPassword` avec
      // `userType: 'client'` codé en dur — il viserait la collection
      // `clients`, jamais `livreurs`.
      expect(smsRecoveryAvailable(AccountRecoveryRole.driver), isFalse);
    });

    test('le rôle par défaut est client', () {
      const page = ForgotPasswordPage();
      expect(page.role, AccountRecoveryRole.client);
    });
  });

  group('Client — e-mail par défaut, SMS conservé', () {
    testWidgets('arrive sur le mode e-mail', (tester) async {
      await pumpPage(tester, AccountRecoveryRole.client);
      expect(find.text('Votre adresse email'), findsOneWidget);
      expect(find.text('Votre numéro de téléphone'), findsNothing);
      expect(find.text('Envoyer le lien email'), findsOneWidget);
      expect(find.text('Envoyer le code SMS'), findsNothing);
    });

    testWidgets('le canal SMS reste visible et sélectionnable',
        (tester) async {
      await pumpPage(tester, AccountRecoveryRole.client);
      final smsCard = find.text('Recevoir un code\npar SMS');
      expect(smsCard, findsOneWidget);

      await tester.tap(smsCard);
      await tester.pump();
      expect(find.text('Votre numéro de téléphone'), findsOneWidget);
      expect(find.text('Envoyer le code SMS'), findsOneWidget);
      expect(find.text('Votre adresse email'), findsNothing);
    });

    testWidgets('l\'avertissement SMS indisponible est affiché',
        (tester) async {
      await pumpPage(tester, AccountRecoveryRole.client);
      expect(find.text(kSmsRecoveryWarning), findsOneWidget);
      expect(kSmsRecoveryWarning, contains('e-mail'));
      expect(kSmsRecoveryWarning, contains('indisponible'));
    });

    testWidgets('le numéro prérempli ne force pas le mode SMS',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: ForgotPasswordPage(prefillPhone: '0700000000'),
      ));
      await tester.pump();
      expect(find.text('Votre adresse email'), findsOneWidget,
          reason: 'le préremplissage ne doit pas ramener sur le canal cassé');
    });
  });

  group('Livreur — e-mail uniquement', () {
    testWidgets('arrive sur le mode e-mail', (tester) async {
      await pumpPage(tester, AccountRecoveryRole.driver);
      expect(find.text('Votre adresse email'), findsOneWidget);
      expect(find.text('Envoyer le lien email'), findsOneWidget);
    });

    testWidgets('aucune carte SMS proposée', (tester) async {
      await pumpPage(tester, AccountRecoveryRole.driver);
      expect(find.text('Recevoir un code\npar SMS'), findsNothing);
      expect(find.text('Votre numéro de téléphone'), findsNothing);
      expect(find.text('Envoyer le code SMS'), findsNothing);
    });

    testWidgets('pas d\'avertissement SMS, mais une explication dédiée',
        (tester) async {
      await pumpPage(tester, AccountRecoveryRole.driver);
      expect(find.text(kSmsRecoveryWarning), findsNothing);
      expect(
        find.text('La réinitialisation se fait par e-mail pour ce compte.'),
        findsOneWidget,
      );
    });

    testWidgets('le livreur ne peut jamais atteindre l\'écran de code SMS',
        (tester) async {
      // Aucun chemin d'interface ne mène au reset SMS : ni carte, ni bouton.
      // La garde de `_submitSms` ferme en plus le cas où la carte
      // réapparaîtrait par régression.
      await pumpPage(tester, AccountRecoveryRole.driver);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'un seul champ : l\'adresse e-mail');
      expect(find.textContaining('6 chiffres'), findsNothing);
    });
  });

  group('Le canal e-mail est bien celui présenté', () {
    testWidgets('le libellé annonce un lien, pas un code', (tester) async {
      for (final role in AccountRecoveryRole.values) {
        await pumpPage(tester, role);
        expect(find.text('Recevoir un lien\npar e-mail'), findsOneWidget);
        expect(
          find.text('Un lien de réinitialisation sera envoyé à cet email'),
          findsOneWidget,
        );
      }
    });

    testWidgets('l\'en-tête ne parle plus de code de récupération',
        (tester) async {
      await pumpPage(tester, AccountRecoveryRole.client);
      expect(find.textContaining('votre code de récupération'), findsNothing);
      expect(find.textContaining('lien de réinitialisation'), findsWidgets);
    });
  });
}
