'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertFinancialLock } = require('../accountClosureLock');
const { assertNewAccountActivity } = require('../accountAdmission');
const { REFUSAL } = require('../accountClosureState');

// Vraie forme d'HttpsError : (code, message, details).
class HttpsError extends Error { constructor(code, message, details) { super(message); this.code = code; this.details = details; } }

// Base factice : docs = { 'collection/id': data }. Journalise l'ordre des lectures et toute écriture.
function fakeStore(docs) {
  const reads = [];
  const writes = [];
  const db = { collection: (c) => ({ doc: (id) => ({ path: `${c}/${id}` }) }) };
  const tx = {
    get: async (ref) => { reads.push(ref.path); const d = docs[ref.path]; return { exists: d !== undefined, data: () => d }; },
    update: (ref, data) => writes.push([ref.path, data]),
  };
  return { db, tx, reads, writes };
}
const clock = () => 1700000000000;
const lock = (store, parties, cls, opts = {}) => assertFinancialLock(store.tx, store.db, HttpsError, parties, cls, { now: clock, ...opts });
const client = { collection: 'clients', id: 'u1' };

test('compte actif : aucune écriture supplémentaire, quelle que soit la catégorie', async () => {
  for (const cls of ['A', 'B', 'C', 'D']) {
    const store = fakeStore({ 'clients/u1': { wallet: 5 } });
    const res = await lock(store, [client], cls);
    assert.deepEqual(res.writes, []);
    assert.equal(res.parties[0].state, 'active');
    res.applyTo(store.tx);
    assert.deepEqual(store.writes, [], `${cls} : aucun coût pour un compte actif`);
  }
});

test('quarantaine : catégorie A refusée ; B/C/D autorisées avec epoch+1 écrit dans la même transaction', async () => {
  const docs = { 'clients/u1': { wallet: 5 }, 'account_tombstones/u1': { state: 'deleting', phase: 'closing', epoch: 2 } };
  await assert.rejects(lock(fakeStore(docs), [client], 'A'), (e) => e.code === 'failed-precondition' && e.details.code === REFUSAL.CLOSING);
  for (const cls of ['B', 'C', 'D']) {
    const store = fakeStore(docs);
    const res = await lock(store, [client], cls);
    assert.equal(res.writes.length, 1);
    assert.deepEqual(store.writes, [], 'le helper lui-même n’écrit jamais');
    res.applyTo(store.tx);
    assert.deepEqual(store.writes, [['account_tombstones/u1', { epoch: 3, updatedAtMs: 1700000000000 }]]);
  }
});

test('ancien tombstone (sans phase ni epoch) : protégé, lu comme closing epoch 0, passe à epoch 1', async () => {
  const docs = { 'clients/u1': { wallet: 5 }, 'account_tombstones/u1': { createdAt: 'x', state: 'deleting' } };
  await assert.rejects(lock(fakeStore(docs), [client], 'A'), (e) => e.details.code === REFUSAL.CLOSING);
  const store = fakeStore(docs);
  const res = await lock(store, [client], 'C');
  res.applyTo(store.tx);
  assert.deepEqual(store.writes[0][1].epoch, 1);
});

test('scellé : refus pour toutes les catégories, sans écriture, avec un code stable', async () => {
  const docs = { 'clients/u1': { wallet: 5 }, 'account_tombstones/u1': { phase: 'sealed', epoch: 3, sealToken: 't', sealEpoch: 3 } };
  for (const cls of ['A', 'B', 'C', 'D']) {
    const store = fakeStore(docs);
    await assert.rejects(lock(store, [client], cls), (e) => e.code === 'failed-precondition' && e.details.code === REFUSAL.SEALED && e.message === 'Compte supprime ou en cours de suppression', cls);
    assert.deepEqual(store.writes, []);
  }
});

test('tombstone illisible, profil anonymisé ou absent : refusés par défaut, sans écriture', async () => {
  const cases = [
    [{ 'clients/u1': {}, 'account_tombstones/u1': { phase: 'zzz' } }, REFUSAL.UNREADABLE],
    [{ 'clients/u1': { isDeleted: true } }, REFUSAL.ANONYMIZED],
    [{}, REFUSAL.ABSENT],
  ];
  for (const [docs, code] of cases) {
    for (const cls of ['A', 'B', 'C', 'D']) {
      const store = fakeStore(docs);
      await assert.rejects(lock(store, [client], cls), (e) => e.details.code === code, `${cls} ${code}`);
      assert.deepEqual(store.writes, []);
    }
  }
});

test('tombstone sans profil : la protection subsiste (closing) ; B/C/D autorisées, la perte du profil reste au writer', async () => {
  const docs = { 'account_tombstones/u1': {} };
  await assert.rejects(lock(fakeStore(docs), [client], 'A'), (e) => e.details.code === REFUSAL.CLOSING);
  const res = await lock(fakeStore(docs), [client], 'B');
  assert.equal(res.parties[0].state, 'closing');
  assert.equal(res.writes.length, 1);
});

test('bénéficiaire anonymisé ou absent : « skip » omet la partie et la signale ; un bénéficiaire scellé reste refusé', async () => {
  const docs = { 'clients/u1': { wallet: 5 }, 'livreurs/d1': { isDeleted: true }, 'livreurs/d2': {}, 'livreurs/d3': { wallet: 0 }, 'account_tombstones/d3': { phase: 'sealed' } };
  const store = fakeStore(docs);
  const res = await lock(store, [client, { collection: 'livreurs', id: 'd1', onClosed: 'skip' }, { collection: 'livreurs', id: 'missing', onClosed: 'skip' }], 'C');
  assert.deepEqual(res.skipped.map((s) => [s.id, s.state, s.reason]), [['d1', 'anonymized', 'beneficiary_account_closed'], ['missing', 'absent', 'beneficiary_account_closed']]);
  assert.deepEqual(res.parties.map((p) => p.id), ['u1']);
  await assert.rejects(lock(fakeStore(docs), [client, { collection: 'livreurs', id: 'd1' }], 'C'), (e) => e.details.code === REFUSAL.ANONYMIZED, 'défaut : refus');
  await assert.rejects(lock(fakeStore(docs), [client, { collection: 'livreurs', id: 'd3', onClosed: 'skip' }], 'C'), (e) => e.details.code === REFUSAL.SEALED, 'scellé jamais omis');
  await assert.rejects(lock(fakeStore(docs), [client, { collection: 'livreurs', id: 'd1', onClosed: 'skip' }], 'A'), (e) => e.details.code === REFUSAL.ANONYMIZED, 'catégorie A : jamais omis');
});

test('plusieurs parties : lecture déterministe, tombstone avant profil, une seule écriture par tombstone', async () => {
  const docs = {
    'clients/b': {}, 'sellers/a': {}, 'livreurs/c': {},
    'account_tombstones/b': { epoch: 1 }, 'account_tombstones/c': { phase: 'closing', epoch: 7 },
  };
  const store = fakeStore(docs);
  const res = await lock(store, [{ collection: 'livreurs', id: 'c' }, { collection: 'clients', id: 'b' }, { collection: 'sellers', id: 'a' }, { collection: 'clients', id: 'b' }, { collection: 'sellers', id: 'b' }], 'D');
  assert.deepEqual(store.reads, [
    'account_tombstones/a', 'sellers/a',
    'account_tombstones/b', 'clients/b', 'sellers/b',
    'account_tombstones/c', 'livreurs/c',
  ]);
  assert.deepEqual(res.writes.map((w) => [w.ref.path, w.data.epoch]), [['account_tombstones/b', 2], ['account_tombstones/c', 8]], 'un bump par tombstone, même si le compte apparaît sous deux collections');
  assert.deepEqual(store.writes, []);
});

test('toutes les lectures précèdent toute écriture et un refus n’écrit rien', async () => {
  const docs = { 'clients/u1': {}, 'account_tombstones/u1': {}, 'livreurs/d1': {}, 'account_tombstones/d1': { phase: 'sealed' } };
  const store = fakeStore(docs);
  await assert.rejects(lock(store, [client, { collection: 'livreurs', id: 'd1' }], 'B'), (e) => e.details.code === REFUSAL.SEALED);
  assert.deepEqual(store.writes, [], 'refus ⇒ état strictement identique');
});

test('arguments invalides : identité de commande invalide (message historique) ou erreur de programmation', async () => {
  const store = fakeStore({});
  for (const parties of [[], null, [null], [{ collection: 'clients', id: '' }], [{ collection: 'clients', id: 'a/b' }], [{ collection: '', id: 'a' }], [{ collection: 'clients', id: 5 }]]) {
    await assert.rejects(lock(store, parties, 'B'), (e) => e.code === 'failed-precondition' && e.message === 'Identite de commande invalide', JSON.stringify(parties));
  }
  await assert.rejects(lock(store, [client], 'Z'), TypeError);
  assert.deepEqual(store.reads, [], 'aucune lecture avant validation');
});

test('compatibilité : le code d’erreur et le message d’un refus sont ceux de accountAdmission pour la même situation', async () => {
  const situations = [
    { docs: { 'clients/u1': {}, 'account_tombstones/u1': {} }, party: [] },
    { docs: { 'clients/u1': {}, 'account_tombstones/u1': { phase: 'sealed' } }, party: [] },
    { docs: { 'clients/u1': { deletionRequested: true } }, party: [] },
    { docs: { 'clients/u1': { isDeleted: true } }, party: [] },
  ];
  for (const { docs, party } of situations) {
    let legacy; let fresh;
    try { await assertNewAccountActivity(fakeStore(docs).tx, fakeStore(docs).db, HttpsError, 'u1', party); } catch (e) { legacy = e; }
    try { await lock(fakeStore(docs), [client], 'A'); } catch (e) { fresh = e; }
    assert.ok(legacy && fresh, JSON.stringify(docs));
    assert.deepEqual([fresh.code, fresh.message], [legacy.code, legacy.message], JSON.stringify(docs));
  }
});

test('le socle n’est branché que sur les writers de L3 (orderActions.js et ekbineOrders.js), jamais ailleurs', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const root = path.join(__dirname, '..');
  const offenders = fs.readdirSync(root).filter((f) => f.endsWith('.js') && !f.startsWith('accountClosure'))
    .filter((f) => /accountClosure(Lock|State|Registry)/.test(fs.readFileSync(path.join(root, f), 'utf8')));
  assert.ok(offenders.every((f) => ['ekbineOrders.js', 'orderActions.js'].includes(f)), `seuls les writers de L3 importent le socle : ${offenders}`);
});
