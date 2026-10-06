'use strict';

// ═══════════════════════════════════════════════════════════════════════════
// Contrat commun à tous les fournisseurs IA (Master Prompt 108).
//
// Chaque provider implémente :
//   - isConfigured() : bool — sa clé API est-elle présente dans functions/.env ?
//   - generateText(prompt, opts)               → { text, model, inputTokens, outputTokens }
//   - generateChat(messages, opts)              → { text, model, inputTokens, outputTokens }
//   - generateVision(prompt, imageBase64, opts) → { text, model, inputTokens, outputTokens }
//     (lève une erreur explicite si le provider ne supporte pas la vision,
//      plutôt que d'échouer silencieusement)
//
// `messages` : [{ role: 'user'|'assistant', content: string }]
// `opts`     : { model?, temperature?, maxTokens?, system?, mediaType? }
//
// Canonical history requires an explicit adapter capability.
class BaseProvider {
  constructor(name) {
    if (new.target === BaseProvider) {
      throw new Error('BaseProvider est abstraite, utiliser une sous-classe');
    }
    this.name = name;
  }

  isConfigured() {
    throw new Error(`${this.name}.isConfigured() non implémenté`);
  }

  async generateText(_prompt, _opts) {
    throw new Error(`${this.name}.generateText() non implémenté`);
  }

  async generateChat(_messages, _opts) {
    throw new Error(`${this.name}.generateChat() non implémenté`);
  }

  async generateVision(_prompt, _imageBase64, _opts) {
    throw new Error(`${this.name} ne supporte pas generateVision()`);
  }

  supportsTools() {
    return false;
  }

  supportsCanonicalHistory() {
    return false;
  }

  // Canonical cross-provider contract. Providers that do not expose native
  // tool calling still support safe, text-only turns through this default.
  async generateTurn({ systemPrompt, messages, tools = [], images, temperature, maxTokens, model }) {
    if (tools.length > 0) {
      const error = new Error(`${this.name} ne supporte pas les appels d'outils AZ IA`);
      error.code = 'provider_tools_unsupported';
      throw error;
    }
    const opts = { system: systemPrompt, temperature, maxTokens, model };
    const result = images?.base64
      ? await this.generateVision(messages.at(-1)?.content || '', images.base64, { ...opts, mediaType: images.mediaType })
      : await this.generateChat(messages, opts);
    return { ...result, toolCalls: [], finishReason: 'stop' };
  }
}

module.exports = BaseProvider;
