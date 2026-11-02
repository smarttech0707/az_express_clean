'use strict';

// Fiabilité des commandes (audit du 2026-10-30) :
//  - C1 : les remboursements automatiques (expiration, limite de débit) rendent
//    TOUT ce qui a été débité (budget + shoppingBudget), et jamais plus.
//  - I1 : après récupération du colis, un client ne peut plus annuler seul.
//
// Concurrence : le faux Firestore n'isole pas les transactions. On le sérialise
// (serialize) pour modéliser la garantie de Firestore (une transaction en conflit
// est rejouée sur l'état à jour) ; ce n'est PAS un test sur émulateur.

const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb } = require('./fakeFirestore');
const { world, admin } = require('./billingWorld');
const { expireOrderTx, rateLimitCancelTx, refundAmounts } = require('../orderRefunds');
const { cancelOrder } = require('../azia/tools/delivery');
const { HttpsError } = require('firebase-functions/v2/https');

function serialize(db) {
  const run = db.runTransaction;
  let chain = Promise.resolve();
  db.runTransaction = (cb) => {
    const p = chain.then(() => run(cb));
    chain = p.catch(() => {});
    return p;
  };
  return db;
}

function setup(order, { client = 0, seller = 5000 } = {}) {
  const db = serialize(fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: client },
    'sellers/s1': { wallet: seller },
  }));
  const ref = db.collection('orders').doc('o1');
  const expire = () => db.runTransaction((tx) => expireOrderTx(tx, { db, admin, orderRef: ref, orderId: 'o1' }));
  const rateLimit = () => db.runTransaction((tx) => rateLimitCancelTx(tx, {
    db, admin, orderRef: ref, orderId: 'o1', order: db.store.get('orders/o1'), clientId: 'c1',
  }));
  const w = (p) => db.store.get(p).wallet;
  const refundTxs = () => [...db.store.entries()]
    .filter(([k, v]) => k.startsWith('clients/c1/wallet_transactions/') && v.type === 'refund');
  return { db, expire, rateLimit, w, refundTxs, order: () => db.store.get('orders/o1') };
}

const courses = (extra = {}) => ({
  clientId: 'c1', status: 'pending', type: 'courses', paymentMethod: 'wallet', isPaid: true,
  budget: 500, shoppingBudget: 3000, ...extra,
});

// ───────────────────────────── C1 : montants ─────────────────────────────
test('refundAmounts : budget + shoppingBudget ; la part vendeur ne contient jamais le shoppingBudget', () => {
  assert.deepEqual(refundAmounts({ budget: 500, shoppingBudget: 3000 }), { total: 3500, sellerShare: 500 });
  assert.deepEqual(refundAmounts({ budget: 500 }), { total: 500, sellerShare: 500 });
  assert.deepEqual(refundAmounts({
    amountsVersion: 1, productAmount: 5000, deliveryFee: 500, totalAmount: 5500, budget: 500, shoppingBudget: 200,
  }), { total: 5700, sellerShare: 5000 });
  // Valeurs aberrantes : jamais un remboursement négatif ni NaN.
  for (const bad of [-100, 'abc', null, undefined, NaN, Infinity]) {
    const r = refundAmounts({ budget: 500, shoppingBudget: bad });
    assert.ok(Number.isFinite(r.total) && r.total >= 500, `shoppingBudget=${String(bad)}`);
  }
});

test('expiration automatique : Courses wallet — le client récupère livraison + achats (3500), une seule écriture de journal', async () => {
  const t = setup(courses());
  assert.deepEqual(await t.expire(), { expired: true, refunded: 3500 });
  assert.equal(t.w('clients/c1'), 3500);
  assert.equal(t.refundTxs().length, 1);
  assert.equal(t.refundTxs()[0][1].amount, 3500);
  assert.equal(t.order().status, 'cancelled');
});

test('limite de débit : Courses wallet — même remboursement intégral (3500)', async () => {
  const t = setup(courses());
  assert.deepEqual(await t.rateLimit(), { cancelled: true, refunded: 3500 });
  assert.equal(t.w('clients/c1'), 3500);
});

test('livraison simple wallet (sans shoppingBudget) : remboursement inchangé', async () => {
  const t = setup(courses({ shoppingBudget: 0, type: 'livraison' }));
  assert.equal((await t.expire()).refunded, 500);
  assert.equal(t.w('clients/c1'), 500);
});

test('paiement cash avec shoppingBudget : rien n’a été débité, rien n’est remboursé', async () => {
  for (const run of ['expire', 'rateLimit']) {
    const t = setup(courses({ paymentMethod: 'cash', isPaid: false }));
    assert.equal((await t[run]()).refunded, 0);
    assert.equal(t.w('clients/c1'), 0);
    assert.equal(t.refundTxs().length, 0);
  }
});

test('pharmacie / wallet non payé (règlement après livraison) : aucun remboursement fictif', async () => {
  for (const run of ['expire', 'rateLimit']) {
    const t = setup(courses({ type: 'pharmacie', isPaid: false }));
    assert.equal((await t[run]()).refunded, 0);
    assert.equal(t.w('clients/c1'), 0);
  }
});

test('marketplace à montants explicites + shoppingBudget : client rendu en entier, vendeur repris des seuls produits', async () => {
  const t = setup({
    ...courses({ shoppingBudget: 200 }), type: 'marketplace', sellerId: 's1', sellerType: 'seller',
    amountsVersion: 1, productAmount: 5000, deliveryFee: 500, totalAmount: 5500, budget: 500, deliveryFeePaid: true,
  });
  assert.equal((await t.expire()).refunded, 5700);
  assert.equal(t.w('clients/c1'), 5700);
  assert.equal(t.w('sellers/s1'), 0);
});

test('parité : l’expiration rend exactement ce que rend l’annulation manuelle (une seule règle de montant)', async () => {
  const order = { clientId: 'c1', status: 'pending', type: 'courses', paymentMethod: 'wallet', isPaid: true,
    budget: 700, shoppingBudget: 2300 };
  const manual = world({ 'orders/o1': order, 'clients/c1': { wallet: 0 } });
  await manual.call('cancel', 'c1', { orderId: 'o1' });
  const auto = setup({ ...order });
  await auto.expire();
  assert.equal(manual.w('clients/c1'), 3000);
  assert.equal(auto.w('clients/c1'), manual.w('clients/c1'));
});

// ───────────────────────────── C1 : idempotence, concurrence, erreurs partielles ─────────────────────────────
test('réexécution : expiration puis limite de débit puis expiration — un seul remboursement', async () => {
  const t = setup(courses());
  await t.expire();
  assert.equal((await t.expire()).expired, false);
  assert.equal((await t.rateLimit()).cancelled, false);
  assert.equal(t.w('clients/c1'), 3500);
  assert.equal(t.refundTxs().length, 1);
});

test('tentatives concurrentes (expiration ×3 + limite de débit ×2) : un seul remboursement', async () => {
  const t = setup(courses());
  await Promise.all([t.expire(), t.expire(), t.rateLimit(), t.expire(), t.rateLimit()]);
  assert.equal(t.w('clients/c1'), 3500);
  assert.equal(t.refundTxs().length, 1);
  assert.equal(t.order().status, 'cancelled');
});

test('acceptation concurrente : un livreur accepte avant l’expiration → aucune annulation ni remboursement', async () => {
  const t = setup(courses());
  const accept = t.db.runTransaction(async (tx) => {
    tx.update(t.db.collection('orders').doc('o1'), { status: 'accepted', driverId: 'dA' });
  });
  await Promise.all([accept, t.expire()]);
  assert.equal(t.order().status, 'accepted');
  assert.equal(t.w('clients/c1'), 0);
  assert.equal(t.refundTxs().length, 0);
});

test('erreur partielle : transaction interrompue après le calcul du remboursement → rien n’est écrit, la reprise rembourse une fois', async () => {
  const t = setup(courses());
  await assert.rejects(() => t.db.runTransaction(async (tx) => {
    await expireOrderTx(tx, { db: t.db, admin, orderRef: t.db.collection('orders').doc('o1'), orderId: 'o1' });
    throw new Error('coupure réseau');
  }), /coupure réseau/);
  assert.equal(t.order().status, 'pending');
  assert.equal(t.w('clients/c1'), 0);
  assert.equal(t.refundTxs().length, 0);
  await t.expire();
  assert.equal(t.w('clients/c1'), 3500);
  assert.equal(t.refundTxs().length, 1);
});

// ───────────────────────────── I1 : annulation après récupération ─────────────────────────────
const pickedUpOrder = (extra = {}) => ({
  clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
  budget: 1000, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, ...extra,
});
const refused = (e) => e.code === 'failed-precondition' && /récupéré/.test(e.message);
const money = (h) => [h.w('clients/c1'), h.w('livreurs/dA')];

test('I1 wallet : le client ne peut plus annuler après picked_up — aucun remboursement, commission non rendue, demande tracée', async () => {
  const h = world({ 'orders/o1': pickedUpOrder(), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 } });
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
  assert.deepEqual(money(h), [9000, 900]);
  const o = h.get('orders/o1');
  assert.equal(o.status, 'picked_up');
  assert.equal(o.commissionStatus, 'charged');
  assert.equal(o.cancelRequestAfterPickup.status, 'pending_admin_review');
  assert.equal(o.cancelRequestAfterPickup.requestedBy, 'c1');
  assert.equal(h.keys('clients/c1/wallet_transactions/').length, 0);
});

test('I1 cash : même refus, aucun mouvement', async () => {
  const h = world({
    'orders/o1': pickedUpOrder({ paymentMethod: 'cash', isPaid: false }),
    'clients/c1': { wallet: 5000 }, 'livreurs/dA': { wallet: 900 },
  });
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
  assert.deepEqual(money(h), [5000, 900]);
});

test('I1 : une seconde demande ne remplace pas la première (idempotent)', async () => {
  const h = world({ 'orders/o1': pickedUpOrder(), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 } });
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
  const first = h.get('orders/o1').cancelRequestAfterPickup;
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
  assert.deepEqual(h.get('orders/o1').cancelRequestAfterPickup, first);
});

test('I1 : horodatage de récupération sans statut cohérent — également refusé', async () => {
  const h = world({
    'orders/o1': pickedUpOrder({ status: 'accepted', pickedUpAt: 1 }),
    'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 },
  });
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
  assert.deepEqual(money(h), [9000, 900]);
});

test('I1 : marketplace et pharmacie récupérées — refusées au client aussi', async () => {
  for (const extra of [
    { type: 'marketplace', sellerId: 's1', sellerType: 'seller' },
    { type: 'pharmacie', sellerId: 'ph1', sellerType: 'pharmacie', isPaid: false },
  ]) {
    const h = world({ 'orders/o1': pickedUpOrder(extra), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 } });
    await assert.rejects(() => h.call('cancel', 'c1', { orderId: 'o1' }), refused);
    assert.deepEqual(money(h), [9000, 900]);
    assert.equal(h.get('orders/o1').status, 'picked_up');
  }
});

test('I1 : un autre client ne peut ni annuler ni laisser de trace sur la commande', async () => {
  const h = world({
    'orders/o1': pickedUpOrder(), 'clients/c1': { wallet: 9000 }, 'clients/c2': { wallet: 0 },
    'livreurs/dA': { wallet: 900 },
  });
  await assert.rejects(() => h.call('cancel', 'c2', { orderId: 'o1' }), (e) => e.code === 'permission-denied');
  assert.equal(h.get('orders/o1').cancelRequestAfterPickup, undefined);
});

test('I1 : annulation AVANT récupération préservée — client remboursé, commission rendue', async () => {
  const h = world({
    'orders/o1': pickedUpOrder({ status: 'accepted' }), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 },
  });
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.deepEqual(money(h), [10000, 1000]);
  assert.equal(h.get('orders/o1').status, 'cancelled');
  assert.equal(h.get('orders/o1').cancelRequestAfterPickup, undefined);
});

test('I1 : annulations concurrentes après récupération — aucune ne rembourse', async () => {
  const h = world({ 'orders/o1': pickedUpOrder(), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 } });
  serialize(h.db);
  const results = await Promise.allSettled([1, 2, 3].map(() => h.call('cancel', 'c1', { orderId: 'o1' })));
  assert.ok(results.every((r) => r.status === 'rejected'));
  assert.deepEqual(money(h), [9000, 900]);
});

test('I1 : course entre annulation et récupération — l’argent est conservé dans les deux ordres', async () => {
  for (const pickFirst of [true, false]) {
    const h = world({
      'orders/o1': pickedUpOrder({ status: 'accepted' }), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 },
    });
    serialize(h.db);
    const pick = () => h.db.runTransaction(async (tx) => {
      tx.update(h.db.collection('orders').doc('o1'), { status: 'picked_up', pickedUpAt: 1 });
    });
    const cancel = () => h.call('cancel', 'c1', { orderId: 'o1' }).catch(() => 'refused');
    if (pickFirst) await Promise.all([pick(), cancel()]); else await Promise.all([cancel(), pick()]);
    const status = h.get('orders/o1').status;
    if (status === 'cancelled') assert.deepEqual(money(h), [10000, 1000]);
    else assert.deepEqual(money(h), [9000, 900]);
    // Jamais « récupéré ET remboursé ».
    assert.ok(!(status !== 'cancelled' && h.w('clients/c1') > 9000));
  }
});

test('I1 : l’administrateur peut toujours clore une commande récupérée (adminBilling), avec justification et trace', async () => {
  const h = world();
  await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
  const id = h.keys('orders/')[0].split('/')[1];
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: id }), refused);
  await h.call('adminBilling', 'root', { action: 'closeStuckDelivery', orderId: id, justification: 'Litige constaté' });
  assert.equal(h.get(`orders/${id}`).status, 'cancelled');
  assert.equal(h.get(`orders/${id}`).adminReview.action, 'closeStuckDelivery');
});

test('I1 AZ IA : cancel_order refuse une commande récupérée, aussi à la confirmation (état modifié entre-temps)', async () => {
  const db = fakeDb({
    'orders/o1': pickedUpOrder(), 'clients/c1': { wallet: 9000 }, 'livreurs/dA': { wallet: 900 },
  });
  const tool = cancelOrder({ db, admin, HttpsError });
  const r = await tool.handler('c1', { orderId: 'o1' }, {});
  assert.match(r.error, /récupéré/);
  await assert.rejects(() => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', { orderId: 'o1' })), refused);
  assert.deepEqual([db.store.get('clients/c1').wallet, db.store.get('livreurs/dA').wallet], [9000, 900]);
});
