import 'package:cloud_firestore/cloud_firestore.dart';

class MpProduct {
  final String id;
  final String sellerId;
  final String sellerName;
  final String sellerPhone;
  final String sellerCity;
  final bool sellerVerified;
  final String title;
  final String description;
  final int price;
  final String category; // phones / tablets / computers / accessories
  final String? subcategory;
  final String brand;
  final String condition; // new / like_new / used
  final String? storage;
  final String? ram;
  final String? color;
  final String? battery;
  final List<String> images;
  final String city;
  final double lat;
  final double lng;
  final int views;
  final int favoritesCount;
  final String status; // active / sold / hidden
  final DateTime? createdAt;
  final String sellerVipStatus;
  final int priorityLevel;
  final DateTime? expiresAt;

  const MpProduct({
    required this.id,
    required this.sellerId,
    required this.sellerName,
    required this.sellerPhone,
    this.sellerCity = '',
    this.sellerVerified = false,
    required this.title,
    required this.description,
    required this.price,
    required this.category,
    this.subcategory,
    required this.brand,
    required this.condition,
    this.storage,
    this.ram,
    this.color,
    this.battery,
    this.images = const [],
    this.city = 'Abengourou',
    this.lat = 0,
    this.lng = 0,
    this.views = 0,
    this.favoritesCount = 0,
    this.status = 'active',
    this.createdAt,
    this.sellerVipStatus = 'none',
    this.priorityLevel = 0,
    this.expiresAt,
  });

  factory MpProduct.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return MpProduct(
      id: doc.id,
      sellerId: d['sellerId'] ?? '',
      sellerName: d['sellerName'] ?? '',
      sellerPhone: d['sellerPhone'] ?? '',
      sellerCity: d['sellerCity'] ?? '',
      sellerVerified: d['sellerVerified'] == true,
      title: d['title'] ?? '',
      description: d['description'] ?? '',
      price: (d['price'] as num? ?? 0).toInt(),
      category: d['category'] ?? 'phones',
      subcategory: d['subcategory'] as String?,
      brand: d['brand'] ?? '',
      condition: d['condition'] ?? 'used',
      storage: d['storage'] as String?,
      ram: d['ram'] as String?,
      color: d['color'] as String?,
      battery: d['battery'] as String?,
      images: List<String>.from(d['images'] ?? []),
      city: d['city'] ?? 'Abengourou',
      lat: (d['lat'] as num? ?? 0).toDouble(),
      lng: (d['lng'] as num? ?? 0).toDouble(),
      views: (d['views'] as num? ?? 0).toInt(),
      favoritesCount: (d['favoritesCount'] as num? ?? 0).toInt(),
      status: d['status'] ?? 'active',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      sellerVipStatus: d['sellerVipStatus'] as String? ?? 'none',
      priorityLevel: (d['priorityLevel'] as num?)?.toInt() ?? 0,
      expiresAt: (d['expiresAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'sellerId': sellerId,
        'sellerName': sellerName,
        'sellerPhone': sellerPhone,
        'sellerCity': sellerCity,
        'sellerVerified': sellerVerified,
        'title': title,
        'titleSearch': title.toLowerCase(),
        'description': description,
        'price': price,
        'category': category,
        'subcategory': subcategory,
        'brand': brand,
        'brandSearch': brand.toLowerCase(),
        'condition': condition,
        'storage': storage,
        'ram': ram,
        'color': color,
        'battery': battery,
        'images': images,
        'city': city,
        'lat': lat,
        'lng': lng,
        'views': views,
        'favoritesCount': favoritesCount,
        'status': status,
        'createdAt': FieldValue.serverTimestamp(),
        'sellerVipStatus': sellerVipStatus,
        'priorityLevel': priorityLevel,
        'expiresAt': expiresAt == null ? null : Timestamp.fromDate(expiresAt!),
      };

  MpProduct copyWith({
    String? title,
    String? description,
    int? price,
    String? category,
    String? subcategory,
    String? brand,
    String? condition,
    String? storage,
    String? ram,
    String? color,
    String? battery,
    List<String>? images,
    String? city,
    String? status,
    String? sellerVipStatus,
    int? priorityLevel,
    DateTime? expiresAt,
  }) =>
      MpProduct(
        id: id,
        sellerId: sellerId,
        sellerName: sellerName,
        sellerPhone: sellerPhone,
        sellerCity: sellerCity,
        sellerVerified: sellerVerified,
        title: title ?? this.title,
        description: description ?? this.description,
        price: price ?? this.price,
        category: category ?? this.category,
        subcategory: subcategory ?? this.subcategory,
        brand: brand ?? this.brand,
        condition: condition ?? this.condition,
        storage: storage ?? this.storage,
        ram: ram ?? this.ram,
        color: color ?? this.color,
        battery: battery ?? this.battery,
        images: images ?? this.images,
        city: city ?? this.city,
        lat: lat,
        lng: lng,
        views: views,
        favoritesCount: favoritesCount,
        status: status ?? this.status,
        createdAt: createdAt,
        sellerVipStatus: sellerVipStatus ?? this.sellerVipStatus,
        priorityLevel: priorityLevel ?? this.priorityLevel,
        expiresAt: expiresAt ?? this.expiresAt,
      );
}
