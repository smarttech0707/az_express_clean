'use strict';

// Concurrence RÉELLE (émulateur Firestore) de l'outil de litige.
//   npx firebase emulators:exec --only firestore --project az-billing-test \
//     "node --test functions/test/adminOrderDisputes.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let dispute; let cancel; let confirm; let driverDeliver;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-billing-test' });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildAdminOrderDispute } = require('../adminOrderDisputes');
  const { buildCancelOrder } = require('../orderActions');
  const { calculateCommission } = require('../dispatch');
  const oc = (...a) => ({ run: a[a.length - 1] });
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  dispute = buildAdminOrderDispute({
    ...common, onCall: oc, calculateCommission,
    requireAdminPermission: async () => ({}),
    requireSuperAdmin: async ({ request }) => {
      if (request.auth.uid !== 'rootDisp') throw new HttpsError('permission-denied', 'non');
    },
  }).run;
  cancel = buildCancelOrder({ ...common, onCall: oc, calculateCommission }).run;
  const { buildDeliverOrder } = require('../orderActions');
  const { requireSuperAdmin } = require('../adminGuards');
  await db.doc('admins/rootDisp').set({ role: 'super', isActive: true });
  confirm = buildDeliverOrder({ ...common, onCall: oc, adminConfirm: true, requireSuperAdmin }).run;
  driverDeliver = buildDeliverOrder({ ...common, onCall: oc }).run;
});

const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const wallet = async (p) => (await db.doc(p).get()).data().wallet;
const seed = async (oid) => {
  await db.doc(`orders/${oid}`).set({
    clientId: 'cDisp', driverId: 'dDisp', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
    budget: 1000, shoppingBudget: 2000, pickedUpAt: 1, commissionStatus: 'charged', commissionPayerId: 'dDisp', commissionAmount: 200,
    cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'cDisp', requestedAtMs: 1 },
  });
  await db.doc('clients/cDisp').set({ wallet: 7000 });
  await db.doc('livreurs/dDisp').set({ wallet: 800, isOnDelivery: true, currentOrderId: oid });
};
const decide = (n, oid, decision = 'exceptionalCancel') => dispute(req('rootDisp', {
  action: 'decide', orderId: oid, decision, requestId: `req-${n}-${oid}-0000000000`, justification: 'Litige test émulateur', shoppingContext: 'not_purchased',
}));

test('émulateur : cinq décisions simultanées + deux annulations client → un seul remboursement', options, async () => {
  const oid = `disp_${Date.now()}_a`;
  await seed(oid);
  const results = await Promise.allSettled([
    decide(1, oid), decide(2, oid), decide(3, oid), decide(4, oid), decide(5, oid),
    cancel(req('cDisp', { orderId: oid })), cancel(req('cDisp', { orderId: oid })),
  ]);
  assert.equal(results.slice(0, 5).filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results[5].status, 'rejected');
  assert.equal(results[6].status, 'rejected');
  assert.equal(await wallet('clients/cDisp'), 7000 + 3000);
  assert.equal(await wallet('livreurs/dDisp'), 800 + 200);
  assert.equal((await db.doc(`orders/${oid}`).get()).data().status, 'cancelled');
});

test('émulateur : même requestId rejoué en parallèle → un seul effet', options, async () => {
  const oid = `disp_${Date.now()}_b`;
  await seed(oid);
  const results = await Promise.allSettled([decide(1, oid), decide(1, oid), decide(1, oid)]);
  assert.ok(results.every((r) => r.status === 'fulfilled'));
  assert.equal(await wallet('clients/cDisp'), 10000);
  assert.equal(await wallet('livreurs/dDisp'), 1000);
});

test('émulateur : remboursements A, B, C, D simultanés → une seule décision, argent conservé', options, async () => {
  const oid = `disp_${Date.now()}_c`;
  await seed(oid);
  const results = await Promise.allSettled([
    decide(1, oid, 'refundShopping'), decide(2, oid, 'refundFee'), decide(3, oid, 'refundHalfFee'), decide(4, oid, 'exceptionalCancel'),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const delta = (await wallet('clients/cDisp')) + (await wallet('livreurs/dDisp')) - 7800;
  assert.ok(delta === 3000 || delta === 3200, `delta ${delta}`);
});

test('émulateur : livraison du livreur + confirmations administratives simultanées → un seul crédit', options, async () => {
  const oid = `disp_${Date.now()}_d`;
  await seed(oid);
  const ask = (n) => confirm(req('rootDisp', {
    orderId: oid, requestId: `conf-${n}-${oid}-0000000000`, justification: 'Livraison constatée par appel', evidence: 'phone_verified',
  }));
  const results = await Promise.allSettled([
    driverDeliver(req('dDisp', { orderId: oid })), ask(1), ask(2), driverDeliver(req('dDisp', { orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(await wallet('livreurs/dDisp'), 800 + 3000);
  assert.equal(await wallet('clients/cDisp'), 7000);
});

const seedWith = async (oid, orderExtra) => {
  await seed(oid);
  await db.doc(`orders/${oid}`).set(orderExtra, { merge: true });
};
const decideX = (n, oid, decision, extra) => dispute(req('rootDisp', {
  action: 'decide', orderId: oid, decision, requestId: `req-${n}-${oid}-0000000000`, justification: 'Litige test émulateur', ...extra,
}));
const flagsOf = async (oid, kind) => (await db.collection('reconciliation_flags').where('orderId', '==', oid).get()).docs
  .filter((d) => d.id.startsWith(`${oid}_${kind}`));

test('émulateur : B/C sur achat dépensé avec avance du livreur, décisions simultanées → une seule, client + livreur = payé', options, async () => {
  const oid = `disp_${Date.now()}_e`;
  await seed(oid);
  const extra = { shoppingContext: 'purchased_delivered', advancedBy: 'driver_own_funds' };
  const results = await Promise.allSettled([
    decideX(1, oid, 'refundFee', extra), decideX(2, oid, 'refundHalfFee', extra), decideX(3, oid, 'refundFee', extra),
    cancel(req('cDisp', { orderId: oid })),
  ]);
  assert.equal(results.slice(0, 3).filter((r) => r.status === 'fulfilled' && !r.value.replay).length, 1);
  assert.equal(results[3].status, 'rejected');
  const delta = (await wallet('clients/cDisp')) + (await wallet('livreurs/dDisp')) - 7800;
  assert.equal(delta, 3000);
  const o = (await db.doc(`orders/${oid}`).get()).data();
  assert.equal(o.disputeDecision.driverReimbursement, 2000);
  assert.equal((await flagsOf(oid, 'driver_advance')).length, 0, 'B/C remboursent l’avance : rien à signaler');
});

test('émulateur : A/D sur achat dépensé → avance signalée une seule fois, jamais compensée', options, async () => {
  const oid = `disp_${Date.now()}_f`;
  await seed(oid);
  const extra = {
    shoppingContext: 'purchased_unreturned', advancedBy: 'driver_own_funds', justifiedSpentRefund: true,
    justification: 'Le client n’a jamais reçu les produits achetés, preuve par appel enregistré et photo du livreur.',
  };
  const results = await Promise.allSettled([
    decideX(1, oid, 'refundShopping', extra), decideX(2, oid, 'exceptionalCancel', extra), decideX(3, oid, 'refundShopping', extra),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled' && !r.value.replay).length, 1);
  const flags = await flagsOf(oid, 'driver_advance');
  assert.equal(flags.length, 1);
  assert.deepEqual([flags[0].data().amount, flags[0].data().status], [2000, 'open']);
  const delta = (await wallet('clients/cDisp')) + (await wallet('livreurs/dDisp')) - 7800;
  assert.ok(delta === 3000 || delta === 3200, `delta ${delta}`);
});

test('émulateur : commission non tracée → aucun crédit livreur, un signalement, annulations simultanées', options, async () => {
  const oid = `disp_${Date.now()}_g`;
  await seedWith(oid, {
    commissionStatus: admin.firestore.FieldValue.delete(), commissionPayerId: admin.firestore.FieldValue.delete(),
    commissionAmount: admin.firestore.FieldValue.delete(),
  });
  const results = await Promise.allSettled([
    decide(1, oid), decide(2, oid), cancel(req('cDisp', { orderId: oid })), decide(1, oid),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled' && !r.value?.replay).length, 1);
  assert.equal(await wallet('clients/cDisp'), 10000);
  assert.equal(await wallet('livreurs/dDisp'), 800, 'aucune commission jamais prouvée n’est rendue');
  assert.equal((await flagsOf(oid, 'commission_untraced')).length, 1);
});

test('émulateur : commission non tracée MAIS prouvée par la transaction de wallet → rendue une seule fois, montant prélevé', options, async () => {
  const oid = `disp_${Date.now()}_h`;
  const del = admin.firestore.FieldValue.delete();
  await seedWith(oid, { commissionStatus: del, commissionPayerId: del, commissionAmount: del });
  await db.doc(`livreurs/dDisp/wallet_transactions/commission_${oid}_dDisp`).set({ type: 'commission', amount: 150, orderId: oid });
  const results = await Promise.allSettled([
    decide(1, oid), decide(2, oid), decide(1, oid), cancel(req('cDisp', { orderId: oid })), cancel(req('cDisp', { orderId: oid })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled' && !r.value?.replay).length, 1);
  assert.equal(await wallet('clients/cDisp'), 10000);
  assert.equal(await wallet('livreurs/dDisp'), 800 + 150, 'montant prouvé (150), pas le barème (200), une seule fois');
  assert.equal((await flagsOf(oid, 'commission_untraced')).length, 0);
});
