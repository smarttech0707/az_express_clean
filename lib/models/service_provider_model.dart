import 'package:cloud_firestore/cloud_firestore.dart';

class ServiceProvider {
  final String id;
  final String name;
  final String phone;
  final String address;
  final String description;
  final String subcategory;
  final String category;
  final List<String> photos;
  final double lat;
  final double lng;
  final bool isAvailable;
  final double rating;
  final int ratingCount;
  final bool isVerified;
  final String? whatsapp;
  final DateTime? createdAt;

  // Calculé côté client — non stocké en Firestore
  double? distanceKm;

  ServiceProvider({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    required this.description,
    required this.subcategory,
    required this.category,
    required this.photos,
    required this.lat,
    required this.lng,
    required this.isAvailable,
    required this.rating,
    required this.ratingCount,
    required this.isVerified,
    this.whatsapp,
    this.createdAt,
    this.distanceKm,
  });

  factory ServiceProvider.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ServiceProvider(
      id:          doc.id,
      name:        d['name']        as String? ?? '',
      phone:       d['phone']       as String? ?? '',
      address:     d['address']     as String? ?? '',
      description: d['description'] as String? ?? '',
      subcategory: d['subcategory'] as String? ?? '',
      category:    d['category']    as String? ?? '',
      photos:      (d['photos']     as List?)?.cast<String>() ?? [],
      lat:         (d['lat']        as num?)?.toDouble() ?? 0,
      lng:         (d['lng']        as num?)?.toDouble() ?? 0,
      isAvailable: d['isAvailable'] as bool? ?? true,
      rating:      (d['rating']     as num?)?.toDouble() ?? 0,
      ratingCount: (d['ratingCount'] as num?)?.toInt() ?? 0,
      isVerified:  d['isVerified']  as bool? ?? false,
      whatsapp:    d['whatsapp']    as String?,
      createdAt:   (d['createdAt']  as Timestamp?)?.toDate(),
    );
  }

  bool get hasGps => lat != 0 && lng != 0;
  String get ratingStr => rating > 0
      ? rating.toStringAsFixed(1)
      : '—';
  String get distanceStr {
    if (distanceKm == null) return '';
    if (distanceKm! < 1) return '${(distanceKm! * 1000).round()} m';
    return '${distanceKm!.toStringAsFixed(1)} km';
  }
}

// ── Avis clients ──────────────────────────────────────────────────────────────
class ServiceReview {
  final String id;
  final String providerId;
  final String clientId;
  final String clientName;
  final double rating;
  final String comment;
  final DateTime createdAt;

  const ServiceReview({
    required this.id,
    required this.providerId,
    required this.clientId,
    required this.clientName,
    required this.rating,
    required this.comment,
    required this.createdAt,
  });

  factory ServiceReview.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ServiceReview(
      id:          doc.id,
      providerId:  d['providerId']  as String? ?? '',
      clientId:    d['clientId']    as String? ?? '',
      clientName:  d['clientName']  as String? ?? 'Client',
      rating:      (d['rating']     as num?)?.toDouble() ?? 0,
      comment:     d['comment']     as String? ?? '',
      createdAt:   (d['createdAt']  as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
