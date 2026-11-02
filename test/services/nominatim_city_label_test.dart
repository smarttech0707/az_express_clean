import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Régression : en préproduction la zone s'appelle « Abengourou (TEST) » et la
/// requête Nominatim `q=hopital, Abengourou (TEST)` renvoie 0 résultat alors que
/// `q=hopital, Abengourou` en renvoie 1 (mêmes viewbox et paramètres, HTTP 200).

DeliveryZone _zone(String name) => DeliveryZone(
      id: 'abengourou-test',
      name: name,
      type: 'ville',
      cityId: 'abengourou',
      lat: 6.7273,
      lng: -3.4961,
      radiusKm: 8,
      coordinateSource: ZoneCoordinateSource.own,
      isServiceable: true,
      isActive: true,
    );

Future<ActiveCityService> _service(String name) async {
  final service = ActiveCityService(
    cityLoader: () async => [_zone(name)],
    preferencesLoader: SharedPreferences.getInstance,
  );
  await service.resolveGps(latitude: 6.7273, longitude: -3.4961);
  return service;
}

Future<List<LocalPlace>> _noLocal({
  required String cityId,
  required String query,
  required LocalPlacesQueryKind kind,
}) async =>
    const [];

const _hospital =
    '[{"osm_id":1,"name":"Hôpital PMI","display_name":"Hôpital PMI, Abengourou",'
    '"lat":"6.73","lon":"-3.49","type":"hospital","class":"amenity","address":{}}]';

void main() {
  late List<Uri> requests;

  /// Simule le serveur réel : ne trouve rien si la requête contient « (TEST) ».
  void serve({int status = 200, String? body, Object? error}) {
    PlacesSearchService.debugSetHttpClient(MockClient((request) async {
      requests.add(request.url);
      if (error != null) throw error;
      if (body != null) return http.Response(body, status);
      final q = request.url.queryParameters['q'] ?? '';
      return http.Response(q.contains('(TEST)') ? '[]' : _hospital, status);
    }));
  }

  setUp(() {
    requests = [];
    SharedPreferences.setMockInitialValues({});
    PlacesSearchService.debugResetSearchState();
  });

  group('libellé de ville envoyé à Nominatim', () {
    test('retire la décoration entre parenthèses ou crochets', () {
      expect(PlacesSearchService.nominatimCityLabel('Abengourou (TEST)'),
          'Abengourou');
      expect(PlacesSearchService.nominatimCityLabel('Abengourou [démo]  '),
          'Abengourou');
      expect(PlacesSearchService.nominatimCityLabel('Abengourou  &   environs'),
          'Abengourou & environs');
    });

    test('un nom ordinaire reste inchangé', () {
      expect(PlacesSearchService.nominatimCityLabel('Abengourou'), 'Abengourou');
      expect(PlacesSearchService.nominatimCityLabel('Agnibilékrou'),
          'Agnibilékrou');
    });

    test('jamais de libellé vide : repli sur le nom d\'origine', () {
      expect(PlacesSearchService.nominatimCityLabel('(TEST)'), '(TEST)');
    });
  });

  group('recherche Nominatim avec une zone « Abengourou (TEST) »', () {
    test('la requête envoyée ne contient plus « (TEST) » et renvoie le lieu',
        () async {
      serve();
      final results = await PlacesSearchService.search('hopital',
          cityService: await _service('Abengourou (TEST)'),
          queryExecutor: _noLocal);
      expect(requests, hasLength(1));
      final params = requests.single.queryParameters;
      expect(params['q'], 'hopital, Abengourou');
      expect(params['bounded'], '1');
      expect(params['countrycodes'], 'ci');
      expect(results.map((p) => p.name), contains('Hôpital PMI'));
      expect(PlacesSearchService.lastSearchState,
          PlacesSearchState.externalResults);
      expect(PlacesSearchService.lastNominatimDiagnostic!.outcome,
          NominatimOutcome.ok);
    });

    test('même résultat avec une zone sans décoration', () async {
      serve();
      final results = await PlacesSearchService.search('hopital',
          cityService: await _service('Abengourou'), queryExecutor: _noLocal);
      expect(requests.single.queryParameters['q'], 'hopital, Abengourou');
      expect(results, isNotEmpty);
    });

    test('le User-Agent et la zone bornée sont conservés', () async {
      PlacesSearchService.debugSetHttpClient(MockClient((request) async {
        requests.add(request.url);
        expect(request.headers['User-Agent'], 'AZExpress/1.0');
        return http.Response(_hospital, 200);
      }));
      await PlacesSearchService.search('hopital',
          cityService: await _service('Abengourou (TEST)'),
          queryExecutor: _noLocal);
      final box = requests.single.queryParameters['viewbox']!.split(',');
      expect(box, hasLength(4));
      expect(double.parse(box[0]), lessThan(-3.4961));
      expect(double.parse(box[2]), greaterThan(-3.4961));
    });
  });

  group('parcours Google : même normalisation du nom de ville', () {
    test('autocomplétion après « Élargir la recherche »', () async {
      final googleInputs = <String>[];
      PlacesSearchService.debugSetHttpClient(MockClient((request) async {
        if (request.url.host == 'nominatim.openstreetmap.org') {
          return http.Response('[]', 200);
        }
        googleInputs.add(request.url.queryParameters['input'] ?? '');
        return http.Response('{"predictions":[]}', 200);
      }));
      await PlacesSearchService.search('hopital',
          cityService: await _service('Abengourou (TEST)'),
          expandSearch: true,
          queryExecutor: _noLocal);
      expect(googleInputs, ['hopital, Abengourou, Côte d\'Ivoire']);
    });

    test('géocodage d\'un lieu sans coordonnées (resolve)', () async {
      final addresses = <String>[];
      PlacesSearchService.debugSetHttpClient(MockClient((request) async {
        addresses.add(request.url.queryParameters['address'] ?? '');
        return http.Response('{"results":[]}', 200);
      }));
      await PlacesSearchService.resolve(
        LocalPlace(
          id: 'g1',
          name: 'Marché',
          address: 'Marché',
          latitude: 0,
          longitude: 0,
          category: 'other',
          district: 'centre',
          source: 'google',
        ),
        cityService: await _service('Abengourou (TEST)'),
      );
      expect(addresses, ['Marché, Abengourou, Côte d\'Ivoire']);
    });
  });

  group('diagnostic : les causes d\'une liste vide sont distinguables', () {
    Future<NominatimDiagnostic?> diagnose({
      int status = 200,
      String? body,
      Object? error,
    }) async {
      serve(status: status, body: body, error: error);
      final results = await PlacesSearchService.search('hopital',
          cityService: await _service('Abengourou'), queryExecutor: _noLocal);
      expect(results, isEmpty);
      return PlacesSearchService.lastNominatimDiagnostic;
    }

    test('aucune réponse utile du serveur', () async {
      final d = await diagnose(body: '[]');
      expect(d!.outcome, NominatimOutcome.noResults);
      expect(d.httpStatus, 200);
      expect(d.rawCount, 0);
    });

    test('erreur HTTP (limitation, blocage)', () async {
      final d = await diagnose(status: 429, body: 'trop de requêtes');
      expect(d!.outcome, NominatimOutcome.httpError);
      expect(d.httpStatus, 429);
    });

    test('réponse JSON invalide', () async {
      final d = await diagnose(body: '<html>bloqué</html>');
      expect(d!.outcome, NominatimOutcome.invalidResponse);
    });

    test('réponse JSON qui n\'est pas une liste', () async {
      final d = await diagnose(body: '{"error":"x"}');
      expect(d!.outcome, NominatimOutcome.invalidResponse);
    });

    test('résultats tous écartés par le filtrage (sans coordonnées)', () async {
      final d = await diagnose(
          body:
              '[{"osm_id":2,"name":"Sans coordonnées","display_name":"x","lat":"","lon":"","type":"x","class":"x"}]');
      expect(d!.outcome, NominatimOutcome.allFilteredOut);
      expect(d.rawCount, 1);
      expect(d.keptCount, 0);
    });

    test('erreur réseau', () async {
      final d = await diagnose(error: http.ClientException('hors ligne'));
      expect(d!.outcome, NominatimOutcome.network);
    });

    test('le diagnostic ne contient aucun texte recherché', () async {
      final d = await diagnose(body: '[]');
      expect(d.toString().toLowerCase().contains('hopital'), isFalse);
      expect(d.toString().toLowerCase().contains('abengourou'), isFalse);
    });
  });
}
