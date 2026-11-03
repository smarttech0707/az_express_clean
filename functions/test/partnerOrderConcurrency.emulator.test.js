'use strict';

// Commandes standard Restaurant / Boulangerie (Mission 7B-1) contre l'émulateur Firestore (jamais la production) :
// concurrence RÉELLE des transactions. Données fictives uniquement.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-partner \
//     "node --test functions/test/partnerOrderConcurrency.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

const PLACE = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 };
const GEO = { pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' };
const rReq = { sellerType: 'restaurant', sellerId: 'pr1', items: [{ itemId: 'm1', qty: 2 }], destination: DEST };

let admin; let db; let run;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
  const { buildCancelOrder, buildDeliverOrder, buildPayOrderFromWallet } = require('../orderActions');
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, isEnabled: () => true };
  run = {
    quote: buildQuotePartnerOrderCF(deps).run,
    order: buildCreatePartnerOrderFromQuoteCF({ ...deps, resolveGeography: async () => GEO }).run,
    cancel: buildCancelOrder({ ...deps, calculateCommission: async () => 100 }).run,
    deliver: buildDeliverOrder({ ...deps, onCall: (...a) => ({ run: a[a.length - 1] }) }).run,
    pay: buildPayOrderFromWallet(deps).run,
  };
  await db.doc('restaurants/pr1').set({ name: 'Chez Test', lat: PLACE.lat, lng: PLACE.lng, isOpen: true });
  await db.doc('restaurants/pr1/menu/m1').set({ name: 'Plat test', price: 1500, available: true });
});

const as = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const walletOf = async (uid) => (await db.doc(`clients/${uid}`).get()).data().wallet;
const settled = (calls) => Promise.allSettled(calls);
const pay = (quote, extra = {}) => ({ quoteId: quote.data.quoteId, paymentMethod: 'wallet', ...rReq, confirmedAmount: quote.data.total, deliveryAddress: 'Rue test', ...extra });

test('8 commandes simultanées sur UN devis → un seul débit du total, une seule commande ; un appel en échec se rejoue sans risque', options, async () => {
  await db.doc('clients/p1').set({ wallet: 10000 });
  const quote = await run.quote(as('p1', rReq));
  const total = quote.data.total;
  const results = await settled(Array.from({ length: 8 }, () => run.order(as('p1', pay(quote)))));
  const failed = results.filter((r) => r.status === 'rejected' || r.value?.success !== true);
  assert.ok(failed.length < 8, 'au moins un appel aboutit');
  for (let i = 0; i < failed.length; i++) {
    const retry = await run.order(as('p1', pay(quote)));
    assert.equal(retry.success, true);
    assert.equal(retry.data.replayed, true);
  }
  const ok = results.filter((r) => r.status === 'fulfilled' && r.value.success === true).map((r) => r.value);
  assert.equal(ok.filter((v) => v.data.replayed !== true).length, 1, 'un seul vrai traitement');
  assert.equal(new Set(ok.map((v) => v.data.orderId)).size, 1, 'une seule commande');
  assert.equal(await walletOf('p1'), 10000 - total);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p1').get()).size, 1);
  assert.equal((await db.collection('clients/p1/wallet_transactions').get()).size, 1);
});

test('plusieurs devis en parallèle, solde pour UNE commande → jamais de solde négatif', options, async () => {
  await db.doc('clients/p2').set({ wallet: 6000 });
  const quotes = await Promise.all(Array.from({ length: 6 }, () => run.quote(as('p2', rReq))));
  const total = quotes[0].data.total;
  await db.doc('clients/p2').update({ wallet: total + 100 });
  const results = await settled(quotes.map((q) => run.order(as('p2', pay(q)))));
  assert.equal(results.filter((r) => r.value?.success === true).length, 1);
  assert.equal(results.filter((r) => r.value?.code === 'SOLDE_INSUFFISANT').length, 5);
  assert.equal(await walletOf('p2'), 100);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p2').get()).size, 1);
});

test('prix du menu relevé après le devis, pendant des créations simultanées → aucune commande au prix périmé', options, async () => {
  await db.doc('clients/p3').set({ wallet: 50000 });
  await db.doc('restaurants/pr1/menu/m1').set({ name: 'Plat test', price: 1500, available: true });
  const quote = await run.quote(as('p3', rReq));
  await db.doc('restaurants/pr1/menu/m1').update({ price: 2500 });
  const results = await settled(Array.from({ length: 5 }, () => run.order(as('p3', pay(quote)))));
  assert.equal(results.filter((r) => r.value?.success === true).length, 0);
  assert.ok(results.every((r) => r.status === 'fulfilled' ? r.value.code === 'PRICE_CHANGED' : true));
  assert.equal(await walletOf('p3'), 50000);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p3').get()).size, 0);
  await db.doc('restaurants/pr1/menu/m1').update({ price: 1500 });
});

test('cash : aucun débit ni journal, même sous concurrence', options, async () => {
  await db.doc('clients/p4').set({ wallet: 700 });
  const quote = await run.quote(as('p4', rReq));
  const results = await settled(Array.from({ length: 4 }, () => run.order(as('p4', pay(quote, { paymentMethod: 'cash' })))));
  assert.ok(results.some((r) => r.value?.success === true));
  assert.equal(await walletOf('p4'), 700);
  assert.equal((await db.collection('clients/p4/wallet_transactions').get()).size, 0);
  assert.ok((await db.collection('orders').where('clientId', '==', 'p4').get()).size <= 1);
});

test('aucun crédit partenaire ni livreur à la création', options, async () => {
  const partner = await db.doc('restaurants/pr1').get();
  assert.equal(partner.data().wallet, undefined);
  assert.equal((await db.collection('restaurants/pr1/wallet_transactions').get()).size, 0);
});

// ── Mission 7B-2 : livraison / annulation / remboursement des commandes v2, transactions réellement concurrentes ──

// Commande créée par le VRAI chemin serveur, puis acceptée (commission tracée comme acceptOrderCF le fait).
async function paidOrder(uid, driverId, { method = 'wallet', commission = 100 } = {}) {
  await db.doc(`clients/${uid}`).set({ wallet: 10000 });
  await db.doc(`livreurs/${driverId}`).set({ wallet: 1000 - commission, isOnDelivery: false });
  const quote = await run.quote(as(uid, rReq));
  const created = await run.order(as(uid, pay(quote, { paymentMethod: method })));
  const orderId = created.data.orderId;
  await db.doc(`orders/${orderId}`).update({
    status: 'accepted', driverId, commissionStatus: 'charged', commissionPayerId: driverId, commissionAmount: commission,
  });
  await db.doc(`livreurs/${driverId}`).update({ isOnDelivery: true, currentOrderId: orderId });
  return { orderId, quote };
}
const partnerWallet = async () => (await db.doc('restaurants/pr1').get()).data().wallet || 0;
const orderOf = async (id) => (await db.doc(`orders/${id}`).get()).data();

test('livraison wallet : 6 appels simultanés → partenaire +produits UNE fois, livreur +frais UNE fois, commission non reprélevée', options, async () => {
  const { orderId, quote } = await paidOrder('q1', 'dq1');
  const before = await partnerWallet();
  const { productAmount, deliveryFee } = quote.data;
  await settled(Array.from({ length: 6 }, () => run.deliver(as('dq1', { orderId }))));
  // Une transaction abandonnée sous contention n'a aucun effet : le même appel peut être rejoué sans risque.
  if ((await orderOf(orderId)).status !== 'delivered') await run.deliver(as('dq1', { orderId }));
  assert.equal((await orderOf(orderId)).status, 'delivered');
  assert.equal(await partnerWallet(), before + productAmount);
  assert.equal((await db.doc('livreurs/dq1').get()).data().wallet, 900 + deliveryFee);
  assert.equal((await db.doc('clients/q1').get()).data().wallet, 10000 - quote.data.total);
  assert.equal((await db.collection('restaurants/pr1/wallet_transactions').where('orderId', '==', orderId).get()).size, 1);
  assert.equal((await db.collection('livreurs/dq1/wallet_transactions').where('orderId', '==', orderId).get()).size, 1);
  assert.equal((await orderOf(orderId)).commissionAmount, 100, "commission d'acceptation inchangée");
  // Rejeu tardif : refusé, aucun effet.
  await assert.rejects(() => run.deliver(as('dq1', { orderId })));
  assert.equal(await partnerWallet(), before + productAmount);
});

test('annulation wallet : 6 appels simultanés → remboursement EXACT du total, une seule fois, partenaire jamais crédité', options, async () => {
  await db.doc('clients/q2').set({ wallet: 10000 });
  const p0 = await partnerWallet();
  const quote = await run.quote(as('q2', rReq));
  const created = await run.order(as('q2', pay(quote)));
  const orderId = created.data.orderId;
  assert.equal((await db.doc('clients/q2').get()).data().wallet, 10000 - quote.data.total);
  await settled(Array.from({ length: 6 }, () => run.cancel(as('q2', { orderId }))));
  if ((await orderOf(orderId)).status !== 'cancelled') await run.cancel(as('q2', { orderId }));
  assert.equal((await orderOf(orderId)).status, 'cancelled');
  assert.equal((await db.doc('clients/q2').get()).data().wallet, 10000, 'remboursement exact du total');
  assert.equal((await db.collection('clients/q2/wallet_transactions').where('type', '==', 'refund').get()).size, 1);
  assert.equal(await partnerWallet(), p0);
});

test('livraison ET annulation simultanées (10 tours) : jamais les deux effets', options, async () => {
  for (let i = 0; i < 10; i++) {
    const uid = `qc${i}`; const driver = `dqc${i}`;
    const { orderId, quote } = await paidOrder(uid, driver);
    const p0 = await partnerWallet();
    await settled([run.deliver(as(driver, { orderId })), run.cancel(as(uid, { orderId }))]);
    const o = await orderOf(orderId);
    const client = (await db.doc(`clients/${uid}`).get()).data().wallet;
    const dWallet = (await db.doc(`livreurs/${driver}`).get()).data().wallet;
    const p1 = await partnerWallet();
    assert.ok(['delivered', 'cancelled'].includes(o.status), `tour ${i} : ${o.status}`);
    if (o.status === 'delivered') {
      assert.deepEqual([client, dWallet, p1 - p0], [10000 - quote.data.total, 900 + quote.data.deliveryFee, quote.data.productAmount]);
    } else {
      assert.deepEqual([client, dWallet, p1 - p0], [10000, 1000, 0], 'client remboursé du total, commission rendue, partenaire non crédité');
    }
  }
});

test('cash : livraison sans aucun mouvement de wallet ; remise au partenaire tracée ; annulation cash sans remboursement', options, async () => {
  const { orderId, quote } = await paidOrder('q4', 'dq4', { method: 'cash' });
  assert.equal((await db.doc('clients/q4').get()).data().wallet, 10000);
  const p0 = await partnerWallet();
  await settled(Array.from({ length: 4 }, () => run.deliver(as('dq4', { orderId }))));
  if ((await orderOf(orderId)).status !== 'delivered') await run.deliver(as('dq4', { orderId }));
  const o = await orderOf(orderId);
  assert.equal(o.status, 'delivered');
  assert.equal(await partnerWallet(), p0);
  assert.equal((await db.doc('livreurs/dq4').get()).data().wallet, 900);
  assert.equal((await db.doc('clients/q4').get()).data().wallet, 10000);
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.amountDue, o.cashRemittance.partnerId, o.cashRemittance.driverId],
    ['pending', quote.data.productAmount, 'pr1', 'dq4']);
  assert.equal(o.cashBreakdown.cashCollected, quote.data.total);
  assert.equal(o.merchantCashSettled, false);
  const c = await paidOrder('q5', 'dq5', { method: 'cash' });
  await run.cancel(as('q5', { orderId: c.orderId }));
  assert.equal((await db.doc('clients/q5').get()).data().wallet, 10000);
});

test('payOrderFromWalletCF ne peut pas payer une commande v2 cash', options, async () => {
  const cash = await paidOrder('q6', 'dq6', { method: 'cash' });
  await assert.rejects(() => run.pay(as('q6', { orderId: cash.orderId })));
  assert.equal((await db.doc('clients/q6').get()).data().wallet, 10000);
  assert.equal((await db.doc('livreurs/dq6').get()).data().wallet, 900);
});

test('solde insuffisant : aucune commande, aucun débit, devis rejouable après recharge', options, async () => {
  await db.doc('clients/q7').set({ wallet: 100 });
  const quote = await run.quote(as('q7', rReq));
  const r = await run.order(as('q7', pay(quote)));
  assert.equal(r.code, 'SOLDE_INSUFFISANT');
  assert.equal((await db.doc('clients/q7').get()).data().wallet, 100);
  assert.equal((await db.collection('orders').where('clientId', '==', 'q7').get()).size, 0);
  await db.doc('clients/q7').update({ wallet: 10000 });
  const ok = await run.order(as('q7', pay(quote)));
  assert.equal(ok.success, true);
  assert.equal((await db.doc('clients/q7').get()).data().wallet, 10000 - quote.data.total);
});

test('baisse de prix entre devis et création : nouveau montant à reconfirmer, aucun débit tant que non reconfirmé', options, async () => {
  await db.doc('clients/q8').set({ wallet: 10000 });
  await db.doc('restaurants/pr1/menu/m1').set({ name: 'Plat test', price: 1500, available: true });
  const quote = await run.quote(as('q8', rReq));
  await db.doc('restaurants/pr1/menu/m1').update({ price: 1000 });
  const stale = await run.order(as('q8', pay(quote)));
  assert.equal(stale.code, 'PRICE_CHANGED');
  assert.equal(stale.data.decreased, true);
  assert.equal((await db.doc('clients/q8').get()).data().wallet, 10000);
  const ok = await run.order(as('q8', pay(quote, { confirmedAmount: stale.data.currentAmount })));
  assert.equal(ok.success, true);
  assert.equal(ok.data.charged, stale.data.currentAmount);
  assert.equal((await db.doc('clients/q8').get()).data().wallet, 10000 - stale.data.currentAmount);
  await db.doc('restaurants/pr1/menu/m1').update({ price: 1500 });
});

test('commande historique (sans amountsVersion) : livraison et annulation inchangées', options, async () => {
  await db.doc('clients/q9').set({ wallet: 5000 });
  await db.doc('livreurs/dq9').set({ wallet: 900, isOnDelivery: true, currentOrderId: 'legacy-d' });
  await db.doc('orders/legacy-d').set({
    id: 'legacy-d', clientId: 'q9', driverId: 'dq9', status: 'accepted', type: 'restaurant', sellerType: 'restaurant', sellerId: 'pr1',
    paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dq9', commissionAmount: 100,
  });
  const p0 = await partnerWallet();
  await run.deliver(as('dq9', { orderId: 'legacy-d' }));
  assert.equal(await partnerWallet(), p0 + 700, 'historique : partenaire crédité de budget (comportement inchangé)');
  assert.equal((await db.doc('livreurs/dq9').get()).data().wallet, 900);
  await db.doc('orders/legacy-c').set({
    id: 'legacy-c', clientId: 'q9', status: 'pending', type: 'restaurant', sellerType: 'restaurant', sellerId: 'pr1',
    paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0,
  });
  await run.cancel(as('q9', { orderId: 'legacy-c' }));
  assert.equal((await db.doc('clients/q9').get()).data().wallet, 5700);
});

// ── Mission 7B-3A : litige administratif v2 (correctif A1) sur transactions réellement concurrentes ──

const adminReq = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
let dispute; let adminConfirm;
async function pickedUpOrder(uid, driverId) {
  const { orderId, quote } = await paidOrder(uid, driverId);
  await db.doc(`orders/${orderId}`).update({
    status: 'picked_up', pickedUpAt: Date.now(),
    cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: uid, requestedAtMs: Date.now() },
  });
  return { orderId, quote };
}
function adminTools() {
  if (dispute) return;
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildAdminOrderDispute } = require('../adminOrderDisputes');
  const { buildDeliverOrder } = require('../orderActions');
  const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');
  const { calculateCommission } = require('../dispatch');
  const base = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission };
  dispute = buildAdminOrderDispute({ ...base, onCall: (...a) => ({ run: a[a.length - 1] }), requireAdminPermission, requireSuperAdmin }).run;
  adminConfirm = buildDeliverOrder({ ...base, onCall: (...a) => ({ run: a[a.length - 1] }), adminConfirm: true, requireSuperAdmin }).run;
}
const exceptional = (orderId, n) => dispute(adminReq('root3a', {
  action: 'decide', orderId, decision: 'exceptionalCancel', requestId: `request-id-${String(n).padStart(8, '0')}`,
  justification: 'Litige constaté après appel du client', shoppingContext: 'not_purchased',
}));

test('A1 émulateur : annulation exceptionnelle v2 → remboursement intégral du total ; 6 appels simultanés = un seul remboursement', options, async () => {
  adminTools();
  await db.doc('admins/root3a').set({ role: 'super', isActive: true });
  const { orderId, quote } = await pickedUpOrder('r3a1', 'dr3a1');
  const p0 = await partnerWallet();
  const calls = [...Array.from({ length: 4 }, () => exceptional(orderId, 1)), exceptional(orderId, 2), run.cancel(as('r3a1', { orderId }))];
  await settled(calls);
  if ((await orderOf(orderId)).status !== 'cancelled') await exceptional(orderId, 1);
  const o = await orderOf(orderId);
  assert.equal(o.status, 'cancelled');
  assert.equal((await db.doc('clients/r3a1').get()).data().wallet, 10000, 'remboursement exact : total payé rendu, rien de plus');
  assert.equal((await db.doc('livreurs/dr3a1').get()).data().wallet, 1000, 'commission rendue à son payeur');
  assert.equal(o.deliveryFeeHold, undefined);
  assert.equal(o.disputeDecision.clientRefund, quote.data.total);
  assert.equal(await partnerWallet(), p0);
  assert.equal((await db.collection('clients/r3a1/wallet_transactions').where('type', '==', 'refund').get()).size, 1);
  assert.equal((await db.collection('livreurs/dr3a1/wallet_transactions').where('type', '==', 'refund').get()).size, 1);
});

test('A1 émulateur : confirmation administrative de livraison ET annulation exceptionnelle simultanées → un seul effet', options, async () => {
  adminTools();
  for (let i = 0; i < 6; i++) {
    const uid = `r3b${i}`; const driver = `dr3b${i}`;
    const { orderId, quote } = await pickedUpOrder(uid, driver);
    const p0 = await partnerWallet();
    await settled([
      adminConfirm(adminReq('root3a', { orderId, requestId: 'confirm-id-0000000001', justification: 'Livraison constatée après appel', evidence: 'client_confirmed' })),
      exceptional(orderId, 1),
    ]);
    const o = await orderOf(orderId);
    const client = (await db.doc(`clients/${uid}`).get()).data().wallet;
    const dWallet = (await db.doc(`livreurs/${driver}`).get()).data().wallet;
    const p1 = await partnerWallet();
    assert.ok(['delivered', 'cancelled'].includes(o.status), `tour ${i}`);
    if (o.status === 'delivered') {
      assert.deepEqual([client, dWallet, p1 - p0], [10000 - quote.data.total, 900 + quote.data.deliveryFee, quote.data.productAmount]);
    } else {
      assert.deepEqual([client, dWallet, p1 - p0], [10000, 1000, 0]);
    }
  }
});
