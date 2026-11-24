'use strict';

const { assertNewAccountActivity } = require('./accountAdmission');

// Recharge manuelle du portefeuille d'un livreur par l'administration, après remise d'espèces au bureau.
//
// Seule source de crédit des livreurs au lancement (FeexPay est reporté). Avant ce module, l'écran admin
// écrivait directement le solde dans Firestore : pas de plafond, pas d'identité de l'admin sur le mouvement,
// pas de journal d'audit, et un double appui pouvait créditer deux fois. Ici, tout est côté serveur :
//   - autorisation : admin actif ayant la permission « recharges » (ou super-admin) ;
//   - plafond par opération : `config/driver_recharge.maxPerOperation` (50 000 FCFA par défaut) ;
//   - idempotence : la clé générée par l'écran à la confirmation fixe l'identifiant du mouvement
//     (`recharge_<clé>`) ; un rejeu renvoie le résultat sans second crédit ;
//   - solde et registre écrits dans la même transaction, puis `audit_logs`.

const DEFAULT_MAX_PER_OPERATION = 50000;
const CONFIG_CEILING = 1000000; // une valeur de configuration absurde retombe sur le plafond par défaut
const KEY_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const MAX_NOTE = 140;

const envelope = (message, data) => ({ success: true, error: null, message, data, code: 'OK' });

async function readMaxPerOperation(db) {
  try {
    const snap = await db.collection('config').doc('driver_recharge').get();
    const configured = snap.exists ? snap.data()?.maxPerOperation : undefined;
    if (Number.isSafeInteger(configured) && configured > 0 && configured <= CONFIG_CEILING) return configured;
  } catch (_) { /* configuration illisible : plafond par défaut, jamais d'absence de plafond */ }
  return DEFAULT_MAX_PER_OPERATION;
}

function buildAdminDriverRecharge({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireAdminPermission,
}) {
  return onCall(async (request) => {
    const adminData = await requireAdminPermission({ request, db, permission: 'recharges' });
    const adminUid = request.auth.uid;
    const { driverId, amount, idempotencyKey, note } = request.data || {};

    if (typeof driverId !== 'string' || !driverId.trim() || driverId.length > 128 || driverId.includes('/')) {
      throw new HttpsError('invalid-argument', 'Livreur invalide');
    }
    if (!Number.isSafeInteger(amount) || amount <= 0) {
      throw new HttpsError('invalid-argument', 'Montant invalide (entier positif en FCFA)');
    }
    if (typeof idempotencyKey !== 'string' || !KEY_PATTERN.test(idempotencyKey)) {
      throw new HttpsError('invalid-argument', 'Clé de confirmation invalide');
    }
    if (note !== undefined && note !== null && (typeof note !== 'string' || note.length > 500)) {
      throw new HttpsError('invalid-argument', 'Note invalide');
    }
    const max = await readMaxPerOperation(db);
    if (amount > max) {
      throw new HttpsError('invalid-argument', `Plafond par recharge : ${max} FCFA`, { max });
    }
    await checkRateLimit(adminUid, 'admin_driver_recharge', 30, 60);

    const targetId = driverId.trim();
    const driverRef = db.collection('livreurs').doc(targetId);
    const txRef = driverRef.collection('wallet_transactions').doc(`recharge_${idempotencyKey}`);
    const description = (typeof note === 'string' && note.trim())
      ? note.trim().slice(0, MAX_NOTE)
      : 'Recharge espèces — remise au bureau AZ Express';
    let outcome;

    await db.runTransaction(async (tx) => {
      const [driverSnap, txSnap] = await Promise.all([tx.get(driverRef), tx.get(txRef)]);
      if (!driverSnap.exists) throw new HttpsError('not-found', 'Livreur introuvable');
      const wallet = Number(driverSnap.data().wallet || 0);
      if (!Number.isSafeInteger(wallet) || wallet < 0) {
        throw new HttpsError('failed-precondition', 'Solde du livreur invalide : vérification manuelle requise');
      }
      if (txSnap.exists) {
        // Rejeu (double appui, reprise réseau) : succès sans second crédit. Même clé avec un autre montant = anomalie.
        if (txSnap.data().amount !== amount || txSnap.data().adminId !== adminUid) {
          throw new HttpsError('already-exists', 'Cette confirmation a déjà été utilisée pour une autre recharge');
        }
        outcome = { alreadyDone: true, newBalance: wallet, balanceBefore: wallet - amount };
        return;
      }
      // Un livreur en cours de suppression (ou supprimé) ne reçoit plus d'argent : le solde non nul bloquerait la
      // suppression, et le crédit d'un compte supprimé serait perdu. Relu dans la transaction (course avec la suppression).
      await assertNewAccountActivity(tx, db, HttpsError, targetId, [['livreurs', targetId]]);
      if (!Number.isSafeInteger(wallet + amount)) {
        throw new HttpsError('failed-precondition', 'Solde résultant invalide');
      }
      tx.update(driverRef, { wallet: wallet + amount });
      tx.set(txRef, {
        type: 'recharge', amount, description, orderId: null,
        source: 'admin_cash', adminId: adminUid, idempotencyKey,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      outcome = { alreadyDone: false, newBalance: wallet + amount, balanceBefore: wallet };
    });

    if (!outcome.alreadyDone) {
      await logAudit({
        userId: adminUid, userType: 'admin', action: 'admin_driver_recharge', targetId,
        amount, status: 'success',
        metadata: {
          balanceBefore: outcome.balanceBefore, balanceAfter: outcome.newBalance,
          adminRole: adminData.role, idempotencyKey, source: 'admin_cash',
        },
      });
    }
    return envelope(outcome.alreadyDone ? 'Recharge déjà enregistrée' : 'Recharge enregistrée',
      { driverId: targetId, amount, newBalance: outcome.newBalance, alreadyDone: outcome.alreadyDone, max });
  });
}

module.exports = { buildAdminDriverRecharge, DEFAULT_MAX_PER_OPERATION };
