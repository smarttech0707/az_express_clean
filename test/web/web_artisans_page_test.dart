import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/service_provider_model.dart';
import 'package:az_express/web/pages/client/web_artisans_page.dart';
import 'package:az_express/web/pages/client/web_client_dashboard.dart';
import 'package:az_express/web/web_router.dart';

/// Phase 3A — Artisans (espace client Web).
///
/// Comme pour les phases précédentes : logique pure testée sans Firebase
/// (filtrage/tri/format), écritures Firestore (favoris, avis) non testées
/// ici — même limite que `service_providers_page.dart` côté mobile, qui n'a
/// pas de test unitaire sur ses écritures non plus. Voir rapport de phase
/// pour les points à vérifier manuellement.
ServiceProvider _p({
  required String id,
  String name = 'Artisan',
  String subcategory = 'macon',
  double rating = 0,
  int ratingCount = 0,
  double? distanceKm,
  String address = '',
  String description = '',
}) {
  final p = ServiceProvider(
    id: id,
    name: name,
    phone: '0102030405',
    address: address,
    description: description,
    subcategory: subcategory,
    category: 'artisans',
    photos: const [],
    lat: 0,
    lng: 0,
    isAvailable: true,
    rating: rating,
    ratingCount: ratingCount,
    isVerified: false,
  );
  p.distanceKm = distanceKm;
  return p;
}

void main() {
  group('1. Liste des 16 métiers : aucun métier inventé', () {
    test('exactement les mêmes identifiants que service_provider_register_page.dart',
        () {
      // Référence : `_catFor()` dans service_provider_register_page.dart —
      // ces 16 ids sont ceux mappés sur category == 'artisans'.
      const expected = {
        'macon', 'plombier', 'electricien', 'ferronnier', 'menuisier',
        'carreleur', 'peintre', 'vitrier', 'reparateur_tv',
        'installation_camera', 'decoration', 'reparateur_portable',
        'salon_coiffure_homme', 'barber_shop', 'salon_coiffure_femme',
        'onglerie',
      };
      final ids = kArtisanSubcategories.map((s) => s.$1).toSet();
      expect(ids, expected);
      expect(ids.length, 16);
    });

    test('aucun doublon d\'identifiant', () {
      final ids = kArtisanSubcategories.map((s) => s.$1).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('2. Filtrage et tri (fonction pure filterAndSortArtisans)', () {
    final all = [
      _p(id: 'a', name: 'Chedjou', subcategory: 'macon', rating: 4.5, ratingCount: 10, distanceKm: 2.0),
      _p(id: 'b', name: 'Amara', subcategory: 'plombier', rating: 3.0, ratingCount: 2, distanceKm: 0.5),
      _p(id: 'c', name: 'Bakary', subcategory: 'macon', rating: 5.0, ratingCount: 1, distanceKm: 10.0),
    ];

    test('sans filtre, les 3 prestataires sont retournés', () {
      expect(filterAndSortArtisans(all).length, 3);
    });

    test('le filtre par sous-catégorie ne garde que le métier choisi', () {
      final result = filterAndSortArtisans(all, subcategory: 'macon');
      expect(result.length, 2);
      expect(result.every((p) => p.subcategory == 'macon'), isTrue);
    });

    test('la recherche texte filtre par nom (insensible à la casse)', () {
      final result = filterAndSortArtisans(all, search: 'bakary');
      expect(result.length, 1);
      expect(result.first.id, 'c');
    });

    test('tri par note : le mieux noté en premier', () {
      final result = filterAndSortArtisans(all, sortBy: ArtisanSortBy.rating);
      expect(result.first.id, 'c'); // 5.0
      expect(result.last.id, 'b'); // 3.0
    });

    test('tri par distance : le plus proche en premier', () {
      final result = filterAndSortArtisans(all, sortBy: ArtisanSortBy.distance);
      expect(result.first.id, 'b'); // 0.5 km
      expect(result.last.id, 'c'); // 10 km
    });

    test('tri par nom : ordre alphabétique', () {
      final result = filterAndSortArtisans(all, sortBy: ArtisanSortBy.name);
      expect(result.map((p) => p.name).toList(), ['Amara', 'Bakary', 'Chedjou']);
    });

    test('un prestataire sans distance connue passe toujours en dernier au tri distance',
        () {
      final withUnknown = [
        ..._listWith(all),
        _p(id: 'd', name: 'SansGPS', subcategory: 'macon', distanceKm: null),
      ];
      final result = filterAndSortArtisans(withUnknown, sortBy: ArtisanSortBy.distance);
      expect(result.last.id, 'd');
    });
  });

  group('3. Calcul de distance (haversineKm)', () {
    test('distance nulle entre un point et lui-même', () {
      expect(haversineKm(6.7273, -3.4961, 6.7273, -3.4961), closeTo(0, 0.001));
    });

    test('distance positive et symétrique entre deux points distincts', () {
      final d1 = haversineKm(6.7273, -3.4961, 6.8, -3.5);
      final d2 = haversineKm(6.8, -3.5, 6.7273, -3.4961);
      expect(d1, greaterThan(0));
      expect(d1, closeTo(d2, 0.0001));
    });
  });

  group('4. Câblage de la route /app/artisans', () {
    test('/app/artisans n\'est plus un "service sans page" (vraie page web)', () {
      expect(clientArtisansRoute, '/app/artisans');
      // Toujours une route déclarée...
      expect(clientAppRoutes, contains(clientArtisansRoute));
      // ...mais PAS une section à onglet (comme Livraison Express).
      expect(clientSectionTabs.containsKey(clientArtisansRoute), isFalse);
      // ...et toujours annoncée par une carte de service existante
      // (clientServiceCards), donc toujours atteignable depuis l'accueil.
      expect(clientServiceRoutes, contains(clientArtisansRoute));
    });
  });

  group('5. Modèle ServiceProvider : pas d\'information inventée', () {
    test('hasGps est faux par défaut (lat/lng à 0, jamais une coordonnée fictive)',
        () {
      final p = _p(id: 'x');
      expect(p.hasGps, isFalse);
    });

    test('ratingStr affiche un tiret tant qu\'aucune note n\'existe', () {
      final p = _p(id: 'x', rating: 0);
      expect(p.ratingStr, '—');
    });
  });
}

List<ServiceProvider> _listWith(List<ServiceProvider> base) => List.of(base);
