'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall } = require('firebase-functions/v2/https');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildCreateEventReservation } = require('../eventReservations');

// Même style de fake Firestore que test/orderActions.test.js.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data) => { store.set(path, data); },
      update: async (data) => {
        store.set(path, { ...(store.get(path) || {}), ...data });
      },
      collection: (sub) => makeCollection(`${path}/${sub}`),
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
    };
  }

  const db = {
    collection: (name) => makeCollection(name),
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

function makeCheckRateLimit() {
  return async () => {};
}

function seedOffer(overrides = {}) {
  return {
    providerId: 'p1',
    providerName: 'DJ Kouassi',
    title: 'Animation DJ',
    category: 'entertainment',
    subcategory: 'dj',
    unitPrice: 25000,
    availableQuantity: 5,
    isActive: true,
    photoUrls: ['https://x/y.jpg'],
    ...overrides,
  };
}

function seedProvider(overrides = {}) {
  return { status: 'approved', isSuspended: false, shopName: 'DJ Kouassi Events', ...overrides };
}

function build(db) {
  return buildCreateEventReservation({
    db, admin: fakeAdmin, onCall, HttpsError, checkRateLimit: makeCheckRateLimit(),
  });
}

test('createEventReservationCF: recalcule totalAmount depuis le VRAI prix de l\'offre, jamais un prix client', async () => {
  const { db, store } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 25000 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  // Le client envoie un prix falsifié (1 FCFA) — totalement ignoré.
  const result = await fn.run({
    auth: { uid: 'c1' },
    data: { attemptId: 'test-attempt-0001',
      items: [{ offerId: 'o1', quantity: 2, unitPrice: 1, lineTotal: 2 }],
      eventDateMs: Date.now(), eventTime: '18:00', address: 'Abengourou',
      description: 'Anniversaire', paymentMethod: 'wallet',
      delivery: false, installation: false, dismantling: false,
    },
  });

  assert.equal(result.totalAmount, 50000); // 25000 * 2, jamais 1 ou 2
  const reservation = store.get(`event_reservations/${result.reservationId}`);
  assert.equal(reservation.totalAmount, 50000);
  assert.equal(reservation.items[0].unitPrice, 25000);
  assert.equal(store.get('clients/c1').wallet, 50000); // 100000 - 50000
});

test('createEventReservationCF: quantité manipulée (négative/nulle) est rejetée', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer(),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: -5 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('createEventReservationCF: quantité absurdement grande est rejetée (borne anti-abus)', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer(),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 999999 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('createEventReservationCF: rejette une offre inexistante', async () => {
  const { db } = makeFakeDb({ 'clients/c1': { wallet: 100000 } });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'does-not-exist', quantity: 1 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'failed-precondition',
  );
});

test('createEventReservationCF: rejette une offre inactive (isActive:false)', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer({ isActive: false }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'failed-precondition',
  );
});

test('createEventReservationCF: rejette un prestataire suspendu', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer(),
    'event_providers/p1': seedProvider({ isSuspended: true }),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'failed-precondition',
  );
});

test('createEventReservationCF: rejette un prestataire non encore approuvé', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer(),
    'event_providers/p1': seedProvider({ status: 'pending' }),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'failed-precondition',
  );
});

test('createEventReservationCF: montant zéro (offre à prix nul) est rejeté', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 0 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
    }),
    (err) => err.code === 'failed-precondition',
  );
});

test('createEventReservationCF: paiement wallet en dessous du plancher (500 FCFA) est rejeté même à prix réel', async () => {
  const { db } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 100 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'wallet' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('createEventReservationCF: solde insuffisant rejette et ne crée aucun document', async () => {
  const { db, store } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 25000 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 1000 },
  });
  const fn = build(db);

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'wallet' },
    }),
    (err) => err.code === 'failed-precondition' && err.message.startsWith('SOLDE_INSUFFISANT'),
  );
  const anyReservation = [...store.keys()].some((k) => k.startsWith('event_reservations/'));
  assert.equal(anyReservation, false, 'aucune réservation ne doit être créée si le débit échoue');
  assert.equal(store.get('clients/c1').wallet, 1000, 'le wallet ne doit pas bouger');
});

test('createEventReservationCF: paiement cash n\'affecte jamais le wallet et marque isPaid:false', async () => {
  const { db, store } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 25000 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 100000 },
  });
  const fn = build(db);

  const result = await fn.run({
    auth: { uid: 'c1' },
    data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
  });

  assert.equal(store.get('clients/c1').wallet, 100000, 'cash ne débite jamais le wallet');
  const reservation = store.get(`event_reservations/${result.reservationId}`);
  assert.equal(reservation.isPaid, false);
  assert.equal(reservation.paymentMethod, 'cash');
});

test('createEventReservationCF: réutilisation de débit structurellement impossible — un appel crée exactement une réservation liée à exactement un débit', async () => {
  const { db, store } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 500 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 1000 },
  });
  const fn = build(db);

  const result = await fn.run({
    auth: { uid: 'c1' },
    data: { attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'wallet' },
  });

  const reservationDocs = [...store.keys()].filter((k) => k.startsWith('event_reservations/'));
  assert.equal(reservationDocs.length, 1,
    'un seul appel ne peut jamais produire plus d\'une réservation — contrairement à l\'ancien flux client par batch, cette API n\'expose aucune surface multi-documents');
  assert.equal(store.get('clients/c1').wallet, 500); // 1000 - 500, un seul débit
  assert.equal(result.totalAmount, 500);
});

test('createEventReservationCF: missing or unsafe attempt keys fail before any write', async () => {
  const { db, store } = makeFakeDb();
  const fn = build(db);
  for (const attemptId of [undefined, '', 'short', '../another/document', 123, 'a'.repeat(129)]) {
    await assert.rejects(() => fn.run({
      auth: { uid: 'c1' },
      data: { attemptId, items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'cash' },
    }), (error) => error.code === 'invalid-argument');
  }
  assert.equal(store.size, 0);
});

test('createEventReservationCF: receipt replay bypasses rate limiting and returns the committed total', async () => {
  const { db, store } = makeFakeDb({
    'event_offers/o1': seedOffer({ unitPrice: 500 }),
    'event_providers/p1': seedProvider(),
    'clients/c1': { wallet: 1000 },
  });
  let checks = 0;
  const fn = buildCreateEventReservation({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: async () => {
      if (++checks > 1) throw new Error('rate limit');
    },
  });
  const request = { auth: { uid: 'c1' }, data: {
    attemptId: 'test-attempt-0001', items: [{ offerId: 'o1', quantity: 1 }], paymentMethod: 'wallet',
  } };
  const first = await fn.run(request);
  store.set('event_offers/o1', seedOffer({ unitPrice: 900 }));
  assert.deepEqual(await fn.run(request), first);
  assert.equal(checks, 1);
  assert.equal(store.get('clients/c1').wallet, 500);
  const ledger = [...store.entries()].filter(([path]) => path.startsWith('clients/c1/wallet_transactions/'));
  assert.equal(ledger.length, 1);
  assert.equal(ledger[0][1].orderId, first.reservationId);
});
