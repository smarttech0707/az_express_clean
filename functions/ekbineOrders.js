'use strict';

const crypto = require('crypto');
const { selectDepositAccount, isEligibleAgent } = require('./ekbineFlow');

// E-Kbine — création, annulation et confirmation de commande CÔTÉ SERVEUR.
//
// Avant ce module, l'application débitait le wallet (écriture client) puis écrivait la commande dans un second
// temps : aucune preuve serveur du débit, `agentEarning` fourni par le client (un client complice d'un agent
// pouvait fabriquer de l'argent), annulation directe sans remboursement. Ici :
//   - création : UNE transaction (débit + commande + preuve), montants recalculés, clé d'idempotence ;
//   - annulation : UNE transaction (statut + remboursement du montant réellement débité, une seule fois) ;
//   - confirmation : l'agent n'est crédité que du montant PROUVÉ débité (`debitedAmount`), jamais d'un champ client.
// Règles métier conservées : frais = 0, le client paie le montant exact, l'agent gagne `amount` (wallet).
// Paiements hors wallet : AZ ne détient aucun fonds → aucun mouvement de wallet, aucun crédit agent (voir docs).

const MAX_EK_AMOUNT = 1000000;
const KEY_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const OPERATORS = Object.freeze(['orange', 'mtn', 'moov', 'wave']);
const PAYMENT_METHODS = Object.freeze(['wallet', 'orange_money', 'mtn_momo', 'wave', 'cash']);
// Miroir de `ekServices` (lib/ekbine/ek_constants.dart) : montant minimal par opérateur/service.
const EK_SERVICES = Object.freeze({
  orange: { credit: 100, mix: 200, internet: 500, transfer: 500, momo_deposit: 500, momo_withdrawal: 1000 },
  mtn: { credit: 100, internet: 500, transfer: 500, momo_deposit: 500, momo_withdrawal: 1000 },
  moov: { credit: 100, internet: 500, momo_deposit: 500, momo_withdrawal: 1000 },
  wave: { transfer: 500, momo_deposit: 500, momo_withdrawal: 1000 },
});
// Annulable par le client tant que rien n'a été exécuté : avant toute preuve de dépôt.
const CANCELLABLE = Object.freeze(['pending', 'awaiting_deposit']);
// Commande wallet prépayée dont l'agent a accepté mais N'A PAS commencé : annulable tant que l'agent n'a pas appuyé
// sur « Commencer » (status passe alors à in_progress).
// DÉSACTIVÉ par défaut (décision de lancement) : activé seulement si EK_CANCEL_FROM_DEPOSIT_CONFIRMED=true dans
// functions/.env (voir docs/FINANCIAL_EKBINE_2026-11-03.md). Le code de remboursement sécurisé reste en place.
function cancelFromDepositConfirmedEnabled() {
  return process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED === 'true';
}

// Débit wallet PROUVÉ côté serveur : preuve écrite par ekCreateOrderCF / AZ IA, montant cohérent, jamais remboursé.
function provenDebit(order) {
  return order.paymentMethod === 'wallet' && order.walletDebited === true
    && Number.isSafeInteger(order.debitedAmount) && order.debitedAmount > 0 && order.debitedAmount === order.amount
    && order.refunded !== true && order.refundedAmount === undefined;
}

// Opération non commencée, de façon vérifiable : aucun démarrage, aucune preuve de service, aucun crédit agent.
function executionNotStarted(order) {
  return order.startedAt === undefined && order.proofUrl === undefined && order.agentCredited === undefined
    && order.completedAt === undefined;
}

function cancellable(order, allowFromDepositConfirmed) {
  if (CANCELLABLE.includes(order.status)) return true;
  return allowFromDepositConfirmed && order.status === 'deposit_confirmed'
    && provenDebit(order) && executionNotStarted(order);
}

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// Identifiant déterministe : un même (client, clé) retombe toujours sur la même commande.
function orderIdFor(uid, key) {
  return `ek_${crypto.createHash('sha256').update(`${uid}:${key}`).digest('hex').slice(0, 24)}`;
}

function validOrderId(id) {
  return typeof id === 'string' && id.length > 0 && id.length <= 128 && !id.includes('/') && id !== '.' && id !== '..';
}

function serviceMinAmount(operator, serviceId) {
  const svc = EK_SERVICES[operator];
  return svc && Object.prototype.hasOwnProperty.call(svc, serviceId) ? svc[serviceId] : null;
}

function assertActive(clientData, HttpsError) {
  if (clientData.deletionRequested === true || clientData.isDeleted === true) {
    throw new HttpsError('failed-precondition', 'Compte en cours de suppression');
  }
  if (clientData.isBlocked === true || clientData.isActive === false) {
    throw new HttpsError('permission-denied', 'Compte indisponible');
  }
}

function requireAuth(request, HttpsError) {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
  if (request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
    throw new HttpsError('unauthenticated', 'Authentification requise');
  }
  return request.auth.uid;
}

// ── ekCreateOrderCF ────────────────────────────────────────────────────────
function buildEkCreateOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    const uid = requireAuth(request, HttpsError);
    const d = request.data || {};
    const { idempotencyKey, operator, serviceId } = d;
    const amount = d.amount;
    const paymentMethod = d.paymentMethod ?? 'wallet';
    if (typeof idempotencyKey !== 'string' || !KEY_PATTERN.test(idempotencyKey)) {
      throw new HttpsError('invalid-argument', 'Clé d\'idempotence invalide');
    }
    if (!OPERATORS.includes(operator)) throw new HttpsError('invalid-argument', 'Opérateur invalide');
    if (!PAYMENT_METHODS.includes(paymentMethod)) throw new HttpsError('invalid-argument', 'Mode de paiement invalide');
    const minAmount = typeof serviceId === 'string' ? serviceMinAmount(operator, serviceId) : null;
    if (minAmount === null) throw new HttpsError('invalid-argument', 'Service invalide');
    if (!Number.isSafeInteger(amount) || amount < minAmount || amount > MAX_EK_AMOUNT) {
      throw new HttpsError('invalid-argument', `Montant invalide (min ${minAmount}, max ${MAX_EK_AMOUNT} FCFA)`);
    }
    const beneficiaryNumber = typeof d.beneficiaryNumber === 'string' ? d.beneficiaryNumber.trim() : '';
    if (beneficiaryNumber.length < 8 || beneficiaryNumber.length > 32) {
      throw new HttpsError('invalid-argument', 'Numéro bénéficiaire invalide');
    }
    const serviceLabel = typeof d.serviceLabel === 'string' ? d.serviceLabel.trim().slice(0, 80) : '';
    await checkRateLimit(uid, 'ek_create_order', 10, 60);

    const orderId = orderIdFor(uid, idempotencyKey);
    const orderRef = db.collection('ekbine_orders').doc(orderId);
    const clientRef = db.collection('clients').doc(uid);
    // Tout est recalculé ici : frais 0 (règle E-Kbine), le client paie `amount`, l'agent gagne `amount` si wallet.
    const fee = 0;
    const totalPaid = amount;
    const isWallet = paymentMethod === 'wallet';
    const ledgerId = `ekorder_${orderId}`;
    let outcome;

    try {
      await db.runTransaction(async (tx) => {
        const [orderSnap, clientSnap] = await Promise.all([tx.get(orderRef), tx.get(clientRef)]);
        if (orderSnap.exists) {
          const o = orderSnap.data();
          // Rejeu de la même clé : jamais de second débit. Même clé, autre contenu → refus net.
          if (o.clientId !== uid || o.amount !== amount || o.operator !== operator
            || o.serviceId !== serviceId || o.paymentMethod !== paymentMethod
            || o.beneficiaryNumber !== beneficiaryNumber) {
            throw new Refusal('IDEMPOTENCY_CONFLICT', 'Cette clé a déjà servi pour une autre commande');
          }
          outcome = { orderId, alreadyDone: true, status: o.status, walletDebited: o.walletDebited === true };
          return;
        }
        if (!clientSnap.exists) throw new Refusal('ACCOUNT_NOT_FOUND', 'Compte client introuvable');
        const client = clientSnap.data();
        assertActive(client, HttpsError);

        let balanceAfter = null;
        if (isWallet) {
          const balance = Number(client.wallet || 0);
          if (!Number.isSafeInteger(balance) || balance < 0) {
            throw new Refusal('WALLET_INVALID', 'Solde invalide : vérification manuelle requise');
          }
          if (balance < totalPaid) throw new Refusal('INSUFFICIENT_BALANCE', 'Solde insuffisant dans votre wallet');
          balanceAfter = balance - totalPaid;
          tx.update(clientRef, { wallet: balanceAfter });
          tx.set(clientRef.collection('wallet_transactions').doc(ledgerId), {
            type: 'payment', amount: -totalPaid, orderId, source: 'ekbine_order',
            description: `E-Kbine ${serviceLabel || serviceId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        // `tx.create` : jamais d'écrasement d'une commande existante.
        tx.create(orderRef, {
          clientId: uid, clientName: client.name || null, clientPhone: client.phone || null,
          operator, serviceId, serviceLabel: serviceLabel || serviceId, beneficiaryNumber,
          amount, fee, totalPaid, commissionAZ: 0,
          agentEarning: isWallet ? amount : 0,
          paymentMethod, status: 'pending', source: 'ek_create_cf', idempotencyKey,
          // Preuve de débit lue plus tard par la confirmation et l'annulation.
          walletDebited: isWallet, debitedAmount: isWallet ? totalPaid : 0,
          debitLedgerId: isWallet ? ledgerId : null,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        outcome = { orderId, alreadyDone: false, status: 'pending', walletDebited: isWallet, balanceAfter };
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({ userId: uid, userType: 'client', action: 'ek_create_order', targetId: orderId,
          status: 'refused', metadata: { code: err.code } });
        return envelope(false, err.code, err.message);
      }
      throw err;
    }
    if (!outcome.alreadyDone) {
      await logAudit({ userId: uid, userType: 'client', action: 'ek_create_order', targetId: orderId,
        amount: totalPaid, status: 'success',
        metadata: { paymentMethod, operator, serviceId, walletDebited: outcome.walletDebited, balanceAfter: outcome.balanceAfter } });
    }
    return envelope(true, null, outcome.alreadyDone ? 'Commande déjà créée' : 'Commande créée',
      { orderId, alreadyDone: outcome.alreadyDone, status: outcome.status, walletDebited: outcome.walletDebited });
  });
}

// ── ekCancelOrderCF ────────────────────────────────────────────────────────
// allowCancelFromDepositConfirmed : forcé par les tests ; sinon lu à chaque appel depuis l'environnement (défaut : non).
function buildEkCancelOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, allowCancelFromDepositConfirmed }) {
  return onCall(async (request) => {
    const uid = requireAuth(request, HttpsError);
    const { orderId, reason } = request.data || {};
    if (!validOrderId(orderId)) throw new HttpsError('invalid-argument', 'Commande invalide');
    if (reason !== undefined && reason !== null && (typeof reason !== 'string' || reason.length > 300)) {
      throw new HttpsError('invalid-argument', 'Motif invalide');
    }
    await checkRateLimit(uid, 'ek_cancel_order', 10, 60);

    const orderRef = db.collection('ekbine_orders').doc(orderId);
    const clientRef = db.collection('clients').doc(uid);
    const refundLedgerId = `ekrefund_${orderId}`;
    let outcome;

    try {
      await db.runTransaction(async (tx) => {
        const [orderSnap, clientSnap] = await Promise.all([tx.get(orderRef), tx.get(clientRef)]);
        if (!orderSnap.exists) throw new Refusal('ORDER_NOT_FOUND', 'Commande introuvable');
        const o = orderSnap.data();
        if (o.clientId !== uid) throw new HttpsError('permission-denied', 'Non autorisé');
        if (o.status === 'cancelled') { outcome = { alreadyDone: true, refunded: o.refundedAmount || 0 }; return; }
        const allowDc = allowCancelFromDepositConfirmed ?? cancelFromDepositConfirmedEnabled();
        if (!cancellable(o, allowDc)) {
          throw new Refusal('ORDER_NOT_CANCELLABLE', 'Cette commande est déjà en cours d\'exécution et ne peut plus être annulée');
        }
        // Remboursement : uniquement ce que le serveur a prouvé avoir débité, une seule fois.
        const proven = provenDebit(o);
        let refund = 0;
        let balanceAfter = null;
        if (proven) {
          if (!clientSnap.exists) throw new Refusal('ACCOUNT_NOT_FOUND', 'Compte client introuvable');
          refund = o.debitedAmount;
          const balance = Number(clientSnap.data().wallet || 0);
          if (!Number.isSafeInteger(balance) || balance < 0) {
            throw new Refusal('WALLET_INVALID', 'Solde invalide : vérification manuelle requise');
          }
          balanceAfter = balance + refund;
          tx.update(clientRef, { wallet: balanceAfter });
          tx.set(clientRef.collection('wallet_transactions').doc(refundLedgerId), {
            type: 'refund', amount: refund, orderId, source: 'ekbine_cancel',
            description: 'Remboursement E-Kbine (annulation)',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        tx.update(orderRef, {
          status: 'cancelled', cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
          cancelledBy: uid, cancellationReason: typeof reason === 'string' && reason.trim() ? reason.trim() : 'Annulée par le client',
          refunded: proven, refundedAmount: refund,
        });
        outcome = { alreadyDone: false, refunded: refund, balanceAfter, unprovenWallet: o.paymentMethod === 'wallet' && !proven };
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({ userId: uid, userType: 'client', action: 'ek_cancel_order', targetId: orderId,
          status: 'refused', metadata: { code: err.code } });
        return envelope(false, err.code, err.message);
      }
      throw err;
    }
    if (!outcome.alreadyDone) {
      await logAudit({ userId: uid, userType: 'client', action: 'ek_cancel_order', targetId: orderId,
        amount: outcome.refunded, status: 'success',
        metadata: { balanceAfter: outcome.balanceAfter, unprovenWallet: outcome.unprovenWallet === true } });
      // Commande wallet historique sans preuve de débit : aucun remboursement automatique → revue humaine.
      if (outcome.unprovenWallet) {
        await db.collection('reconciliation_flags').doc(`ekcancel_${orderId}`).set({
          kind: 'ekbine_cancel_unproven_debit', orderId, clientId: uid, status: 'open',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
    return envelope(true, null, outcome.alreadyDone ? 'Commande déjà annulée' : 'Commande annulée',
      { orderId, alreadyDone: outcome.alreadyDone, refunded: outcome.refunded, reviewRequired: outcome.unprovenWallet === true });
  });
}

// ── ekClientConfirmOrder (durci) ───────────────────────────────────────────
// Montant crédité à l'agent : dérivé de la PREUVE de débit, jamais de `agentEarning` (champ modifiable côté client).
function creditFor(order) {
  if (order.paymentMethod !== 'wallet') return { credit: 0, reason: 'non_wallet' };
  return provenDebit(order) ? { credit: order.debitedAmount, reason: 'proven' } : { credit: 0, reason: 'unproven_debit' };
}

function buildEkClientConfirmOrder({ db, admin, onCall, HttpsError, checkRateLimit }) {
  return onCall(async (request) => {
    const uid = requireAuth(request, HttpsError);
    const { orderId } = request.data || {};
    if (!validOrderId(orderId)) throw new HttpsError('invalid-argument', 'orderId manquant');
    await checkRateLimit(uid, 'ek_confirm_order', 20, 60);

    const orderRef = db.collection('ekbine_orders').doc(orderId);
    let outcome;
    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();
      if (order.clientId !== uid) throw new HttpsError('permission-denied', 'Non autorisé');
      if (order.status === 'completed' && order.agentCredited !== undefined) { outcome = { alreadyDone: true }; return; }
      if (order.status !== 'proof_sent') throw new HttpsError('failed-precondition', 'Statut invalide');
      const agentId = order.agentId;
      if (typeof agentId !== 'string' || !agentId || agentId.includes('/')) {
        throw new HttpsError('invalid-argument', 'Données commande invalides');
      }
      const { credit, reason } = creditFor(order);
      const agRef = db.collection('ekbine_agents').doc(agentId);
      const agentSnap = await tx.get(agRef);
      if (!agentSnap.exists) throw new HttpsError('not-found', 'Agent introuvable');

      tx.update(orderRef, {
        status: 'completed', completedAt: admin.firestore.FieldValue.serverTimestamp(),
        agentCredited: credit, creditReason: reason,
      });
      const agentUpdate = { totalCompleted: admin.firestore.FieldValue.increment(1), lastOrderId: orderId };
      if (credit > 0) agentUpdate.walletBalance = admin.firestore.FieldValue.increment(credit);
      tx.update(agRef, agentUpdate);
      if (reason === 'unproven_debit') {
        tx.set(db.collection('reconciliation_flags').doc(`ekconfirm_${orderId}`), {
          kind: 'ekbine_confirm_unproven_debit', orderId, clientId: uid, agentId, amount: order.amount ?? null,
          status: 'open', createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      tx.set(db.collection('audit_logs').doc(), {
        userId: uid, userType: 'client', action: 'ekbine_confirm_order', targetId: orderId,
        amount: credit, agentId, status: 'success', creditReason: reason,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      outcome = { alreadyDone: false, credit, reason };
    });
    // settlement : wallet_credit = débit AZ prouvé ; declarative_no_credit = paiement hors wallet, simple déclaration
    // (aucune preuve de fournisseur, aucun crédit) ; withheld_unproven = commande historique sans preuve.
    const settlement = outcome.reason === 'proven' ? 'wallet_credit'
      : outcome.reason === 'non_wallet' ? 'declarative_no_credit' : outcome.reason === 'unproven_debit' ? 'withheld_unproven' : null;
    return { success: true, alreadyDone: outcome.alreadyDone, credited: outcome.credit || 0, settlement, reviewRequired: outcome.reason === 'unproven_debit' };
  });
}

// ── ekbineAcceptOrder ──────────────────────────────────────────────────────
// Acceptation par un agent. Commande wallet à débit PROUVÉ : le client a déjà payé via AZ, aucun dépôt ne lui est
// demandé → directement 'deposit_confirmed' (l'agent peut commencer). Tout autre cas (hors wallet, commande
// historique sans preuve) : parcours de dépôt inchangé ('awaiting_deposit'). Aucun crédit, aucun débit ici.
function buildEkbineAcceptOrder({ db, admin, onCall, HttpsError }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
    const orderId = request.data?.orderId;
    if (typeof orderId !== 'string') throw new HttpsError('invalid-argument', 'orderId manquant');
    const agentId = request.auth.uid;
    const orderRef = db.collection('ekbine_orders').doc(orderId);
    const agentRef = db.collection('ekbine_agents').doc(agentId);
    let nextStatus;
    await db.runTransaction(async (tx) => {
      const [orderSnap, agentSnap] = await Promise.all([tx.get(orderRef), tx.get(agentRef)]);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      if (!agentSnap.exists) throw new HttpsError('permission-denied', 'Agent introuvable');
      const order = orderSnap.data();
      const agent = agentSnap.data();
      if (order.status !== 'pending') throw new HttpsError('failed-precondition', 'Commande non disponible');
      if (!isEligibleAgent(agent)) throw new HttpsError('permission-denied', 'Agent non éligible');
      const common = {
        agentId,
        agentName: String(agent.name || 'Agent E-Kbine'),
        agentPhone: String(agent.phone || ''),
        assignedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (provenDebit(order)) {
        nextStatus = 'deposit_confirmed';
        tx.update(orderRef, { ...common, status: nextStatus, depositConfirmedAt: admin.firestore.FieldValue.serverTimestamp() });
        return;
      }
      const depositAccount = selectDepositAccount(agent, order.operator);
      if (!depositAccount) throw new HttpsError('failed-precondition', 'Aucun numéro valide pour cet opérateur');
      nextStatus = 'awaiting_deposit';
      tx.update(orderRef, {
        ...common,
        // Instantanés immuables : les consignes ne changent pas si l'agent modifie son profil.
        agentDepositAccountId: depositAccount.id,
        agentDepositNumber: depositAccount.phoneNumber,
        agentDepositOperator: order.operator,
        status: nextStatus,
      });
    });
    return { success: true, status: nextStatus };
  });
}

module.exports = {
  buildEkbineAcceptOrder, provenDebit, executionNotStarted, cancelFromDepositConfirmedEnabled,
  buildEkCreateOrder, buildEkCancelOrder, buildEkClientConfirmOrder, creditFor, orderIdFor,
  EK_SERVICES, MAX_EK_AMOUNT, CANCELLABLE,
};
