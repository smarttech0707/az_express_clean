'use strict';

// Mission 7E-72 : E-Kbine face à la quarantaine de suppression de compte (tombstone).
//  - ekClientConfirmOrder : l'agent bénéficiaire est relu dans la transaction ; jamais de crédit sur un agent en fermeture.
//  - ekCreateOrderCF : un client en quarantaine ne crée plus de commande, avec ou sans débit wallet.
// Faux Firestore (aucune concurrence réelle) : voir ekbineOrders.test.js pour les chemins nominaux.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildEkCreateOrder, buildEkClientConfirmOrder, orderIdFor } = require('../ekbineOrders');
const { fakeDb } = require('./fakeFirestore');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', increment: (n) => ({ __inc: n }) } } };
const auth = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const call = (data, uid = 'c1') => ({ auth: auth(uid), data });
const KEY = 'key-aaaaaaaaaaaaaaaa';
const base = { idempotencyKey: KEY, operator: 'orange', serviceId: 'credit', serviceLabel: 'Crédit', amount: 1000, beneficiaryNumber: '0700000000', paymentMethod: 'wallet' };
const ready = (extra = {}) => ({
  clientId: 'c1', agentId: 'a1', status: 'proof_sent', paymentMethod: 'wallet', amount: 1000,
  walletDebited: true, debitedAmount: 1000, agentEarning: 1000, ...extra,
});

function setup(seed = {}) {
  const db = fakeDb({
    'clients/c1': { wallet: 5000, name: 'Client' },
    'ekbine_agents/a1': { walletBalance: 0, totalCompleted: 0, name: 'Agent' },
    ...seed,
  });
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  return { db, create: buildEkCreateOrder(deps).run, confirm: buildEkClientConfirmOrder(deps).run };
}
const get = (h, p) => h.db.store.get(p);
const ekOrders = (h) => [...h.db.store.keys()].filter((k) => k.startsWith('ekbine_orders/'));
const tomb = { createdAt: 'ts', state: 'deleting' };

// Fait échouer la lecture d'un document précis dans les transactions (les autres lectures sont inchangées).
function failReads(h, prefix) {
  const run = h.db.runTransaction;
  h.db.runTransaction = (cb) => run((tx) => cb({ ...tx, get: async (t) => { if (String(t.path).startsWith(prefix)) throw new Error('unavailable'); return tx.get(t); } }));
}

// ── ekClientConfirmOrder ────────────────────────────────────────────────────
test('confirmation : agent normal, tombstone absent → crédité une fois (comportement inchangé)', async () => {
  const h = setup({ 'ekbine_orders/o1': ready() });
  const res = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(res.credited, 1000);
  assert.deepEqual(get(h, 'ekbine_agents/a1').walletBalance, { __inc: 1000 });
  assert.equal(get(h, 'ekbine_orders/o1').status, 'completed');
});

test('confirmation : agent en quarantaine (tombstone) → refus, aucun crédit, commande inchangée', async () => {
  const h = setup({ 'ekbine_orders/o1': ready(), 'account_tombstones/a1': tomb });
  await assert.rejects(() => h.confirm(call({ orderId: 'o1' })), (e) => e.code === 'failed-precondition');
  assert.equal(get(h, 'ekbine_orders/o1').status, 'proof_sent');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal([...h.db.store.keys()].filter((k) => k.startsWith('audit_logs/')).length, 0);
});

test('confirmation : profil agent anonymisé ou deletionRequested → refus, aucun crédit', async () => {
  for (const flag of [{ isDeleted: true }, { deletionRequested: true }]) {
    const h = setup({ 'ekbine_orders/o1': ready(), 'ekbine_agents/a1': { walletBalance: 0, ...flag } });
    await assert.rejects(() => h.confirm(call({ orderId: 'o1' })), (e) => e.code === 'failed-precondition');
    assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
    assert.equal(get(h, 'ekbine_orders/o1').status, 'proof_sent');
  }
});

test('confirmation : lecture du tombstone en erreur → échec sûr (fail-closed), aucun crédit', async () => {
  const h = setup({ 'ekbine_orders/o1': ready() });
  failReads(h, 'account_tombstones/');
  await assert.rejects(() => h.confirm(call({ orderId: 'o1' })), /unavailable/);
  assert.equal(get(h, 'ekbine_orders/o1').status, 'proof_sent');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});

test('confirmation : quarantaine posée entre la lecture de la commande et le point d\'écriture → refus', async () => {
  const h = setup({ 'ekbine_orders/o1': ready() });
  const run = h.db.runTransaction;
  h.db.runTransaction = (cb) => run((tx) => cb({
    ...tx,
    get: async (t) => {
      const snap = await tx.get(t);
      if (String(t.path) === 'ekbine_orders/o1') h.db.store.set('account_tombstones/a1', tomb); // course concurrente
      return snap;
    },
  }));
  await assert.rejects(() => h.confirm(call({ orderId: 'o1' })), (e) => e.code === 'failed-precondition');
  assert.equal(get(h, 'ekbine_orders/o1').status, 'proof_sent');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});

test('confirmation : double confirmation → un seul crédit ; rejeu après quarantaine de l\'agent → alreadyDone sans écriture', async () => {
  const h = setup({ 'ekbine_orders/o1': ready() });
  assert.equal((await h.confirm(call({ orderId: 'o1' }))).alreadyDone, false);
  h.db.store.set('account_tombstones/a1', tomb);
  const again = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(again.alreadyDone, true);
  assert.equal(again.credited, 0);
  assert.deepEqual(get(h, 'ekbine_agents/a1').walletBalance, { __inc: 1000 });
});

test('confirmation : commande déjà terminée ou annulée, agent en quarantaine → comportement existant inchangé', async () => {
  const h = setup({
    'ekbine_orders/done': ready({ status: 'completed', agentCredited: 1000 }),
    'ekbine_orders/canc': ready({ status: 'cancelled' }),
    'account_tombstones/a1': tomb,
  });
  assert.equal((await h.confirm(call({ orderId: 'done' }))).alreadyDone, true);
  await assert.rejects(() => h.confirm(call({ orderId: 'canc' })), (e) => e.code === 'failed-precondition' && /Statut/.test(e.message));
});

test('confirmation : le client appelant en quarantaine peut clôturer une commande déjà engagée (aucune nouvelle activité)', async () => {
  // L3 / X-2 : « déjà engagée » est désormais prouvée (assignedAt antérieur au tombstone, journal du débit, client sans autre rôle).
  const ts = (ms) => ({ toMillis: () => ms });
  const h = setup({
    'ekbine_orders/o1': ready({ assignedAt: ts(1000), debitLedgerId: 'ekorder_o1' }),
    'clients/c1/wallet_transactions/ekorder_o1': { type: 'payment', amount: -1000, orderId: 'o1', source: 'ekbine_order' },
    'account_tombstones/c1': { ...tomb, createdAt: ts(2000) },
  });
  const res = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(res.credited, 1000);
});

// ── ekCreateOrderCF ─────────────────────────────────────────────────────────
test('création : client en quarantaine → refus pour wallet comme hors wallet, aucune commande, aucun débit', async () => {
  for (const paymentMethod of ['wallet', 'orange_money', 'cash']) {
    const h = setup({ 'account_tombstones/c1': tomb });
    await assert.rejects(() => h.create(call({ ...base, paymentMethod })), (e) => e.code === 'failed-precondition');
    assert.equal(ekOrders(h).length, 0);
    assert.equal(get(h, 'clients/c1').wallet, 5000);
  }
});

test('création : lecture du tombstone en erreur → échec sûr, aucun débit, aucune commande', async () => {
  const h = setup();
  failReads(h, 'account_tombstones/');
  await assert.rejects(() => h.create(call(base)), /unavailable/);
  assert.equal(ekOrders(h).length, 0);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
});

test('création : client sans tombstone → inchangé ; rejeu de la même clé après quarantaine → alreadyDone, aucun second débit', async () => {
  const h = setup();
  assert.equal((await h.create(call(base))).data.alreadyDone, false);
  h.db.store.set('account_tombstones/c1', tomb);
  const again = await h.create(call(base));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal(ekOrders(h).length, 1);
  assert.ok(get(h, `ekbine_orders/${orderIdFor('c1', KEY)}`));
});
