'use strict';

// Colis / Blanchisserie / Eau & Boissons — devis serveur contre l'émulateur Firestore (jamais la production) :
// concurrence RÉELLE des transactions et compatibilité avec cancelOrderCF. Données fictives uniquement.
//   firebase emulators:exec --only firestore --project demo-az-catalog \
//     "node --test functions/test/catalogConcurrency.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

let admin; let db; let run;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildQuoteCatalogCF, buildCreateCatalogOrderFromQuoteCF } = require('../catalogQuote');
  const { buildCancelOrder } = require('../orderActions');
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  run = {
    quote: buildQuoteCatalogCF(deps).run,
    order: buildCreateCatalogOrderFromQuoteCF(deps).run,
    cancel: buildCancelOrder({ ...deps, calculateCommission: async () => 100 }).run,
  };
});

const as = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const walletOf = async (uid) => (await db.doc(`clients/${uid}`).get()).data().wallet;
const settled = (calls) => Promise.allSettled(calls);
const colis = { service: 'colis', colisType: 'Colis standard', fragile: false };
const colisTexts = { recipientName: 'Kouassi', recipientPhone: '0700000000', recipientAddress: 'Quartier test' };
const pay = (quoteId, req, extra = {}) => ({ quoteId, paymentMethod: 'wallet', ...req, ...colisTexts, ...extra });

test('8 commandes simultanées sur UN devis → un seul débit, une seule commande ; un appel en échec se rejoue sans risque', options, async () => {
  await db.doc('clients/k1').set({ wallet: 5000 });
  const quote = await run.quote(as('k1', colis));
  const results = await settled(Array.from({ length: 8 }, () => run.order(as('k1', pay(quote.data.quoteId, colis)))));
  // Sous forte contention l'émulateur peut abandonner une transaction (erreur technique, aucun effet) : le client rejoue.
  const failed = results.filter((r) => r.status === 'rejected' || r.value?.success !== true);
  assert.ok(failed.length < 8, 'au moins un appel aboutit');
  for (let i = 0; i < failed.length; i++) {
    const retry = await run.order(as('k1', pay(quote.data.quoteId, colis)));
    assert.equal(retry.success, true);
    assert.equal(retry.data.replayed, true, 'le réessai retrouve la commande, sans nouveau traitement');
  }
  const ok = results.filter((r) => r.status === 'fulfilled' && r.value.success === true).map((r) => r.value);
  assert.equal(ok.filter((v) => v.data.replayed !== true).length, 1, 'un seul vrai traitement');
  assert.equal(new Set(ok.map((v) => v.data.orderId)).size, 1, 'une seule commande');
  assert.equal(await walletOf('k1'), 4500);
  assert.equal((await db.collection('orders').where('clientId', '==', 'k1').get()).size, 1);
  assert.equal((await db.collection('clients/k1/wallet_transactions').get()).size, 1);
});

test('plusieurs devis en parallèle, solde pour UNE commande → jamais de solde négatif', options, async () => {
  await db.doc('clients/k2').set({ wallet: 600 });
  const quotes = await Promise.all(Array.from({ length: 6 }, () => run.quote(as('k2', colis))));
  const results = await settled(quotes.map((q) => run.order(as('k2', pay(q.data.quoteId, colis)))));
  assert.equal(results.filter((r) => r.value?.success === true).length, 1);
  assert.equal(results.filter((r) => r.value?.code === 'SOLDE_INSUFFISANT').length, 5);
  assert.equal(await walletOf('k2'), 100);
  assert.equal((await db.collection('orders').where('clientId', '==', 'k2').get()).size, 1);
});

test('annulation : cancelOrderCF rembourse EXACTEMENT le débit du devis (colis, blanchisserie, eau), une seule fois', options, async () => {
  await db.doc('clients/k3').set({ wallet: 20000 });
  const cases = [
    [colis, colisTexts, 500],
    [{ service: 'blanchisserie', serviceType: 'Pressing', quantity: 4 }, { address: 'Rue test' }, 4000],
    [{ service: 'eau_boissons', items: [{ id: 'casier_eau', qty: 2 }, { id: 'eau_500', qty: 3 }] }, { address: 'Rue test' }, 500 + 7000 + 600],
  ];
  for (const [req, texts, total] of cases) {
    const before = await walletOf('k3');
    const quote = await run.quote(as('k3', req));
    assert.equal(quote.data.total, total);
    const created = await run.order(as('k3', { quoteId: quote.data.quoteId, paymentMethod: 'wallet', ...req, ...texts }));
    const orderId = created.data.orderId;
    assert.equal(await walletOf('k3'), before - total);
    const results = await settled(Array.from({ length: 4 }, () => run.cancel(as('k3', { orderId }))));
    assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1, 'une seule annulation aboutit');
    assert.equal(await walletOf('k3'), before, `${req.service} : remboursement exact`);
    assert.equal((await db.doc(`orders/${orderId}`).get()).data().status, 'cancelled');
  }
});

test('annulation d\'une commande en espèces ou historique (créée par l\'ancien écran) : comportement inchangé', options, async () => {
  await db.doc('clients/k4').set({ wallet: 700 });
  // Commande en espèces créée par le serveur : aucun remboursement.
  const quote = await run.quote(as('k4', colis));
  const cash = await run.order(as('k4', pay(quote.data.quoteId, colis, { paymentMethod: 'cash' })));
  await run.cancel(as('k4', { orderId: cash.data.orderId }));
  assert.equal(await walletOf('k4'), 700);
  // Commande historique (forme de l'écran actuel, créée par le client) payée par wallet : remboursement budget + shoppingBudget.
  await db.doc('orders/legacy-1').set({
    id: 'legacy-1', clientId: 'k4', status: 'pending', type: 'eau_boissons', paymentMethod: 'wallet', isPaid: true,
    budget: 500, shoppingBudget: 1500, latitude: 0, longitude: 0, items: [],
  });
  await run.cancel(as('k4', { orderId: 'legacy-1' }));
  assert.equal(await walletOf('k4'), 2700);
  // Une commande d'un autre client reste inaccessible.
  await db.doc('orders/legacy-2').set({ id: 'legacy-2', clientId: 'someone', status: 'pending', type: 'colis', paymentMethod: 'wallet', isPaid: true, budget: 500, shoppingBudget: 0 });
  await assert.rejects(() => run.cancel(as('k4', { orderId: 'legacy-2' })));
  assert.equal(await walletOf('k4'), 2700);
});

test('commande déjà récupérée par un livreur : annulation refusée, aucun remboursement', options, async () => {
  await db.doc('clients/k5').set({ wallet: 5000 });
  const quote = await run.quote(as('k5', colis));
  const created = await run.order(as('k5', pay(quote.data.quoteId, colis)));
  await db.doc(`orders/${created.data.orderId}`).update({ status: 'picked_up', driverId: 'd1', pickedUpAt: Date.now() });
  await db.doc('livreurs/d1').set({ wallet: 0 });
  await settled([run.cancel(as('k5', { orderId: created.data.orderId }))]);
  assert.equal(await walletOf('k5'), 4500, 'pas de remboursement après récupération');
  assert.equal((await db.doc(`orders/${created.data.orderId}`).get()).data().status, 'picked_up');
});

test('Document / Enveloppe 300 FCFA : débit 300, annulation = remboursement exact 300, commission 100 (palier < 1000)', options, async () => {
  const { calculateCommission } = require('../dispatch');
  const doc = { service: 'colis', colisType: 'Document / Enveloppe', fragile: false };
  await db.doc('clients/k6').set({ wallet: 1000 });
  const quote = await run.quote(as('k6', doc));
  assert.equal(quote.data.total, 300);
  const created = await run.order(as('k6', pay(quote.data.quoteId, doc)));
  assert.equal(await walletOf('k6'), 700);
  assert.equal(await calculateCommission(db, 300), 100, 'le livreur garde 200 FCFA sur 300');
  await run.cancel(as('k6', { orderId: created.data.orderId }));
  assert.equal(await walletOf('k6'), 1000);
});
