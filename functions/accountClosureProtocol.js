'use strict';

// L2 — séquence de fermeture de compte : T1 (quarantaine), T2 (préparation), T2b (scellement), F (fence), suppression Auth, T3.
// Contrat : docs/ACCOUNT_DELETION_2D2A3_FINAL_PROTOCOL.md §1 et §3 ; schéma additif du tombstone (L1 : accountClosureState.js).
//
// Garanties portées par ce module (et testées) :
//   - le tombstone fait autorité : `sealed` n'est jamais rouvert ici (ni par le temps, ni par une reprise) — D-11 ;
//   - `deleteUser` n'est appelé qu'après T2b (scellement) PUIS F (fence) réussis dans des transactions distinctes ;
//   - T2b exige le MÊME epoch que T2, une relecture complète non bloquante et la même empreinte du snapshot financier ;
//   - l'ordre de lecture est fixe : tombstone d'abord, puis dossier, puis lectures de l'inspecteur (réserve C2 / L0-F) ;
//   - la récupération administrative `sealed -> closing` (L2R) n'est PAS implémentée ici (hors périmètre de la mission L2).
//
// Les planificateurs `plan*` sont purs (aucune lecture, aucune écriture, aucune horloge) ; les enveloppes `*Tx` font les lectures
// puis, seulement si le plan est favorable, les écritures de la même transaction.

const { randomUUID } = require('node:crypto');
const { PHASE, interpretTombstone } = require('./accountClosureState');

const LEASE_MS = 180000;
const jobRef = (db, uid) => db.collection('account_deletions').doc(uid);
const tombstoneRef = (db, uid) => db.collection('account_tombstones').doc(uid);

// Raisons stables inscrites sur le dossier (`reason`) quand une étape refuse.
const REASON = Object.freeze({
  TOMBSTONE_MISSING: 'closure_tombstone_missing',
  TOMBSTONE_UNREADABLE: 'closure_tombstone_unreadable',
  EXISTING_TOMBSTONE: 'existing_tombstone_review',
  LEASE_LOST: 'closure_lease_lost',
  EPOCH_MISSING: 'closure_epoch_missing',
  EPOCH_CHANGED: 'closure_epoch_changed',
  SNAPSHOT_CHANGED: 'closure_snapshot_changed',
  OBLIGATION: 'closure_obligation_detected',
  NOT_SEALED: 'closure_not_sealed',
  SEAL_MISMATCH: 'closure_seal_mismatch',
  SEALED_RESUME_MISMATCH: 'sealed_resume_mismatch',
  SEALED_OBLIGATION: 'sealed_obligation_detected',
  SEALED_SNAPSHOT_CHANGED: 'sealed_snapshot_changed',
});

// Tombstone écrit par T1. `state` et `createdAt` restent ceux de l'ancien format (les gardes existantes ne testent que `exists`).
function closingTombstone({ createdAt, now, source }) {
  return { createdAt, state: 'deleting', phase: PHASE.CLOSING, epoch: 0, updatedAtMs: now, ...(source ? { source } : {}) };
}

async function readTombstone(tx, db, uid) {
  const ref = tombstoneRef(db, uid);
  const snap = await tx.get(ref);
  const data = snap.exists ? snap.data() : null;
  return { ref, data, view: interpretTombstone(data) };
}

// T2 : que faire du tombstone au moment de prendre le bail ?
//   missing/unreadable : anomalie, dossier bloqué (jamais de recréation silencieuse) ;
//   sealed : reprise après arrêt (§3.6) ; closing : on enregistre l'epoch observé.
function planEntry({ view }) {
  if (!view.exists) return { kind: 'blocked', reason: REASON.TOMBSTONE_MISSING };
  if (view.malformed) return { kind: 'blocked', reason: REASON.TOMBSTONE_UNREADABLE };
  if (view.phase === PHASE.SEALED) return { kind: 'sealed' };
  return { kind: 'closing', epoch: view.epoch };
}

function planSeal({ tomb, job, lease, reinspection }) {
  const { view, data } = tomb;
  if (!view.exists) return { ok: false, reason: REASON.TOMBSTONE_MISSING };
  if (view.malformed) return { ok: false, reason: REASON.TOMBSTONE_UNREADABLE };
  if (view.phase === PHASE.SEALED) {
    // Rejeu de T2b : déjà scellé par CE dossier (même jeton) ET par le détenteur du bail = succès idempotent. Un processus qui ne
    // détient plus le bail n'obtient jamais de succès (il ne pourrait de toute façon pas franchir F).
    if (!job.sealToken || data.sealToken !== job.sealToken) return { ok: false, reason: REASON.SEAL_MISMATCH };
    return job.lease && job.lease === lease ? { ok: true, already: true } : { ok: false, reason: REASON.LEASE_LOST };
  }
  if (!job.lease || job.lease !== lease) return { ok: false, reason: REASON.LEASE_LOST };
  if (!Number.isSafeInteger(job.closureEpoch)) return { ok: false, reason: REASON.EPOCH_MISSING };
  if (view.epoch !== job.closureEpoch) return { ok: false, reason: REASON.EPOCH_CHANGED };
  if (!reinspection || reinspection.blocking !== false) return { ok: false, reason: (reinspection && reinspection.reason) || REASON.OBLIGATION };
  if (typeof job.snapshotDigest !== 'string' || reinspection.digest !== job.snapshotDigest) return { ok: false, reason: REASON.SNAPSHOT_CHANGED };
  return { ok: true, epoch: view.epoch };
}

function planFence({ tomb, job, lease }) {
  const { view, data } = tomb;
  if (!view.exists || view.malformed || view.phase !== PHASE.SEALED) return { ok: false, reason: REASON.NOT_SEALED };
  if (typeof job.sealToken !== 'string' || data.sealToken !== job.sealToken) return { ok: false, reason: REASON.SEAL_MISMATCH };
  if (data.sealEpoch !== view.epoch || data.sealEpoch !== job.closureEpoch) return { ok: false, reason: REASON.SEAL_MISMATCH };
  if (!job.lease || job.lease !== lease) return { ok: false, reason: REASON.LEASE_LOST };
  return { ok: true };
}

// Reprise d'un dossier déjà scellé (§3.6) : lecture seule. Jeton, epoch, absence d'obligation et empreinte doivent concorder.
function planResume({ tomb, job, reinspection }) {
  const { view, data } = tomb;
  if (!view.exists || view.malformed || view.phase !== PHASE.SEALED) return { ok: false, reason: REASON.NOT_SEALED };
  if (typeof job.sealToken !== 'string' || data.sealToken !== job.sealToken || data.sealEpoch !== view.epoch || data.sealEpoch !== job.closureEpoch) {
    return { ok: false, reason: REASON.SEALED_RESUME_MISMATCH };
  }
  if (!reinspection || reinspection.blocking !== false) return { ok: false, reason: REASON.SEALED_OBLIGATION };
  if (reinspection.digest !== data.snapshotDigest || reinspection.digest !== job.snapshotDigest) return { ok: false, reason: REASON.SEALED_SNAPSHOT_CHANGED };
  return { ok: true };
}

// T2b. `reinspect(tx)` : lectures seules, retourne { blocking, reason, digest }. Une exception de lecture se propage.
async function sealTx(db, { uid, lease, reinspect, now, token = randomUUID() }) {
  return db.runTransaction(async (tx) => {
    const tomb = await readTombstone(tx, db, uid); // tombstone d'abord (L0-F)
    const ref = jobRef(db, uid);
    const job = (await tx.get(ref)).data() || {};
    const reinspection = await reinspect(tx);
    const plan = planSeal({ tomb, job, lease, reinspection });
    if (!plan.ok || plan.already) return plan;
    tx.update(tomb.ref, { phase: PHASE.SEALED, sealToken: token, sealEpoch: plan.epoch, sealedAtMs: now, snapshotDigest: job.snapshotDigest, updatedAtMs: now });
    tx.update(ref, { sealToken: token, sealedAtMs: now, leaseUntil: now + LEASE_MS });
    return { ok: true, token, epoch: plan.epoch };
  });
}

// F : dernière barrière avant l'appel irréversible. Écrit `deleting:true` ; refus si le scellé n'est pas celui du dossier.
async function fenceTx(db, { uid, lease, now }) {
  return db.runTransaction(async (tx) => {
    const tomb = await readTombstone(tx, db, uid);
    const job = (await tx.get(jobRef(db, uid))).data() || {};
    const plan = planFence({ tomb, job, lease });
    if (!plan.ok) return plan;
    tx.update(tomb.ref, { deleting: true, deleteStartedAtMs: tomb.data.deleteStartedAtMs || now, updatedAtMs: now });
    return { ok: true };
  });
}

// Reprise lecture seule d'un scellé existant : exécutée DANS la transaction du bail (le caller fournit les lectures).
async function resumeCheck(tx, db, { uid, job, reinspect }) {
  const tomb = await readTombstone(tx, db, uid);
  const reinspection = await reinspect(tx);
  return { tomb, plan: planResume({ tomb, job, reinspection }) };
}

// T3 : enregistre la suppression Auth confirmée. Ne change jamais `phase` ; le tombstone n'est jamais supprimé.
async function markAuthDeletedTx(db, { uid, now }) {
  return db.runTransaction(async (tx) => {
    const tomb = await readTombstone(tx, db, uid);
    if (!tomb.view.exists || (tomb.data && tomb.data.authDeletedAtMs)) return { ok: true, unchanged: true };
    tx.update(tomb.ref, { authDeletedAtMs: now, updatedAtMs: now });
    return { ok: true };
  });
}

// Désactivation Auth, T2b, F, suppression Auth confirmée. `resume` : le tombstone est déjà scellé (T2b et A1 ne sont pas rejoués).
// Retourne { ok:true } ou { ok:false, reason, reactivated } ; toute erreur Auth/Firestore imprévue se propage (le caller applique
// sa politique de reprise). Un état Auth incertain (erreur autre que `auth/user-not-found`) ne conclut jamais à une suppression.
async function sealAndDeleteAuth({ db, auth, uid, lease, resume = false, reinspect, clock }) {
  let disabled = false;
  const reactivate = async () => {
    if (!disabled) return false;
    try { await auth.updateUser(uid, { disabled: false }); return true; } catch (_) { return false; }
  };
  if (!resume) {
    try {
      await auth.updateUser(uid, { disabled: true });
      disabled = true;
      await auth.revokeRefreshTokens(uid);
    } catch (e) {
      if (e && e.code !== 'auth/user-not-found') { await reactivate(); throw e; }
    }
    let sealed;
    try { sealed = await sealTx(db, { uid, lease, reinspect, now: clock() }); } catch (e) { await reactivate(); throw e; }
    if (!sealed.ok) return { ...sealed, reactivated: await reactivate() };
  }
  const fence = await fenceTx(db, { uid, lease, now: clock() });
  if (!fence.ok) return fence;
  try { await auth.deleteUser(uid); } catch (e) { if (!e || e.code !== 'auth/user-not-found') throw e; }
  try { await auth.getUser(uid); throw new Error('AUTH_DELETION_NOT_CONFIRMED'); } catch (e) { if (!e || e.code !== 'auth/user-not-found') throw e; }
  await markAuthDeletedTx(db, { uid, now: clock() });
  return { ok: true };
}

// Échec d'une étape de fermeture : dossier bloqué, compteur de tentatives partagé avec failurePatch (même plafond).
function blockedPatch(job, { reason, now, retryMs, maxAttempts }) {
  const attempts = ((job && job.attempts) || 0) + 1;
  if (attempts >= maxAttempts) {
    return { attempts, state: 'blocked', reason: 'max_attempts_reached', lastReason: reason, reviewRequired: true, nextAttemptAt: null, leaseUntil: 0 };
  }
  return { attempts, state: 'blocked', reason, reviewRequired: true, nextAttemptAt: now + retryMs, leaseUntil: 0 };
}

module.exports = {
  LEASE_MS, REASON, closingTombstone, readTombstone, planEntry, planSeal, planFence, planResume,
  sealTx, fenceTx, resumeCheck, markAuthDeletedTx, sealAndDeleteAuth, blockedPatch,
};
