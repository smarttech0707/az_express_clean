'use strict';

const nodeTest = require('node:test');
const { AsyncLocalStorage } = require('node:async_hooks');
const { randomUUID } = require('node:crypto');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

// A timed-out test may keep running. Its async chain retains its own immutable
// context and demo project; a later test never deletes or reuses that database.
function createIsolatedFirestoreTest(prefix) {
  assert.match(process.env.FIRESTORE_EMULATOR_HOST || '', /^(127\.0\.0\.1|localhost):\d+$/);
  assert.match(prefix, /^demo-[a-z0-9-]+$/);
  const storage = new AsyncLocalStorage();
  let setup = async () => {};
  const fixture = () => {
    const value = storage.getStore();
    assert.ok(value, 'Firestore fixture accessed outside its test');
    return value;
  };
  const db = new Proxy({}, { get(_target, key) {
    const current = fixture().db;
    const value = current[key];
    return typeof value === 'function' ? value.bind(current) : value;
  } });
  function test(name, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    return nodeTest(name, options, async context => {
      const projectId = `${prefix}-${randomUUID().replace(/-/g, '').slice(0, 12)}`;
      const app = admin.initializeApp({ projectId }, projectId);
      const state = { db: app.firestore(), projectId };
      return storage.run(state, async () => {
        try { await setup(context); await callback(context); }
        finally { await app.delete(); }
      });
    });
  }
  test.beforeEach = callback => { setup = callback; };
  const ref = path => new Proxy({}, { get(_target, key) {
    const current = fixture().db.doc(path);
    const value = current[key];
    return typeof value === 'function' ? value.bind(current) : value;
  } });
  return { test, db, fixture, ref };
}

module.exports = { createIsolatedFirestoreTest };
