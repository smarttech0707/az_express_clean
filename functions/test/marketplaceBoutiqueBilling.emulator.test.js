'use strict';

// Concurrence réelle (émulateur Firestore, jamais la production) pour la
// facturation Marketplace / Boutique : le faux Firestore ne sérialise pas les
// transactions.
//   npx firebase emulators:exec --only firestore --project az-billing-test \
//     "node --test functions/test/marketplaceBoutiqueBilling.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let fns;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-billing-test' });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildDeliverOrder, buildCancelOrder } = require('../orderActions');
  const { calculateCommission } = require('../dispatch');
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const oc = (...a) => ({ run: a[a.length - 1] });
  const { buildAdminBilling } = require('../adminBilling');
  const { expireOrderTx, rateLimitCancelTx } = require('../orderRefunds');
  fns = {
    expire: (oid) => db.runTransaction((tx) => expireOrderTx(tx, { db, admin, orderRef: db.doc(`orders/${oid}`), orderId: oid })),
    rateLimit: (oid, order) => db.runTransaction((tx) => rateLimitCancelTx(tx, {
      db, admin, orderRef: db.doc(`orders/${oid}`), orderId: oid, order, clientId: 'cBill' })),
    adminBilling: buildAdminBilling({
      ...common, onCall: oc, calculateCommission,
      requireSuperAdmin: async ({ request }) => {
        if (request.auth.uid !== 'rootBill') throw new HttpsError('permission-denied', 'non');
      },
    }).run,
    deliver: buildDeliverOrder({ ...common, onCall: oc }).run,
    cancel: buildCancelOrder({ ...common, onCall: oc, calculateCommission }).run,
  };
});

const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const explicitOrder = (extra = {}) => ({
  clientId: 'cBill', driverId: 'dBill', status: 'picked_up', paymentMethod: 'wallet', isPaid: true,
  amountsVersion: 1, productAmount: 5000, deliveryFee: 500, totalAmount: 5500, budget: 500,
  itemsAmount: 5000, deliveryFeePaid: true, shoppingBudget: 0,
  sellerId: 'sBill', sellerType: 'seller', type: 'marketplace',
  commissionStatus: 'charged', commissionPayerId: 'dBill', commissionAmount: 100, ...extra,
});
const wallet = async (path) => (await db.doc(path).get()).data().wallet;

test('émulateur : trois livraisons simultanées ne créditent le livreur qu’une fois et jamais le vendeur', options, async () => {
  const oid = `deliver_${Date.now()}`;
  await db.doc(`orders/${oid}`).set(explicitOrder());
  await db.doc('livreurs/dBill').set({ wallet: 900, isOnDelivery: true, currentOrderId: oid });
  await db.doc('sellers/sBill').set({ wallet: 5000 });
  await db.doc('clients/cBill').set({ wallet: 4500 });
  const results = await Promise.allSettled([
    fns.deliver(req('dBill', { orderId: oid })),
    fns.deliver(req('dBill', { orderId: oid })),
    fns.deliver(req('dBill', { orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(await wallet('livreurs/dBill'), 900 + 500); // frais de livraison, une fois
  assert.equal(await wallet('sellers/sBill'), 5000); // aucun second paiement vendeur
  assert.equal(await wallet('clients/cBill'), 4500);
});

test('émulateur : annulation et livraison simultanées — une seule issue, aucun argent créé', options, async () => {
  const oid = `race_${Date.now()}`;
  await db.doc(`orders/${oid}`).set(explicitOrder());
  await db.doc('livreurs/dBill').set({ wallet: 900, isOnDelivery: true, currentOrderId: oid });
  await db.doc('sellers/sBill').set({ wallet: 5000 });
  await db.doc('clients/cBill').set({ wallet: 4500 });
  const total = async () => (await wallet('livreurs/dBill')) + (await wallet('sellers/sBill')) + (await wallet('clients/cBill'));
  const before = await total(); // soldes déjà nets de la commission (100) prélevée à l'acceptation
  const results = await Promise.allSettled([
    fns.deliver(req('dBill', { orderId: oid })),
    fns.cancel(req('cBill', { orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const status = (await db.doc(`orders/${oid}`).get()).data().status;
  if (status === 'delivered') {
    assert.equal(await total(), before + 500 - 0); // frais versés au livreur, sortis du séquestre client
    assert.equal(await wallet('clients/cBill'), 4500);
  } else {
    assert.equal(status, 'cancelled');
    // Commande récupérée : produits rendus une seule fois, frais retenus (examen
    // administratif), commission non rendue tant que la décision manque.
    assert.equal(await wallet('clients/cBill'), 4500 + 5000);
    assert.equal(await wallet('sellers/sBill'), 0);
    assert.equal(await wallet('livreurs/dBill'), 900);
    assert.equal((await db.doc(`orders/${oid}`).get()).data().deliveryFeeHold.amount, 500);
  }
});

const just = 'Décision administrative de test';
async function seedWorld(oid, extra = {}) {
  await db.doc(`orders/${oid}`).set(explicitOrder(extra));
  await db.doc('livreurs/dBill').set({ wallet: 900, isOnDelivery: true, currentOrderId: oid });
  await db.doc('sellers/sBill').set({ wallet: 5000 });
  await db.doc('clients/cBill').set({ wallet: 4500 });
}

test('émulateur : trois expirations simultanées (autoExpireOrders) ne remboursent qu’une fois', options, async () => {
  const oid = `expire_${Date.now()}`;
  await seedWorld(oid, { status: 'pending', driverId: null });
  const results = await Promise.all([fns.expire(oid), fns.expire(oid), fns.expire(oid)]);
  assert.equal(results.filter((r) => r.expired).length, 1);
  assert.equal(await wallet('clients/cBill'), 4500 + 5500);
  assert.equal(await wallet('sellers/sBill'), 0);
});

test('émulateur : annulation par limite de commandes simultanée à l’expiration — un seul remboursement', options, async () => {
  const oid = `rl_${Date.now()}`;
  await seedWorld(oid, { status: 'pending', driverId: null });
  const snapshot = (await db.doc(`orders/${oid}`).get()).data();
  await Promise.all([fns.rateLimit(oid, snapshot), fns.expire(oid), fns.rateLimit(oid, snapshot)]);
  assert.equal(await wallet('clients/cBill'), 10000);
  assert.equal(await wallet('sellers/sBill'), 0);
});

test('émulateur : décisions administratives simultanées sur les frais retenus — une seule appliquée', options, async () => {
  const oid = `hold_${Date.now()}`;
  await seedWorld(oid, { status: 'cancelled', deliveryFeeHold: {
    amount: 500, status: 'pending_admin_review', reason: 'cancelled_after_pickup', driverId: 'dBill', createdAtMs: 1 } });
  const call = (decision) => fns.adminBilling(req('rootBill', { action: 'resolveFeeHold', orderId: oid, decision, justification: just }));
  await Promise.allSettled([call('refundClient'), call('payDriver'), call('refundClient'), call('retain'), call('payDriver')]);
  const hold = (await db.doc(`orders/${oid}`).get()).data().deliveryFeeHold;
  assert.equal(hold.status, 'resolved');
  const client = await wallet('clients/cBill');
  const driver = await wallet('livreurs/dBill');
  // Exactement une décision : remboursement client OU rémunération livreur OU rétention.
  const outcomes = {
    refundClient: client === 5000 && driver === 1000,
    payDriver: client === 4500 && driver === 1400,
    retain: client === 4500 && driver === 1000,
  };
  assert.equal(outcomes[hold.decision], true, `décision ${hold.decision}: client=${client} driver=${driver}`);
});

test('émulateur : annulation client et clôture administrative simultanées — un seul remboursement', options, async () => {
  const oid = `close_${Date.now()}`;
  await seedWorld(oid, { status: 'accepted' });
  const results = await Promise.allSettled([
    fns.cancel(req('cBill', { orderId: oid })),
    fns.adminBilling(req('rootBill', { action: 'closeStuckDelivery', orderId: oid, justification: just })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(await wallet('clients/cBill'), 10000);
  assert.equal(await wallet('sellers/sBill'), 0);
  assert.equal(await wallet('livreurs/dBill'), 1000);
});
