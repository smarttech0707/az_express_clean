'use strict';

const { runLifecycleTransaction } = require('./driverLifecycle');

// Règlement administratif des gains d'une course transférée (Phase 3).
//
// transfer_settlements/{orderId} est créé à la livraison (orderActions.js) en
// 'pending_review'. Seul un super-administrateur le valide, ici, côté serveur :
//   approve           wallet : crédite chaque livreur (transaction atomique,
//                     identifiants de mouvement déterministes = pas de double crédit)
//                     cash   : AUCUN mouvement de wallet ; ouvre le règlement entre
//                     livreurs ('cash_pending') avec les montants à régulariser
//   confirmCashReceipt  un livreur créancier confirme avoir reçu sa part en espèces
//   closeCash         l'administrateur clôt le règlement cash (toutes confirmations,
//                     ou dérogation justifiée)
// Une répartition corrigée (override) exige une justification et doit totaliser
// EXACTEMENT le prix payé. Chaque décision est conservée (decisions[] + audit).

const ACTIONS = Object.freeze(['approve', 'confirmCashReceipt', 'closeCash']);
const MIN_JUSTIFICATION = 10;

const isId = (v) => typeof v === 'string' && v.length > 0 && v.length <= 160 && !v.includes('/');

function validateCredits(raw, settlement) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error('Répartition invalide');
  }
  const out = {};
  let sum = 0;
  for (const [driverId, amount] of Object.entries(raw)) {
    if (!settlement.driverIds.includes(driverId)) throw new Error(`Livreur étranger à la course : ${driverId}`);
    if (!Number.isSafeInteger(amount) || amount < 0) throw new Error('Montant invalide');
    out[driverId] = amount;
    sum += amount;
  }
  if (sum !== settlement.totalPaid) {
    throw new Error(`La somme (${sum}) doit être égale au prix payé (${settlement.totalPaid})`);
  }
  return out;
}

function buildSettleTransferEarnings({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin,
}) {
  const FieldValue = admin.firestore.FieldValue;
  return onCall(async (request) => {
    if (!request.auth?.uid || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const data = request.data || {};
    if (!ACTIONS.includes(data.action)) throw new HttpsError('invalid-argument', 'Action invalide');
    if (!isId(data.orderId)) throw new HttpsError('invalid-argument', 'orderId invalide');
    const orderId = data.orderId;
    await checkRateLimit(uid, `settle_transfer_${data.action}`, 30, 600);
    if (data.action !== 'confirmCashReceipt') await requireSuperAdmin({ request, db });

    const sRef = db.collection('transfer_settlements').doc(orderId);
    const oRef = db.collection('orders').doc(orderId);
    const justification = typeof data.justification === 'string' ? data.justification.trim() : '';
    let result;

    await runLifecycleTransaction(db, async (tx) => {
      result = null;
      const sSnap = await tx.get(sRef);
      if (!sSnap.exists) throw new HttpsError('not-found', 'Règlement introuvable');
      const s = sSnap.data();
      // Rejeux : une décision déjà prise ne se rejoue pas (réponse idempotente).
      if ((data.action === 'approve' && ['settled', 'cash_pending'].includes(s.status)) ||
          (data.action !== 'approve' && s.status === 'settled')) {
        result = { success: true, replay: true, status: s.status };
        return;
      }
      const oSnap = await tx.get(oRef);
      const order = oSnap.exists ? oSnap.data() : null;
      if (!order || order.status !== 'delivered' || order.settlementHold !== true) {
        throw new HttpsError('failed-precondition', 'La commande n’est pas en attente de règlement');
      }
      const now = Date.now();
      const decision = (action, extra = {}) => FieldValue.arrayUnion({
        action, byUid: uid, atMs: now, ...(justification ? { justification } : {}), ...extra,
      });

      // ------------------------------------------------------------ approve
      if (data.action === 'approve') {
        if (s.status === 'settled' || s.status === 'cash_pending') {
          result = { success: true, replay: true, status: s.status };
          return;
        }
        if (s.status !== 'pending_review') throw new HttpsError('failed-precondition', 'Dossier non validable');
        let credits;
        const override = data.credits != null;
        if (override) {
          if (justification.length < MIN_JUSTIFICATION) {
            throw new HttpsError('invalid-argument', 'Une justification est obligatoire pour corriger la répartition');
          }
          try { credits = validateCredits(data.credits, s); } catch (e) { throw new HttpsError('invalid-argument', e.message); }
        } else {
          if (!s.proposal || !s.proposal.credits || s.proposal.needsReview) {
            throw new HttpsError('failed-precondition',
              'Données insuffisantes : fournissez une répartition corrigée avec justification');
          }
          try { credits = validateCredits(s.proposal.credits, s); } catch (e) { throw new HttpsError('failed-precondition', e.message); }
        }

        if (s.method === 'wallet') {
          const driverIds = Object.keys(credits).filter((id) => credits[id] > 0);
          const refs = driverIds.map((id) => db.collection('livreurs').doc(id));
          const snaps = [];
          for (const r of refs) snaps.push(await tx.get(r));
          const ledgerRefs = driverIds.map((id) => db.collection('livreurs').doc(id)
            .collection('wallet_transactions').doc(`transfer_settlement_${orderId}_${id}`));
          const ledgers = [];
          for (const r of ledgerRefs) ledgers.push(await tx.get(r));
          driverIds.forEach((id, i) => {
            if (!snaps[i].exists) throw new HttpsError('failed-precondition', `Compte livreur introuvable : ${id}`);
            if (ledgers[i].exists) throw new HttpsError('failed-precondition', 'Crédit déjà enregistré');
          });
          driverIds.forEach((id, i) => {
            const wallet = Number(snaps[i].data().wallet || 0);
            tx.update(refs[i], { wallet: wallet + credits[id] });
            tx.set(ledgerRefs[i], {
              type: 'earning', amount: credits[id], orderId,
              description: 'Gain de course partagée (transfert entre livreurs)',
              createdAt: FieldValue.serverTimestamp(),
            });
          });
          tx.update(sRef, {
            status: 'settled', finalCredits: credits, settledAtMs: now, overridden: override,
            decisions: decision(override ? 'approve_corrected' : 'approve'),
          });
          tx.update(oRef, { settlementHold: false, settlementStatus: 'settled' });
          result = { success: true, replay: false, status: 'settled', credits };
        } else {
          const holder = s.holderDriverId;
          const toRegularize = Object.entries(credits)
            .filter(([id, amount]) => id !== holder && amount > 0)
            .map(([to, amount]) => ({ from: holder, to, amount }));
          tx.update(sRef, {
            status: 'cash_pending', finalCredits: credits, overridden: override,
            cash: { ...(s.cash || {}), status: 'awaiting_transfer', holderDriverId: holder,
              entitlements: credits, toRegularize, confirmations: {}, approvedAtMs: now },
            decisions: decision(override ? 'approve_corrected' : 'approve'),
          });
          tx.update(oRef, { settlementStatus: 'cash_pending' });
          result = { success: true, replay: false, status: 'cash_pending', toRegularize };
        }
        return;
      }

      // ------------------------------------------------- confirmCashReceipt
      if (data.action === 'confirmCashReceipt') {
        if (s.method !== 'cash' || s.status !== 'cash_pending') {
          if (s.status === 'settled') { result = { success: true, replay: true }; return; }
          throw new HttpsError('failed-precondition', 'Aucun règlement cash en attente');
        }
        const due = (s.cash.toRegularize || []).find((x) => x.to === uid);
        if (!due) throw new HttpsError('permission-denied', 'Aucune somme ne vous est due sur cette course');
        if (s.cash.confirmations && s.cash.confirmations[uid]) {
          result = { success: true, replay: true };
          return;
        }
        tx.update(sRef, {
          cash: { ...s.cash, confirmations: { ...(s.cash.confirmations || {}), [uid]: { atMs: now, amount: due.amount } } },
          decisions: FieldValue.arrayUnion({ action: 'cash_receipt_confirmed', byUid: uid, atMs: now, amount: due.amount }),
        });
        result = { success: true, replay: false };
        return;
      }

      // ------------------------------------------------------------ closeCash
      if (s.status === 'settled') { result = { success: true, replay: true, status: 'settled' }; return; }
      if (s.method !== 'cash' || s.status !== 'cash_pending') {
        throw new HttpsError('failed-precondition', 'Aucun règlement cash en attente');
      }
      const missing = (s.cash.toRegularize || []).filter((x) => !(s.cash.confirmations || {})[x.to]);
      if (missing.length > 0 && justification.length < MIN_JUSTIFICATION) {
        throw new HttpsError('failed-precondition',
          'Des livreurs n’ont pas confirmé leur réception : justification administrative requise');
      }
      tx.update(sRef, {
        status: 'settled', settledAtMs: now, cash: { ...s.cash, status: 'closed' },
        decisions: decision('close_cash', { unconfirmed: missing.map((m) => m.to) }),
      });
      tx.update(oRef, { settlementHold: false, settlementStatus: 'settled' });
      result = { success: true, replay: false, status: 'settled' };
    });

    if (!result.replay) {
      await logAudit({
        userId: uid, userType: data.action === 'confirmCashReceipt' ? 'driver' : 'admin',
        action: `transfer_settlement_${data.action}`, targetId: orderId, status: 'success',
        metadata: { method: result.status, corrected: data.credits != null },
      });
    }
    return result;
  });
}

module.exports = { buildSettleTransferEarnings, validateCredits, ACTIONS };
