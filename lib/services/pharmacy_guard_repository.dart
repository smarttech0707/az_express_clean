import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/pharmacy_guard.dart';

class PharmacyGuardRepository {
  PharmacyGuardRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<PharmacyGuard>> watchPublicGuards({required String city}) {
    return _firestore
        .collection('pharmacy_guards')
        .where('cityKey', isEqualTo: normalizeText(city))
        .where('isActive', isEqualTo: true)
        .where('isVerified', isEqualTo: true)
        .orderBy('guardStartAt')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map(PharmacyGuard.fromDocument)
            .where((guard) => guard.guardEndAt.isAfter(DateTime.now().toUtc()))
            .toList(growable: false));
  }

  Stream<List<PharmacyGuard>> watchAllForAdmin() => _firestore
      .collection('pharmacy_guards')
      .orderBy('guardStartAt', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs
          .map(PharmacyGuard.fromDocument)
          .toList(growable: false));

  Future<void> saveManual(PharmacyGuard guard) async {
    if (!guard.guardEndAt.isAfter(guard.guardStartAt)) {
      throw ArgumentError('La fin de garde doit être postérieure au début.');
    }
    final isNew = guard.id.isEmpty;
    final ref = isNew
        ? _firestore.collection('pharmacy_guards').doc()
        : _firestore.collection('pharmacy_guards').doc(guard.id);
    await ref.set({
      ...guard.toFirestore(),
      'cityKey': normalizeText(guard.city),
      'dedupeKey': manualDedupeKey(guard),
      if (isNew) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setActive(String id, bool active) => _firestore
      .collection('pharmacy_guards')
      .doc(id)
      .update({'isActive': active, 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> delete(String id) =>
      _firestore.collection('pharmacy_guards').doc(id).delete();

  static String normalizeText(String value) {
    const accents = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ';
    const plain = 'aaaaaaceeeeiiiinooooouuuuyy';
    var result = value.trim().toLowerCase();
    for (var i = 0; i < accents.length; i++) {
      result = result.replaceAll(accents[i], plain[i]);
    }
    return result.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  static String normalizePhone(String value) =>
      value.replaceAll(RegExp(r'[^0-9+]'), '');

  static String manualDedupeKey(PharmacyGuard guard) => [
        'manual',
        normalizeText(guard.name),
        normalizeText(guard.city),
        guard.guardStartAt.toUtc().millisecondsSinceEpoch,
        guard.guardEndAt.toUtc().millisecondsSinceEpoch,
      ].join('|');
}
