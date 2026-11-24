import 'dart:async';

import 'package:az_express/services/google_routes_service.dart';
import 'package:az_express/services/maps_proxy_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Lot 1.2.1 — ces tests exerçaient le chemin Google direct (`debugDirectionsGet`),
// supprimé (plus aucun appel Google direct depuis Flutter). Même comportement
// testé (déduplication des appels concurrents, indépendance par trajet, retry
// après échec, cache), désormais via le seul chemin réseau restant : le proxy
// serveur (`MapsProxyClient.debugCall`).
void main() {
  const origin = LatLng(6.73, -3.49);
  const destination = LatLng(6.74, -3.48);

  setUp(() {
    GoogleRoutesService.debugResetCache();
    // Lot 1.2.2 — le retry existe désormais dans MapsProxyClient ; aucun
    // délai réel pendant les tests.
    MapsProxyClient.debugRetryDelay = (_) => Duration.zero;
  });
  tearDown(() {
    GoogleRoutesService.debugResetCache();
    MapsProxyClient.debugCall = null;
    MapsProxyClient.debugRetryDelay = null;
  });

  test('two identical concurrent routes share one request', () async {
    final response = Completer<Map<String, dynamic>?>();
    var requests = 0;
    MapsProxyClient.debugCall = (_, __) {
      requests++;
      return response.future;
    };

    final first = GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );
    final second = GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );

    expect(requests, 1);
    expect(identical(first, second), isTrue);
    response.complete(null); // proxy indisponible → repli local
    expect(await first, await second);
  });

  test('three identical concurrent routes share one request', () async {
    final response = Completer<Map<String, dynamic>?>();
    var requests = 0;
    MapsProxyClient.debugCall = (_, __) {
      requests++;
      return response.future;
    };

    final futures = List.generate(
      3,
      (_) => GoogleRoutesService.getRouteModel(
        origin: origin,
        destination: destination,
      ),
    );

    expect(requests, 1);
    expect(futures.skip(1).every((future) => identical(future, futures.first)),
        isTrue);
    response.complete(null);
    final routes = await Future.wait(futures);
    expect(routes.map((route) => route.distanceKm).toSet(), hasLength(1));
  });

  test('different routes remain independent', () async {
    final responses = <Completer<Map<String, dynamic>?>>[];
    MapsProxyClient.debugCall = (_, __) {
      final response = Completer<Map<String, dynamic>?>();
      responses.add(response);
      return response.future;
    };

    final first = GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );
    final second = GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: const LatLng(6.75, -3.47),
    );

    expect(responses, hasLength(2));
    for (final response in responses) {
      response.complete(null);
    }
    await Future.wait([first, second]);
  });

  test('a failed request is removed so a later request retries', () async {
    var requests = 0;
    MapsProxyClient.debugCall = (_, __) async {
      requests++;
      throw StateError('transient test failure');
    };

    await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );
    await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );

    // Lot 1.2.2 : `StateError` (ni permission-denied/unauthenticated, ni
    // FirebaseFunctionsException) est jugée transitoire et réessayée une
    // fois par MapsProxyClient.call. Chacun des deux appels à
    // getRouteModel ci-dessus épuise donc 2 tentatives (jamais plus) avant
    // de retomber sur l'estimation locale : 2 appels distincts × 2
    // tentatives = 4, pas 2 comme avant l'introduction du retry.
    expect(requests, 4);
  });

  test('a completed route keeps using the existing result cache', () async {
    var requests = 0;
    MapsProxyClient.debugCall = (_, __) async {
      requests++;
      return {
        'encodedPolyline': '??',
        'distanceMeters': 1000,
        'durationSeconds': 120,
        'isEstimate': false,
      };
    };

    final first = await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );
    final second = await GoogleRoutesService.getRouteModel(
      origin: origin,
      destination: destination,
    );

    expect(requests, 1);
    expect(second, same(first));
  });
}
