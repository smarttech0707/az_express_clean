import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/delivery_zone_form.dart';

DeliveryZoneFormData validZone({
  String name = 'Agnibilékrou',
  String type = 'ville',
  String cityId = 'agnibilekrou',
  String? parentZoneId,
  double? lat = 7.131,
  double? lng = -3.204,
  double? radiusKm = 8,
  bool isServiceable = true,
}) {
  return DeliveryZoneFormData(
    name: name,
    type: type,
    cityId: cityId,
    parentZoneId: parentZoneId,
    aliases: const [],
    lat: lat,
    lng: lng,
    radiusKm: radiusKm,
    isServiceable: isServiceable,
    isActive: true,
    order: 0,
  );
}

void main() {
  test('génère le cityId depuis le nom normalisé', () {
    expect(
        DeliveryZoneFormData.cityIdFromName(' Agnibilékrou '), 'agnibilekrou');
  });

  test('refuse un cityId non normalisé', () {
    expect(
        validZone(cityId: 'AGNIBILÉKROU').validate(existingCityIds: const []),
        contains('normalisé'));
  });

  test('refuse un cityId de ville déjà utilisé', () {
    expect(
      validZone().validate(existingCityIds: const ['agnibilekrou']),
      contains('déjà utilisé'),
    );
  });

  test('exige un parent pour quartier, village et secteur', () {
    for (final type in ['quartier', 'village', 'secteur']) {
      expect(
        validZone(type: type).validate(existingCityIds: const []),
        contains('ville parente'),
      );
    }
  });

  test('refuse une latitude sans longitude', () {
    expect(
      validZone(lng: null, isServiceable: false)
          .validate(existingCityIds: const []),
      contains('ensemble'),
    );
  });

  test('refuse un rayon nul ou négatif', () {
    expect(
      validZone(radiusKm: 0, isServiceable: false)
          .validate(existingCityIds: const []),
      contains('supérieur à 0'),
    );
  });

  test('refuse isServiceable sans géométrie complète', () {
    expect(
      validZone(lat: null, lng: null, radiusKm: null)
          .validate(existingCityIds: const []),
      contains('point propre'),
    );
  });

  test('une saisie complète produit coordinateSource own', () {
    final zone = validZone();
    expect(zone.validate(existingCityIds: const []), isNull);
    expect(zone.coordinateSource, ZoneCoordinateSource.own);
    expect(zone.toMap()['coordinateSource'], 'own');
  });

  test('sans point coordinateSource reste unknown et radiusKm est absent', () {
    final zone = validZone(
      lat: null,
      lng: null,
      radiusKm: null,
      isServiceable: false,
    );
    expect(zone.coordinateSource, ZoneCoordinateSource.unknown);
    expect(zone.toMap()['coordinateSource'], 'unknown');
    expect(zone.toMap().containsKey('radiusKm'), isFalse);
  });
}
