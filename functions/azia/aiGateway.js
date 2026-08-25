'use strict';

// Single provider-independent entry point for every AZ IA turn. Flutter keeps
// calling azIaChat; only this server-side boundary knows about providers.
function createAiGateway({ providerService, policyEngine }) {
  async function generateTurn(turn, context = {}) {
    const config = await providerService.getConfig();
    const tools = (turn.tools || []).filter((tool) => policyEngine.canExecute(tool.name, config));
    const result = await providerService.generateTurn({ ...turn, tools }, {
      uid: context.uid,
      conversationId: context.conversationId,
      role: context.role,
      // A tool loop is stateful. It must not be served from a text cache or
      // counted once per internal model turn; azIaChat records aggregate usage.
      cache: false,
      skipQuota: true,
      recordUsage: false,
      preserveProviderDefaults: true,
      forceProvider: context.forceProvider,
    });
    return {
      text: result.text || '',
      toolCalls: Array.isArray(result.toolCalls) ? result.toolCalls : [],
      usage: { inputTokens: result.inputTokens || 0, outputTokens: result.outputTokens || 0 },
      provider: result.provider,
      model: result.model,
      finishReason: result.finishReason || 'stop',
      // Internal continuation state, never returned to Flutter.
      assistantMessage: result.assistantMessage,
    };
  }

  return { generateTurn };
}

module.exports = { createAiGateway };
