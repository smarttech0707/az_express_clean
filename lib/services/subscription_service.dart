import 'package:cloud_firestore/cloud_firestore.dart';

class SubscriptionService {
  static const int subscriptionAmount  = 1000; // Standard : 1 000 FCFA/mois
  static const int vipAmount           = 2000; // VIP      : 2 000 FCFA/mois
  static const int ekbineAgentAmount   = 500;  // E-Kbine  : 500 FCFA/mois (après 2 mois gratuits)
  static const int freeTrialDays       = 60;   // 2 mois offerts

  /// Active l'abonnement E-Kbine avec 2 mois gratuits
  static Future<void> activateEkbineTrial(String agentId) async {
    final ref  = FirebaseFirestore.instance
        .collection('ekbine_agents').doc(agentId);
    final end  = DateTime.now().add(const Duration(days: freeTrialDays));
    await ref.update({
      'subscriptionStatus':    'trial',
      'subscriptionExpiresAt': Timestamp.fromDate(end),
    });
  }

  static Future<void> checkAndRenew(String collection, String docId,
      {int? customAmount, String walletKey = 'wallet'}) async {
    final ref = FirebaseFirestore.instance.collection(collection).doc(docId);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final data = snap.data()!;
        final now = DateTime.now();
        final Map<String, dynamic> updates = {};

        final subStatus = data['subscriptionStatus'] as String? ?? 'active';
        final subExpiry = (data['subscriptionExpiresAt'] as Timestamp?)?.toDate();

        final renewAmount = customAmount ?? subscriptionAmount;
        if (subStatus != 'trial' && (subExpiry == null || subExpiry.isBefore(now))) {
          final wallet = (data[walletKey] as num? ?? 0).toInt();
          if (wallet >= renewAmount) {
            updates[walletKey] = FieldValue.increment(-renewAmount);
            updates['subscriptionStatus'] = 'active';
            updates['subscriptionExpiresAt'] =
                Timestamp.fromDate(now.add(const Duration(days: 30)));
            tx.set(ref.collection('wallet_transactions').doc(), {
              'type': 'subscription',
              'amount': renewAmount,
              'description': 'Abonnement mensuel AZ Express ($renewAmount FCFA)',
              'createdAt': FieldValue.serverTimestamp(),
            });
          } else {
            updates['subscriptionStatus'] = 'suspended';
          }
        }

        final vipStatus = data['vipStatus'] as String? ?? 'none';
        final vipExpiry = (data['vipExpiresAt'] as Timestamp?)?.toDate();
        if (vipStatus == 'active' && (vipExpiry == null || vipExpiry.isBefore(now))) {
          final walletBase = (data[walletKey] as num? ?? 0).toInt();
          final alreadyDeducted =
              updates.containsKey(walletKey) ? renewAmount : 0;
          final available = walletBase - alreadyDeducted;
          if (available >= vipAmount) {
            if (updates.containsKey(walletKey)) {
              updates[walletKey] = FieldValue.increment(-(renewAmount + vipAmount));
            } else {
              updates[walletKey] = FieldValue.increment(-vipAmount);
            }
            updates['vipStatus'] = 'active';
            updates['vipExpiresAt'] =
                Timestamp.fromDate(now.add(const Duration(days: 30)));
            tx.set(ref.collection('wallet_transactions').doc(), {
              'type': 'vip_subscription',
              'amount': vipAmount,
              'description': 'Abonnement VIP mensuel AZ Express (2 000 FCFA)',
              'createdAt': FieldValue.serverTimestamp(),
            });
          } else {
            updates['vipStatus'] = 'expired';
          }
        }

        if (updates.isNotEmpty) tx.update(ref, updates);
      });
    } catch (_) {}
  }

  static Future<void> adminActivateSubscription(
      String collection, String docId, {bool chargeWallet = false}) async {
    final ref = FirebaseFirestore.instance.collection(collection).doc(docId);
    final expiry = Timestamp.fromDate(DateTime.now().add(const Duration(days: 30)));
    if (chargeWallet) {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
        if (wallet < subscriptionAmount) throw Exception('SOLDE_INSUFFISANT');
        tx.update(ref, {
          'wallet': FieldValue.increment(-subscriptionAmount),
          'subscriptionStatus': 'active',
          'subscriptionExpiresAt': expiry,
        });
        tx.set(ref.collection('wallet_transactions').doc(), {
          'type': 'subscription',
          'amount': subscriptionAmount,
          'description': 'Abonnement mensuel — encaissement admin',
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } else {
      await ref.update({'subscriptionStatus': 'active', 'subscriptionExpiresAt': expiry});
    }
  }

  static Future<void> adminActivateVip(
      String collection, String docId, {bool chargeWallet = false}) async {
    final ref = FirebaseFirestore.instance.collection(collection).doc(docId);
    final expiry = Timestamp.fromDate(DateTime.now().add(const Duration(days: 30)));
    if (chargeWallet) {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
        if (wallet < vipAmount) throw Exception('SOLDE_INSUFFISANT');
        tx.update(ref, {
          'wallet': FieldValue.increment(-vipAmount),
          'vipStatus': 'active',
          'vipExpiresAt': expiry,
          'vipStartedAt': FieldValue.serverTimestamp(),
        });
        tx.set(ref.collection('wallet_transactions').doc(), {
          'type': 'vip_subscription',
          'amount': vipAmount,
          'description': 'Abonnement VIP 2 000 FCFA — encaissement admin',
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } else {
      await ref.update({
        'vipStatus': 'active',
        'vipExpiresAt': expiry,
        'vipStartedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  static Future<void> adminDeactivateVip(String collection, String docId) async {
    await FirebaseFirestore.instance
        .collection(collection)
        .doc(docId)
        .update({'vipStatus': 'none', 'vipExpiresAt': null});
  }

  static Future<void> adminSuspend(String collection, String docId) async {
    await FirebaseFirestore.instance
        .collection(collection)
        .doc(docId)
        .update({'subscriptionStatus': 'suspended'});
  }

  static String formatExpiry(dynamic timestamp) {
    if (timestamp == null) return 'Non défini';
    final dt = (timestamp as Timestamp).toDate();
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}
