import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeliveryZone city(String cityId, {double lat = 6.7297, double lng = -3.4964}) =>
    DeliveryZone(
      id: cityId,
      name: cityId,
      type: 'ville',
      cityId: cityId,
      lat: lat,
      lng: lng,
      radiusKm: 30,
      coordinateSource: ZoneCoordinateSource.own,
      isServiceable: true,
      isActive: true,
    );

LocalPlace place(String id, String name,
        {String cityId = 'abengourou',
        List<String> aliases = const [],
        int searchCount = 0}) =>
    LocalPlace(
      id: id,
      name: name,
      category: 'other',
      district: 'centre',
      address: name,
      latitude: 6.73,
      longitude: -3.49,
      cityId: cityId,
      aliases: aliases,
      searchCount: searchCount,
      verified: true,
    );

final abengourouPlaces = [
  place('1', 'École Château'),
  place('2', 'Maternité Cafétou'),
  place('3', 'Mosquée de Cafétou'),
  place('4', 'Cafétou Boutique Jumeaux', searchCount: 9),
  place('5', 'Grand Marché Abengourou'),
  place('6', 'Mairie Abengourou'),
];

/// Ville inconnue : aucun GPS résolu (permission refusée, délai, hors zone).
Future<ActiveCityService> unresolvedService() async {
  final service = ActiveCityService(
    cityLoader: () async => [city('abengourou'), city('agnibilekrou')],
    preferencesLoader: SharedPreferences.getInstance,
  );
  await service.initialize();
  return service;
}

Future<List<LocalPlace>> noLocalQuery({
  required String cityId,
  required String query,
  required LocalPlacesQueryKind kind,
}) async =>
    const [];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlacesSearchService.debugResetSearchState();
  });

  group('placesMatchingWords', () {
    List<String> names(String q) =>
        placesMatchingWords(abengourouPlaces, LocalPlace.normalize(q))
            .map((p) => p.name)
            .toList();

    test('Château retrouve École Château', () {
      expect(names('Château'), ['École Château']);
    });

    test('Cafétou retrouve tous les lieux de Cafétou, le plus utilisé d\'abord',
        () {
      expect(names('Cafétou'), [
        'Cafétou Boutique Jumeaux',
        'Maternité Cafétou',
        'Mosquée de Cafétou',
      ]);
    });

    test('Grand marché retrouve Grand Marché Abengourou', () {
      expect(names('Grand marché'), ['Grand Marché Abengourou']);
    });

    test('tous les mots doivent correspondre', () {
      expect(names('grand mairie'), isEmpty);
    });

    test('le début d\'un mot suffit, pas le milieu', () {
      expect(names('chat'), ['École Château']);
      expect(names('teau'), isEmpty);
    });

    test('les alias comptent', () {
      final found = placesMatchingWords(
        [
          place('9', 'Gare routière', aliases: ['garage nord'])
        ],
        'nord',
      );
      expect(found, hasLength(1));
    });

    test('requête vide : aucun résultat', () {
      expect(placesMatchingWords(abengourouPlaces, '  '), isEmpty);
    });
  });

  group('recherche avec ville inconnue ou choisie', () {
    late List<String> externalCalls;

    setUp(() {
      externalCalls = [];
      PlacesSearchService.debugSetHttpClient(MockClient((request) async {
        externalCalls.add(request.url.host);
        return http.Response('[]', 200);
      }));
    });

    test('sans ville choisie : aucun résultat, aucun appel externe', () async {
      final results = await PlacesSearchService.search(
        'château',
        cityService: await unresolvedService(),
        queryExecutor: noLocalQuery,
      );
      expect(results, isEmpty);
      expect(PlacesSearchService.lastSearchState,
          PlacesSearchState.cityUnavailable);
      expect(externalCalls, isEmpty);
    });

    test('avec une ville choisie : Château retrouve École Château', () async {
      PlacesSearchService.debugSetCityPlacesLoader((cityId) async =>
          cityId == 'abengourou' ? abengourouPlaces : const []);
      final service = await unresolvedService();
      final results = await PlacesSearchService.search(
        'château',
        cityService: service,
        queryExecutor: noLocalQuery,
        contextCityId: 'abengourou',
      );
      expect(results.map((p) => p.name), ['École Château']);
      // Le choix cadre la recherche mais ne devient jamais la ville active :
      // zones desservies, tarifs et dispatch restent inchangés.
      expect(service.activeCityId, isNull);
      expect(service.hasUsableActiveCity, isFalse);
    });

    test('Cafétou et Grand marché sont retrouvés dans la ville choisie',
        () async {
      PlacesSearchService.debugSetCityPlacesLoader(
          (_) async => abengourouPlaces);
      final service = await unresolvedService();
      final cafetou = await PlacesSearchService.search('Cafétou',
          cityService: service,
          queryExecutor: noLocalQuery,
          contextCityId: 'abengourou');
      expect(cafetou.map((p) => p.name), contains('Maternité Cafétou'));
      final marche = await PlacesSearchService.search('Grand marché',
          cityService: service,
          queryExecutor: noLocalQuery,
          contextCityId: 'abengourou');
      expect(marche.map((p) => p.name), contains('Grand Marché Abengourou'));
    });

    test('une ville hors des villes actives ne peut pas servir de contexte',
        () async {
      PlacesSearchService.debugSetCityPlacesLoader(
          (_) async => abengourouPlaces);
      final results = await PlacesSearchService.search(
        'château',
        cityService: await unresolvedService(),
        queryExecutor: noLocalQuery,
        contextCityId: 'bouake',
      );
      expect(results, isEmpty);
      expect(PlacesSearchService.lastSearchState,
          PlacesSearchState.cityUnavailable);
    });

    test('un GPS résolu garde la priorité sur la ville choisie', () async {
      final asked = <String>[];
      PlacesSearchService.debugSetCityPlacesLoader((cityId) async {
        asked.add(cityId);
        return const [];
      });
      final service = ActiveCityService(
        cityLoader: () async => [
          city('abengourou'),
          city('agnibilekrou', lat: 7.1289, lng: -3.2044),
        ],
        preferencesLoader: SharedPreferences.getInstance,
      );
      await service.resolveGps(latitude: 7.1289, longitude: -3.2044);
      await PlacesSearchService.search(
        'château',
        cityService: service,
        queryExecutor: noLocalQuery,
        contextCityId: 'abengourou',
      );
      expect(asked, ['agnibilekrou']);
    });

    test('les lieux de la ville sont lus une seule fois (cache)', () async {
      var loads = 0;
      PlacesSearchService.debugSetCityPlacesLoader((_) async {
        loads++;
        return abengourouPlaces;
      });
      final service = await unresolvedService();
      for (final q in ['château', 'cafétou', 'grand marché']) {
        await PlacesSearchService.search(q,
            cityService: service,
            queryExecutor: noLocalQuery,
            contextCityId: 'abengourou');
      }
      expect(loads, 1);
    });

    test('assez de lieux locaux : aucun appel Nominatim ni Google', () async {
      PlacesSearchService.debugSetCityPlacesLoader((_) async => [
            for (var i = 0; i < 6; i++) place('h$i', 'Hôtel Numéro $i'),
          ]);
      final results = await PlacesSearchService.search(
        'hôtel',
        cityService: await unresolvedService(),
        queryExecutor: noLocalQuery,
        contextCityId: 'abengourou',
      );
      expect(results, hasLength(6));
      expect(externalCalls, isEmpty);
    });

    test('échec du chargement des lieux : aucune exception, repli externe',
        () async {
      PlacesSearchService.debugSetCityPlacesLoader(
          (_) async => throw Exception('hors ligne'));
      final results = await PlacesSearchService.search(
        'château',
        cityService: await unresolvedService(),
        queryExecutor: noLocalQuery,
        contextCityId: 'abengourou',
      );
      expect(results, isEmpty);
      expect(externalCalls, ['nominatim.openstreetmap.org']);
    });

    test('la ville choisie sert aussi aux lieux populaires', () async {
      String? asked;
      final places = await PlacesSearchService.popularPlaces(
        cityService: await unresolvedService(),
        contextCityId: 'agnibilekrou',
        queryExecutor: (cityId) async {
          asked = cityId;
          return [place('a', 'Gabriel', cityId: cityId)];
        },
      );
      expect(asked, 'agnibilekrou');
      expect(places, hasLength(1));
    });
  });
}
