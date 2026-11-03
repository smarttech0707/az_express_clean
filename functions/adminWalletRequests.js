'use strict';

const { assertNewAccountActivity } = require('./accountAdmission');

// Approbation administrative des demandes de recharge et de retrait manuel.
//
// Avant ce module, l'écran admin (FirestoreService.approveRecharge / approveWithdrawal) écrivait directement
// le wallet d'un autre utilisateur depuis Flutter, dans un batch SANS lecture du statut :
//   - recharge : une double validation, ou l'approbation d'une demande déjà rejetée, créditait plusieurs fois ;
//   - retrait  : `initiateWithdrawal` a DÉJÀ débité le wallet à la création de la demande (transaction qui pose
//     `wallet: balance - amount` et crée la demande en 'processing'). Les demandes ambiguës passent en
//     'pending_manual', l'onglet « à traiter » de l'écran admin ; l'ancienne approbation débitait une seconde fois.
// Ici : une transaction relit le statut, ne crédite/ne règle qu'une fois, et l'identifiant du mouvement est
// déterministe. Montants relus de la demande (jamais fournis par l'appelant). Réservé au super-administrateur,
// comme les anciennes règles Firestore (`isAdmin()`).

const { requireSuperAdmin } = require('./adminGuards');

// Une demande de recharge est créée par le client avec un montant libre (≥ 100, règle Firestore) : l'admin
// vérifie le paiement reçu hors application. Plafond de sécurité aligné sur le retrait maximal (500 000 FCFA).
const MAX_RECHARGE_REQUEST = 500000;
const TARGET_COLLECTIONS = Object.freeze({ client: 'clients', driver: 'livreurs', seller: 'sellers' });
const MAX_NOTE = 500;

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function validRequestId(requestId) {
  return typeof requestId === 'string' && requestId.length > 0 && requestId.length <= 128
    && !requestId.includes('/') && requestId !== '.' && requestId !== '..';
}

function validNote(note) {
  return note === undefined || note === null || (typeof note === 'string' && note.length <= MAX_NOTE);
}

function buildAdminApproveRecharge({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin: guard = requireSuperAdmin,
}) {
  return onCall(async (request) => {
    const adminData = await guard({ request, db });
    const adminUid = request.auth.uid;
    const { requestId, note } = request.data || {};
    if (!validRequestId(requestId)) throw new HttpsError('invalid-argument', 'Demande invalide');
    if (!validNote(note)) throw new HttpsError('invalid-argument', 'Note invalide');
    await checkRateLimit(adminUid, 'admin_approve_recharge', 30, 60);

    const reqRef = db.collection('recharge_requests').doc(requestId);
    // Preuve vérifiable : identifiant déterministe, jamais deux lignes pour une même demande.
    const proofId = `recharge_request_${requestId}`;
    let outcome;

    try {
      await db.runTransaction(async (tx) => {
        const reqSnap = await tx.get(reqRef);
        if (!reqSnap.exists) throw new Refusal('REQUEST_NOT_FOUND', 'Demande introuvable');
        const r = reqSnap.data();
        // Le montant et la cible viennent EXCLUSIVEMENT de la demande stockée.
        const collection = TARGET_COLLECTIONS[r.userType === undefined ? 'client' : r.userType];
        if (!collection) throw new Refusal('USER_TYPE_UNSUPPORTED', 'Type de compte non pris en charge');
        // Les demandes existantes portent `userId` (écran client) ou `clientId` (ancien onglet boutique de l'admin).
        const targetId = r.userId ?? r.clientId;
        if (typeof targetId !== 'string' || !targetId || targetId.includes('/')) {
          throw new Refusal('REQUEST_INVALID', 'Demande invalide');
        }
        if (r.status === 'approved') {
          outcome = { alreadyDone: true, amount: r.creditedAmount ?? r.amount, targetId, collection };
          return;
        }
        if (r.status !== 'pending') {
          throw new Refusal('REQUEST_NOT_PENDING', 'Cette demande n\'est plus en attente');
        }
        const amount = r.amount;
        if (!Number.isSafeInteger(amount) || amount < 100) throw new Refusal('AMOUNT_INVALID', 'Montant de la demande invalide');
        if (amount > MAX_RECHARGE_REQUEST) throw new Refusal('AMOUNT_TOO_HIGH', `Plafond par recharge : ${MAX_RECHARGE_REQUEST} FCFA`);

        const targetRef = db.collection(collection).doc(targetId);
        const targetSnap = await tx.get(targetRef);
        if (!targetSnap.exists) throw new Refusal('ACCOUNT_NOT_FOUND', 'Compte à créditer introuvable');
        await assertNewAccountActivity(tx, db, HttpsError, targetId, [[collection, targetId]]);
        const wallet = Number(targetSnap.data().wallet || 0);
        if (!Number.isSafeInteger(wallet) || wallet < 0 || !Number.isSafeInteger(wallet + amount)) {
          throw new Refusal('WALLET_INVALID', 'Solde invalide : vérification manuelle requise');
        }

        tx.update(targetRef, { wallet: wallet + amount });
        tx.set(targetRef.collection('wallet_transactions').doc(proofId), {
          type: 'recharge', amount,
          description: `Recharge ${r.method === 'wave' ? 'Wave' : 'Orange Money'} — ${amount} FCFA`,
          orderId: null, source: 'admin_recharge_request', requestId, adminId: adminUid,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // `status: 'approved'` déclenche notifyClientOnRecharge (inchangé).
        tx.update(reqRef, {
          status: 'approved', approvedAt: admin.firestore.FieldValue.serverTimestamp(),
          approvedBy: adminUid, creditedAmount: amount,
        });
        outcome = { alreadyDone: false, amount, targetId, collection, balanceBefore: wallet, balanceAfter: wallet + amount };
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({
          userId: adminUid, userType: 'admin', action: 'admin_approve_recharge', targetId: requestId,
          status: 'refused', metadata: { code: err.code },
        });
        return envelope(false, err.code, err.message);
      }
      throw err;
    }

    if (!outcome.alreadyDone) {
      await logAudit({
        userId: adminUid, userType: 'admin', action: 'admin_approve_recharge', targetId: requestId,
        amount: outcome.amount, status: 'success',
        metadata: {
          account: `${outcome.collection}/${outcome.targetId}`, balanceBefore: outcome.balanceBefore,
          balanceAfter: outcome.balanceAfter, adminRole: adminData.role,
          ...(typeof note === 'string' && note.trim() ? { note: note.trim() } : {}),
        },
      });
    }
    return envelope(true, null, outcome.alreadyDone ? 'Recharge déjà approuvée' : 'Recharge créditée',
      { requestId, amount: outcome.amount, alreadyDone: outcome.alreadyDone });
  });
}

// Règlement manuel d'un retrait 'pending_manual'. Le wallet est DÉJÀ débité (initiateWithdrawal) : on ne touche
// à aucun solde, on constate seulement que l'opérateur a été payé hors application. Sens des statuts inchangé :
// 'pending_manual' → 'processed' (l'onglet « Traités » de l'écran admin).
function buildAdminApproveWithdrawal({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin: guard = requireSuperAdmin,
}) {
  return onCall(async (request) => {
    await guard({ request, db });
    const adminUid = request.auth.uid;
    const { requestId, note } = request.data || {};
    if (!validRequestId(requestId)) throw new HttpsError('invalid-argument', 'Demande invalide');
    if (!validNote(note)) throw new HttpsError('invalid-argument', 'Note invalide');
    await checkRateLimit(adminUid, 'admin_approve_withdrawal', 30, 60);

    const wdRef = db.collection('withdrawal_requests').doc(requestId);
    let outcome;
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(wdRef);
        if (!snap.exists) throw new Refusal('REQUEST_NOT_FOUND', 'Demande introuvable');
        const w = snap.data();
        if (w.status === 'processed') { outcome = { alreadyDone: true, amount: w.amount }; return; }
        // Un retrait déjà remboursé (rejet, échec compensé) ne peut jamais être déclaré payé.
        if (w.status !== 'pending_manual' || w.refunded === true) {
          throw new Refusal('REQUEST_NOT_PENDING', 'Ce retrait n\'est plus en attente de traitement manuel');
        }
        tx.update(wdRef, {
          status: 'processed', processedAt: admin.firestore.FieldValue.serverTimestamp(),
          processedBy: adminUid, settlementConfirmed: true,
        });
        outcome = { alreadyDone: false, amount: w.amount, userId: w.userId };
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({
          userId: adminUid, userType: 'admin', action: 'admin_approve_withdrawal', targetId: requestId,
          status: 'refused', metadata: { code: err.code },
        });
        return envelope(false, err.code, err.message);
      }
      throw err;
    }
    if (!outcome.alreadyDone) {
      await logAudit({
        userId: adminUid, userType: 'admin', action: 'admin_approve_withdrawal', targetId: requestId,
        amount: outcome.amount, status: 'success',
        metadata: { account: outcome.userId, walletUntouched: true,
          ...(typeof note === 'string' && note.trim() ? { note: note.trim() } : {}) },
      });
    }
    return envelope(true, null, outcome.alreadyDone ? 'Retrait déjà traité' : 'Retrait marqué comme traité',
      { requestId, alreadyDone: outcome.alreadyDone });
  });
}

module.exports = { buildAdminApproveRecharge, buildAdminApproveWithdrawal, MAX_RECHARGE_REQUEST };
