import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_constants.dart';

class OrderRepository {
  static final _db = FirebaseFirestore.instance;
  static final _col = _db.collection(Collections.orders);

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Créer une commande ───────────────────────────────────────────────────
  static Future<String> create(Map<String, dynamic> data) async {
    final uid = _uid;
    if (uid == null) throw Exception('Utilisateur non authentifié');
    final ref = await _col.add({
      ...data,
      'clientId':  uid,
      'status':    OrderStatus.pending,
      'isPaid':    false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  // ── Commandes du client connecté ─────────────────────────────────────────
  static Stream<QuerySnapshot> myOrdersStream() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _col
        .where('clientId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots();
  }

  // ── Commandes en attente (pour les livreurs) ─────────────────────────────
  static Stream<QuerySnapshot> pendingOrdersStream() {
    return _col
        .where('status', isEqualTo: OrderStatus.pending)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  // ── Commandes assignées à un livreur ─────────────────────────────────────
  static Stream<QuerySnapshot> driverOrdersStream(String driverId) {
    return _col
        .where('driverId', isEqualTo: driverId)
        .where('status', whereNotIn: [OrderStatus.delivered, OrderStatus.cancelled])
        .snapshots();
  }

  // ── Commandes d'un vendeur ───────────────────────────────────────────────
  static Stream<QuerySnapshot> sellerOrdersStream(String sellerId, String sellerType) {
    return _col
        .where('sellerId', isEqualTo: sellerId)
        .where('sellerType', isEqualTo: sellerType)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  // ── Mettre à jour le statut ───────────────────────────────────────────────
  static Future<void> updateStatus(String orderId, String status,
      {Map<String, dynamic>? extra}) async {
    await _col.doc(orderId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
      ...?extra,
    });
  }

  // ── Assigner un livreur ───────────────────────────────────────────────────
  static Future<void> assignDriver(String orderId, String driverId) async {
    await _col.doc(orderId).update({
      'driverId':   driverId,
      'status':     OrderStatus.assigned,
      'assignedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Annuler ───────────────────────────────────────────────────────────────
  static Future<void> cancel(String orderId, {String? reason}) async {
    await _col.doc(orderId).update({
      'status':      OrderStatus.cancelled,
      'cancelReason': reason,
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Noter la livraison ────────────────────────────────────────────────────
  static Future<void> rate(String orderId, double rating,
      {String? comment}) async {
    final clampedRating = rating.clamp(1.0, 5.0);
    await _col.doc(orderId).update({
      'rating':       clampedRating,
      'ratingComment': comment,
      'ratedAt':      FieldValue.serverTimestamp(),
    });
  }

  // ── Lecture unique d'une commande ─────────────────────────────────────────
  static Future<DocumentSnapshot> get(String orderId) =>
      _col.doc(orderId).get();

  // ── Stream d'une commande ─────────────────────────────────────────────────
  static Stream<DocumentSnapshot> watch(String orderId) =>
      _col.doc(orderId).snapshots();
}
