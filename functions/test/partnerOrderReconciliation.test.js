'use strict';

// Données FICTIVES uniquement. Aucun accès Firebase.
const test = require('node:test');
const assert = require('node:assert/strict');
const { analyzePartnerOrders } = require('../partnerOrderReconciliation');
const { buildPartnerAmounts } = require('../partnerOrderAmounts');

const resto = (id, extra = {}) => ({ id, sellerType: 'restaurant', sellerId: 'r1', clientId: 'c1', driverId: 'd1', paymentMethod: 'wallet', isPaid: true, status: 'delivered', budget: 2500, ...extra });
const bakery = (id, extra = {}) => ({ id, sellerType: 'boulangerie', sellerId: 'b1', clientId: 'c1', driverId: 'd1', paymentMethod: 'wallet', isPaid: false, status: 'delivered', itemsAmount: 1800, budget: 500, totalAmount: 2300, ...extra });
const cake = (id, extra = {}) => bakery(id, { orderSubType: 'custom_cake', isPaid: true, itemsAmount: 8000, budget: 700, totalAmount: 8700, ...extra });
const run = (orders, ledgers = {}) => analyzePartnerOrders({ orders, ...ledgers });
const row = (r, id) => r.rows.find((x) => x.orderId === id);
const codes = (r, id) => (row(r, id) ? row(r, id).findings.map((f) => f.code) : []);
const finding = (r, id, code) => row(r, id).findings.find((f) => f.code === code);

test('restaurant wallet livré, partenaire crédité du budget, livreur non crédité : aucun constat financier', () => {
  const r = run([resto('o1')], {
    clientLedger: [{ orderId: 'o1', type: 'purchase', amount: 2500 }],
    partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 2500 }],
  });
  assert.deepEqual(codes(r, 'o1').filter((c) => !c.startsWith('COMMISSION')), []);
  assert.equal(r.summary.bySeverity.critical, 0);
});

test('restaurant : débit client sans crédit partenaire correspondant', () => {
  const r = run([resto('o1')], { clientLedger: [{ orderId: 'o1', type: 'purchase', amount: 2500 }] });
  const f = finding(r, 'o1', 'CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT');
  assert.equal(f.severity, 'critical');
  assert.deepEqual([f.expected, f.actual, f.difference, f.owedTo], [2500, 0, 2500, 'partner']);
});

test('crédit partenaire partiel, double ou excessif détecté', () => {
  const partial = run([resto('o1')], { partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 1000 }] });
  assert.equal(finding(partial, 'o1', 'CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT').difference, 1500);
  const twice = run([resto('o1')], { partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 2500 }, { orderId: 'o1', type: 'earning', amount: 2500 }] });
  assert.ok(codes(twice, 'o1').includes('PARTNER_DOUBLE_CREDIT'));
  assert.ok(codes(twice, 'o1').includes('PARTNER_OVERCREDITED'));
});

test('restaurant : livreur crédité EN PLUS du partenaire (double paiement)', () => {
  const r = run([resto('o1')], {
    partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 2500 }],
    driverLedger: [{ orderId: 'o1', type: 'earning', amount: 500 }],
  });
  assert.ok(codes(r, 'o1').includes('DRIVER_AND_PARTNER_BOTH_CREDITED'));
});

test('boulangerie standard en wallet livrée, jamais payée : articles et frais non encaissés', () => {
  const r = run([bakery('b1o')]);
  const f = finding(r, 'b1o', 'WALLET_NOT_FULLY_COLLECTED');
  assert.equal(f.severity, 'critical');
  assert.deepEqual([f.expected, f.actual, f.difference, f.owedBy], [2300, 0, 2300, 'client']);
});

test('boulangerie standard payée après livraison (frais seuls) : articles non encaissés, livreur payé', () => {
  const r = run([bakery('b1o', { isPaid: true })], {
    clientLedger: [{ orderId: 'b1o', type: 'payment', amount: 500 }],
    driverLedger: [{ orderId: 'b1o', type: 'earning', amount: 500 }],
  });
  assert.equal(finding(r, 'b1o', 'WALLET_NOT_FULLY_COLLECTED').difference, 1800);
  assert.ok(!codes(r, 'b1o').includes('DRIVER_FEE_UNPAID'));
  assert.ok(!codes(r, 'b1o').includes('CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT'), 'le client n a pas payé les articles : la cause est l encaissement');
});

test('gâteau wallet livré : partenaire crédité des seuls frais, livreur non payé, articles perdus', () => {
  const r = run([cake('k1')], { partnerLedger: [{ orderId: 'k1', type: 'earning', amount: 700 }] });
  const missing = finding(r, 'k1', 'CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT');
  assert.deepEqual([missing.expected, missing.actual, missing.difference], [8000, 700, 7300]);
  const driver = finding(r, 'k1', 'DRIVER_FEE_UNPAID');
  assert.deepEqual([driver.expected, driver.actual, driver.difference], [700, 0, 700]);
  assert.ok(codes(r, 'k1').includes('CLIENT_LEDGER_MISSING'));
  assert.equal(row(r, 'k1').collectedFromClient, 8700);
});

test('gâteau annulé : seuls les frais remboursés → remboursement incomplet', () => {
  const r = run([cake('k1', { status: 'cancelled', driverId: undefined })], { clientLedger: [{ orderId: 'k1', type: 'refund', amount: 700 }] });
  const f = finding(r, 'k1', 'REFUND_INCOMPLETE');
  assert.deepEqual([f.expected, f.actual, f.difference, f.owedTo], [8700, 700, 8000, 'client']);
});

test('annulation : jamais remboursée, remboursement exact, sur-remboursement', () => {
  const none = run([resto('o1', { status: 'cancelled' })]);
  assert.equal(finding(none, 'o1', 'CANCELLED_NOT_REFUNDED').difference, 2500);
  const exact = run([resto('o1', { status: 'cancelled' })], { clientLedger: [{ orderId: 'o1', type: 'refund', amount: 2500 }] });
  assert.equal(row(exact, 'o1'), undefined);
  const over = run([resto('o1', { status: 'cancelled' })], { clientLedger: [{ orderId: 'o1', type: 'refund', amount: 3000 }] });
  assert.equal(finding(over, 'o1', 'OVER_REFUNDED').difference, 500);
});

test('annulée avant tout paiement (boulangerie standard) : rien à rembourser', () => {
  const r = run([bakery('b1o', { status: 'cancelled', driverId: undefined })]);
  assert.equal(row(r, 'b1o'), undefined);
});

test('partenaire crédité sur commande annulée ; remboursement sur commande active', () => {
  const a = run([resto('o1', { status: 'cancelled' })], {
    clientLedger: [{ orderId: 'o1', type: 'refund', amount: 2500 }],
    partnerLedger: [{ orderId: 'o1', type: 'earning', amount: 2500 }],
  });
  assert.ok(codes(a, 'o1').includes('PARTNER_CREDITED_ON_CANCELLED'));
  const b = run([resto('o2', { status: 'accepted' })], { clientLedger: [{ orderId: 'o2', type: 'refund', amount: 100 }] });
  assert.ok(codes(b, 'o2').includes('REFUND_ON_ACTIVE_ORDER'));
});

test('écart produits / livraison / total (boulangerie) et montants absents', () => {
  const mismatch = run([bakery('b1o', { totalAmount: 9999 })]);
  assert.equal(finding(mismatch, 'b1o', 'AMOUNT_MISMATCH').severity, 'high');
  const missing = run([bakery('b2o', { itemsAmount: undefined })]);
  assert.ok(codes(missing, 'b2o').includes('AMOUNT_MISMATCH'));
  const resto0 = run([resto('o3', { budget: 'abc' })]);
  assert.ok(codes(resto0, 'o3').includes('AMOUNT_MISMATCH'));
});

test('cash livré : reversement au partenaire en attente / réglé non tracé / réglé tracé', () => {
  const pending = run([resto('o1', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: false })]);
  const f = finding(pending, 'o1', 'CASH_REMITTANCE_PENDING');
  assert.deepEqual([f.amountDueToPartner, f.severity], [2500, 'medium']);
  const bakeryCash = run([bakery('b1o', { paymentMethod: 'cash' })]);
  assert.equal(finding(bakeryCash, 'b1o', 'CASH_REMITTANCE_PENDING').amountDueToPartner, 1800);
  const untraced = run([resto('o2', { paymentMethod: 'cash', merchantCashSettled: true })]);
  assert.ok(codes(untraced, 'o2').includes('CASH_SETTLEMENT_UNTRACED'));
  const traced = run([resto('o3', { paymentMethod: 'cash', merchantCashSettled: true, merchantCashSettledBy: 'adm', merchantCashSettledAt: 1 })]);
  assert.ok(!codes(traced, 'o3').includes('CASH_REMITTANCE_PENDING'));
  assert.ok(!codes(traced, 'o3').includes('CASH_SETTLEMENT_UNTRACED'));
});

test('commission : informations seulement (non tracée, calculée sur les plats)', () => {
  const ledgers = (id) => ({
    clientLedger: [{ orderId: id, type: 'purchase', amount: 2500 }],
    partnerLedger: [{ orderId: id, type: 'earning', amount: 2500 }],
  });
  const traced = run([resto('o1', { commissionStatus: 'charged', commissionAmount: 200 })], ledgers('o1'));
  assert.deepEqual(codes(traced, 'o1'), ['COMMISSION_ON_PRODUCT_BASE']);
  assert.equal(row(traced, 'o1').worstSeverity, 'info');
  const untraced = run([resto('o2')], ledgers('o2'));
  assert.deepEqual(codes(untraced, 'o2'), ['COMMISSION_UNTRACED']);
});

test('périmètre : commandes versionnées et autres services ignorées ; entrées jamais modifiées', () => {
  const versioned = { id: 'v1', sellerType: 'restaurant', paymentMethod: 'wallet', isPaid: true, status: 'delivered', ...buildPartnerAmounts(3000, 700) };
  const other = { id: 'x1', sellerType: 'seller', paymentMethod: 'wallet', budget: 1000 };
  const orders = [versioned, other, resto('o1')];
  const snapshot = JSON.stringify(orders);
  const r = run(orders, { partnerLedger: [], clientLedger: [] });
  assert.equal(JSON.stringify(orders), snapshot, 'entrées intactes');
  assert.equal(r.summary.versionedSkipped, 1);
  assert.equal(r.summary.outOfScope, 1);
  assert.equal(r.summary.ordersAnalyzed, 1);
  assert.equal(row(r, 'v1'), undefined);
});

test('rapport : tri par gravité, résumé par code, clé de décision unique par commande, aucune action automatique', () => {
  const r = run([resto('o1', { paymentMethod: 'cash', isPaid: false }), cake('k1'), resto('o2', { status: 'cancelled' })]);
  assert.equal(r.rows[0].worstSeverity, 'critical');
  assert.ok(r.summary.bySeverity.critical >= 2);
  assert.equal(new Set(r.rows.map((x) => x.decisionKey)).size, r.rows.length);
  assert.ok(r.rows.every((x) => /^partner_reconcile_/.test(x.decisionKey)));
  assert.ok(r.rows.every((x) => !('refund' in x) && !('apply' in x)), 'aucune écriture proposée');
  assert.equal(typeof r.summary.byCode.CANCELLED_NOT_REFUNDED, 'number');
});

test('rapport anonymisé : aucun identifiant ni texte libre en clair, empreintes stables avec le même sel', () => {
  const { anonymizeReport } = require('../partnerOrderReconciliation');
  const report = run([cake('order-secret-1', { sellerId: 'partner-secret', clientId: 'client-secret', status: 'cancelled', clientName: 'Awa Koné', clientPhone: '+2250700000000' })], {
    clientLedger: [{ orderId: 'order-secret-1', type: 'refund', amount: 700 }],
  });
  const a = anonymizeReport(report, 'sel-test');
  const text = JSON.stringify(a);
  for (const secret of ['order-secret-1', 'partner-secret', 'client-secret', 'd1', 'Awa', '+2250700000000', 'partner_reconcile_']) {
    assert.ok(!text.includes(secret), `fuite : ${secret}`);
  }
  assert.match(a.rows[0].orderRef, /^order_[0-9a-f]{12}$/);
  assert.equal(a.rows[0].findings[0].code, 'REFUND_INCOMPLETE');
  assert.equal(a.rows[0].findings[0].difference, 8000);
  assert.equal(anonymizeReport(report, 'sel-test').rows[0].orderRef, a.rows[0].orderRef);
  assert.notEqual(anonymizeReport(report, 'autre-sel').rows[0].orderRef, a.rows[0].orderRef);
  assert.deepEqual(a.summary, report.summary);
});

test('entrées vides ou absentes', () => {
  assert.deepEqual(analyzePartnerOrders().rows, []);
  assert.equal(run([]).summary.ordersAnalyzed, 0);
});
