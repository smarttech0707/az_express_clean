'use strict';

// partnerOrderActionCF — Mission 7B-3B-P, locale, NON déployée.
//
// Actions de PRÉPARATION d'une commande Restaurant/Boulangerie amountsVersion 2, pilotées par le partenaire propriétaire :
//   acceptPartnerOrder | startPreparation (alias acceptAndPrepare) | markReady | refusePartnerOrder
//
// Pourquoi côté serveur : les règles Firestore interdisent désormais toute écriture directe de sellerStatus et des
// horodatages de préparation sur une commande v2 (Mission 7B-3B-S). Ces champs conditionnent (a) le droit du client à
// être remboursé automatiquement (cancelOrderTx → ORDER_IN_PREPARATION) et (b) le droit du livreur à récupérer la
// commande (règle + deliveryProofs : sellerStatus === 'ready'). Ils ne doivent donc changer que par une transition
// validée ici, dans une transaction qui relit la commande.
//
// Machine d'états de préparation (sellerStatus), sans retour arrière :
//   absent/null/'' ──startPreparation──▶ 'preparing' ──markReady──▶ 'ready'
// `acceptPartnerOrder` ne change PAS sellerStatus : il pose seulement partnerAcceptedAtMs. Ainsi les écrans boulangerie
// existants (qui ne connaissent que null / 'preparing' / 'ready') restent compatibles jusqu'à la migration Flutter, et
// la préparation « commencée » (point de non-retour financier) n'est jamais déclenchée par une simple acceptation.
// Restaurant : « Accepter et préparer » = startPreparation, qui pose aussi partnerAcceptedAtMs.
//
// Aucune action ne touche à un prix, un frais, un solde ou au statut de livraison (status) — sauf le refus, qui passe
// exclusivement par cancelOrderTx (remboursement exact du total, commission du livreur rendue à son payeur).
//
// PAS d'interrupteur PARTNER_ORDERS_V2 ici, volontairement : si l'interrupteur est coupé alors que des commandes v2 sont
// en cours, le partenaire doit pouvoir les préparer ou les refuser. Sans commande v2 (état par défaut), la fonction ne
// trouve rien à traiter.

const { PARTNER_AMOUNTS_VERSION, PARTNER_SELLER_TYPES } = require('./partnerOrderAmounts');
const { PARTNER_KINDS } = require('./partnerCatalog');
const { cancelOrderTx, cancelOrderPostTx, isPickedUp } = require('./orderActions');
const { runLifecycleTransaction } = require('./driverLifecycle');

const ACTIONS = Object.freeze(['acceptPartnerOrder', 'startPreparation', 'acceptAndPrepare', 'markReady', 'refusePartnerOrder']);
// Statuts où le partenaire peut encore agir ; tout autre statut (delivered, cancelled, picked_up, inconnu) est refusé.
const ACTIVE_STATUSES = Object.freeze(['pending', 'broadcast', 'assigned', 'accepted']);
const STARTED = Object.freeze(['preparing', 'ready']);

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function buildPartnerOrderAction({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission, now = Date.now }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    if (request.auth.token?.firebase?.sign_in_provider === 'anonymous') throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const d = request.data || {};
    if (typeof d.orderId !== 'string' || !d.orderId || d.orderId.length > 128 || d.orderId.includes('/')) {
      throw new HttpsError('invalid-argument', 'orderId manquant');
    }
    if (!ACTIONS.includes(d.action)) throw new HttpsError('invalid-argument', 'Action inconnue');
    const action = d.action === 'acceptAndPrepare' ? 'startPreparation' : d.action;
    const reason = typeof d.reason === 'string' ? d.reason.trim().slice(0, 200) : '';
    await checkRateLimit(uid, 'partner_order_action', 60, 60);

    const orderRef = db.collection('orders').doc(d.orderId);
    let outcome;
    try {
      outcome = await runLifecycleTransaction(db, async (tx) => {
        const orderSnap = await tx.get(orderRef);
        const order = orderSnap.exists ? orderSnap.data() : null;
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

    if (outcome.refund && !outcome.replay) {
      await cancelOrderPostTx(db, admin, { orderId: d.orderId, uid: outcome.clientId, ...outcome.refund });
    }
    if (!outcome.replay) {
      await logAudit({
        userId: uid, userType: outcome.sellerType, action: `partner_order_${action}`, targetId: d.orderId,
        metadata: { sellerStatus: outcome.sellerStatus, ...(outcome.refund ? { clientRefund: outcome.refund.clientRefund, driverRefund: outcome.refund.driverRefund } : {}) },
      });
    }
    return envelope(true, null, outcome.message, {
      orderId: d.orderId, action, sellerStatus: outcome.sellerStatus, replay: outcome.replay === true,
      ...(outcome.refund ? { refund: { clientRefund: outcome.refund.clientRefund, driverRefund: outcome.refund.driverRefund } } : {}),
    });
  });

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
      return { ...base, sellerStatus: current, message: 'Commande acceptée' };
    }

    if (action === 'startPreparation') {
      if (current === 'preparing') return replayOf(current, 'Préparation déjà commencée');
      if (current === 'ready') throw new Refusal('INVALID_TRANSITION', 'La commande est déjà prête');
      tx.update(orderRef, {
        sellerStatus: 'preparing', preparationStartedAtMs: nowMs,
        ...(order.partnerAcceptedAtMs ? {} : { partnerAcceptedAtMs: nowMs }),
      });
      return { ...base, sellerStatus: 'preparing', message: 'Préparation commencée' };
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

module.exports = { buildPartnerOrderAction, PARTNER_ACTIONS: ACTIONS };
