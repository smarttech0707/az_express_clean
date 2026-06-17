import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_constants.dart';

class WalletRepository {
  static final _db = FirebaseFirestore.instance;

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Solde en temps réel ──────────────────────────────────────────────────
  static Stream<int> balanceStream({String collection = Collections.clients}) {
    final uid = _uid;
    if (uid == null) return Stream.value(0);
    return _db
        .collection(collection)
        .doc(uid)
        .snapshots()
        .map((s) => (s.data()?['wallet'] as num?)?.toInt() ?? 0);
  }

  // ── Lecture unique du solde ───────────────────────────────────────────────
  static Future<int> getBalance({String collection = Collections.clients}) async {
    final uid = _uid;
    if (uid == null) return 0;
    final snap = await _db.collection(collection).doc(uid).get();
    return (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
  }

  // ── Transactions FeexPay (collection racine) ──────────────────────────────
  static Stream<QuerySnapshot> feexpayTransactionsStream() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection(Collections.walletTransactions)
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots();
  }

  // ── Historique wallet (sous-collection) ───────────────────────────────────
  static Stream<QuerySnapshot> historyStream({
    String collection = Collections.clients,
  }) {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection(collection)
        .doc(uid)
        .collection('wallet_transactions')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots();
  }

  // ── Débit direct (via transaction atomique) ───────────────────────────────
  static Future<void> debit(
    String userId,
    int amount, {
    required String description,
    String collection = Collections.clients,
    String? orderId,
  }) async {
    if (amount <= 0) throw ArgumentError('Le montant doit être positif');
    await _db.runTransaction((tx) async {
      final ref  = _db.collection(collection).doc(userId);
      final snap = await tx.get(ref);

      if (!snap.exists) throw Exception('Utilisateur introuvable');

      final balance = (snap.data()!['wallet'] as num?)?.toInt() ?? 0;
      if (balance < amount) throw Exception('Solde insuffisant');

      tx.update(ref, {'wallet': balance - amount});

      final txRef = ref.collection('wallet_transactions').doc();
      tx.set(txRef, {
        'type':        'debit',
        'amount':      amount,
        'description': description,
        'orderId':     orderId,
        'createdAt':   FieldValue.serverTimestamp(),
      });
    });
  }

  // ── Crédit direct (via transaction atomique) ──────────────────────────────
  static Future<void> credit(
    String userId,
    int amount, {
    required String description,
    String collection = Collections.clients,
    String? orderId,
    String provider = 'manual',
  }) async {
    if (amount <= 0) throw ArgumentError('Le montant doit être positif');
    await _db.runTransaction((tx) async {
      final ref     = _db.collection(collection).doc(userId);
      final snap    = await tx.get(ref);

      if (!snap.exists) throw Exception('Utilisateur introuvable');

      final balance = (snap.data()!['wallet'] as num?)?.toInt() ?? 0;

      tx.update(ref, {
        'wallet':         balance + amount,
        'lastRechargeAt': FieldValue.serverTimestamp(),
      });

      final txRef = ref.collection('wallet_transactions').doc();
      tx.set(txRef, {
        'type':        'credit',
        'amount':      amount,
        'description': description,
        'orderId':     orderId,
        'provider':    provider,
        'createdAt':   FieldValue.serverTimestamp(),
      });
    });
  }
}
