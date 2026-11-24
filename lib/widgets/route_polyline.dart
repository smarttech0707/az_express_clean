import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/route_model.dart';
import '../theme/app_theme.dart';

/// Construit le jeu de polylines pour affichage sur GoogleMap.
class RoutePolylineBuilder {
  // ── Couleurs ──────────────────────────────────────────────────────────────
  static const Color _orangeRoute = AppColors.primary;
  static const Color _blueRoute = Color(0xFF1565C0);
  static const Color _shadowColor = Color(0x55000000);

  /// Vue client : route livreur→client (orange) + client→destination (bleu tirets)
  static Set<Polyline> buildForClient({
    required RouteModel routeToClient,
    required RouteModel routeToDest,
  }) {
    final polylines = <Polyline>{};

    // Route livreur → client (orange plein)
    if (routeToClient.isNotEmpty) {
      // Ombre sous la route
      polylines.add(Polyline(
        polylineId: const PolylineId('shadow_to_client'),
        points: routeToClient.points,
        color: _shadowColor,
        width: 9,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 0,
      ));
      // Route principale
      polylines.add(Polyline(
        polylineId: const PolylineId('to_client'),
        points: routeToClient.points,
        color: _orangeRoute,
        width: 6,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 1,
      ));
    }

    // Route client → destination (bleu tirets)
    if (routeToDest.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('to_dest'),
        points: routeToDest.points,
        color: _blueRoute,
        width: 4,
        patterns: [PatternItem.dash(18), PatternItem.gap(10)],
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 1,
      ));
    }

    return polylines;
  }

  /// Vue livreur : route vers le client (orange) + route vers la destination (bleu)
  static Set<Polyline> buildForDriver({
    required RouteModel routeToClient,
    required RouteModel routeToDest,
  }) {
    final polylines = <Polyline>{};

    if (routeToClient.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('driver_shadow'),
        points: routeToClient.points,
        color: _shadowColor,
        width: 10,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 0,
      ));
      polylines.add(Polyline(
        polylineId: const PolylineId('driver_to_client'),
        points: routeToClient.points,
        color: _orangeRoute,
        width: 7,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 1,
      ));
    }

    if (routeToDest.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('driver_to_dest'),
        points: routeToDest.points,
        color: _blueRoute,
        width: 5,
        patterns: [PatternItem.dash(15), PatternItem.gap(8)],
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 1,
      ));
    }

    return polylines;
  }

  /// Calcule les bounds englobant une liste de points.
  static LatLngBounds? boundsFor(List<LatLng> points) {
    if (points.isEmpty) return null;
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Éviter un bounds de taille 0 (un seul point)
    if (minLat == maxLat) {
      minLat -= 0.005;
      maxLat += 0.005;
    }
    if (minLng == maxLng) {
      minLng -= 0.005;
      maxLng += 0.005;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }
}
