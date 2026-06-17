import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geoflutterfire_plus/geoflutterfire_plus.dart';
import '../models/order_model.dart';
import '../models/driver_earnings_summary.dart';

class FirestoreService {

  final FirebaseFirestore db = FirebaseFirestore.instance;

  // ==============================
  // COMMISSIONS
  // ==============================

  // Commission fixe prélevée à chaque livraison terminée
  static const int _kCommissionAmount = 100;

  // Commission tiered : 100 FCFA pour 500-1000 FCFA, 200 FCFA au-delà
  static int _commissionBasic    = 100; // courses 500–1000 FCFA
  static int _commissionStandard = 200; // courses > 1000 FCFA
  static int _threshold          = 1000;

  /// Charge la config commission depuis Firestore (appelé au démarrage).
  Future<void> loadCommissionConfig() async {
    try {
      final doc = await db.collection('config').doc('commission').get();
      if (doc.exists) {
        final data = doc.data()!;
        final basic    = data['commissionBasic'];
        final standard = data['commissionStandard'];
        final thresh   = data['threshold'];
        if (basic    != null) _commissionBasic    = (basic    as num).toInt();
        if (standard != null) _commissionStandard = (standard as num).toInt();
        if (thresh   != null) _threshold          = (thresh   as num).toInt();
      }
    } catch (_) {}
  }

  /// 500–999 FCFA → 100 FCFA · ≥1000 FCFA → 200 FCFA
  int calculateCommission(int price) =>
      price < _threshold ? _commissionBasic : _commissionStandard;

  int calculateDriverGain(int price) {
    return price - calculateCommission(price);
  }

  // ==============================
  // CRÉER COMMANDE
  // ==============================

  Future<void> createOrder(OrderModel order) async {
    final orderRef = db.collection("orders").doc(order.id);
    await orderRef.set(order.toMap());
    // Tente l'assignation auto du livreur le plus proche.
    // Si la règle Firestore le bloque, les Cloud Functions FCM prennent le relais.
    try {
      await findNearestDriver(
          order.latitude, order.longitude, order.id, budget: order.budget);
    } catch (_) {}
  }

  // ==============================
  // STREAMS COMMANDES
  // ==============================

  Stream<List<OrderModel>> ordersStream() {
    return db
        .collection("orders")
        .orderBy("createdAt", descending: true)
        .limit(100)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => OrderModel.fromMap(d.id, d.data())).toList());
  }

  Stream<List<OrderModel>> sellerOrders(String sellerId, String sellerType) {
    return db
        .collection("orders")
        .where("sellerId", isEqualTo: sellerId)
        .where("sellerType", isEqualTo: sellerType)
        .orderBy("createdAt", descending: true)
        .limit(100)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => OrderModel.fromMap(d.id, d.data())).toList());
  }

  Stream<List<OrderModel>> clientOrders(String clientId) {
    return db
        .collection("orders")
        .where("clientId", isEqualTo: clientId)
        .orderBy("createdAt", descending: true)
        .limit(200)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => OrderModel.fromMap(d.id, d.data())).toList());
  }

  // ==============================
  // STREAMS LIVREUR (style Yango)
  // ==============================

  /// Commande en attente d'acceptation par CE livreur
  Stream<OrderModel?> driverPendingRequest(String driverId) {
    return db
        .collection("orders")
        .where("driverId", isEqualTo: driverId)
        .where("status", isEqualTo: "assigned")
        .limit(1)
        .snapshots()
        .map((snap) {
      if (snap.docs.isEmpty) return null;
      return OrderModel.fromMap(snap.docs.first.id, snap.docs.first.data());
    });
  }

  /// Commande active en cours (acceptée ou récupérée)
  Stream<OrderModel?> driverActiveOrder(String driverId) {
    return db
        .collection("orders")
        .where("driverId", isEqualTo: driverId)
        .where("status", whereIn: ["accepted", "picked_up"])
        .limit(1)
        .snapshots()
        .map((snap) {
      if (snap.docs.isEmpty) return null;
      return OrderModel.fromMap(snap.docs.first.id, snap.docs.first.data());
    });
  }

  /// Nombre de livraisons complétées par ce livreur (count aggregation — no doc reads)
  Future<int> driverDeliveredCountOnce(String driverId) async {
    final snap = await db
        .collection("orders")
        .where("driverId", isEqualTo: driverId)
        .where("status", isEqualTo: "delivered")
        .count()
        .get();
    return snap.count ?? 0;
  }

  // ==============================
  // TROUVER LIVREUR LE PLUS PROCHE (GeoHash — scalable)
  // ==============================

  /// Cherche dans [radiusKm] km les livreurs disponibles.
  /// — Filtre : isOnline, isOnDelivery=false, GPS actif (<3 min), wallet ≥ commission.
  /// — Top 5 par distance : 1 seul → assignation directe ; 2+ → broadcast multi-livreurs.
  /// — Retourne true si au moins un livreur a été notifié.
  Future<bool> findNearestDriver(
      double clientLat, double clientLng, String orderId,
      {int budget = 0, double radiusKm = 2.0}) async {
    final center     = GeoFirePoint(GeoPoint(clientLat, clientLng));
    final commission = calculateCommission(budget);
    final geoRef     = GeoCollectionReference<Map<String, dynamic>>(db.collection("livreurs"));
    final stale      = DateTime.now().subtract(const Duration(minutes: 3));

    final results = await geoRef.fetchWithin(
      center:       center,
      radiusInKm:   radiusKm,
      field:        'position',
      geopointFrom: (data) {
        try {
          return (data['position']?['geopoint'] as GeoPoint?) ?? const GeoPoint(0, 0);
        } catch (_) { return const GeoPoint(0, 0); }
      },
      strictMode: true,
    );

    final nearby = results.where((doc) {
      final d = doc.data();
      if (d == null)               return false;
      if (d['isOnline']     != true)  return false;
      if (d['isOnDelivery'] == true)  return false;
      if (d['isAvailable']  == false) return false; // absent = disponible par défaut
      if (d['isSuspended']  == true)  return false; // absent = non suspendu par défaut
      // Ne pas re-notifier un livreur déjà dans ce broadcast
      if (d['pendingOrderId'] == orderId) return false;
      final wallet = (d['wallet'] as num? ?? 0).toInt();
      if (wallet < commission)      return false;
      // GPS actif : updatedAt < 3 min
      final ua = d['updatedAt'];
      if (ua is Timestamp && ua.toDate().isBefore(stale)) return false;
      return true;
    }).toList();

    if (nearby.isEmpty) return false;

    // Tri par distance, top 5
    final withDist = nearby.map((doc) {
      final d   = doc.data()!;
      final lat = (d['lat'] ?? 0).toDouble();
      final lng = (d['lng'] ?? 0).toDouble();
      final dist = (lat == 0 || lng == 0)
          ? double.infinity
          : Geolocator.distanceBetween(clientLat, clientLng, lat, lng);
      return (doc: doc, dist: dist);
    }).toList()
      ..sort((a, b) => a.dist.compareTo(b.dist));

    final top5 = withDist.where((r) => r.dist.isFinite).take(5).toList();
    if (top5.isEmpty) return false;

    final ids = top5.map((r) => r.doc.id).toList();

    if (ids.length == 1) {
      // Un seul livreur → assignation directe (flow existant inchangé)
      await db.collection("orders").doc(orderId).update({
        "driverId": ids.first,
        "status":   "assigned",
      });
    } else {
      // Plusieurs → broadcast : status="broadcast" + notifiedDriverIds + pendingOrderId
      await db.collection("orders").doc(orderId).update({
        "status":            "broadcast",
        "notifiedDriverIds": FieldValue.arrayUnion(ids),
      });
      final batch = db.batch();
      for (final id in ids) {
        batch.update(db.collection("livreurs").doc(id), {"pendingOrderId": orderId});
      }
      await batch.commit();
    }
    return true;
  }

  // ==============================
  // ACCEPTER COMMANDE
  // ==============================

  Future<void> acceptOrder(
    String orderId,
    String driverId, {
    String? acceptanceSelfieUrl,
    String? driverPhotoUrl,
  }) async {
    final orderRef  = db.collection("orders").doc(orderId);
    final driverRef = db.collection("livreurs").doc(driverId);

    String? commissionDescription;
    int     commissionAmount = 0;
    List<String> otherDriverIds = [];

    await db.runTransaction((transaction) async {
      final orderSnapshot  = await transaction.get(orderRef);
      final driverSnapshot = await transaction.get(driverRef);

      if (!orderSnapshot.exists || !driverSnapshot.exists) return;

      final orderData = orderSnapshot.data() as Map<String, dynamic>;
      final status    = orderData["status"] as String? ?? '';

      // Accepte à la fois les assignations directes et les broadcasts
      if (status != "assigned" && status != "broadcast") return;

      final int price      = (orderData["budget"] as num? ?? 0).toInt();
      commissionAmount     = calculateCommission(price);

      final int wallet = (driverSnapshot["wallet"] as num? ?? 0).toInt();
      if (wallet < commissionAmount) {
        throw Exception("CREDIT_INSUFFISANT:$wallet:$commissionAmount");
      }

      // Livreurs à notifier de l'annulation (pour broadcast)
      final notified  = List<String>.from(orderData["notifiedDriverIds"] as List? ?? []);
      otherDriverIds  = notified.where((id) => id != driverId).toList();

      // Commission déduite + flag isOnDelivery
      transaction.update(driverRef, {
        "wallet":       wallet - commissionAmount,
        "isOnDelivery": true,
      });

      transaction.update(orderRef, {
        "status":   "accepted",
        "driverId": driverId,
        "notifiedDriverIds": FieldValue.delete(),
        if (acceptanceSelfieUrl != null) "driverAcceptanceSelfie": acceptanceSelfieUrl,
        if (driverPhotoUrl      != null) "driverPhotoUrl":         driverPhotoUrl,
      });

      commissionDescription =
          "Commission AZ Express — course ${orderData['description']?.toString().split('\n').first ?? ''} ($price FCFA)";
    });

    // Effacer pendingOrderId chez les autres livreurs notifiés
    if (otherDriverIds.isNotEmpty) {
      final batch = db.batch();
      for (final id in otherDriverIds) {
        batch.update(db.collection("livreurs").doc(id), {
          "pendingOrderId": FieldValue.delete(),
        });
      }
      await batch.commit();
    }

    if (commissionAmount > 0 && commissionDescription != null) {
      await _logTransaction(
        driverId,
        "commission",
        commissionAmount,
        commissionDescription!,
        orderId: orderId,
      );
    }
  }

  // ==============================
  // REFUSER COMMANDE (Yango-style)
  // ==============================

  /// Refus d'une course par [driverId].
  /// — Broadcast : retire ce livreur de notifiedDriverIds + efface pendingOrderId.
  ///   Si dernier livreur → reset pending + re-cherche à rayon élargi.
  /// — Assignation directe : reset pending + re-cherche.
  Future<void> declineOrder(String orderId, String driverId) async {
    final orderRef  = db.collection("orders").doc(orderId);
    final driverRef = db.collection("livreurs").doc(driverId);

    // Effacer pendingOrderId chez ce livreur immédiatement
    await driverRef.update({"pendingOrderId": FieldValue.delete()});

    List<String> remaining = [];
    String currentStatus   = '';

    await db.runTransaction((tx) async {
      final snap = await tx.get(orderRef);
      if (!snap.exists) return;
      final data    = snap.data()!;
      currentStatus = data["status"] as String? ?? '';

      if (currentStatus == "broadcast") {
        final notified = List<String>.from(data["notifiedDriverIds"] as List? ?? []);
        remaining = notified.where((id) => id != driverId).toList();

        if (remaining.isEmpty) {
          // Tous ont refusé → reset
          tx.update(orderRef, {
            "status":            "pending",
            "notifiedDriverIds": FieldValue.delete(),
          });
        } else {
          // D'autres attendent encore
          tx.update(orderRef, {"notifiedDriverIds": remaining});
        }
      } else if (currentStatus == "assigned") {
        // Assignation directe refusée
        tx.update(orderRef, {
          "status":   "pending",
          "driverId": FieldValue.delete(),
        });
      }
    });

    // Si plus aucun livreur disponible → re-chercher à rayon plus large
    if (remaining.isEmpty &&
        (currentStatus == "broadcast" || currentStatus == "assigned")) {
      final snap = await orderRef.get();
      if (!snap.exists) return;
      final d = snap.data()!;
      await findNearestDriver(
        (d["latitude"]  ?? 0).toDouble(),
        (d["longitude"] ?? 0).toDouble(),
        orderId,
        budget:   (d["budget"] as num? ?? 0).toInt(),
        radiusKm: 5.0,
      );
    }
  }

  // ==============================
  // PAIEMENT WALLET CLIENT
  // ==============================

  /// Transfère de façon atomique :
  /// - deliveryAmount  : client → livreur
  /// - medicineAmount  : client → pharmacie (si pharmacieId non null)
  /// Marque la commande isPaid:true + paymentMethod:'wallet'.
  Future<void> payOrderFromWallet({
    required String orderId,
    required String clientId,
    required String driverId,
    required int deliveryAmount,
    String? pharmacieId,
    int medicineAmount = 0,
  }) async {
    final total = deliveryAmount + medicineAmount;

    final clientRef  = db.collection('clients').doc(clientId);
    final driverRef  = db.collection('livreurs').doc(driverId);
    final orderRef   = db.collection('orders').doc(orderId);
    final pharmacieRef = pharmacieId != null
        ? db.collection('pharmacies').doc(pharmacieId)
        : null;

    await db.runTransaction((tx) async {
      final clientSnap = await tx.get(clientRef);
      final driverSnap = await tx.get(driverRef);

      final clientWallet = (clientSnap.data()?['wallet'] as num? ?? 0).toInt();
      if (clientWallet < total) {
        throw Exception('SOLDE_INSUFFISANT:$clientWallet:$total');
      }

      // Débit client
      tx.update(clientRef, {'wallet': clientWallet - total});

      // Crédit livreur
      final driverWallet = (driverSnap.data()?['wallet'] as num? ?? 0).toInt();
      tx.update(driverRef, {'wallet': driverWallet + deliveryAmount});

      // Crédit pharmacie
      if (pharmacieRef != null && medicineAmount > 0) {
        final pharmSnap = await tx.get(pharmacieRef);
        final pharmWallet = (pharmSnap.data()?['wallet'] as num? ?? 0).toInt();
        tx.update(pharmacieRef, {'wallet': pharmWallet + medicineAmount});
      }

      // Marquer commande payée
      tx.update(orderRef, {
        'isPaid': true,
        'paymentMethod': 'wallet',
        if (medicineAmount > 0) 'medicineAmount': medicineAmount,
      });
    });

    // Logs hors transaction
    final now = Timestamp.now();

    await clientRef.collection('wallet_transactions').add({
      'type': 'payment',
      'amount': total,
      'description': 'Paiement commande — livraison $deliveryAmount FCFA'
          '${medicineAmount > 0 ? ' + médicaments $medicineAmount FCFA' : ''}',
      'orderId': orderId,
      'createdAt': now,
    });

    await driverRef.collection('wallet_transactions').add({
      'type': 'earning',
      'amount': deliveryAmount,
      'description': 'Paiement client (wallet) — livraison',
      'orderId': orderId,
      'createdAt': now,
    });

    if (pharmacieRef != null && medicineAmount > 0) {
      await pharmacieRef.collection('wallet_transactions').add({
        'type': 'earning',
        'amount': medicineAmount,
        'description': 'Paiement client — médicaments',
        'orderId': orderId,
        'createdAt': now,
      });
    }
  }

  // ==============================
  // ACTIONS SUR COMMANDE
  // ==============================

  Future<void> cancelOrder(String orderId) async {
    final orderRef = db.collection("orders").doc(orderId);
    String? clientId;
    String? driverId;
    int refundAmount     = 0;
    int commissionRefund = 0;

    await db.runTransaction((tx) async {
      final orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) return;
      final data = orderSnap.data()!;

      // Lire les données utiles depuis le snapshot original
      final originalStatus  = data['status'] as String? ?? '';
      final paymentMethod   = data['paymentMethod'] as String?;
      final budget          = (data['budget'] as num? ?? 0).toInt();
      final shoppingBudget  = (data['shoppingBudget'] as num? ?? 0).toInt();
      final cid             = data['clientId'] as String?;
      final did             = data['driverId'] as String?;
      final needsClientRefund = paymentMethod == 'wallet' && cid != null;
      final needsDriverRefund = ['accepted', 'picked_up'].contains(originalStatus) && did != null;

      // Toutes les lectures AVANT les écritures
      DocumentSnapshot? clientSnap;
      DocumentSnapshot? driverSnap;
      if (needsClientRefund) {
        clientSnap = await tx.get(db.collection('clients').doc(cid));
      }
      if (needsDriverRefund) {
        driverSnap = await tx.get(db.collection('livreurs').doc(did));
      }

      // Écriture statut
      tx.update(orderRef, {"status": "cancelled"});

      // Remboursement wallet client
      if (needsClientRefund) {
        clientId     = cid;
        refundAmount = budget + shoppingBudget;
        if (refundAmount > 0 && clientSnap != null && clientSnap.exists) {
          final d = clientSnap.data() as Map<String, dynamic>?;
          final w = (d?['wallet'] as num? ?? 0).toInt();
          tx.update(db.collection('clients').doc(cid), {'wallet': w + refundAmount});
        }
      }

      // Remboursement commission livreur si commande déjà acceptée
      if (needsDriverRefund) {
        driverId         = did;
        commissionRefund = calculateCommission(budget);
        if (driverSnap != null && driverSnap.exists) {
          final d = driverSnap.data() as Map<String, dynamic>?;
          final w = (d?['wallet'] as num? ?? 0).toInt();
          tx.update(db.collection('livreurs').doc(did), {'wallet': w + commissionRefund});
        }
      }
    });

    final now = Timestamp.now();

    if (clientId != null && refundAmount > 0) {
      await db.collection('clients').doc(clientId!)
          .collection('wallet_transactions').add({
        'type': 'refund',
        'amount': refundAmount,
        'description': 'Remboursement annulation commande',
        'orderId': orderId,
        'createdAt': now,
      });
    }

    if (driverId != null && commissionRefund > 0) {
      await _logTransaction(driverId!, 'refund', commissionRefund,
          'Remboursement commission — commande annulée', orderId: orderId);
    }
  }

  Future<void> pickUpOrder(String orderId) async {
    final ref = db.collection("orders").doc(orderId);
    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      if (snap["status"] != "accepted") return;
      tx.update(ref, {
        "status": "picked_up",
        "pickedUpAt": FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> deliverOrder(
      String orderId, String driverId, int price,
      {bool markCashPaid = false,
       double? deliveredLat,
       double? deliveredLng,
       String? deliveryPhotoUrl}) async {
    final orderRef = db.collection("orders").doc(orderId);
    String? walletTarget; // 'driver' or 'partner'
    String? partnerId;
    String? partnerCol;
    int creditAmount  = 0;
    int deliveryFee   = 0;
    String payMethod  = '';

    await db.runTransaction((tx) async {
      final orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) return;
      final data = orderSnap.data()!;

      final sid            = data['sellerId'] as String?;
      final sType          = data['sellerType'] as String? ?? 'seller';
      final budget         = (data['budget'] as num? ?? 0).toInt();
      final shoppingBudget = (data['shoppingBudget'] as num? ?? 0).toInt();
      deliveryFee = budget;
      payMethod   = data['paymentMethod'] as String? ?? '';

      // Lire le wallet livreur dans tous les cas (wallet OU cash)
      final driverRef  = db.collection("livreurs").doc(driverId);
      final driverSnap = await tx.get(driverRef);

      DocumentSnapshot? partnerSnap;
      if (payMethod == 'wallet' && sid != null && sid.isNotEmpty) {
        final col = _partnerCollection(sType);
        partnerSnap = await tx.get(db.collection(col).doc(sid));
      }

      // Statut livraison
      tx.update(orderRef, {
        "status":      "delivered",
        "deliveredAt": FieldValue.serverTimestamp(),
        if (markCashPaid) "isPaid": true,
        if (deliveredLat      != null) "deliveredLat":      deliveredLat,
        if (deliveredLng      != null) "deliveredLng":      deliveredLng,
        if (deliveryPhotoUrl  != null) "deliveryPhoto":     deliveryPhotoUrl,
      });

      final driverData   = driverSnap.exists ? (driverSnap.data() as Map?) : null;
      final driverWallet = (driverData?['wallet'] as num? ?? 0).toInt();

      if (payMethod == 'wallet') {
        if (sid != null && sid.isNotEmpty) {
          // Partenaire (restaurant / pharmacie / boutique)
          partnerId    = sid;
          partnerCol   = _partnerCollection(sType);
          walletTarget = 'partner';
          creditAmount = (budget - _kCommissionAmount).clamp(0, 9999999);
          if (partnerSnap != null && partnerSnap.exists) {
            final pd = partnerSnap.data() as Map<String, dynamic>?;
            final w  = (pd?['wallet'] as num? ?? 0).toInt();
            tx.update(db.collection(partnerCol!).doc(partnerId!),
                {'wallet': w + creditAmount});
          }
          // Libérer le livreur (pas de wallet update ici, juste le flag)
          tx.update(driverRef, {'isOnDelivery': false});
        } else {
          // Livraison directe : créditer le livreur net de commission + libérer
          walletTarget = 'driver';
          creditAmount = (budget + shoppingBudget - _kCommissionAmount).clamp(0, 9999999);
          tx.update(driverRef, {
            'wallet':       driverWallet + creditAmount,
            'isOnDelivery': false,
          });
        }
      } else {
        // Cash : commission prélevée sur wallet + libérer le livreur
        walletTarget = 'cash';
        final newWallet = driverWallet - _kCommissionAmount;
        tx.update(driverRef, {
          'wallet':       newWallet,
          'isOnDelivery': false,
        });
      }
    });

    // Incrémenter le compteur de livraisons du livreur
    await db.collection("livreurs").doc(driverId).update({
      "deliveries": FieldValue.increment(1),
    });

    // ── Wallet AZ Express : +100 FCFA par livraison ─────────────────────────
    await db.collection('config').doc('az_wallet').set({
      'totalCommissions': FieldValue.increment(_kCommissionAmount),
      'totalDeliveries':  FieldValue.increment(1),
      'updatedAt':        FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // ── Journal commissions (collection dédiée) ──────────────────────────────
    await _logCommission(
      orderId:       orderId,
      driverId:      driverId,
      deliveryFee:   deliveryFee,
      driverGain:    deliveryFee - _kCommissionAmount,
      paymentMethod: payMethod,
    );

    // ── Transactions wallet ──────────────────────────────────────────────────
    if (walletTarget == 'driver' && creditAmount > 0) {
      // Paiement wallet : on crédite le gain net du livreur
      await _logTransaction(
        driverId, 'earning', creditAmount,
        'Gain livraison — $deliveryFee FCFA (commission AZ: $_kCommissionAmount FCFA)',
        orderId: orderId,
      );
    } else if (walletTarget == 'cash') {
      // Paiement espèces : on prélève la commission sur le wallet du livreur
      await _logTransaction(
        driverId, 'commission', _kCommissionAmount,
        'Commission AZ Express — espèces $deliveryFee FCFA',
        orderId: orderId,
      );
    } else if (walletTarget == 'partner' &&
        partnerId != null &&
        partnerCol != null &&
        creditAmount > 0) {
      await db
          .collection(partnerCol!)
          .doc(partnerId!)
          .collection('wallet_transactions')
          .add({
        'type':        'earning',
        'amount':      creditAmount,
        'description': 'Commande livrée — commission AZ: $_kCommissionAmount FCFA',
        'orderId':     orderId,
        'createdAt':   Timestamp.now(),
      });
    }
  }

  Future<void> _logCommission({
    required String orderId,
    required String driverId,
    required int deliveryFee,
    required int driverGain,
    required String paymentMethod,
  }) async {
    String driverName = '';
    try {
      final snap = await db.collection('livreurs').doc(driverId).get();
      driverName = snap.data()?['name'] as String? ?? '';
    } catch (_) {}

    await db.collection('commissions').add({
      'orderId':       orderId,
      'driverId':      driverId,
      'driverName':    driverName,
      'amount':        _kCommissionAmount,
      'deliveryFee':   deliveryFee,
      'driverGain':    driverGain,
      'paymentMethod': paymentMethod,
      'createdAt':     Timestamp.now(),
    });
  }

  // ==============================
  // WALLET
  // ==============================

  // ==============================
  // TRANSACTIONS WALLET
  // ==============================

  Future<void> _logTransaction(
      String driverId, String type, int amount, String description,
      {String? orderId}) async {
    await db
        .collection("livreurs")
        .doc(driverId)
        .collection("wallet_transactions")
        .add({
      "type": type,
      "amount": amount,
      "description": description,
      "orderId": orderId,
      "createdAt": Timestamp.now(),
    });
  }

  Stream<QuerySnapshot> walletTransactions(String driverId) {
    return db
        .collection("livreurs")
        .doc(driverId)
        .collection("wallet_transactions")
        .orderBy("createdAt", descending: true)
        .limit(100)
        .snapshots();
  }

  Future<void> rechargeDriverWallet(String driverId, int amount,
      {String adminNote = "Rechargé par l'admin"}) async {
    final driverRef = db.collection("livreurs").doc(driverId);
    await db.runTransaction((transaction) async {
      final snapshot = await transaction.get(driverRef);
      if (!snapshot.exists) return;
      final wallet = (snapshot["wallet"] as num? ?? 0).toInt();
      transaction.update(driverRef, {"wallet": wallet + amount});
    });
    await _logTransaction(driverId, "recharge", amount, adminNote);
  }

  Future<void> assignDriverToFleet(
      String driverId, String ownerId, String ownerName) async {
    await db.collection('livreurs').doc(driverId).update({
      'ownerId':   ownerId,
      'ownerName': ownerName,
    });
  }

  Future<void> makeDriverIndependent(String driverId) async {
    await db.collection('livreurs').doc(driverId).update({
      'ownerId':   FieldValue.delete(),
      'ownerName': FieldValue.delete(),
    });
  }

  Future<void> deductCommission(String driverId, int price,
      {String? orderId}) async {
    int commission = calculateCommission(price);
    final driverRef = db.collection("livreurs").doc(driverId);
    await db.runTransaction((transaction) async {
      final snapshot = await transaction.get(driverRef);
      if (!snapshot.exists) return;
      int wallet = (snapshot["wallet"] as num? ?? 0).toInt();
      int newWallet = (wallet - commission).clamp(0, double.maxFinite.toInt());
      transaction.update(driverRef, {"wallet": newWallet});
    });
    await _logTransaction(
      driverId,
      "commission",
      commission,
      "Commission AZ Express — course à $price FCFA",
      orderId: orderId,
    );
  }

  // ==============================
  // ANTI-FRAUDE COD
  // ==============================

  Future<bool> isClientCodEnabled(String clientId) async {
    final doc = await db.collection('clients').doc(clientId).get();
    return (doc.data()?['cashOnDeliveryEnabled'] ?? true) as bool;
  }

  Future<void> reportFakeOrder(String clientId) async {
    final ref = db.collection('clients').doc(clientId);
    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final count = ((snap.data()?['fakeOrderCount'] ?? 0) as int) + 1;
      final updates = <String, dynamic>{'fakeOrderCount': count};
      if (count >= 3) updates['cashOnDeliveryEnabled'] = false;
      tx.update(ref, updates);
    });
  }

  Future<void> resetClientCod(String clientId) async {
    await db.collection('clients').doc(clientId).update({
      'cashOnDeliveryEnabled': true,
      'fakeOrderCount': 0,
    });
  }

  // ==============================
  // WALLET VENDEURS
  // ==============================

  Future<void> creditSellerWallet(
      String sellerId, int amount, String description,
      {String? orderId}) async {
    final ref = db.collection('sellers').doc(sellerId);
    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
      tx.update(ref, {'wallet': wallet + amount});
    });
    await db
        .collection('sellers')
        .doc(sellerId)
        .collection('wallet_transactions')
        .add({
      'type': 'credit',
      'amount': amount,
      'description': description,
      'orderId': orderId,
      'createdAt': Timestamp.now(),
    });
  }

  Stream<int> sellerWallet(String sellerId) {
    return db.collection('sellers').doc(sellerId).snapshots().map(
          (snap) => (snap.data()?['wallet'] as num? ?? 0).toInt(),
        );
  }

  Stream<int> clientWallet(String clientId) {
    return db.collection('clients').doc(clientId).snapshots().map(
          (snap) => (snap.data()?['wallet'] as num? ?? 0).toInt(),
        );
  }

  // ==============================
  // NOTATION
  // ==============================

  Future<void> rateOrder(String orderId, int rating) async {
    final orderRef = db.collection("orders").doc(orderId);
    await db.runTransaction((tx) async {
      final orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) return;
      final driverId = orderSnap.data()?['driverId'] as String?;
      tx.update(orderRef, {'rating': rating});
      if (driverId != null) {
        final driverRef = db.collection("livreurs").doc(driverId);
        final driverSnap = await tx.get(driverRef);
        final currentAvg   = (driverSnap.data()?['avgRating']   as num? ?? 0).toDouble();
        final currentCount = (driverSnap.data()?['ratingCount'] as num? ?? 0).toInt();
        final newCount = currentCount + 1;
        final newAvg   = double.parse(((currentAvg * currentCount + rating) / newCount).toStringAsFixed(1));
        tx.update(driverRef, {'avgRating': newAvg, 'ratingCount': newCount});
      }
    });
  }

  // ==============================
  // PREUVE DE LIVRAISON
  // ==============================

  Future<void> setDeliveryPhoto(String orderId, String photoUrl) async {
    await db
        .collection("orders")
        .doc(orderId)
        .update({"deliveryPhoto": photoUrl});
  }

  // ==============================
  // STATS LIVREUR (patron de flotte)
  // ==============================

  Future<DriverEarningsSummary> driverEarningsSummary(
      String driverId) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart =
        todayStart.subtract(Duration(days: now.weekday - 1));
    final monthStart = DateTime(now.year, now.month, 1);

    final snap = await db
        .collection("orders")
        .where("driverId", isEqualTo: driverId)
        .where("status", isEqualTo: "delivered")
        .get();

    int todayCourses = 0, todayGain = 0;
    int weekCourses = 0, weekGain = 0;
    int monthCourses = 0, monthGain = 0;

    for (final doc in snap.docs) {
      final data = doc.data();
      final ts = data["deliveredAt"] ?? data["createdAt"];
      if (ts == null) continue;
      final date = (ts as Timestamp).toDate();
      final budget = (data["budget"] as num? ?? 0).toInt();
      final gain = calculateDriverGain(budget);

      if (date.isAfter(todayStart)) {
        todayCourses++;
        todayGain += gain;
      }
      if (date.isAfter(weekStart)) {
        weekCourses++;
        weekGain += gain;
      }
      if (date.isAfter(monthStart)) {
        monthCourses++;
        monthGain += gain;
      }
    }

    return DriverEarningsSummary(
      todayCourses: todayCourses,
      todayGain: todayGain,
      weekCourses: weekCourses,
      weekGain: weekGain,
      monthCourses: monthCourses,
      monthGain: monthGain,
    );
  }

  // ==============================
  // FLOTTE
  // ==============================

  Future<String> createFleetOwner(String name, String phone) async {
    final existing = await db
        .collection("fleet_owners")
        .where("phone", isEqualTo: phone)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) return existing.docs.first.id;

    final ref = await db.collection("fleet_owners").add({
      "name": name,
      "phone": phone,
      "createdAt": Timestamp.now(),
    });
    return ref.id;
  }

  Future<Map<String, dynamic>?> getFleetOwner(String phone) async {
    final snap = await db
        .collection("fleet_owners")
        .where("phone", isEqualTo: phone)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return {"id": snap.docs.first.id, ...snap.docs.first.data()};
  }

  Future<void> addDriverToFleet(
      String ownerId, String name, String phone) async {
    await db.collection("livreurs").add({
      "name": name,
      "phone": phone,
      "ownerId": ownerId,
      "wallet": 0,
      "isOnline": false,
      "lat": 0,
      "lng": 0,
      "createdAt": Timestamp.now(),
    });
  }

  Stream<QuerySnapshot> fleetDrivers(String ownerId) {
    return db
        .collection("livreurs")
        .where("ownerId", isEqualTo: ownerId)
        .snapshots();
  }

  // ==============================
  // RECHARGE / RETRAIT UNIVERSEL
  // ==============================

  String _col(String userType) {
    switch (userType) {
      case 'driver': return 'livreurs';
      case 'seller': return 'sellers';
      default: return 'clients';
    }
  }

  // Retourne la collection Firestore correspondant au type de partenaire
  String _partnerCollection(String sellerType) {
    switch (sellerType) {
      case 'restaurant':   return 'restaurants';
      case 'boulangerie':  return 'boulangeries';
      case 'pharmacie':    return 'pharmacies';
      default:             return 'sellers';
    }
  }

  Future<void> createRechargeRequest({
    required String userId,
    required String userType,
    required String userName,
    required int amount,
    required String method,
    required String senderPhone,
    String? txRef,
  }) async {
    await db.collection('recharge_requests').add({
      'userId': userId,
      'userType': userType,
      'userName': userName,
      'amount': amount,
      'method': method,
      'senderPhone': senderPhone,
      if (txRef != null && txRef.isNotEmpty) 'txRef': txRef,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> createWithdrawalRequest({
    required String userId,
    required String userType,
    required String userName,
    required int amount,
    required String method,
    required String phone,
  }) async {
    await db.collection('withdrawal_requests').add({
      'userId': userId,
      'userType': userType,
      'userName': userName,
      'amount': amount,
      'method': method,
      'phone': phone,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> approveRecharge(
      String requestId, String userId, String userType, int amount, String method) async {
    final colName = _col(userType);
    final batch = db.batch();
    batch.update(db.collection('recharge_requests').doc(requestId), {
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
    });
    batch.update(db.collection(colName).doc(userId), {
      'wallet': FieldValue.increment(amount),
    });
    final txRef = db.collection(colName).doc(userId).collection('wallet_transactions').doc();
    batch.set(txRef, {
      'type': 'recharge',
      'amount': amount,
      'description': 'Recharge ${method == "wave" ? "Wave" : "Orange Money"} — $amount FCFA',
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<void> rejectRecharge(String requestId) async {
    await db.collection('recharge_requests').doc(requestId).update({
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Admin confirme un retrait → débite le wallet et marque comme traité.
  Future<void> approveWithdrawal(
      String requestId, String userId, String userType, int amount) async {
    final colName = _col(userType);
    final userRef  = db.collection(colName).doc(userId);

    final batch = db.batch();
    batch.update(db.collection('withdrawal_requests').doc(requestId), {
      'status':      'processed',
      'processedAt': FieldValue.serverTimestamp(),
    });
    // Débiter le wallet de l'utilisateur
    batch.update(userRef, {'wallet': FieldValue.increment(-amount)});
    // Logger la transaction
    final txRef = userRef.collection('wallet_transactions').doc();
    batch.set(txRef, {
      'type':        'withdrawal',
      'amount':      amount,
      'description': 'Retrait approuvé — $amount FCFA',
      'createdAt':   FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Admin rejette un retrait pending_manual → rembourse le wallet (déjà débité).
  Future<void> rejectWithdrawal(String requestId) async {
    final wdSnap = await db.collection('withdrawal_requests').doc(requestId).get();
    if (!wdSnap.exists) return;
    final data = wdSnap.data()!;
    final userId   = data['userId']   as String?;
    final userType = data['userType'] as String? ?? 'client';
    final amount   = (data['amount']  as num?)?.toInt() ?? 0;
    final colName  = _col(userType);

    final batch = db.batch();
    batch.update(db.collection('withdrawal_requests').doc(requestId), {
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
    });
    if (userId != null && amount > 0) {
      batch.update(db.collection(colName).doc(userId), {
        'wallet': FieldValue.increment(amount),
      });
      final txRef = db.collection(colName).doc(userId)
          .collection('wallet_transactions').doc();
      batch.set(txRef, {
        'type': 'refund',
        'amount': amount,
        'description': 'Remboursement retrait rejeté — $amount FCFA',
        'withdrawId': requestId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  Stream<QuerySnapshot> pendingRecharges() => db
      .collection('recharge_requests')
      .where('status', isEqualTo: 'pending')
      .snapshots();

  Stream<QuerySnapshot> rechargesByStatus(String status) => db
      .collection('recharge_requests')
      .where('status', isEqualTo: status)
      .snapshots();

  Stream<QuerySnapshot> pendingWithdrawals() => db
      .collection('withdrawal_requests')
      .where('status', isEqualTo: 'pending')
      .snapshots();

  Stream<QuerySnapshot> withdrawalsByStatus(String status) => db
      .collection('withdrawal_requests')
      .where('status', isEqualTo: status)
      .snapshots();
}

