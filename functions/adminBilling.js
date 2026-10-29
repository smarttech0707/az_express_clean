'use strict';

const { runLifecycleTransaction } = require('./driverLifecycle');
const { cancelOrderTx, cancelOrderPostTx, PREPAID_PARTNER_TYPES } = require('./orderActions');
const { readAmounts } = require('./orderAmounts');

// Examen administratif des commandes Marketplace / Boutique (super-admin).
//
//   closeStuckDelivery  clôt une livraison bloquée/abandonnée (acceptée ou récupérée
//                       sans issue) : annulation + remboursement selon la règle
//                       commerciale (avant récupération = intégral ; après récupération
//                       = produits remboursés, frais retenus en attente d'examen),
//                       sauf `refundFee: true` (faute du livreur ou d'AZ).
//   resolveFeeHold      tranche les frais retenus après récupération :
//                         refundClient  rembourse les frais au client et rend la commission
//                         payDriver     rémunère le livreur (la commission reste due)
//                         retain        AZ garde les frais, la commission est rendue
//   refundBoutiqueOrder rembourse une commande boutique wallet dont la livraison est close
//                       (annulée) sans passer par le délai de 48 h.
//   confirmStockReturn  remet en stock les produits d'une commande boutique remboursée ou
//                       annulée, UNIQUEMENT sur confirmation administrative : le stock n'est
//                       jamais restitué automatiquement (le produit peut déjà être chez le
//                       client). `non_delivery` : la livraison n'a jamais récupéré le colis ;
//                       `product_returned` : le retour physique chez le vendeur est constaté.
//
// Aucun paiement fictif : seul l'argent déjà payé par le client est redistribué.
// Chaque action est rejouable sans effet (état relu dans la transaction +
// identifiants de mouvement déterministes), journalisée (orders.adminReview /
// deliveryFeeHold.decision, audit_logs).

const ACTIONS = Object.freeze(['closeStuckDelivery', 'resolveFeeHold', 'refundBoutiqueOrder', 'confirmStockReturn']);
const STOCK_REASONS = Object.freeze(['non_delivery', 'product_returned']);
const DECISIONS = Object.freeze(['refundClient', 'payDriver', 'retain']);
const MIN_JUSTIFICATION = 10;
const OPEN_STATUSES = ['pending', 'broadcast', 'assigned', 'accepted', 'picked_up'];

const isId = (v) => typeof v === 'string' && v.length > 0 && v.length <= 160 && !v.includes('/');

function buildAdminBilling({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin, calculateCommission,
}) {
  const FieldValue = admin.firestore.FieldValue;
  return onCall({ maxInstances: 1, cpu: 0.5 }, async (request) => {
    if (!request.auth?.uid || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const data = request.data || {};
    if (!ACTIONS.includes(data.action)) throw new HttpsError('invalid-argument', 'Action invalide');
    if (!isId(data.orderId)) throw new HttpsError('invalid-argument', 'orderId invalide');
    const justification = typeof data.justification === 'string' ? data.justification.trim() : '';
    if (justification.length < MIN_JUSTIFICATION) {
      throw new HttpsError('invalid-argument', `Justification obligatoire (${MIN_JUSTIFICATION} caractères minimum)`);
    }
    await checkRateLimit(uid, `admin_billing_${data.action}`, 30, 600);
    await requireSuperAdmin({ request, db });

    const result = data.action === 'closeStuckDelivery'
      ? await closeStuckDelivery({ data, uid, justification })
      : data.action === 'resolveFeeHold'
        ? await resolveFeeHold({ data, uid, justification })
        : data.action === 'confirmStockReturn'
          ? await confirmStockReturn({ data, uid, justification })
          : await refundBoutiqueOrder({ data, uid, justification });

    await logAudit({
      userId: uid, userType: 'admin', action: `admin_billing_${data.action}`, targetId: data.orderId,
      status: 'success', metadata: { ...result.audit, justification },
    });
    return { success: true, ...result.response };
  });

  async function closeStuckDelivery({ data, uid, justification }) {
    const orderRef = db.collection('orders').doc(data.orderId);
    let refundInfo;
    let clientId;
    await runLifecycleTransaction(db, async (tx) => {
      const snap = await tx.get(orderRef);
      if (!snap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = snap.data();
      if (!PREPAID_PARTNER_TYPES.has(order.sellerType)) {
        throw new HttpsError('failed-precondition', 'Commande hors Marketplace / Boutique');
      }
      if (!OPEN_STATUSES.includes(order.status)) {
        throw new HttpsError('failed-precondition', 'La livraison est déjà terminée ou annulée');
      }
      clientId = order.clientId;
      try {
        refundInfo = await cancelOrderTx(tx, {
          db, admin, orderRef, order, uid: order.clientId, calculateCommission,
          reason: 'admin_close_stuck', adminDecision: { refundFee: data.refundFee === true },
        });
      } catch (err) {
        if (err.message === 'ORDER_NOT_CANCELLABLE') {
          throw new HttpsError('failed-precondition', 'La livraison est déjà terminée ou annulée');
        }
        throw err;
      }
      tx.update(orderRef, {
        adminReview: {
          action: 'closeStuckDelivery', byUid: uid, atMs: Date.now(), justification,
          refundFee: data.refundFee === true, statusAtClose: order.status,
        },
      });
    });
    await cancelOrderPostTx(db, admin, { orderId: data.orderId, uid: clientId, ...refundInfo });
    return {
      response: { clientRefund: refundInfo.clientRefund, feeHeld: refundInfo.feeHeld },
      audit: { ...refundInfo, refundFee: data.refundFee === true },
    };
  }

  async function resolveFeeHold({ data, uid, justification }) {
    if (!DECISIONS.includes(data.decision)) throw new HttpsError('invalid-argument', 'Décision invalide');
    const orderRef = db.collection('orders').doc(data.orderId);
    let out;
    await runLifecycleTransaction(db, async (tx) => {
      out = null;
      const snap = await tx.get(orderRef);
      if (!snap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = snap.data();
      const hold = order.deliveryFeeHold;
      if (!hold || !Number.isSafeInteger(hold.amount) || hold.amount <= 0) {
        throw new HttpsError('failed-precondition', 'Aucun frais de livraison en attente pour cette commande');
      }
      // Rejeu : une décision déjà prise ne se rejoue jamais.
      if (hold.status !== 'pending_admin_review') {
        out = { replay: true, decision: hold.decision };
        return;
      }
      const amount = hold.amount;
      const now = Date.now();
      const ts = FieldValue.serverTimestamp();
      const traced = order.commissionStatus === 'charged' && Number.isSafeInteger(order.commissionAmount) &&
        order.commissionAmount >= 0 && isId(order.commissionPayerId);
      const driverId = isId(hold.driverId) ? hold.driverId : null;

      // Lectures avant écritures.
      const clientRef = db.collection('clients').doc(order.clientId);
      const clientSnap = data.decision === 'refundClient' ? await tx.get(clientRef) : null;
      const driverRef = data.decision === 'payDriver' && driverId ? db.collection('livreurs').doc(driverId) : null;
      const driverSnap = driverRef ? await tx.get(driverRef) : null;
      if (data.decision === 'payDriver' && (!driverSnap || !driverSnap.exists)) {
        throw new HttpsError('failed-precondition', 'Livreur introuvable : choisissez une autre décision');
      }
      const refundCommission = data.decision !== 'payDriver' && traced;
      const payerRef = refundCommission ? db.collection('livreurs').doc(order.commissionPayerId) : null;
      const payerSnap = payerRef ? await tx.get(payerRef) : null;

      if (data.decision === 'refundClient') {
        if (!clientSnap.exists) throw new HttpsError('failed-precondition', 'Client introuvable');
        tx.update(clientRef, { wallet: Number(clientSnap.data().wallet || 0) + amount });
        tx.set(clientRef.collection('wallet_transactions').doc(`fee_hold_${data.orderId}`), {
          type: 'refund', amount, description: 'Remboursement des frais de livraison (examen administratif)',
          orderId: data.orderId, createdAt: ts,
        });
      } else if (data.decision === 'payDriver') {
        tx.update(driverRef, { wallet: Number(driverSnap.data().wallet || 0) + amount });
        tx.set(driverRef.collection('wallet_transactions').doc(`fee_hold_${data.orderId}`), {
          type: 'earning', amount,
          description: `Frais de livraison — course annulée après récupération (commission AZ ${traced ? order.commissionAmount : 0} déjà prélevée)`,
          orderId: data.orderId, createdAt: ts,
        });
        if (traced) {
          // La commission reste due : elle devient un revenu AZ au même titre qu'à la livraison.
          tx.set(db.collection('commissions').doc(`fee_hold_${data.orderId}`), {
            orderId: data.orderId, driverId: order.commissionPayerId, amount: order.commissionAmount,
            commissionSource: 'traced', deliveryFee: amount, driverGain: amount - order.commissionAmount,
            paymentMethod: order.paymentMethod || '', createdAt: ts,
          });
          tx.set(db.collection('config').doc('az_wallet'), {
            totalCommissions: FieldValue.increment(order.commissionAmount), updatedAt: ts,
          }, { merge: true });
        }
      } else {
        tx.set(db.collection('config').doc('az_wallet'), {
          retainedDeliveryFees: FieldValue.increment(amount), updatedAt: ts,
        }, { merge: true });
      }

      if (refundCommission && payerSnap && payerSnap.exists) {
        tx.update(payerRef, { wallet: Number(payerSnap.data().wallet || 0) + order.commissionAmount });
        tx.set(payerRef.collection('wallet_transactions').doc(`fee_hold_commission_${data.orderId}`), {
          type: 'refund', amount: order.commissionAmount,
          description: 'Remboursement commission — course non rémunérée (examen administratif)',
          orderId: data.orderId, createdAt: ts,
        });
        tx.update(orderRef, { commissionStatus: 'refunded' });
      }

      tx.update(orderRef, {
        deliveryFeeHold: {
          ...hold, status: 'resolved', decision: data.decision, resolvedBy: uid,
          resolvedAtMs: now, justification,
        },
      });
      out = { replay: false, decision: data.decision, amount };
    });
    return { response: out, audit: { decision: out.decision, replay: out.replay, amount: out.amount || null } };
  }

  async function confirmStockReturn({ data, uid, justification }) {
    if (!STOCK_REASONS.includes(data.reason)) throw new HttpsError('invalid-argument', 'Motif de restitution invalide');
    const boRef = db.collection('boutique_orders').doc(data.orderId);
    let out;
    await runLifecycleTransaction(db, async (tx) => {
      const boSnap = await tx.get(boRef);
      if (!boSnap.exists) throw new HttpsError('not-found', 'Commande boutique introuvable');
      const bo = boSnap.data();
      if (bo.stockReturn?.status === 'restored') {
        out = { replay: true, restored: 0 };
        return; // rejeu : jamais de second remise en stock
      }
      if (bo.status === 'dispatch_failed') {
        throw new HttpsError('failed-precondition', 'Stock déjà restitué automatiquement (échec de dispatch)');
      }
      const qty = Number(bo.qty);
      if (!Number.isSafeInteger(qty) || qty <= 0 || !isId(bo.productId)) {
        throw new HttpsError('failed-precondition', 'Quantité ou produit invalide');
      }
      const deliveryId = bo.deliveryOrderId || bo.linkedOrderId;
      const deliveryRef = isId(deliveryId) ? db.collection('orders').doc(deliveryId) : null;
      const deliverySnap = deliveryRef ? await tx.get(deliveryRef) : null;
      const productRef = db.collection('boutique_products').doc(bo.productId);
      const productSnap = await tx.get(productRef);
      if (!productSnap.exists) throw new HttpsError('failed-precondition', 'Produit introuvable');
      const delivery = deliverySnap?.exists ? deliverySnap.data() : null;

      // La commande doit être terminée côté argent : remboursée (wallet) ou, en cash,
      // livraison annulée. Une livraison ouverte ou livrée n'autorise aucune restitution
      // tant que le client n'a pas été remboursé.
      const cashCancelled = bo.paymentMethod === 'cash' && delivery?.status === 'cancelled';
      if (bo.status !== 'refunded' && !cashCancelled) {
        throw new HttpsError('failed-precondition', 'Commande ni remboursée ni annulée');
      }
      if (data.reason === 'non_delivery') {
        // Le colis n'a jamais quitté le vendeur : livraison annulée sans récupération.
        const neverPickedUp = delivery && delivery.status === 'cancelled' &&
          delivery.pickedUpAt == null && !delivery.deliveryFeeHold && delivery.deliveredAt == null;
        if (!neverPickedUp) {
          throw new HttpsError('failed-precondition',
            'Le colis a pu être récupéré : seule la confirmation d’un retour (product_returned) est possible');
        }
      }
      const stock = Number(productSnap.data().stock || 0);
      tx.update(productRef, { stock: stock + qty });
      tx.update(boRef, {
        stockReturn: { status: 'restored', quantity: qty, reason: data.reason, byUid: uid, atMs: Date.now(), justification },
      });
      out = { replay: false, restored: qty, reason: data.reason };
    });
    return { response: out, audit: out };
  }

  async function refundBoutiqueOrder({ data, uid, justification }) {
    const boRef = db.collection('boutique_orders').doc(data.orderId);
    let out;
    await runLifecycleTransaction(db, async (tx) => {
      const boSnap = await tx.get(boRef);
      if (!boSnap.exists) throw new HttpsError('not-found', 'Commande boutique introuvable');
      const bo = boSnap.data();
      if (bo.status === 'refunded') throw new HttpsError('failed-precondition', 'Commande déjà remboursée');
      if (bo.paymentMethod !== 'wallet' || bo.status !== 'paid') {
        throw new HttpsError('failed-precondition', 'Seule une commande boutique payée par wallet peut être remboursée');
      }
      const deliveryId = bo.deliveryOrderId || bo.linkedOrderId;
      const deliveryRef = isId(deliveryId) ? db.collection('orders').doc(deliveryId) : null;
      const deliverySnap = deliveryRef ? await tx.get(deliveryRef) : null;
      // La livraison doit être close : annulée (ou jamais créée). Une livraison
      // ouverte ou terminée se traite via closeStuckDelivery / n'est pas remboursable.
      if (deliverySnap?.exists && deliverySnap.data().status !== 'cancelled') {
        throw new HttpsError('failed-precondition',
          'La livraison liée doit d’abord être clôturée (closeStuckDelivery)');
      }
      const delivery = deliverySnap?.exists ? deliverySnap.data() : null;
      if (delivery && delivery.deliveryFeeHold) {
        throw new HttpsError('failed-precondition', 'Des frais de livraison sont en attente d’examen (resolveFeeHold)');
      }
      const amounts = readAmounts(bo);
      const productShare = amounts ? amounts.productAmount : Number(bo.totalPrice || 0);
      const amount = amounts ? amounts.totalAmount : Number(bo.totalPrice || 0);
      if (!(amount > 0)) throw new HttpsError('failed-precondition', 'Montant invalide');

      const clientRef = db.collection('clients').doc(bo.clientId);
      const sellerRef = isId(bo.sellerId) ? db.collection('sellers').doc(bo.sellerId) : null;
      const [clientSnap, sellerSnap] = await Promise.all([tx.get(clientRef), sellerRef ? tx.get(sellerRef) : null]);
      if (!clientSnap.exists) throw new HttpsError('failed-precondition', 'Client introuvable');

      const ts = FieldValue.serverTimestamp();
      tx.update(boRef, {
        status: 'refunded', refundedAt: ts, refundReason: 'admin_refund', refundedBy: uid,
        adminReview: { action: 'refundBoutiqueOrder', byUid: uid, atMs: Date.now(), justification },
      });
      tx.update(clientRef, { wallet: Number(clientSnap.data().wallet || 0) + amount });
      tx.set(clientRef.collection('wallet_transactions').doc(`admin_refund_${data.orderId}`), {
        type: 'refund', amount, description: 'Remboursement commande boutique (examen administratif)',
        orderId: data.orderId, createdAt: ts,
      });
      let sellerDebit = 0;
      if (sellerSnap && sellerSnap.exists) {
        const w = Number(sellerSnap.data().wallet || 0);
        sellerDebit = Math.min(productShare, w); // plafonné : jamais de solde négatif
        if (sellerDebit > 0) {
          tx.update(sellerRef, { wallet: w - sellerDebit });
          tx.set(sellerRef.collection('wallet_transactions').doc(`admin_refund_${data.orderId}`), {
            type: 'debit', amount: sellerDebit, description: 'Commande boutique remboursée — reprise du paiement',
            orderId: data.orderId, createdAt: ts,
          });
        }
      }
      out = { amount, sellerDebit };
    });
    return { response: out, audit: out };
  }
}

module.exports = { buildAdminBilling, ACTIONS, DECISIONS };
