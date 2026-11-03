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

test('périmètre : autres services ignorés, commandes versionnées analysées à part ; entrées jamais modifiées', () => {
  const versioned = { id: 'v1', sellerType: 'restaurant', paymentMethod: 'wallet', isPaid: true, status: 'delivered', ...buildPartnerAmounts(3000, 700) };
  const other = { id: 'x1', sellerType: 'seller', paymentMethod: 'wallet', budget: 1000 };
  const orders = [versioned, other, resto('o1')];
  const snapshot = JSON.stringify(orders);
  const r = run(orders, { partnerLedger: [], clientLedger: [] });
  assert.equal(JSON.stringify(orders), snapshot, 'entrées intactes');
  assert.equal(r.summary.versionedAnalyzed, 1);
  assert.equal(r.summary.versionedSkipped, 0);
  assert.equal(r.summary.outOfScope, 1);
  assert.equal(r.summary.ordersAnalyzed, 2);
  assert.ok(codes(r, 'v1').includes('V2_CLIENT_DEBIT_MISSING'), 'la v2 livrée sans journal est désormais analysée');
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

// ── Commandes versionnées (amountsVersion 2) — Mission 7B-3A, correctif A2 ───────────────────────────────────

const NOW = Date.UTC(2026, 10, 3, 12, 0, 0);
const v2o = (id, extra = {}) => ({
  id, sellerType: 'restaurant', sellerId: 'r1', clientId: 'c1', driverId: 'd1', paymentMethod: 'wallet', isPaid: true, status: 'delivered',
  ...buildPartnerAmounts(3500, 500), commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100, ...extra,
});
const L = (orderId, type, amount) => ({ orderId, type, amount });
const okLedgers = (id) => ({
  clientLedger: [L(id, 'payment', 4000)], partnerLedger: [L(id, 'earning', 3500)], driverLedger: [L(id, 'commission', 100), L(id, 'earning', 500)],
});
const runV2 = (orders, ledgers = {}, extra = {}) => analyzePartnerOrders({ orders, nowMs: NOW, ...ledgers, ...extra });

test('v2 wallet livrée et conforme (débit total, produits au partenaire, frais au livreur, une fois chacun) : aucun constat', () => {
  const r = runV2([v2o('a1')], okLedgers('a1'));
  assert.equal(r.summary.versionedAnalyzed, 1);
  assert.equal(r.summary.versionedSkipped, 0);
  assert.equal(r.summary.ordersAnalyzed, 1);
  assert.deepEqual(r.rows, []);
});

test('v2 non livrée : jamais signalée pour absence de crédit partenaire ou livreur', () => {
  for (const status of ['pending', 'broadcast', 'assigned', 'accepted', 'picked_up']) {
    const r = runV2([v2o('a2', { status })], { clientLedger: [L('a2', 'payment', 4000)] });
    assert.deepEqual(codes(r, 'a2'), [], status);
  }
  const early = runV2([v2o('a3', { status: 'accepted' })], { clientLedger: [L('a3', 'payment', 4000)], partnerLedger: [L('a3', 'earning', 3500)] });
  assert.ok(codes(early, 'a3').includes('V2_CREDIT_BEFORE_DELIVERY'), 'crédit AVANT livraison signalé');
});

test('v2 livrée : crédits manquants, doubles, excessifs ou insuffisants détectés', () => {
  const noPartner = runV2([v2o('b1')], { clientLedger: [L('b1', 'payment', 4000)], driverLedger: [L('b1', 'earning', 500)] });
  assert.deepEqual(finding(noPartner, 'b1', 'V2_PARTNER_CREDIT_MISSING').owedTo, 'partner');
  const dblP = runV2([v2o('b2')], { clientLedger: [L('b2', 'payment', 4000)], partnerLedger: [L('b2', 'earning', 3500), L('b2', 'earning', 3500)], driverLedger: [L('b2', 'earning', 500)] });
  assert.ok(codes(dblP, 'b2').includes('V2_PARTNER_DOUBLE_CREDIT'));
  assert.ok(codes(dblP, 'b2').includes('V2_PARTNER_OVERCREDITED'));
  const under = runV2([v2o('b3')], { clientLedger: [L('b3', 'payment', 4000)], partnerLedger: [L('b3', 'earning', 3000)], driverLedger: [L('b3', 'earning', 500)] });
  assert.equal(finding(under, 'b3', 'V2_PARTNER_UNDERCREDITED').difference, 500);
  const noDriver = runV2([v2o('b4')], { clientLedger: [L('b4', 'payment', 4000)], partnerLedger: [L('b4', 'earning', 3500)] });
  assert.equal(finding(noDriver, 'b4', 'V2_DRIVER_FEE_MISSING').owedTo, 'driver');
  const dblD = runV2([v2o('b5')], { clientLedger: [L('b5', 'payment', 4000)], partnerLedger: [L('b5', 'earning', 3500)], driverLedger: [L('b5', 'earning', 500), L('b5', 'earning', 500)] });
  assert.ok(codes(dblD, 'b5').includes('V2_DRIVER_DOUBLE_CREDIT'));
  assert.ok(codes(dblD, 'b5').includes('V2_DRIVER_OVERCREDITED'));
  // Produits crédités au livreur à la place des frais : le plus grave des cas.
  const swapped = runV2([v2o('b6')], { clientLedger: [L('b6', 'payment', 4000)], partnerLedger: [L('b6', 'earning', 500)], driverLedger: [L('b6', 'earning', 3500)] });
  assert.ok(codes(swapped, 'b6').includes('V2_DRIVER_OVERCREDITED'));
  assert.ok(codes(swapped, 'b6').includes('V2_PARTNER_UNDERCREDITED'));
});

test('v2 : débit client absent ou différent du total ; wallet non marqué payé', () => {
  assert.equal(finding(runV2([v2o('c1')], { partnerLedger: [L('c1', 'earning', 3500)], driverLedger: [L('c1', 'earning', 500)] }), 'c1', 'V2_CLIENT_DEBIT_MISSING').expected, 4000);
  const mism = runV2([v2o('c2')], { clientLedger: [L('c2', 'payment', 500)], partnerLedger: [L('c2', 'earning', 3500)], driverLedger: [L('c2', 'earning', 500)] });
  assert.equal(finding(mism, 'c2', 'V2_CLIENT_DEBIT_MISMATCH').severity, 'critical');
  assert.ok(codes(runV2([v2o('c3', { isPaid: false })], okLedgers('c3')), 'c3').includes('V2_WALLET_NOT_MARKED_PAID'));
});

test('v2 annulée : remboursement du total exact attendu ; manquant, partiel ou excessif détecté ; aucun crédit toléré', () => {
  const good = runV2([v2o('d1', { status: 'cancelled' })], { clientLedger: [L('d1', 'payment', 4000), L('d1', 'refund', 4000)] });
  assert.deepEqual(codes(good, 'd1'), []);
  assert.equal(finding(runV2([v2o('d2', { status: 'cancelled' })], { clientLedger: [L('d2', 'payment', 4000)] }), 'd2', 'V2_CANCELLED_NOT_REFUNDED').expected, 4000);
  assert.equal(finding(runV2([v2o('d3', { status: 'cancelled' })], { clientLedger: [L('d3', 'payment', 4000), L('d3', 'refund', 500)] }), 'd3', 'V2_REFUND_INCOMPLETE').difference, 3500);
  const over = runV2([v2o('d4', { status: 'cancelled' })], { clientLedger: [L('d4', 'payment', 4000), L('d4', 'refund', 4000), L('d4', 'refund', 4000)] });
  assert.ok(codes(over, 'd4').includes('V2_OVER_REFUNDED'));
  const credited = runV2([v2o('d5', { status: 'cancelled' })], { clientLedger: [L('d5', 'payment', 4000), L('d5', 'refund', 4000)], partnerLedger: [L('d5', 'earning', 3500)], driverLedger: [L('d5', 'earning', 500)] });
  assert.ok(codes(credited, 'd5').includes('V2_PARTNER_CREDITED_ON_CANCELLED'));
  assert.ok(codes(credited, 'd5').includes('V2_DRIVER_CREDITED_ON_CANCELLED'));
  assert.ok(codes(runV2([v2o('d6', { status: 'accepted' })], { clientLedger: [L('d6', 'payment', 4000), L('d6', 'refund', 4000)] }), 'd6').includes('V2_REFUND_ON_ACTIVE_ORDER'));
});

test('v2 annulée avec frais retenus par décision administrative : produits rendus acceptés, retenue signalée en attente', () => {
  const held = runV2([v2o('e1', { status: 'cancelled', deliveryFeeHold: { amount: 500, status: 'pending_admin_review' } })], { clientLedger: [L('e1', 'payment', 4000), L('e1', 'refund', 3500)] });
  assert.deepEqual(codes(held, 'e1'), ['V2_FEE_HOLD_PENDING']);
  assert.equal(row(held, 'e1').worstSeverity, 'medium');
  const resolvedRefund = runV2([v2o('e2', { status: 'cancelled', deliveryFeeHold: { amount: 500, status: 'resolved', decision: 'refundClient' } })], { clientLedger: [L('e2', 'payment', 4000), L('e2', 'refund', 3500)] });
  assert.ok(codes(resolvedRefund, 'e2').includes('V2_REFUND_INCOMPLETE'), 'frais à rendre mais seulement les produits remboursés');
  const resolvedPay = runV2([v2o('e3', { status: 'cancelled', deliveryFeeHold: { amount: 500, status: 'resolved', decision: 'payDriver' } })], { clientLedger: [L('e3', 'payment', 4000), L('e3', 'refund', 3500)], driverLedger: [L('e3', 'earning', 500)] });
  assert.deepEqual(codes(resolvedPay, 'e3'), []);
});

test('v2 remboursement partiel : autorisé seulement par décision administrative et au montant décidé', () => {
  const ok = runV2([v2o('f1', { deliveryClosedBy: 'admin_dispute', disputeDecision: { financialTreatment: 'partial_refund', clientRefund: 1000 } })], { clientLedger: [L('f1', 'payment', 4000), L('f1', 'refund', 1000)] });
  assert.deepEqual(codes(ok, 'f1'), ['V2_PARTIAL_REFUND_AUTHORIZED']);
  const wrong = runV2([v2o('f2', { deliveryClosedBy: 'admin_dispute', disputeDecision: { financialTreatment: 'partial_refund', clientRefund: 1000 } })], { clientLedger: [L('f2', 'payment', 4000), L('f2', 'refund', 2000)] });
  assert.ok(codes(wrong, 'f2').includes('V2_PARTIAL_REFUND_MISMATCH'));
  const unauthorized = runV2([v2o('f3')], { ...okLedgers('f3'), clientLedger: [L('f3', 'payment', 4000), L('f3', 'refund', 1000)] });
  assert.ok(codes(unauthorized, 'f3').includes('V2_REFUND_ON_DELIVERED'));
});

test('v2 cash : aucun débit, crédit ni remboursement wallet ; reversement tracé', () => {
  const base = v2o('g1', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: false, cashRemittance: { status: 'pending', amountDue: 3500, deliveredAtMs: NOW - 3600000 } });
  const pending = runV2([base]);
  assert.deepEqual(codes(pending, 'g1'), ['V2_CASH_REMITTANCE_PENDING']);
  assert.equal(row(pending, 'g1').worstSeverity, 'info');
  const bad = runV2([base], { clientLedger: [L('g1', 'payment', 4000), L('g1', 'refund', 4000)], partnerLedger: [L('g1', 'earning', 3500)], driverLedger: [L('g1', 'earning', 500)] });
  for (const c of ['V2_CASH_WALLET_DEBIT', 'V2_CASH_REFUND', 'V2_CASH_WALLET_CREDIT']) assert.ok(codes(bad, 'g1').includes(c), c);
  const missing = runV2([v2o('g2', { paymentMethod: 'cash', isPaid: false })]);
  assert.deepEqual(codes(missing, 'g2'), ['V2_CASH_REMITTANCE_MISSING']);
  // Annulée en cash : rien à rapprocher.
  assert.deepEqual(codes(runV2([v2o('g3', { paymentMethod: 'cash', isPaid: false, status: 'cancelled' })]), 'g3'), []);
});

test('v2 cash : retard de reversement (> 24 h) = alerte, jamais sanction ; une déclaration du livreur seule ne vaut pas règlement', () => {
  const late = runV2([v2o('h1', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: false, cashRemittance: { status: 'pending', amountDue: 3500, deliveredAtMs: NOW - 25 * 3600000 } })]);
  assert.deepEqual(codes(late, 'h1'), ['V2_CASH_REMITTANCE_OVERDUE']);
  assert.equal(row(late, 'h1').worstSeverity, 'medium');
  const declared = runV2([v2o('h2', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: true, cashRemittance: { status: 'declared', amountDue: 3500, amountHandedOver: 3500, deliveredAtMs: NOW - 3600000 } })]);
  assert.ok(codes(declared, 'h2').includes('V2_CASH_SETTLED_WITHOUT_CONFIRMATION'));
  const wrongDue = runV2([v2o('h3', { paymentMethod: 'cash', isPaid: false, cashRemittance: { status: 'pending', amountDue: 4000, deliveredAtMs: NOW } })]);
  assert.equal(finding(wrongDue, 'h3', 'V2_CASH_AMOUNT_MISMATCH').severity, 'critical');
});

test('v2 cash : confirmation du partenaire — complète, partielle (reliquat), contestée, non tracée, supérieure au dû', () => {
  const conf = (r) => v2o('i', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: true, cashRemittance: { amountDue: 3500, deliveredAtMs: NOW - 1000, ...r } });
  assert.deepEqual(codes(runV2([{ ...conf({ status: 'confirmed', amountConfirmed: 3500, partnerConfirmedAtMs: NOW, confirmedBy: 'r1' }), id: 'i1' }]), 'i1'), []);
  const short = runV2([{ ...conf({ status: 'confirmed', amountConfirmed: 3000, partnerConfirmedAtMs: NOW, confirmedBy: 'r1' }), id: 'i2' }]);
  assert.equal(finding(short, 'i2', 'V2_CASH_SHORTFALL').difference, 500);
  const disputed = runV2([{ ...v2o('i3', { paymentMethod: 'cash', isPaid: false, merchantCashSettled: false, cashRemittance: { status: 'disputed', amountDue: 3500, deliveredAtMs: NOW } }) }]);
  assert.deepEqual(codes(disputed, 'i3'), ['V2_CASH_DISPUTED']);
  assert.ok(codes(runV2([{ ...conf({ status: 'confirmed', amountConfirmed: 3500 }), id: 'i4' }]), 'i4').includes('V2_CASH_CONFIRMATION_UNTRACED'));
  assert.ok(codes(runV2([{ ...conf({ status: 'confirmed', amountConfirmed: 9000, partnerConfirmedAtMs: NOW, confirmedBy: 'r1' }), id: 'i5' }]), 'i5').includes('V2_CASH_CONFIRMED_ABOVE_DUE'));
});

test('v2 course transférée : gain livreur retenu = information, jamais une anomalie ; livreur crédité pendant la retenue = critique', () => {
  const held = runV2([v2o('j1', { settlementHold: true, heldDriverEarning: 500, settlementStatus: 'pending_admin_review' })], { clientLedger: [L('j1', 'payment', 4000)], partnerLedger: [L('j1', 'earning', 3500)] });
  assert.deepEqual(codes(held, 'j1'), ['V2_DRIVER_EARNING_HELD']);
  const bad = runV2([v2o('j2', { settlementHold: true, heldDriverEarning: 500, settlementStatus: 'pending_admin_review' })], { clientLedger: [L('j2', 'payment', 4000)], partnerLedger: [L('j2', 'earning', 3500)], driverLedger: [L('j2', 'earning', 500)] });
  assert.ok(codes(bad, 'j2').includes('V2_DRIVER_CREDITED_WHILE_HELD'));
  const settled = runV2([v2o('j3', { settlementHold: false, heldDriverEarning: 500, settlementStatus: 'settled' })], { clientLedger: [L('j3', 'payment', 4000)], partnerLedger: [L('j3', 'earning', 3500)], driverLedger: [L('j3', 'earning', 300)] });
  assert.deepEqual(codes(settled, 'j3'), []);
});

test('v2 partenaire introuvable à la livraison : régularisation connue (signalement ouvert) = moyen ; sans signalement = critique', () => {
  const ledgers = { clientLedger: [L('k1', 'payment', 4000)], driverLedger: [L('k1', 'earning', 500)] };
  const flagged = runV2([v2o('k1')], ledgers, { reconciliationFlags: [{ orderId: 'k1', type: 'partner_credit_missing', status: 'open' }] });
  assert.deepEqual(codes(flagged, 'k1'), ['V2_PARTNER_CREDIT_FLAGGED']);
  assert.equal(row(flagged, 'k1').worstSeverity, 'medium');
  assert.ok(codes(runV2([v2o('k1')], ledgers), 'k1').includes('V2_PARTNER_CREDIT_MISSING'));
});

test('v2 : commission jamais supérieure aux frais, jamais prélevée deux fois ; montants incohérents signalés (jamais traités comme historique)', () => {
  assert.ok(codes(runV2([v2o('l1', { commissionAmount: 600 })], okLedgers('l1')), 'l1').includes('V2_COMMISSION_EXCEEDS_FEE'));
  const twice = { ...okLedgers('l2'), driverLedger: [L('l2', 'commission', 100), L('l2', 'commission', 100), L('l2', 'earning', 500)] };
  assert.ok(codes(runV2([v2o('l2')], twice), 'l2').includes('V2_COMMISSION_DOUBLE'));
  const inconsistent = runV2([{ ...v2o('l3'), totalAmount: 1 }]);
  assert.deepEqual(codes(inconsistent, 'l3'), ['V2_AMOUNTS_INCONSISTENT']);
  assert.equal(inconsistent.summary.versionedAnalyzed, 1);
});

test('v2 : analyse en lecture seule, anonymisation sans fuite, historique conservé dans le même rapport', () => {
  const { anonymizeReport } = require('../partnerOrderReconciliation');
  const orders = [v2o('secret-order-9', { sellerId: 'secret-partner', clientId: 'secret-client', paymentMethod: 'cash', isPaid: false, merchantCashSettled: true, cashRemittance: { status: 'declared', amountDue: 3500, deliveredAtMs: NOW } }), resto('o1')];
  const snapshot = JSON.stringify(orders);
  const r = runV2(orders, { clientLedger: [L('o1', 'purchase', 2500)], partnerLedger: [L('o1', 'earning', 2500)] });
  assert.equal(JSON.stringify(orders), snapshot, 'entrées intactes');
  assert.ok(r.rows.every((x) => !('apply' in x) && !('refund' in x)));
  assert.deepEqual(codes(r, 'o1').filter((c) => !c.startsWith('COMMISSION')), [], 'historique : constats inchangés');
  const text = JSON.stringify(anonymizeReport(r, 'sel'));
  for (const s of ['secret-order-9', 'secret-partner', 'secret-client', 'partner_reconcile_']) assert.ok(!text.includes(s), s);
  assert.match(text, /V2_CASH_SETTLED_WITHOUT_CONFIRMATION/);
});
