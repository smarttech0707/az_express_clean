'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createAIProviderService, PRICING, DEFAULT_CONFIG,
} = require('../azia/AIProviderService');
const {
  OpenAIProvider, GeminiProvider, DeepSeekProvider, MistralProvider, GroqProvider, ProviderNotConfiguredError,
} = require('../azia/providers');
const ClaudeProvider = require('../azia/providers/ClaudeProvider');

// ── Fake Firestore (même pattern que test/orderActions.test.js) ────────────
function makeFakeDb() {
  const store = new Map();
  let autoId = 0;

  function mergeIncrements(existing, data) {
    const out = { ...data };
    for (const k of Object.keys(data)) {
      if (data[k] && data[k].__increment !== undefined) {
        out[k] = (existing?.[k] || 0) + data[k].__increment;
      }
    }
    return out;
  }

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        if (opts && opts.merge) {
          store.set(path, { ...(store.get(path) || {}), ...mergeIncrements(store.get(path), data) });
        } else {
          store.set(path, data);
        }
      },
    };
  }

  function makeCollection(name) {
    return {
      doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
      add: async (data) => {
        const path = `${name}/auto${autoId++}`;
        store.set(path, data);
        return { id: path.split('/').pop() };
      },
    };
  }

  const db = {
    collection: (name) => makeCollection(name),
    runTransaction: async (fn) => {
      const tx = {
        get: async (ref) => ({ exists: store.has(ref.__path), data: () => store.get(ref.__path) }),
        set: (ref, data) => store.set(ref.__path, data),
      };
      return fn(tx);
    },
  };

  return { db, store };
}

const fakeAdmin = {
  firestore: {
    FieldValue: {
      serverTimestamp: () => '__SERVER_TIMESTAMP__',
      increment: (n) => ({ __increment: n }),
    },
    Timestamp: {
      fromMillis: (ms) => ({ toMillis: () => ms }),
    },
  },
};

// ── Fournisseur factice pour tester l'orchestration sans appel réseau ──────
function makeFakeProvider(name, { configured = true, fail = false, text = `réponse de ${name}` } = {}) {
  const calls = [];
  return {
    name,
    isConfigured: () => configured,
    generateText: async (prompt, opts) => {
      calls.push({ method: 'generateText', prompt, opts });
      if (fail) throw new Error(`${name} a échoué`);
      return { text, model: 'fake-model', inputTokens: 10, outputTokens: 5 };
    },
    generateChat: async (messages, opts) => {
      calls.push({ method: 'generateChat', messages, opts });
      if (fail) throw new Error(`${name} a échoué`);
      return { text, model: 'fake-model', inputTokens: 10, outputTokens: 5 };
    },
    generateVision: async () => { throw new Error(`${name} ne supporte pas la vision`); },
    calls,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// 1. Chaque provider — isConfigured() reflète bien la présence de la clé
// ═══════════════════════════════════════════════════════════════════════════
test('ClaudeProvider.isConfigured() suit ANTHROPIC_API_KEY', () => {
  const original = process.env.ANTHROPIC_API_KEY;
  delete process.env.ANTHROPIC_API_KEY;
  assert.equal(new ClaudeProvider().isConfigured(), false);
  process.env.ANTHROPIC_API_KEY = 'sk-ant-test';
  assert.equal(new ClaudeProvider().isConfigured(), true);
  if (original === undefined) delete process.env.ANTHROPIC_API_KEY; else process.env.ANTHROPIC_API_KEY = original;
});

test('OpenAIProvider/GeminiProvider/DeepSeekProvider/MistralProvider/GroqProvider : non configurés sans clé', () => {
  for (const key of ['OPENAI_API_KEY', 'GEMINI_API_KEY', 'DEEPSEEK_API_KEY', 'MISTRAL_API_KEY', 'GROQ_API_KEY']) {
    delete process.env[key];
  }
  assert.equal(new OpenAIProvider().isConfigured(), false);
  assert.equal(new GeminiProvider().isConfigured(), false);
  assert.equal(new DeepSeekProvider().isConfigured(), false);
  assert.equal(new MistralProvider().isConfigured(), false);
  assert.equal(new GroqProvider().isConfigured(), false);
});

test('OpenAIProvider devient configuré dès que OPENAI_API_KEY est présente', () => {
  process.env.OPENAI_API_KEY = 'sk-test';
  assert.equal(new OpenAIProvider().isConfigured(), true);
  delete process.env.OPENAI_API_KEY;
});

test('un provider non configuré lève ProviderNotConfiguredError, jamais un appel réseau', async () => {
  delete process.env.OPENAI_API_KEY;
  const provider = new OpenAIProvider();
  await assert.rejects(
    () => provider.generateChat([{ role: 'user', content: 'salut' }], {}),
    (err) => err instanceof ProviderNotConfiguredError && err.code === 'provider_not_configured',
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 2. estimateCost() — calcul pur, tarifs connus
// ═══════════════════════════════════════════════════════════════════════════
test('estimateCost() applique la grille tarifaire par provider', () => {
  const { db, } = makeFakeDb();
  const service = createAIProviderService({ db, admin: fakeAdmin });
  const cost = service.estimateCost('claude', 1_000_000, 1_000_000);
  assert.equal(cost, PRICING.claude.input + PRICING.claude.output);
});

test('estimateCost() renvoie 0 pour un provider inconnu (pas d\'exception)', () => {
  const { db } = makeFakeDb();
  const service = createAIProviderService({ db, admin: fakeAdmin });
  assert.equal(service.estimateCost('inconnu', 1000, 1000), 0);
});

// ═══════════════════════════════════════════════════════════════════════════
// 3. Fallback automatique
// ═══════════════════════════════════════════════════════════════════════════
test('sans fallbackEnabled : un échec du provider configuré remonte directement, pas de bascule', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false });
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await assert.rejects(() => service.generateText('bonjour', { uid: 'u1' }));
  assert.equal(gemini.calls.length, 0, 'gemini ne doit jamais être appelé sans fallback activé');
});

test('avec fallbackEnabled : Claude échoue → bascule vers Gemini avec succès', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: true });
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini', { text: 'réponse de secours' });
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini, openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  const result = await service.generateText('bonjour', { uid: 'u2', cache: false });
  assert.equal(result.provider, 'gemini');
  assert.equal(result.fallbackFrom, 'claude');
  assert.equal(result.text, 'réponse de secours');
});

test('un provider non configuré est sauté silencieusement pendant le fallback (pas compté comme panne réseau)', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: true });
  const claude = makeFakeProvider('claude', { fail: true });
  const gemini = makeFakeProvider('gemini', { configured: false }); // pas de clé
  const openai = makeFakeProvider('openai', { text: 'openai répond' });
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini, openai, deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  const result = await service.generateText('bonjour', { uid: 'u3', cache: false });
  assert.equal(result.provider, 'openai');
  assert.equal(gemini.calls.length, 0, 'gemini non configuré ne doit jamais recevoir d\'appel');
});

test('si tous les providers échouent, l\'erreur finale est bien remontée', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: true });
  const failing = () => makeFakeProvider('x', { fail: true });
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude: makeFakeProvider('claude', { fail: true }), gemini: makeFakeProvider('gemini', { fail: true }), openai: makeFakeProvider('openai', { fail: true }), deepseek: makeFakeProvider('deepseek', { fail: true }), mistral: makeFakeProvider('mistral', { fail: true }), groq: makeFakeProvider('groq', { fail: true }) },
  });
  await assert.rejects(() => service.generateText('bonjour', { uid: 'u4', cache: false }));
});

// ═══════════════════════════════════════════════════════════════════════════
// 4. Cache
// ═══════════════════════════════════════════════════════════════════════════
test('deux appels identiques : le second est servi depuis le cache, sans réappeler le provider', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false });
  const claude = makeFakeProvider('claude');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  const r1 = await service.generateText('même question', { uid: 'u5' });
  const r2 = await service.generateText('même question', { uid: 'u5' });
  assert.equal(claude.calls.length, 1, 'le provider ne doit être appelé qu\'une seule fois');
  assert.equal(r2.cached, true);
  assert.equal(r2.text, r1.text);

  // Master Prompt 118 — le coup de cache doit désormais laisser une trace
  // dans ai_daily_stats (jusqu'ici totalement invisible aux statistiques).
  const today = new Date().toISOString().slice(0, 10);
  const stat = store.get(`ai_daily_stats/${today}_claude`);
  assert.equal(stat.cacheHitCount, 1);
});

test('cache: false désactive le cache pour cet appel', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false });
  const claude = makeFakeProvider('claude');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await service.generateText('question sans cache', { uid: 'u6', cache: false });
  await service.generateText('question sans cache', { uid: 'u6', cache: false });
  assert.equal(claude.calls.length, 2);
});

// ═══════════════════════════════════════════════════════════════════════════
// 5. Quotas (par utilisateur, par jour et par mois)
// ═══════════════════════════════════════════════════════════════════════════
test('quota quotidien : la 3e requête du jour est refusée si perDay=2', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false, quotas: { default: { perDay: 2, perMonth: 1000 } } });
  const claude = makeFakeProvider('claude');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await service.generateText('q1', { uid: 'quota-user', cache: false });
  await service.generateText('q2', { uid: 'quota-user', cache: false });
  await assert.rejects(
    () => service.generateText('q3', { uid: 'quota-user', cache: false }),
    (err) => err.code === 'quota_exceeded' && err.scope === 'day',
  );
});

test('quota : deux utilisateurs différents ont des compteurs indépendants', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false, quotas: { default: { perDay: 1, perMonth: 1000 } } });
  const claude = makeFakeProvider('claude');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await service.generateText('q', { uid: 'user-a', cache: false });
  // user-b ne doit pas être affecté par le quota déjà consommé par user-a
  await service.generateText('q', { uid: 'user-b', cache: false });
});

// ═══════════════════════════════════════════════════════════════════════════
// 6. Enregistrement de l'usage / coût / logs / stats quotidiennes
// ═══════════════════════════════════════════════════════════════════════════
test('un appel réussi écrit dans ai_usage, ai_logs et ai_daily_stats', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false });
  const claude = makeFakeProvider('claude');
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await service.generateText('trace-moi', { uid: 'trace-user', cache: false });
  // laisse les écritures non-bloquantes (fire-and-forget) se résoudre
  await new Promise((r) => setTimeout(r, 10));

  const usageEntries = [...store.entries()].filter(([k]) => k.startsWith('ai_usage/'));
  const logEntries   = [...store.entries()].filter(([k]) => k.startsWith('ai_logs/'));
  const statsEntries = [...store.entries()].filter(([k]) => k.startsWith('ai_daily_stats/'));

  assert.equal(usageEntries.length, 1);
  assert.equal(usageEntries[0][1].provider, 'claude');
  assert.equal(usageEntries[0][1].success, true);
  assert.equal(usageEntries[0][1].inputTokens, 10);
  assert.equal(usageEntries[0][1].outputTokens, 5);
  assert.ok(usageEntries[0][1].estimatedCost > 0);

  assert.equal(logEntries.length, 1);
  assert.equal(logEntries[0][1].success, true);

  assert.equal(statsEntries.length, 1);
  assert.equal(statsEntries[0][1].requestCount, 1);
  assert.equal(statsEntries[0][1].errorCount, 0);
});

test('un appel échoué (tous providers en échec) écrit quand même une trace success:false', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { ...DEFAULT_CONFIG, provider: 'claude', fallbackEnabled: false });
  const claude = makeFakeProvider('claude', { fail: true });
  const service = createAIProviderService({
    db, admin: fakeAdmin,
    providers: { claude, gemini: makeFakeProvider('gemini'), openai: makeFakeProvider('openai'), deepseek: makeFakeProvider('deepseek'), mistral: makeFakeProvider('mistral'), groq: makeFakeProvider('groq') },
  });

  await assert.rejects(() => service.generateText('échec attendu', { uid: 'fail-user', cache: false }));
  await new Promise((r) => setTimeout(r, 10));

  const usageEntries = [...store.entries()].filter(([k]) => k.startsWith('ai_usage/'));
  assert.equal(usageEntries.length, 1);
  assert.equal(usageEntries[0][1].success, false);
});

// ═══════════════════════════════════════════════════════════════════════════
// 7. Configuration (settings/ai)
// ═══════════════════════════════════════════════════════════════════════════
test('getConfig() renvoie les valeurs par défaut si settings/ai n\'existe pas', async () => {
  const { db } = makeFakeDb();
  const service = createAIProviderService({ db, admin: fakeAdmin });
  const config = await service.getConfig();
  assert.equal(config.provider, 'claude');
  assert.equal(config.fallbackEnabled, false);
  assert.equal(config.temperature, 0.7);
  assert.equal(config.maxTokens, 1024);
});

test('getConfig() fusionne settings/ai avec les valeurs par défaut', async () => {
  const { db, store } = makeFakeDb();
  store.set('settings/ai', { provider: 'gemini', fallbackEnabled: true });
  const service = createAIProviderService({ db, admin: fakeAdmin });
  const config = await service.getConfig();
  assert.equal(config.provider, 'gemini');
  assert.equal(config.fallbackEnabled, true);
  assert.equal(config.temperature, 0.7); // valeur par défaut conservée
});
