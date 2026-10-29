'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertFails } = require('@firebase/rules-unit-testing');
const admin = require('../functions/node_modules/firebase-admin');
const { settleTerminalOrder, diagnoseDriver, runLifecycleTransaction } = require('../functions/driverLifecycle');
const { cancelOrderTx } = require('../functions/orderActions');
const { buildDeliverOrder } = require('../functions/orderActions');
const functionsRequire = require('node:module').createRequire(path.join(__dirname, '../functions/package.json'));
const { onCall, HttpsError } = functionsRequire('firebase-functions/v2/https');

// This suite must NEVER reach production, even when credentials are available.
if (!/^127\.0\.0\.1:\d+$/.test(process.env.FIRESTORE_EMULATOR_HOST || '')) {
  throw Error('Local Firestore emulator required');
}
async function completeConcurrent(operations) {
  const results = await Promise.allSettled(operations);
  const failure = results.find(result => result.status === 'rejected');
  if (failure) throw failure.reason;
}
let env, app, db;
test.before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-az-phase1', firestore: {
    rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
  } });
  app = admin.initializeApp({ projectId: 'demo-az-phase1' }, 'phase1-test');
  db = app.firestore();
});
test.after(async () => { await env?.cleanup(); await app?.delete(); });
test.beforeEach(async () => env.clearFirestore());

test('purge denies every order status even to admin and preserves financial references', async () => {
  await db.doc('admins/a').set({ role: 'super', isActive: true });
  await db.doc('livreurs/d').set({ wallet: 400, isOnDelivery: true });
  await db.doc('livreurs/d/wallet_transactions/t').set({ orderId: 'accepted', amount: 100 });
  for (const status of ['pending', 'assigned', 'broadcast', 'accepted', 'picked_up', 'delivered', 'cancelled', 'unknown']) {
    await db.doc(`orders/${status}`).set({ status, driverId: 'd', budget: 500 });
    await assertFails(env.authenticatedContext('a').firestore().doc(`orders/${status}`).delete());
    assert.equal((await db.doc(`orders/${status}`).get()).exists, true);
  }
  assert.equal((await db.doc('livreurs/d').get()).data().wallet, 400);
  assert.equal((await db.doc('livreurs/d/wallet_transactions/t').get()).exists, true);
});

test('real transaction: cancellation refunds once and preserves newer pending reference', async () => {
  await db.doc('livreurs/d').set({ wallet: 400, isOnDelivery: true, pendingOrderId: 'new' });
  await db.doc('orders/new').set({ status: 'broadcast' });
  await db.doc('orders/old').set({ status: 'accepted', driverId: 'd', paymentMethod: 'cash', budget: 500 });
  const cancel = () => runLifecycleTransaction(db, async tx => {
    const ref = db.doc('orders/old');
    const snap = await tx.get(ref);
    return cancelOrderTx(tx, { db, admin, orderRef: ref, order: snap.data(), uid: 'c',
      calculateCommission: async () => 100, reason: 'test' });
  });
  const results = await Promise.allSettled([cancel(), cancel()]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.deepEqual((await db.doc('livreurs/d').get()).data(), {
    wallet: 500, isOnDelivery: false, pendingOrderId: 'new',
  });
});

test('real transaction: terminal cleanup racing acceptance never releases new mission', async () => {
  await db.doc('livreurs/d').set({ wallet: 400, isOnDelivery: false });
  await db.doc('orders/old').set({ status: 'cancelled', driverId: 'd' });
  await db.doc('orders/new').set({ status: 'assigned', clientId: 'c', sellerId: '', isPaid: false, driverId: 'd' });
  const client = env.authenticatedContext('d').firestore();
  const accept = () => client.runTransaction(async tx => {
    const driver = await tx.get(client.doc('livreurs/d'));
    const order = await tx.get(client.doc('orders/new'));
    assert.equal(driver.data().isOnDelivery, false);
    assert.equal(order.data().status, 'assigned');
    tx.update(client.doc('livreurs/d'), { isOnDelivery: true, wallet: driver.data().wallet - 100 });
    tx.update(client.doc('orders/new'), { status: 'accepted' });
  });
  await completeConcurrent([settleTerminalOrder(db, admin, 'old'), accept()]);
  await settleTerminalOrder(db, admin, 'old');
  assert.equal((await db.doc('livreurs/d').get()).data().isOnDelivery, true);
  assert.equal((await db.doc('livreurs/d').get()).data().wallet, 300);
});

test('diagnostic on emulator never mutates an orphaned driver', async () => {
  const before = { wallet: 400, isOnDelivery: true, currentOrderId: 'deleted', isOnline: true };
  await db.doc('livreurs/d').set(before);
  const result = await diagnoseDriver(db, 'd');
  assert.equal(result.correctionAllowed, false);
  assert.equal(result.references.currentOrderId, 'missing');
  assert.deepEqual((await db.doc('livreurs/d').get()).data(), before);
});

test('real transaction: acceptance racing cancellation has balanced commission and releases driver', async () => {
  await db.doc('livreurs/d').set({ wallet: 400, isOnDelivery: false });
  await db.doc('orders/o').set({ status: 'assigned', clientId: 'c', sellerId: '', isPaid: false, driverId: 'd', paymentMethod: 'cash', budget: 500 });
  // Use the actual client transaction model used by Flutter (optimistic),
  // against the server cancellation transaction (pessimistic).
  const client = env.authenticatedContext('d').firestore();
  const accept = () => client.runTransaction(async tx => {
    const order = await tx.get(client.doc('orders/o'));
    const driver = await tx.get(client.doc('livreurs/d'));
    if (order.data().status !== 'assigned' || driver.data().isOnDelivery) return;
    tx.update(client.doc('orders/o'), { status: 'accepted' });
    tx.update(client.doc('livreurs/d'), { isOnDelivery: true, wallet: driver.data().wallet - 100 });
  });
  const cancel = () => runLifecycleTransaction(db, async tx => {
    const ref = db.doc('orders/o');
    const order = await tx.get(ref);
    await cancelOrderTx(tx, { db, admin, orderRef: ref, order: order.data(), uid: 'c',
      calculateCommission: async () => 100, reason: 'test' });
  });
  await completeConcurrent([accept(), cancel()]);
  assert.equal((await db.doc('orders/o').get()).data().status, 'cancelled');
  assert.deepEqual((await db.doc('livreurs/d').get()).data(), { wallet: 400, isOnDelivery: false });
});

test('delivery preserves another active mission and replay cannot credit twice', async () => {
  await db.doc('livreurs/d').set({ wallet: 400, isOnDelivery: true, pendingOrderId: 'other' });
  await db.doc('orders/other').set({ status: 'picked_up', driverId: 'd' });
  await db.doc('orders/o').set({ status: 'picked_up', driverId: 'd', budget: 500,
    paymentMethod: 'wallet', isPaid: true });
  const deliver = buildDeliverOrder({ db, admin, onCall, HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {} });
  const request = { auth: { uid: 'd' }, data: { orderId: 'o' } };
  await deliver.run(request);
  await assert.rejects(deliver.run(request));
  const driver = (await db.doc('livreurs/d').get()).data();
  assert.equal(driver.wallet, 900);
  assert.equal(driver.isOnDelivery, true);
  assert.equal(driver.pendingOrderId, 'other');
  assert.equal((await db.doc('orders/o').get()).data().status, 'delivered');
});
