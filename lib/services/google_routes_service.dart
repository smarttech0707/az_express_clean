import 'dart:convert';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/route_model.dart';

const String _mapsKey = MapsConfig.apiKey;

/// Service de calcul d'itinéraire utilisant Google Directions API.
/// Cache en mémoire par grille 100m (TTL 5 min) pour éviter les appels répétitifs.
class GoogleRoutesService {
  static const _directionsUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // ── Cache itinéraires : clé = grille 100m × 100m, TTL 5 minutes ───────────
  // Arrondir à 3 décimales ≈ 111m de précision
  static final Map<String, _CachedRoute> _routeCache = {};
  static const _routeCacheTtl = Duration(minutes: 5);

  static String _routeKey(LatLng origin, LatLng dest) =>
      '${origin.latitude.toStringAsFixed(3)},${origin.longitude.toStringAsFixed(3)}'
      '→${dest.latitude.toStringAsFixed(3)},${dest.longitude.toStringAsFixed(3)}';

  // ── Route complète avec détails (distance API + durée trafic) ─────────────

  static Future<RouteModel> getRouteModel({
    required LatLng origin,
    required LatLng destination,
    bool withTraffic = false,
  }) async {
    // Vérifier le cache (sauf si withTraffic, car le trafic change vite)
    if (!withTraffic) {
      final key    = _routeKey(origin, destination);
      final cached = _routeCache[key];
      if (cached != null && !cached.isExpired(_routeCacheTtl)) {
        return cached.route;
      }
    }

    try {
      final params = <String, String>{
        'origin':      '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'mode':        'driving',
        'language':    'fr',
        'key':         _mapsKey,
      };
      if (withTraffic) {
        params['departure_time'] = 'now';
        params['traffic_model']  = 'best_guess';
      }

      final uri = Uri.parse(_directionsUrl).replace(queryParameters: params);

      // 12s timeout, 1 retry avant fallback ligne droite
      http.Response resp;
      try {
        resp = await http.get(uri).timeout(const Duration(seconds: 12));
      } catch (_) {
        resp = await http.get(uri).timeout(const Duration(seconds: 12));
      }

      if (resp.statusCode != 200) return _fallback(origin, destination);

      final json   = jsonDecode(resp.body) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status != 'OK') return _fallback(origin, destination);

      final route    = (json['routes'] as List).first as Map<String, dynamic>;
      final leg      = (route['legs']  as List).first as Map<String, dynamic>;
      final distM    = (leg['distance']['value'] as num).toDouble();
      final durS     = withTraffic
          ? (leg['duration_in_traffic']?['value'] as num? ??
             leg['duration']['value'] as num).toDouble()
          : (leg['duration']['value'] as num).toDouble();
      final polyline = route['overview_polyline']['points'] as String;

      final points = PolylinePoints()
          .decodePolyline(polyline)
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();

      final distKm  = distM / 1000;
      final etaMins = (durS / 60).ceil();

      final result = RouteModel(
        points:         points,
        distanceKm:     distKm,
        etaMinutes:     etaMins,
        distanceText:   RouteModel.formatDistance(distKm),
        etaText:        RouteModel.formatEta(etaMins),
        estimatedPrice: RouteModel.estimatePrice(distKm),
      );

      // Mettre en cache (sans traffic uniquement)
      if (!withTraffic) {
        final key = _routeKey(origin, destination);
        _routeCache[key] = _CachedRoute(result);
        if (_routeCache.length > 50) {
          _routeCache.removeWhere((_, v) => v.isExpired(_routeCacheTtl));
        }
      }

      return result;
    } catch (_) {
      return _fallback(origin, destination);
    }
  }

  // ── Route rapide (polyline seulement — pour mises à jour fréquentes) ──────

  static Future<List<LatLng>> getPoints({
    required LatLng origin,
    required LatLng destination,
  }) async {
    // Vérifier le cache d'abord
    final key    = _routeKey(origin, destination);
    final cached = _routeCache[key];
    if (cached != null && !cached.isExpired(_routeCacheTtl)) {
      return cached.route.points;
    }

    try {
      final result = await PolylinePoints().getRouteBetweenCoordinates(
        googleApiKey: _mapsKey,
        request: PolylineRequest(
          origin:      PointLatLng(origin.latitude, origin.longitude),
          destination: PointLatLng(destination.latitude, destination.longitude),
          mode:        TravelMode.driving,
        ),
      );
      if (result.points.isEmpty) return [origin, destination];
      return result.points.map((p) => LatLng(p.latitude, p.longitude)).toList();
    } catch (_) {
      return [origin, destination];
    }
  }

  // ── Fallback sans API (ligne droite + estimation locale) ──────────────────

  static RouteModel _fallback(LatLng origin, LatLng dest) {
    final distKm = RouteModel.estimateEta(
          _haversineKm(origin, dest)) > 0
        ? _haversineKm(origin, dest)
        : 1.0;
    final eta = RouteModel.estimateEta(distKm);
    return RouteModel(
      points:         _straightLine(origin, dest),
      distanceKm:     distKm,
      etaMinutes:     eta,
      distanceText:   RouteModel.formatDistance(distKm),
      etaText:        RouteModel.formatEta(eta),
      estimatedPrice: RouteModel.estimatePrice(distKm),
    );
  }

  // Interpolation de 20 points sur la droite (fallback visuellement propre)
  static List<LatLng> _straightLine(LatLng a, LatLng b) {
    const steps = 20;
    return List.generate(steps + 1, (i) {
      final t = i / steps;
      return LatLng(
        a.latitude  + (b.latitude  - a.latitude)  * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    });
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _rad(b.latitude  - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final sinDLat = _sin(dLat / 2);
    final sinDLon = _sin(dLon / 2);
    final c = sinDLat * sinDLat +
        _cos(_rad(a.latitude)) * _cos(_rad(b.latitude)) * sinDLon * sinDLon;
    return r * 2 * _atan2(_sqrt(c), _sqrt(1 - c));
  }

  static double _rad(double deg) => deg * 3.14159265358979 / 180;
  static double _sin(double x) => x - x * x * x / 6;
  static double _cos(double x) => 1 - x * x / 2;
  static double _sqrt(double x) => x <= 0 ? 0 : x < 1 ? x * (1 + x / 2) : x;
  static double _atan2(double y, double x) =>
      x == 0 ? (y > 0 ? 1.5708 : -1.5708) : (x > 0 ? y / x : y / x + 3.14159);
}

// ── Entrée de cache interne ────────────────────────────────────────────────

class _CachedRoute {
  final RouteModel route;
  final DateTime   createdAt;
  _CachedRoute(this.route) : createdAt = DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
