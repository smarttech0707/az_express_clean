import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/route_model.dart';
import 'maps_proxy_client.dart';

/// Service de calcul d'itinéraire : passe par le proxy serveur
/// (`functions/mapsProxy.js`) uniquement. Lot 1.2.1 — plus aucun appel
/// Google direct depuis Flutter : si le proxy est indisponible ou refuse
/// (quelle que soit la cause), le repli est l'estimation locale
/// ([_fallback], ligne droite marquée [RouteModel.isEstimate]), jamais un
/// appel HTTP vers Google avec la clé de l'application.
/// Cache en mémoire par grille 100m (TTL 5 min) pour éviter les appels répétitifs.
class GoogleRoutesService {
  // ── Cache itinéraires : clé = grille 100m × 100m, TTL 5 minutes ───────────
  // Arrondir à 3 décimales ≈ 111m de précision
  static final Map<String, _CachedRoute> _routeCache = {};
  static final Map<String, Future<RouteModel>> _inFlightRouteModels = {};
  static const _routeCacheTtl = Duration(minutes: 5);
  static const _maxRouteCacheEntries = 50;

  @visibleForTesting
  static void debugResetCache() {
    _routeCache.clear();
    _inFlightRouteModels.clear();
  }

  static String _routeKey(LatLng origin, LatLng dest) =>
      '${origin.latitude.toStringAsFixed(3)},${origin.longitude.toStringAsFixed(3)}'
      '→${dest.latitude.toStringAsFixed(3)},${dest.longitude.toStringAsFixed(3)}';

  // ── Route complète avec détails (distance API + durée trafic) ─────────────

  static Future<RouteModel> getRouteModel({
    required LatLng origin,
    required LatLng destination,
    bool withTraffic = false,
  }) {
    if (!withTraffic) {
      final cached = _routeCache[_routeKey(origin, destination)];
      if (cached != null && !cached.isExpired(_routeCacheTtl)) {
        return Future.value(cached.route);
      }
    }

    final inFlightKey =
        '${_routeKey(origin, destination)}|traffic=$withTraffic';
    final existing = _inFlightRouteModels[inFlightKey];
    if (existing != null) return existing;

    late final Future<RouteModel> request;
    request = _fetchRouteModel(
      origin: origin,
      destination: destination,
      withTraffic: withTraffic,
    ).whenComplete(() {
      if (identical(_inFlightRouteModels[inFlightKey], request)) {
        _inFlightRouteModels.remove(inFlightKey);
      }
    });
    _inFlightRouteModels[inFlightKey] = request;
    return request;
  }

  static Future<RouteModel> _fetchRouteModel({
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

    // Seul chemin réseau : le proxy serveur (clé côté serveur, jamais dans
    // l'app). Lot 1.2.1 — aucun appel Google direct en repli, quelle que
    // soit la cause de l'échec du proxy (refus de sécurité ou panne
    // technique) : seule l'estimation locale ([_fallback]) prend le relais.
    final proxied = await _fetchViaProxy(
      origin: origin,
      destination: destination,
      withTraffic: withTraffic,
    );
    if (proxied != null) {
      if (!withTraffic) {
        _routeCache[_routeKey(origin, destination)] = _CachedRoute(proxied);
        _trimRouteCache();
      }
      return proxied;
    }

    return _fallback(origin, destination);
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

  // Lot 1.1 — `getPoints()` est supprimée : aucun appelant dans lib/ ni
  // test/ (vérifié), elle appelait Directions directement avec la clé de
  // l'application sans passer par le proxy serveur. Utiliser [getRouteModel]
  // (proxy → estimation signalée, Lot 1.2.1 : plus de repli Google direct).

  // ── Itinéraire via le proxy serveur ───────────────────────────────────────

  /// `null` = proxy indisponible ou refusé, ou réponse inexploitable :
  /// l'appelant passe directement à l'estimation locale (jamais à un appel
  /// Google direct, quelle que soit la cause — Lot 1.2.1).
  static Future<RouteModel?> _fetchViaProxy({
    required LatLng origin,
    required LatLng destination,
    required bool withTraffic,
  }) async {
    final result = await MapsProxyClient.call(
      MapsProxyClient.route,
      {
        'origin': MapsProxyClient.point(origin.latitude, origin.longitude),
        'destination':
            MapsProxyClient.point(destination.latitude, destination.longitude),
        'withTraffic': withTraffic,
      },
      timeout: const Duration(seconds: 12),
    );
    if (!result.hasData) return null;
    return routeFromProxyData(result.data!);
  }

  /// Convertit la réponse de `mapsRouteCF`. Refuse (→ `null`) toute réponse
  /// incomplète ou marquée estimation : seul un itinéraire routier réel peut
  /// sortir d'ici sans le drapeau [RouteModel.isEstimate].
  @visibleForTesting
  static RouteModel? routeFromProxyData(Map<String, dynamic> data) {
    try {
      final encoded = data['encodedPolyline'];
      final distM = data['distanceMeters'];
      final durS = data['durationSeconds'];
      if (encoded is! String || encoded.isEmpty) return null;
      if (distM is! num || durS is! num) return null;
      if (data['isEstimate'] != false) return null;
      final points = PolylinePoints()
          .decodePolyline(encoded)
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();
      if (points.isEmpty) return null;
      final distKm = distM.toDouble() / 1000;
      final etaMins = (durS.toDouble() / 60).ceil();
      return RouteModel(
        points: points,
        distanceKm: distKm,
        etaMinutes: etaMins,
        distanceText: RouteModel.formatDistance(distKm),
        etaText: RouteModel.formatEta(etaMins),
        estimatedPrice: RouteModel.estimatePrice(distKm),
      );
    } catch (_) {
      return null;
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
      // Ligne droite, vol d'oiseau, vitesse fixe : jamais un trajet réel.
      isEstimate: true,
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
