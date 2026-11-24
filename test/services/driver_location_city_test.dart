import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/driver_location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('la position GPS produit currentCityId sans reverse geocoding',
      () async {
    final service = ActiveCityService(
      cityLoader: () async => const [
        DeliveryZone(
          id: 'abengourou-zone',
          cityId: 'abengourou',
          type: 'ville',
          lat: 6.7273,
          lng: -3.4961,
          radiusKm: 25,
          coordinateSource: ZoneCoordinateSource.own,
          isServiceable: true,
          isActive: true,
        ),
      ],
    );

    final state = await service.resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );
    final fields = driverCityFields(
      currentCityId: state.gpsDetectedCityId,
      registeredCityId: 'agnibilekrou',
    );

    expect(fields, {
      'currentCityId': 'abengourou',
      'registeredCityId': 'agnibilekrou',
    });
  });

  test('registeredCityId conserve le champ explicite en priorité', () {
    expect(
      registeredDriverCityId({
        'registeredCityId': 'agnibilekrou',
        'cityId': 'abengourou',
        'city': 'Abengourou',
      }),
      'agnibilekrou',
    );
  });

  test('la ville legacy est normalisée sans inventer une ville absente', () {
    expect(
        registeredDriverCityId({'city': '  Agnibilékrou  '}), 'agnibilekrou');
    expect(registeredDriverCityId({}), isNull);
  });
}
