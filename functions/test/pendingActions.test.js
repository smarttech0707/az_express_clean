'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall } = require('firebase-functions/v2/https');
const { HttpsError } = require('firebase-functions/v2/https');
const { createPendingAction, buildConfirmAction, DEFAULT_EXPIRY_MS } = require('../azia/pendingActions');

// Fake Firestore : un Map en mémoire + de quoi satisfaire get/set/update
// hors et dans une transaction — suffisant pour tester la logique de
// pendingActions.js sans émulateur.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data) => { store.set(path, data); },
      update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
      __path: path,
    };
  }

  let autoId = 0;
  const db = {
    collection(name) {
      return { doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`) };
    },
    runTransaction: async (fn) => {
      const tx = {
        get: async (ref) => ({ exists: store.has(ref.__path), data: () => store.get(ref.__path) }),
        update: (ref, data) => store.set(ref.__path, { ...(store.get(ref.__path) || {}), ...data }),
        set: (ref, data) => store.set(ref.__path, data),
      };
      return fn(tx);
    },
  };
  return { db, store };
}

const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' },
    Timestamp: { fromMillis: (ms) => ({ toMillis: () => ms }) },
  },
};

function makeLogAudit() {
  const calls = [];
  const logAudit = async (details) => { calls.push(details); };
  logAudit.calls = calls;
  return logAudit;
}

test('createPendingAction writes a pending action expiring ~5 minutes out', async () => {
  const { db, store } = makeFakeDb();
  const before = Date.now();
  const actionId = await createPendingAction(db, fakeAdmin, {
    uid: 'u1', conversationId: 'c1', toolName: 'cancel_order',
    toolInput: { orderId: 'o1' }, summaryFr: 'Annuler...', amount: null,
  });

  const saved = store.get(`ai_pending_actions/${actionId}`);
  assert.equal(saved.status, 'pending');
  assert.equal(saved.uid, 'u1');
  const expiresMs = saved.expiresAt.toMillis();
  assert.ok(expiresMs >= before + DEFAULT_EXPIRY_MS - 1000 && expiresMs <= before + DEFAULT_EXPIRY_MS + 1000);
});

test('aiConfirmAction: happy path calls confirmHandler and marks the action completed', async () => {
  const { db, store } = makeFakeDb({
    'ai_pending_actions/a1': {
      uid: 'u1', toolName: 'test_tool', toolInput: { x: 1 }, status: 'pending',
      amount: 500, expiresAt: { toMillis: () => Date.now() + 60000 },
    },
  });
  const confirmCalls = [];
  const toolsByName = new Map([
    ['test_tool', {
      confirmHandler: async (tx, uid, toolInput) => { confirmCalls.push({ uid, toolInput }); return { orderId: 'o1' }; },
    }],
  ]);
  const logAudit = makeLogAudit();

  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit, HttpsError, toolsByName });
  const result = await fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } });

  assert.deepEqual(result, { status: 'completed', orderId: 'o1' });
  assert.equal(confirmCalls.length, 1);
  assert.equal(confirmCalls[0].uid, 'u1');
  assert.equal(store.get('ai_pending_actions/a1').status, 'completed');
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'ai_confirm_test_tool');
});

test('aiConfirmAction: afterConfirm result is merged into the response', async () => {
  const { db } = makeFakeDb({
    'ai_pending_actions/a1': {
      uid: 'u1', toolName: 'wallet_recharge', toolInput: {}, status: 'pending',
      amount: 1000, expiresAt: { toMillis: () => Date.now() + 60000 },
    },
  });
  const toolsByName = new Map([
    ['wallet_recharge', {
      confirmHandler: async () => ({ txId: 't1' }),
      afterConfirm: async (uid, result) => ({ ...result, paymentUrl: 'https://pay.example/t1' }),
    }],
  ]);
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName });
  const result = await fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } });

  assert.deepEqual(result, { status: 'completed', txId: 't1', paymentUrl: 'https://pay.example/t1' });
});

test('aiConfirmAction: rejects an unknown actionId (not-found)', async () => {
  const { db } = makeFakeDb();
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName: new Map() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'u1' }, data: { actionId: 'ghost' } }),
    (err) => err.code === 'not-found',
  );
});

test('aiConfirmAction: rejects when the caller does not own the action (permission-denied)', async () => {
  const { db } = makeFakeDb({
    'ai_pending_actions/a1': { uid: 'owner', toolName: 't', status: 'pending', expiresAt: { toMillis: () => Date.now() + 60000 } },
  });
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName: new Map() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'intruder' }, data: { actionId: 'a1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('aiConfirmAction: rejects a tool without a confirmHandler (failed-precondition)', async () => {
  const { db } = makeFakeDb({
    'ai_pending_actions/a1': { uid: 'u1', toolName: 'search_marketplace', status: 'pending', expiresAt: { toMillis: () => Date.now() + 60000 } },
  });
  const toolsByName = new Map([['search_marketplace', { /* no confirmHandler: read-only tool */ }]]);
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('aiConfirmAction: an expired action fails closed and flips to expired', async () => {
  const { db, store } = makeFakeDb({
    'ai_pending_actions/a1': {
      uid: 'u1', toolName: 't', status: 'pending',
      expiresAt: { toMillis: () => Date.now() - 1000 }, // déjà expirée
    },
  });
  const toolsByName = new Map([['t', { confirmHandler: async () => ({}) }]]);
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } }),
    (err) => err.code === 'deadline-exceeded',
  );
  assert.equal(store.get('ai_pending_actions/a1').status, 'expired');
});

test('aiConfirmAction: a double-tap (replay) is rejected once the action is already completed', async () => {
  const { db } = makeFakeDb({
    'ai_pending_actions/a1': {
      uid: 'u1', toolName: 't', toolInput: {}, status: 'pending',
      expiresAt: { toMillis: () => Date.now() + 60000 },
    },
  });
  let calls = 0;
  const toolsByName = new Map([['t', { confirmHandler: async () => { calls++; return { ok: true }; } }]]);
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName });

  const first = await fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } });
  assert.equal(first.status, 'completed');

  await assert.rejects(
    () => fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1' } }),
    (err) => err.code === 'failed-precondition',
  );
  assert.equal(calls, 1, 'confirmHandler must not run twice on replay');
});

test('aiConfirmAction: decision=cancel marks the action cancelled without running confirmHandler', async () => {
  const { db, store } = makeFakeDb({
    'ai_pending_actions/a1': { uid: 'u1', toolName: 't', status: 'pending', expiresAt: { toMillis: () => Date.now() + 60000 } },
  });
  let ran = false;
  const toolsByName = new Map([['t', { confirmHandler: async () => { ran = true; return {}; } }]]);
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName });

  const result = await fn.run({ auth: { uid: 'u1' }, data: { actionId: 'a1', decision: 'cancel' } });
  assert.deepEqual(result, { status: 'cancelled' });
  assert.equal(ran, false);
  assert.equal(store.get('ai_pending_actions/a1').status, 'cancelled');
});

test('aiConfirmAction: rejects unauthenticated calls', async () => {
  const { db } = makeFakeDb();
  const fn = buildConfirmAction({ db, admin: fakeAdmin, onCall, logAudit: makeLogAudit(), HttpsError, toolsByName: new Map() });
  await assert.rejects(
    () => fn.run({ data: { actionId: 'a1' } }),
    (err) => err.code === 'unauthenticated',
  );
});
