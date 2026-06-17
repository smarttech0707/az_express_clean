import 'package:geolocator/geolocator.dart';

class DeliveryService {

  // Abengourou et environs — coordonnées de référence
  static const double abengourouLat = 6.7273;
  static const double abengourouLng = -3.4961;

  // ==============================
  // DISTANCE
  // ==============================

  static double calculateDistance(
      double startLat, double startLng, double endLat, double endLng) {
    double meters =
        Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
    return meters / 1000;
  }

  // ==============================
  // TARIF (jour / nuit)
  //
  // JOUR (avant 20h30)
  //   1 – 5 km  : 500 FCFA
  //   5 – 7 km  : 500 + 100 FCFA × km suppl. (arrondi au km)
  //   7 – 9 km  : 1 000 FCFA
  //   > 9 km    : 2 000 FCFA
  //
  // NUIT (à partir de 20h30)
  //   1 – 5 km  : 1 000 FCFA
  //   > 5 km    : 1 000 + 200 FCFA × km suppl. (arrondi au km)
  // ==============================

  static bool isNightTime([DateTime? time]) {
    final t = time ?? DateTime.now();
    return t.hour >= 20 || t.hour < 6;
  }

  static int calculatePrice(double distanceKm, [DateTime? time]) {
    final night = isNightTime(time);

    if (night) {
      if (distanceKm <= 5) return 1000;
      final extra = (distanceKm - 5).ceil();
      return 1000 + extra * 200;
    }

    // Tarif jour
    if (distanceKm <= 5) return 500;
    if (distanceKm > 9) return 2000;
    if (distanceKm > 7) return 1000;
    // 5 < km ≤ 7
    final extra = (distanceKm - 5).ceil();
    return 500 + extra * 100;
  }

  // Retourne le détail du calcul pour l'affichage
  static PriceBreakdown priceBreakdown(double distanceKm, [DateTime? time]) {
    final night = isNightTime(time);
    final total = calculatePrice(distanceKm, time);
    final eta = calculateETA(distanceKm);

    String detail;
    if (night) {
      if (distanceKm <= 5) {
        detail = "Base nuit (1–5 km) : 1 000 FCFA";
      } else {
        final extra = (distanceKm - 5).ceil();
        detail =
            "Base nuit : 1 000 FCFA\n+ $extra km suppl. × 200 FCFA = ${extra * 200} FCFA";
      }
    } else {
      if (distanceKm <= 5) {
        detail = "Base jour (1–5 km) : 500 FCFA";
      } else if (distanceKm <= 7) {
        final extra = (distanceKm - 5).ceil();
        detail =
            "Base jour : 500 FCFA\n+ $extra km suppl. × 100 FCFA = ${extra * 100} FCFA";
      } else if (distanceKm <= 9) {
        detail = "Forfait longue distance (7–9 km) : 1 000 FCFA";
      } else {
        detail = "Forfait très longue distance (> 9 km) : 2 000 FCFA";
      }
    }

    return PriceBreakdown(
      total: total,
      distanceKm: distanceKm,
      etaMinutes: eta,
      isNight: night,
      detail: detail,
    );
  }

  // ==============================
  // ETA
  // ==============================

  static int calculateETA(double distanceKm) {
    const double speedKmh = 30;
    return ((distanceKm / speedKmh) * 60).round().clamp(2, 120);
  }
}

class PriceBreakdown {
  final int total;
  final double distanceKm;
  final int etaMinutes;
  final bool isNight;
  final String detail;

  const PriceBreakdown({
    required this.total,
    required this.distanceKm,
    required this.etaMinutes,
    required this.isNight,
    required this.detail,
  });
}
