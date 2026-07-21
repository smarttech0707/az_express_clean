import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geoflutterfire_plus/geoflutterfire_plus.dart';
import 'package:geolocator/geolocator.dart';

/// État du suivi GPS — utilisé par l'UI pour afficher le bon indicateur.
enum GpsTrackingState {
  active,
  permissionDenied,
  permanentlyDenied,
  error,
}

/// Point d'entrée du ForegroundTask — doit être au top-level pour @pragma.
@pragma('vm:entry-point')
void azTrackingCallback() {
  FlutterForegroundTask.setTaskHandler(_AzKeepAliveHandler());
}

class _AzKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Service singleton de localisation GPS pour le livreur.
///
/// - Expose [positionStream] (broadcast) — écran carte s'y abonne en lecture seule.
/// - Écrit dans Firestore avec double throttle : 5 s ET 15 m minimum entre deux saves.
/// - Lance un [ForegroundService] Android pour survivre au verrouillage écran / OEM killers.
class DriverLocationService {
  static DriverLocationService? _instance;
  static DriverLocationService get instance =>
      _instance ??= DriverLocationService._();
  DriverLocationService._();

  // ── Stream broadcast partagé ──────────────────────────────────────────────
  final _posCtrl = StreamController<Position>.broadcast();

  /// Stream de positions GPS — lecture seule pour l'UI.
  Stream<Position> get positionStream => _posCtrl.stream;

  // ── État GPS ───────────────────────────────────────────────────────────────
  GpsTrackingState _gpsState = GpsTrackingState.error;
  GpsTrackingState get gpsState => _gpsState;

  // ── Internes ───────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _positionSub;
  Timer?    _heartbeatTimer;
  String?   _currentDriverId;
  DateTime? _lastSave;
  Position? _lastSavedPos;
  String    _fcmToken = '';
  bool      _foregroundStarted = false;

  static const _minSaveInterval   = Duration(seconds: 5);
  static const _minDistanceMeters = 15.0;
  // Master Prompt 129 — cause racine confirmée du dispatch silencieusement
  // cassé pour un livreur stationnaire : le double throttle (temps ET
  // distance) n'avait aucune limite haute pour la distance. Un livreur qui
  // ne bouge pas de plus de 15 m ne déclenchait donc plus JAMAIS
  // `_saveToFirestore()` après sa première position — `updatedAt` restait
  // figé indéfiniment, alors même que l'app reste ouverte et le GPS actif.
  // Côté serveur, `functions/dispatch.js` exclut tout livreur dont
  // `updatedAt` dépasse `STALE_MINUTES = 3` — un livreur en attente d'une
  // course (donc typiquement à l'arrêt) devenait invisible au dispatch
  // après seulement 3 minutes, sans qu'aucun signal ne le révèle ni côté
  // livreur ni côté admin. Marge de 90 s sous ce seuil de 3 min.
  //
  // Correctif du 2026-07-19 (audit E2E réel en production) : le premier
  // correctif ci-dessus plaçait ce heartbeat DANS `_maybeSave()`, appelée
  // uniquement depuis le callback du stream de position — donc seulement
  // quand l'OS émet un NOUVEL événement GPS. Avec `distanceFilter: 50`, un
  // livreur véritablement stationnaire (le cas le plus courant en attente
  // d'une course) ne déclenche jamais un nouvel événement, donc le
  // heartbeat ne s'exécutait jamais non plus — le bug réapparaissait
  // silencieusement dans le cas exact qu'il devait corriger. Preuve directe :
  // test de bout en bout réel (device physique, vrai livreur approuvé,
  // dashboard ouvert et immobile) — `updatedAt` figé à la position initiale
  // après 4m27s, `dispatchOrderToDriver` renvoyant `dispatched:false` par
  // exclusion `staleGps` alors que le livreur était réellement en ligne.
  // Corrigé en rendant le heartbeat véritablement périodique (`Timer.periodic`
  // indépendant, démarré dans `startTracking()`), qui réécrit la dernière
  // position connue à intervalle fixe qu'un nouvel événement GPS soit
  // survenu ou non.
  static const _heartbeatInterval = Duration(seconds: 90);

  // ── Démarrage du tracking ──────────────────────────────────────────────────

  Future<GpsTrackingState> startTracking(String driverId) async {
    // Déjà actif pour ce driver — ne pas redémarrer
    if (_currentDriverId == driverId && _gpsState == GpsTrackingState.active) {
      return GpsTrackingState.active;
    }

    await _stopStream();
    _currentDriverId = driverId;

    // ── Permissions ──────────────────────────────────────────────────────────
    final perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever) {
      _gpsState = GpsTrackingState.permanentlyDenied;
      return _gpsState;
    }
    if (perm == LocationPermission.denied) {
      _gpsState = GpsTrackingState.permissionDenied;
      return _gpsState;
    }

    // ── ForegroundService Android ────────────────────────────────────────────
    await _ensureForegroundService();

    // ── Token FCM ────────────────────────────────────────────────────────────
    try {
      _fcmToken = await FirebaseMessaging.instance.getToken() ?? '';
    } catch (_) {}

    // ── Position initiale immédiate ──────────────────────────────────────────
    try {
      final init = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _emit(init);
      await _saveToFirestore(init);
    } catch (_) {}

    // ── Stream continu ───────────────────────────────────────────────────────
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 50, // mètres — throttle Firestore 15m, hausse 10→50m pour réduire écrits GPS
      ),
    ).listen(
      (pos) {
        _emit(pos);
        _maybeSave(pos);
      },
      onError: (_) {
        _gpsState = GpsTrackingState.error;
        _positionSub?.cancel();
        _positionSub = null;
      },
    );

    // Heartbeat véritablement périodique — indépendant du stream de
    // position, garantit une écriture au moins toutes les
    // `_heartbeatInterval`, même si le livreur ne bouge jamais assez pour
    // qu'un nouvel événement GPS n'arrive (voir commentaire du 2026-07-19
    // ci-dessus).
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _heartbeatTick());

    _gpsState = GpsTrackingState.active;
    return _gpsState;
  }

  Future<void> _heartbeatTick() async {
    if (_currentDriverId == null || _lastSavedPos == null) return;
    // Ne réécrit que si aucune sauvegarde "naturelle" (mouvement réel) n'a
    // déjà eu lieu depuis le dernier tick — évite une écriture en double
    // juste après une vraie mise à jour de position.
    if (_lastSave != null &&
        DateTime.now().difference(_lastSave!) < _heartbeatInterval) {
      return;
    }
    await _saveToFirestore(_lastSavedPos!);
  }

  // ── Reprise automatique (C4 — retour depuis background) ───────────────────

  Future<void> resumeIfNeeded() async {
    if (_currentDriverId == null) return;
    if (_gpsState == GpsTrackingState.active && _positionSub != null) return;
    await startTracking(_currentDriverId!);
  }

  // ── Arrêt propre ──────────────────────────────────────────────────────────

  Future<void> stopTracking() async {
    await _stopStream();
    _currentDriverId = null;
    _lastSave        = null;
    _lastSavedPos    = null;
    _gpsState        = GpsTrackingState.error;
    await _stopForegroundService();
  }

  Future<void> goOffline(String driverId) async {
    await stopTracking();
    try {
      await FirebaseFirestore.instance
          .collection('livreurs')
          .doc(driverId)
          .update({'isOnline': false});
    } catch (_) {}
  }

  // ── Écriture Firestore avec double throttle ────────────────────────────────

  Future<void> _maybeSave(Position pos) async {
    final now = DateTime.now();

    // Throttle temporel
    if (_lastSave != null && now.difference(_lastSave!) < _minSaveInterval) return;

    // Throttle distance (évite d'écrire si livreur ne bouge pas) — la
    // fraîcheur de `updatedAt` en l'absence de mouvement est désormais
    // garantie séparément par `_heartbeatTick()` (Timer.periodic, voir
    // startTracking()), pas par ce throttle réactif au stream de position.
    if (_lastSavedPos != null) {
      final dist = Geolocator.distanceBetween(
        _lastSavedPos!.latitude, _lastSavedPos!.longitude,
        pos.latitude, pos.longitude,
      );
      if (dist < _minDistanceMeters) return;
    }

    await _saveToFirestore(pos);
  }

  Future<void> _saveToFirestore(Position pos) async {
    if (_currentDriverId == null) return;
    _lastSave      = DateTime.now();
    _lastSavedPos  = pos;

    try {
      final geo = GeoFirePoint(GeoPoint(pos.latitude, pos.longitude));
      await FirebaseFirestore.instance
          .collection('livreurs')
          .doc(_currentDriverId)
          .set({
        'lat':       pos.latitude,
        'lng':       pos.longitude,
        'position':  geo.data,
        'heading':   pos.heading,
        'speed':     pos.speed,
        'fcmToken':  _fcmToken,
        'isOnline':  true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[DLS] Firestore write error: $e');
    }
  }

  void _emit(Position pos) {
    if (!_posCtrl.isClosed) _posCtrl.add(pos);
  }

  Future<void> _stopStream() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ── ForegroundService ──────────────────────────────────────────────────────

  Future<void> _ensureForegroundService() async {
    if (_foregroundStarted) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId:          'az_tracking',
          channelName:        'AZ Express — GPS actif',
          channelDescription: 'Maintient la localisation GPS pendant la livraison',
          channelImportance:  NotificationChannelImportance.LOW,
          priority:           NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification:    false,
          playSound:           false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction:       ForegroundTaskEventAction.repeat(30000),
          autoRunOnBoot:     false,
          allowWakeLock:     true,
          allowWifiLock:     false,
        ),
      );

      await FlutterForegroundTask.startService(
        serviceId:           1001,
        notificationTitle:   'AZ Express — Livraison en cours',
        notificationText:    'GPS actif · position transmise en temps réel',
        callback:            azTrackingCallback,
      );
      _foregroundStarted = true;
    } catch (e) {
      debugPrint('[DLS] ForegroundService error: $e');
      // Non bloquant — le GPS continue même sans ForegroundService
    }
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundStarted) return;
    try {
      await FlutterForegroundTask.stopService();
      _foregroundStarted = false;
    } catch (_) {}
  }
}
