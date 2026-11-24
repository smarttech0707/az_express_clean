import 'package:az_express/models/route_model.dart';
import 'package:az_express/services/google_routes_service.dart';
import 'package:az_express/services/maps_proxy_client.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:az_express/services/places_service.dart';
import 'package:az_express/services/tracking_service.dart';
import 'package:az_express/widgets/route_estimate_notice.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Exemple officiel de polyline encodée (3 points).
const _polyline = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

void main() {
  // Le binding de test fait répondre 400 à toute requête HTTP réelle : le
  // chemin hérité ne peut donc jamais joindre Google pendant ces tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = LatLng(6.7273, -3.4961);
  const destination = LatLng(6.74, -3.48);

  setUp(() {
    GoogleRoutesService.debugResetCache();
    MapsProxyClient.debugCall = null;
    // Lot 1.2.2 — aucun délai réel pendant les tests (le retry existe,
    // mais ne doit jamais ralentir la suite).
    MapsProxyClient.debugRetryDelay = (_) => Duration.zero;
  });
  tearDown(() {
    GoogleRoutesService.debugResetCache();
    MapsProxyClient.debugCall = null;
    MapsProxyClient.debugRetryDelay = null;
  });

  group('MapsProxyClient', () {
    test('unwrap : seul un succès explicite avec un objet data est accepté',
        () {
      expect(
        MapsProxyClient.unwrap({
          'success': true,
          'error': null,
          'message': 'ok',
          'code': 'OK',
          'data': {'a': 1},
        }),
        {'a': 1},
      );
      expect(
        MapsProxyClient.unwrap({
          'success': false,
          'code': 'UPSTREAM_UNAVAILABLE',
          'data': null,
        }),
        isNull,
      );
      expect(MapsProxyClient.unwrap({'success': true, 'data': null}), isNull);
      expect(MapsProxyClient.unwrap({'success': 'true', 'data': {}}), isNull);
      expect(MapsProxyClient.unwrap({'data': {}}), isNull);
      expect(MapsProxyClient.unwrap('texte'), isNull);
      expect(MapsProxyClient.unwrap(null), isNull);
    });

    test('sans Firebase initialisé : indisponible, aucune exception',
        () async {
      final result = await MapsProxyClient.call(MapsProxyClient.route, {});
      expect(result.hasData, isFalse);
      expect(result.outcome, MapsProxyOutcome.unavailable);
      expect(result.data, isNull);
    });

    test('une exception du transport devient "indisponible"', () async {
      MapsProxyClient.debugCall = (_, __) async => throw StateError('réseau');
      final result = await MapsProxyClient.call(MapsProxyClient.geocode, {});
      expect(result.hasData, isFalse);
      expect(result.outcome, MapsProxyOutcome.unavailable);
    });

    test(
        'une FirebaseFunctionsException permission-denied/unauthenticated '
        'devient "refusé" : jamais indisponible', () async {
      for (final code in ['permission-denied', 'unauthenticated']) {
        MapsProxyClient.debugCall = (_, __) async =>
            throw FirebaseFunctionsException(code: code, message: 'refus');
        final result = await MapsProxyClient.call(MapsProxyClient.route, {});
        expect(result.hasData, isFalse, reason: code);
        expect(result.outcome, MapsProxyOutcome.denied, reason: code);
      }
    });

    test(
        'unavailable / deadline-exceeded / internal / resource-exhausted / '
        'code inconnu : jamais un refus, toujours "indisponible"', () async {
      for (final code in [
        'unavailable',
        'deadline-exceeded',
        'internal',
        'resource-exhausted',
        'un-code-jamais-vu',
      ]) {
        MapsProxyClient.debugCall = (_, __) async =>
            throw FirebaseFunctionsException(code: code, message: 'panne');
        final result = await MapsProxyClient.call(MapsProxyClient.route, {});
        expect(result.hasData, isFalse, reason: code);
        expect(result.outcome, MapsProxyOutcome.unavailable, reason: code);
      }
    });
  });

  group('Retry (Lot 1.2.2) — au plus deux tentatives, jamais vers Google',
      () {
    test('1. succès dès la première tentative : un seul appel', () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        return {'results': <Map<String, dynamic>>[]};
      };
      final result = await MapsProxyClient.call(MapsProxyClient.geocode, {});
      expect(calls, 1);
      expect(result.hasData, isTrue);
    });

    test('2. une erreur temporaire puis un succès : deux appels, data finale',
        () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        if (calls == 1) {
          throw FirebaseFunctionsException(code: 'unavailable', message: 'x');
        }
        return {'results': <Map<String, dynamic>>[]};
      };
      final result = await MapsProxyClient.call(MapsProxyClient.geocode, {});
      expect(calls, 2);
      expect(result.hasData, isTrue);
    });

    test('3. deux erreurs temporaires : arrêt après deux tentatives, jamais 3',
        () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        throw FirebaseFunctionsException(code: 'deadline-exceeded', message: 'x');
      };
      final result = await MapsProxyClient.call(MapsProxyClient.route, {});
      expect(calls, 2);
      expect(result.hasData, isFalse);
      expect(result.outcome, MapsProxyOutcome.unavailable);
    });

    test('4. permission-denied : aucune nouvelle tentative', () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        throw FirebaseFunctionsException(code: 'permission-denied', message: 'x');
      };
      final result = await MapsProxyClient.call(MapsProxyClient.route, {});
      expect(calls, 1);
      expect(result.outcome, MapsProxyOutcome.denied);
    });

    test('5. unauthenticated : aucune nouvelle tentative', () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        throw FirebaseFunctionsException(code: 'unauthenticated', message: 'x');
      };
      final result = await MapsProxyClient.call(MapsProxyClient.route, {});
      expect(calls, 1);
      expect(result.outcome, MapsProxyOutcome.denied);
    });

    test(
        '6. erreur de validation (refus métier sans exception) : '
        'aucune nouvelle tentative', () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        return null; // simule {success:false, code:'INVALID_ARGUMENT'}
      };
      final result = await MapsProxyClient.call(MapsProxyClient.route, {});
      expect(calls, 1);
      expect(result.outcome, MapsProxyOutcome.unavailable);
    });

    test(
        '7. internal / resource-exhausted : non réessayables, '
        'un seul appel chacun', () async {
      for (final code in ['internal', 'resource-exhausted']) {
        var calls = 0;
        MapsProxyClient.debugCall = (_, __) async {
          calls++;
          throw FirebaseFunctionsException(code: code, message: 'x');
        };
        final result = await MapsProxyClient.call(MapsProxyClient.route, {});
        expect(calls, 1, reason: code);
        expect(result.outcome, MapsProxyOutcome.unavailable, reason: code);
      }
    });

    test(
        '8. respect du timeout global : le retry est sauté si le budget '
        'restant est insuffisant après la 1ʳᵉ tentative', () async {
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        // Consomme la quasi-totalité du budget avant d'échouer.
        await Future<void>.delayed(const Duration(milliseconds: 45));
        throw FirebaseFunctionsException(code: 'unavailable', message: 'x');
      };
      final result = await MapsProxyClient.call(
        MapsProxyClient.route,
        {},
        timeout: const Duration(milliseconds: 50),
      );
      expect(calls, 1, reason: 'pas assez de budget restant pour retenter');
      expect(result.outcome, MapsProxyOutcome.unavailable);
    });

    test(
        '9. aucun appel HTTP Google direct même après épuisement des deux '
        'tentatives (itinéraire)', () async {
      MapsProxyClient.debugCall = (_, __) async =>
          throw FirebaseFunctionsException(code: 'unavailable', message: 'x');
      // Le binding de test fait échouer toute requête HTTP réelle (voir
      // TestWidgetsFlutterBinding.ensureInitialized ci-dessus) : si un appel
      // Google direct avait lieu, getRouteModel lèverait ou échouerait
      // autrement qu'en renvoyant une estimation propre.
      final route = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      expect(route.isEstimate, isTrue);
      expect(route.points, isNotEmpty);
    });

    test(
        '10. solutions locales et estimation maintenues après épuisement '
        'des deux tentatives, de façon cohérente sur plusieurs trajets',
        () async {
      MapsProxyClient.debugCall = (_, __) async =>
          throw FirebaseFunctionsException(code: 'unavailable', message: 'x');
      final a = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      final b = await GoogleRoutesService.getRouteModel(
          origin: destination, destination: origin);
      for (final route in [a, b]) {
        expect(route.isEstimate, isTrue);
        expect(route.distanceKm, greaterThan(0));
        expect(route.etaMinutes, RouteModel.estimateEta(route.distanceKm));
        expect(route.estimatedPrice, RouteModel.estimatePrice(route.distanceKm));
      }
    });
  });

  group('Itinéraire : réel contre estimation', () {
    test('réponse du proxy : itinéraire réel, sans drapeau d\'estimation',
        () async {
      final calls = <Map<String, dynamic>>[];
      MapsProxyClient.debugCall = (name, payload) async {
        expect(name, MapsProxyClient.route);
        calls.add(payload);
        return {
          'encodedPolyline': _polyline,
          'distanceMeters': 2345,
          'durationSeconds': 412,
          'withTraffic': false,
          'isEstimate': false,
        };
      };

      final route = await GoogleRoutesService.getRouteModel(
        origin: origin,
        destination: destination,
      );

      expect(route.isEstimate, isFalse);
      expect(route.points, hasLength(3));
      expect(route.distanceKm, closeTo(2.345, 1e-9));
      expect(route.etaMinutes, 7); // 412 s arrondis à la minute supérieure
      expect(calls.single['origin'], {'lat': 6.7273, 'lng': -3.4961});
      expect(calls.single['destination'], {'lat': 6.74, 'lng': -3.48});
      expect(calls.single['withTraffic'], isFalse);
      expect(calls.single.containsKey('key'), isFalse);
    });

    test('itinéraire réel mis en cache : un seul appel au proxy', () async {
      var requests = 0;
      MapsProxyClient.debugCall = (_, __) async {
        requests++;
        return {
          'encodedPolyline': _polyline,
          'distanceMeters': 1000,
          'durationSeconds': 120,
          'isEstimate': false,
        };
      };

      final first = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      final second = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);

      expect(requests, 1);
      expect(second, same(first));
    });

    test('proxy indisponible : ligne droite marquée estimation, non cachée',
        () async {
      var requests = 0;
      MapsProxyClient.debugCall = (_, __) async {
        requests++;
        return null;
      };

      final route = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);

      expect(route.isEstimate, isTrue);
      expect(route.points, hasLength(21));
      expect(route.distanceKm, greaterThan(0));
      expect(route.etaMinutes, RouteModel.estimateEta(route.distanceKm));
      // Une estimation n'est jamais mise en cache : le proxy est redemandé.
      expect(requests, 2);
    });

    test('réponse du proxy incomplète ou douteuse : refusée', () {
      Map<String, dynamic> base() => {
            'encodedPolyline': _polyline,
            'distanceMeters': 1000,
            'durationSeconds': 120,
            'isEstimate': false,
          };
      expect(GoogleRoutesService.routeFromProxyData(base()), isNotNull);
      expect(
          GoogleRoutesService.routeFromProxyData(
              base()..remove('encodedPolyline')),
          isNull);
      expect(
          GoogleRoutesService.routeFromProxyData(
              base()..['encodedPolyline'] = ''),
          isNull);
      expect(
          GoogleRoutesService.routeFromProxyData(
              base()..['distanceMeters'] = '1000'),
          isNull);
      expect(
          GoogleRoutesService.routeFromProxyData(
              base()..remove('durationSeconds')),
          isNull);
      // Sans confirmation explicite du serveur, pas d'itinéraire « réel ».
      expect(
          GoogleRoutesService.routeFromProxyData(base()..remove('isEstimate')),
          isNull);
      expect(
          GoogleRoutesService.routeFromProxyData(base()..['isEstimate'] = true),
          isNull);
    });

    test('RouteModel : estimation fausse par défaut, conservée par copyWith',
        () {
      expect(RouteModel.empty().isEstimate, isFalse);
      final estimate = RouteModel.empty().copyWith(isEstimate: true);
      expect(estimate.isEstimate, isTrue);
      expect(estimate.copyWith(distanceKm: 2).isEstimate, isTrue);
    });

    test('TrackingState : drapeau d\'estimation faux par défaut', () {
      const state = TrackingState(clientPosition: origin);
      expect(state.routeIsEstimate, isFalse);
      expect(state.copyWith(routeIsEstimate: true).routeIsEstimate, isTrue);
      expect(
          state
              .copyWith(routeIsEstimate: true)
              .copyWith(routeLoading: true)
              .routeIsEstimate,
          isTrue);
    });
  });

  group('Recherche et géocodage par le proxy', () {
    test('suggestions converties comme le chemin hérité', () {
      final places = PlacesSearchService.placesFromProxyPredictions({
        'predictions': [
          {
            'placeId': 'ChIJ_place_0001',
            'mainText': 'Marché central',
            'secondaryText': 'Abengourou, Côte d\'Ivoire',
            'description': 'Marché central, Abengourou',
          },
          {'placeId': '', 'mainText': 'ignoré'},
          {'placeId': 'ChIJ_place_0002', 'mainText': ''},
          'texte',
          {'placeId': 'ChIJ_place_0003', 'mainText': 'Gare routière'},
        ],
      })!;

      expect(places, hasLength(2));
      expect(places.first.id, 'ChIJ_place_0001');
      expect(places.first.name, 'Marché central');
      expect(places.first.address, 'Marché central, Abengourou');
      expect(places.first.district, 'Abengourou');
      expect(places.first.source, 'google');
      expect(places.first.hasCoords, isFalse);
      expect(places.last.address, 'Gare routière');
    });

    test('suggestions absentes ou mal formées : proxy considéré indisponible',
        () {
      expect(PlacesSearchService.placesFromProxyPredictions({}), isNull);
      expect(
          PlacesSearchService.placesFromProxyPredictions(
              {'predictions': 'x'}),
          isNull);
      expect(
          PlacesSearchService.placesFromProxyPredictions({'predictions': []}),
          isEmpty);
    });

    test('point du proxy : coordonnées valides seulement', () {
      final point = PlacesSearchService.pointFromProxyResult(
          {'lat': 6.73, 'lng': -3.49, 'formattedAddress': 'Abengourou'})!;
      expect(point.position, const LatLng(6.73, -3.49));
      expect(point.formattedAddress, 'Abengourou');
      expect(
          PlacesSearchService.pointFromProxyResult({'lat': 6.73, 'lng': -3.49})!
              .formattedAddress,
          '');
      expect(
          PlacesSearchService.pointFromProxyResult({'lat': 0, 'lng': 0}), isNull);
      expect(
          PlacesSearchService.pointFromProxyResult({'lat': '6.7', 'lng': -3.4}),
          isNull);
      expect(PlacesSearchService.pointFromProxyResult(null), isNull);
    });

    test('géocodage inverse : première adresse non vide', () {
      expect(
        PlacesService.addressFromProxyData({
          'results': [
            {'lat': 6.7, 'lng': -3.4, 'formattedAddress': '  '},
            {'lat': 6.7, 'lng': -3.4, 'formattedAddress': 'Rue A, Abengourou'},
          ],
        }),
        'Rue A, Abengourou',
      );
      expect(PlacesService.addressFromProxyData({'results': []}), isNull);
      expect(PlacesService.addressFromProxyData({}), isNull);
      expect(PlacesService.addressFromProxyData(null), isNull);
    });
  });

  group('Mention d\'estimation', () {
    Future<void> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(20),
            child: RouteEstimateNotice(),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('message explicite, lisible par les lecteurs d\'écran',
        (tester) async {
      await pump(tester, 360);
      expect(find.text(RouteEstimateNotice.message), findsOneWidget);
      expect(find.bySemanticsLabel(RouteEstimateNotice.message), findsOneWidget);
      expect(RouteEstimateNotice.message, contains('Estimation'));
    });

    testWidgets('aucun débordement à 320 px', (tester) async {
      await pump(tester, 320);
      expect(tester.takeException(), isNull);
    });
  });
}
