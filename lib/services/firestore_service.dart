import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/order_model.dart';
import '../models/driver_earnings_summary.dart';

class FirestoreService {
  final FirebaseFirestore db = FirebaseFirestore.instance;

  // ==============================
  // COMMISSIONS
  // ==============================

  // Commission tiered : 100 FCFA pour 500-1000 FCFA, 200 FCFA au-delà
  static int _commissionBasic = 100; // courses 500–1000 FCFA
  static int _commissionStandard = 200; // courses > 1000 FCFA
  static int _threshold = 1000;

  /// Charge la config commission depuis Firestore (appelé au démarrage).
  Future<void> loadCommissionConfig() async {
    try {
      final doc = await db.collection('config').doc('commission').get();
      if (doc.exists) {
        final data = doc.data()!;
        final basic = data['commissionBasic'];
        final standard = data['commissionStandard'];
        final thresh = data['threshold'];
        if (basic != null) _commissionBasic = (basic as num).toInt();
        if (standard != null) _commissionStandard = (standard as num).toInt();
        if (thresh != null) _threshold = (thresh as num).toInt();
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

  Future<void> createOrder(OrderModel order,
      {bool alreadyCreated = false}) async {
    final orderRef = db.collection("orders").doc(order.id);
    if (!alreadyCreated) {
      await orderRef.set(order.toMap());
    }
    // Tente l'assignation auto du livreur le plus proche.
    // Volontairement non bloquant pour la création de commande (déjà réussie
    // à ce stade) — mais l'échec est désormais loggé plutôt qu'avalé en
    // silence total : un dispatch qui échoue (timeout, erreur réseau...)
    // laissait jusqu'ici la commande "pending" sans aucune trace exploitable
    // avant l'expiration automatique 10 min plus tard (autoExpireOrders).
    try {
      await findNearestDriver(order.latitude, order.longitude, order.id,
          budget: order.budget);
    } catch (e) {
      debugPrint('[FirestoreService.createOrder] dispatch initial échoué pour '
          '${order.id} : $e — la commande reste pending, '
          'autoExpireOrders prendra le relais si aucun retry ne réussit.');
    }
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
  // TROUVER LIVREUR LE PLUS PROCHE
  // ==============================

  /// Délègue la recherche/assignation au Cloud Function `dispatchOrderToDriver`.
  /// La logique (filtre isOnline/isOnDelivery/wallet≥commission/GPS<3min, tri
  /// par distance, top 5, assignation directe ou broadcast) tourne désormais
  /// côté serveur (Admin SDK) — plus jamais côté client, qui ne peut plus lire
  /// le champ `wallet` des autres livreurs (voir FIRESTORE_RULES.md, §5). Le
  /// CF relit lat/longitude/budget depuis `orders/{orderId}` lui-même : les
  /// paramètres [clientLat]/[clientLng]/[budget] sont conservés dans la
  /// signature pour ne pas casser les appelants existants, mais ignorés côté
  /// serveur (l'appelant doit avoir déjà écrit ces champs sur la commande).
  Future<bool> findNearestDriver(
      double clientLat, double clientLng, String orderId,
      {int budget = 0, double radiusKm = 2.0}) async {
    final callable =
        FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(
      'dispatchOrderToDriver',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'orderId': orderId,
      'radiusKm': radiusKm,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return data['dispatched'] == true;
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
    final orderRef = db.collection("orders").doc(orderId);
    final driverRef = db.collection("livreurs").doc(driverId);

    String? commissionDescription;
    int commissionAmount = 0;
    List<String> otherDriverIds = [];

    await db.runTransaction((transaction) async {
      final orderSnapshot = await transaction.get(orderRef);
      final driverSnapshot = await transaction.get(driverRef);

      if (!orderSnapshot.exists || !driverSnapshot.exists) return;

      final orderData = orderSnapshot.data() as Map<String, dynamic>;
      final status = orderData["status"] as String? ?? '';

      // Accepte à la fois les assignations directes et les broadcasts
      if (status != "assigned" && status != "broadcast") return;

      // Ré-vérification à l'acceptation : dispatchOrder() (functions/dispatch.js)
      // exclut déjà les livreurs suspendus/hors-ligne/déjà en course au moment
      // de l'OFFRE, mais rien ne re-vérifiait ces mêmes conditions au moment de
      // l'ACCEPTATION — un livreur notifié avant d'être suspendu (ou passé
      // hors-ligne, ou déjà occupé par une autre course acceptée entre-temps)
      // pouvait donc encore accepter. Fenêtre étroite mais réelle.
      //
      // Correctif 2026-07-19 : `driverSnapshot["champ"]` (operator [] de
      // DocumentSnapshot) appelle .get("champ") en interne, qui lève un
      // StateError ("field ... does not exist within the
      // DocumentSnapshotPlatform") si le champ est absent — le `as bool? ??
      // false` qui suit ne protège jamais contre ça, l'exception part avant
      // que le `??` ne puisse s'appliquer. Confirmé en production : les
      // livreurs approuvés via le flux standard (driver_requests_page.dart)
      // n'ont jamais `isSuspended`/`isAvailable` à la création (déjà
      // documenté CLAUDE.md), donc CHAQUE première acceptation d'un nouveau
      // livreur faisait planter cette transaction. Corrigé en passant par
      // `.data()` (un Map, dont l'opérateur [] retourne bien `null` sur une
      // clé absente, sans exception) avant de lire les champs individuels.
      final driverData = driverSnapshot.data() ?? {};
      final bool driverSuspended = driverData["isSuspended"] as bool? ?? false;
      final bool driverOnline = driverData["isOnline"] as bool? ?? false;
      final bool driverOnDelivery =
          driverData["isOnDelivery"] as bool? ?? false;
      if (driverSuspended) {
        throw Exception(
            "Votre compte a été suspendu, vous ne pouvez plus accepter de commandes.");
      }
      if (!driverOnline) {
        throw Exception("Vous devez être en ligne pour accepter une commande.");
      }
      if (driverOnDelivery) {
        throw Exception("Vous avez déjà une livraison en cours.");
      }

      final int price = (orderData["budget"] as num? ?? 0).toInt();
      commissionAmount = calculateCommission(price);

      final int wallet = (driverSnapshot["wallet"] as num? ?? 0).toInt();
      if (wallet < commissionAmount) {
        throw Exception("CREDIT_INSUFFISANT:$wallet:$commissionAmount");
      }

      // Livreurs à notifier de l'annulation (pour broadcast)
      final notified =
          List<String>.from(orderData["notifiedDriverIds"] as List? ?? []);
      otherDriverIds = notified.where((id) => id != driverId).toList();

      // Commission déduite + flag isOnDelivery
      transaction.update(driverRef, {
        "wallet": wallet - commissionAmount,
        "isOnDelivery": true,
      });

      transaction.update(orderRef, {
        "status": "accepted",
        "driverId": driverId,
        "notifiedDriverIds": FieldValue.delete(),
        if (acceptanceSelfieUrl != null)
          "driverAcceptanceSelfie": acceptanceSelfieUrl,
        if (driverPhotoUrl != null) "driverPhotoUrl": driverPhotoUrl,
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
    final orderRef = db.collection("orders").doc(orderId);
    final driverRef = db.collection("livreurs").doc(driverId);

    // Effacer pendingOrderId chez ce livreur immédiatement
    await driverRef.update({"pendingOrderId": FieldValue.delete()});

    List<String> remaining = [];
    String currentStatus = '';

    await db.runTransaction((tx) async {
      final snap = await tx.get(orderRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      currentStatus = data["status"] as String? ?? '';

      if (currentStatus == "broadcast") {
        final notified =
            List<String>.from(data["notifiedDriverIds"] as List? ?? []);
        remaining = notified.where((id) => id != driverId).toList();

        if (remaining.isEmpty) {
          // Tous ont refusé → reset
          tx.update(orderRef, {
            "status": "pending",
            "notifiedDriverIds": FieldValue.delete(),
          });
        } else {
          // D'autres attendent encore
          tx.update(orderRef, {"notifiedDriverIds": remaining});
        }
      } else if (currentStatus == "assigned") {
        // Assignation directe refusée
        tx.update(orderRef, {
          "status": "pending",
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
        (d["latitude"] ?? 0).toDouble(),
        (d["longitude"] ?? 0).toDouble(),
        orderId,
        budget: (d["budget"] as num? ?? 0).toInt(),
        radiusKm: 5.0,
      );
    }
  }

  // ==============================
  // PAIEMENT WALLET CLIENT
  // ==============================

  /// Délègue au Cloud Function `payOrderFromWalletCF` : le crédit du wallet
  /// livreur (et pharmacie) est une écriture cross-user que le client ne peut
  /// plus faire directement (voir firestore.rules, `livreurs/{id}` n'autorise
  /// que l'admin ou le propriétaire diminuant son propre solde). Le CF relit
  /// driverId/pharmacieId/deliveryAmount depuis la commande elle-même — les
  /// paramètres [clientId]/[driverId]/[deliveryAmount] restent dans la
  /// signature pour ne pas casser l'appelant (suivi_commande.dart), mais sont
  /// ignorés côté serveur.
  Future<void> payOrderFromWallet({
    required String orderId,
    required String clientId,
    required String driverId,
    required int deliveryAmount,
    String? pharmacieId,
    int medicineAmount = 0,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('payOrderFromWalletCF');
    await callable.call(<String, dynamic>{
      'orderId': orderId,
      'medicineAmount': medicineAmount,
    });
  }

  // ==============================
  // ACTIONS SUR COMMANDE
  // ==============================

  /// Délègue au Cloud Function `cancelOrderCF` : le remboursement de la
  /// commission au livreur est une écriture cross-user (client → livreur) que
  /// le client ne peut plus faire directement (voir firestore.rules). Le CF
  /// relit budget/paymentMethod/driverId depuis la commande elle-même et
  /// vérifie que l'appelant est bien le client propriétaire.
  Future<void> cancelOrder(String orderId) async {
    final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('cancelOrderCF');
    await callable.call(<String, dynamic>{'orderId': orderId});
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

  /// Délègue au Cloud Function `deliverOrderCF` : le crédit du wallet livreur
  /// (paiement wallet direct, augmentation de son propre solde) et le crédit
  /// du partenaire (restaurant/pharmacie/boutique) sont tous deux des
  /// écritures que le livreur/client ne peut plus faire directement (voir
  /// firestore.rules — le propriétaire ne peut que diminuer son wallet). Le
  /// CF relit price/sellerId/paymentMethod depuis la commande elle-même et
  /// vérifie que l'appelant est bien le livreur assigné ; [driverId]/[price]
  /// restent dans la signature pour ne pas casser l'appelant
  /// (driver_dashboard.dart) mais sont ignorés côté serveur.
  Future<void> deliverOrder(String orderId, String driverId, int price,
      {bool markCashPaid = false,
      double? deliveredLat,
      double? deliveredLng,
      String? deliveryPhotoUrl}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('deliverOrderCF');
    await callable.call(<String, dynamic>{
      'orderId': orderId,
      'markCashPaid': markCashPaid,
      if (deliveredLat != null) 'deliveredLat': deliveredLat,
      if (deliveredLng != null) 'deliveredLng': deliveredLng,
      if (deliveryPhotoUrl != null) 'deliveryPhotoUrl': deliveryPhotoUrl,
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
      'ownerId': ownerId,
      'ownerName': ownerName,
    });
  }

  Future<void> makeDriverIndependent(String driverId) async {
    await db.collection('livreurs').doc(driverId).update({
      'ownerId': FieldValue.delete(),
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
        final currentAvg =
            (driverSnap.data()?['avgRating'] as num? ?? 0).toDouble();
        final currentCount =
            (driverSnap.data()?['ratingCount'] as num? ?? 0).toInt();
        final newCount = currentCount + 1;
        final newAvg = double.parse(
            ((currentAvg * currentCount + rating) / newCount)
                .toStringAsFixed(1));
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

  Future<DriverEarningsSummary> driverEarningsSummary(String driverId) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = todayStart.subtract(Duration(days: now.weekday - 1));
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
      case 'driver':
        return 'livreurs';
      case 'seller':
        return 'sellers';
      default:
        return 'clients';
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

  Future<void> approveRecharge(String requestId, String userId, String userType,
      int amount, String method) async {
    final colName = _col(userType);
    final batch = db.batch();
    batch.update(db.collection('recharge_requests').doc(requestId), {
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
    });
    batch.update(db.collection(colName).doc(userId), {
      'wallet': FieldValue.increment(amount),
    });
    final txRef = db
        .collection(colName)
        .doc(userId)
        .collection('wallet_transactions')
        .doc();
    batch.set(txRef, {
      'type': 'recharge',
      'amount': amount,
      'description':
          'Recharge ${method == "wave" ? "Wave" : "Orange Money"} — $amount FCFA',
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
    final userRef = db.collection(colName).doc(userId);

    final batch = db.batch();
    batch.update(db.collection('withdrawal_requests').doc(requestId), {
      'status': 'processed',
      'processedAt': FieldValue.serverTimestamp(),
    });
    // Débiter le wallet de l'utilisateur
    batch.update(userRef, {'wallet': FieldValue.increment(-amount)});
    // Logger la transaction
    final txRef = userRef.collection('wallet_transactions').doc();
    batch.set(txRef, {
      'type': 'withdrawal',
      'amount': amount,
      'description': 'Retrait approuvé — $amount FCFA',
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Admin rejette un retrait pending_manual → rembourse le wallet (déjà débité).
  Future<void> rejectWithdrawal(String requestId) async {
    final wdSnap =
        await db.collection('withdrawal_requests').doc(requestId).get();
    if (!wdSnap.exists) return;
    final data = wdSnap.data()!;
    final userId = data['userId'] as String?;
    final userType = data['userType'] as String? ?? 'client';
    final amount = (data['amount'] as num?)?.toInt() ?? 0;
    final colName = _col(userType);

    final batch = db.batch();
    batch.update(db.collection('withdrawal_requests').doc(requestId), {
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
    });
    if (userId != null && amount > 0) {
      batch.update(db.collection(colName).doc(userId), {
        'wallet': FieldValue.increment(amount),
      });
      final txRef = db
          .collection(colName)
          .doc(userId)
          .collection('wallet_transactions')
          .doc();
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
