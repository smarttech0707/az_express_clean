import 'package:cloud_firestore/cloud_firestore.dart';

class ShoppingRequest {
  final String id;
  final String description;
  final double budget;
  final double latitude;
  final double longitude;
  final String status;
  final String? driverId;

  ShoppingRequest({
    required this.id,
    required this.description,
    required this.budget,
    required this.latitude,
    required this.longitude,
    required this.status,
    this.driverId,
  });

  Map<String, dynamic> toMap() {
    return {
      "description": description,
      "budget": budget,
      "latitude": latitude,
      "longitude": longitude,
      "status": status,
      "driverId": driverId,
      "createdAt": FieldValue.serverTimestamp(),
    };
  }

  factory ShoppingRequest.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return ShoppingRequest(
      id: doc.id,
      description: data["description"] ?? "",
      budget: (data["budget"] ?? 0).toDouble(),
      latitude: (data["latitude"] ?? 0).toDouble(),
      longitude: (data["longitude"] ?? 0).toDouble(),
      status: data["status"] ?? "pending",
      driverId: data["driverId"],
    );
  }
}
