'use strict';

// Mission 7D-5-F — concurrence RÉELLE (transactions Firestore) de deliverOrderCF / declareCashNonPayment /
// reviewCashNonPayment / resolveCashRemittance. Exige l'émulateur Firestore (FIRESTORE_EMULATOR_HOST) : ignoré sinon,
// pour que `npm test` reste exécutable sans Java. Lancement :
//   firebase emulators:exec --only firestore --project demo-cash-7d5 "node --test test/cashPayment.emulator.test.js"

const test = require('node:test');
const assert = require('node:assert/strict');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const skip = HOST ? false : 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)';

const { HttpsError } = require('firebase-functions/v2/https');
const { buildPartnerOrderAction } = require('../partnerOrderActions');
const { buildDeliverOrder } = require('../orderActions');
const { calculateCommission } = require('../dispatch');
const { requireSuperAdmin } = require('../adminGuards');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const REQ_A = 'review-request-0001';
const REQ_B = 'review-request-0002';
const RES_A = 'resolve-request-0001';
const JUST = 'Appel du client et du livreur, versions comparées';
const REASON = 'Le client est parti sans payer à la livraison';

let admin; let db; let act; let deliver; let audits;
if (!skip) {
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'demo-cash-7d5' });
  db = admin.firestore();
  audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission };
  act = buildPartnerOrderAction({ ...common, onCall: oc, requireSuperAdmin, isEnabled: () => true }).run;
  deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
}

const baseOrder = (extra = {}) => ({
  clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'cash', isPaid: false, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000,
  budget: 500, shoppingBudget: 0, sellerStatus: 'ready', commissionStatus: 'charged', commissionPayerId: 'dA',
  commissionAmount: 100, ...extra,
});

async function wipe() {
  for (const col of ['orders', 'clients', 'restaurants', 'livreurs', 'admins', 'reconciliation_flags', 'wallet_transactions']) {
    const snap = await db.collection(col).get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
  }
  audits.length = 0;
}

async function seed(order) {
  await wipe();
  await Promise.all([
    db.doc('orders/o1').set(order),
    db.doc('clients/c1').set({ wallet: 16000, name: 'Aya', fakeOrderCount: 0, cashOnDeliveryEnabled: true }),
    db.doc('restaurants/r1').set({ name: 'Chez Test', wallet: 1000, isActive: true }),
    db.doc('livreurs/dA').set({ wallet: 900, isOnDelivery: true, currentOrderId: 'o1', isOnline: true }),
    db.doc('admins/root').set({ role: 'super', isActive: true }),
    db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] }),
  ]);
}

const call = (action, uid, extra = {}) => act({ auth: authOf(uid), data: { orderId: 'o1', action, ...extra } });
const declare = (uid = 'dA') => call('declareCashNonPayment', uid, { reason: REASON });
const review = (over = {}) => call('reviewCashNonPayment', 'root', { requestId: REQ_A, decision: 'confirm_unpaid', justification: JUST, ...over });
const resolve = (over = {}) => call('resolveCashRemittance', 'root', { requestId: RES_A, justification: JUST, finalAmount: 1000, ...over });
const deliverAs = (data = {}) => deliver({ auth: authOf('dA'), data: { orderId: 'o1', ...data } });
const get = async (p) => (await db.doc(p).get()).data();
const wallets = async () => [(await get('clients/c1')).wallet, (await get('livreurs/dA')).wallet, (await get('restaurants/r1')).wallet];
const walletTxCount = async () => (await db.collection('wallet_transactions').get()).size;
const settle = (ps) => Promise.all(ps.map((p) => p.catch((e) => ({ thrown: e }))));
const codes = (rs) => rs.map((r) => (r.success ? (r.data.replay ? 'replay' : 'ok') : r.error)).sort();

// Livre l'ordre (sans déclaration de paiement → inconnu) puis renvoie l'état de départ des scénarios suivants.
async function deliveredUnknown() {
  await seed(baseOrder());
  const r = await deliverAs({});
  assert.equal(r.success, true, JSON.stringify(r));
  assert.equal((await get('orders/o1')).cashPayment.status, 'unknown');
}

test('émulateur : livraison puis deux signalements simultanés → un seul incident', { skip }, async () => {
  await deliveredUnknown();
  const before = await wallets();
  const rs = await settle([declare(), declare()]);
  assert.deepEqual(codes(rs), ['ok', 'replay']);
  const o = await get('orders/o1');
  assert.equal(o.cashPayment.status, 'non_payment_declared');
  assert.equal(o.cashPayment.verification, 'pending_review');
  assert.equal(o.cashPayment.history.filter((h) => h.event === 'non_payment_declared').length, 1);
  assert.equal(audits.filter((a) => a.action === 'partner_order_declareCashNonPayment' && !a.status).length, 1);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.deepEqual(await wallets(), before);
  assert.equal(await walletTxCount(), 0);
  assert.equal((await get('reconciliation_flags/o1_cash_payment_review')).status, 'open');
});

test('émulateur : deux décisions administratives simultanées, requestId différents → une seule retenue', { skip }, async () => {
  await deliveredUnknown(); await declare(); audits.length = 0;
  const rs = await settle([review({ requestId: REQ_A, decision: 'confirm_unpaid' }), review({ requestId: REQ_B, decision: 'refute' })]);
  assert.deepEqual(codes(rs), ['PAYMENT_ALREADY_REVIEWED', 'ok']);
  const o = await get('orders/o1');
  const winner = rs.find((r) => r.success);
  assert.equal(o.cashPayment.review.requestId, winner.data.payment.review.requestId);
  assert.equal(o.cashPayment.history.filter((h) => h.event.startsWith('review_')).length, 1);
  assert.equal(audits.filter((a) => a.action === 'partner_order_reviewCashNonPayment' && !a.status).length, 1);
  assert.equal((await get('reconciliation_flags/o1_cash_payment_review')).requestId, o.cashPayment.review.requestId);
});

test('émulateur : même requestId simultané → une décision, un rejeu', { skip }, async () => {
  await deliveredUnknown(); await declare(); audits.length = 0;
  const rs = await settle([review(), review()]);
  assert.deepEqual(codes(rs), ['ok', 'replay']);
  assert.equal((await get('orders/o1')).cashPayment.history.filter((h) => h.event.startsWith('review_')).length, 1);
  assert.equal(audits.filter((a) => a.action === 'partner_order_reviewCashNonPayment' && !a.status).length, 1);
});

test('émulateur : signalement et résolution simultanés → dû, reliquat et audits conservés, aucun wallet', { skip }, async () => {
  await deliveredUnknown();
  const before = await wallets();
  audits.length = 0;
  const rs = await settle([declare(), resolve()]);
  // Deux ordres valides : déclaration puis résolution (les deux passent), ou résolution puis déclaration refusée (reversement clos).
  assert.equal(rs[1].success, true, JSON.stringify(rs));
  assert.ok(rs[0].success === true || rs[0].error === 'CASH_ALREADY_FINAL', JSON.stringify(rs[0]));
  const o = await get('orders/o1');
  assert.equal(o.cashPayment.status, rs[0].success ? 'non_payment_declared' : 'unknown');
  assert.equal(o.cashRemittance.status, 'resolved');
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal(o.cashRemittance.resolution.finalAmount, 1000);
  assert.equal(o.cashRemittance.outstanding, 2500);
  const shortfall = await get('reconciliation_flags/o1_cash_shortfall');
  assert.equal(shortfall.amount, 2500);
  assert.equal(audits.filter((a) => !a.status).length, rs[0].success ? 2 : 1);
  assert.deepEqual(await wallets(), before);
  assert.equal(await walletTxCount(), 0);
});

test('émulateur : rejeu de la déclaration après examen puis résolution → rejeu, décision intacte', { skip }, async () => {
  await deliveredUnknown(); await declare(); await review(); await resolve();
  const frozen = await get('orders/o1');
  const again = await declare();
  assert.equal(again.success, true);
  assert.equal(again.data.replay, true);
  const refuted = await call('reviewCashNonPayment', 'root', { requestId: REQ_B, decision: 'refute', justification: JUST });
  assert.equal(refuted.error, 'PAYMENT_ALREADY_REVIEWED');
  const after = await get('orders/o1');
  assert.deepEqual(after.cashPayment, frozen.cashPayment);
  assert.deepEqual(after.cashRemittance, frozen.cashRemittance);
  assert.equal((await resolve()).data.replay, true);
});

test('émulateur : déclaré payé → signalement contradictoire refusé ; autre livreur et non-livrée refusés', { skip }, async () => {
  await seed(baseOrder());
  assert.equal((await deliverAs({ markCashPaid: true })).success, true);
  assert.equal((await declare()).error, 'PAYMENT_ALREADY_DECLARED_PAID');
  assert.equal((await declare('dB')).error, 'ORDER_NOT_FOUND');
  assert.equal((await get('orders/o1')).cashPayment.status, 'confirmed');
  await seed(baseOrder());
  assert.equal((await declare()).error, 'CASH_ORDER_NOT_DELIVERED');
});

test('émulateur : livraison et signalement simultanés → au plus un état cohérent, aucun wallet touché par le signalement', { skip }, async () => {
  await seed(baseOrder());
  const rs = await settle([deliverAs({}), declare()]);
  assert.equal(rs[0].success, true, JSON.stringify(rs[0]));
  const second = rs[1];
  assert.ok(second.success === true || second.error === 'CASH_ORDER_NOT_DELIVERED', JSON.stringify(second));
  const o = await get('orders/o1');
  assert.equal(o.status, 'delivered');
  assert.ok(['unknown', 'non_payment_declared'].includes(o.cashPayment.status));
  assert.equal(o.cashPayment.status === 'non_payment_declared', second.success === true);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal((await get('clients/c1')).wallet, 16000);
  assert.equal((await get('restaurants/r1')).wallet, 1000);
});
