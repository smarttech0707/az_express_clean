'use strict';

const { OpenAI } = require('openai');
const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');

// ═══════════════════════════════════════════════════════════════════════════
// OpenAIProvider — fournisseur réel utilisant le SDK officiel `openai` (npm),
// via l'API Responses (`client.responses.create`), l'interface recommandée
// par OpenAI pour toute nouvelle intégration (remplace l'ancienne API Chat
// Completions utilisée par OpenAICompatibleProvider — celle-ci reste en
// place, inchangée, pour DeepSeek/Mistral/Groq qui ne l'exposent pas).
//
// Portée de sécurité (voir CLAUDE.md — règles non négociables AZ IA) :
//   - Ce fichier n'écrit JAMAIS directement dans Firestore/Wallet/commandes.
//   - Il n'exécute JAMAIS un outil lui-même — il renvoie seulement les appels
//     d'outils demandés par le modèle ; l'exécution reste dans la boucle
//     serveur existante (functions/azia/index.js), inchangée par ce fichier.
//   - supportsTools() est verrouillé sur AI_OPENAI_TOOL_CALLING_ENABLED
//     (défaut: désactivé) — tant que ce flag n'est pas explicitement "true",
//     AIProviderService.callWithFallback exclut structurellement ce provider
//     de toute tentative avec des outils (voir AIProviderService.js:242-244),
//     et azia/index.js force de toute façon `forceProvider:'claude'` pour la
//     boucle d'outils réelle — cette classe ajoute une troisième garde
//     (generateTurn refuse explicitement si tools.length>0 et flag inactif),
//     jamais un simple silence sur les outils demandés.
// ═══════════════════════════════════════════════════════════════════════════

function isToolCallingEnabled() {
  return String(process.env.AI_OPENAI_TOOL_CALLING_ENABLED || '').toLowerCase() === 'true';
}

class OpenAIProvider extends BaseProvider {
  constructor() {
    super('openai');
    this._client = null;
  }

  isConfigured() {
    return !!process.env.OPENAI_API_KEY;
  }

  supportsTools() {
    return isToolCallingEnabled();
  }

  _getClient() {
    if (!this.isConfigured()) throw new ProviderNotConfiguredError(this.name);
    if (!this._client) {
      this._client = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
        timeout: Number(process.env.OPENAI_TIMEOUT_MS) || 30000,
      });
    }
    return this._client;
  }

  // ── Normalisation message/contenu (Mission 3) ──────────────────────────
  // Toute structure native OpenAI (Responses API) reste confinée ici — le
  // reste du serveur (aiGateway/AIProviderService/azia/index.js) ne connaît
  // que le contrat interne {text, toolCalls, inputTokens, outputTokens,
  // provider, model, finishReason, assistantMessage}.

  _normalizeBlock(block, fallbackMediaType) {
    if (block === null || block === undefined) return null;
    if (typeof block === 'string') return { type: 'input_text', text: block };
    if (typeof block !== 'object') return { type: 'input_text', text: String(block) };
    if (block.type === 'input_text' || block.type === 'input_image') return block;
    if (block.type === 'text') return { type: 'input_text', text: block.text || '' };
    if (block.type === 'image') {
      const source = block.source || {};
      if (source.type === 'base64' && source.data) {
        const mediaType = source.media_type || fallbackMediaType || 'image/jpeg';
        return { type: 'input_image', image_url: `data:${mediaType};base64,${source.data}` };
      }
      if (source.url) return { type: 'input_image', image_url: source.url };
      return null;
    }
    // Bloc de type inconnu (ex. tool_use/tool_result Claude-natifs). Ignoré
    // plutôt que de faire échouer tout le tour ou de le transformer en texte
    // trompeur — ces blocs n'atteignent jamais ce fournisseur en production
    // aujourd'hui (azia/index.js force Claude pour toute la boucle d'outils).
    return null;
  }

  _normalizeContent(content, fallbackMediaType) {
    if (typeof content === 'string') return [{ type: 'input_text', text: content }];
    if (Array.isArray(content)) {
      return content.map((block) => this._normalizeBlock(block, fallbackMediaType)).filter(Boolean);
    }
    if (content === null || content === undefined) return [];
    return [{ type: 'input_text', text: String(content) }];
  }

  // Contrat agnostique (Mission 5) pour renvoyer un résultat d'outil à un
  // fournisseur : {role:'tool', toolCallId, name, content}. Converti ici
  // vers le protocole natif OpenAI (`function_call_output`) ; ClaudeProvider
  // continue d'utiliser son propre protocole `tool_result`, inchangé.
  _normalizeToolResultMessage(message) {
    const content = message.content;
    const output = typeof content === 'string' ? content : JSON.stringify(content ?? '');
    return { type: 'function_call_output', call_id: message.toolCallId, output };
  }

  _normalizeMessages(messages = []) {
    const input = [];
    for (const message of messages) {
      if (!message || typeof message !== 'object') continue;
      if (message.role === 'tool') {
        if (!message.toolCallId) continue; // résultat d'outil sans identifiant : ne peut être relié à aucun appel, ignoré plutôt que d'envoyer une structure invalide
        input.push(this._normalizeToolResultMessage(message));
        continue;
      }
      const role = message.role === 'assistant' ? 'assistant' : (message.role === 'system' ? 'system' : 'user');
      const blocks = this._normalizeContent(message.content, message.mediaType);
      if (blocks.length === 0) continue; // message vide après normalisation : jamais envoyé comme item creux au fournisseur
      input.push({ role, content: blocks });
    }
    return input;
  }

  _appendImage(input, images) {
    if (!images || !images.base64) return input;
    const block = { type: 'input_image', image_url: `data:${images.mediaType || 'image/jpeg'};base64,${images.base64}` };
    const last = input[input.length - 1];
    if (last && last.role === 'user' && Array.isArray(last.content)) {
      last.content.push(block);
    } else {
      input.push({ role: 'user', content: [block] });
    }
    return input;
  }

  // ── Normalisation des outils (Mission 4) ───────────────────────────────
  // Format interne AZ IA {name, description, input_schema} (déjà utilisé par
  // ClaudeProvider/policyEngine) → format OpenAI Responses API, qui est PLAT
  // (pas imbriqué sous une clé `function` comme l'ancienne API Chat
  // Completions) : {type:'function', name, description, parameters, strict}.
  _toolsToOpenAI(tools = []) {
    return tools.map((tool) => ({
      type: 'function',
      name: tool.name,
      description: tool.description || '',
      parameters: tool.input_schema || { type: 'object', properties: {} },
      strict: false,
    }));
  }

  // Arguments JSON invalides : jamais exécutés (ce fichier n'exécute aucun
  // outil de toute façon), jamais silencieusement ignorés — remontés avec un
  // marqueur explicite `argumentsError` pour que l'appelant les rejette proprement.
  _parseToolCalls(output = []) {
    const calls = [];
    for (const item of output) {
      if (!item || item.type !== 'function_call') continue;
      let input = {};
      let argumentsError = null;
      try {
        input = item.arguments ? JSON.parse(item.arguments) : {};
      } catch (e) {
        input = {};
        argumentsError = `arguments JSON invalides: ${e.message}`;
      }
      calls.push({ id: item.call_id, name: item.name, input, ...(argumentsError ? { argumentsError } : {}) });
    }
    return calls;
  }

  _hasRefusal(response) {
    return (response.output || []).some((item) =>
      item && item.type === 'message' && Array.isArray(item.content) && item.content.some((b) => b && b.type === 'refusal')
    );
  }

  _extractText(response) {
    if (response.output_text) return response.output_text.trim();
    // Repli manuel si `output_text` (convenience getter du SDK) est absent —
    // ex. réponse composée uniquement d'un refus explicite du modèle.
    for (const item of response.output || []) {
      if (!item || item.type !== 'message') continue;
      for (const block of item.content || []) {
        if (block && block.type === 'refusal') return (block.refusal || '').trim();
      }
    }
    return '';
  }

  _finishReason(response, toolCalls) {
    if (toolCalls.length > 0) return 'tool_calls';
    if (this._hasRefusal(response)) return 'refusal';
    if (response.incomplete_details && response.incomplete_details.reason === 'max_output_tokens') return 'max_tokens';
    if (response.status === 'failed') return 'error';
    return 'stop';
  }

  async _createResponse({ systemPrompt, messages = [], images, tools = [], temperature, maxTokens, model } = {}) {
    const client = this._getClient();
    const selectedModel = model || process.env.OPENAI_MODEL || 'gpt-4o-mini';
    let input = this._normalizeMessages(messages);
    input = this._appendImage(input, images);
    if (input.length === 0) {
      // Jamais envoyer une requête sans le moindre item — un message
      // utilisateur vide explicite est préférable à un appel API invalide.
      input = [{ role: 'user', content: [{ type: 'input_text', text: '' }] }];
    }
    const body = {
      model: selectedModel,
      input,
      ...(systemPrompt ? { instructions: systemPrompt } : {}),
      ...(temperature !== undefined ? { temperature } : {}),
      max_output_tokens: maxTokens || Number(process.env.OPENAI_MAX_OUTPUT_TOKENS) || 1024,
      ...(tools.length > 0 ? { tools: this._toolsToOpenAI(tools) } : {}),
    };

    let response;
    try {
      response = await client.responses.create(body);
    } catch (err) {
      // Ne jamais journaliser la clé API — le SDK ne l'inclut de toute façon
      // jamais dans err.message, mais on reste explicite sur cette garantie.
      const wrapped = new Error(`${this.name} a échoué: ${err && err.message ? err.message : 'erreur inconnue'}`);
      wrapped.code = (err && (err.code || err.status)) || 'openai_error';
      throw wrapped;
    }

    const toolCalls = this._parseToolCalls(response.output);
    return {
      text: this._extractText(response),
      toolCalls,
      inputTokens: (response.usage && response.usage.input_tokens) || 0,
      outputTokens: (response.usage && response.usage.output_tokens) || 0,
      cachedInputTokens: (response.usage && response.usage.input_tokens_details && response.usage.input_tokens_details.cached_tokens) || 0,
      model: response.model || selectedModel,
      finishReason: this._finishReason(response, toolCalls),
      rawOutput: response.output,
    };
  }

  async generateText(prompt, opts = {}) {
    const result = await this._createResponse({
      systemPrompt: opts.system,
      messages: [{ role: 'user', content: prompt }],
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      model: opts.model,
    });
    return { text: result.text, model: result.model, inputTokens: result.inputTokens, outputTokens: result.outputTokens };
  }

  async generateChat(messages, opts = {}) {
    const result = await this._createResponse({
      systemPrompt: opts.system,
      messages,
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      model: opts.model,
    });
    return { text: result.text, model: result.model, inputTokens: result.inputTokens, outputTokens: result.outputTokens };
  }

  async generateVision(prompt, imageBase64, opts = {}) {
    const result = await this._createResponse({
      systemPrompt: opts.system,
      messages: [{ role: 'user', content: prompt }],
      images: { base64: imageBase64, mediaType: opts.mediaType },
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      model: opts.model,
    });
    return { text: result.text, model: result.model, inputTokens: result.inputTokens, outputTokens: result.outputTokens };
  }

  // Contrat canonique multi-fournisseurs (identique à ClaudeProvider.generateTurn).
  async generateTurn({ systemPrompt, messages = [], tools = [], images, temperature, maxTokens, model } = {}) {
    if (tools.length > 0 && !this.supportsTools()) {
      // Refus explicite et typé — jamais un silence sur les outils demandés
      // (Mission 4 : "Ne jamais silencieusement ignorer les tools").
      const error = new Error(`${this.name}: appel d'outils désactivé (AI_OPENAI_TOOL_CALLING_ENABLED=false)`);
      error.code = 'provider_tools_unsupported';
      throw error;
    }
    if (!this.isConfigured()) throw new ProviderNotConfiguredError(this.name);
    const result = await this._createResponse({ systemPrompt, messages, images, tools, temperature, maxTokens, model });
    return {
      text: result.text,
      toolCalls: result.toolCalls,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
      cachedInputTokens: result.cachedInputTokens,
      provider: this.name,
      model: result.model,
      finishReason: result.finishReason,
      // État de continuation natif OpenAI (tableau `output` brut) — n'a de
      // sens que si un futur appelant OpenAI-natif enchaîne un tour d'outil
      // sur ce même fournisseur ; jamais consommé par la boucle Claude
      // existante (azia/index.js), qui force Claude pour tout tour à outils.
      assistantMessage: result.rawOutput,
    };
  }
}

module.exports = OpenAIProvider;
