import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeliveryZone city(String cityId) => DeliveryZone(
      id: cityId,
      name: cityId,
      type: 'ville',
      cityId: cityId,
      lat: 6.7,
      lng: -3.5,
      radiusKm: 20,
      coordinateSource: ZoneCoordinateSource.own,
      isServiceable: true,
      isActive: true,
    );

Future<ActiveCityService> cityService(String cityId) async {
  final service = ActiveCityService(
    cityLoader: () async => [city(cityId)],
    preferencesLoader: SharedPreferences.getInstance,
  );
  await service.resolveGps(latitude: 6.7, longitude: -3.5);
  return service;
}

Future<ActiveCityService> manuallySelectedCity(
  String cityId, {
  double? gpsLatitude,
  double? gpsLongitude,
}) async {
  final service = ActiveCityService(
    cityLoader: () async => [city(cityId)],
    preferencesLoader: SharedPreferences.getInstance,
  );
  if (gpsLatitude != null && gpsLongitude != null) {
    await service.resolveGps(latitude: gpsLatitude, longitude: gpsLongitude);
  }
  await service.setManualOverride(cityId);
  return service;
}

LocalPlace place({
  required String id,
  required String cityId,
  required String name,
  List<String> aliases = const [],
}) =>
    LocalPlace(
      id: id,
      name: name,
      normalizedName: LocalPlace.normalize(name),
      aliases: aliases,
      category: 'other',
      district: 'centre',
      address: name,
      latitude: 6.7,
      longitude: -3.5,
      cityId: cityId,
      verified: true,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('un match canonique P arrête après une seule requête', () async {
    final calls = <LocalPlacesQueryKind>[];
    final result = await PlacesSearchService.debugSearchLocal(
      'gabriel',
      cityService: await cityService('agnibilekrou'),
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls.add(kind);
        if (kind == LocalPlacesQueryKind.alias) {
          fail(
              'La requête A ne doit pas être lancée après un match canonique.');
        }
        return [
          place(
            id: 'gabriel',
            cityId: cityId,
            name: 'Gabriel',
          ),
        ];
      },
    );

    expect(result.single.normalizedName, 'gabriel');
    expect(calls, [LocalPlacesQueryKind.prefix]);
  });

  test('un alias exact lance A après P sans résultat', () async {
    final calls = <LocalPlacesQueryKind>[];
    final result = await PlacesSearchService.debugSearchLocal(
      'pharmacie gabriel',
      cityService: await cityService('agnibilekrou'),
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls.add(kind);
        if (kind == LocalPlacesQueryKind.prefix) return [];
        return [
          place(
            id: 'gabriel',
            cityId: cityId,
            name: 'Gabriel Santé',
            aliases: ['pharmacie gabriel'],
          ),
        ];
      },
    );

    expect(result.single.id, 'gabriel');
    expect(calls, [
      LocalPlacesQueryKind.prefix,
      LocalPlacesQueryKind.alias,
    ]);
  });

  test('aucun résultat effectue exactement P puis A', () async {
    final calls = <LocalPlacesQueryKind>[];
    final result = await PlacesSearchService.debugSearchLocal(
      'inconnu',
      cityService: await cityService('agnibilekrou'),
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls.add(kind);
        return [];
      },
    );

    expect(result, isEmpty);
    expect(calls, [
      LocalPlacesQueryKind.prefix,
      LocalPlacesQueryKind.alias,
    ]);
  });

  test('une ville absente bloque la recherche locale sans requête', () async {
    var calls = 0;
    final service = ActiveCityService(
      cityLoader: () async => [],
      preferencesLoader: SharedPreferences.getInstance,
    );

    final result = await PlacesSearchService.debugSearchLocal(
      'gabriel',
      cityService: service,
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls++;
        return [];
      },
    );

    expect(result, isEmpty);
    expect(calls, 0);
    expect(
      PlacesSearchService.lastLocalSearchStatus,
      LocalPlacesSearchStatus.cityUnavailable,
    );
  });

  test('une surcharge manuelle autorise la recherche avec GPS unknown',
      () async {
    var calls = 0;
    final service = await manuallySelectedCity('agnibilekrou');
    final result = await PlacesSearchService.debugSearchLocal(
      'gabriel',
      cityService: service,
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls++;
        return [];
      },
    );

    expect(result, isEmpty);
    expect(calls, 2);
    expect(service.cityResolutionStatus, CityResolutionStatus.unknown.value);
    expect(service.gpsDetectedCityId, isNull);
  });

  test('une surcharge manuelle autorise la recherche avec GPS outside_service',
      () async {
    var calls = 0;
    final service = await manuallySelectedCity(
      'agnibilekrou',
      gpsLatitude: 1,
      gpsLongitude: 1,
    );
    final result = await PlacesSearchService.debugSearchLocal(
      'gabriel',
      cityService: service,
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls++;
        return [];
      },
    );

    expect(result, isEmpty);
    expect(calls, 2);
    expect(
      service.cityResolutionStatus,
      CityResolutionStatus.outsideService.value,
    );
    expect(service.gpsDetectedCityId, isNull);
  });

  test('une position hors service bloque aussi la recherche locale', () async {
    var calls = 0;
    final service = ActiveCityService(
      cityLoader: () async => [city('agnibilekrou')],
      preferencesLoader: SharedPreferences.getInstance,
    );
    await service.resolveGps(latitude: 1, longitude: 1);

    final result = await PlacesSearchService.debugSearchLocal(
      'gabriel',
      cityService: service,
      queryExecutor: ({required cityId, required query, required kind}) async {
        calls++;
        return [];
      },
    );

    expect(result, isEmpty);
    expect(calls, 0);
    expect(
      PlacesSearchService.lastLocalSearchStatus,
      LocalPlacesSearchStatus.cityUnavailable,
    );
  });

  test('deux villes ne mélangent pas un quartier homonyme', () async {
    final calls = <String>[];

    Future<List<LocalPlace>> query({
      required String cityId,
      required String query,
      required LocalPlacesQueryKind kind,
    }) async {
      calls.add('$cityId:$kind');
      if (kind == LocalPlacesQueryKind.prefix) {
        return [
          place(id: cityId, cityId: cityId, name: 'Commerce'),
        ];
      }
      return [];
    }

    final agnibilekrou = await PlacesSearchService.debugSearchLocal(
      'commerce',
      cityService: await cityService('agnibilekrou'),
      queryExecutor: query,
    );
    final abengourou = await PlacesSearchService.debugSearchLocal(
      'commerce',
      cityService: await cityService('abengourou'),
      queryExecutor: query,
    );

    expect(agnibilekrou.single.cityId, 'agnibilekrou');
    expect(abengourou.single.cityId, 'abengourou');
    expect(calls, [
      'agnibilekrou:LocalPlacesQueryKind.prefix',
      'abengourou:LocalPlacesQueryKind.prefix',
    ]);
  });

  test('auto-apprentissage cloisonne la déduplication par ville', () async {
    final lookups = <String>[];
    final created = <Map<String, dynamic>>[];
    final updated = <Map<String, dynamic>>[];
    final learned = LocalPlace.fromExternal(
      name: 'Commerce',
      address: 'Commerce',
      latitude: 6.7,
      longitude: -3.5,
    );

    await PlacesSearchService.autoLearn(
      learned,
      cityService: await cityService('agnibilekrou'),
      existingPlaceLookup: ({required cityId, required normalizedName}) async {
        lookups.add('$cityId:$normalizedName');
        return place(id: 'old-agnibilekrou', cityId: cityId, name: 'Commerce');
      },
      updatePlace: (data) async => updated.add(data),
    );
    await PlacesSearchService.autoLearn(
      learned,
      cityService: await cityService('abengourou'),
      existingPlaceLookup: ({required cityId, required normalizedName}) async {
        lookups.add('$cityId:$normalizedName');
        return null;
      },
      createPlace: (data) async => created.add(data),
    );

    expect(lookups, [
      'agnibilekrou:commerce',
      'abengourou:commerce',
    ]);
    expect(updated, hasLength(1));
    expect(created, hasLength(1));
    expect(created.single['cityId'], 'abengourou');
    expect(created.single['normalizedName'], 'commerce');
    expect(created.single['verified'], false);
  });

  test('auto-apprentissage expose un échec sans lever dans le parcours',
      () async {
    final status = await PlacesSearchService.autoLearn(
      LocalPlace.fromExternal(
        name: 'Gabriel',
        address: 'Gabriel',
        latitude: 6.7,
        longitude: -3.5,
      ),
      cityService: await cityService('agnibilekrou'),
      existingPlaceLookup: ({
        required cityId,
        required normalizedName,
      }) async =>
          null,
      createPlace: (_) async => throw StateError('écriture refusée'),
    );

    expect(status, PlaceLearningStatus.failed);
  });

  test('lieux populaires filtrés par ville, vérifiés, triés et limités',
      () async {
    final service = await cityService('agnibilekrou');
    final result = await PlacesSearchService.popularPlaces(
      cityService: service,
      queryExecutor: (cityId) async => [
        for (var index = 0; index < 10; index++)
          LocalPlace(
            id: 'p$index',
            name: 'Lieu $index',
            category: 'other',
            district: '',
            address: 'Lieu $index',
            latitude: 6.7,
            longitude: -3.5,
            cityId: cityId,
            searchCount: index,
            verified: true,
          ),
        place(
          id: 'other-city',
          cityId: 'abengourou',
          name: 'Autre ville',
        ),
        LocalPlace(
          id: 'unverified',
          name: 'Non vérifié',
          category: 'other',
          district: '',
          address: 'Non vérifié',
          latitude: 6.7,
          longitude: -3.5,
          cityId: cityId,
          searchCount: 100,
          verified: false,
        ),
      ],
    );

    expect(result, hasLength(8));
    expect(result.map((item) => item.id),
        ['p9', 'p8', 'p7', 'p6', 'p5', 'p4', 'p3', 'p2']);
  });

  test('lieux populaires vides sans ville active', () async {
    var queried = false;
    final service = ActiveCityService(
      cityLoader: () async => [],
      preferencesLoader: SharedPreferences.getInstance,
    );

    final result = await PlacesSearchService.popularPlaces(
      cityService: service,
      queryExecutor: (_) async {
        queried = true;
        return [];
      },
    );

    expect(result, isEmpty);
    expect(queried, isFalse);
  });
}
