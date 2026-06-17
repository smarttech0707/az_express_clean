import 'package:cloud_firestore/cloud_firestore.dart';

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
  final int?    sellerRating;
  final double? destLat;   // latitude destination livraison (compat)
  final double? destLng;   // longitude destination livraison (compat)
  // ── Nouveaux champs adresse structurés ───────────────────────────────────
  final String? deliveryAddress;  // adresse textuelle du lieu de livraison
  final double? pickupLat;        // coordonnées du lieu de collecte
  final double? pickupLng;
  final bool    forSelf;          // true = pour moi, false = pour quelqu'un d'autre
  final String  deliveryMode;     // 'standard' | 'express'
  final String? recipientPhone;   // téléphone destinataire
  final String? recipientName;    // nom du destinataire
  final String? pickupContactName;  // nom du récupérateur au point de collecte
  final String? pickupContactPhone; // téléphone du récupérateur
  final String? pickupZone;         // zone de collecte sélectionnée
  final String? deliveryZone;       // zone de livraison sélectionnée
  final double? deliveredLat;       // GPS final au moment de la livraison
  final double? deliveredLng;
  final DateTime? deliveredAt;      // horodatage de livraison effective

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
    this.deliveredLat,
    this.deliveredLng,
    this.deliveredAt,
  });

  factory OrderModel.fromMap(String id, Map<String, dynamic> data) {
    return OrderModel(
      id: id,
      description: data['description'] ?? '',
      budget: (data['budget'] as num? ?? 0).toInt(),
      status: data['status'] ?? 'pending',
      latitude: (data['latitude'] ?? 0).toDouble(),
      longitude: (data['longitude'] ?? 0).toDouble(),
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
      destLat:  (data['destLat']  as num?)?.toDouble(),
      destLng:  (data['destLng']  as num?)?.toDouble(),
      deliveryAddress: data['deliveryAddress'] as String?,
      pickupLat: (data['pickupLatitude']  as num?)?.toDouble(),
      pickupLng: (data['pickupLongitude'] as num?)?.toDouble(),
      forSelf:       data['forSelf']       as bool?   ?? true,
      deliveryMode:  data['deliveryMode']  as String? ?? 'standard',
      recipientPhone:    data['recipientPhone']    as String?,
      recipientName:     data['recipientName']     as String?,
      pickupContactName: data['pickupContactName'] as String?,
      pickupContactPhone:data['pickupContactPhone']as String?,
      pickupZone:        data['pickupZone']        as String?,
      deliveryZone:      data['deliveryZone']      as String?,
      deliveredLat:  (data['deliveredLat']  as num?)?.toDouble(),
      deliveredLng:  (data['deliveredLng']  as num?)?.toDouble(),
      deliveredAt:   data['deliveredAt'] != null
          ? (data['deliveredAt'] as Timestamp).toDate()
          : null,
    );
  }

  int get totalAmount => budget + shoppingBudget;

  Map<String, dynamic> toMap() {
    return {
      'description':    description,
      'budget':         budget,
      'shoppingBudget': shoppingBudget,
      'status':         status,
      'latitude':       latitude,
      'longitude':      longitude,
      'type':           type,
      'clientId':       clientId,
      'clientName':     clientName,
      'clientPhone':    clientPhone,
      'paymentMethod':  paymentMethod,
      'isPaid':         isPaid,
      'createdAt':      Timestamp.now(),
      // Champs optionnels — inclus seulement si non null
      // (notPresent('driverId') dans les règles Firestore doit être respecté)
      if (driverId              != null) 'driverId':              driverId,
      if (voiceMessage          != null) 'voiceMessage':          voiceMessage,
      if (rating                != null) 'rating':                rating,
      if (sellerRating          != null) 'sellerRating':          sellerRating,
      if (deliveryPhoto         != null) 'deliveryPhoto':         deliveryPhoto,
      if (driverAcceptanceSelfie != null) 'driverAcceptanceSelfie': driverAcceptanceSelfie,
      if (driverPhotoUrl        != null) 'driverPhotoUrl':        driverPhotoUrl,
      if (pickupAddress         != null) 'pickupAddress':         pickupAddress,
      if (sellerId              != null) 'sellerId':              sellerId,
      if (sellerName            != null) 'sellerName':            sellerName,
      if (sellerType            != null) 'sellerType':            sellerType,
      if (linkedBoutiqueOrderId != null) 'linkedBoutiqueOrderId': linkedBoutiqueOrderId,
      if (medicineAmount        != null) 'medicineAmount':        medicineAmount,
      if (pharmacieId           != null) 'pharmacieId':           pharmacieId,
      if (pharmacieName         != null) 'pharmacieName':         pharmacieName,
      if (destLat          != null) 'destLat':          destLat,
      if (destLng          != null) 'destLng':          destLng,
      // Champs adresse structurés (nouveaux)
      'deliveryLatitude':  latitude,
      'deliveryLongitude': longitude,
      'forSelf':           forSelf,
      if (deliveryAddress  != null) 'deliveryAddress':  deliveryAddress,
      if (pickupLat        != null) 'pickupLatitude':   pickupLat,
      if (pickupLng        != null) 'pickupLongitude':  pickupLng,
      'deliveryMode':    deliveryMode,
      if (recipientPhone     != null) 'recipientPhone':     recipientPhone,
      if (recipientName      != null) 'recipientName':      recipientName,
      if (pickupContactName  != null) 'pickupContactName':  pickupContactName,
      if (pickupContactPhone != null) 'pickupContactPhone': pickupContactPhone,
      if (pickupZone         != null) 'pickupZone':         pickupZone,
      if (deliveryZone       != null) 'deliveryZone':       deliveryZone,
      if (deliveredLat       != null) 'deliveredLat':       deliveredLat,
      if (deliveredLng       != null) 'deliveredLng':       deliveredLng,
      if (deliveredAt        != null) 'deliveredAt':        Timestamp.fromDate(deliveredAt!),
    };
  }
}