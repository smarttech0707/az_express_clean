import 'package:cloud_firestore/cloud_firestore.dart';

import '../event_constants.dart';
import '../../models/professional_subscription.dart';

DateTime? _date(dynamic value) => value is Timestamp
    ? value.toDate()
    : value is DateTime
        ? value
        : null;

class EventProviderProfile {
  const EventProviderProfile({
    required this.id,
    required this.ownerId,
    required this.shopName,
    required this.description,
    required this.zone,
    this.logoUrl,
    this.phone = '',
    this.status = 'pending',
    this.isSuspended = false,
    this.rating = 0,
    this.reviewCount = 0,
    this.rejectionReason = '',
    this.categories = const [],
    this.subcategories = const [],
    this.suspensionReason = '',
    this.requestedPlan = SubscriptionPlan.standard,
    this.planStatus = ProfessionalPlanStatus.pending,
  });

  final String id;
  final String ownerId;
  final String shopName;
  final String description;
  final String zone;
  final String? logoUrl;
  final String phone;
  final String status;
  final bool isSuspended;
  final double rating;
  final int reviewCount;
  final String rejectionReason;
  final List<String> categories;
  final List<String> subcategories;
  final String suspensionReason;
  final SubscriptionPlan requestedPlan;
  final ProfessionalPlanStatus planStatus;

  bool get isVisible => status == 'approved' && !isSuspended;

  factory EventProviderProfile.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return EventProviderProfile(
      id: doc.id,
      ownerId: d['ownerId'] as String? ?? '',
      shopName: d['shopName'] as String? ?? 'Prestataire',
      description: d['description'] as String? ?? '',
      zone: d['zone'] as String? ?? '',
      logoUrl: d['logoUrl'] as String?,
      phone: d['phone'] as String? ?? '',
      status: d['status'] as String? ?? 'pending',
      isSuspended: d['isSuspended'] as bool? ?? false,
      rating: (d['rating'] as num?)?.toDouble() ?? 0,
      reviewCount: (d['reviewCount'] as num?)?.toInt() ?? 0,
      rejectionReason: d['rejectionReason'] as String? ?? '',
      categories: List<String>.from(d['categories'] ?? const []),
      subcategories: List<String>.from(d['subcategories'] ?? const []),
      suspensionReason: d['suspensionReason'] as String? ?? '',
      requestedPlan: SubscriptionPlan.values.firstWhere(
        (value) => value.name == d['requestedPlan'],
        orElse: () => SubscriptionPlan.standard,
      ),
      planStatus: ProfessionalPlanStatus.values.firstWhere(
        (value) => value.name == d['planStatus'],
        orElse: () => ProfessionalPlanStatus.pending,
      ),
    );
  }
}

class EventOffer {
  const EventOffer({
    required this.id,
    required this.providerId,
    required this.ownerId,
    required this.providerName,
    required this.title,
    required this.description,
    required this.category,
    required this.subcategory,
    required this.unitPrice,
    required this.availableQuantity,
    required this.zone,
    this.photoUrls = const [],
    this.videoUrls = const [],
    this.availableDays = const [],
    this.openingTime = '',
    this.closingTime = '',
    this.conditions = '',
    this.deliveryAvailable = false,
    this.installationAvailable = false,
    this.dismantlingAvailable = false,
    this.isActive = true,
    this.createdAt,
    this.plan = SubscriptionPlan.standard,
    this.priorityLevel = 1,
    this.featuredUntil,
    this.relevance = 0,
  });

  final String id;
  final String providerId;
  final String ownerId;
  final String providerName;
  final String title;
  final String description;
  final EventCategory category;
  final String subcategory;
  final int unitPrice;
  final int availableQuantity;
  final String zone;
  final List<String> photoUrls;
  final List<String> videoUrls;
  final List<String> availableDays;
  final String openingTime;
  final String closingTime;
  final String conditions;
  final bool deliveryAvailable;
  final bool installationAvailable;
  final bool dismantlingAvailable;
  final bool isActive;
  final DateTime? createdAt;
  final SubscriptionPlan plan;
  final int priorityLevel;
  final DateTime? featuredUntil;
  final double relevance;

  factory EventOffer.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return EventOffer(
      id: doc.id,
      providerId: d['providerId'] as String? ?? '',
      ownerId: d['ownerId'] as String? ?? '',
      providerName: d['providerName'] as String? ?? 'Prestataire',
      title: d['title'] as String? ?? '',
      description: d['description'] as String? ?? '',
      category: EventCategory.values.firstWhere(
        (e) => e.name == d['category'],
        orElse: () => EventCategory.rental,
      ),
      subcategory: d['subcategory'] as String? ?? '',
      unitPrice: (d['unitPrice'] as num?)?.toInt() ?? 0,
      availableQuantity: (d['availableQuantity'] as num?)?.toInt() ?? 0,
      zone: d['zone'] as String? ?? '',
      photoUrls: List<String>.from(d['photoUrls'] ?? const []),
      videoUrls: List<String>.from(d['videoUrls'] ?? const []),
      availableDays: List<String>.from(d['availableDays'] ?? const []),
      openingTime: d['openingTime'] as String? ?? '',
      closingTime: d['closingTime'] as String? ?? '',
      conditions: d['conditions'] as String? ?? '',
      deliveryAvailable: d['deliveryAvailable'] as bool? ?? false,
      installationAvailable: d['installationAvailable'] as bool? ?? false,
      dismantlingAvailable: d['dismantlingAvailable'] as bool? ?? false,
      isActive: d['isActive'] as bool? ?? true,
      createdAt: _date(d['createdAt']),
      plan: SubscriptionPlan.values.firstWhere(
        (value) => value.name == d['plan'],
        orElse: () => SubscriptionPlan.standard,
      ),
      priorityLevel: (d['priorityLevel'] as num?)?.toInt() ?? 1,
      featuredUntil: _date(d['featuredUntil']),
      relevance: (d['relevance'] as num?)?.toDouble() ??
          (d['rating'] as num?)?.toDouble() ??
          0,
    );
  }
}

class EventCartItem {
  const EventCartItem({required this.offer, required this.quantity});
  final EventOffer offer;
  final int quantity;
  int get total => offer.unitPrice * quantity;

  Map<String, dynamic> toMap() => {
        'offerId': offer.id,
        'providerId': offer.providerId,
        'providerName': offer.providerName,
        'title': offer.title,
        'category': offer.category.name,
        'subcategory': offer.subcategory,
        'unitPrice': offer.unitPrice,
        'quantity': quantity,
        'lineTotal': total,
        'photoUrl': offer.photoUrls.isEmpty ? null : offer.photoUrls.first,
      };
}

class EventReservation {
  const EventReservation({
    required this.id,
    required this.clientId,
    required this.items,
    required this.eventDate,
    required this.eventTime,
    required this.address,
    required this.description,
    required this.totalAmount,
    required this.paymentMethod,
    required this.status,
    this.latitude,
    this.longitude,
    this.delivery = false,
    this.installation = false,
    this.dismantling = false,
    this.createdAt,
  });

  final String id;
  final String clientId;
  final List<Map<String, dynamic>> items;
  final DateTime eventDate;
  final String eventTime;
  final String address;
  final String description;
  final int totalAmount;
  final String paymentMethod;
  final String status;
  final double? latitude;
  final double? longitude;
  final bool delivery;
  final bool installation;
  final bool dismantling;
  final DateTime? createdAt;

  factory EventReservation.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return EventReservation(
      id: doc.id,
      clientId: d['clientId'] as String? ?? '',
      items: List<Map<String, dynamic>>.from((d['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e))),
      eventDate: _date(d['eventDate']) ?? DateTime.now(),
      eventTime: d['eventTime'] as String? ?? '',
      address: d['address'] as String? ?? '',
      description: d['description'] as String? ?? '',
      totalAmount: (d['totalAmount'] as num?)?.toInt() ?? 0,
      paymentMethod: d['paymentMethod'] as String? ?? 'cash',
      status: d['status'] as String? ?? 'pending',
      latitude: (d['latitude'] as num?)?.toDouble(),
      longitude: (d['longitude'] as num?)?.toDouble(),
      delivery: d['delivery'] as bool? ?? false,
      installation: d['installation'] as bool? ?? false,
      dismantling: d['dismantling'] as bool? ?? false,
      createdAt: _date(d['createdAt']),
    );
  }
}
