'use strict';

// Confirmation ADMINISTRATIVE de livraison = deliverOrderCF en mode adminConfirm : même cœur
// financier, super-admin seul, jamais de seconde commission ni de double crédit.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildDeliverOrder } = require('../orderActions');
const { requireSuperAdmin } = require('../adminGuards');

const oc = (...a) => ({ run: a[a.length - 1] });
const REQ = (n) => `confirm-id-000000${n}`.padEnd(20, 'x');
const J = 'Livraison constatée après appel du client et du livreur';
const code = (c) => (e) => e.code === c;

function setup(orderExtra = {}, driverExtra = {}) {
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
      budget: 1000, shoppingBudget: 2000, pickedUpAt: 1,
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
      cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 },
      ...orderExtra,
    },
    'clients/c1': { wallet: 7000 },
    'livreurs/dA': { wallet: 800, isOnDelivery: true, currentOrderId: 'o1', ...driverExtra },
    'admins/root': { role: 'super', isActive: true },
    'admins/subOk': { role: 'sub', isActive: true, permissions: ['commandes'] },
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); } };
  const confirm = buildDeliverOrder({ ...common, onCall: oc, adminConfirm: true, requireSuperAdmin }).run;
  const driverDeliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const call = (uid, extra = {}) => confirm({
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    data: { orderId: 'o1', requestId: REQ(1), justification: J, evidence: 'client_confirmed', ...extra },
  });
  const order = () => db.store.get('orders/o1');
  const driver = () => db.store.get('livreurs/dA');
  const commissions = () => [...db.store.keys()].filter((k) => k.startsWith('commissions/'));
  const earnings = () => [...db.store.keys()].filter((k) => k.includes('wallet_transactions/'));
  return { db, call, driverDeliver, order, driver, commissions, earnings, audits };
}

test('confirmation par le super-admin : livrée, livreur crédité UNE fois (budget + achat), aucune seconde commission', async () => {
  const t = setup();
  const r = await t.call('root');
  assert.equal(r.success, true);
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.driver().wallet, 800 + 3000);
  assert.equal(t.order().commissionStatus, 'charged', 'la commission prélevée à l\'acceptation n\'est ni rendue ni reprélevée');
  assert.equal(t.order().adminDeliveryConfirmation.byUid, 'root');
  assert.equal(t.order().adminDeliveryConfirmation.evidence, 'client_confirmed');
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_delivery_confirmed');
  assert.equal(t.driver().isOnDelivery, false);
  assert.equal(t.earnings().length, 1);
  assert.equal(t.db.store.get('clients/c1').wallet, 7000, 'le client n\'est pas touché');
});

test('journal d’audit : acteur administrateur, preuve, justification, livreur concerné', async () => {
  const t = setup();
  await t.call('root');
  const a = t.audits.find((x) => x.action === 'admin_confirm_delivery');
  assert.deepEqual([a.userId, a.userType, a.targetId, a.amount], ['root', 'admin', 'o1', 3000]);
  assert.deepEqual([a.metadata.driverId, a.metadata.evidence, a.metadata.justification], ['dA', 'client_confirmed', J]);
});

test('idempotence : même requestId rejoué → aucun second crédit ; autre requestId → refusé', async () => {
  const t = setup();
  await t.call('root');
  const again = await t.call('root');
  assert.equal(again.replay, true);
  await assert.rejects(() => t.call('root', { requestId: REQ(2) }), code('failed-precondition'));
  assert.equal(t.driver().wallet, 3800);
  assert.equal(t.earnings().length, 1);
  assert.equal(t.audits.filter((a) => a.action === 'admin_confirm_delivery').length, 1);
});

test('concurrence : le livreur livre en même temps que l’administration confirme → un seul crédit', async () => {
  const t = setup();
  const results = await Promise.allSettled([
    t.driverDeliver({ auth: { uid: 'dA', token: {} }, data: { orderId: 'o1' } }),
    t.call('root'),
    t.call('root', { requestId: REQ(3) }),
    t.driverDeliver({ auth: { uid: 'dA', token: {} }, data: { orderId: 'o1' } }),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(t.driver().wallet, 3800);
  assert.equal(t.commissions().length, 1);
});

test('permissions : sous-admin (même `commandes`), client, livreur, anonyme → refusés, rien ne bouge', async () => {
  const t = setup();
  await assert.rejects(() => t.call('subOk'), code('permission-denied'));
  await assert.rejects(() => t.call('c1'), code('permission-denied'));
  await assert.rejects(() => t.call('dA'), code('permission-denied'));
  assert.equal(t.order().status, 'picked_up');
  assert.equal(t.driver().wallet, 800);
});

test('anonyme et non connecté refusés', async () => {
  const t = setup();
  const conf = buildDeliverOrder({
    db: t.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, onCall: oc, adminConfirm: true, requireSuperAdmin,
  }).run;
  await assert.rejects(() => conf({ data: { orderId: 'o1' } }), code('unauthenticated'));
  await assert.rejects(() => conf({
    auth: { uid: 'root', token: { firebase: { sign_in_provider: 'anonymous' } } },
    data: { orderId: 'o1', requestId: REQ(1), justification: J, evidence: 'client_confirmed' },
  }), code('unauthenticated'));
  assert.equal(t.order().status, 'picked_up');
});

test('justification, preuve et requestId obligatoires', async () => {
  const t = setup();
  await assert.rejects(() => t.call('root', { justification: 'court' }), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { evidence: undefined }), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { evidence: 'je_crois' }), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { requestId: 'x' }), code('invalid-argument'));
  assert.equal(t.order().status, 'picked_up');
  assert.equal(t.driver().wallet, 800);
});

test('statut vérifié : seule une commande récupérée est confirmable (accepted, pending, cancelled, delivered refusées)', async () => {
  for (const status of ['accepted', 'pending', 'cancelled', 'delivered']) {
    const t = setup({ status });
    await assert.rejects(() => t.call('root'), code('failed-precondition'), status);
    assert.equal(t.driver().wallet, 800);
  }
});

test('course transférée (gain à répartir) : refusée, règlement de transfert dédié', async () => {
  const t = setup({ settlementHold: true });
  await assert.rejects(() => t.call('root'), code('failed-precondition'));
  assert.equal(t.driver().wallet, 800);
});

test('commande sans livreur : refusée', async () => {
  const t = setup({ driverId: undefined });
  await assert.rejects(() => t.call('root'), code('failed-precondition'));
});

test('cash : livrée sans mouvement de wallet (le livreur garde les espèces), commission inchangée', async () => {
  const t = setup({ paymentMethod: 'cash', isPaid: false });
  await t.call('root');
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.driver().wallet, 800);
  assert.equal(t.order().commissionStatus, 'charged');
});

test('wallet non payé (pharmacie) : livrée, aucun crédit fictif au livreur', async () => {
  const t = setup({ isPaid: false });
  await t.call('root');
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.driver().wallet, 800);
});

test('la fonction est exportée, distincte de deliverOrderCF et ne modifie pas son comportement pour le livreur', async () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const idx = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(idx, /exports\.adminConfirmDeliveryCF = buildDeliverOrder\(\{[\s\S]*?adminConfirm: true, requireSuperAdmin/);
  assert.match(idx, /exports\.deliverOrderCF\s+= buildDeliverOrder\(\{ db, admin, onCall/);
  // Le livreur ne peut pas utiliser le mode administrateur en passant des champs : le mode est fixé à la fabrication.
  const t = setup();
  await assert.rejects(() => t.driverDeliver({ auth: { uid: 'dB', token: {} }, data: { orderId: 'o1', adminConfirm: true, requestId: REQ(1), justification: J, evidence: 'client_confirmed' } }), code('permission-denied'));
  assert.equal(t.order().status, 'picked_up');
});
