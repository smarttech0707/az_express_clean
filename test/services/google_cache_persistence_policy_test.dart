import 'dart:convert';

import 'package:az_express/services/google_routes_service.dart';
import 'package:az_express/services/maps_proxy_client.dart';
import 'package:az_express/services/places_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleRoutesService.debugResetCache();
    MapsProxyClient.debugCall = null;
  });
  tearDown(() {
    MapsProxyClient.debugCall = null;
  });

  test("une adresse Google n'est jamais persistée", () async {
    await PlacesService.debugReloadCaches();
    await PlacesService.debugPersistReverseEntry(
      key: '6.720_-3.490',
      address: 'Adresse Google',
      source: 'google',
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('geo_cache_reverse_v2');
    expect(raw, isNotNull);
    final stored = jsonDecode(raw!) as Map<String, dynamic>;
    // ignore: avoid_print
    print('reverse google SharedPreferences exact: $raw');
    expect(stored, isEmpty);
    expect(raw, isNot(contains('Adresse Google')));
  });

  test('une adresse Nominatim est réellement persistée', () async {
    await PlacesService.debugReloadCaches();
    await PlacesService.debugPersistReverseEntry(
      key: '6.721_-3.491',
      address: 'Adresse Nominatim',
      source: 'nominatim',
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('geo_cache_reverse_v2');
    expect(raw, isNotNull);
    final stored = jsonDecode(raw!) as Map<String, dynamic>;
    // ignore: avoid_print
    print('reverse nominatim SharedPreferences exact: $raw');
    expect(stored['6.721_-3.491'], isA<Map<String, dynamic>>());
    final entry = stored['6.721_-3.491'] as Map<String, dynamic>;
    expect(entry['address'], 'Adresse Nominatim');
    expect(entry['source'], 'nominatim');
    expect(entry['createdAt'], isA<int>());
  });

  test('Directions reste en mémoire 5 min et ne persiste aucune route',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('unrelated', 'keep-me');

    var proxyCalls = 0;
    MapsProxyClient.debugCall = (_, __) async {
      proxyCalls++;
      return {
        'encodedPolyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
        'distanceMeters': 1200,
        'durationSeconds': 600,
        'isEstimate': false,
      };
    };

    const origin = LatLng(6.7201, -3.4901);
    const destination = LatLng(6.7301, -3.4801);
    final first = await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );
    final second = await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );

    expect(proxyCalls, 1);
    expect(first.distanceKm, 1.2);
    expect(first.etaMinutes, 10);
    expect(second.distanceKm, first.distanceKm);
    expect(second.etaMinutes, first.etaMinutes);

    final allValues = <String, Object?>{
      for (final key in prefs.getKeys()) key: prefs.get(key),
    };
    // ignore: avoid_print
    print('directions SharedPreferences exact: $allValues');
    expect(allValues, {'unrelated': 'keep-me'});

    final persistedText = allValues.values.join(' ').toLowerCase();
    expect(persistedText, isNot(contains('_p~if~ps|u')));
    expect(persistedText, isNot(contains('polyline')));
    expect(persistedText, isNot(contains('distance')));
    expect(persistedText, isNot(contains('eta')));
  });

  test('le fallback local conserve une distance positive entre deux points',
      () async {
    MapsProxyClient.debugCall = (_, __) async => null;

    final route = await GoogleRoutesService.getRouteModel(
      origin: const LatLng(6.7273, -3.4961),
      destination: const LatLng(6.7373, -3.4861),
    );

    expect(route.distanceKm, greaterThan(0));
    expect(route.distanceText, isNot('0 m'));
    expect(route.isEstimate, isTrue);
  });
}
