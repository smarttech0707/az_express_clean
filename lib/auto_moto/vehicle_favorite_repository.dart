import 'package:cloud_firestore/cloud_firestore.dart';

import 'models/vehicle_favorite.dart';
import 'models/vehicle_listing.dart';

class VehicleFavoritesPage {
  const VehicleFavoritesPage({
    required this.favorites,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<VehicleFavorite> favorites;
  final DocumentSnapshot<Map<String, dynamic>>? nextCursor;
  final bool hasMore;
}

class VehicleFavoriteRepository {
  VehicleFavoriteRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  static const usersCollection = 'vehicle_favorites';

  CollectionReference<Map<String, dynamic>> _items(String uid) =>
      _firestore.collection(usersCollection).doc(uid).collection('items');

  Future<Set<String>> getFavoriteIds(String uid, Iterable<String> ids) async {
    final values = ids.toSet().toList(growable: false);
    if (values.isEmpty) return {};
    final result = <String>{};
    for (var offset = 0; offset < values.length; offset += 30) {
      final end = (offset + 30).clamp(0, values.length);
      final snapshot = await _items(uid)
          .where(FieldPath.documentId, whereIn: values.sublist(offset, end))
          .get();
      result.addAll(snapshot.docs.map((document) => document.id));
    }
    return result;
  }

  Future<void> setFavorite({
    required String uid,
    required VehicleListing listing,
    required bool favorite,
  }) async {
    final reference = _items(uid).doc(listing.id);
    if (!favorite) {
      await reference.delete();
      return;
    }
    await reference.set({
      'userId': uid,
      'listingId': listing.id,
      'listingSnapshot': listing.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<VehicleFavoritesPage> getFavorites({
    required String uid,
    int pageSize = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> query =
        _items(uid).orderBy('createdAt', descending: true).limit(pageSize + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snapshot = await query.get();
    final documents = snapshot.docs.take(pageSize).toList();
    return VehicleFavoritesPage(
      favorites: documents.map(VehicleFavorite.fromDocument).toList(),
      nextCursor: documents.isEmpty ? null : documents.last,
      hasMore: snapshot.docs.length > pageSize,
    );
  }
}
