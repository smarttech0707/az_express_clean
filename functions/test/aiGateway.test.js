'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildRoute } = require('../azia/aiRouter');
const { createPolicyEngine } = require('../azia/policyEngine');
const { createAiGateway } = require('../azia/aiGateway');

const tools = [
  { name: 'read_wallet', description: 'Read', input_schema: { type: 'object' } },
  { name: 'create_pending_payment', description: 'Create', input_schema: { type: 'object' }, confirmHandler: async () => {} },
];

test('AI router keeps stateful tool turns on the configured tool provider', () => {
  const route = buildRoute({
    config: { defaultProvider: 'gemini', toolProvider: 'claude', allowedProviders: ['claude', 'gemini'] },
    hasTools: true,
  });
  assert.equal(route.provider, 'claude');
  assert.equal(route.reason, 'tools');
});

test('Policy Engine only exposes configured tools and does not infer financial rules', () => {
  const policy = createPolicyEngine({ tools });
  const schemas = policy.getToolSchemas({ allowedTools: ['read_wallet'] });
  assert.deepEqual(schemas.map((tool) => tool.name), ['read_wallet']);
  assert.equal(policy.canExecute('create_pending_payment', { allowedTools: ['read_wallet'] }), false);
  assert.equal(policy.requiresConfirmation('create_pending_payment'), true);
});

test('Gateway normalizes a provider turn without exposing provider protocol to callers', async () => {
  const policy = createPolicyEngine({ tools });
  let received;
  const gateway = createAiGateway({
    policyEngine: policy,
    providerService: {
      getConfig: async () => ({ allowedTools: ['read_wallet'] }),
      generateTurn: async (turn, options) => {
        received = { turn, options };
        return {
          text: 'solde disponible', toolCalls: [{ id: 'tool-1', name: 'read_wallet', input: {} }],
          inputTokens: 11, outputTokens: 7, provider: 'claude', model: 'test-model', finishReason: 'tool_use',
          assistantMessage: [{ type: 'tool_use', id: 'tool-1', name: 'read_wallet', input: {} }],
        };
      },
    },
  });

  const result = await gateway.generateTurn({
    systemPrompt: 'system', messages: [{ role: 'user', content: 'mon solde' }], tools,
  }, { uid: 'u1', conversationId: 'c1' });

  assert.deepEqual(received.turn.tools.map((tool) => tool.name), ['read_wallet']);
  assert.equal(received.options.recordUsage, false);
  assert.deepEqual(result.usage, { inputTokens: 11, outputTokens: 7 });
  assert.equal(result.provider, 'claude');
});
