import 'package:cloud_firestore/cloud_firestore.dart';

import 'vehicle_listing.dart';

class VehicleFavorite {
  const VehicleFavorite({required this.listing, this.createdAt});

  final VehicleListing listing;
  final DateTime? createdAt;

  factory VehicleFavorite.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};
    final snapshot = Map<String, dynamic>.from(
      data['listingSnapshot'] as Map? ?? const {},
    );
    final timestamp = data['createdAt'];
    return VehicleFavorite(
      listing: VehicleListing.fromMap(document.id, snapshot),
      createdAt: timestamp is Timestamp ? timestamp.toDate() : null,
    );
  }
}
