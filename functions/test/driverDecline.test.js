'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildDeclineLegacyOrder } = require('../driverDecline');
const { DispatchError } = require('../dispatch');

const admin = {
  firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion } },
};

function setup(order = {}, dispatchError) {
  const db = fakeDb({
    'orders/o1': { clientId: 'c1', driverId: 'dA', status: 'assigned', budget: 1500, latitude: 6.7, longitude: -3.4, ...order },
    'livreurs/dA': { wallet: 500, isOnline: true, isOnDelivery: true },
  });
  const dispatches = [];
  const run = buildDeclineLegacyOrder({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
    dispatchOrder: async (_d, _a, args) => { dispatches.push(args); if (dispatchError) throw dispatchError; return { dispatched: true }; },
    DispatchError,
  }).run;
  const req = (data, uid = 'dA') => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  return { db, run, req, dispatches };
}

test('refus d’une mission assignée : remise en file, aucun mouvement de wallet', async () => {
  const h = setup();
  const r = await h.run(h.req({ orderId: 'o1' }));
  assert.deepEqual([r.success, r.replay, r.recoveryPending], [true, false, false]);
  const o = h.db.store.get('orders/o1');
  assert.equal(o.status, 'pending');
  assert.equal(o.driverId, undefined);
  assert.ok(o.excludedDriverIds.includes('dA'));
  assert.equal(o.transferCount, undefined);
  assert.equal(h.db.store.get('livreurs/dA').wallet, 500);
  assert.equal(h.dispatches.length, 1);
  assert.ok(h.dispatches[0].excludedDriverIds.includes('dA'));
});

test('rejeu : deuxième refus sans effet ni redispatch', async () => {
  const h = setup();
  await h.run(h.req({ orderId: 'o1' }));
  const r = await h.run(h.req({ orderId: 'o1' }));
  assert.equal(r.replay, true);
  assert.equal(h.dispatches.length, 1);
});

test('mauvais livreur, course acceptée, anonyme et id invalide refusés', async () => {
  const h = setup();
  await assert.rejects(h.run(h.req({ orderId: 'o1' }, 'dX')), { code: 'permission-denied' });
  const h2 = setup({ status: 'accepted' });
  await assert.rejects(h2.run(h2.req({ orderId: 'o1' })), { code: 'failed-precondition' });
  await assert.rejects(h.run({ auth: { uid: 'dA', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: { orderId: 'o1' } }), { code: 'unauthenticated' });
  await assert.rejects(h.run(h.req({ orderId: 'a/b' })), { code: 'invalid-argument' });
});

test('échec du redispatch : commande reste pending, recoveryPending true', async () => {
  const h = setup({}, new Error('boom'));
  const r = await h.run(h.req({ orderId: 'o1' }));
  assert.equal(r.recoveryPending, true);
  assert.equal(h.db.store.get('orders/o1').status, 'pending');
});

test('diffusion : le livreur est seulement exclu', async () => {
  const h = setup({ status: 'broadcast', driverId: undefined });
  const r = await h.run(h.req({ orderId: 'o1' }));
  assert.equal(r.success, true);
  const o = h.db.store.get('orders/o1');
  assert.equal(o.status, 'broadcast');
  assert.ok(o.excludedDriverIds.includes('dA'));
  assert.equal(h.dispatches.length, 0);
});
