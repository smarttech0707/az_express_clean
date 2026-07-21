'use strict';

const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');
// Réutilise le client Anthropic déjà initialisé/partagé par la boucle
// d'appel d'outils existante (azia/index.js) — une seule source de vérité
// pour la clé API et le client SDK, jamais dupliquée.
const { getClient, MODEL } = require('../claudeClient');

class ClaudeProvider extends BaseProvider {
  constructor() {
    super('claude');
  }

  isConfigured() {
    return !!process.env.ANTHROPIC_API_KEY;
  }

  async generateText(prompt, opts = {}) {
    return this.generateChat([{ role: 'user', content: prompt }], opts);
  }

  async generateChat(messages, opts = {}) {
    if (!this.isConfigured()) throw new ProviderNotConfiguredError(this.name);
    const client = getClient();
    const model = opts.model || MODEL;
    const response = await client.messages.create({
      model,
      max_tokens: opts.maxTokens || 1024,
      temperature: opts.temperature ?? 0.7,
      ...(opts.system ? { system: opts.system } : {}),
      messages: messages.map(m => ({
        role: m.role === 'assistant' ? 'assistant' : 'user',
        content: m.content,
      })),
    });
    const text = (response.content || [])
      .filter(b => b.type === 'text')
      .map(b => b.text)
      .join('\n')
      .trim();
    return {
      text, model,
      inputTokens: response.usage?.input_tokens || 0,
      outputTokens: response.usage?.output_tokens || 0,
    };
  }

  async generateVision(prompt, imageBase64, opts = {}) {
    if (!this.isConfigured()) throw new ProviderNotConfiguredError(this.name);
    const client = getClient();
    const model = opts.model || MODEL;
    const response = await client.messages.create({
      model,
      max_tokens: opts.maxTokens || 1024,
      messages: [{
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: opts.mediaType || 'image/jpeg', data: imageBase64 } },
          { type: 'text', text: prompt },
        ],
      }],
    });
    const text = (response.content || [])
      .filter(b => b.type === 'text')
      .map(b => b.text)
      .join('\n')
      .trim();
    return {
      text, model,
      inputTokens: response.usage?.input_tokens || 0,
      outputTokens: response.usage?.output_tokens || 0,
    };
  }
}

module.exports = ClaudeProvider;
