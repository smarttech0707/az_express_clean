import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/feexpay_transaction.dart';

class FeexPayService {
  static final _fn = FirebaseFunctions.instanceFor(region: 'europe-west1');
  static final _db = FirebaseFirestore.instance;

  // ── Initier un paiement ────────────────────────────────────────────────────
  // Retourne le txId pour suivre le statut en temps réel.
  static Future<String> initiatePayment({
    required int amount,
    required String phone,
    required String operator,
    String userType = 'client',
  }) async {
    if (amount <= 0) throw ArgumentError('Le montant doit être positif');
    if (phone.trim().isEmpty) throw ArgumentError('Numéro de téléphone requis');
    if (operator.trim().isEmpty) throw ArgumentError('Opérateur requis');

    final callable = _fn.httpsCallable('initiateFeexPayPayment');
    final result = await callable.call({
      'amount': amount,
      'phone': phone.trim(),
      'operator': operator.trim(),
      'userType': userType,
    });

    final data = Map<String, dynamic>.from(result.data as Map);
    final txId = data['txId']?.toString();
    if (txId == null || txId.isEmpty) {
      throw Exception('Réponse invalide du serveur de paiement');
    }
    final paymentUrl = data['paymentUrl'] as String?;

    // Si FeexPay retourne une URL (page web) → ouvrir dans le navigateur
    if (paymentUrl != null && paymentUrl.isNotEmpty) {
      final uri = Uri.tryParse(paymentUrl);
      if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw Exception('URL de paiement invalide');
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    // Sinon le paiement se fait via USSD/push directement sur le téléphone

    return txId;
  }

  // ── Initier un retrait ────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> initiateWithdrawal({
    required int amount,
    required String phone,
    required String operator,
    String userType = 'client',
    String userName = '',
  }) async {
    final callable = _fn.httpsCallable('initiateWithdrawal');
    final result = await callable.call({
      'amount': amount,
      'phone': phone,
      'operator': operator,
      'userType': userType,
      'userName': userName,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  // ── Stream d'une transaction (statut temps réel) ───────────────────────────
  static Stream<FeexPayTransaction?> watchTransaction(String txId) {
    return _db
        .collection('wallet_transactions')
        .doc(txId)
        .snapshots()
        .map((s) => s.exists ? FeexPayTransaction.fromFirestore(s) : null);
  }

  // ── Historique des transactions de l'utilisateur connecté ─────────────────
  static Stream<List<FeexPayTransaction>> watchMyTransactions() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value([]);
    return _db
        .collection('wallet_transactions')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(FeexPayTransaction.fromFirestore).toList());
  }
}
