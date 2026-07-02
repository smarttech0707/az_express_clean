import 'package:cloud_firestore/cloud_firestore.dart';

class RealEstateListing {
  final String id;
  final String agentId;
  final String? agentName;
  final String? agentPhone;
  final String title;
  final String description;
  final int price;
  final String priceType; // 'sale' | 'rent'
  final String propertyType;
  final String city;
  final double lat;
  final double lng;
  final List<String> images;
  final String status; // 'active' | 'hidden'
  final int views;
  final DateTime? createdAt;

  const RealEstateListing({
    required this.id,
    required this.agentId,
    this.agentName,
    this.agentPhone,
    required this.title,
    required this.description,
    required this.price,
    this.priceType = 'sale',
    required this.propertyType,
    required this.city,
    this.lat = 0,
    this.lng = 0,
    this.images = const [],
    this.status = 'active',
    this.views = 0,
    this.createdAt,
  });

  factory RealEstateListing.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RealEstateListing(
      id: doc.id,
      agentId: d['agentId'] as String? ?? '',
      agentName: d['agentName'] as String?,
      agentPhone: d['agentPhone'] as String?,
      title: d['title'] as String? ?? '',
      description: d['description'] as String? ?? '',
      price: (d['price'] as num? ?? 0).toInt(),
      priceType: d['priceType'] as String? ?? 'sale',
      propertyType: d['propertyType'] as String? ?? '',
      city: d['city'] as String? ?? '',
      lat: (d['lat'] as num? ?? 0).toDouble(),
      lng: (d['lng'] as num? ?? 0).toDouble(),
      images: (d['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      status: d['status'] as String? ?? 'active',
      views: (d['views'] as num? ?? 0).toInt(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'agentId': agentId,
        if (agentName != null) 'agentName': agentName,
        if (agentPhone != null) 'agentPhone': agentPhone,
        'title': title,
        'description': description,
        'price': price,
        'priceType': priceType,
        'propertyType': propertyType,
        'city': city,
        'lat': lat,
        'lng': lng,
        'images': images,
        'status': status,
        'views': views,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
