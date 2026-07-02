import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../models/real_estate_listing.dart';
import '../models/real_estate_agent.dart';
import '../models/real_estate_visit_request.dart';

/// Service statique pour le module Immobilier — mêmes conventions que
/// lib/marketplace/services/mp_service.dart (recherche/filtrage côté client
/// car Firestore ne fait pas de recherche plein texte) et lib/ekbine pour
/// l'appel aux Cloud Functions.
class RealEstateService {
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static final _listings = _db.collection('real_estate_listings');
  static final _fn = FirebaseFunctions.instanceFor(region: 'europe-west1');

  // ── Annonces ─────────────────────────────────────────────────────────────

  static Stream<List<RealEstateListing>> streamActive({int limit = 40}) =>
      _listings
          .where('status', isEqualTo: 'active')
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((s) => s.docs.map(RealEstateListing.fromDoc).toList());

  static Stream<List<RealEstateListing>> streamByAgent(String agentId) =>
      _listings
          .where('agentId', isEqualTo: agentId)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map(RealEstateListing.fromDoc).toList());

  static Future<List<RealEstateListing>> search({
    String? query,
    String? propertyType,
    String? city,
    String? priceType,
    int? minPrice,
    int? maxPrice,
  }) async {
    Query<Map<String, dynamic>> q = _listings.where('status', isEqualTo: 'active');
    if (propertyType != null && propertyType.isNotEmpty) {
      q = q.where('propertyType', isEqualTo: propertyType);
    }
    final snap = await q.orderBy('createdAt', descending: true).limit(80).get();
    var results = snap.docs.map(RealEstateListing.fromDoc).toList();

    if (query != null && query.trim().isNotEmpty) {
      final needle = query.toLowerCase().trim();
      results = results
          .where((l) =>
              l.title.toLowerCase().contains(needle) ||
              l.description.toLowerCase().contains(needle))
          .toList();
    }
    if (city != null && city.isNotEmpty) {
      final needle = city.toLowerCase();
      results = results.where((l) => l.city.toLowerCase().contains(needle)).toList();
    }
    if (priceType != null && priceType.isNotEmpty) {
      results = results.where((l) => l.priceType == priceType).toList();
    }
    if (minPrice != null) results = results.where((l) => l.price >= minPrice).toList();
    if (maxPrice != null) results = results.where((l) => l.price <= maxPrice).toList();
    return results;
  }

  static Future<String> addListing(Map<String, dynamic> data) async {
    final ref = await _listings.add(data);
    return ref.id;
  }

  static Future<void> updateListing(String id, Map<String, dynamic> data) =>
      _listings.doc(id).update(data);

  static Future<void> softDelete(String id) => _listings.doc(id).update({'status': 'hidden'});

  static Future<void> reactivate(String id) => _listings.doc(id).update({'status': 'active'});

  static Future<void> incrementViews(String id) =>
      _listings.doc(id).update({'views': FieldValue.increment(1)});

  // ── Images ───────────────────────────────────────────────────────────────

  static Future<String> uploadImage(XFile file, String listingId, int index) async {
    final ref = _storage.ref('real_estate/$listingId/img_$index.jpg');
    final bytes = await file.readAsBytes();
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  static Future<List<String>> uploadImages(List<XFile> files, String listingId) async {
    final urls = <String>[];
    for (var i = 0; i < files.length; i++) {
      urls.add(await uploadImage(files[i], listingId, i));
    }
    return urls;
  }

  // ── Agents ───────────────────────────────────────────────────────────────

  static Future<RealEstateAgent?> getAgent(String uid) async {
    final doc = await _db.collection('real_estate_agents').doc(uid).get();
    return doc.exists ? RealEstateAgent.fromDoc(doc) : null;
  }

  static Future<void> submitAgentRequest({
    required String name,
    required String phone,
    String? agencyName,
    String? city,
  }) async {
    await _fn.httpsCallable('submitRealEstateAgentRequest').call({
      'name': name,
      'phone': phone,
      if (agencyName != null) 'agencyName': agencyName,
      if (city != null) 'city': city,
    });
  }

  // ── Visites ──────────────────────────────────────────────────────────────

  static Future<String> requestVisit({
    required String listingId,
    String? preferredDate,
    String? message,
  }) async {
    final result = await _fn.httpsCallable('requestPropertyVisit').call({
      'listingId': listingId,
      if (preferredDate != null) 'preferredDate': preferredDate,
      if (message != null) 'message': message,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return data['requestId'] as String;
  }

  static Future<void> respondToVisit({
    required String requestId,
    required String action, // propose | confirm | decline | cancel
    String? proposedDate,
  }) async {
    await _fn.httpsCallable('respondToVisitRequest').call({
      'requestId': requestId,
      'action': action,
      if (proposedDate != null) 'proposedDate': proposedDate,
    });
  }

  static Stream<List<RealEstateVisitRequest>> visitRequestsAsClient(String uid) => _db
      .collection('real_estate_visit_requests')
      .where('clientId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(RealEstateVisitRequest.fromDoc).toList());

  static Stream<List<RealEstateVisitRequest>> visitRequestsAsAgent(String agentId) => _db
      .collection('real_estate_visit_requests')
      .where('agentId', isEqualTo: agentId)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(RealEstateVisitRequest.fromDoc).toList());
}
