import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/route_model.dart';

const String _mapsKey = MapsConfig.apiKey;

@visibleForTesting
Future<http.Response> getDirectionsWithTransientRetry(
  Uri uri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 12),
  Duration retryDelay = const Duration(milliseconds: 300),
}) async {
  final ownedClient = client == null;
  final requestClient = client ?? http.Client();
  try {
    try {
      return await requestClient.get(uri).timeout(timeout);
    } on TimeoutException {
      await Future<void>.delayed(retryDelay);
      return requestClient.get(uri).timeout(timeout);
    } on SocketException {
      await Future<void>.delayed(retryDelay);
      return requestClient.get(uri).timeout(timeout);
    } on http.ClientException {
      await Future<void>.delayed(retryDelay);
      return requestClient.get(uri).timeout(timeout);
    }
  } finally {
    if (ownedClient) requestClient.close();
  }
}

/// Service de calcul d'itinéraire utilisant Google Directions API.
/// Cache en mémoire par grille 100m (TTL 5 min) pour éviter les appels répétitifs.
class GoogleRoutesService {
  static const _directionsUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // ── Cache itinéraires : clé = grille 100m × 100m, TTL 5 minutes ───────────
  // Arrondir à 3 décimales ≈ 111m de précision
  static final Map<String, _CachedRoute> _routeCache = {};
  static const _routeCacheTtl = Duration(minutes: 5);
  static const _maxRouteCacheEntries = 50;

  @visibleForTesting
  static Future<http.Response> Function(Uri uri)? debugDirectionsGet;

  @visibleForTesting
  static void debugResetCache() {
    _routeCache.clear();
    debugDirectionsGet = null;
  }

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
      final key = _routeKey(origin, destination);
      final cached = _routeCache[key];
      if (cached != null && !cached.isExpired(_routeCacheTtl)) {
        return cached.route;
      }
    }

    try {
      final params = <String, String>{
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'mode': 'driving',
        'language': 'fr',
        'key': _mapsKey,
      };
      if (withTraffic) {
        params['departure_time'] = 'now';
        params['traffic_model'] = 'best_guess';
      }

      final uri = Uri.parse(_directionsUrl).replace(queryParameters: params);

      // Un seul retry, après un court délai et uniquement sur panne transitoire.
      final testGet = debugDirectionsGet;
      final resp = testGet != null
          ? await testGet(uri)
          : await getDirectionsWithTransientRetry(uri);

      if (resp.statusCode != 200) return _fallback(origin, destination);

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status != 'OK') return _fallback(origin, destination);

      final route = (json['routes'] as List).first as Map<String, dynamic>;
      final leg = (route['legs'] as List).first as Map<String, dynamic>;
      final distM = (leg['distance']['value'] as num).toDouble();
      final durS = withTraffic
          ? (leg['duration_in_traffic']?['value'] as num? ??
                  leg['duration']['value'] as num)
              .toDouble()
          : (leg['duration']['value'] as num).toDouble();
      final polyline = route['overview_polyline']['points'] as String;

      final points = PolylinePoints()
          .decodePolyline(polyline)
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();

      final distKm = distM / 1000;
      final etaMins = (durS / 60).ceil();

      final result = RouteModel(
        points: points,
        distanceKm: distKm,
        etaMinutes: etaMins,
        distanceText: RouteModel.formatDistance(distKm),
        etaText: RouteModel.formatEta(etaMins),
        estimatedPrice: RouteModel.estimatePrice(distKm),
      );

      // Mettre en cache (sans traffic uniquement)
      if (!withTraffic) {
        final key = _routeKey(origin, destination);
        _routeCache[key] = _CachedRoute(result);
        _trimRouteCache();
      }

      return result;
    } catch (_) {
      return _fallback(origin, destination);
    }
  }

  // ── Route rapide (polyline seulement — pour mises à jour fréquentes) ──────

  static void _trimRouteCache() {
    _routeCache.removeWhere((_, value) => value.isExpired(_routeCacheTtl));
    if (_routeCache.length <= _maxRouteCacheEntries) return;

    final oldestKeys = _routeCache.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    final overflow = _routeCache.length - _maxRouteCacheEntries;
    for (var i = 0; i < overflow; i++) {
      _routeCache.remove(oldestKeys[i].key);
    }
  }

  static Future<List<LatLng>> getPoints({
    required LatLng origin,
    required LatLng destination,
  }) async {
    // Vérifier le cache d'abord
    final key = _routeKey(origin, destination);
    final cached = _routeCache[key];
    if (cached != null && !cached.isExpired(_routeCacheTtl)) {
      return cached.route.points;
    }

    try {
      final result = await PolylinePoints().getRouteBetweenCoordinates(
        googleApiKey: _mapsKey,
        request: PolylineRequest(
          origin: PointLatLng(origin.latitude, origin.longitude),
          destination: PointLatLng(destination.latitude, destination.longitude),
          mode: TravelMode.driving,
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
    final distKm = _haversineKm(origin, dest);
    final eta = RouteModel.estimateEta(distKm);
    return RouteModel(
      points: _straightLine(origin, dest),
      distanceKm: distKm,
      etaMinutes: eta,
      distanceText: RouteModel.formatDistance(distKm),
      etaText: RouteModel.formatEta(eta),
      estimatedPrice: RouteModel.estimatePrice(distKm),
    );
  }

  // Interpolation de 20 points sur la droite (fallback visuellement propre)
  static List<LatLng> _straightLine(LatLng a, LatLng b) {
    const steps = 20;
    return List.generate(steps + 1, (i) {
      final t = i / steps;
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    });
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _rad(b.latitude - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);
    final h = sinDLat * sinDLat +
        math.cos(_rad(a.latitude)) *
            math.cos(_rad(b.latitude)) *
            sinDLon *
            sinDLon;
    return r * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  static double _rad(double deg) => deg * 3.14159265358979 / 180;
}

// ── Entrée de cache interne ────────────────────────────────────────────────

class _CachedRoute {
  final RouteModel route;
  final DateTime createdAt;
  _CachedRoute(this.route, {DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
