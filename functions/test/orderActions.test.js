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
  buildPayBoutiqueOrderCash,
  buildRefundExpiredBoutiqueOrder,
} = require('../orderActions');

// Fake Firestore : un Map en mémoire + de quoi satisfaire get/set/update/add
// hors et dans une transaction — même style que test/pendingActions.test.js.
function makeFakeDb(seed = {}) {
  const geographicSeed = {
    'zones_livraison/abengourou': {
      type: 'ville', cityId: 'abengourou', isActive: true,
      isServiceable: true, coordinateSource: 'own',
      lat: 6.7, lng: -3.5, radiusKm: 100,
    },
    'zones_livraison/centre': {
      type: 'quartier', cityId: 'abengourou', isActive: true,
      isServiceable: true, coordinateSource: 'own',
      lat: 6.7, lng: -3.5, radiusKm: 100,
    },
  };
  const normalizedSeed = Object.fromEntries(Object.entries(seed).map(([path, data]) => [
    path,
    path.startsWith('sellers/') ? { lat: 6.7, lng: -3.5, ...data } : data,
  ]));
  const store = new Map(Object.entries({ ...geographicSeed, ...normalizedSeed }));
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
    const makeQuery = (filters = []) => ({
      where: (field, op, value) => makeQuery([...filters, { field, op, value }]),
      limit: (n) => ({
        get: async () => {
          const docs = [];
          for (const [path, data] of store.entries()) {
            if (!path.startsWith(`${name}/`)) continue;
            if (path.slice(name.length + 1).includes('/')) continue;
            const matches = filters.every(({ field, op, value }) =>
              op === '==' && data?.[field] === value);
            if (matches) docs.push({ id: path.split('/').pop(), data: () => data });
            if (docs.length >= n) break;
          }
          return { empty: docs.length === 0, docs, size: docs.length };
        },
      }),
    });
    return {
      doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
      add: async (data) => {
        const path = `${name}/auto${autoId++}`;
        store.set(path, data);
        added.push({ collection: name, data });
        return { id: path.split('/').pop() };
      },
      where: (field, op, value) => makeQuery([{ field, op, value }]),
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

test('cancelOrderCF: debits a marketplace seller already paid at order creation', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 1000 }, // déjà crédité en entier par create_marketplace_order
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('clients/c1').wallet, 1000); // remboursé
  assert.equal(store.get('sellers/s1').wallet, 0);     // repris — plus d'argent créé à partir de rien
});

test('cancelOrderCF: clamps the seller debit at 0 if they already spent part of the prepaid credit', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 300 }, // a déjà retiré une partie des 1000 FCFA crédités
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('clients/c1').wallet, 1000); // remboursé en entier malgré tout
  assert.equal(store.get('sellers/s1').wallet, 0);     // repris jusqu'à 0, jamais négatif
});

test('cancelOrderCF: does NOT touch a boutique seller wallet (delivery-leg order, different amount)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':  { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 500, isPaid: false, type: 'boutique', sellerId: 's1', sellerType: 'boutique', linkedBoutiqueOrderId: 'bo1' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 20000 }, // crédité via boutique_orders, montant différent de `budget` ici
  });
  const fn = buildCancelOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
    calculateCommission: fakeCalculateCommission,
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('sellers/s1').wallet, 20000); // volontairement inchangé (voir commentaire code)
  assert.equal(store.get('clients/c1').wallet, 0);      // pas de remboursement fantôme (rien n'a été payé sur ce document)
  assert.equal(store.get('orders/o1').status, 'cancelled');
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

test('deliverOrderCF: cash order does NOT touch the driver wallet — commission already collected at acceptance (regression test for the double-commission bug fixed 2026-07-09)', async () => {
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
  assert.equal(store.get('livreurs/d1').wallet, 300); // inchangé — commission déjà prise à l'acceptation
  assert.equal(store.get('livreurs/d1').isOnDelivery, false);
  assert.equal(store.get('livreurs/d1').deliveries, 1);
  // Pas de vendeur sur cette commande (livraison/course pure) — rien à
  // régler avec un marchand, le champ ne doit pas être écrit.
  assert.equal(store.get('orders/o1').merchantCashSettled, undefined);
});

test('deliverOrderCF: cash order with a merchant (restaurant/pharmacie) is flagged as needing cash settlement (Master Prompt 76, 2026-07-09)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 2500, sellerId: 'r1', sellerType: 'restaurant' },
    'livreurs/d1': { wallet: 300 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('orders/o1').merchantCashSettled, false);
  assert.equal(store.get('livreurs/d1').wallet, 300); // commission déjà prise à l'acceptation, rien ici
});

test('deliverOrderCF: cash order for boutique is NOT flagged — settlement tracked separately via boutique_orders.status', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'cash', budget: 500, sellerId: 's1', sellerType: 'boutique' },
    'livreurs/d1': { wallet: 300 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('orders/o1').merchantCashSettled, undefined);
});

test('deliverOrderCF: direct wallet-paid delivery (no seller) credits the driver the full amount — commission already collected at acceptance (regression test, 2026-07-09)', async () => {
  const { db, store } = makeFakeDb({
    // isPaid: true — la commande a déjà été réglée à la création
    // (livraison_screen.dart/courses_screen.dart débitent le client et
    // marquent isPaid:true dans la même transaction). C'est le cas normal.
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: true },
    'livreurs/d1': { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('livreurs/d1').wallet, 1000); // montant intégral — commission déjà prise à l'acceptation
});

test('deliverOrderCF: does NOT credit the driver for a wallet order not yet paid (deferred settlement, e.g. pharmacie_garde.dart) — regression test for the double-credit bug fixed 2026-07-09', async () => {
  const { db, store } = makeFakeDb({
    // isPaid: false — commande pharmacie : le montant final (livraison +
    // médicaments) n'est réglé qu'après livraison via payOrderFromWalletCF.
    // Avant le correctif, deliverOrderCF créditait quand même le livreur ici,
    // PUIS payOrderFromWalletCF le créditait une seconde fois post-livraison
    // — double crédit livreur + double débit client confirmé et corrigé.
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: false },
    'livreurs/d1': { wallet: 0, isOnDelivery: true },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('livreurs/d1').wallet, 0); // pas crédité ici
  assert.equal(store.get('livreurs/d1').isOnDelivery, false); // mais bien libéré
  assert.equal(store.get('orders/o1').status, 'delivered');
});

test('deliverOrderCF: wallet-paid delivery with a seller credits the partner the full amount, not the driver wallet — commission already collected at acceptance (regression test, 2026-07-09)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':       { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, sellerId: 'r1', sellerType: 'restaurant', isPaid: true },
    'livreurs/d1':     { wallet: 500 },
    'restaurants/r1':  { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('restaurants/r1').wallet, 1000); // montant intégral — commission déjà prise sur le wallet du livreur
  assert.equal(store.get('livreurs/d1').wallet, 500); // driver's own wallet untouched
  assert.equal(store.get('livreurs/d1').isOnDelivery, false);
});

test('SECURITY (Master Prompt 80): deliverOrderCF does NOT credit a partner for a wallet order whose isPaid is still false — closes a money-minting exploit (fake order + colluding/unaware driver would otherwise credit any partner for free)', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':       { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 999999, sellerId: 'r1', sellerType: 'restaurant', isPaid: false },
    'livreurs/d1':     { wallet: 500 },
    'restaurants/r1':  { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('restaurants/r1').wallet, 0); // aucun crédit tant que isPaid n'est pas vérifié
  assert.equal(store.get('livreurs/d1').wallet, 500); // livreur non plus
  assert.equal(store.get('livreurs/d1').isOnDelivery, false); // mais bien libéré
  assert.equal(store.get('orders/o1').status, 'delivered');
});

test('deliverOrderCF: does not re-credit a marketplace seller already paid at order creation', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'seller' },
    'livreurs/d1': { wallet: 500 },
    'sellers/s1':  { wallet: 1000 }, // déjà crédité en entier par create_marketplace_order
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('sellers/s1').wallet, 1000); // inchangé — pas de second crédit
  assert.equal(store.get('livreurs/d1').wallet, 500); // driver's own wallet untouched
  assert.equal(store.get('livreurs/d1').isOnDelivery, false);
  assert.equal(store.get('orders/o1').status, 'delivered');
});

test('deliverOrderCF: does not re-credit a boutique seller already paid at order creation', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1':   { driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, sellerId: 's1', sellerType: 'boutique' },
    'livreurs/d1': { wallet: 500 },
    'sellers/s1':  { wallet: 2000 }, // déjà crédité en entier par payBoutiqueOrderCF
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('sellers/s1').wallet, 2000); // inchangé — pas de second crédit
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
    'boutique_products/p1':  { sellerId: 's1', name: 'Riz 5kg', category: 'Alimentation', price: 3000, stock: 10 },
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

  const deliveryEntry = [...store.entries()].find(([k]) => k.startsWith('orders/'));
  assert.ok(deliveryEntry, 'delivery order should exist');
  assert.equal(deliveryEntry[1].latitude, 6.7);
  assert.equal(deliveryEntry[1].longitude, -3.5);
  assert.equal(deliveryEntry[1].destLat, 6.7);
  assert.equal(deliveryEntry[1].destLng, -3.5);
  assert.equal(deliveryEntry[1].pickupCityId, 'abengourou');
  assert.equal(deliveryEntry[1].deliveryCityId, 'abengourou');
  assert.equal(deliveryEntry[1].pickupZoneId, 'centre');
  assert.equal(deliveryEntry[1].deliveryZoneId, 'centre');

  assert.equal(added.filter(a => a.collection.includes('wallet_transactions')).length, 2);
  assert.equal(fakeDispatchOrder.calls.length, 1);
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'pay_boutique_order');
});

test('payBoutiqueOrderCF: rejects when stock is insufficient', async () => {
  const { db } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 1 },
    'clients/c1':           { wallet: 100000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: {
      productId: 'p1', qty: 5, deliveryLat: 6.7, deliveryLng: -3.5,
    } }),
    (err) => err.code === 'failed-precondition' && err.message.includes('STOCK_EPUISE'),
  );
});

test('payBoutiqueOrderCF: rejects with SOLDE_INSUFFISANT when balance is too low', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 10 },
    'clients/c1':           { wallet: 100 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: {
      productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5,
    } }),
    (err) => err.code === 'failed-precondition' && err.message.includes('SOLDE_INSUFFISANT'),
  );
  // Stock/wallet must be untouched on rejection.
  assert.equal(store.get('boutique_products/p1').stock, 10);
  assert.equal(store.get('clients/c1').wallet, 100);
});

test('payBoutiqueOrderCF: rejects when no boutique seller is configured', async () => {
  const { db } = makeFakeDb({
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 10 },
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
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 10 },
    'clients/c1':           { wallet: 10000 },
  });
  const throwingDispatch = async () => { throw new Error('dispatch is down'); };
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: throwingDispatch,
  });

  const result = await fn.run({ auth: { uid: 'c1' }, data: {
    productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5,
  } });

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

test('payBoutiqueOrderCF: refuses a seller whose pickup is 0/0', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1': { type: 'boutique', name: 'Boutique AZ', wallet: 0, lat: 0, lng: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz', price: 1000, stock: 2 },
    'clients/c1': { wallet: 5000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: {
      productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5,
    } }),
    (err) => err.code === 'failed-precondition' &&
      err.message.includes('collecte'),
  );
  assert.equal(store.get('clients/c1').wallet, 5000);
});

// ── payBoutiqueOrderCashCF ───────────────────────────────────────────────────
// Master Prompt 54 : l'ancien chemin cash (boutique_page.dart) décrémentait le
// stock via une écriture directe PUIS tentait de créer boutique_orders avec un
// statut qui violait la règle Firestore — cette dernière écriture échouait
// donc systématiquement, laissant le stock décrémenté sans commande créée.

test('payBoutiqueOrderCashCF: happy path decrements stock and creates the order — no wallet touched', async () => {
  fakeDispatchOrder.calls = [];
  const { db, store } = makeFakeDb({
    'sellers/s1':            { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1':  { sellerId: 's1', name: 'Riz 5kg', category: 'Alimentation', price: 3000, stock: 10 },
  });
  const logAudit = makeLogAudit();
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit, dispatchOrder: fakeDispatchOrder,
  });

  const result = await fn.run({
    auth: { uid: 'c1' },
    data: { productId: 'p1', qty: 2, deliveryLat: 6.7, deliveryLng: -3.5 },
  });

  assert.equal(result.totalPrice, 6000);
  assert.equal(result.dispatched, true);
  assert.equal(store.get('sellers/s1').wallet, 0); // jamais touché — paiement cash physique
  assert.equal(store.get('boutique_products/p1').stock, 8);

  const orderEntry = [...store.entries()].find(([k]) => k.startsWith('boutique_orders/'));
  assert.ok(orderEntry, 'boutique_orders entry should exist alongside the stock decrement');
  assert.equal(orderEntry[1].status, 'pending_payment');
  assert.equal(orderEntry[1].paymentMethod, 'cash');
  assert.equal(orderEntry[1].totalPrice, 6000);

  assert.equal(fakeDispatchOrder.calls.length, 1);
  assert.equal(logAudit.calls[0].action, 'pay_boutique_order_cash');
});

test('payBoutiqueOrderCashCF: rejects when stock is insufficient — no stock decrement, no order created', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 1 },
  });
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 5, deliveryLat: 6.7, deliveryLng: -3.5 } }),
    (err) => err.message === 'STOCK_EPUISE',
  );

  // Rien n'a bougé : ni le stock, ni une commande fantôme.
  assert.equal(store.get('boutique_products/p1').stock, 1);
  const orderEntry = [...store.entries()].find(([k]) => k.startsWith('boutique_orders/'));
  assert.equal(orderEntry, undefined);
});

test('payBoutiqueOrderCashCF: two purchases against the last unit — only one succeeds, stock never goes negative', async () => {
  // Proxy pour "double achat simultané" : avec ce faux Firestore synchrone,
  // deux transactions ne peuvent jamais littéralement s'exécuter en parallèle
  // (comme en JS single-thread) — mais ça reproduit fidèlement la garantie
  // que Firestore lui-même offre : le net effect de deux transactions
  // concurrentes équivaut toujours à un ordre séquentiel, jamais à une
  // survente. La 2ᵉ tentative doit voir le stock déjà à 0 et échouer proprement.
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 1 },
  });
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  const first  = await fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5 } });
  assert.ok(first.orderId);

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c2' }, data: { productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5 } }),
    (err) => err.message === 'STOCK_EPUISE',
  );

  assert.equal(store.get('boutique_products/p1').stock, 0); // jamais négatif
  const orders = [...store.entries()].filter(([k]) => k.startsWith('boutique_orders/'));
  assert.equal(orders.length, 1); // une seule commande créée, pas deux
});

test('payBoutiqueOrderCashCF: restores stock exactly once when dispatch throws', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1':           { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 5 },
  });
  const throwingDispatch = async () => { throw new Error('dispatch is down'); };
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: throwingDispatch,
  });

  await assert.rejects(
    () => fn.run({
      auth: { uid: 'c1' },
      data: { productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5 },
    }),
    (err) => err.code === 'unavailable',
  );

  assert.equal(store.get('boutique_products/p1').stock, 5);
  const order = [...store.entries()].find(([k]) => k.startsWith('boutique_orders/'))?.[1];
  assert.equal(order.status, 'dispatch_failed');
});

test('payBoutiqueOrderCashCF: rejects an unknown product', async () => {
  const { db } = makeFakeDb({
    'sellers/s1': { type: 'boutique', name: 'Boutique AZ', wallet: 0 },
  });
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'missing', qty: 1 } }),
    (err) => err.code === 'not-found',
  );
});

test('payBoutiqueOrderCashCF: rejects when no boutique seller is configured', async () => {
  const { db } = makeFakeDb({
    'boutique_products/p1': { sellerId: 's1', name: 'Riz 5kg', price: 3000, stock: 5 },
  });
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('payBoutiqueOrderCashCF: rejects unauthenticated calls', async () => {
  const { db } = makeFakeDb();
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });
  await assert.rejects(
    () => fn.run({ data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'unauthenticated',
  );
});

// ── refundExpiredBoutiqueOrderCF ────────────────────────────────────────────

test('refundExpiredBoutiqueOrderCF: refunds the client and debits the seller once the 48h deadline has passed', async () => {
  const { db, store } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'paid', totalPrice: 5000,
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 5000 }, // déjà crédité en entier à l'achat
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'bo1' } });

  assert.deepEqual(result, { success: true, amount: 5000 });
  assert.equal(store.get('clients/c1').wallet, 5000);
  assert.equal(store.get('sellers/s1').wallet, 0);
  assert.equal(store.get('boutique_orders/bo1').status, 'refunded');
});

test('refundExpiredBoutiqueOrderCF: clamps the seller debit at 0 if they already spent part of the credit', async () => {
  const { db, store } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'paid', totalPrice: 5000,
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 1000 }, // a déjà retiré une partie des 5000 FCFA crédités
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'bo1' } });

  assert.equal(store.get('clients/c1').wallet, 5000); // remboursé en entier malgré tout
  assert.equal(store.get('sellers/s1').wallet, 0);     // repris jusqu'à 0, jamais négatif
});

test('refundExpiredBoutiqueOrderCF: rejects when the 48h deadline has not passed yet', async () => {
  const { db } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'paid', totalPrice: 5000,
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() + 60000),
    },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 5000 },
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'bo1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('refundExpiredBoutiqueOrderCF: rejects a caller who does not own the order', async () => {
  const { db } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'paid', totalPrice: 5000,
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    },
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'stranger' }, data: { orderId: 'bo1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('refundExpiredBoutiqueOrderCF: rejects an order that is not in "paid" status', async () => {
  const { db } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'delivered', totalPrice: 5000,
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    },
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'bo1' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('refundExpiredBoutiqueOrderCF: rejects unauthenticated calls', async () => {
  const { db } = makeFakeDb();
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });
  await assert.rejects(
    () => fn.run({ data: { orderId: 'bo1' } }),
    (err) => err.code === 'unauthenticated',
  );
});

test('deliverOrderCF: synchronizes the linked boutique order atomically', async () => {
  const { db, store } = makeFakeDb({
    'orders/o1': {
      driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 500,
      sellerId: 's1', sellerType: 'boutique', linkedBoutiqueOrderId: 'bo1',
    },
    'boutique_orders/bo1': { status: 'paid', deliveryOrderId: 'o1' },
    'livreurs/d1': { wallet: 0 },
  });
  const fn = buildDeliverOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });

  assert.equal(store.get('orders/o1').status, 'delivered');
  assert.equal(store.get('boutique_orders/bo1').status, 'delivered');
});

test('refundExpiredBoutiqueOrderCF: rejects a paid order when its linked delivery is delivered', async () => {
  const { db, store } = makeFakeDb({
    'boutique_orders/bo1': {
      clientId: 'c1', sellerId: 's1', status: 'paid', totalPrice: 5000,
      deliveryOrderId: 'o1',
      deliveryDeadline: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 1000),
    },
    'orders/o1': { status: 'delivered', linkedBoutiqueOrderId: 'bo1' },
    'clients/c1': { wallet: 0 },
    'sellers/s1': { wallet: 5000 },
  });
  const fn = buildRefundExpiredBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(),
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'bo1' } }),
    (err) => err.code === 'failed-precondition',
  );
  assert.equal(store.get('clients/c1').wallet, 0);
  assert.equal(store.get('boutique_orders/bo1').status, 'paid');
});

test('payBoutiqueOrderCF: credits only the seller declared by the product', async () => {
  const { db, store } = makeFakeDb({
    'sellers/s1': { type: 'boutique', wallet: 0 },
    'sellers/s2': { type: 'boutique', wallet: 0 },
    'boutique_products/p1': { sellerId: 's2', name: 'Riz', price: 1000, stock: 2 },
    'clients/c1': { wallet: 5000 },
  });
  const fn = buildPayBoutiqueOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await fn.run({ auth: { uid: 'c1' }, data: {
    productId: 'p1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5,
  } });

  assert.equal(store.get('sellers/s1').wallet, 0);
  assert.equal(store.get('sellers/s2').wallet, 1000);
});

test('payBoutiqueOrderCF: rejects a product without a sellerId', async () => {
  const { db } = makeFakeDb({
    'boutique_products/p1': { name: 'Riz', price: 1000, stock: 2 },
    'clients/c1': { wallet: 5000 },
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

test('payBoutiqueOrderCashCF: rejects a suspended product seller', async () => {
  const { db } = makeFakeDb({
    'sellers/s1': { type: 'boutique', isSuspended: true, wallet: 0 },
    'boutique_products/p1': { sellerId: 's1', name: 'Riz', price: 1000, stock: 2 },
  });
  const fn = buildPayBoutiqueOrderCash({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: makeCheckRateLimit(), logAudit: makeLogAudit(), dispatchOrder: fakeDispatchOrder,
  });

  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { productId: 'p1', qty: 1 } }),
    (err) => err.code === 'failed-precondition',
  );
});
