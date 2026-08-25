'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildResetAccountPassword, normalizePhone } = require('../passwordReset');

function fakeDb(seed) {
  const store = new Map(Object.entries(seed));
  function ref(path) {
    return {
      id: path.split('/').pop(),
      update: async (data) => store.set(path, { ...(store.get(path) || {}), ...data }),
      set: async (data) => store.set(path, data),
    };
  }
  return {
    store,
    collection(name) {
      return {
        doc: (id) => ref(`${name}/${id}`),
        where(field, _op, value) {
          return {
            limit() {
              return {
                async get() {
                  const docs = [];
                  for (const [path, data] of store) {
                    if (!path.startsWith(`${name}/`) || path.slice(name.length + 1).includes('/')) continue;
                    if (data[field] === value) docs.push({ ...ref(path), data: () => data });
                  }
                  return { empty: docs.length === 0, docs };
                },
              };
            },
          };
        },
      };
    },
  };
}

function makeHandler(seed = { 'clients/email-uid': { phone: '+2250701020304' } }) {
  const db = fakeDb(seed);
  const updates = [];
  const auth = {
    getUser: async (uid) => ({ uid, providerData: [{ providerId: 'password' }] }),
    updateUser: async (uid, data) => updates.push({ uid, data }),
  };
  const handler = buildResetAccountPassword({
    db, auth,
    fieldValue: { serverTimestamp: () => 'now', delete: () => 'deleted' },
    hashSecret: (value) => `hash:${value}`,
    checkRateLimit: async () => {},
  });
  return { handler, updates, db };
}

function request(overrides = {}) {
  return {
    auth: { uid: 'temporary-phone-uid', token: { phone_number: '+2250701020304' } },
    data: { userType: 'client', phone: '0701020304', newValue: 'Secure123', ...overrides },
  };
}

test('normalise le format national ivoirien sans supprimer le zero', () => {
  assert.equal(normalizePhone('07 01 02 03 04'), '+2250701020304');
  assert.equal(normalizePhone('+225 07 01 02 03 04'), '+2250701020304');
  assert.equal(normalizePhone('01 02 03 04'), '+22501020304');
});

test('met a jour exactement UID du document cible, jamais UID de la session telephone', async () => {
  const { handler, updates } = makeHandler();
  const result = await handler(request());
  assert.deepEqual(result, { success: true, uid: 'email-uid' });
  assert.deepEqual(updates, [{ uid: 'email-uid', data: { password: 'Secure123' } }]);
  assert.notEqual(updates[0].uid, 'temporary-phone-uid');
});

test('refuse un numero demande different du numero OTP verifie', async () => {
  const { handler, updates } = makeHandler();
  await assert.rejects(handler(request({ phone: '0501020304' })),
    (error) => error.code === 'permission-denied');
  assert.equal(updates.length, 0);
});

test('refuse une session sans preuve Phone Auth', async () => {
  const { handler } = makeHandler();
  const req = request();
  req.auth.token = {};
  await assert.rejects(handler(req), (error) => error.code === 'unauthenticated');
});

test('refuse les doublons au lieu de choisir arbitrairement un compte', async () => {
  const { handler, updates } = makeHandler({
    'clients/uid-a': { phone: '+2250701020304' },
    'clients/uid-b': { phone: '+2250701020304' },
  });
  await assert.rejects(handler(request()), (error) => error.code === 'failed-precondition');
  assert.equal(updates.length, 0);
});

test('refuse un mot de passe faible avant toute modification Auth', async () => {
  const { handler, updates } = makeHandler();
  await assert.rejects(handler(request({ newValue: 'faible' })),
    (error) => error.code === 'invalid-argument');
  assert.equal(updates.length, 0);
});
