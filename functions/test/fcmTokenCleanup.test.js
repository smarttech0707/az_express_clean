'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { runFcmTokenCleanup, clearTokenFromAccounts, FCM_TOKEN_COLLECTIONS } = require('../fcmTokenCleanup');

// Fake Firestore couvrant exactement ce que fcmTokenCleanup.js touche :
// collection('invalid_fcm_tokens').limit().get(), collection(name).where(
// 'fcmToken','==',token).limit().get(), et db.batch() pour effacer/supprimer.
function makeFakeDb({ invalidTokens = {}, accounts = {} } = {}) {
  const store = new Map();
  for (const [id, data] of Object.entries(invalidTokens)) {
    store.set(`invalid_fcm_tokens/${id}`, data);
  }
  for (const [collectionName, docs] of Object.entries(accounts)) {
    for (const [id, data] of Object.entries(docs)) {
      store.set(`${collectionName}/${id}`, data);
    }
  }

  function makeRef(path) {
    return {
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
    };
  }

  const db = {
    collection: (name) => ({
      limit: (n) => ({
        get: async () => {
          const prefix = `${name}/`;
          const docs = [...store.entries()]
            .filter(([k]) => k.startsWith(prefix) && !k.slice(prefix.length).includes('/'))
            .slice(0, n)
            .map(([k, data]) => ({ id: k.slice(prefix.length), data: () => data, ref: makeRef(k) }));
          return { empty: docs.length === 0, size: docs.length, docs };
        },
      }),
      where: (field, _op, value) => ({
        limit: (n) => ({
          get: async () => {
            const prefix = `${name}/`;
            const docs = [...store.entries()]
              .filter(([k, data]) => k.startsWith(prefix) && !k.slice(prefix.length).includes('/') && data[field] === value)
              .slice(0, n)
              .map(([k, data]) => ({ id: k.slice(prefix.length), data: () => data, ref: makeRef(k) }));
            return { empty: docs.length === 0, size: docs.length, docs };
          },
        }),
      }),
    }),
    batch: () => {
      const ops = [];
      return {
        update: (ref, data) => ops.push({ type: 'update', ref, data }),
        delete: (ref) => ops.push({ type: 'delete', ref }),
        commit: async () => {
          ops.forEach((op) => {
            if (op.type === 'delete') {
              store.delete(op.ref.__path);
            } else if (op.type === 'update') {
              const existing = store.get(op.ref.__path) || {};
              const next = { ...existing };
              for (const [k, v] of Object.entries(op.data)) {
                if (v && v.__delete) delete next[k];
                else next[k] = v;
              }
              store.set(op.ref.__path, next);
            }
          });
        },
      };
    },
  };

  return { db, store };
}

const fakeAdmin = {
  firestore: { FieldValue: { delete: () => ({ __delete: true }) } },
};

test('FCM_TOKEN_COLLECTIONS includes the main account types', () => {
  for (const c of ['clients', 'livreurs', 'sellers', 'admins']) {
    assert.ok(FCM_TOKEN_COLLECTIONS.includes(c));
  }
});

test('clearTokenFromAccounts: clears the fcmToken field on the account that holds it', async () => {
  const { db, store } = makeFakeDb({
    accounts: { livreurs: { d1: { fcmToken: 'dead-token', name: 'Kouassi' } } },
  });

  const cleared = await clearTokenFromAccounts(db, fakeAdmin, 'dead-token');

  assert.equal(cleared, 1);
  assert.equal('fcmToken' in store.get('livreurs/d1'), false);
  assert.equal(store.get('livreurs/d1').name, 'Kouassi'); // rest of the doc untouched
});

test('clearTokenFromAccounts: no-op when no account holds the token anymore', async () => {
  const { db } = makeFakeDb({
    accounts: { clients: { c1: { fcmToken: 'still-valid-token' } } },
  });

  const cleared = await clearTokenFromAccounts(db, fakeAdmin, 'long-gone-token');
  assert.equal(cleared, 0);
});

test('runFcmTokenCleanup: processes every invalid_fcm_tokens entry and removes it after handling', async () => {
  const { db, store } = makeFakeDb({
    invalidTokens: {
      t1: { token: 'dead-1' },
      t2: { token: 'dead-2' },
    },
    accounts: {
      clients:  { c1: { fcmToken: 'dead-1' } },
      livreurs: { d1: { fcmToken: 'dead-2' } },
    },
  });

  const result = await runFcmTokenCleanup(db, fakeAdmin);

  assert.equal(result.processed, 2);
  assert.equal(result.accountsCleared, 2);
  assert.equal('fcmToken' in store.get('clients/c1'), false);
  assert.equal('fcmToken' in store.get('livreurs/d1'), false);
  assert.equal(store.has('invalid_fcm_tokens/t1'), false);
  assert.equal(store.has('invalid_fcm_tokens/t2'), false);
});

test('runFcmTokenCleanup: still removes the processed entry even if no account holds the token', async () => {
  const { db, store } = makeFakeDb({
    invalidTokens: { t1: { token: 'orphan-token' } },
  });

  const result = await runFcmTokenCleanup(db, fakeAdmin);

  assert.equal(result.processed, 1);
  assert.equal(result.accountsCleared, 0);
  assert.equal(store.has('invalid_fcm_tokens/t1'), false);
});

test('runFcmTokenCleanup: reports zero work when invalid_fcm_tokens is empty', async () => {
  const { db } = makeFakeDb();
  const result = await runFcmTokenCleanup(db, fakeAdmin);
  assert.deepEqual(result, { processed: 0, accountsCleared: 0 });
});
