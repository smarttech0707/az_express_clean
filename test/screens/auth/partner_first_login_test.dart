import 'dart:io';

import 'package:az_express/screens/auth/partner_first_password_page.dart';
import 'package:az_express/services/partner_first_login_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUser extends Fake implements User {
  @override
  String? get email => '0700000001@az-seller.ci';
}

class _FakeService extends PartnerFirstLoginService {
  _FakeService({
    this.must = true,
    this.mustThrows = false,
    List<Object?> results = const [null],
  }) : _results = List.of(results);

  final bool must;
  final bool mustThrows;
  final List<Object?> _results;
  final List<({String email, String temp, String next})> calls = [];

  @override
  Future<bool> mustChangePassword(User user) async {
    if (mustThrows) throw Exception('offline');
    return must;
  }

  @override
  Future<void> changePassword({
    required String email,
    required String temporaryPassword,
    required String newPassword,
  }) async {
    calls.add((email: email, temp: temporaryPassword, next: newPassword));
    final outcome = _results.isEmpty ? null : _results.removeAt(0);
    if (outcome is PartnerFirstLoginException) throw outcome;
  }
}

String _read(String path) => File(path).readAsStringSync();

/// Ouvre la page depuis une route parente et retourne le résultat de la porte.
Future<void> _pumpGate(
  WidgetTester tester,
  _FakeService service,
  void Function(bool) onResult,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => onResult(
            await PartnerFirstPasswordPage.ensureActivated(
                context, _FakeUser(),
                service: service),
          ),
          child: const Text('ouvrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester,
    {String temp = 'TempPass9Xyz',
    String next = 'MonNouveau9',
    String? confirm}) async {
  await tester.enterText(find.byKey(const Key('temporaryPassword')), temp);
  await tester.enterText(find.byKey(const Key('newPassword')), next);
  await tester.enterText(
      find.byKey(const Key('confirmPassword')), confirm ?? next);
  await tester.pump();
}

void main() {
  group('politique de mot de passe', () {
    test('minimum 8, majuscule et chiffre', () {
      expect(validatePartnerPassword('Abcdefg1'), isNull);
      expect(validatePartnerPassword('Abc1'), isNotNull);
      expect(validatePartnerPassword('abcdefgh1'), isNotNull);
      expect(validatePartnerPassword('ABCDEFGHI'), isNotNull);
      expect(validatePartnerPassword('Abcdefgh'), isNotNull);
    });

    test('refuse le mot de passe temporaire lui-même', () {
      expect(validatePartnerPassword('TempPass9Xyz', temporaryPassword: 'TempPass9Xyz'),
          isNotNull);
      expect(validatePartnerPassword('Autre9Passw', temporaryPassword: 'TempPass9Xyz'),
          isNull);
    });

    test('la revendication serveur est lue strictement', () {
      expect(claimsRequirePasswordChange({kPartnerMustChangeClaim: true}), isTrue);
      expect(claimsRequirePasswordChange({kPartnerMustChangeClaim: 'true'}), isFalse);
      expect(claimsRequirePasswordChange({kPartnerMustChangeClaim: false}), isFalse);
      expect(claimsRequirePasswordChange({}), isFalse);
      expect(claimsRequirePasswordChange(null), isFalse);
    });
  });

  group('porte d\'accès au tableau de bord', () {
    testWidgets('compte historique ou déjà activé : accès direct, aucun écran',
        (tester) async {
      bool? result;
      await _pumpGate(tester, _FakeService(must: false), (r) => result = r);
      expect(result, isTrue);
      expect(find.byType(PartnerFirstPasswordPage), findsNothing);
    });

    testWidgets('état illisible (hors ligne) : accès REFUSÉ (échec fermé)',
        (tester) async {
      bool? result;
      await _pumpGate(tester, _FakeService(mustThrows: true), (r) => result = r);
      expect(result, isFalse);
      expect(find.byType(PartnerFirstPasswordPage), findsNothing);
    });

    testWidgets('changement obligatoire : écran affiché, accès accordé après succès',
        (tester) async {
      final service = _FakeService();
      bool? result;
      await _pumpGate(tester, service, (r) => result = r);
      expect(find.byType(PartnerFirstPasswordPage), findsOneWidget);
      expect(result, isNull, reason: 'pas d\'accès tant que le changement n\'a pas réussi');

      await _fill(tester);
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pumpAndSettle();
      expect(service.calls, hasLength(1));
      expect(service.calls.single.email, '0700000001@az-seller.ci');
      expect(service.calls.single.next, 'MonNouveau9');
      expect(result, isTrue);
    });

    testWidgets('« Se déconnecter » : accès refusé', (tester) async {
      bool? result;
      await _pumpGate(tester, _FakeService(), (r) => result = r);
      await tester.tap(find.text('Se déconnecter'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('le bouton retour système ne permet pas de quitter l\'écran',
        (tester) async {
      bool? result;
      await _pumpGate(tester, _FakeService(), (r) => result = r);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PartnerFirstPasswordPage), findsOneWidget);
      expect(result, isNull);
    });
  });

  group('écran de changement', () {
    testWidgets('mot de passe trop faible : message, aucun appel serveur',
        (tester) async {
      final service = _FakeService();
      await _pumpGate(tester, service, (_) {});
      for (final weak in ['court1A', 'minuscule123', 'SansChiffreAbc']) {
        await _fill(tester, next: weak);
        await tester.tap(find.byKey(const Key('submitFirstPassword')));
        await tester.pump();
        expect(find.byKey(const Key('firstLoginError')), findsOneWidget);
      }
      expect(service.calls, isEmpty);
    });

    testWidgets('confirmation différente : refus local', (tester) async {
      final service = _FakeService();
      await _pumpGate(tester, service, (_) {});
      await _fill(tester, confirm: 'Different9X');
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pump();
      expect(find.text('Les deux mots de passe ne correspondent pas.'), findsOneWidget);
      expect(service.calls, isEmpty);
    });

    testWidgets('nouveau mot de passe identique au temporaire : refus local',
        (tester) async {
      final service = _FakeService();
      await _pumpGate(tester, service, (_) {});
      await _fill(tester, temp: 'TempPass9Xyz', next: 'TempPass9Xyz');
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pump();
      expect(find.byKey(const Key('firstLoginError')), findsOneWidget);
      expect(service.calls, isEmpty);
    });

    testWidgets('mot de passe temporaire incorrect : message clair, on reste sur l\'écran',
        (tester) async {
      final service = _FakeService(results: const [
        PartnerFirstLoginException('Mot de passe temporaire incorrect.'),
      ]);
      bool? result;
      await _pumpGate(tester, service, (r) => result = r);
      await _fill(tester);
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pumpAndSettle();
      expect(find.text('Mot de passe temporaire incorrect.'), findsOneWidget);
      expect(find.byType(PartnerFirstPasswordPage), findsOneWidget);
      expect(result, isNull);
    });

    testWidgets('interruption réseau : erreur affichée, nouvelle tentative possible puis succès',
        (tester) async {
      final service = _FakeService(results: const [
        PartnerFirstLoginException('Connexion interrompue. Vérifiez votre réseau et réessayez.'),
        null,
      ]);
      bool? result;
      await _pumpGate(tester, service, (r) => result = r);
      await _fill(tester);
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connexion interrompue'), findsOneWidget);
      expect(result, isNull);

      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pumpAndSettle();
      expect(service.calls, hasLength(2));
      expect(result, isTrue);
    });

    testWidgets('aucun mot de passe n\'est affiché dans les messages d\'erreur',
        (tester) async {
      final service = _FakeService(results: const [
        PartnerFirstLoginException('Changement impossible. Réessayez.'),
      ]);
      await _pumpGate(tester, service, (_) {});
      await _fill(tester, temp: 'TempPass9Xyz', next: 'MonNouveau9');
      await tester.tap(find.byKey(const Key('submitFirstPassword')));
      await tester.pumpAndSettle();
      final error = tester.widget<Text>(find.byKey(const Key('firstLoginError')));
      expect(error.data, isNot(contains('TempPass9Xyz')));
      expect(error.data, isNot(contains('MonNouveau9')));
    });
  });

  group('aucun contournement dans le code', () {
    const gated = {
      'lib/screens/seller/seller_login.dart',
      'lib/screens/boulangerie/boulangerie_login.dart',
      'lib/screens/restaurant/restaurant_owner_login.dart',
      'lib/screens/home/home_screen.dart',
      'lib/screens/auth/client_auth_page.dart',
    };

    test('tout fichier qui ouvre un tableau de bord partenaire applique la porte', () {
      final constructors = RegExp(
          r'\b(SellerDashboard|BoulangerieDashboard|RestaurantOwnerDashboard)\(');
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll('\\', '/');
        // les tableaux de bord eux-mêmes déclarent leur constructeur
        if (path.endsWith('seller_dashboard.dart') ||
            path.endsWith('boulangerie_dashboard.dart') ||
            path.endsWith('restaurant_owner_dashboard.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        if (constructors.hasMatch(source) &&
            !source.contains('PartnerFirstPasswordPage.ensureActivated')) {
          offenders.add(path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'points d\'entrée sans porte d\'activation : $offenders');
    });

    test('chaque point d\'entrée connu appelle la porte (connexion ET reprise)', () {
      for (final path in gated) {
        final source = _read(path);
        expect(source, contains('PartnerFirstPasswordPage.ensureActivated'), reason: path);
      }
      for (final path in [
        'lib/screens/seller/seller_login.dart',
        'lib/screens/boulangerie/boulangerie_login.dart',
        'lib/screens/restaurant/restaurant_owner_login.dart',
      ]) {
        expect('PartnerFirstPasswordPage.ensureActivated'.allMatches(_read(path)).length,
            2, reason: '$path : connexion + reprise automatique');
      }
    });

    test('la porte précède l\'ouverture du tableau de bord (ordre dans le source)', () {
      for (final path in [
        'lib/screens/seller/seller_login.dart',
        'lib/screens/boulangerie/boulangerie_login.dart',
        'lib/screens/restaurant/restaurant_owner_login.dart',
      ]) {
        final source = _read(path);
        final gate = source.indexOf('PartnerFirstPasswordPage.ensureActivated');
        final dashboard = source.indexOf(RegExp(r'Dashboard\('));
        expect(gate, lessThan(dashboard), reason: path);
      }
    });

    test('le client ne lève jamais lui-même l\'obligation : aucune écriture du drapeau', () {
      for (final path in [
        'lib/services/partner_first_login_service.dart',
        'lib/screens/auth/partner_first_password_page.dart',
      ]) {
        final source = _read(path);
        expect(source, isNot(contains('mustChangePassword\': false')), reason: path);
        expect(source, isNot(contains("collection('partner_provisioning')")), reason: path);
        expect(source, isNot(contains('.update(')), reason: path);
      }
      // le service passe par la fonction serveur
      expect(_read('lib/services/partner_first_login_service.dart'),
          contains("'completePartnerFirstPasswordChange'"));
      // l'état est confirmé par le serveur, pas déduit du seul jeton local
      expect(_read('lib/services/partner_first_login_service.dart'),
          contains("'statusOnly': true"));
    });

    test('les écrans admin n\'envoient ni ne saisissent de mot de passe', () {
      final service = _read('lib/screens/admin/admin_partner_account_service.dart');
      expect(service, isNot(contains("'password'")));
      for (final path in [
        'lib/screens/admin/admin_sellers_page.dart',
        'lib/screens/admin/admin_boulangeries_page.dart',
        'lib/screens/admin/admin_restaurants_page.dart',
      ]) {
        final source = _read(path);
        expect(source, isNot(contains('password: pass')), reason: path);
        expect(source, isNot(contains('_generatePassword')), reason: path);
        expect(source, contains('showPartnerTempCredentialsDialog'), reason: path);
      }
    });
  });
}
