'use strict';

// Master Prompt 55 — couverture de test directe des confirmHandler AZ IA de
// création de commande, jusqu'ici testés seulement par relecture attentive
// et node -c/require() (voir CLAUDE.md/AUDIT_FINAL.md, gap déjà documenté
// depuis les Prompts 51-54). Priorité : les chemins argent — chaque tool
// testé ici débite/crédite un wallet ou refuse proprement de le faire.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createDeliveryOrder, createShoppingOrder } = require('../azia/tools/delivery');
const { createRestaurantOrder } = require('../azia/tools/restaurants');
const { createPharmacieOrder } = require('../azia/tools/pharmacies');
const { createMarketplaceOrder } = require('../azia/tools/marketplace');

// Même fake Firestore que test/orderActions.test.js / test/aziaCancelOrder.test.js.
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

function findOrder(store) {
  return [...store.entries()].find(([k]) => k.startsWith('orders/'));
}

// ── create_delivery_order ────────────────────────────────────────────────

test('AZ IA create_delivery_order: confirmHandler debits the client wallet and creates a shopping-type order', async () => {
  const { db, store } = makeFakeDb({ 'clients/c1': { wallet: 5000 } });
  const tool = createDeliveryOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    description: 'Un colis', budget: 700, deliveryLat: 6.7, deliveryLng: -3.5,
    forSelf: true, deliveryMode: 'standard', paymentMethod: 'wallet',
  }));

  assert.equal(result.budget, 700);
  assert.equal(store.get('clients/c1').wallet, 4300);
  const order = findOrder(store);
  assert.ok(order, 'order should be created');
  assert.equal(order[1].type, 'shopping');
  assert.equal(order[1].isPaid, true);
  assert.equal(order[1].source, 'ai_chat');
});

test('AZ IA create_delivery_order: cash payment never touches the wallet', async () => {
  const { db, store } = makeFakeDb({ 'clients/c1': { wallet: 5000 } });
  const tool = createDeliveryOrder({ db, admin: fakeAdmin, HttpsError });

  await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    description: 'Un colis', budget: 700, deliveryLat: 6.7, deliveryLng: -3.5,
    forSelf: true, deliveryMode: 'standard', paymentMethod: 'cash',
  }));

  assert.equal(store.get('clients/c1').wallet, 5000);
  const order = findOrder(store);
  assert.equal(order[1].isPaid, false);
});

test('AZ IA create_delivery_order: rejects wallet payment with insufficient balance (money-loss guard)', async () => {
  const { db } = makeFakeDb({ 'clients/c1': { wallet: 100 } });
  const tool = createDeliveryOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      description: 'Un colis', budget: 700, deliveryLat: 6.7, deliveryLng: -3.5,
      forSelf: true, deliveryMode: 'standard', paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
});

test('AZ IA create_delivery_order: handler rejects when required delivery coordinates are missing', async () => {
  const { db } = makeFakeDb({ 'clients/c1': { wallet: 5000 } });
  const tool = createDeliveryOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => tool.handler('c1', { description: 'Un colis', budget: 700 }),
    /Coordonnées/,
  );
});

// ── create_shopping_order ────────────────────────────────────────────────

test('AZ IA create_shopping_order: confirmHandler debits the client and stores the itemized list', async () => {
  const { db, store } = makeFakeDb({ 'clients/c1': { wallet: 5000 } });
  const tool = createShoppingOrder({ db, admin: fakeAdmin, HttpsError });
  const items = [{ name: 'Tomates', budgetFcfa: 500 }, { name: 'Piment', budgetFcfa: 300 }];

  await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    items, budget: 800, deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet',
  }));

  assert.equal(store.get('clients/c1').wallet, 4200);
  const order = findOrder(store);
  assert.deepEqual(order[1].items, items);
  assert.equal(order[1].type, 'shopping');
});

test('AZ IA create_shopping_order: handler rejects an empty item list', async () => {
  const { db } = makeFakeDb();
  const tool = createShoppingOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => tool.handler('c1', { items: [], deliveryLat: 6.7, deliveryLng: -3.5 }),
    /vide/,
  );
});

// ── create_restaurant_order ──────────────────────────────────────────────

test('AZ IA create_restaurant_order: confirmHandler debits the client, does NOT credit the restaurant (Prompt 46 fix must hold)', async () => {
  const { db, store } = makeFakeDb({
    'clients/c1':      { wallet: 5000 },
    'restaurants/r1':  { wallet: 0, name: 'Chez Awa' },
  });
  const tool = createRestaurantOrder({ db, admin: fakeAdmin, HttpsError });
  const items = [{ name: 'Poulet braisé', price: 2000, quantity: 1 }];

  const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    restaurantId: 'r1', restaurantName: 'Chez Awa', items, budget: 2000,
    deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet',
  }));

  assert.equal(result.budget, 2000);
  assert.equal(store.get('clients/c1').wallet, 3000);
  assert.equal(store.get('restaurants/r1').wallet, 0); // jamais crédité ici — deliverOrderCF s'en charge
  const order = findOrder(store);
  assert.equal(order[1].sellerType, 'restaurant');
  assert.equal(order[1].sellerId, 'r1');
});

test('AZ IA create_restaurant_order: rejects wallet payment with insufficient balance', async () => {
  const { db } = makeFakeDb({
    'clients/c1':     { wallet: 500 },
    'restaurants/r1': { wallet: 0, name: 'Chez Awa' },
  });
  const tool = createRestaurantOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      restaurantId: 'r1', restaurantName: 'Chez Awa',
      items: [{ name: 'Poulet braisé', price: 2000, quantity: 1 }], budget: 2000,
      deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
});

test('AZ IA create_restaurant_order: handler rejects an unknown restaurant', async () => {
  const { db } = makeFakeDb();
  const tool = createRestaurantOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await tool.handler('c1', {
    restaurantId: 'missing', items: [{ name: 'Plat', price: 1000 }],
    deliveryLat: 6.7, deliveryLng: -3.5,
  });
  assert.ok(result.error);
});

test('AZ IA create_restaurant_order: handler rejects items with no name or non-positive price', async () => {
  const { db } = makeFakeDb({ 'restaurants/r1': { name: 'Chez Awa' } });
  const tool = createRestaurantOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => tool.handler('c1', {
      restaurantId: 'r1', items: [{ name: '', price: 1000 }],
      deliveryLat: 6.7, deliveryLng: -3.5,
    }),
    /nom et un prix positif/,
  );
});

// ── create_pharmacie_order ───────────────────────────────────────────────

test('AZ IA create_pharmacie_order: confirmHandler debits the client only (pharmacy paid separately at pickup, by design)', async () => {
  const { db, store } = makeFakeDb({
    'clients/c1':    { wallet: 5000 },
    'pharmacies/p1': { wallet: 0, name: 'Pharmacie du Centre' },
  });
  const tool = createPharmacieOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    pharmacieId: 'p1', pharmacieName: 'Pharmacie du Centre', description: 'Paracétamol',
    budget: 500, deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet',
  }));

  assert.equal(result.budget, 500);
  assert.equal(store.get('clients/c1').wallet, 4500);
  assert.equal(store.get('pharmacies/p1').wallet, 0); // frais de livraison seulement, pas les médicaments
  const order = findOrder(store);
  assert.equal(order[1].type, 'pharmacie');
  assert.equal(order[1].pharmacieId, 'p1');
});

test('AZ IA create_pharmacie_order: rejects wallet payment with insufficient balance', async () => {
  const { db } = makeFakeDb({ 'clients/c1': { wallet: 100 } });
  const tool = createPharmacieOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      pharmacieId: 'p1', pharmacieName: 'Pharmacie du Centre', description: 'Paracétamol',
      budget: 500, deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
});

test('AZ IA create_pharmacie_order: handler rejects an unknown pharmacie', async () => {
  const { db } = makeFakeDb();
  const tool = createPharmacieOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await tool.handler('c1', {
    pharmacieId: 'missing', description: 'Paracétamol', deliveryLat: 6.7, deliveryLng: -3.5,
  });
  assert.ok(result.error);
});

// ── create_marketplace_order ─────────────────────────────────────────────

test('AZ IA create_marketplace_order: confirmHandler debits the client AND credits the seller immediately (deliberate 0%-commission design, Prompt 46)', async () => {
  const { db, store } = makeFakeDb({
    'clients/c1':               { wallet: 20000 },
    'sellers/s1':                { wallet: 0, name: 'Vendeur X' },
    'marketplace_products/p1':  { status: 'active', title: 'iPhone 11', price: 15000, sellerId: 's1' },
  });
  const tool = createMarketplaceOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
    productId: 'p1', quantity: 1, budget: 15000, title: 'iPhone 11',
    sellerId: 's1', sellerName: 'Vendeur X', deliveryLat: 6.7, deliveryLng: -3.5,
    paymentMethod: 'wallet',
  }));

  assert.equal(result.budget, 15000);
  assert.equal(store.get('clients/c1').wallet, 5000);
  assert.equal(store.get('sellers/s1').wallet, 15000); // crédité en entier, 0% commission (politique déjà actée)
  const order = findOrder(store);
  assert.equal(order[1].sellerType, 'seller');
  assert.equal(order[1].isPaid, true);
});

test('AZ IA create_marketplace_order: confirmHandler rejects a product that is no longer active (commande impossible)', async () => {
  const { db, store } = makeFakeDb({
    'clients/c1':               { wallet: 20000 },
    'marketplace_products/p1':  { status: 'sold', title: 'iPhone 11', price: 15000, sellerId: 's1' },
  });
  const tool = createMarketplaceOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      productId: 'p1', quantity: 1, budget: 15000, title: 'iPhone 11',
      sellerId: 's1', sellerName: 'Vendeur X', deliveryLat: 6.7, deliveryLng: -3.5,
      paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
  assert.equal(store.get('clients/c1').wallet, 20000); // rien débité
});

test('AZ IA create_marketplace_order: rejects wallet payment with insufficient balance', async () => {
  const { db } = makeFakeDb({
    'clients/c1':               { wallet: 100 },
    'marketplace_products/p1':  { status: 'active', title: 'iPhone 11', price: 15000, sellerId: 's1' },
  });
  const tool = createMarketplaceOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      productId: 'p1', quantity: 1, budget: 15000, title: 'iPhone 11',
      sellerId: 's1', sellerName: 'Vendeur X', deliveryLat: 6.7, deliveryLng: -3.5,
      paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
});

test('AZ IA create_marketplace_order: handler rejects an unknown product', async () => {
  const { db } = makeFakeDb();
  const tool = createMarketplaceOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await tool.handler('c1', {
    productId: 'missing', deliveryLat: 6.7, deliveryLng: -3.5,
  });
  assert.ok(result.error);
});
