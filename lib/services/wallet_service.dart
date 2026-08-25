import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class WalletService {
  static final _db = FirebaseFirestore.instance;

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Stream du solde en temps réel ─────────────────────────────────────────
  static Stream<int> watchBalance({String collection = 'clients'}) {
    final uid = _uid;
    if (uid == null) return Stream.value(0);
    return _db
        .collection(collection)
        .doc(uid)
        .snapshots()
        .map((s) => (s.data()?['wallet'] as num?)?.toInt() ?? 0);
  }

  // ── Lecture unique du solde ───────────────────────────────────────────────
  static Future<int> getBalance({String collection = 'clients'}) async {
    final uid = _uid;
    if (uid == null) return 0;
    final snap = await _db.collection(collection).doc(uid).get();
    return (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
  }

  // ── Nom de l'utilisateur ──────────────────────────────────────────────────
  static Future<String> getUserName({String collection = 'clients'}) async {
    final uid = _uid;
    if (uid == null) return '';
    final snap = await _db.collection(collection).doc(uid).get();
    final d = snap.data();
    if (d == null) return '';
    return d['name'] as String? ??
        '${d['firstName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
  }
}
