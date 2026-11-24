'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAcceptOrder } = require('../driverAcceptance');
const { assertDriverRechargeAllowed, DRIVER_FIRST_RECHARGE_MIN } = require('../driverWalletPolicy');
const { calculateCommission } = require('../dispatch');

const { fakeDb, DELETE } = require('./fakeFirestore');
const { withSelfie, selfieUrlFor } = require('./selfieHelper');

const admin = {
  firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE } },
};

function setup({ order = {}, driver = {}, extra = {}, selfieExists } = {}) {
  const db = fakeDb({
    'orders/o1': { status: 'assigned', driverId: 'd1', budget: 500, description: 'Course test', ...order },
    'livreurs/d1': { wallet: 1000, isOnline: true, ...driver },
    ...extra,
  });
  const audits = [], limits = [];
  const run = withSelfie(buildAcceptOrder({
    db, admin, onCall: (handler) => ({ run: handler }), HttpsError,
    checkRateLimit: async (...a) => { limits.push(a); },
    logAudit: async (a) => { audits.push(a); },
    calculateCommission, selfieExists,
  }).run);
  const req = (data = { orderId: 'o1' }, uid = 'd1') => ({
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data,
  });
  return { db, run, req, audits, limits };
}

const wallet = (h, id = 'd1') => h.db.store.get(`livreurs/${id}`).wallet;
const ledger = (h) => [...h.db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));

test('commission 100 FCFA sous 1000 : prélevée une fois, tracée sur la commande', async () => {
  const h = setup({ order: { budget: 999 } });
  const result = await h.run(h.req());
  assert.deepEqual(result, { success: true, alreadyAccepted: false, commission: 100 });
  assert.equal(wallet(h), 900);
  const order = h.db.store.get('orders/o1');
  assert.equal(order.status, 'accepted');
  assert.equal(order.commissionAmount, 100);
  assert.equal(order.commissionPayerId, 'd1');
  assert.equal(order.commissionTxId, 'commission_o1_d1');
  assert.equal(order.commissionStatus, 'charged');
  assert.equal(h.db.store.get('livreurs/d1').isOnDelivery, true);
  assert.deepEqual(ledger(h), ['livreurs/d1/wallet_transactions/commission_o1_d1']);
  assert.equal(h.db.store.get(ledger(h)[0]).type, 'commission');
});

test('commission 200 FCFA à partir de 1000', async () => {
  for (const budget of [1000, 1500, 5000]) {
    const h = setup({ order: { budget } });
    assert.equal((await h.run(h.req())).commission, 200);
    assert.equal(wallet(h), 800);
  }
});

test('nouveau livreur avec portefeuille à 0 : refus CREDIT_INSUFFISANT, rien ne change', async () => {
  const h = setup({ driver: { wallet: 0 } });
  await assert.rejects(h.run(h.req()), (e) => e.code === 'failed-precondition' &&
    e.message === 'CREDIT_INSUFFISANT:0:100');
  assert.equal(wallet(h), 0);
  assert.equal(h.db.store.get('orders/o1').status, 'assigned');
  assert.equal(ledger(h).length, 0);
});

test('solde insuffisant pour 200 FCFA (150) refusé ; solde exact accepté jusqu’à 0', async () => {
  const low = setup({ order: { budget: 1000 }, driver: { wallet: 150 } });
  await assert.rejects(low.run(low.req()), (e) => e.message === 'CREDIT_INSUFFISANT:150:200');
  const exact = setup({ order: { budget: 1000 }, driver: { wallet: 200 } });
  await exact.run(exact.req());
  assert.equal(wallet(exact), 0);
});

test('rejeu (double tap) : succès sans second prélèvement ni second journal', async () => {
  const h = setup();
  await h.run(h.req());
  const again = await h.run(h.req());
  assert.equal(again.alreadyAccepted, true);
  assert.equal(wallet(h), 900);
  assert.equal(ledger(h).length, 1);
  assert.equal(h.audits.length, 1);
});

// Livreur sans photo de profil (supprimée, ou compte créé par un patron de flotte) : l'app envoie le selfie
// d'acceptation sans driverPhotoUrl. L'acceptation doit aboutir, avec une seule commission.
test('selfie sans photo de profil : accepté, un seul prélèvement, rejeu sans second débit', async () => {
  const h = setup({ order: { budget: 500 }, driver: { wallet: 5000 } });
  const data = { orderId: 'o1', acceptanceSelfieUrl: selfieUrlFor('o1', 'd1') };
  const result = await h.run(h.req(data));
  assert.deepEqual(result, { success: true, alreadyAccepted: false, commission: 100 });
  assert.equal(wallet(h), 4900);
  const order = h.db.store.get('orders/o1');
  assert.equal(order.status, 'accepted');
  assert.equal(order.driverAcceptanceSelfie, selfieUrlFor('o1', 'd1'));
  assert.equal('driverPhotoUrl' in order, false);
  const again = await h.run(h.req(data));
  assert.equal(again.alreadyAccepted, true);
  assert.equal(wallet(h), 4900);
  assert.equal(ledger(h).length, 1);
});

test('deux livreurs sur une diffusion : le second est refusé, un seul prélèvement', async () => {
  const h = setup({
    order: { status: 'broadcast', driverId: undefined, notifiedDriverIds: ['d1', 'd2'] },
    extra: { 'livreurs/d2': { wallet: 1000, isOnline: true } },
  });
  await h.run(h.req(undefined, 'd1'));
  await assert.rejects(h.run(h.req(undefined, 'd2')), (e) => e.code === 'failed-precondition');
  assert.equal(wallet(h, 'd2'), 1000);
  assert.equal(h.db.store.get('orders/o1').driverId, 'd1');
  assert.equal(h.db.store.get('orders/o1').commissionPayerId, 'd1');
});

test('diffusion : un livreur non notifié est refusé', async () => {
  const h = setup({
    order: { status: 'broadcast', driverId: undefined, notifiedDriverIds: ['d9'] },
  });
  await assert.rejects(h.run(h.req()), (e) => e.code === 'permission-denied');
  assert.equal(wallet(h), 1000);
});

test('commande assignée à un autre livreur : refusée', async () => {
  const h = setup({ order: { driverId: 'd2' } });
  await assert.rejects(h.run(h.req()), (e) => e.code === 'permission-denied');
  assert.equal(wallet(h), 1000);
});

test('suspendu, hors ligne ou déjà en course : refusé sans débit', async () => {
  for (const driver of [{ isSuspended: true }, { isOnline: false }, { isOnDelivery: true }]) {
    const h = setup({ driver });
    await assert.rejects(h.run(h.req()), (e) => e.code === 'failed-precondition');
    assert.equal(wallet(h), 1000);
  }
  const busy = setup({ extra: { 'orders/o2': { status: 'picked_up', driverId: 'd1', budget: 500 } } });
  await assert.rejects(busy.run(busy.req()), (e) => e.code === 'failed-precondition');
  assert.equal(wallet(busy), 1000);
});

test('statut non acceptable ou anonyme : refusé', async () => {
  for (const status of ['pending', 'accepted', 'picked_up', 'delivered', 'cancelled']) {
    const h = setup({ order: { status, driverId: 'd2' } });
    await assert.rejects(h.run(h.req()));
  }
  const h = setup();
  await assert.rejects(h.run({ auth: null, data: { orderId: 'o1' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(h.run({
    auth: { uid: 'd1', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: { orderId: 'o1' },
  }), (e) => e.code === 'unauthenticated');
  await assert.rejects(h.run(h.req({ orderId: '../x' })), (e) => e.code === 'invalid-argument');
});

test('le montant du portefeuille fourni par le client est ignoré', async () => {
  const h = setup({ driver: { wallet: 0 } });
  await assert.rejects(h.run(h.req({ orderId: 'o1', wallet: 99999, commission: 0 })),
    (e) => e.message.startsWith('CREDIT_INSUFFISANT'));
  assert.equal(wallet(h), 0);
});

// ── Politique de recharge livreur ───────────────────────────────────────────
function policyDb(credited) {
  const db = fakeDb({ 'livreurs/d1': { wallet: 0 } });
  if (credited) db.store.set('wallet_transactions/t1', { userId: 'd1', credited: true });
  db.store.set('wallet_transactions/t2', { userId: 'd1', credited: false, status: 'pending' });
  return db;
}

test('première recharge livreur < 1000 : refusée ; = 1000 : autorisée', async () => {
  assert.equal(DRIVER_FIRST_RECHARGE_MIN, 1000);
  await assert.rejects(assertDriverRechargeAllowed({ db: policyDb(false), uid: 'd1', amount: 999, HttpsError }),
    (e) => e.code === 'invalid-argument');
  await assertDriverRechargeAllowed({ db: policyDb(false), uid: 'd1', amount: 1000, HttpsError });
});

test('une demande en attente ne compte pas comme recharge : le minimum s’applique encore', async () => {
  await assert.rejects(assertDriverRechargeAllowed({ db: policyDb(false), uid: 'd1', amount: 500, HttpsError }),
    (e) => e.code === 'invalid-argument');
});

test('après une recharge créditée, les recharges suivantes ne sont plus limitées à 1000', async () => {
  await assertDriverRechargeAllowed({ db: policyDb(true), uid: 'd1', amount: 100, HttpsError });
});

test('compte livreur inexistant : recharge livreur refusée', async () => {
  await assert.rejects(assertDriverRechargeAllowed({ db: fakeDb(), uid: 'x', amount: 5000, HttpsError }),
    (e) => e.code === 'failed-precondition');
});

test('suppression de compte consentie ou demandée : acceptation refusée sans débit', async () => {
  const consent = setup({ extra: { 'account_deletions/d1': { consentVerified: true } } });
  await assert.rejects(consent.run(consent.req()), (e) => e.code === 'failed-precondition');
  assert.equal(wallet(consent), 1000);
  const requested = setup({ driver: { deletionRequested: true } });
  await assert.rejects(requested.run(requested.req()), (e) => e.code === 'failed-precondition');
  const notVerified = setup({ extra: { 'account_deletions/d1': { consentVerified: false } } });
  await notVerified.run(notVerified.req());
  assert.equal(wallet(notVerified), 900);
});

// ── Selfie obligatoire côté serveur (non contournable par un appel direct) ─────────────────────────────
const refused = async (h, data, uid = 'd1') => {
  await assert.rejects(() => h.run(h.req(data, uid)),
    (e) => e.code === 'failed-precondition' && e.message === 'SELFIE_REQUIRED');
  // Refus total : aucun débit, aucune écriture, la commande reste disponible.
  assert.equal(wallet(h), 1000);
  assert.equal(ledger(h).length, 0);
  assert.equal(h.db.store.get('orders/o1').status, 'assigned');
};

test('selfie absent : acceptation refusée, aucun prélèvement', async () => {
  const h = setup();
  await refused(h, { orderId: 'o1', acceptanceSelfieUrl: undefined });
  await refused(h, { orderId: 'o1', acceptanceSelfieUrl: null });
  await refused(h, { orderId: 'o1', acceptanceSelfieUrl: '' });
  await refused(h, { orderId: 'o1' , acceptanceSelfieUrl: undefined, driverPhotoUrl: 'https://x/photo.jpg' });
});

test('selfie invalide : autre commande, autre livreur, URL quelconque, préfixe trompeur', async () => {
  const h = setup();
  for (const url of [
    selfieUrlFor('o2', 'd1'),
    selfieUrlFor('o1', 'd2'),
    'https://storage.example/selfie.jpg',
    selfieUrlFor('o1', 'd1').replace('.jpg', '.jpg.evil'),
    selfieUrlFor('o1', 'd1').replace('d1', 'xd1'),
    '%E0%A4%A',
  ]) await refused(h, { orderId: 'o1', acceptanceSelfieUrl: url });
});

test('selfie déclaré mais absent de Storage : refusé', async () => {
  const checked = [];
  const h = setup({ selfieExists: async (p) => { checked.push(p); return false; } });
  await refused(h, { orderId: 'o1', acceptanceSelfieUrl: selfieUrlFor('o1', 'd1') });
  assert.deepEqual(checked, ['acceptance_selfies/o1/d1.jpg']);
});

test('selfie présent dans Storage : accepté, une seule commission', async () => {
  const h = setup({ selfieExists: async (p) => p === 'acceptance_selfies/o1/d1.jpg' });
  assert.equal((await h.run(h.req())).commission, 100);
  assert.equal(wallet(h), 900);
  assert.equal(ledger(h).length, 1);
});

test('rejeu après acceptation sans photo : succès sans second prélèvement', async () => {
  const h = setup();
  await h.run(h.req());
  const replay = await h.run(h.req({ orderId: 'o1', acceptanceSelfieUrl: undefined }));
  assert.equal(replay.alreadyAccepted, true);
  assert.equal(wallet(h), 900);
  assert.equal(ledger(h).length, 1);
});
