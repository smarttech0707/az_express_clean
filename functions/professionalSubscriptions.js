'use strict';

const crypto = require('crypto');
const { HttpsError } = require('firebase-functions/v2/https');

const COLLECTIONS = new Set([
  'sellers', 'restaurants', 'boulangeries', 'ekbine_agents', 'fleet_owners',
]);
const STANDARD_PRICES = Object.freeze({
  sellers: 1000,
  restaurants: 1000,
  boulangeries: 1000,
  ekbine_agents: 500,
  fleet_owners: 1000,
});
const VIP_PRICE = 2000;
const WALLET_FIELDS = Object.freeze({ ekbine_agents: 'walletBalance' });
const MONTH_MS = 30 * 24 * 60 * 60 * 1000;
const TRIAL_MS = 60 * 24 * 60 * 60 * 1000;
const ADMIN_ACTIONS = new Set([
  'activateStandard', 'activateVip', 'deactivateVip', 'suspend', 'activateTrial',
]);

function operationId(parts) {
  return crypto.createHash('sha256').update(parts.join('|')).digest('hex');
}

function millis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return null;
}

function buildManageProfessionalSubscription({ db, auth, timestamp, fieldValue }) {
  return async (request) => {
    if (!request.auth || request.auth.token.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Compte authentifie requis');
    }
    const data = request.data || {};
    const collection = String(data.collection || '');
    const docId = String(data.docId || '');
    const action = String(data.action || 'renew');
    if (!COLLECTIONS.has(collection) || !docId ||
        !new Set(['renew', ...ADMIN_ACTIONS]).has(action)) {
      throw new HttpsError('invalid-argument', 'Action ou compte invalide');
    }

    const adminSnap = await db.collection('admins').doc(request.auth.uid).get();
    const isAdmin = adminSnap.exists && adminSnap.data()?.isActive !== false;
    if (ADMIN_ACTIONS.has(action) && !isAdmin) {
      throw new HttpsError('permission-denied', 'Administrateur requis');
    }
    if (action === 'renew' && !isAdmin) {
      if (collection === 'restaurants') {
        const owner = await db.collection('restaurant_owners').doc(request.auth.uid).get();
        if (!owner.exists || owner.data()?.restaurantId !== docId) {
          throw new HttpsError('permission-denied', 'Restaurant non autorise');
        }
      } else if (docId !== request.auth.uid) {
        throw new HttpsError('permission-denied', 'Compte non autorise');
      }
    }
    if (ADMIN_ACTIONS.has(action) &&
        (typeof data.requestId !== 'string' || data.requestId.length < 16 || data.requestId.length > 128)) {
      throw new HttpsError('invalid-argument', 'requestId idempotent requis');
    }

    const accountRef = db.collection(collection).doc(docId);
    const nowMs = Date.now();
    const result = await db.runTransaction(async (tx) => {
      const accountSnap = await tx.get(accountRef);
      if (!accountSnap.exists) throw new HttpsError('not-found', 'Compte introuvable');
      const account = accountSnap.data();
      const walletField = WALLET_FIELDS[collection] || 'wallet';

      if (action === 'renew') {
        const standardDue = millis(account.subscriptionExpiresAt) == null ||
          millis(account.subscriptionExpiresAt) <= nowMs;
        const vipDue = account.vipStatus === 'active' &&
          (millis(account.vipExpiresAt) == null || millis(account.vipExpiresAt) <= nowMs);
        if (!standardDue && !vipDue) {
          return {
            success: true, outcome: 'unchanged', chargedAmount: 0,
            walletBalance: Number(account[walletField] || 0), idempotent: false,
          };
        }
      }

      const cycle = action === 'renew'
        ? `${millis(account.subscriptionExpiresAt) || 0}_`
          + `${millis(account.vipExpiresAt) || 0}_${account[walletField] || 0}_`
          + `${account.subscriptionStatus || ''}_${account.vipStatus || ''}`
        : data.requestId;
      const opId = operationId([request.auth.uid, collection, docId, action, cycle]);
      const opRef = db.collection('subscription_operations').doc(opId);
      const prior = await tx.get(opRef);
      if (prior.exists) return { ...prior.data().result, idempotent: true };

      const updates = {};
      const walletWrites = [];
      let wallet = Number(account[walletField] || 0);
      let charged = 0;
      let outcome = 'unchanged';

      const debit = (amount, type, description) => {
        if (!Number.isSafeInteger(wallet) || wallet < amount) return false;
        wallet -= amount;
        charged += amount;
        walletWrites.push({ amount, type, description });
        return true;
      };

      if (action === 'renew') {
        const subExpiry = millis(account.subscriptionExpiresAt);
        const standardDue = subExpiry == null || subExpiry <= nowMs;
        if (standardDue) {
          const amount = STANDARD_PRICES[collection];
          if (debit(amount, 'subscription', `Abonnement mensuel AZ Express (${amount} FCFA)`)) {
            updates.subscriptionStatus = 'active';
            updates.subscriptionExpiresAt = timestamp.fromMillis(nowMs + MONTH_MS);
            outcome = 'renewed';
          } else {
            updates.subscriptionStatus = 'suspended';
            outcome = 'insufficient_funds';
          }
        }
        const vipExpiry = millis(account.vipExpiresAt);
        if (account.vipStatus === 'active' && (vipExpiry == null || vipExpiry <= nowMs)) {
          if (debit(VIP_PRICE, 'vip_subscription', 'Abonnement VIP mensuel AZ Express')) {
            updates.vipStatus = 'active';
            updates.vipExpiresAt = timestamp.fromMillis(nowMs + MONTH_MS);
            outcome = outcome === 'renewed' ? 'renewed_standard_and_vip' : 'renewed_vip';
          } else {
            updates.vipStatus = 'expired';
            if (outcome === 'unchanged') outcome = 'insufficient_funds';
          }
        }
      } else if (action === 'activateStandard') {
        if (data.chargeWallet === true &&
            !debit(STANDARD_PRICES[collection], 'subscription', 'Abonnement mensuel - encaissement admin')) {
          throw new HttpsError('failed-precondition', 'SOLDE_INSUFFISANT');
        }
        updates.subscriptionStatus = 'active';
        updates.subscriptionExpiresAt = timestamp.fromMillis(nowMs + MONTH_MS);
        outcome = 'activated';
      } else if (action === 'activateVip') {
        if (data.chargeWallet === true &&
            !debit(VIP_PRICE, 'vip_subscription', 'Abonnement VIP - encaissement admin')) {
          throw new HttpsError('failed-precondition', 'SOLDE_INSUFFISANT');
        }
        updates.vipStatus = 'active';
        updates.vipExpiresAt = timestamp.fromMillis(nowMs + MONTH_MS);
        updates.vipStartedAt = fieldValue.serverTimestamp();
        outcome = 'vip_activated';
      } else if (action === 'deactivateVip') {
        updates.vipStatus = 'none';
        updates.vipExpiresAt = null;
        outcome = 'vip_deactivated';
      } else if (action === 'suspend') {
        updates.subscriptionStatus = 'suspended';
        outcome = 'suspended';
      } else if (action === 'activateTrial') {
        updates.subscriptionStatus = 'trial';
        updates.subscriptionExpiresAt = timestamp.fromMillis(nowMs + TRIAL_MS);
        outcome = 'trial_activated';
      }

      if (charged > 0) updates[walletField] = wallet;
      if (Object.keys(updates).length > 0) tx.update(accountRef, updates);
      for (let i = 0; i < walletWrites.length; i++) {
        const entry = walletWrites[i];
        tx.set(accountRef.collection('wallet_transactions').doc(`${opId}_${i}`), {
          type: entry.type,
          amount: entry.amount,
          description: entry.description,
          operationId: opId,
          createdAt: fieldValue.serverTimestamp(),
        });
      }
      const response = {
        success: true, outcome, chargedAmount: charged,
        walletBalance: charged > 0 ? wallet : Number(account[walletField] || 0),
      };
      tx.set(opRef, {
        operationId: opId, action, collection, docId,
        actorUid: request.auth.uid, result: response,
        createdAt: fieldValue.serverTimestamp(),
      });
      tx.set(db.collection('subscription_audit_logs').doc(opId), {
        operationId: opId, action, collection, docId,
        actorUid: request.auth.uid, actorType: isAdmin ? 'admin' : 'owner',
        outcome, chargedAmount: charged, createdAt: fieldValue.serverTimestamp(),
      });
      return { ...response, idempotent: false };
    });
    return result;
  };
}

module.exports = {
  buildManageProfessionalSubscription,
  STANDARD_PRICES,
  VIP_PRICE,
};
