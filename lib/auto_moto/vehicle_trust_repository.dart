import 'package:cloud_firestore/cloud_firestore.dart';

enum VehicleReportTarget { listing, seller }

class VehicleTrustRepository {
  VehicleTrustRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<void> report({
    required VehicleReportTarget target,
    required String targetId,
    required String sellerId,
    required String reporterUid,
    required String reason,
    String? details,
  }) async {
    final cleanDetails = details?.trim();
    final reportId = '${target.name}_${targetId}_$reporterUid';
    await _firestore.collection('vehicle_reports').doc(reportId).set({
      'targetType': target.name,
      'targetId': targetId,
      'sellerId': sellerId,
      'reporterUid': reporterUid,
      'reason': reason,
      if (cleanDetails?.isNotEmpty == true) 'details': cleanDetails,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<Set<String>> getBlockedUserIds(String uid) async {
    final snapshot = await _firestore
        .collection('vehicle_user_blocks')
        .doc(uid)
        .collection('blocked')
        .limit(100)
        .get();
    return snapshot.docs.map((document) => document.id).toSet();
  }

  Future<bool> isBlocked(String uid, String otherUid) async {
    final documents = await Future.wait([
      _firestore
          .collection('vehicle_user_blocks')
          .doc(uid)
          .collection('blocked')
          .doc(otherUid)
          .get(),
      _firestore
          .collection('vehicle_user_blocks')
          .doc(otherUid)
          .collection('blocked')
          .doc(uid)
          .get(),
    ]);
    return documents.any((document) => document.exists);
  }

  Future<void> block({required String uid, required String blockedUid}) async {
    if (uid == blockedUid) throw ArgumentError('Auto-blocage interdit.');
    await _firestore
        .collection('vehicle_user_blocks')
        .doc(uid)
        .collection('blocked')
        .doc(blockedUid)
        .set({
      'ownerUid': uid,
      'blockedUid': blockedUid,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> unblock({required String uid, required String blockedUid}) =>
      _firestore
          .collection('vehicle_user_blocks')
          .doc(uid)
          .collection('blocked')
          .doc(blockedUid)
          .delete();
}
