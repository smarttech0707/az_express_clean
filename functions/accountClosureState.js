'use strict';

// Socle L1 de la suppression de compte : interprétation UNIQUE de l'état de fermeture d'un compte.
// Fonctions pures : aucune lecture Firestore, aucune horloge. Le temps ne déverrouille jamais rien (décision D-11) : un tombstone
// reste protecteur quel que soit son âge, et seul un changement explicite de `phase` (récupération administrative) le fait évoluer.
// Contrat : docs/ACCOUNT_DELETION_2D2A3_FINAL_PROTOCOL.md §1.1 à §1.4 (schéma additif, `phase` absente = `closing`, `epoch` absent = 0).

const PHASE = Object.freeze({ CLOSING: 'closing', SEALED: 'sealed' });

// active              : aucun tombstone, profil présent, aucune demande de suppression.
// deletion_requested  : profil marqué `deletionRequested`, pas encore de tombstone (ce n'est PAS une anonymisation).
// closing             : tombstone sans `phase` (ancien format) ou `phase:'closing'` = quarantaine.
// sealed              : tombstone `phase:'sealed'` (suppression Auth en cours ou faite) : plus aucun règlement.
// anonymized          : profil `isDeleted:true`.
// absent              : aucun profil et aucun tombstone.
// unreadable          : tombstone présent mais illisible (phase ou epoch invalide) : traité comme le plus strict (fail-closed).
const STATE = Object.freeze({
  ACTIVE: 'active',
  DELETION_REQUESTED: 'deletion_requested',
  CLOSING: 'closing',
  SEALED: 'sealed',
  ANONYMIZED: 'anonymized',
  ABSENT: 'absent',
  UNREADABLE: 'unreadable',
});

// Codes stables des refus (details.code d'une HttpsError 'failed-precondition' : même code d'erreur que les gardes existantes).
const REFUSAL = Object.freeze({
  SEALED: 'ACCOUNT_SEALED',
  CLOSING: 'ACCOUNT_CLOSING',
  DELETION_REQUESTED: 'ACCOUNT_DELETION_REQUESTED',
  ANONYMIZED: 'ACCOUNT_ANONYMIZED',
  ABSENT: 'ACCOUNT_ABSENT',
  UNREADABLE: 'ACCOUNT_TOMBSTONE_UNREADABLE',
});

// Catégories de writers (protocole §4) : A = nouvelle activité (refusée dès la quarantaine), B/C/D = règlement ou remboursement
// d'une opération déjà engagée (B : progression, C : annulation/remboursement, D : décision administrative).
const OP_CLASS = Object.freeze({ A: 'A', B: 'B', C: 'C', D: 'D' });

// Libellés repris des gardes existantes (accountAdmission.js) pour ne pas changer ce que voient les appelants.
const MESSAGE = Object.freeze({
  [REFUSAL.SEALED]: 'Compte supprime ou en cours de suppression',
  [REFUSAL.CLOSING]: 'Compte supprime ou en cours de suppression',
  [REFUSAL.UNREADABLE]: 'Compte supprime ou en cours de suppression',
  [REFUSAL.DELETION_REQUESTED]: 'Compte en cours de suppression; nouvelles operations suspendues',
  [REFUSAL.ANONYMIZED]: 'Compte en cours de suppression; nouvelles operations suspendues',
  [REFUSAL.ABSENT]: 'Compte introuvable',
});

const isRecord = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// Lecture d'un document `account_tombstones/{uid}` (ou null). Un champ absent prend sa valeur par défaut ; un champ présent mais
// invalide rend le tombstone illisible (`malformed`), jamais « plus permissif ».
function interpretTombstone(data) {
  if (data === null || data === undefined) return { exists: false };
  if (!isRecord(data)) return { exists: true, malformed: true, phase: null, epoch: 0, deleting: false, authDeleted: false };
  let malformed = false;
  let phase = PHASE.CLOSING;
  if (data.phase !== undefined && data.phase !== null) {
    if (data.phase === PHASE.CLOSING || data.phase === PHASE.SEALED) phase = data.phase;
    else malformed = true;
  }
  let epoch = 0;
  if (data.epoch !== undefined && data.epoch !== null) {
    if (Number.isSafeInteger(data.epoch) && data.epoch >= 0) epoch = data.epoch;
    else malformed = true;
  }
  return {
    exists: true,
    malformed,
    phase: malformed ? null : phase,
    epoch,
    deleting: data.deleting === true,
    authDeleted: Number.isSafeInteger(data.authDeletedAtMs),
  };
}

// profile : données du profil, ou null si le document n'existe pas. tombstone : données du tombstone, ou null.
function readClosureState({ tombstone = null, profile = null } = {}) {
  const t = interpretTombstone(tombstone);
  const profileExists = isRecord(profile);
  let state;
  if (t.exists && t.malformed) state = STATE.UNREADABLE;
  else if (profileExists && profile.isDeleted === true) state = STATE.ANONYMIZED;
  else if (t.exists) state = t.phase === PHASE.SEALED ? STATE.SEALED : STATE.CLOSING;
  else if (!profileExists) state = STATE.ABSENT;
  else if (profile.deletionRequested === true) state = STATE.DELETION_REQUESTED;
  else state = STATE.ACTIVE;
  return {
    state,
    tombstoneExists: t.exists,
    // Une fermeture est « protégée » dès qu'un tombstone existe ou que le profil est anonymisé, même si le tombstone est illisible.
    protected: t.exists || state === STATE.ANONYMIZED,
    phase: t.exists ? t.phase : null,
    epoch: t.exists ? t.epoch : 0,
    deleting: t.exists ? t.deleting : false,
    authDeleted: t.exists ? t.authDeleted : false,
  };
}

const REFUSAL_BY_STATE = Object.freeze({
  [STATE.SEALED]: REFUSAL.SEALED,
  [STATE.CLOSING]: REFUSAL.CLOSING,
  [STATE.DELETION_REQUESTED]: REFUSAL.DELETION_REQUESTED,
  [STATE.ANONYMIZED]: REFUSAL.ANONYMIZED,
  [STATE.ABSENT]: REFUSAL.ABSENT,
  [STATE.UNREADABLE]: REFUSAL.UNREADABLE,
});

// Règle de décision commune (protocole §1.4) : null = autorisé ; sinon { code, message, state }.
//   A       : seul un compte actif est admis (refus dès la demande de suppression, comme accountAdmission.js).
//   B/C/D   : admis en actif, demande de suppression ou quarantaine ; refusés une fois scellé, illisible, anonymisé ou absent.
// Une opération de catégorie B/C/D en quarantaine doit incrémenter `epoch` (voir accountClosureLock.js).
function closureRefusal(closure, opClass) {
  if (!Object.values(OP_CLASS).includes(opClass)) throw new TypeError(`Catégorie d'opération inconnue : ${opClass}`);
  if (!closure || !Object.values(STATE).includes(closure.state)) throw new TypeError('État de fermeture invalide');
  const allowed = opClass === OP_CLASS.A
    ? [STATE.ACTIVE]
    : [STATE.ACTIVE, STATE.DELETION_REQUESTED, STATE.CLOSING];
  if (allowed.includes(closure.state)) return null;
  const code = REFUSAL_BY_STATE[closure.state];
  return { code, message: MESSAGE[code], state: closure.state };
}

module.exports = { PHASE, STATE, REFUSAL, OP_CLASS, interpretTombstone, readClosureState, closureRefusal };
