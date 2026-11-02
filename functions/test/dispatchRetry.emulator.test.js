'use strict';

// Concurrence RÉELLE (émulateur Firestore, jamais la production) pour la reprise
// du dispatch : vrai `dispatchOrder`, vraies transactions, vraies acceptations.
//   npx firebase emulators:exec --only firestore --project az-billing-test \
//     "node --test functions/test/dispatchRetry.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let retry; let dispatch; let accept; let expire;

const ts = (ms) => admin.firestore.Timestamp.fromMillis(ms);
const driver = (extra = {}) => ({
  wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou',
  lat: 6.74, lng: -3.49, updatedAt: ts(Date.now()), ...extra,
});

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-billing-test' });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  retry = require('../dispatchRetry');
  dispatch = require('../dispatch');
  const { buildAcceptOrder } = require('../driverAcceptance');
  const { withSelfie } = require('./selfieHelper');
  const { expireOrderTx } = require('../orderRefunds');
  const oc = (...a) => ({ run: a[a.length - 1] });
  accept = withSelfie(buildAcceptOrder({
    db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {},
    onCall: oc, calculateCommission: dispatch.calculateCommission,
  }).run);
  expire = (oid) => db.runTransaction((tx) => expireOrderTx(tx, { db, admin, orderRef: db.doc(`orders/${oid}`), orderId: oid }));
  await db.doc('zones_livraison/abengourou').set({
    type: 'ville', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own',
    lat: 6.7, lng: -3.5, radiusKm: 100,
  });
  await db.doc('zones_livraison/centre').set({
    type: 'quartier', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own',
    lat: 6.7, lng: -3.5, radiusKm: 100,
  });
});

// Un échec d'un test ne doit pas laisser de livreurs qui fausseraient les suivants.
test.afterEach(async () => {
  if (!emulated) return;
  for (const id of ['dRetryA', 'dRetryB', 'dRetryC1', 'dRetryC2', 'dRetryF', 'dRetryF1', 'dRetryF2', 'dRetryG1', 'dRetryG2']) await db.doc('livreurs/' + id).delete();
});

const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const order = (ageMs, extra = {}) => ({
  clientId: 'cRetry', status: 'pending', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
  createdAt: ts(Date.now() - ageMs), latitude: 6.73, longitude: -3.49, destLat: 6.74, destLng: -3.5,
  budget: 1000, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved', ...extra,
});
const run = (extra = {}) => retry.retryPendingDispatch({
  db, admin, dispatchOrder: dispatch.dispatchOrder, DispatchError: dispatch.DispatchError,
  logger: { log() {}, error() {}, warn() {} }, ...extra,
});
const read = async (path) => (await db.doc(path).get()).data();

test('émulateur : trois passes simultanées → un seul essai réservé, une seule attribution', options, async () => {
  const oid = `retry_${Date.now()}_a`;
  await db.doc(`orders/${oid}`).set(order(60_000));
  await db.doc('livreurs/dRetryA').set(driver());
  // Seule cette commande doit être concernée par l'assertion.
  await Promise.all([run(), run(), run()]);
  const lease = await read(`order_dispatch_retries/${oid}`);
  assert.equal(lease.attempts, 1);
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'assigned');
  assert.equal(o.driverId, 'dRetryA');
  await db.doc('livreurs/dRetryA').delete();
});

test('émulateur : reprise puis dispatch du client simultanés → une seule attribution, aucune commission prélevée', options, async () => {
  const oid = `retry_${Date.now()}_b`;
  await db.doc(`orders/${oid}`).set(order(60_000));
  await db.doc('livreurs/dRetryB').set(driver({ lat: 6.7301, lng: -3.4901 }));
  await Promise.all([
    run(),
    dispatch.dispatchOrder(db, admin, { orderId: oid, lat: 6.73, lng: -3.49, budget: 1000, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved' }),
  ]);
  const o = await read(`orders/${oid}`);
  assert.ok(['assigned', 'broadcast'].includes(o.status));
  assert.equal((await read('livreurs/dRetryB')).wallet, 1000, 'le dispatch ne prélève jamais de commission');
  assert.equal(o.commissionStatus, undefined);
  await db.doc('livreurs/dRetryB').delete();
});

test('émulateur : deux livreurs acceptent en même temps une commande reprise → une seule acceptation, une seule commission', options, async () => {
  const oid = `retry_${Date.now()}_c`;
  await db.doc(`orders/${oid}`).set(order(60_000, { type: 'livraison' }));
  await db.doc('livreurs/dRetryC1').set(driver({ lat: 6.7301, lng: -3.4901 }));
  await db.doc('livreurs/dRetryC2').set(driver({ lat: 6.7302, lng: -3.4902 }));
  await run();
  const afterRetry = await read(`orders/${oid}`);
  assert.equal(afterRetry.status, 'broadcast');
  const results = await Promise.allSettled([
    accept(req('dRetryC1', { orderId: oid })),
    accept(req('dRetryC2', { orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'accepted');
  const wallets = [(await read('livreurs/dRetryC1')).wallet, (await read('livreurs/dRetryC2')).wallet].sort((a, b) => a - b);
  assert.deepEqual(wallets, [800, 1000], 'exactement une commission (200 FCFA pour un budget de 1000) prélevée');
  // Une nouvelle passe ne touche pas une commande acceptée.
  await run();
  assert.equal((await read(`orders/${oid}`)).status, 'accepted');
  assert.equal((await read(`order_dispatch_retries/${oid}`)).attempts, 1);
  await db.doc('livreurs/dRetryC1').delete();
  await db.doc('livreurs/dRetryC2').delete();
});

test('émulateur : expiration et reprise simultanées sur une commande payée → un seul remboursement, jamais de reprise après annulation', options, async () => {
  const oid = `retry_${Date.now()}_d`;
  await db.doc('clients/cRetry').set({ wallet: 0 });
  await db.doc(`orders/${oid}`).set(order(11 * 60_000, { shoppingBudget: 3000, budget: 500 }));
  await Promise.all([expire(oid), expire(oid), run()]);
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'cancelled');
  assert.equal((await read('clients/cRetry')).wallet, 3500, 'livraison + achats remboursés une seule fois');
  await run();
  assert.equal((await read(`orders/${oid}`)).status, 'cancelled');
});

test('émulateur : broadcast sans réponse → élargi : le nouveau livreur est AJOUTÉ, les premiers restent', options, async () => {
  const oid = `retry_${Date.now()}_e`;
  await db.doc(`orders/${oid}`).set(order(150_000, { status: 'broadcast', notifiedDriverIds: ['dRetryF1', 'dRetryF2'], lastDispatchAtMs: Date.now() - 100_000 }));
  await db.doc('livreurs/dRetryF1').set(driver({ pendingOrderId: oid }));
  await db.doc('livreurs/dRetryF2').set(driver({ pendingOrderId: oid }));
  await db.doc('livreurs/dRetryF').set(driver({ lat: 6.76, lng: -3.49 })); // ~3,3 km : hors 2 km, dans 5 km
  await run();
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'broadcast');
  assert.deepEqual([...o.notifiedDriverIds].sort(), ['dRetryF', 'dRetryF1', 'dRetryF2']);
  assert.equal(o.driverId, undefined);
  assert.equal((await read('livreurs/dRetryF')).pendingOrderId, oid);
  assert.equal((await read('livreurs/dRetryF')).wallet, 1000, 'aucune commission à la diffusion');
  // Le nouveau livreur peut accepter (il figure dans notifiedDriverIds) ; une seule commission.
  await accept(req('dRetryF', { orderId: oid }));
  assert.equal((await read(`orders/${oid}`)).status, 'accepted');
  assert.equal((await read('livreurs/dRetryF')).wallet, 800);
  await run();
  assert.equal((await read(`orders/${oid}`)).status, 'accepted');
});

test('émulateur : élargissement et acceptation simultanés → une seule acceptation, une commission, aucune double attribution', options, async () => {
  const oid = `retry_${Date.now()}_g`;
  await db.doc(`orders/${oid}`).set(order(150_000, { status: 'broadcast', notifiedDriverIds: ['dRetryG1'], lastDispatchAtMs: Date.now() - 100_000 }));
  await db.doc('livreurs/dRetryG1').set(driver({ pendingOrderId: oid }));
  await db.doc('livreurs/dRetryG2').set(driver({ lat: 6.76, lng: -3.49 }));
  const results = await Promise.allSettled([
    run(), accept(req('dRetryG1', { orderId: oid })), run(),
  ]);
  assert.equal(results[1].status, 'fulfilled');
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'accepted');
  assert.equal(o.driverId, 'dRetryG1');
  assert.equal((await read('livreurs/dRetryG1')).wallet, 800);
  assert.equal((await read('livreurs/dRetryG2')).wallet, 1000);
});

test('émulateur : broadcast jamais accepté → expire à 10 min et le client est remboursé une seule fois', options, async () => {
  const oid = `retry_${Date.now()}_h`;
  await db.doc('clients/cRetry').set({ wallet: 0 });
  await db.doc(`orders/${oid}`).set(order(11 * 60_000, { status: 'broadcast', notifiedDriverIds: ['x1'], budget: 1000 }));
  await run();
  assert.equal((await read(`orders/${oid}`)).status, 'broadcast', 'plus d’élargissement après 9 min');
  await Promise.all([expire(oid), expire(oid)]);
  assert.equal((await read(`orders/${oid}`)).status, 'cancelled');
  assert.equal((await read('clients/cRetry')).wallet, 1000);
});

test('émulateur : élargissement du rayon — livreur à ~3 km trouvé au 2ᵉ essai (5 km), pas au 1ᵉʳ (2 km)', options, async () => {
  const oid = `retry_${Date.now()}_f`;
  await db.doc(`orders/${oid}`).set(order(40_000));
  // ~3,3 km au nord du point de collecte (6.73, -3.49).
  await db.doc('livreurs/dRetryF').set(driver({ lat: 6.76, lng: -3.49 }));
  await run();
  assert.equal((await read(`orders/${oid}`)).status, 'pending', 'hors rayon de 2 km');
  // 100 s plus tard (2ᵉ exécution du scheduler) : rayon de 5 km.
  await db.doc(`orders/${oid}`).update({ createdAt: ts(Date.now() - 100_000) });
  await db.doc(`order_dispatch_retries/${oid}`).update({ lastAttemptAtMs: Date.now() - 60_000 });
  await run();
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'assigned');
  assert.equal(o.driverId, 'dRetryF');
  await db.doc('livreurs/dRetryF').delete();
});
