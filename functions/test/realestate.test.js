'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { createRealEstateFunctions, createVisitRequest, VISIT_TRANSITIONS } = require('../realestate');

// Même fake Firestore minimaliste que test/pendingActions.test.js — un Map en
// mémoire suffisant pour get/set/update, hors et dans une transaction.
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
        set: (ref, data) => store.set(ref.__path, data),
        update: (ref, data) => store.set(ref.__path, { ...(store.get(ref.__path) || {}), ...data }),
      };
      return fn(tx);
    },
  };
  return { db, store };
}

const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' } } };

function noopLogAudit() {}
async function noopCheckRateLimit() {}

// ── createVisitRequest (logique partagée Flutter + outil AZ IA) ────────────

test('createVisitRequest fails when the listing does not exist', async () => {
  const { db } = makeFakeDb();
  await assert.rejects(
    () => createVisitRequest(db, fakeAdmin, { uid: 'u1', listingId: 'ghost' }),
    /introuvable/,
  );
});

test('createVisitRequest fails when the listing is not active', async () => {
  const { db } = makeFakeDb({ 'real_estate_listings/l1': { title: 'Villa', status: 'hidden', agentId: 'a1' } });
  await assert.rejects(
    () => createVisitRequest(db, fakeAdmin, { uid: 'u1', listingId: 'l1' }),
    /plus disponible/,
  );
});

test('createVisitRequest (non-transactional path) creates a pending request', async () => {
  const { db, store } = makeFakeDb({ 'real_estate_listings/l1': { title: 'Villa Cocody', status: 'active', agentId: 'a1' } });
  const result = await createVisitRequest(db, fakeAdmin, { uid: 'u1', listingId: 'l1', preferredDate: 'samedi' });

  assert.equal(result.agentId, 'a1');
  const saved = store.get(`real_estate_visit_requests/${result.requestId}`);
  assert.equal(saved.status, 'pending');
  assert.equal(saved.clientId, 'u1');
  assert.equal(saved.agentId, 'a1');
  assert.equal(saved.preferredDate, 'samedi');
});

test('createVisitRequest (transactional path) also works, using tx.get/tx.set', async () => {
  const { db, store } = makeFakeDb({ 'real_estate_listings/l1': { title: 'Studio Marcory', status: 'active', agentId: 'a2' } });
  let result;
  await db.runTransaction(async (tx) => {
    result = await createVisitRequest(db, fakeAdmin, { uid: 'u2', listingId: 'l1' }, tx);
  });
  const saved = store.get(`real_estate_visit_requests/${result.requestId}`);
  assert.equal(saved.status, 'pending');
  assert.equal(saved.clientId, 'u2');
});

// ── respondToVisitRequest (transitions de statut) ───────────────────────────

function buildFns(seedStore) {
  const { db, store } = makeFakeDb(seedStore);
  const fns = createRealEstateFunctions({
    db, admin: fakeAdmin, onCall, onDocumentCreated, onDocumentUpdated,
    checkRateLimit: noopCheckRateLimit, logAudit: noopLogAudit, HttpsError,
    sendToToken: async () => {},
  });
  return { fns, store };
}

test('respondToVisitRequest: agent can propose a date on a pending request', async () => {
  const { fns, store } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  const result = await fns.respondToVisitRequest.run({
    auth: { uid: 'agent1' },
    data: { requestId: 'r1', action: 'propose', proposedDate: '2026-07-10T10:00:00' },
  });
  assert.deepEqual(result, { success: true, status: 'proposed' });
  assert.equal(store.get('real_estate_visit_requests/r1').status, 'proposed');
  assert.equal(store.get('real_estate_visit_requests/r1').proposedDate, '2026-07-10T10:00:00');
});

test('respondToVisitRequest: propose requires a proposedDate', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'agent1' }, data: { requestId: 'r1', action: 'propose' } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('respondToVisitRequest: client can confirm once a date has been proposed', async () => {
  const { fns, store } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'proposed', proposedDate: '2026-07-10' },
  });
  const result = await fns.respondToVisitRequest.run({
    auth: { uid: 'client1' }, data: { requestId: 'r1', action: 'confirm' },
  });
  assert.deepEqual(result, { success: true, status: 'confirmed' });
  assert.equal(store.get('real_estate_visit_requests/r1').status, 'confirmed');
});

test('respondToVisitRequest: client cannot confirm a request still pending (no date proposed yet)', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'client1' }, data: { requestId: 'r1', action: 'confirm' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('respondToVisitRequest: the agent cannot confirm (wrong role for that action)', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'proposed' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'agent1' }, data: { requestId: 'r1', action: 'confirm' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('respondToVisitRequest: a stranger cannot act on someone else\'s request', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'intruder' }, data: { requestId: 'r1', action: 'propose', proposedDate: 'x' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('respondToVisitRequest: client can cancel a pending or proposed request', async () => {
  const { fns, store } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  const result = await fns.respondToVisitRequest.run({ auth: { uid: 'client1' }, data: { requestId: 'r1', action: 'cancel' } });
  assert.deepEqual(result, { success: true, status: 'cancelled' });
  assert.equal(store.get('real_estate_visit_requests/r1').status, 'cancelled');
});

test('respondToVisitRequest: agent can decline a pending or proposed request', async () => {
  const { fns, store } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'proposed' },
  });
  const result = await fns.respondToVisitRequest.run({ auth: { uid: 'agent1' }, data: { requestId: 'r1', action: 'decline' } });
  assert.deepEqual(result, { success: true, status: 'declined' });
  assert.equal(store.get('real_estate_visit_requests/r1').status, 'declined');
});

test('respondToVisitRequest: no transition is possible from a terminal status', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'confirmed' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'agent1' }, data: { requestId: 'r1', action: 'decline' } }),
    (err) => err.code === 'failed-precondition',
  );
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'client1' }, data: { requestId: 'r1', action: 'cancel' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('respondToVisitRequest: rejects an unknown action', async () => {
  const { fns } = buildFns({
    'real_estate_visit_requests/r1': { clientId: 'client1', agentId: 'agent1', status: 'pending' },
  });
  await assert.rejects(
    () => fns.respondToVisitRequest.run({ auth: { uid: 'client1' }, data: { requestId: 'r1', action: 'bogus' } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('VISIT_TRANSITIONS: every transition targets a distinct, sane status', () => {
  const targets = Object.values(VISIT_TRANSITIONS).map((t) => t.to);
  assert.deepEqual(new Set(targets).size, targets.length);
  for (const t of Object.values(VISIT_TRANSITIONS)) {
    assert.ok(['agent', 'client'].includes(t.by));
    assert.ok(Array.isArray(t.from) && t.from.length > 0);
  }
});

// ── submitRealEstateAgentRequest / approveRealEstateAgentRequest ───────────

test('approveRealEstateAgentRequest: rejects a non-admin caller', async () => {
  const { fns } = buildFns({
    'real_estate_agent_requests/req1': { uid: 'u1', name: 'Agence X', phone: '070000000', status: 'pending' },
  });
  await assert.rejects(
    () => fns.approveRealEstateAgentRequest.run({ auth: { uid: 'not-an-admin' }, data: { requestId: 'req1', decision: 'approve' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('approveRealEstateAgentRequest: approving creates the agent and marks the request approved', async () => {
  const { fns, store } = buildFns({
    'admins/admin1': { role: 'super', isActive: true },
    'real_estate_agent_requests/req1': { uid: 'agentUid1', name: 'Agence X', phone: '070000000', status: 'pending' },
  });
  const result = await fns.approveRealEstateAgentRequest.run({
    auth: { uid: 'admin1' }, data: { requestId: 'req1', decision: 'approve' },
  });
  assert.deepEqual(result, { success: true });
  assert.equal(store.get('real_estate_agent_requests/req1').status, 'approved');
  const agent = store.get('real_estate_agents/agentUid1');
  assert.equal(agent.isVerified, true);
  assert.equal(agent.isActive, true);
});

test('approveRealEstateAgentRequest: rejecting does not create an agent', async () => {
  const { fns, store } = buildFns({
    'admins/admin1': { role: 'super', isActive: true },
    'real_estate_agent_requests/req1': { uid: 'agentUid1', name: 'Agence X', phone: '070000000', status: 'pending' },
  });
  await fns.approveRealEstateAgentRequest.run({ auth: { uid: 'admin1' }, data: { requestId: 'req1', decision: 'reject' } });
  assert.equal(store.get('real_estate_agent_requests/req1').status, 'rejected');
  assert.equal(store.get('real_estate_agents/agentUid1'), undefined);
});

test('approveRealEstateAgentRequest: rejects a sub-admin and a disabled super-admin', async () => {
  for (const admin of [
    { role: 'sub', isActive: true, permissions: ['ekbine'] },
    { role: 'super', isActive: false },
  ]) {
    const { fns } = buildFns({
      'admins/admin1': admin,
      'real_estate_agent_requests/req1': { uid: 'u1', name: 'Agence X', phone: '070000000', status: 'pending' },
    });
    await assert.rejects(
      () => fns.approveRealEstateAgentRequest.run({ auth: { uid: 'admin1' }, data: { requestId: 'req1', decision: 'approve' } }),
      (err) => err.code === 'permission-denied',
    );
  }
});
