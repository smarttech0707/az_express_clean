import 'dart:math' as math;

// BUSINESS RULE:
// Livraison Express
// Jour = 1000 FCFA
// Nuit = 1500 FCFA
// Ne pas modifier sans décision métier.
// (Zone centrale ≤8km d'Abengourou — voir TarifResult.expressPrice ci-dessous
// pour la formule exacte. Port Node fidèle : functions/tarifService.js.)

class TarifResult {
  final int standardPrice;
  final int expressPrice;
  final bool isNight;
  final bool isOutside;
  final bool canOrder;
  final String? rejectionMessage;

  const TarifResult({
    required this.standardPrice,
    required this.expressPrice,
    required this.isNight,
    required this.isOutside,
    required this.canOrder,
    this.rejectionMessage,
  });
}

class TarifService {
  static const double centerLat     = 6.7273;
  static const double centerLng     = -3.4961;
  static const double _cityRadiusKm = 8.0;

  // Tarif nuit : 20h00–05h59
  static bool isNightTime([DateTime? time]) {
    final t = time ?? DateTime.now();
    return t.hour >= 20 || t.hour < 6;
  }

  // Refus commandes >10 km : uniquement après 21h00
  static bool isLateNight([DateTime? time]) {
    final t = time ?? DateTime.now();
    return t.hour >= 21;
  }

  static double haversineKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  static int _round50(double value) {
    final raw = value.round();
    return ((raw + 24) ~/ 50) * 50;
  }

  /// Calcule le tarif de livraison.
  ///
  /// [clientLat] / [clientLng] : coordonnées du point de livraison.
  /// [routeDistanceKm] : distance réelle du trajet si disponible,
  ///   sinon la distance haversine depuis le centre est utilisée.
  static TarifResult compute({
    required double clientLat,
    required double clientLng,
    double? routeDistanceKm,
    DateTime? time,
  }) {
    final night     = isNightTime(time);
    final lateNight = isLateNight(time);
    final distFromCenter =
        haversineKm(centerLat, centerLng, clientLat, clientLng);
    final isOutside = distFromCenter > _cityRadiusKm;

    if (!isOutside) {
      return TarifResult(
        standardPrice: night ? 1000 : 500,
        // BUSINESS RULE:
        // Livraison Express
        // Jour = 1000 FCFA
        // Nuit = 1500 FCFA
        // Ne pas modifier sans décision métier.
        expressPrice:  night ? 1500 : 1000,
        isNight:   night,
        isOutside: false,
        canOrder:  true,
      );
    }

    // Hors ville : tarif kilométrique
    final dist = routeDistanceKm ?? distFromCenter;

    if (lateNight && dist > 10) {
      return const TarifResult(
        standardPrice:    0,
        expressPrice:     0,
        isNight:          true,
        isOutside:        true,
        canOrder:         false,
        rejectionMessage: 'Livraison non disponible après 21h00 '
            'pour les zones à plus de 10 km d\'Abengourou.',
      );
    }

    final stdRaw = 500.0 + dist * 150;
    final std    = _round50(stdRaw);
    final exp    = _round50(std * 1.4);

    return TarifResult(
      standardPrice: std,
      expressPrice:  exp,
      isNight:   night,
      isOutside: true,
      canOrder:  true,
    );
  }
}
