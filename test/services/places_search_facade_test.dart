import 'dart:convert';

import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/geo_cache_store.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingHttpClient extends http.BaseClient {
  final requests = <Uri>[];
  final bool returnGoogleResult;

  _RecordingHttpClient({this.returnGoogleResult = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final isGoogle = request.url.host == 'maps.googleapis.com';
    final body = isGoogle && returnGoogleResult
        ? jsonEncode({
            'predictions': [
              {
                'place_id': 'google-1',
                'description': 'Gabriel, Agnibilékrou',
                'structured_formatting': {
                  'main_text': 'Gabriel',
                  'secondary_text': 'Agnibilékrou',
                },
              },
            ],
          })
        : '[]';
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
    );
  }
}

DeliveryZone agnibilekrou() => const DeliveryZone(
      id: 'zone-agnibilekrou',
      name: 'Agnibilékrou',
      type: 'ville',
      cityId: 'agnibilekrou',
      lat: 7.131,
      lng: -3.204,
      radiusKm: 20,
      coordinateSource: ZoneCoordinateSource.own,
      isServiceable: true,
      isActive: true,
    );

Future<ActiveCityService> resolvedCity() async {
  final service = ActiveCityService(
    cityLoader: () async => [agnibilekrou()],
    preferencesLoader: SharedPreferences.getInstance,
  );
  await service.resolveGps(latitude: 7.131, longitude: -3.204);
  return service;
}

Future<List<LocalPlace>> noLocalResults({
  required String cityId,
  required String query,
  required LocalPlacesQueryKind kind,
}) async =>
    [];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlacesSearchService.debugResetSearchState();
    await GeoCacheStore.write('geo_cache_nominatim_v1', {});
  });

  tearDown(() {
    PlacesSearchService.debugResetSearchState();
  });

  test('Nominatim utilise le nom, le centre et le rayon de la ville active',
      () async {
    final client = _RecordingHttpClient();
    PlacesSearchService.debugSetHttpClient(client);

    await PlacesSearchService.search(
      'quartier',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    final nominatim = client.requests.single;
    expect(nominatim.host, 'nominatim.openstreetmap.org');
    expect(nominatim.queryParameters['q'], 'quartier, Agnibilékrou');
    expect(nominatim.queryParameters['viewbox'], isNot('-4.2,6.0,-2.8,7.6'));
    expect(nominatim.queryParameters['bounded'], '1');
  });

  test('Google ne part pas sans demande explicite d’élargissement', () async {
    final client = _RecordingHttpClient();
    PlacesSearchService.debugSetHttpClient(client);

    final result = await PlacesSearchService.search(
      'gabriel',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(result, isEmpty);
    expect(client.requests.map((uri) => uri.host), [
      'nominatim.openstreetmap.org',
    ]);
    expect(
      PlacesSearchService.lastSearchState,
      PlacesSearchState.awaitingExpansion,
    );
  });

  test('Google part après expansion explicite si Nominatim est vide', () async {
    final client = _RecordingHttpClient(returnGoogleResult: true);
    PlacesSearchService.debugSetHttpClient(client);

    final result = await PlacesSearchService.expandSearch(
      'gabriel',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(result.single.source, 'google');
    expect(client.requests.map((uri) => uri.host), [
      'nominatim.openstreetmap.org',
      'maps.googleapis.com',
    ]);
    expect(
      PlacesSearchService.lastSearchState,
      PlacesSearchState.expanded,
    );
  });

  test('une requête de quatre caractères n’atteint jamais Google', () async {
    final client = _RecordingHttpClient(returnGoogleResult: true);
    PlacesSearchService.debugSetHttpClient(client);

    await PlacesSearchService.expandSearch(
      'abcd',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(
      client.requests.where((uri) => uri.host == 'maps.googleapis.com'),
      isEmpty,
    );
  });

  test('les résultats Google ne sont pas persistés dans le cache disque',
      () async {
    final client = _RecordingHttpClient(returnGoogleResult: true);
    PlacesSearchService.debugSetHttpClient(client);

    await PlacesSearchService.expandSearch(
      'gabriel',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    final stored = await GeoCacheStore.read('geo_cache_nominatim_v1');
    final serialized = jsonEncode(stored);
    expect(serialized, isNot(contains('google')));
  });
}
