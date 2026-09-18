import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../event_constants.dart';
import '../models/event_models.dart';
import 'event_reservation_attempts.dart';
import '../../models/professional_subscription.dart';
import '../../services/notification_service.dart';

class EventService {
  EventService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    FirebaseFunctions? functions,
  })  : db = firestore ?? FirebaseFirestore.instance,
        auth = auth ?? FirebaseAuth.instance,
        _storage = storage,
        functions = functions ??
            FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore db;
  final FirebaseAuth auth;
  // LOT 7.1 : résolu paresseusement — FirebaseStorage.instance lève sans
  // bucket par défaut configuré (ex. dans un test qui n'exerce jamais
  // l'upload). Construire EventService() pour n'utiliser que .functions/.db
  // (comme le test de routage régional) ne doit jamais échouer pour une
  // dépendance non utilisée. Comportement réel inchangé : le premier accès
  // résout FirebaseStorage.instance exactement comme avant.
  FirebaseStorage? _storage;
  FirebaseStorage get storage => _storage ??= FirebaseStorage.instance;
  final FirebaseFunctions functions;
  static const pageSize = 20;

  String newProviderId() => uid;

  Future<String> uploadProviderFile({
    required String providerId,
    required String path,
    required String kind,
  }) async {
    if (kIsWeb) throw UnsupportedError('Envoi web non configuré');
    final extension = path.contains('.') ? path.split('.').last : 'jpg';
    final ref = storage.ref(
      'event_providers/$uid/$providerId/$kind/'
      '${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await ref.putFile(File(path));
    return ref.getDownloadURL();
  }

  Future<void> submitProviderApplication({
    required String providerId,
    required Map<String, dynamic> profile,
    required List<Map<String, dynamic>> offers,
    required String requestedPlan,
  }) async {
    if (offers.isEmpty) throw ArgumentError('Une prestation est requise');
    final provider = db.collection('event_providers').doc(providerId);
    final existing = await db
        .collection('event_providers')
        .where('ownerId', isEqualTo: uid)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      throw StateError('Une demande prestataire existe déjà');
    }
    final documents =
        Map<String, dynamic>.from(profile['documents'] as Map? ?? const {});
    final publicProfile = Map<String, dynamic>.from(profile)
      ..remove('documents');
    final offerRefs =
        offers.map((_) => db.collection('event_offers').doc()).toList();
    await db.runTransaction((transaction) async {
      if ((await transaction.get(provider)).exists) {
        throw StateError('Une demande prestataire existe déjà');
      }
      transaction.set(provider, {
        ...publicProfile,
        'ownerId': uid,
        'status': 'pending',
        'isSuspended': false,
        'rating': 0,
        'reviewCount': 0,
        'rejectionReason': '',
        'suspensionReason': '',
        'requestedPlan': requestedPlan,
        'planStatus': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      transaction
          .set(db.collection('event_provider_documents').doc(providerId), {
        ...documents,
        'ownerId': uid,
        'providerId': providerId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      for (var index = 0; index < offers.length; index++) {
        transaction.set(offerRefs[index], {
          ...offers[index],
          'providerId': providerId,
          'providerName': profile['shopName'],
          'ownerId': uid,
          'isActive': false,
          'photoUrls': <String>[],
          'videoUrls': <String>[],
          'availableDays': <String>[],
          'openingTime': '',
          'closingTime': '',
          'conditions': '',
          'zone': profile['interventionZone'],
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  String get uid {
    final value = auth.currentUser?.uid;
    if (value == null) throw StateError('Connexion requise');
    return value;
  }

  Future<(List<EventOffer>, DocumentSnapshot<Map<String, dynamic>>?)>
      fetchOffers({
    EventCategory? category,
    String? subcategory,
    String? zone,
    DocumentSnapshot<Map<String, dynamic>>? after,
  }) async {
    Query<Map<String, dynamic>> q = db
        .collection('event_offers')
        .where('isActive', isEqualTo: true)
        .orderBy('createdAt', descending: true);
    if (category != null) q = q.where('category', isEqualTo: category.name);
    if (subcategory?.isNotEmpty == true) {
      q = q.where('subcategory', isEqualTo: subcategory);
    }
    if (zone?.trim().isNotEmpty == true) {
      q = q.where('zone', isEqualTo: zone!.trim());
    }
    if (after != null) q = q.startAfterDocument(after);
    final snap = await q.limit(pageSize).get();
    final offers = snap.docs.map(EventOffer.fromDoc).toList()
      ..sort((left, right) => compareProfessionalListings(
            leftPlan: left.plan,
            leftActive: left.isActive,
            leftFeaturedUntil: left.featuredUntil,
            leftPublishedAt:
                left.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            leftRelevance: left.relevance,
            rightPlan: right.plan,
            rightActive: right.isActive,
            rightFeaturedUntil: right.featuredUntil,
            rightPublishedAt:
                right.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            rightRelevance: right.relevance,
          ));
    return (offers, snap.docs.isEmpty ? null : snap.docs.last);
  }

  Stream<EventProviderProfile?> watchMyProfile() => db
      .collection('event_providers')
      .where('ownerId', isEqualTo: uid)
      .limit(1)
      .snapshots()
      .map((s) =>
          s.docs.isEmpty ? null : EventProviderProfile.fromDoc(s.docs.first));

  Stream<List<EventOffer>> watchProviderOffers(String providerId) => db
      .collection('event_offers')
      .where('providerId', isEqualTo: providerId)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(EventOffer.fromDoc).toList());

  Stream<List<EventReservation>> watchClientReservations() => db
      .collection('event_reservations')
      .where('clientId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(50)
      .snapshots()
      .map((s) => s.docs.map(EventReservation.fromDoc).toList());

  Stream<List<EventReservation>> watchProviderReservations(String providerId) =>
      db
          .collection('event_reservations')
          .where('providerIds', arrayContains: providerId)
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots()
          .map((s) => s.docs.map(EventReservation.fromDoc).toList());

  Future<String> saveProvider({
    String? id,
    required String shopName,
    required String description,
    required String zone,
    required String phone,
    String? logoUrl,
  }) async {
    final ref = id == null
        ? db.collection('event_providers').doc()
        : db.collection('event_providers').doc(id);
    await ref.set({
      'ownerId': uid,
      'shopName': shopName.trim(),
      'description': description.trim(),
      'zone': zone.trim(),
      'phone': phone.trim(),
      if (logoUrl != null) 'logoUrl': logoUrl,
      if (id == null) ...{
        'status': 'pending',
        'isSuspended': false,
        'rating': 0,
        'reviewCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    try {
      final token = await NotificationService().getTokenWhenReady();
      if (token != null) {
        await ref.set({'fcmToken': token}, SetOptions(merge: true));
      }
    } catch (_) {
      // Le profil reste enregistrable si les notifications sont indisponibles.
    }
    return ref.id;
  }

  Future<String> saveOffer({
    String? id,
    required String providerId,
    required String providerName,
    required Map<String, dynamic> values,
  }) async {
    final ref = id == null
        ? db.collection('event_offers').doc()
        : db.collection('event_offers').doc(id);
    await ref.set({
      ...values,
      'providerId': providerId,
      'providerName': providerName,
      'ownerId': uid,
      if (id == null) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return ref.id;
  }

  Future<String> uploadMedia({
    required String offerId,
    required String path,
    required bool video,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Sélection de fichier web non configurée');
    }
    final extension = path.contains('.') ? path.split('.').last : 'bin';
    final ref = storage.ref(
        'event_offers/$uid/$offerId/${DateTime.now().microsecondsSinceEpoch}.$extension');
    await ref.putFile(
      File(path),
      SettableMetadata(
          contentType: video ? 'video/$extension' : 'image/$extension'),
    );
    return ref.getDownloadURL();
  }

  // LOT 6.3 SECURITY : ne crée plus jamais le document directement — le
  // client ne fournissait auparavant aucune garantie que `totalAmount`/
  // `items[].unitPrice` correspondait aux vrais prix `event_offers` (les
  // règles Firestore ne peuvent pas revalider fidèlement une liste
  // d'éléments contre un catalogue serveur). createEventReservationCF
  // recalcule le montant exclusivement à partir des offres réelles, ignore
  // tout prix envoyé par le client, et débite le wallet atomiquement côté
  // serveur si besoin. Seuls `offerId`/`quantity` sont transmis par item —
  // jamais un prix.
  Future<String> createReservation({
    required List<EventCartItem> items,
    required DateTime eventDate,
    required String eventTime,
    required String address,
    required String description,
    required EventPaymentMethod paymentMethod,
    required bool delivery,
    required bool installation,
    required bool dismantling,
    double? latitude,
    double? longitude,
  }) async {
    if (items.isEmpty) throw ArgumentError('La réservation est vide');

    final sortedItems = items
        .map((e) => {'offerId': e.offer.id, 'quantity': e.quantity})
        .toList()
      ..sort(
          (a, b) => (a['offerId'] as String).compareTo(b['offerId'] as String));
    final payload = <String, dynamic>{
      'items': sortedItems,
      // The time is a separate field; incidental seconds must not change a retry.
      'eventDateMs': DateTime(eventDate.year, eventDate.month, eventDate.day)
          .millisecondsSinceEpoch,
      'eventTime': eventTime,
      'address': address.trim(),
      'description': description.trim(),
      'paymentMethod': paymentMethod.name,
      'delivery': delivery,
      'installation': installation,
      'dismantling': dismantling,
      'latitude': latitude,
      'longitude': longitude,
    };
    try {
      return await EventReservationAttempts().submit(
        uid: uid,
        payload: payload,
        send: (request) async {
          final callable = functions.httpsCallable('createEventReservationCF');
          final result = await callable.call<Map<String, dynamic>>(request);
          final data = Map<String, dynamic>.from(result.data as Map);
          return data['reservationId'] as String;
        },
      );
    } on FirebaseFunctionsException catch (e) {
      // SOLDE_INSUFFISANT reste dans le message d'erreur pour compatibilité
      // avec le parsing existant côté UI (même convention que les autres
      // paiements wallet de l'app).
      throw StateError(e.message ?? 'Échec de la réservation');
    }
  }

  Future<void> cancelReservation(String id) =>
      db.collection('event_reservations').doc(id).update(
          {'status': 'cancelled', 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> updateReservationStatus(String id, String status) => db
      .collection('event_reservations')
      .doc(id)
      .update({'status': status, 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> submitReview({
    required String reservationId,
    required String providerId,
    required int rating,
    required String comment,
  }) =>
      db.collection('event_reviews').doc('${reservationId}_$providerId').set({
        'reservationId': reservationId,
        'providerId': providerId,
        'clientId': uid,
        'rating': rating,
        'comment': comment.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

  Future<void> report({
    required String targetType,
    required String targetId,
    required String reason,
  }) =>
      db.collection('event_reports').add({
        'reporterId': uid,
        'targetType': targetType,
        'targetId': targetId,
        'reason': reason.trim(),
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
      });

  String chatIdFor(String providerId) => 'event_${providerId}_$uid';

  Future<String> openChat({
    required String providerId,
    required String providerOwnerId,
    required String providerName,
  }) async {
    final id = chatIdFor(providerId);
    final ref = db.collection('event_chats').doc(id);
    await db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      if (snapshot.exists) {
        transaction.update(ref, {'updatedAt': FieldValue.serverTimestamp()});
      } else {
        transaction.set(ref, {
          'providerId': providerId,
          'providerName': providerName,
          'clientId': uid,
          'participantIds': [uid, providerOwnerId],
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
    return id;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchProviderReviews(
          String providerId) =>
      db
          .collection('event_reviews')
          .where('providerId', isEqualTo: providerId)
          .limit(20)
          .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchMyChats() => db
      .collection('event_chats')
      .where('participantIds', arrayContains: uid)
      .orderBy('updatedAt', descending: true)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchMessages(String chatId) => db
      .collection('event_chats')
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt')
      .limitToLast(100)
      .snapshots();

  Future<void> sendMessage(String chatId, String text) async {
    final value = text.trim();
    if (value.isEmpty || value.length > 2000) return;
    final chat = db.collection('event_chats').doc(chatId);
    final message = chat.collection('messages').doc();
    final batch = db.batch();
    batch.set(message, {
      'senderId': uid,
      'text': value,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(chat, {
      'lastMessage': value,
      'lastSenderId': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }
}
