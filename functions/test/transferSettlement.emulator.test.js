'use strict';

// Intégration contre l'émulateur Firestore (jamais la production) : la
// concurrence réelle des transactions que le faux Firestore ne simule pas.
//   npx firebase emulators:exec --only firestore --project az-transfer-settlement-test \
//     "node --test functions/test/transferSettlement.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let call;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-transfer-settlement-test' });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildSettleTransferEarnings } = require('../transferSettlement');
  const { settlementDocument } = require('../earningsSettlement');
  const { buildDeliveryTransfer, expireTransfer } = require('../driverTransfer');
  const settle = buildSettleTransferEarnings({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
    requireSuperAdmin: async ({ request }) => {
      if (request.auth.uid !== 'root') throw new HttpsError('permission-denied', 'non');
    },
  }).run;
  call = { settle, settlementDocument, buildDeliveryTransfer, expireTransfer, HttpsError };
});

const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const order = {
  clientId: 'c1', status: 'delivered', driverId: 'dB', budget: 1000, settlementHold: true,
  latitude: 6.70, longitude: -3.49, destLat: 6.80, destLng: -3.49, pickedUpAt: 1, deliveryPhoto: 'p.jpg',
  commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
  driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10,
    handover: { trusted: true, point: { lat: 6.74, lng: -3.49 } } }],
};

test('émulateur : deux validations simultanées ne créditent qu’une fois', options, async () => {
  const oid = `race_${Date.now()}`;
  await db.doc(`orders/${oid}`).set(order);
  await db.doc(`livreurs/dA`).set({ wallet: 300 });
  await db.doc(`livreurs/dB`).set({ wallet: 0 });
  await db.doc(`transfer_settlements/${oid}`).set(call.settlementDocument(oid, order, 'wallet', Date.now()));
  const results = await Promise.allSettled([
    call.settle(req('root', { action: 'approve', orderId: oid })),
    call.settle(req('root', { action: 'approve', orderId: oid })),
    call.settle(req('root', { action: 'approve', orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled' && r.value.replay === false).length, 1);
  const a = (await db.doc('livreurs/dA').get()).data().wallet - 300;
  const b = (await db.doc('livreurs/dB').get()).data().wallet;
  assert.equal(a + b, 1000);
  const ledger = await db.collection('livreurs').doc('dA').collection('wallet_transactions').get();
  assert.equal(ledger.docs.filter((d) => d.id === `transfer_settlement_${oid}_dA`).length, 1);
  assert.equal((await db.doc(`orders/${oid}`).get()).data().settlementHold, false);
});

test('émulateur : double expiration simultanée d’un transfert libère B une fois', options, async () => {
  const oid = `exp_${Date.now()}`;
  await db.doc(`orders/${oid}`).set({ status: 'picked_up', driverId: 'dA', activeTransferId: `${oid}_1` });
  await db.doc('livreurs/dA').set({ isOnDelivery: true });
  await db.doc('livreurs/dB2').set({ isOnDelivery: true, pendingOrderId: oid });
  await db.doc(`delivery_transfers/${oid}_1`).set({
    orderId: oid, fromDriverId: 'dA', toDriverId: 'dB2', status: 'accepted', candidateIds: ['dB2'],
    expiresAtMs: Date.now() - 1000,
  });
  const r = await Promise.all([
    call.expireTransfer(db, admin, `${oid}_1`), call.expireTransfer(db, admin, `${oid}_1`),
  ]);
  assert.equal(r.filter(Boolean).length, 1);
  const b = (await db.doc('livreurs/dB2').get()).data();
  assert.equal(b.isOnDelivery, false);
  assert.equal(b.pendingOrderId, undefined);
  assert.equal((await db.doc(`orders/${oid}`).get()).data().activeTransferId, undefined);
  assert.equal((await db.doc(`orders/${oid}`).get()).data().driverId, 'dA');
});

test('émulateur : deux acceptations simultanées du même transfert, une seule gagne', options, async () => {
  const oid = `acc_${Date.now()}`;
  const tid = `${oid}_1`;
  await db.doc(`orders/${oid}`).set({ status: 'picked_up', driverId: 'dA', activeTransferId: tid, driverAssignmentVersion: 1 });
  const d = { isOnline: true, isAvailable: true, currentCityId: 'abengourou' };
  await db.doc('livreurs/dA').set({ ...d, isOnDelivery: true });
  await db.doc('livreurs/dB3').set(d);
  await db.doc('livreurs/dC3').set(d);
  await db.doc(`delivery_transfers/${tid}`).set({
    orderId: oid, fromDriverId: 'dA', toDriverId: null, status: 'requested', cityId: 'abengourou',
    candidateIds: ['dB3', 'dC3'], declinedBy: [], assignmentVersion: 1, expiresAtMs: Date.now() + 600000,
  });
  const run = call.buildDeliveryTransfer({
    db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError: call.HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
  }).run;
  const results = await Promise.allSettled([
    run(req('dB3', { action: 'accept', transferId: tid })),
    run(req('dC3', { action: 'accept', transferId: tid })),
  ]);
  assert.equal(results.filter((x) => x.status === 'fulfilled').length, 1);
  const t = (await db.doc(`delivery_transfers/${tid}`).get()).data();
  assert.equal(t.status, 'accepted');
  const loser = t.toDriverId === 'dB3' ? 'dC3' : 'dB3';
  assert.notEqual((await db.doc(`livreurs/${loser}`).get()).data().isOnDelivery, true);
});

test('émulateur : acceptation simultanée par le même livreur, une seule commission prélevée', options, async () => {
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildAcceptOrder } = require('../driverAcceptance');
  const { withSelfie } = require('./selfieHelper');
  const { calculateCommission } = require('../dispatch');
  const accept = withSelfie(buildAcceptOrder({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run);
  const oid = `dbl_${Date.now()}`;
  await db.doc(`orders/${oid}`).set({ status: 'assigned', driverId: 'dAcc', budget: 1000, description: 'x' });
  await db.doc('livreurs/dAcc').set({ wallet: 1000, isOnline: true });
  const results = await Promise.allSettled(Array.from({ length: 3 }, () =>
    accept(req('dAcc', { orderId: oid }))));
  assert.ok(results.every((r) => r.status === 'fulfilled'));
  assert.equal((await db.doc('livreurs/dAcc').get()).data().wallet, 800); // 200 une seule fois
  const o = (await db.doc(`orders/${oid}`).get()).data();
  assert.deepEqual([o.commissionAmount, o.commissionStatus, o.commissionPayerId], [200, 'charged', 'dAcc']);
});

test('émulateur : libération simultanée avant récupération, une seule restitution de commission', options, async () => {
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildReleaseOrderBeforePickup } = require('../driverRelease');
  const { calculateCommission, DispatchError } = require('../dispatch');
  const release = buildReleaseOrderBeforePickup({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
    dispatchOrder: async () => ({ dispatched: false }), DispatchError,
  }).run;
  const oid = `rel_${Date.now()}`;
  await db.doc(`orders/${oid}`).set({
    status: 'accepted', driverId: 'dRel', budget: 1000, commissionStatus: 'charged',
    commissionPayerId: 'dRel', commissionAmount: 200, commissionTxId: `commission_${oid}_dRel`,
  });
  await db.doc('livreurs/dRel').set({ wallet: 800, isOnDelivery: true });
  await Promise.allSettled(Array.from({ length: 3 }, () =>
    release(req('dRel', { orderId: oid, reason: 'other' }))));
  assert.equal((await db.doc('livreurs/dRel').get()).data().wallet, 1000); // +200 une seule fois
  assert.equal((await db.doc(`orders/${oid}`).get()).data().commissionStatus, 'refunded');
});

// ---- Annulation pendant un transfert (concurrence réelle) ----
async function cancelWorld(tag) {
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  process.env.DELIVERY_PROOF_PEPPER = 'test-pepper';
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildAcceptOrder } = require('../driverAcceptance');
  const { buildDeliveryTransfer } = require('../driverTransfer');
  const { buildCancelOrder } = require('../orderActions');
  const { calculateCommission } = require('../dispatch');
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const oc = (...a) => ({ run: a[a.length - 1] });
  const fns = {
    accept: withSelfie(buildAcceptOrder({ ...common, onCall: oc, calculateCommission }).run),
    transfer: buildDeliveryTransfer({ ...common, onCall: oc }).run,
    cancel: buildCancelOrder({ ...common, onCall: oc, calculateCommission }).run,
  };
  const ids = { o: `${tag}_${Date.now()}`, c: `c_${tag}_${Date.now()}`, a: `dA_${tag}_${Date.now()}`, b: `dB_${tag}_${Date.now()}` };
  const city = `city_${tag}_${Date.now()}`; // isole les candidats des autres tests
  const drv = { wallet: 1000, isOnline: true, isAvailable: true, currentCityId: city };
  await db.doc(`orders/${ids.o}`).set({
    clientId: ids.c, status: 'assigned', driverId: ids.a, budget: 1000, description: 'x',
    paymentMethod: 'wallet', isPaid: true, pickupCityId: city,
  });
  await db.doc(`clients/${ids.c}`).set({ wallet: 4000 });
  await db.doc(`livreurs/${ids.a}`).set(drv);
  await db.doc(`livreurs/${ids.b}`).set(drv);
  await fns.accept(req(ids.a, { orderId: ids.o }));
  await db.doc(`orders/${ids.o}`).update({ status: 'picked_up', pickedUpAt: 1 });
  const r = await fns.transfer(req(ids.a, { action: 'request', orderId: ids.o, reason: 'other' }));
  await fns.transfer(req(ids.b, { action: 'accept', transferId: r.transferId }));
  const p = await fns.transfer(req(ids.b, { action: 'prepareHandover', transferId: r.transferId }));
  return { fns, ids, tid: r.transferId, p };
}
const snapshotAfter = async (ids) => ({
  c: (await db.doc(`clients/${ids.c}`).get()).data().wallet,
  a: (await db.doc(`livreurs/${ids.a}`).get()).data().wallet,
  b: (await db.doc(`livreurs/${ids.b}`).get()).data(),
  o: (await db.doc(`orders/${ids.o}`).get()).data(),
});

test('émulateur : annulations simultanées pendant un transfert, un seul remboursement', options, async () => {
  const { fns, ids, tid } = await cancelWorld('cc');
  const results = await Promise.allSettled([
    fns.cancel(req(ids.c, { orderId: ids.o })), fns.cancel(req(ids.c, { orderId: ids.o })),
    fns.cancel(req(ids.c, { orderId: ids.o })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const s = await snapshotAfter(ids);
  assert.equal(s.c, 5000); // 1000 remboursés une seule fois
  assert.equal(s.a, 1000); // commission rendue une seule fois
  assert.equal(s.b.wallet, 1000);
  assert.equal(s.b.isOnDelivery, false);
  assert.equal(s.o.status, 'cancelled');
  assert.equal((await db.doc(`delivery_transfers/${tid}`).get()).data().status, 'cancelled');
});

test('émulateur : annulation et confirmation de remise simultanées, état final toujours cohérent', options, async () => {
  const { fns, ids, tid, p } = await cancelWorld('cx');
  const results = await Promise.allSettled([
    fns.cancel(req(ids.c, { orderId: ids.o })),
    fns.transfer(req(ids.a, { action: 'confirmHandover', transferId: tid, token: p.token })),
  ]);
  assert.equal(results[0].status, 'fulfilled'); // l'annulation aboutit toujours
  const s = await snapshotAfter(ids);
  assert.equal(s.o.status, 'cancelled');
  assert.equal(s.c, 5000);
  assert.equal(s.a, 1000); // payeur d'origine remboursé exactement une fois
  assert.equal(s.b.wallet, 1000);
  assert.equal(s.b.isOnDelivery, false); // B libéré quel que soit l'ordre d'exécution
  assert.equal(s.b.pendingOrderId, undefined);
  assert.equal(s.o.activeTransferId, undefined);
  const t = (await db.doc(`delivery_transfers/${tid}`).get()).data();
  assert.ok(['cancelled', 'completed'].includes(t.status));
});
