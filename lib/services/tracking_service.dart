import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'route_service.dart';

const String _mapsKey = 'AIzaSyCjWt989YSIBblhRE9WNVOWXvOsXHIQ1DE';

/// État de suivi partagé entre la vue client et la vue livreur.
class TrackingState {
  final LatLng?       driverPosition;
  final LatLng        clientPosition;
  final LatLng?       destination;
  final List<LatLng>  routeToClient;      // livreur → client
  final List<LatLng>  routeToDestination; // client → destination
  final double        distanceToClient;   // km
  final double        distanceToDest;     // km
  final int           etaToClient;        // minutes
  final int           etaToDest;          // minutes
  final bool          routeLoading;

  const TrackingState({
    this.driverPosition,
    required this.clientPosition,
    this.destination,
    this.routeToClient      = const [],
    this.routeToDestination = const [],
    this.distanceToClient   = 0,
    this.distanceToDest     = 0,
    this.etaToClient        = 0,
    this.etaToDest          = 0,
    this.routeLoading       = false,
  });

  TrackingState copyWith({
    LatLng?      driverPosition,
    LatLng?      clientPosition,
    LatLng?      destination,
    List<LatLng>? routeToClient,
    List<LatLng>? routeToDestination,
    double?      distanceToClient,
    double?      distanceToDest,
    int?         etaToClient,
    int?         etaToDest,
    bool?        routeLoading,
  }) => TrackingState(
    driverPosition:      driverPosition      ?? this.driverPosition,
    clientPosition:      clientPosition      ?? this.clientPosition,
    destination:         destination         ?? this.destination,
    routeToClient:       routeToClient       ?? this.routeToClient,
    routeToDestination:  routeToDestination  ?? this.routeToDestination,
    distanceToClient:    distanceToClient    ?? this.distanceToClient,
    distanceToDest:      distanceToDest      ?? this.distanceToDest,
    etaToClient:         etaToClient         ?? this.etaToClient,
    etaToDest:           etaToDest           ?? this.etaToDest,
    routeLoading:        routeLoading        ?? this.routeLoading,
  );

  int get etaTotal => etaToClient + etaToDest;
  double get distanceTotal => distanceToClient + distanceToDest;
}

/// Service de suivi en temps réel.
/// - Écoute la position du livreur dans Firestore.
/// - Recalcule l'itinéraire quand le livreur se déplace de plus de [_routeRefreshMeters].
/// - Notifie les widgets via ChangeNotifier.
class TrackingService extends ChangeNotifier {
  TrackingService({
    required String driverId,
    required LatLng clientPosition,
    LatLng? destination,
  })  : _driverId       = driverId,
        _clientPosition = clientPosition,
        _destination    = destination {
    _state = TrackingState(
      clientPosition: clientPosition,
      destination:    destination,
    );
    _start();
  }

  final String  _driverId;
  final LatLng  _clientPosition;
  final LatLng? _destination;

  late TrackingState _state;
  TrackingState get state => _state;

  StreamSubscription<DocumentSnapshot>? _driverSub;
  LatLng? _lastRouteCalcPos;
  Timer?  _animTimer;

  // Recalcule la route si le livreur a bougé de plus de 30 m
  static const double _routeRefreshMeters = 30;
  // Durée de l'animation entre deux positions GPS (ms)
  static const int _animDurationMs = 1000;
  // Pas de mise à jour (~60 fps)
  static const int _animStepMs = 16;

  void _start() {
    _driverSub = FirebaseFirestore.instance
        .collection('livreurs')
        .doc(_driverId)
        .snapshots()
        .listen(_onDriverSnapshot, onError: (_) {});
  }

  void _onDriverSnapshot(DocumentSnapshot doc) {
    if (!doc.exists) return;
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) return;

    final lat = (data['lat'] as num?)?.toDouble() ?? 0;
    final lng = (data['lng'] as num?)?.toDouble() ?? 0;
    if (lat == 0 || lng == 0) return;

    final target = LatLng(lat, lng);

    // Première position : pas d'animation
    if (_state.driverPosition == null) {
      _state = _state.copyWith(driverPosition: target);
      notifyListeners();
      _refreshRouteIfNeeded(target);
      return;
    }

    // Animation fluide de l'ancienne vers la nouvelle position
    _animateMarkerTo(target);
  }

  void _animateMarkerTo(LatLng target) {
    _animTimer?.cancel();
    final start = _state.driverPosition!;
    final steps = (_animDurationMs / _animStepMs).round();
    var step = 0;

    _animTimer = Timer.periodic(
      const Duration(milliseconds: _animStepMs),
      (t) {
        step++;
        final progress = _easeInOut(step / steps);
        final interpolated = LatLng(
          _lerp(start.latitude,  target.latitude,  progress),
          _lerp(start.longitude, target.longitude, progress),
        );
        _state = _state.copyWith(driverPosition: interpolated);
        notifyListeners();

        if (step >= steps) {
          t.cancel();
          _refreshRouteIfNeeded(target);
        }
      },
    );
  }

  void _refreshRouteIfNeeded(LatLng pos) {
    final shouldRefresh = _lastRouteCalcPos == null ||
        Geolocator.distanceBetween(
          _lastRouteCalcPos!.latitude, _lastRouteCalcPos!.longitude,
          pos.latitude, pos.longitude,
        ) >= _routeRefreshMeters;

    if (shouldRefresh) {
      _lastRouteCalcPos = pos;
      _calculateRoutes(pos);
    }
  }

  static double _lerp(double a, double b, double t) =>
      a + (b - a) * t.clamp(0.0, 1.0);

  // Courbe ease-in-out pour un mouvement naturel (pas de départ/arrivée brusque)
  static double _easeInOut(double t) {
    final c = t.clamp(0.0, 1.0);
    return c < 0.5
        ? 2 * c * c
        : 1 - math.pow(-2 * c + 2, 2) / 2;
  }

  Future<void> _calculateRoutes(LatLng driverPos) async {
    _state = _state.copyWith(routeLoading: true);
    notifyListeners();

    // Distance livreur → client
    final distToClient = Geolocator.distanceBetween(
      driverPos.latitude, driverPos.longitude,
      _clientPosition.latitude, _clientPosition.longitude,
    ) / 1000;

    final etaToClient = _eta(distToClient);

    // Route livreur → client (via Directions API)
    final routeToClient = await RouteService.getRoute(
      driverPos.latitude, driverPos.longitude,
      _clientPosition.latitude, _clientPosition.longitude,
      _mapsKey,
    );

    // Route client → destination (si destination disponible)
    List<LatLng> routeToDest = [];
    double distToDest = 0;
    int etaToDest = 0;

    if (_destination != null) {
      distToDest = Geolocator.distanceBetween(
        _clientPosition.latitude, _clientPosition.longitude,
        _destination!.latitude, _destination!.longitude,
      ) / 1000;
      etaToDest = _eta(distToDest);

      routeToDest = await RouteService.getRoute(
        _clientPosition.latitude, _clientPosition.longitude,
        _destination!.latitude, _destination!.longitude,
        _mapsKey,
      );
    }

    _state = _state.copyWith(
      routeToClient:      routeToClient.isNotEmpty ? routeToClient : [driverPos, _clientPosition],
      routeToDestination: routeToDest,
      distanceToClient:   distToClient,
      distanceToDest:     distToDest,
      etaToClient:        etaToClient,
      etaToDest:          etaToDest,
      routeLoading:       false,
    );
    notifyListeners();
  }

  /// Vitesse moto en ville : 25 km/h (inclut arrêts feux, ralentissements)
  static int _eta(double distKm) {
    if (distKm <= 0) return 1;
    return ((distKm / 25) * 60).round().clamp(1, 180);
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _driverSub?.cancel();
    super.dispose();
  }
}
