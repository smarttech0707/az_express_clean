import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tests de régression sur `firestore.indexes.json`.
///
/// Chaque requête client combinant un filtre d'égalité et un `orderBy` sur un
/// AUTRE champ exige un index composite : sans lui, Firestore répond
/// `FAILED_PRECONDITION` et l'écran se vide en production alors que tout va
/// bien en émulateur (l'émulateur crée les index à la volée, donc aucun test
/// d'émulateur ne peut détecter ce défaut — d'où ce contrôle déclaratif).
///
/// Les directions sont volontairement vérifiées une par une : un index dont
/// l'ordre ne correspond pas à l'`orderBy` réel du code ne sert à rien.
void main() {
  late List<Map<String, dynamic>> indexes;

  setUpAll(() {
    final file = File('firestore.indexes.json');
    expect(file.existsSync(), isTrue,
        reason: 'firestore.indexes.json introuvable à la racine du dépôt');
    final decoded =
        json.decode(file.readAsStringSync()) as Map<String, dynamic>;
    indexes = (decoded['indexes'] as List).cast<Map<String, dynamic>>();
  });

  /// Vrai si un index déclaré commence exactement par [fields] pour [collection].
  bool hasIndex(String collection, List<List<String>> fields) {
    return indexes.any((index) {
      if (index['collectionGroup'] != collection) return false;
      final declared = (index['fields'] as List).cast<Map<String, dynamic>>();
      if (declared.length < fields.length) return false;
      for (var i = 0; i < fields.length; i++) {
        if (declared[i]['fieldPath'] != fields[i][0]) return false;
        if (declared[i]['order'] != fields[i][1]) return false;
      }
      return true;
    });
  }

  group('index composites requis par des requêtes réelles', () {
    test('orders : commandes vendeur et restaurateur', () {
      // lib/services/firestore_service.dart -> sellerOrders()
      // lib/screens/restaurant/restaurant_owner_dashboard.dart -> _OrdersTab
      expect(
        hasIndex('orders', [
          ['sellerId', 'ASCENDING'],
          ['sellerType', 'ASCENDING'],
          ['createdAt', 'DESCENDING'],
        ]),
        isTrue,
      );
    });

    test('boutique_products : produits du vendeur', () {
      // lib/screens/seller/seller_dashboard.dart
      expect(
        hasIndex('boutique_products', [
          ['sellerId', 'ASCENDING'],
          ['createdAt', 'DESCENDING'],
        ]),
        isTrue,
      );
    });

    test('menu_items : menu boulangerie (tri ascendant, sans descending)', () {
      // lib/screens/client/boulangerie_order_page.dart -> orderBy('category')
      expect(
        hasIndex('menu_items', [
          ['isAvailable', 'ASCENDING'],
          ['category', 'ASCENDING'],
        ]),
        isTrue,
      );
    });

    test('service_providers : administration des artisans filtrée', () {
      // lib/screens/admin/admin_services_page.dart
      expect(
        hasIndex('service_providers', [
          ['subcategory', 'ASCENDING'],
          ['createdAt', 'DESCENDING'],
        ]),
        isTrue,
      );
    });

    test('simple_services : administration des services filtrée', () {
      // lib/screens/admin/admin_simple_services_page.dart
      expect(
        hasIndex('simple_services', [
          ['serviceType', 'ASCENDING'],
          ['createdAt', 'DESCENDING'],
        ]),
        isTrue,
      );
    });

    test('service_reviews : avis d\'un artisan', () {
      // lib/screens/client/service_providers_page.dart
      expect(
        hasIndex('service_reviews', [
          ['providerId', 'ASCENDING'],
          ['createdAt', 'DESCENDING'],
        ]),
        isTrue,
      );
    });

    test('boulangeries : liste client (index préexistant, à ne pas perdre)',
        () {
      // lib/screens/client/boulangeries_list.dart -> orderBy('name')
      expect(
        hasIndex('boulangeries', [
          ['isActive', 'ASCENDING'],
          ['name', 'ASCENDING'],
        ]),
        isTrue,
      );
    });
  });

  test('aucun index dupliqué', () {
    final seen = <String>[];
    for (final index in indexes) {
      final fields = (index['fields'] as List)
          .cast<Map<String, dynamic>>()
          .map((f) => '${f['fieldPath']}:${f['order'] ?? f['arrayConfig']}')
          .join(',');
      seen.add('${index['collectionGroup']}|$fields');
    }
    final duplicates =
        seen.where((key) => seen.where((k) => k == key).length > 1).toSet();
    expect(duplicates, isEmpty, reason: 'index dupliqués : $duplicates');
  });

  test('chaque index déclare une portée et au moins deux champs', () {
    for (final index in indexes) {
      expect(index['queryScope'], isNotNull);
      expect((index['fields'] as List).length, greaterThanOrEqualTo(2),
          reason: 'index mono-champ inutile sur ${index['collectionGroup']}');
    }
  });
}
