'use strict';

const { resolveDispatchGeography, calculateCommission: tieredCommission } = require('./dispatch');
const { readDriverState, terminalDriverPatch, runLifecycleTransaction } = require('./driverLifecycle');
const { verifyProofInTransaction, getProofRefs } = require('./deliveryProofs');
const { settlementDocument } = require('./earningsSettlement');
const { buildAmounts, readAmounts, cashBreakdown } = require('./orderAmounts');
const { getBillingMode, decideBilling, assertAcceptedTotal } = require('./billingPolicy');
const { isLegacyPartnerOrder, getLegacyPartnerPolicy } = require('./legacyPartnerPolicy');

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
    let driverHeld = false;
    let orderForSettlement = null;

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
      const pharmRef  = (pharmacieId && medAmount > 0)
        ? db.collection('pharmacies').doc(pharmacieId) : null;

      // Toutes les lectures d'abord — Firestore exige qu'aucune écriture
      // (tx.update ci-dessous) ne précède une lecture dans une même
      // transaction. Bug réel trouvé le 2026-07-19 (audit Wallet) :
      // `tx.get(pharmRef)` était exécuté après deux `tx.update()` déjà
      // faits, levant "Firestore transactions require all reads to be
      // executed before all writes" — cassait à 100% toute commande
      // pharmacie avec un montant médicament non nul payée par wallet.
      const clientSnap = await tx.get(clientRef);
      const driverSnap = await tx.get(driverRef);
      const pharmSnap  = pharmRef ? await tx.get(pharmRef) : null;

      const clientWallet = Number(clientSnap.data()?.wallet || 0);
      if (clientWallet < total) {
        // Format conservé pour compatibilité avec le parsing existant côté
        // Flutter (suivi_commande.dart cherche la sous-chaîne SOLDE_INSUFFISANT).
        throw new HttpsError('failed-precondition', `SOLDE_INSUFFISANT:${clientWallet}:${total}`);
      }
      tx.update(clientRef, { wallet: clientWallet - total });

      // Course transférée entre livreurs : la part livreur est retenue (partage
      // non réglé) — le client est bien débité, aucun livreur n'est crédité.
      driverHeld = order.settlementHold === true;
      orderForSettlement = order.status === 'delivered' ? order : null;
      if (!driverHeld) {
        const driverWallet = Number(driverSnap.data()?.wallet || 0);
        tx.update(driverRef, { wallet: driverWallet + deliveryAmount });
      }

      if (pharmRef) {
        const pharmWallet = Number(pharmSnap.data()?.wallet || 0);
        tx.update(pharmRef, { wallet: pharmWallet + medAmount });
      }

      tx.update(orderRef, {
        isPaid: true,
        paymentMethod: 'wallet',
        ...(medAmount > 0 ? { medicineAmount: medAmount } : {}),
        ...(driverHeld ? { heldDriverEarning: deliveryAmount, settlementStatus: 'pending_admin_review' } : {}),
      });
      // Livraison déjà effectuée (paiement différé, ex. pharmacie) : le règlement
      // administratif est ouvert maintenant que le client a réellement payé.
      if (driverHeld && orderForSettlement) {
        const nowMs = Date.now();
        tx.set(db.collection('transfer_settlements').doc(String(orderId)), settlementDocument(
          String(orderId), { ...orderForSettlement, budget: deliveryAmount }, 'wallet', nowMs));
      }
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    await db.collection('clients').doc(uid).collection('wallet_transactions').add({
      type: 'payment', amount: total,
      description: `Paiement commande — livraison ${deliveryAmount} FCFA` +
        (medAmount > 0 ? ` + médicaments ${medAmount} FCFA` : ''),
      orderId, createdAt: now,
    });
    if (!driverHeld) {
      await db.collection('livreurs').doc(driverId).collection('wallet_transactions').add({
        type: 'earning', amount: deliveryAmount,
        description: 'Paiement client (wallet) — livraison',
        orderId, createdAt: now,
      });
    }
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

// Cœur transactionnel de l'annulation d'une commande — source unique de
// vérité (Master Prompt 52), appelée à la fois par cancelOrderCF (le client
// annule depuis l'app) et par l'outil AZ IA cancel_order
// (functions/azia/tools/delivery.js), pour qu'une annulation produise
// exactement le même résultat quel que soit le chemin. Doit être appelée
// DANS une transaction déjà ouverte par l'appelant (qui a déjà vérifié la
// propriété de la commande) ; ne fait aucune écriture hors tx — les logs
// `wallet_transactions` post-commit sont dans cancelOrderPostTx ci-dessous.
// Lève une Error('ORDER_NOT_CANCELLABLE') si le statut ne le permet plus —
// à l'appelant de la traduire dans son propre type d'erreur (HttpsError
// côté onCall, message renvoyé à l'utilisateur côté AZ IA). `reason` identifie
// le déclencheur pour l'audit/le support (ex. 'client_cancel', 'ai_client_cancel')
// — même champ que celui déjà écrit par autoExpireOrders ('no_driver_found'),
// désormais cohérent sur les 3 chemins d'annulation.
async function cancelOrderTx(tx, { db, admin, orderRef, order, uid, calculateCommission, reason, adminDecision }) {
  if (['delivered', 'cancelled'].includes(order.status)) {
    throw new Error('ORDER_NOT_CANCELLABLE');
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
  // isPaid === false explicite : commande wallet réglée APRÈS livraison (ex.
  // pharmacie) et jamais payée — rien n'a été débité, rien à rembourser (sinon
  // l'annulation créerait de l'argent). Champ absent (anciennes commandes) :
  // comportement historique inchangé.
  const needsClientRefund = order.paymentMethod === 'wallet' && order.type !== 'boutique' &&
    order.isPaid !== false;
  // Commande à montants explicites (Marketplace / Boutique). Règle commerciale :
  //  - avant récupération : aucune prestation réalisée, remboursement intégral ;
  //  - après récupération : les frais de livraison ne sont PAS remboursés
  //    automatiquement. Ils restent en attente d'examen administratif
  //    (deliveryFeeHold) : faute du livreur ou d'AZ → remboursement possible, sinon
  //    rémunération du livreur. Aucun paiement fictif : c'est l'argent déjà payé
  //    par le client, simplement non redistribué tant que la décision manque.
  const amounts = readAmounts(order);
  const pickedUp = order.status === 'picked_up' || order.pickedUpAt != null;
  const adminRefundsFee = adminDecision && adminDecision.refundFee === true;
  const feeNotRefundable = !!amounts && pickedUp && !adminRefundsFee;

  // Boutique wallet : le paiement réel vit sur `boutique_orders` (document lié).
  const boutiqueFlow = order.type === 'boutique' && !!amounts && order.deliveryFeePaid === true &&
    order.paymentMethod === 'wallet' && typeof order.linkedBoutiqueOrderId === 'string' &&
    order.linkedBoutiqueOrderId && !order.linkedBoutiqueOrderId.includes('/') && !!order.sellerId;
  const boRef = boutiqueFlow ? db.collection('boutique_orders').doc(order.linkedBoutiqueOrderId) : null;
  const boSnap = boRef ? await tx.get(boRef) : null;
  const boutiqueRefund = !!boSnap && boSnap.exists && boSnap.data().status === 'paid' &&
    boSnap.data().clientId === uid;

  const marketplaceHold = feeNotRefundable && order.paymentMethod === 'wallet' &&
    order.type !== 'boutique' && order.isPaid !== false;
  const holdFee = marketplaceHold || (feeNotRefundable && boutiqueRefund);
  const needsDriverRefund = ['accepted', 'picked_up'].includes(order.status) && !!order.driverId
    && order.commissionStatus !== 'refunded' && !holdFee;
  // Marketplace ('seller') est crédité en entier à la CRÉATION de la
  // commande (voir PREPAID_PARTNER_TYPES, Master Prompt 46) — s'il gardait
  // cet argent après un remboursement client, l'annulation créerait de
  // l'argent à partir de rien (client remboursé + vendeur déjà payé). Il
  // faut donc le débiter en retour ici, symétrique au remboursement de
  // commission du livreur ci-dessous (Master Prompt 47). Volontairement
  // limité à 'seller' — 'boutique' n'atteint plus jamais needsClientRefund
  // ci-dessus, donc jamais ce débit non plus.
  const orderSellerId = order.sellerId || null;
  const needsSellerDebit = (needsClientRefund && !!orderSellerId &&
    order.sellerType === 'seller') || boutiqueRefund;

  let sellerId = null, sellerCol = null;
  if (needsSellerDebit) {
    sellerId  = orderSellerId;
    sellerCol = boutiqueRefund ? 'sellers' : partnerCollection(order.sellerType || 'seller');
  }

  const clientRef = db.collection('clients').doc(uid);
  const driverRef = order.driverId ? db.collection('livreurs').doc(order.driverId) : null;
  const sellerRef = needsSellerDebit ? db.collection(sellerCol).doc(sellerId) : null;

  const clientSnap = (needsClientRefund || boutiqueRefund) ? await tx.get(clientRef) : null;
  const driverState = driverRef ? await readDriverState(tx, db, order.driverId, orderRef.id) : null;
  const driverSnap = driverState ? { exists: driverState.exists, data: () => driverState.data } : null;
  const sellerSnap = needsSellerDebit   ? await tx.get(sellerRef) : null;

  // Commission tracée à l'acceptation (acceptOrderCF) : le remboursement vise le
  // PAYEUR d'origine, avec le montant réellement prélevé — jamais le livreur
  // courant par hypothèse (après un transfert ce ne sont plus les mêmes) ni un
  // recalcul avec une configuration qui a pu changer. Anciennes commandes (sans
  // ces champs) : comportement historique inchangé.
  const tracedCommission = order.commissionStatus === 'charged' &&
    typeof order.commissionPayerId === 'string' && order.commissionPayerId &&
    !order.commissionPayerId.includes('/') &&
    Number.isSafeInteger(order.commissionAmount) && order.commissionAmount >= 0;
  const payerId = tracedCommission ? order.commissionPayerId : order.driverId;
  const payerRef = payerId && payerId !== order.driverId
    ? db.collection('livreurs').doc(payerId) : driverRef;
  const payerSnap = payerRef && payerRef !== driverRef && needsDriverRefund
    ? await tx.get(payerRef) : driverSnap;

  // Transfert entre livreurs en cours (demande ou remplaçant réservé) : l'annulation
  // le clôt dans la MÊME transaction — le remplaçant B est libéré tout de suite,
  // le transfert est annulé (historique conservé) et la preuve de remise est
  // révoquée. Toutes les lectures précèdent les écritures.
  let transferClose = null;
  const activeId = order.activeTransferId;
  if (typeof activeId === 'string' && activeId && !activeId.includes('/')) {
    const tRef = db.collection('delivery_transfers').doc(activeId);
    const tSnap = await tx.get(tRef);
    if (tSnap.exists && ['requested', 'accepted'].includes(tSnap.data().status)) {
      const t = tSnap.data();
      const reserved = t.status === 'accepted' && typeof t.toDriverId === 'string' &&
        t.toDriverId && !t.toDriverId.includes('/')
        ? await readDriverState(tx, db, t.toDriverId, orderRef.id) : null;
      const { sessionRef } = getProofRefs(db, orderRef.id, 'handover');
      const sessSnap = await tx.get(sessionRef);
      let proofRef = null;
      if (sessSnap.exists && sessSnap.data().currentProofId) {
        const ref = getProofRefs(db, orderRef.id, 'handover', sessSnap.data().currentProofId).proofRef;
        const pSnap = await tx.get(ref);
        if (pSnap.exists && pSnap.data().status === 'active') proofRef = ref;
      }
      transferClose = { tRef, reserved, proofRef };
    }
  }

  if (driverState) {
    const patch = terminalDriverPatch(driverState, orderRef.id, admin);
    if (Object.keys(patch).length) tx.update(driverRef, patch);
  }

  if (transferClose) {
    const nowMs = Date.now();
    tx.update(transferClose.tRef, { status: 'cancelled', closedAtMs: nowMs, closeReason: 'order_cancelled' });
    if (transferClose.reserved) {
      const bPatch = terminalDriverPatch(transferClose.reserved, orderRef.id, admin);
      if (Object.keys(bPatch).length) tx.update(transferClose.reserved.ref, bPatch);
    }
    if (transferClose.proofRef) {
      const stamp = admin.firestore.Timestamp.fromMillis(nowMs);
      tx.update(transferClose.proofRef, { status: 'revoked', revokedAt: stamp, updatedAt: stamp });
    }
  }

  tx.update(orderRef, {
    status: 'cancelled',
    ...(transferClose ? { activeTransferId: admin.firestore.FieldValue.delete() } : {}),
    ...(reason ? { cancelReason: reason, cancelledAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
  });

  let clientRefund = 0, driverId = null, driverRefund = 0, sellerDebit = 0;

  // Commande à montants explicites (Marketplace) : le client a payé produits +
  // livraison, le vendeur n'a reçu que les produits, le livreur n'a rien reçu
  // tant que la livraison n'est pas terminée (statut 'delivered' non annulable).
  // Politique appliquée = remboursement intégral de ce qui a été payé (comme
  // avant pour le marketplace) ; le remboursement des frais après récupération
  // du colis est une décision métier à confirmer (voir rapport).
  if (boutiqueRefund) {
    // Produits toujours rendus ; frais rendus seulement avant récupération
    // (ou sur décision administrative).
    clientRefund = amounts.productAmount + (feeNotRefundable ? 0 : amounts.deliveryFee);
    if (clientSnap.exists) {
      tx.update(clientRef, { wallet: Number(clientSnap.data().wallet || 0) + clientRefund });
    }
    tx.update(boRef, {
      status: 'refunded',
      refundedAt: admin.firestore.FieldValue.serverTimestamp(),
      refundReason: adminRefundsFee ? 'admin_cancel_fee_refunded' : (pickedUp ? 'cancelled_after_pickup' : 'cancelled_before_pickup'),
      feeRefunded: !feeNotRefundable,
    });
  } else if (needsClientRefund) {
    clientRefund = (amounts
      ? (feeNotRefundable ? amounts.productAmount : amounts.totalAmount)
      : budget) + shoppingBudget;
    if (clientRefund > 0 && clientSnap.exists) {
      const w = Number(clientSnap.data().wallet || 0);
      tx.update(clientRef, { wallet: w + clientRefund });
    }
  }

  if (needsDriverRefund) {
    driverId     = payerId;
    driverRefund = tracedCommission
      ? order.commissionAmount
      : await calculateCommission(db, budget);
    if (payerSnap && payerSnap.exists) {
      const w = Number(payerSnap.data().wallet || 0);
      tx.update(payerRef, { wallet: w + driverRefund });
    }
    if (tracedCommission) {
      tx.update(orderRef, { commissionStatus: 'refunded' });
    }
  }

  if (needsSellerDebit && sellerSnap.exists) {
    const w = Number(sellerSnap.data().wallet || 0);
    // Plafonné à 0 : si le vendeur a déjà retiré une partie de ce crédit
    // avant l'annulation, on reprend ce qu'il reste plutôt que de créer un
    // solde négatif — le client est de toute façon remboursé en entier
    // ci-dessus, cette reprise ne fait qu'atténuer la perte (Master Prompt 48).
    sellerDebit = Math.min(amounts ? amounts.productAmount : budget, w);
    if (sellerDebit > 0) {
      tx.update(sellerRef, { wallet: w - sellerDebit });
    }
  }

  if (holdFee) {
    tx.update(orderRef, {
      deliveryFeeHold: {
        amount: amounts.deliveryFee, status: 'pending_admin_review',
        reason: 'cancelled_after_pickup', cancelledStatus: order.status,
        driverId: order.driverId || null, createdAtMs: Date.now(),
      },
    });
  }

  return { clientRefund, driverId, driverRefund, sellerId, sellerCol, sellerDebit, feeHeld: holdFee ? amounts.deliveryFee : 0 };
}

// Journalisation post-transaction (wallet_transactions) — à appeler une fois
// que la transaction de cancelOrderTx a été validée avec succès.
async function cancelOrderPostTx(db, admin, { orderId, uid, clientRefund, driverId, driverRefund, sellerId, sellerCol, sellerDebit }) {
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
}

// Remplace FirestoreService.cancelOrder() : annulation par le client
// propriétaire de la commande, avec remboursement wallet client (si payée en
// wallet) et remboursement de la commission au livreur (si la commande avait
// déjà été acceptée/récupérée). Wrapper onCall autour de cancelOrderTx —
// gère auth/rate-limit/permission puis délègue toute la logique métier.
function buildCancelOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { orderId } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'cancel_order', 20, 60);

    const orderRef = db.collection('orders').doc(String(orderId));
    let refundInfo;

    await runLifecycleTransaction(db, async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.clientId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande n'est pas la vôtre");
      }

      try {
        refundInfo = await cancelOrderTx(tx, { db, admin, orderRef, order, uid, calculateCommission, reason: 'client_cancel' });
      } catch (err) {
        if (err.message === 'ORDER_NOT_CANCELLABLE') {
          throw new HttpsError('failed-precondition', 'Cette commande ne peut plus être annulée');
        }
        throw err;
      }
    });

    await cancelOrderPostTx(db, admin, { orderId, uid, ...refundInfo });

    await logAudit({
      userId: uid, userType: 'client', action: 'cancel_order', targetId: orderId,
      metadata: refundInfo,
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
function buildDeliverOrder({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  requireProof = false, deliveryProofPepper,
}) {
  const options = deliveryProofPepper ? { secrets: [deliveryProofPepper] } : {};
  return onCall(options, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const {
      orderId, markCashPaid, deliveredLat, deliveredLng, deliveryPhotoUrl,
      proofToken, proofPin,
    } = request.data || {};
    if (!orderId) throw new HttpsError('invalid-argument', 'orderId manquant');

    await checkRateLimit(uid, 'deliver_order', 30, 60);

    const orderRef  = db.collection('orders').doc(String(orderId));
    const driverRef = db.collection('livreurs').doc(uid);

    let walletTarget = null, partnerId = null, partnerCol = null;
    let creditAmount = 0, deliveryFee = 0, payMethod = '';
    let proofFailure = null;
    let proofValidated = false;
    let held = false;
    let commissionInfo = null;
    let neutralized = null; // commission rendue : course historique sans rémunération

    await runLifecycleTransaction(db, async (tx) => {
      neutralized = null;
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.driverId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande ne vous est pas assignée");
      }
      if (requireProof && order.deliveryProofMode === 'qr_v1' && order.status === 'delivered') {
        throw new HttpsError('failed-precondition', 'Code déjà utilisé');
      }
      if (!['accepted', 'picked_up'].includes(order.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut pas être marquée livrée');
      }
      if (order.deliveryProofMode === 'qr_v1' && !requireProof) {
        throw new HttpsError('failed-precondition', 'Une preuve de réception est requise');
      }
      if (requireProof && order.deliveryProofMode !== 'qr_v1') {
        throw new HttpsError('failed-precondition', 'Cette commande utilise le parcours de livraison classique');
      }
      if (requireProof && order.status !== 'picked_up') {
        throw new HttpsError('failed-precondition', 'La récupération doit être confirmée avant la remise');
      }

      const linkedBoutiqueOrderId = order.linkedBoutiqueOrderId || null;
      const boutiqueOrderRef = linkedBoutiqueOrderId
        ? db.collection('boutique_orders').doc(String(linkedBoutiqueOrderId))
        : null;
      const boutiqueOrderSnap = boutiqueOrderRef ? await tx.get(boutiqueOrderRef) : null;
      const boutiqueOrder = boutiqueOrderSnap?.exists ? boutiqueOrderSnap.data() : null;
      if (boutiqueOrder && ['refunded', 'cancelled'].includes(boutiqueOrder.status)) {
        throw new HttpsError('failed-precondition', 'La commande boutique liée ne peut plus être livrée');
      }

      const sid            = order.sellerId || null;
      const sType          = order.sellerType || 'seller';
      const budget         = Number(order.budget || 0);
      const shoppingBudget = Number(order.shoppingBudget || 0);
      deliveryFee = budget;
      payMethod   = order.paymentMethod || '';
      // Course transférée après récupération : le partage des gains entre
      // livreurs n'est pas encore réglé (décision métier + distance validée).
      // La part livreur n'est donc JAMAIS créditée ici — ni à B seul, ni à A —
      // elle est mise en attente sur la commande pour validation administrative.
      held = order.settlementHold === true;
      // Commission réellement prélevée à l'acceptation (acceptOrderCF) : c'est
      // elle qui est journalisée, au nom du payeur d'origine.
      commissionInfo = (order.commissionStatus === 'charged' &&
        Number.isSafeInteger(order.commissionAmount) && order.commissionAmount >= 0 &&
        typeof order.commissionPayerId === 'string' && order.commissionPayerId)
        ? { amount: order.commissionAmount, payerId: order.commissionPayerId } : null;

      // Marketplace ('seller') et Boutique ('boutique') sont déjà payés
      // intégralement au vendeur à la création de la commande (0% commission
      // par design — create_marketplace_order/payBoutiqueOrderCF créditent le
      // vendeur immédiatement, via Admin SDK). Les recréditer ici en plus
      // paierait le vendeur deux fois pour la même commande, la seconde fois
      // avec une commission de 100 FCFA que ces deux types ne devraient
      // jamais subir — double-crédit confirmé et corrigé (Master Prompt 46).
      const isPrepaidPartner = PREPAID_PARTNER_TYPES.has(sType);
      // Montants explicites (produits / livraison / total) des nouvelles
      // commandes Marketplace et Boutique ; null = commande historique.
      const amounts = readAmounts(order);

      const driverState = await readDriverState(tx, db, uid, String(orderId));
      const driverSnap = { exists: driverState.exists, data: () => driverState.data };
      const driverPatch = terminalDriverPatch(driverState, String(orderId), admin);

      let partnerRef = null, partnerSnap = null;
      if (payMethod === 'wallet' && sid && !isPrepaidPartner) {
        partnerCol  = partnerCollection(sType);
        partnerRef  = db.collection(partnerCol).doc(sid);
        partnerSnap = await tx.get(partnerRef);
      }

      // Course Marketplace/Boutique historique DÉJÀ acceptée (commission déjà
      // prélevée) : aucun frais de livraison n'a été encaissé, le livreur ne sera
      // pas rémunéré. AZ ne conserve pas une commission sans contrepartie : la
      // commission TRACÉE est rendue à son payeur dans cette même transaction.
      // Commission non tracée (ancienne acceptation directe) : rien n'est rendu
      // automatiquement (on ne peut pas prouver qu'elle a été payée) — signalée
      // pour résolution administrative.
      let neutralize = null;
      if (isLegacyPartnerOrder(order) && commissionInfo && commissionInfo.amount > 0) {
        const payerIsSelf = commissionInfo.payerId === uid;
        const payerRef = payerIsSelf ? driverRef : db.collection('livreurs').doc(commissionInfo.payerId);
        const payerSnap = payerIsSelf ? driverSnap : await tx.get(payerRef);
        neutralize = { amount: commissionInfo.amount, payerId: commissionInfo.payerId, payerIsSelf, payerRef, payerSnap };
      }

      let checkedProof = null;
      if (requireProof) {
        const pepper = process.env.DELIVERY_PROOF_PEPPER;
        if (!pepper) {
          throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
        }
        checkedProof = await verifyProofInTransaction({
          tx, db, orderId: String(orderId), type: 'delivery',
          driverId: uid,
          assignmentVersion: Number(order.driverAssignmentVersion || 1),
          token: proofToken,
          pin: proofPin,
          pepper,
          now: Date.now(),
          admin,
        });
        if (!checkedProof.ok) {
          if (checkedProof.failureUpdate && checkedProof.proofRef) {
            tx.update(checkedProof.proofRef, checkedProof.failureUpdate);
          }
          proofFailure = checkedProof;
          return;
        }
      }

      if (checkedProof) {
        tx.update(checkedProof.proofRef, checkedProof.consumeUpdate);
        tx.update(checkedProof.sessionRef, {
          currentProofId: null,
          completedAt: checkedProof.consumeUpdate.validatedAt,
          updatedAt: checkedProof.consumeUpdate.validatedAt,
        });
        tx.update(orderRef, {
          deliveryProofValidatedAt: checkedProof.consumeUpdate.validatedAt,
          deliveryProofValidatedBy: uid,
        });
        proofValidated = true;
      }

      tx.update(orderRef, {
        status:      'delivered',
        deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(markCashPaid === true ? { isPaid: true } : {}),
        ...(typeof deliveredLat === 'number' ? { deliveredLat } : {}),
        ...(typeof deliveredLng === 'number' ? { deliveredLng } : {}),
        ...(deliveryPhotoUrl ? { deliveryPhoto: deliveryPhotoUrl } : {}),
      });

      // La livraison et la vente Boutique doivent atteindre leur état terminal
      // dans la même transaction. Les documents historiques sans
      // deliveryOrderId restent lisibles ; leur remboursement est protégé par
      // la vérification de la course liée dans buildRefundExpiredBoutiqueOrder.
      if (boutiqueOrder && boutiqueOrder.deliveryOrderId === String(orderId) &&
          !['delivered', 'refunded', 'cancelled'].includes(boutiqueOrder.status)) {
        tx.update(boutiqueOrderRef, {
          status: 'delivered',
          dispatchStatus: 'delivered',
          deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const driverWallet = Number(driverSnap.data()?.wallet || 0);

      if (neutralize) {
        const payerWallet = Number(neutralize.payerSnap?.data()?.wallet || 0);
        if (neutralize.payerSnap?.exists) {
          if (neutralize.payerIsSelf) {
            // Fusionné dans le patch livreur appliqué par la branche ci-dessous.
            driverPatch.wallet = payerWallet + neutralize.amount;
          } else {
            tx.update(neutralize.payerRef, { wallet: payerWallet + neutralize.amount });
          }
          tx.update(orderRef, {
            commissionStatus: 'refunded',
            commissionRefundReason: 'legacy_partner_unremunerated',
          });
          neutralized = { payerId: neutralize.payerId, amount: neutralize.amount };
        }
      } else if (isLegacyPartnerOrder(order) && !commissionInfo) {
        tx.update(orderRef, { legacyBillingReview: { status: 'pending_admin_review', reason: 'commission_untraced' } });
      }

      if (payMethod === 'wallet') {
        if (sid && isPrepaidPartner && amounts && order.deliveryFeePaid === true) {
          // Le vendeur a reçu les produits à la création ; les frais de
          // livraison ont été encaissés auprès du client en même temps et
          // reviennent au livreur ici (sa commission a été prélevée à
          // l'acceptation). Le statut 'delivered' (relu plus haut) empêche tout
          // second crédit. Le vendeur n'est jamais recrédité.
          if (held) {
            // Les transferts sont refusés pour ces commandes ; garde-fou : pas
            // de crédit à un seul livreur sans règlement validé.
            walletTarget = 'partner_prepaid_held';
            tx.update(orderRef, {
              heldDriverEarning: amounts.deliveryFee,
              settlementStatus: 'pending_admin_review',
            });
            if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
          } else {
            walletTarget = 'driver_prepaid_fee';
            creditAmount = amounts.deliveryFee;
            tx.update(driverRef, { wallet: driverWallet + creditAmount, ...driverPatch });
          }
        } else if (sid && isPrepaidPartner) {
          // Commande historique : déjà crédité en entier à la création — rien
          // à faire ici, juste libérer le livreur.
          walletTarget = 'partner_prepaid';
          if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
        } else if (sid && order.isPaid === true) {
          partnerId    = sid;
          walletTarget = 'partner';
          // Le commissionnement AZ passe intégralement par le wallet du
          // livreur, déjà débité à l'acceptation (acceptOrder(), Dart) — le
          // reprélever ici en réduisant le crédit du partenaire aurait fait
          // payer la commission deux fois pour la même commande (double
          // prélèvement confirmé et corrigé, 2026-07-09). Le partenaire
          // reçoit désormais le montant intégral.
          creditAmount = Math.max(0, budget);
          if (partnerSnap && partnerSnap.exists) {
            const w = Number(partnerSnap.data().wallet || 0);
            tx.update(partnerRef, { wallet: w + creditAmount });
          }
          if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
        } else if (sid) {
          // Commande wallet avec marchand, mais isPaid encore false : aucun
          // paiement réel n'a jamais été validé côté serveur pour cette
          // commande (order.paymentMethod est un champ librement écrit par
          // le client à la création, non lié à un vrai débit) — créditer ici
          // aurait permis de créer de l'argent sans qu'aucun client n'ait
          // jamais payé (faille confirmée et corrigée, Master Prompt 80,
          // 2026-07-09). Le marchand n'est crédité que si isPaid est déjà
          // passé à true via un chemin serveur validé (payOrderFromWalletCF).
          walletTarget = 'partner_unpaid';
          if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
        } else if (order.isPaid === true && held) {
          // Gain livreur retenu : aucun crédit fictif, aucun crédit au seul livreur final.
          walletTarget = 'driver_held';
          tx.update(orderRef, {
            heldDriverEarning: Math.max(0, budget + shoppingBudget),
            settlementStatus: 'pending_admin_review',
          });
          if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
        } else if (order.isPaid === true) {
          walletTarget = 'driver';
          // Même raisonnement que ci-dessus : la commission a déjà été
          // débitée du wallet livreur à l'acceptation — le crédit ici est
          // désormais intégral (2026-07-09).
          creditAmount = Math.max(0, budget + shoppingBudget);
          tx.update(driverRef, {
            wallet:       driverWallet + creditAmount,
            ...driverPatch,
          });
        } else {
          // Commande wallet dont le paiement final (livraison + éventuel
          // montant additionnel, ex. médicaments pharmacie) n'a pas encore
          // été réglé — le libeller "isPaid" reste false jusqu'au règlement
          // post-livraison (suivi_commande.dart:_WalletPayButton →
          // payOrderFromWalletCF, qui crédite le livreur du montant complet
          // en une seule fois). Créditer le livreur ici en plus créerait un
          // double crédit — confirmé et corrigé (2026-07-09), même famille
          // que les doubles-crédits Marketplace/Boutique du Master Prompt 46.
          walletTarget = 'driver_pending_payment';
          if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);
        }
      } else {
        // Paiement cash : le client règle le livreur directement, en
        // espèces, à la livraison — cet argent ne transite jamais par AZ.
        // La commission AZ a déjà été débitée du wallet livreur à
        // l'acceptation (acceptOrder(), Dart, remboursable en cas
        // d'annulation) ; la reprélever ici doublait la commission sur
        // chaque commande cash (confirmé et corrigé, 2026-07-09) — le
        // livreur garde désormais l'intégralité des espèces collectées,
        // son wallet n'est plus touché à la livraison.
        walletTarget = 'cash';
        if (Object.keys(driverPatch).length) tx.update(driverRef, driverPatch);

        // Commande cash avec un marchand (restaurant/pharmacie) : le livreur
        // collecte aussi la part "produit" en espèces, qu'il doit remettre au
        // marchand séparément — aucun mouvement de wallet n'a lieu ici (par
        // design, voir ci-dessus), donc rien ne trace aujourd'hui si cette
        // remise a bien eu lieu. Ajout purement additif, jamais lu par aucune
        // logique de paiement existante : marque la commande comme "cash à
        // régler" pour la nouvelle vue admin dédiée (2026-07-09), sans toucher
        // au wallet. Boutique exclue : son paiement cash suit déjà son propre
        // document `boutique_orders`, traité séparément (voir admin_boutique_page.dart).
        if (sid && sType !== 'boutique') {
          tx.update(orderRef, { merchantCashSettled: false });
        }
        // Commandes à montants explicites : le client règle le total en
        // espèces, le livreur reverse les produits au vendeur et garde les
        // frais. Détail tracé séparément (aucun mouvement de wallet ici).
        if (amounts) {
          tx.update(orderRef, {
            cashBreakdown: cashBreakdown(amounts, commissionInfo ? commissionInfo.amount : undefined),
          });
        }
      }

      // Course transférée : la part de chaque livreur est proposée au règlement
      // administratif (distance utile validée) — rien n'est crédité ici.
      if (held && (walletTarget === 'driver_held' || walletTarget === 'cash')) {
        const nowMs = Date.now();
        tx.set(db.collection('transfer_settlements').doc(String(orderId)), settlementDocument(
          String(orderId),
          { ...order, deliveryPhoto: deliveryPhotoUrl || null,
            deliveryProofValidatedAt: proofValidated ? nowMs : null },
          walletTarget === 'cash' ? 'cash' : 'wallet', nowMs));
        tx.update(orderRef, { settlementStatus: 'pending_admin_review' });
      }
    });

    if (proofFailure) {
      await logAudit({
        userId: uid,
        userType: 'driver',
        action: 'delivery_proof_validation',
        targetId: String(orderId),
        status: 'error',
        metadata: { proofType: 'delivery', errorCode: proofFailure.code },
      });
      throw new HttpsError(proofFailure.code, proofFailure.message);
    }

    // Commission journalisée = celle RÉELLEMENT prélevée à l'acceptation (tracée par
    // acceptOrderCF). Courses acceptées avant le suivi serveur (aucune trace) : le
    // barème à paliers 100/200 appliqué à l'ancienne acceptation Dart, jamais une
    // valeur fixe. Aucun prélèvement ici : cette valeur ne sert qu'au journal.
    const loggedCommission = neutralized
      ? 0 // rendue au livreur : aucune commission conservée par AZ
      : commissionInfo
        ? commissionInfo.amount
        : Math.max(0, Math.floor(Number(await tieredCommission(db, Number(deliveryFee || 0)))));

    // Hors transaction : compteurs + journaux (même comportement que côté Dart)
    await driverRef.update({ deliveries: admin.firestore.FieldValue.increment(1) });

    await db.collection('config').doc('az_wallet').set({
      totalCommissions: admin.firestore.FieldValue.increment(loggedCommission),
      totalDeliveries:  admin.firestore.FieldValue.increment(1),
      updatedAt:        admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    let driverName = '';
    try {
      const snap = await driverRef.get();
      driverName = snap.data()?.name || '';
    } catch (_) { /* non-bloquant */ }

    await db.collection('commissions').add({
      orderId, driverId: commissionInfo ? commissionInfo.payerId : uid, driverName,
      amount:        loggedCommission,
      commissionSource: neutralized ? 'refunded_legacy_partner' : (commissionInfo ? 'traced' : 'legacy_tiered'),
      deliveryFee,
      // Course transférée : gain à répartir, jamais attribué ici.
      driverGain:    held ? null : deliveryFee - loggedCommission,
      ...(held ? { settlementStatus: 'pending_admin_review', deliveredBy: uid } : {}),
      paymentMethod: payMethod,
      createdAt:     admin.firestore.FieldValue.serverTimestamp(),
    });

    // walletTarget === 'cash' n'écrit plus de wallet_transactions ici : plus
    // aucune mutation de wallet livreur n'a lieu à la livraison pour ce cas
    // (commission déjà journalisée à l'acceptation, côté Dart) — en écrire
    // une quand même aurait laissé une entrée fantôme sans mouvement de
    // solde réel correspondant, faussant l'historique et la conciliation
    // hebdomadaire (2026-07-09).
    const now = admin.firestore.FieldValue.serverTimestamp();
    if (neutralized) {
      await db.collection('livreurs').doc(neutralized.payerId).collection('wallet_transactions').add({
        type: 'refund', amount: neutralized.amount,
        description: 'Commission rendue — commande Marketplace/Boutique sans frais de livraison encaissés',
        orderId, createdAt: now,
      });
    }
    if ((walletTarget === 'driver' || walletTarget === 'driver_prepaid_fee') && creditAmount > 0) {
      await driverRef.collection('wallet_transactions').add({
        type: 'earning', amount: creditAmount,
        description: `Gain livraison — ${deliveryFee} FCFA (commission AZ déjà prélevée à l'acceptation)`,
        orderId, createdAt: now,
      });
    } else if (walletTarget === 'partner' && partnerId && partnerCol && creditAmount > 0) {
      await db.collection(partnerCol).doc(partnerId).collection('wallet_transactions').add({
        type: 'earning', amount: creditAmount,
        description: `Commande livrée — ${creditAmount} FCFA (commission AZ prélevée séparément sur le wallet du livreur)`,
        orderId, createdAt: now,
      });
    }

    await logAudit({
      userId: uid, userType: 'driver', action: 'deliver_order', targetId: orderId,
      amount: creditAmount || null,
      metadata: { walletTarget, deliveryFee, payMethod, proofValidated, settlementHold: held },
    });

    if (proofValidated) {
      await logAudit({
        userId: uid, userType: 'driver', action: 'delivery_proof_validation',
        targetId: String(orderId), status: 'success',
        metadata: { proofType: 'delivery' },
      });
    }

    return { success: true };
  });
}

function buildDeliverOrderWithProof(options) {
  return buildDeliverOrder({ ...options, requireProof: true });
}

const BOUTIQUE_DELIVERY_FEE = 500; // même constante que boutique_page.dart côté Dart

function isCompletedBoutiqueDelivery(delivery) {
  if (!delivery) return false;
  return ['delivered', 'completed'].includes(delivery.status) ||
    (delivery.status === 'proof_sent' &&
      (delivery.proofValidated === true || delivery.deliveryCompletedAt != null)) ||
    delivery.deliveredAt != null ||
    delivery.deliveryCompletedAt != null;
}

async function readProductBoutiqueSeller(tx, db, product, HttpsError) {
  const sellerId = String(product.sellerId || product.boutiqueId || '');
  if (!sellerId) {
    throw new HttpsError('failed-precondition', 'Produit sans vendeur boutique');
  }

  const sellerRef = db.collection('sellers').doc(sellerId);
  const sellerSnap = await tx.get(sellerRef);
  if (!sellerSnap.exists) {
    throw new HttpsError('failed-precondition', 'Vendeur boutique introuvable');
  }

  const seller = sellerSnap.data();
  if (seller.deletionRequested === true || seller.isDeleted === true || seller.type !== 'boutique' || seller.isSuspended === true ||
      seller.isActive === false || seller.status === 'suspended') {
    throw new HttpsError('failed-precondition', 'Vendeur boutique indisponible');
  }

  return { sellerId, sellerRef, seller };
}

async function resolveBoutiqueOrderGeography(
  db,
  HttpsError,
  productId,
  deliveryLat,
  deliveryLng,
) {
  const productSnap = await db.collection('boutique_products')
    .doc(String(productId)).get();
  if (!productSnap.exists) {
    throw new HttpsError('not-found', 'Produit introuvable');
  }
  const sellerId = String(
    productSnap.data().sellerId || productSnap.data().boutiqueId || '',
  );
  const sellerSnap = sellerId
    ? await db.collection('sellers').doc(sellerId).get()
    : null;
  if (!sellerSnap?.exists) {
    throw new HttpsError('failed-precondition', 'Vendeur boutique introuvable');
  }
  try {
    return await resolveDispatchGeography(db, {
      pickupLat: Number(sellerSnap.data().lat),
      pickupLng: Number(sellerSnap.data().lng),
      deliveryLat: Number(deliveryLat),
      deliveryLng: Number(deliveryLng),
      pickupCoordinateSource: 'local_place',
      deliveryCoordinateSource: 'gps',
    });
  } catch (error) {
    throw new HttpsError('failed-precondition', error.message);
  }
}

async function compensateFailedCashBoutiqueDispatch({
  db, admin, orderId, deliveryOrderId, productId, quantity, reason,
}) {
  return db.runTransaction(async (tx) => {
    const orderRef = db.collection('boutique_orders').doc(orderId);
    const deliveryRef = db.collection('orders').doc(deliveryOrderId);
    const productRef = db.collection('boutique_products').doc(String(productId));
    const [orderSnap, deliverySnap, productSnap] = await Promise.all([
      tx.get(orderRef), tx.get(deliveryRef), tx.get(productRef),
    ]);

    if (!orderSnap.exists || !deliverySnap.exists || !productSnap.exists) {
      return false;
    }
    const order = orderSnap.data();
    const delivery = deliverySnap.data();
    if (order.status !== 'pending_dispatch' ||
        order.deliveryOrderId !== deliveryOrderId ||
        delivery.status !== 'pending' || delivery.driverId ||
        (delivery.notifiedDriverIds || []).length > 0) {
      return false;
    }

    const currentStock = Number(productSnap.data().stock || 0);
    tx.update(productRef, { stock: currentStock + quantity });
    tx.update(orderRef, {
      status: 'dispatch_failed',
      dispatchStatus: 'failed',
      failureReason: String(reason || 'dispatch_failed').slice(0, 500),
      dispatchFailedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(deliveryRef, {
      status: 'cancelled',
      cancellationReason: 'boutique_dispatch_failed',
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

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
    const { productId, qty, deliveryLat, deliveryLng, acceptedTotal } = request.data || {};
    if (!productId) throw new HttpsError('invalid-argument', 'productId manquant');
    const quantity = Math.max(1, Math.round(Number(qty) || 1));

    await checkRateLimit(uid, 'pay_boutique_order', 20, 60);
    // Facturation explicite uniquement si l'application déclare le total qu'elle
    // a affiché ; une ancienne application reste facturée comme avant.
    const billing = decideBilling({ mode: await getBillingMode(db), acceptedTotal, HttpsError });
    // Ancienne application : la course créée ne pourrait être acceptée qu'au prix
    // d'une commission sans rémunération du livreur. On ne débite donc rien tant
    // que l'exploitant n'a pas choisi la politique 'no_commission'.
    if (billing === 'legacy' && (await getLegacyPartnerPolicy(db)) === 'block') {
      throw new HttpsError('failed-precondition', 'APP_UPDATE_REQUIRED');
    }

    const geography = await resolveBoutiqueOrderGeography(
      db, HttpsError, productId, deliveryLat, deliveryLng,
    );

    const orderRef = db.collection('boutique_orders').doc();
    const orderId  = orderRef.id;
    const deliveryOrderRef = db.collection('orders').doc();
    const deliveryOrderId = deliveryOrderRef.id;

    let totalPrice, productName, productCategory, sellerId, sellerName;
    let pickupLat, pickupLng;
    let amounts = null;
    let chargeTotal, sellerCredit;

    await db.runTransaction(async (tx) => {
      const productRef = db.collection('boutique_products').doc(String(productId));
      const clientRef  = db.collection('clients').doc(uid);

      const productSnap = await tx.get(productRef);
      if (!productSnap.exists) throw new HttpsError('not-found', 'Produit introuvable');
      const product = productSnap.data();
      const sellerInfo = await readProductBoutiqueSeller(tx, db, product, HttpsError);
      sellerId = sellerInfo.sellerId;
      sellerName = sellerInfo.seller.name || 'Boutique AZ';

      const currentStock = Number(product.stock || 0);
      if (currentStock < quantity) {
        throw new HttpsError('failed-precondition', 'STOCK_EPUISE');
      }

      const unitPrice = Number(product.price || 0);
      totalPrice      = unitPrice * quantity;
      productName     = product.name || null;
      productCategory = product.category || null;
      if (totalPrice <= 0) throw new HttpsError('failed-precondition', 'Prix produit invalide');

      // Le client règle produits + livraison ; le vendeur ne reçoit que les produits.
      // Le total facturé doit être exactement celui que le client a accepté.
      amounts = billing === 'explicit' ? buildAmounts(totalPrice, BOUTIQUE_DELIVERY_FEE) : null;
      if (amounts) assertAcceptedTotal({ acceptedTotal, totalAmount: amounts.totalAmount, HttpsError });
      chargeTotal = amounts ? amounts.totalAmount : totalPrice;
      sellerCredit = amounts ? amounts.productAmount : totalPrice;

      const clientSnap    = await tx.get(clientRef);
      const clientWallet  = Number(clientSnap.data()?.wallet || 0);
      if (clientWallet < chargeTotal) {
        // Format conservé pour compatibilité avec le parsing existant côté
        // Flutter (boutique_page.dart cherche la sous-chaîne SOLDE_INSUFFISANT) ;
        // le second nombre est désormais le TOTAL à payer (produits + livraison).
        throw new HttpsError('failed-precondition', `SOLDE_INSUFFISANT:${clientWallet}:${chargeTotal}`);
      }

      const sellerRef = sellerInfo.sellerRef;
      const sellerSnapTx = sellerInfo.seller;
      const sellerWallet = Number(sellerSnapTx.wallet || 0);

      tx.update(clientRef, { wallet: clientWallet - chargeTotal });
      tx.update(sellerRef, { wallet: sellerWallet + sellerCredit });
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
        ...(amounts || {}),
        paymentMethod: 'wallet',
        status:        'paid',
        deliveryOrderId,
        linkedOrderId: deliveryOrderId,
        dispatchStatus: 'pending_dispatch',
        deliveryDeadline: admin.firestore.Timestamp.fromMillis(Date.now() + 48 * 3600 * 1000),
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
      });
      const seller = sellerInfo.seller;
      const lat = Number(seller.lat);
      const lng = Number(seller.lng);
      pickupLat = lat;
      pickupLng = lng;
      tx.set(deliveryOrderRef, {
        description:   `🛍️ Boutique AZ : ${productName} ×${quantity}`,
        ...(amounts
          ? { ...amounts, itemsAmount: amounts.productAmount, deliveryFeePaid: true }
          : { budget: BOUTIQUE_DELIVERY_FEE }),
        shoppingBudget: 0,
        status:         'pending',
        latitude:       lat,
        longitude:      lng,
        destLat:        Number(deliveryLat),
        destLng:        Number(deliveryLng),
        type:           'boutique',
        orderType:      'boutique',
        clientId:       uid,
        sellerId,
        sellerName,
        sellerType:     'boutique',
        paymentMethod:  'wallet',
        linkedBoutiqueOrderId: orderId,
        isPaid:         false,
        ...geography,
        createdAt:      admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    const now = admin.firestore.FieldValue.serverTimestamp();
    await db.collection('clients').doc(uid).collection('wallet_transactions').add({
      type: 'purchase', amount: chargeTotal,
      description: amounts
        ? `Achat : ${productName} ×${quantity} — produits ${amounts.productAmount} + livraison ${amounts.deliveryFee}`
        : `Achat : ${productName} ×${quantity}`,
      orderId, createdAt: now,
    });
    await db.collection('sellers').doc(sellerId).collection('wallet_transactions').add({
      type: 'sale', amount: sellerCredit,
      description: `Vente boutique : ${productName} ×${quantity}`,
      orderId, createdAt: now,
    });

    await logAudit({
      userId: uid, userType: 'client', action: 'pay_boutique_order', targetId: orderId,
      amount: chargeTotal,
      metadata: { productId, quantity, sellerId, billing,
        ...(amounts ? { productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee } : {}) },
    });

    // Course de livraison — best-effort : un échec ici n'invalide pas
    // l'achat déjà payé (même comportement que le code Dart d'origine, qui
    // enveloppait cette étape dans son propre try/catch silencieux).
    let dispatchResult = null;
    try {
      dispatchResult = await dispatchOrder(db, admin, {
        orderId: deliveryOrderId,
        lat: pickupLat,
        lng: pickupLng,
        pickupCityId: geography.pickupCityId,
        cityResolutionStatus: geography.cityResolutionStatus,
        budget: BOUTIQUE_DELIVERY_FEE,
      });
      await orderRef.update({
        dispatchStatus: dispatchResult.dispatched ? 'dispatched' : 'pending',
      });
    } catch (err) {
      console.error('payBoutiqueOrderCF: création/dispatch de la course a échoué (achat déjà validé):', err.message);
      // Master Prompt 58 : rendre ce cas ("commande bloquée" / "livreur
      // introuvable" après un achat déjà payé) visible dans audit_logs, pas
      // seulement dans les logs bruts Cloud Functions — c'est exactement le
      // genre d'échec qu'un admin doit pouvoir repérer sans lire les logs.
      logAudit({
        userId: uid, userType: 'client', action: 'pay_boutique_order_dispatch_failed',
        targetId: orderId, status: 'error', metadata: { sellerId, error: err.message },
      });
    }

    return {
      orderId, totalPrice, deliveryFee: amounts ? amounts.deliveryFee : 0,
      totalAmount: chargeTotal, dispatched: dispatchResult?.dispatched || false,
    };
  });
}

// Remplace le chemin cash de boutique_page.dart:_buyProduct() — décrémentait
// le stock via une écriture directe (hors transaction), PUIS tentait de
// créer `boutique_orders` avec `status: 'pending_payment'`, qui viole la
// règle de création côté client (`status == 'pending'` exact) et échouait
// donc SYSTÉMATIQUEMENT — stock perdu sans aucune commande créée à chaque
// tentative d'achat cash (Master Prompt 54, trouvaille documentée sans être
// corrigée au Prompt 48 bis). Porté en Cloud Function, atomique : vérifie et
// décrémente le stock, crée `boutique_orders`, dans la MÊME transaction —
// soit les deux réussissent ensemble, soit aucune écriture n'a lieu (rollback
// naturel de la transaction Firestore). Utilise Admin SDK (contourne les
// règles côté client, qui ne s'appliquent qu'aux écritures directes) donc
// `status: 'pending_payment'` peut être écrit sans devoir changer la règle
// Firestore elle-même. Aucun wallet touché ici (le paiement cash se fait
// physiquement à la livraison) — donc aucun des correctifs de paiement
// wallet des Prompts 46-49 ne s'applique, seule l'atomicité stock↔commande
// est en jeu, contrairement à buildPayBoutiqueOrder (chemin wallet) qui reste
// inchangé par ce correctif.
function buildPayBoutiqueOrderCash({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, dispatchOrder }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { productId, qty, deliveryLat, deliveryLng, acceptedTotal } = request.data || {};
    if (!productId) throw new HttpsError('invalid-argument', 'productId manquant');
    const quantity = Math.max(1, Math.round(Number(qty) || 1));

    await checkRateLimit(uid, 'pay_boutique_order_cash', 20, 60);
    const billing = decideBilling({ mode: await getBillingMode(db), acceptedTotal, HttpsError });
    // Ancienne application : la course créée ne pourrait être acceptée qu'au prix
    // d'une commission sans rémunération du livreur. On ne débite donc rien tant
    // que l'exploitant n'a pas choisi la politique 'no_commission'.
    if (billing === 'legacy' && (await getLegacyPartnerPolicy(db)) === 'block') {
      throw new HttpsError('failed-precondition', 'APP_UPDATE_REQUIRED');
    }

    const geography = await resolveBoutiqueOrderGeography(
      db, HttpsError, productId, deliveryLat, deliveryLng,
    );

    // Vendeur boutique unique — même requête que payBoutiqueOrderCF (le
    // paiement wallet), non transactionnelle (ce compte change rarement).
    let sellerId;
    let sellerName;
    let pickupLat, pickupLng;

    const orderRef = db.collection('boutique_orders').doc();
    const orderId  = orderRef.id;
    const deliveryOrderRef = db.collection('orders').doc();
    const deliveryOrderId = deliveryOrderRef.id;

    let totalPrice, productName, productCategory;
    let amounts = null;

    await db.runTransaction(async (tx) => {
      // Lecture avant écriture (obligatoire dans une transaction Firestore) —
      // le stock est vérifié à l'intérieur de la même transaction qui le
      // décrémente, donc deux achats simultanés du dernier exemplaire ne
      // peuvent jamais tous les deux réussir (le second relit un stock déjà
      // à jour au retry de la transaction, ou échoue si insuffisant).
      const productRef = db.collection('boutique_products').doc(String(productId));
      const productSnap = await tx.get(productRef);
      if (!productSnap.exists) throw new HttpsError('not-found', 'Produit introuvable');
      const product = productSnap.data();
      const sellerInfo = await readProductBoutiqueSeller(tx, db, product, HttpsError);
      sellerId = sellerInfo.sellerId;
      sellerName = sellerInfo.seller.name || 'Boutique AZ';

      const currentStock = Number(product.stock || 0);
      if (currentStock < quantity) {
        throw new HttpsError('failed-precondition', 'STOCK_EPUISE');
      }

      const unitPrice = Number(product.price || 0);
      totalPrice      = unitPrice * quantity;
      productName     = product.name || null;
      productCategory = product.category || null;
      if (totalPrice <= 0) throw new HttpsError('failed-precondition', 'Prix produit invalide');

      amounts = billing === 'explicit' ? buildAmounts(totalPrice, BOUTIQUE_DELIVERY_FEE) : null;
      if (amounts) assertAcceptedTotal({ acceptedTotal, totalAmount: amounts.totalAmount, HttpsError });
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
        ...(amounts || {}),
        paymentMethod: 'cash',
        status:        'pending_dispatch',
        deliveryOrderId,
        linkedOrderId: deliveryOrderId,
        dispatchStatus: 'pending_dispatch',
        deliveryDeadline: admin.firestore.Timestamp.fromMillis(Date.now() + 48 * 3600 * 1000),
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
      });
      const lat = Number(sellerInfo.seller.lat);
      const lng = Number(sellerInfo.seller.lng);
      pickupLat = lat;
      pickupLng = lng;
      tx.set(deliveryOrderRef, {
        description: `Boutique AZ : ${productName} x${quantity}`,
        ...(amounts
          ? { ...amounts, itemsAmount: amounts.productAmount, deliveryFeePaid: false }
          : { budget: BOUTIQUE_DELIVERY_FEE }),
        shoppingBudget: 0,
        status: 'pending',
        latitude: lat,
        longitude: lng,
        destLat: Number(deliveryLat),
        destLng: Number(deliveryLng),
        type: 'boutique',
        orderType: 'boutique',
        clientId: uid,
        sellerId,
        sellerName,
        sellerType: 'boutique',
        paymentMethod: 'cash',
        linkedBoutiqueOrderId: orderId,
        isPaid: false,
        ...geography,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    await logAudit({
      userId: uid, userType: 'client', action: 'pay_boutique_order_cash', targetId: orderId,
      amount: amounts ? amounts.totalAmount : totalPrice,
      metadata: { productId, quantity, sellerId, billing,
        ...(amounts ? { productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee } : {}) },
    });

    // Course de livraison — best-effort, même pattern que
    // buildPayBoutiqueOrder : un échec ici n'invalide pas l'achat déjà créé.
    let dispatchResult = null;
    try {
      dispatchResult = await dispatchOrder(db, admin, {
        orderId: deliveryOrderId,
        lat: pickupLat,
        lng: pickupLng,
        pickupCityId: geography.pickupCityId,
        cityResolutionStatus: geography.cityResolutionStatus,
        budget: BOUTIQUE_DELIVERY_FEE,
      });
      await orderRef.update({
        status: 'pending_payment',
        dispatchStatus: dispatchResult.dispatched ? 'dispatched' : 'pending',
      });
      return {
        orderId, totalPrice, deliveryFee: amounts ? amounts.deliveryFee : 0,
        totalAmount: amounts ? amounts.totalAmount : totalPrice,
        dispatched: dispatchResult.dispatched || false,
      };
    } catch (err) {
      const restored = await compensateFailedCashBoutiqueDispatch({
        db, admin, orderId, deliveryOrderId, productId, quantity, reason: err.message,
      });
      console.error('payBoutiqueOrderCashCF: dispatch failed:', err.message);
      await logAudit({
        userId: uid, userType: 'client', action: 'pay_boutique_order_cash_dispatch_failed',
        targetId: orderId,
        status: restored ? 'rolled_back' : 'error',
        metadata: { sellerId, deliveryOrderId, stockRestored: restored, error: err.message },
      });
      if (restored) {
        throw new HttpsError('unavailable', 'Course indisponible, stock restauré. Réessayez.');
      }
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
    // Compatibilité historique : les anciennes ventes n'avaient pas de
    // deliveryOrderId, mais la course conserve linkedBoutiqueOrderId.
    const legacyDeliveryQuery = await db.collection('orders')
      .where('linkedBoutiqueOrderId', '==', String(orderId))
      .limit(1)
      .get();
    const legacyDeliveryRef = legacyDeliveryQuery.empty
      ? null
      : db.collection('orders').doc(legacyDeliveryQuery.docs[0].id);
    let amount = 0, sellerId = null, sellerDebit = 0;

    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();

      if (order.clientId !== uid) {
        throw new HttpsError('permission-denied', "Cette commande n'est pas la vôtre");
      }
      if (order.deliveredAt != null || order.deliveryCompletedAt != null ||
          ['delivered', 'refunded', 'cancelled'].includes(order.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande est déjà terminée');
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
      const deliveryOrderId = order.deliveryOrderId || order.linkedOrderId || null;
      const deliveryRef = deliveryOrderId
        ? db.collection('orders').doc(String(deliveryOrderId))
        : legacyDeliveryRef;

      const [clientSnap, sellerSnap, deliverySnap] = await Promise.all([
        tx.get(clientRef),
        sellerRef ? tx.get(sellerRef) : null,
        deliveryRef ? tx.get(deliveryRef) : null,
      ]);
      if (deliverySnap?.exists && isCompletedBoutiqueDelivery(deliverySnap.data())) {
        throw new HttpsError('failed-precondition', 'La livraison liée est déjà accomplie');
      }
      // Commande à montants explicites : un livreur a déjà accepté la course
      // (commission prélevée) et touchera les frais à la livraison. Rembourser
      // maintenant laisserait une course orpheline : le remboursement attend
      // la fin ou l'annulation de la course.
      const amounts = readAmounts(order);
      if (amounts && deliverySnap?.exists &&
          ['accepted', 'picked_up'].includes(deliverySnap.data().status)) {
        throw new HttpsError('failed-precondition', 'La livraison est en cours : remboursement impossible pour le moment');
      }
      // Remboursé = ce qui a réellement été payé (produits + livraison) ; le
      // vendeur ne rend que les produits qu'il a reçus.
      amount = amounts ? amounts.totalAmount : amount;
      const sellerShare = amounts ? amounts.productAmount : amount;

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
          sellerDebit = Math.min(sellerShare, sellerWallet);
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
  buildDeliverOrderWithProof,
  buildPayBoutiqueOrder,
  buildPayBoutiqueOrderCash,
  buildRefundExpiredBoutiqueOrder,
  cancelOrderTx,
  cancelOrderPostTx,
  partnerCollection,
  AZ_COMMISSION_FIXED,
  PREPAID_PARTNER_TYPES,
};
