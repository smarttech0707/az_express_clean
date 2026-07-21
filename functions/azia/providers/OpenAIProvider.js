'use strict';

const OpenAICompatibleProvider = require('./OpenAICompatibleProvider');

class OpenAIProvider extends OpenAICompatibleProvider {
  constructor() {
    super('openai', {
      apiKeyEnv: 'OPENAI_API_KEY',
      host: 'api.openai.com',
      defaultModel: 'gpt-4o-mini',
      visionSupported: true,
    });
  }
}

module.exports = OpenAIProvider;
