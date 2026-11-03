'use strict';

const crypto = require('crypto');
const { runLifecycleTransaction, readDriverState, terminalDriverPatch } = require('./driverLifecycle');
const { cancelOrderTx, cancelOrderPostTx, isPickedUp, PREPAID_PARTNER_TYPES } = require('./orderActions');
const { readAmounts } = require('./orderAmounts');

// Litiges après récupération du colis (livraisons ordinaires).
//
// Un client ne peut plus annuler seul une commande `picked_up` : sa demande est
// tracée (`orders.cancelRequestAfterPickup`) et tranchée ici par l'administration.
// AUCUN remboursement automatique : chaque décision est explicite, justifiée,
// journalisée et rejouable sans effet. Spécification : docs/ORDER_DISPUTES_SPEC.md.
//
//   get                 dossier complet + options chiffrées par le serveur (permission `commandes`)
//   listDisputes        demandes en attente d'examen (permission `commandes`)
//   listAlerts          alertes de commandes bloquées (permission `commandes`)
//   listReconciliation  signalements de rapprochement comptable ouverts (permission `commandes`)
//   decide / resolve    RÉSOLUTION sans clôture : la livraison continue, la demande est classée ;
//                       aucun mouvement d'argent, statut inchangé
//   decide / refundShopping | refundFee | refundHalfFee   (A, B, C) remboursement PARTIEL, SUPER-ADMIN :
//                       montants calculés ici, jamais saisis ; le reste du payé revient au livreur ;
//                       la commission AZ est conservée ; la commande est close (`delivered`)
//   decide / exceptionalCancel   (D) remboursement TOTAL, SUPER-ADMIN : cœur d'annulation commun
//                       (cancelOrderTx), commission rendue à son payeur d'origine
//
// La CONFIRMATION ADMINISTRATIVE DE LIVRAISON est une autre fonction (adminConfirmDeliveryCF =
// deliverOrderCF en mode adminConfirm) : ce module ne la fait jamais.
//
// Marketplace / Boutique (montants explicites, frais retenus) : outil existant
// adminBilling (closeStuckDelivery / resolveFeeHold) — refusé ici.

const DECISIONS = Object.freeze(['resolve', 'refundShopping', 'refundFee', 'refundHalfFee', 'exceptionalCancel']);
const REFUND_DECISIONS = Object.freeze(['refundShopping', 'refundFee', 'refundHalfFee', 'exceptionalCancel']);
// Situation du budget d'achat (shoppingBudget) déclarée par le super-admin après vérification.
const SHOPPING_CONTEXTS = Object.freeze(['not_purchased', 'purchased_returned', 'purchased_delivered', 'purchased_unreturned']);
const SHOPPING_REFUNDABLE = Object.freeze(['not_purchased', 'purchased_returned']);
const MIN_JUSTIFICATION = 10;
const MIN_SPENT_JUSTIFICATION = 30;
const isId = (v) => typeof v === 'string' && v.length > 0 && v.length <= 160 && !v.includes('/');

const millis = (v) => {
  if (!v) return null;
  if (typeof v.toMillis === 'function') return v.toMillis();
  if (v instanceof Date) return v.getTime();
  return Number.isFinite(Number(v)) ? Number(v) : null;
};

// Montant réellement encaissé sur le wallet du client pour CETTE commande (aucun
// montant n'est jamais déduit d'ailleurs). Cash, pharmacie wallet non payée et
// course boutique : rien n'a été débité.
function paidFromWallet(order) {
  if (order.paymentMethod !== 'wallet' || order.type === 'boutique' || order.isPaid === false) return 0;
  const explicit = readAmounts(order);
  const base = explicit ? explicit.totalAmount : Number(order.budget || 0);
  const shopping = Number(order.shoppingBudget) > 0 ? Number(order.shoppingBudget) : 0;
  return Math.max(0, base + shopping);
}

// Faits vérifiables côté serveur (affichés au super-admin, utilisés par les garde-fous).
function financialChecks(order) {
  const paid = paidFromWallet(order);
  const shopping = Math.min(paid, Number(order.shoppingBudget) > 0 ? Math.floor(Number(order.shoppingBudget)) : 0);
  return {
    paid, shopping, fee: paid - shopping,
    // Aucun paiement livreur n'existe avant `delivered` ; ces marqueurs signalent un état anormal.
    driverAlreadyPaid: order.status === 'delivered' || order.deliveredAt != null ||
      order.heldDriverEarning != null || order.settlementStatus != null,
    commissionStatus: order.commissionStatus || null,
    commissionCharged: order.commissionStatus === 'charged' && Number.isSafeInteger(order.commissionAmount),
    commissionAmount: Number.isSafeInteger(order.commissionAmount) ? order.commissionAmount : 0,
    // Vendeur déjà payé : jamais avant la livraison pour restaurant/pharmacie ; à la création pour
    // Marketplace/Boutique (hors de cet outil).
    sellerPaidAtCreation: PREPAID_PARTNER_TYPES.has(order.sellerType),
    hasSeller: isId(order.sellerId),
    transferInProgress: order.settlementHold === true || isId(order.activeTransferId),
  };
}

// Calcule les montants d'une option de remboursement. `gate:false` : montants seuls (aperçu du
// dossier). Retourne { ok:true, clientRefund, driverCredit } ou { ok:false, reason }.
// Invariant : clientRefund + driverCredit = payé ; clientRefund ≤ payé.
function planRefund(order, decision, { shoppingContext, justifiedSpentRefund, justification, advancedBy } = {}, gate = true) {
  const c = financialChecks(order);
  if (c.paid <= 0) return { ok: false, reason: 'Rien n\'a été encaissé sur le wallet du client (cash ou non payé)' };
  if (c.driverAlreadyPaid) return { ok: false, reason: 'Le livreur a déjà été payé ou un gain est retenu : décision manuelle requise' };
  if (c.transferInProgress && decision !== 'exceptionalCancel') {
    return { ok: false, reason: 'Course transférée : utiliser le règlement de transfert' };
  }
  const partial = decision !== 'exceptionalCancel';
  if (partial && c.hasSeller) {
    return { ok: false, reason: 'Commande avec vendeur : seul le remboursement total est possible (rapprochement séparé)' };
  }
  const refundsShopping = decision === 'refundShopping' || decision === 'exceptionalCancel';
  const ctxKnown = SHOPPING_CONTEXTS.includes(shoppingContext);
  if (c.shopping > 0 && gate) {
    if (!ctxKnown) {
      return { ok: false, reason: 'Situation du budget d\'achat à déclarer (achats faits ? produits remis ? retournés ?)' };
    }
    if (refundsShopping && !SHOPPING_REFUNDABLE.includes(shoppingContext)) {
      const why = typeof justification === 'string' ? justification.trim() : '';
      if (justifiedSpentRefund !== true || why.length < MIN_SPENT_JUSTIFICATION) {
        return {
          ok: false,
          reason: `Budget d'achat déjà dépensé : remboursement refusé sans décision justifiée (${MIN_SPENT_JUSTIFICATION} caractères minimum)`,
        };
      }
    }
  }
  // Sans contexte (aperçu) le budget est supposé NON dépensé : il revient au client.
  const spent = c.shopping > 0 && ctxKnown && !SHOPPING_REFUNDABLE.includes(shoppingContext);
  const ownFunds = advancedBy === 'driver_own_funds';
  // Budget d'achat dépensé et conservé par le client : le livreur n'est remboursé de son avance que
  // s'il a payé de sa poche (déclaré). Sinon aucune règle de paiement n'existe : décision refusée.
  if (spent && (decision === 'refundFee' || decision === 'refundHalfFee') && gate && !ownFunds) {
    return {
      ok: false,
      reason: 'Budget d\'achat dépensé : préciser que le livreur a avancé ses propres fonds, sinon aucun versement n\'est autorisé',
    };
  }
  // Quatre postes distincts : remboursement client (frais / achat), remboursement de l'avance du
  // livreur, rémunération du livreur. Le budget d'achat n'est JAMAIS une rémunération.
  let feeRefund = 0;
  let shoppingRefund = 0;
  let driverReimbursement = 0;
  let driverPay = 0;
  if (decision === 'refundShopping') {
    if (c.shopping <= 0) return { ok: false, reason: 'Aucun budget d\'achat à rembourser' };
    shoppingRefund = c.shopping;
    driverPay = c.fee;
  } else if (decision === 'refundFee') {
    if (c.fee <= 0) return { ok: false, reason: 'Aucun frais de livraison à rembourser' };
    feeRefund = c.fee;
    if (spent) driverReimbursement = c.shopping; else shoppingRefund = c.shopping;
  } else if (decision === 'refundHalfFee') {
    feeRefund = Math.floor(c.fee / 2);
    if (feeRefund <= 0) return { ok: false, reason: 'Frais de livraison trop faibles pour un remboursement de 50 %' };
    driverPay = c.fee - feeRefund;
    if (spent) driverReimbursement = c.shopping; else shoppingRefund = c.shopping;
  } else {
    feeRefund = c.fee;
    shoppingRefund = c.shopping;
  }
  const clientRefund = feeRefund + shoppingRefund;
  const driverCredit = driverReimbursement + driverPay;
  if (clientRefund > c.paid) return { ok: false, reason: 'Remboursement supérieur au montant payé : opération refusée' };
  if (clientRefund + driverCredit !== c.paid && decision !== 'exceptionalCancel') {
    return { ok: false, reason: 'Incohérence de répartition : opération refusée' };
  }
  // Avance du livreur non remboursée (budget dépensé mais rendu au client) : à traiter à part.
  const advanceUnreimbursed = spent && ownFunds && shoppingRefund > 0 ? shoppingRefund : 0;
  return {
    ok: true, clientRefund, feeRefund, shoppingRefund, driverReimbursement, driverPay, driverCredit, advanceUnreimbursed,
  };
}

function decisionId(orderId, requestId) {
  return crypto.createHash('sha256').update(`${orderId}|${requestId}`).digest('hex');
}

function buildAdminOrderDispute({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  requireAdminPermission, requireSuperAdmin, calculateCommission,
}) {
  const FieldValue = admin.firestore.FieldValue;
  return onCall(async (request) => {
    if (!request.auth?.uid || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const data = request.data || {};
    const LISTS = ['listAlerts', 'listDisputes', 'listReconciliation'];
    if (!['get', 'decide', ...LISTS].includes(data.action)) throw new HttpsError('invalid-argument', 'Action invalide');
    await checkRateLimit(uid, `admin_order_dispute_${data.action}`, 60, 600);

    if (LISTS.includes(data.action)) {
      await requireAdminPermission({ request, db, permission: 'commandes' });
      const lists = { listAlerts: loadAlerts, listDisputes: loadDisputes, listReconciliation: loadReconciliation };
      const key = { listAlerts: 'alerts', listDisputes: 'disputes', listReconciliation: 'flags' }[data.action];
      return { success: true, [key]: await lists[data.action]() };
    }
    if (!isId(data.orderId)) throw new HttpsError('invalid-argument', 'orderId invalide');

    if (data.action === 'get') {
      await requireAdminPermission({ request, db, permission: 'commandes' });
      return { success: true, dispute: await loadDispute(data.orderId) };
    }

    if (!DECISIONS.includes(data.decision)) throw new HttpsError('invalid-argument', 'Décision invalide');
    const justification = typeof data.justification === 'string' ? data.justification.trim() : '';
    if (justification.length < MIN_JUSTIFICATION) {
      throw new HttpsError('invalid-argument', `Justification obligatoire (${MIN_JUSTIFICATION} caractères minimum)`);
    }
    if (typeof data.requestId !== 'string' || data.requestId.length < 16 || data.requestId.length > 128) {
      throw new HttpsError('invalid-argument', 'requestId idempotent requis');
    }
    // Tout remboursement (partiel ou total) : super-admin seul. Le reste : permission `commandes`.
    if (REFUND_DECISIONS.includes(data.decision)) await requireSuperAdmin({ request, db });
    else await requireAdminPermission({ request, db, permission: 'commandes' });

    let result;
    try {
      result = await decide({ data, uid, justification });
    } catch (err) {
      await logAudit({
        userId: uid, userType: 'admin', action: 'admin_order_dispute', targetId: data.orderId,
        status: 'error', metadata: { decision: data.decision, error: err.message, justification },
      }).catch(() => {});
      throw err;
    }
    if (!result.replay) {
      await logAudit({
        userId: uid, userType: 'admin', action: 'admin_order_dispute', targetId: data.orderId,
        status: 'success', amount: result.refund?.clientRefund || null,
        metadata: {
          decision: data.decision, justification, financialTreatment: result.financialTreatment,
          shoppingContext: data.shoppingContext || null, ...result.refund,
        },
      });
    }
    return {
      success: true, decision: data.decision, replay: result.replay === true,
      financialTreatment: result.financialTreatment, ...(result.refund ? { refund: result.refund } : {}),
    };
  });

  // Alertes de commandes bloquées (écrites par stuckOrderAlerts.js), les plus récentes d'abord.
  async function loadAlerts() {
    const snap = await db.collection('stuck_order_alerts').orderBy('alertedAtMs', 'desc').limit(50).get();
    return snap.docs.map((d) => {
      const x = d.data();
      return {
        orderId: x.orderId, status: x.status, minutes: x.minutes ?? null,
        alertedAtMs: x.alertedAtMs ?? null, driverId: x.driverId || null,
      };
    });
  }

  // Demandes d'annulation après récupération, en attente d'examen.
  async function loadDisputes() {
    const snap = await db.collection('orders')
      .where('cancelRequestAfterPickup.status', '==', 'pending_admin_review').limit(50).get();
    return snap.docs.map((d) => {
      const o = d.data();
      return {
        orderId: d.id, status: o.status, type: o.type || null, paymentMethod: o.paymentMethod || null,
        paid: paidFromWallet(o), clientId: o.clientId || null, driverId: o.driverId || null,
        requestedAtMs: o.cancelRequestAfterPickup?.requestedAtMs ?? null,
      };
    }).sort((a, b) => (b.requestedAtMs || 0) - (a.requestedAtMs || 0));
  }

  // Signalements de rapprochement comptable (vendeur déjà payé…) : à traiter hors de cet outil.
  async function loadReconciliation() {
    const snap = await db.collection('reconciliation_flags').where('status', '==', 'open').limit(50).get();
    return snap.docs.map((d) => {
      const x = d.data();
      return {
        id: d.id, orderId: x.orderId, type: x.type, sellerId: x.sellerId || null,
        sellerType: x.sellerType || null, reason: x.reason || null, createdAtMs: x.createdAtMs ?? null,
        driverId: x.driverId || null, amount: Number.isSafeInteger(x.amount) ? x.amount : null,
      };
    }).sort((a, b) => (b.createdAtMs || 0) - (a.createdAtMs || 0));
  }

  async function loadDispute(orderId) {
    const snap = await db.collection('orders').doc(orderId).get();
    if (!snap.exists) throw new HttpsError('not-found', 'Commande introuvable');
    const o = snap.data();
    const nameOf = async (col, id) => {
      if (!isId(id)) return null;
      try { return (await db.collection(col).doc(id).get()).data()?.name || null; } catch (_) { return null; }
    };
    let events = [];
    try {
      const logs = await db.collection('audit_logs').where('targetId', '==', orderId).limit(20).get();
      events = logs.docs.map((d) => {
        const x = d.data();
        return { action: x.action, status: x.status || null, userType: x.userType || null, atMs: millis(x.createdAt || x.timestamp) };
      });
    } catch (_) { /* le dossier reste lisible sans l'historique d'audit */ }
    const checks = financialChecks(o);
    // Montants proposés = calculés ICI (aperçu sans garde de déclaration) ; aucune saisie libre.
    const options = {};
    for (const key of REFUND_DECISIONS) {
      const brief = (p) => ({
        clientRefund: p.clientRefund, driverReimbursement: p.driverReimbursement, driverPay: p.driverPay, driverCredit: p.driverCredit,
      });
      const plan = planRefund(o, key, { shoppingContext: 'not_purchased' }, false);
      // Variante « budget dépensé, avancé par le livreur » (seule différente pour B et C).
      const spentPlan = planRefund(o, key, { shoppingContext: 'purchased_delivered', advancedBy: 'driver_own_funds' }, false);
      options[key] = plan.ok
        ? { available: true, ...brief(plan), ...(spentPlan.ok ? { ifSpent: brief(spentPlan) } : {}) }
        : { available: false, reason: plan.reason };
    }
    return {
      orderId,
      status: o.status,
      type: o.type || null,
      sellerType: o.sellerType || null,
      handledByAdminBilling: PREPAID_PARTNER_TYPES.has(o.sellerType),
      client: { id: o.clientId || null, name: await nameOf('clients', o.clientId) },
      driver: { id: o.driverId || null, name: await nameOf('livreurs', o.driverId) },
      amounts: {
        paymentMethod: o.paymentMethod || null,
        isPaid: o.isPaid === true,
        budget: Number(o.budget || 0),
        shoppingBudget: Number(o.shoppingBudget || 0),
        paidFromWallet: checks.paid,
        commissionStatus: checks.commissionStatus,
        commissionAmount: Number.isSafeInteger(o.commissionAmount) ? o.commissionAmount : null,
        commissionPayerId: o.commissionPayerId || null,
      },
      checks: {
        driverAlreadyPaid: checks.driverAlreadyPaid, commissionCharged: checks.commissionCharged,
        hasSeller: checks.hasSeller, sellerPaidAtCreation: checks.sellerPaidAtCreation,
        transferInProgress: checks.transferInProgress, needsShoppingContext: checks.shopping > 0,
      },
      options,
      request: o.cancelRequestAfterPickup || null,
      decision: o.disputeDecision || null,
      timeline: {
        createdAtMs: millis(o.createdAt), acceptedAtMs: millis(o.acceptedAt),
        pickedUpAtMs: millis(o.pickedUpAt), requeuedAtMs: millis(o.requeuedAt),
      },
      driverHistory: Array.isArray(o.driverHistory) ? o.driverHistory.slice(-10) : [],
      events,
    };
  }

  async function decide({ data, uid, justification }) {
    const orderRef = db.collection('orders').doc(data.orderId);
    const opRef = db.collection('order_dispute_decisions').doc(decisionId(data.orderId, data.requestId));
    const ctx = {
      shoppingContext: data.shoppingContext, justifiedSpentRefund: data.justifiedSpentRefund === true, justification,
      advancedBy: data.advancedBy === 'driver_own_funds' ? 'driver_own_funds' : undefined,
    };
    let out;
    await runLifecycleTransaction(db, async (tx) => {
      out = null;
      const opSnap = await tx.get(opRef);
      if (opSnap.exists) { out = { ...opSnap.data().result, replay: true }; return; }
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();
      if (PREPAID_PARTNER_TYPES.has(order.sellerType)) {
        throw new HttpsError('failed-precondition', 'Commande Marketplace/Boutique : utiliser adminBilling (clôture / frais retenus)');
      }
      if (order.status !== 'picked_up' || !isPickedUp(order)) {
        throw new HttpsError('failed-precondition', 'Seule une commande récupérée (picked_up) peut faire l\'objet d\'un litige');
      }

      const nowMs = Date.now();
      const decision = {
        decision: data.decision, requestId: data.requestId, byUid: uid, atMs: nowMs, justification,
        ...(data.shoppingContext ? { shoppingContext: data.shoppingContext } : {}),
      };
      const requestStatus = {
        resolve: 'resolved_without_closure', exceptionalCancel: 'resolved_cancelled',
        refundShopping: 'resolved_partial_refund', refundFee: 'resolved_partial_refund', refundHalfFee: 'resolved_partial_refund',
      }[data.decision];
      const requestPatch = order.cancelRequestAfterPickup
        ? { cancelRequestAfterPickup: { ...order.cancelRequestAfterPickup, status: requestStatus, resolvedAtMs: nowMs } }
        : {};

      let response;
      if (data.decision === 'exceptionalCancel') {
        const plan = planRefund(order, data.decision, ctx);
        // Cash / non payé : l'annulation reste possible (seule la commission est rendue) ; ce sont les
        // garde-fous du remboursement d'argent qui s'appliquent quand quelque chose a été payé.
        if (!plan.ok && paidFromWallet(order) > 0) throw new HttpsError('failed-precondition', plan.reason);
        const paid = paidFromWallet(order);
        // Annulation exceptionnelle = remboursement TOTAL choisi explicitement (c'est ce que le dossier annonce).
        // `refundFee: true` : pour une commande à montants explicites (Restaurant/Boulangerie v2) les frais ne sont
        // pas retenus. Sans effet sur les commandes historiques (sans montants explicites, aucune retenue n'existe).
        const info = await cancelOrderTx(tx, {
          db, admin, orderRef, order, uid: order.clientId, calculateCommission,
          reason: 'admin_dispute_cancel', adminDecision: { refundFee: true },
        });
        // Garde-fou : jamais plus que ce que le client a réellement payé.
        if (info.clientRefund > paid) {
          throw new HttpsError('failed-precondition', 'Remboursement supérieur au montant payé : opération refusée');
        }
        tx.update(orderRef, {
          ...requestPatch,
          disputeDecision: { ...decision, financialTreatment: 'cancel_with_refund', clientRefund: info.clientRefund, driverRefund: info.driverRefund },
          adminReview: { action: 'disputeExceptionalCancel', byUid: uid, atMs: nowMs, justification, statusAtClose: order.status },
        });
        flagSellerReview(tx, order, data.orderId, 'refund_total', nowMs, uid, opRef.id);
        if (plan.ok && plan.advanceUnreimbursed > 0) {
          flagDriverAdvance(tx, data.orderId, order.driverId, plan.advanceUnreimbursed, nowMs, uid, opRef.id);
        }
        response = { financialTreatment: 'cancel_with_refund', refund: info };
      } else if (data.decision === 'resolve') {
        tx.update(orderRef, {
          ...requestPatch,
          disputeDecision: { ...decision, financialTreatment: 'none' },
        });
        response = { financialTreatment: 'none' };
      } else {
        response = await partialRefund(tx, { order, orderRef, ctx, decision, requestPatch, uid, nowMs, justification, data });
      }
      tx.set(opRef, {
        orderId: data.orderId, requestId: data.requestId, decision: data.decision, byUid: uid,
        result: {
          financialTreatment: response.financialTreatment,
          ...(response.refund ? { refund: { clientRefund: response.refund.clientRefund, driverRefund: response.refund.driverRefund ?? 0, driverCredit: response.refund.driverCredit ?? 0 } } : {}),
        },
        createdAt: FieldValue.serverTimestamp(),
      });
      out = { ...response, replay: false, clientId: order.clientId, commission: response.commission };
    });
    if (!out.replay && out.refund) {
      if (out.financialTreatment === 'partial_refund') await partialPostTx(out, data.orderId);
      else await cancelOrderPostTx(db, admin, { orderId: data.orderId, uid: out.clientId, ...out.refund });
    }
    return out;
  }

  // Remboursement partiel : lectures puis écritures, un seul bloc atomique avec la clôture.
  async function partialRefund(tx, { order, orderRef, ctx, decision, requestPatch, uid, nowMs, justification, data }) {
    const plan = planRefund(order, data.decision, ctx);
    if (!plan.ok) throw new HttpsError('failed-precondition', plan.reason);
    if (!isId(order.clientId) || !isId(order.driverId)) {
      throw new HttpsError('failed-precondition', 'Client ou livreur introuvable sur la commande');
    }
    const clientRef = db.collection('clients').doc(order.clientId);
    const clientSnap = await tx.get(clientRef);
    const driverState = await readDriverState(tx, db, order.driverId, orderRef.id);
    if (!clientSnap.exists || !driverState.exists) {
      throw new HttpsError('failed-precondition', 'Wallet client ou livreur introuvable : aucun mouvement effectué');
    }
    const driverPatch = terminalDriverPatch(driverState, orderRef.id, admin);
    tx.update(clientRef, { wallet: Number(clientSnap.data().wallet || 0) + plan.clientRefund });
    tx.update(driverState.ref, {
      ...driverPatch, wallet: Number(driverState.data.wallet || 0) + plan.driverCredit,
    });
    const kept = order.commissionStatus === 'charged' && Number.isSafeInteger(order.commissionAmount)
      ? order.commissionAmount : 0;
    tx.update(orderRef, {
      ...requestPatch,
      status: 'delivered',
      deliveredAt: FieldValue.serverTimestamp(),
      deliveryClosedBy: 'admin_dispute',
      disputeDecision: {
        ...decision, financialTreatment: 'partial_refund',
        clientRefund: plan.clientRefund, feeRefund: plan.feeRefund, shoppingRefund: plan.shoppingRefund,
        driverCredit: plan.driverCredit, driverReimbursement: plan.driverReimbursement, driverPay: plan.driverPay,
        commissionKept: kept,
        ...(ctx.advancedBy ? { advancedBy: ctx.advancedBy } : {}),
      },
      adminReview: { action: 'disputePartialRefund', option: data.decision, byUid: uid, atMs: nowMs, justification, statusAtClose: order.status },
    });
    if (plan.advanceUnreimbursed > 0) {
      flagDriverAdvance(tx, orderRef.id, order.driverId, plan.advanceUnreimbursed, nowMs, uid, decisionId(data.orderId, data.requestId));
    }
    return {
      financialTreatment: 'partial_refund',
      refund: {
        clientRefund: plan.clientRefund, driverCredit: plan.driverCredit, driverRefund: 0,
        driverReimbursement: plan.driverReimbursement, driverPay: plan.driverPay,
      },
      commission: { amount: kept, payerId: order.commissionPayerId || order.driverId },
    };
  }

  // Journalisation post-transaction : mouvements de wallet et commission conservée.
  async function partialPostTx(out, orderId) {
    const now = FieldValue.serverTimestamp();
    const { clientRefund, driverReimbursement = 0, driverPay = 0 } = out.refund;
    const order = (await db.collection('orders').doc(orderId).get()).data() || {};
    if (clientRefund > 0) {
      await db.collection('clients').doc(out.clientId).collection('wallet_transactions').add({
        type: 'refund', amount: clientRefund, description: 'Remboursement partiel — litige tranché par AZ Express',
        orderId, createdAt: now,
      });
    }
    // Deux écritures distinctes : le remboursement d'une avance n'est pas une rémunération.
    if (driverPay > 0 && order.driverId) {
      await db.collection('livreurs').doc(order.driverId).collection('wallet_transactions').add({
        type: 'earning', amount: driverPay, description: 'Gain livraison — litige tranché par AZ Express',
        orderId, createdAt: now,
      });
    }
    if (driverReimbursement > 0 && order.driverId) {
      await db.collection('livreurs').doc(order.driverId).collection('wallet_transactions').add({
        type: 'reimbursement', amount: driverReimbursement,
        description: 'Remboursement des achats avancés — litige tranché par AZ Express', orderId, createdAt: now,
      });
    }
    if (out.commission && out.commission.amount > 0) {
      await db.collection('commissions').add({
        orderId, driverId: out.commission.payerId, amount: out.commission.amount,
        commissionSource: 'traced_dispute_partial', deliveryFee: Number(order.budget || 0),
        paymentMethod: order.paymentMethod || '', createdAt: now,
      });
      await db.collection('config').doc('az_wallet').set({
        totalCommissions: FieldValue.increment(out.commission.amount), updatedAt: now,
      }, { merge: true });
    }
  }

  // Un vendeur éventuellement déjà payé n'est JAMAIS débité automatiquement : signalement de
  // rapprochement comptable, toute récupération est autorisée séparément.
  // Identifiant dérivé de la décision : deux décisions successives ne s'écrasent jamais, un rejeu
  // de la même décision (même requestId) retombe sur le même document.
  function flagSellerReview(tx, order, orderId, reason, nowMs, uid, decisionKey) {
    if (!isId(order.sellerId)) return;
    tx.set(db.collection('reconciliation_flags').doc(`${orderId}_seller_${decisionKey.slice(0, 16)}`), {
      orderId, type: 'seller_review', status: 'open', sellerId: order.sellerId, sellerType: order.sellerType || null,
      reason, decidedBy: uid, createdAtMs: nowMs,
    });
  }

  // Le livreur a avancé les achats, le client en a été remboursé : l'écart est signalé, jamais
  // compensé automatiquement (aucune règle de rémunération sans décision du propriétaire).
  function flagDriverAdvance(tx, orderId, driverId, amount, nowMs, uid, decisionKey) {
    tx.set(db.collection('reconciliation_flags').doc(`${orderId}_driver_advance_${decisionKey.slice(0, 16)}`), {
      orderId, type: 'driver_advance_unreimbursed', status: 'open', driverId: driverId || null, amount,
      decidedBy: uid, createdAtMs: nowMs,
    });
  }
}

module.exports = {
  buildAdminOrderDispute, paidFromWallet, planRefund, financialChecks, DECISIONS, REFUND_DECISIONS, SHOPPING_CONTEXTS,
};
