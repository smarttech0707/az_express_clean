'use strict';

const { createHash } = require('node:crypto');

/**
 * Idempotence PERSISTANTE des outils AZ IA à effet durable.
 *
 * Le ledger en mémoire (`toolExecutionLedger.js`) ne protège qu'à l'intérieur
 * d'UNE invocation `azIaChat`. Il ne couvre donc ni un retry client, ni un
 * double clic, ni une reconnexion réseau, ni le redémarrage d'une Cloud
 * Function, ni deux instances concurrentes. Ce module ajoute une réservation
 * transactionnelle dans Firestore, partagée par toutes les invocations.
 *
 * ⚠️ COUCHE SUPPLÉMENTAIRE, JAMAIS UN REMPLACEMENT. Les protections
 * financières existantes (transactions Firestore des outils, `ai_pending_actions`
 * + `aiConfirmAction`, vérification serveur FeexPay, idempotence du webhook)
 * restent seules responsables de la sûreté de l'argent.
 *
 * Confidentialité : la clé est un SHA-256 ; les arguments bruts (téléphone,
 * adresse, montant…) ne sont jamais écrits. Aucun jeton, aucune clé, aucun
 * en-tête n'entre dans ce document.
 */

const COLLECTION = 'ai_tool_executions';
const STALE_RUNNING_MS = 5 * 60 * 1000;          // au-delà, une réservation est réputée abandonnée

// ── Fenêtre d'idempotence, par CLASSE d'outil ──────────────────────────────
// Une constante unique de 24 h convenait mal : elle est généreuse pour un
// rappel, mais courte pour une action financière irréversible. Au-delà de la
// fenêtre, le document finit par être supprimé (TTL) et une demande identique
// redeviendrait exécutable — ce qui est acceptable pour un ticket de support,
// pas pour une recharge ou une annulation avec remboursement.
//
// Source unique de vérité, jamais dispersée dans les outils. Surchargeable
// par `ttlMs` (tests) ou par variable d'environnement, sans redéploiement.
const NON_FINANCIAL_TTL_MS = 24 * 60 * 60 * 1000;        // 24 h
const FINANCIAL_TTL_MS = 30 * 24 * 60 * 60 * 1000;       // 30 jours
const DEFAULT_TTL_MS = NON_FINANCIAL_TTL_MS;

function envTtl(name, fallback) {
  const raw = Number(process.env[name]);
  return Number.isFinite(raw) && raw > 0 ? raw : fallback;
}

/**
 * Les outils à effet durable SANS confirmation (rappel, ticket, mémoire) sont
 * réversibles et sans impact financier : fenêtre courte. Tous les autres
 * outils routés ici sont, par construction, ceux qui exposent un
 * `confirmHandler` — commandes, annulations/remboursements, recharge wallet :
 * fenêtre longue, jamais réduite.
 */
function ttlForTool(name) {
  return PERSISTENT_WITHOUT_CONFIRMATION.includes(name)
    ? envTtl('AI_TOOL_IDEMPOTENCY_TTL_MS', NON_FINANCIAL_TTL_MS)
    : envTtl('AI_TOOL_IDEMPOTENCY_FINANCIAL_TTL_MS', FINANCIAL_TTL_MS);
}

// Outils à effet durable SANS confirmation préalable. Les outils sensibles,
// eux, sont détectés dynamiquement : ils exposent un `confirmHandler` (leur
// `handler` crée déjà une action en attente, donc un document persistant).
const PERSISTENT_WITHOUT_CONFIRMATION = Object.freeze([
  'create_support_ticket',
  'create_reminder',
  'remember_user_info',
  'remember_named_address',
]);

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${stableJson(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/**
 * Un outil a-t-il un effet persistant ? Dérivé du registre lui-même, pour ne
 * pas figer une liste qui dériverait au prochain outil ajouté.
 */
function isPersistentTool(tool) {
  if (!tool) return false;
  if (typeof tool.confirmHandler === 'function') return true;
  return PERSISTENT_WITHOUT_CONFIRMATION.includes(tool.name);
}

/**
 * Identité LOGIQUE d'une action, indépendante du fournisseur : deux appels
 * représentant la même action produisent la même clé, que la demande vienne
 * de Gemini, Claude ou OpenAI (aucun identifiant natif n'entre dans le
 * calcul). Les arguments sont normalisés puis hachés.
 */
function identify({ uid, conversationId, name, input }) {
  const digest = createHash('sha256')
    .update(stableJson([uid, conversationId || null, name, input || {}]))
    .digest('hex');
  return `tool_${digest}`;
}

function createPersistentToolLedger({ db, admin, ttlMs = null, now = () => Date.now() }) {
  const collection = db.collection(COLLECTION);

  /**
   * Réserve l'exécution de façon atomique.
   * @returns {{state:'reserved'|'completed'|'running'|'failed', key, result?}}
   */
  async function reserve({ uid, conversationId, name, input }) {
    const key = identify({ uid, conversationId, name, input });
    const ref = collection.doc(key);
    const startedAtMs = now();

    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists) {
        const data = snap.data();
        if (data.status === 'completed') {
          // Résultat déjà obtenu : réutilisé tel quel, aucune réexécution.
          return { state: 'completed', key, result: data.result ?? null };
        }
        if (data.status === 'running') {
          const startedMs = typeof data.startedAtMs === 'number' ? data.startedAtMs : 0;
          if (startedAtMs - startedMs < STALE_RUNNING_MS) {
            // Une autre invocation l'exécute en ce moment : on ne réexécute
            // JAMAIS, on renvoie un état contrôlé.
            return { state: 'running', key };
          }
          // Réservation abandonnée (instance morte en cours d'exécution).
          // On ne rejoue pas pour autant : l'effet a pu se produire. L'état
          // est marqué pour revue plutôt que relancé aveuglément.
          tx.update(ref, { status: 'abandoned', abandonedAtMs: startedAtMs });
          return { state: 'running', key, abandoned: true };
        }
        if (data.status === 'failed' || data.status === 'abandoned') {
          // Un échec dont l'effet est incertain n'est pas rejoué
          // automatiquement : l'outil a pu écrire avant d'échouer.
          return { state: 'failed', key, result: data.result ?? null };
        }
      }
      tx.set(ref, {
        uid,
        toolName: name,
        conversationId: conversationId || null,
        status: 'running',
        startedAtMs,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        // Fenetre propre a la classe de l'outil (financier = longue).
        expiresAt: admin.firestore.Timestamp.fromMillis(startedAtMs + (ttlMs ?? ttlForTool(name))),
      });
      return { state: 'reserved', key };
    });
  }

  async function complete(key, result) {
    await collection.doc(key).update({
      status: 'completed',
      result: result ?? null,
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  async function fail(key, message) {
    await collection.doc(key).update({
      status: 'failed',
      // Message d'erreur borné : jamais de trace d'exécution ni de secret.
      failureReason: String(message || 'unknown').slice(0, 200),
      failedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  /**
   * Exécute `run` au plus une fois pour une action logique donnée, toutes
   * invocations confondues. Les outils en lecture seule ne passent jamais ici
   * (voir `isPersistentTool`) : y ajouter une écriture Firestore par appel
   * serait un coût injustifié pour une action sans effet.
   */
  async function execute({ uid, conversationId, name, input }, run) {
    const reservation = await reserve({ uid, conversationId, name, input });

    if (reservation.state === 'completed') {
      return { executed: false, reused: true, key: reservation.key, result: reservation.result };
    }
    if (reservation.state === 'running') {
      return {
        executed: false, reused: false, key: reservation.key,
        result: {
          status: 'duplicate_in_progress',
          message: 'Cette action est déjà en cours de traitement. Aucune nouvelle exécution.',
        },
      };
    }
    if (reservation.state === 'failed') {
      return {
        executed: false, reused: false, key: reservation.key,
        result: {
          status: 'previous_attempt_failed',
          message: "Une tentative précédente n'a pas abouti. Vérification manuelle requise avant de réessayer.",
        },
      };
    }

    try {
      const result = await run();
      await complete(reservation.key, result);
      return { executed: true, reused: false, key: reservation.key, result };
    } catch (err) {
      await fail(reservation.key, err?.message);
      throw err;
    }
  }

  return { identify, reserve, complete, fail, execute };
}

module.exports = {
  COLLECTION,
  DEFAULT_TTL_MS,
  NON_FINANCIAL_TTL_MS,
  FINANCIAL_TTL_MS,
  ttlForTool,
  STALE_RUNNING_MS,
  PERSISTENT_WITHOUT_CONFIRMATION,
  isPersistentTool,
  identify,
  createPersistentToolLedger,
};
