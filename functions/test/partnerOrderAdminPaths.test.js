'use strict';

// Mission 7B-3A — chemins ADMINISTRATIFS des commandes Restaurant / Boulangerie amountsVersion 2.
// Fonctions RÉELLES (confirmation admin de livraison, litiges, facturation admin, règlement de transfert, AZ IA
// cancel_order, remboursements automatiques, rapprochement 7A) sur faux Firestore sérialisé ; données fictives.
//
// A1 (annulation exceptionnelle v2 : remboursement intégral) est corrigée ; A2 (rapprochement v2) est couverte par
// partnerOrderReconciliation.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const {
  buildDeliverOrder, buildCancelOrder, cancelOrderTx,
} = require('../orderActions');
const { buildAdminOrderDispute, paidFromWallet } = require('../adminOrderDisputes');
const { buildAdminBilling } = require('../adminBilling');
const { buildSettleTransferEarnings } = require('../transferSettlement');
const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');
const { calculateCommission } = require('../dispatch');
const { cancelOrder: aziaCancelOrder } = require('../azia/tools/delivery');
const { expireOrderTx, rateLimitCancelTx } = require('../orderRefunds');
const { analyzePartnerOrders } = require('../partnerOrderReconciliation');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const REQ = (n) => `request-id-${String(n).padStart(8, '0')}`;
const J = 'Litige constaté après appel du client et du livreur';

const v2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000,
  budget: 500, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100,
  cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 }, ...extra,
});
const legacy = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0,
  commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100,
  cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 }, ...extra,
});

function world(order = v2(), seed = {}) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya' },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000 },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1' },
    'admins/root': { role: 'super', isActive: true },
    'admins/subOk': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission };
  const confirm = buildDeliverOrder({ ...common, onCall: oc, adminConfirm: true, requireSuperAdmin }).run;
  const deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const dispute = buildAdminOrderDispute({ ...common, onCall: oc, requireAdminPermission, requireSuperAdmin }).run;
  const billing = buildAdminBilling({ ...common, onCall: oc, requireSuperAdmin }).run;
  const cancel = buildCancelOrder({ ...common, onCall: oc }).run;
  const settle = buildSettleTransferEarnings({ ...common, onCall: oc, requireSuperAdmin }).run;
  const s = db.store;
  return {
    db, s, audits,
    adminConfirm: (n = 1, uid = 'root', extra = {}) => confirm({
      auth: authOf(uid), data: { orderId: 'o1', requestId: REQ(n), justification: J, evidence: 'client_confirmed', ...extra },
    }),
    driverDeliver: (extra = {}) => deliver({ auth: authOf('dA'), data: { orderId: 'o1', ...extra } }),
    disputeCall: (data, uid = 'root') => dispute({ auth: authOf(uid), data }),
    decide: (decision, n = 1, extra = {}) => dispute({
      auth: authOf('root'), data: { action: 'decide', orderId: 'o1', decision, requestId: REQ(n), justification: J, shoppingContext: 'not_purchased', ...extra },
    }),
    billingCall: (data) => billing({ auth: authOf('root'), data: { orderId: 'o1', justification: J, ...data } }),
    clientCancel: () => cancel({ auth: authOf('c1'), data: { orderId: 'o1' } }),
    settleCall: (data, uid = 'root') => settle({ auth: authOf(uid), data: { orderId: 'o1', ...data } }),
    w: (p) => s.get(p).wallet,
    order: () => s.get('orders/o1'),
    keys: (prefix) => [...s.keys()].filter((k) => k.startsWith(prefix)),
    walletTx: () => [...s.keys()].filter((k) => k.includes('/wallet_transactions/')),
  };
}

// ── 1. Confirmation administrative de livraison (adminConfirmDeliveryCF) ──────────────────────────────

test('livraison administrative wallet v2 : partenaire +produits, livreur +frais, une seule fois ; aucune seconde commission', async () => {
  const t = world();
  const r = await t.adminConfirm();
  assert.equal(r.success, true);
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.w('restaurants/r1'), 1000 + 3500);
  assert.equal(t.w('livreurs/dA'), 900 + 500);
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.order().commissionStatus, 'charged');
  assert.equal(t.order().commissionAmount, 100);
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_delivery_confirmed');
  // Journaux : un seul crédit par bénéficiaire, identifiants déterministes ; somme des crédits = total payé.
  assert.deepEqual(t.walletTx().sort(), ['livreurs/dA/wallet_transactions/earning_o1', 'restaurants/r1/wallet_transactions/earning_o1']);
  const credited = t.walletTx().reduce((sum, k) => sum + t.s.get(k).amount, 0);
  assert.equal(credited, t.order().totalAmount);
  const a = t.audits.find((x) => x.action === 'admin_confirm_delivery');
  assert.deepEqual([a.userType, a.metadata.walletTarget], ['admin', 'partner_v2']);
});

test('livraison administrative cash v2 : aucun mouvement de wallet, remise au partenaire à confirmer', async () => {
  const t = world(v2({ paymentMethod: 'cash', isPaid: false }));
  await t.adminConfirm();
  assert.equal(t.order().status, 'delivered');
  assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dA'), t.w('clients/c1')], [1000, 900, 16000]);
  assert.equal(t.walletTx().length, 0);
  assert.equal(t.order().cashRemittance.status, 'pending');
  assert.equal(t.order().cashRemittance.amountDue, 3500);
  assert.equal(t.order().merchantCashSettled, false);
});

test('double confirmation de livraison : même requestId = rejeu sans effet ; autre requestId = refusé ; livreur ne peut plus livrer', async () => {
  const t = world();
  await t.adminConfirm(1);
  const after = [t.w('restaurants/r1'), t.w('livreurs/dA')];
  const replay = await t.adminConfirm(1);
  assert.equal(replay.replay, true);
  await assert.rejects(() => t.adminConfirm(2), (e) => e.code === 'failed-precondition');
  await assert.rejects(() => t.driverDeliver(), (e) => e.code === 'failed-precondition');
  await Promise.allSettled([t.adminConfirm(3), t.adminConfirm(4), t.driverDeliver()]);
  assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dA')], after);
  assert.equal(t.walletTx().length, 2);
});

test('confirmation administrative v2 : réservée au super-admin, picked_up seulement, course transférée refusée, montants cohérents', async () => {
  const sub = world();
  await assert.rejects(() => sub.adminConfirm(1, 'subOk'), (e) => e.code === 'permission-denied');
  const accepted = world(v2({ status: 'accepted', pickedUpAt: null }));
  await assert.rejects(() => accepted.adminConfirm(), (e) => e.code === 'failed-precondition');
  const held = world(v2({ settlementHold: true }));
  await assert.rejects(() => held.adminConfirm(), (e) => e.code === 'failed-precondition');
  const bad = world(v2({ totalAmount: 1 }));
  await assert.rejects(() => bad.adminConfirm(), (e) => e.code === 'failed-precondition');
  for (const t of [sub, accepted, held, bad]) {
    assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dA')], [1000, 900]);
  }
});

// ── 2. Litiges après récupération (adminOrderDisputeCF) ───────────────────────────────────────────────

test('dossier de litige v2 : remboursements partiels indisponibles (vendeur), annulation exceptionnelle annoncée au total payé', async () => {
  const t = world();
  const { dispute } = await t.disputeCall({ action: 'get', orderId: 'o1' });
  for (const k of ['refundShopping', 'refundFee', 'refundHalfFee']) assert.equal(dispute.options[k].available, false, k);
  assert.equal(dispute.options.exceptionalCancel.available, true);
  assert.equal(dispute.options.exceptionalCancel.clientRefund, 4000);
  assert.equal(dispute.amounts.paidFromWallet, 4000);
  assert.equal(paidFromWallet(v2()), 4000);
  assert.equal(paidFromWallet(v2({ paymentMethod: 'cash', isPaid: false })), 0);
});

test('remboursements partiels v2 : refusés côté serveur (jamais de montant saisi, jamais plus que le payé)', async () => {
  const t = world();
  for (const d of ['refundShopping', 'refundFee', 'refundHalfFee']) {
    await assert.rejects(() => t.decide(d, 1), (e) => e.code === 'failed-precondition');
  }
  assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA'), t.w('restaurants/r1')], [16000, 900, 1000]);
  assert.equal(t.order().status, 'picked_up');
  await assert.rejects(() => t.decide('refundFee', 2, { clientRefund: 99999 }), (e) => e.code === 'failed-precondition');
});

test('A1 corrigée — annulation exceptionnelle v2 wallet : remboursement intégral de 4000, commission rendue, aucune retenue', async () => {
  const t = world();
  const { dispute } = await t.disputeCall({ action: 'get', orderId: 'o1' });
  const announced = dispute.options.exceptionalCancel.clientRefund;
  const r = await t.decide('exceptionalCancel');
  assert.equal(r.financialTreatment, 'cancel_with_refund');
  // 1. Le client reçoit exactement le montant annoncé (= total payé).
  assert.equal(announced, 4000);
  assert.equal(r.refund.clientRefund, announced);
  assert.equal(t.w('clients/c1'), 16000 + announced);
  // 2. Commission du livreur restituée à son payeur, selon le traitement existant.
  assert.equal(t.w('livreurs/dA'), 900 + 100);
  assert.equal(t.order().commissionStatus, 'refunded');
  // 3. Rien n'est retenu ; partenaire ni livreur ne reçoivent ni ne perdent rien d'autre.
  assert.equal(r.refund.feeHeld, 0);
  assert.equal(t.order().deliveryFeeHold, undefined);
  assert.equal(t.w('restaurants/r1'), 1000);
  // 4. Dossier et journaux cohérents.
  assert.equal(t.order().status, 'cancelled');
  assert.deepEqual([t.order().disputeDecision.clientRefund, t.order().disputeDecision.financialTreatment], [4000, 'cancel_with_refund']);
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_cancelled');
  const refunds = t.keys('clients/c1/wallet_transactions/').map((k) => t.s.get(k));
  assert.deepEqual(refunds.map((x) => [x.type, x.amount]), [['refund', 4000]]);
  const driverRefunds = t.keys('livreurs/dA/wallet_transactions/').map((k) => t.s.get(k));
  assert.deepEqual(driverRefunds.map((x) => [x.type, x.amount]), [['refund', 100]]);
  assert.equal(paidFromWallet(v2()), 4000, 'jamais plus que le montant payé');
  // Le partenaire n'était pas payé : un signalement de rapprochement vendeur est ouvert, aucun débit automatique.
  assert.equal(t.keys('reconciliation_flags/').length, 1);
});

test('A1 — aucun double remboursement : rejeu, deuxième décision, appels simultanés', async () => {
  const t = world();
  await Promise.allSettled([t.decide('exceptionalCancel', 1), t.decide('exceptionalCancel', 1), t.decide('exceptionalCancel', 2), t.clientCancel()]);
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.w('livreurs/dA'), 1000);
  assert.equal(t.keys('clients/c1/wallet_transactions/').length, 1);
  await assert.rejects(() => t.decide('exceptionalCancel', 3), (e) => e.code === 'failed-precondition');
  assert.equal(t.w('clients/c1'), 20000);
});

test('A1 — annulation exceptionnelle v2 : jamais plus que le payé, quels que soient les montants du document', async () => {
  // Document incohérent (total gonflé sans montants cohérents) : lecture v2 refusée, l'annulation s'arrête.
  const bad = world(v2({ totalAmount: 999999 }));
  await assert.rejects(() => bad.decide('exceptionalCancel'));
  assert.equal(bad.w('clients/c1'), 16000);
  // Commande wallet non marquée payée : rien n'a été débité, rien n'est remboursé.
  const unpaid = world(v2({ isPaid: false }));
  await unpaid.decide('exceptionalCancel').catch(() => {});
  assert.equal(unpaid.w('clients/c1'), 16000);
});

test('retenue VOLONTAIRE des frais (décision administrative explicite refundFee:false) : inchangée — produits rendus, frais en attente', async () => {
  const t = world();
  const info = await adminCancel(t, { refundFee: false });
  assert.deepEqual([info.clientRefund, info.feeHeld], [3500, 500]);
  assert.equal(t.order().deliveryFeeHold.status, 'pending_admin_review');
  assert.equal(t.order().commissionStatus, 'charged');
  assert.equal(t.w('clients/c1'), 16000 + 3500);
});

test('frais retenus v2 : refundClient rend les 500 restants (total 4000), une fois ; payDriver et retain inchangés', async () => {
  const refund = world();
  await adminCancel(refund, { refundFee: false });
  await refund.billingCall({ action: 'resolveFeeHold', decision: 'refundClient' });
  assert.equal(refund.w('clients/c1'), 16000 + 4000);
  assert.equal(refund.w('livreurs/dA'), 900 + 100);
  const after = refund.w('clients/c1');
  await refund.billingCall({ action: 'resolveFeeHold', decision: 'refundClient' });
  assert.equal(refund.w('clients/c1'), after);

  const pay = world();
  await adminCancel(pay, { refundFee: false });
  await pay.billingCall({ action: 'resolveFeeHold', decision: 'payDriver' });
  assert.equal(pay.w('livreurs/dA'), 900 + 500);
  assert.equal(pay.w('clients/c1'), 16000 + 3500);

  const retain = world();
  await adminCancel(retain, { refundFee: false });
  await retain.billingCall({ action: 'resolveFeeHold', decision: 'retain' });
  assert.equal(retain.w('livreurs/dA'), 900 + 100);
  assert.equal(retain.w('clients/c1'), 16000 + 3500);
});

test('annulation exceptionnelle v2 cash : aucun remboursement client, commission rendue, aucun crédit partenaire/livreur', async () => {
  const t = world(v2({ paymentMethod: 'cash', isPaid: false }));
  const r = await t.decide('exceptionalCancel');
  assert.equal(r.refund.clientRefund, 0);
  assert.equal(t.w('clients/c1'), 16000);
  assert.equal(t.w('restaurants/r1'), 1000);
  assert.equal(t.w('livreurs/dA'), 900 + 100);
  assert.equal(t.order().commissionStatus, 'refunded');
});

test('litige : « résoudre sans clôture » ne déplace aucun argent ; annulation exceptionnelle rejouée = aucun second remboursement', async () => {
  const t = world();
  await t.decide('resolve', 1);
  assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA'), t.w('restaurants/r1')], [16000, 900, 1000]);
  assert.equal(t.order().status, 'picked_up');
  await t.decide('exceptionalCancel', 2);
  const after = t.w('clients/c1');
  const replay = await t.decide('exceptionalCancel', 2);
  assert.equal(replay.replay, true);
  await assert.rejects(() => t.decide('exceptionalCancel', 3), (e) => e.code === 'failed-precondition');
  assert.equal(t.w('clients/c1'), after);
});

test('litige : sous-admin refusé pour un remboursement ; commande non récupérée refusée ; Marketplace non concernée', async () => {
  const t = world();
  await assert.rejects(() => t.disputeCall({ action: 'decide', orderId: 'o1', decision: 'exceptionalCancel', requestId: REQ(1), justification: J }, 'subOk'),
    (e) => e.code === 'permission-denied');
  const accepted = world(v2({ status: 'accepted', pickedUpAt: null }));
  await assert.rejects(() => accepted.decide('exceptionalCancel'), (e) => e.code === 'failed-precondition');
  assert.equal(accepted.w('clients/c1'), 16000);
});

test('concurrence : confirmation administrative de livraison ET annulation exceptionnelle simultanées → un seul effet financier', async () => {
  for (let i = 0; i < 10; i++) {
    const t = world();
    const calls = i % 2 ? [t.adminConfirm(1), t.decide('exceptionalCancel', 1)] : [t.decide('exceptionalCancel', 1), t.adminConfirm(1)];
    await Promise.allSettled(calls);
    const st = t.order().status;
    assert.ok(['delivered', 'cancelled'].includes(st));
    if (st === 'delivered') {
      assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dA'), t.w('clients/c1')], [4500, 1400, 16000]);
    } else {
      assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dA')], [1000, 1000]);
      assert.equal(t.w('clients/c1'), 20000);
    }
  }
});

test('annulation du client après récupération : refusée, demande tracée, aucun remboursement ; la confirmation admin la résout', async () => {
  const t = world(v2({ cancelRequestAfterPickup: null }));
  await assert.rejects(() => t.clientCancel(), (e) => e.code === 'failed-precondition');
  assert.equal(t.order().cancelRequestAfterPickup.status, 'pending_admin_review');
  assert.equal(t.w('clients/c1'), 16000);
  await t.adminConfirm();
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_delivery_confirmed');
});

test('adminBilling.closeStuckDelivery : refuse les commandes v2 (limite connue — hors Marketplace/Boutique)', async () => {
  const t = world(v2({ status: 'accepted', pickedUpAt: null }));
  await assert.rejects(() => t.billingCall({ action: 'closeStuckDelivery' }), (e) => e.code === 'failed-precondition');
  assert.equal(t.order().status, 'accepted');
  assert.equal(t.w('clients/c1'), 16000);
});

// ── 3. Annulation administrative (cancelOrderTx avec décision) ────────────────────────────────────────

async function adminCancel(t, adminDecision) {
  const orderRef = t.db.collection('orders').doc('o1');
  return t.db.runTransaction(async (tx) => {
    const order = (await tx.get(orderRef)).data();
    return cancelOrderTx(tx, { db: t.db, admin, orderRef, order, uid: order.clientId, calculateCommission, reason: 'admin_test', adminDecision });
  });
}

test('annulation administrative v2 avant récupération : remboursement du total exact, commission rendue', async () => {
  const t = world(v2({ status: 'accepted', pickedUpAt: null, sellerStatus: 'preparing' }));
  const info = await adminCancel(t, { refundFee: false });
  assert.equal(info.clientRefund, 4000);
  assert.equal(info.feeHeld, 0);
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.w('livreurs/dA'), 1000);
  assert.deepEqual([t.w('restaurants/r1')], [1000]);
});

test('annulation administrative v2 après récupération : refundFee true = total remboursé ; false = produits + frais retenus', async () => {
  const total = world();
  const a = await adminCancel(total, { refundFee: true });
  assert.equal(a.clientRefund, 4000);
  assert.equal(a.feeHeld, 0);
  const held = world();
  const b = await adminCancel(held, { refundFee: false });
  assert.deepEqual([b.clientRefund, b.feeHeld], [3500, 500]);
  assert.equal(held.order().deliveryFeeHold.amount, 500);
});

// ── 4. Remboursements automatiques (orderRefunds) ─────────────────────────────────────────────────────

test('orderRefunds : expiration sans livreur et limite de débit remboursent le total v2, jamais le partenaire', async () => {
  const pending = { status: 'pending', driverId: null, pickedUpAt: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null };
  const t = world(v2(pending));
  const orderRef = t.db.collection('orders').doc('o1');
  const e = await t.db.runTransaction((tx) => expireOrderTx(tx, { db: t.db, admin, orderRef, orderId: 'o1' }));
  assert.equal(e.expired, true);
  assert.deepEqual(t.w('clients/c1'), { __inc: 4000 }.__inc ? t.w('clients/c1') : null);
  const ledger = t.keys('clients/c1/wallet_transactions/').map((k) => t.s.get(k));
  assert.deepEqual(ledger.map((x) => [x.type, x.amount]), [['refund', 4000]]);
  assert.equal(t.w('restaurants/r1'), 1000);
  // Rejeu : plus en file d'attente, aucun second remboursement.
  const again = await t.db.runTransaction((tx) => expireOrderTx(tx, { db: t.db, admin, orderRef, orderId: 'o1' }));
  assert.equal(again.expired, false);
  assert.equal(t.keys('clients/c1/wallet_transactions/').length, 1);

  const r = world(v2(pending));
  const ref2 = r.db.collection('orders').doc('o1');
  const out = await r.db.runTransaction(async (tx) => {
    const order = (await tx.get(ref2)).data();
    return rateLimitCancelTx(tx, { db: r.db, admin, orderRef: ref2, orderId: 'o1', order, clientId: 'c1' });
  });
  assert.ok(out);
  const l2 = r.keys('clients/c1/wallet_transactions/').map((k) => r.s.get(k));
  assert.deepEqual(l2.map((x) => [x.type, x.amount]), [['refund', 4000]]);
});

// ── 5. AZ IA cancel_order ─────────────────────────────────────────────────────────────────────────────

async function aziaCancel(t) {
  const tool = aziaCancelOrder({ db: t.db, admin, HttpsError, calculateCommission });
  const res = await t.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', { orderId: 'o1' }));
  return tool.afterConfirm('c1', res);
}

test('AZ IA cancel_order v2 : total remboursé une fois ; commission rendue après acceptation ; préparation commencée refusée', async () => {
  const pend = world(v2({ status: 'pending', driverId: null, pickedUpAt: null, commissionStatus: null, commissionPayerId: null, commissionAmount: null }));
  const r = await aziaCancel(pend);
  assert.equal(r.refundAmount, 4000);
  assert.equal(pend.w('clients/c1'), 20000);
  assert.equal(pend.w('restaurants/r1'), 1000);
  await assert.rejects(() => aziaCancel(pend), (e) => e.code === 'failed-precondition');
  assert.equal(pend.w('clients/c1'), 20000);

  const acc = world(v2({ status: 'accepted', pickedUpAt: null }));
  const r2 = await aziaCancel(acc);
  assert.deepEqual([r2.refundAmount, r2.commissionRefund], [4000, 100]);
  assert.equal(acc.w('livreurs/dA'), 1000);

  const prep = world(v2({ status: 'pending', driverId: null, pickedUpAt: null, sellerStatus: 'preparing', sellerType: 'boulangerie', sellerId: 'b1' }));
  await assert.rejects(() => aziaCancel(prep), (e) => e.code === 'failed-precondition' && /préparation/.test(e.message));
  assert.equal(prep.w('clients/c1'), 16000);

  const picked = world();
  await assert.rejects(() => aziaCancel(picked), (e) => e.code === 'failed-precondition');
  assert.equal(picked.w('clients/c1'), 16000);
});

// ── 6. Transfert de livraison + règlement ─────────────────────────────────────────────────────────────

const transferred = (extra = {}) => v2({
  driverId: 'dB', settlementHold: true, latitude: 6.70, longitude: -3.49, destLat: 6.80, destLng: -3.49,
  driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: { trusted: true, point: { lat: 6.74, lng: -3.49 } } }],
  cancelRequestAfterPickup: null, ...extra,
});

test('course transférée v2 wallet : partenaire payé une fois à la livraison, gain livreur = frais seulement, règlement sans double crédit', async () => {
  const t = world(transferred(), { 'livreurs/dB': { wallet: 0, isOnDelivery: true, currentOrderId: 'o1' } });
  await t.s.get('orders/o1');
  const deliver = buildDeliverOrder({ db: t.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, onCall: oc }).run;
  await deliver({ auth: authOf('dB'), data: { orderId: 'o1', deliveryPhotoUrl: 'p.jpg' } });
  assert.equal(t.w('restaurants/r1'), 4500);
  assert.equal(t.w('livreurs/dB'), 0, 'rien au livreur final seul');
  assert.equal(t.order().heldDriverEarning, 500);
  const s = t.s.get('transfer_settlements/o1');
  assert.equal(s.method, 'wallet');
  assert.equal(s.totalPaid, 500, 'seuls les FRAIS sont à répartir — jamais les produits déjà versés au partenaire');
  const approve = await t.settleCall({ action: 'approve', credits: { dA: 200, dB: 300 }, justification: J });
  assert.equal(approve.status, 'settled');
  assert.equal(t.w('livreurs/dA') + t.w('livreurs/dB'), 900 + 500);
  assert.equal(t.w('restaurants/r1'), 4500, 'le règlement ne touche pas le partenaire');
  const again = await t.settleCall({ action: 'approve', credits: { dA: 200, dB: 300 }, justification: J });
  assert.equal(again.replay, true);
  assert.equal(t.w('livreurs/dA') + t.w('livreurs/dB'), 1400);
  const other = await t.settleCall({ action: 'approve', credits: { dA: 100, dB: 400 }, justification: J });
  assert.equal(other.replay, true, 'une autre répartition ne rejoue pas le crédit');
  assert.equal(t.w('livreurs/dA') + t.w('livreurs/dB'), 1400);
});

test('course transférée v2 cash : aucun wallet, remise partenaire tracée ; le règlement cash ne porte que sur les frais', async () => {
  const t = world(transferred({ paymentMethod: 'cash', isPaid: false }), { 'livreurs/dB': { wallet: 0, isOnDelivery: true, currentOrderId: 'o1' } });
  const deliver = buildDeliverOrder({ db: t.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, onCall: oc }).run;
  await deliver({ auth: authOf('dB'), data: { orderId: 'o1', deliveryPhotoUrl: 'p.jpg' } });
  assert.deepEqual([t.w('restaurants/r1'), t.w('livreurs/dB'), t.w('livreurs/dA'), t.w('clients/c1')], [1000, 0, 900, 16000]);
  assert.equal(t.order().cashRemittance.amountDue, 3500);
  assert.equal(t.order().cashRemittance.driverId, 'dB');
  const s = t.s.get('transfer_settlements/o1');
  assert.equal(s.method, 'cash');
  // Constat : le règlement cash de transfert suit les frais (500), pas l'espèce totale réellement encaissée (4000).
  assert.equal(s.cash.collected, 500);
  assert.equal(t.order().cashBreakdown.cashCollected, 4000);
});

// ── 7. Rapprochement 7A ───────────────────────────────────────────────────────────────────────────────

test('A2 corrigée — le rapprochement 7A lit les écritures RÉELLES des flux administratifs v2 et ne signale rien de normal', async () => {
  const ledgerOf = (t, prefix, orderId = 'o1') => t.keys(prefix).map((k) => ({ orderId, type: t.s.get(k).type, amount: t.s.get(k).amount }));
  const analyze = (t) => analyzePartnerOrders({
    orders: [{ ...t.order(), id: 'o1' }],
    clientLedger: [{ orderId: 'o1', type: 'payment', amount: 4000 }, ...ledgerOf(t, 'clients/c1/wallet_transactions/')],
    partnerLedger: ledgerOf(t, 'restaurants/r1/wallet_transactions/'),
    driverLedger: [{ orderId: 'o1', type: 'commission', amount: 100 }, ...ledgerOf(t, 'livreurs/dA/wallet_transactions/').filter((x) => x.type === 'earning')],
    nowMs: Date.now(),
  });
  const delivered = world();
  await delivered.adminConfirm();
  assert.deepEqual(analyze(delivered).rows, [], 'livraison administrative wallet conforme');
  const cancelled = world();
  await cancelled.decide('exceptionalCancel');
  assert.deepEqual(analyze(cancelled).rows, [], 'annulation exceptionnelle : total remboursé, aucun crédit');
  const cash = world(v2({ paymentMethod: 'cash', isPaid: false }));
  await cash.adminConfirm();
  const cashReport = analyzePartnerOrders({ orders: [{ ...cash.order(), id: 'o1' }], nowMs: Date.now() });
  assert.deepEqual(cashReport.rows[0].findings.map((f) => f.code), ['V2_CASH_REMITTANCE_PENDING']);
  // Un double crédit partenaire v2 est désormais détecté.
  const dbl = analyzePartnerOrders({
    orders: [{ ...delivered.order(), id: 'o1' }],
    clientLedger: [{ orderId: 'o1', type: 'payment', amount: 4000 }],
    partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 3500 }, { orderId: 'o1', type: 'earning', amount: 3500 }],
    driverLedger: [{ orderId: 'o1', type: 'earning', amount: 500 }],
  });
  assert.ok(dbl.rows[0].findings.some((f) => f.code === 'V2_PARTNER_DOUBLE_CREDIT'));
});

// ── 8. Compatibilité des commandes historiques ────────────────────────────────────────────────────────

test('commande historique restaurant : confirmation admin, annulation exceptionnelle et expiration inchangées', async () => {
  const conf = world(legacy());
  await conf.adminConfirm();
  assert.equal(conf.w('restaurants/r1'), 1700, 'partenaire crédité de budget (historique)');
  assert.equal(conf.w('livreurs/dA'), 900, 'livreur non crédité ici (historique)');

  const canc = world(legacy({ shoppingBudget: 300 }));
  const r = await canc.decide('exceptionalCancel');
  assert.equal(r.refund.clientRefund, 1000);
  assert.equal(canc.w('clients/c1'), 17000);
  assert.equal(canc.order().deliveryFeeHold, undefined, 'aucune retenue de frais pour une commande historique');
  assert.equal(canc.w('livreurs/dA'), 1000, 'commission rendue');

  const cash = world(legacy({ paymentMethod: 'cash', isPaid: false }));
  await cash.adminConfirm();
  assert.equal(cash.order().cashRemittance, undefined);
  assert.equal(cash.order().merchantCashSettled, false);
});
