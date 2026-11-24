'use strict';

// L3.1 point 3 — AUDIT (constats figés, aucun comportement modifié) : un acteur appelant SANS profil et SANS tombstone ne peut contourner
// ni l'identité, ni la propriété, ni le solde. Ces tests décrivent l'état actuel ; une anomalie d'intégrité documentée (cancelOrderCF,
// journal de remboursement sans crédit) est figée telle quelle en attendant la décision du rapport L3.1.
const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE } = require('./fakeFirestore');
const { buildPayOrderFromWallet, buildCancelOrder, buildDeliverOrder } = require('../orderActions');
const { buildEkClientConfirmOrder } = require('../ekbineOrders');

const ts = (ms) => ({ toMillis: () => ms });
const admin = { firestore: { Timestamp: { fromMillis: ts }, FieldValue: { serverTimestamp: () => 'ts', increment: (n) => ({ __increment: n }), delete: () => DELETE } } };
const base = { admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
const snap = (db) => JSON.stringify([...db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
const ekAuth = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });

test('pay : client sans profil -> jamais débité (solde nul refusé ; montant nul : écriture sur document absent refusée), aucune écriture', async () => {
  for (const budget of [500, 0]) {
    const db = fakeDb({ 'orders/o1': { clientId: 'c1', driverId: 'd1', budget, isPaid: false, status: 'accepted' }, 'livreurs/d1': { wallet: 0 } });
    const before = snap(db);
    await assert.rejects(() => buildPayOrderFromWallet({ db, onCall, ...base }).run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }));
    assert.equal(snap(db), before);
  }
});

test('identité et propriété : un appelant sans profil qui n’est pas le propriétaire est refusé par les cinq fonctions, sans écriture', async () => {
  const cases = [
    [{ 'orders/o1': { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false } }, (db) => buildPayOrderFromWallet({ db, onCall, ...base }), { uid: 'x' }],
    [{ 'orders/o1': { clientId: 'c1', status: 'pending' } }, (db) => buildCancelOrder({ db, onCall, ...base, calculateCommission: async () => 1 }), { uid: 'x' }],
    [{ 'orders/o1': { driverId: 'd1', status: 'accepted' } }, (db) => buildDeliverOrder({ db, onCall, ...base }), { uid: 'x' }],
    [{ 'ekbine_orders/o1': { clientId: 'c1', status: 'proof_sent' } }, (db) => buildEkClientConfirmOrder({ db, onCall: (h) => ({ run: h }), ...base }), ekAuth('x')],
  ];
  for (const [seed, build, auth] of cases) {
    const db = fakeDb(seed);
    const before = snap(db);
    await assert.rejects(() => build(db).run({ auth, data: { orderId: 'o1' } }), (e) => e.code === 'permission-denied');
    assert.equal(snap(db), before);
  }
});

test('deliver : livreur lié sans profil -> refusé (écriture sur document absent), aucune écriture ; jamais crédité', async () => {
  const db = fakeDb({ 'orders/o1': { clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: true } });
  const before = snap(db);
  await assert.rejects(() => buildDeliverOrder({ db, onCall, ...base }).run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } }));
  assert.equal(snap(db), before);
});

test('ek : client propriétaire sans profil -> la confirmation aboutit comme avant (propriété + débit prouvé sur la commande), agent crédité du montant prouvé', async () => {
  const db = fakeDb({
    'ekbine_orders/o1': { clientId: 'c1', agentId: 'a1', status: 'proof_sent', paymentMethod: 'wallet', amount: 1000, walletDebited: true, debitedAmount: 1000 },
    'ekbine_agents/a1': { walletBalance: 0 },
  });
  const res = await buildEkClientConfirmOrder({ db, onCall: (h) => ({ run: h }), ...base }).run({ auth: ekAuth('c1'), data: { orderId: 'o1' } });
  assert.equal(res.credited, 1000);
  assert.equal(db.store.get('ekbine_agents/a1').walletBalance, 1000);
});

test('CONSTAT cancel : client propriétaire sans profil -> annulation faite, aucun crédit possible, mais un journal « refund » est écrit (anomalie d’intégrité, pas un contournement)', async () => {
  const db = fakeDb({ 'orders/o1': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', isPaid: true, budget: 1000 } });
  const res = await buildCancelOrder({ db, onCall, ...base, calculateCommission: async () => 100 }).run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.deepEqual(res, { success: true });
  assert.equal(db.store.get('orders/o1').status, 'cancelled');
  assert.equal(db.store.has('clients/c1'), false, 'aucun profil créé : aucun solde crédité');
  const journal = [...db.store.entries()].filter(([k]) => k.startsWith('clients/c1/wallet_transactions/'));
  assert.equal(journal.length, 1);
  assert.equal(journal[0][1].type, 'refund');
});
