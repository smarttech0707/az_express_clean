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

// ── Mission 7C-2 : phase 2 bornée et livreur assigné sans réponse, transactions réellement concurrentes ──

const v2prepared = (ageMs, extra = {}) => order(ageMs, {
  amountsVersion: 2, sellerStatus: 'preparing', sellerType: 'restaurant', sellerId: 'rRetry', type: 'restaurant',
  partnerAcceptedAtMs: Date.now() - ageMs + 20_000, ...extra,
});

test('émulateur 7C-2 : trois passes simultanées en phase 2 → un seul essai, élargissement sans rappel des premiers livreurs', options, async () => {
  const oid = `retry_${Date.now()}_p2`;
  // Commande v2 : seuls les livreurs listés explicitement dans le pilote peuvent être notifiés (Mission 7E-55). Config retirée par afterEach.
  await db.doc('config/partnerOrdersV2').set({ pilotPartnerIds: ['rRetry'], pilotClientIds: ['cRetry'], pilotDriverIds: ['dP1', 'dP2'], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 1 });
  await db.doc(`orders/${oid}`).set(v2prepared(14 * 60_000, { status: 'broadcast', notifiedDriverIds: ['dP1'], lastDispatchAtMs: Date.now() - 13 * 60_000 }));
  await db.doc('livreurs/dP1').set(driver({ pendingOrderId: oid }));
  await db.doc('livreurs/dP2').set(driver({ lat: 6.76, lng: -3.49 }));
  await Promise.all([run(), run(), run()]);
  const lease = await read(`order_dispatch_retries/${oid}`);
  assert.deepEqual([lease.phase2Attempts, lease.lifetimeAttempts], [1, 1]);
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'broadcast');
  assert.deepEqual([...o.notifiedDriverIds].sort(), ['dP1', 'dP2'], 'dP1 conservé, dP2 ajouté une seule fois');
  // Nouvelle passe immédiate : espacement de 3 min, aucun nouvel essai.
  await run();
  assert.equal((await read(`order_dispatch_retries/${oid}`)).phase2Attempts, 1);
  await db.doc('livreurs/dP1').delete(); await db.doc('livreurs/dP2').delete();
});

test('émulateur 7C-2 : fenêtre de 45 min close → aucun essai, aucune annulation, commande intacte', options, async () => {
  const oid = `retry_${Date.now()}_win`;
  await db.doc(`orders/${oid}`).set(v2prepared(50 * 60_000, { partnerAcceptedAtMs: Date.now() - 46 * 60_000 }));
  await db.doc('livreurs/dP1').set(driver());
  const seen = [];
  await run({ onExhausted: async (id, _o, reason) => { seen.push([id, reason]); } });
  assert.ok(seen.some(([id, reason]) => id === oid && reason === 'window_closed'));
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'pending');
  assert.equal(o.driverId, undefined);
  await db.doc('livreurs/dP1').delete();
});

test('émulateur 7C-2 : livreur assigné silencieux — acceptation et remise en file simultanées (8 tours) : un seul gagnant', options, async () => {
  for (let i = 0; i < 4; i++) {
    const oid = `retry_${Date.now()}_as${i}`;
    await db.doc(`orders/${oid}`).set(v2prepared(10 * 60_000, { status: 'assigned', driverId: 'dS1', assignedAtMs: Date.now() - 4 * 60_000 }));
    await db.doc('livreurs/dS1').set(driver({ pendingOrderId: oid }));
    const calls = [accept(req('dS1', { orderId: oid })), run(), run()];
    await Promise.allSettled(i % 2 ? calls.reverse() : calls);
    const o = await read(`orders/${oid}`);
    const wallet = (await read('livreurs/dS1')).wallet;
    if (o.status === 'accepted') {
      assert.equal(o.driverId, 'dS1', `tour ${i}`);
      assert.equal(wallet, 800, `tour ${i} : commission prélevée une fois`);
      assert.equal(o.excludedDriverIds, undefined);
    } else {
      assert.ok(['pending', 'broadcast', 'assigned'].includes(o.status), `tour ${i} : ${o.status}`);
      assert.ok(Array.isArray(o.excludedDriverIds) && o.excludedDriverIds.includes('dS1'), `tour ${i}`);
      assert.equal(wallet, 1000, `tour ${i} : aucune commission`);
    }
    await db.doc('livreurs/dS1').delete();
  }
});

// ── Mission 7E-55 : liste blanche des livreurs du pilote (partnerOrdersV2.pilotDriverIds), commande v2 ──

test.afterEach(async () => {
  if (!emulated) return;
  await db.doc('config/partnerOrdersV2').delete();
  for (const id of ['dAuth', 'dOther']) await db.doc('livreurs/' + id).delete();
});

test('émulateur 7E-55 : commande v2 sans configuration de pilote → aucun livreur notifié (refus par défaut), commande intacte', options, async () => {
  const oid = `retry_${Date.now()}_nocfg`;
  await db.doc(`orders/${oid}`).set(v2prepared(60_000));
  await db.doc('livreurs/dAuth').set(driver());
  await run();
  const o = await read(`orders/${oid}`);
  assert.equal(o.status, 'pending');
  assert.equal(o.driverId, undefined);
  assert.deepEqual(o.notifiedDriverIds || [], []);
});

test('émulateur 7E-55 : liste vide ou absente → personne ; livreur listé servi, livreur non listé jamais notifié ni accepté', options, async () => {
  const base = { pilotPartnerIds: ['rRetry'], pilotClientIds: ['cRetry'], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 1 };
  await db.doc('livreurs/dAuth').set(driver());
  await db.doc('livreurs/dOther').set(driver({ lat: 6.7401 }));
  for (const [label, extra] of [['liste absente', {}], ['liste vide', { pilotDriverIds: [] }]]) {
    await db.doc('config/partnerOrdersV2').set({ ...base, ...extra });
    const oid = `retry_${Date.now()}_${label.replace(/ /g, '')}`;
    await db.doc(`orders/${oid}`).set(v2prepared(60_000));
    await run();
    const o = await read(`orders/${oid}`);
    assert.equal(o.status, 'pending', label);
    assert.equal(o.driverId, undefined, label);
  }
  await db.doc('config/partnerOrdersV2').set({ ...base, pilotDriverIds: ['dAuth'] });
  const oid = `retry_${Date.now()}_listed`;
  await db.doc(`orders/${oid}`).set(v2prepared(60_000));
  await run();
  const o = await read(`orders/${oid}`);
  assert.equal(o.driverId, 'dAuth', 'le livreur listé est servi');
  assert.ok(!(o.notifiedDriverIds || []).includes('dOther'), 'le livreur non listé n’est jamais notifié');
  // Un livreur non listé ne peut pas accepter la commande, même s'il connaît son identifiant.
  const oid2 = `retry_${Date.now()}_forced`;
  await db.doc(`orders/${oid2}`).set(v2prepared(60_000, { status: 'broadcast', notifiedDriverIds: ['dOther'] }));
  await assert.rejects(accept(req('dOther', { orderId: oid2 })), (e) => e.code === 'permission-denied' && /DRIVER_NOT_IN_PILOT/.test(e.message));
  assert.equal((await read(`orders/${oid2}`)).driverId, undefined);
});
