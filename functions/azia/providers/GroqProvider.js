'use strict';

const OpenAICompatibleProvider = require('./OpenAICompatibleProvider');

class GroqProvider extends OpenAICompatibleProvider {
  constructor() {
    super('groq', {
      apiKeyEnv: 'GROQ_API_KEY',
      host: 'api.groq.com',
      path: '/openai/v1/chat/completions',
      defaultModel: 'llama-3.3-70b-versatile',
      visionSupported: false,
    });
  }
}

module.exports = GroqProvider;
