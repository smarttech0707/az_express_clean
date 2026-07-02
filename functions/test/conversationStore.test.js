'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { clearHistory } = require('../azia/conversationStore');

// Fake Firestore couvrant collection(...).doc(...).collection(...).limit(n).get()
// + db.batch() — assez pour clearHistory(), qui boucle par lots de 500.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));

  function makeMessagesCollection(uid) {
    const prefix = `ai_conversations/${uid}/messages/`;
    return {
      limit: (n) => ({
        get: async () => {
          const docs = [...store.keys()]
            .filter((k) => k.startsWith(prefix))
            .slice(0, n)
            .map((k) => ({ ref: { __path: k } }));
          return { empty: docs.length === 0, size: docs.length, docs };
        },
      }),
    };
  }

  const db = {
    collection: (name) => ({
      doc: (uid) => ({
        collection: (sub) => (sub === 'messages' ? makeMessagesCollection(uid) : null),
      }),
    }),
    batch: () => {
      const ops = [];
      return {
        delete: (ref) => ops.push(ref),
        commit: async () => ops.forEach((ref) => store.delete(ref.__path)),
      };
    },
  };

  return { db, store };
}

test('clearHistory: deletes every message for the given user', async () => {
  const { db, store } = makeFakeDb({
    'ai_conversations/u1/messages/m1': { role: 'user', content: 'hi' },
    'ai_conversations/u1/messages/m2': { role: 'assistant', content: 'hello' },
    'ai_conversations/u2/messages/m3': { role: 'user', content: 'other user' },
  });

  const deletedCount = await clearHistory(db, 'u1');

  assert.equal(deletedCount, 2);
  assert.equal(store.has('ai_conversations/u1/messages/m1'), false);
  assert.equal(store.has('ai_conversations/u1/messages/m2'), false);
  assert.equal(store.has('ai_conversations/u2/messages/m3'), true); // autre utilisateur intact
});

test('clearHistory: returns zero for a user with no history', async () => {
  const { db } = makeFakeDb();
  const deletedCount = await clearHistory(db, 'nobody');
  assert.equal(deletedCount, 0);
});

test('clearHistory: pages through more than one batch of 500', async () => {
  const seed = {};
  for (let i = 0; i < 650; i++) {
    seed[`ai_conversations/u1/messages/m${i}`] = { role: 'user', content: `msg ${i}` };
  }
  const { db, store } = makeFakeDb(seed);

  const deletedCount = await clearHistory(db, 'u1');

  assert.equal(deletedCount, 650);
  const remaining = [...store.keys()].filter((k) => k.startsWith('ai_conversations/u1/messages/'));
  assert.equal(remaining.length, 0);
});
