'use strict';

// Contrôle négatif du vérificateur d'état utilisé par C7/C7b : il doit accepter les états sûrs et REFUSER chaque corruption.
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertSafeSealState } = require('./support/sealStateChecker');

const D = 'd'.repeat(64);
const closing = () => ({
  tomb: { state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: 1 },
  job: { lease: 'L', closureEpoch: 0, snapshotDigest: D },
  profile: { wallet: 0 },
});
const sealed = () => {
  const s = closing();
  Object.assign(s.tomb, { phase: 'sealed', sealToken: 't', sealEpoch: 0, sealedAtMs: 5, snapshotDigest: D });
  s.job.sealToken = 't';
  return s;
};
const check = (s, o = {}) => assertSafeSealState(s, { uid: 'u', digest: D, ...o });

test('vérificateur C7 : états sûrs acceptés', () => {
  check(closing());
  check(sealed());
  check(sealed(), { expectSealed: true });
});

const corruptions = {
  'scellé attendu mais closing': [() => closing(), { expectSealed: true }],
  'sealToken tombstone ≠ dossier': [() => { const s = sealed(); s.job.sealToken = 'x'; return s; }],
  'jeton sur le dossier sans scellé': [() => { const s = closing(); s.job.sealToken = 't'; return s; }],
  'état à moitié écrit (jeton sans phase sealed)': [() => { const s = closing(); s.tomb.sealToken = 't'; return s; }],
  'sealEpoch ≠ epoch': [() => { const s = sealed(); s.tomb.sealEpoch = 1; return s; }],
  'empreinte tombstone ≠ dossier': [() => { const s = sealed(); s.tomb.snapshotDigest = 'e'.repeat(64); return s; }],
  'sealedAtMs absent': [() => { const s = sealed(); delete s.tomb.sealedAtMs; return s; }],
  'deleting posé (suppression prématurée)': [() => { const s = sealed(); s.tomb.deleting = true; return s; }],
  'authDeletedAtMs posé': [() => { const s = sealed(); s.tomb.authDeletedAtMs = 9; return s; }],
  'compte modifié': [() => { const s = sealed(); s.profile = { wallet: 5 }; return s; }],
  'epoch modifié': [() => { const s = sealed(); s.tomb.epoch = 1; s.tomb.sealEpoch = 1; return s; }],
  'phase inconnue': [() => { const s = closing(); s.tomb.phase = 'open'; return s; }],
  'tombstone absent': [() => { const s = closing(); s.tomb = undefined; return s; }],
};
for (const [name, [build, opts]] of Object.entries(corruptions)) {
  test(`vérificateur C7 : refuse « ${name} »`, () => { assert.throws(() => check(build(), opts || {})); });
}
