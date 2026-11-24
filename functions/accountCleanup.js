'use strict';

// Inventaire et effacement des données personnelles rattachées à un compte (Mission 7E-64).
//
// Pourquoi ce module : le moteur supprimait le compte Firebase Auth AVANT de vérifier le contenu du profil. Une
// sous-collection inattendue faisait alors échouer le nettoyage, après coup, sur un compte déjà irrécupérable. L'inventaire
// ci-dessous est exécuté AVANT toute suppression Auth ; un élément inconnu bloque le dossier en revue manuelle.

const BLOCKED_UNKNOWN_DATA = 'unknown_personal_data_review_required';
const PAGE = 100;
const MAX_PAGES = 50;

// Sous-collections d'un profil : les pièces financières ne sont JAMAIS supprimées (durée de conservation non validée) ;
// les notifications sont des données personnelles effaçables. Toute autre sous-collection est inconnue.
const KEPT_PROFILE_CHILDREN = new Set(['wallet_transactions']);
const ERASED_PROFILE_CHILDREN = new Set(['notifications']);
// Sous-collections de ai_conversations/{uid} : seul `messages` est connu.
const AI_CONVERSATION_CHILDREN = new Set(['messages']);
// Actions AZ IA jamais exécutées : leurs paramètres (téléphone, adresse…) sont personnels. Une action `completed`
// est la trace d'une opération financière ou destructrice confirmée : conservée.
const ERASABLE_PENDING_STATUSES = new Set(['pending', 'cancelled', 'expired']);

const collectionName = (ref) => String(ref.path || '').split('/')[0];

/**
 * Lecture seule. `{ reason: null }` si tout le nettoyage est réalisable, sinon le motif de blocage et les NOMS
 * de collections inconnues (jamais de contenu).
 */
async function inspectCleanup(db, profileRefs, uid) {
  const unknown = [];
  for (const ref of profileRefs) {
    for (const child of await ref.listCollections()) {
      if (KEPT_PROFILE_CHILDREN.has(child.id) || ERASED_PROFILE_CHILDREN.has(child.id)) continue;
      unknown.push(`${collectionName(ref)}/*/${child.id}`);
    }
  }
  for (const child of await db.collection('ai_conversations').doc(uid).listCollections()) {
    if (!AI_CONVERSATION_CHILDREN.has(child.id)) unknown.push(`ai_conversations/*/${child.id}`);
  }
  return unknown.length ? { reason: BLOCKED_UNKNOWN_DATA, collections: unknown } : { reason: null, collections: [] };
}

async function deletePage(db, docs) {
  const batch = db.batch();
  for (const doc of docs) batch.delete(doc.ref);
  await batch.commit();
}

/** Efface les notifications des profils. `false` s'il en reste (reprise au passage suivant). */
async function eraseProfileChildren(db, profileRefs) {
  for (const ref of profileRefs) {
    for (const child of await ref.listCollections()) {
      if (KEPT_PROFILE_CHILDREN.has(child.id)) continue;
      // Défense en profondeur : l'inventaire préalable doit avoir bloqué ce cas.
      if (!ERASED_PROFILE_CHILDREN.has(child.id)) throw new Error('UNKNOWN_PROFILE_CHILDREN');
      for (let pages = 0; ; pages++) {
        const page = await child.limit(PAGE).get();
        if (page.empty) break;
        await deletePage(db, page.docs);
        if (page.size < PAGE) break;
        if (pages + 1 >= MAX_PAGES) return false;
      }
    }
  }
  return true;
}

async function eraseByUid(db, collection, uid, shouldErase) {
  let erased = 0, retained = 0, last = null;
  for (let pages = 0; pages < MAX_PAGES; pages++) {
    let query = db.collection(collection).where('uid', '==', uid).limit(PAGE);
    if (last) query = query.startAfter(last);
    const page = await query.get();
    if (page.empty) return { erased, retained, done: true };
    const doomed = page.docs.filter((d) => shouldErase(d.data()));
    if (doomed.length) await deletePage(db, doomed);
    erased += doomed.length;
    retained += page.size - doomed.length;
    if (page.size < PAGE) return { erased, retained, done: true };
    last = page.docs[page.docs.length - 1];
  }
  return { erased, retained, done: false };
}

/**
 * Efface les données AZ IA identifiables sans ambiguïté par l'UID : messages et document de conversation
 * (`ai_conversations/{uid}`), mémoire (`ai_user_memory/{uid}`), rappels et actions non exécutées (champ `uid`).
 *
 * CONSERVÉ volontairement, à valider juridiquement : `ai_consents/{uid}` (preuve du consentement),
 * `ai_pending_actions` au statut `completed` (trace d'une opération confirmée) et `ai_tool_executions`
 * (registre d'idempotence des outils financiers, sans arguments bruts, à expiration propre).
 */
async function eraseAiData(db, uid) {
  const counts = { messages: 0, memory: 0, reminders: 0, pendingActions: 0, retainedPendingActions: 0 };
  const conversation = db.collection('ai_conversations').doc(uid);
  const messages = conversation.collection('messages');
  let done = true;
  for (let pages = 0; ; pages++) {
    const page = await messages.limit(PAGE).get();
    if (page.empty) break;
    await deletePage(db, page.docs);
    counts.messages += page.size;
    if (page.size < PAGE) break;
    if (pages + 1 >= MAX_PAGES) { done = false; break; }
  }
  if (done) {
    await conversation.delete();
    const memory = db.collection('ai_user_memory').doc(uid);
    if ((await memory.get()).exists) { await memory.delete(); counts.memory = 1; }
  }
  const reminders = await eraseByUid(db, 'ai_reminders', uid, () => true);
  counts.reminders = reminders.erased;
  const actions = await eraseByUid(db, 'ai_pending_actions', uid, (d) => ERASABLE_PENDING_STATUSES.has(d.status));
  counts.pendingActions = actions.erased;
  counts.retainedPendingActions = actions.retained;
  return { done: done && reminders.done && actions.done, counts };
}

/**
 * Plafond de tentatives techniques : au-delà, plus aucune reprise automatique (le dossier attend le support, qui remet
 * le compteur à zéro avec une reprise motivée). Pure, partagée par le moteur client/livreur et le moteur partenaires.
 */
function failurePatch(job, { now, retryMs, maxAttempts, reason = 'server_retry_required' }) {
  const attempts = (job && job.attempts || 0) + 1;
  if (attempts >= maxAttempts) {
    return {
      attempts, reason: 'max_attempts_reached', reviewRequired: true, nextAttemptAt: null, leaseUntil: 0,
      // Après suppression Auth, l'accès est déjà fermé : le dossier reste « cleanup_pending ».
      state: job && job.authDeleted === true ? 'cleanup_pending' : 'blocked',
    };
  }
  return { attempts, state: 'cleanup_pending', reason, reviewRequired: true, nextAttemptAt: now + retryMs };
}

module.exports = {
  BLOCKED_UNKNOWN_DATA, MAX_PAGES, inspectCleanup, eraseProfileChildren, eraseAiData, failurePatch,
};
