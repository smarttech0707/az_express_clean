import 'package:geolocator/geolocator.dart';

class LocationService {

  /// ================================
  /// CALCUL DISTANCE (KM)
  /// ================================
  static double calculateDistance(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {

    double distanceMeters = Geolocator.distanceBetween(
      startLat,
      startLng,
      endLat,
      endLng,
    );

    double distanceKm = distanceMeters / 1000;

    return double.parse(distanceKm.toStringAsFixed(2));
  }

  /// ================================
  /// CALCUL PRIX LIVRAISON
  /// ================================
  static int calculateDeliveryPrice(double distanceKm) {

    if (distanceKm <= 2) {
      return 500;
    }

    if (distanceKm <= 5) {
      return 700;
    }

    if (distanceKm <= 8) {
      return 1000;
    }

    return 1500;
  }

  /// ================================
  /// COMMISSION PLATEFORME
  /// ================================
  static Map<String, int> calculateCommission(int deliveryPrice) {

    int platform = (deliveryPrice * 0.20).round();
    int driver = deliveryPrice - platform;

    return {
      "platform": platform,
      "driver": driver,
    };
  }

  /// ================================
  /// TEMPS ARRIVÉE (ETA)
  /// ================================
  static int calculateETA(double distanceKm) {

    double speed = 30; // vitesse moyenne moto km/h

    double timeHours = distanceKm / speed;

    int minutes = (timeHours * 60).round();

    if (minutes < 1) {
      return 1;
    }

    return minutes;
  }
}