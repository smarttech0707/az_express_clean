'use strict';

// M2.14 — Seuls Anthropic (claude) et Google (gemini) peuvent recevoir des données dans le parcours AZ IA.
// Aucun appel réseau : fournisseurs factices, base factice, processus enfants pour les variables d'environnement.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const { buildRoute, normalizeConfig, AZIA_ALLOWED_PROVIDERS } = require('../azia/aiRouter');
const { createAIProviderService, DEFAULT_CONFIG } = require('../azia/AIProviderService');
const { createAiGateway } = require('../azia/aiGateway');
const { consentedRouterProviders, CONSENT_VERSION } = require('../azia/consent');

const FORBIDDEN = ['openai', 'mistral', 'deepseek', 'groq'];
const ALL = ['claude', 'gemini', ...FORBIDDEN];

// ── Valeurs par défaut du routeur selon AI_ALLOWED_PROVIDERS (lues à l'import → processus enfant) ──────────────────
function routerDefaultsWith(allowedEnv, extraEnv = {}) {
  const env = { ...process.env, ...extraEnv };
  delete env.AI_ALLOWED_PROVIDERS;
  if (allowedEnv !== undefined) env.AI_ALLOWED_PROVIDERS = allowedEnv;
  const script = `const r=require(${JSON.stringify(path.join(__dirname, '../azia/aiRouter'))});
    const out={allowed:r.ROUTER_DEFAULTS.allowedProviders,refused:{}};
    for (const p of ${JSON.stringify(ALL)}) { try { r.buildRoute({config:{},forceProvider:p}); out.refused[p]=false; } catch(e) { out.refused[p]=true; } }
    console.log(JSON.stringify(out));`;
  return JSON.parse(execFileSync(process.execPath, ['-e', script], { env, encoding: 'utf8' }));
}

test('plafond du code : claude et gemini seulement', () => {
  assert.deepEqual([...AZIA_ALLOWED_PROVIDERS], ['claude', 'gemini']);
  assert.ok(Object.isFrozen(AZIA_ALLOWED_PROVIDERS));
});

test('AI_ALLOWED_PROVIDERS absent → claude et gemini seulement (jamais les six)', () => {
  const r = routerDefaultsWith(undefined);
  assert.deepEqual(r.allowed, ['claude', 'gemini']);
  for (const p of FORBIDDEN) assert.equal(r.refused[p], true, p);
  assert.equal(r.refused.claude, false);
  assert.equal(r.refused.gemini, false);
});

test('AI_ALLOWED_PROVIDERS vide ou invalide → liste vide, tout est refusé (fail closed)', () => {
  for (const value of ['', '   ', 'foo', 'foo,bar', ',,']) {
    const r = routerDefaultsWith(value);
    assert.deepEqual(r.allowed, [], JSON.stringify(value));
    for (const p of ALL) assert.equal(r.refused[p], true, `${JSON.stringify(value)} → ${p}`);
  }
});

test('AI_ALLOWED_PROVIDERS ne peut pas réactiver un fournisseur interdit', () => {
  const r = routerDefaultsWith('claude,openai,mistral,deepseek,groq,gemini');
  assert.deepEqual(r.allowed, ['claude', 'gemini']);
  for (const p of FORBIDDEN) assert.equal(r.refused[p], true, p);
  assert.deepEqual(routerDefaultsWith('openai,claude').allowed, ['claude']);
  assert.deepEqual(routerDefaultsWith('openai').allowed, []);
});

test('fournisseur interdit demandé explicitement → refusé, quels que soient outils, images ou configuration', () => {
  const permissive = { allowedProviders: ALL };
  for (const p of FORBIDDEN) {
    assert.throws(() => buildRoute({ config: permissive, forceProvider: p }), /non autorise/, p);
    assert.throws(() => buildRoute({ config: { ...permissive, defaultProvider: p } }), /non autorise/, `défaut ${p}`);
    assert.throws(() => buildRoute({ config: { ...permissive, imageProvider: p }, hasImage: true }), /non autorise/, `image ${p}`);
    assert.throws(() => buildRoute({ config: { ...permissive, complexProvider: p }, complexity: 'complex' }), /non autorise/, `complexe ${p}`);
    // Tour à outils : OpenAI est détourné vers Claude par la garde historique, les autres sont refusés ; jamais le fournisseur interdit.
    try {
      assert.notEqual(buildRoute({ config: { ...permissive, toolProvider: p }, hasTools: true }).provider, p, `outils ${p}`);
    } catch (err) {
      assert.match(err.message, /non autorise/);
    }
  }
});

test('fournisseur interdit dans le secours → écarté, jamais retenu', () => {
  const route = buildRoute({
    config: { enableFallback: true, fallbackProviders: ['openai', 'mistral', 'gemini', 'deepseek', 'groq', 'claude'], allowedProviders: ALL },
    forceProvider: 'claude',
  });
  assert.deepEqual(route.fallbacks, ['gemini']);
  const viaEnvLikeList = normalizeConfig({ fallbackProviders: 'openai,groq' });
  assert.deepEqual(viaEnvLikeList.fallbackProviders, [], 'le pool de secours lui-même est plafonné');
});

test('configuration dynamique (settings/ai) tentant d\'ajouter OpenAI → liste effective inchangée', () => {
  for (const settings of [
    { allowedProviders: ['claude', 'gemini', 'openai'] },
    { allowedProviders: 'claude,gemini,openai,mistral' },
    { allowedProviders: ALL },
  ]) {
    assert.deepEqual(normalizeConfig(settings).allowedProviders, ['claude', 'gemini'], JSON.stringify(settings));
  }
  // Une restriction reste possible.
  assert.deepEqual(normalizeConfig({ allowedProviders: ['claude'] }).allowedProviders, ['claude']);
  assert.deepEqual(normalizeConfig({ allowedProviders: [] }).allowedProviders, []);
  // Champs hérités : provider/defaultProvider=openai → refusé au routage.
  assert.throws(() => buildRoute({ config: { allowedProviders: ALL, provider: 'openai' } }), /non autorise/);
  assert.throws(() => buildRoute({ config: { allowedProviders: ALL, defaultProvider: 'openai' } }), /non autorise/);
});

// ── Consentement ↔ fournisseur ──────────────────────────────────────────────────────────────────────────────────
test('consentement : claude↔anthropic, gemini↔google ; rien d\'autre n\'est jamais consenti', () => {
  const base = { granted: true, version: CONSENT_VERSION };
  assert.deepEqual(consentedRouterProviders({ ...base, providers: ['anthropic', 'google'] }), ['claude', 'gemini']);
  assert.deepEqual(consentedRouterProviders({ ...base, providers: ['anthropic'] }), ['claude']);
  assert.deepEqual(consentedRouterProviders({ ...base, providers: ['google'] }), ['gemini']);
  assert.deepEqual(consentedRouterProviders({ ...base, providers: ['openai', 'mistral', 'claude'] }), []);
  assert.deepEqual(consentedRouterProviders({ ...base }), [], 'liste absente : aucun fournisseur');
  assert.deepEqual(consentedRouterProviders({ ...base, providers: 'anthropic' }), []);
  assert.deepEqual(consentedRouterProviders({ granted: false, version: CONSENT_VERSION, providers: ['anthropic', 'google'] }), []);
  assert.deepEqual(consentedRouterProviders({ granted: true, version: CONSENT_VERSION - 1, providers: ['anthropic', 'google'] }), []);
  assert.deepEqual(consentedRouterProviders(null), []);
});

// ── Service et passerelle avec fournisseurs factices ────────────────────────────────────────────────────────────
function fakeDb(settings) {
  return {
    collection: (name) => ({
      doc: (id) => ({
        get: async () => ({ exists: name === 'settings' && id === 'ai' && !!settings, data: () => settings }),
        set: async () => {},
      }),
      add: async () => ({ id: 'x' }),
    }),
  };
}
const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => 't', increment: (n) => n }, Timestamp: { fromMillis: (ms) => ({ toMillis: () => ms }) } } };

function fakeProvider(name, { fail = false } = {}) {
  const calls = [];
  const result = () => ({ text: `réponse ${name}`, model: 'm', inputTokens: 1, outputTokens: 1, toolCalls: [] });
  return {
    name, calls,
    isConfigured: () => true,
    supportsTools: () => true,
    supportsCanonicalHistory: () => true,
    generateText: async () => { calls.push('generateText'); if (fail) throw new Error(`${name} a échoué`); return result(); },
    generateVision: async () => { calls.push('generateVision'); if (fail) throw new Error(`${name} a échoué`); return result(); },
    generateTurn: async () => { calls.push('generateTurn'); if (fail) throw new Error(`${name} a échoué`); return result(); },
  };
}
function harness({ settings, failing = [] } = {}) {
  const providers = Object.fromEntries(ALL.map((n) => [n, fakeProvider(n, { fail: failing.includes(n) })]));
  const service = createAIProviderService({ db: fakeDb(settings), admin: fakeAdmin, providers });
  const forbiddenCalls = () => FORBIDDEN.reduce((n, p) => n + providers[p].calls.length, 0);
  return { providers, service, forbiddenCalls };
}
const TURN = { messages: [{ role: 'user', content: 'Bonjour' }], tools: [] };
const OPTS = { uid: 'u', cache: false, skipQuota: true, recordUsage: false };

test('generateText / generateVision : fournisseur interdit demandé → refusé, aucun appel', async () => {
  for (const p of FORBIDDEN) {
    const h = harness();
    await assert.rejects(h.service.generateText('x', { ...OPTS, provider: p }), /non autorise/, `texte ${p}`);
    await assert.rejects(h.service.generateVision('x', 'img', { ...OPTS, provider: p }), /non autorise/, `vision ${p}`);
    assert.equal(h.providers[p].calls.length, 0, p);
  }
});

test('generateText / generateVision : settings/ai.provider=openai → refusé, aucune transmission', async () => {
  const h = harness({ settings: { provider: 'openai', allowedProviders: ALL } });
  await assert.rejects(h.service.generateText('x', OPTS), /non autorise/);
  await assert.rejects(h.service.generateVision('x', 'img', OPTS), /non autorise/);
  assert.equal(h.forbiddenCalls(), 0);
});

test('generateText / generateVision : repli automatique uniquement vers claude/gemini, même si tout échoue', async () => {
  const h = harness({ failing: ['claude', 'gemini', ...FORBIDDEN], settings: { provider: 'claude', fallbackEnabled: true } });
  await assert.rejects(h.service.generateText('x', OPTS));
  await assert.rejects(h.service.generateVision('x', 'img', OPTS));
  assert.equal(h.forbiddenCalls(), 0, 'aucun fournisseur interdit ne doit être tenté en repli');
  assert.ok(h.providers.claude.calls.length > 0 && h.providers.gemini.calls.length > 0);
});

test('generateText : le repli fonctionne toujours vers gemini quand claude échoue', async () => {
  const h = harness({ failing: ['claude'], settings: { provider: 'claude', fallbackEnabled: true } });
  const r = await h.service.generateText('x', OPTS);
  assert.equal(r.provider, 'gemini');
  assert.equal(h.forbiddenCalls(), 0);
});

test('generateTurn : provider interdit demandé ou en repli → aucun appel', async () => {
  const h = harness({ settings: { allowedProviders: ALL, fallbackProviders: ['openai', 'mistral', 'gemini'], enableFallback: true }, failing: ['claude', 'gemini'] });
  await assert.rejects(h.service.generateTurn(TURN, OPTS));
  assert.equal(h.forbiddenCalls(), 0);
  const h2 = harness();
  await assert.rejects(h2.service.generateTurn(TURN, { ...OPTS, forceProvider: 'openai' }), /non autorise/);
  assert.equal(h2.forbiddenCalls(), 0);
});

test('consentement incompatible avec le fournisseur sélectionné → aucune transmission', async () => {
  const h = harness();
  // Consentement ne couvrant que Google : Claude (départ) est sauté, Gemini reçoit le tour si le repli est activé.
  const onlyGoogle = await h.service.generateTurn(TURN, { ...OPTS, consentedProviders: ['gemini'] });
  assert.equal(onlyGoogle.provider, 'gemini');
  assert.equal(h.providers.claude.calls.length, 0, 'claude non consenti : aucune transmission');
  // Aucun fournisseur consenti : erreur et zéro appel.
  const h2 = harness();
  await assert.rejects(h2.service.generateTurn(TURN, { ...OPTS, consentedProviders: [] }), /consentement/);
  assert.equal(ALL.reduce((n, p) => n + h2.providers[p].calls.length, 0), 0);
});

test('fournisseur de secours contrôlé par le consentement avant son utilisation', async () => {
  const h = harness({ failing: ['claude'] });
  // Claude consenti mais en panne ; Gemini non consenti → pas de repli, zéro transmission à Gemini.
  await assert.rejects(h.service.generateTurn(TURN, { ...OPTS, consentedProviders: ['claude'] }));
  assert.equal(h.providers.claude.calls.length, 1);
  assert.equal(h.providers.gemini.calls.length, 0);
  // Les deux consentis : le repli est utilisé.
  const h2 = harness({ failing: ['claude'] });
  const r = await h2.service.generateTurn(TURN, { ...OPTS, consentedProviders: ['claude', 'gemini'] });
  assert.equal(r.provider, 'gemini');
  assert.equal(r.fallbackFrom, 'claude');
});

test('une erreur de fournisseur ne provoque jamais de transmission à un fournisseur interdit', async () => {
  const h = harness({ failing: ['claude', 'gemini'], settings: { allowedProviders: ALL, fallbackProviders: ['openai', 'groq'], enableFallback: true } });
  await assert.rejects(h.service.generateTurn(TURN, { ...OPTS, consentedProviders: ['claude', 'gemini'] }));
  assert.equal(h.forbiddenCalls(), 0);
});

test('passerelle AZ IA : sans liste de fournisseurs consentis, rien ne part (fail closed)', async () => {
  const h = harness();
  const gateway = createAiGateway({ providerService: h.service, policyEngine: { canExecute: () => true } });
  await assert.rejects(gateway.generateTurn(TURN, { uid: 'u' }), /CONSENT_REQUIRED/);
  assert.equal(ALL.reduce((n, p) => n + h.providers[p].calls.length, 0), 0);
  const ok = await gateway.generateTurn(TURN, { uid: 'u', consentedProviders: ['claude', 'gemini'] });
  assert.equal(ok.provider, 'claude');
});

test('DEFAULT_CONFIG du service reste limité à claude et gemini', () => {
  assert.deepEqual(DEFAULT_CONFIG.allowedProviders, ['claude', 'gemini']);
});
