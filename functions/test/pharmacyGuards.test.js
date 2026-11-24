'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  DisabledExternalPharmacyGuardProvider,
  normalizeGuard,
  stableGuardId,
  syncProvider,
} = require('../pharmacyGuards');

const active = {
  externalId: 'g-1', name: 'Pharmacie Étoile', city: 'Abengourou',
  guardStartAt: '2026-08-11T20:00:00Z', guardEndAt: '2026-08-12T08:00:00Z',
};

test('normalise une garde traversant minuit avec timestamps UTC', () => {
  const guard = normalizeGuard(active, 'Source officielle');
  assert.equal(guard.cityKey, 'abengourou');
  assert.equal(guard.guardStartAt.toISOString(), '2026-08-11T20:00:00.000Z');
  assert.equal(guard.guardEndAt.toISOString(), '2026-08-12T08:00:00.000Z');
});

test('refuse une garde expirant avant son début', () => {
  assert.throws(() => normalizeGuard({ ...active,
    guardEndAt: '2026-08-11T19:00:00Z' }, 'Source'), /Garde invalide/);
});

test('déduplication stable source + externalId', () => {
  const a = normalizeGuard(active, 'Source officielle');
  const b = normalizeGuard({ ...active, name: 'Autre libellé' }, 'Source officielle');
  assert.equal(stableGuardId(a), stableGuardId(b));
});

test('source externe indisponible ne supprime ni écrit aucune garde', async () => {
  let writes = 0;
  const db = { collection: () => ({ doc: () => ({ set: async () => writes++ }) }) };
  const result = await syncProvider({
    db, admin: {}, provider: new DisabledExternalPharmacyGuardProvider(),
    city: 'Abengourou', from: new Date(), to: new Date(),
    logger: { info() {} },
  });
  assert.equal(result.available, false);
  assert.equal(writes, 0);
});
