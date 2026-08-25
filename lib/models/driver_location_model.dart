import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class DriverLocationModel {
  final String driverId;
  final double latitude;
  final double longitude;
  final double heading; // degrés (0 = nord)
  final double speed; // m/s
  final DateTime timestamp;
  final bool isOnline;
  final String? name;
  final String? photoUrl;

  const DriverLocationModel({
    required this.driverId,
    required this.latitude,
    required this.longitude,
    this.heading = 0,
    this.speed = 0,
    required this.timestamp,
    this.isOnline = true,
    this.name,
    this.photoUrl,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  bool get isValid => latitude != 0 || longitude != 0;

  factory DriverLocationModel.fromMap(String id, Map<String, dynamic> d) {
    return DriverLocationModel(
      driverId: id,
      latitude: (d['lat'] as num? ?? 0).toDouble(),
      longitude: (d['lng'] as num? ?? 0).toDouble(),
      heading: (d['heading'] as num? ?? 0).toDouble(),
      speed: (d['speed'] as num? ?? 0).toDouble(),
      timestamp: d['updatedAt'] != null
          ? (d['updatedAt'] as Timestamp).toDate()
          : DateTime.now(),
      isOnline: d['isOnline'] as bool? ?? true,
      name: d['name'] as String?,
      photoUrl: d['photoUrl'] as String?,
    );
  }

  /// Interpolation linéaire entre deux positions pour animation fluide.
  /// [t] est compris entre 0.0 (this) et 1.0 (target).
  DriverLocationModel lerp(DriverLocationModel target, double t) {
    final clampedT = t.clamp(0.0, 1.0);
    return DriverLocationModel(
      driverId: driverId,
      latitude: latitude + (target.latitude - latitude) * clampedT,
      longitude: longitude + (target.longitude - longitude) * clampedT,
      heading: _lerpAngle(heading, target.heading, clampedT),
      speed: speed + (target.speed - speed) * clampedT,
      timestamp: timestamp,
      isOnline: isOnline,
      name: name,
      photoUrl: photoUrl,
    );
  }

  // Interpolation d'angle en gérant le passage 359° → 0°
  double _lerpAngle(double from, double to, double t) {
    double diff = to - from;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  @override
  String toString() =>
      'Driver($driverId @ $latitude,$longitude heading=$heading°)';
}
