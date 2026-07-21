'use strict';

const OpenAICompatibleProvider = require('./OpenAICompatibleProvider');

class DeepSeekProvider extends OpenAICompatibleProvider {
  constructor() {
    super('deepseek', {
      apiKeyEnv: 'DEEPSEEK_API_KEY',
      host: 'api.deepseek.com',
      defaultModel: 'deepseek-chat',
      visionSupported: false,
    });
  }
}

module.exports = DeepSeekProvider;
