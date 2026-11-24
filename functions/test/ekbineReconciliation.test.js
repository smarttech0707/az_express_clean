'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { analyzeLegacyEkOrders } = require('../ekbineReconciliation');

const ts = (ms) => ({ toMillis: () => ms });
const T = 1700000000000;
const order = (id, extra = {}) => ({ id, clientId: 'c1', agentId: 'a1', paymentMethod: 'wallet', amount: 1000, status: 'pending', createdAt: ts(T), ...extra });
const debit = (id, extra = {}) => ({ id, uid: 'c1', amount: -1000, createdAt: ts(T - 3000), ...extra });
const run = (o) => analyzeLegacyEkOrders({ debits: [], creditedOrderIds: [], refundLedger: [], ...o });
const row = (r, id) => r.rows.find((x) => x.orderId === id);

test('commandes traitées par le serveur et commandes hors wallet exclues (aucun double traitement)', () => {
  const r = run({ orders: [
    order('a', { walletDebited: true, debitedAmount: 1000 }), order('b', { refunded: true }), order('c', { agentCredited: 0 }),
    order('d', { paymentMethod: 'orange_money' }), order('e'),
  ], debits: [debit('d1')] });
  assert.deepEqual(r.rows.map((x) => x.orderId), ['e']);
});

test('annulée sans remboursement avec débit unique → client à rembourser SI confirmé (jamais automatique)', () => {
  const r = run({ orders: [order('o1', { status: 'cancelled' })], debits: [debit('d1')] });
  assert.equal(row(r, 'o1').action, 'client_refund_to_decide');
  assert.equal(row(r, 'o1').debitEvidence, 'single_candidate');
  assert.equal(r.summary.clientRefundToDecide, 1);
});

test('annulée mais déjà remboursée dans le journal → rien à faire', () => {
  const r = run({ orders: [order('o1', { status: 'cancelled' })], debits: [debit('d1')], refundLedger: [{ orderId: 'o1' }] });
  assert.equal(row(r, 'o1').action, 'none');
});

test('annulée sans aucun débit retrouvé → vérifier le débit avant tout remboursement', () => {
  assert.equal(row(run({ orders: [order('o1', { status: 'cancelled' })] }), 'o1').action, 'verify_debit_first');
});

test('terminée : agent déjà crédité tracé / non tracé / crédité sans débit', () => {
  const r = run({
    orders: [order('p', { status: 'completed' }), order('q', { status: 'completed', createdAt: ts(T + 3600000) }),
      order('s', { status: 'completed', createdAt: ts(T + 7200000) })],
    debits: [debit('dp'), debit('dq', { createdAt: ts(T + 3600000 - 2000) })],
    creditedOrderIds: ['p', 's'],
  });
  assert.equal(row(r, 'p').action, 'none');
  assert.equal(row(r, 'q').action, 'agent_pay_to_decide');
  assert.equal(row(r, 's').action, 'agent_paid_without_debit_review');
});

test('un même débit ne justifie jamais deux commandes (appariement un-pour-un)', () => {
  const r = run({ orders: [order('o1', { status: 'cancelled' }), order('o2', { status: 'cancelled', createdAt: ts(T + 5000) })], debits: [debit('d1')] });
  assert.equal(row(r, 'o1').debitEvidence, 'single_candidate');
  assert.equal(row(r, 'o2').debitEvidence, 'none');
});

test('plusieurs débits plausibles → ambigu, signalé', () => {
  const r = run({ orders: [order('o1', { status: 'cancelled' })], debits: [debit('d1'), debit('d2', { createdAt: ts(T - 9000) })] });
  assert.equal(row(r, 'o1').debitEvidence, 'ambiguous');
  assert.equal(r.summary.ambiguousDebit, 1);
});

test('débit d\'un autre client, d\'un autre montant ou hors fenêtre : ignoré', () => {
  const r = run({ orders: [order('o1', { status: 'cancelled' })], debits: [
    debit('x1', { uid: 'c2' }), debit('x2', { amount: -2000 }), debit('x3', { createdAt: ts(T - 3600000) }), debit('x4', { createdAt: ts(T + 600000) })] });
  assert.equal(row(r, 'o1').debitEvidence, 'none');
});

test('clé de décision stable par commande ; la fonction ne modifie pas ses entrées', () => {
  const orders = [order('o1', { status: 'cancelled' })];
  const copy = JSON.stringify(orders);
  const r = run({ orders, debits: [debit('d1')] });
  assert.equal(row(r, 'o1').decisionKey, 'ek_reconcile_o1');
  assert.equal(JSON.stringify(orders), copy);
});
