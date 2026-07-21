'use strict';

const https = require('https');
const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');

// ═══════════════════════════════════════════════════════════════════════════
// Base partagée pour tous les fournisseurs exposant une API compatible avec
// le format "chat completions" d'OpenAI (OpenAI lui-même, DeepSeek, Mistral,
// Groq — chacun documente explicitement cette compatibilité). Évite de
// dupliquer 4 fois le même code d'appel HTTP/parsing de réponse.
// ═══════════════════════════════════════════════════════════════════════════
class OpenAICompatibleProvider extends BaseProvider {
  constructor(name, { apiKeyEnv, host, path = '/v1/chat/completions', defaultModel, visionSupported = false }) {
    super(name);
    this.apiKeyEnv = apiKeyEnv;
    this.host = host;
    this.path = path;
    this.defaultModel = defaultModel;
    this.visionSupported = visionSupported;
  }

  isConfigured() {
    return !!process.env[this.apiKeyEnv];
  }

  _post(body) {
    const apiKey = process.env[this.apiKeyEnv];
    if (!apiKey) return Promise.reject(new ProviderNotConfiguredError(this.name));
    const data = JSON.stringify(body);
    return new Promise((resolve, reject) => {
      const req = https.request({
        hostname: this.host,
        path: this.path,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`,
          'Content-Length': Buffer.byteLength(data),
        },
      }, (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            reject(new Error(`${this.name} HTTP ${res.statusCode}: ${raw.slice(0, 300)}`));
            return;
          }
          try {
            resolve(JSON.parse(raw));
          } catch (e) {
            reject(new Error(`${this.name} réponse JSON invalide: ${e.message}`));
          }
        });
      });
      req.on('error', reject);
      req.write(data);
      req.end();
    });
  }

  async generateText(prompt, opts = {}) {
    return this.generateChat([{ role: 'user', content: prompt }], opts);
  }

  async generateChat(messages, opts = {}) {
    const model = opts.model || this.defaultModel;
    const body = {
      model,
      messages: [
        ...(opts.system ? [{ role: 'system', content: opts.system }] : []),
        ...messages.map(m => ({ role: m.role, content: m.content })),
      ],
      temperature: opts.temperature ?? 0.7,
      max_tokens: opts.maxTokens || 1024,
    };
    const json = await this._post(body);
    const text = json.choices?.[0]?.message?.content?.trim() || '';
    return {
      text, model,
      inputTokens: json.usage?.prompt_tokens || 0,
      outputTokens: json.usage?.completion_tokens || 0,
    };
  }

  async generateVision(prompt, imageBase64, opts = {}) {
    if (!this.visionSupported) {
      throw new Error(`${this.name} ne supporte pas generateVision()`);
    }
    const model = opts.model || this.defaultModel;
    const body = {
      model,
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: prompt },
          { type: 'image_url', image_url: { url: `data:${opts.mediaType || 'image/jpeg'};base64,${imageBase64}` } },
        ],
      }],
      max_tokens: opts.maxTokens || 1024,
    };
    const json = await this._post(body);
    const text = json.choices?.[0]?.message?.content?.trim() || '';
    return {
      text, model,
      inputTokens: json.usage?.prompt_tokens || 0,
      outputTokens: json.usage?.completion_tokens || 0,
    };
  }
}

module.exports = OpenAICompatibleProvider;
