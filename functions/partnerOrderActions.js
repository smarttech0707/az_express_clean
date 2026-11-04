'use strict';

// partnerOrderActionCF — Missions 7B-3B-P (préparation) et 7B-3B-C (reversement cash), locale, NON déployée.
//
// Actions de PRÉPARATION d'une commande Restaurant/Boulangerie amountsVersion 2, pilotées par le partenaire propriétaire :
//   acceptPartnerOrder | startPreparation (alias acceptAndPrepare) | markReady | refusePartnerOrder
// Actions de REVERSEMENT CASH (commande v2 livrée et payée en espèces) :
//   declareCashHandover (livreur final) | confirmCashRemittance (partenaire) | disputeCashRemittance (partenaire ou
//   livreur final) | resolveCashRemittance (super-administrateur uniquement, requestId idempotent)
//
// Pourquoi côté serveur : les règles Firestore interdisent désormais toute écriture directe de sellerStatus, des
// horodatages de préparation et de cashRemittance sur une commande v2 (Mission 7B-3B-S). Ces champs conditionnent (a) le
// droit du client à être remboursé automatiquement (cancelOrderTx → ORDER_IN_PREPARATION), (b) le droit du livreur à
// récupérer la commande (règle + deliveryProofs : sellerStatus === 'ready') et (c) la preuve que le partenaire a reçu
// ses produits en espèces. Ils ne changent que par une transition validée ici, dans une transaction qui relit la commande.
//
// Machine d'états de préparation (sellerStatus), sans retour arrière :
//   absent/null/'' ──startPreparation──▶ 'preparing' ──markReady──▶ 'ready'
// `acceptPartnerOrder` ne change PAS sellerStatus : il pose seulement partnerAcceptedAtMs. Ainsi les écrans boulangerie
// existants (qui ne connaissent que null / 'preparing' / 'ready') restent compatibles jusqu'à la migration Flutter, et
// la préparation « commencée » (point de non-retour financier) n'est jamais déclenchée par une simple acceptation.
// Restaurant : « Accepter et préparer » = startPreparation, qui pose aussi partnerAcceptedAtMs.
//
// Aucune action de préparation ne touche à un prix, un frais, un solde ou au statut de livraison (status) — sauf le
// refus, qui passe exclusivement par cancelOrderTx (remboursement exact du total, commission du livreur rendue à son payeur).
//
// Reversement cash (cashRemittance, posé à la livraison par deliverOrderCF) — AUCUN mouvement de wallet dans ces actions :
//   pending ──declare──▶ declared ──confirm──▶ confirmed (reliquat > 0 : le livreur peut déclarer la suite)
//   tout état non final ──dispute──▶ disputed ──resolve (super-admin)──▶ resolved ; resolve possible aussi hors litige.
// Montants CUMULATIFS : amountHandedOver (déclaré par le livreur) et amountConfirmed (confirmé par le partenaire) ne
// dépassent jamais amountDue (= productAmount). Une déclaration du livreur n'est JAMAIS une confirmation : seule la
// confirmation intégrale du partenaire ou une régularisation administrative pose merchantCashSettled = true. Un reliquat
// n'est jamais débité automatiquement : il reste tracé (outstanding ; reconciliation_flags à la régularisation).
//
// INTERRUPTEURS (partnerOrdersConfig.js) : la CRÉATION de commandes v2 (PARTNER_ORDERS_V2=on, désactivée par défaut) est
// indépendante de leur GESTION. Cette fonction ne dépend que de PARTNER_ORDERS_V2_MANAGE, activée par défaut : arrêter les
// nouvelles commandes laisse terminer, refuser et résoudre (cash, litiges) celles qui existent. PARTNER_ORDERS_V2_MANAGE=off
// est un gel d'urgence : toutes les actions répondent alors FEATURE_DISABLED.
//
// DISPATCH : à la PREMIÈRE acceptation du partenaire (acceptPartnerOrder ou startPreparation), la commande est proposée aux
// livreurs, une seule fois (la première transition est unique car sérialisée sur le document de commande), via
// `dispatchAccepted` (partnerDispatch.js). Un échec n'affecte jamais l'acceptation : la reprise serveur prend le relais.

const { PARTNER_AMOUNTS_VERSION, PARTNER_SELLER_TYPES, readPartnerAmounts } = require('./partnerOrderAmounts');
const { PARTNER_KINDS } = require('./partnerCatalog');
const { cancelOrderTx, cancelOrderPostTx, isPickedUp } = require('./orderActions');
const { runLifecycleTransaction } = require('./driverLifecycle');
const { managementEnabled } = require('./partnerOrdersConfig');

const PREP_ACTIONS = Object.freeze(['acceptPartnerOrder', 'startPreparation', 'acceptAndPrepare', 'markReady', 'refusePartnerOrder']);
const CASH_ACTIONS = Object.freeze(['declareCashHandover', 'confirmCashRemittance', 'disputeCashRemittance', 'resolveCashRemittance']);
const ACTIONS = Object.freeze([...PREP_ACTIONS, ...CASH_ACTIONS]);
// Statuts où le partenaire peut encore agir ; tout autre statut (delivered, cancelled, picked_up, inconnu) est refusé.
const ACTIVE_STATUSES = Object.freeze(['pending', 'broadcast', 'assigned', 'accepted']);
const STARTED = Object.freeze(['preparing', 'ready']);

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });
const defaultEnabled = managementEnabled;

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// Vue normalisée d'un cashRemittance : tout dérive des montants cumulés, jamais d'un champ « outstanding » stocké.
function describeCash(c, due) {
  const confirmed = Number.isSafeInteger(c.amountConfirmed) ? c.amountConfirmed : 0;
  const resolved = c.status === 'resolved';
  const received = resolved ? c.resolution.finalAmount : confirmed;
  return {
    status: c.status, amountDue: due, amountHandedOver: c.amountHandedOver ?? null, amountConfirmed: confirmed,
    outstanding: due - received, merchantCashSettled: resolved || (c.status === 'confirmed' && confirmed >= due),
  };
}

function buildPartnerOrderAction({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission, requireSuperAdmin, now = Date.now,
  isEnabled = defaultEnabled, dispatchAccepted,
}) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    if (request.auth.token?.firebase?.sign_in_provider === 'anonymous') throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    if (!isEnabled()) return envelope(false, 'FEATURE_DISABLED', 'Fonction non activée');
    const d = request.data || {};
    if (typeof d.orderId !== 'string' || !d.orderId || d.orderId.length > 128 || d.orderId.includes('/')) {
      throw new HttpsError('invalid-argument', 'orderId manquant');
    }
    if (!ACTIONS.includes(d.action)) throw new HttpsError('invalid-argument', 'Action inconnue');
    const action = d.action === 'acceptAndPrepare' ? 'startPreparation' : d.action;
    const reason = typeof d.reason === 'string' ? d.reason.trim().slice(0, 200) : '';
    await checkRateLimit(uid, 'partner_order_action', 60, 60);
    // La résolution d'un litige cash est réservée au super-administrateur : contrôle AVANT toute lecture de commande.
    if (action === 'resolveCashRemittance') await requireSuperAdmin({ request, db });

    const orderRef = db.collection('orders').doc(d.orderId);
    let outcome;
    try {
      outcome = await runLifecycleTransaction(db, async (tx) => {
        const orderSnap = await tx.get(orderRef);
        const order = orderSnap.exists ? orderSnap.data() : null;
        if (CASH_ACTIONS.includes(action)) return applyCashAction({ tx, order, orderRef, action, uid, data: d });
        // Même réponse pour « inexistante » et « à un autre partenaire » : on ne révèle rien sur les commandes d'autrui.
        if (!order || order.sellerId !== uid || !PARTNER_SELLER_TYPES.includes(order.sellerType)) {
          throw new Refusal('ORDER_NOT_FOUND', 'Commande introuvable');
        }
        if (order.amountsVersion !== PARTNER_AMOUNTS_VERSION) {
          throw new Refusal('ORDER_NOT_PARTNER_V2', 'Cette commande ne se gère pas avec cette fonction');
        }
        const partnerSnap = await tx.get(db.collection(PARTNER_KINDS[order.sellerType].collection).doc(uid));
        if (!partnerSnap.exists || partnerSnap.data().isActive === false) {
          throw new Refusal('PARTNER_UNAVAILABLE', 'Compte partenaire indisponible');
        }
        return applyAction({ tx, order, orderRef, action, reason, uid });
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({
          userId: uid, userType: 'partner', action: `partner_order_${action}`, targetId: d.orderId,
          status: 'denied', metadata: { code: err.code },
        });
        return envelope(false, err.code, err.message);
      }
      throw err;
    }

    if (outcome.cash) {
      if (!outcome.replay) {
        await logAudit({
          userId: uid, userType: outcome.userType, action: `partner_order_${action}`, targetId: d.orderId,
          metadata: {
            status: outcome.cash.status, amountDue: outcome.cash.amountDue, amountHandedOver: outcome.cash.amountHandedOver,
            amountConfirmed: outcome.cash.amountConfirmed, outstanding: outcome.cash.outstanding, ...(outcome.audit || {}),
          },
        });
      }
      return envelope(true, null, outcome.message, { orderId: d.orderId, action, replay: outcome.replay === true, cash: outcome.cash });
    }
    if (outcome.refund && !outcome.replay) {
      await cancelOrderPostTx(db, admin, { orderId: d.orderId, uid: outcome.clientId, ...outcome.refund });
    }
    if (!outcome.replay) {
      await logAudit({
        userId: uid, userType: outcome.sellerType, action: `partner_order_${action}`, targetId: d.orderId,
        metadata: { sellerStatus: outcome.sellerStatus, ...(outcome.refund ? { clientRefund: outcome.refund.clientRefund, driverRefund: outcome.refund.driverRefund } : {}) },
      });
    }
    // Première acceptation seulement : proposer la commande aux livreurs (jamais bloquant pour le partenaire).
    let dispatch;
    if (outcome.dispatchNow && !outcome.replay && typeof dispatchAccepted === 'function') {
      dispatch = await Promise.resolve(dispatchAccepted(d.orderId)).catch(() => ({ dispatched: false, mode: 'error' }));
    }
    return envelope(true, null, outcome.message, {
      orderId: d.orderId, action, sellerStatus: outcome.sellerStatus, replay: outcome.replay === true,
      ...(dispatch ? { dispatch: { dispatched: dispatch.dispatched === true, mode: dispatch.mode } } : {}),
      ...(outcome.refund ? { refund: { clientRefund: outcome.refund.clientRefund, driverRefund: outcome.refund.driverRefund } } : {}),
    });
  });

  // ── Reversement cash ────────────────────────────────────────────────────────────────────────────────────────
  // Une seule transaction sur le document de commande : déclaration, confirmation, litige et résolution simultanés se
  // sérialisent, chacun relit l'état écrit par le précédent. Aucune écriture de wallet.
  async function applyCashAction({ tx, order, orderRef, action, uid, data }) {
    const nowMs = now();
    if (!order) throw new Refusal('ORDER_NOT_FOUND', 'Commande introuvable');
    const isPartner = order.sellerId === uid && PARTNER_SELLER_TYPES.includes(order.sellerType);
    // Livreur FINAL : celui qui détient la commande à la livraison (après transfert, le dernier), jamais un ancien livreur.
    const isDriver = typeof order.driverId === 'string' && order.driverId === uid;
    const permitted = {
      declareCashHandover: isDriver,
      confirmCashRemittance: isPartner,
      disputeCashRemittance: isPartner || isDriver,
      resolveCashRemittance: true, // super-administrateur déjà vérifié
    }[action];
    // Même réponse pour « inexistante » et « à un autre » : rien n'est révélé sur les commandes d'autrui.
    if (!permitted) throw new Refusal('ORDER_NOT_FOUND', 'Commande introuvable');
    if (order.amountsVersion !== PARTNER_AMOUNTS_VERSION) {
      throw new Refusal('ORDER_NOT_PARTNER_V2', 'Cette commande ne se gère pas avec cette fonction');
    }
    if (action !== 'resolveCashRemittance') {
      const actorRef = isPartner
        ? db.collection(PARTNER_KINDS[order.sellerType].collection).doc(uid)
        : db.collection('livreurs').doc(uid);
      const actor = await tx.get(actorRef);
      if (!actor.exists || actor.data().isActive === false) throw new Refusal('ACTOR_UNAVAILABLE', 'Compte indisponible');
    }
    if (order.status !== 'delivered') throw new Refusal('CASH_ORDER_NOT_DELIVERED', 'La commande n’est pas livrée');
    if (order.paymentMethod !== 'cash') throw new Refusal('CASH_ORDER_NOT_CASH', 'La commande n’a pas été payée en espèces');
    const amounts = readPartnerAmounts(order);
    if (!amounts) throw new Refusal('ORDER_AMOUNTS_INCONSISTENT', 'Montants de la commande incohérents : contactez le support AZ Express');
    const r = order.cashRemittance;
    if (!r || typeof r !== 'object' || r.amountDue !== amounts.productAmount || r.partnerId !== order.sellerId) {
      throw new Refusal('CASH_REMITTANCE_INVALID', 'Suivi du reversement absent ou incohérent');
    }
    const due = amounts.productAmount;
    const confirmedSoFar = Number.isSafeInteger(r.amountConfirmed) ? r.amountConfirmed : 0;
    const resolved = r.status === 'resolved';
    const fullyConfirmed = r.status === 'confirmed' && confirmedSoFar >= due;
    const replay = (message) => ({ replay: true, message, cash: describeCash(r, due), userType: 'none' });
    const amountOf = () => {
      if (!Number.isSafeInteger(data.amount) || data.amount <= 0) throw new Refusal('INVALID_AMOUNT', 'Montant invalide');
      if (data.amount > due) throw new Refusal('AMOUNT_EXCEEDS_DUE', 'Le montant dépasse le montant dû au partenaire');
      return data.amount;
    };
    const write = (patch, extra = {}) => {
      const next = { ...r, ...patch };
      const view = describeCash(next, due);
      next.outstanding = view.outstanding;
      tx.update(orderRef, { cashRemittance: next, ...(view.merchantCashSettled ? { merchantCashSettled: true } : {}), ...extra });
      return { cash: view };
    };

    if (action === 'declareCashHandover') {
      if (resolved || fullyConfirmed) throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà clos');
      if (r.status === 'disputed') throw new Refusal('CASH_DISPUTED', 'Reversement contesté : décision de l’administrateur attendue');
      const amount = amountOf();
      if (r.status === 'declared' && r.amountHandedOver === amount) return replay('Remise déjà déclarée');
      if (amount <= confirmedSoFar) throw new Refusal('INVALID_AMOUNT', 'La déclaration doit dépasser le montant déjà confirmé par le partenaire');
      return {
        ...write({ status: 'declared', amountHandedOver: amount, handedOverAtMs: nowMs, handedOverBy: uid }),
        userType: 'driver', message: 'Remise déclarée : en attente de confirmation du partenaire',
      };
    }

    if (action === 'confirmCashRemittance') {
      if (resolved) throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà clos');
      if (r.status === 'disputed') throw new Refusal('CASH_DISPUTED', 'Reversement contesté : décision de l’administrateur attendue');
      const amount = amountOf();
      if (r.status === 'confirmed' && confirmedSoFar === amount) return replay('Réception déjà confirmée');
      if (fullyConfirmed) throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà confirmé en totalité');
      if (amount < confirmedSoFar) throw new Refusal('INVALID_AMOUNT', 'Le montant ne peut pas être inférieur à celui déjà confirmé');
      const complete = amount === due;
      return {
        ...write({
          status: 'confirmed', amountConfirmed: amount, partnerConfirmedAtMs: nowMs, confirmedBy: uid,
          ...(complete ? { settledAtMs: nowMs } : {}),
        }),
        userType: 'partner', message: complete ? 'Réception confirmée en totalité' : 'Réception partielle confirmée : le reliquat reste dû',
      };
    }

    if (action === 'disputeCashRemittance') {
      const reason = typeof data.reason === 'string' ? data.reason.trim() : '';
      if (resolved || fullyConfirmed) throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà clos');
      if (r.status === 'disputed') return replay('Reversement déjà contesté');
      if (reason.length < 10 || reason.length > 300) throw new Refusal('REASON_REQUIRED', 'Motif requis (10 à 300 caractères)');
      const byRole = isPartner ? 'partner' : 'driver';
      return {
        ...write({ status: 'disputed', dispute: { byUid: uid, byRole, reason, atMs: nowMs, previousStatus: r.status } }),
        userType: byRole, message: 'Désaccord signalé : décision de l’administrateur attendue', audit: { byRole },
      };
    }

    // resolveCashRemittance : super-administrateur, requestId idempotent, justification obligatoire.
    if (typeof data.requestId !== 'string' || data.requestId.length < 16 || data.requestId.length > 128) {
      throw new Refusal('REQUEST_ID_REQUIRED', 'requestId idempotent requis');
    }
    if (resolved) {
      if (r.resolution && r.resolution.requestId === data.requestId) return replay('Décision déjà enregistrée');
      throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà clos');
    }
    if (fullyConfirmed) throw new Refusal('CASH_ALREADY_FINAL', 'Le reversement est déjà confirmé en totalité');
    const justification = typeof data.justification === 'string' ? data.justification.trim() : '';
    if (justification.length < 10 || justification.length > 500) throw new Refusal('JUSTIFICATION_REQUIRED', 'Justification requise (10 à 500 caractères)');
    if (!Number.isSafeInteger(data.finalAmount) || data.finalAmount < 0) throw new Refusal('INVALID_AMOUNT', 'Montant invalide');
    if (data.finalAmount > due) throw new Refusal('AMOUNT_EXCEEDS_DUE', 'Le montant dépasse le montant dû au partenaire');
    const outstanding = due - data.finalAmount;
    const result = write({
      status: 'resolved',
      resolution: { finalAmount: data.finalAmount, outstanding, byUid: uid, requestId: data.requestId, justification, atMs: nowMs, previousStatus: r.status },
    });
    // Reliquat arrêté par décision : tracé pour le rapprochement, jamais débité automatiquement.
    if (outstanding > 0) {
      tx.set(db.collection('reconciliation_flags').doc(`${orderRef.id}_cash_shortfall`), {
        orderId: orderRef.id, type: 'cash_shortfall', status: 'recorded', partnerId: order.sellerId, driverId: order.driverId || null,
        amount: outstanding, owedTo: 'partner', decidedBy: uid, requestId: data.requestId, createdAtMs: nowMs,
      });
    }
    return { ...result, userType: 'admin', message: 'Reversement régularisé par décision administrative', audit: { finalAmount: data.finalAmount } };
  }

  // Toutes les lectures de `order` ont eu lieu AVANT ; cette fonction ne lit que dans cancelOrderTx (refus), qui
  // respecte lui-même « lectures avant écritures ». La transaction étant sérialisée sur le document de commande, un
  // refus et une acceptation du livreur (ou une préparation et une annulation du client) ne peuvent pas se croiser :
  // le second relit l'état écrit par le premier.
  async function applyAction({ tx, order, orderRef, action, reason, uid }) {
    const nowMs = now();
    const current = order.sellerStatus || null;
    const base = { sellerType: order.sellerType };
    const replayOf = (status, message) => ({ ...base, replay: true, sellerStatus: status, message });

    // Rejeu d'un refus déjà acté : même résultat, aucun second remboursement (la commande est annulée).
    if (action === 'refusePartnerOrder' && order.status === 'cancelled' && order.partnerRefusal) {
      return replayOf(current, 'Commande déjà refusée');
    }
    if (order.status === 'delivered' || order.status === 'cancelled') throw new Refusal('ORDER_CLOSED', 'Commande terminée ou annulée');
    if (isPickedUp(order)) throw new Refusal('ORDER_PICKED_UP', 'Commande déjà récupérée par le livreur');
    if (!ACTIVE_STATUSES.includes(order.status)) throw new Refusal('ORDER_STATUS_INVALID', 'Statut de commande inattendu');
    if (current !== null && !STARTED.includes(current)) throw new Refusal('PREPARATION_STATE_INVALID', 'État de préparation inattendu');

    if (action === 'acceptPartnerOrder') {
      if (order.partnerAcceptedAtMs || current) return replayOf(current, 'Commande déjà acceptée');
      tx.update(orderRef, { partnerAcceptedAtMs: nowMs });
      return { ...base, sellerStatus: current, message: 'Commande acceptée', dispatchNow: true };
    }

    if (action === 'startPreparation') {
      if (current === 'preparing') return replayOf(current, 'Préparation déjà commencée');
      if (current === 'ready') throw new Refusal('INVALID_TRANSITION', 'La commande est déjà prête');
      tx.update(orderRef, {
        sellerStatus: 'preparing', preparationStartedAtMs: nowMs,
        ...(order.partnerAcceptedAtMs ? {} : { partnerAcceptedAtMs: nowMs }),
      });
      return { ...base, sellerStatus: 'preparing', message: 'Préparation commencée', dispatchNow: !order.partnerAcceptedAtMs };
    }

    if (action === 'markReady') {
      if (current === 'ready') return replayOf(current, 'Commande déjà prête');
      if (current !== 'preparing') throw new Refusal('INVALID_TRANSITION', 'La préparation doit d’abord être commencée');
      tx.update(orderRef, { sellerStatus: 'ready', readyAtMs: nowMs });
      return { ...base, sellerStatus: 'ready', message: 'Commande prête' };
    }

    // refusePartnerOrder : uniquement avant le début de la préparation (cancelOrderTx le revérifie, défense en profondeur).
    if (current) throw new Refusal('PREPARATION_STARTED', 'La préparation est commencée : contactez le support AZ Express');
    if (typeof order.clientId !== 'string' || !order.clientId || order.clientId.includes('/')) {
      throw new Refusal('ORDER_STATUS_INVALID', 'Commande invalide');
    }
    let refund;
    try {
      refund = await cancelOrderTx(tx, {
        db, admin, orderRef, order, uid: order.clientId, calculateCommission, reason: 'partner_refused',
      });
    } catch (err) {
      const mapped = {
        ORDER_NOT_CANCELLABLE: ['ORDER_CLOSED', 'Commande terminée ou annulée'],
        ORDER_PICKED_UP: ['ORDER_PICKED_UP', 'Commande déjà récupérée par le livreur'],
        ORDER_IN_PREPARATION: ['PREPARATION_STARTED', 'La préparation est commencée : contactez le support AZ Express'],
        ORDER_AMOUNTS_INCONSISTENT: ['ORDER_AMOUNTS_INCONSISTENT', 'Montants de la commande incohérents : contactez le support AZ Express'],
      }[err.message];
      if (mapped) throw new Refusal(mapped[0], mapped[1]);
      throw err;
    }
    tx.update(orderRef, { partnerRefusal: { reason, partnerId: uid, atMs: nowMs } });
    return { ...base, sellerStatus: current, clientId: order.clientId, refund, message: 'Commande refusée et remboursée' };
  }
}

module.exports = { buildPartnerOrderAction, PARTNER_ACTIONS: ACTIONS, describeCash };
