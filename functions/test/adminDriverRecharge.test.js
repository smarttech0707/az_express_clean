'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAdminDriverRecharge, DEFAULT_MAX_PER_OPERATION } = require('../adminDriverRecharge');
const { requireAdminPermission } = require('../adminGuards');
const { fakeDb } = require('./fakeFirestore');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts' } } };
const KEY = 'a1b2c3d4e5f6a7b8c9d0';

function setup({ seed = {}, adminDoc = { isActive: true, role: 'super' } } = {}) {
  const db = fakeDb({
    'admins/adm1': adminDoc,
    'livreurs/d1': { wallet: 1000, name: 'Livreur' },
    ...seed,
  });
  const audits = [], limits = [];
  const run = buildAdminDriverRecharge({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async (...a) => { limits.push(a); },
    logAudit: async (a) => { audits.push(a); },
    requireAdminPermission,
  }).run;
  const req = (data, uid = 'adm1', provider = 'password') => ({
    auth: uid ? { uid, token: { firebase: { sign_in_provider: provider } } } : undefined,
    data: { driverId: 'd1', amount: 10000, idempotencyKey: KEY, ...data },
  });
  return { db, run, req, audits, limits };
}
const wallet = (h) => h.db.store.get('livreurs/d1').wallet;
const ledger = (h) => [...h.db.store.keys()].filter((k) => k.startsWith('livreurs/d1/wallet_transactions/'));
const refuses = async (h, request, code) => {
  await assert.rejects(() => h.run(request), (e) => e.code === code);
  assert.equal(wallet(h), 1000);
  assert.equal(ledger(h).length, 0);
  assert.equal(h.audits.length, 0);
};

test('recharge valide : solde, registre (admin, clé) et audit écrits ensemble', async () => {
  const h = setup();
  const res = await h.run(h.req({ note: 'Remise espèces 12/10' }));
  assert.equal(res.success, true);
  assert.equal(res.code, 'OK');
  assert.equal(res.data.newBalance, 11000);
  assert.equal(res.data.alreadyDone, false);
  assert.equal(wallet(h), 11000);
  assert.deepEqual(ledger(h), [`livreurs/d1/wallet_transactions/recharge_${KEY}`]);
  const entry = h.db.store.get(ledger(h)[0]);
  assert.equal(entry.type, 'recharge');
  assert.equal(entry.amount, 10000);
  assert.equal(entry.adminId, 'adm1');
  assert.equal(entry.source, 'admin_cash');
  assert.equal(entry.description, 'Remise espèces 12/10');
  assert.equal(h.audits.length, 1);
  assert.equal(h.audits[0].action, 'admin_driver_recharge');
  assert.equal(h.audits[0].amount, 10000);
  assert.equal(h.audits[0].metadata.balanceBefore, 1000);
  assert.equal(h.audits[0].metadata.balanceAfter, 11000);
  assert.deepEqual(h.limits[0], ['adm1', 'admin_driver_recharge', 30, 60]);
});

test('double appui / rejeu avec la même clé : un seul crédit, un seul audit', async () => {
  const h = setup();
  await h.run(h.req());
  const again = await h.run(h.req());
  assert.equal(again.data.alreadyDone, true);
  assert.equal(again.data.newBalance, 11000);
  assert.equal(wallet(h), 11000);
  assert.equal(ledger(h).length, 1);
  assert.equal(h.audits.length, 1);
  // Appels simultanés (même clé) : toujours un seul crédit.
  const h2 = setup();
  await Promise.allSettled([h2.run(h2.req()), h2.run(h2.req()), h2.run(h2.req())]);
  assert.equal(wallet(h2), 11000);
  assert.equal(ledger(h2).length, 1);
});

test('même clé avec un autre montant : refusé, aucun crédit supplémentaire', async () => {
  const h = setup();
  await h.run(h.req());
  await assert.rejects(() => h.run(h.req({ amount: 20000 })), (e) => e.code === 'already-exists');
  assert.equal(wallet(h), 11000);
});

test('deux confirmations distinctes = deux recharges volontaires', async () => {
  const h = setup();
  await h.run(h.req());
  await h.run(h.req({ idempotencyKey: 'ffffffffffffffffffff' }));
  assert.equal(wallet(h), 21000);
  assert.equal(ledger(h).length, 2);
});

test('plafond par défaut 50 000 FCFA : 50 000 accepté, 50 001 refusé', async () => {
  assert.equal(DEFAULT_MAX_PER_OPERATION, 50000);
  const h = setup();
  await refuses(h, h.req({ amount: 50001 }), 'invalid-argument');
  assert.equal((await h.run(h.req({ amount: 50000 }))).data.newBalance, 51000);
});

test('plafond configurable : config/driver_recharge.maxPerOperation', async () => {
  const h = setup({ seed: { 'config/driver_recharge': { maxPerOperation: 20000 } } });
  await refuses(h, h.req({ amount: 20001 }), 'invalid-argument');
  assert.equal((await h.run(h.req({ amount: 20000 }))).data.newBalance, 21000);
  // Configuration invalide : retombe sur 50 000, jamais sans plafond.
  for (const bad of [0, -5, 'abc', 1e12, 12.5, null]) {
    const hb = setup({ seed: { 'config/driver_recharge': { maxPerOperation: bad } } });
    await refuses(hb, hb.req({ amount: 50001 }), 'invalid-argument');
  }
});

test('montants invalides refusés', async () => {
  for (const amount of [0, -100, 10.5, '5000', null, undefined, NaN, Infinity, Number.MAX_SAFE_INTEGER + 2]) {
    const h = setup();
    await refuses(h, h.req({ amount }), 'invalid-argument');
  }
});

test('clé de confirmation absente ou invalide refusée', async () => {
  for (const idempotencyKey of [undefined, '', 'court', 'a'.repeat(65), 'avec espace 12345678', '../xxxxxxxxxxxxxxxxx']) {
    const h = setup();
    await refuses(h, h.req({ idempotencyKey }), 'invalid-argument');
  }
});

test('livreur invalide ou introuvable', async () => {
  for (const driverId of [undefined, '', 'a/b', 'x'.repeat(129), 42]) {
    const h = setup();
    await refuses(h, h.req({ driverId }), 'invalid-argument');
  }
  const h = setup();
  await refuses(h, h.req({ driverId: 'inconnu' }), 'not-found');
  assert.equal(h.db.store.has('livreurs/inconnu'), false);
});

test('autorisation : non connecté, anonyme, non-admin, admin désactivé, sous-admin sans permission', async () => {
  let h = setup();
  await refuses(h, h.req({}, null), 'unauthenticated');
  await refuses(h, h.req({}, 'adm1', 'anonymous'), 'unauthenticated');
  await refuses(h, h.req({}, 'd1'), 'permission-denied'); // le livreur lui-même
  await refuses(h, h.req({}, 'client9'), 'permission-denied');
  h = setup({ adminDoc: { isActive: false, role: 'super' } });
  await refuses(h, h.req(), 'permission-denied');
  h = setup({ adminDoc: { isActive: true, role: 'sub', permissions: ['restaurants'] } });
  await refuses(h, h.req(), 'permission-denied');
  h = setup({ adminDoc: { isActive: true, role: 'sub', permissions: ['recharges'] } });
  assert.equal((await h.run(h.req())).data.newBalance, 11000);
});

test('solde livreur corrompu : refus, aucune écriture', async () => {
  for (const bad of [-5, 12.5, 'abc']) {
    const h = setup({ seed: { 'livreurs/d1': { wallet: bad } } });
    await assert.rejects(() => h.run(h.req()), (e) => e.code === 'failed-precondition');
    assert.equal(ledger(h).length, 0);
  }
});

test('note : tronquée à 140 caractères, libellé par défaut sinon', async () => {
  const h = setup();
  await h.run(h.req({ note: 'x'.repeat(300) }));
  assert.equal(h.db.store.get(ledger(h)[0]).description.length, 140);
  const h2 = setup();
  await h2.run(h2.req({ note: '   ' }));
  assert.match(h2.db.store.get(ledger(h2)[0]).description, /espèces/);
  const h3 = setup();
  await assert.rejects(() => h3.run(h3.req({ note: 'x'.repeat(501) })), (e) => e.code === 'invalid-argument');
});

test('livreur en cours de suppression ou supprimé : recharge refusée, aucun crédit ; un rejeu déjà enregistré reste inchangé', async () => {
  for (const seed of [
    { 'livreurs/d1': { wallet: 1000, deletionRequested: true } },
    { 'livreurs/d1': { wallet: 1000, isDeleted: true } },
    { 'account_tombstones/d1': { state: 'deleting' } },
  ]) {
    const h = setup({ seed });
    await refuses(h, h.req(), 'failed-precondition');
  }
  const h = setup();
  await h.run(h.req());
  h.db.store.set('livreurs/d1', { ...h.db.store.get('livreurs/d1'), deletionRequested: true });
  const again = await h.run(h.req());
  assert.equal(again.data.alreadyDone, true);
  assert.equal(wallet(h), 11000);
});
