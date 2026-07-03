'use strict';

// Teste l'outil AZ IA `cancel_order` (functions/azia/tools/delivery.js) après
// sa migration vers le cœur transactionnel partagé (cancelOrderTx/
// cancelOrderPostTx, functions/orderActions.js) — Master Prompt 52. Avant
// cette migration, ce chemin dupliquait la logique d'annulation avec les
// correctifs des Prompts 47/48 manquants (pas de débit vendeur Marketplace,
// pas de plafond anti-solde-négatif) ; ces tests prouvent que le même
// résultat qu'un client annulant depuis l'app (cancelOrderCF) est désormais
// obtenu via AZ IA.

const test = require('node:test');
const assert = require('node:assert/strict');
const { cancelOrder } = require('../azia/tools/delivery');

// Même fake Firestore que test/orderActions.test.js (transactions + get/set/update).
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data) => { store.set(path, data); },
      update: async (data) => { store.set(path, applyUpdate(store.get(path) || {}, data)); },
      collection: (sub) => makeCollection(`${path}/${sub}`),
    };
  }

  function applyUpdate(existing, data) {
    const out = { ...existing };
    for (const k of Object.keys(data)) {
      const v = data[k];
      if (v && v.__increment !== undefined) {
        out[k] = (existing[k] || 0) + v.__increment;
      } else {
        out[k] = v;
      }
    }
    return out;
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
        update: (ref, data) => store.set(ref.__path, applyUpdate(store.get(ref.__path) || {}, data)),
        set: (ref, data) => store.set(ref.__path, data),
      };
      return fn(tx);
    },
  };

  return { db, store };
}

const fakeAdmin = {
  firestore: {
    FieldValue: {
      serverTimestamp: () => '__SERVER_TIMESTAMP__',
      increment: (n) => ({ __increment: n }),
    },
  },
};

const HttpsError = class extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
};

// Exécute confirmHandler dans une transaction (comme le fait réellement
// aiConfirmAction/pendingActions.js) puis afterConfirm après coup.
async function runCancel(tool, db, uid, toolInput) {
  const confirmResult = await db.runTransaction((tx) => tool.confirmHandler(tx, uid, toolInput));
  return tool.afterConfirm(uid, confirmResult);
}

test('AZ IA cancel_order: annulation normale rembourse le client (wallet)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 500 },
    'clients/c1': { wallet: 100 },
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await runCancel(tool, db, 'c1', { orderId: 'o1' });

  assert.equal(result.orderId, 'o1');
  assert.equal(result.refundAmount, 500);
  assert.equal(store.get('orders/o1').status, 'cancelled');
  assert.equal(store.get('orders/o1').cancelReason, 'ai_client_cancel');
  assert.equal(store.get('clients/c1').wallet, 600);
});

test('AZ IA cancel_order: rembourse aussi la commission du livreur si déjà acceptée', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 1500 },
    'clients/c1':  { wallet: 0 },
    'livreurs/d1': { wallet: 50 },
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await runCancel(tool, db, 'c1', { orderId: 'o1' });

  assert.equal(result.commissionRefund, 200); // budget=1500 >= seuil(1000) -> commission 200
  assert.equal(store.get('livreurs/d1').wallet, 250);
});

test('AZ IA cancel_order: annulation Marketplace débite le vendeur déjà payé (seller rollback)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 1000 }, // déjà crédité en entier par create_marketplace_order
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  await runCancel(tool, db, 'c1', { orderId: 'o1' });

  assert.equal(store.get('clients/c1').wallet, 1000); // remboursé
  assert.equal(store.get('sellers/s1').wallet, 0);     // repris — plus d'argent créé à partir de rien
});

test('AZ IA cancel_order: plafonne le débit vendeur à 0 (pas de solde négatif)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 300 }, // a déjà retiré une partie du crédit
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  await runCancel(tool, db, 'c1', { orderId: 'o1' });

  assert.equal(store.get('clients/c1').wallet, 1000);
  assert.equal(store.get('sellers/s1').wallet, 0); // jamais négatif
});

test('AZ IA cancel_order: ne touche pas un vendeur boutique (document de livraison, pas le vrai paiement)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 500, isPaid: false, type: 'boutique', sellerId: 's1', sellerType: 'boutique' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 20000 },
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  await runCancel(tool, db, 'c1', { orderId: 'o1' });

  assert.equal(store.get('sellers/s1').wallet, 20000); // inchangé
  assert.equal(store.get('clients/c1').wallet, 0);      // pas de remboursement fantôme
});

test('AZ IA cancel_order: rejette une commande déjà livrée', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'c1', status: 'delivered', paymentMethod: 'cash', budget: 500 },
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', { orderId: 'o1' })),
    (err) => err.code === 'failed-precondition',
  );
});

test('AZ IA cancel_order: rejette un appelant qui n\'est pas le propriétaire', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'c1', status: 'pending', paymentMethod: 'cash', budget: 500 },
  });
  const tool = cancelOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'stranger', { orderId: 'o1' })),
    (err) => err.code === 'permission-denied',
  );
});
