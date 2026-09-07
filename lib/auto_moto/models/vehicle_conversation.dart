import 'package:cloud_firestore/cloud_firestore.dart';

import 'vehicle_listing.dart';
import 'vehicle_seller_profile.dart';

enum VehicleConversationStatus { active, closed, unknown }

enum VehicleMessageType { text, unknown }

class VehicleConversation {
  const VehicleConversation({
    required this.id,
    required this.listingId,
    required this.buyerId,
    required this.sellerId,
    required this.participantIds,
    required this.listingTitle,
    required this.listingPrice,
    required this.currency,
    this.listingImageUrl,
    required this.sellerDisplayName,
    required this.sellerType,
    required this.sellerVerificationStatus,
    this.lastMessagePreview = '',
    this.lastSenderId,
    this.buyerUnreadCount = 0,
    this.sellerUnreadCount = 0,
    this.status = VehicleConversationStatus.active,
    this.createdAt,
    this.updatedAt,
    this.lastMessageAt,
  });

  final String id;
  final String listingId;
  final String buyerId;
  final String sellerId;
  final List<String> participantIds;
  final String listingTitle;
  final int listingPrice;
  final String currency;
  final String? listingImageUrl;
  final String sellerDisplayName;
  final VehicleSellerType sellerType;
  final VehicleSellerVerificationStatus sellerVerificationStatus;
  final String lastMessagePreview;
  final String? lastSenderId;
  final int buyerUnreadCount;
  final int sellerUnreadCount;
  final VehicleConversationStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastMessageAt;

  int unreadFor(String uid) => uid == buyerId
      ? buyerUnreadCount
      : uid == sellerId
          ? sellerUnreadCount
          : 0;

  factory VehicleConversation.fromMap(String id, Map<String, dynamic> data) =>
      VehicleConversation(
        id: id,
        listingId: data['listingId'] as String? ?? '',
        buyerId: data['buyerId'] as String? ?? '',
        sellerId: data['sellerId'] as String? ?? '',
        participantIds:
            (data['participantIds'] as List?)?.whereType<String>().toList() ??
                const [],
        listingTitle: data['listingTitle'] as String? ?? 'Annonce Auto & Moto',
        listingPrice: (data['listingPrice'] as num?)?.toInt() ?? 0,
        currency: data['currency'] as String? ?? 'XOF',
        listingImageUrl: data['listingImageUrl'] as String?,
        sellerDisplayName: data['sellerDisplayName'] as String? ?? 'Vendeur',
        sellerType: vehicleSellerTypeFromFirestore(data['sellerType']),
        sellerVerificationStatus:
            verificationStatusFromFirestore(data['sellerVerificationStatus']),
        lastMessagePreview: data['lastMessagePreview'] as String? ?? '',
        lastSenderId: data['lastSenderId'] as String?,
        buyerUnreadCount: (data['buyerUnreadCount'] as num?)?.toInt() ?? 0,
        sellerUnreadCount: (data['sellerUnreadCount'] as num?)?.toInt() ?? 0,
        status: switch (data['status']) {
          'active' => VehicleConversationStatus.active,
          'closed' => VehicleConversationStatus.closed,
          _ => VehicleConversationStatus.unknown,
        },
        createdAt: _date(data['createdAt']),
        updatedAt: _date(data['updatedAt']),
        lastMessageAt: _date(data['lastMessageAt']),
      );
}

class VehicleChatMessage {
  const VehicleChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    this.type = VehicleMessageType.text,
    this.createdAt,
  });

  final String id;
  final String senderId;
  final String text;
  final VehicleMessageType type;
  final DateTime? createdAt;

  factory VehicleChatMessage.fromMap(String id, Map<String, dynamic> data) =>
      VehicleChatMessage(
        id: id,
        senderId: data['senderId'] as String? ?? '',
        text: data['text'] as String? ?? '',
        type: data['type'] == 'text'
            ? VehicleMessageType.text
            : VehicleMessageType.unknown,
        createdAt: _date(data['createdAt']),
      );
}

class VehicleChatValidator {
  const VehicleChatValidator._();
  static const maxMessageLength = 1000;

  static String? validateMessage(String value) {
    final text = value.trim();
    if (text.isEmpty) return 'Écrivez un message.';
    if (text.length > maxMessageLength) {
      return 'Le message est limité à 1000 caractères.';
    }
    return null;
  }
}

DateTime? _date(Object? value) => switch (value) {
      Timestamp timestamp => timestamp.toDate(),
      DateTime date => date,
      _ => null,
    };
