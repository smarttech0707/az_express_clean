import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteModel {
  final List<LatLng> points;
  final double distanceKm;
  final int etaMinutes;
  final String distanceText;
  final String etaText;
  final int estimatedPrice; // FCFA

  const RouteModel({
    required this.points,
    required this.distanceKm,
    required this.etaMinutes,
    required this.distanceText,
    required this.etaText,
    required this.estimatedPrice,
  });

  bool get isEmpty => points.isEmpty;
  bool get isNotEmpty => points.isNotEmpty;

  static RouteModel empty() => const RouteModel(
        points: [],
        distanceKm: 0,
        etaMinutes: 0,
        distanceText: '--',
        etaText: '--',
        estimatedPrice: 0,
      );

  RouteModel copyWith({
    List<LatLng>? points,
    double? distanceKm,
    int? etaMinutes,
    String? distanceText,
    String? etaText,
    int? estimatedPrice,
  }) =>
      RouteModel(
        points: points ?? this.points,
        distanceKm: distanceKm ?? this.distanceKm,
        etaMinutes: etaMinutes ?? this.etaMinutes,
        distanceText: distanceText ?? this.distanceText,
        etaText: etaText ?? this.etaText,
        estimatedPrice: estimatedPrice ?? this.estimatedPrice,
      );

  // ── Formatage ─────────────────────────────────────────────────────────────

  static String formatEta(int minutes) {
    if (minutes <= 0) return '< 1 min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h $m min' : '${h}h';
  }

  static String formatDistance(double km) {
    if (km <= 0) return '0 m';
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  /// Prix estimé en FCFA (base 500 + 200 FCFA/km, arrondi à 50)
  static int estimatePrice(double distanceKm) {
    const base = 500;
    const perKm = 200;
    if (distanceKm <= 0) return base;
    final raw = base + (distanceKm * perKm).round();
    return ((raw + 24) ~/ 50) * 50; // arrondi supérieur à 50
  }

  /// ETA à 25 km/h (moto en ville)
  static int estimateEta(double distanceKm) {
    if (distanceKm <= 0) return 1;
    return ((distanceKm / 25) * 60).round().clamp(1, 180);
  }
}
