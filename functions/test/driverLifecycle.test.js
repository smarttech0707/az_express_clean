'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb, admin } = require('./lifecycleFake');
const { cancelOrderTx } = require('../orderActions');
const { settleTerminalOrder, diagnoseDriver, clearAcceptedOffers, runLifecycleTransaction } = require('../driverLifecycle');

function fixture(extra = {}) {
  return fakeDb({
    'livreurs/d1': { wallet: 400, isOnDelivery: true, isOnline: true, pendingOrderId: 'o1' },
    'orders/o1': { status: 'accepted', driverId: 'd1', clientId: 'c1', budget: 500, paymentMethod: 'cash' },
    ...extra,
  });
}
function cancel(db) {
  return db.runTransaction(async tx => {
    const orderRef = db.collection('orders').doc('o1');
    const snap = await tx.get(orderRef);
    return cancelOrderTx(tx, { db, admin, orderRef, order: snap.data(), uid: 'c1',
      calculateCommission: async () => 100, reason: 'test' });
  });
}

test('closed transaction retry is bounded and never swallows unrelated errors', async () => {
  let attempts = 0;
  const closed = Object.assign(new Error('closed'), { code: 3, details: 'Transaction is invalid or closed.' });
  await assert.rejects(runLifecycleTransaction({ runTransaction: async () => {
    attempts++; throw closed;
  } }, () => {}), error => error === closed);
  assert.equal(attempts, 3);
  attempts = 0;
  await assert.rejects(runLifecycleTransaction({ runTransaction: async () => {
    attempts++; throw Object.assign(new Error('invalid query'), { code: 3, details: 'Invalid query' });
  } }, () => {}), /invalid query/);
  assert.equal(attempts, 1);
});

test('closed transaction reruns entire callback on a new transaction', async () => {
  let attempts = 0;
  const result = await runLifecycleTransaction({ runTransaction: async callback => {
    attempts++;
    if (attempts === 1) throw { code: 3, details: 'Transaction is invalid or closed.' };
    return callback({ fresh: true });
  } }, tx => tx.fresh);
  assert.equal(result, true);
  assert.equal(attempts, 2);
});

test('accepted cancellation releases driver and refunds once; repeat has no financial effect', async () => {
  const { db, store } = fixture();
  await cancel(db);
  assert.equal(store.get('orders/o1').status, 'cancelled');
  assert.deepEqual(store.get('livreurs/d1'), { wallet: 500, isOnDelivery: false, isOnline: true });
  await assert.rejects(cancel(db), /ORDER_NOT_CANCELLABLE/);
  assert.equal(store.get('livreurs/d1').wallet, 500);
});

test('cancellation preserves another active mission and its newer offer', async () => {
  const { db, store } = fixture({
    'orders/o2': { status: 'picked_up', driverId: 'd1' },
    'livreurs/d1': { wallet: 400, isOnDelivery: true, pendingOrderId: 'o2', currentOrderId: 'o2' },
  });
  await cancel(db);
  assert.equal(store.get('livreurs/d1').isOnDelivery, true);
  assert.equal(store.get('livreurs/d1').pendingOrderId, 'o2');
  assert.equal(store.get('livreurs/d1').currentOrderId, 'o2');
});

test('terminal event replay preserves newer offer and never changes money', async () => {
  const { db, store } = fixture({
    'orders/o1': { status: 'delivered', driverId: 'd1' },
    'orders/o2': { status: 'broadcast' },
    'livreurs/d1': { wallet: 400, isOnDelivery: true, pendingOrderId: 'o2' },
  });
  await settleTerminalOrder(db, admin, 'o1');
  await settleTerminalOrder(db, admin, 'o1');
  assert.deepEqual(store.get('livreurs/d1'), { wallet: 400, isOnDelivery: false, pendingOrderId: 'o2' });
});

test('stale terminal event cannot release a now accepted order', async () => {
  const { db, store, writes } = fixture();
  await settleTerminalOrder(db, admin, 'o1');
  assert.equal(writes(), 0);
  assert.equal(store.get('livreurs/d1').isOnDelivery, true);
});

test('diagnostic of deleted mission refuses correction and performs zero writes', async () => {
  const { db, store, writes } = fixture({
    'livreurs/d1': { wallet: 400, isOnDelivery: true, currentOrderId: 'deleted', isSuspended: true },
    'orders/o1': { status: 'cancelled', driverId: 'd1' },
  });
  const before = structuredClone([...store]);
  const result = await diagnoseDriver(db, 'd1');
  assert.equal(result.references.currentOrderId, 'missing');
  assert.equal(result.correctionAllowed, false);
  assert.equal(result.decision, 'ambiguous_references_or_history');
  assert.equal(writes(), 0);
  assert.deepEqual([...store], before);
});

test('no history and occupied flag remains a candidate, never an automatic release', async () => {
  const { db, store } = fakeDb({ 'livreurs/d1': { wallet: 400, isOnDelivery: true } });
  assert.equal((await diagnoseDriver(db, 'd1')).decision, 'stale_candidate_requires_manual_evidence');
  assert.equal(store.get('livreurs/d1').isOnDelivery, true);
});

test('unknown status refuses automatic release', async () => {
  const { db, store } = fixture({ 'orders/o2': { status: 'legacy_active', driverId: 'd1' } });
  await cancel(db);
  assert.equal(store.get('livreurs/d1').isOnDelivery, true);
});

test('accepted offer cleanup only clears matching references, including winner', async () => {
  const { db, store } = fixture({ 'livreurs/d2': { pendingOrderId: 'new', wallet: 800 } });
  await clearAcceptedOffers(db, admin, 'o1', { notifiedDriverIds: ['d1', 'd2'] });
  assert.equal(store.get('livreurs/d1').pendingOrderId, undefined);
  assert.equal(store.get('livreurs/d2').pendingOrderId, 'new');
  assert.equal(store.get('livreurs/d1').wallet, 400);
});

test('serialized acceptance after cancellation keeps the new mission occupied', async () => {
  const { db, store } = fixture({ 'orders/o2': { status: 'assigned', driverId: 'd1' } });
  const accept = () => db.runTransaction(async tx => {
    const ref = db.collection('livreurs').doc('d1');
    const driver = await tx.get(ref);
    if (driver.data().isOnDelivery) throw Error('occupied');
    tx.update(ref, { isOnDelivery: true });
    tx.update(db.collection('orders').doc('o2'), { status: 'accepted' });
  });
  await Promise.all([cancel(db), accept()]);
  await settleTerminalOrder(db, admin, 'o1');
  assert.equal(store.get('livreurs/d1').isOnDelivery, true);
  assert.equal(store.get('orders/o2').status, 'accepted');
});
