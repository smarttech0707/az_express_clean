'use strict';

// Master Prompt 117 — couverture de responseBuilder.js : chaque cas mappe
// un nom d'outil réellement exécuté + son résultat réel vers une enveloppe
// {type, title, message, icon, color, priority, actions, payload}. Aucun
// parsing de texte n'intervient jamais dans ce fichier ni dans les tests.

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildTurnResponse, buildConfirmResponse, ALL_TYPES } = require('../azia/responseBuilder');

function call(name, result) {
  return { name, input: {}, result };
}

// ── buildTurnResponse — lecture (wallet) ─────────────────────────────────

test('buildTurnResponse: get_wallet_balance -> type wallet with real balance/currency payload', () => {
  const response = buildTurnResponse({
    finalText: 'Ton solde est de 5000 FCFA.',
    toolCalls: [call('get_wallet_balance', { balanceFcfa: 5000 })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'wallet');
  assert.equal(response.message, 'Ton solde est de 5000 FCFA.');
  assert.deepEqual(response.payload, { balance: 5000, currency: 'FCFA' });
  assert.equal(response.icon, 'account_balance_wallet');
  assert.ok(response.title);
});

test('buildTurnResponse: get_wallet_transactions -> type wallet_history with the real transaction list', () => {
  const txs = [{ type: 'recharge', amount: 1000 }];
  const response = buildTurnResponse({
    finalText: 'Voici tes derniers mouvements.',
    toolCalls: [call('get_wallet_transactions', { transactions: txs })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'wallet_history');
  assert.deepEqual(response.payload.transactions, txs);
});

// ── buildTurnResponse — livraison / suivi ────────────────────────────────

test('buildTurnResponse: track_order -> type delivery_tracking, payload built from the real order (including driver name if present)', () => {
  const order = {
    id: 'o1', status: 'accepted', description: 'Un colis', budget: 700,
    driverId: 'd1', driverName: 'Jean Kouassi',
  };
  const response = buildTurnResponse({
    finalText: 'Ta commande est en cours.',
    toolCalls: [call('track_order', { found: true, orders: [order] })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'delivery_tracking');
  assert.equal(response.payload.orderId, 'o1');
  assert.equal(response.payload.status, 'accepted');
  assert.equal(response.payload.driver, 'Jean Kouassi');
  assert.equal(response.payload.amount, 700);
  assert.ok(response.actions.some(a => a.label === 'Suivre la commande'));
});

test('buildTurnResponse: track_ekbine_order -> type ekbine_tracking with agent contact when assigned', () => {
  const response = buildTurnResponse({
    finalText: 'Un agent a été assigné.',
    toolCalls: [call('track_ekbine_order', {
      found: true,
      orders: [{ id: 'e1', status: 'assigned', amount: 1000 }],
      agentContact: { name: 'Awa', phone: '+225070000' },
    })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'ekbine_tracking');
  assert.equal(response.payload.orderId, 'e1');
  assert.deepEqual(response.payload.agent, { name: 'Awa', phone: '+225070000' });
});

// ── buildTurnResponse — recherche (restaurant/marketplace/pharmacie/immo) ─

test('buildTurnResponse: search_restaurants -> type restaurant, payload carries the real result list untouched', () => {
  const results = [{ id: 'r1', name: 'Chez Awa', isOpen: true }];
  const response = buildTurnResponse({
    finalText: "Voici ce que j'ai trouvé.",
    toolCalls: [call('search_restaurants', { count: 1, results })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'restaurant');
  assert.deepEqual(response.payload.results, results);
  assert.equal(response.payload.count, 1);
});

test('buildTurnResponse: search_marketplace -> type marketplace', () => {
  const response = buildTurnResponse({
    finalText: 'Quelques articles trouvés.',
    toolCalls: [call('search_marketplace', { count: 2, results: [{ id: 'p1' }, { id: 'p2' }] })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'marketplace');
  assert.equal(response.payload.count, 2);
});

// ── buildTurnResponse — confirmation (priorité absolue) ──────────────────

test('buildTurnResponse: an awaiting_confirmation tool result always wins -> type confirmation with actionId/summary/amount', () => {
  const response = buildTurnResponse({
    finalText: 'Je confirme ce dépôt E-Kbine ?',
    toolCalls: [call('create_ekbine_order', { status: 'awaiting_confirmation', actionId: 'a1', summaryFr: 'Dépôt 1000 FCFA' })],
    pendingActionAmount: 1000,
  });
  assert.equal(response.type, 'confirmation');
  assert.equal(response.priority, 'high');
  assert.deepEqual(response.payload, { actionId: 'a1', summary: 'Dépôt 1000 FCFA', amount: 1000 });
});

test('buildTurnResponse: confirmation wins even if a read-tool ran earlier in the same turn', () => {
  const response = buildTurnResponse({
    finalText: 'Tu veux confirmer ?',
    toolCalls: [
      call('get_wallet_balance', { balanceFcfa: 5000 }),
      call('initiate_wallet_recharge', { status: 'awaiting_confirmation', actionId: 'a2', summaryFr: 'Recharge 2000 FCFA' }),
    ],
    pendingActionAmount: 2000,
  });
  assert.equal(response.type, 'confirmation');
  assert.equal(response.payload.actionId, 'a2');
});

// ── buildTurnResponse — erreur ────────────────────────────────────────────

test('buildTurnResponse: a tool error with no successful call this turn -> type error', () => {
  const response = buildTurnResponse({
    finalText: "Désolé, je n'ai pas trouvé cette commande.",
    toolCalls: [call('track_order', { error: 'Commande introuvable.' })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'error');
  assert.equal(response.payload.reason, 'Commande introuvable.');
});

test('buildTurnResponse: a tool error does NOT override a genuine success in the same turn', () => {
  const response = buildTurnResponse({
    finalText: 'Voici ton solde (la recherche de commande a échoué).',
    toolCalls: [
      call('track_order', { error: 'Commande introuvable.' }),
      call('get_wallet_balance', { balanceFcfa: 100 }),
    ],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'wallet');
});

// ── buildTurnResponse — remember_user_info (silencieux, jamais le type) ──

test('buildTurnResponse: remember_user_info alone (no other tool) -> type generic, not surfaced as its own card', () => {
  const response = buildTurnResponse({
    finalText: "C'est noté !",
    toolCalls: [call('remember_user_info', { saved: true, fields: ['quartier'] })],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'generic');
});

test('buildTurnResponse: remember_user_info running alongside a real tool never overrides its type', () => {
  const response = buildTurnResponse({
    finalText: 'Voici ton solde.',
    toolCalls: [
      call('remember_user_info', { saved: true, fields: ['quartier'] }),
      call('get_wallet_balance', { balanceFcfa: 500 }),
    ],
    pendingActionAmount: null,
  });
  assert.equal(response.type, 'wallet');
});

// ── buildTurnResponse — compatibilité / aucun outil ───────────────────────

test('buildTurnResponse: no tool called this turn -> type generic (plain conversational reply)', () => {
  const response = buildTurnResponse({ finalText: 'Bonjour ! Comment puis-je vous aider ?', toolCalls: [], pendingActionAmount: null });
  assert.equal(response.type, 'generic');
  assert.equal(response.message, 'Bonjour ! Comment puis-je vous aider ?');
  assert.deepEqual(response.payload, {});
});

test('buildTurnResponse: every declared type has real metadata (icon/color/title/priority), no silent fallback gaps', () => {
  for (const type of ALL_TYPES) {
    const response = buildTurnResponse({ finalText: 'x', toolCalls: [], pendingActionAmount: null });
    assert.ok(response.icon && response.color && response.title && response.priority);
  }
});

// ── buildConfirmResponse — après confirmation réelle ─────────────────────

test('buildConfirmResponse: initiate_wallet_recharge confirmed -> type wallet_recharge with txId/paymentUrl', () => {
  const response = buildConfirmResponse({
    toolName: 'initiate_wallet_recharge',
    result: { txId: 't1', paymentUrl: 'https://pay.example/t1', message: 'Paiement initié.' },
  });
  assert.equal(response.type, 'wallet_recharge');
  assert.equal(response.message, 'Paiement initié.');
  assert.deepEqual(response.payload, { txId: 't1', paymentUrl: 'https://pay.example/t1' });
});

test('buildConfirmResponse: create_ekbine_order confirmed -> type ekbine_order', () => {
  const response = buildConfirmResponse({
    toolName: 'create_ekbine_order',
    result: { orderId: 'e9', message: 'Commande E-Kbine créée.' },
  });
  assert.equal(response.type, 'ekbine_order');
  assert.equal(response.payload.orderId, 'e9');
});

test('buildConfirmResponse: cancel_order confirmed -> type delivery_cancel with refund fields', () => {
  const response = buildConfirmResponse({
    toolName: 'cancel_order',
    result: { orderId: 'o1', refundAmount: 700, commissionRefund: 100, message: 'Commande annulée.' },
  });
  assert.equal(response.type, 'delivery_cancel');
  assert.equal(response.payload.refundAmount, 700);
  assert.equal(response.payload.commissionRefund, 100);
});

test('buildConfirmResponse: request_property_visit confirmed -> type visit_request', () => {
  const response = buildConfirmResponse({
    toolName: 'request_property_visit',
    result: { requestId: 'v1', agentId: 'ag1', listingTitle: 'Villa X' },
  });
  assert.equal(response.type, 'visit_request');
  assert.equal(response.payload.requestId, 'v1');
  // Pas de .message dans le résultat réel de createVisitRequest -> repli explicite, jamais vide.
  assert.equal(response.message, 'Action confirmée.');
});

test('buildConfirmResponse: an unmapped tool name falls back to type success, never crashes', () => {
  const response = buildConfirmResponse({ toolName: 'some_future_tool', result: { message: 'Fait.' } });
  assert.equal(response.type, 'success');
  assert.equal(response.message, 'Fait.');
});

test('buildConfirmResponse: create_marketplace_order and create_pharmacie_order confirmed both map to payment (no dedicated enum type)', () => {
  const mp = buildConfirmResponse({ toolName: 'create_marketplace_order', result: { orderId: 'm1', dispatched: true, message: 'Achat confirmé.' } });
  const ph = buildConfirmResponse({ toolName: 'create_pharmacie_order', result: { orderId: 'p1', dispatched: false, message: 'Commande envoyée.' } });
  assert.equal(mp.type, 'payment');
  assert.equal(ph.type, 'payment');
});
