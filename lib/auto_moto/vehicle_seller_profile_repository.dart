import 'package:cloud_firestore/cloud_firestore.dart';

import 'models/vehicle_seller_private_location.dart';
import 'models/vehicle_seller_profile.dart';
import 'vehicle_seller_profile_validator.dart';

class VehicleSellerProfileRepository {
  VehicleSellerProfileRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const profilesCollectionName = 'vehicle_seller_profiles';
  static const privateLocationsCollectionName =
      'vehicle_seller_private_locations';

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _profiles =>
      _firestore.collection(profilesCollectionName);

  CollectionReference<Map<String, dynamic>> get _privateLocations =>
      _firestore.collection(privateLocationsCollectionName);

  Future<VehicleSellerProfile?> getSellerProfile(String uid) async {
    final document = await _profiles.doc(uid).get();
    if (!document.exists) return null;
    return VehicleSellerProfile.fromDocument(document);
  }

  Future<void> createSellerProfile(VehicleSellerProfile profile) async {
    VehicleSellerProfileValidator.validateOrThrow(profile);
    final data = profile.toMap()
      ..remove('createdAt')
      ..remove('updatedAt')
      ..addAll({
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    await _profiles.doc(profile.ownerId).set(data);
  }

  Future<void> updateSellerProfile(VehicleSellerProfile profile) async {
    VehicleSellerProfileValidator.validateOrThrow(profile);
    final data = profile.toMap()
      ..remove('createdAt')
      ..remove('updatedAt')
      ..['updatedAt'] = FieldValue.serverTimestamp();
    for (final field in _optionalPublicFields) {
      if (!data.containsKey(field)) data[field] = FieldValue.delete();
    }
    await _profiles.doc(profile.ownerId).update(data);
  }

  Future<void> requestVerification(String ownerId) =>
      _profiles.doc(ownerId).update({
        'verificationStatus': 'pending',
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static const _optionalPublicFields = <String>{
    'zoneId',
    'profilePhotoUrl',
    'shopName',
    'businessType',
    'professionalPhone',
    'address',
    'locationVisibility',
    'logoUrl',
    'logoStoragePath',
    'description',
    'openingHours',
  };

  Future<VehicleSellerPrivateLocation?> getPrivateLocation(String uid) async {
    final document = await _privateLocations.doc(uid).get();
    if (!document.exists) return null;
    return VehicleSellerPrivateLocation.fromDocument(document);
  }

  Future<void> savePrivateLocation(
    VehicleSellerPrivateLocation location,
  ) async {
    VehicleSellerProfileValidator.validatePrivateLocationOrThrow(location);
    final data = location.toMap()
      ..remove('updatedAt')
      ..['updatedAt'] = FieldValue.serverTimestamp();
    await _privateLocations.doc(location.ownerId).set(data);
  }
}
