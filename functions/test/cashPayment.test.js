'use strict';

// Mission 7D-5 — état du paiement cash v2 (cashPayment) : livraison, déclaration tardive du livreur, examen administratif.
// Invariants vérifiés partout : le dû (cashRemittance.amountDue) n'est jamais modifié ni effacé par une déclaration,
// aucun wallet ne bouge, aucune écriture hors cashPayment / reconciliation_flags.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildPartnerOrderAction } = require('../partnerOrderActions');
const { buildDeliverOrder } = require('../orderActions');
const { calculateCommission } = require('../dispatch');
const { requireSuperAdmin } = require('../adminGuards');
const { analyzePartnerOrders } = require('../partnerOrderReconciliation');
const { initialCashPayment, declareNonPayment, reviewNonPayment, PaymentRefusal } = require('../cashPayment');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const REQ_A = 'review-request-0001';
const REQ_B = 'review-request-0002';
const JUST = 'Appel du client et du livreur, versions comparées';
const REASON = 'Le client est parti sans payer à la livraison';

const v2cash = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'cash', isPaid: false, amountsVersion: 2, productAmount: 3500, deliveryFee: 500,
  totalAmount: 4000, budget: 500, shoppingBudget: 0, sellerStatus: 'ready', commissionStatus: 'charged',
  commissionPayerId: 'dA', commissionAmount: 100, ...extra,
});

function world(order = v2cash(), seed = {}) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya', fakeOrderCount: 0, cashOnDeliveryEnabled: true },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1', isOnline: true },
    'livreurs/dB': { wallet: 500, isOnline: true },
    'admins/root': { role: 'super', isActive: true },
    'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = []; const limits = []; const clock = { t: 1000 };
  const common = {
    db, admin, HttpsError, checkRateLimit: async (...a) => { limits.push(a); }, logAudit: async (d) => { audits.push(d); }, calculateCommission,
  };
  const act = buildPartnerOrderAction({ ...common, onCall: oc, requireSuperAdmin, now: () => clock.t, isEnabled: () => true }).run;
  const deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const s = db.store;
  return {
    s, audits, limits, clock,
    call: (action, uid, extra = {}) => act({ auth: authOf(uid), data: { orderId: 'o1', action, ...extra } }),
    deliver: (data = {}, uid = 'dA') => deliver({ auth: authOf(uid), data: { orderId: 'o1', ...data } }),
    order: () => s.get('orders/o1'),
    flag: () => s.get('reconciliation_flags/o1_cash_payment_review'),
    balances: () => [s.get('clients/c1').wallet, s.get('livreurs/dA').wallet, s.get('restaurants/r1').wallet],
    walletTx: () => [...s.keys()].filter((k) => k.includes('/wallet_transactions/')),
  };
}

const declareLate = (t, uid = 'dA', reason = REASON) => t.call('declareCashNonPayment', uid, { reason });
const review = (t, over = {}, uid = 'root') => t.call('reviewCashNonPayment', uid, { requestId: REQ_A, decision: 'confirm_unpaid', justification: JUST, ...over });
const resolveCash = (t, over = {}) => t.call('resolveCashRemittance', 'root', { requestId: 'resolve-request-0001', justification: JUST, finalAmount: 3500, ...over });

// Commande déjà livrée (sans passer par deliverOrderCF) avec ou sans cashPayment.
const delivered = (payment, r = {}) => v2cash({
  status: 'delivered', merchantCashSettled: false,
  cashRemittance: {
    status: 'pending', orderId: 'o1', partnerId: 'r1', sellerType: 'restaurant', driverId: 'dA', amountDue: 3500,
    amountHandedOver: null, deliveredAtMs: 1, handedOverAtMs: null, partnerConfirmedAtMs: null, ...r,
  },
  ...(payment ? { cashPayment: payment } : {}),
});

// ── Module pur ──────────────────────────────────────────────────────────────────────────────────────────────

test('initialCashPayment : seul un booléen explicite vaut déclaration ; absent ou autre type = inconnu', () => {
  const paid = initialCashPayment({ markCashPaid: true, totalAmount: 4000, uid: 'dA', nowMs: 5 });
  assert.deepEqual([paid.status, paid.verification, paid.declaredBy, paid.theoreticalTotal], ['confirmed', 'not_required', 'dA', 4000]);
  const unpaid = initialCashPayment({ markCashPaid: false, totalAmount: 4000, uid: 'dA', nowMs: 5 });
  assert.deepEqual([unpaid.status, unpaid.verification, unpaid.declaredBy, unpaid.declaredAtMs], ['non_payment_declared', 'pending_review', 'dA', 5]);
  for (const v of [undefined, null, 'false', 0, 'true', {}]) {
    const u = initialCashPayment({ markCashPaid: v, totalAmount: 4000, uid: 'dA', nowMs: 5 });
    assert.deepEqual([u.status, u.verification, u.declaredBy], ['unknown', 'not_required', null], String(v));
  }
});

test('declareNonPayment / reviewNonPayment : transitions, rejeux et refus', () => {
  assert.throws(() => declareNonPayment(null, { uid: 'dA', nowMs: 1, reason: 'court', totalAmount: 4000 }), (e) => e.code === 'REASON_REQUIRED');
  const d = declareNonPayment(null, { uid: 'dA', nowMs: 1, reason: REASON, totalAmount: 4000 });
  assert.equal(d.next.status, 'non_payment_declared');
  assert.equal(d.next.history.length, 1);
  assert.equal(declareNonPayment(d.next, { uid: 'dA', nowMs: 2, reason: REASON, totalAmount: 4000 }).replay, true);
  const paid = initialCashPayment({ markCashPaid: true, totalAmount: 4000, uid: 'dA', nowMs: 1 });
  assert.throws(() => declareNonPayment(paid, { uid: 'dA', nowMs: 2, reason: REASON, totalAmount: 4000 }), (e) => e instanceof PaymentRefusal && e.code === 'PAYMENT_ALREADY_DECLARED_PAID');
  assert.throws(() => reviewNonPayment(null, { uid: 'root', nowMs: 3, requestId: REQ_A, decision: 'refute', justification: JUST }), (e) => e.code === 'NO_NON_PAYMENT_DECLARED');
  assert.throws(() => reviewNonPayment(d.next, { uid: 'root', nowMs: 3, requestId: 'x', decision: 'refute', justification: JUST }), (e) => e.code === 'REQUEST_ID_REQUIRED');
  assert.throws(() => reviewNonPayment(d.next, { uid: 'root', nowMs: 3, requestId: REQ_A, decision: 'delete', justification: JUST }), (e) => e.code === 'INVALID_DECISION');
  assert.throws(() => reviewNonPayment(d.next, { uid: 'root', nowMs: 3, requestId: REQ_A, decision: 'refute', justification: 'court' }), (e) => e.code === 'JUSTIFICATION_REQUIRED');
  const r = reviewNonPayment(d.next, { uid: 'root', nowMs: 3, requestId: REQ_A, decision: 'refute', justification: JUST });
  assert.equal(r.next.verification, 'refuted');
  assert.equal(r.next.history.length, 2);
  assert.equal(reviewNonPayment(r.next, { uid: 'root', nowMs: 4, requestId: REQ_A, decision: 'refute', justification: JUST }).replay, true);
  assert.throws(() => reviewNonPayment(r.next, { uid: 'root', nowMs: 4, requestId: REQ_B, decision: 'confirm_unpaid', justification: JUST }), (e) => e.code === 'PAYMENT_ALREADY_REVIEWED');
});

// ── Livraison (deliverOrderCF) ─────────────────────────────────────────────────────────────────────────────

test('1. cash payé : cashPayment confirmé (déclaration du livreur), circuit normal, dû inchangé, aucun signalement', async () => {
  const t = world();
  const before = t.balances();
  await t.deliver({ markCashPaid: true });
  const o = t.order();
  assert.equal(o.isPaid, true);
  assert.deepEqual([o.cashPayment.status, o.cashPayment.verification, o.cashPayment.basis], ['confirmed', 'not_required', 'driver_declaration']);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal(o.cashRemittance.status, 'pending');
  assert.equal(t.flag(), undefined);
  assert.deepEqual(t.balances(), before);
  assert.equal(t.walletTx().length, 0);
});

test('2. non-paiement déclaré : conservé (auteur, date, vérification), dû théorique CONSERVÉ, signalement ouvert, aucun wallet', async () => {
  const t = world();
  const before = t.balances();
  await t.deliver({ markCashPaid: false });
  const o = t.order();
  assert.equal(o.isPaid, false);
  assert.deepEqual([o.cashPayment.status, o.cashPayment.verification, o.cashPayment.declaredBy], ['non_payment_declared', 'pending_review', 'dA']);
  assert.ok(o.cashPayment.declaredAtMs > 0);
  assert.equal(o.cashPayment.theoreticalTotal, 4000);
  assert.equal(o.cashRemittance.amountDue, 3500, 'le dû au restaurant n’est pas effacé');
  assert.equal(o.cashRemittance.status, 'pending');
  assert.equal(o.merchantCashSettled, false);
  assert.deepEqual([t.flag().type, t.flag().status, t.flag().amountDueToPartner], ['cash_payment_review', 'open', 3500]);
  assert.deepEqual(t.balances(), before);
  assert.equal(t.walletTx().length, 0);
});

test('3. paiement inconnu : rien n’est déclaré, isPaid:false n’est pas pris pour une preuve, aucun signalement', async () => {
  const t = world();
  await t.deliver({});
  const o = t.order();
  assert.equal(o.isPaid, false);
  assert.deepEqual([o.cashPayment.status, o.cashPayment.verification, o.cashPayment.declaredBy], ['unknown', 'not_required', null]);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal(t.flag(), undefined);
});

test('7. commande wallet v2 : aucun cashPayment, la déclaration tardive est refusée', async () => {
  const t = world(v2cash({ paymentMethod: 'wallet', isPaid: true }));
  await t.deliver({ markCashPaid: false });
  assert.equal(t.order().cashPayment, undefined);
  assert.equal(t.order().cashRemittance, undefined);
  const r = await declareLate(t);
  assert.deepEqual([r.success, r.code], [false, 'CASH_ORDER_NOT_CASH']);
});

test('12. commande historique (sans amountsVersion 2) : aucun cashPayment, actions refusées', async () => {
  const legacy = { id: 'o1', clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1', paymentMethod: 'cash', isPaid: false, budget: 700, shoppingBudget: 0 };
  const t = world(legacy);
  await t.deliver({ markCashPaid: false });
  assert.equal(t.order().cashPayment, undefined);
  assert.equal(t.order().cashRemittance, undefined);
  assert.equal((await declareLate(t)).success, false);
  assert.equal((await review(t)).success, false);
});

// ── Signalement tardif ─────────────────────────────────────────────────────────────────────────────────────

test('déclaration tardive (paiement inconnu) : état + signalement, dû intact, audit, limite stricte', async () => {
  const t = world(delivered(initialCashPayment({ markCashPaid: undefined, totalAmount: 4000, uid: 'dA', nowMs: 1 })));
  const before = t.balances();
  const r = await declareLate(t);
  assert.equal(r.success, true);
  const o = t.order();
  assert.deepEqual([o.cashPayment.status, o.cashPayment.verification, o.cashPayment.reason], ['non_payment_declared', 'pending_review', REASON]);
  assert.equal(o.cashPayment.history.length, 2);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal(o.cashRemittance.status, 'pending');
  assert.equal(o.merchantCashSettled, false);
  assert.equal(t.flag().status, 'open');
  assert.deepEqual(t.balances(), before);
  assert.equal(t.walletTx().length, 0);
  assert.ok(t.audits.some((a) => a.action === 'partner_order_declareCashNonPayment' && a.userId === 'dA' && a.metadata.verification === 'pending_review'));
  assert.ok(t.limits.some(([uid, action, max, win]) => uid === 'dA' && action === 'cash_non_payment_declaration' && max === 10 && win === 3600));
  // Aucun effet sur le profil client : pas de compteur, pas de blocage automatique.
  assert.deepEqual([t.s.get('clients/c1').fakeOrderCount, t.s.get('clients/c1').cashOnDeliveryEnabled], [0, true]);
});

test('4. signalement répété : idempotent, un seul compte, historique et date inchangés', async () => {
  const t = world(delivered(null));
  await declareLate(t);
  const first = JSON.stringify(t.order().cashPayment);
  t.clock.t = 9000;
  const again = await declareLate(t);
  assert.equal(again.data.replay, true);
  assert.equal(JSON.stringify(t.order().cashPayment), first);
  assert.equal(t.audits.filter((a) => a.action === 'partner_order_declareCashNonPayment' && !a.status).length, 1);
  const rest = await Promise.allSettled([declareLate(t), declareLate(t), declareLate(t)]);
  assert.ok(rest.every((x) => x.value?.success));
  assert.equal(JSON.stringify(t.order().cashPayment), first);
  assert.equal(t.order().cashPayment.history.length, 1);
});

test('5. un autre livreur, le restaurant, le client et l’admin ne peuvent pas déclarer', async () => {
  const t = world(delivered(null));
  for (const uid of ['dB', 'r1', 'c1', 'root', 'ghost']) {
    const r = await declareLate(t, uid).catch((e) => ({ success: false, code: e.code }));
    assert.equal(r.success, false, uid);
  }
  assert.equal(t.order().cashPayment, undefined);
  assert.equal(t.flag(), undefined);
});

test('6. commande non livrée : déclaration refusée, rien d’écrit', async () => {
  for (const status of ['accepted', 'picked_up', 'cancelled']) {
    const t = world(v2cash({ status }));
    const r = await declareLate(t);
    assert.deepEqual([r.success, r.code], [false, 'CASH_ORDER_NOT_DELIVERED'], status);
    assert.equal(t.order().cashPayment, undefined);
  }
});

test('8. déclaration mensongère : le livreur qui a déclaré « payé » ne peut plus dire « non payé » ; motif obligatoire', async () => {
  const t = world(delivered(initialCashPayment({ markCashPaid: true, totalAmount: 4000, uid: 'dA', nowMs: 1 })));
  const r = await declareLate(t);
  assert.deepEqual([r.success, r.code], [false, 'PAYMENT_ALREADY_DECLARED_PAID']);
  const t2 = world(delivered(null));
  assert.equal((await declareLate(t2, 'dA', 'court')).code, 'REASON_REQUIRED');
  assert.equal(t2.order().cashPayment, undefined);
});

test('déclaration refusée une fois le reversement clos (intégral ou régularisé)', async () => {
  const t = world(delivered(null, { status: 'confirmed', amountHandedOver: 3500, amountConfirmed: 3500 }));
  assert.equal((await declareLate(t)).code, 'CASH_ALREADY_FINAL');
});

test('déclarer un non-paiement ne supprime pas la dette : le livreur peut encore déclarer, le restaurant confirmer', async () => {
  const t = world(delivered(null));
  await declareLate(t);
  assert.equal((await t.call('declareCashHandover', 'dA', { amount: 1000 })).success, true);
  const c = await t.call('confirmCashRemittance', 'r1', { amount: 1000 });
  assert.equal(c.success, true);
  assert.equal(t.order().cashRemittance.amountDue, 3500);
  assert.equal(c.data.cash.outstanding, 2500);
  assert.equal(t.order().merchantCashSettled, false);
});

// ── Examen et régularisation administrative ─────────────────────────────────────────────────────────────

test('9. examen : super-admin seul ; confirmation du non-paiement n’efface rien et n’édite aucun wallet', async () => {
  const t = world(delivered(null));
  await declareLate(t);
  for (const uid of ['sub', 'dA', 'r1', 'c1']) {
    const r = await review(t, {}, uid).catch((e) => ({ success: false, code: e.code }));
    assert.equal(r.success, false, uid);
  }
  assert.equal(t.order().cashPayment.verification, 'pending_review');
  const before = t.balances();
  const r = await review(t);
  assert.equal(r.success, true);
  const p = t.order().cashPayment;
  assert.deepEqual([p.verification, p.review.byUid, p.review.decision, p.review.requestId], ['confirmed_unpaid', 'root', 'confirm_unpaid', REQ_A]);
  assert.equal(p.history.length, 2); // déclaration + examen, rien d'écrasé
  assert.equal(t.order().cashRemittance.amountDue, 3500);
  assert.equal(t.flag().status, 'reviewed');
  assert.deepEqual(t.balances(), before);
  assert.equal(t.walletTx().length, 0);
  assert.ok(t.audits.some((a) => a.action === 'partner_order_reviewCashNonPayment' && a.userType === 'admin'));
  // Rejeu idempotent, autre décision refusée (pas de double résolution).
  assert.equal((await review(t)).data.replay, true);
  assert.equal((await review(t, { requestId: REQ_B, decision: 'refute' })).code, 'PAYMENT_ALREADY_REVIEWED');
  assert.equal(t.order().cashPayment.verification, 'confirmed_unpaid');
});

test('examen : infirmer le non-paiement ramène au circuit normal ; sans non-paiement déclaré, refusé', async () => {
  const t = world(delivered(null));
  assert.equal((await review(t)).code, 'NO_NON_PAYMENT_DECLARED');
  await declareLate(t);
  const r = await review(t, { decision: 'refute' });
  assert.equal(r.success, true);
  assert.equal(t.order().cashPayment.verification, 'refuted');
  assert.equal(t.order().cashRemittance.status, 'pending');
  assert.equal((await t.call('declareCashHandover', 'dA', { amount: 3500 })).success, true);
});

test('10. régularisation après non-paiement confirmé : reliquat conservé, historique conservé, jamais de double résolution', async () => {
  const t = world(delivered(null));
  await declareLate(t);
  await review(t);
  const before = t.balances();
  const res = await resolveCash(t, { finalAmount: 1000 });
  assert.equal(res.success, true);
  const o = t.order();
  assert.equal(o.cashRemittance.resolution.finalAmount, 1000);
  assert.equal(o.cashRemittance.resolution.outstanding, 2500);
  assert.equal(o.cashRemittance.amountDue, 3500);
  assert.equal(o.cashPayment.verification, 'confirmed_unpaid');
  assert.equal(o.cashPayment.history.length, 2);
  assert.equal(t.s.get('reconciliation_flags/o1_cash_shortfall').amount, 2500);
  assert.deepEqual(t.balances(), before);
  assert.equal((await resolveCash(t, { requestId: 'resolve-request-0002', finalAmount: 0 })).code, 'CASH_ALREADY_FINAL');
  assert.equal(t.order().cashRemittance.resolution.finalAmount, 1000);
});

test('rapprochement : non-paiement non vérifié signalé sans dette ; confirmé non régularisé en alerte haute', async () => {
  const codes = (o) => (analyzePartnerOrders({ orders: [{ id: 'o1', ...o }], nowMs: 1000 }).rows[0]?.findings || []).map((f) => f.code);
  const t = world(delivered(null));
  await declareLate(t);
  assert.ok(codes(t.order()).includes('V2_CASH_PAYMENT_UNVERIFIED'));
  await review(t);
  assert.ok(codes(t.order()).includes('V2_CASH_UNPAID_CONFIRMED_UNSETTLED'));
  await resolveCash(t, { finalAmount: 0 });
  assert.ok(!codes(t.order()).includes('V2_CASH_UNPAID_CONFIRMED_UNSETTLED'));
});

// ── Concurrence ────────────────────────────────────────────────────────────────────────────────────────

test('13. concurrence livraison / signalement / examen / résolution : états valides, un seul signalement, aucun wallet', async () => {
  for (let i = 0; i < 12; i++) {
    const t = world();
    const before = t.balances();
    const calls = [
      t.deliver({ markCashPaid: i % 2 === 0 ? false : undefined }), declareLate(t), declareLate(t), review(t), review(t, { requestId: REQ_B, decision: 'refute' }),
      resolveCash(t, { finalAmount: 1000 }), declareLate(t, 'dB'),
    ];
    if (i % 3 === 0) calls.reverse();
    await Promise.allSettled(calls);
    const o = t.order();
    assert.equal(o.status, 'delivered');
    assert.equal(o.cashRemittance.amountDue, 3500, `tour ${i}`);
    const p = o.cashPayment;
    assert.ok(['confirmed', 'non_payment_declared', 'unknown'].includes(p.status), `tour ${i} : ${p.status}`);
    if (p.verification !== 'not_required' && p.verification !== 'pending_review') {
      assert.equal(p.status, 'non_payment_declared');
      assert.ok(p.review && [REQ_A, REQ_B].includes(p.review.requestId));
    }
    if (p.status === 'non_payment_declared') assert.equal(p.declaredBy, 'dA');
    assert.ok(p.history.length <= 3, `tour ${i} : historique ${p.history.length}`);
    assert.equal(t.audits.filter((a) => a.action === 'partner_order_reviewCashNonPayment' && !a.status).length <= 1, true);
    assert.deepEqual(t.balances(), before);
    assert.equal(t.walletTx().length, 0);
  }
});

test('7D-5-F : rejeu de la déclaration après examen et clôture du reversement = rejeu, décision intacte', async () => {
  const t = world(delivered(null));
  assert.equal((await declareLate(t)).success, true);
  assert.equal((await review(t)).success, true);
  assert.equal((await resolveCash(t)).success, true);
  const frozen = JSON.stringify([t.order().cashPayment, t.order().cashRemittance]);
  const again = await declareLate(t);
  assert.equal(again.success, true);
  assert.equal(again.data.replay, true);
  assert.equal(JSON.stringify([t.order().cashPayment, t.order().cashRemittance]), frozen);
  // Un signalement NEUF sur un reversement clos reste refusé.
  const closed = world(delivered(null));
  await resolveCash(closed);
  assert.equal((await declareLate(closed)).error, 'CASH_ALREADY_FINAL');
});
