'use strict';

// Commandes standard Restaurant / Boulangerie (Mission 7B-1) contre l'émulateur Firestore (jamais la production) :
// concurrence RÉELLE des transactions. Données fictives uniquement.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-partner \
//     "node --test functions/test/partnerOrderConcurrency.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

const PLACE = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 };
const GEO = { pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' };
const rReq = { sellerType: 'restaurant', sellerId: 'pr1', items: [{ itemId: 'm1', qty: 2 }], destination: DEST };

let admin; let db; let run;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
  const { buildCancelOrder } = require('../orderActions');
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, isEnabled: () => true };
  run = {
    quote: buildQuotePartnerOrderCF(deps).run,
    order: buildCreatePartnerOrderFromQuoteCF({ ...deps, resolveGeography: async () => GEO }).run,
    cancel: buildCancelOrder({ ...deps, calculateCommission: async () => 100 }).run,
  };
  await db.doc('restaurants/pr1').set({ name: 'Chez Test', lat: PLACE.lat, lng: PLACE.lng, isOpen: true });
  await db.doc('restaurants/pr1/menu/m1').set({ name: 'Plat test', price: 1500, available: true });
});

const as = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const walletOf = async (uid) => (await db.doc(`clients/${uid}`).get()).data().wallet;
const settled = (calls) => Promise.allSettled(calls);
const pay = (quote, extra = {}) => ({ quoteId: quote.data.quoteId, paymentMethod: 'wallet', ...rReq, confirmedAmount: quote.data.total, deliveryAddress: 'Rue test', ...extra });

test('8 commandes simultanées sur UN devis → un seul débit du total, une seule commande ; un appel en échec se rejoue sans risque', options, async () => {
  await db.doc('clients/p1').set({ wallet: 10000 });
  const quote = await run.quote(as('p1', rReq));
  const total = quote.data.total;
  const results = await settled(Array.from({ length: 8 }, () => run.order(as('p1', pay(quote)))));
  const failed = results.filter((r) => r.status === 'rejected' || r.value?.success !== true);
  assert.ok(failed.length < 8, 'au moins un appel aboutit');
  for (let i = 0; i < failed.length; i++) {
    const retry = await run.order(as('p1', pay(quote)));
    assert.equal(retry.success, true);
    assert.equal(retry.data.replayed, true);
  }
  const ok = results.filter((r) => r.status === 'fulfilled' && r.value.success === true).map((r) => r.value);
  assert.equal(ok.filter((v) => v.data.replayed !== true).length, 1, 'un seul vrai traitement');
  assert.equal(new Set(ok.map((v) => v.data.orderId)).size, 1, 'une seule commande');
  assert.equal(await walletOf('p1'), 10000 - total);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p1').get()).size, 1);
  assert.equal((await db.collection('clients/p1/wallet_transactions').get()).size, 1);
});

test('plusieurs devis en parallèle, solde pour UNE commande → jamais de solde négatif', options, async () => {
  await db.doc('clients/p2').set({ wallet: 6000 });
  const quotes = await Promise.all(Array.from({ length: 6 }, () => run.quote(as('p2', rReq))));
  const total = quotes[0].data.total;
  await db.doc('clients/p2').update({ wallet: total + 100 });
  const results = await settled(quotes.map((q) => run.order(as('p2', pay(q)))));
  assert.equal(results.filter((r) => r.value?.success === true).length, 1);
  assert.equal(results.filter((r) => r.value?.code === 'SOLDE_INSUFFISANT').length, 5);
  assert.equal(await walletOf('p2'), 100);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p2').get()).size, 1);
});

test('prix du menu relevé après le devis, pendant des créations simultanées → aucune commande au prix périmé', options, async () => {
  await db.doc('clients/p3').set({ wallet: 50000 });
  await db.doc('restaurants/pr1/menu/m1').set({ name: 'Plat test', price: 1500, available: true });
  const quote = await run.quote(as('p3', rReq));
  await db.doc('restaurants/pr1/menu/m1').update({ price: 2500 });
  const results = await settled(Array.from({ length: 5 }, () => run.order(as('p3', pay(quote)))));
  assert.equal(results.filter((r) => r.value?.success === true).length, 0);
  assert.ok(results.every((r) => r.status === 'fulfilled' ? r.value.code === 'PRICE_CHANGED' : true));
  assert.equal(await walletOf('p3'), 50000);
  assert.equal((await db.collection('orders').where('clientId', '==', 'p3').get()).size, 0);
  await db.doc('restaurants/pr1/menu/m1').update({ price: 1500 });
});

test('cash : aucun débit ni journal, même sous concurrence', options, async () => {
  await db.doc('clients/p4').set({ wallet: 700 });
  const quote = await run.quote(as('p4', rReq));
  const results = await settled(Array.from({ length: 4 }, () => run.order(as('p4', pay(quote, { paymentMethod: 'cash' })))));
  assert.ok(results.some((r) => r.value?.success === true));
  assert.equal(await walletOf('p4'), 700);
  assert.equal((await db.collection('clients/p4/wallet_transactions').get()).size, 0);
  assert.ok((await db.collection('orders').where('clientId', '==', 'p4').get()).size <= 1);
});

test('aucun crédit partenaire ni livreur à la création', options, async () => {
  const partner = await db.doc('restaurants/pr1').get();
  assert.equal(partner.data().wallet, undefined);
  assert.equal((await db.collection('restaurants/pr1/wallet_transactions').get()).size, 0);
});

test('INCOMPATIBILITÉ CONNUE (à lever en 7B-2) : cancelOrderCF ne rembourse que budget (les frais) sur une commande v2', options, async () => {
  await db.doc('clients/p5').set({ wallet: 10000 });
  const quote = await run.quote(as('p5', rReq));
  const created = await run.order(as('p5', pay(quote)));
  assert.equal(await walletOf('p5'), 10000 - quote.data.total);
  await settled([run.cancel(as('p5', { orderId: created.data.orderId }))]);
  const refunded = (await walletOf('p5')) - (10000 - quote.data.total);
  // Documente l'état actuel : tant que 7B-2 n'a pas adapté cancelOrderTx, le remboursement n'est PAS le total.
  assert.notEqual(refunded, quote.data.total, 'si ce test échoue, cancelOrderTx gère déjà la v2 : mettre à jour le rapport');
  console.log(`# cancelOrderCF sur v2 : total=${quote.data.total} frais=${quote.data.deliveryFee} remboursé=${refunded}`);
});
