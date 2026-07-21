'use strict';

const OpenAICompatibleProvider = require('./OpenAICompatibleProvider');

class MistralProvider extends OpenAICompatibleProvider {
  constructor() {
    super('mistral', {
      apiKeyEnv: 'MISTRAL_API_KEY',
      host: 'api.mistral.ai',
      defaultModel: 'mistral-large-latest',
      visionSupported: false,
    });
  }
}

module.exports = MistralProvider;
