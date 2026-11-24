'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { PHASE, STATE, REFUSAL, OP_CLASS, interpretTombstone, readClosureState, closureRefusal } = require('../accountClosureState');

const profile = (extra = {}) => ({ wallet: 0, ...extra });

test('états distincts : actif, suppression demandée, quarantaine, scellé, anonymisé, absent', () => {
  assert.equal(readClosureState({ profile: profile() }).state, STATE.ACTIVE);
  assert.equal(readClosureState({ profile: profile({ deletionRequested: true }) }).state, STATE.DELETION_REQUESTED);
  assert.equal(readClosureState({ tombstone: { state: 'deleting' }, profile: profile() }).state, STATE.CLOSING);
  assert.equal(readClosureState({ tombstone: { state: 'deleting', phase: 'sealed' }, profile: profile() }).state, STATE.SEALED);
  assert.equal(readClosureState({ profile: profile({ isDeleted: true }) }).state, STATE.ANONYMIZED);
  assert.equal(readClosureState({}).state, STATE.ABSENT);
});

test('une suppression demandée n’est pas une anonymisation et n’est pas protégée par un tombstone', () => {
  const requested = readClosureState({ profile: profile({ deletionRequested: true }) });
  assert.equal(requested.state, STATE.DELETION_REQUESTED);
  assert.equal(requested.protected, false);
  assert.equal(requested.tombstoneExists, false);
  const anonymized = readClosureState({ profile: profile({ deletionRequested: true, isDeleted: true }) });
  assert.equal(anonymized.state, STATE.ANONYMIZED, 'isDeleted l’emporte sur deletionRequested');
  assert.equal(anonymized.protected, true);
});

test('un ancien tombstone sans phase ni epoch reste protégé : lu comme closing, epoch 0', () => {
  const legacy = { createdAt: { toMillis: () => 0 }, state: 'deleting' };
  const closure = readClosureState({ tombstone: legacy, profile: profile() });
  assert.deepEqual([closure.state, closure.phase, closure.epoch, closure.protected, closure.deleting, closure.authDeleted], [STATE.CLOSING, PHASE.CLOSING, 0, true, false, false]);
  // Même un tombstone sans aucun champ (document vide) protège : seule l’existence compte.
  assert.equal(readClosureState({ tombstone: {}, profile: profile() }).state, STATE.CLOSING);
  assert.equal(readClosureState({ tombstone: {} }).state, STATE.CLOSING, 'tombstone sans profil : toujours protégé');
});

test('aucun déverrouillage par le temps : l’état ne dépend d’aucune horloge', () => {
  const ancient = { state: 'deleting', createdAt: new Date('1999-01-01'), updatedAtMs: 1, sealedAtMs: 1, phase: 'sealed' };
  const realNow = Date.now;
  try {
    Date.now = () => 4102444800000; // an 2100
    assert.equal(readClosureState({ tombstone: ancient, profile: profile() }).state, STATE.SEALED);
    assert.equal(readClosureState({ tombstone: { state: 'deleting', createdAt: new Date('1999-01-01') }, profile: profile() }).state, STATE.CLOSING);
  } finally { Date.now = realNow; }
  assert.equal(readClosureState.length, 0, 'la lecture ne prend ni horloge ni durée');
});

test('champs additifs lus fidèlement : epoch, deleting, authDeletedAtMs', () => {
  const t = { phase: 'sealed', epoch: 4, deleting: true, authDeletedAtMs: 1700000000000, sealToken: 'x', sealEpoch: 4 };
  const closure = readClosureState({ tombstone: t, profile: profile() });
  assert.deepEqual([closure.state, closure.epoch, closure.deleting, closure.authDeleted], [STATE.SEALED, 4, true, true]);
  assert.equal(interpretTombstone(null).exists, false);
  assert.equal(interpretTombstone(undefined).exists, false);
});

test('tombstone illisible : fail-closed, jamais plus permissif', () => {
  for (const bad of [{ phase: 'deleted' }, { phase: 1 }, { epoch: -1 }, { epoch: 1.5 }, { epoch: '2' }, { epoch: NaN }, 'oops', ['x'], 42]) {
    const closure = readClosureState({ tombstone: bad, profile: profile() });
    assert.equal(closure.state, STATE.UNREADABLE, JSON.stringify(bad));
    assert.equal(closure.protected, true);
    for (const cls of Object.values(OP_CLASS)) assert.equal(closureRefusal(closure, cls).code, REFUSAL.UNREADABLE, `${cls} ${JSON.stringify(bad)}`);
  }
});

test('matrice de décision : A seulement en actif ; B/C/D jusqu’à la quarantaine incluse, jamais scellé', () => {
  const states = {
    active: readClosureState({ profile: profile() }),
    requested: readClosureState({ profile: profile({ deletionRequested: true }) }),
    closing: readClosureState({ tombstone: {}, profile: profile() }),
    sealed: readClosureState({ tombstone: { phase: 'sealed' }, profile: profile() }),
    anonymized: readClosureState({ profile: profile({ isDeleted: true }) }),
    absent: readClosureState({}),
  };
  const outcome = (cls) => Object.fromEntries(Object.entries(states).map(([k, v]) => [k, closureRefusal(v, cls)?.code || null]));
  assert.deepEqual(outcome('A'), { active: null, requested: REFUSAL.DELETION_REQUESTED, closing: REFUSAL.CLOSING, sealed: REFUSAL.SEALED, anonymized: REFUSAL.ANONYMIZED, absent: REFUSAL.ABSENT });
  for (const cls of ['B', 'C', 'D']) {
    assert.deepEqual(outcome(cls), { active: null, requested: null, closing: null, sealed: REFUSAL.SEALED, anonymized: REFUSAL.ANONYMIZED, absent: REFUSAL.ABSENT }, cls);
  }
});

test('refus déterministes et exploitables : code stable, message identique aux gardes existantes', () => {
  const sealed = closureRefusal(readClosureState({ tombstone: { phase: 'sealed' }, profile: profile() }), 'B');
  assert.deepEqual(Object.keys(sealed).sort(), ['code', 'message', 'state']);
  assert.equal(sealed.message, 'Compte supprime ou en cours de suppression', 'même libellé que accountAdmission.js pour un tombstone');
  const requested = closureRefusal(readClosureState({ profile: profile({ deletionRequested: true }) }), 'A');
  assert.equal(requested.message, 'Compte en cours de suppression; nouvelles operations suspendues', 'même libellé que accountAdmission.js pour un profil');
  assert.deepEqual(closureRefusal(readClosureState({ tombstone: {}, profile: profile() }), 'A'), closureRefusal(readClosureState({ tombstone: {}, profile: profile() }), 'A'));
});

test('arguments invalides : erreur de programmation, jamais un refus ou une autorisation silencieuse', () => {
  const ok = readClosureState({ profile: profile() });
  assert.throws(() => closureRefusal(ok, 'Z'), TypeError);
  assert.throws(() => closureRefusal(ok, undefined), TypeError);
  assert.throws(() => closureRefusal({ state: 'weird' }, 'A'), TypeError);
  assert.throws(() => closureRefusal(null, 'A'), TypeError);
});
