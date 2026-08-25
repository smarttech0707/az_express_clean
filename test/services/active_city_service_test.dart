import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeliveryZone city({
  required String id,
  required String cityId,
  required double lat,
  required double lng,
  double? radiusKm = 10,
  ZoneCoordinateSource coordinateSource = ZoneCoordinateSource.own,
  bool isServiceable = true,
}) =>
    DeliveryZone(
      id: id,
      name: cityId,
      type: 'ville',
      cityId: cityId,
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      coordinateSource: coordinateSource,
      isServiceable: isServiceable,
      isActive: true,
    );

final abengourou = city(
  id: 'zone-abengourou',
  cityId: 'abengourou',
  lat: 6.7273,
  lng: -3.4961,
);

final agnibilekrou = city(
  id: 'zone-agnibilekrou',
  cityId: 'agnibilekrou',
  lat: 7.131,
  lng: -3.204,
);

ActiveCityService serviceWith(List<DeliveryZone> cities) =>
    ActiveCityService(cityLoader: () async => cities);

DeliveryZone childZone({
  required String id,
  required double lat,
  required double lng,
  double? radiusKm = 2,
  ZoneCoordinateSource coordinateSource = ZoneCoordinateSource.own,
  String type = 'quartier',
}) =>
    DeliveryZone(
      id: id,
      name: id,
      type: type,
      cityId: 'abengourou',
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      coordinateSource: coordinateSource,
      isServiceable: true,
      isActive: true,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('détecte Abengourou par son disque', () async {
    final state = await serviceWith([abengourou, agnibilekrou]).resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(state.activeCityId, 'abengourou');
    expect(state.gpsDetectedCityId, 'abengourou');
    expect(state.citySelectionSource, CitySelectionSource.gps);
    expect(state.cityResolutionStatus, CityResolutionStatus.resolved);
    expect(serviceWith([abengourou]).citySelectionSource, 'gps');
  });

  test('détecte Agnibilékrou par son disque', () async {
    final state = await serviceWith([abengourou, agnibilekrou]).resolveGps(
      latitude: 7.131,
      longitude: -3.204,
    );

    expect(state.activeCityId, 'agnibilekrou');
    expect(state.cityResolutionStatus, CityResolutionStatus.resolved);
  });

  test('un point hors de toute ville est outside_service', () async {
    final service = serviceWith([abengourou, agnibilekrou]);
    final state = await service.resolveGps(
      latitude: 5,
      longitude: -5,
    );

    expect(state.activeCityId, isNull);
    expect(state.gpsDetectedCityId, isNull);
    expect(
      state.cityResolutionStatus,
      CityResolutionStatus.outsideService,
    );
    expect(service.cityResolutionStatus, 'outside_service');
  });

  test('aucune ville chargée produit unknown', () async {
    final state = await serviceWith(const []).resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(state.cityResolutionStatus, CityResolutionStatus.unknown);
    expect(state.activeCityId, isNull);
  });

  test('deux disques superposés produisent border et le ratio minimal gagne',
      () async {
    final broad = city(
      id: 'broad',
      cityId: 'broad-city',
      lat: 6.7,
      lng: -3.5,
      radiusKm: 20,
    );
    final nearest = city(
      id: 'nearest',
      cityId: 'nearest-city',
      lat: 6.72,
      lng: -3.5,
      radiusKm: 10,
    );

    final state = await serviceWith([broad, nearest]).resolveGps(
      latitude: 6.72,
      longitude: -3.5,
    );

    expect(state.cityResolutionStatus, CityResolutionStatus.border);
    expect(state.gpsDetectedCityId, 'nearest-city');
  });

  test('une zone sans rayon est ignorée', () async {
    final invalid = city(
      id: 'no-radius',
      cityId: 'no-radius-city',
      lat: 6.7273,
      lng: -3.4961,
      radiusKm: null,
    );

    final state = await serviceWith([invalid]).resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(state.cityResolutionStatus, CityResolutionStatus.outsideService);
    expect(state.gpsDetectedCityId, isNull);
  });

  test('une zone coordinateSource unknown est ignorée', () async {
    final invalid = city(
      id: 'unknown-source',
      cityId: 'unknown-source-city',
      lat: 6.7273,
      lng: -3.4961,
      coordinateSource: ZoneCoordinateSource.unknown,
    );

    final state = await serviceWith([invalid]).resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(state.cityResolutionStatus, CityResolutionStatus.outsideService);
    expect(state.gpsDetectedCityId, isNull);
  });

  test('la surcharge manuelle prime et conserve la ville GPS séparément',
      () async {
    final service = serviceWith([abengourou, agnibilekrou]);
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    final state = await service.setManualOverride('agnibilekrou');

    expect(state.activeCityId, 'agnibilekrou');
    expect(state.gpsDetectedCityId, 'abengourou');
    expect(
      state.citySelectionSource,
      CitySelectionSource.manualOverride,
    );
    expect(service.citySelectionSource, 'manual_override');
  });

  test('la surcharge est persistée puis relue dans une nouvelle session',
      () async {
    final firstSession = serviceWith([abengourou, agnibilekrou]);
    await firstSession.setManualOverride('agnibilekrou');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(ActiveCityService.manualOverridePreferenceKey),
      'agnibilekrou',
    );

    final secondSession = serviceWith([abengourou, agnibilekrou]);
    final restored = await secondSession.initialize();

    expect(restored.activeCityId, 'agnibilekrou');
    expect(
      restored.citySelectionSource,
      CitySelectionSource.manualOverride,
    );
  });

  test('le chargement des villes et la résolution sont réutilisés en session',
      () async {
    var loads = 0;
    final service = ActiveCityService(cityLoader: () async {
      loads++;
      return [abengourou];
    });

    final first = await service.resolveGps(
      latitude: 6.7273,
      longitude: -3.4961,
    );
    final second = await service.resolveGps(
      latitude: 6.7274,
      longitude: -3.4961,
    );

    expect(loads, 1);
    expect(identical(first, second), isTrue);
  });

  test('un point dans un quartier résout son zoneId', () async {
    final quartier = childZone(
      id: 'quartier-gabriel',
      lat: 6.7273,
      lng: -3.4961,
    );
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async => [quartier],
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    final resolved = await service.resolveZone(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(resolved?.id, 'quartier-gabriel');
  });

  test('un point dans la ville hors quartier conserve la ville sans zoneId',
      () async {
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async => [
        childZone(id: 'quartier-lointain', lat: 6.9, lng: -3.7),
      ],
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    final resolved = await service.resolveZone(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(service.activeCityId, 'abengourou');
    expect(resolved, isNull);
  });

  test('deux quartiers superposés choisissent le ratio distance/rayon minimal',
      () async {
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async => [
        childZone(id: 'large', lat: 6.72, lng: -3.4961, radiusKm: 4),
        childZone(id: 'petit-ratio', lat: 6.7273, lng: -3.4961),
      ],
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    final resolved = await service.resolveZone(
      latitude: 6.7273,
      longitude: -3.4961,
    );

    expect(resolved?.id, 'petit-ratio');
  });

  test('une sous-zone sans géométrie utilisable est ignorée', () async {
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async => [
        childZone(
          id: 'sans-geometrie',
          lat: 6.7273,
          lng: -3.4961,
          coordinateSource: ZoneCoordinateSource.unknown,
        ),
      ],
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    expect(
      await service.resolveZone(latitude: 6.7273, longitude: -3.4961),
      isNull,
    );
  });

  test('les sous-zones sont chargées une seule fois par ville', () async {
    var loads = 0;
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async {
        loads++;
        return [
          childZone(id: 'quartier-gabriel', lat: 6.7273, lng: -3.4961),
        ];
      },
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    await service.resolveZone(latitude: 6.7273, longitude: -3.4961);
    await service.resolveZone(latitude: 6.7274, longitude: -3.4961);

    expect(loads, 1);
  });

  test('géographie dispatch renseigne villes et zones des deux points',
      () async {
    final quartier = childZone(
      id: 'quartier-gabriel',
      lat: 6.7273,
      lng: -3.4961,
    );
    final service = ActiveCityService(
      cityLoader: () async => [abengourou],
      zoneLoader: (_) async => [quartier],
    );
    await service.resolveGps(latitude: 6.7273, longitude: -3.4961);

    final geography = await service.resolveDispatchGeography(
      pickupLatitude: 6.7273,
      pickupLongitude: -3.4961,
      deliveryLatitude: 6.7273,
      deliveryLongitude: -3.4961,
    );

    expect(geography.pickupCityId, 'abengourou');
    expect(geography.deliveryCityId, 'abengourou');
    expect(geography.pickupZoneId, 'quartier-gabriel');
    expect(geography.deliveryZoneId, 'quartier-gabriel');
    expect(geography.cityResolutionStatus, 'resolved');
  });

  test('géographie dispatch refuse 0/0', () async {
    final service = serviceWith([abengourou]);

    expect(
      () => service.resolveDispatchGeography(
        pickupLatitude: 0,
        pickupLongitude: 0,
        deliveryLatitude: 6.7273,
        deliveryLongitude: -3.4961,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
