'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall } = require('firebase-functions/v2/https');
const { HttpsError } = require('firebase-functions/v2/https');
const {
  buildPayOrderFromWallet,
  buildCancelOrder,
  buildDeliverOrder,
  buildPayBoutiqueOrder,
} = require('../orderActions');

// Fake Firestore : un Map en mémoire + de quoi satisfaire get/set/update/add
// hors et dans une transaction — même style que test/pendingActions.test.js.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  const added = [];
  let autoId = 0;

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        if (opts && opts.merge) {
          store.set(path, { ...(store.get(path) || {}), ...mergeIncrements(store.get(path), data) });
        } else {
          store.set(path, data);
        }
      },
      update: async (data) => {
        store.set(path, applyUpdate(store.get(path) || {}, data));
      },
      collection: (sub) => makeCollection(`${path}/${sub}`),
    };
  }

  function mergeIncrements(existing, data) {
    const out = { ...data };
    for (const k of Object.keys(data)) {
      if (data[k] && data[k].__increment !== undefined) {
        out[k] = (existing?.[k] || 0) + data[k].__increment;
      }
    }
    return out;
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
        added.push({ collection: name, data });
        return { id: path.split('/').pop() };
      },
      where: (field, _op, value) => ({
        limit: (n) => ({
          get: async () => {
            const docs = [];
            for (const [path, data] of store.entries()) {
              if (!path.startsWith(`${name}/`)) continue;
              if (path.slice(name.length + 1).includes('/')) continue; // pas de sous-collection
              if (data && data[field] === value) {
                docs.push({ id: path.split('/').pop(), data: () => data });
              }
              if (docs.length >= n) break;
            }
            return { empty: docs.length === 0, docs };
          },
        }),
      }),
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

  return { db, store, added };
}

const fakeAdmin = {
  firestore: {
    FieldValue: {
      serverTimestamp: () => '__SERVER_TIMESTAMP__',
      increment: (n) => ({ __increment: n }),
    },
    Timestamp: {
      fromMillis: (ms) => ({ toMillis: () => ms }),
    },
  },
};

async function fakeDispatchOrder(_db, _admin, { orderId }) {
  fakeDispatchOrder.calls.push(orderId);
  return { dispatched: true, mode: 'assigned' };
}
fakeDispatchOrder.calls = [];

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

async function fakeCalculateCommission(_db, budget) {
  return budget < 1000 ? 100 : 200;
}

// ── payOrderFromWalletCF ─────────────────────────────────────────────────

test('payOrderFromWalletCF: happy path debits client, credits driver, marks order paid', async () => {
  const { db, store, added } = makeFakeDb({
    'orders/o1':    { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false },
    'clients/c1':   { wallet: 1000 },
    'livreurs/d1':  { wallet: 200 },
  });
  const logAudit = makeLogAudit();
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit,
  });

  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  assert.deepEqual(result, { success: true });
  assert.equal(store.get('clients/c1').wallet, 500);
  assert.equal(store.get('livreurs/d1').wallet, 700);
  assert.equal(store.get('orders/o1').isPaid, true);
  assert.equal(store.get('orders/o1').paymentMethod, 'wallet');
  assert.equal(added.filter(a => a.collection.includes('wallet_transactions')).length, 2);
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'pay_order_wallet');
});

test('payOrderFromWalletCF: also credits the pharmacie when medicineAmount > 0', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':      { clientId: 'c1', driverId: 'd1', budget: 500, pharmacieId: 'p1', isPaid: false },
    'clients/c1':     { wallet: 2000 },
    'livreurs/d1':    { wallet: 0 },
    'pharmacies/p1':  { wallet: 0 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1', medicineAmount: 800 } });

  assert.equal(store.get('clients/c1').wallet, 2000 - 500 - 800);
  assert.equal(store.get('livreurs/d1').wallet, 500);
  assert.equal(store.get('pharmacies/p1').wallet, 800);
  assert.equal(store.get('orders/o1').medicineAmount, 800);
});

test('payOrderFromWalletCF: rejects with SOLDE_INSUFFISANT when balance is too low', async () => {
  const { db } = makeFakeDb({
    'orders/o1':   { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false },
    'clients/c1':  { wallet: 100 },
    'livreurs/d1': { wallet: 0 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'failed-precondition' && err.message.includes('SOLDE_INSUFFISANT'),
  );
});

test('payOrderFromWalletCF: rejects when caller is not the order\'s own client', async () => {
  const { db } = makeFakeDb({
    'orders/o1':   { clientId: 'owner', driverId: 'd1', budget: 500, isPaid: false },
    'clients/intruder': { wallet: 10000 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'intruder' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('payOrderFromWalletCF: rejects an already-paid order', async () => {
  const { db } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: true },
    'clients/c1': { wallet: 10000 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('payOrderFromWalletCF: rejects when no driver is assigned yet', async () => {
  const { db } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', driverId: null, budget: 500, isPaid: false },
    'clients/c1': { wallet: 10000 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('payOrderFromWalletCF: caps a client-attested medicineAmount at 500000', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':     { clientId: 'c1', driverId: 'd1', budget: 500, pharmacieId: 'p1', isPaid: false },
    'clients/c1':    { wallet: 10_000_000 },
    'livreurs/d1':   { wallet: 0 },
    'pharmacies/p1': { wallet: 0 },
  });
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1', medicineAmount: 999999999 } });

  assert.equal(store.get('pharmacies/p1').wallet, 500000);
});

test('payOrderFromWalletCF: rejects unauthenticated calls', async () => {
  const { db } = makeFakeDb();
  const fn = buildPayOrderFromWallet({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });
  await assert.rejects(
    () => fn.run({ data: { orderId: 'o1' } }),
    (err) => err.code === 'unauthenticated',
  );
});

// ── cancelOrderCF ─────────────────────────────────────────────────────────

test('cancelOrderCF: refunds the client wallet when the order was paid by wallet', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 500 },
    'clients/c1': { wallet: 100 },
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  assert.deepEqual(result, { success: true });
  assert.equal(store.get('orders/o1').status, 'cancelled');
  assert.equal(store.get('clients/c1').wallet, 600);
});

test('cancelOrderCF: also refunds the driver commission when the order was already accepted', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 1500 },
    'clients/c1':  { wallet: 0 },
    'livreurs/d1': { wallet: 50 },
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  // budget=1500 >= threshold(1000) -> commission 200 (fakeCalculateCommission)
  assert.equal(store.get('livreurs/d1').wallet, 250);
  assert.equal(store.get('clients/c1').wallet, 0); // cash order: no client refund
});

test('cancelOrderCF: rejects cancelling an already-delivered order', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'c1', status: 'delivered', paymentMethod: 'cash', budget: 500 },
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('cancelOrderCF: rejects a caller who does not own the order', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'owner', status: 'pending', paymentMethod: 'cash', budget: 500 },
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'intruder' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

// ── deliverOrderCF ────────────────────────────────────────────────────────

test('deliverOrderCF: cash order deducts the fixed commission from the driver', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 1000 },
    'livreurs/d1': { wallet: 300 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  const result = await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.deepEqual(result, { success: true });
  assert.equal(store.get('orders/o1').status, 'delivered');
  assert.equal(store.get('livreurs/d1').wallet, 200); // 300 - 100 commission
  assert.equal(store.get('livreurs/d1').isOnDelivery, false);
  assert.equal(store.get('livreurs/d1').deliveries, 1);
});

test('deliverOrderCF: direct wallet-paid delivery (no seller) credits the driver net of commission', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000 },
    'livreurs/d1': { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('livreurs/d1').wallet, 900); // 1000 - 100 commission
});

test('deliverOrderCF: wallet-paid delivery with a seller credits the partner, not the driver wallet', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':       { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, sellerId: 'r1', sellerType: 'restaurant' },
    'livreurs/d1':     { wallet: 500 },
    'restaurants/r1':  { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('restaurants/r1').wallet, 900); // 1000 - 100 commission
  assert.equal(store.get('livreurs/d1').wallet, 500); // driver's own wallet untouched
  assert.equal(store.get('livreurs/d1').isOnDelivery, false);
});

test('deliverOrderCF: records GPS + photo when provided', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'picked_up', paymentMethod: 'cash', budget: 500 },
    'livreurs/d1': { wallet: 100 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({
    auth: { uid: 'd1' },
    data: { orderId: 'o1', deliveredLat: 6.7, deliveredLng: -3.4, deliveryPhotoUrl: 'https://x/y.jpg' },
  });

  const order = store.get('orders/o1');
  assert.equal(order.deliveredLat, 6.7);
  assert.equal(order.deliveredLng, -3.4);
  assert.equal(order.deliveryPhoto, 'https://x/y.jpg');
});

test('deliverOrderCF: rejects a driver who is not assigned to the order', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 500 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'intruder' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('deliverOrderCF: rejects an order that is not accepted/picked_up', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { driverId: 'd1', status: 'pending', paymentMethod: 'cash', budget: 500 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

// ── payBoutiqueOrderCF ───────────────────────────────────────────────────

test('payBoutiqueOrderCF: happy path debits client, credits seller, decrements stock, creates the order', async () => {
  fakeDispatchOrder.calls = [];
  const { db, store, added } = makeFakeDb({
    'sellers/s1':            { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1':  { name: 'Riz 5kg', category: 'Alimentation', price: 3000, stock: 10 },
    'clients/c1':            { wallet: 10000 },
  });
  const logAudit = makeLogAudit();
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit, dispatchOrder: fakeDispatchOrder,
  });

  const result = await fn.run({
    auth: { uid: 'c1' },
    data: { productId: 'p1', qty: 2, deliveryLat: 6.7, deliveryLng: -3.5 },
  });

  assert.equal(result.totalPrice, 6000);
  assert.equal(result.dispatched, true);
  assert.equal(store.get('clients/c1').wallet, 4000);
  assert.equal(store.get('sellers/s1').wallet, 6000);
  assert.equal(store.get('boutique_products/p1').stock, 8);

  const orderEntry = [...store.entries()].find(([k]) => k.startsWith('boutique_orders/'));
  assert.ok(orderEntry, 'boutique_orders entry should exist');
  assert.equal(orderEntry[1].status, 'paid');
  assert.equal(orderEntry[1].qty, 2);
  assert.equal(orderEntry[1].totalPrice, 6000);

  assert.equal(added.filter(a => a.collection.includes('wallet_transactions')).length, 2);
  assert.equal(fakeDispatchOrder.calls.length, 1);
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'pay_boutique_order');
});

test('payBoutiqueOrderCF: rejects when stock is insufficient', async () => {
  const { db } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { name: 'Riz 5kg', price: 3000, stock: 1 },
    'clients/c1':           { wallet: 100000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 5 } }),
    (err) => err.code === 'failed-precondition' && err.message.includes('STOCK_EPUISE'),
  );
});

test('payBoutiqueOrderCF: rejects with SOLDE_INSUFFISANT when balance is too low', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { name: 'Riz 5kg', price: 3000, stock: 10 },
    'clients/c1':           { wallet: 100 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'failed-precondition' && err.message.includes('SOLDE_INSUFFISANT'),
  );
  // Stock/wallet must be untouched on rejection.
  assert.equal(store.get('boutique_products/p1').stock, 10);
  assert.equal(store.get('clients/c1').wallet, 100);
});

test('payBoutiqueOrderCF: rejects when no boutique seller is configured', async () => {
  const { db } = makeFakeDb({
    'boutique_products/p1': { name: 'Riz 5kg', price: 3000, stock: 10 },
    'clients/c1':           { wallet: 100000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('payBoutiqueOrderCF: rejects an unknown product', async () => {
  const { db } = makeFakeDb({
    'sellers/s1': { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'clients/c1': { wallet: 100000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'ghost', qty: 1 } }),
    (err) => err.code === 'not-found',
  );
});

test('payBoutiqueOrderCF: still succeeds (purchase honored) even if dispatch throws', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { name: 'Riz 5kg', price: 3000, stock: 10 },
    'clients/c1':           { wallet: 10000 },
  });
  const throwingDispatch = async () => { throw new Error('dispatch is down'); };
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: throwingDispatch,
  });

  const result = await fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1 } });

  assert.equal(result.dispatched, false);
  assert.equal(store.get('clients/c1').wallet, 7000);
  assert.equal(store.get('sellers/s1').wallet, 3000);
});

test('payBoutiqueOrderCF: rejects unauthenticated calls', async () => {
  const { db } = makeFakeDb();
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });
  await assert.rejects(
    () => fn.run({ data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'unauthenticated',
  );
});
