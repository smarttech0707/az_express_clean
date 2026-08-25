'use strict';

const DEPOSIT_STATUSES = Object.freeze({
  pending: 'pending', assigned: 'assigned', awaitingDeposit: 'awaiting_deposit',
  proofSent: 'deposit_proof_sent', confirmed: 'deposit_confirmed',
  rejected: 'deposit_rejected', inProgress: 'in_progress', proofSentByAgent: 'proof_sent',
  completed: 'completed', cancelled: 'cancelled', disputed: 'disputed',
});

function selectDepositAccount(agent, operator) {
  const accounts = Array.isArray(agent?.depositAccounts) ? agent.depositAccounts : [];
  const matching = accounts
    .filter((account) => account && account.operator === operator && account.isActive !== false
      && typeof account.phoneNumber === 'string' && account.phoneNumber.trim().length >= 8)
    .sort((a, b) => {
      if (Boolean(a.isPrimary) !== Boolean(b.isPrimary)) return a.isPrimary ? -1 : 1;
      return String(a.id || '').localeCompare(String(b.id || ''));
    });
  if (matching.length) {
    const account = matching[0];
    return { id: String(account.id || ''), phoneNumber: account.phoneNumber.trim(), operator };
  }
  // Compatibility for agents not yet migrated to depositAccounts.
  const value = agent?.operatorNumbers?.[operator];
  if (typeof value !== 'string' || value.trim().length < 8) return null;
  return { id: `legacy_${operator}`, phoneNumber: value.trim(), operator };
}

function selectDepositNumber(agent, operator) {
  return selectDepositAccount(agent, operator)?.phoneNumber || null;
}

function isEligibleAgent(agent) {
  return agent?.isVerified === true && agent?.isSuspended !== true
    && ['trial', 'active'].includes(agent?.subscriptionStatus);
}

function assertStatus(order, expected, message) {
  if (order.status !== expected) {
    const error = new Error(message || `Transition invalide depuis ${order.status}`);
    error.code = 'failed-precondition';
    throw error;
  }
}

module.exports = { DEPOSIT_STATUSES, selectDepositAccount, selectDepositNumber, isEligibleAgent, assertStatus };
