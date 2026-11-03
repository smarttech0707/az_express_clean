'use strict';

// Phase A (F2/F3/F4) — intégration contre l'émulateur Firestore (jamais la production) : la concurrence RÉELLE
// des transactions, que le faux Firestore ne simule pas. Appels simultanés (double appui, deux administrateurs,
// reprise réseau) : un seul effet financier. Données fictives uniquement.
//   firebase emulators:exec --only firestore --project demo-az-financial \
//     "node --test functions/test/financialConcurrency.emulator.test.js"
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
  const { buildAdminApproveRecharge, buildAdminApproveWithdrawal } = require('../adminWalletRequests');
  const { buildCancelOrder } = require('../orderActions');
  const deps = {
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
  };
  run = {
    recharge: buildAdminApproveRecharge(deps).run,
    withdraw: buildAdminApproveWithdrawal(deps).run,
    cancel: buildCancelOrder({ ...deps, calculateCommission: async () => 100 }).run,
  };
});

const as = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const wallet = async (path) => (await db.doc(path).get()).data().wallet;
const settled = async (calls) => Promise.allSettled(calls);
const ok = (results) => results.filter((r) => r.status === 'fulfilled' && r.value.success !== false);

test('recharge : 8 approbations simultanées → un seul crédit, une seule preuve', options, async () => {
  await db.doc('admins/root').set({ role: 'super', isActive: true });
  await db.doc('clients/c1').set({ wallet: 1000 });
  await db.doc('recharge_requests/r1').set({ userId: 'c1', userType: 'client', amount: 5000, method: 'wave', status: 'pending' });
  const results = await settled(Array.from({ length: 8 }, () => run.recharge(as('root', { requestId: 'r1' }))));
  assert.equal(ok(results).length, 8, 'tous les appels aboutissent (rejeu = alreadyDone)');
  assert.equal(results.filter((r) => r.value?.data?.alreadyDone === false).length, 1, 'un seul crédit réel');
  assert.equal(await wallet('clients/c1'), 6000);
  const proofs = await db.collection('clients/c1/wallet_transactions').get();
  assert.equal(proofs.size, 1);
  assert.equal((await db.doc('recharge_requests/r1').get()).data().status, 'approved');
});

test('recharge rejetée pendant des approbations simultanées : jamais de crédit après le rejet', options, async () => {
  await db.doc('clients/c2').set({ wallet: 0 });
  await db.doc('recharge_requests/r2').set({ userId: 'c2', userType: 'client', amount: 700, method: 'wave', status: 'rejected' });
  const results = await settled(Array.from({ length: 4 }, () => run.recharge(as('root', { requestId: 'r2' }))));
  assert.equal(ok(results).length, 0);
  assert.equal(await wallet('clients/c2'), 0);
});

test('retrait : approbations simultanées → un seul passage en processed, portefeuille intact', options, async () => {
  await db.doc('clients/c3').set({ wallet: 1500 });
  await db.doc('withdrawal_requests/w1').set({ userId: 'c3', userType: 'client', amount: 2000, status: 'pending_manual' });
  const results = await settled(Array.from({ length: 6 }, () => run.withdraw(as('root', { requestId: 'w1' }))));
  assert.equal(results.filter((r) => r.value?.data?.alreadyDone === false).length, 1);
  assert.equal(await wallet('clients/c3'), 1500);
  assert.equal((await db.doc('withdrawal_requests/w1').get()).data().status, 'processed');
});

test('annulation : 6 appels simultanés sur une commande payée par wallet → remboursé une seule fois', options, async () => {
  await db.doc('clients/c4').set({ wallet: 0 });
  await db.doc('orders/o1').set({
    clientId: 'c4', status: 'pending', paymentMethod: 'wallet', isPaid: true, type: 'shopping',
    budget: 1000, shoppingBudget: 3000, tariffQuoteId: 'q1',
  });
  const results = await settled(Array.from({ length: 6 }, () => run.cancel(as('c4', { orderId: 'o1' }))));
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1, 'une seule annulation réussit');
  assert.equal(await wallet('clients/c4'), 4000);
  assert.equal((await db.doc('orders/o1').get()).data().status, 'cancelled');
  const refunds = (await db.collection('clients/c4/wallet_transactions').get()).docs.filter((d) => d.data().type === 'refund');
  assert.equal(refunds.length, 1);
});
