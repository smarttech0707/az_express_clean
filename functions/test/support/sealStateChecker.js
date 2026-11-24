'use strict';

// Vérificateur d'état final d'un scellement (T2b) : utilisé par les scénarios de concurrence C7/C7b (émulateur) et par son
// contrôle négatif (test pur). Il ne regarde que des documents lus ; aucune logique du protocole n'y est réimplémentée.
const assert = require('node:assert/strict');

// state : { tomb, job, profile } (data() des trois documents). opts : { uid, digest, expectSealed }.
function assertSafeSealState(state, { uid, digest, expectSealed = false }) {
  const { tomb, job, profile } = state;
  assert.ok(tomb, `${uid} : tombstone absent`);
  assert.ok(job, `${uid} : dossier absent`);
  assert.deepEqual(profile, { wallet: 0 }, `${uid} : le compte a été modifié`);
  // Aucune suppression amorcée par un simple scellement : ni fence, ni Auth.
  for (const f of ['deleting', 'deleteStartedAtMs', 'authDeletedAtMs']) assert.equal(tomb[f], undefined, `${uid} : ${f} présent (suppression prématurée)`);
  assert.equal(tomb.state, 'deleting');
  assert.ok(tomb.phase === 'closing' || tomb.phase === 'sealed', `${uid} : phase inattendue ${tomb.phase}`);
  assert.equal(tomb.epoch, 0, `${uid} : epoch modifié`);
  assert.equal(job.closureEpoch, 0);
  assert.equal(job.snapshotDigest, digest, `${uid} : empreinte du dossier modifiée`);
  if (tomb.phase === 'sealed') {
    assert.equal(typeof tomb.sealToken, 'string', `${uid} : scellé sans jeton`);
    assert.equal(tomb.sealToken, job.sealToken, `${uid} : jetons tombstone/dossier différents`);
    assert.equal(tomb.sealEpoch, tomb.epoch, `${uid} : sealEpoch ≠ epoch`);
    assert.equal(tomb.snapshotDigest, job.snapshotDigest, `${uid} : empreinte tombstone ≠ dossier`);
    assert.equal(typeof tomb.sealedAtMs, 'number', `${uid} : sealedAtMs absent`);
  } else {
    assert.equal(expectSealed, false, `${uid} : scellé attendu`);
    for (const f of ['sealToken', 'sealEpoch', 'sealedAtMs', 'snapshotDigest']) assert.equal(tomb[f], undefined, `${uid} : ${f} sur un tombstone non scellé (état à moitié écrit)`);
    assert.equal(job.sealToken, undefined, `${uid} : jeton sur le dossier sans scellé`);
  }
}

module.exports = { assertSafeSealState };
