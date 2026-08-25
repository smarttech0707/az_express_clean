import 'package:geolocator/geolocator.dart';

// Prix/commission/ETA retirés (2026-07-09) : jamais appelés nulle part dans
// l'app — calculateDeliveryPrice()/calculateCommission() dupliquaient une
// formule de tarification jamais branchée (voir TarifService/tarifService.js,
// seule source de vérité déjà unifiée, Master Prompt 51) ; calculateETA()
// dupliquait une estimation grossière (30km/h fixe) déjà remplacée par le
// calcul basé sur Google Directions API (GoogleRoutesService/RouteModel).
// Ne garder que calculateDistance(), la seule méthode réellement utilisée
// (lib/screens/driver/driver_dashboard.dart).
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
}
