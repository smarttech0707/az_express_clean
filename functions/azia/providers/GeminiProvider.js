'use strict';

const https = require('https');
const BaseProvider = require('./BaseProvider');
const { ProviderNotConfiguredError } = require('./errors');

// Gemini a un format de requête/réponse distinct du format "OpenAI-compatible"
// (contents/parts, pas messages/content ; clé API en query string, pas en
// header Authorization) — ne peut pas réutiliser OpenAICompatibleProvider.
class GeminiProvider extends BaseProvider {
  constructor() {
    super('gemini');
    this.defaultModel = 'gemini-2.0-flash';
  }

  isConfigured() {
    return !!process.env.GEMINI_API_KEY;
  }

  _post(model, body) {
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) return Promise.reject(new ProviderNotConfiguredError(this.name));
    const data = JSON.stringify(body);
    return new Promise((resolve, reject) => {
      const req = https.request({
        hostname: 'generativelanguage.googleapis.com',
        path: `/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${apiKey}`,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
      }, (res) => {
        let raw = '';
        res.on('data', (c) => { raw += c; });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            reject(new Error(`gemini HTTP ${res.statusCode}: ${raw.slice(0, 300)}`));
            return;
          }
          try {
            resolve(JSON.parse(raw));
          } catch (e) {
            reject(new Error(`gemini réponse JSON invalide: ${e.message}`));
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
    const contents = messages.map(m => ({
      role: m.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: m.content }],
    }));
    const body = {
      contents,
      ...(opts.system ? { systemInstruction: { parts: [{ text: opts.system }] } } : {}),
      generationConfig: {
        temperature: opts.temperature ?? 0.7,
        maxOutputTokens: opts.maxTokens || 1024,
      },
    };
    const json = await this._post(model, body);
    const text = (json.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('').trim();
    return {
      text, model,
      inputTokens: json.usageMetadata?.promptTokenCount || 0,
      outputTokens: json.usageMetadata?.candidatesTokenCount || 0,
    };
  }

  async generateVision(prompt, imageBase64, opts = {}) {
    const model = opts.model || this.defaultModel;
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
    const json = await this._post(model, body);
    const text = (json.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('').trim();
    return {
      text, model,
      inputTokens: json.usageMetadata?.promptTokenCount || 0,
      outputTokens: json.usageMetadata?.candidatesTokenCount || 0,
    };
  }
}

module.exports = GeminiProvider;
