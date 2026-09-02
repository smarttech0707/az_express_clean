import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/mp_product.dart';

class MpService {
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static final _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');
  static final _col = _db.collection('marketplace_products');

  // ── Streams ────────────────────────────────────────────────────────────────

  static Stream<List<MpProduct>> streamActive({int limit = 40}) => _col
      .where('status', isEqualTo: 'active')
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map(MpProduct.fromDoc).toList());

  static Stream<List<MpProduct>> streamByCategory(String cat,
          {int limit = 30}) =>
      _col
          .where('status', isEqualTo: 'active')
          .where('category', isEqualTo: cat)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((s) => s.docs.map(MpProduct.fromDoc).toList());

  static Stream<List<MpProduct>> streamBySeller(String uid) => _col
      .where('sellerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(MpProduct.fromDoc).toList());

  // ── Search (client-side filtering for simplicity) ──────────────────────────

  static Future<List<MpProduct>> search({
    String? query,
    String? category,
    String? condition,
    String? brand,
    int? minPrice,
    int? maxPrice,
  }) async {
    Query q = _col.where('status', isEqualTo: 'active');
    if (category != null && category.isNotEmpty) {
      q = q.where('category', isEqualTo: category);
    }
    if (condition != null && condition.isNotEmpty) {
      q = q.where('condition', isEqualTo: condition);
    }
    if (brand != null && brand.isNotEmpty) {
      q = q.where('brand', isEqualTo: brand);
    }
    final snap = await q.orderBy('createdAt', descending: true).limit(80).get();
    var results = snap.docs.map(MpProduct.fromDoc).toList();
    if (query != null && query.trim().isNotEmpty) {
      final q2 = query.toLowerCase().trim();
      results = results
          .where((p) =>
              p.title.toLowerCase().contains(q2) ||
              p.brand.toLowerCase().contains(q2) ||
              p.description.toLowerCase().contains(q2))
          .toList();
    }
    if (minPrice != null) {
      results = results.where((p) => p.price >= minPrice).toList();
    }
    if (maxPrice != null) {
      results = results.where((p) => p.price <= maxPrice).toList();
    }
    return results;
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  static Future<String> addProduct(Map<String, dynamic> data) async {
    try {
      final payload = Map<String, dynamic>.from(data)
        ..remove('createdAt')
        ..remove('expiresAt')
        ..remove('sellerVerified')
        ..remove('sellerVipStatus')
        ..remove('priorityLevel')
        ..remove('status');
      final result = await _functions
          .httpsCallable('publishMarketplaceProduct')
          .call(<String, dynamic>{'product': payload}).timeout(
              const Duration(seconds: 45));
      return (result.data as Map)['productId'] as String;
    } on TimeoutException {
      throw Exception(
          'La publication prend trop de temps. Vérifiez votre connexion puis réessayez.');
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Publication impossible.');
    }
  }

  static Future<void> updateProduct(String id, Map<String, dynamic> data) =>
      _col.doc(id).update(data);

  static Future<void> softDelete(String id) =>
      _col.doc(id).update({'status': 'hidden'});

  static Future<void> markSold(String id) =>
      _col.doc(id).update({'status': 'sold'});

  static Future<void> reactivate(String id) async {
    try {
      await _functions
          .httpsCallable('republishMarketplaceProduct')
          .call(<String, dynamic>{'productId': id});
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Republication impossible.');
    }
  }

  static Future<void> incrementViews(String id) =>
      _col.doc(id).update({'views': FieldValue.increment(1)});

  // ── Image upload ───────────────────────────────────────────────────────────
  // Uses readAsBytes() to work on both mobile and web.
  static Future<String> uploadImage(
      XFile file, String productId, int index) async {
    final ref = _storage.ref('marketplace/$productId/img_$index.jpg');
    final bytes = await file.readAsBytes();
    try {
      await ref
          .putData(bytes, SettableMetadata(contentType: 'image/jpeg'))
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception('Le téléchargement de la photo prend trop de temps.');
    }

    try {
      return await ref.getDownloadURL().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw Exception('Impossible de récupérer la photo téléchargée.');
    }
  }

  static Future<List<String>> uploadImages(
      List<XFile> files, String productId) async {
    final urls = <String>[];
    for (var i = 0; i < files.length; i++) {
      final url = await uploadImage(files[i], productId, i);
      urls.add(url);
    }
    return urls;
  }

  // ── Favorites ──────────────────────────────────────────────────────────────

  static Future<Set<String>> getFavorites(String uid) async {
    final doc = await _db.collection('marketplace_favorites').doc(uid).get();
    if (!doc.exists) return {};
    final ids = doc.data()?['productIds'] as List<dynamic>? ?? [];
    return Set<String>.from(ids.map((e) => e.toString()));
  }

  static Future<void> toggleFavorite(
      String uid, String productId, bool add) async {
    final ref = _db.collection('marketplace_favorites').doc(uid);
    if (add) {
      await ref.set({
        'productIds': FieldValue.arrayUnion([productId])
      }, SetOptions(merge: true));
      await _col
          .doc(productId)
          .update({'favoritesCount': FieldValue.increment(1)});
    } else {
      await ref.set({
        'productIds': FieldValue.arrayRemove([productId])
      }, SetOptions(merge: true));
      await _col
          .doc(productId)
          .update({'favoritesCount': FieldValue.increment(-1)});
    }
  }

  static Future<List<MpProduct>> getFavoriteProducts(String uid) async {
    final ids = (await getFavorites(uid)).take(20).toList();
    if (ids.isEmpty) return [];
    final futures = ids.map((id) => _col.doc(id).get());
    final docs = await Future.wait(futures);
    return docs.where((d) => d.exists).map(MpProduct.fromDoc).toList();
  }

  // ── Reports ────────────────────────────────────────────────────────────────

  static Future<void> reportProduct(
          String productId, String reporterId, String reason) =>
      _db.collection('marketplace_reports').add({
        'productId': productId,
        'reportedBy': reporterId,
        'reason': reason,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
      });
}
