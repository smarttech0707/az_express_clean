'use strict';

// Outil administratif de litige après récupération (livraisons ordinaires).
// Faux Firestore sérialisé pour la concurrence (modèle de la garantie Firestore).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildAdminOrderDispute, paidFromWallet } = require('../adminOrderDisputes');
const { buildCancelOrder } = require('../orderActions');
const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');
const { calculateCommission } = require('../dispatch');

const oc = (...a) => ({ run: a[a.length - 1] });
const REQ = (n) => `request-id-0000000${n}`.slice(0, 24).padEnd(20, 'x');
const J = 'Litige constaté après appel du client';

function setup(orderExtra = {}, seedExtra = {}) {
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
      budget: 1000, shoppingBudget: 2000, pickedUpAt: 1,
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
      cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 },
      ...orderExtra,
    },
    'clients/c1': { wallet: 7000, name: 'Aya' },
    'livreurs/dA': { wallet: 800, name: 'Kone' },
    'admins/root': { role: 'super', isActive: true },
    'admins/subOk': { role: 'sub', isActive: true, permissions: ['commandes'] },
    'admins/subNo': { role: 'sub', isActive: true, permissions: ['restaurants'] },
    ...seedExtra,
  });
  // Transactions sérialisées (une transaction en conflit est rejouée sur l'état à jour).
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const fn = buildAdminOrderDispute({
    db, admin, onCall: oc, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); },
    requireAdminPermission, requireSuperAdmin, calculateCommission,
  }).run;
  const call = (uid, data) => fn({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const decide = (uid, decision, n = 1, extra = {}) => call(uid, {
    action: 'decide', orderId: 'o1', decision, requestId: REQ(n), justification: J, shoppingContext: 'not_purchased', ...extra,
  });
  const order = () => db.store.get('orders/o1');
  const money = () => [db.store.get('clients/c1').wallet, db.store.get('livreurs/dA').wallet];
  const walletTx = () => [...db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));
  return { db, call, decide, order, money, audits, walletTx };
}

const code = (c) => (e) => e.code === c;

// ───────────────────────────── lecture du dossier ─────────────────────────────
test('get : dossier complet (client, livreur, statut, montants encaissés, demande, historique) sans téléphone ni wallet', async () => {
  const t = setup({ driverHistory: [{ driverId: 'dX', phase: 'declined' }], acceptedAt: { toMillis: () => 10 } });
  const r = await t.call('subOk', { action: 'get', orderId: 'o1' });
  const d = r.dispute;
  assert.deepEqual([d.orderId, d.status, d.client.id, d.client.name, d.driver.id, d.driver.name],
    ['o1', 'picked_up', 'c1', 'Aya', 'dA', 'Kone']);
  assert.equal(d.amounts.paidFromWallet, 3000);
  assert.equal(d.amounts.commissionAmount, 200);
  assert.equal(d.request.status, 'pending_admin_review');
  assert.equal(d.timeline.acceptedAtMs, 10);
  assert.equal(d.driverHistory.length, 1);
  const flat = JSON.stringify(d);
  assert.doesNotMatch(flat, /phone|fcmToken|"wallet":/);
});

test('permissions : sous-admin sans `commandes`, anonyme, simple client → refusés', async () => {
  const t = setup();
  await assert.rejects(() => t.call('subNo', { action: 'get', orderId: 'o1' }), code('permission-denied'));
  await assert.rejects(() => t.call('c1', { action: 'get', orderId: 'o1' }), code('permission-denied'));
  await assert.rejects(() => t.decide('subNo', 'resolve'), code('permission-denied'));
  await assert.rejects(() => t.decide('c1', 'exceptionalCancel'), code('permission-denied'));
  await assert.rejects(() => t.call(undefined, { action: 'get', orderId: 'o1' }), code('unauthenticated'));
  assert.deepEqual(t.money(), [7000, 800]);
});

test('remboursement exceptionnel : réservé au super-admin (un sous-admin `commandes` est refusé)', async () => {
  const t = setup();
  await assert.rejects(() => t.decide('subOk', 'exceptionalCancel'), code('permission-denied'));
  assert.equal(t.order().status, 'picked_up');
  assert.deepEqual(t.money(), [7000, 800]);
});

// ───────────────────────────── décisions sans argent ─────────────────────────────
test('résolution sans clôture : demande classée, aucun mouvement, la commande reste récupérée et non livrée', async () => {
  const t = setup();
  const r = await t.decide('subOk', 'resolve');
  assert.equal(r.financialTreatment, 'none');
  assert.deepEqual(t.money(), [7000, 800]);
  assert.equal(t.order().status, 'picked_up');
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_without_closure');
  assert.equal(t.order().deliveredAt, undefined);
  assert.equal(t.order().disputeDecision.byUid, 'subOk');
  assert.equal(t.walletTx().length, 0);
});

test('la « clôture » ambiguë n’existe plus : ni décision close, ni passage à delivered par cet outil', async () => {
  const t = setup();
  await assert.rejects(() => t.decide('root', 'close'), code('invalid-argument'));
  await assert.rejects(() => t.decide('root', 'confirmDelivery'), code('invalid-argument'));
  assert.equal(t.order().status, 'picked_up');
  assert.deepEqual(t.money(), [7000, 800]);
});

// ───────────────────────────── annulation exceptionnelle ─────────────────────────────
test('annulation exceptionnelle wallet : client rendu de ce qu’il a payé (3000), commission rendue à son payeur (200), une fois', async () => {
  const t = setup();
  const r = await t.decide('root', 'exceptionalCancel');
  assert.equal(r.refund.clientRefund, 3000);
  assert.deepEqual(t.money(), [10000, 1000]);
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.order().commissionStatus, 'refunded');
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_cancelled');
  assert.equal(t.order().adminReview.action, 'disputeExceptionalCancel');
  assert.equal(t.order().cancelReason, 'admin_dispute_cancel');
});

test('annulation exceptionnelle : jamais plus que le montant payé (cash et wallet non payé → aucun remboursement client)', async () => {
  for (const extra of [{ paymentMethod: 'cash', isPaid: false }, { type: 'pharmacie', isPaid: false }]) {
    const t = setup(extra);
    const r = await t.decide('root', 'exceptionalCancel');
    assert.equal(r.refund.clientRefund, 0);
    assert.equal(t.money()[0], 7000);
    assert.equal(t.money()[1], 1000); // seule la commission est rendue
  }
  assert.equal(paidFromWallet({ paymentMethod: 'wallet', isPaid: true, budget: 500, shoppingBudget: -50 }), 500);
  assert.equal(paidFromWallet({ paymentMethod: 'cash', budget: 500 }), 0);
});

test('idempotence : même requestId rejoué → aucun second remboursement ni second journal ; autre requestId → refusé', async () => {
  const t = setup();
  await t.decide('root', 'exceptionalCancel', 1);
  const again = await t.decide('root', 'exceptionalCancel', 1);
  assert.equal(again.replay, true);
  await assert.rejects(() => t.decide('root', 'exceptionalCancel', 2), code('failed-precondition'));
  assert.deepEqual(t.money(), [10000, 1000]);
  assert.equal(t.walletTx().length, 2); // un remboursement client + un remboursement de commission
  assert.equal(t.audits.filter((a) => a.status === 'success').length, 1);
});

test('concurrence : trois décisions simultanées (requestId différents) → une seule annulation, un seul remboursement', async () => {
  const t = setup();
  const results = await Promise.allSettled([
    t.decide('root', 'exceptionalCancel', 1), t.decide('root', 'exceptionalCancel', 2), t.decide('root', 'exceptionalCancel', 3),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.deepEqual(t.money(), [10000, 1000]);
});

test('concurrence : annulation du client en même temps → refusée, un seul remboursement (décision admin)', async () => {
  const t = setup();
  const cancel = buildCancelOrder({
    db: t.db, admin, onCall: oc, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run;
  const results = await Promise.allSettled([
    cancel({ auth: { uid: 'c1', token: {} }, data: { orderId: 'o1' } }),
    t.decide('root', 'exceptionalCancel', 1),
    cancel({ auth: { uid: 'c1', token: {} }, data: { orderId: 'o1' } }),
  ]);
  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].status, 'fulfilled');
  assert.deepEqual(t.money(), [10000, 1000]);
});

test('une décision « maintenir » puis une annulation exceptionnelle (nouvel examen) sont possibles ; une fois annulée, plus rien', async () => {
  const t = setup();
  await t.decide('subOk', 'resolve', 1);
  await t.decide('root', 'exceptionalCancel', 2);
  await assert.rejects(() => t.decide('subOk', 'resolve', 3), code('failed-precondition'));
  assert.deepEqual(t.money(), [10000, 1000]);
});

// ───────────────────────────── garde-fous ─────────────────────────────
test('justification obligatoire, requestId obligatoire, décision et action valides', async () => {
  const t = setup();
  await assert.rejects(() => t.call('root', { action: 'decide', orderId: 'o1', decision: 'resolve', requestId: REQ(1), justification: 'court' }), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { action: 'decide', orderId: 'o1', decision: 'resolve', requestId: 'x', justification: J }), code('invalid-argument'));
  await assert.rejects(() => t.decide('root', 'refundEverything'), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { action: 'wipe', orderId: 'o1' }), code('invalid-argument'));
  await assert.rejects(() => t.call('root', { action: 'get', orderId: 'a/b' }), code('invalid-argument'));
  assert.deepEqual(t.money(), [7000, 800]);
});

test('seule une commande picked_up est concernée ; Marketplace/Boutique renvoyées vers adminBilling', async () => {
  for (const extra of [{ status: 'accepted' }, { status: 'delivered' }, { status: 'cancelled' }, { status: 'pending' }]) {
    const t = setup(extra);
    await assert.rejects(() => t.decide('root', 'exceptionalCancel'), code('failed-precondition'));
    assert.deepEqual(t.money(), [7000, 800]);
  }
  const m = setup({ sellerType: 'seller', sellerId: 's1' });
  await assert.rejects(() => m.decide('root', 'exceptionalCancel'), (e) => e.code === 'failed-precondition' && /adminBilling/.test(e.message));
  assert.equal((await m.call('root', { action: 'get', orderId: 'o1' })).dispute.handledByAdminBilling, true);
});

test('journal d’audit : décision, justification, administrateur, montants ; erreurs journalisées aussi', async () => {
  const t = setup();
  await t.decide('root', 'exceptionalCancel', 1);
  const a = t.audits[0];
  assert.deepEqual([a.userId, a.userType, a.action, a.status, a.targetId], ['root', 'admin', 'admin_order_dispute', 'success', 'o1']);
  assert.equal(a.metadata.justification, J);
  assert.equal(a.metadata.decision, 'exceptionalCancel');
  await assert.rejects(() => t.decide('root', 'exceptionalCancel', 2));
  assert.equal(t.audits[t.audits.length - 1].status, 'error');
});

test('les écrans Flutter appellent la fonction sans jamais écrire de wallet ; leur rattachement au menu reste désactivé', () => {
  const idx = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(idx, /exports\.adminOrderDisputeCF = buildAdminOrderDispute\(/);
  const lib = path.join(__dirname, '..', '..', 'lib');
  const hits = [];
  (function walk(d) {
    for (const f of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, f.name);
      if (f.isDirectory()) walk(p); else if (f.name.endsWith('.dart') && /adminOrderDisputeCF|adminConfirmDeliveryCF|cancelRequestAfterPickup/.test(fs.readFileSync(p, 'utf8'))) hits.push(p);
    }
  }(lib));
  for (const p of hits) assert.doesNotMatch(fs.readFileSync(p, 'utf8'), /\.update\(|FieldValue|'wallet'\s*:/, p);
  // Rattachement préparé mais désactivé tant que les fonctions ne sont pas déployées et vérifiées.
  const menuPath = path.join(lib, 'screens', 'admin', 'admin_menu.dart');
  if (fs.existsSync(menuPath)) assert.match(fs.readFileSync(menuPath, 'utf8'), /const bool kShowOrderDisputeScreens = false;/);
});

test('listAlerts : consultation des alertes de commandes bloquées, permission `commandes`, sans donnée sensible', async () => {
  const t = setup({}, {
    'stuck_order_alerts/a': { orderId: 'o9', status: 'picked_up', minutes: 120, alertedAtMs: 20, driverId: 'dA', fcm: 'secret' },
    'stuck_order_alerts/b': { orderId: 'o8', status: 'accepted', minutes: 45, alertedAtMs: 10, driverId: 'dB' },
  });
  // Le faux Firestore n'a pas orderBy : on le simule sur cette collection.
  const base = t.db.collection;
  t.db.collection = (name) => {
    const c = base(name);
    if (name !== 'stuck_order_alerts') return c;
    return { ...c, orderBy: () => ({ limit: () => ({ get: async () => {
      const docs = [...t.db.store.entries()].filter(([k]) => k.startsWith('stuck_order_alerts/'))
        .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v })).sort((x, y) => y.data().alertedAtMs - x.data().alertedAtMs);
      return { docs };
    } }) }) };
  };
  const r = await t.call('subOk', { action: 'listAlerts' });
  assert.deepEqual(r.alerts.map((a) => [a.orderId, a.status, a.minutes]), [['o9', 'picked_up', 120], ['o8', 'accepted', 45]]);
  assert.doesNotMatch(JSON.stringify(r), /secret|fcm/);
  await assert.rejects(() => t.call('subNo', { action: 'listAlerts' }), code('permission-denied'));
  await assert.rejects(() => t.call('c1', { action: 'listAlerts' }), code('permission-denied'));
});
