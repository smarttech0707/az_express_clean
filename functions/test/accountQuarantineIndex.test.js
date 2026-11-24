'use strict';

// Mission 7E-68 : garde de quarantaine des fonctions financières de functions/index.js, exécutées de bout en bout
// contre un faux Firestore en mémoire. AUCUN accès cloud : firebase-admin et axios sont remplacés AVANT le chargement de
// index.js (aucun SDK réel, aucun appel FeexPay, aucune donnée de production). Données entièrement synthétiques.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');

process.env.GCLOUD_PROJECT = 'demo-test';
process.env.FUNCTIONS_EMULATOR = 'true';
process.env.FEEXPAY_SHOP_ID = 'shop-test';
for (const k of ['FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'OPENAI_API_KEY', 'DELIVERY_PROOF_PEPPER']) {
  process.env[k] = 'test-only-not-a-secret';
}

const db = fakeDb();
const hooks = { reads: 0, fail: false, onFirstRead: null };
const baseCollection = db.collection;
// Interception des lectures de account_tombstones : erreur de lecture simulée et quarantaine apparaissant EN COURS d'appel.
db.collection = (name) => {
  const col = baseCollection(name);
  if (name !== 'account_tombstones') return col;
  return {
    ...col,
    doc: (id) => {
      const r = col.doc(id);
      return {
        ...r,
        get: async () => {
          hooks.reads += 1;
          if (hooks.fail) throw new Error('firestore unavailable');
          const snap = await r.get();
          if (hooks.onFirstRead && hooks.reads === 1) { const f = hooks.onFirstRead; hooks.onFirstRead = null; f(); }
          return snap;
        },
      };
    },
  };
};

const deep = (name = 'x') => new Proxy(function () {}, {
  get: (_t, p) => (p === 'then' ? undefined : deep(`${name}.${String(p)}`)),
  apply: () => deep(`${name}()`),
  construct: () => deep(`${name}#new`),
});
const ts = (ms) => ({ toMillis: () => ms, toDate: () => new Date(ms) });
const firestoreFn = Object.assign(() => db, {
  FieldValue: { serverTimestamp: () => ts(Date.now()), increment: (n) => ({ __increment: n }), delete: () => DELETE, arrayUnion },
  Timestamp: { fromMillis: ts, now: () => ts(Date.now()), fromDate: (d) => ts(d.getTime()) },
});
const adminStub = new Proxy(function () {}, {
  get: (_t, p) => (p === 'firestore' ? firestoreFn : p === 'initializeApp' ? () => {} : p === 'then' ? undefined : deep(`admin.${String(p)}`)),
});
const here = createRequire(require.resolve('../index.js'));
const calls = { axios: [] };
for (const [mod, exp] of [
  ['firebase-admin', adminStub],
  ['axios', { post: async (...a) => { calls.axios.push(a[0]); return { data: { token: 'tok', url: 'https://pay.example/x', reference: 'REF1' } }; }, get: async () => ({ data: {} }) }],
]) {
  const key = here.resolve(mod);
  require.cache[key] = { id: key, filename: key, loaded: true, exports: exp };
}
const fns = require('../index.js');

const phone = '+2250700000000';
const rechargeReq = (uid = 'u1', over = {}) => ({ auth: { uid, token: {} }, data: { amount: 1000, phone, operator: 'mtn', userType: 'client', ...over } });
const withdrawReq = (uid = 'u1', over = {}) => ({ auth: { uid, token: {} }, data: { amount: 500, phone, operator: 'mtn', userType: 'client', userName: 'Test', ...over } });
const docsOf = (prefix) => [...db.store.keys()].filter((k) => k.startsWith(`${prefix}/`) && !k.slice(prefix.length + 1).includes('/'));
const reset = (seed = {}) => {
  db.store.clear();
  hooks.reads = 0; hooks.fail = false; hooks.onFirstRead = null; calls.axios.length = 0;
  for (const [k, v] of Object.entries(seed)) db.store.set(k, v);
};
const rejectsWith = async (p, pattern) => assert.rejects(p, (e) => pattern.test(`${e.code} ${e.message}`));

// ── Recharge FeexPay ───────────────────────────────────────────────────────────────────────────────────────────────
test('recharge : un compte actif crée sa demande de paiement normalement', async () => {
  reset({ 'clients/u1': { wallet: 0 } });
  const r = await fns.initiateFeexPayPayment.run(rechargeReq());
  assert.ok(r.txId);
  assert.equal(docsOf('wallet_transactions').length, 1);
  assert.equal(db.store.get(`wallet_transactions/${r.txId}`).status, 'pending');
  assert.equal(calls.axios.length, 1);
});

test('recharge : compte en quarantaine refusé (garde d’entrée), aucune demande, aucun appel opérateur', async () => {
  reset({ 'clients/u1': { wallet: 0 }, 'account_tombstones/u1': { createdAt: ts(1), state: 'deleting' } });
  await rejectsWith(fns.initiateFeexPayPayment.run(rechargeReq()), /ACCOUNT_DELETION_IN_PROGRESS/);
  assert.equal(docsOf('wallet_transactions').length, 0);
  assert.equal(calls.axios.length, 0);
});

test('recharge : quarantaine posée APRÈS la garde d’entrée mais avant l’écriture → refus transactionnel', async () => {
  reset({ 'clients/u1': { wallet: 0 } });
  hooks.onFirstRead = () => db.store.set('account_tombstones/u1', { createdAt: ts(Date.now()), state: 'deleting' });
  await rejectsWith(fns.initiateFeexPayPayment.run(rechargeReq()), /suppression/i);
  assert.equal(docsOf('wallet_transactions').length, 0, 'aucune demande pending créée');
  assert.equal(calls.axios.length, 0);
});

test('recharge : profil anonymisé sans tombstone → refus ; erreur de lecture du tombstone → refus (fail-closed)', async () => {
  reset({ 'clients/u1': { wallet: 0, isDeleted: true } });
  await rejectsWith(fns.initiateFeexPayPayment.run(rechargeReq()), /suppression|supprime/i);
  assert.equal(docsOf('wallet_transactions').length, 0);
  reset({ 'clients/u1': { wallet: 0 } });
  hooks.fail = true;
  await assert.rejects(fns.initiateFeexPayPayment.run(rechargeReq()));
  assert.equal(docsOf('wallet_transactions').length, 0);
  assert.equal(calls.axios.length, 0);
});

test('recharge : le tombstone d’un autre compte ne bloque pas un compte non concerné', async () => {
  reset({ 'clients/u1': { wallet: 0 }, 'clients/u2': { wallet: 0 }, 'account_tombstones/u2': { createdAt: ts(1) } });
  const r = await fns.initiateFeexPayPayment.run(rechargeReq('u1'));
  assert.ok(r.txId);
});

// ── Retrait FeexPay ────────────────────────────────────────────────────────────────────────────────────────────────
test('retrait : un compte actif réserve ses fonds et crée la demande', async () => {
  reset({ 'clients/u1': { wallet: 5000 } });
  await fns.initiateWithdrawal.run(withdrawReq());
  const wds = docsOf('withdrawal_requests');
  assert.equal(wds.length, 1);
  assert.equal(db.store.get(wds[0]).userId, 'u1');
});

test('retrait : compte en quarantaine refusé, solde intact, aucune demande de retrait', async () => {
  reset({ 'clients/u1': { wallet: 5000 }, 'account_tombstones/u1': { createdAt: ts(1) } });
  await rejectsWith(fns.initiateWithdrawal.run(withdrawReq()), /ACCOUNT_DELETION_IN_PROGRESS/);
  assert.equal(db.store.get('clients/u1').wallet, 5000);
  assert.equal(docsOf('withdrawal_requests').length, 0);
  assert.equal(calls.axios.length, 0);
});

test('retrait : quarantaine posée entre la garde d’entrée et la transaction → aucun débit', async () => {
  reset({ 'clients/u1': { wallet: 5000 } });
  hooks.onFirstRead = () => db.store.set('account_tombstones/u1', { createdAt: ts(Date.now()), state: 'deleting' });
  await rejectsWith(fns.initiateWithdrawal.run(withdrawReq()), /suppression/i);
  assert.equal(db.store.get('clients/u1').wallet, 5000, 'aucun débit');
  assert.equal(docsOf('withdrawal_requests').length, 0);
  assert.equal(calls.axios.length, 0, 'aucun payout lancé');
});

test('retrait : profil anonymisé (jeton encore valide) et erreur de lecture → refus sans débit', async () => {
  reset({ 'clients/u1': { wallet: 5000, isDeleted: true } });
  await rejectsWith(fns.initiateWithdrawal.run(withdrawReq()), /suppression|supprime/i);
  assert.equal(db.store.get('clients/u1').wallet, 5000);
  reset({ 'clients/u1': { wallet: 5000 } });
  hooks.fail = true;
  await assert.rejects(fns.initiateWithdrawal.run(withdrawReq()));
  assert.equal(db.store.get('clients/u1').wallet, 5000);
  assert.equal(docsOf('withdrawal_requests').length, 0);
});

test('retrait : un compte non concerné par la quarantaine d’un autre n’est pas bloqué', async () => {
  reset({ 'clients/u1': { wallet: 5000 }, 'account_tombstones/u2': { createdAt: ts(1) } });
  await fns.initiateWithdrawal.run(withdrawReq('u1'));
  assert.equal(docsOf('withdrawal_requests').length, 1);
});

// ── Réconciliation d’un retrait déjà engagé : jamais bloquée par la quarantaine du webhook / du scheduler ────────────
test('le webhook FeexPay et les réconciliations planifiées ne sont pas enveloppés par la garde callable', () => {
  const src = require('node:fs').readFileSync(require.resolve('../index.js'), 'utf8');
  assert.match(src, /exports\.feexPayWebhook\s*=\s*onRequest\(/);
  // Le scheduler reçoit `onSchedule` (jamais le wrapper onCall) : la réconciliation des retraits engagés continue.
  assert.match(src, /exports\.checkPendingWithdrawals\s*=\s*buildPendingWithdrawalChecker\(\{\s*db, admin, onSchedule,/);
});
