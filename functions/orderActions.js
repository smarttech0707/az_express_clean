'use strict';

// Fabriques pour payOrderFromWalletCF / cancelOrderCF / deliverOrderCF —
// séparées de index.js pour rester testables sans initialiser Firebase Admin
// (même pattern que azia/pendingActions.js:buildConfirmAction). Portage
// serveur de FirestoreService.payOrderFromWallet/cancelOrder/deliverOrder
// (lib/services/firestore_service.dart) : ces trois actions créditaient le
// wallet d'UN AUTRE utilisateur (client → livreur, livreur → lui-même en
// augmentant son solde) depuis des transactions Firestore lancées
// directement par le client Flutter — la règle `livreurs/{id}` n'autorise
// que isAdmin() ou le propriétaire DIMINUANT son propre wallet, donc ces
// écritures cross-user étaient déjà rejetées par les règles en production
// (bug préexistant). Portage fidèle de la même logique métier côté Admin SDK,
// qui ignore les règles et peut donc exécuter légitimement ces crédits.

const AZ_COMMISSION_FIXED = 100; // même constante que _kCommissionAmount côté Dart

function partnerCollection(sellerType) {
  switch (sellerType) {
    case 'restaurant':  return 'restaurants';
    case 'boulangerie': return 'boulangeries';
    case 'pharmacie':   return 'pharmacies';
    default:            return 'sellers';
  }
}

// Remplace FirestoreService.payOrderFromWallet() : le client paie une
// commande (frais de livraison + éventuellement médicaments) directement
// depuis son wallet. medicineAmount reste attesté par le client (le prix réel
// payé en pharmacie n'a pas d'autre source de vérité côté serveur) —
// comportement déjà existant, juste borné pour éviter un montant aberrant.
function buildPayOrderFromWallet({ db, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { orderId, medicineAmount } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'pay_order_wallet', 20, 60);

    const medAmount = Math.max(0, Math.min(500000, Math.round(Number(medicineAmount) || 0)));
    const orderRef  = db.collection('orders').doc(String(orderId));

    let driverId, pharmacieId, deliveryAmount, total;

    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.clientId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande n'est pas la vôtre");
      }
      if (order.isPaid === true) {
        throw new HttpsError('failed-precondition', 'Commande déjà payée');
      }
      driverId = order.driverId;
      if (!driverId) {
        throw new HttpsError('failed-precondition', "Aucun livreur n'est encore assigné");
      }
      pharmacieId    = order.pharmacieId || null;
      deliveryAmount = Number(order.budget || 0);
      total          = deliveryAmount + medAmount;

      const clientRef = db.collection('clients').doc(uid);
      const driverRef = db.collection('livreurs').doc(driverId);
      const clientSnap = await tx.get(clientRef);
      const driverSnap = await tx.get(driverRef);

      const clientWallet = Number(clientSnap.data()?.wallet || 0);
      if (clientWallet < total) {
        // Format conservé pour compatibilité avec le parsing existant côté
        // Flutter (suivi_commande.dart cherche la sous-chaîne SOLDE_INSUFFISANT).
        throw new HttpsError('failed-precondition', `SOLDE_INSUFFISANT:${clientWallet}:${total}`);
      }
      tx.update(clientRef, { wallet: clientWallet - total });

      const driverWallet = Number(driverSnap.data()?.wallet || 0);
      tx.update(driverRef, { wallet: driverWallet + deliveryAmount });

      if (pharmacieId && medAmount > 0) {
        const pharmRef  = db.collection('pharmacies').doc(pharmacieId);
        const pharmSnap = await tx.get(pharmRef);
        const pharmWallet = Number(pharmSnap.data()?.wallet || 0);
        tx.update(pharmRef, { wallet: pharmWallet + medAmount });
      }

      tx.update(orderRef, {
        isPaid: true,
        paymentMethod: 'wallet',
        ...(medAmount > 0 ? { medicineAmount: medAmount } : {}),
      });
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    await db.collection('clients').doc(uid).collection('wallet_transactions').add({
      type: 'payment', amount: total,
      description: `Paiement commande — livraison ${deliveryAmount} FCFA` +
        (medAmount > 0 ? ` + médicaments ${medAmount} FCFA` : ''),
      orderId, createdAt: now,
    });
    await db.collection('livreurs').doc(driverId).collection('wallet_transactions').add({
      type: 'earning', amount: deliveryAmount,
      description: 'Paiement client (wallet) — livraison',
      orderId, createdAt: now,
    });
    if (pharmacieId && medAmount > 0) {
      await db.collection('pharmacies').doc(pharmacieId).collection('wallet_transactions').add({
        type: 'earning', amount: medAmount,
        description: 'Paiement client — médicaments',
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'client', action: 'pay_order_wallet', targetId: orderId,
      amount: total, metadata: { deliveryAmount, medicineAmount: medAmount, driverId },
    });

    return { success: true };
  });
}

// Remplace FirestoreService.cancelOrder() : annulation par le client
// propriétaire de la commande, avec remboursement wallet client (si payée en
// wallet) et remboursement de la commission au livreur (si la commande avait
// déjà été acceptée/récupérée).
function buildCancelOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { orderId } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'cancel_order', 20, 60);

    const orderRef = db.collection('orders').doc(String(orderId));
    let clientRefund = 0, driverRefund = 0, driverId = null;

    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.clientId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande n'est pas la vôtre");
      }
      if (['delivered', 'cancelled'].includes(order.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut plus être annulée');
      }

      const budget         = Number(order.budget || 0);
      const shoppingBudget = Number(order.shoppingBudget || 0);
      const needsClientRefund = order.paymentMethod === 'wallet';
      const needsDriverRefund = ['accepted', 'picked_up'].includes(order.status) && !!order.driverId;

      const clientRef = db.collection('clients').doc(uid);
      const driverRef = needsDriverRefund ? db.collection('livreurs').doc(order.driverId) : null;

      const clientSnap = needsClientRefund ? await tx.get(clientRef) : null;
      const driverSnap = needsDriverRefund ? await tx.get(driverRef) : null;

      tx.update(orderRef, { status: 'cancelled' });

      if (needsClientRefund) {
        clientRefund = budget + shoppingBudget;
        if (clientRefund > 0 && clientSnap.exists) {
          const w = Number(clientSnap.data().wallet || 0);
          tx.update(clientRef, { wallet: w + clientRefund });
        }
      }

      if (needsDriverRefund) {
        driverId     = order.driverId;
        driverRefund = await calculateCommission(db, budget);
        if (driverSnap.exists) {
          const w = Number(driverSnap.data().wallet || 0);
          tx.update(driverRef, { wallet: w + driverRefund });
        }
      }
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    if (clientRefund > 0) {
      await db.collection('clients').doc(uid).collection('wallet_transactions').add({
        type: 'refund', amount: clientRefund,
        description: 'Remboursement annulation commande',
        orderId, createdAt: now,
      });
    }
    if (driverId && driverRefund > 0) {
      await db.collection('livreurs').doc(driverId).collection('wallet_transactions').add({
        type: 'refund', amount: driverRefund,
        description: 'Remboursement commission — commande annulée',
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'client', action: 'cancel_order', targetId: orderId,
      metadata: { clientRefund, driverRefund, driverId },
    });

    return { success: true };
  });
}

// Remplace FirestoreService.deliverOrder() : le livreur assigné marque la
// commande comme livrée. deliveredLat/deliveredLng/deliveryPhotoUrl restent
// attestés par le client (position GPS et photo au moment de la livraison —
// aucune autre source de vérité côté serveur), comme avant. price n'est plus
// un paramètre : relu depuis la commande elle-même (order.budget) pour ne
// jamais faire confiance à un montant fourni par le client.
function buildDeliverOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { orderId, markCashPaid, deliveredLat, deliveredLng, deliveryPhotoUrl } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'deliver_order', 30, 60);

    const orderRef  = db.collection('orders').doc(String(orderId));
    const driverRef = db.collection('livreurs').doc(uid);

    let walletTarget = null, partnerId = null, partnerCol = null;
    let creditAmount = 0, deliveryFee = 0, payMethod = '';

    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.driverId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande ne vous est pas assignée");
      }
      if (!['accepted', 'picked_up'].includes(order.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut pas être marquée livrée');
      }

      const sid            = order.sellerId || null;
      const sType          = order.sellerType || 'seller';
      const budget         = Number(order.budget || 0);
      const shoppingBudget = Number(order.shoppingBudget || 0);
      deliveryFee = budget;
      payMethod   = order.paymentMethod || '';

      const driverSnap = await tx.get(driverRef);

      let partnerRef = null, partnerSnap = null;
      if (payMethod === 'wallet' && sid) {
        partnerCol  = partnerCollection(sType);
        partnerRef  = db.collection(partnerCol).doc(sid);
        partnerSnap = await tx.get(partnerRef);
      }

      tx.update(orderRef, {
        status:      'delivered',
        deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(markCashPaid === true ? { isPaid: true } : {}),
        ...(typeof deliveredLat === 'number' ? { deliveredLat } : {}),
        ...(typeof deliveredLng === 'number' ? { deliveredLng } : {}),
        ...(deliveryPhotoUrl ? { deliveryPhoto: deliveryPhotoUrl } : {}),
      });

      const driverWallet = Number(driverSnap.data()?.wallet || 0);

      if (payMethod === 'wallet') {
        if (sid) {
          partnerId    = sid;
          walletTarget = 'partner';
          creditAmount = Math.max(0, budget - AZ_COMMISSION_FIXED);
          if (partnerSnap && partnerSnap.exists) {
            const w = Number(partnerSnap.data().wallet || 0);
            tx.update(partnerRef, { wallet: w + creditAmount });
          }
          tx.update(driverRef, { isOnDelivery: false });
        } else {
          walletTarget = 'driver';
          creditAmount = Math.max(0, budget + shoppingBudget - AZ_COMMISSION_FIXED);
          tx.update(driverRef, {
            wallet:       driverWallet + creditAmount,
            isOnDelivery: false,
          });
        }
      } else {
        walletTarget = 'cash';
        tx.update(driverRef, {
          wallet:       driverWallet - AZ_COMMISSION_FIXED,
          isOnDelivery: false,
        });
      }
    });

    // Hors transaction : compteurs + journaux (même comportement que côté Dart)
    await driverRef.update({ deliveries: admin.firestore.FieldValue.increment(1) });

    await db.collection('config').doc('az_wallet').set({
      totalCommissions: admin.firestore.FieldValue.increment(AZ_COMMISSION_FIXED),
      totalDeliveries:  admin.firestore.FieldValue.increment(1),
      updatedAt:        admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    let driverName = '';
    try {
      const snap = await driverRef.get();
      driverName = snap.data()?.name || '';
    } catch (_) { /* non-bloquant */ }

    await db.collection('commissions').add({
      orderId, driverId: uid, driverName,
      amount:        AZ_COMMISSION_FIXED,
      deliveryFee,
      driverGain:    deliveryFee - AZ_COMMISSION_FIXED,
      paymentMethod: payMethod,
      createdAt:     admin.firestore.FieldValue.serverTimestamp(),
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    if (walletTarget === 'driver' && creditAmount > 0) {
      await driverRef.collection('wallet_transactions').add({
        type: 'earning', amount: creditAmount,
        description: `Gain livraison — ${deliveryFee} FCFA (commission AZ: ${AZ_COMMISSION_FIXED} FCFA)`,
        orderId, createdAt: now,
      });
    } else if (walletTarget === 'cash') {
      await driverRef.collection('wallet_transactions').add({
        type: 'commission', amount: AZ_COMMISSION_FIXED,
        description: `Commission AZ Express — espèces ${deliveryFee} FCFA`,
        orderId, createdAt: now,
      });
    } else if (walletTarget === 'partner' && partnerId && partnerCol && creditAmount > 0) {
      await db.collection(partnerCol).doc(partnerId).collection('wallet_transactions').add({
        type: 'earning', amount: creditAmount,
        description: `Commande livrée — commission AZ: ${AZ_COMMISSION_FIXED} FCFA`,
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'driver', action: 'deliver_order', targetId: orderId,
      amount: creditAmount || null, metadata: { walletTarget, deliveryFee, payMethod },
    });

    return { success: true };
  });
}

const BOUTIQUE_DELIVERY_FEE = 500; // même constante que boutique_page.dart côté Dart

// Remplace FirestoreService.creditSellerWallet() appelé depuis
// lib/screens/client/boutique_page.dart (Prompt 28) : le client débitait son
// propre wallet dans une transaction, PUIS créditait le wallet du vendeur
// boutique dans une écriture séparée, non transactionnelle, lancée
// directement par le client. La règle `sellers/{id}` n'autorise que
// isAdmin() ou le propriétaire avec `unchanged('wallet')` — un client ne peut
// donc JAMAIS créditer un vendeur, cette écriture échouait systématiquement
// (`permission-denied`) alors que le débit client + la création de la
// commande avaient déjà réussi juste avant : bug de paiement partiel réel en
// production (argent débité, vendeur jamais crédité, commande de livraison
// jamais créée), pas une simple fenêtre de course. Porté en Cloud Function :
// débit client + crédit vendeur + décrément stock + création de la commande
// boutique dans une seule transaction ; la course de livraison est créée et
// dispatchée en best-effort après coup (même comportement que l'original :
// un échec de cette étape n'invalide pas l'achat déjà payé).
function buildPayBoutiqueOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, dispatchOrder }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { productId, qty, deliveryLat, deliveryLng } = request.data || {};
    if (!productId) throw new HttpsError('invalid-argument', 'productId manquant');
    const quantity = Math.max(1, Math.round(Number(qty) || 1));

    await checkRateLimit(uid, 'pay_boutique_order', 20, 60);

    // Vendeur boutique unique — même requête que boutique_page.dart côté
    // Dart, non transactionnelle (ce compte change rarement, risque négligeable).
    const sellerSnap = await db.collection('sellers').where('type', '==', 'boutique').limit(1).get();
    if (sellerSnap.empty) {
      throw new HttpsError('failed-precondition', 'Aucun vendeur boutique configuré');
    }
    const sellerDoc  = sellerSnap.docs[0];
    const sellerId   = sellerDoc.id;
    const sellerName = sellerDoc.data().name || 'Boutique AZ';

    const orderRef = db.collection('boutique_orders').doc();
    const orderId  = orderRef.id;

    let totalPrice, productName, productCategory;

    await db.runTransaction(async (tx) => {
      const productRef = db.collection('boutique_products').doc(String(productId));
      const clientRef  = db.collection('clients').doc(uid);
      const sellerRef  = db.collection('sellers').doc(sellerId);

      const productSnap = await tx.get(productRef);
      if (!productSnap.exists) throw new HttpsError('not-found', 'Produit introuvable');
      const product = productSnap.data();

      const currentStock = Number(product.stock || 0);
      if (currentStock < quantity) {
        throw new HttpsError('failed-precondition', 'STOCK_EPUISE');
      }

      const unitPrice = Number(product.price || 0);
      totalPrice      = unitPrice * quantity;
      productName     = product.name || null;
      productCategory = product.category || null;
      if (totalPrice <= 0) throw new HttpsError('failed-precondition', 'Prix produit invalide');

      const clientSnap    = await tx.get(clientRef);
      const clientWallet  = Number(clientSnap.data()?.wallet || 0);
      if (clientWallet < totalPrice) {
        // Format conservé pour compatibilité avec le parsing existant côté
        // Flutter (boutique_page.dart cherche la sous-chaîne SOLDE_INSUFFISANT).
        throw new HttpsError('failed-precondition', `SOLDE_INSUFFISANT:${clientWallet}:${totalPrice}`);
      }

      const sellerSnapTx = await tx.get(sellerRef);
      const sellerWallet = Number(sellerSnapTx.data()?.wallet || 0);

      tx.update(clientRef, { wallet: clientWallet - totalPrice });
      tx.update(sellerRef, { wallet: sellerWallet + totalPrice });
      tx.update(productRef, { stock: currentStock - quantity });

      tx.set(orderRef, {
        id: orderId,
        clientId: uid,
        sellerId,
        productId: String(productId),
        productName,
        productCategory,
        qty:           quantity,
        unitPrice,
        totalPrice,
        paymentMethod: 'wallet',
        status:        'paid',
        deliveryDeadline: admin.firestore.Timestamp.fromMillis(Date.now() + 48 * 3600 * 1000),
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    await db.collection('clients').doc(uid).collection('wallet_transactions').add({
      type: 'purchase', amount: totalPrice,
      description: `Achat : ${productName} ×${quantity}`,
      orderId, createdAt: now,
    });
    await db.collection('sellers').doc(sellerId).collection('wallet_transactions').add({
      type: 'sale', amount: totalPrice,
      description: `Vente boutique : ${productName} ×${quantity}`,
      orderId, createdAt: now,
    });

    await logAudit({
      userId: uid, userType: 'client', action: 'pay_boutique_order', targetId: orderId,
      amount: totalPrice, metadata: { productId, quantity, sellerId },
    });

    // Course de livraison — best-effort : un échec ici n'invalide pas
    // l'achat déjà payé (même comportement que le code Dart d'origine, qui
    // enveloppait cette étape dans son propre try/catch silencieux).
    let dispatchResult = null;
    try {
      const deliveryOrderRef = db.collection('orders').doc();
      const lat = typeof deliveryLat === 'number' ? deliveryLat : 0;
      const lng = typeof deliveryLng === 'number' ? deliveryLng : 0;
      await deliveryOrderRef.set({
        description:   `🛍️ Boutique AZ : ${productName} ×${quantity}`,
        budget:         BOUTIQUE_DELIVERY_FEE,
        shoppingBudget: 0,
        status:         'pending',
        latitude:       lat,
        longitude:      lng,
        type:           'boutique',
        clientId:       uid,
        sellerId,
        sellerName,
        sellerType:     'boutique',
        paymentMethod:  'wallet',
        linkedBoutiqueOrderId: orderId,
        isPaid:         false,
        createdAt:      admin.firestore.FieldValue.serverTimestamp(),
      });
      dispatchResult = await dispatchOrder(db, admin, {
        orderId: deliveryOrderRef.id, lat, lng, budget: BOUTIQUE_DELIVERY_FEE,
      });
    } catch (err) {
      console.error('payBoutiqueOrderCF: création/dispatch de la course a échoué (achat déjà validé):', err.message);
    }

    return { orderId, totalPrice, dispatched: dispatchResult?.dispatched || false };
  });
}

module.exports = {
  buildPayOrderFromWallet,
  buildCancelOrder,
  buildDeliverOrder,
  buildPayBoutiqueOrder,
  partnerCollection,
  AZ_COMMISSION_FIXED,
};
