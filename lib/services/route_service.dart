import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteService {
  static Future<List<LatLng>> getRoute(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
    String apiKey,
  ) async {
    final polylinePoints = PolylinePoints();

    final result = await polylinePoints.getRouteBetweenCoordinates(
      googleApiKey: apiKey,
      request: PolylineRequest(
        origin: PointLatLng(startLat, startLng),
        destination: PointLatLng(endLat, endLng),
        mode: TravelMode.driving,
      ),
    );

    if (result.points.isEmpty) return [];

    return result.points
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
  }
}
