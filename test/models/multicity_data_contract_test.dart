import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalisation unique', () {
    test('normalise casse, accents et préfixe incomplet', () {
      expect(LocalPlace.normalize('Agnibilékrou'), 'agnibilekrou');
      expect(LocalPlace.normalize('Agnibilekrou'), 'agnibilekrou');
      expect(LocalPlace.normalize('AGNIBILEKROU'), 'agnibilekrou');
      expect(LocalPlace.normalize('agnibilekro'), 'agnibilekro');
      expect(LocalPlace.normalize('Lycée moderne'), 'lycee moderne');
    });

    test('uniformise apostrophes, tirets et espaces multiples', () {
      expect(LocalPlace.normalize("  Château-d'Eau  "), 'chateau d eau');
      expect(LocalPlace.normalize('Château–d’Eau'), 'chateau d eau');
      expect(LocalPlace.normalize('Lycée   moderne'), 'lycee moderne');
    });
  });

  group('DeliveryZone legacy', () {
    test('tolère un document sans les nouveaux champs', () {
      final zone = DeliveryZone.fromMap('legacy', {
        'name': 'Commerce',
        'type': 'quartier',
        'parentName': 'Abengourou',
        'isActive': true,
        'order': 1,
      });

      expect(zone.cityId, isNull);
      expect(zone.parentZoneId, isNull);
      expect(zone.normalizedName, isNull);
      expect(zone.effectiveNormalizedName, 'commerce');
      expect(zone.aliases, isEmpty);
      expect(zone.lat, isNull);
      expect(zone.lng, isNull);
      expect(zone.radiusKm, isNull);
      expect(zone.coordinateSource, ZoneCoordinateSource.unknown);
      expect(zone.isServiceable, isFalse);
    });

    test('géométrie own valide et desservable', () {
      const zone = DeliveryZone(
        id: 'valid',
        lat: 7.131,
        lng: -3.204,
        radiusKm: 8,
        coordinateSource: ZoneCoordinateSource.own,
        isServiceable: true,
      );
      expect(zone.hasUsableGeometry, isTrue);
    });

    test('géométrie own sans rayon', () {
      const zone = DeliveryZone(
        id: 'no-radius',
        lat: 7.131,
        lng: -3.204,
        coordinateSource: ZoneCoordinateSource.own,
        isServiceable: true,
      );
      expect(zone.hasUsableGeometry, isFalse);
    });

    test('géométrie inherited', () {
      const zone = DeliveryZone(
        id: 'inherited',
        lat: 7.131,
        lng: -3.204,
        radiusKm: 8,
        coordinateSource: ZoneCoordinateSource.inherited,
        isServiceable: true,
      );
      expect(zone.hasUsableGeometry, isFalse);
    });

    test('géométrie unknown', () {
      const zone = DeliveryZone(
        id: 'unknown',
        lat: 7.131,
        lng: -3.204,
        radiusKm: 8,
        isServiceable: true,
      );
      expect(zone.hasUsableGeometry, isFalse);
    });
  });

  test('LocalPlace lit un document legacy et sérialise les nouveaux champs',
      () {
    final place = LocalPlace.fromMap('legacy-place', {
      'name': 'Lycée moderne',
      'latitude': 7.13,
      'longitude': -3.2,
      'verified': false,
    });

    expect(place.cityId, isNull);
    expect(place.normalizedName, 'lycee moderne');
    expect(place.aliases, isEmpty);
    expect(place.keywords, isEmpty);
    expect(place.verified, isFalse);

    final serialized = place.toMap();
    expect(serialized.containsKey('cityId'), isFalse);
    expect(serialized['normalizedName'], 'lycee moderne');
    expect(serialized['aliases'], isEmpty);
    expect(serialized['nameSearch'], 'lycee moderne');
    expect(serialized['verified'], isFalse);
  });
}
