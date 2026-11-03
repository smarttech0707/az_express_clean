'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildEkCreateOrder, buildEkCancelOrder, buildEkClientConfirmOrder, orderIdFor } = require('../ekbineOrders');
const { fakeDb } = require('./fakeFirestore');

const inc = (n) => ({ __inc: n });
const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', increment: (n) => inc(n) } } };
const auth = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const KEY = 'key-aaaaaaaaaaaaaaaa';
const base = { idempotencyKey: KEY, operator: 'orange', serviceId: 'credit', serviceLabel: 'Crédit Orange', amount: 1000, beneficiaryNumber: '0700000000', paymentMethod: 'wallet' };

function setup(seed = {}) {
  const db = fakeDb({
    'clients/c1': { wallet: 5000, name: 'Client' },
    'clients/c2': { wallet: 5000 },
    'ekbine_agents/a1': { walletBalance: 0, totalCompleted: 0 },
    ...seed,
  });
  const audits = [];
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); } };
  return { db, audits, create: buildEkCreateOrder(deps).run, cancel: buildEkCancelOrder(deps).run, confirm: buildEkClientConfirmOrder(deps).run };
}
const call = (data, a = auth('c1')) => ({ auth: a, data });
const get = (h, p) => h.db.store.get(p);
const keys = (h, prefix) => [...h.db.store.keys()].filter((k) => k.startsWith(prefix));
const oid = (uid = 'c1', key = KEY) => orderIdFor(uid, key);

test('création wallet : un débit, une commande, preuve et montants calculés serveur', async () => {
  const h = setup();
  // Le client tente d'imposer frais, gain agent, statut : ignorés.
  const res = await h.create(call({ ...base, fee: 500, agentEarning: 99999, status: 'completed', totalPaid: 1 }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  const o = get(h, `ekbine_orders/${oid()}`);
  assert.deepEqual([o.fee, o.totalPaid, o.agentEarning, o.status, o.walletDebited, o.debitedAmount], [0, 1000, 1000, 'pending', true, 1000]);
  const proof = get(h, `clients/c1/wallet_transactions/ekorder_${oid()}`);
  assert.deepEqual([proof.type, proof.amount], ['payment', -1000]);
  assert.equal(h.audits.length, 1);
});

test('création : double appel même clé → un seul débit, rejeu alreadyDone', async () => {
  const h = setup();
  await h.create(call(base));
  const again = await h.create(call(base));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal(keys(h, 'ekbine_orders/').length, 1);
});

test('création : même clé, contenu différent → refus, aucun second débit', async () => {
  const h = setup();
  await h.create(call(base));
  const res = await h.create(call({ ...base, amount: 2000 }));
  assert.equal(res.code, 'IDEMPOTENCY_CONFLICT');
  assert.equal(get(h, 'clients/c1').wallet, 4000);
});

test('création : la clé d\'un autre client ne rejoue pas sa commande', async () => {
  const h = setup();
  await h.create(call(base));
  const res = await h.create(call(base, auth('c2')));
  assert.equal(res.success, true);
  assert.notEqual(oid('c1'), oid('c2'));
  assert.equal(get(h, 'clients/c2').wallet, 4000);
});

test('création : solde insuffisant → refus, aucune commande, solde intact', async () => {
  const h = setup({ 'clients/c1': { wallet: 500 } });
  const res = await h.create(call(base));
  assert.equal(res.code, 'INSUFFICIENT_BALANCE');
  assert.equal(get(h, 'clients/c1').wallet, 500);
  assert.equal(keys(h, 'ekbine_orders/').length, 0);
});

test('création : montants/services manipulés refusés', async () => {
  const h = setup();
  for (const bad of [{ amount: 50 }, { amount: 99.5 }, { amount: -1000 }, { amount: '1000' }, { amount: 2000000 },
    { serviceId: 'inconnu' }, { operator: 'bidule' }, { paymentMethod: 'bitcoin' }, { idempotencyKey: 'court' },
    { beneficiaryNumber: '123' }, { serviceId: 'mix', operator: 'mtn' }, { amount: 150, serviceId: 'mix' }]) {
    await assert.rejects(() => h.create(call({ ...base, ...bad })), (e) => e.code === 'invalid-argument', JSON.stringify(bad));
  }
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(keys(h, 'ekbine_orders/').length, 0);
});

test('création : non connecté / anonyme / compte absent / en suppression', async () => {
  const h = setup({ 'clients/c3': { wallet: 5000, deletionRequested: true } });
  await assert.rejects(() => h.create({ data: base }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => h.create(call(base, auth('c1', 'anonymous'))), (e) => e.code === 'unauthenticated');
  assert.equal((await h.create(call(base, auth('fantome')))).code, 'ACCOUNT_NOT_FOUND');
  await assert.rejects(() => h.create(call(base, auth('c3'))), (e) => e.code === 'failed-precondition');
});

test('création hors wallet : aucune écriture de wallet, aucun gain agent prévu', async () => {
  const h = setup();
  const res = await h.create(call({ ...base, paymentMethod: 'orange_money' }));
  assert.equal(res.data.walletDebited, false);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  const o = get(h, `ekbine_orders/${oid()}`);
  assert.deepEqual([o.agentEarning, o.debitedAmount, o.walletDebited], [0, 0, false]);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/').length, 0);
});

test('annulation : remboursement du montant débité, une seule fois, statut posé', async () => {
  const h = setup();
  await h.create(call(base));
  const id = oid();
  const res = await h.cancel(call({ orderId: id, reason: 'erreur' }));
  assert.equal(res.data.refunded, 1000);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, `ekbine_orders/${id}`).status, 'cancelled');
  const again = await h.cancel(call({ orderId: id }));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/ekrefund_').length, 1);
});

test('annulation : propriétaire exigé ; commande déjà exécutée refusée sans remboursement', async () => {
  const h = setup();
  await h.create(call(base));
  const id = oid();
  await assert.rejects(() => h.cancel(call({ orderId: id }, auth('c2'))), (e) => e.code === 'permission-denied');
  for (const st of ['deposit_proof_sent', 'deposit_confirmed', 'in_progress', 'proof_sent', 'completed', 'disputed']) {
    h.db.store.set(`ekbine_orders/${id}`, { ...get(h, `ekbine_orders/${id}`), status: st });
    const res = await h.cancel(call({ orderId: id }));
    assert.equal(res.code, 'ORDER_NOT_CANCELLABLE', st);
  }
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal((await h.cancel(call({ orderId: 'absent' }))).code, 'ORDER_NOT_FOUND');
});

test('annulation : jamais remboursé sur déclaration — commande sans preuve de débit → aucun crédit + revue', async () => {
  const h = setup({ 'ekbine_orders/legacy': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', amount: 1000, totalPaid: 1000, agentEarning: 1000 } });
  const res = await h.cancel(call({ orderId: 'legacy' }));
  assert.equal(res.success, true);
  assert.equal(res.data.refunded, 0);
  assert.equal(res.data.reviewRequired, true);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, 'reconciliation_flags/ekcancel_legacy').status, 'open');
});

test('annulation : commande hors wallet → aucun remboursement', async () => {
  const h = setup();
  await h.create(call({ ...base, paymentMethod: 'wave' }));
  const res = await h.cancel(call({ orderId: oid() }));
  assert.equal(res.data.refunded, 0);
  assert.equal(res.data.reviewRequired, false);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
});

const ready = (extra = {}) => ({
  clientId: 'c1', agentId: 'a1', status: 'proof_sent', paymentMethod: 'wallet', amount: 1000,
  walletDebited: true, debitedAmount: 1000, agentEarning: 1000, ...extra,
});

test('confirmation : crédite le montant PROUVÉ, une seule fois', async () => {
  const h = setup({ 'ekbine_orders/o1': ready({ agentEarning: 999999 }) });
  const res = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(res.credited, 1000);
  assert.equal(res.settlement, 'wallet_credit');
  assert.deepEqual(get(h, 'ekbine_agents/a1').walletBalance, inc(1000));
  assert.equal(get(h, 'ekbine_orders/o1').status, 'completed');
  const again = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(again.alreadyDone, true);
  await assert.rejects(() => Promise.resolve(h.confirm(call({ orderId: 'o1' }, auth('c2')))), (e) => e.code === 'permission-denied');
});

test('confirmation : agentEarning manipulé, sans preuve de débit → aucun crédit agent + signalement', async () => {
  const h = setup({ 'ekbine_orders/o2': ready({ walletDebited: undefined, debitedAmount: undefined, agentEarning: 50000 }) });
  const res = await h.confirm(call({ orderId: 'o2' }));
  assert.equal(res.credited, 0);
  assert.equal(res.reviewRequired, true);
  assert.equal(res.settlement, 'withheld_unproven');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal(get(h, 'reconciliation_flags/ekconfirm_o2').status, 'open');
});

test('confirmation : montant débité différent du montant commande ou commande remboursée → aucun crédit', async () => {
  const h = setup({
    'ekbine_orders/o3': ready({ debitedAmount: 100 }),
    'ekbine_orders/o4': ready({ refunded: true }),
  });
  assert.equal((await h.confirm(call({ orderId: 'o3' }))).credited, 0);
  assert.equal((await h.confirm(call({ orderId: 'o4' }))).credited, 0);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});

test('confirmation hors wallet : terminée sans aucun crédit (AZ ne détient pas les fonds)', async () => {
  const h = setup({ 'ekbine_orders/o5': ready({ paymentMethod: 'orange_money', agentEarning: 0, walletDebited: false, debitedAmount: 0 }) });
  const res = await h.confirm(call({ orderId: 'o5' }));
  assert.equal(res.success, true);
  assert.equal(res.credited, 0);
  assert.equal(res.reviewRequired, false);
  assert.equal(res.settlement, 'declarative_no_credit');
  assert.equal(get(h, 'ekbine_orders/o5').creditReason, 'non_wallet');
  assert.equal(get(h, 'ekbine_orders/o5').status, 'completed');
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/').length, 0);
});

test('confirmation : annulée ou mauvais statut refusée', async () => {
  const h = setup({ 'ekbine_orders/o6': ready({ status: 'cancelled' }), 'ekbine_orders/o7': ready({ status: 'in_progress' }) });
  for (const id of ['o6', 'o7']) {
    await assert.rejects(() => Promise.resolve(h.confirm(call({ orderId: id }))), (e) => e.code === 'failed-precondition');
  }
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});
