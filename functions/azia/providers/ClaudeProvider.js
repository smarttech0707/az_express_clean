'use strict';

const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');
// Réutilise le client Anthropic déjà initialisé/partagé par la boucle
// d'appel d'outils existante (azia/index.js) — une seule source de vérité
// pour la clé API et le client SDK, jamais dupliquée.
const { getClient, MODEL } = require('../claudeClient');
const { toClaudeMessages, fromClaudeContent } = require('../canonicalHistory');

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

  supportsTools() {
    return true;
  }

  supportsCanonicalHistory() { return true; }

  _getClient() { return getClient(); }

  async generateTurn({ systemPrompt, messages, tools = [], temperature, maxTokens, model, canonicalHistory = false }) {
    if (!this.isConfigured()) throw new ProviderNotConfiguredError(this.name);
    const selectedModel = model || process.env.CLAUDE_MODEL || MODEL;
    // Keep the existing static prompt/tool cache points in the native adapter,
    // never in the provider-independent conversation loop.
    const nativeSystem = canonicalHistory && Array.isArray(systemPrompt)
      ? systemPrompt.map((block, index) => ({ type: 'text', text: block.text,
        ...(index === 0 ? { cache_control: { type: 'ephemeral' } } : {}) })) : systemPrompt;
    const nativeTools = canonicalHistory ? tools.map((tool, index) => ({ ...tool,
      ...(index === tools.length - 1 ? { cache_control: { type: 'ephemeral' } } : {}) })) : tools;
    const response = await this._getClient().messages.create({
      model: selectedModel,
      max_tokens: maxTokens || 1024,
      ...(temperature !== undefined ? { temperature } : {}),
      ...(nativeSystem ? { system: nativeSystem } : {}),
      messages: canonicalHistory ? toClaudeMessages(messages) : messages,
      ...(nativeTools.length > 0 ? { tools: nativeTools } : {}),
    });
    const content = response.content || [];
    return {
      text: content.filter((block) => block.type === 'text').map((block) => block.text).join('\n').trim(),
      toolCalls: content.filter((block) => block.type === 'tool_use').map((block) => ({
        id: block.id,
        name: block.name,
        input: block.input || {},
      })),
      inputTokens: response.usage?.input_tokens || 0,
      outputTokens: response.usage?.output_tokens || 0,
      provider: this.name,
      model: selectedModel,
      finishReason: response.stop_reason || 'stop',
      assistantMessage: fromClaudeContent(content),
    };
  }
}

module.exports = ClaudeProvider;
