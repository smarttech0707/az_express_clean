import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('l’acquisition GPS automatique ne lance aucun reverse geocoding',
      () async {
    var reverseCalls = 0;
    final place = await buildLivraisonGpsPlace(
      latitude: 7.13,
      longitude: -3.2,
      district: 'Agnibilékrou',
      resolveAddress: false,
      reverseGeocoder: (_, __) async {
        reverseCalls++;
        return 'Adresse externe';
      },
    );

    expect(reverseCalls, 0);
    expect(place.name, 'Ma position actuelle');
    expect(place.address, 'Position GPS');
  });

  test('une sélection GPS explicite peut résoudre le nom réel', () async {
    var reverseCalls = 0;
    final place = await buildLivraisonGpsPlace(
      latitude: 7.13,
      longitude: -3.2,
      district: 'Agnibilékrou',
      resolveAddress: true,
      reverseGeocoder: (_, __) async {
        reverseCalls++;
        return 'Gabriel, Agnibilékrou';
      },
    );

    expect(reverseCalls, 1);
    expect(place.name, 'Gabriel');
  });

  test('le district GPS vient de la ville active', () async {
    final provider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => const [
          DeliveryZone(
            id: 'agnibilekrou-zone',
            name: 'Agnibilékrou',
            type: 'ville',
            cityId: 'agnibilekrou',
            lat: 7.13,
            lng: -3.2,
            radiusKm: 10,
            coordinateSource: ZoneCoordinateSource.own,
            isServiceable: true,
            isActive: true,
          ),
        ],
        preferencesLoader: SharedPreferences.getInstance,
      ),
    );
    await provider.resolveGps(latitude: 7.13, longitude: -3.2);

    final district = activeLivraisonCityName(provider);
    final place = await buildLivraisonGpsPlace(
      latitude: 7.13,
      longitude: -3.2,
      district: district,
      resolveAddress: false,
    );

    expect(district, 'Agnibilékrou');
    expect(place.district, 'Agnibilékrou');
  });

  test('le district reste vide sans ville résolue', () async {
    final provider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => [],
        preferencesLoader: SharedPreferences.getInstance,
      ),
    );
    await provider.initialize();

    expect(activeLivraisonCityName(provider), isEmpty);
  });
}
