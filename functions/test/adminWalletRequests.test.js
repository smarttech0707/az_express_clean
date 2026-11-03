'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAdminApproveRecharge, buildAdminApproveWithdrawal, MAX_RECHARGE_REQUEST } = require('../adminWalletRequests');
const { fakeDb } = require('./fakeFirestore');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts' } } };
const auth = (uid = 'adm1', provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });

function setup(seed = {}) {
  const db = fakeDb({
    'admins/adm1': { isActive: true, role: 'super' },
    'admins/sub1': { isActive: true, role: 'sub', permissions: ['recharges'] },
    'clients/c1': { wallet: 1000, name: 'Client' },
    'livreurs/d1': { wallet: 50 },
    'recharge_requests/r1': { userId: 'c1', userType: 'client', amount: 5000, method: 'wave', status: 'pending' },
    'withdrawal_requests/w1': { userId: 'c1', userType: 'client', amount: 2000, status: 'pending_manual' },
    ...seed,
  });
  const audits = [];
  const deps = {
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); },
  };
  return {
    db, audits,
    recharge: buildAdminApproveRecharge(deps).run,
    withdraw: buildAdminApproveWithdrawal(deps).run,
  };
}
const call = (data, a = auth()) => ({ auth: a, data });
const get = (h, p) => h.db.store.get(p);
const ledger = (h, base) => [...h.db.store.keys()].filter((k) => k.startsWith(`${base}/wallet_transactions/`));

// ── Recharge ──────────────────────────────────────────────────────────────

test('recharge : crédite le montant STOCKÉ, écrit la preuve déterministe, l\'état et l\'audit', async () => {
  const h = setup();
  // L'appel (écran admin) tente d'imposer un autre montant et une autre cible : ignorés.
  const res = await h.recharge(call({ requestId: 'r1', amount: 999999, userId: 'd1', userType: 'driver' }));
  assert.equal(res.success, true);
  assert.equal(res.data.amount, 5000);
  assert.equal(get(h, 'clients/c1').wallet, 6000);
  assert.equal(get(h, 'livreurs/d1').wallet, 50);
  assert.deepEqual(ledger(h, 'clients/c1'), ['clients/c1/wallet_transactions/recharge_request_r1']);
  const proof = get(h, 'clients/c1/wallet_transactions/recharge_request_r1');
  assert.deepEqual([proof.type, proof.amount, proof.requestId, proof.adminId], ['recharge', 5000, 'r1', 'adm1']);
  const req = get(h, 'recharge_requests/r1');
  assert.deepEqual([req.status, req.approvedBy, req.creditedAmount], ['approved', 'adm1', 5000]);
  assert.equal(h.audits.length, 1);
  assert.equal(h.audits[0].metadata.balanceAfter, 6000);
});

test('recharge approuvée DEUX fois : un seul crédit, le rejeu renvoie alreadyDone', async () => {
  const h = setup();
  await h.recharge(call({ requestId: 'r1' }));
  const again = await h.recharge(call({ requestId: 'r1' }));
  assert.equal(again.success, true);
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 6000);
  assert.equal(ledger(h, 'clients/c1').length, 1);
  assert.equal(h.audits.length, 1);
});

test('recharge REJETÉE puis approuvée : refusée, aucun crédit', async () => {
  const h = setup({ 'recharge_requests/r1': { userId: 'c1', userType: 'client', amount: 5000, status: 'rejected' } });
  const res = await h.recharge(call({ requestId: 'r1' }));
  assert.equal(res.success, false);
  assert.equal(res.code, 'REQUEST_NOT_PENDING');
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(ledger(h, 'clients/c1').length, 0);
});

test('recharge : une ligne de journal forgée au même identifiant ne bloque pas le crédit légitime', async () => {
  const h = setup({ 'clients/c1/wallet_transactions/recharge_request_r1': { type: 'recharge', amount: 1 } });
  const res = await h.recharge(call({ requestId: 'r1' }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'clients/c1').wallet, 6000);
  assert.equal(get(h, 'clients/c1/wallet_transactions/recharge_request_r1').amount, 5000);
});

test('recharge : sous-admin, anonyme et non connecté refusés', async () => {
  const h = setup();
  await assert.rejects(() => h.recharge(call({ requestId: 'r1' }, auth('sub1'))), (e) => e.code === 'permission-denied');
  await assert.rejects(() => h.recharge(call({ requestId: 'r1' }, auth('adm1', 'anonymous'))), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => h.recharge({ data: { requestId: 'r1' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => h.recharge(call({ requestId: 'r1' }, auth('inconnu'))), (e) => e.code === 'permission-denied');
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(get(h, 'recharge_requests/r1').status, 'pending');
});

test('recharge : identifiant invalide, demande absente, type inconnu, compte absent, montant hors limites', async () => {
  const h = setup({
    'recharge_requests/rt': { userId: 'c1', userType: 'admin', amount: 500, status: 'pending' },
    'recharge_requests/rg': { userId: 'fantome', userType: 'client', amount: 500, status: 'pending' },
    'recharge_requests/rh': { userId: 'c1', userType: 'client', amount: MAX_RECHARGE_REQUEST + 1, status: 'pending' },
    'recharge_requests/rb': { userId: 'c1', userType: 'client', amount: 50.5, status: 'pending' },
  });
  await assert.rejects(() => h.recharge(call({ requestId: 'a/b' })), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => h.recharge(call({})), (e) => e.code === 'invalid-argument');
  for (const [id, code] of [['absent', 'REQUEST_NOT_FOUND'], ['rt', 'USER_TYPE_UNSUPPORTED'], ['rg', 'ACCOUNT_NOT_FOUND'],
    ['rh', 'AMOUNT_TOO_HIGH'], ['rb', 'AMOUNT_INVALID']]) {
    const res = await h.recharge(call({ requestId: id }));
    assert.deepEqual([res.success, res.code], [false, code], id);
  }
  assert.equal(get(h, 'clients/c1').wallet, 1000);
});

test('recharge : compte en cours de suppression non crédité', async () => {
  const h = setup({ 'clients/c1': { wallet: 1000, deletionRequested: true } });
  await assert.rejects(() => h.recharge(call({ requestId: 'r1' })), (e) => e.code === 'failed-precondition');
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(get(h, 'recharge_requests/r1').status, 'pending');
});

test('recharge livreur : crédite le portefeuille du livreur de la demande', async () => {
  const h = setup({ 'recharge_requests/rd': { userId: 'd1', userType: 'driver', amount: 2000, method: 'orange', status: 'pending' } });
  const res = await h.recharge(call({ requestId: 'rd' }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'livreurs/d1').wallet, 2050);
});

// ── Retrait ───────────────────────────────────────────────────────────────

test('retrait pending_manual : marqué traité SANS toucher au portefeuille (déjà débité à la création)', async () => {
  const h = setup();
  const res = await h.withdraw(call({ requestId: 'w1' }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(ledger(h, 'clients/c1').length, 0);
  const w = get(h, 'withdrawal_requests/w1');
  assert.deepEqual([w.status, w.processedBy, w.settlementConfirmed], ['processed', 'adm1', true]);
  assert.equal(h.audits[0].metadata.walletUntouched, true);
});

test('retrait approuvé DEUX fois : aucun second effet', async () => {
  const h = setup();
  await h.withdraw(call({ requestId: 'w1' }));
  const again = await h.withdraw(call({ requestId: 'w1' }));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(h.audits.length, 1);
});

test('retrait déjà remboursé / échoué / en traitement : jamais déclaré payé', async () => {
  const h = setup({
    'withdrawal_requests/wr': { userId: 'c1', amount: 2000, status: 'pending_manual', refunded: true },
    'withdrawal_requests/wf': { userId: 'c1', amount: 2000, status: 'failed' },
    'withdrawal_requests/wp': { userId: 'c1', amount: 2000, status: 'processing' },
  });
  for (const id of ['wr', 'wf', 'wp']) {
    const res = await h.withdraw(call({ requestId: id }));
    assert.deepEqual([res.success, res.code], [false, 'REQUEST_NOT_PENDING'], id);
    assert.notEqual(get(h, `withdrawal_requests/${id}`).status, 'processed');
  }
});

test('retrait : sous-admin et demande absente refusés', async () => {
  const h = setup();
  await assert.rejects(() => h.withdraw(call({ requestId: 'w1' }, auth('sub1'))), (e) => e.code === 'permission-denied');
  assert.equal((await h.withdraw(call({ requestId: 'absent' }))).code, 'REQUEST_NOT_FOUND');
  assert.equal(get(h, 'withdrawal_requests/w1').status, 'pending_manual');
});

test('recharge : demande ancienne forme (clientId, sans userType) créditée au client, une seule fois', async () => {
  const h = setup({ 'recharge_requests/rc': { clientId: 'c1', amount: 1200, method: 'wave', status: 'pending' } });
  const res = await h.recharge(call({ requestId: 'rc' }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'clients/c1').wallet, 2200);
  assert.equal((await h.recharge(call({ requestId: 'rc' }))).data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 2200);
});
