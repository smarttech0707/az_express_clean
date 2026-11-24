import 'dart:io';

import 'package:az_express/screens/restaurant/restaurant_register.dart';
import 'package:az_express/widgets/admin_restaurant_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Comptes restaurant (étape A) : création administrative via la fonction
/// serveur, attribution manuelle et inscription autonome accessible.
///
/// `RestaurantOwnerLogin`/`AdminRestaurantsPage` initialisent Firebase dans
/// `initState`, donc leur câblage est vérifié par lecture du source (même
/// technique que `indexes_declaration_test.dart`), et les widgets sans
/// dépendance Firebase par de vrais tests de widget.
String _source(String path) => File(path).readAsStringSync();

void main() {
  group('inscription autonome accessible', () {
    test("l'écran de connexion restaurateur mène à RestaurantRegister", () {
      final source = _source('lib/screens/restaurant/restaurant_owner_login.dart');
      expect(source, contains("import 'restaurant_register.dart';"));
      expect(source, contains('const RestaurantRegister()'));
      expect(source, contains('Pas encore inscrit ?'));
    });

    testWidgets('RestaurantRegister s\'affiche (parcours demande → approbation)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RestaurantRegister()));
      expect(find.byType(RestaurantRegister), findsOneWidget);
      expect(find.byType(TextField), findsWidgets);
    });

    test('aucun second système d\'inscription : même collection de demandes', () {
      final register = _source('lib/screens/restaurant/restaurant_register.dart');
      expect(register, contains("'restaurant_requests'"));
      expect(register, contains("'status': 'pending'"));
    });
  });

  group('création administrative', () {
    final page = _source('lib/screens/admin/admin_restaurants_page.dart');

    test('plus de création de restaurant sans responsable', () {
      expect(page, isNot(contains('collection("restaurants").add(')));
      expect(page, isNot(contains("collection('restaurants').add(")));
      expect(page, contains('AdminPartnerAccountService.createRestaurant('));
    });

    test('identifiant de connexion = celui que reconstruit l\'écran de connexion', () {
      expect(page, contains("'\$phone@az-restaurant.ci'"));
      final login = _source('lib/screens/restaurant/restaurant_owner_login.dart');
      expect(login, contains("'\$phone@az-restaurant.ci'"));
    });

    test('aucun mot de passe écrit dans Firestore par la page', () {
      expect(page, isNot(contains('"password"')));
      expect(page, isNot(contains("'password':")));
    });

    test('le service appelle la fonction serveur sécurisée', () {
      final service = _source('lib/screens/admin/admin_partner_account_service.dart');
      expect(service, contains("'manageAdminPartnerAccount'"));
      expect(service, contains("'kind': 'restaurant'"));
      expect(service, contains("'action': 'assignOwner'"));
    });
  });

  group('attribution manuelle (restaurants historiques)', () {
    testWidgets('le bouton « Responsable » n\'apparaît que s\'il est fourni',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AdminRestaurantActions(
            onMenu: () {},
            onSubscription: () {},
            onDelete: () {},
          ),
        ),
      ));
      expect(find.text('Responsable'), findsNothing);

      var called = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AdminRestaurantActions(
            onMenu: () {},
            onSubscription: () {},
            onDelete: () {},
            onAssignOwner: () => called++,
          ),
        ),
      ));
      expect(find.text('Responsable'), findsOneWidget);
      await tester.tap(find.text('Responsable'));
      expect(called, 1);
    });

    test('l\'attribution est explicite, jamais lancée automatiquement', () {
      final page = _source('lib/screens/admin/admin_restaurants_page.dart');
      // appelée uniquement depuis le bouton de la carte et le dialogue
      expect('assignRestaurantOwner('.allMatches(page).length, 1);
      expect(page, contains('onAssignOwner: () => _showAssignOwner(context, doc)'));
      expect(page, contains('restaurantId: doc.id'));
    });
  });
}
