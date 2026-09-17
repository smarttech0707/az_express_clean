'use strict';

// Run only against a disposable local emulator:
// FIRESTORE_EMULATOR_HOST=127.0.0.1:8185 node --test test-emulator/eventReservations.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildCreateEventReservation } = require('../eventReservations');

assert.match(process.env.FIRESTORE_EMULATOR_HOST || '', /^(127\.0\.0\.1|localhost):\d+$/,
  'A local Firestore emulator is required; production access is forbidden');
const app = admin.initializeApp({ projectId: 'demo-lot65' }, `lot65-${process.pid}`);
const db = app.firestore();
let sequence = 0;
test.after(() => app.delete());

async function fixture(paymentMethod = 'wallet', wallet = 2000, checkRateLimit = async () => {}) {
  const id = `test-${process.pid}-${++sequence}`;
  const uid = `client-${id}`;
  const offerId = `offer-${id}`;
  await Promise.all([
    db.doc(`clients/${uid}`).set({ wallet }),
    db.doc(`event_providers/${id}`).set({ status: 'approved', isSuspended: false }),
    db.doc(`event_offers/${offerId}`).set({
      providerId: id, unitPrice: 500, isActive: true, title: 'Prestation',
    }),
  ]);
  const run = buildCreateEventReservation({ db, admin, onCall: (fn) => fn, HttpsError, checkRateLimit });
  const request = {
    auth: { uid },
    data: {
      attemptId: 'reservation-attempt-0001',
      items: [{ offerId, quantity: 1 }],
      eventDateMs: 1800000000000, eventTime: '10:00',
      address: 'Abengourou', description: '', paymentMethod,
      delivery: false, installation: false, dismantling: false,
    },
  };
  const inspect = async () => {
    const [client, reservations, ledger, receipts] = await Promise.all([
      db.doc(`clients/${uid}`).get(),
      db.collection('event_reservations').where('clientId', '==', uid).get(),
      db.collection(`clients/${uid}/wallet_transactions`).get(),
      db.collection('event_reservation_attempts').where('clientId', '==', uid).get(),
    ]);
    return { wallet: client.data().wallet, reservations, ledger, receipts };
  };
  return { uid, offerId, run, request, inspect };
}

function barrier(count) {
  let arrived = 0;
  let release;
  const ready = new Promise((resolve) => { release = resolve; });
  return async () => {
    if (++arrived === count) release();
    await ready;
  };
}

for (const method of ['wallet', 'cash', 'future']) {
  test(`${method}: simultaneous calls with the same key commit one reservation`, { timeout: 30000 }, async () => {
    const f = await fixture(method, 2000, barrier(2));
    const results = await Promise.all([f.run(f.request), f.run(f.request)]);
    assert.deepEqual(results[0], results[1]);
    const state = await f.inspect();
    assert.equal(state.reservations.size, 1);
    assert.equal(state.receipts.size, 1);
    assert.equal(state.wallet, method === 'wallet' ? 1500 : 2000);
    assert.equal(state.ledger.size, method === 'wallet' ? 1 : 0);
    assert.equal(state.reservations.docs[0].data().isPaid, method === 'wallet');
    if (method === 'wallet') {
      assert.equal(state.ledger.docs[0].id, results[0].reservationId);
      assert.equal(state.ledger.docs[0].data().amount, -500);
    }
  });

  test(`${method}: replay after success returns the original result even if the offer disappears`, async () => {
    const f = await fixture(method);
    const first = await f.run(f.request);
    await db.doc(`event_offers/${f.offerId}`).delete();
    assert.deepEqual(await f.run(f.request), first);
    const state = await f.inspect();
    assert.equal(state.reservations.size, 1);
    assert.equal(state.wallet, method === 'wallet' ? 1500 : 2000);
  });

  test(`${method}: lost response after commit followed by retry does not charge or reserve twice`, async () => {
    const f = await fixture(method);
    let committed;
    await assert.rejects(async () => {
      committed = await f.run(f.request);
      // The transport loses the response, not the committed transaction.
      throw new Error('deadline-exceeded');
    }, /deadline-exceeded/);
    assert.deepEqual(await f.run(f.request), committed);
    const state = await f.inspect();
    assert.equal(state.reservations.size, 1);
    assert.equal(state.ledger.size, method === 'wallet' ? 1 : 0);
    assert.equal(state.wallet, method === 'wallet' ? 1500 : 2000);
  });
}

test('same key with a different basket is rejected after success', async () => {
  const f = await fixture();
  await f.run(f.request);
  await assert.rejects(() => f.run({ ...f.request, data: {
    ...f.request.data, items: [{ offerId: f.offerId, quantity: 2 }],
  } }), (error) => error.code === 'already-exists');
  const state = await f.inspect();
  assert.equal(state.reservations.size, 1);
  assert.equal(state.wallet, 1500);
});

test('different baskets competing for the same key: exactly one succeeds', { timeout: 30000 }, async () => {
  const f = await fixture('wallet', 2000, barrier(2));
  const results = await Promise.allSettled([
    f.run(f.request),
    f.run({ ...f.request, data: { ...f.request.data, items: [{ offerId: f.offerId, quantity: 2 }] } }),
  ]);
  const successes = results.filter((r) => r.status === 'fulfilled');
  const failures = results.filter((r) => r.status === 'rejected');
  assert.equal(successes.length, 1);
  assert.equal(failures.length, 1);
  assert.equal(failures[0].reason.code, 'already-exists');
  const state = await f.inspect();
  assert.equal(state.reservations.size, 1);
  assert.equal(state.ledger.size, 1);
  assert.equal(state.wallet, 2000 - successes[0].value.totalAmount);
});

test('insufficient balance rolls back everything and the same attempt can succeed after top-up', async () => {
  const f = await fixture('wallet', 100);
  await assert.rejects(() => f.run(f.request),
    (error) => error.code === 'failed-precondition' && error.message === 'SOLDE_INSUFFISANT:100:500');
  const failed = await f.inspect();
  assert.equal(failed.wallet, 100);
  assert.equal(failed.reservations.size, 0);
  assert.equal(failed.ledger.size, 0);
  assert.equal(failed.receipts.size, 0);
  await db.doc(`clients/${f.uid}`).update({ wallet: 500 });
  const result = await f.run(f.request);
  assert.deepEqual(await f.run(f.request), result);
  const success = await f.inspect();
  assert.equal(success.wallet, 0);
  assert.equal(success.reservations.size, 1);
  assert.equal(success.ledger.size, 1);
});

test('two distinct attempts cannot concurrently overdraw the same wallet', { timeout: 30000 }, async () => {
  const f = await fixture('wallet', 500, barrier(2));
  const results = await Promise.allSettled([
    f.run(f.request),
    f.run({ ...f.request, data: { ...f.request.data, attemptId: 'reservation-attempt-0002' } }),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results.filter((r) => r.status === 'rejected').length, 1);
  const state = await f.inspect();
  assert.equal(state.wallet, 0);
  assert.equal(state.reservations.size, 1);
  assert.equal(state.ledger.size, 1);
});

test('keys are scoped to the authenticated client', async () => {
  const first = await fixture('cash');
  const second = await fixture('cash');
  const a = await first.run(first.request);
  const b = await second.run({ ...second.request, data: first.request.data });
  assert.notEqual(a.reservationId, b.reservationId);
});

test('changing the payment method or delivery details cannot reuse a committed key', async () => {
  const f = await fixture('cash');
  await f.run(f.request);
  for (const change of [{ paymentMethod: 'wallet' }, { delivery: true }, { address: 'Autre lieu' }]) {
    await assert.rejects(() => f.run({ ...f.request, data: { ...f.request.data, ...change } }),
      (error) => error.code === 'already-exists');
  }
  const state = await f.inspect();
  assert.equal(state.wallet, 2000);
  assert.equal(state.reservations.size, 1);
});
