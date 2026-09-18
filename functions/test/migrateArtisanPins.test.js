'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomInt } = require('node:crypto');
const { hashSecret } = require('../passwordHash');
const { planDocument, safeSummary, migrationExitCode, runMigration } = require('../scripts/migrateArtisanPins');
const secret = () => String(randomInt(100000, 1000000));

test('legacy-only state needs migration', () => {
  assert.equal(planDocument({ artisanPin: secret() }, null).outcome, 'needs_migration');
});
test('valid migrated credentials remain clean', () => {
  assert.equal(planDocument({ status: 'approved' }, { hash: hashSecret(secret()) }).outcome, 'clean');
});
test('matching partial state is resumable, not skipped as an anomaly', () => {
  const value = secret();
  assert.equal(planDocument({ artisanPin: value }, { hash: hashSecret(value) }).outcome, 'resume_cleanup');
});
test('mismatching credentials, malformed hashes and approved accounts without credentials are anomalies', () => {
  const value = secret();
  assert.equal(planDocument({ artisanPin: value }, { hash: hashSecret(value + 'x') }).reason, 'credential_mismatch');
  assert.equal(planDocument({}, { hash: 'invalid' }).reason, 'invalid_credential');
  assert.equal(planDocument({ status: 'approved' }, null).reason, 'missing_credential');
  assert.equal(planDocument({ status: 'pending' }, null).outcome, 'clean');
});
test('safe summaries never serialize sensitive or arbitrary fields', () => {
  const value = secret();
  const summary = safeSummary({ dryRun: true, errors: 0, anomalies: 0, applied: 0,
    needsMigration: 1, resumable: 0, pin: value, hash: hashSecret(value), documentIds: ['private-id'] });
  const text = JSON.stringify(summary);
  assert.ok(!text.includes(value));
  assert.ok(!text.includes('private-id'));
  assert.ok(!Object.hasOwn(summary, 'hash'));
});
test('incomplete execution or anomalies produce nonzero exit status', () => {
  assert.equal(migrationExitCode({ dryRun: false, errors: 1 }), 2);
  assert.equal(migrationExitCode({ dryRun: true, anomalies: 1 }), 2);
  assert.equal(migrationExitCode({ dryRun: false, incomplete: true }), 2);
  assert.equal(migrationExitCode({ dryRun: true, incomplete: true }), 0);
  assert.equal(migrationExitCode({ dryRun: false, incomplete: false }), 0);
});
test('dry-run uses consistent transactional reads without writing', async () => {
  const data = { artisanPin: secret() };
  let writes = 0;
  const db = {
    collection(name) {
      return { get: async () => ({ docs: [{ id: 'provider' }] }), doc: (id) => ({ path: name + '/' + id }) };
    },
    runTransaction: async (callback) => callback({
      get: async (ref) => ({ exists: ref.path.startsWith('service_providers/'), data: () => data }),
      set: () => { writes++; }, update: () => { writes++; },
    }),
  };
  const summary = await runMigration({ db, admin: { firestore: { FieldValue: {} } }, log: () => {} });
  assert.equal(summary.needsMigration, 1);
  assert.equal(summary.applied, 0);
  assert.equal(writes, 0);
});
