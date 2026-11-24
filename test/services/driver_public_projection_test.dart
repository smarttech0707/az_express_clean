import 'dart:io';

import 'package:az_express/services/driver_public_projection.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// SEC-01 / driver_public — Mission S4 (double écriture GPS). Tests PURS sur
/// `buildDriverPublicGpsProjection` : aucun Firestore réel, aucun plugin natif.
void main() {
  Position pos({
    double lat = 6.73,
    double lng = -3.49,
    double heading = 180.0,
    double speed = 2.5,
  }) =>
      Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: 0,
        speed: speed,
        speedAccuracy: 0,
      );

  group('mapping strict', () {
    test('position valide : exactement lat/lng/heading/speed/updatedAt, rien de plus', () {
      final data = buildDriverPublicGpsProjection(pos());
      expect(data, isNotNull);
      expect(data!.keys.toSet(), {'lat', 'lng', 'updatedAt', 'heading', 'speed'});
      expect(data['lat'], 6.73);
      expect(data['lng'], -3.49);
      expect(data['heading'], 180.0);
      expect(data['speed'], 2.5);
    });

    test('timestamp serveur : toujours FieldValue.serverTimestamp(), jamais une horloge cliente', () {
      final data = buildDriverPublicGpsProjection(pos())!;
      expect(data['updatedAt'], isA<FieldValue>());
    });
  });

  group('absence de champs sensibles', () {
    test('aucune clé hors lat/lng/heading/speed/updatedAt, quelle que soit la position', () {
      const allowed = {'lat', 'lng', 'heading', 'speed', 'updatedAt'};
      for (final p in [pos(), pos(lat: -6, lng: 100), pos(heading: 0, speed: 0)]) {
        final data = buildDriverPublicGpsProjection(p);
        if (data == null) continue;
        expect(data.keys.every(allowed.contains), isTrue, reason: '${data.keys}');
      }
    });
  });

  group('position invalide', () {
    test('latitude/longitude hors plage : aucune projection', () {
      expect(buildDriverPublicGpsProjection(pos(lat: 200)), isNull);
      expect(buildDriverPublicGpsProjection(pos(lat: -200)), isNull);
      expect(buildDriverPublicGpsProjection(pos(lng: 400)), isNull);
      expect(buildDriverPublicGpsProjection(pos(lng: -400)), isNull);
    });

    test('latitude/longitude non finies (NaN/infini) : aucune projection', () {
      expect(buildDriverPublicGpsProjection(pos(lat: double.nan)), isNull);
      expect(buildDriverPublicGpsProjection(pos(lng: double.infinity)), isNull);
    });
  });

  group('placeholder 0,0', () {
    test('lat=0,lng=0 (placeholder de création) : jamais projeté comme position réelle', () {
      expect(buildDriverPublicGpsProjection(pos(lat: 0, lng: 0)), isNull);
    });

    test('une vraie position à 0 sur un seul axe reste projetée', () {
      final data = buildDriverPublicGpsProjection(pos(lat: 0, lng: -3.49));
      expect(data, isNotNull);
      expect(data!['lat'], 0);
    });
  });

  group('heading/speed optionnels', () {
    test('heading/speed non finis : omis individuellement, le reste est projeté', () {
      final data = buildDriverPublicGpsProjection(pos(heading: double.nan, speed: double.infinity));
      expect(data, isNotNull);
      expect(data!.containsKey('heading'), isFalse);
      expect(data.containsKey('speed'), isFalse);
      expect(data['lat'], 6.73);
    });
  });

  group('écriture principale préservée (garde de source)', () {
    final svc = File('lib/services/driver_location_service.dart').readAsStringSync();

    test('la projection driver_public est appelée APRÈS la mise à jour de _lastSave, jamais avant', () {
      final mainWriteIdx = svc.indexOf("_lastSave = DateTime.now();");
      final projectionIdx = svc.indexOf('writeDriverPublicGpsProjection(');
      expect(mainWriteIdx, greaterThan(0));
      expect(projectionIdx, greaterThan(mainWriteIdx),
          reason: 'la projection ne doit jamais précéder la confirmation de l\'écriture livreurs');
    });

    test('la projection est non-bloquante (unawaited), jamais attendue par le flux principal', () {
      expect(svc, contains('unawaited(writeDriverPublicGpsProjection('));
    });

    test('la projection est appelée avec le driverId courant, jamais un autre UID', () {
      expect(svc, contains('writeDriverPublicGpsProjection(_currentDriverId!, pos)'));
    });
  });

  group('injection du writer (S4.1)', () {
    tearDown(() {
      // Toujours restaurer la vraie écriture par défaut : les groupes suivants (notamment
      // « erreur de projection isolée ») dépendent du comportement réel de production.
      driverPublicWriter = defaultDriverPublicWriter;
    });

    test('payload exact transmis : docId et données, rien de plus', () async {
      final calls = <(String, Map<String, Object?>)>[];
      driverPublicWriter = (docId, data) async => calls.add((docId, data));

      await writeDriverPublicGpsProjection('driver-42', pos());

      expect(calls, hasLength(1));
      final (docId, data) = calls.single;
      expect(docId, 'driver-42');
      expect(data.keys.toSet(), {'lat', 'lng', 'heading', 'speed', 'updatedAt'});
      expect(data['lat'], 6.73);
      expect(data['lng'], -3.49);
      expect(data['heading'], 180.0);
      expect(data['speed'], 2.5);
      expect(data['updatedAt'], isA<FieldValue>());
    });

    test('position invalide ou placeholder : le writer injecté n\'est jamais appelé', () async {
      var calls = 0;
      driverPublicWriter = (docId, data) async => calls++;

      await writeDriverPublicGpsProjection('driver-42', pos(lat: 0, lng: 0));
      await writeDriverPublicGpsProjection('driver-42', pos(lat: 200));
      await writeDriverPublicGpsProjection('driver-42', pos(lat: double.nan));

      expect(calls, 0, reason: 'le court-circuit sur position invalide reste actif avec un writer injecté');
    });

    test('writer injecté qui échoue : writeDriverPublicGpsProjection se termine quand même', () async {
      driverPublicWriter = (docId, data) async => throw StateError('échec Firestore simulé');

      await expectLater(writeDriverPublicGpsProjection('driver-42', pos()), completes);
    });

    test('writer injecté qui réussit : aucune exception, aucun effet secondaire inattendu', () async {
      var calls = 0;
      driverPublicWriter = (docId, data) async => calls++;

      await writeDriverPublicGpsProjection('driver-42', pos());

      expect(calls, 1);
    });

    test('deux positions successives : deux appels distincts avec les bonnes données', () async {
      final calls = <(String, Map<String, Object?>)>[];
      driverPublicWriter = (docId, data) async => calls.add((docId, data));

      await writeDriverPublicGpsProjection('driver-1', pos(lat: 6.1, lng: -3.1));
      await writeDriverPublicGpsProjection('driver-2', pos(lat: 6.2, lng: -3.2));

      expect(calls, hasLength(2));
      expect(calls[0].$1, 'driver-1');
      expect(calls[0].$2['lat'], 6.1);
      expect(calls[1].$1, 'driver-2');
      expect(calls[1].$2['lat'], 6.2);
    });
  });

  group('erreur de projection isolée', () {
    test('writeDriverPublicGpsProjection ne lève jamais, même sans Firebase initialisé', () async {
      // Aucun Firebase.initializeApp() dans ce test : FirebaseFirestore.instance échoue
      // nécessairement ([core/no-app]). writeDriverPublicGpsProjection doit absorber cette
      // erreur en interne (try/catch) et se terminer normalement, exactement comme un vrai
      // échec réseau ou un refus de permission le ferait en production.
      await expectLater(writeDriverPublicGpsProjection('d1', pos()), completes);
    });

    test('position invalide : aucun appel Firestore tenté (retour immédiat avant le try)', () async {
      // Même sans Firebase, ce cas ne doit jamais atteindre FirebaseFirestore.instance.
      await expectLater(writeDriverPublicGpsProjection('d1', pos(lat: 0, lng: 0)), completes);
    });
  });

  group('deux sites GPS historiques : un seul est réellement actif (garde de source)', () {
    final map = File('lib/screens/driver/driver_map.dart').readAsStringSync();

    test('driver_map.dart (jamais instancié dans l\'application) n\'a pas été modifié par S4', () {
      // DriverMap reste un écran mort (confirmé par test/services/driver_location_service_test.dart,
      // groupe « Écran de navigation et écritures », et par grep : aucun import/instanciation ailleurs
      // dans lib/). S4 ne touche donc que le site réellement actif (DriverLocationService).
      expect(map, isNot(contains('driver_public')));
      expect(map, isNot(contains('writeDriverPublicGpsProjection')));
    });
  });
}
