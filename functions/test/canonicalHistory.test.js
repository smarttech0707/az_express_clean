'use strict';

/**
 * Historique canonique AZ IA — conversions indépendantes du fournisseur.
 * Aucun appel réseau : pure transformation de structures.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  textBlock, imageBlock, toolCallBlock, toolResultBlock,
  userMessage, assistantMessage,
  toClaudeMessages, fromClaudeContent,
  toGeminiContents, toGeminiToolDeclarations, fromGeminiCandidate,
  sanitizeJsonSchema,
} = require('../azia/canonicalHistory');

// Outils AZ IA réels (format `input_schema`, tel que défini dans tools/).
const REAL_TOOLS = [
  {
    name: 'get_wallet_balance',
    description: 'Consulte le solde actuel du wallet AZ Express du client.',
    input_schema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'initiate_wallet_recharge',
    description: 'Prépare une recharge du wallet via Mobile Money.',
    input_schema: {
      type: 'object',
      properties: {
        amount: { type: 'number', description: 'Montant en FCFA (100 à 500 000).' },
        operator: { type: 'string', enum: ['mtn', 'orange', 'moov', 'wave'] },
        phone: { type: 'string', description: 'Numéro payeur.' },
      },
      required: ['amount', 'operator', 'phone'],
    },
  },
  {
    name: 'create_delivery_order',
    description: 'Crée une commande de livraison.',
    input_schema: {
      type: 'object',
      properties: {
        deliveryLat: { type: 'number' },
        items: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' } } } },
      },
      required: ['deliveryLat'],
    },
  },
];

// ── Claude ──────────────────────────────────────────────────────────────────
test('canonique → Claude : texte, appel et résultat d\'outil', () => {
  const messages = [
    userMessage([textBlock('Quel est mon solde ?')]),
    assistantMessage([toolCallBlock({ id: 'tu_1', name: 'get_wallet_balance', input: {} })]),
    userMessage([toolResultBlock({
      toolCallId: 'tu_1', name: 'get_wallet_balance', content: { balance: 1500 },
    })]),
  ];
  const claude = toClaudeMessages(messages);
  assert.equal(claude[1].content[0].type, 'tool_use');
  assert.equal(claude[1].content[0].id, 'tu_1');
  assert.equal(claude[2].content[0].type, 'tool_result');
  assert.equal(claude[2].content[0].tool_use_id, 'tu_1');
  assert.equal(claude[2].content[0].content, '{"balance":1500}');
  assert.equal(claude[2].content[0].is_error, false);
});

test('canonique → Claude : image en base64', () => {
  const claude = toClaudeMessages([userMessage([imageBlock({ data: 'BASE64', mediaType: 'image/png' })])]);
  assert.deepEqual(claude[0].content[0], {
    type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'BASE64' },
  });
});

test('réponse Claude → canonique (aller-retour sans perte)', () => {
  const blocks = fromClaudeContent([
    { type: 'text', text: 'Je vérifie.' },
    { type: 'tool_use', id: 'tu_9', name: 'get_wallet_balance', input: { limit: 5 } },
  ]);
  assert.equal(blocks[0].type, 'text');
  assert.equal(blocks[1].type, 'tool_call');
  assert.equal(blocks[1].id, 'tu_9');
  assert.deepEqual(blocks[1].input, { limit: 5 });
  // Reconverti vers Claude, on retrouve la forme d'origine.
  const back = toClaudeMessages([assistantMessage(blocks)])[0].content;
  assert.equal(back[1].type, 'tool_use');
  assert.equal(back[1].id, 'tu_9');
});

// ── Gemini ──────────────────────────────────────────────────────────────────
test('canonique → Gemini : rôles et parties', () => {
  const contents = toGeminiContents([
    userMessage([textBlock('Bonjour')]),
    assistantMessage([textBlock('Bonjour !')]),
  ]);
  assert.equal(contents[0].role, 'user');
  assert.equal(contents[1].role, 'model', 'Gemini utilise "model", pas "assistant"');
  assert.deepEqual(contents[0].parts[0], { text: 'Bonjour' });
});

test('canonique → Gemini : functionCall et functionResponse appariés par nom', () => {
  const contents = toGeminiContents([
    assistantMessage([toolCallBlock({ id: 'gemini-0-0-get_wallet_balance', name: 'get_wallet_balance', input: {} })]),
    userMessage([toolResultBlock({
      toolCallId: 'gemini-0-0-get_wallet_balance', name: 'get_wallet_balance', content: { balance: 1500 },
    })]),
  ]);
  assert.deepEqual(contents[0].parts[0], { functionCall: { name: 'get_wallet_balance', args: {} } });
  assert.deepEqual(contents[1].parts[0], {
    functionResponse: { name: 'get_wallet_balance', response: { balance: 1500 } },
  });
  // L'identifiant canonique n'est jamais transmis à Gemini (il ne le gère pas).
  assert.ok(!JSON.stringify(contents).includes('gemini-0-0-'));
});

test('canonique → Gemini : un résultat en erreur est signalé SANS perdre son message', () => {
  const contents = toGeminiContents([userMessage([toolResultBlock({
    toolCallId: 'x', name: 'create_delivery_order', content: { error: 'solde insuffisant' }, isError: true,
  })])]);
  const response = contents[0].parts[0].functionResponse.response;
  assert.equal(response.isError, true, 'l\'échec doit rester signalé');
  assert.equal(response.error, 'solde insuffisant', 'le message métier ne doit pas être écrasé');
});

test('canonique → Gemini : un résultat non-objet est encapsulé', () => {
  const contents = toGeminiContents([userMessage([toolResultBlock({
    toolCallId: 'x', name: 't', content: 'texte brut',
  })])]);
  assert.deepEqual(contents[0].parts[0].functionResponse.response, { result: 'texte brut' });
});

test('canonique → Gemini : image', () => {
  const contents = toGeminiContents([userMessage([imageBlock({ data: 'B64', mediaType: 'image/webp' })])]);
  assert.deepEqual(contents[0].parts[0], { inline_data: { mime_type: 'image/webp', data: 'B64' } });
});

// ── Déclarations d'outils ───────────────────────────────────────────────────
test('outils AZ IA → déclarations Gemini : nom, description et schéma préservés', () => {
  const [declaration] = toGeminiToolDeclarations(REAL_TOOLS);
  assert.equal(declaration.functionDeclarations.length, 3);
  const recharge = declaration.functionDeclarations.find((d) => d.name === 'initiate_wallet_recharge');
  assert.equal(recharge.description, 'Prépare une recharge du wallet via Mobile Money.');
  assert.deepEqual(recharge.parameters.required, ['amount', 'operator', 'phone']);
  assert.deepEqual(recharge.parameters.properties.operator.enum, ['mtn', 'orange', 'moov', 'wave']);
  assert.equal(recharge.parameters.properties.amount.type, 'number');
});

test('déclarations Gemini : schémas imbriqués préservés', () => {
  const [declaration] = toGeminiToolDeclarations(REAL_TOOLS);
  const order = declaration.functionDeclarations.find((d) => d.name === 'create_delivery_order');
  assert.equal(order.parameters.properties.items.items.properties.name.type, 'string');
});

test('déclarations Gemini : clés non supportées retirées, sémantique intacte', () => {
  const cleaned = sanitizeJsonSchema({
    $schema: 'http://json-schema.org/draft-07/schema#',
    type: 'object',
    additionalProperties: false,
    properties: { a: { type: 'string', description: 'gardé' } },
    required: ['a'],
  });
  assert.ok(!('$schema' in cleaned));
  assert.ok(!('additionalProperties' in cleaned));
  assert.deepEqual(cleaned.required, ['a']);
  assert.equal(cleaned.properties.a.description, 'gardé');
});

test('aucun outil → aucune déclaration', () => {
  assert.deepEqual(toGeminiToolDeclarations([]), []);
  assert.deepEqual(toGeminiToolDeclarations(undefined), []);
});

// ── Réponse Gemini → canonique ──────────────────────────────────────────────
test('réponse Gemini texte → canonique', () => {
  const parsed = fromGeminiCandidate({
    candidates: [{ content: { parts: [{ text: 'Votre solde est de 1500 FCFA.' }] }, finishReason: 'STOP' }],
  });
  assert.equal(parsed.text, 'Votre solde est de 1500 FCFA.');
  assert.equal(parsed.toolCalls.length, 0);
});

test('réponse Gemini avec appel de fonction → canonique, identifiant synthétisé', () => {
  const parsed = fromGeminiCandidate({
    candidates: [{ content: { parts: [{ functionCall: { name: 'get_wallet_balance', args: {} } }] } }],
  }, { turnIndex: 2 });
  assert.equal(parsed.toolCalls.length, 1);
  assert.equal(parsed.toolCalls[0].name, 'get_wallet_balance');
  assert.equal(parsed.toolCalls[0].id, 'gemini-2-0-get_wallet_balance');
  assert.equal(parsed.blocks[0].type, 'tool_call');
});

test('plusieurs appels : ordre préservé, identifiants distincts', () => {
  const parsed = fromGeminiCandidate({
    candidates: [{ content: { parts: [
      { functionCall: { name: 'a', args: { x: 1 } } },
      { functionCall: { name: 'b', args: {} } },
    ] } }],
  });
  assert.deepEqual(parsed.toolCalls.map((c) => c.name), ['a', 'b']);
  assert.notEqual(parsed.toolCalls[0].id, parsed.toolCalls[1].id);
  assert.deepEqual(parsed.toolCalls[0].input, { x: 1 });
});

test('appel de fonction malformé ignoré, jamais interprété', () => {
  const parsed = fromGeminiCandidate({
    candidates: [{ content: { parts: [
      { functionCall: { args: { x: 1 } } },          // nom absent
      { functionCall: { name: 'ok', args: 'pas un objet' } },
    ] } }],
  });
  assert.equal(parsed.toolCalls.length, 1);
  assert.equal(parsed.toolCalls[0].name, 'ok');
  assert.deepEqual(parsed.toolCalls[0].input, {}, 'arguments invalides → objet vide, jamais propagés');
});

test('candidates absent / vide / parts absent → jamais un succès', () => {
  assert.equal(fromGeminiCandidate({}).finishReason, 'empty');
  assert.equal(fromGeminiCandidate({ candidates: [] }).finishReason, 'empty');
  assert.equal(fromGeminiCandidate({ candidates: [{ content: {} }] }).finishReason, 'empty');
});

test('réponse bloquée détectée explicitement', () => {
  assert.equal(fromGeminiCandidate({ promptFeedback: { blockReason: 'SAFETY' } }).finishReason, 'blocked');
  assert.equal(
    fromGeminiCandidate({ candidates: [{ content: { parts: [] }, finishReason: 'SAFETY' }] }).finishReason,
    'blocked',
  );
});

// ── Interopérabilité : le même historique sert les deux fournisseurs ────────
test('un historique canonique avec outils est convertible pour Claude ET Gemini', () => {
  const history = [
    userMessage([textBlock('Recharge 1000 FCFA')]),
    assistantMessage([toolCallBlock({ id: 'c1', name: 'initiate_wallet_recharge', input: { amount: 1000 } })]),
    userMessage([toolResultBlock({
      toolCallId: 'c1', name: 'initiate_wallet_recharge',
      content: { status: 'awaiting_confirmation', actionId: 'a1' },
    })]),
  ];
  const claude = toClaudeMessages(history);
  const gemini = toGeminiContents(history);
  assert.equal(claude.length, gemini.length, 'aucun message perdu d\'un format à l\'autre');
  assert.equal(claude[1].content[0].name, gemini[1].parts[0].functionCall.name);
  assert.equal(
    JSON.parse(claude[2].content[0].content).actionId,
    gemini[2].parts[0].functionResponse.response.actionId,
  );
});

// ── Régression : bloc texte vide (panne AZ IA du 2026-10-02) ────────────────
//
// `azIaChat` échouait avec 400 « messages: text content blocks must be
// non-empty » dès qu'un outil était déclenché : le tour 1 passait, puis
// l'historique rejoué au tour 2 contenait un bloc texte vide fabriqué à
// partir d'un bloc Claude sans `.text`. Un seul bloc vide invalide la requête
// ENTIÈRE, donc toute conversation utilisant un outil était cassée.

test('régression : un bloc Claude sans texte ne produit JAMAIS de bloc vide', () => {
  const blocks = fromClaudeContent([
    { type: 'thinking', thinking: 'réflexion interne', signature: 'sig' },
    { type: 'tool_use', id: 'tu_1', name: 'get_wallet_balance', input: {} },
  ]);
  assert.equal(blocks.length, 1, 'le bloc sans texte est écarté, pas converti');
  assert.equal(blocks[0].type, 'tool_call');
  // Et la requête du tour suivant reste valide.
  const claude = toClaudeMessages([assistantMessage(blocks)]);
  assert.ok(claude[0].content.every(b => b.type !== 'text' || b.text !== ''));
});

test('régression : un bloc texte Claude vide est écarté', () => {
  const blocks = fromClaudeContent([
    { type: 'text', text: '' },
    { type: 'tool_use', id: 'tu_2', name: 'get_wallet_balance', input: {} },
  ]);
  assert.deepEqual(blocks.map(b => b.type), ['tool_call']);
});

test('le texte réel est toujours préservé, lui', () => {
  const blocks = fromClaudeContent([
    { type: 'text', text: 'Je vérifie votre solde.' },
    { type: 'tool_use', id: 'tu_3', name: 'get_wallet_balance', input: {} },
  ]);
  assert.deepEqual(blocks.map(b => b.type), ['text', 'tool_call']);
  assert.equal(blocks[0].text, 'Je vérifie votre solde.');
});

test('tour 2 complet (texte + outil + résultat) : aucun bloc vide envoyé', () => {
  const assistant = fromClaudeContent([
    { type: 'thinking', thinking: 'interne' },
    { type: 'tool_use', id: 'tu_4', name: 'get_wallet_balance', input: {} },
  ]);
  const turn2 = [
    userMessage([textBlock('Quel est mon solde ?')]),
    assistantMessage(assistant),
    userMessage([toolResultBlock({
      toolCallId: 'tu_4', name: 'get_wallet_balance', content: { balanceFcfa: 0 },
    })]),
  ];
  for (const payload of [toClaudeMessages(turn2), toGeminiContents(turn2)]) {
    assert.equal(payload.length, 3, 'aucun message perdu');
    for (const message of payload) {
      const parts = message.content || message.parts;
      assert.ok(parts.length > 0, 'jamais un message sans contenu');
      for (const part of parts) {
        if ('text' in part) assert.notEqual(part.text, '', 'bloc texte vide envoyé');
      }
    }
  }
});

test('un message vidé de tout bloc exploitable est retiré', () => {
  // Cas concret : un message d'historique persisté au contenu blanc.
  const claude = toClaudeMessages([
    userMessage([textBlock('')]),
    userMessage([textBlock('Bonjour')]),
  ]);
  assert.equal(claude.length, 1);
  assert.equal(claude[0].content[0].text, 'Bonjour');
});

test('un type de bloc inconnu est écarté, pas transformé en texte vide', () => {
  const claude = toClaudeMessages([
    { role: 'assistant', content: [{ type: 'bloc_futur_inconnu' }, textBlock('ok')] },
  ]);
  assert.deepEqual(claude[0].content, [{ type: 'text', text: 'ok' }]);
  const gemini = toGeminiContents([
    { role: 'assistant', content: [{ type: 'bloc_futur_inconnu' }, textBlock('ok')] },
  ]);
  assert.deepEqual(gemini[0].parts, [{ text: 'ok' }]);
});

test('un résultat d\'outil vide ne produit jamais un contenu vide', () => {
  const claude = toClaudeMessages([userMessage([
    toolResultBlock({ toolCallId: 'tu_5', name: 'x', content: '' }),
  ])]);
  assert.equal(claude[0].content[0].content, '{}');
});
