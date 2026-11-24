'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { verifyLegacyCommissionProof, expectedLegacyCommission } = require('../commissionProof');

const ok = { type: 'commission', amount: 100, orderId: 'o1' };
const verdict = (proof, expected = 200) => verifyLegacyCommissionProof({ proof, orderId: 'o1', expected });

test('preuve conforme : montant retenu tel quel (jamais relevé au barème)', () => {
  assert.deepEqual(verdict(ok), { amount: 100, reason: null });
  assert.deepEqual(verdict({ ...ok, amount: 200 }), { amount: 200, reason: null });
});

test('chaque défaut de la preuve est refusé avec une raison explicite', () => {
  const cases = [
    [null, 'proof_missing'], [undefined, 'proof_missing'], ['x', 'proof_missing'],
    [{ ...ok, type: 'refund' }, 'proof_type_invalid'], [{ ...ok, type: 'earning' }, 'proof_type_invalid'],
    [{ ...ok, orderId: 'autre' }, 'proof_order_mismatch'],
    [{ ...ok, amount: 0 }, 'proof_amount_invalid'], [{ ...ok, amount: -5 }, 'proof_amount_invalid'],
    [{ ...ok, amount: 10.5 }, 'proof_amount_invalid'], [{ ...ok, amount: '100' }, 'proof_amount_invalid'],
    [{ ...ok, amount: Number.MAX_SAFE_INTEGER + 2 }, 'proof_amount_invalid'],
    [{ ...ok, provider: 'x' }, 'proof_client_shape'], [{ ...ok, txId: 'y' }, 'proof_client_shape'],
    [{ ...ok, amount: 201 }, 'proof_exceeds_policy'], [{ ...ok, amount: 100000 }, 'proof_exceeds_policy'],
  ];
  for (const [proof, reason] of cases) {
    assert.deepEqual(verdict(proof), { amount: null, reason }, JSON.stringify(proof));
  }
});

test('barème inconnu ou nul : aucun remboursement automatique', () => {
  for (const expected of [null, undefined, 0, -1, 1.5, NaN]) {
    assert.deepEqual(verifyLegacyCommissionProof({ proof: ok, orderId: 'o1', expected }), { amount: null, reason: 'expected_unknown' }, String(expected));
  }
});

test('expectedLegacyCommission : calcul du barème, budget invalide → inconnu', async () => {
  const calc = async (_db, b) => (b < 1000 ? 100 : 200);
  assert.equal(await expectedLegacyCommission({}, { budget: 500 }, calc), 100);
  assert.equal(await expectedLegacyCommission({}, { budget: 1500 }, calc), 200);
  for (const budget of [undefined, null, 0, -10, 'abc', NaN]) {
    assert.equal(await expectedLegacyCommission({}, { budget }, calc), null, String(budget));
  }
  assert.equal(await expectedLegacyCommission({}, null, calc), null);
  assert.equal(await expectedLegacyCommission({}, { budget: 500 }, async () => 0), null);
  assert.equal(await expectedLegacyCommission({}, { budget: 500 }, async () => 'x'), null);
});
