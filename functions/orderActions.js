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

// sellerType déjà payés intégralement (0% commission) à la création de la
// commande, par leur propre Cloud Function atomique — voir buildDeliverOrder.
const PREPAID_PARTNER_TYPES = new Set(['seller', 'boutique']);

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
    let sellerDebit = 0, sellerId = null, sellerCol = null;

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
      // 'boutique' : ce document `orders` ne représente que le trajet de
      // livraison (budget = frais fixe, isPaid TOUJOURS false, voir
      // buildPayBoutiqueOrder) — rien n'a jamais été prélevé au client sur CE
      // document précis (le vrai paiement, totalPrice, vit sur
      // `boutique_orders` via `linkedBoutiqueOrderId`, remboursé séparément
      // par buildRefundExpiredBoutiqueOrder). Le rembourser ici créerait de
      // l'argent à partir de rien pour un montant jamais payé — confirmé et
      // corrigé (Master Prompt 48 bis), après l'avoir laissé en trouvaille
      // documentée seule au Prompt 47.
      const needsClientRefund = order.paymentMethod === 'wallet' && order.type !== 'boutique';
      const needsDriverRefund = ['accepted', 'picked_up'].includes(order.status) && !!order.driverId;
      // Marketplace ('seller') est crédité en entier à la CRÉATION de la
      // commande (voir PREPAID_PARTNER_TYPES, Master Prompt 46) — s'il
      // gardait cet argent après un remboursement client, l'annulation
      // créerait de l'argent à partir de rien (client remboursé + vendeur
      // déjà payé). Il faut donc le débiter en retour ici, symétrique au
      // remboursement de commission du livreur ci-dessous (Master Prompt 47).
      // Volontairement limité à 'seller' — 'boutique' n'atteint plus jamais
      // needsClientRefund ci-dessus, donc jamais ce débit non plus.
      const orderSellerId = order.sellerId || null;
      const needsSellerDebit = needsClientRefund && !!orderSellerId &&
        order.sellerType === 'seller';
      if (needsSellerDebit) {
        sellerId  = orderSellerId;
        sellerCol = partnerCollection(order.sellerType || 'seller');
      }

      const clientRef = db.collection('clients').doc(uid);
      const driverRef = needsDriverRefund ? db.collection('livreurs').doc(order.driverId) : null;
      const sellerRef = needsSellerDebit ? db.collection(sellerCol).doc(sellerId) : null;

      const clientSnap = needsClientRefund ? await tx.get(clientRef) : null;
      const driverSnap = needsDriverRefund ? await tx.get(driverRef) : null;
      const sellerSnap = needsSellerDebit   ? await tx.get(sellerRef) : null;

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

      if (needsSellerDebit && sellerSnap.exists) {
        const w = Number(sellerSnap.data().wallet || 0);
        // Plafonné à 0 : si le vendeur a déjà retiré une partie de ce crédit
        // avant l'annulation, on reprend ce qu'il reste plutôt que de créer
        // un solde négatif — le client est de toute façon remboursé en
        // entier ci-dessus, cette reprise ne fait qu'atténuer la perte.
        sellerDebit = Math.min(budget, w);
        if (sellerDebit > 0) {
          tx.update(sellerRef, { wallet: w - sellerDebit });
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
    if (sellerId && sellerCol && sellerDebit > 0) {
      await db.collection(sellerCol).doc(sellerId).collection('wallet_transactions').add({
        type: 'debit', amount: sellerDebit,
        description: 'Commande annulée par le client — reprise du paiement',
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'client', action: 'cancel_order', targetId: orderId,
      metadata: { clientRefund, driverRefund, driverId, sellerDebit, sellerId },
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

      // Marketplace ('seller') et Boutique ('boutique') sont déjà payés
      // intégralement au vendeur à la création de la commande (0% commission
      // par design — create_marketplace_order/payBoutiqueOrderCF créditent le
      // vendeur immédiatement, via Admin SDK). Les recréditer ici en plus
      // paierait le vendeur deux fois pour la même commande, la seconde fois
      // avec une commission de 100 FCFA que ces deux types ne devraient
      // jamais subir — double-crédit confirmé et corrigé (Master Prompt 46).
      const isPrepaidPartner = PREPAID_PARTNER_TYPES.has(sType);

      const driverSnap = await tx.get(driverRef);

      let partnerRef = null, partnerSnap = null;
      if (payMethod === 'wallet' && sid && !isPrepaidPartner) {
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
        if (sid && isPrepaidPartner) {
          // Déjà crédité en entier à la création — rien à faire ici, juste
          // libérer le livreur.
          walletTarget = 'partner_prepaid';
          tx.update(driverRef, { isOnDelivery: false });
        } else if (sid) {
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

// Remplace boutique_page.dart:_processRefund() — remboursement automatique
// (48h sans livraison) d'une commande boutique. L'original créditait
// directement le wallet du client depuis une transaction Firestore
// lancée par le client lui-même (`tx.update(clientRef, {wallet: wallet +
// amount})`) — mais la règle `clients/{id}` n'autorise une mise à jour du
// champ `wallet` par son propriétaire que si la nouvelle valeur est
// STRICTEMENT INFÉRIEURE à l'ancienne (un client peut diminuer son propre
// solde, jamais l'augmenter, même pour lui-même) ; de plus
// `boutique_orders/{id}` n'autorise `allow update: if isAdmin();` — aucune
// des deux écritures de cette transaction ne pouvait donc réussir. Le
// remboursement automatique 48h n'a donc jamais fonctionné en production,
// et l'échec était avalé silencieusement par le try/catch de
// `_checkAutoRefunds()` (Master Prompt 48 bis). Même en admettant que
// l'écriture ait réussi, elle ne débitait jamais le vendeur (déjà crédité
// en entier à l'achat) — un vrai remboursement doit le reprendre,
// symétrique au correctif Marketplace (Master Prompt 47/PREPAID_PARTNER_TYPES).
// Le délai de 48h est revalidé côté serveur (jamais fait confiance à
// l'appelant) pour empêcher un remboursement instantané frauduleux.
function buildRefundExpiredBoutiqueOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { orderId } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'refund_boutique_order', 10, 60);

    const orderRef = db.collection('boutique_orders').doc(String(orderId));
    let amount = 0, sellerId = null, sellerDebit = 0;

    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.clientId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande n'est pas la vôtre");
      }
      if (order.status !== 'paid') {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut plus être remboursée automatiquement');
      }
      const deadline = order.deliveryDeadline;
      if (!deadline || deadline.toMillis() > Date.now()) {
        throw new HttpsError('failed-precondition', "Le délai de 48h n'est pas encore dépassé");
      }

      amount   = Number(order.totalPrice || 0);
      sellerId = order.sellerId || null;

      const clientRef = db.collection('clients').doc(uid);
      const sellerRef = sellerId ? db.collection('sellers').doc(sellerId) : null;

      const clientSnap = await tx.get(clientRef);
      const sellerSnap = sellerRef ? await tx.get(sellerRef) : null;

      tx.update(orderRef, {
        status:       'refunded',
        refundedAt:   admin.firestore.FieldValue.serverTimestamp(),
        refundReason: 'Non livré dans les 48h',
      });

      if (amount > 0) {
        const clientWallet = Number(clientSnap.data()?.wallet || 0);
        tx.update(clientRef, { wallet: clientWallet + amount });

        if (sellerRef && sellerSnap && sellerSnap.exists) {
          const sellerWallet = Number(sellerSnap.data().wallet || 0);
          // Plafonné à 0 : si le vendeur a déjà retiré une partie de ce
          // crédit, on reprend ce qu'il reste plutôt que de créer un solde
          // négatif (même logique que cancelOrderCF, Master Prompt 48).
          sellerDebit = Math.min(amount, sellerWallet);
          if (sellerDebit > 0) {
            tx.update(sellerRef, { wallet: sellerWallet - sellerDebit });
          }
        }
      }
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    if (amount > 0) {
      await db.collection('clients').doc(uid).collection('wallet_transactions').add({
        type: 'refund', amount,
        description: 'Remboursement automatique — commande boutique non livrée (48h)',
        orderId, createdAt: now,
      });
    }
    if (sellerId && sellerDebit > 0) {
      await db.collection('sellers').doc(sellerId).collection('wallet_transactions').add({
        type: 'debit', amount: sellerDebit,
        description: 'Commande boutique non livrée (48h) — reprise du paiement',
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'client', action: 'refund_boutique_order', targetId: orderId,
      amount, metadata: { sellerId, sellerDebit },
    });

    return { success: true, amount };
  });
}

module.exports = {
  buildPayOrderFromWallet,
  buildCancelOrder,
  buildDeliverOrder,
  buildPayBoutiqueOrder,
  buildRefundExpiredBoutiqueOrder,
  partnerCollection,
  AZ_COMMISSION_FIXED,
  PREPAID_PARTNER_TYPES,
};
