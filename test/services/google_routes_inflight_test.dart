import 'dart:async';

import 'package:az_express/services/google_routes_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

void main() {
  const origin = LatLng(6.73, -3.49);
  const destination = LatLng(6.74, -3.48);

  setUp(GoogleRoutesService.debugResetCache);
  tearDown(GoogleRoutesService.debugResetCache);

  test('two identical concurrent routes share one request', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    GoogleRoutesService.debugDirectionsGet = (_) {
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
    response.complete(http.Response('', 500));
    expect(await first, await second);
  });

  test('three identical concurrent routes share one request', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    GoogleRoutesService.debugDirectionsGet = (_) {
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
    response.complete(http.Response('', 500));
    final routes = await Future.wait(futures);
    expect(routes.map((route) => route.distanceKm).toSet(), hasLength(1));
  });

  test('different routes remain independent', () async {
    final responses = <Completer<http.Response>>[];
    GoogleRoutesService.debugDirectionsGet = (_) {
      final response = Completer<http.Response>();
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
      response.complete(http.Response('', 500));
    }
    await Future.wait([first, second]);
  });

  test('a failed request is removed so a later request retries', () async {
    var requests = 0;
    GoogleRoutesService.debugDirectionsGet = (_) async {
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

    expect(requests, 2);
  });

  test('a completed route keeps using the existing result cache', () async {
    var requests = 0;
    GoogleRoutesService.debugDirectionsGet = (_) async {
      requests++;
      return http.Response(_successResponse, 200);
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

const _successResponse = '''
{
  "status": "OK",
  "routes": [{
    "legs": [{
      "distance": {"value": 1000},
      "duration": {"value": 120}
    }],
    "overview_polyline": {"points": "??"}
  }]
}
''';
