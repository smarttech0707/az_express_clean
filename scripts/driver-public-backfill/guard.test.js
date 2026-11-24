'use strict';

// Tests des garde-fous du backfill `driver_public` (SEC-01, préparation S3).
// Aucun accès Firebase ici — uniquement la logique de refus elle-même.
//
// Exécution : node --test scripts/driver-public-backfill/guard.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const guard = require('./guard');

test('refuse les project IDs de production et préproduction', () => {
  for (const id of ['az-express-b0469', 'az-express-clean', 'az-express-preprod']) {
    assert.throws(() => guard.assertNoForbiddenProjectId(id), guard.BackfillGuardError);
  }
  // Un identifiant quelconque (non un project ID réel) ne doit pas être refusé par cette fonction.
  assert.doesNotThrow(() => guard.assertNoForbiddenProjectId('driver-fresh'));
});

test('refuse toute variable d\'environnement signalant un Firebase réel', () => {
  for (const key of guard.FORBIDDEN_ENV_VARS) {
    assert.throws(() => guard.assertNoRealFirebaseEnvironment({ [key]: 'x' }), guard.BackfillGuardError);
  }
  assert.doesNotThrow(() => guard.assertNoRealFirebaseEnvironment({ PATH: '/usr/bin' }));
});

test('refuse toute source autre qu\'un fichier local', () => {
  for (const bad of ['gs://bucket/x', 'https://x/livreurs.json', 'firestore://projects/x', 'projects/az-express-b0469']) {
    assert.throws(() => guard.assertFixtureSource(bad), guard.BackfillGuardError);
  }
  assert.doesNotThrow(() => guard.assertFixtureSource('./fixtures/sample-livreurs.json'));
});

test('refuse une source absente ou vide', () => {
  for (const bad of [undefined, null, '', '   ']) {
    assert.throws(() => guard.assertFixtureSource(bad), guard.BackfillGuardError);
  }
});

test('refuse tout mode d\'exécution différent de dry-run', () => {
  for (const mode of ['execute', 'write', 'apply', 'live', '', undefined, null]) {
    assert.throws(() => guard.assertDryRun(mode), guard.BackfillGuardError);
  }
  assert.doesNotThrow(() => guard.assertDryRun('dry-run'));
});

test('refuse toute option ressemblant à des identifiants Firebase', () => {
  for (const opt of [
    { credentials: 'x' }, { credential: 'x' }, { serviceAccount: 'x' },
    { keyFile: 'x' }, { adc: true }, { token: 'x' },
  ]) {
    assert.throws(() => guard.assertNoCredentialsProvided(opt), guard.BackfillGuardError);
  }
  assert.doesNotThrow(() => guard.assertNoCredentialsProvided({ source: './fixtures/sample-livreurs.json' }));
});
