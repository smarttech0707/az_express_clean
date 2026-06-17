import 'package:geolocator/geolocator.dart';

class ETAService {

  /// calcul distance en km
  static double calculateDistance(
      double startLat,
      double startLng,
      double endLat,
      double endLng) {

    double meters = Geolocator.distanceBetween(
      startLat,
      startLng,
      endLat,
      endLng,
    );

    return meters / 1000;
  }

  /// estimation temps d'arrivée
  static int estimateArrivalTime(double distanceKm) {

    double speed = 30; // vitesse moyenne 30 km/h

    double timeHours = distanceKm / speed;

    int minutes = (timeHours * 60).round();

    return minutes;
  }
}