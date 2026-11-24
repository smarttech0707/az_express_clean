'use strict';

/**
 * Vérification AUTOMATIQUE des retraits FeexPay restés en attente.
 *
 * Pourquoi côté serveur : un retrait initié répond `PENDING` et n'est confirmé
 * que par l'endpoint officiel de statut. Dépendre de l'application mobile pour
 * déclencher cette vérification laisserait un retrait non résolu dès que
 * l'utilisateur ferme l'app — avec un wallet déjà débité.
 *
 * Règles structurantes :
 *   - cette tâche n'appelle JAMAIS l'endpoint d'initiation : elle ne fait que
 *     consulter le statut d'une référence déjà obtenue (aucune ré-émission,
 *     donc aucun risque de double transfert) ;
 *   - toute décision financière passe par `applyPayoutStatus`, la MÊME
 *     fonction que le callable `checkWithdrawalStatus` — il n'existe qu'une
 *     seule machine d'états ;
 *   - les vérifications sont bornées (backoff croissant, plafond de
 *     tentatives, âge maximal) pour ne pas multiplier les appels ni les
 *     lectures Firestore.
 */

const { applyPayoutStatus } = require('./feexpayPayments');

// Backoff croissant, en minutes, indexé par le nombre de vérifications déjà
// effectuées : ~3 min, puis espacement progressif jusqu'à 12 h.
const STATUS_CHECK_DELAYS_MINUTES = Object.freeze([
  3, 5, 10, 20, 40, 60, 120, 240, 480, 720, 720, 720,
]);
const MAX_STATUS_CHECKS = STATUS_CHECK_DELAYS_MINUTES.length;      // 12 au total
const MAX_TRACKING_AGE_MS = 7 * 24 * 60 * 60 * 1000;               // 7 jours
const SCHEDULER_BATCH_LIMIT = 50;
// Seuls ces états peuvent encore évoluer ; `sent` et `failed_refunded` sont
// finaux et ne sont jamais réinterrogés.
const ELIGIBLE_STATUSES = Object.freeze(['provider_pending', 'pending_manual']);

// États retournés par applyPayoutStatus qui closent définitivement le suivi.
const TERMINAL_STATES = Object.freeze([
  'settled', 'compensated', 'already_successful', 'already_compensated',
]);
// États nécessitant une intervention humaine : on arrête d'interroger FeexPay.
const REVIEW_STATES = Object.freeze([
  'reference_mismatch', 'amount_mismatch', 'user_not_found', 'not_found',
  'inconsistent_success_after_refund', 'inconsistent_failed_after_success',
]);

function delayMsForCheck(checkCount) {
  const index = Math.min(Math.max(checkCount, 0), STATUS_CHECK_DELAYS_MINUTES.length - 1);
  return STATUS_CHECK_DELAYS_MINUTES[index] * 60 * 1000;
}

/**
 * Décide s'il faut reprogrammer une vérification, et quand.
 * @returns {{exhausted:boolean, reason?:string, nextMs?:number}}
 */
function planNextCheck({ checkCount, createdAtMs, nowMs }) {
  if (checkCount >= MAX_STATUS_CHECKS) {
    return { exhausted: true, reason: 'max_checks_reached' };
  }
  if (createdAtMs && nowMs - createdAtMs > MAX_TRACKING_AGE_MS) {
    return { exhausted: true, reason: 'max_age_reached' };
  }
  return { exhausted: false, nextMs: nowMs + delayMsForCheck(checkCount) };
}

function toMillis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (typeof value.toDate === 'function') return value.toDate().getTime();
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number') return value;
  return null;
}

/**
 * Réserve un retrait pour vérification : repousse `nextStatusCheckAt` AVANT
 * l'appel réseau. Deux exécutions simultanées du planificateur ne peuvent donc
 * pas interroger FeexPay deux fois pour la même référence. La sécurité
 * financière, elle, ne dépend pas de cette réservation : elle est garantie par
 * la transaction d'`applyPayoutStatus`.
 */
async function claimWithdrawalForCheck({ db, admin, withdrawId, nowMs }) {
  const ref = db.collection('withdrawal_requests').doc(withdrawId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return { claimed: false, reason: 'not_found' };
    const data = snap.data();
    const dueMs = toMillis(data.nextStatusCheckAt);
    if (dueMs !== null && dueMs > nowMs) {
      return { claimed: false, reason: 'not_due' };
    }
    const checkCount = Number(data.statusCheckCount || 0);
    tx.update(ref, {
      nextStatusCheckAt: admin.firestore.Timestamp.fromMillis(nowMs + delayMsForCheck(checkCount)),
    });
    return { claimed: true, data };
  });
}

/**
 * Vérifie un retrait auprès de FeexPay et applique le résultat.
 * Utilisée à la fois par le callable et par le planificateur : une seule
 * implémentation de la logique financière.
 */
async function verifyAndApplyWithdrawal({
  db, admin, withdrawId, data, verifier, collectionFor,
  logAudit = async () => {}, logSecurityEvent = async () => {},
  nowMs = Date.now(),
}) {
  if (!data?.providerReference) {
    return { checked: false, reason: 'no_provider_reference' };
  }
  if (data.settlementConfirmed === true || data.compensated === true) {
    return { checked: false, reason: 'already_final' };
  }

  const verdict = await verifier.checkPayoutStatus(data.providerReference);
  const applied = await applyPayoutStatus({
    db, admin, withdrawId, verdict, collectionFor, logAudit, logSecurityEvent,
  });

  // ── Programmation de la suite (jamais une ré-initiation) ─────────────────
  const ref = db.collection('withdrawal_requests').doc(withdrawId);
  const checkCount = Number(data.statusCheckCount || 0) + 1;
  const scheduling = {
    statusCheckCount: checkCount,
    lastStatusCheckAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (TERMINAL_STATES.includes(applied.state) || REVIEW_STATES.includes(applied.state)) {
    Object.assign(scheduling, {
      nextStatusCheckAt: null,
      statusCheckStopped: true,
      statusCheckStopReason: TERMINAL_STATES.includes(applied.state) ? 'final_state' : 'needs_review',
    });
  } else {
    const plan = planNextCheck({
      checkCount, createdAtMs: toMillis(data.createdAt), nowMs,
    });
    if (plan.exhausted) {
      Object.assign(scheduling, {
        nextStatusCheckAt: null,
        statusCheckStopped: true,
        statusCheckStopReason: plan.reason,
        status: 'pending_manual',
        needsReview: true,
        autoRetryBlocked: true,
      });
    } else {
      scheduling.nextStatusCheckAt = admin.firestore.Timestamp.fromMillis(plan.nextMs);
      scheduling.statusCheckStopped = false;
    }
  }
  await ref.update(scheduling);

  return {
    checked: true,
    outcome: verdict.outcome,
    state: applied.state,
    stopped: scheduling.statusCheckStopped === true,
    stopReason: scheduling.statusCheckStopReason || null,
    checkCount,
  };
}

/**
 * Parcourt les retraits éligibles et les vérifie. Requête bornée par
 * `nextStatusCheckAt <= maintenant` et par une limite de lot : le coût est
 * proportionnel au nombre de retraits réellement en attente, jamais à
 * l'historique complet.
 */
async function runPendingWithdrawalCheck({
  db, admin, createVerifier, collectionFor,
  logAudit = async () => {}, logSecurityEvent = async () => {},
  nowMs = Date.now(), limit = SCHEDULER_BATCH_LIMIT, log = () => {},
}) {
  const verifier = createVerifier();
  if (!verifier) {
    log('Vérification des retraits impossible : vérificateur non configuré.');
    return { scanned: 0, checked: 0, settled: 0, compensated: 0, skipped: 0 };
  }

  const snap = await db.collection('withdrawal_requests')
    .where('status', 'in', ELIGIBLE_STATUSES)
    .where('nextStatusCheckAt', '<=', admin.firestore.Timestamp.fromMillis(nowMs))
    .orderBy('nextStatusCheckAt')
    .limit(limit)
    .get();

  const summary = { scanned: snap.docs.length, checked: 0, settled: 0, compensated: 0, skipped: 0 };

  for (const doc of snap.docs) {
    const claim = await claimWithdrawalForCheck({ db, admin, withdrawId: doc.id, nowMs });
    if (!claim.claimed) { summary.skipped++; continue; }

    const result = await verifyAndApplyWithdrawal({
      db, admin, withdrawId: doc.id, data: claim.data, verifier,
      collectionFor, logAudit, logSecurityEvent, nowMs,
    });
    if (!result.checked) { summary.skipped++; continue; }
    summary.checked++;
    if (result.state === 'settled') summary.settled++;
    if (result.state === 'compensated') summary.compensated++;
  }

  // Journalisation agrégée : ni référence, ni jeton, ni donnée personnelle.
  log(`Retraits vérifiés : ${summary.checked}/${summary.scanned} `
    + `(réglés=${summary.settled}, remboursés=${summary.compensated}, ignorés=${summary.skipped}).`);
  return summary;
}

/**
 * Fabrique la fonction planifiée. Même discipline de quota que les autres
 * tâches de maintenance du projet (une seule instance, CPU réduit).
 */
function buildPendingWithdrawalChecker({
  db, admin, onSchedule, createVerifier, collectionFor,
  logAudit, logSecurityEvent, schedule = 'every 5 minutes', secrets = [],
}) {
  return onSchedule(
    {
      schedule, timeZone: 'Africa/Abidjan',
      // Le vérificateur lit FEEXPAY_TOKEN : sans cette déclaration, la
      // fonction planifiée échouerait à l'exécution.
      secrets,
      maxInstances: 1, cpu: 0.5, timeoutSeconds: 300,
    },
    async () => {
      await runPendingWithdrawalCheck({
        db, admin, createVerifier, collectionFor, logAudit, logSecurityEvent,
        log: (message) => console.log(message),
      });
    },
  );
}

module.exports = {
  STATUS_CHECK_DELAYS_MINUTES,
  MAX_STATUS_CHECKS,
  MAX_TRACKING_AGE_MS,
  SCHEDULER_BATCH_LIMIT,
  ELIGIBLE_STATUSES,
  delayMsForCheck,
  planNextCheck,
  claimWithdrawalForCheck,
  verifyAndApplyWithdrawal,
  runPendingWithdrawalCheck,
  buildPendingWithdrawalChecker,
};
