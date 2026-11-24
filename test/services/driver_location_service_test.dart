import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:az_express/services/driver_location_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// Mission M2.7 (guideline Apple 2.5.4) : service de premier plan Android jamais lancé sur iOS, localisation
/// arrière-plan iOS limitée à une livraison en cours, jamais deux abonnements GPS. Aucun réseau, Firestore ni plugin natif.
void main() {
  final service = DriverLocationService.instance;
  late List<LocationSettings> requested;
  late int active;
  late int starterCalls;
  late int stopperCalls;

  setUp(() async {
    requested = [];
    active = 0;
    starterCalls = 0;
    stopperCalls = 0;
    service.positionStreamFactory = (settings) {
      requested.add(settings);
      late StreamController<Position> controller;
      controller = StreamController<Position>(
        onListen: () => active++,
        onCancel: () => active--,
      );
      return controller.stream;
    };
    service.foregroundServiceStarter = () async => starterCalls++;
    service.foregroundServiceStopper = () async => stopperCalls++;
    await service.stopTracking();
    await service.setDeliveryActive(false);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await service.stopTracking();
    await service.setDeliveryActive(false);
  });

  bool background(LocationSettings s) =>
      s is AppleSettings && s.allowBackgroundLocationUpdates;
  bool indicator(LocationSettings s) =>
      s is AppleSettings && s.showBackgroundLocationIndicator;

  group('Politique par plateforme', () {
    test('service de premier plan : Android seulement', () {
      for (final p in TargetPlatform.values) {
        expect(
          DriverLocationService.usesAndroidForegroundService(
              isWeb: false, platform: p),
          p == TargetPlatform.android,
          reason: '$p',
        );
      }
      expect(
        DriverLocationService.usesAndroidForegroundService(
            isWeb: true, platform: TargetPlatform.android),
        isFalse,
      );
    });

    test('arrière-plan : iOS et livraison active seulement', () {
      for (final p in TargetPlatform.values) {
        for (final delivery in [false, true]) {
          expect(
            DriverLocationService.allowsBackgroundLocation(
                isWeb: false, platform: p, deliveryActive: delivery),
            p == TargetPlatform.iOS && delivery,
            reason: '$p livraison=$delivery',
          );
        }
      }
    });

    test('réglages iOS : sans livraison, ni arrière-plan ni pastille bleue', () {
      final s = DriverLocationService.streamSettings(
          isWeb: false, platform: TargetPlatform.iOS, deliveryActive: false);
      expect(s, isA<AppleSettings>());
      expect(background(s), isFalse);
      expect(indicator(s), isFalse);
    });

    test('réglages iOS : en livraison, arrière-plan et pastille bleue', () {
      final s = DriverLocationService.streamSettings(
          isWeb: false, platform: TargetPlatform.iOS, deliveryActive: true);
      expect(background(s), isTrue);
      expect(indicator(s), isTrue);
      expect((s as AppleSettings).pauseLocationUpdatesAutomatically, isFalse);
    });

    test('réglages Android : inchangés, indépendants de la livraison', () {
      for (final delivery in [false, true]) {
        final s = DriverLocationService.streamSettings(
            isWeb: false,
            platform: TargetPlatform.android,
            deliveryActive: delivery);
        expect(s, isNot(isA<AppleSettings>()));
        expect(s.accuracy, LocationAccuracy.high);
        expect(s.distanceFilter, 50);
      }
    });
  });

  group('Service de premier plan', () {
    test('iOS : jamais lancé', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await service.debugEnsureForegroundService();
      await service.debugEnsureForegroundService();
      expect(starterCalls, 0);
      expect(service.debugForegroundStarted, isFalse);
    });

    test('Android : lancé une seule fois puis arrêté avec le suivi', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await service.debugEnsureForegroundService();
      await service.debugEnsureForegroundService();
      expect(starterCalls, 1);
      expect(service.debugForegroundStarted, isTrue);
      await service.stopTracking();
      expect(stopperCalls, 1);
      expect(service.debugForegroundStarted, isFalse);
    });

    test('Android : un échec du service n\'est pas bloquant', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      service.foregroundServiceStarter = () async => throw StateError('refus');
      await service.debugEnsureForegroundService();
      expect(service.debugForegroundStarted, isFalse);
    });
  });

  group('Suivi iOS selon la livraison', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('ouverture du suivi (tableau de bord) : pas d\'arrière-plan', () async {
      await service.debugAttach('d1');
      expect(active, 1);
      expect(requested, hasLength(1));
      expect(background(requested.single), isFalse);
      expect(service.backgroundLocationActive, isFalse);
    });

    test('début de livraison : flux recréé en arrière-plan, un seul abonnement',
        () async {
      await service.debugAttach('d1');
      await service.setDeliveryActive(true);
      expect(active, 1);
      expect(requested, hasLength(2));
      expect(background(requested.last), isTrue);
      expect(indicator(requested.last), isTrue);
      expect(service.backgroundLocationActive, isTrue);
    });

    test('fin ou annulation : retour au premier plan, un seul abonnement',
        () async {
      await service.debugAttach('d1');
      await service.setDeliveryActive(true);
      await service.setDeliveryActive(false);
      expect(active, 1);
      expect(background(requested.last), isFalse);
      expect(service.backgroundLocationActive, isFalse);
    });

    test('même état répété : aucun nouvel abonnement', () async {
      await service.debugAttach('d1');
      await service.setDeliveryActive(true);
      await service.setDeliveryActive(true);
      await service.setDeliveryActive(false);
      await service.setDeliveryActive(false);
      expect(requested, hasLength(3));
      expect(active, 1);
    });

    test('bascules simultanées : jamais plus d\'un abonnement', () async {
      await service.debugAttach('d1');
      await Future.wait([
        service.setDeliveryActive(true),
        service.setDeliveryActive(false),
        service.setDeliveryActive(true),
      ]);
      expect(active, 1);
      expect(service.backgroundLocationActive, isTrue);
    });

    test('arrêt du suivi : plus aucun abonnement ni arrière-plan', () async {
      await service.debugAttach('d1');
      await service.setDeliveryActive(true);
      await service.stopTracking();
      expect(active, 0);
      expect(service.backgroundLocationActive, isFalse);
    });

    test('livraison signalée sans flux : appliquée au prochain démarrage',
        () async {
      await service.setDeliveryActive(true);
      expect(active, 0);
      await service.debugAttach('d1');
      expect(background(requested.single), isTrue);
    });

    test('livraison signalée pendant l\'arrêt : aucun flux fantôme', () async {
      await service.debugAttach('d1');
      final pending = service.setDeliveryActive(true);
      await service.stopTracking();
      await pending;
      expect(active, 0);
    });
  });

  group('Suivi Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('la livraison ne recrée pas le flux (comportement actuel conservé)',
        () async {
      await service.debugAttach('d1');
      await service.setDeliveryActive(true);
      await service.setDeliveryActive(false);
      expect(requested, hasLength(1));
      expect(active, 1);
      expect(service.backgroundLocationActive, isFalse);
    });
  });

  group('Tableau de bord livreur (garde de source)', () {
    final source =
        File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();

    test('n\'active jamais lui-même l\'arrière-plan', () {
      expect(source.contains('allowBackgroundLocationUpdates'), isFalse);
      expect(source.contains('showBackgroundLocationIndicator'), isFalse);
    });

    test('l\'état de livraison vient uniquement de la commande active', () {
      final calls = RegExp(r'setDeliveryActive\(([^)]*)\)').allMatches(source);
      final args = calls.map((m) => m.group(1)!.replaceAll(RegExp(r'\s+'), ''));
      expect(args, containsAll(['order!=null', 'false']));
      expect(args.length, 2);
      expect(source.contains('driverActiveOrder(widget.driverId).listen'),
          isTrue);
    });

    test('le flux de livraison est fermé à la sortie', () {
      expect(source.contains('_deliverySub?.cancel()'), isTrue);
    });
  });

  group('Bail de précision', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    int filter(LocationSettings s) => s.distanceFilter;

    test('sans bail : 50 m ; un bail : 5 m sur le même flux', () async {
      await service.debugAttach('d1');
      expect(filter(requested.single), 50);
      final lease = service.acquirePrecisionLease();
      await lease.applied;
      expect(active, 1);
      expect(requested, hasLength(2));
      expect(filter(requested.last), 5);
      expect(service.fineLocationActive, isTrue);
    });

    test('plusieurs baux : un seul abonnement, un seul changement de flux',
        () async {
      await service.debugAttach('d1');
      final a = service.acquirePrecisionLease();
      final b = service.acquirePrecisionLease();
      final c = service.acquirePrecisionLease();
      await Future.wait([a.applied, b.applied, c.applied]);
      expect(active, 1);
      expect(requested, hasLength(2)); // flux initial + passage à 5 m, pas un par bail
      expect(service.debugLeaseCount, 3);
    });

    test('libérer un bail ne modifie pas les autres ; le dernier rétablit 50 m',
        () async {
      await service.debugAttach('d1');
      final a = service.acquirePrecisionLease();
      final b = service.acquirePrecisionLease();
      await a.applied;
      await service.releasePrecisionLease(a);
      expect(requested, hasLength(2), reason: 'b est toujours actif : aucun nouveau flux');
      expect(service.fineLocationActive, isTrue);
      expect(service.debugLeaseCount, 1);
      await service.releasePrecisionLease(b);
      expect(requested, hasLength(3));
      expect(filter(requested.last), 50);
      expect(service.fineLocationActive, isFalse);
      expect(active, 1);
    });

    test('double libération : sans effet, sans toucher aux autres baux',
        () async {
      await service.debugAttach('d1');
      final a = service.acquirePrecisionLease();
      final b = service.acquirePrecisionLease();
      await service.releasePrecisionLease(a);
      await service.releasePrecisionLease(a);
      await service.releasePrecisionLease(a);
      expect(service.debugLeaseCount, 1);
      expect(service.fineLocationActive, isTrue);
      await service.releasePrecisionLease(b);
      await service.releasePrecisionLease(b);
      expect(service.debugLeaseCount, 0);
      expect(active, 1);
    });

    test('bail demandé sans flux actif : appliqué au prochain démarrage',
        () async {
      final lease = service.acquirePrecisionLease();
      await lease.applied;
      expect(active, 0);
      expect(requested, isEmpty);
      await service.debugAttach('d1');
      expect(filter(requested.single), 5);
    });

    test('arrêt du suivi : tous les baux effacés, libération tardive inoffensive',
        () async {
      await service.debugAttach('d1');
      final a = service.acquirePrecisionLease();
      final b = service.acquirePrecisionLease();
      await service.stopTracking();
      expect(service.debugLeaseCount, 0);
      expect(active, 0);
      await service.releasePrecisionLease(a);
      await service.releasePrecisionLease(b);
      expect(active, 0);
      await service.debugAttach('d1');
      expect(filter(requested.last), 50, reason: 'plus aucun bail après l\'arrêt');
    });

    test('bascules simultanées : jamais plus d\'un abonnement', () async {
      await service.debugAttach('d1');
      final leases = <PrecisionLease>[];
      await Future.wait([
        for (var i = 0; i < 6; i++)
          Future(() async {
            final l = service.acquirePrecisionLease();
            leases.add(l);
            if (i.isEven) await service.releasePrecisionLease(l);
          }),
        service.setDeliveryActive(true),
        service.setDeliveryActive(false),
      ]);
      expect(active, 1);
      expect(service.debugLeaseCount, 3);
      for (final l in leases) {
        await service.releasePrecisionLease(l);
      }
      expect(service.debugLeaseCount, 0);
      expect(active, 1);
      expect(filter(requested.last), 50);
    });

    test('quatre combinaisons iOS : le bail ne donne jamais l\'arrière-plan',
        () async {
      for (final delivery in [false, true]) {
        for (final lease in [false, true]) {
          await service.stopTracking();
          await service.setDeliveryActive(false);
          requested.clear();
          await service.setDeliveryActive(delivery);
          final l = lease ? service.acquirePrecisionLease() : null;
          await service.debugAttach('d1');
          final s = requested.last;
          expect(s, isA<AppleSettings>());
          expect(filter(s), lease ? 5 : 50, reason: 'livraison=$delivery bail=$lease');
          expect(background(s), delivery, reason: 'livraison=$delivery bail=$lease');
          expect(indicator(s), delivery, reason: 'livraison=$delivery bail=$lease');
          expect(active, 1);
          if (l != null) await service.releasePrecisionLease(l);
        }
      }
    });

    test('bail pris puis livraison : l\'arrière-plan vient de la livraison seule',
        () async {
      await service.debugAttach('d1');
      final lease = service.acquirePrecisionLease();
      await lease.applied;
      expect(background(requested.last), isFalse);
      await service.setDeliveryActive(true);
      expect(background(requested.last), isTrue);
      expect(filter(requested.last), 5);
      await service.setDeliveryActive(false);
      expect(background(requested.last), isFalse);
      expect(filter(requested.last), 5);
      expect(active, 1);
    });
  });

  group('Bail de précision sur Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('réglages Android : 5 m sous bail, 50 m sinon, jamais d\'AppleSettings',
        () async {
      await service.debugAttach('d1');
      expect(requested.last.distanceFilter, 50);
      final lease = service.acquirePrecisionLease();
      await lease.applied;
      expect(requested.last, isNot(isA<AppleSettings>()));
      expect(requested.last.distanceFilter, 5);
      await service.releasePrecisionLease(lease);
      expect(requested.last.distanceFilter, 50);
      expect(active, 1);
    });

    test('le service de premier plan n\'est jamais redémarré par un bail',
        () async {
      await service.debugEnsureForegroundService();
      expect(starterCalls, 1);
      await service.debugAttach('d1');
      final a = service.acquirePrecisionLease();
      final b = service.acquirePrecisionLease();
      await a.applied;
      await service.releasePrecisionLease(a);
      await service.releasePrecisionLease(b);
      await service.setDeliveryActive(true);
      await service.setDeliveryActive(false);
      expect(starterCalls, 1);
      expect(stopperCalls, 0);
      expect(service.debugForegroundStarted, isTrue);
    });
  });

  group('FinePrecisionScope (écran de navigation)', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('acquire / release idempotents : un seul bail à la fois', () async {
      final scope = FinePrecisionScope(service);
      scope.acquire();
      scope.acquire();
      expect(service.debugLeaseCount, 1);
      await scope.release();
      await scope.release();
      expect(service.debugLeaseCount, 0);
      expect(scope.isActive, isFalse);
    });

    test('cycle de vie : rendu en arrière-plan, repris au retour, inactive ignoré',
        () async {
      final scope = FinePrecisionScope(service);
      await service.debugAttach('d1');
      scope.acquire();
      scope.onLifecycle(AppLifecycleState.inactive);
      expect(service.debugLeaseCount, 1);
      scope.onLifecycle(AppLifecycleState.hidden);
      expect(service.debugLeaseCount, 0);
      scope.onLifecycle(AppLifecycleState.paused);
      scope.onLifecycle(AppLifecycleState.detached);
      expect(service.debugLeaseCount, 0);
      scope.onLifecycle(AppLifecycleState.resumed);
      scope.onLifecycle(AppLifecycleState.resumed);
      expect(service.debugLeaseCount, 1);
      await scope.release();
      expect(service.debugLeaseCount, 0);
      await Future<void>.delayed(Duration.zero);
      expect(active, 1);
    });

    test('fermeture après un passage en arrière-plan : aucune fuite', () async {
      final scope = FinePrecisionScope(service);
      scope.acquire();
      scope.onLifecycle(AppLifecycleState.paused);
      await scope.release(); // dispose()
      expect(service.debugLeaseCount, 0);
    });

    test('deux écrans : la fermeture de l\'un laisse l\'autre en précision fine',
        () async {
      final one = FinePrecisionScope(service);
      final two = FinePrecisionScope(service);
      await service.debugAttach('d1');
      one.acquire();
      two.acquire();
      await one.release();
      expect(service.fineLocationActive, isTrue);
      await two.release();
      expect(service.fineLocationActive, isFalse);
      expect(active, 1);
    });
  });

  group('Écran de navigation et écritures (gardes de source)', () {
    final screen = File('lib/screens/driver_tracking_screen.dart').readAsStringSync();
    final svc = File('lib/services/driver_location_service.dart').readAsStringSync();

    test('DriverTrackingScreen demande, suit le cycle de vie et libère son bail',
        () {
      expect(screen, contains('final FinePrecisionScope _precision = FinePrecisionScope();'));
      expect(RegExp(r'_precision\.acquire\(\)').allMatches(screen).length, 1);
      expect(RegExp(r'_precision\.release\(\)').allMatches(screen).length, 1);
      expect(screen, contains('_precision.onLifecycle(state);'));
      final dispose = screen.substring(screen.indexOf('void dispose()'));
      expect(dispose, contains('_precision.release();'));
    });

    test('seul le service ouvre un flux GPS parmi les écrans actifs', () {
      final users = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.readAsStringSync().contains('getPositionStream(')) {
          users.add(f.path.replaceAll('\\', '/'));
        }
      }
      users.sort();
      // DriverMap (jamais instancié) est conservé tel quel ; aucun nouvel appel ne doit apparaître.
      expect(users, ['lib/screens/driver/driver_map.dart', 'lib/services/driver_location_service.dart']);
    });

    test('écritures Firestore inchangées : 5 s, 15 m, heartbeat 90 s / 30 s, champs GPS et géohash', () {
      expect(svc, contains('static const _minSaveInterval = Duration(seconds: 5);'));
      expect(svc, contains('static const _minDistanceMeters = 15.0;'));
      expect(svc, contains('static const _heartbeatMaxAge = Duration(seconds: 90);'));
      expect(svc, contains('static const _heartbeatCheckInterval = Duration(seconds: 30);'));
      for (final field in ["'lat': pos.latitude", "'lng': pos.longitude", "'position': geo.data", "'updatedAt': FieldValue.serverTimestamp()"]) {
        expect(svc, contains(field));
      }
      expect(DriverLocationService.normalDistanceFilter, 50);
      expect(DriverLocationService.fineDistanceFilter, 5);
    });
  });

  group('SEC-01 / S5.1 — consolidation de la déconnexion (gardes de source)', () {
    final profil = File('lib/screens/driver/driver_profil.dart').readAsStringSync();

    test('la déconnexion manuelle ne réécrit plus isOnline directement', () {
      final dialog = profil.substring(profil.indexOf('_showSignOutDialog'));
      expect(dialog, isNot(contains('"isOnline": false')));
      expect(dialog, isNot(contains("'isOnline': false")));
    });

    test('la déconnexion manuelle passe par la source unique goOffline()', () {
      final dialog = profil.substring(profil.indexOf('_showSignOutDialog'));
      expect(dialog, contains('DriverLocationService.instance'));
      expect(dialog, contains('.goOffline(widget.driverId)'));
      expect(profil, contains("import '../../services/driver_location_service.dart';"));
    });

    test('la déconnexion ne touche à aucun autre statut serveur protégé', () {
      final dialog = profil.substring(profil.indexOf('_showSignOutDialog'),
          profil.indexOf('@override\n  Widget build'));
      for (final forbidden in [
        'isAvailable',
        'isOnDelivery',
        'isSuspended',
        'avgRating',
        'ratingCount',
      ]) {
        expect(dialog.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });

  group('SEC-01 / S5.1 — goOffline() : comportement réel', () {
    test(
        'arrête un flux GPS actif puis tente l\'écriture isOnline:false sans jamais lever, '
        'même sans Firebase initialisé', () async {
      await service.debugAttach('d1');
      expect(active, 1);

      await expectLater(service.goOffline('d1'), completes);

      expect(active, 0, reason: 'goOffline doit fermer le flux GPS, pas seulement écrire isOnline');
    });

    test('idempotent : aucun flux actif à arrêter, ne lève toujours pas', () async {
      await expectLater(service.goOffline('d1'), completes);
      expect(active, 0);
    });
  });
}
