'use strict';

// Routing is configuration-driven. Environment variables provide safe deploy-time
// defaults; settings/ai can override them at runtime without exposing API keys.
const PROVIDERS = ['claude', 'openai', 'gemini', 'mistral', 'deepseek', 'groq'];

// Seuls fournisseurs qui peuvent recevoir des données d'utilisateurs dans le parcours AZ IA : ceux annoncés dans le
// consentement et la politique de confidentialité (Anthropic, Google). Plafond ABSOLU : ni AI_ALLOWED_PROVIDERS, ni
// settings/ai (modifiable par un admin), ni un fournisseur forcé par l'appelant ne peuvent le dépasser. Pour en
// ajouter un, il faut modifier ce code ET le consentement/la politique (CONSENT_VERSION), jamais une configuration.
const AZIA_ALLOWED_PROVIDERS = Object.freeze(['claude', 'gemini']);

function isAziaProviderAllowed(provider) {
  return AZIA_ALLOWED_PROVIDERS.includes(provider);
}

function asBoolean(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  return String(value).toLowerCase() === 'true';
}

function asList(value, fallback = []) {
  if (Array.isArray(value)) return value.filter((item) => PROVIDERS.includes(item));
  if (typeof value !== 'string') return fallback;
  return value.split(',').map((item) => item.trim()).filter((item) => PROVIDERS.includes(item));
}

// OpenAI ne participe aux tours à outils que si ce flag est explicitement
// activé (voir OpenAIProvider.supportsTools()) — défaut désactivé tant que
// les tests E2E des outils OpenAI ne sont pas terminés (Mission 4/6).
function isOpenAIToolCallingEnabled() {
  return asBoolean(process.env.AI_OPENAI_TOOL_CALLING_ENABLED, false);
}

// Liste blanche effective : l'intersection de la valeur fournie (tableau ou CSV) et du plafond AZIA_ALLOWED_PROVIDERS.
// Absente (ni tableau ni chaîne) = le plafond lui-même. Vide ou invalide = liste vide = tout est refusé (fail closed).
function asAllowedList(value) {
  if (Array.isArray(value)) return value.filter(isAziaProviderAllowed);
  if (typeof value !== 'string') return [...AZIA_ALLOWED_PROVIDERS];
  return value.split(',').map((item) => item.trim()).filter(isAziaProviderAllowed);
}

const ROUTER_DEFAULTS = Object.freeze({
  defaultProvider: process.env.AI_DEFAULT_PROVIDER || 'claude',
  complexProvider: process.env.AI_COMPLEX_PROVIDER || null,
  imageProvider: process.env.AI_IMAGE_PROVIDER || null,
  // Explicit tool override; otherwise follow the configured primary.
  toolProvider: process.env.AI_TOOL_PROVIDER || null,
  // Cible actée : Claude principal, Gemini en repli.
  //
  // ⚠️ Cette liste est un POOL, pas une chaîne orientée : `buildRoute()` en
  // retire le fournisseur de départ (`filter(c => c !== provider)`). Elle doit
  // donc contenir Claude ET Gemini pour que le repli fonctionne dans le sens
  // réellement voulu (claude → gemini) — la réduire à ['gemini'] viderait au
  // contraire les replis quand Gemini est le fournisseur de départ.
  //
  // OpenAI/Groq/Mistral/DeepSeek restent implémentés et activables
  // explicitement (`AI_FALLBACK_PROVIDERS`, `settings/ai`) mais sont hors de
  // la chaîne par défaut : aucune de leurs clés n'est requise au déploiement,
  // et un incident Claude ne déclenche pas une cascade vers quatre
  // fournisseurs non configurés.
  fallbackProviders: asList(process.env.AI_FALLBACK_PROVIDERS, ['claude', 'gemini']).filter(isAziaProviderAllowed),
  allowedProviders: asAllowedList(process.env.AI_ALLOWED_PROVIDERS),
  // Activé par défaut : `settings/ai` n'existe pas en production, donc un
  // défaut à `false` revenait à n'avoir AUCUN filet si Claude tombe. Le
  // basculement reste strictement conditionné à l'éligibilité de l'erreur
  // (voir providers/fallbackPolicy.js), jamais déclenché à l'aveugle.
  enableFallback: asBoolean(process.env.AI_ENABLE_FALLBACK, true),
  enableCache: asBoolean(process.env.AI_ENABLE_CACHE, true),
  enableMetrics: asBoolean(process.env.AI_ENABLE_METRICS, true),
});

function normalizeConfig(config = {}) {
  // `provider` and `fallbackEnabled` are legacy settings already used in production.
  const defaultProvider = config.defaultProvider || config.provider || ROUTER_DEFAULTS.defaultProvider;
  return {
    ...ROUTER_DEFAULTS,
    ...config,
    defaultProvider,
    provider: config.provider || defaultProvider,
    complexProvider: config.complexProvider || ROUTER_DEFAULTS.complexProvider || defaultProvider,
    imageProvider: config.imageProvider || ROUTER_DEFAULTS.imageProvider || defaultProvider,
    // Explicit legacy overrides remain valid. An absent override follows the
    // configured primary, rather than silently pinning every chat to Claude.
    toolProvider: config.toolProvider || ROUTER_DEFAULTS.toolProvider || defaultProvider,
    fallbackProviders: asList(config.fallbackProviders, ROUTER_DEFAULTS.fallbackProviders).filter(isAziaProviderAllowed),
    // settings/ai ne peut que RESTREINDRE la liste : l'intersection avec le plafond retire tout fournisseur non annoncé.
    allowedProviders: config.allowedProviders === undefined
      ? [...ROUTER_DEFAULTS.allowedProviders]
      : asAllowedList(config.allowedProviders).filter((p) => ROUTER_DEFAULTS.allowedProviders.includes(p)),
    // Keep the legacy Firestore key active during migration. An explicit true
    // on either key enables fallback; the new key is the preferred one.
    // Précédence EXPLICITE, et non un OU logique. L'ancienne forme
    // (`config.enableFallback === true || config.fallbackEnabled === true`)
    // laissait l'ancien champ écraser le champ officiel : poser
    // `enableFallback: false` dans settings/ai pour couper un repli devenu
    // indésirable n'avait aucun effet si `fallbackEnabled: true` traînait
    // dans le même document. Un opérateur ne doit jamais se voir refuser un
    // arrêt explicite du repli.
    enableFallback: config.enableFallback !== undefined
      ? config.enableFallback === true
      : (config.fallbackEnabled !== undefined
        ? config.fallbackEnabled === true
        : ROUTER_DEFAULTS.enableFallback),
  };
}

function buildRoute({ config, hasTools = false, hasImage = false, complexity = 'standard', forceProvider }) {
  const normalized = normalizeConfig(config);
  let provider = forceProvider;
  let reason = 'forced';
  if (!provider && hasTools) {
    provider = normalized.toolProvider;
    reason = 'tools';
    // Garde-fou additif : un provider explicitement forcé par l'appelant
    // (forceProvider) n'est jamais réécrit ici — seule la sélection par
    // heuristique de routage l'est, pour ne jamais aboutir sur un provider
    // qui refusera structurellement les outils (voir supportsTools()).
    if (provider === 'openai' && !isOpenAIToolCallingEnabled()) {
      provider = 'claude';
      reason = 'tools_openai_disabled';
    }
  } else if (!provider && hasImage) {
    provider = normalized.imageProvider;
    reason = 'image';
  } else if (!provider && complexity === 'complex') {
    provider = normalized.complexProvider;
    reason = 'complex';
  } else if (!provider) {
    provider = normalized.defaultProvider;
    reason = 'default';
  }

  if (!isAziaProviderAllowed(provider) || !normalized.allowedProviders.includes(provider)) {
    throw new Error(`Fournisseur IA non autorise par la politique: ${provider}`);
  }

  const fallbacks = normalized.enableFallback
    ? normalized.fallbackProviders.filter((candidate) => candidate !== provider
      && isAziaProviderAllowed(candidate) && normalized.allowedProviders.includes(candidate))
    : [];
  return { provider, fallbacks, reason, config: normalized };
}

module.exports = { PROVIDERS, AZIA_ALLOWED_PROVIDERS, isAziaProviderAllowed, ROUTER_DEFAULTS, normalizeConfig, buildRoute, isOpenAIToolCallingEnabled };
