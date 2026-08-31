'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall } = require('firebase-functions/v2/https');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildLogAuthEvent, buildLogAdminAuditEvent } = require('../authEvents');

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  return {
    store,
    collection: (name) => ({
      doc: (id) => ({
        get: async () => ({ exists: store.has(`${name}/${id}`), data: () => store.get(`${name}/${id}`) }),
      }),
    }),
  };
}

function makeCheckRateLimit() {
  const calls = [];
  const fn = async (uid, action) => { calls.push({ uid, action }); };
  fn.calls = calls;
  return fn;
}

function makeLogAudit() {
  const calls = [];
  const fn = async (details) => { calls.push(details); };
  fn.calls = calls;
  return fn;
}

// ── logAuthEvent ─────────────────────────────────────────────────────────

test('logAuthEvent: records a login for a known user type', async () => {
  const logAudit = makeLogAudit();
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit });

  const result = await fn.run({ auth: { uid: 'u1' }, data: { event: 'login', userType: 'client' } });

  assert.deepEqual(result, { success: true });
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'auth_login');
  assert.equal(logAudit.calls[0].userId, 'u1');
  assert.equal(logAudit.calls[0].userType, 'client');
});

test('logAuthEvent: records a logout', async () => {
  const logAudit = makeLogAudit();
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit });

  await fn.run({ auth: { uid: 'd1' }, data: { event: 'logout', userType: 'livreur' } });

  assert.equal(logAudit.calls[0].action, 'auth_logout');
  assert.equal(logAudit.calls[0].userType, 'livreur');
});

test('logAuthEvent: falls back to "unknown" for an unrecognized userType rather than trusting it verbatim', async () => {
  const logAudit = makeLogAudit();
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit });

  await fn.run({ auth: { uid: 'u1' }, data: { event: 'login', userType: 'totally-made-up' } });

  assert.equal(logAudit.calls[0].userType, 'unknown');
});

test('logAuthEvent: rejects an invalid event name', async () => {
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'u1' }, data: { event: 'delete_everything' } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('logAuthEvent: rejects unauthenticated calls', async () => {
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ data: { event: 'login' } }),
    (err) => err.code === 'unauthenticated',
  );
});

test('logAuthEvent: rate-limits per caller', async () => {
  const checkRateLimit = makeCheckRateLimit();
  const fn = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit, logAudit: makeLogAudit() });
  await fn.run({ auth: { uid: 'u1' }, data: { event: 'login', userType: 'client' } });
  assert.equal(checkRateLimit.calls.length, 1);
  assert.equal(checkRateLimit.calls[0].uid, 'u1');
  assert.equal(checkRateLimit.calls[0].action, 'auth_event');
});

// ── logAdminAuditEvent ───────────────────────────────────────────────────

test('logAdminAuditEvent: an active super-admin can log a permissions_changed event', async () => {
  const { db } = (() => {
    const d = makeFakeDb({ 'admins/a1': { role: 'super', isActive: true } });
    return { db: d };
  })();
  const logAudit = makeLogAudit();
  const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit });

  const result = await fn.run({
    auth: { uid: 'a1' },
    data: { action: 'permissions_changed', targetId: 'sub1', metadata: { added: ['restaurants'] } },
  });

  assert.deepEqual(result, { success: true });
  assert.equal(logAudit.calls[0].action, 'permissions_changed');
  assert.equal(logAudit.calls[0].userType, 'admin');
  assert.equal(logAudit.calls[0].targetId, 'sub1');
  assert.deepEqual(logAudit.calls[0].metadata, { added: ['restaurants'] });
});

test('logAdminAuditEvent: rejects a caller who is not in admins/', async () => {
  const db = makeFakeDb();
  const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'intruder' }, data: { action: 'permissions_changed' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('logAdminAuditEvent: rejects a deactivated admin', async () => {
  const db = makeFakeDb({ 'admins/a1': { isActive: false } });
  const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'a1' }, data: { action: 'permissions_changed' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('logAdminAuditEvent: rejects an action outside the allowlist', async () => {
  const db = makeFakeDb({ 'admins/a1': { role: 'super', isActive: true } });
  const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'a1' }, data: { action: 'delete_database' } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('logAdminAuditEvent: rejects a sub-admin and an unknown role', async () => {
  for (const admin of [
    { role: 'sub', isActive: true, permissions: ['commandes'] },
    { role: 'unknown', isActive: true },
  ]) {
    const db = makeFakeDb({ 'admins/a1': admin });
    const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
    await assert.rejects(
      () => fn.run({ auth: { uid: 'a1' }, data: { action: 'permissions_changed' } }),
      (err) => err.code === 'permission-denied',
    );
  }
});

test('logAdminAuditEvent: rejects unauthenticated calls', async () => {
  const db = makeFakeDb();
  const fn = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit() });
  await assert.rejects(
    () => fn.run({ data: { action: 'permissions_changed' } }),
    (err) => err.code === 'unauthenticated',
  );
});
