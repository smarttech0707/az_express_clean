'use strict';

/**
 * Claude principal + Gemini en repli — chaîne complète, 100 % hors ligne.
 *
 * Aucun provider réel n'est instancié : chaque fournisseur est une doublure
 * qui compte ses appels et peut lever une erreur de forme choisie. Un
 * fournisseur « optionnel » est doté d'un `isConfigured()` faux ET d'un appel
 * qui échoue le test s'il est jamais atteint — c'est ainsi qu'on prouve
 * l'absence d'appel réseau, plutôt qu'en le supposant.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAIProviderService } = require('../azia/AIProviderService');
const { classifyProviderFailure } = require('../azia/providers/fallbackPolicy');

const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__ts__', increment: (n) => ({ __increment: n }) },
    Timestamp: { fromMillis: (m) => ({ toMillis: () => m }) },
  },
};

// Doublure Firestore de meme surface que celle de aiProviderService.test.js
// (doc/set/get/add/runTransaction + fusion des increments) : la couche
// d'observabilite d'AIProviderService ecrit reellement ai_usage/ai_logs/
// ai_daily_stats, et une doublure incomplete ferait echouer le test pour une
// raison sans rapport avec le repli.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;
  const mergeIncrements = (existing, data) => {
    const out = { ...data };
    for (const k of Object.keys(data)) {
      if (data[k] && data[k].__increment !== undefined) {
        out[k] = (existing?.[k] || 0) + data[k].__increment;
      }
    }
    return out;
  };
  const makeRef = (path) => ({
    id: path.split('/').pop(),
    __path: path,
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
    set: async (data, opts) => {
      store.set(path, opts && opts.merge
        ? { ...(store.get(path) || {}), ...mergeIncrements(store.get(path), data) }
        : data);
    },
    update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
  });
  const makeCollection = (name) => ({
    doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
    add: async (data) => {
      const path = `${name}/auto${autoId++}`;
      store.set(path, data);
      return { id: path.split('/').pop() };
    },
  });
  const db = {
    collection: (name) => makeCollection(name),
    runTransaction: async (fn) => fn({
      get: async (ref) => ({ exists: store.has(ref.__path), data: () => store.get(ref.__path) }),
      set: (ref, data) => store.set(ref.__path, data),
      update: (ref, data) => store.set(ref.__path, { ...(store.get(ref.__path) || {}), ...data }),
    }),
  };
  return { db, store };
}

/** Fournisseur de test. `error` est levée telle quelle (forme réaliste). */
function provider(name, { error = null, text = `reponse de ${name}`, configured = true, tools = true } = {}) {
  const calls = [];
  return {
    name,
    calls,
    isConfigured: () => configured,
    supportsTools: () => tools,
    supportsCanonicalHistory: () => true,
    async generateText(prompt) {
      calls.push(prompt);
      if (error) throw error;
      return { text, model: `${name}-modele`, inputTokens: 1, outputTokens: 1 };
    },
    async generateTurn(turn) {
      calls.push(turn);
      if (error) throw error;
      return { text, toolCalls: [], model: `${name}-modele`, inputTokens: 1, outputTokens: 1 };
    },
  };
}

/** Fournisseur optionnel : non configuré ET piégé s'il est appelé. */
function trapProvider(name) {
  const calls = [];
  return {
    name,
    calls,
    isConfigured: () => false,
    supportsTools: () => true,
    supportsCanonicalHistory: () => true,
    async generateText() { calls.push('APPEL'); throw new Error(`${name} ne doit jamais partir sur le reseau`); },
    async generateTurn() { calls.push('APPEL'); throw new Error(`${name} ne doit jamais partir sur le reseau`); },
  };
}

const httpError = (status) => Object.assign(new Error(`HTTP ${status}`), { httpStatus: status, code: 'provider_http_error' });
const sdkError = (name, status) => Object.assign(new Error(name), { name, status });

function serviceWith(providers, config) {
  const { db, store } = makeFakeDb();
  if (config) store.set('settings/ai', config);
  return { service: createAIProviderService({ db, admin: fakeAdmin, providers }), store };
}

const BASE = { provider: 'claude', defaultProvider: 'claude' };
const OPTIONALS = () => ({
  openai: trapProvider('openai'),
  groq: trapProvider('groq'),
  mistral: trapProvider('mistral'),
  deepseek: trapProvider('deepseek'),
});

// ── 1-2. Claude d'abord, Gemini jamais si Claude réussit ────────────────────
test('FB1. Claude est appelé en premier sur un tour normal', async () => {
  const claude = provider('claude');
  const gemini = provider('gemini');
  const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
  const out = await service.generateText('bonjour', { uid: 'u1', cache: false });
  assert.equal(out.provider, 'claude');
  assert.equal(claude.calls.length, 1);
});

test('FB2. Claude réussit → Gemini jamais appelé', async () => {
  const claude = provider('claude');
  const gemini = provider('gemini');
  const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
  await service.generateText('bonjour', { uid: 'u1', cache: false });
  assert.equal(gemini.calls.length, 0, 'aucun appel de repli sur un succès');
});

// ── 3-5. Erreurs éligibles → Gemini prend le relais ─────────────────────────
for (const [label, err] of [
  ['FB3. Claude 503', httpError(503)],
  ['FB4. Claude timeout', Object.assign(new Error('timeout'), { code: 'provider_timeout' })],
  ['FB5. Claude 429', httpError(429)],
  ['FB5b. Claude 502', httpError(502)],
  ['FB5c. Claude 500', httpError(500)],
  ['FB5d. Claude transport ECONNRESET', Object.assign(new Error('reset'), { code: 'ECONNRESET' })],
  ['FB5e. Claude APIConnectionError (SDK)', sdkError('APIConnectionError')],
  ['FB5f. Claude 529 surcharge Anthropic', sdkError('InternalServerError', 529)],
]) {
  test(`${label} → Gemini appelé et sa réponse retournée`, async () => {
    const claude = provider('claude', { error: err });
    const gemini = provider('gemini', { text: 'reponse de secours' });
    const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
    const out = await service.generateText('bonjour', { uid: 'u1', cache: false });
    assert.equal(out.provider, 'gemini');
    assert.equal(out.text, 'reponse de secours');
    assert.equal(out.fallbackFrom, 'claude');
    assert.equal(gemini.calls.length, 1);
  });
}

// ── 6. Erreurs NON éligibles → Gemini jamais appelé ─────────────────────────
for (const [label, err] of [
  ['FB6. authentification (401)', sdkError('AuthenticationError', 401)],
  ['FB6b. permissions (403)', sdkError('PermissionDeniedError', 403)],
  ['FB6c. requête invalide (400)', sdkError('BadRequestError', 400)],
  ['FB6d. modèle introuvable (404)', sdkError('NotFoundError', 404)],
  ['FB6e. refus de sécurité', Object.assign(new Error('bloque'), { code: 'provider_blocked' })],
  ['FB6f. mauvaise configuration de modèle', Object.assign(new Error('modele'), { code: 'provider_model_not_configured' })],
  ['FB6g. erreur de programmation', new TypeError('x is not a function')],
]) {
  test(`${label} → aucun repli, erreur remontée telle quelle`, async () => {
    const claude = provider('claude', { error: err });
    const gemini = provider('gemini');
    const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
    await assert.rejects(() => service.generateText('bonjour', { uid: 'u1', cache: false }));
    assert.equal(gemini.calls.length, 0, 'un refus ou une erreur de notre fait ne se rejoue jamais ailleurs');
  });
}

// ── 7. Claude non configuré ─────────────────────────────────────────────────
test('FB7. Claude non configuré → sauté sans appel, Gemini répond', async () => {
  const claude = provider('claude', { configured: false });
  const gemini = provider('gemini', { text: 'gemini ok' });
  const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
  const out = await service.generateText('bonjour', { uid: 'u1', cache: false });
  assert.equal(out.provider, 'gemini');
  assert.equal(claude.calls.length, 0, 'un fournisseur non configuré ne part jamais sur le reseau');
});

// ── 8-9. Issue finale ───────────────────────────────────────────────────────
test('FB8. Claude 503 puis Gemini 503 → erreur finale contrôlée', async () => {
  const claude = provider('claude', { error: httpError(503) });
  const gemini = provider('gemini', { error: httpError(503) });
  const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
  await assert.rejects(
    () => service.generateText('bonjour', { uid: 'u1', cache: false }),
    (e) => {
      assert.equal(e.httpStatus, 503, 'la derniere erreur reelle est remontee');
      assert.equal(e.code, 'provider_http_error');
      return true;
    },
  );
  assert.equal(claude.calls.length, 1, 'un seul essai par fournisseur, jamais de boucle');
  assert.equal(gemini.calls.length, 1);
});

test('FB9. Gemini réussit après Claude 503 → réponse Gemini retournée', async () => {
  const claude = provider('claude', { error: httpError(503) });
  const gemini = provider('gemini', { text: 'AZ IA via Gemini' });
  const { service } = serviceWith({ claude, gemini, ...OPTIONALS() }, BASE);
  const out = await service.generateText('bonjour', { uid: 'u1', cache: false });
  assert.equal(out.text, 'AZ IA via Gemini');
  assert.equal(out.provider, 'gemini');
});

// ── 11-14. Fournisseurs optionnels : présents, inertes, jamais appelés ──────
test('FB11-14. OpenAI/Groq/Mistral/DeepSeek : aucun appel réseau, même si Claude ET Gemini échouent', async () => {
  const optionals = OPTIONALS();
  const claude = provider('claude', { error: httpError(503) });
  const gemini = provider('gemini', { error: httpError(503) });
  const { service } = serviceWith({ claude, gemini, ...optionals }, BASE);
  await assert.rejects(() => service.generateText('bonjour', { uid: 'u1', cache: false }));
  for (const [name, p] of Object.entries(optionals)) {
    assert.equal(p.calls.length, 0, `${name} ne doit recevoir aucun appel`);
  }
});

test('FB11b. les providers optionnels restent présents et instanciables', () => {
  for (const file of ['OpenAIProvider', 'GroqProvider', 'MistralProvider', 'DeepSeekProvider']) {
    const Provider = require(`../azia/providers/${file}`);
    const instance = new Provider();
    assert.equal(typeof instance.isConfigured, 'function',
      `${file} doit rester utilisable (code conservé, simplement inactif)`);
  }
});

// ── 10. Anti-double-exécution sur un tour à outils ──────────────────────────
test('FB10. tour à outils : seuls des fournisseurs compatibles outils sont tentés', async () => {
  const claude = provider('claude', { error: httpError(503) });
  const gemini = provider('gemini', { text: 'repli outils' });
  // Un fournisseur incapable d'outils ne doit jamais entrer dans la chaîne.
  const sansOutils = provider('openai', { tools: false });
  const { service } = serviceWith(
    { claude, gemini, openai: sansOutils, groq: trapProvider('groq'), mistral: trapProvider('mistral'), deepseek: trapProvider('deepseek') },
    { ...BASE, toolProvider: 'claude', fallbackProviders: ['claude', 'gemini', 'openai'] },
  );
  const out = await service.generateTurn(
    { messages: [{ role: 'user', content: [{ type: 'text', text: 'solde' }] }], tools: [{ name: 'get_wallet_balance' }] },
    { uid: 'u1', cache: false, skipQuota: true },
  );
  assert.equal(out.provider, 'gemini');
  assert.equal(sansOutils.calls.length, 0,
    'un fournisseur sans tool calling ne doit jamais recevoir un tour a outils');
});

// ── Politique d'éligibilité, en isolation ───────────────────────────────────
test('FB-P. la politique classe correctement chaque famille d\'erreur', () => {
  const eligible = [
    httpError(503), httpError(502), httpError(500), httpError(429), httpError(408),
    Object.assign(new Error('t'), { code: 'provider_timeout' }),
    Object.assign(new Error('n'), { code: 'provider_network' }),
    Object.assign(new Error('j'), { code: 'provider_invalid_json' }),
    Object.assign(new Error('v'), { code: 'provider_empty_response' }),
    Object.assign(new Error('c'), { code: 'ETIMEDOUT' }),
    sdkError('RateLimitError', 429),
    new Error('panne imprevue sans forme connue'),
  ];
  for (const err of eligible) {
    assert.equal(classifyProviderFailure(err).eligible, true,
      `devrait etre eligible : ${err.code || err.name} ${err.httpStatus || err.status || ''}`);
  }
  const blocked = [
    httpError(400), httpError(401), httpError(403), httpError(404), httpError(422),
    Object.assign(new Error('b'), { code: 'provider_blocked' }),
    Object.assign(new Error('m'), { code: 'provider_model_not_configured' }),
    sdkError('AuthenticationError', 401),
    new TypeError('bug de notre cote'),
    new ReferenceError('bug de notre cote'),
  ];
  for (const err of blocked) {
    assert.equal(classifyProviderFailure(err).eligible, false,
      `ne devrait PAS etre eligible : ${err.code || err.name} ${err.httpStatus || err.status || ''}`);
  }
});
