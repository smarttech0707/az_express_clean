'use strict';

// Intégration contre l'ÉMULATEUR Firestore local (jamais un projet cloud) : transactions réellement concurrentes,
// interaction avec cancelOrderCF / payOrderFromWalletCF / dispatch RÉELS.
//   npx firebase emulators:exec --only firestore --config firebase.tariff-emulator.json --project demo-az-tariff \
//     "node --test test/deliveryQuote.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

const CENTER = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 };
const at = (h, m = 0) => Date.UTC(2026, 5, 1, h, m);

let admin; let db; let m;
const state = { clock: at(12) };
const req = (uid, data) => ({ auth: { uid }, data });

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const q = require('../deliveryQuote');
  const oa = require('../orderActions');
  const dispatch = require('../dispatch');
  const base = { db, admin, onCall: (h) => h, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, now: () => state.clock };
  m = {
    HttpsError, dispatch,
    quote: (uid, data, ms = state.clock) => q.createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST, ...data }, nowMs: ms }),
    create: q.buildCreateOrderFromQuoteCF(base),
    cancel: oa.buildCancelOrder({ ...base, calculateCommission: dispatch.calculateCommission }),
    pay: oa.buildPayOrderFromWallet(base),
  };
  // Géographie réelle (collection zones_livraison lue par resolveDispatchGeography).
  await db.doc('zones_livraison/abengourou').set({ type: 'ville', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 30 });
  await db.doc('zones_livraison/centre').set({ type: 'quartier', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 5 });
});

const orderReq = (quoteId, extra = {}) => ({ quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'test' }, ...extra });
const wallet = async (uid) => (await db.doc(`clients/${uid}`).get()).data().wallet;
const countWhere = async (col, field, value) => (await db.collection(col).where(field, '==', value).get()).size;
let seq = 0;
const newClient = async (balance, uid = `c${Date.now().toString(36)}${seq++}`) => { await db.doc(`clients/${uid}`).set({ wallet: balance, name: 'Client Émulé', phone: '+2250000000009' }); return uid; };

test('émulateur : 8 appels simultanés avec le même devis → 1 commande, 1 débit, 1 écriture de journal', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const results = await Promise.all(Array.from({ length: 8 }, () => m.create(req(uid, orderReq(q.data.quoteId)))));
  assert.ok(results.every((r) => r.success), JSON.stringify(results.filter((r) => !r.success)));
  const ids = new Set(results.map((r) => r.data.orderId));
  assert.equal(ids.size, 1, 'tous les appels renvoient la même commande');
  assert.equal(results.filter((r) => !r.data.replayed).length, 1, 'une seule vraie création');
  assert.equal(await wallet(uid), 4500);
  assert.equal(await countWhere('orders', 'clientId', uid), 1);
  assert.equal((await db.collection(`clients/${uid}/wallet_transactions`).get()).size, 1);
  assert.equal((await db.doc(`tariff_quotes/${q.data.quoteId}`).get()).data().status, 'used');
});

test('émulateur : réponse réseau perdue puis rejeu → même commande, aucun second débit', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const first = await m.create(req(uid, orderReq(q.data.quoteId)));
  const replay = await m.create(req(uid, orderReq(q.data.quoteId)));
  assert.equal(replay.data.orderId, first.data.orderId); assert.equal(replay.data.replayed, true);
  assert.equal(await wallet(uid), 4500);
});

test('émulateur : solde pour une seule commande, deux devis simultanés → une réussite, un refus, solde jamais négatif', options, async () => {
  const uid = await newClient(600);
  const [q1, q2] = await Promise.all([m.quote(uid, {}), m.quote(uid, {})]);
  const [a, b] = await Promise.all([m.create(req(uid, orderReq(q1.data.quoteId))), m.create(req(uid, orderReq(q2.data.quoteId)))]);
  const ok = [a, b].filter((r) => r.success), ko = [a, b].filter((r) => !r.success);
  assert.equal(ok.length, 1); assert.equal(ko.length, 1); assert.equal(ko[0].code, 'SOLDE_INSUFFISANT');
  assert.equal(await wallet(uid), 100);
  assert.equal(await countWhere('orders', 'clientId', uid), 1);
  const losing = (a.success ? q2 : q1).data.quoteId;
  assert.equal((await db.doc(`tariff_quotes/${losing}`).get()).data().status, 'open', 'le devis refusé reste utilisable après recharge');
});

test('émulateur : devis expiré, d\'un autre client, détourné → aucun débit, aucune commande', options, async () => {
  const uid = await newClient(5000); const other = await newClient(5000);
  const q = await m.quote(uid, {});
  assert.equal((await m.create(req(other, orderReq(q.data.quoteId)))).code, 'QUOTE_NOT_FOUND');
  assert.equal((await m.create(req(uid, orderReq(q.data.quoteId, { destination: { lat: 6.95, lng: -3.4961 } })))).code, 'QUOTE_MISMATCH');
  state.clock = at(12, 11);
  assert.equal((await m.create(req(uid, orderReq(q.data.quoteId)))).code, 'QUOTE_EXPIRED');
  state.clock = at(12);
  assert.equal(await wallet(uid), 5000); assert.equal(await wallet(other), 5000);
  assert.equal(await countWhere('orders', 'clientId', uid), 0);
});

test('émulateur : changement d\'heure entre devis et paiement → PRICE_CHANGED sans débit puis nouveau devis accepté', options, async () => {
  const uid = await newClient(5000);
  state.clock = at(19, 58);
  const q = await m.quote(uid, {}, state.clock);
  state.clock = at(20, 1);
  const r = await m.create(req(uid, orderReq(q.data.quoteId)));
  assert.equal(r.code, 'PRICE_CHANGED'); assert.deepEqual(r.data, { quotedAmount: 500, currentAmount: 1000 });
  assert.equal(await wallet(uid), 5000);
  const q2 = await m.quote(uid, {}, state.clock);
  assert.equal(q2.data.amount, 1000);
  const ok = await m.create(req(uid, orderReq(q2.data.quoteId, { confirmedAmount: 1000 })));
  assert.equal(ok.data.charged, 1000); assert.equal(await wallet(uid), 4000);
  state.clock = at(12);
});

test('émulateur : cancelOrderCF réel rembourse exactement une fois la commande créée par devis', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const c = await m.create(req(uid, orderReq(q.data.quoteId, { shoppingBudget: 0 })));
  assert.equal(await wallet(uid), 4500);
  await m.cancel(req(uid, { orderId: c.data.orderId }));
  assert.equal(await wallet(uid), 5000);
  const o = (await db.doc(`orders/${c.data.orderId}`).get()).data();
  assert.equal(o.status, 'cancelled');
  await m.cancel(req(uid, { orderId: c.data.orderId })).catch(() => {});
  assert.equal(await wallet(uid), 5000, 'rejeu : pas de second remboursement');
  const refunds = (await db.collection(`clients/${uid}/wallet_transactions`).get()).docs.map((d) => d.data()).filter((t) => t.type === 'refund');
  assert.equal(refunds.length, 1); assert.equal(refunds[0].amount, 500);
});

test('émulateur : cancelOrderCF avec budget d\'achat → rembourse livraison + budget d\'achat', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, { serviceType: 'courses' });
  const c = await m.create(req(uid, orderReq(q.data.quoteId, { serviceType: 'courses', shoppingBudget: 2000 })));
  assert.equal(await wallet(uid), 2500);
  await m.cancel(req(uid, { orderId: c.data.orderId }));
  assert.equal(await wallet(uid), 5000);
});

test('émulateur : payOrderFromWalletCF réel refuse une commande déjà payée par devis (pas de double débit)', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const c = await m.create(req(uid, orderReq(q.data.quoteId)));
  await assert.rejects(m.pay(req(uid, { orderId: c.data.orderId })), (e) => ['failed-precondition'].includes(e.code));
  assert.equal(await wallet(uid), 4500);
});

test('émulateur : commande espèces puis payOrderFromWalletCF → débit unique du seul montant officiel', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const c = await m.create(req(uid, orderReq(q.data.quoteId, { paymentMethod: 'cash' })));
  assert.equal(await wallet(uid), 5000);
  await db.doc('livreurs/dpay').set({ wallet: 0 });
  await db.doc(`orders/${c.data.orderId}`).update({ driverId: 'dpay', status: 'accepted' });
  await m.pay(req(uid, { orderId: c.data.orderId }));
  assert.equal(await wallet(uid), 4500);
  await assert.rejects(m.pay(req(uid, { orderId: c.data.orderId })));
  assert.equal(await wallet(uid), 4500);
  assert.equal((await db.doc('livreurs/dpay').get()).data().wallet, 500);
});

test('émulateur : la commande créée est acceptée par le dispatch réel (champs requis présents, ville dérivée)', options, async () => {
  const uid = await newClient(5000);
  const q = await m.quote(uid, {});
  const c = await m.create(req(uid, orderReq(q.data.quoteId, { order: { description: 'd', pickupCityId: 'pirate' } })));
  const o = (await db.doc(`orders/${c.data.orderId}`).get()).data();
  assert.equal(o.pickupCityId, 'abengourou', 'ville du serveur, pas celle du client');
  assert.equal(o.cityResolutionStatus, 'resolved');
  const r = await m.dispatch.dispatchOrder(db, admin, { orderId: c.data.orderId, lat: o.latitude, lng: o.longitude, pickupCityId: o.pickupCityId, cityResolutionStatus: o.cityResolutionStatus, budget: o.budget });
  assert.equal(r.dispatched, false, 'aucun livreur seedé : pas d\'attribution, mais aucune erreur de dispatch');
  assert.equal(typeof o.budget, 'number'); assert.equal(o.status, 'pending'); assert.ok(o.createdAt);
});

test('émulateur : point hors des villes desservies refusé avant débit', options, async () => {
  const uid = await newClient(5000);
  // Le tarif accepte (aucun plafond de service) mais la géographie de dispatch refuse : rien n'est débité.
  const q = await m.quote(uid, { destination: { lat: 9.9, lng: -3.4961 }, pickup: CENTER });
  const r = await m.create(req(uid, orderReq(q.data.quoteId, { destination: { lat: 9.9, lng: -3.4961 } })));
  assert.equal(r.success, false); assert.equal(r.code, 'OUTSIDE_SERVICE');
  assert.equal(await wallet(uid), 5000);
});
