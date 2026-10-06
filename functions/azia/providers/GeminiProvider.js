'use strict';

const https = require('https');
const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');
const {
  toGeminiContents,
  toGeminiToolDeclarations,
  fromGeminiCandidate,
  textBlock,
  userMessage,
} = require('../canonicalHistory');

// Gemini a un format de requête/réponse distinct du format "OpenAI-compatible"
// (contents/parts, pas messages/content ; clé API en query string, pas en
// header Authorization) — ne peut pas réutiliser OpenAICompatibleProvider.
//
// ⚠️ MODÈLE : `gemini-2.0-flash`, seule référence historique du dépôt, n'est
// plus utilisé par défaut. Aucun modèle de remplacement n'étant déterminable
// localement (aucune constante moderne dans le code, et il est interdit
// d'interroger le réseau), `GEMINI_MODEL` est OBLIGATOIRE pour activer ce
// fournisseur. Un modèle absent provoque une erreur claire plutôt qu'un repli
// silencieux sur un modèle potentiellement retiré.
const DEFAULT_TIMEOUT_MS = 30000;
// Longueur max du message Google conservé après expurgation. Volontairement
// courte : ce champ sert au diagnostic, pas à rejouer le corps de Google.
const MAX_ERROR_MESSAGE_LENGTH = 200;

class GeminiProvider extends BaseProvider {
  constructor() {
    super('gemini');
    // Native continuation parts (including thought signatures) never leave
    // this provider. Weak keys are the canonical content arrays of this turn.
    this._nativeTurns = new WeakMap();
  }

  /** Modèle résolu pour CE fournisseur uniquement — jamais un modèle Claude. */
  resolveModel(requestedModel) {
    const candidate = String(requestedModel || process.env.GEMINI_MODEL || '').trim();
    if (!candidate) {
      const error = new Error(
        'gemini: aucun modèle configuré — définir GEMINI_MODEL pour activer ce fournisseur',
      );
      error.code = 'provider_model_not_configured';
      throw error;
    }
    return candidate;
  }

  isConfigured() {
    // Une clé sans modèle ne suffit pas : le fournisseur serait inutilisable.
    return !!process.env.GEMINI_API_KEY && !!String(process.env.GEMINI_MODEL || '').trim();
  }

  supportsTools() {
    return true;
  }

  supportsCanonicalHistory() { return true; }

  /**
   * Extrait d'un corps d'erreur Google les SEULS champs sûrs pour le
   * diagnostic. Jusqu'ici le corps était intégralement jeté : un 503 ne
   * disait pas s'il s'agissait d'une surcharge de modèle ou d'autre chose.
   *
   * Ne sortent d'ici que :
   *   - `error.status`            (énumération : UNAVAILABLE, RESOURCE_EXHAUSTED…)
   *   - `error.details[].reason`  (énumération : MODEL_OVERLOADED…)
   *   - `error.message`           expurgé PUIS tronqué
   *
   * Les deux premiers sont filtrés caractère par caractère (`A-Z0-9_`) : même
   * si Google renvoyait un jour du texte libre dans ces champs, rien
   * d'arbitraire ne peut transiter. Le corps brut n'est JAMAIS conservé, et un
   * corps non-JSON ne produit simplement aucune métadonnée.
   */
  static extractGoogleError(raw) {
    const out = { status: null, reason: null, message: null };
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return out;                 // corps texte/HTML : rien n'est extrait ni journalisé
    }
    const err = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed.error : null;
    if (!err || typeof err !== 'object') return out;

    const enumOnly = (value) => String(value).replace(/[^A-Za-z0-9_]/g, '').slice(0, 64) || null;
    if (typeof err.status === 'string') out.status = enumOnly(err.status);
    if (Array.isArray(err.details)) {
      for (const detail of err.details) {
        if (detail && typeof detail.reason === 'string') {
          out.reason = enumOnly(detail.reason);
          break;
        }
      }
    }
    if (typeof err.message === 'string') {
      out.message = GeminiProvider.sanitizeError(err.message).slice(0, MAX_ERROR_MESSAGE_LENGTH);
    }
    return out;
  }

  /**
   * Expurge tout message d'erreur : ni clé, ni URL (qui contient la clé en
   * query string), ni en-tête ne doivent atteindre les journaux.
   */
  static sanitizeError(message) {
    const apiKey = process.env.GEMINI_API_KEY;
    let safe = String(message || '');
    if (apiKey) safe = safe.split(apiKey).join('[REDACTED]');
    safe = safe
      .replace(/key=[^&\s"']+/gi, 'key=[REDACTED]')
      .replace(/https:\/\/generativelanguage\.googleapis\.com\/\S*/gi, '[gemini-endpoint]')
      .replace(/(authorization|x-goog-api-key)\s*:\s*\S+/gi, '$1: [REDACTED]');
    return safe.slice(0, 300);
  }

  _post(model, body, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) return Promise.reject(new ProviderNotConfiguredError(this.name));
    const data = JSON.stringify(body);
    const transport = this.constructor.transport || https;
    return new Promise((resolve, reject) => {
      let settled = false;
      let deadline;
      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(deadline);
        if (error) reject(error); else resolve(value);
      };
      const fail = (rawMessage, code) => {
        const error = new Error(GeminiProvider.sanitizeError(rawMessage));
        if (code) error.code = code;
        finish(error);
      };
      const req = transport.request({
        hostname: 'generativelanguage.googleapis.com',
        path: `/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${apiKey}`,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
      }, (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            // Le corps de Google porte la seule information qui distingue une
            // surcharge passagère (UNAVAILABLE/MODEL_OVERLOADED) d'une requête
            // réellement invalide. On n'en extrait que des champs sûrs, et le
            // corps brut n'est ni conservé ni journalisé.
            const safe = GeminiProvider.extractGoogleError(raw);
            const parts = [`gemini HTTP ${res.statusCode}`];
            if (safe.status) parts.push(`status=${safe.status}`);
            if (safe.reason) parts.push(`reason=${safe.reason}`);
            if (safe.message) parts.push(`message=${safe.message}`);
            const error = new Error(GeminiProvider.sanitizeError(parts.join(' ')));
            error.code = 'provider_http_error';
            error.httpStatus = res.statusCode;
            error.providerStatus = safe.status;
            error.providerReason = safe.reason;
            error.sanitizedMessage = safe.message;
            finish(error);
            return;
          }
          try {
            finish(null, JSON.parse(raw));
          } catch (e) {
            fail(`gemini réponse JSON invalide: ${e.message}`, 'provider_invalid_json');
          }
        });
      });
      // Timeout borné appliqué au transport (la configuration existait mais
      // n'était jamais transmise à la requête) : sans cela, un appel bloqué
      // retenait la Cloud Function jusqu'à son propre délai d'expiration.
      const expire = () => {
        fail(`gemini: délai d'attente dépassé (${timeoutMs} ms)`, 'provider_timeout');
        req.destroy();
      };
      // Socket inactivity alone does not bound DNS/connect or a trickling body.
      timeoutMs = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS;
      deadline = setTimeout(expire, timeoutMs);
      req.setTimeout(timeoutMs, expire);
      req.on('error', (err) => fail(`gemini: ${err.message}`, err.code === 'ECONNRESET' ? 'provider_network' : undefined));
      req.write(data);
      req.end();
    });
  }

  async generateText(prompt, opts = {}) {
    return this.generateChat([{ role: 'user', content: prompt }], opts);
  }

  async generateChat(messages, opts = {}) {
    const model = this.resolveModel(opts.model);
    const contents = messages.map(m => ({
      role: m.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: m.content }],
    }));
    const body = {
      contents,
      ...(opts.system ? { systemInstruction: { parts: [{ text: flattenSystem(opts.system) }] } } : {}),
      generationConfig: {
        temperature: opts.temperature ?? 0.7,
        maxOutputTokens: opts.maxTokens || 1024,
      },
    };
    const json = await this._post(model, body, { timeoutMs: opts.timeoutMs });
    const parsed = fromGeminiCandidate(json);
    assertUsableResponse(parsed);
    return {
      text: parsed.text, model,
      inputTokens: json.usageMetadata?.promptTokenCount || 0,
      outputTokens: json.usageMetadata?.candidatesTokenCount || 0,
    };
  }

  async generateVision(prompt, imageBase64, opts = {}) {
    const model = this.resolveModel(opts.model);
    const body = {
      contents: [{
        role: 'user',
        parts: [
          { text: prompt },
          { inline_data: { mime_type: opts.mediaType || 'image/jpeg', data: imageBase64 } },
        ],
      }],
      generationConfig: { maxOutputTokens: opts.maxTokens || 1024 },
    };
    const json = await this._post(model, body, { timeoutMs: opts.timeoutMs });
    const parsed = fromGeminiCandidate(json);
    assertUsableResponse(parsed);
    return {
      text: parsed.text, model,
      inputTokens: json.usageMetadata?.promptTokenCount || 0,
      outputTokens: json.usageMetadata?.candidatesTokenCount || 0,
    };
  }

  /**
   * Tour canonique AZ IA : messages canoniques + déclarations d'outils AZ IA,
   * convertis vers le protocole Gemini, puis réponse reconvertie en canonique.
   * La couche supérieure ignore totalement qu'il s'agit de Gemini.
   */
  async generateTurn({
    systemPrompt, messages, tools = [], images, temperature, maxTokens, model,
    turnIndex = 0, timeoutMs,
  }) {
    if (!process.env.GEMINI_API_KEY) throw new ProviderNotConfiguredError(this.name);
    const selectedModel = this.resolveModel(model);

    const canonical = images?.base64
      ? [...messages, userMessage([
        textBlock(''),
        { type: 'image', data: images.base64, mediaType: images.mediaType || 'image/jpeg' },
      ])]
      : messages;

    const contents = toGeminiContents(canonical);
    canonical.forEach((message, index) => {
      const native = this._nativeTurns.get(message.content);
      if (native) {
        contents[index].parts = native;
      } else {
        contents[index].parts.forEach((part, position) => {
          const block = message.content[position];
          if (part.functionCall) {
            part.functionCall.id = block.id;
            // Official cross-model history transfer marker, never a substitute
            // for a Gemini signature we received. See Google thought-signature FAQ.
            part.thoughtSignature = 'skip_thought_signature_validator';
          }
        });
      }
      contents[index].parts.forEach((part, position) => {
        if (part.functionResponse) part.functionResponse.id = message.content[position].toolCallId;
      });
    });
    const body = {
      contents,
      ...(systemPrompt ? { systemInstruction: { parts: [{ text: flattenSystem(systemPrompt) }] } } : {}),
      ...(tools.length > 0 ? { tools: toGeminiToolDeclarations(tools) } : {}),
      generationConfig: {
        ...(temperature !== undefined ? { temperature } : {}),
        maxOutputTokens: maxTokens || 1024,
      },
    };

    const json = await this._post(selectedModel, body, { timeoutMs });
    const parsed = fromGeminiCandidate(json, { turnIndex });
    assertUsableResponse(parsed);
    this._nativeTurns.set(parsed.blocks, json.candidates[0].content.parts);

    return {
      text: parsed.text,
      toolCalls: parsed.toolCalls,
      inputTokens: json.usageMetadata?.promptTokenCount || 0,
      outputTokens: json.usageMetadata?.candidatesTokenCount || 0,
      provider: this.name,
      model: selectedModel,
      finishReason: parsed.finishReason,
      // Historique canonique : jamais de blocs propres au fournisseur.
      assistantMessage: parsed.blocks,
    };
  }
}

/**
 * Le prompt système d'AZ IA est une liste de blocs Anthropic
 * (`[{type:'text', text}]`) ; Gemini attend du texte simple. On aplatit sans
 * rien retirer : les règles de sécurité du prompt restent intégralement
 * transmises, et le prompt n'est jamais dupliqué.
 */
function flattenSystem(systemPrompt) {
  if (typeof systemPrompt === 'string') return systemPrompt;
  if (Array.isArray(systemPrompt)) {
    return systemPrompt.map((block) => (typeof block === 'string' ? block : block?.text || '')).join('\n\n');
  }
  return '';
}

/** Une réponse vide ou bloquée n'est jamais traitée comme un succès. */
function assertUsableResponse(parsed) {
  if (parsed.finishReason === 'blocked') {
    const error = new Error(`gemini: réponse bloquée (${parsed.blockReason || 'raison non précisée'})`);
    error.code = 'provider_blocked';
    throw error;
  }
  if (!parsed.text && parsed.toolCalls.length === 0) {
    const error = new Error('gemini: réponse vide');
    error.code = 'provider_empty_response';
    throw error;
  }
}

module.exports = GeminiProvider;
module.exports.flattenSystem = flattenSystem;
