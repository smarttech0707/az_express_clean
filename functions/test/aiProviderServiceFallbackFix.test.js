'use strict';

// Tests dédiés au correctif de la Mission "CORRECTION SÉCURISÉE DU FALLBACK
// MULTI-LLM AZ IA" : callWithFallback() lisait l'ancien champ legacy
// `config.fallbackEnabled` au lieu du champ normalisé `config.enableFallback`
// (alimenté par AI_ENABLE_FALLBACK). Ces tests prouvent que la source unique
// de vérité est désormais bien `enableFallback`, avec compatibilité
// ascendante préservée pour l'ancien champ Firestore (via normalizeConfig()),
// et que `azia/index.js` reste strictement forcé sur Claude.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAIProviderService, DEFAULT_CONFIG } = require('../azia/AIProviderService');

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

function makeFakeProvider(name, { fail = false, text = `réponse de ${name}`, supportsTools = false } = {}) {
  const calls = [];
  return {
    name,
    isConfigured: () => true,
    supportsTools: () => supportsTools,
    generateText: async (prompt, opts) => { calls.push({ prompt, opts }); if (fail) throw fail instanceof Error ? fail : new Error(`${name} a échoué`); return { text, model: 'fake-model', inputTokens: 10, outputTokens: 5 }; },
    generateChat: async (messages, opts) => { calls.push({ messages, opts }); if (fail) throw fail instanceof Error ? fail : new Error(`${name} a échoué`); return { text, model: 'fake-model', inputTokens: 10, outputTokens: 5 }; },
    generateTurn: async (turn) => { calls.push(turn); if (fail) throw fail instanceof Error ? fail : new Error(`${name} a échoué`); return { text, toolCalls: [], model: 'fake-model', inputTokens: 10, outputTokens: 5, provider: name, finishReason: 'stop' }; },
    calls,
  };
}

function makeService(providers, firestoreConfig) {
  const { db, store } = makeFakeDb();
  if (firestoreConfig) store.set('settings/ai', firestoreConfig);
  return createAIProviderService({ db, admin: fakeAdmin, providers });
}

// ── 1. AI_ENABLE_FALLBACK=false : le deuxième fournisseur n'est jamais essayé ─
test('1. AI_ENABLE_FALLBACK=false (via config) : le deuxième fournisseur n\'est jamais tenté', async () => {
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini');
  const service = makeService(
    { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'claude', enableFallback: false },
  );
  await assert.rejects(() => service.generateText('bonjour', { uid: 'u1', cache: false }));
  assert.equal(gemini.calls.length, 0, 'gemini ne doit jamais être appelé, fallback désactivé');
});

// ── 2. AI_ENABLE_FALLBACK=true : le deuxième fournisseur est essayé après échec ─
test('2. AI_ENABLE_FALLBACK=true (via config.enableFallback) : bascule réelle vers le deuxième fournisseur', async () => {
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini', { text: 'réponse de secours' });
  const service = makeService(
    { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'claude', enableFallback: true },
  );
  const result = await service.generateText('bonjour', { uid: 'u2', cache: false });
  assert.equal(gemini.calls.length, 1, 'gemini doit être tenté après l\'échec de claude');
  assert.equal(result.provider, 'gemini');
  assert.equal(result.fallbackFrom, 'claude');
  assert.equal(result.text, 'réponse de secours');
});

// ── 3. Premier fournisseur réussi : aucun fallback inutile ────────────────
test('3. Premier fournisseur réussi : aucun appel au deuxième fournisseur, même avec fallback activé', async () => {
  const claude = makeFakeProvider('claude'); // réussit
  const gemini = makeFakeProvider('gemini');
  const service = makeService(
    { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'claude', enableFallback: true },
  );
  const result = await service.generateText('bonjour', { uid: 'u3', cache: false });
  assert.equal(gemini.calls.length, 0, 'aucun fallback ne doit être tenté si le premier fournisseur réussit');
  assert.equal(result.provider, 'claude');
  assert.equal(result.fallbackFrom, null);
});

// ── 4. Échec OpenAI 429 avant tout outil : Claude est essayé une fois ─────
test('4. Échec OpenAI (429 simulé) sur un tour SANS outil : Claude est tenté une fois en repli', async () => {
  const quotaError = new Error('openai a échoué: 429 You exceeded your current quota');
  quotaError.code = 429;
  const openai = makeFakeProvider('openai', { fail: quotaError });
  const claude = makeFakeProvider('claude', { text: 'Claude prend le relais' });
  const service = makeService(
    { claude, openai, gemini: makeFakeProvider('gemini'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    // `defaultProvider` doit être fixé explicitement : DEFAULT_CONFIG a déjà
    // `defaultProvider:'claude'` (via ROUTER_DEFAULTS) qui, sinon, gagnerait
    // sur `provider` dans normalizeConfig() et empêcherait ce test d'exercer
    // réellement un premier essai sur openai.
    { ...DEFAULT_CONFIG, provider: 'openai', defaultProvider: 'openai', enableFallback: true, fallbackProviders: ['claude'] },
  );
  const result = await service.generateTurn({ messages: [{ role: 'user', content: 'Bonjour' }], tools: [] }, { uid: 'u4', cache: false });
  assert.equal(openai.calls.length, 1, 'openai doit être tenté exactement une fois, jamais rejoué');
  assert.equal(claude.calls.length, 1, 'claude doit être tenté exactement une fois en repli');
  assert.equal(result.provider, 'claude');
  assert.equal(result.fallbackFrom, 'openai');
});

// ── 5. Échec après exécution d'un outil : aucun fallback susceptible de rejouer ─
test('5. Tour à outils : seul un fournisseur supportant réellement les outils peut apparaître dans la tentative — jamais un rejeu via un fournisseur différent', async () => {
  const toolError = new Error('claude indisponible après exécution simulée de l\'outil');
  const claude = makeFakeProvider('claude', { fail: toolError, supportsTools: true });
  // openai/gemini ne supportent pas les outils par défaut (flag désactivé) —
  // même avec fallback activé et openai/gemini dans la liste de repli, ils
  // ne doivent JAMAIS apparaître dans la tentative d'un tour à outils.
  const openai = makeFakeProvider('openai', { supportsTools: false });
  const gemini = makeFakeProvider('gemini', { supportsTools: false });
  const service = makeService(
    { claude, openai, gemini, deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'claude', enableFallback: true, fallbackProviders: ['openai', 'gemini'] },
  );
  await assert.rejects(
    () => service.generateTurn({ messages: [{ role: 'user', content: 'Paie 5000 FCFA' }], tools: [{ name: 'create_pending_payment', description: 'x', input_schema: {} }] }, { uid: 'u5', cache: false }),
    (err) => err.message.includes('claude indisponible'),
  );
  assert.equal(openai.calls.length, 0, 'openai ne doit jamais être tenté sur un tour à outils (ne le supporte pas)');
  assert.equal(gemini.calls.length, 0, 'gemini ne doit jamais être tenté sur un tour à outils (ne le supporte pas)');
  // La panne remonte directement à l'appelant — aucun mécanisme ici ne
  // pourrait "rejouer" une action déjà exécutée par un tool, puisqu'aucun
  // second fournisseur capable d'outils n'existe pour la reprendre.
});

// ── 6. Ancien champ fallbackEnabled=true : compatibilité conservée ────────
test('6. Compatibilité ascendante : Firestore settings/ai.fallbackEnabled=true (ancien champ) active toujours réellement le fallback', async () => {
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini', { text: 'via ancien champ' });
  const service = makeService(
    { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: true }, // ancien champ SEUL, enableFallback absent de ce doc
  );
  const result = await service.generateText('bonjour', { uid: 'u6', cache: false });
  assert.equal(gemini.calls.length, 1, 'le fallback doit réellement se déclencher via le seul champ legacy');
  assert.equal(result.text, 'via ancien champ');
});

// ── 7. Nouveau champ enableFallback=true seul : comportement officiel correct ─
test('7. Champ officiel enableFallback=true SEUL (sans fallbackEnabled) : comportement correct — c\'est exactement le bug corrigé', async () => {
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini', { text: 'via nouveau champ officiel' });
  const service = makeService(
    { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    // enableFallback=true, fallbackEnabled ABSENT du document — avant le
    // correctif, callWithFallback() lisait fallbackEnabled (undefined/false)
    // et abandonnait après le premier échec malgré ce réglage officiel.
    { provider: 'claude', enableFallback: true, defaultProvider: 'claude', fallbackProviders: ['gemini'], allowedProviders: ['claude', 'gemini', 'openai', 'deepseek', 'mistral', 'groq'] },
  );
  const result = await service.generateText('bonjour', { uid: 'u7', cache: false });
  assert.equal(gemini.calls.length, 1, 'AI_ENABLE_FALLBACK=true seul doit suffire à activer réellement le fallback');
  assert.equal(result.text, 'via nouveau champ officiel');
});

// ── 8. forceProvider:'claude' : OpenAI n'est jamais appelé, même mal configuré ─
test('8. forceProvider:\'claude\' (comme azia/index.js) : OpenAI jamais appelé, même avec AI_DEFAULT_PROVIDER=openai et fallback activé', async () => {
  const claude = makeFakeProvider('claude', { text: 'Claude répond', supportsTools: true });
  const openai = makeFakeProvider('openai', { text: 'ne devrait jamais être appelé' });
  const service = makeService(
    { claude, openai, gemini: makeFakeProvider('gemini'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
    { ...DEFAULT_CONFIG, provider: 'openai', defaultProvider: 'openai', enableFallback: true, fallbackProviders: ['openai'] },
  );
  const result = await service.generateTurn({
    messages: [{ role: 'user', content: 'Débite mon wallet' }],
    tools: [{ name: 'create_pending_payment', description: 'x', input_schema: {} }],
  }, { uid: 'u8', cache: false, forceProvider: 'claude' }); // reproduit exactement azia/index.js:182

  assert.equal(openai.calls.length, 0, 'OpenAI ne doit JAMAIS être appelé quand forceProvider:\'claude\' est imposé (azIaChat)');
  assert.equal(result.provider, 'claude');
  assert.equal(result.text, 'Claude répond');
});
