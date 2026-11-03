'use strict';

// Mission 7B-2 — flux financiers des commandes Restaurant / Boulangerie amountsVersion 2 : livraison, annulation,
// remboursement, cash. Fonctions RÉELLES (buildDeliverOrder, buildCancelOrder, buildPayOrderFromWallet,
// expireOrderTx) sur faux Firestore ; données fictives.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { buildDeliverOrder, buildCancelOrder, buildPayOrderFromWallet, cancelOrderTx } = require('../orderActions');
const { expireOrderTx } = require('../orderRefunds');
const { readAmounts } = require('../orderAmounts');
const { partnerBreakdown } = require('../partnerOrderAmounts');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'TS', increment: (n) => ({ __inc: n }), delete: () => ({ __del: true }) }, Timestamp: { fromMillis: (n) => n } } };
const oc = (...a) => ({ run: a[a.length - 1] });
const auth = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });

const v2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000,
  budget: 500, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, ...extra,
});

function world(orderExtra = {}, { seed = {}, serialize = true } = {}) {
  const db = fakeDb({
    'orders/o1': v2(orderExtra),
    'clients/c1': { wallet: 16000 },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000 },
    'boulangeries/b1': { name: 'Boulangerie Test', wallet: 2000 },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1' },
    ...seed,
  });
  if (serialize) { // l'émulateur sérialise réellement ; le faux Firestore non : on le sérialise ici
    const run = db.runTransaction; let chain = Promise.resolve();
    db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  }
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission: async () => 100 };
  const deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const cancel = buildCancelOrder({ ...common, onCall: oc }).run;
  const pay = buildPayOrderFromWallet({ ...common, onCall: oc }).run;
  const s = db.store;
  return {
    db, s, audits, deliver, cancel, pay,
    d: () => deliver({ auth: auth('dA'), data: { orderId: 'o1' } }),
    c: () => cancel({ auth: auth('c1'), data: { orderId: 'o1' } }),
    w: (path) => s.get(path).wallet,
    keys: (prefix) => [...s.keys()].filter((k) => k.startsWith(prefix)),
    order: () => s.get('orders/o1'),
  };
}

// ── Lecture des montants ──────────────────────────────────────────────────

test('readAmounts : v2 acceptée pour restaurant/boulangerie seulement ; incohérente → null ; v1 inchangée', () => {
  assert.deepEqual(readAmounts(v2()), { productAmount: 3500, deliveryFee: 500, totalAmount: 4000 });
  assert.deepEqual(readAmounts(v2({ sellerType: 'boulangerie' })), { productAmount: 3500, deliveryFee: 500, totalAmount: 4000 });
  assert.equal(readAmounts(v2({ sellerType: 'seller' })), null);
  assert.equal(readAmounts(v2({ totalAmount: 3999 })), null);
  assert.equal(readAmounts(v2({ budget: 3500 })), null);
  assert.deepEqual(readAmounts({ amountsVersion: 1, productAmount: 100, deliveryFee: 500, totalAmount: 600, budget: 500 }), { productAmount: 100, deliveryFee: 500, totalAmount: 600 });
  assert.equal(readAmounts({ budget: 500 }), null);
});

// ── Livraison wallet ──────────────────────────────────────────────────────

test('livraison wallet v2 : partenaire +produits, livreur +frais, client intact, commission non reprélevée, journaux déterministes', async () => {
  const t = world();
  assert.equal((await t.d()).success, true);
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.w('restaurants/r1'), 1000 + 3500);
  assert.equal(t.w('livreurs/dA'), 900 + 500);
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.order().commissionStatus, 'charged');
  assert.equal(t.order().commissionAmount, 100);
  assert.deepEqual(t.keys('restaurants/r1/wallet_transactions/'), ['restaurants/r1/wallet_transactions/earning_o1']);
  assert.deepEqual(t.keys('livreurs/dA/wallet_transactions/'), ['livreurs/dA/wallet_transactions/earning_o1']);
  assert.equal(t.s.get('restaurants/r1/wallet_transactions/earning_o1').amount, 3500);
  assert.equal(t.s.get('livreurs/dA/wallet_transactions/earning_o1').amount, 500);
  // La commission AZ journalisée = celle de l'acceptation, calculée sur les frais seuls (jamais sur les produits).
  const commission = t.s.get([...t.s.keys()].find((k) => k.startsWith('commissions/')));
  assert.deepEqual([commission.amount, commission.deliveryFee, commission.driverGain], [100, 500, 400]);
  const b = partnerBreakdown({ productAmount: 3500, deliveryFee: 500 }, { commission: 100 });
  assert.deepEqual([b.partnerDue, b.driverNet, b.azCommission], [3500, 400, 100]);
});

test('livraison wallet v2 boulangerie : même règle sur la collection boulangeries', async () => {
  const t = world({ sellerType: 'boulangerie', type: 'boulangerie', sellerId: 'b1' });
  await t.d();
  assert.equal(t.w('boulangeries/b1'), 2000 + 3500);
  assert.equal(t.w('livreurs/dA'), 900 + 500);
});

test('double livraison (rejeu / double appui) : aucun second crédit ni second journal', async () => {
  const t = world();
  await t.d();
  await assert.rejects(() => t.d(), (e) => e.code === 'failed-precondition');
  await Promise.allSettled([t.d(), t.d()]);
  assert.equal(t.w('restaurants/r1'), 4500);
  assert.equal(t.w('livreurs/dA'), 1400);
  assert.equal(t.keys('restaurants/r1/wallet_transactions/').length, 1);
  assert.equal(t.keys('livreurs/dA/wallet_transactions/').length, 1);
});

test('partenaire introuvable à la livraison : livreur payé, montant dû signalé (jamais perdu en silence)', async () => {
  const t = world({ sellerId: 'ghost' });
  await t.d();
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.w('livreurs/dA'), 1400);
  const flag = t.s.get('reconciliation_flags/o1_partner_credit_missing');
  assert.deepEqual([flag.type, flag.status, flag.amount], ['partner_credit_missing', 'open', 3500]);
});

test('course transférée (gain retenu) : partenaire payé, gain livreur retenu pour l\'administration', async () => {
  const t = world({ settlementHold: true });
  await t.d();
  assert.equal(t.w('restaurants/r1'), 4500);
  assert.equal(t.w('livreurs/dA'), 900, 'aucun crédit au livreur final seul');
  assert.equal(t.order().heldDriverEarning, 500);
  assert.equal(t.order().settlementStatus, 'pending_admin_review');
});

test('v2 aux montants incohérents : livraison bloquée, jamais traitée comme une commande historique', async () => {
  const t = world({ totalAmount: 1 });
  await assert.rejects(() => t.d(), (e) => e.code === 'failed-precondition');
  assert.equal(t.order().status, 'accepted');
  assert.equal(t.w('restaurants/r1'), 1000);
  assert.equal(t.w('livreurs/dA'), 900);
  await assert.rejects(() => t.c(), /ORDER_AMOUNTS_INCONSISTENT/);
  assert.equal(t.w('clients/c1'), 16000);
});

// ── Livraison cash ────────────────────────────────────────────────────────

test('livraison cash v2 : aucun mouvement de wallet, remise au partenaire tracée et à confirmer', async () => {
  const t = world({ paymentMethod: 'cash', isPaid: false });
  await t.d();
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.w('restaurants/r1'), 1000);
  assert.equal(t.w('livreurs/dA'), 900);
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.keys('restaurants/r1/wallet_transactions/').length, 0);
  assert.equal(t.keys('livreurs/dA/wallet_transactions/').length, 0);
  assert.equal(t.order().merchantCashSettled, false);
  assert.deepEqual(t.order().cashBreakdown, {
    productAmount: 3500, deliveryFee: 500, cashCollected: 4000, dueToSeller: 3500, driverGross: 500, commissionAmount: 100, driverNet: 400,
  });
  const r = t.order().cashRemittance;
  assert.deepEqual([r.status, r.orderId, r.partnerId, r.driverId, r.amountDue, r.amountHandedOver, r.partnerConfirmedAtMs],
    ['pending', 'o1', 'r1', 'dA', 3500, null, null]);
});

test('cash v2 : jamais de double règlement — payOrderFromWalletCF refuse toute commande v2 (cash ou wallet)', async () => {
  const cash = world({ paymentMethod: 'cash', isPaid: false });
  await assert.rejects(() => cash.pay({ auth: auth('c1'), data: { orderId: 'o1' } }), (e) => e.code === 'failed-precondition');
  assert.equal(cash.w('clients/c1'), 16000); assert.equal(cash.w('livreurs/dA'), 900);
  const paid = world();
  await assert.rejects(() => paid.pay({ auth: auth('c1'), data: { orderId: 'o1' } }), (e) => e.code === 'failed-precondition');
  assert.equal(paid.w('clients/c1'), 16000);
});

test('annulation cash v2 : aucun remboursement ni mouvement de wallet', async () => {
  const t = world({ paymentMethod: 'cash', isPaid: false, status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
  await t.c();
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.w('restaurants/r1'), 1000);
});

// ── Annulation wallet ─────────────────────────────────────────────────────

test('annulation wallet avant acceptation : remboursement EXACT du total, une seule fois ; aucun crédit partenaire/livreur', async () => {
  const t = world({ status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
  await t.c();
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.w('clients/c1'), 16000 + 4000);
  assert.equal(t.w('restaurants/r1'), 1000);
  assert.equal(t.w('livreurs/dA'), 900);
  assert.equal(t.keys('clients/c1/wallet_transactions/').length, 1);
  assert.equal(t.s.get(t.keys('clients/c1/wallet_transactions/')[0]).amount, 4000);
});

test('double annulation (rejeu, appels simultanés) : un seul remboursement', async () => {
  const t = world({ status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
  const results = await Promise.allSettled([t.c(), t.c(), t.c()]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  await assert.rejects(() => t.c(), (e) => e.code === 'failed-precondition');
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.keys('clients/c1/wallet_transactions/').length, 1);
});

test('annulation après acceptation : client remboursé du total ET commission rendue au livreur (une seule fois)', async () => {
  const t = world({ status: 'accepted' });
  await t.c();
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.w('livreurs/dA'), 900 + 100, 'commission d\'acceptation rendue');
  assert.equal(t.order().commissionStatus, 'refunded');
  assert.equal(t.w('restaurants/r1'), 1000);
});

test('refus du partenaire avant préparation : remboursement intégral du total (chemin cancelOrderTx, reason partner_refused)', async () => {
  const t = world({ status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null, sellerStatus: null });
  const orderRef = t.db.collection('orders').doc('o1');
  const info = await t.db.runTransaction(async (tx) => {
    const order = (await tx.get(orderRef)).data();
    return cancelOrderTx(tx, { db: t.db, admin, orderRef, order, uid: order.clientId, calculateCommission: async () => 100, reason: 'partner_refused' });
  });
  assert.equal(info.clientRefund, 4000);
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.order().cancelReason, 'partner_refused');
});

test('préparation commencée : pas d\'annulation/remboursement automatique ; décision administrative requise', async () => {
  for (const sellerStatus of ['preparing', 'ready']) {
    const t = world({ sellerType: 'boulangerie', type: 'boulangerie', sellerId: 'b1', sellerStatus, status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
    await assert.rejects(() => t.c(), (e) => e.code === 'failed-precondition' && /préparation/.test(e.message));
    assert.equal(t.order().status, 'pending');
    assert.equal(t.w('clients/c1'), 16000);
  }
  const t = world({ sellerStatus: 'preparing', status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
  const orderRef = t.db.collection('orders').doc('o1');
  const info = await t.db.runTransaction(async (tx) => {
    const order = (await tx.get(orderRef)).data();
    return cancelOrderTx(tx, { db: t.db, admin, orderRef, order, uid: 'c1', calculateCommission: async () => 100, reason: 'admin', adminDecision: { refundFee: true } });
  });
  assert.equal(info.clientRefund, 4000);
});

test('annulation après récupération : bloquée pour le client (inchangé), pas de remboursement', async () => {
  const t = world({ status: 'picked_up', pickedUpAt: 1 });
  await assert.rejects(() => t.c(), (e) => e.code === 'failed-precondition');
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.order().status, 'picked_up');
});

test('expiration sans livreur (autoExpireOrders) : remboursement du total v2, rien au partenaire', async () => {
  const t = world({ status: 'pending', driverId: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null });
  const orderRef = t.db.collection('orders').doc('o1');
  const r = await t.db.runTransaction((tx) => expireOrderTx(tx, { db: t.db, admin, orderRef, orderId: 'o1' }));
  assert.equal(r.expired, true);
  assert.equal(t.order().status, 'cancelled');
  const refund = t.keys('clients/c1/wallet_transactions/').map((k) => t.s.get(k));
  assert.deepEqual(refund.map((x) => [x.type, x.amount]), [['refund', 4000]]);
  assert.deepEqual(t.s.get('clients/c1').wallet, { __inc: 4000 }, 'incrément atomique du total exact');
  assert.equal(t.w('restaurants/r1'), 1000);
});

// ── Concurrence livraison / annulation ────────────────────────────────────

test('concurrence livraison/annulation : jamais les deux — soit payé au partenaire/livreur, soit client remboursé', async () => {
  for (let i = 0; i < 20; i++) {
    const t = world({ status: 'accepted' });
    const calls = i % 2 ? [t.d(), t.c()] : [t.c(), t.d()];
    await Promise.allSettled(calls);
    const status = t.order().status;
    const clientRefunded = t.w('clients/c1') === 20000;
    const partnerPaid = t.w('restaurants/r1') === 4500;
    assert.ok(status === 'delivered' || status === 'cancelled');
    if (status === 'delivered') {
      assert.equal(partnerPaid, true); assert.equal(clientRefunded, false); assert.equal(t.w('livreurs/dA'), 1400);
    } else {
      assert.equal(partnerPaid, false); assert.equal(clientRefunded, true); assert.equal(t.w('livreurs/dA'), 1000);
    }
    assert.equal(t.w('restaurants/r1') + t.w('clients/c1') + t.w('livreurs/dA') >= 0, true);
  }
});

// ── Échec et rejeu après interruption ─────────────────────────────────────

test('livraison interrompue (livreur introuvable → transaction annulée) puis rejouée : aucun effet partiel, un seul crédit', async () => {
  const t = world({}, { seed: { 'livreurs/dA': undefined } });
  t.s.delete('livreurs/dA');
  await assert.rejects(() => t.d());
  assert.equal(t.order().status, 'accepted');
  assert.equal(t.w('restaurants/r1'), 1000);
  assert.equal(t.keys('restaurants/r1/wallet_transactions/').length, 0);
  t.s.set('livreurs/dA', { wallet: 900, isOnDelivery: true, currentOrderId: 'o1' });
  await t.d();
  await assert.rejects(() => t.d());
  assert.equal(t.w('restaurants/r1'), 4500);
  assert.equal(t.w('livreurs/dA'), 1400);
  assert.equal(t.keys('restaurants/r1/wallet_transactions/').length, 1);
});

// ── Compatibilité historique ──────────────────────────────────────────────

const legacy = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, ...extra,
});

test('commande historique restaurant (sans amountsVersion) : livraison inchangée — partenaire crédité de budget, livreur non crédité ici', async () => {
  const t = world();
  t.s.set('orders/o1', legacy());
  await t.d();
  assert.equal(t.w('restaurants/r1'), 1700);
  assert.equal(t.w('livreurs/dA'), 900);
  assert.equal(t.keys('restaurants/r1/wallet_transactions/earning_').length, 0, 'journal historique inchangé (ajout post-transaction)');
});

test('commande historique : annulation et remboursement inchangés (budget + shoppingBudget)', async () => {
  const t = world();
  t.s.set('orders/o1', legacy({ status: 'pending', driverId: null, commissionStatus: null, shoppingBudget: 300 }));
  await t.c();
  assert.equal(t.w('clients/c1'), 16000 + 1000);
});

test('commande historique cash : comportement inchangé (merchantCashSettled sans cashRemittance)', async () => {
  const t = world();
  t.s.set('orders/o1', legacy({ paymentMethod: 'cash', isPaid: false }));
  await t.d();
  assert.equal(t.order().merchantCashSettled, false);
  assert.equal(t.order().cashRemittance, undefined);
  assert.equal(t.order().cashBreakdown, undefined);
});

test('payOrderFromWalletCF : commande historique non v2 non concernée par le nouveau refus', async () => {
  const t = world();
  t.s.set('orders/o1', { ...legacy({ isPaid: false, paymentMethod: 'wallet', type: 'pharmacie', sellerType: 'pharmacie' }) });
  t.s.set('clients/c1', { wallet: 5000 });
  const r = await t.pay({ auth: auth('c1'), data: { orderId: 'o1' } });
  assert.equal(r.success, true);
  assert.equal(t.w('clients/c1'), 4300);
});
