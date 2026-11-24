import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/services/map_navigation_service.dart';

// Mission 7/8/14 — distance locale (jamais Google Routes) + URLs de
// navigation externe, toutes pures et testables sans launchUrl/plateforme.
void main() {
  group('MapNavigationService.isValidCoordinate', () {
    test('rejette null', () {
      expect(MapNavigationService.isValidCoordinate(null, -3.49), false);
      expect(MapNavigationService.isValidCoordinate(6.72, null), false);
    });
    test('rejette 0,0', () {
      expect(MapNavigationService.isValidCoordinate(0, 0), false);
    });
    test('rejette hors plage', () {
      expect(MapNavigationService.isValidCoordinate(95, -3.49), false);
      expect(MapNavigationService.isValidCoordinate(6.72, 190), false);
    });
    test('accepte une coordonnée valide réelle', () {
      expect(MapNavigationService.isValidCoordinate(6.7273, -3.4961), true);
    });
  });

  group('MapNavigationService — construction d\'URL', () {
    test('Google Maps vue statique', () {
      final uri = MapNavigationService.buildGoogleMapsViewUri(6.72, -3.49);
      expect(uri.toString(),
          'https://www.google.com/maps/search/?api=1&query=6.72,-3.49');
    });

    test('Google Maps itinéraire (destination + travelmode=driving)', () {
      final uri =
          MapNavigationService.buildGoogleMapsDirectionsUri(6.72, -3.49);
      expect(uri.toString(),
          'https://www.google.com/maps/dir/?api=1&destination=6.72,-3.49&travelmode=driving');
    });

    test('Apple Maps itinéraire', () {
      final uri = MapNavigationService.buildAppleMapsDirectionsUri(6.72, -3.49);
      expect(
          uri.toString(), 'https://maps.apple.com/?daddr=6.72,-3.49&dirflg=d');
    });

    test('Waze', () {
      final uri = MapNavigationService.buildWazeUri(6.72, -3.49);
      expect(uri.toString(), 'https://waze.com/ul?ll=6.72,-3.49&navigate=yes');
    });
  });

  group('MapNavigationService.formatDistance', () {
    test('moins de 1 km → mètres arrondis', () {
      expect(MapNavigationService.formatDistance(650), '650 m');
      expect(MapNavigationService.formatDistance(999), '999 m');
    });
    test('à partir de 1 km → kilomètres, une décimale, virgule française', () {
      expect(MapNavigationService.formatDistance(2400), '2,4 km');
      expect(MapNavigationService.formatDistance(12000), '12,0 km');
    });
  });

  group('MapNavigationService.distanceLabel', () {
    test('exact — "À X km de votre position"', () {
      expect(
          MapNavigationService.distanceLabel(
              meters: 2400, isApproximate: false),
          'À 2,4 km de votre position');
    });
    test('approximate — "Environ X km jusqu\'à la zone indiquée"', () {
      expect(
          MapNavigationService.distanceLabel(meters: 2400, isApproximate: true),
          'Environ 2,4 km jusqu\'à la zone indiquée');
    });
  });

  group('MapNavigationService.distanceMeters — distance réelle à vol d\'oiseau',
      () {
    test('même point → distance nulle', () {
      final d = MapNavigationService.distanceMeters(
          fromLat: 6.7273, fromLng: -3.4961, toLat: 6.7273, toLng: -3.4961);
      expect(d, closeTo(0, 0.01));
    });
    test(
        'deux points distincts → distance positive plausible (Abengourou, ~2km)',
        () {
      final d = MapNavigationService.distanceMeters(
          fromLat: 6.7273, fromLng: -3.4961, toLat: 6.74, toLng: -3.49);
      expect(d, greaterThan(1000));
      expect(d, lessThan(5000));
    });
  });
}
