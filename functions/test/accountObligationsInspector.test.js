'use strict';

// L2 — lecteur Firestore du moteur d'obligations : requêtes exactes et plafonnées, reçus de couverture, empreinte stable,
// fail-closed sur lecture illisible ou rôle inconnu. Faux Firestore : aucun accès cloud.
const test = require('node:test');
const assert = require('node:assert/strict');
const inspector = require('../accountObligationsInspector');
const engine = require('../accountObligations');
const { fakeStore } = require('./support/closureWorld');

const TERMINAL = engine.INSPECTOR_TERMINAL_STATUSES.accountDeletion;
const run = (store, args) => store.runTransaction((tx) => inspector.inspectObligations(tx, store, { terminalStatuses: TERMINAL, atMs: 1, accountUid: 'u1', ...args }));

// Journalise les requêtes réellement émises (collection, champ, opérateur, limite).
function spy(store) {
  const log = [];
  const col = store.collection;
  store.collection = (name) => {
    const c = col(name);
    const where = c.where;
    c.where = (f, op, v) => {
      const q = where(f, op, v);
      const limit = q.limit;
      q.limit = (n) => { log.push([name, f, op, v, n]); return limit(n); };
      return q;
    };
    return c;
  };
  return log;
}

test('client : exactement les requêtes de requiredQueries, limit(201), aucune lecture hors périmètre', async () => {
  const store = fakeStore({ 'clients/u1': { wallet: 0 } });
  const log = spy(store);
  const out = await run(store, { role: 'client', ids: ['u1'] });
  assert.equal(out.blocking, false); assert.equal(out.reason, null);
  assert.deepEqual(log, [['orders', 'clientId', '==', 'u1', 201], ['transfer_settlements', 'clientId', '==', 'u1', 201], ['reconciliation_flags', 'clientId', '==', 'u1', 201]]);
});

test('livreur : driverIds en array-contains, holderDriverId en égalité, une requête par clé exigée', async () => {
  const store = fakeStore({});
  const log = spy(store);
  await run(store, { role: 'livreur', ids: ['d1'] });
  assert.deepEqual(log.filter((l) => l[0] === 'transfer_settlements').map((l) => [l[1], l[2]]), [['driverIds', 'array-contains'], ['holderDriverId', '==']]);
  assert.deepEqual(log.filter((l) => l[0] === 'orders').map((l) => l[1]), ['driverId']);
  assert.deepEqual(log.filter((l) => l[0] === 'reconciliation_flags').map((l) => l[1]), ['driverId']);
});

test('livreur : un règlement où le livreur figure dans driverIds est vu et bloque', async () => {
  const store = fakeStore({ 'transfer_settlements/s1': { driverIds: ['d1', 'd2'], status: 'pending_review' } });
  const out = await run(store, { role: 'livreur', ids: ['d1'] });
  assert.equal(out.blocking, true); assert.equal(out.reason, 'financial_obligation_pending');
});

test('un document trouvé par deux requêtes (driverIds et holderDriverId) n’est évalué qu’une fois', async () => {
  const store = fakeStore({ 'transfer_settlements/s1': { driverIds: ['d1'], holderDriverId: 'd1', status: 'settled' } });
  const out = await run(store, { role: 'livreur', ids: ['d1'] });
  assert.equal(JSON.stringify(out.snapshot).includes('duplicate'), false);
});

test('journaux de débit : lecture ponctuelle de order_<id> pour une commande wallet v2 livrée ; absent = bloquant, conforme = libre', async () => {
  const order = { clientId: 'u1', status: 'delivered', amountsVersion: 2, paymentMethod: 'wallet', isPaid: true, productAmount: 900, deliveryFee: 1000, totalAmount: 1900, budget: 1000 };
  const without = await run(fakeStore({ 'orders/o1': order }), { role: 'client', ids: ['u1'] });
  assert.equal(without.blocking, true); assert.equal(without.reason, 'financial_obligation_pending');
  const journal = { type: 'payment', amount: 1900, orderId: 'o1' };
  const withLog = await run(fakeStore({ 'orders/o1': order, 'clients/u1/wallet_transactions/order_o1': journal }), { role: 'client', ids: ['u1'] });
  assert.equal(withLog.blocking, false);
  const mismatch = await run(fakeStore({ 'orders/o1': order, 'clients/u1/wallet_transactions/order_o1': { ...journal, amount: 5 } }), { role: 'client', ids: ['u1'] });
  assert.equal(mismatch.blocking, true);
});

test('tronqué (201 documents) : jamais traité comme « aucune obligation »', async () => {
  const seed = {};
  for (let i = 0; i < 201; i += 1) seed[`orders/o${i}`] = { clientId: 'u1', status: 'cancelled' };
  const out = await run(fakeStore(seed), { role: 'client', ids: ['u1'] });
  assert.equal(out.blocking, true); assert.equal(out.reason, 'financial_state_ambiguous');
});

test('rôle hors moteur : « non couvert » explicite, jamais « sans obligation » ; identifiants vides = ambigu', async () => {
  const uncovered = await run(fakeStore({}), { role: 'fleet_owner', ids: ['u1'] });
  assert.deepEqual(uncovered, { covered: false, role: 'fleet_owner' });
  const empty = await run(fakeStore({}), { role: 'client', ids: [] });
  assert.equal(empty.blocking, true); assert.equal(empty.reason, 'financial_state_ambiguous');
});

test('une exception de lecture se propage (la transaction échoue) au lieu d’être transformée en liste vide', async () => {
  const store = fakeStore({});
  store.store.queryFailure = (name) => name === 'transfer_settlements';
  await assert.rejects(run(store, { role: 'client', ids: ['u1'] }), /read failure/);
});

test('empreinte : stable (ordre des clés, horloge exclue), sensible à tout changement de contenu', async () => {
  assert.equal(inspector.canonical({ b: 1, a: [2, { d: 1, c: 2 }] }), inspector.canonical({ a: [2, { c: 2, d: 1 }], b: 1 }));
  assert.equal(inspector.snapshotDigest({ atMs: 1, x: 1 }), inspector.snapshotDigest({ atMs: 999, x: 1 }));
  assert.notEqual(inspector.snapshotDigest({ x: 1 }), inspector.snapshotDigest({ x: 2 }));
  const a = await run(fakeStore({}), { role: 'client', ids: ['u1'], atMs: 1 });
  const b = await run(fakeStore({}), { role: 'client', ids: ['u1'], atMs: 5000 });
  assert.equal(a.digest, b.digest); assert.match(a.digest, /^[a-f0-9]{64}$/);
  const c = await run(fakeStore({ 'reconciliation_flags/f1': { clientId: 'u1', status: 'closed' } }), { role: 'client', ids: ['u1'] });
  assert.notEqual(c.digest, a.digest);
});

test('plusieurs rôles : blocage si un seul bloque, rôles non couverts listés', async () => {
  const store = fakeStore({ 'reconciliation_flags/f1': { sellerId: 's1', status: 'open', kind: 'seller_review' } });
  const out = await store.runTransaction((tx) => inspector.inspectProfiles(tx, store, {
    terminalStatuses: engine.INSPECTOR_TERMINAL_STATUSES.accountDeletionScope, atMs: 1, accountUid: 'u1',
    entries: [{ role: 'client', ids: ['u1'] }, { role: 'seller', ids: ['s1'] }, { role: 'fleet_owner', ids: ['u1'] }],
  }));
  assert.equal(out.blocking, true); assert.equal(out.reason, 'financial_obligation_pending'); assert.deepEqual(out.uncovered, ['fleet_owner']);
});
