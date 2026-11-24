import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/catalog_location_resolver.dart';

// SEC-01 release readiness — Lot A Phase 4 : correction du dispatch Catalogue
// (Blanchisserie, Colis, Eau & Boissons). Isole la seule logique PURE de
// `CatalogLocationResolver` — l'extraction d'un point depuis la réponse
// `{results: [...]}` de `mapsGeocodeCF` — sans dépendre de Geolocator ni de
// Firebase Functions (aucun paquet de simulation disponible dans ce dépôt,
// même limite déjà documentée pour les autres services réseau).
//
// `flutter test` n'a pas pu être exécuté dans cet environnement
// (`flutter`/`dart` indisponibles) — ce fichier est préparé, pas validé par
// une exécution réelle. Signalé explicitement, conformément à la consigne.
void main() {
  group('CatalogLocationResolver.pointFromGeocodeData', () {
    test('réponse normale → premier point exploitable extrait', () {
      final r = CatalogLocationResolver.pointFromGeocodeData({
        'results': [
          {'lat': 6.7301, 'lng': -3.4967, 'formattedAddress': 'Abengourou'},
        ],
      });
      expect(r, isNotNull);
      expect(r!.lat, 6.7301);
      expect(r.lng, -3.4967);
      expect(r.source, CatalogLocationSource.google);
      expect(r.serverSourceName, 'google');
    });

    test('résultats vides → null', () {
      expect(CatalogLocationResolver.pointFromGeocodeData({'results': []}),
          isNull);
    });

    test('data absent ou mal formé → null, jamais d\'exception', () {
      expect(CatalogLocationResolver.pointFromGeocodeData(null), isNull);
      expect(CatalogLocationResolver.pointFromGeocodeData({}), isNull);
      expect(
          CatalogLocationResolver.pointFromGeocodeData({'results': 'x'}),
          isNull);
    });

    test('premier résultat (0,0) ignoré, le suivant exploitable est utilisé', () {
      final r = CatalogLocationResolver.pointFromGeocodeData({
        'results': [
          {'lat': 0, 'lng': 0},
          {'lat': 6.71, 'lng': -3.44},
        ],
      });
      expect(r, isNotNull);
      expect(r!.lat, 6.71);
      expect(r.lng, -3.44);
    });

    test('tous les résultats (0,0) ou invalides → null, jamais (0,0) retourné', () {
      final r = CatalogLocationResolver.pointFromGeocodeData({
        'results': [
          {'lat': 0, 'lng': 0},
          {'lat': 'texte', 'lng': -3.44},
        ],
      });
      expect(r, isNull);
    });
  });

  group('CatalogLocationResult.serverSourceName', () {
    test('gps → "gps", google → "google" (noms attendus par catalogQuote.js)', () {
      expect(const CatalogLocationResult(6.7, -3.4, CatalogLocationSource.gps)
          .serverSourceName, 'gps');
      expect(
          const CatalogLocationResult(6.7, -3.4, CatalogLocationSource.google)
              .serverSourceName,
          'google');
    });
  });
}
