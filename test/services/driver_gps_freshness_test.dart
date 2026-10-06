import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_live_tracking_page.dart';
import 'package:az_express/screens/customer_tracking_screen.dart';
import 'package:az_express/services/driver_location_service.dart';

/// Fraîcheur de la position du livreur — régression du 2026-10-05.
///
/// Deux défauts prouvés en production sur une course réelle (livreur à 3 m du
/// point de récupération, donc immobile) :
///
///   a) `Timer.periodic` et la garde de `_heartbeatTick()` utilisaient la MÊME
///      durée (90 s). `_lastSave` étant affecté après l'`await` de l'écriture
///      Firestore, la garde renvoyait au tick suivant (~89,5 s < 90 s) et un
///      tick sur deux était perdu → cadence réelle mesurée 180 s, soit pile le
///      seuil `STALE_MINUTES = 3` du dispatch.
///   b) le seuil stale du client (45 s) était INFÉRIEUR à l'intervalle du
///      heartbeat → bannière affichée ~75 % du temps alors que tout
///      fonctionnait.
///
/// Aucun réseau, aucun Geolocator, aucun Firestore : seules les décisions
/// pures sont testées.
void main() {
  group('Heartbeat livreur', () {
    final maxAge = DriverLocationService.debugHeartbeatMaxAge;
    final check = DriverLocationService.debugHeartbeatCheckInterval;
    final t0 = DateTime.utc(2026, 10, 5, 15, 0, 0);

    test('le timer de contrôle est STRICTEMENT plus court que l\'âge maximal',
        () {
      // C'est l'invariant qui empêche le bug : si les deux durées sont égales,
      // la latence de l'écriture Firestore fait sauter un tick sur deux.
      expect(check, lessThan(maxAge));
      expect(check, const Duration(seconds: 30));
      expect(maxAge, const Duration(seconds: 90));
    });

    test('livreur immobile : écriture garantie entre 90 s et 120 s, jamais ~180 s',
        () {
      // Simule le timer de contrôle qui bat toutes les 30 s depuis la dernière
      // sauvegarde, en reproduisant le décalage réel : `_lastSave` est affecté
      // 500 ms APRÈS le déclenchement du tick (await de l'écriture Firestore).
      var lastSave = t0;
      DateTime? firstWrite;
      for (var tick = 1; tick <= 20; tick++) {
        final now = lastSave.add(check * tick).add(const Duration(milliseconds: -500));
        if (DriverLocationService.shouldHeartbeat(lastSave: lastSave, now: now)) {
          firstWrite = now;
          break;
        }
      }
      expect(firstWrite, isNotNull,
          reason: 'le heartbeat doit finir par écrire');
      final delay = firstWrite!.difference(lastSave);
      expect(delay, greaterThanOrEqualTo(maxAge),
          reason: 'jamais avant 90 s : pas d\'écriture inutile');
      expect(delay, lessThanOrEqualTo(maxAge + check),
          reason: 'au plus 120 s — la régression donnait 180 s');
      expect(delay.inSeconds, lessThan(180),
          reason: 'ne doit JAMAIS retomber structurellement à ~180 s');
    });

    test('sauvegarde récente : aucun heartbeat inutile', () {
      for (final age in [
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(seconds: 30),
        const Duration(seconds: 60),
        const Duration(seconds: 89, milliseconds: 500),
      ]) {
        expect(
          DriverLocationService.shouldHeartbeat(
              lastSave: t0, now: t0.add(age)),
          isFalse,
          reason: 'écriture inutile à $age',
        );
      }
    });

    test('l\'âge maximal atteint déclenche bien l\'écriture', () {
      expect(
        DriverLocationService.shouldHeartbeat(
            lastSave: t0, now: t0.add(maxAge)),
        isTrue,
      );
      expect(
        DriverLocationService.shouldHeartbeat(
            lastSave: t0, now: t0.add(maxAge + const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('une sauvegarde par mouvement repousse le prochain heartbeat', () {
      // Le livreur bouge à t+70 s : `_maybeSave` écrit et met `_lastSave` à
      // jour. Le heartbeat doit repartir de CE moment, pas de l'ancien.
      final moveSave = t0.add(const Duration(seconds: 70));
      expect(
        DriverLocationService.shouldHeartbeat(
            lastSave: moveSave, now: t0.add(const Duration(seconds: 100))),
        isFalse,
        reason: '30 s après le mouvement : pas de heartbeat',
      );
      expect(
        DriverLocationService.shouldHeartbeat(
            lastSave: moveSave, now: moveSave.add(maxAge)),
        isTrue,
        reason: '90 s après le mouvement : heartbeat',
      );
    });

    test('aucune sauvegarde encore faite : écriture immédiate', () {
      expect(
        DriverLocationService.shouldHeartbeat(lastSave: null, now: t0),
        isTrue,
      );
    });
  });

  group('Bannière « position non actualisée » (client)', () {
    final t0 = DateTime.utc(2026, 10, 5, 15, 0, 0);
    bool stale(Duration age) => isDriverPositionStale(
          hasDriver: true,
          lastUpdate: t0,
          now: t0.add(age),
        );

    test('le seuil client est STRICTEMENT supérieur à l\'âge max du heartbeat',
        () {
      // Invariant qui empêche le défaut (b) de revenir.
      expect(driverStaleThreshold,
          greaterThan(DriverLocationService.debugHeartbeatMaxAge));
      expect(
        driverStaleThreshold,
        greaterThan(DriverLocationService.debugHeartbeatMaxAge +
            DriverLocationService.debugHeartbeatCheckInterval),
        reason: 'doit couvrir le pire cas de 120 s',
      );
      expect(driverStaleThreshold, const Duration(seconds: 150));
    });

    test('pas de bannière à 45 s (ancien seuil fautif)', () {
      expect(stale(const Duration(seconds: 45)), isFalse);
      expect(stale(const Duration(seconds: 46)), isFalse);
    });

    test('pas de bannière à 90 s (heartbeat normal d\'un livreur immobile)',
        () {
      expect(stale(const Duration(seconds: 90)), isFalse);
    });

    test('pas de bannière à 120 s (pire cas du heartbeat)', () {
      expect(stale(const Duration(seconds: 120)), isFalse);
    });

    test('bannière après 150 s', () {
      expect(stale(const Duration(seconds: 150)), isFalse,
          reason: 'au seuil exact : encore frais');
      expect(stale(const Duration(seconds: 151)), isTrue);
      expect(stale(const Duration(seconds: 300)), isTrue);
    });

    test('aucun livreur assigné : jamais de bannière', () {
      expect(
        isDriverPositionStale(
            hasDriver: false, lastUpdate: t0, now: t0.add(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('position jamais reçue (sentinelle année 2000) : jamais de bannière',
        () {
      expect(
        isDriverPositionStale(
          hasDriver: true,
          lastUpdate: DateTime(2000),
          now: t0,
        ),
        isFalse,
      );
    });

    test(
        'la fraîcheur est purement informative : la dernière position connue reste exploitable',
        () {
      // `isDriverPositionStale` ne consomme ni ne modifie la position : elle ne
      // reçoit qu'un horodatage. Le marqueur est construit séparément par
      // MapMarkersBuilder, qui n'a aucune notion de fraîcheur — la dernière
      // position connue reste donc affichée quand la bannière apparaît.
      final lastKnown = DateTime.utc(2026, 10, 5, 15, 0, 0);
      final veryStale = lastKnown.add(const Duration(minutes: 30));
      expect(
        isDriverPositionStale(
            hasDriver: true, lastUpdate: lastKnown, now: veryStale),
        isTrue,
      );
      // L'horodatage d'origine est intact : rien n'est effacé ni réinitialisé.
      expect(lastKnown, DateTime.utc(2026, 10, 5, 15, 0, 0));
    });
  });

  group('Seuil « GPS inactif » (carte admin)', () {
    // Reproduit la décision de admin_live_tracking_page.dart :
    //   gpsOk = lat != null && lng != null && secsSince <= seuil
    bool gpsOk(int secsSince, {double? lat = 6.73, double? lng = -3.49}) =>
        lat != null &&
        lng != null &&
        secsSince <= adminGpsFreshnessThreshold.inSeconds;

    test('le seuil admin couvre le pire cas du heartbeat', () {
      expect(adminGpsFreshnessThreshold,
          greaterThan(DriverLocationService.debugHeartbeatMaxAge +
              DriverLocationService.debugHeartbeatCheckInterval));
      expect(adminGpsFreshnessThreshold, const Duration(seconds: 150));
    });

    test('aligné sur le seuil client — une seule vérité de fraîcheur', () {
      expect(adminGpsFreshnessThreshold, driverStaleThreshold);
    });

    test('livreur immobile mais sain : GPS considéré actif', () {
      // 60 s était l'ancien seuil fautif : un heartbeat normal (90–120 s) le
      // dépassait systématiquement.
      for (final secs in [0, 30, 59, 60, 90, 120, 150]) {
        expect(gpsOk(secs), isTrue, reason: 'secsSince=$secs doit rester actif');
      }
    });

    test('GPS réellement obsolète : marqué inactif', () {
      for (final secs in [151, 300, 9999]) {
        expect(gpsOk(secs), isFalse, reason: 'secsSince=$secs doit être inactif');
      }
    });

    test('updatedAt absent (sentinelle 9999 s) : inactif', () {
      expect(gpsOk(9999), isFalse);
    });

    test('position absente : inactif quelle que soit la fraîcheur', () {
      expect(gpsOk(10, lat: null), isFalse);
      expect(gpsOk(10, lng: null), isFalse);
    });
  });
}
