import 'package:cloud_firestore/cloud_firestore.dart';

import 'models/vehicle_listing.dart';
import 'vehicle_listing_validator.dart';
import 'vehicle_listing_query.dart';

class VehicleListingsPage {
  const VehicleListingsPage({
    required this.listings,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<VehicleListing> listings;
  final DocumentSnapshot<Map<String, dynamic>>? nextCursor;
  final bool hasMore;
}

class VehicleListingRepository {
  VehicleListingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const collectionName = 'vehicle_listings';
  static const defaultPageSize = 20;
  static const maxPageSize = 50;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _listings =>
      _firestore.collection(collectionName);

  String newListingId() => _listings.doc().id;

  Future<String> createListing(VehicleListing listing) async {
    VehicleListingValidator.validateOrThrow(listing);
    final data = listing.toMap()
      ..remove('createdAt')
      ..remove('updatedAt')
      ..addAll({
        'searchKeywords': buildVehicleSearchKeywords(
          title: listing.title,
          brand: listing.brand,
          model: listing.model,
        ),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    final document = await _listings.add(data);
    return document.id;
  }

  Future<void> createListingWithId(VehicleListing listing) async {
    if (listing.id.trim().isEmpty) {
      throw ArgumentError.value(listing.id, 'listing.id', 'ID obligatoire');
    }
    VehicleListingValidator.validateOrThrow(listing);
    final data = listing.toMap()
      ..remove('createdAt')
      ..remove('updatedAt')
      ..addAll({
        'searchKeywords': buildVehicleSearchKeywords(
          title: listing.title,
          brand: listing.brand,
          model: listing.model,
        ),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    await _listings.doc(listing.id).set(data);
  }

  Future<VehicleListing?> getListingById(String listingId) async {
    final document = await _listings.doc(listingId).get();
    if (!document.exists) return null;
    return VehicleListing.fromDocument(document);
  }

  Future<void> updateListing(VehicleListing listing) async {
    if (listing.id.trim().isEmpty) {
      throw ArgumentError.value(listing.id, 'listing.id', 'ID obligatoire');
    }
    VehicleListingValidator.validateOrThrow(listing);
    final existing = await _listings.doc(listing.id).get();
    if (!existing.exists) throw StateError('Annonce introuvable.');
    final original = VehicleListing.fromDocument(existing);
    if (listing.sellerId != original.sellerId) {
      throw StateError('Le propriétaire de l’annonce est immuable.');
    }
    final data = listing.toMap()
      ..remove('createdAt')
      ..remove('updatedAt')
      ..['updatedAt'] = FieldValue.serverTimestamp()
      ..['searchKeywords'] = buildVehicleSearchKeywords(
        title: listing.title,
        brand: listing.brand,
        model: listing.model,
      );
    await _listings.doc(listing.id).update(data);
  }

  Future<void> archiveListing(String listingId) =>
      _listings.doc(listingId).update({
        'status': VehicleListingStatus.archived.toFirestore(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<VehicleListingsPage> getActiveListings({
    String? cityId,
    VehicleOfferType? offerType,
    VehicleType? vehicleType,
    int pageSize = defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    if (pageSize < 1 || pageSize > maxPageSize) {
      throw RangeError.range(pageSize, 1, maxPageSize, 'pageSize');
    }
    if (cityId != null &&
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(cityId)) {
      throw ArgumentError.value(cityId, 'cityId', 'cityId non normalisé');
    }

    Query<Map<String, dynamic>> query = _listings.where('status',
        isEqualTo: VehicleListingStatus.active.toFirestore());
    if (cityId != null) query = query.where('cityId', isEqualTo: cityId);
    if (offerType != null) {
      query = query.where('offerType', isEqualTo: offerType.toFirestore());
    }
    if (vehicleType != null) {
      query = query.where('vehicleType', isEqualTo: vehicleType.toFirestore());
    }
    query = query.orderBy('createdAt', descending: true).limit(pageSize + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);

    final snapshot = await query.get();
    final hasMore = snapshot.docs.length > pageSize;
    final pageDocuments = snapshot.docs.take(pageSize).toList();
    return VehicleListingsPage(
      listings: pageDocuments.map(VehicleListing.fromDocument).toList(),
      nextCursor: pageDocuments.isEmpty ? null : pageDocuments.last,
      hasMore: hasMore,
    );
  }

  Future<VehicleListingsPage> searchActiveListings({
    required VehicleListingRequest request,
    int pageSize = defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    if (pageSize < 1 || pageSize > maxPageSize) {
      throw RangeError.range(pageSize, 1, maxPageSize, 'pageSize');
    }
    final cityId = request.cityId;
    if (cityId != null &&
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(cityId)) {
      throw ArgumentError.value(cityId, 'cityId', 'ville invalide');
    }
    Query<Map<String, dynamic>> query = _listings
        .where('status', isEqualTo: VehicleListingStatus.active.toFirestore())
        .where('offerType', isEqualTo: request.offerType.toFirestore())
        .where('vehicleType', isEqualTo: request.vehicleType.toFirestore());
    if (cityId != null) {
      query = query.where('cityId', isEqualTo: cityId);
    }
    if (request.normalizedSearch.isNotEmpty) {
      query = query.where(
        'searchKeywords',
        arrayContains: request.normalizedSearch,
      );
    }
    query = switch (request.sort) {
      VehicleListingSort.newest => query.orderBy('createdAt', descending: true),
      VehicleListingSort.priceAscending => query.orderBy('price'),
      VehicleListingSort.priceDescending =>
        query.orderBy('price', descending: true),
      VehicleListingSort.yearNewest => query.orderBy('year', descending: true),
    };
    query = query.limit(pageSize + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snapshot = await query.get();
    final pageDocuments = snapshot.docs.take(pageSize).toList();
    return VehicleListingsPage(
      listings: pageDocuments
          .map(VehicleListing.fromDocument)
          .where(request.filters.matches)
          .toList(growable: false),
      nextCursor: pageDocuments.isEmpty ? null : pageDocuments.last,
      hasMore: snapshot.docs.length > pageSize,
    );
  }

  Future<VehicleListingsPage> getSellerListings({
    required String sellerId,
    int pageSize = defaultPageSize,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    if (sellerId.trim().isEmpty) {
      throw ArgumentError.value(sellerId, 'sellerId', 'UID obligatoire');
    }
    if (pageSize < 1 || pageSize > maxPageSize) {
      throw RangeError.range(pageSize, 1, maxPageSize, 'pageSize');
    }
    Query<Map<String, dynamic>> query = _listings
        .where('sellerId', isEqualTo: sellerId)
        .orderBy('createdAt', descending: true)
        .limit(pageSize + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snapshot = await query.get();
    final hasMore = snapshot.docs.length > pageSize;
    final documents = snapshot.docs.take(pageSize).toList();
    return VehicleListingsPage(
      listings: documents.map(VehicleListing.fromDocument).toList(),
      nextCursor: documents.isEmpty ? null : documents.last,
      hasMore: hasMore,
    );
  }
}
