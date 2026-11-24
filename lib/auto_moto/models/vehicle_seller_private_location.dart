import 'package:cloud_firestore/cloud_firestore.dart';

class VehicleSellerPrivateLocation {
  const VehicleSellerPrivateLocation({
    required this.ownerId,
    required this.latitude,
    required this.longitude,
    required this.cityId,
    this.zoneId,
    this.addressLabel,
    this.updatedAt,
  });

  final String ownerId;
  final double latitude;
  final double longitude;
  final String cityId;
  final String? zoneId;
  final String? addressLabel;
  final DateTime? updatedAt;

  factory VehicleSellerPrivateLocation.fromMap(Map<String, dynamic> data) {
    return VehicleSellerPrivateLocation(
      ownerId: data['ownerId'] as String? ?? '',
      latitude: (data['latitude'] as num? ?? 0).toDouble(),
      longitude: (data['longitude'] as num? ?? 0).toDouble(),
      cityId: data['cityId'] as String? ?? '',
      zoneId: data['zoneId'] as String?,
      addressLabel: data['addressLabel'] as String?,
      updatedAt: _dateTimeFromFirestore(data['updatedAt']),
    );
  }

  factory VehicleSellerPrivateLocation.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) =>
      VehicleSellerPrivateLocation.fromMap(document.data() ?? const {});

  Map<String, dynamic> toMap() => {
        'ownerId': ownerId.trim(),
        'latitude': latitude,
        'longitude': longitude,
        'cityId': cityId.trim(),
        if (zoneId != null && zoneId!.trim().isNotEmpty)
          'zoneId': zoneId!.trim(),
        if (addressLabel != null && addressLabel!.trim().isNotEmpty)
          'addressLabel': addressLabel!.trim(),
        if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      };
}

DateTime? _dateTimeFromFirestore(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}
