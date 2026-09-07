import 'package:cloud_firestore/cloud_firestore.dart';

import 'models/vehicle_conversation.dart';
import 'models/vehicle_listing.dart';
import 'models/vehicle_seller_profile.dart';
import 'vehicle_trust_repository.dart';

class VehicleConversationsPage {
  const VehicleConversationsPage({
    required this.conversations,
    required this.nextCursor,
    required this.hasMore,
  });
  final List<VehicleConversation> conversations;
  final DocumentSnapshot<Map<String, dynamic>>? nextCursor;
  final bool hasMore;
}

abstract interface class VehicleConversationDataSource {
  Stream<List<VehicleChatMessage>> watchMessages(String conversationId);
  Future<void> sendMessage({
    required VehicleConversation conversation,
    required String senderId,
    required String text,
  });
  Future<void> markRead(VehicleConversation conversation, String uid);
  Future<VehicleConversationsPage> getConversations({
    required String uid,
    int pageSize = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  });
  Future<VehicleConversation?> getConversation(String id);
}

class VehicleConversationRepository implements VehicleConversationDataSource {
  VehicleConversationRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const collectionName = 'vehicle_conversations';
  static const messagePageSize = 50;
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _conversations =>
      _firestore.collection(collectionName);

  static String conversationIdFor(String listingId, String buyerId) =>
      'vc_${listingId}_$buyerId';

  Future<VehicleConversation> openConversation({
    required VehicleListing listing,
    required VehicleSellerProfile sellerProfile,
    required String buyerId,
  }) async {
    if (buyerId.isEmpty || buyerId == listing.sellerId) {
      throw StateError('Vous ne pouvez pas contacter votre propre annonce.');
    }
    final id = conversationIdFor(listing.id, buyerId);
    final ref = _conversations.doc(id);
    await _firestore.runTransaction((transaction) async {
      final existing = await transaction.get(ref);
      if (existing.exists) return;
      final currentListing = await transaction.get(
        _firestore.collection('vehicle_listings').doc(listing.id),
      );
      if (!currentListing.exists) throw StateError('Annonce introuvable.');
      final current = VehicleListing.fromDocument(currentListing);
      if (current.sellerId != listing.sellerId ||
          current.status != VehicleListingStatus.active) {
        throw StateError('Cette annonce n’est plus disponible.');
      }
      transaction.set(ref, {
        'listingId': listing.id,
        'buyerId': buyerId,
        'sellerId': listing.sellerId,
        'participantIds': [buyerId, listing.sellerId],
        'listingTitle': listing.title,
        'listingPrice': listing.price,
        'currency': listing.currency,
        if (listing.coverMedia?.downloadUrl case final imageUrl?)
          'listingImageUrl': imageUrl,
        'sellerDisplayName':
            sellerProfile.sellerType == VehicleSellerType.professional
                ? sellerProfile.shopName
                : sellerProfile.displayName,
        'sellerType': sellerProfile.sellerType.toFirestore(),
        'sellerVerificationStatus':
            sellerProfile.verificationStatus.toFirestore(),
        'lastMessagePreview': '',
        'lastSenderId': null,
        'buyerUnreadCount': 0,
        'sellerUnreadCount': 0,
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'lastMessageAt': FieldValue.serverTimestamp(),
      });
    });
    final snapshot = await ref.get();
    return VehicleConversation.fromMap(snapshot.id, snapshot.data()!);
  }

  @override
  Future<VehicleConversation?> getConversation(String id) async {
    final snapshot = await _conversations.doc(id).get();
    return snapshot.exists
        ? VehicleConversation.fromMap(snapshot.id, snapshot.data()!)
        : null;
  }

  @override
  Stream<List<VehicleChatMessage>> watchMessages(String conversationId) =>
      _conversations
          .doc(conversationId)
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .limit(messagePageSize)
          .snapshots()
          .map((snapshot) => snapshot.docs
              .map((doc) => VehicleChatMessage.fromMap(doc.id, doc.data()))
              .toList());

  @override
  Future<void> sendMessage({
    required VehicleConversation conversation,
    required String senderId,
    required String text,
  }) async {
    final validation = VehicleChatValidator.validateMessage(text);
    if (validation != null) throw ArgumentError(validation);
    if (!conversation.participantIds.contains(senderId)) {
      throw StateError('Utilisateur non autorisé.');
    }
    final trimmed = text.trim();
    final conversationRef = _conversations.doc(conversation.id);
    final messageRef = conversationRef.collection('messages').doc();
    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(conversationRef);
      if (!snapshot.exists) throw StateError('Conversation introuvable.');
      final current =
          VehicleConversation.fromMap(snapshot.id, snapshot.data()!);
      if (!current.participantIds.contains(senderId)) {
        throw StateError('Utilisateur non autorisé.');
      }
      final otherUid = current.participantIds.firstWhere(
        (uid) => uid != senderId,
      );
      if (await VehicleTrustRepository(firestore: _firestore)
          .isBlocked(senderId, otherUid)) {
        throw StateError('Conversation bloquée.');
      }
      transaction.set(messageRef, {
        'senderId': senderId,
        'text': trimmed,
        'type': 'text',
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.update(conversationRef, {
        'lastMessagePreview':
            trimmed.length <= 160 ? trimmed : '${trimmed.substring(0, 160)}…',
        'lastSenderId': senderId,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (senderId == current.buyerId)
          'sellerUnreadCount': current.sellerUnreadCount + 1
        else
          'buyerUnreadCount': current.buyerUnreadCount + 1,
      });
    });
  }

  @override
  Future<void> markRead(VehicleConversation conversation, String uid) async {
    if (!conversation.participantIds.contains(uid)) return;
    await _conversations.doc(conversation.id).update({
      uid == conversation.buyerId ? 'buyerUnreadCount' : 'sellerUnreadCount': 0,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<VehicleConversationsPage> getConversations({
    required String uid,
    int pageSize = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    var query = _conversations
        .where('participantIds', arrayContains: uid)
        .orderBy('lastMessageAt', descending: true)
        .limit(pageSize + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snapshot = await query.get();
    final docs = snapshot.docs.take(pageSize).toList();
    return VehicleConversationsPage(
      conversations: docs
          .map((doc) => VehicleConversation.fromMap(doc.id, doc.data()))
          .toList(),
      nextCursor: docs.isEmpty ? null : docs.last,
      hasMore: snapshot.docs.length > pageSize,
    );
  }
}
