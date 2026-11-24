'use strict';

const { requireAdminPermission } = require('./adminGuards');
const { COLLECTION, STALE_RUNNING_MS } = require('./azia/persistentToolLedger');

/**
 * Supervision ADMIN des exécutions d'outils AZ IA — LECTURE SEULE.
 *
 * `ai_tool_executions` reste totalement fermée aux clients dans
 * `firestore.rules` (read/create/update/delete = false). Aucune règle n'est
 * assouplie ici : l'accès admin passe par cette Cloud Function, qui lit via
 * l'Admin SDK après avoir vérifié l'identité et la permission côté SERVEUR.
 *
 * Ce point d'entrée ne permet AUCUNE mutation : ni relance, ni suppression,
 * ni forçage de statut. Un état `failed`/`abandoned` peut masquer un effet
 * métier déjà appliqué (l'outil a pu écrire avant d'échouer) — le rejouer
 * depuis une interface d'administration risquerait un double paiement.
 * L'admin diagnostique ; il ne répare pas d'un clic.
 */

const VALID_STATUSES = Object.freeze(['failed', 'abandoned', 'running', 'completed']);
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

const REPLAY_WARNING = "Ne pas relancer automatiquement : l'effet métier peut déjà avoir été appliqué.";

function toMillis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (typeof value.toDate === 'function') return value.toDate().getTime();
  if (typeof value === 'number') return value;
  return null;
}

/**
 * Projection sûre : seuls les champs de diagnostic sortent. Les arguments
 * bruts ne sont de toute façon jamais persistés (la clé est un SHA-256), et
 * `result` n'est pas exposé — il peut contenir des données métier détaillées
 * sans valeur pour un diagnostic d'exécution.
 */
function toSafeRow(doc, nowMs) {
  const data = doc.data() || {};
  const startedAtMs = typeof data.startedAtMs === 'number' ? data.startedAtMs : null;
  const stale = data.status === 'running'
    && startedAtMs !== null
    && nowMs - startedAtMs > STALE_RUNNING_MS;

  return {
    id: doc.id,
    toolName: data.toolName || null,
    status: data.status || null,
    uid: data.uid || null,
    conversationId: data.conversationId || null,
    createdAtMs: toMillis(data.createdAt),
    startedAtMs,
    expiresAtMs: toMillis(data.expiresAt),
    completedAtMs: toMillis(data.completedAt),
    failureReason: data.failureReason ? String(data.failureReason).slice(0, 200) : null,
    // Signalé, jamais corrigé : aucun document n'est modifié par cette vue.
    stale,
    needsManualReview: ['failed', 'abandoned'].includes(data.status) || stale,
    replayWarning: ['failed', 'abandoned'].includes(data.status) || stale ? REPLAY_WARNING : null,
  };
}

function buildListAiToolExecutions({ db, onCall, HttpsError, now = () => Date.now() }) {
  return onCall({ region: 'europe-west1' }, async (request) => {
    // Identité ET permission vérifiées côté serveur, jamais côté client.
    await requireAdminPermission({ request, db, permission: 'ai_dashboard' });

    const status = request.data?.status;
    if (status !== undefined && status !== null && !VALID_STATUSES.includes(status)) {
      throw new HttpsError('invalid-argument', 'Statut de filtre invalide.');
    }
    const requestedLimit = Number(request.data?.limit);
    const limit = Number.isFinite(requestedLimit)
      ? Math.min(Math.max(Math.trunc(requestedLimit), 1), MAX_LIMIT)
      : DEFAULT_LIMIT;

    let query = db.collection(COLLECTION);
    if (status) query = query.where('status', '==', status);
    // Plus récents d'abord.
    query = query.orderBy('createdAt', 'desc');

    // Le curseur s'applique AVANT la limite : l'inverse laisserait la taille
    // de page dépendre de l'ordre d'application des clauses.
    const startAfterMs = Number(request.data?.startAfterMs);
    if (Number.isFinite(startAfterMs) && typeof query.startAfter === 'function') {
      query = query.startAfter(new Date(startAfterMs));
    }
    query = query.limit(limit);

    const snapshot = await query.get();
    const nowMs = now();
    const rows = snapshot.docs.map((doc) => toSafeRow(doc, nowMs));

    return {
      rows,
      count: rows.length,
      statuses: VALID_STATUSES,
      staleThresholdMs: STALE_RUNNING_MS,
      // Rappel explicite : cette vue ne propose aucune action corrective.
      readOnly: true,
      replayWarning: REPLAY_WARNING,
      nextStartAfterMs: rows.length === limit ? rows[rows.length - 1].createdAtMs : null,
    };
  });
}

module.exports = {
  VALID_STATUSES, DEFAULT_LIMIT, MAX_LIMIT, REPLAY_WARNING,
  toSafeRow, buildListAiToolExecutions,
};
