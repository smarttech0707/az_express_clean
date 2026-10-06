'use strict';

// Tests du routage (Mission 12) — aiRouter.js reste une fonction pure,
// aucun appel réseau, aucune dépendance Firestore.

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildRoute, normalizeConfig } = require('../azia/aiRouter');

function withEnv(key, value, fn) {
  const original = process.env[key];
  if (value === undefined) delete process.env[key]; else process.env[key] = value;
  try { return fn(); } finally { if (original === undefined) delete process.env[key]; else process.env[key] = original; }
}

const OPEN_CONFIG = {
  defaultProvider: 'openai', complexProvider: 'claude', imageProvider: 'openai',
  toolProvider: 'claude', allowedProviders: ['claude', 'openai', 'gemini'],
};

test('1. requête simple sans outil ni image → OpenAI (provider par défaut)', () => {
  const route = buildRoute({ config: OPEN_CONFIG });
  assert.equal(route.provider, 'openai');
  assert.equal(route.reason, 'default');
});

test('2. requête complexe → fournisseur configuré (complexProvider)', () => {
  const route = buildRoute({ config: OPEN_CONFIG, complexity: 'complex' });
  assert.equal(route.provider, 'claude');
  assert.equal(route.reason, 'complex');
});

test('3. image non-sensible, sans outil → OpenAI si configuré (imageProvider)', () => {
  const route = buildRoute({ config: OPEN_CONFIG, hasImage: true });
  assert.equal(route.provider, 'openai');
  assert.equal(route.reason, 'image');
});

test('4. outil non-sensible, flag OpenAI désactivé → Claude (jamais un dead-end)', () => {
  const route = withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', 'false', () =>
    buildRoute({ config: { ...OPEN_CONFIG, toolProvider: 'openai' }, hasTools: true }));
  assert.equal(route.provider, 'claude');
  assert.equal(route.reason, 'tools_openai_disabled');
});

test('5. outil sensible (wallet/paiement) → toujours Claude, quel que soit defaultProvider', () => {
  const route = buildRoute({ config: OPEN_CONFIG, hasTools: true });
  assert.equal(route.provider, 'claude');
  assert.equal(route.reason, 'tools');
});

test('6. Wallet (lecture solde, tool présent) → Claude', () => {
  const route = buildRoute({ config: { ...OPEN_CONFIG, toolProvider: 'claude' }, hasTools: true });
  assert.equal(route.provider, 'claude');
});

test('7. Création de commande (tool présent) → Claude', () => {
  const route = buildRoute({ config: { ...OPEN_CONFIG, toolProvider: 'claude' }, hasTools: true, complexity: 'complex' });
  // hasTools est vérifié avant complexity dans buildRoute — le tool provider gagne toujours.
  assert.equal(route.provider, 'claude');
  assert.equal(route.reason, 'tools');
});

test('8. Confirmation d\'action en attente (tool présent) → Claude', () => {
  const route = buildRoute({ config: OPEN_CONFIG, hasTools: true });
  assert.equal(route.provider, 'claude');
});

test('9. Erreur OpenAI sans outil → fallback Claude autorisé si enableFallback', () => {
  const route = buildRoute({
    config: { ...OPEN_CONFIG, enableFallback: true, fallbackProviders: ['claude', 'gemini'] },
  });
  assert.equal(route.provider, 'openai');
  assert.deepEqual(route.fallbacks, ['claude', 'gemini']);
});

// Le repli est désormais ACTIVÉ par défaut (Claude principal, Gemini en
// repli) : l'assertion d'origine ne prouvait l'absence de rejeu que par effet
// de bord d'un fallback désactivé. On vérifie maintenant la vraie garantie,
// sur ses propres termes : un repli explicitement coupé ne propose aucun
// fournisseur, et un repli activé n'en propose que des compatibles outils.
test('10. Repli explicitement coupé sur un tour à outils → aucun fournisseur de repli', () => {
  const route = buildRoute({
    config: { ...OPEN_CONFIG, enableFallback: false }, hasTools: true,
  });
  assert.deepEqual(route.fallbacks, []);
});

test('10b. Repli activé sur un tour à outils → seuls des fournisseurs autorisés, jamais le fournisseur de départ', () => {
  const route = buildRoute({
    config: { ...OPEN_CONFIG, enableFallback: true, fallbackProviders: ['claude', 'gemini'] },
    hasTools: true,
  });
  assert.equal(route.provider, 'claude', 'toolProvider reste la cible initiale');
  assert.ok(!route.fallbacks.includes('claude'),
    'le fournisseur de départ ne doit jamais figurer dans ses propres replis');
  for (const candidate of route.fallbacks) {
    assert.ok(OPEN_CONFIG.allowedProviders.includes(candidate),
      `${candidate} doit être autorisé par la politique`);
  }
});

test('11. Fournisseur non autorisé par la politique → erreur explicite, jamais un routage silencieux', () => {
  assert.throws(
    () => buildRoute({ config: { ...OPEN_CONFIG, allowedProviders: ['claude'] }, forceProvider: 'openai' }),
    /non autorise/,
  );
});

test('12. Configuration Firestore invalide/partielle → repli sur des valeurs sûres (normalizeConfig)', () => {
  const normalized = normalizeConfig({});
  assert.equal(normalized.defaultProvider, 'claude');
  assert.equal(normalized.toolProvider, 'claude');
  // Cible actée : le repli est activé par défaut (Claude principal, Gemini en
  // repli) — un défaut à false laissait AZ IA sans aucun filet, puisque le
  // document settings/ai n'existe pas en production.
  assert.equal(normalized.enableFallback, true);
  assert.deepEqual(normalized.fallbackProviders, ['claude', 'gemini']);
  assert.ok(Array.isArray(normalized.allowedProviders) && normalized.allowedProviders.length > 0);
});

test('13. Aucun fournisseur disponible dans la liste autorisée → erreur claire (pas un throw opaque)', () => {
  assert.throws(
    () => buildRoute({ config: { defaultProvider: 'openai', allowedProviders: ['claude'] } }),
    (err) => err.message.includes('openai'),
  );
});

test('forceProvider explicite avec des outils reste respecté par le routeur (le filtre supportsTools() vit dans AIProviderService, pas ici)', () => {
  const route = buildRoute({ config: OPEN_CONFIG, hasTools: true, forceProvider: 'openai' });
  assert.equal(route.provider, 'openai');
  assert.equal(route.reason, 'forced');
});
