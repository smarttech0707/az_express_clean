'use strict';

// L2 — intégration du moteur `accountObligations.js` (prédicat pur) dans les inspecteurs de suppression.
// Contrat : docs/ACCOUNT_DELETION_2D2A_TECHNICAL_CONTRACT.md §2 et §4 ; D-12 : le moteur S'AJOUTE aux contrôles existants.
//
// Ce module est le seul à lire Firestore pour le moteur. Les requêtes sont EXACTEMENT celles de `requiredQueries(role, ids)`,
// chacune plafonnée à READ_LIMIT (201) ; le reçu de couverture vient de `snapshot.size`. Aucune pagination dans une transaction.
// Toute exception de lecture se propage : la transaction de l'appelant échoue, rien n'est écrit (jamais une liste vide par défaut).
// Registre des décisions (`decisions`, `evidence`) : le writer de décisions est la mission L7 ; tant qu'il n'existe pas, les
// listes fournies sont vides et tout signalement « résolu » reste bloquant (fail-closed, aucune preuve inventée).

const { createHash } = require('node:crypto');
const engine = require('./accountObligations');

const COLLECTION = Object.freeze({ orders: 'orders', settlements: 'transfer_settlements', flags: 'reconciliation_flags' });
// `driverIds` est un tableau de la course (transferSettlement.js) : seule clé lue avec array-contains.
const OPERATOR = Object.freeze({ driverIds: 'array-contains' });
const LISTS = Object.freeze(['orders', 'settlements', 'flags']);

const CODE = Object.freeze({
  OBLIGATION: 'financial_obligation_pending',
  AMBIGUOUS: 'financial_state_ambiguous',
});

// JSON canonique (clés triées) : même contenu => même empreinte, quel que soit l'ordre d'insertion.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}
const sha256 = (text) => createHash('sha256').update(text).digest('hex');

// L'horloge (`atMs`) est exclue : deux inspections identiques à des instants différents ont la même empreinte.
function snapshotDigest(snapshot) {
  const { atMs, ...rest } = snapshot || {};
  return sha256(canonical(rest));
}

// Rôle de suppression -> rôle du moteur ; null = rôle que le moteur ne couvre pas (contrôles existants seuls, voir rapport L2).
function engineRole(role) {
  return engine.normalizeRole(role) ? role : null;
}

async function readList(tx, db, name, queries) {
  const docs = new Map();
  const receipt = [];
  for (const { key, id } of queries) {
    const snap = await tx.get(db.collection(COLLECTION[name]).where(key, OPERATOR[key] || '==', id).limit(engine.READ_LIMIT));
    receipt.push({ key, id, limit: engine.READ_LIMIT, size: snap.size });
    for (const doc of snap.docs) docs.set(doc.id, { id: doc.id, data: doc.data() });
  }
  return { list: [...docs.values()], receipt };
}

// Lit tout ce que le moteur exige pour UN rôle et l'évalue. Retourne :
//   { covered:false, role }                                       rôle hors moteur (contrôles existants seuls)
//   { covered:true, blocking, reason, code, snapshot, digest }    reason = null si non bloquant
async function inspectObligations(tx, db, { role, ids, terminalStatuses, atMs, accountUid }) {
  if (!engineRole(role)) return { covered: false, role };
  const queries = engine.requiredQueries(role, ids);
  if (!queries) return { covered: true, blocking: true, reason: CODE.AMBIGUOUS, code: CODE.AMBIGUOUS, snapshot: null, digest: null };
  const input = { role, ids, terminalStatuses, reads: {}, decisions: [], evidence: [] };
  for (const name of LISTS) {
    const { list, receipt } = await readList(tx, db, name, queries[name]);
    input[name] = list;
    input.reads[name] = { queries: receipt };
  }
  // Journaux de débit « order_<id> » du client : lectures ponctuelles, une par commande wallet v2/devis livrée.
  input.walletDebits = [];
  for (const debitId of engine.requiredWalletDebitIds(role, input.orders)) {
    const snap = await tx.get(db.collection('clients').doc(accountUid).collection('wallet_transactions').doc(debitId));
    input.walletDebits.push({ id: debitId, exists: snap.exists, data: snap.exists ? snap.data() : undefined });
  }
  const result = engine.evaluateAccountObligations(input);
  const snapshot = engine.buildFinancialSnapshot(result, { atMs });
  // Seul `blocking === false` autorise : un résultat illisible ou une catégorie inconnue bloque (jamais ignorée).
  const readable = result && typeof result.blocking === 'boolean' && snapshot && snapshot.blocking === result.blocking;
  const blocking = !readable || result.blocking !== false || snapshot.manualReviewRequired === true;
  const code = !readable ? CODE.AMBIGUOUS : result.code === CODE.OBLIGATION ? CODE.OBLIGATION : CODE.AMBIGUOUS;
  return { covered: true, blocking, reason: blocking ? code : null, code, snapshot, digest: snapshotDigest(snapshot) };
}

// Plusieurs rôles (partenaires multi-identités, Q9) : un appel par rôle, résultats cumulés, blocage si l'un bloque.
async function inspectProfiles(tx, db, { entries, terminalStatuses, atMs, accountUid }) {
  const parts = [];
  for (const entry of entries) {
    parts.push({ role: entry.role, ids: entry.ids, ...(await inspectObligations(tx, db, { ...entry, terminalStatuses, atMs, accountUid })) });
  }
  const blocked = parts.find((p) => p.covered && p.blocking);
  const snapshot = {
    version: 1, atMs,
    roles: parts.map((p) => ({ role: p.role, ids: p.ids, covered: p.covered, snapshot: p.covered ? p.snapshot : null })),
  };
  return {
    blocking: Boolean(blocked), reason: blocked ? blocked.reason : null, snapshot,
    digest: sha256(canonical(parts.map((p) => ({ role: p.role, ids: p.ids, covered: p.covered, digest: p.covered ? p.digest : null })))),
    uncovered: parts.filter((p) => !p.covered).map((p) => p.role),
  };
}

// Motifs historiques conservés pour les retraits (mêmes valeurs que les inspecteurs avant L2.2 : les appelants et leurs tests les connaissent).
const WITHDRAWAL_BLOCK = Object.freeze({
  TRUNCATED: 'history_requires_manual_review',
  OPEN: 'active_or_unresolved_operation',
  UNRESOLVED: 'financial_regularization_required',
});

// Retraits d'UN compte (`withdrawal_requests.userId`), classés par le prédicat du moteur (L2.1) : le seul endroit qui décide si un
// retrait est réglé. Remplace le test « statut ∈ statuts de commande » des inspecteurs historiques, qui refusait à tort `sent` et
// `processed`. Même lecture qu'avant (une requête plafonnée à READ_LIMIT), avec reçu de couverture ; toute exception de lecture se
// propage (jamais une liste vide par défaut). Retourne { blocking, reason, docs } ; `docs` = documents lus (non bloquant :
// tous réglés), à joindre à l'historique du compte comme avant.
async function inspectWithdrawals(tx, db, { accountUid }) {
  const snap = await tx.get(db.collection('withdrawal_requests').where('userId', '==', accountUid).limit(engine.READ_LIMIT));
  const docs = snap.docs;
  const verdict = engine.evaluateWithdrawals({
    ids: [accountUid],
    withdrawals: docs.map((doc) => ({ id: doc.id, data: doc.data() })),
    reads: { queries: [{ key: 'userId', id: accountUid, limit: engine.READ_LIMIT, size: snap.size }] },
  });
  if (snap.size >= engine.READ_LIMIT) return { blocking: true, reason: WITHDRAWAL_BLOCK.TRUNCATED, docs };
  if (!verdict || verdict.blocking !== false) {
    const open = verdict && Array.isArray(verdict.obligations) && verdict.obligations.some((o) => o.state === engine.WITHDRAWAL_STATE.OPEN);
    return { blocking: true, reason: open ? WITHDRAWAL_BLOCK.OPEN : WITHDRAWAL_BLOCK.UNRESOLVED, docs };
  }
  // Contrôles historiques conservés : un retrait « réglé » portant un remboursement ou un paiement en attente reste bloquant.
  if (docs.some((doc) => { const d = doc.data(); return d.refundPending === true || d.paymentStatus === 'pending'; })) {
    return { blocking: true, reason: WITHDRAWAL_BLOCK.UNRESOLVED, docs };
  }
  return { blocking: false, reason: null, docs };
}

module.exports = { inspectObligations, inspectProfiles, inspectWithdrawals, snapshotDigest, canonical, engineRole, CODE, COLLECTION, WITHDRAWAL_BLOCK };
