import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/ek_order.dart';
import '../models/ek_agent.dart';
import '../ek_constants.dart';

class EkService {
  static final _db      = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static final _orders  = _db.collection('ekbine_orders');
  static final _agents  = _db.collection('ekbine_agents');

  // ── Orders ─────────────────────────────────────────────────────────────────

  static Future<String> createOrder(Map<String, dynamic> data) async {
    final ref = await _orders.add(data);
    return ref.id;
  }

  static Stream<List<EkOrder>> streamClientOrders(String uid) =>
      _orders
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots()
          .map((s) => s.docs.map(EkOrder.fromDoc).toList());

  static Stream<EkOrder?> streamOrder(String orderId) =>
      _orders.doc(orderId).snapshots().map(
            (s) => s.exists ? EkOrder.fromDoc(s) : null,
          );

  // Agent: écouter les commandes en attente qui correspondent à ses opérateurs
  static Stream<List<EkOrder>> streamPendingForAgent(
      List<String> supportedOperators) {
    if (supportedOperators.isEmpty) return Stream.value([]);
    return _orders
        .where('status', isEqualTo: 'pending')
        .where('operator', whereIn: supportedOperators)
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .map((s) => s.docs.map(EkOrder.fromDoc).toList());
  }

  static Stream<List<EkOrder>> streamAgentActiveOrders(String agentId) =>
      _orders
          .where('agentId', isEqualTo: agentId)
          .where('status', whereIn: ['assigned', 'awaiting_deposit', 'in_progress', 'proof_sent'])
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map(EkOrder.fromDoc).toList());

  static Stream<List<EkOrder>> streamAgentHistory(String agentId) =>
      _orders
          .where('agentId', isEqualTo: agentId)
          .where('status', whereIn: ['completed', 'cancelled', 'disputed'])
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots()
          .map((s) => s.docs.map(EkOrder.fromDoc).toList());

  // ── Order actions ──────────────────────────────────────────────────────────

  static Future<void> agentAcceptOrder(
      String orderId, EkAgent agent, String paymentMethod, String operator) async {
    // wallet: already debited at order creation → agent starts directly (assigned)
    // other: client must send deposit proof first (awaiting_deposit)
    final newStatus  = paymentMethod == 'wallet' ? 'assigned' : 'awaiting_deposit';
    final momoNumber = agent.operatorNumbers[operator] ?? agent.phone;
    await _orders.doc(orderId).update({
      'agentId':         agent.id,
      'agentName':       agent.name,
      'agentPhone':      agent.phone,
      'agentMomoNumber': momoNumber,
      'status':          newStatus,
      'assignedAt':      FieldValue.serverTimestamp(),
    });
  }

  static Future<void> agentStartOrder(String orderId) =>
      _orders.doc(orderId).update({'status': 'in_progress'});

  // Client uploads proof of their payment to the agent (mobile money screenshot)
  static Future<String> uploadDepositProof(XFile file, String orderId) async {
    final ref   = _storage.ref('ekbine_proofs/$orderId/deposit.jpg');
    final bytes = await file.readAsBytes();
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  static Future<void> clientSendDepositProof(
      String orderId, String depositProofUrl) =>
      _orders.doc(orderId).update({'depositProofUrl': depositProofUrl});

  // Agent confirms they received the deposit and starts the service
  static Future<void> agentVerifyDeposit(String orderId) =>
      _orders.doc(orderId).update({'status': 'in_progress'});

  static Future<void> agentSendProof(String orderId, String proofUrl) =>
      _orders.doc(orderId).update({
        'status':   'proof_sent',
        'proofUrl': proofUrl,
      });

  // Confirmation via Cloud Function sécurisée (interdit l'injection directe de walletBalance)
  static Future<void> clientConfirmOrder(String orderId, EkOrder order) async {
    final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('ekClientConfirmOrder');
    await callable.call({'orderId': orderId});
  }

  static Future<void> cancelOrder(String orderId, String reason) =>
      _orders.doc(orderId).update({
        'status':             'cancelled',
        'cancellationReason': reason,
      });

  static Future<void> disputeOrder(String orderId) =>
      _orders.doc(orderId).update({'status': 'disputed'});

  // ── Upload proof image ─────────────────────────────────────────────────────

  static Future<String> uploadProof(XFile file, String orderId) async {
    final ref   = _storage.ref('ekbine_proofs/$orderId/proof.jpg');
    final bytes = await file.readAsBytes();
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  // ── Agents ─────────────────────────────────────────────────────────────────

  static Future<EkAgent?> getAgent(String uid) async {
    final doc = await _agents.doc(uid).get();
    return doc.exists ? EkAgent.fromDoc(doc) : null;
  }

  static Stream<EkAgent?> streamAgent(String uid) =>
      _agents.doc(uid).snapshots().map(
            (s) => s.exists ? EkAgent.fromDoc(s) : null,
          );

  static Future<void> registerAgent(String uid, Map<String, dynamic> data) =>
      _agents.doc(uid).set(data);

  static Future<void> updateAgentOnlineStatus(String uid, bool online) =>
      _agents.doc(uid).update({'isOnline': online});

  static Future<void> updateAgentProfile(
      String uid, Map<String, dynamic> data) =>
      _agents.doc(uid).update(data);

  // ── Chat E-Kbine ───────────────────────────────────────────────────────────
  // Collection: ekbine_chats/{orderId}/messages

  static Stream<QuerySnapshot> streamChatMessages(String orderId) =>
      _db
          .collection('ekbine_chats')
          .doc(orderId)
          .collection('messages')
          .orderBy('time')
          .snapshots();

  static Future<void> sendChatMessage(
      String orderId, Map<String, dynamic> message) async {
    await _db
        .collection('ekbine_chats')
        .doc(orderId)
        .collection('messages')
        .add({...message, 'time': FieldValue.serverTimestamp()});
    await _db.collection('ekbine_chats').doc(orderId).set({
      'orderId':   orderId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ── Wallet (client) ────────────────────────────────────────────────────────

  static Future<int> getClientWallet(String uid) async {
    final doc = await _db.collection('clients').doc(uid).get();
    return (doc.data()?['wallet'] as num? ?? 0).toInt();
  }

  // Transaction atomique : vérifie le solde et débite en une seule opération
  // Protège contre les double-débits simultanés (race condition)
  static Future<bool> debitClientWallet(String uid, int amount) async {
    bool success = false;
    try {
      await _db.runTransaction((tx) async {
        final ref = _db.collection('clients').doc(uid);
        final snap = await tx.get(ref);
        final bal = (snap.data()?['wallet'] as num? ?? 0).toInt();
        if (bal < amount) {
          // Solde insuffisant — on lève une exception pour annuler la transaction
          throw Exception('insufficient_funds');
        }
        tx.update(ref, {'wallet': FieldValue.increment(-amount)});
      });
      // Log hors transaction (non-critique, lecture uniquement)
      await _db.collection('wallet_transactions').add({
        'uid':       uid,
        'type':      'ekbine_payment',
        'amount':    -amount,
        'createdAt': FieldValue.serverTimestamp(),
      });
      success = true;
    } on Exception catch (e) {
      if (e.toString().contains('insufficient_funds')) return false;
      rethrow;
    }
    return success;
  }

  // ── Rating agent ───────────────────────────────────────────────────────────

  static Future<void> rateAgent(String agentId, double stars) async {
    final doc = await _agents.doc(agentId).get();
    if (!doc.exists) return;
    final d = doc.data() as Map<String, dynamic>;
    final count = (d['ratingCount'] as num? ?? 0).toInt();
    final curr  = (d['rating'] as num? ?? 0).toDouble();
    final newRating = ((curr * count) + stars) / (count + 1);
    await _agents.doc(agentId).update({
      'rating':      double.parse(newRating.toStringAsFixed(1)),
      'ratingCount': FieldValue.increment(1),
    });
  }

  // ── Stats for admin ────────────────────────────────────────────────────────

  static Future<Map<String, int>> getStats() async {
    final [pending, completed, agents] = await Future.wait([
      _orders.where('status', isEqualTo: 'pending').count().get(),
      _orders.where('status', isEqualTo: 'completed').count().get(),
      _agents.where('isVerified', isEqualTo: true).count().get(),
    ]);
    return {
      'pending':   pending.count ?? 0,
      'completed': completed.count ?? 0,
      'agents':    agents.count ?? 0,
    };
  }

  // ── Format helpers ─────────────────────────────────────────────────────────

  static String operatorLabel(String op) {
    switch (op) {
      case 'orange': return 'Orange';
      case 'mtn':    return 'MTN';
      case 'moov':   return 'Moov';
      case 'wave':   return 'Wave';
      default:       return op;
    }
  }

  static Color operatorColor(String op) {
    switch (op) {
      case 'orange': return const Color(0xFFFF6600);
      case 'mtn':    return const Color(0xFFFFBB00);
      case 'moov':   return const Color(0xFF005EB8);
      case 'wave':   return const Color(0xFF00B9F1);
      default:       return kEkGreen;
    }
  }
}
