import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'shopping_item.dart';

/// Contrat géographique de toute commande envoyée au dispatch :
/// - [latitude]/[longitude] désignent le point de collecte ;
/// - [destLat]/[destLng] désignent le point de livraison.
///
/// Ces deux points doivent être des coordonnées réelles et distinctes sur le
/// plan sémantique, même lorsqu'un service (comme les courses) les place au
/// même endroit par décision métier.
class OrderModel {
  final String id;
  final String description;
  final int budget;
  final String status;
  final double latitude;
  final double longitude;
  final String type;
  final String? driverId;
  final String? clientId;
  final String? clientName;
  final String? clientPhone;
  final String? voiceMessage;
  final DateTime? createdAt;

  final int? rating;
  final String? deliveryPhoto;
  final int shoppingBudget;
  final String? driverAcceptanceSelfie;
  final String? driverPhotoUrl;
  final String? pickupAddress;
  final String paymentMethod;
  final String? sellerId;
  final String? sellerName;
  final String? sellerType;
  final String? linkedBoutiqueOrderId;
  final bool isPaid;
  final int? medicineAmount;
  final String? pharmacieId;
  final String? pharmacieName;
  final int? sellerRating;
  final double? destLat; // latitude destination livraison (compat)
  final double? destLng; // longitude destination livraison (compat)
  // ── Nouveaux champs adresse structurés ───────────────────────────────────
  final String? deliveryAddress; // adresse textuelle du lieu de livraison
  final double? pickupLat; // coordonnées du lieu de collecte
  final double? pickupLng;
  final bool forSelf; // true = pour moi, false = pour quelqu'un d'autre
  final String deliveryMode; // 'standard' | 'express'
  final String? recipientPhone; // téléphone destinataire
  final String? recipientName; // nom du destinataire
  final String? pickupContactName; // nom du récupérateur au point de collecte
  final String? pickupContactPhone; // téléphone du récupérateur
  final String? pickupZone; // zone de collecte sélectionnée
  final String? deliveryZone; // zone de livraison sélectionnée
  final String? pickupCityId;
  final String? deliveryCityId;
  final String? pickupZoneId;
  final String? deliveryZoneId;
  final String? pickupCoordinateSource;
  final String? deliveryCoordinateSource;
  final String? gpsDetectedCityId;
  final String? activeCityId;
  final String? citySelectionSource;
  final String? cityResolutionStatus;
  final double? deliveredLat; // GPS final au moment de la livraison
  final double? deliveredLng;
  final DateTime? deliveredAt; // horodatage de livraison effective
  final List<ShoppingItem>?
      items; // liste d'articles courses (ex. AZ IA) — nullable, additif

  OrderModel({
    required this.id,
    required this.description,
    required this.budget,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.type,
    this.driverId,
    this.clientId,
    this.clientName,
    this.clientPhone,
    this.voiceMessage,
    this.createdAt,
    this.rating,
    this.deliveryPhoto,
    this.shoppingBudget = 0,
    this.driverAcceptanceSelfie,
    this.driverPhotoUrl,
    this.pickupAddress,
    this.paymentMethod = 'cash',
    this.sellerId,
    this.sellerName,
    this.sellerType,
    this.linkedBoutiqueOrderId,
    this.isPaid = false,
    this.medicineAmount,
    this.pharmacieId,
    this.pharmacieName,
    this.sellerRating,
    this.destLat,
    this.destLng,
    this.deliveryAddress,
    this.pickupLat,
    this.pickupLng,
    this.forSelf = true,
    this.deliveryMode = 'standard',
    this.recipientPhone,
    this.recipientName,
    this.pickupContactName,
    this.pickupContactPhone,
    this.pickupZone,
    this.deliveryZone,
    this.pickupCityId,
    this.deliveryCityId,
    this.pickupZoneId,
    this.deliveryZoneId,
    this.pickupCoordinateSource,
    this.deliveryCoordinateSource,
    this.gpsDetectedCityId,
    this.activeCityId,
    this.citySelectionSource,
    this.cityResolutionStatus,
    this.deliveredLat,
    this.deliveredLng,
    this.deliveredAt,
    this.items,
  });

  factory OrderModel.fromMap(String id, Map<String, dynamic> data) {
    return OrderModel(
      id: id,
      description: data['description'] ?? '',
      budget: (data['budget'] as num? ?? 0).toInt(),
      status: data['status'] ?? 'pending',
      latitude: (data['latitude'] ?? data['deliveryLatitude'] ?? 0).toDouble(),
      longitude:
          (data['longitude'] ?? data['deliveryLongitude'] ?? 0).toDouble(),
      type: data['type'] ?? 'shopping',
      driverId: data['driverId'],
      clientId: data['clientId'],
      clientName: data['clientName'],
      clientPhone: data['clientPhone'],
      voiceMessage: data['voiceMessage'],
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
      rating: data['rating'],
      deliveryPhoto: data['deliveryPhoto'],
      shoppingBudget: (data['shoppingBudget'] as num? ?? 0).toInt(),
      driverAcceptanceSelfie: data['driverAcceptanceSelfie'],
      driverPhotoUrl: data['driverPhotoUrl'],
      pickupAddress: data['pickupAddress'],
      paymentMethod: data['paymentMethod'] ?? 'cash',
      sellerId: data['sellerId'],
      sellerName: data['sellerName'],
      sellerType: data['sellerType'],
      linkedBoutiqueOrderId: data['linkedBoutiqueOrderId'],
      isPaid: data['isPaid'] == true,
      medicineAmount: (data['medicineAmount'] as num?)?.toInt(),
      pharmacieId: data['pharmacieId'] as String?,
      pharmacieName: data['pharmacieName'] as String?,
      sellerRating: (data['sellerRating'] as num?)?.toInt(),
      destLat: (data['destLat'] as num?)?.toDouble(),
      destLng: (data['destLng'] as num?)?.toDouble(),
      deliveryAddress: data['deliveryAddress'] as String?,
      pickupLat: (data['pickupLatitude'] as num?)?.toDouble(),
      pickupLng: (data['pickupLongitude'] as num?)?.toDouble(),
      forSelf: data['forSelf'] as bool? ?? true,
      deliveryMode: data['deliveryMode'] as String? ?? 'standard',
      recipientPhone: data['recipientPhone'] as String?,
      recipientName: data['recipientName'] as String?,
      pickupContactName: data['pickupContactName'] as String?,
      pickupContactPhone: data['pickupContactPhone'] as String?,
      pickupZone: data['pickupZone'] as String?,
      deliveryZone: data['deliveryZone'] as String?,
      pickupCityId: data['pickupCityId'] as String?,
      deliveryCityId: data['deliveryCityId'] as String?,
      pickupZoneId: data['pickupZoneId'] as String?,
      deliveryZoneId: data['deliveryZoneId'] as String?,
      pickupCoordinateSource: data['pickupCoordinateSource'] as String?,
      deliveryCoordinateSource: data['deliveryCoordinateSource'] as String?,
      gpsDetectedCityId: data['gpsDetectedCityId'] as String?,
      activeCityId: data['activeCityId'] as String?,
      citySelectionSource: data['citySelectionSource'] as String?,
      cityResolutionStatus: data['cityResolutionStatus'] as String?,
      deliveredLat: (data['deliveredLat'] as num?)?.toDouble(),
      deliveredLng: (data['deliveredLng'] as num?)?.toDouble(),
      deliveredAt: data['deliveredAt'] != null
          ? (data['deliveredAt'] as Timestamp).toDate()
          : null,
      items: (data['items'] as List?)
          ?.map(
              (e) => ShoppingItem.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  int get totalAmount => budget + shoppingBudget;

  Map<String, dynamic> toMap() {
    return {
      'description': description,
      'budget': budget,
      'shoppingBudget': shoppingBudget,
      'status': status,
      'latitude': latitude,
      'longitude': longitude,
      'type': type,
      'clientId': clientId,
      'clientName': clientName,
      'clientPhone': clientPhone,
      'paymentMethod': paymentMethod,
      'isPaid': isPaid,
      'createdAt': Timestamp.now(),
      // Champs optionnels — inclus seulement si non null
      // (notPresent('driverId') dans les règles Firestore doit être respecté)
      if (driverId != null) 'driverId': driverId,
      if (voiceMessage != null) 'voiceMessage': voiceMessage,
      if (rating != null) 'rating': rating,
      if (sellerRating != null) 'sellerRating': sellerRating,
      if (deliveryPhoto != null) 'deliveryPhoto': deliveryPhoto,
      if (driverAcceptanceSelfie != null)
        'driverAcceptanceSelfie': driverAcceptanceSelfie,
      if (driverPhotoUrl != null) 'driverPhotoUrl': driverPhotoUrl,
      if (pickupAddress != null) 'pickupAddress': pickupAddress,
      if (sellerId != null) 'sellerId': sellerId,
      if (sellerName != null) 'sellerName': sellerName,
      if (sellerType != null) 'sellerType': sellerType,
      if (linkedBoutiqueOrderId != null)
        'linkedBoutiqueOrderId': linkedBoutiqueOrderId,
      if (medicineAmount != null) 'medicineAmount': medicineAmount,
      if (pharmacieId != null) 'pharmacieId': pharmacieId,
      if (pharmacieName != null) 'pharmacieName': pharmacieName,
      if (destLat != null) 'destLat': destLat,
      if (destLng != null) 'destLng': destLng,
      // Champs adresse structurés (nouveaux)
      'deliveryLatitude': latitude,
      'deliveryLongitude': longitude,
      'forSelf': forSelf,
      if (deliveryAddress != null) 'deliveryAddress': deliveryAddress,
      if (pickupLat != null) 'pickupLatitude': pickupLat,
      if (pickupLng != null) 'pickupLongitude': pickupLng,
      'deliveryMode': deliveryMode,
      if (recipientPhone != null) 'recipientPhone': recipientPhone,
      if (recipientName != null) 'recipientName': recipientName,
      if (pickupContactName != null) 'pickupContactName': pickupContactName,
      if (pickupContactPhone != null) 'pickupContactPhone': pickupContactPhone,
      if (pickupZone != null) 'pickupZone': pickupZone,
      if (deliveryZone != null) 'deliveryZone': deliveryZone,
      if (pickupCityId != null) 'pickupCityId': pickupCityId,
      if (deliveryCityId != null) 'deliveryCityId': deliveryCityId,
      if (pickupZoneId != null) 'pickupZoneId': pickupZoneId,
      if (deliveryZoneId != null) 'deliveryZoneId': deliveryZoneId,
      if (pickupCoordinateSource != null)
        'pickupCoordinateSource': pickupCoordinateSource,
      if (deliveryCoordinateSource != null)
        'deliveryCoordinateSource': deliveryCoordinateSource,
      if (gpsDetectedCityId != null) 'gpsDetectedCityId': gpsDetectedCityId,
      if (activeCityId != null) 'activeCityId': activeCityId,
      if (citySelectionSource != null)
        'citySelectionSource': citySelectionSource,
      if (cityResolutionStatus != null)
        'cityResolutionStatus': cityResolutionStatus,
      if (deliveredLat != null) 'deliveredLat': deliveredLat,
      if (deliveredLng != null) 'deliveredLng': deliveredLng,
      if (deliveredAt != null) 'deliveredAt': Timestamp.fromDate(deliveredAt!),
      if (items != null) 'items': items!.map((e) => e.toMap()).toList(),
    };
  }

  OrderModel copyWith({
    String? id,
    String? description,
    int? budget,
    String? status,
    double? latitude,
    double? longitude,
    String? type,
    String? driverId,
    String? clientId,
    String? clientName,
    String? clientPhone,
    String? voiceMessage,
    DateTime? createdAt,
    int? rating,
    String? deliveryPhoto,
    int? shoppingBudget,
    String? driverAcceptanceSelfie,
    String? driverPhotoUrl,
    String? pickupAddress,
    String? paymentMethod,
    String? sellerId,
    String? sellerName,
    String? sellerType,
    String? linkedBoutiqueOrderId,
    bool? isPaid,
    int? medicineAmount,
    String? pharmacieId,
    String? pharmacieName,
    int? sellerRating,
    double? destLat,
    double? destLng,
    String? deliveryAddress,
    double? pickupLat,
    double? pickupLng,
    bool? forSelf,
    String? deliveryMode,
    String? recipientPhone,
    String? recipientName,
    String? pickupContactName,
    String? pickupContactPhone,
    String? pickupZone,
    String? deliveryZone,
    String? pickupCityId,
    String? deliveryCityId,
    String? pickupZoneId,
    String? deliveryZoneId,
    String? pickupCoordinateSource,
    String? deliveryCoordinateSource,
    String? gpsDetectedCityId,
    String? activeCityId,
    String? citySelectionSource,
    String? cityResolutionStatus,
    double? deliveredLat,
    double? deliveredLng,
    DateTime? deliveredAt,
    List<ShoppingItem>? items,
  }) {
    return OrderModel(
      id: id ?? this.id,
      description: description ?? this.description,
      budget: budget ?? this.budget,
      status: status ?? this.status,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      type: type ?? this.type,
      driverId: driverId ?? this.driverId,
      clientId: clientId ?? this.clientId,
      clientName: clientName ?? this.clientName,
      clientPhone: clientPhone ?? this.clientPhone,
      voiceMessage: voiceMessage ?? this.voiceMessage,
      createdAt: createdAt ?? this.createdAt,
      rating: rating ?? this.rating,
      deliveryPhoto: deliveryPhoto ?? this.deliveryPhoto,
      shoppingBudget: shoppingBudget ?? this.shoppingBudget,
      driverAcceptanceSelfie:
          driverAcceptanceSelfie ?? this.driverAcceptanceSelfie,
      driverPhotoUrl: driverPhotoUrl ?? this.driverPhotoUrl,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      sellerId: sellerId ?? this.sellerId,
      sellerName: sellerName ?? this.sellerName,
      sellerType: sellerType ?? this.sellerType,
      linkedBoutiqueOrderId:
          linkedBoutiqueOrderId ?? this.linkedBoutiqueOrderId,
      isPaid: isPaid ?? this.isPaid,
      medicineAmount: medicineAmount ?? this.medicineAmount,
      pharmacieId: pharmacieId ?? this.pharmacieId,
      pharmacieName: pharmacieName ?? this.pharmacieName,
      sellerRating: sellerRating ?? this.sellerRating,
      destLat: destLat ?? this.destLat,
      destLng: destLng ?? this.destLng,
      deliveryAddress: deliveryAddress ?? this.deliveryAddress,
      pickupLat: pickupLat ?? this.pickupLat,
      pickupLng: pickupLng ?? this.pickupLng,
      forSelf: forSelf ?? this.forSelf,
      deliveryMode: deliveryMode ?? this.deliveryMode,
      recipientPhone: recipientPhone ?? this.recipientPhone,
      recipientName: recipientName ?? this.recipientName,
      pickupContactName: pickupContactName ?? this.pickupContactName,
      pickupContactPhone: pickupContactPhone ?? this.pickupContactPhone,
      pickupZone: pickupZone ?? this.pickupZone,
      deliveryZone: deliveryZone ?? this.deliveryZone,
      pickupCityId: pickupCityId ?? this.pickupCityId,
      deliveryCityId: deliveryCityId ?? this.deliveryCityId,
      pickupZoneId: pickupZoneId ?? this.pickupZoneId,
      deliveryZoneId: deliveryZoneId ?? this.deliveryZoneId,
      pickupCoordinateSource:
          pickupCoordinateSource ?? this.pickupCoordinateSource,
      deliveryCoordinateSource:
          deliveryCoordinateSource ?? this.deliveryCoordinateSource,
      gpsDetectedCityId: gpsDetectedCityId ?? this.gpsDetectedCityId,
      activeCityId: activeCityId ?? this.activeCityId,
      citySelectionSource: citySelectionSource ?? this.citySelectionSource,
      cityResolutionStatus: cityResolutionStatus ?? this.cityResolutionStatus,
      deliveredLat: deliveredLat ?? this.deliveredLat,
      deliveredLng: deliveredLng ?? this.deliveredLng,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      items: items ?? this.items,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderModel &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          description == other.description &&
          budget == other.budget &&
          status == other.status &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          type == other.type &&
          driverId == other.driverId &&
          clientId == other.clientId &&
          clientName == other.clientName &&
          clientPhone == other.clientPhone &&
          voiceMessage == other.voiceMessage &&
          createdAt == other.createdAt &&
          rating == other.rating &&
          deliveryPhoto == other.deliveryPhoto &&
          shoppingBudget == other.shoppingBudget &&
          driverAcceptanceSelfie == other.driverAcceptanceSelfie &&
          driverPhotoUrl == other.driverPhotoUrl &&
          pickupAddress == other.pickupAddress &&
          paymentMethod == other.paymentMethod &&
          sellerId == other.sellerId &&
          sellerName == other.sellerName &&
          sellerType == other.sellerType &&
          linkedBoutiqueOrderId == other.linkedBoutiqueOrderId &&
          isPaid == other.isPaid &&
          medicineAmount == other.medicineAmount &&
          pharmacieId == other.pharmacieId &&
          pharmacieName == other.pharmacieName &&
          sellerRating == other.sellerRating &&
          destLat == other.destLat &&
          destLng == other.destLng &&
          deliveryAddress == other.deliveryAddress &&
          pickupLat == other.pickupLat &&
          pickupLng == other.pickupLng &&
          forSelf == other.forSelf &&
          deliveryMode == other.deliveryMode &&
          recipientPhone == other.recipientPhone &&
          recipientName == other.recipientName &&
          pickupContactName == other.pickupContactName &&
          pickupContactPhone == other.pickupContactPhone &&
          pickupZone == other.pickupZone &&
          deliveryZone == other.deliveryZone &&
          pickupCityId == other.pickupCityId &&
          deliveryCityId == other.deliveryCityId &&
          pickupZoneId == other.pickupZoneId &&
          deliveryZoneId == other.deliveryZoneId &&
          pickupCoordinateSource == other.pickupCoordinateSource &&
          deliveryCoordinateSource == other.deliveryCoordinateSource &&
          gpsDetectedCityId == other.gpsDetectedCityId &&
          activeCityId == other.activeCityId &&
          citySelectionSource == other.citySelectionSource &&
          cityResolutionStatus == other.cityResolutionStatus &&
          deliveredLat == other.deliveredLat &&
          deliveredLng == other.deliveredLng &&
          deliveredAt == other.deliveredAt &&
          listEquals(items, other.items);

  @override
  int get hashCode => Object.hash(
        id,
        description,
        budget,
        status,
        latitude,
        longitude,
        type,
        driverId,
        clientId,
        clientName,
        Object.hash(
          clientPhone,
          voiceMessage,
          createdAt,
          rating,
          deliveryPhoto,
          shoppingBudget,
          driverAcceptanceSelfie,
          driverPhotoUrl,
          pickupAddress,
          paymentMethod,
        ),
        Object.hash(
          sellerId,
          sellerName,
          sellerType,
          linkedBoutiqueOrderId,
          isPaid,
          medicineAmount,
          pharmacieId,
          pharmacieName,
          sellerRating,
          destLat,
        ),
        Object.hash(
          destLng,
          deliveryAddress,
          pickupLat,
          pickupLng,
          forSelf,
          deliveryMode,
          recipientPhone,
          recipientName,
          pickupContactName,
          pickupContactPhone,
        ),
        Object.hash(
          pickupZone,
          deliveryZone,
          pickupCityId,
          deliveryCityId,
          pickupZoneId,
          deliveryZoneId,
          pickupCoordinateSource,
          deliveryCoordinateSource,
          gpsDetectedCityId,
          activeCityId,
        ),
        Object.hash(
          citySelectionSource,
          cityResolutionStatus,
          deliveredLat,
          deliveredLng,
          deliveredAt,
          Object.hashAll(items ?? const []),
        ),
      );
}
