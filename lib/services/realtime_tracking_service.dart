import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/driver_location_model.dart';
import '../models/route_model.dart';
import 'google_routes_service.dart';

/// Service central de suivi temps réel.
///
/// - Écoute la position du livreur dans Firestore.
/// - Anime le marqueur livreur frame par frame (16ms ≈ 60 fps).
/// - Recalcule l'itinéraire quand le livreur s'éloigne de la route (> 80m).
/// - Expose [animatedDriverPos] pour affichage fluide.
/// - Notifie les widgets via [ChangeNotifier].
class RealtimeTrackingService extends ChangeNotifier {

  // ── Paramètres ─────────────────────────────────────────────────────────────
  final String  _driverId;
  final LatLng  _clientPosition;  // point de récupération (référence originale)
  final LatLng? _destination;

  // ── Cible active (peut changer après picked_up) ────────────────────────────
  LatLng? _overrideTarget; // non-null → remplace _clientPosition pour le routage

  LatLng get _effectiveTarget => _overrideTarget ?? _clientPosition;

  // ── État courant ────────────────────────────────────────────────────────────
  DriverLocationModel? _driverLocation;
  LatLng?              _animatedPos;
  double               _animatedHeading = 0;
  RouteModel           _routeToClient   = RouteModel.empty();
  RouteModel           _routeToDest     = RouteModel.empty();
  bool                 _routeLoading    = false;
  bool                 _followDriver    = true;
  DateTime             _lastUpdateTime  = DateTime(2000);

  // ── Internes ───────────────────────────────────────────────────────────────
  bool     _disposed   = false;
  StreamSubscription<DocumentSnapshot>? _firestoreSub;
  Timer?   _animTimer;
  LatLng?  _animFrom;
  LatLng?  _animTo;
  double   _headingFrom = 0;
  double   _headingTo   = 0;
  DateTime _animStart = DateTime.now();
  static const _animDurationMs   = 1600;
  // Seuil déviation itinéraire relevé de 80m→200m pour limiter les appels Directions API
  static const _recalcThresholdM = 200.0;
  static const _minMoveMeters    = 5.0;
  DateTime _lastRouteCalc = DateTime(2000);

  // ── Getters publics ────────────────────────────────────────────────────────
  DriverLocationModel? get driverLocation   => _driverLocation;
  LatLng               get clientPosition   => _clientPosition;
  LatLng?              get destination      => _destination;
  RouteModel           get routeToClient    => _routeToClient;
  RouteModel           get routeToDest      => _routeToDest;
  bool                 get routeLoading     => _routeLoading;
  bool                 get followDriver     => _followDriver;
  LatLng?              get animatedDriverPos => _animatedPos;
  double               get animatedHeading  => _animatedHeading;
  DateTime             get lastUpdateTime   => _lastUpdateTime;

  bool get hasDriver     => _driverLocation != null;
  bool get hasDest       => _destination    != null;
  int  get totalEta      => _routeToClient.etaMinutes + _routeToDest.etaMinutes;
  double get totalDistKm => _routeToClient.distanceKm + _routeToDest.distanceKm;
  int  get totalPrice    => _routeToClient.estimatedPrice;

  /// Bascule la cible de routage vers la destination de livraison.
  /// Appelé quand le statut commande passe à `picked_up`.
  void switchToDelivery(LatLng deliveryDest) {
    _overrideTarget = deliveryDest;
    _routeToDest    = RouteModel.empty();
    _lastRouteCalc  = DateTime(2000); // force recalc immédiat
    notifyListeners();
    if (_driverLocation != null) {
      _calculateRoutes(_driverLocation!.latLng);
    }
  }

  // ── Constructeur ───────────────────────────────────────────────────────────
  RealtimeTrackingService({
    required String  driverId,
    required LatLng  clientPosition,
    LatLng?          destination,
  })  : _driverId       = driverId,
        _clientPosition = clientPosition,
        _destination    = destination {
    _startFirestoreListener();
  }

  void setFollowDriver(bool value) {
    _followDriver = value;
    notifyListeners();
  }

  // ── Écoute Firestore ────────────────────────────────────────────────────────
  void _startFirestoreListener() {
    // Ne rien écouter si pas encore de livreur assigné (évite doc path vide)
    if (_driverId.isEmpty) return;
    _firestoreSub = FirebaseFirestore.instance
        .collection('livreurs')
        .doc(_driverId)
        .snapshots()
        .listen(_onFirestoreUpdate, onError: (_) {});
  }

  void _onFirestoreUpdate(DocumentSnapshot snap) {
    if (!snap.exists) return;
    final data = snap.data() as Map<String, dynamic>?;
    if (data == null) return;

    final newLoc = DriverLocationModel.fromMap(_driverId, data);
    if (!newLoc.isValid) return;

    final prev = _driverLocation;
    _driverLocation = newLoc;
    _lastUpdateTime = DateTime.now();

    // ── Animation fluide ──────────────────────────────────────────────────────
    if (prev != null && _animatedPos != null) {
      // Ne pas re-animer si le livreur n'a pas vraiment bougé
      final moved = Geolocator.distanceBetween(
        prev.latitude, prev.longitude,
        newLoc.latitude, newLoc.longitude,
      );
      if (moved >= _minMoveMeters) {
        _startAnimation(_animatedPos!, newLoc.latLng, _animatedHeading, newLoc.heading);
      }
    } else {
      _animatedPos     = newLoc.latLng;
      _animatedHeading = newLoc.heading;
      _startAnimation(newLoc.latLng, newLoc.latLng, newLoc.heading, newLoc.heading);
    }

    notifyListeners();

    // ── Recalcul itinéraire ────────────────────────────────────────────────────
    final now = DateTime.now();
    final secsSinceCalc = now.difference(_lastRouteCalc).inSeconds;

    // Recalcule si 1ère fois, ou toutes les 120s, ou déviation importante (>200m)
    final shouldRecalc = !hasDriver || secsSinceCalc >= 120 ||
        _isOffRoute(newLoc.latLng);

    if (shouldRecalc && !_routeLoading) {
      _lastRouteCalc = now;
      _calculateRoutes(newLoc.latLng);
    }
  }

  // ── Vérification déviation ─────────────────────────────────────────────────
  bool _isOffRoute(LatLng driverPos) {
    if (_routeToClient.isEmpty) return true;
    double minDist = double.infinity;
    for (final point in _routeToClient.points) {
      final d = Geolocator.distanceBetween(
        driverPos.latitude, driverPos.longitude,
        point.latitude,     point.longitude,
      );
      if (d < minDist) minDist = d;
    }
    return minDist > _recalcThresholdM;
  }

  // ── Animation du marqueur (16ms = ~60fps) ──────────────────────────────────
  void _startAnimation(LatLng from, LatLng to, double fromH, double toH) {
    _animFrom     = from;
    _animTo       = to;
    _headingFrom  = fromH;
    _headingTo    = toH;
    _animStart    = DateTime.now();
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 16), _onAnimTick);
  }

  void _onAnimTick(Timer timer) {
    if (_disposed) { timer.cancel(); return; }
    if (_animFrom == null || _animTo == null) {
      timer.cancel();
      return;
    }
    final elapsed = DateTime.now().difference(_animStart).inMilliseconds;
    double t = (elapsed / _animDurationMs).clamp(0.0, 1.0);
    // Ease-out cubic pour mouvement naturel
    t = 1 - (1 - t) * (1 - t) * (1 - t);

    _animatedPos = LatLng(
      _animFrom!.latitude  + (_animTo!.latitude  - _animFrom!.latitude)  * t,
      _animFrom!.longitude + (_animTo!.longitude - _animFrom!.longitude) * t,
    );
    _animatedHeading = _lerpAngle(_headingFrom, _headingTo, t);
    notifyListeners();

    if (elapsed >= _animDurationMs) {
      _animatedPos     = _animTo;
      _animatedHeading = _headingTo;
      timer.cancel();
    }
  }

  // Interpolation d'angle gérant le passage 359° → 0°
  double _lerpAngle(double from, double to, double t) {
    double diff = to - from;
    if (diff >  180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  // ── Calcul des itinéraires ─────────────────────────────────────────────────
  Future<void> _calculateRoutes(LatLng driverPos) async {
    if (_routeLoading) return;
    _routeLoading = true;
    notifyListeners();

    // Route 1 : livreur → cible active (récupération ou livraison)
    _routeToClient = await GoogleRoutesService.getRouteModel(
      origin:      driverPos,
      destination: _effectiveTarget,
    );

    // Route 2 : point de récupération → destination finale (avant picked_up)
    if (_overrideTarget == null && _destination != null) {
      _routeToDest = await GoogleRoutesService.getRouteModel(
        origin:      _clientPosition,
        destination: _destination!,
      );
    }

    _routeLoading = false;
    notifyListeners();
  }

  /// Forcer un recalcul immédiat (ex: client change de destination)
  Future<void> forceRecalculate() async {
    if (_driverLocation == null) return;
    await _calculateRoutes(_driverLocation!.latLng);
  }

  // ── Dispose ────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _disposed = true;
    _animTimer?.cancel();
    _firestoreSub?.cancel();
    super.dispose();
  }
}
