'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  planDocument,
  safeSummary,
} = require('../scripts/migrateArtisanPins');

test('plan: PIN en clair sans hash existant -> needs_migration', () => {
  const plan = planDocument({ name: 'Kouassi', artisanPin: '4821' }, false);
  assert.equal(plan.outcome, 'needs_migration');
  assert.equal(plan.hasPlainPin, true);
});

test('plan: aucun PIN en clair -> clean (déjà migré ou jamais approuvé)', () => {
  const plan = planDocument({ name: 'Kouassi' }, true);
  assert.equal(plan.outcome, 'clean');
});

test('plan: PIN en clair vide (chaîne vide, artisan pas encore approuvé) -> clean', () => {
  const plan = planDocument({ name: 'Kouassi', artisanPin: '' }, false);
  assert.equal(plan.outcome, 'clean');
});

test('plan: PIN en clair ET hash déjà présent -> anomaly, jamais traité automatiquement', () => {
  const plan = planDocument({ name: 'Kouassi', artisanPin: '4821' }, true);
  assert.equal(plan.outcome, 'anomaly');
});

test('plan: document déjà nettoyé est idempotent (ré-exécution sans effet)', () => {
  const plan = planDocument({ name: 'Kouassi' }, false);
  assert.equal(plan.outcome, 'clean');
});

test('rapport sécurisé ne contient jamais de PIN, de hash ni d\'identifiant de document', () => {
  const report = safeSummary({
    dryRun: true, inspected: 3, needsMigration: 1, alreadyClean: 2,
    anomalies: 0, proposedCredentialWrites: 1, proposedPlainDeletes: 1,
    applied: 0, errors: 0,
    documentIds: ['secret-provider-id'], plainPin: '4821', hash: 'salt:deadbeef',
  });
  const serialized = JSON.stringify(report);
  assert.equal(serialized.includes('secret-provider-id'), false);
  assert.equal(serialized.includes('4821'), false);
  assert.equal(serialized.includes('deadbeef'), false);
});

test('runMigration en dry-run ne modifie jamais Firestore', async () => {
  const { runMigration } = require('../scripts/migrateArtisanPins');
  const providers = {
    p1: { name: 'A', artisanPin: '1234' },
    p2: { name: 'B' }, // déjà propre
  };
  const credentials = {};
  const written = [];
  const deleted = [];

  const fakeDb = {
    collection(name) {
      if (name === 'service_providers') {
        return {
          async get() {
            return {
              docs: Object.entries(providers).map(([id, data]) => ({
                id,
                data: () => data,
                ref: {
                  async get() { return { exists: true, data: () => providers[id] }; },
                  async update(patch) { deleted.push({ id, patch }); },
                },
              })),
            };
          },
        };
      }
      if (name === 'artisan_credentials') {
        return {
          doc(id) {
            return {
              async get() {
                return { exists: Object.hasOwn(credentials, id), data: () => credentials[id] };
              },
              async set(data) { written.push({ id, data }); credentials[id] = data; },
            };
          },
        };
      }
      throw new Error(`unexpected collection ${name}`);
    },
  };
  const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => 'now', delete: () => 'DELETE' } } };

  const summary = await runMigration({ db: fakeDb, admin: fakeAdmin, dryRun: true, log: () => {} });

  assert.equal(summary.dryRun, true);
  assert.equal(summary.inspected, 2);
  assert.equal(summary.needsMigration, 1);
  assert.equal(summary.alreadyClean, 1);
  assert.equal(written.length, 0, 'dry-run ne doit jamais écrire artisan_credentials');
  assert.equal(deleted.length, 0, 'dry-run ne doit jamais supprimer artisanPin');
});
