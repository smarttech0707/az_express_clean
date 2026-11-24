'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { selectDepositAccount, selectDepositNumber, isEligibleAgent, assertStatus, DEPOSIT_STATUSES } = require('../ekbineFlow');

test('E-Kbine: selects the exact deposit number for Orange and MTN', () => {
  const agent = { operatorNumbers: { orange: '0700000001', mtn: '0500000002' } };
  assert.equal(selectDepositNumber(agent, 'orange'), '0700000001');
  assert.equal(selectDepositNumber(agent, 'mtn'), '0500000002');
});

test('E-Kbine: rejects an agent with no number for the requested operator', () => {
  assert.equal(selectDepositNumber({ operatorNumbers: { orange: '0700000001' } }, 'wave'), null);
});

test('E-Kbine: selects the active primary account, then a deterministic active fallback', () => {
  const agent = { depositAccounts: [
    { id: 'orange-b', operator: 'orange', phoneNumber: '0700000002', isActive: true },
    { id: 'orange-a', operator: 'orange', phoneNumber: '0700000001', isPrimary: true, isActive: true },
    { id: 'orange-off', operator: 'orange', phoneNumber: '0700000003', isPrimary: true, isActive: false },
  ] };
  assert.deepEqual(selectDepositAccount(agent, 'orange'), {
    id: 'orange-a', operator: 'orange', phoneNumber: '0700000001',
  });
  assert.equal(selectDepositNumber({ depositAccounts: [{ id: 'mtn-z', operator: 'mtn', phoneNumber: '0500000002', isActive: true }] }, 'mtn'), '0500000002');
});

test('E-Kbine: only verified, non-suspended trial/active agents are eligible', () => {
  assert.equal(isEligibleAgent({ isVerified: true, isSuspended: false, subscriptionStatus: 'trial' }), true);
  assert.equal(isEligibleAgent({ isVerified: true, isSuspended: true, subscriptionStatus: 'active' }), false);
  assert.equal(isEligibleAgent({ isVerified: true, isSuspended: false, subscriptionStatus: 'expired' }), false);
});

test('E-Kbine: agent cannot start before deposit confirmation and confirmation is idempotent', () => {
  assert.throws(() => assertStatus({ status: DEPOSIT_STATUSES.proofSent }, DEPOSIT_STATUSES.confirmed));
  assert.doesNotThrow(() => assertStatus({ status: DEPOSIT_STATUSES.confirmed }, DEPOSIT_STATUSES.confirmed));
});
