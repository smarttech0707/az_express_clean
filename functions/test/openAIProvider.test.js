'use strict';

// Tests unitaires OpenAIProvider (Mission 11) — le SDK OpenAI est entièrement
// mocké via l'injection directe de `provider._client` : aucun appel réseau
// réel n'est jamais effectué par cette suite.

const test = require('node:test');
const assert = require('node:assert/strict');
const OpenAIProvider = require('../azia/providers/OpenAIProvider');
const { ProviderNotConfiguredError } = require('../azia/providers/errors');

const SECRET_MARKER = 'sk-test-CE-SECRET-NE-DOIT-JAMAIS-APPARAITRE';

function makeProvider(createImpl) {
  process.env.OPENAI_API_KEY = SECRET_MARKER;
  const provider = new OpenAIProvider();
  const calls = [];
  provider._client = {
    responses: {
      create: async (body) => {
        calls.push(body);
        return createImpl(body);
      },
    },
  };
  provider.__calls = calls;
  return provider;
}

function withEnv(key, value, fn) {
  const original = process.env[key];
  if (value === undefined) delete process.env[key]; else process.env[key] = value;
  try {
    return fn();
  } finally {
    if (original === undefined) delete process.env[key]; else process.env[key] = original;
  }
}

test('1. réponse texte normale — text/model/tokens correctement extraits', async () => {
  const provider = makeProvider(() => ({
    output_text: 'Bonjour, comment puis-je vous aider ?',
    output: [],
    usage: { input_tokens: 12, output_tokens: 8, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: {} },
    model: 'gpt-4o-mini',
    status: 'completed',
  }));
  const result = await provider.generateChat([{ role: 'user', content: 'Bonjour' }]);
  assert.equal(result.text, 'Bonjour, comment puis-je vous aider ?');
  assert.equal(result.model, 'gpt-4o-mini');
  assert.equal(result.inputTokens, 12);
  assert.equal(result.outputTokens, 8);
});

test('2. historique multi-tours — chaque message normalisé dans le bon ordre/rôle', async () => {
  const provider = makeProvider(() => ({ output_text: 'ok', output: [], usage: null, model: 'gpt-4o-mini' }));
  await provider.generateTurn({
    messages: [
      { role: 'user', content: 'Bonjour' },
      { role: 'assistant', content: 'Salut ! Comment puis-je aider ?' },
      { role: 'user', content: 'Quel est mon solde ?' },
    ],
  });
  const body = provider.__calls[0];
  assert.equal(body.input.length, 3);
  assert.deepEqual(body.input.map((m) => m.role), ['user', 'assistant', 'user']);
  assert.deepEqual(body.input[2].content, [{ type: 'input_text', text: 'Quel est mon solde ?' }]);
});

test('3. system prompt transmis via `instructions`, jamais comme message', async () => {
  const provider = makeProvider(() => ({ output_text: 'ok', output: [], usage: null, model: 'gpt-4o-mini' }));
  await provider.generateTurn({ systemPrompt: 'Tu es AZ IA.', messages: [{ role: 'user', content: 'Salut' }] });
  const body = provider.__calls[0];
  assert.equal(body.instructions, 'Tu es AZ IA.');
  assert.ok(!body.input.some((m) => m.role === 'system' && JSON.stringify(m.content).includes('Tu es AZ IA')));
});

test('4. message avec image — bloc input_image correctement attaché', async () => {
  const provider = makeProvider(() => ({ output_text: 'Je vois une image.', output: [], usage: null, model: 'gpt-4o-mini' }));
  const result = await provider.generateTurn({
    messages: [{ role: 'user', content: 'Décris cette image' }],
    images: { base64: 'QkFTRTY0', mediaType: 'image/png' },
  });
  const body = provider.__calls[0];
  const lastContent = body.input[body.input.length - 1].content;
  assert.ok(lastContent.some((b) => b.type === 'input_image' && b.image_url === 'data:image/png;base64,QkFTRTY0'));
  assert.equal(result.text, 'Je vois une image.');
});

test('5. réponse avec un appel d\'outil — normalisé en {id, name, input}', async () => {
  const provider = makeProvider(() => ({
    output_text: '',
    output: [{ type: 'function_call', call_id: 'call_1', name: 'get_wallet_balance', arguments: '{"uid":"u1"}' }],
    usage: { input_tokens: 20, output_tokens: 10 },
    model: 'gpt-4o-mini',
  }));
  const result = await withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', 'true', () => provider.generateTurn({
    messages: [{ role: 'user', content: 'Mon solde ?' }],
    tools: [{ name: 'get_wallet_balance', description: 'Lit le solde', input_schema: { type: 'object' } }],
  }));
  assert.equal(result.toolCalls.length, 1);
  assert.deepEqual(result.toolCalls[0], { id: 'call_1', name: 'get_wallet_balance', input: { uid: 'u1' } });
  assert.equal(result.finishReason, 'tool_calls');
});

test('6. plusieurs appels d\'outils dans la même réponse — tous normalisés, dans l\'ordre', async () => {
  const provider = makeProvider(() => ({
    output_text: '',
    output: [
      { type: 'function_call', call_id: 'call_1', name: 'get_wallet_balance', arguments: '{}' },
      { type: 'function_call', call_id: 'call_2', name: 'track_order', arguments: '{"orderId":"o1"}' },
    ],
    usage: null,
    model: 'gpt-4o-mini',
  }));
  const result = await withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', 'true', () => provider.generateTurn({
    messages: [{ role: 'user', content: 'Solde et commande' }],
    tools: [
      { name: 'get_wallet_balance', description: 'x', input_schema: {} },
      { name: 'track_order', description: 'x', input_schema: {} },
    ],
  }));
  assert.equal(result.toolCalls.length, 2);
  assert.deepEqual(result.toolCalls.map((c) => c.name), ['get_wallet_balance', 'track_order']);
  assert.deepEqual(result.toolCalls[1].input, { orderId: 'o1' });
});

test('7. arguments JSON valides — correctement parsés en objet', async () => {
  const provider = makeProvider(() => ({
    output_text: '', output: [{ type: 'function_call', call_id: 'c1', name: 'x', arguments: '{"a":1,"b":"deux"}' }],
    usage: null, model: 'gpt-4o-mini',
  }));
  const result = await withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', 'true', () => provider.generateTurn({
    messages: [{ role: 'user', content: 'x' }], tools: [{ name: 'x', description: 'x', input_schema: {} }],
  }));
  assert.deepEqual(result.toolCalls[0].input, { a: 1, b: 'deux' });
  assert.equal(result.toolCalls[0].argumentsError, undefined);
});

test('8. arguments JSON invalides — jamais exécutés, rejetés proprement (pas de crash)', async () => {
  const provider = makeProvider(() => ({
    output_text: '', output: [{ type: 'function_call', call_id: 'c1', name: 'x', arguments: '{invalide' }],
    usage: null, model: 'gpt-4o-mini',
  }));
  const result = await withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', 'true', () => provider.generateTurn({
    messages: [{ role: 'user', content: 'x' }], tools: [{ name: 'x', description: 'x', input_schema: {} }],
  }));
  assert.equal(result.toolCalls.length, 1);
  assert.deepEqual(result.toolCalls[0].input, {});
  assert.ok(typeof result.toolCalls[0].argumentsError === 'string' && result.toolCalls[0].argumentsError.includes('JSON invalides'));
});

test('9. usage de tokens normalisé, y compris les tokens en cache', async () => {
  const provider = makeProvider(() => ({
    output_text: 'ok', output: [],
    usage: { input_tokens: 100, output_tokens: 40, input_tokens_details: { cached_tokens: 30 } },
    model: 'gpt-4o-mini',
  }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(result.inputTokens, 100);
  assert.equal(result.outputTokens, 40);
  assert.equal(result.cachedInputTokens, 30);
});

test('10. usage manquant — retombe sur 0 partout, jamais undefined ni crash', async () => {
  const provider = makeProvider(() => ({ output_text: 'ok', output: [], model: 'gpt-4o-mini' })); // pas de champ usage
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(result.inputTokens, 0);
  assert.equal(result.outputTokens, 0);
  assert.equal(result.cachedInputTokens, 0);
});

test('11. refus du modèle — texte de refus exposé, finishReason=refusal', async () => {
  const provider = makeProvider(() => ({
    output_text: '',
    output: [{ type: 'message', role: 'assistant', content: [{ type: 'refusal', refusal: 'Je ne peux pas répondre à cela.' }] }],
    model: 'gpt-4o-mini',
  }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(result.text, 'Je ne peux pas répondre à cela.');
  assert.equal(result.finishReason, 'refusal');
});

test('12. timeout réseau — rejette proprement, jamais un throw non capturé', async () => {
  const provider = makeProvider(() => {
    const e = new Error('Request timed out');
    e.code = 'ETIMEDOUT';
    throw e;
  });
  await assert.rejects(
    () => provider.generateChat([{ role: 'user', content: 'x' }]),
    (err) => err.message.includes('openai a échoué') && err.code === 'ETIMEDOUT',
  );
});

test('13. erreur API (ex. 400 Bad Request) — normalisée, code conservé', async () => {
  const provider = makeProvider(() => {
    const e = new Error('Invalid request: model not found');
    e.status = 400;
    throw e;
  });
  await assert.rejects(
    () => provider.generateChat([{ role: 'user', content: 'x' }]),
    (err) => err.message.includes('Invalid request') && err.code === 400,
  );
});

test('14. clé API absente — ProviderNotConfiguredError, jamais d\'appel réseau', async () => {
  delete process.env.OPENAI_API_KEY;
  const provider = new OpenAIProvider();
  await assert.rejects(
    () => provider.generateChat([{ role: 'user', content: 'x' }]),
    (err) => err instanceof ProviderNotConfiguredError && err.code === 'provider_not_configured',
  );
});

test('15. réponse sans texte ni refus — text vide, pas de crash, finishReason=stop', async () => {
  const provider = makeProvider(() => ({
    output_text: '', output: [{ type: 'message', role: 'assistant', content: [] }], model: 'gpt-4o-mini',
  }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(result.text, '');
  assert.equal(result.finishReason, 'stop');
});

test('16. modèle explicitement configuré — transmis au SDK et reflété dans le résultat', async () => {
  const provider = makeProvider((body) => ({ output_text: 'ok', output: [], model: body.model }));
  const result = await provider.generateChat([{ role: 'user', content: 'x' }], { model: 'gpt-4o' });
  assert.equal(provider.__calls[0].model, 'gpt-4o');
  assert.equal(result.model, 'gpt-4o');
});

test('16b. modèle par défaut — OPENAI_MODEL puis repli gpt-4o-mini', async () => {
  const provider = makeProvider((body) => ({ output_text: 'ok', output: [], model: body.model }));
  await withEnv('OPENAI_MODEL', undefined, async () => {
    await provider.generateChat([{ role: 'user', content: 'x' }]);
    assert.equal(provider.__calls[0].model, 'gpt-4o-mini');
  });
});

test('17. aucun secret dans les messages d\'erreur (clé API jamais journalisée)', async () => {
  const provider = makeProvider(() => { throw new Error('panne réseau simulée'); });
  await assert.rejects(
    () => provider.generateChat([{ role: 'user', content: 'x' }]),
    (err) => !err.message.includes(SECRET_MARKER) && !JSON.stringify(err).includes(SECRET_MARKER),
  );
});

test('18. generateTurn() respecte strictement le contrat de retour canonique', async () => {
  const provider = makeProvider(() => ({
    output_text: 'réponse', output: [], usage: { input_tokens: 5, output_tokens: 3 }, model: 'gpt-4o-mini', status: 'completed',
  }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(typeof result.text, 'string');
  assert.ok(Array.isArray(result.toolCalls));
  assert.equal(typeof result.inputTokens, 'number');
  assert.equal(typeof result.outputTokens, 'number');
  assert.equal(typeof result.cachedInputTokens, 'number');
  assert.equal(result.provider, 'openai');
  assert.equal(typeof result.model, 'string');
  assert.equal(typeof result.finishReason, 'string');
  assert.ok('assistantMessage' in result);
});

// ── Tests complémentaires (garde du flag, historique vide, Unicode/Nouchi) ──

test('19. tool calling désactivé par défaut — refus explicite, jamais un appel silencieux', async () => {
  const provider = makeProvider(() => ({ output_text: 'ne devrait jamais être appelé', output: [] }));
  await withEnv('AI_OPENAI_TOOL_CALLING_ENABLED', undefined, async () => {
    await assert.rejects(
      () => provider.generateTurn({
        messages: [{ role: 'user', content: 'x' }],
        tools: [{ name: 'create_pending_payment', description: 'x', input_schema: {} }],
      }),
      (err) => err.code === 'provider_tools_unsupported',
    );
    assert.equal(provider.__calls.length, 0, 'le SDK ne doit jamais être appelé quand le flag est désactivé');
  });
});

test('20. messages vides — jamais un item creux envoyé au fournisseur', async () => {
  const provider = makeProvider(() => ({ output_text: 'ok', output: [] }));
  await provider.generateTurn({ messages: [] });
  const body = provider.__calls[0];
  assert.equal(body.input.length, 1);
  assert.deepEqual(body.input[0].content, [{ type: 'input_text', text: '' }]);
});

test('21. Unicode / français accentué / Nouchi — transmis sans altération', async () => {
  const texte = 'Wôlô wôlô, y\'a foto là-bas 🚀 — ça va bien même si c\'est chè !';
  const provider = makeProvider(() => ({ output_text: texte, output: [] }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: texte }] });
  assert.equal(provider.__calls[0].input[0].content[0].text, texte);
  assert.equal(result.text, texte);
});

test('22. réponse texte très longue — jamais tronquée ni source de crash', async () => {
  const longText = 'A'.repeat(50000);
  const provider = makeProvider(() => ({ output_text: longText, output: [] }));
  const result = await provider.generateTurn({ messages: [{ role: 'user', content: 'x' }] });
  assert.equal(result.text.length, 50000);
});

test('23. résultat d\'outil (contrat agnostique role:tool) — converti en function_call_output', async () => {
  const provider = makeProvider(() => ({ output_text: 'ok', output: [] }));
  await provider.generateTurn({
    messages: [
      { role: 'user', content: 'Solde ?' },
      { role: 'tool', toolCallId: 'call_1', name: 'get_wallet_balance', content: { balance: 500 } },
    ],
  });
  const body = provider.__calls[0];
  const toolResultItem = body.input.find((i) => i.type === 'function_call_output');
  assert.ok(toolResultItem, 'le message role:tool doit être converti en function_call_output');
  assert.equal(toolResultItem.call_id, 'call_1');
  assert.equal(toolResultItem.output, JSON.stringify({ balance: 500 }));
});
