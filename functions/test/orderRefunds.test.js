'use strict';

// Les deux chemins de remboursement automatique d'index.js, désormais dans
// orderRefunds.js : autoExpireOrders (10 min sans livreur) et
// enforceOrderRateLimit (plus de 10 commandes/heure).

const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb } = require('./fakeFirestore');
const { world, admin } = require('./billingWorld');
const { expireOrderTx, rateLimitCancelTx } = require('../orderRefunds');

function setup(order, { client = 4500, seller = 5000 } = {}) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: client },
    'sellers/s1': { wallet: seller },
  });
  const ref = db.collection('orders').doc('o1');
  const expire = () => db.runTransaction((tx) => expireOrderTx(tx, { db, admin, orderRef: ref, orderId: 'o1' }));
  const rateLimit = (snapshot) => db.runTransaction((tx) => rateLimitCancelTx(tx, {
    db, admin, orderRef: ref, orderId: 'o1', order: snapshot || db.store.get('orders/o1'), clientId: 'c1',
  }));
  const w = (p) => db.store.get(p).wallet;
  return { db, expire, rateLimit, w, order: () => db.store.get('orders/o1') };
}

const explicit = (extra = {}) => ({
  clientId: 'c1', status: 'pending', paymentMethod: 'wallet', isPaid: true, sellerId: 's1', sellerType: 'seller',
  type: 'marketplace', amountsVersion: 1, productAmount: 5000, deliveryFee: 500, totalAmount: 5500, budget: 500,
  deliveryFeePaid: true, ...extra,
});

// ───────────────────────────── autoExpireOrders ─────────────────────────────
for (const status of ['pending', 'broadcast', 'assigned']) {
  test(`autoExpireOrders (${status}) : marketplace wallet à montants explicites — client rendu 5500, vendeur repris 5000`, async () => {
    const t = setup(explicit({ status }));
    const r = await t.expire();
    assert.deepEqual(r, { expired: true, refunded: 5500 });
    assert.equal(t.order().status, 'cancelled');
    assert.equal(t.order().cancelReason, 'no_driver_found');
    assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [10000, 0]);
  });
}

test('autoExpireOrders : rejeu — un second passage ne rembourse pas deux fois', async () => {
  const t = setup(explicit());
  await t.expire();
  const again = await t.expire();
  assert.equal(again.expired, false);
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [10000, 0]);
});

test('autoExpireOrders : accepté entre-temps (course en cours) → rien annulé, rien remboursé', async () => {
  for (const status of ['accepted', 'picked_up', 'delivered', 'cancelled']) {
    const t = setup(explicit({ status }));
    assert.equal((await t.expire()).expired, false);
    assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [4500, 5000]);
  }
});

test('autoExpireOrders : commande remise en file il y a moins de 10 min → épargnée', async () => {
  const t = setup(explicit({ requeuedAt: { toMillis: () => Date.now() - 60 * 1000 } }));
  assert.equal((await t.expire()).expired, false);
  assert.equal(t.order().status, 'pending');
});

test('autoExpireOrders : cash → annulée sans remboursement (rien n’avait été payé)', async () => {
  const t = setup(explicit({ paymentMethod: 'cash', isPaid: false, deliveryFeePaid: false }));
  const r = await t.expire();
  assert.deepEqual(r, { expired: true, refunded: 0 });
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [4500, 5000]);
});

test('autoExpireOrders : wallet non payé (isPaid false) → aucun remboursement fictif', async () => {
  const t = setup(explicit({ isPaid: false }));
  assert.equal((await t.expire()).refunded, 0);
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [4500, 5000]);
});

test('autoExpireOrders : reprise vendeur plafonnée à son solde (jamais négatif)', async () => {
  const t = setup(explicit(), { seller: 1200 });
  await t.expire();
  assert.equal(t.w('sellers/s1'), 0);
  assert.equal(t.w('clients/c1'), 10000);
});

test('autoExpireOrders : commande marketplace historique → remboursement du budget (comportement inchangé)', async () => {
  const t = setup({ clientId: 'c1', status: 'pending', paymentMethod: 'wallet', isPaid: true, budget: 5000,
    sellerId: 's1', sellerType: 'seller' }, { client: 0 });
  assert.equal((await t.expire()).refunded, 5000);
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [5000, 0]);
});

test('autoExpireOrders : montants altérés → traitée comme historique (jamais plus que le budget)', async () => {
  const t = setup(explicit({ totalAmount: 99999 }), { client: 0 });
  assert.equal((await t.expire()).refunded, 500);
});

test('autoExpireOrders : course boutique (document de livraison, isPaid false) → pas de remboursement ici (il vit sur boutique_orders)', async () => {
  const t = setup(explicit({ type: 'boutique', sellerType: 'boutique', isPaid: false }));
  assert.equal((await t.expire()).refunded, 0);
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [4500, 5000]);
});

test('autoExpireOrders : conservation — client + vendeur avant = client + vendeur après − frais remboursés par la caisse', async () => {
  const t = setup(explicit());
  const before = t.w('clients/c1') + t.w('sellers/s1'); // 9500 : les 500 de frais étaient en transit
  await t.expire();
  assert.equal(t.w('clients/c1') + t.w('sellers/s1'), before + 500);
});

// ───────────────────────────── enforceOrderRateLimit ─────────────────────────────
test('limite de commandes : marketplace wallet à montants explicites — client rendu 5500, vendeur repris 5000 (anomalie corrigée)', async () => {
  const t = setup(explicit());
  const r = await t.rateLimit();
  assert.deepEqual(r, { cancelled: true, refunded: 5500 });
  assert.equal(t.order().cancelReason, 'rate_limit_exceeded');
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [10000, 0]);
});

test('limite de commandes : rejeu — une commande déjà annulée n’est pas remboursée une seconde fois', async () => {
  const t = setup(explicit());
  const snapshot = { ...t.order() };
  await t.rateLimit(snapshot);
  assert.equal((await t.rateLimit(snapshot)).cancelled, false); // l'instantané est périmé, l'état serveur fait foi
  assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [10000, 0]);
});

test('limite de commandes : commande déjà prise en charge → non annulée', async () => {
  for (const status of ['accepted', 'assigned', 'broadcast', 'picked_up']) {
    const t = setup(explicit({ status }));
    assert.equal((await t.rateLimit()).cancelled, false);
    assert.deepEqual([t.w('clients/c1'), t.w('sellers/s1')], [4500, 5000]);
  }
});

test('limite de commandes : cash → annulée sans remboursement ; wallet non payé → aucun remboursement', async () => {
  const cash = setup(explicit({ paymentMethod: 'cash', isPaid: false }));
  assert.deepEqual(await cash.rateLimit(), { cancelled: true, refunded: 0 });
  assert.deepEqual([cash.w('clients/c1'), cash.w('sellers/s1')], [4500, 5000]);
  const unpaid = setup(explicit({ isPaid: false }));
  assert.equal((await unpaid.rateLimit()).refunded, 0);
});

test('limite de commandes : vendeur historique plafonné, livraison ordinaire (sans vendeur) remboursée sans reprise', async () => {
  const legacy = setup({ clientId: 'c1', status: 'pending', paymentMethod: 'wallet', isPaid: true, budget: 5000,
    sellerId: 's1', sellerType: 'seller' }, { client: 0, seller: 1200 });
  await legacy.rateLimit();
  assert.deepEqual([legacy.w('clients/c1'), legacy.w('sellers/s1')], [5000, 0]);
  const plain = setup({ clientId: 'c1', status: 'pending', paymentMethod: 'wallet', isPaid: true, budget: 1000 });
  assert.equal((await plain.rateLimit()).refunded, 1000);
  assert.equal(plain.w('sellers/s1'), 5000);
});

// ───────────────────────────── branchement dans index.js ─────────────────────────────
test('index.js appelle bien ces deux fonctions (pas de logique de remboursement dupliquée)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(src, /expireOrderTx\(tx, \{ db, admin, orderRef: doc\.ref, orderId \}\)/);
  assert.match(src, /rateLimitCancelTx\(tx, \{ db, admin, orderRef, orderId, order, clientId \}\)/);
  assert.doesNotMatch(src, /Remboursement — limite de commandes dépassée/);
  assert.doesNotMatch(src, /Remboursement — aucun livreur disponible/);
});

test('harnais partagé disponible (sanity)', () => {
  assert.equal(typeof world, 'function');
});
