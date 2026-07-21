'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { runStaleDriverCleanup, MAX_PER_RUN } = require('../staleDriverCleanup');
const { STALE_MINUTES } = require('../dispatch');

// Fake Firestore couvrant exactement ce que staleDriverCleanup.js touche :
// collection('livreurs').where('isOnline','==',true).limit().get() et
// db.batch() pour corriger le flag.
function makeFakeDb({ livreurs = {} } = {}) {
  const store = new Map();
  for (const [id, data] of Object.entries(livreurs)) {
    store.set(`livreurs/${id}`, data);
  }

  function makeRef(path) {
    return { __path: path };
  }

  const db = {
    collection: (name) => ({
      where: (field, _op, value) => ({
        limit: (n) => ({
          get: async () => {
            const prefix = `${name}/`;
            const docs = [...store.entries()]
              .filter(([k, data]) => k.startsWith(prefix) && data[field] === value)
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
        update: (ref, data) => ops.push({ ref, data }),
        commit: async () => {
          ops.forEach(({ ref, data }) => {
            const existing = store.get(ref.__path) || {};
            store.set(ref.__path, { ...existing, ...data });
          });
        },
      };
    },
  };

  return { db, store };
}

const fakeAdmin = {};

// Timestamp Firestore minimal — seul `.toMillis()` est utilisé par le code.
function ts(millis) {
  return { toMillis: () => millis };
}

test('STALE_MINUTES est bien importé depuis dispatch.js (source unique, jamais dupliqué)', () => {
  assert.equal(typeof STALE_MINUTES, 'number');
});

test('runStaleDriverCleanup: aucun livreur en ligne -> aucune vérification, aucune correction', async () => {
  const { db } = makeFakeDb();
  const result = await runStaleDriverCleanup(db, fakeAdmin);
  assert.deepEqual(result, { checked: 0, corrected: 0 });
});

test('runStaleDriverCleanup: livreur en ligne avec GPS frais -> non corrigé', async () => {
  const now = Date.now();
  const { db, store } = makeFakeDb({
    livreurs: { d1: { isOnline: true, updatedAt: ts(now - 30 * 1000) } }, // 30s — frais
  });

  const result = await runStaleDriverCleanup(db, fakeAdmin, { now });

  assert.deepEqual(result, { checked: 1, corrected: 0 });
  assert.equal(store.get('livreurs/d1').isOnline, true);
});

test('runStaleDriverCleanup: livreur en ligne avec GPS obsolète (> STALE_MINUTES) -> isOnline corrigé à false', async () => {
  const now = Date.now();
  const { db, store } = makeFakeDb({
    // Exactement le scénario réel observé : GPS vieux de plusieurs heures.
    livreurs: { d1: { isOnline: true, updatedAt: ts(now - (STALE_MINUTES + 60) * 60 * 1000) } },
  });

  const result = await runStaleDriverCleanup(db, fakeAdmin, { now });

  assert.deepEqual(result, { checked: 1, corrected: 1 });
  assert.equal(store.get('livreurs/d1').isOnline, false);
});

test('runStaleDriverCleanup: livreur en ligne sans updatedAt du tout -> traité comme obsolète', async () => {
  const { db, store } = makeFakeDb({
    livreurs: { d1: { isOnline: true } },
  });

  const result = await runStaleDriverCleanup(db, fakeAdmin);

  assert.deepEqual(result, { checked: 1, corrected: 1 });
  assert.equal(store.get('livreurs/d1').isOnline, false);
});

test('runStaleDriverCleanup: mélange frais/obsolète/absent -> seuls les non-frais sont corrigés', async () => {
  const now = Date.now();
  const { db, store } = makeFakeDb({
    livreurs: {
      fresh:   { isOnline: true, updatedAt: ts(now - 10 * 1000) },
      stale:   { isOnline: true, updatedAt: ts(now - 10 * 60 * 1000) },
      missing: { isOnline: true },
      offline: { isOnline: false, updatedAt: ts(now - 999 * 60 * 1000) }, // déjà hors ligne, jamais interrogé
    },
  });

  const result = await runStaleDriverCleanup(db, fakeAdmin, { now });

  assert.deepEqual(result, { checked: 3, corrected: 2 });
  assert.equal(store.get('livreurs/fresh').isOnline, true);
  assert.equal(store.get('livreurs/stale').isOnline, false);
  assert.equal(store.get('livreurs/missing').isOnline, false);
  assert.equal(store.get('livreurs/offline').isOnline, false); // inchangé
});

test('runStaleDriverCleanup: respecte un seuil personnalisé (staleMinutes)', async () => {
  const now = Date.now();
  const { db, store } = makeFakeDb({
    livreurs: { d1: { isOnline: true, updatedAt: ts(now - 4 * 60 * 1000) } }, // 4 min
  });

  // Avec un seuil de 10 min, 4 min reste frais.
  const lenient = await runStaleDriverCleanup(db, fakeAdmin, { now, staleMinutes: 10 });
  assert.deepEqual(lenient, { checked: 1, corrected: 0 });
  assert.equal(store.get('livreurs/d1').isOnline, true);

  // Avec un seuil de 3 min (celui de dispatch.js), 4 min est obsolète.
  const strict = await runStaleDriverCleanup(db, fakeAdmin, { now, staleMinutes: 3 });
  assert.deepEqual(strict, { checked: 1, corrected: 1 });
  assert.equal(store.get('livreurs/d1').isOnline, false);
});

test('MAX_PER_RUN reste sous la limite de 500 opérations par batch Firestore', () => {
  assert.ok(MAX_PER_RUN < 500);
});
