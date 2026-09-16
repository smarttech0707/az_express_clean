'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  PRIVATE_FIELDS,
  planDocument,
  safeSummary,
} = require('../scripts/migrateSimpleServicesPrivate');

test('plan: sépare identité et coordonnées sans toucher au catalogue', () => {
  const plan = planDocument({
    name: 'Prestataire', phone: '0700000000', serviceType: 'tricycle',
    isAvailable: true, photoUrl: '', idNumber: 'SECRET',
    idPhotoUrl: 'PRIVATE_URL', lat: 6.7, lng: -3.4,
  }, null);
  assert.equal(plan.outcome, 'needs_migration');
  assert.deepEqual(plan.detected, PRIVATE_FIELDS);
  assert.deepEqual(plan.publicDeletes, PRIVATE_FIELDS);
  assert.equal(Object.hasOwn(plan.privatePatch, 'name'), false);
});

test('plan: document déjà séparé est idempotent', () => {
  const plan = planDocument({
    name: 'Prestataire', phone: '0700000000', serviceType: 'taxi_nuit',
    isAvailable: true, photoUrl: '',
  }, { idNumber: 'SECRET', migrationVersion: 'simple_services_private_v1' });
  assert.equal(plan.outcome, 'already_migrated');
  assert.deepEqual(plan.publicDeletes, []);
});

test('plan: copie privée identique peut être reprise après interruption', () => {
  const plan = planDocument(
    { name: 'P', idNumber: 'SECRET', idPhotoUrl: 'PRIVATE_URL' },
    { idNumber: 'SECRET', idPhotoUrl: 'PRIVATE_URL' },
  );
  assert.equal(plan.outcome, 'needs_migration');
  assert.deepEqual(plan.conflicts, []);
});

test('plan: conflit privé interdit tout écrasement silencieux', () => {
  const plan = planDocument(
    { name: 'P', idNumber: 'SOURCE' },
    { idNumber: 'DESTINATION_DIFFERENTE' },
  );
  assert.equal(plan.outcome, 'conflict');
  assert.deepEqual(plan.privatePatch, {});
  assert.deepEqual(plan.publicDeletes, []);
});

test('rapport sécurisé ne contient ni identifiant de document ni valeur privée', () => {
  const report = safeSummary({
    dryRun: true, inspected: 2, needsMigration: 1, alreadyMigrated: 1,
    cleanPublic: 0, conflicts: 0, anomalies: 0, proposedPrivateWrites: 1,
    proposedPublicCleanups: 1, applied: 0, errors: 0,
    detectedFieldCounts: { idNumber: 1, idPhotoUrl: 1, lat: 1, lng: 1 },
    documentIds: ['secret-id'], privateValues: ['SECRET'],
  });
  const serialized = JSON.stringify(report);
  assert.equal(serialized.includes('secret-id'), false);
  assert.equal(serialized.includes('SECRET'), false);
});
