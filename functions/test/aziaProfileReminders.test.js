'use strict';

// Master Prompt 118 — profil enrichi (carnet d'adresses nommées), rappels
// (create_reminder + scheduler d'envoi), et insights de contexte dérivés de
// données réelles (dernière commande, vendeur fréquent, solde faible).
// Même fake Firestore que test/aziaMemoryEkbineContext.test.js, étendu pour
// couvrir les requêtes du scheduler de rappels.

const test = require('node:test');
const assert = require('node:assert/strict');

const { rememberNamedAddress } = require('../azia/tools/memory');
const { createReminder } = require('../azia/tools/reminders');
const { buildReminderScheduler } = require('../azia/reminderScheduler');
const { collectUserContext } = require('../azia/contextBuilder');

function fakeTimestamp(ms) {
  return { __ts: ms, toDate: () => new Date(ms), toMillis: () => ms };
}

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;

  function applyMerge(existing, data) {
    return { ...existing, ...data };
  }

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        store.set(path, opts && opts.merge ? applyMerge(store.get(path) || {}, data) : data);
      },
      update: async (data) => { store.set(path, applyMerge(store.get(path) || {}, data)); },
      collection: (sub) => makeCollection(`${path}/${sub}`),
    };
  }

  function matchingDocs(prefix, filters) {
    return [...store.entries()]
      .filter(([k]) => k.startsWith(`${prefix}/`) && !k.slice(prefix.length + 1).includes('/'))
      .filter(([, data]) => filters.every(([field, op, value]) => {
        const v = data[field];
        if (op === '==') return v === value;
        if (op === '<=') {
          const a = v && v.__ts !== undefined ? v.__ts : v;
          const b = value && value.__ts !== undefined ? value.__ts : value;
          return a <= b;
        }
        return true;
      }))
      .map(([k, data]) => ({ id: k.split('/').pop(), data: () => data, ref: makeRef(k) }));
  }

  function makeQuery(prefix, filters, order) {
    return {
      where: (field, op, value) => makeQuery(prefix, [...filters, [field, op, value]], order),
      orderBy: (field, dir) => makeQuery(prefix, filters, { field, dir: dir || 'asc' }),
      limit: (n) => ({
        get: async () => {
          let docs = matchingDocs(prefix, filters);
          if (order) {
            docs.sort((a, b) => {
              const av = a.data()[order.field]?.__ts ?? a.data()[order.field] ?? 0;
              const bv = b.data()[order.field]?.__ts ?? b.data()[order.field] ?? 0;
              return order.dir === 'desc' ? bv - av : av - bv;
            });
          }
          docs = docs.slice(0, n);
          return { empty: docs.length === 0, docs, size: docs.length };
        },
      }),
      get: async () => {
        const docs = matchingDocs(prefix, filters);
        return { empty: docs.length === 0, docs, size: docs.length };
      },
    };
  }

  function makeCollection(name) {
    return {
      doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
      add: async (data) => {
        const path = `${name}/auto${autoId++}`;
        store.set(path, data);
        return { id: path.split('/').pop() };
      },
      where: (field, op, value) => makeQuery(name, [[field, op, value]]),
      orderBy: (field, dir) => makeQuery(name, [], { field, dir: dir || 'asc' }),
    };
  }

  return {
    db: { collection: (name) => makeCollection(name) },
    store,
  };
}

const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' },
    Timestamp: { fromMillis: (ms) => fakeTimestamp(ms), now: () => fakeTimestamp(Date.now()) },
  },
};

// ── remember_named_address ──────────────────────────────────────────────

test('remember_named_address: saves a new named address', async () => {
  const { db, store } = makeFakeDb();
  const tool = rememberNamedAddress({ db, admin: fakeAdmin });

  const result = await tool.handler('u1', { label: 'Maison', address: 'Cafétou, près du marché' });
  assert.equal(result.saved, true);
  const saved = store.get('ai_user_memory/u1');
  assert.deepEqual(saved.addresses, [{ label: 'maison', address: 'Cafétou, près du marché' }]);
});

test('remember_named_address: updates an existing label instead of duplicating it', async () => {
  const { db, store } = makeFakeDb({
    'ai_user_memory/u1': { addresses: [{ label: 'bureau', address: 'Ancien bureau' }] },
  });
  const tool = rememberNamedAddress({ db, admin: fakeAdmin });

  await tool.handler('u1', { label: 'Bureau', address: 'Nouveau bureau, Plateau' });
  const saved = store.get('ai_user_memory/u1');
  assert.equal(saved.addresses.length, 1);
  assert.equal(saved.addresses[0].address, 'Nouveau bureau, Plateau');
});

test('remember_named_address: rejects a missing label or address', async () => {
  const { db } = makeFakeDb();
  const tool = rememberNamedAddress({ db, admin: fakeAdmin });

  const result = await tool.handler('u1', { label: '', address: 'x' });
  assert.equal(result.saved, false);
});

// ── create_reminder ──────────────────────────────────────────────────────

test('create_reminder: creates a reminder with an explicit inMinutes offset', async () => {
  const { db, store } = makeFakeDb();
  const tool = createReminder({ db, admin: fakeAdmin });

  const before = Date.now();
  const result = await tool.handler('u1', { type: 'recharger', message: 'Recharge ton wallet', inMinutes: 60 });
  assert.ok(result.reminderId);
  const saved = [...store.values()].find(v => v.uid === 'u1');
  assert.equal(saved.type, 'recharger');
  assert.equal(saved.status, 'pending');
  assert.ok(saved.dueAt.toMillis() >= before + 59 * 60 * 1000);
});

test('create_reminder: falls back to a default delay when neither inMinutes nor a valid atIso is given', async () => {
  const { db, store } = makeFakeDb();
  const tool = createReminder({ db, admin: fakeAdmin });

  await tool.handler('u1', { type: 'medicament', message: 'Prendre le médicament' });
  const saved = [...store.values()].find(v => v.uid === 'u1');
  assert.ok(saved.dueAt.toMillis() > Date.now()); // repli 24h, toujours dans le futur
});

test('create_reminder: rejects a missing message', async () => {
  const { db } = makeFakeDb();
  const tool = createReminder({ db, admin: fakeAdmin });
  await assert.rejects(() => tool.handler('u1', { type: 'payer', message: '' }), /requis/);
});

test('create_reminder: an invalid type falls back to "autre" rather than throwing', async () => {
  const { db, store } = makeFakeDb();
  const tool = createReminder({ db, admin: fakeAdmin });
  await tool.handler('u1', { type: 'bogus', message: 'x' });
  const saved = [...store.values()].find(v => v.uid === 'u1');
  assert.equal(saved.type, 'autre');
});

// ── reminderScheduler ─────────────────────────────────────────────────────

test('reminderScheduler: sends a push and marks a due reminder as sent', async () => {
  const past = Date.now() - 1000;
  const { db, store } = makeFakeDb({
    'ai_reminders/r1': { uid: 'u1', type: 'payer', message: 'Paye la commande', status: 'pending', dueAt: fakeTimestamp(past) },
    'clients/u1': { fcmToken: 'tok123' },
  });
  const sent = [];
  const sendToToken = async (token, title, body) => { sent.push({ token, title, body }); };
  const scheduler = buildReminderScheduler({ db, admin: fakeAdmin, onSchedule: (opts, fn) => ({ run: fn }), sendToToken });

  await scheduler.run();

  assert.equal(sent.length, 1);
  assert.equal(sent[0].token, 'tok123');
  assert.equal(sent[0].body, 'Paye la commande');
  assert.equal(store.get('ai_reminders/r1').status, 'sent');
});

test('reminderScheduler: does not touch a reminder not yet due', async () => {
  const future = Date.now() + 60 * 60 * 1000;
  const { db, store } = makeFakeDb({
    'ai_reminders/r1': { uid: 'u1', type: 'payer', message: 'x', status: 'pending', dueAt: fakeTimestamp(future) },
    'clients/u1': { fcmToken: 'tok123' },
  });
  const sendToToken = async () => { throw new Error('should not be called'); };
  const scheduler = buildReminderScheduler({ db, admin: fakeAdmin, onSchedule: (opts, fn) => ({ run: fn }), sendToToken });

  await scheduler.run();
  assert.equal(store.get('ai_reminders/r1').status, 'pending');
});

test('reminderScheduler: marks as sent even without a known fcmToken (never crashes on a missing token)', async () => {
  const past = Date.now() - 1000;
  const { db, store } = makeFakeDb({
    'ai_reminders/r1': { uid: 'u1', type: 'payer', message: 'x', status: 'pending', dueAt: fakeTimestamp(past) },
    'clients/u1': {},
  });
  let called = false;
  const sendToToken = async () => { called = true; };
  const scheduler = buildReminderScheduler({ db, admin: fakeAdmin, onSchedule: (opts, fn) => ({ run: fn }), sendToToken });

  await scheduler.run();
  assert.equal(called, false);
  assert.equal(store.get('ai_reminders/r1').status, 'sent');
});

// ── contextBuilder insights (Master Prompt 118) ──────────────────────────

test('collectUserContext: addresses rubric returns named addresses and nothing else', async () => {
  const { db } = makeFakeDb({
    'clients/u1': { name: 'Awa', phone: '+2250700000000', wallet: 100 },
    'ai_user_memory/u1': { addresses: [{ label: 'maison', address: 'Cafétou' }, { label: 'bureau', address: 'Plateau' }] },
  });
  const r = await collectUserContext(db, 'u1', ['addresses'], null);
  assert.deepEqual(r.namedAddresses, [{ label: 'maison', address: 'Cafétou' }, { label: 'bureau', address: 'Plateau' }]);
  const flat = JSON.stringify(r);
  assert.ok(!flat.includes('+2250700000000') && !flat.includes('Awa') && !flat.includes('100'));
});

test('collectUserContext: last_order rubric returns the last real order and a genuinely frequent seller', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'u1', sellerName: 'Chez Awa', budget: 2000, createdAt: fakeTimestamp(5) },
    'orders/o2': { clientId: 'u1', sellerName: 'Chez Awa', budget: 1800, createdAt: fakeTimestamp(4) },
    'orders/o3': { clientId: 'u1', sellerName: 'Chez Awa', budget: 1900, createdAt: fakeTimestamp(3) },
    'orders/o4': { clientId: 'u1', sellerName: 'Autre Vendeur', budget: 500, createdAt: fakeTimestamp(2) },
  });
  const r = await collectUserContext(db, 'u1', ['last_order'], null);
  assert.equal(r.lastOrder.label, 'Chez Awa');
  assert.equal(r.frequentSeller.name, 'Chez Awa');
});

test('collectUserContext: no "frequent seller" below the real threshold (no false positive)', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'u1', sellerName: 'Chez Awa', budget: 2000, createdAt: fakeTimestamp(2) },
    'orders/o2': { clientId: 'u1', sellerName: 'Autre Vendeur', budget: 500, createdAt: fakeTimestamp(1) },
  });
  assert.equal((await collectUserContext(db, 'u1', ['last_order'], null)).frequentSeller, null);
});
