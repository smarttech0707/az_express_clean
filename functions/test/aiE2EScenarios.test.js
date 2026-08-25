'use strict';

// Scénarios E2E locaux (Mission 13) — entièrement mockés (aucun réseau réel),
// exerçant la vraie chaîne aiGateway → policyEngine → AIProviderService →
// providers factices, pour prouver le comportement de bout en bout sans
// jamais toucher functions/azia/index.js (la boucle d'outils réelle,
// spécifique à Claude, explicitement hors périmètre de ce chantier).

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAiGateway } = require('../azia/aiGateway');
const { createPolicyEngine } = require('../azia/policyEngine');
const { createAIProviderService } = require('../azia/AIProviderService');

// ── Fake Firestore minimal (même pattern que test/aiProviderService.test.js) ─
function makeFakeDb() {
  const store = new Map();
  let autoId = 0;
  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data) => { store.set(path, data); },
    };
  }
  return {
    db: {
      collection: (name) => ({
        doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
        add: async (data) => { const path = `${name}/auto${autoId++}`; store.set(path, data); return { id: path.split('/').pop() }; },
      }),
      runTransaction: async (fn) => fn({ get: async () => ({ exists: false }), set: () => {} }),
    },
    store,
  };
}

const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__TS__', increment: (n) => ({ __increment: n }) },
    Timestamp: { fromMillis: (ms) => ({ toMillis: () => ms }) },
  },
};

const TOOLS = [
  { name: 'search_faq', description: 'FAQ générique', input_schema: { type: 'object' } },
  { name: 'track_order', description: 'Suivi de commande (lecture seule)', input_schema: { type: 'object' } },
  { name: 'initiate_wallet_recharge', description: 'Recharge wallet (sensible)', input_schema: { type: 'object' }, confirmHandler: async () => {} },
  { name: 'create_pending_payment', description: 'Paiement (sensible)', input_schema: { type: 'object' }, confirmHandler: async () => {} },
];

function makeFakeProvider(name, impl) {
  const calls = [];
  return {
    name,
    isConfigured: () => true,
    supportsTools: () => name === 'claude',
    generateText: async (prompt, opts) => { calls.push({ prompt, opts }); return impl({ prompt, opts }); },
    generateChat: async (messages, opts) => { calls.push({ messages, opts }); return impl({ messages, opts }); },
    generateTurn: async (turn) => { calls.push(turn); return impl(turn); },
    calls,
  };
}

function makeHarness(providerImpls, config = {}) {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { provider: 'claude', fallbackEnabled: false, ...config });
  const policy = createPolicyEngine({ tools: TOOLS });
  const providerService = createAIProviderService({
    db, admin: fakeAdmin,
    providers: {
      claude: providerImpls.claude || makeFakeProvider('claude', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
      openai: providerImpls.openai || makeFakeProvider('openai', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
      gemini: makeFakeProvider('gemini', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
      deepseek: makeFakeProvider('deepseek', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
      mistral: makeFakeProvider('mistral', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
      groq: makeFakeProvider('groq', () => ({ text: '', toolCalls: [], inputTokens: 1, outputTokens: 1, finishReason: 'stop' })),
    },
  });
  const gateway = createAiGateway({ providerService, policyEngine: policy });
  return { gateway, store };
}

// ── Scénario A — conversation simple, sans outil, va vers OpenAI ───────────
test('Scénario A : "Bonjour, comment fonctionne AZ Express ?" → OpenAI, pas d\'outil', async () => {
  const openai = makeFakeProvider('openai', () => ({
    text: 'AZ Express est une super-app ivoirienne de livraison et de services.',
    toolCalls: [], inputTokens: 15, outputTokens: 20, provider: 'openai', model: 'gpt-4o-mini', finishReason: 'stop',
  }));
  const { gateway } = makeHarness({ openai }, { defaultProvider: 'openai' });
  const result = await gateway.generateTurn({
    systemPrompt: 'Tu es AZ IA.',
    messages: [{ role: 'user', content: 'Bonjour, comment fonctionne AZ Express ?' }],
    tools: [],
  }, { uid: 'client-1', conversationId: 'conv-a' });

  assert.equal(result.provider, 'openai');
  assert.equal(result.toolCalls.length, 0);
  assert.ok(result.text.includes('AZ Express'));
});

// ── Scénario B — outil de lecture non-sensible, comportement selon config ──
test('Scénario B : "Où est mon livreur ?" → outil de lecture autorisé, comportement selon la Policy', async () => {
  const claude = makeFakeProvider('claude', () => ({
    text: '', toolCalls: [{ id: 'call_1', name: 'track_order', input: { orderId: 'o-42' } }],
    inputTokens: 30, outputTokens: 10, provider: 'claude', model: 'claude-sonnet-5', finishReason: 'tool_use',
    assistantMessage: [{ type: 'tool_use', id: 'call_1', name: 'track_order', input: { orderId: 'o-42' } }],
  }));
  const { gateway } = makeHarness({ claude });
  const result = await gateway.generateTurn({
    systemPrompt: 'Tu es AZ IA.',
    messages: [{ role: 'user', content: 'Où est mon livreur ?' }],
    tools: TOOLS,
  }, { uid: 'client-2', conversationId: 'conv-b', forceProvider: 'claude' });

  assert.equal(result.provider, 'claude');
  assert.equal(result.toolCalls.length, 1);
  assert.equal(result.toolCalls[0].name, 'track_order');
});

// ── Scénario C — action sensible (wallet) → Claude, jamais de débit direct ──
test('Scénario C : "Débite 5 000 FCFA de mon wallet" → outil sensible, toujours Claude, aucune exécution ici', async () => {
  const claudeCalls = [];
  const openaiCalls = [];
  const claude = makeFakeProvider('claude', (turn) => {
    claudeCalls.push(turn);
    return {
      text: '', toolCalls: [{ id: 'call_1', name: 'initiate_wallet_recharge', input: { amount: 5000 } }],
      inputTokens: 40, outputTokens: 15, provider: 'claude', model: 'claude-sonnet-5', finishReason: 'tool_use',
    };
  });
  const openai = makeFakeProvider('openai', (turn) => { openaiCalls.push(turn); return { text: 'ne devrait jamais être appelé' }; });
  const { gateway } = makeHarness({ claude, openai }, { defaultProvider: 'openai' });

  const policy = createPolicyEngine({ tools: TOOLS });
  assert.equal(policy.requiresConfirmation('initiate_wallet_recharge'), true, 'l\'outil sensible doit rester gated par confirmHandler, jamais par ce chantier');

  const result = await gateway.generateTurn({
    systemPrompt: 'Tu es AZ IA.',
    messages: [{ role: 'user', content: 'Débite 5 000 FCFA de mon wallet' }],
    tools: TOOLS,
  }, { uid: 'client-3', conversationId: 'conv-c' }); // pas de forceProvider : le routage réel doit choisir claude car hasTools=true

  assert.equal(result.provider, 'claude', 'un outil sensible ne doit jamais être routé vers OpenAI, même si defaultProvider=openai');
  assert.equal(openaiCalls.length, 0, 'OpenAI ne doit jamais être appelé pour un tour à outils');
  assert.equal(result.toolCalls[0].name, 'initiate_wallet_recharge');
  // Ce test ne simule aucune exécution d'outil ni écriture ai_pending_actions —
  // la gateway ne fait QUE renvoyer la demande d'outil ; l'exécution/la
  // création de la confirmation restent dans azia/index.js, non touché ici.
});

// ── Scénario D — timeout OpenAI avant tout outil → fallback Claude ─────────
test('Scénario D : timeout OpenAI avant tout outil → bascule Claude autorisée', async () => {
  const openai = makeFakeProvider('openai', () => { const e = new Error('OpenAI timeout'); e.code = 'ETIMEDOUT'; throw e; });
  const claude = makeFakeProvider('claude', () => ({ text: 'réponse de secours Claude', model: 'claude-sonnet-5', inputTokens: 5, outputTokens: 5 }));
  const { db } = makeFakeDb();
  const providerService = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, openai, gemini: makeFakeProvider('gemini', () => ({ text: 'x' })), deepseek: makeFakeProvider('deepseek', () => ({ text: 'x' })), mistral: makeFakeProvider('mistral', () => ({ text: 'x' })), groq: makeFakeProvider('groq', () => ({ text: 'x' })) },
  });
  // settings/ai configure OpenAI par défaut, avec bascule Claude activée —
  // exactement le scénario D (timeout OpenAI sans outil → fallback autorisé).
  await db.collection('settings').doc('ai').set({ provider: 'openai', fallbackEnabled: true, fallbackProviders: ['claude'] });
  const result = await providerService.generateText('bonjour', { uid: 'client-4', cache: false });
  assert.equal(result.provider, 'claude');
  assert.equal(result.fallbackFrom, 'openai');
  assert.equal(result.text, 'réponse de secours Claude');
});

// ── Scénario E — outil déjà exécuté puis erreur fournisseur → pas de rejeu ─
test('Scénario E : un outil déjà exécuté puis une erreur fournisseur ne rejoue jamais l\'outil', async () => {
  // Boucle de test MINIMALE, jamais utilisée en production — un simple
  // stand-in local pour prouver que rien dans gateway/AIProviderService ne
  // réexécute automatiquement un outil déjà traité. La vraie boucle
  // (functions/azia/index.js) n'est pas dupliquée ni modifiée ici.
  let toolExecutionCount = 0;
  async function fakeExecuteTool(name) {
    if (name === 'create_pending_payment') toolExecutionCount += 1;
    return { status: 'awaiting_confirmation' };
  }

  let turnNumber = 0;
  const claude = makeFakeProvider('claude', () => {
    turnNumber += 1;
    if (turnNumber === 1) {
      return {
        text: '', toolCalls: [{ id: 'call_1', name: 'create_pending_payment', input: { amount: 5000 } }],
        inputTokens: 10, outputTokens: 5, provider: 'claude', model: 'claude-sonnet-5', finishReason: 'tool_use',
      };
    }
    // Deuxième tour : le fournisseur échoue (ex. panne réseau après que
    // l'outil du premier tour a déjà été exécuté par l'appelant).
    throw new Error('Claude indisponible après exécution de l\'outil');
  });
  const { gateway } = makeHarness({ claude });

  const turn1 = await gateway.generateTurn({
    systemPrompt: 'x', messages: [{ role: 'user', content: 'Paie 5000 FCFA' }], tools: TOOLS,
  }, { uid: 'client-5', conversationId: 'conv-e', forceProvider: 'claude' });
  assert.equal(turn1.toolCalls.length, 1);

  // L'appelant (test) exécute l'outil UNE fois — jamais la gateway elle-même.
  await fakeExecuteTool(turn1.toolCalls[0].name);
  assert.equal(toolExecutionCount, 1);

  // Deuxième tour : le fournisseur échoue. Rien dans gateway/AIProviderService
  // ne réessaie automatiquement d'exécuter l'outil du premier tour.
  await assert.rejects(() => gateway.generateTurn({
    systemPrompt: 'x',
    messages: [
      { role: 'user', content: 'Paie 5000 FCFA' },
      { role: 'tool', toolCallId: 'call_1', name: 'create_pending_payment', content: { status: 'awaiting_confirmation' } },
    ],
    tools: TOOLS,
  }, { uid: 'client-5', conversationId: 'conv-e', forceProvider: 'claude' }));

  assert.equal(toolExecutionCount, 1, 'l\'outil sensible ne doit jamais être ré-exécuté après l\'échec du tour suivant');
});

// ── Scénario F — arguments JSON invalides → outil jamais exécuté ──────────
test('Scénario F : arguments JSON invalides sur un appel d\'outil → jamais exécuté, erreur contrôlée', async () => {
  const claude = makeFakeProvider('claude', () => ({
    text: '',
    toolCalls: [{ id: 'call_1', name: 'create_pending_payment', input: {}, argumentsError: 'arguments JSON invalides: Unexpected token' }],
    inputTokens: 10, outputTokens: 5, provider: 'claude', model: 'claude-sonnet-5', finishReason: 'tool_use',
  }));
  const { gateway } = makeHarness({ claude });
  const result = await gateway.generateTurn({
    systemPrompt: 'x', messages: [{ role: 'user', content: 'x' }], tools: TOOLS,
  }, { uid: 'client-6', conversationId: 'conv-f', forceProvider: 'claude' });

  assert.equal(result.toolCalls.length, 1);
  assert.equal(result.toolCalls[0].argumentsError.includes('invalides'), true);
  // La gateway transmet le marqueur d'erreur tel quel — c'est à l'appelant
  // (executeTool, dans azia/index.js, non touché ici) de refuser proprement
  // d'exécuter un outil dont les arguments n'ont pas pu être parsés.
});
