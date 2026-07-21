'use strict';

const crypto = require('crypto');
const {
  ClaudeProvider, OpenAIProvider, GeminiProvider,
  DeepSeekProvider, MistralProvider, GroqProvider,
} = require('./providers');

// ═══════════════════════════════════════════════════════════════════════════
// AIProviderService (Master Prompt 108) — orchestrateur multi-fournisseurs IA.
//
// Architecture :
//   AZ IA / futures fonctionnalités IA
//         │
//         ▼
//   AIProviderService (ce fichier)
//         │
//   ├── ClaudeProvider    (réel, seul fournisseur avec une clé configurée aujourd'hui)
//   ├── GeminiProvider    (réel — appel HTTP fonctionnel, attend GEMINI_API_KEY)
//   ├── OpenAIProvider    (réel — attend OPENAI_API_KEY)
//   ├── DeepSeekProvider  (réel — attend DEEPSEEK_API_KEY)
//   ├── MistralProvider   (réel — attend MISTRAL_API_KEY)
//   └── GroqProvider      (réel — attend GROQ_API_KEY)
//
// Portée volontairement limitée à generateText/generateChat/generateVision
// (texte/chat/vision simples, sans appel d'outils) — la boucle d'appel
// d'outils d'AZ IA (functions/azia/index.js) reste spécifique à Claude et
// n'est PAS routée à travers ce service : aucun des 5 autres fournisseurs
// n'implémente le registre d'outils AZ IA (commandes, wallet, etc.), un
// fallback qui tenterait de continuer une conversation avec outils sur un
// autre fournisseur perdrait le contexte des appels déjà effectués — un vrai
// risque fonctionnel, pas juste un détail technique. Ce service sert les
// futurs besoins de génération simple (résumé, reformulation, description
// d'image...) et fournit dès maintenant le suivi d'usage/coût réutilisé par
// azIaChat pour son propre appel Claude (voir functions/azia/index.js).
// ═══════════════════════════════════════════════════════════════════════════

// Tarifs approximatifs en USD par million de tokens — donnés à titre
// indicatif pour l'ESTIMATION de coût uniquement (jamais une facturation
// exacte), à ajuster si les grilles tarifaires publiques des fournisseurs
// changent. Aucune valeur inventée : ce sont les tarifs publics connus au
// moment de l'écriture pour le modèle par défaut de chaque provider.
const PRICING = {
  claude:   { input: 3.00,  output: 15.00 }, // claude-sonnet-5
  openai:   { input: 0.15,  output: 0.60  }, // gpt-4o-mini
  gemini:   { input: 0.075, output: 0.30  }, // gemini-2.0-flash
  deepseek: { input: 0.14,  output: 0.28  }, // deepseek-chat
  mistral:  { input: 2.00,  output: 6.00  }, // mistral-large-latest
  groq:     { input: 0.05,  output: 0.08  }, // llama-3.3-70b (groq)
};

// Ordre de bascule automatique — reprend l'exemple donné dans la demande
// (Claude → Gemini → OpenAI → DeepSeek), complété par Mistral/Groq en fin
// de liste. Le provider explicitement configuré (settings/ai.provider) est
// toujours tenté en premier, cet ordre ne s'applique qu'aux tentatives
// suivantes si fallbackEnabled est actif.
const FALLBACK_ORDER = ['claude', 'gemini', 'openai', 'deepseek', 'mistral', 'groq'];

const DEFAULT_CONFIG = {
  provider: 'claude',
  fallbackEnabled: false,
  preferredModel: null,
  temperature: 0.7,
  maxTokens: 1024,
  timeout: 30000,
};

// Quotas par défaut si settings/ai.quotas n'en définit pas — un simple
// repli, pas une politique figée : modifiable depuis Firestore sans redéploiement.
const DEFAULT_QUOTAS = {
  client:  { perDay: 50, perMonth: 1000 },
  default: { perDay: 30, perMonth: 500 },
};

const CACHE_TTL_MS = 60 * 60 * 1000; // 1h — question identique servie depuis le cache
const CONFIG_CACHE_MS = 60 * 1000;   // évite une lecture Firestore à chaque appel

function createAIProviderService({ db, admin, providers: providersOverride }) {
  // `providers` injectable pour les tests (fournisseurs factices sans appel
  // réseau) — par défaut, les vraies implémentations ci-dessus.
  const providers = providersOverride || {
    claude:   new ClaudeProvider(),
    gemini:   new GeminiProvider(),
    openai:   new OpenAIProvider(),
    deepseek: new DeepSeekProvider(),
    mistral:  new MistralProvider(),
    groq:     new GroqProvider(),
  };

  let cachedConfig = null;
  let cachedConfigAt = 0;

  async function getConfig() {
    const now = Date.now();
    if (cachedConfig && now - cachedConfigAt < CONFIG_CACHE_MS) return cachedConfig;
    try {
      const snap = await db.collection('settings').doc('ai').get();
      cachedConfig = { ...DEFAULT_CONFIG, ...(snap.exists ? snap.data() : {}) };
    } catch (_) {
      cachedConfig = { ...DEFAULT_CONFIG };
    }
    cachedConfigAt = now;
    return cachedConfig;
  }

  function estimateCost(providerName, inputTokens, outputTokens) {
    const rate = PRICING[providerName];
    if (!rate) return 0;
    return (inputTokens / 1e6) * rate.input + (outputTokens / 1e6) * rate.output;
  }

  // ── Cache (questions identiques) ──────────────────────────────────────────
  function hashKey(providerHint, method, args) {
    return crypto.createHash('sha256')
      .update(`${providerHint}|${method}|${JSON.stringify(args)}`)
      .digest('hex');
  }

  async function getFromCache(key) {
    try {
      const doc = await db.collection('ai_cache').doc(key).get();
      if (!doc.exists) return null;
      const data = doc.data();
      if (!data.expiresAt || data.expiresAt.toMillis() < Date.now()) return null;
      return data.result;
    } catch (_) {
      return null;
    }
  }

  async function saveToCache(key, result) {
    try {
      await db.collection('ai_cache').doc(key).set({
        result,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + CACHE_TTL_MS),
      });
    } catch (_) {
      // best-effort : un échec d'écriture cache ne doit jamais faire échouer la réponse
    }
  }

  // ── Quotas (par utilisateur, par rôle, par jour et par mois) ─────────────
  async function checkAndIncrementQuota(uid, role) {
    const config = await getConfig();
    const quotas = { ...DEFAULT_QUOTAS, ...(config.quotas || {}) };
    const limits = quotas[role] || quotas.default;

    const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
    const month = today.slice(0, 7);                       // YYYY-MM

    const dayRef = db.collection('ai_quotas').doc(`${uid}_${today}`);
    const monthRef = db.collection('ai_quotas').doc(`${uid}_${month}`);

    await db.runTransaction(async (tx) => {
      const [daySnap, monthSnap] = await Promise.all([tx.get(dayRef), tx.get(monthRef)]);
      const dayCount = daySnap.exists ? (daySnap.data().count || 0) : 0;
      const monthCount = monthSnap.exists ? (monthSnap.data().count || 0) : 0;

      if (limits.perDay && dayCount >= limits.perDay) {
        const e = new Error(`Quota quotidien AZ IA atteint (${limits.perDay} requêtes/jour)`);
        e.code = 'quota_exceeded';
        e.scope = 'day';
        throw e;
      }
      if (limits.perMonth && monthCount >= limits.perMonth) {
        const e = new Error(`Quota mensuel AZ IA atteint (${limits.perMonth} requêtes/mois)`);
        e.code = 'quota_exceeded';
        e.scope = 'month';
        throw e;
      }

      tx.set(dayRef, {
        uid, period: 'day', key: today, count: dayCount + 1,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      tx.set(monthRef, {
        uid, period: 'month', key: month, count: monthCount + 1,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });
  }

  // ── Usage / coût / logs / statistiques quotidiennes ───────────────────────
  // Non-bloquant : jamais attendu avant de renvoyer la réponse à l'appelant.
  function recordUsage({ uid, role, provider, model, inputTokens, outputTokens, responseTimeMs, success, fallbackFrom, errorMessage }) {
    const cost = estimateCost(provider, inputTokens || 0, outputTokens || 0);
    const date = new Date().toISOString().slice(0, 10);

    db.collection('ai_usage').add({
      uid: uid || null, role: role || null, provider, model: model || null,
      inputTokens: inputTokens || 0, outputTokens: outputTokens || 0,
      estimatedCost: cost, responseTimeMs: responseTimeMs || 0, success,
      fallbackFrom: fallbackFrom || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }).catch((e) => console.error('ai_usage write failed:', e.message));

    db.collection('ai_logs').add({
      uid: uid || null, provider, model: model || null, success,
      errorMessage: errorMessage || null, fallbackFrom: fallbackFrom || null,
      responseTimeMs: responseTimeMs || 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }).catch((e) => console.error('ai_logs write failed:', e.message));

    db.collection('ai_daily_stats').doc(`${date}_${provider}`).set({
      date, provider,
      requestCount: admin.firestore.FieldValue.increment(1),
      errorCount: admin.firestore.FieldValue.increment(success ? 0 : 1),
      totalInputTokens: admin.firestore.FieldValue.increment(inputTokens || 0),
      totalOutputTokens: admin.firestore.FieldValue.increment(outputTokens || 0),
      totalCost: admin.firestore.FieldValue.increment(cost),
      totalResponseTimeMs: admin.firestore.FieldValue.increment(responseTimeMs || 0),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true }).catch((e) => console.error('ai_daily_stats write failed:', e.message));

    return cost;
  }

  // ── Cœur : appelle un provider, avec bascule automatique si activée ──────
  async function callWithFallback(method, args, opts, config) {
    const startProvider = opts.provider || config.provider || 'claude';
    const order = [startProvider, ...FALLBACK_ORDER.filter(p => p !== startProvider)];
    const attemptOrder = config.fallbackEnabled ? order : [startProvider];

    let lastError = null;
    for (let i = 0; i < attemptOrder.length; i++) {
      const providerName = attemptOrder[i];
      const provider = providers[providerName];
      if (!provider) continue;
      if (!provider.isConfigured()) {
        // Jamais tenté sur le réseau — ne compte pas comme une panne, juste
        // un fournisseur pas encore activé, on passe au suivant silencieusement.
        lastError = lastError || new Error(`Fournisseur "${providerName}" non configuré`);
        continue;
      }
      const t0 = Date.now();
      try {
        const result = await provider[method](...args, {
          model: opts.model || config.preferredModel || undefined,
          temperature: opts.temperature ?? config.temperature,
          maxTokens: opts.maxTokens ?? config.maxTokens,
          system: opts.system,
          mediaType: opts.mediaType,
        });
        return {
          ...result,
          provider: providerName,
          responseTimeMs: Date.now() - t0,
          fallbackFrom: i > 0 ? startProvider : null,
        };
      } catch (err) {
        lastError = err;
        console.error(`AIProviderService: ${providerName}.${method} a échoué — ${err.message}`);
        if (!config.fallbackEnabled) break;
        // fallbackEnabled : on continue vers le fournisseur suivant
      }
    }
    throw lastError || new Error('Aucun fournisseur IA disponible');
  }

  async function generate(method, args, opts = {}) {
    const config = await getConfig();
    const uid = opts.uid || null;
    const role = opts.role || null;

    if (uid) await checkAndIncrementQuota(uid, role || 'default');

    // La vision n'est jamais mise en cache (image différente à chaque appel,
    // une clé de cache basée sur le texte seul serait trompeuse).
    const cacheable = opts.cache !== false && method !== 'generateVision';
    const cacheKey = cacheable ? hashKey(opts.provider || config.provider, method, args) : null;
    if (cacheKey) {
      const cached = await getFromCache(cacheKey);
      if (cached) {
        // Master Prompt 118 — jusqu'ici, un coup de cache ne laissait
        // absolument aucune trace (recordUsage() n'est appelé que sur le
        // chemin réseau ci-dessous) : impossible de mesurer l'efficacité du
        // cache. Compteur additif minimal, jamais bloquant.
        const date = new Date().toISOString().slice(0, 10);
        db.collection('ai_daily_stats').doc(`${date}_${opts.provider || config.provider}`).set({
          date, provider: opts.provider || config.provider,
          cacheHitCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }).catch((e) => console.error('ai_daily_stats cache-hit write failed:', e.message));
        return { ...cached, cached: true };
      }
    }

    try {
      const result = await callWithFallback(method, args, opts, config);
      recordUsage({
        uid, role, provider: result.provider, model: result.model,
        inputTokens: result.inputTokens, outputTokens: result.outputTokens,
        responseTimeMs: result.responseTimeMs, success: true,
        fallbackFrom: result.fallbackFrom,
      });
      if (cacheKey) await saveToCache(cacheKey, result);
      return result;
    } catch (err) {
      recordUsage({
        uid, role, provider: opts.provider || config.provider,
        model: opts.model || 'n/a', inputTokens: 0, outputTokens: 0,
        responseTimeMs: 0, success: false, errorMessage: err.message,
      });
      throw err;
    }
  }

  return {
    providers,
    getConfig,
    generateText:   (prompt, opts)        => generate('generateText',   [prompt], opts || {}),
    generateChat:   (messages, opts)      => generate('generateChat',   [messages], opts || {}),
    generateVision: (prompt, image, opts) => generate('generateVision', [prompt, image], opts || {}),
    // Exposé pour intégration additive dans azIaChat (boucle d'outils Claude
    // existante, volontairement non réécrite — voir en-tête de ce fichier) :
    // permet à azIaChat de continuer à journaliser son propre usage/coût
    // dans les mêmes collections ai_usage/ai_logs/ai_daily_stats que ce
    // service, sans passer par callWithFallback (qui perdrait le contexte
    // d'outils déjà en cours).
    recordUsage,
    estimateCost,
  };
}

module.exports = { createAIProviderService, PRICING, FALLBACK_ORDER, DEFAULT_CONFIG, DEFAULT_QUOTAS };
