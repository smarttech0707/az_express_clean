import 'dart:convert';

import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/geo_cache_store.dart';
import 'package:az_express/services/maps_proxy_client.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Lot 1.2.1 — Google ne répond plus jamais via un appel HTTP direct : ce
// client ne simule plus que Nominatim (sans clé, inchangé). La réponse
// Google éventuelle est désormais simulée via `MapsProxyClient.debugCall`.
class _RecordingHttpClient extends http.BaseClient {
  final requests = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode('[]')),
      200,
      request: request,
    );
  }
}

/// Installe (ou retire, si `null`) un proxy qui renvoie une suggestion
/// "Gabriel, Agnibilékrou" pour mapsAutocompleteCF ; enregistre chaque appel.
void _setGoogleProxy(List<String> calls, {required bool returnResult}) {
  MapsProxyClient.debugCall = (name, payload) async {
    calls.add(name);
    if (!returnResult) return null;
    return {
      'predictions': [
        {
          'placeId': 'google-1',
          'mainText': 'Gabriel',
          'secondaryText': 'Agnibilékrou',
          'description': 'Gabriel, Agnibilékrou',
        },
      ],
    };
  };
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
    MapsProxyClient.debugCall = null;
  });

  tearDown(() {
    PlacesSearchService.debugResetSearchState();
    MapsProxyClient.debugCall = null;
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
    final proxyCalls = <String>[];
    _setGoogleProxy(proxyCalls, returnResult: true);

    final result = await PlacesSearchService.search(
      'gabriel',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(result, isEmpty);
    expect(client.requests.map((uri) => uri.host), [
      'nominatim.openstreetmap.org',
    ]);
    expect(proxyCalls, isEmpty, reason: 'le proxy Maps ne doit pas être sollicité');
    expect(
      PlacesSearchService.lastSearchState,
      PlacesSearchState.awaitingExpansion,
    );
  });

  test('Google part après expansion explicite si Nominatim est vide', () async {
    final client = _RecordingHttpClient();
    PlacesSearchService.debugSetHttpClient(client);
    final proxyCalls = <String>[];
    _setGoogleProxy(proxyCalls, returnResult: true);

    final result = await PlacesSearchService.expandSearch(
      'gabriel',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(result.single.source, 'google');
    expect(client.requests.map((uri) => uri.host), [
      'nominatim.openstreetmap.org',
    ]);
    expect(proxyCalls, [MapsProxyClient.autocomplete]);
    expect(
      PlacesSearchService.lastSearchState,
      PlacesSearchState.expanded,
    );
  });

  test('une requête de quatre caractères n’atteint jamais Google', () async {
    final client = _RecordingHttpClient();
    PlacesSearchService.debugSetHttpClient(client);
    final proxyCalls = <String>[];
    _setGoogleProxy(proxyCalls, returnResult: true);

    await PlacesSearchService.expandSearch(
      'abcd',
      cityService: await resolvedCity(),
      queryExecutor: noLocalResults,
    );

    expect(proxyCalls, isEmpty);
  });

  test('les résultats Google ne sont pas persistés dans le cache disque',
      () async {
    final client = _RecordingHttpClient();
    PlacesSearchService.debugSetHttpClient(client);
    final proxyCalls = <String>[];
    _setGoogleProxy(proxyCalls, returnResult: true);

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
