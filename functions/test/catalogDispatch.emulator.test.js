'use strict';

// SEC-01 release readiness — Lot A Phase 5 : validation d'intégration RÉELLE (émulateur Firestore,
// jamais la production) de la correction Phase 4 — une commande Catalogue (Blanchisserie, Colis,
// Eau & Boissons) créée via createCatalogOrderFromQuoteCF doit être réellement détectée et attribuée
// par le VRAI dispatch.js / dispatchRetry.js, pas seulement validée en isolation (voir
// catalogQuote.test.js, qui injecte un résolveur de géographie simulé).
//
//   npx firebase emulators:exec --only firestore \
//     "node --test functions/test/catalogDispatch.emulator.test.js"
//
// Fichier séparé de dispatchRetry.emulator.test.js : ne le modifie pas, même patron de harnais.
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let retry; let dispatch; let catalogQuote; let HttpsError;

const ts = (ms) => admin.firestore.Timestamp.fromMillis(ms);
const driver = (extra = {}) => ({
  wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou',
  lat: 6.731, lng: -3.491, updatedAt: ts(Date.now()), ...extra,
});

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-billing-test' });
  db = admin.firestore();
  HttpsError = require('firebase-functions/v2/https').HttpsError;
  retry = require('../dispatchRetry');
  dispatch = require('../dispatch');
  catalogQuote = require('../catalogQuote');
  await db.doc('zones_livraison/abengourou').set({
    type: 'ville', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own',
    lat: 6.7, lng: -3.5, radiusKm: 100,
  });
  await db.doc('zones_livraison/centre').set({
    type: 'quartier', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own',
    lat: 6.7, lng: -3.5, radiusKm: 100,
  });
});

test.afterEach(async () => {
  if (!emulated) return;
  for (const id of ['dCatA', 'dCatB']) await db.doc('livreurs/' + id).delete();
});

const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const noop = async () => {};
const run = (extra = {}) => retry.retryPendingDispatch({
  db, admin, dispatchOrder: dispatch.dispatchOrder, DispatchError: dispatch.DispatchError,
  logger: { log() {}, error() {}, warn() {} }, ...extra,
});
const read = async (path) => (await db.doc(path).get()).data();

function catalogFns(uid) {
  // Aucune géographie injectée : le VRAI resolveDispatchGeography (dispatch.js) est utilisé, via le
  // paramètre par défaut de catalogQuote.js — c'est précisément ce que cette passe veut prouver.
  const deps = {
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: noop, logAudit: noop, now: () => Date.now(),
  };
  const quoteFn = catalogQuote.buildQuoteCatalogCF({ ...deps, randomId: () => `catq_${Date.now()}_${Math.random()}` }).run;
  const orderFn = catalogQuote.buildCreateCatalogOrderFromQuoteCF({ ...deps, newOrderId: () => `catord_${Date.now()}_${Math.random()}` }).run;
  return {
    quote: (data) => quoteFn(req(uid, data)),
    order: (data) => orderFn(req(uid, data)),
  };
}

for (const [service, choices] of [
  ['colis', { service: 'colis', colisType: 'Colis standard', fragile: false, recipientName: 'Kouassi', recipientAddress: 'Centre' }],
  ['blanchisserie', { service: 'blanchisserie', serviceType: 'Lavage + Repassage', quantity: 2, address: 'Centre' }],
  ['eau_boissons', { service: 'eau_boissons', items: [{ id: 'eau_1500', qty: 1 }], address: 'Centre' }],
]) {
  test(`émulateur : commande ${service} réelle (point valide) détectée et attribuée par le VRAI dispatch`, options, async () => {
    const uid = `client_${service}`;
    await db.doc(`clients/${uid}`).set({ wallet: 5000, name: 'Client Test', phone: '+2250000000099' });
    const fns = catalogFns(uid);

    const quote = await fns.quote(choices);
    assert.equal(quote.success, true, `devis ${service} refusé : ${quote.message}`);

    const result = await fns.order({
      ...choices, quoteId: quote.data.quoteId, paymentMethod: 'cash',
      lat: 6.73, lng: -3.49, coordinateSource: 'gps',
    });
    assert.equal(result.success, true, `création ${service} refusée : ${result.message}`);
    const orderId = result.data.orderId;

    const created = await read(`orders/${orderId}`);
    // Preuve directe de la correction Phase 4 : plus de (0,0), géographie réellement résolue par
    // dispatch.js (pas simulée), cohérence pickup/delivery (point unique pour ces 3 services).
    assert.notDeepEqual([created.latitude, created.longitude], [0, 0]);
    assert.equal(created.latitude, 6.73);
    assert.equal(created.longitude, -3.49);
    assert.equal(created.latitude, created.deliveryLatitude);
    assert.equal(created.longitude, created.deliveryLongitude);
    assert.equal(created.pickupCityId, 'abengourou');
    assert.equal(created.deliveryCityId, 'abengourou');
    assert.equal(created.cityResolutionStatus, 'resolved');
    assert.equal(created.status, 'pending');

    // retryPendingDispatch n'attaque le 1er palier qu'à partir de 30 s d'âge (STAGES[0].minAgeMs,
    // dispatchRetry.js) — ni ces 3 écrans Catalogue ni aucun code actuel n'appellent
    // dispatchOrderToDriver immédiatement après création (confirmé en Phase 3 : aucun appel trouvé).
    // On recule donc createdAt de 60 s pour simuler l'état réel au moment où la première passe
    // planifiée (toutes les 1 min) traite la commande — sans cela, le test attesterait un "pending"
    // qui ne prouve rien (trop tôt), pas un échec du dispatch lui-même.
    await db.doc(`orders/${orderId}`).update({ createdAt: ts(Date.now() - 60_000) });

    // Un livreur réel, en ligne, dans la même ville : le VRAI retryPendingDispatch doit le trouver.
    await db.doc('livreurs/dCatA').set(driver());
    await run();

    const afterDispatch = await read(`orders/${orderId}`);
    assert.ok(
      ['assigned', 'broadcast'].includes(afterDispatch.status),
      `commande ${service} toujours 'pending' après retryPendingDispatch — le dispatch n'a pas fonctionné (statut observé : ${afterDispatch.status})`,
    );
    if (afterDispatch.status === 'assigned') assert.equal(afterDispatch.driverId, 'dCatA');
  });
}

test('émulateur : commande Catalogue sans coordonnées valides refusée AVANT création (contrôle négatif — confirme que le test positif ci-dessus est significatif)', options, async () => {
  const uid = 'client_colis_invalid';
  await db.doc(`clients/${uid}`).set({ wallet: 5000 });
  const fns = catalogFns(uid);
  const choices = { service: 'colis', colisType: 'Colis standard', fragile: false, recipientName: 'K', recipientAddress: 'Centre' };
  const quote = await fns.quote(choices);
  const result = await fns.order({ ...choices, quoteId: quote.data.quoteId, paymentMethod: 'cash', lat: 0, lng: 0 });
  assert.equal(result.success, false);
  assert.equal(result.code, 'LOCATION_REQUIRED');
  assert.equal(result.data, null);
});

test('émulateur : reprise simultanée sur une commande Colis réelle → une seule attribution (non-régression concurrence)', options, async () => {
  const uid = 'client_colis_concurrency';
  await db.doc(`clients/${uid}`).set({ wallet: 5000 });
  const fns = catalogFns(uid);
  const choices = { service: 'colis', colisType: 'Colis standard', fragile: false, recipientName: 'K', recipientAddress: 'Centre' };
  const quote = await fns.quote(choices);
  const result = await fns.order({ ...choices, quoteId: quote.data.quoteId, paymentMethod: 'cash', lat: 6.73, lng: -3.49 });
  const orderId = result.data.orderId;
  await db.doc(`orders/${orderId}`).update({ createdAt: ts(Date.now() - 60_000) });
  await db.doc('livreurs/dCatB').set(driver({ lat: 6.7301, lng: -3.4901 }));
  await Promise.all([run(), run(), run()]);
  const lease = await read(`order_dispatch_retries/${orderId}`);
  assert.equal(lease.attempts, 1);
  const o = await read(`orders/${orderId}`);
  assert.equal(o.status, 'assigned');
  assert.equal(o.driverId, 'dCatB');
});
