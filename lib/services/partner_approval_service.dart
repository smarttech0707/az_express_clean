import 'package:cloud_firestore/cloud_firestore.dart';

String selectApprovalId(
    Map<String, dynamic> request, String idField, String proposedId,
    {String? ownerId, String? stableId}) {
  final stored = request[idField];
  if (stored != null &&
      (stored is! String || stored.isEmpty || stored.contains('/'))) {
    throw StateError('Identite incoherente');
  }
  if (stored is String && ownerId != null && stored != ownerId) {
    throw StateError('Liaisons contradictoires');
  }
  final existing = stored as String? ?? ownerId ?? stableId;
  if (existing != null) return existing;
  if (request['status'] == 'approved') {
    throw StateError(
        'Demande historique approuvee sans liaison : verification requise');
  }
  return proposedId;
}

Future<String> approvePartnerOnce(
    {required FirebaseFirestore db,
    required String requestCollection,
    required String requestId,
    required String collection,
    required String idField,
    required Map<String, dynamic> profile,
    String? stableId,
    Map<String, dynamic>? ownerProfile}) async {
  final proposed = db.collection(collection).doc().id;
  return db.runTransaction((tx) async {
    final requestRef = db.collection(requestCollection).doc(requestId);
    final request = await tx.get(requestRef);
    if (!request.exists) throw StateError('Demande absente');
    final ownerRef = ownerProfile == null
        ? null
        : db.collection('restaurant_owners').doc(requestId);
    final owner = ownerRef == null ? null : await tx.get(ownerRef);
    final id = selectApprovalId(request.data()!, idField, proposed,
        ownerId: owner?.data()?['restaurantId'] as String?, stableId: stableId);
    final target = db.collection(collection).doc(id);
    final existing = await tx.get(target);
    if (existing.exists) {
      return id; // No replacement of money, status, QR or owner.
    }
    if (request.data()?['status'] == 'approved' || owner?.exists == true) {
      throw StateError(
          'Etablissement historique absent : verification requise');
    }
    tx.set(target, {...profile, if (collection == 'restaurants') 'id': id});
    if (ownerRef != null) {
      tx.set(ownerRef, {...ownerProfile!, 'restaurantId': id});
    }
    tx.update(requestRef, {
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
      idField: id
    });
    return id;
  });
}
