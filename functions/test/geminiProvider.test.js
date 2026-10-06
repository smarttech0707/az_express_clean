'use strict';

/**
 * GeminiProvider — suite locale entièrement bouchonnée.
 * Aucun appel réseau réel : le transport HTTPS est remplacé par une doublure
 * et la clé API est factice. Aucune valeur sensible n'est jamais affichée.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const GeminiProvider = require('../azia/providers/GeminiProvider');

const FAKE_KEY = 'cle-de-test-non-sensible';
const FAKE_MODEL = 'gemini-modele-de-test';

// ── Transport bouchonné ─────────────────────────────────────────────────────
// Reproduit le contrat de `https.request` utilisé par le provider : callback
// de réponse, événements data/end, req.setTimeout, req.on('error').
function makeTransport(scenario) {
  const calls = [];
  return {
    calls,
    request(options, onResponse) {
      const req = new EventEmitter();
      let body = '';
      req.write = (chunk) => { body += chunk; };
      req.setTimeout = (ms, cb) => { req.__timeoutMs = ms; req.__onTimeout = cb; };
      req.destroy = () => { req.__destroyed = true; };
      req.end = () => {
        calls.push({ options, body: JSON.parse(body), timeoutMs: req.__timeoutMs });
        setImmediate(() => {
          if (scenario.timeout) { req.__onTimeout?.(); return; }
          if (scenario.networkError) { req.emit('error', new Error(scenario.networkError)); return; }
          const res = new EventEmitter();
          res.statusCode = scenario.statusCode ?? 200;
          onResponse(res);
          res.emit('data', typeof scenario.raw === 'string' ? scenario.raw : JSON.stringify(scenario.json ?? {}));
          res.emit('end');
        });
      };
      return req;
    },
  };
}

function withProvider(scenario, fn, { model = FAKE_MODEL, key = FAKE_KEY } = {}) {
  const prevKey = process.env.GEMINI_API_KEY;
  const prevModel = process.env.GEMINI_MODEL;
  process.env.GEMINI_API_KEY = key;
  if (model === null) delete process.env.GEMINI_MODEL; else process.env.GEMINI_MODEL = model;
  const transport = makeTransport(scenario);
  GeminiProvider.transport = transport;
  const provider = new GeminiProvider();
  const restore = () => {
    delete GeminiProvider.transport;
    if (prevKey === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = prevKey;
    if (prevModel === undefined) delete process.env.GEMINI_MODEL; else process.env.GEMINI_MODEL = prevModel;
  };
  return Promise.resolve(fn(provider, transport)).finally(restore);
}

const TOOLS = [{
  name: 'get_wallet_balance',
  description: 'Consulte le solde du wallet.',
  input_schema: { type: 'object', properties: {}, required: [] },
}];
const textResponse = (text) => ({ json: { candidates: [{ content: { parts: [{ text }] }, finishReason: 'STOP' }] } });

// ── 1. Configuration ────────────────────────────────────────────────────────
test('1. isConfigured exige la clé ET le modèle', async () => {
  await withProvider({}, (p) => assert.equal(p.isConfigured(), true));
  await withProvider({}, (p) => assert.equal(p.isConfigured(), false), { model: null });
  await withProvider({}, (p) => assert.equal(p.isConfigured(), false), { key: '' });
});

test('1b. modèle absent → erreur claire, jamais de repli silencieux', async () => {
  await withProvider({}, (p) => {
    assert.throws(() => p.resolveModel(), (e) => e.code === 'provider_model_not_configured');
  }, { model: null });
});

test('1c. gemini-2.0-flash n\'est plus un modèle par défaut', async () => {
  const source = require('node:fs').readFileSync(require.resolve('../azia/providers/GeminiProvider'), 'utf8');
  const code = source.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');
  assert.ok(!code.includes("'gemini-2.0-flash'"), 'aucun modèle codé en dur ne doit subsister');
});

// ── 2-3. Texte et vision ────────────────────────────────────────────────────
test('2. génération texte', async () => {
  await withProvider(textResponse('Bonjour !'), async (p, t) => {
    const r = await p.generateChat([{ role: 'user', content: 'Salut' }], {});
    assert.equal(r.text, 'Bonjour !');
    assert.equal(r.model, FAKE_MODEL);
    assert.equal(t.calls[0].body.contents[0].parts[0].text, 'Salut');
  });
});

test('3. génération vision (image bouchonnée, jamais envoyée en vrai)', async () => {
  await withProvider(textResponse('Une facture.'), async (p, t) => {
    const r = await p.generateVision('Décris', 'BASE64_FICTIF', { mediaType: 'image/png' });
    assert.equal(r.text, 'Une facture.');
    assert.deepEqual(t.calls[0].body.contents[0].parts[1].inline_data,
      { mime_type: 'image/png', data: 'BASE64_FICTIF' });
  });
});

// ── 4-7. Outils ─────────────────────────────────────────────────────────────
test('4. supportsTools est vrai, et les déclarations sont envoyées', async () => {
  await withProvider(textResponse('ok'), async (p, t) => {
    assert.equal(p.supportsTools(), true);
    await p.generateTurn({ messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }], tools: TOOLS });
    const declarations = t.calls[0].body.tools[0].functionDeclarations;
    assert.equal(declarations[0].name, 'get_wallet_balance');
    assert.equal(declarations[0].description, 'Consulte le solde du wallet.');
  });
});

test('5. appel de fonction unique → format canonique', async () => {
  const json = { candidates: [{ content: { parts: [{ functionCall: { name: 'get_wallet_balance', args: {} } }] } }] };
  await withProvider({ json }, async (p) => {
    const turn = await p.generateTurn({
      messages: [{ role: 'user', content: [{ type: 'text', text: 'solde ?' }] }], tools: TOOLS, turnIndex: 0,
    });
    assert.equal(turn.toolCalls.length, 1);
    assert.equal(turn.toolCalls[0].name, 'get_wallet_balance');
    assert.ok(turn.toolCalls[0].id, 'un identifiant canonique est synthétisé');
    assert.equal(turn.assistantMessage[0].type, 'tool_call', 'historique canonique, pas de bloc Gemini');
  });
});

test('6. arguments structurés transmis intacts', async () => {
  const json = { candidates: [{ content: { parts: [{ functionCall: {
    name: 'initiate_wallet_recharge', args: { amount: 1000, operator: 'wave', phone: '0700000000' },
  } }] } }] };
  await withProvider({ json }, async (p) => {
    const turn = await p.generateTurn({ messages: [], tools: TOOLS });
    assert.deepEqual(turn.toolCalls[0].input, { amount: 1000, operator: 'wave', phone: '0700000000' });
  });
});

test('7-8. résultat d\'outil et continuation multi-tours', async () => {
  await withProvider(textResponse('Votre solde est de 1500 FCFA.'), async (p, t) => {
    const history = [
      { role: 'user', content: [{ type: 'text', text: 'solde ?' }] },
      { role: 'assistant', content: [{ type: 'tool_call', id: 'g-0', name: 'get_wallet_balance', input: {} }] },
      { role: 'user', content: [{ type: 'tool_result', toolCallId: 'g-0', name: 'get_wallet_balance', content: { balance: 1500 } }] },
    ];
    const turn = await p.generateTurn({ messages: history, tools: TOOLS });
    const contents = t.calls[0].body.contents;
    assert.equal(contents[1].role, 'model');
    assert.equal(contents[1].parts[0].functionCall.name, 'get_wallet_balance');
    assert.equal(contents[2].parts[0].functionResponse.response.balance, 1500);
    assert.equal(turn.text, 'Votre solde est de 1500 FCFA.');
    assert.equal(turn.toolCalls.length, 0, 'le tour final ne demande plus d\'outil');
  });
});

// ── 9-10. Timeout et erreurs réseau ─────────────────────────────────────────
test('9. timeout appliqué au transport et remonté proprement', async () => {
  await withProvider({ timeout: true }, async (p, t) => {
    await assert.rejects(
      p.generateChat([{ role: 'user', content: 'x' }], { timeoutMs: 1234 }),
      (e) => e.code === 'provider_timeout' && /délai/.test(e.message),
    );
    assert.equal(t.calls[0].timeoutMs, 1234, 'le délai est bien transmis au transport');
  });
});

test('9b. timeout par défaut borné même sans option', async () => {
  await withProvider({ timeout: true }, async (p, t) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}));
    assert.ok(t.calls[0].timeoutMs > 0 && t.calls[0].timeoutMs <= 30000);
  });
});

test('10. erreur réseau remontée sans détail sensible', async () => {
  await withProvider({ networkError: 'socket hang up' }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), /gemini/);
  });
});

// ── 11-14. Réponses dégradées ───────────────────────────────────────────────
test('11. réponse vide → échec explicite, jamais un succès', async () => {
  for (const json of [{}, { candidates: [] }, { candidates: [{ content: { parts: [] } }] }]) {
    await withProvider({ json }, async (p) => {
      await assert.rejects(
        p.generateTurn({ messages: [], tools: [] }),
        (e) => e.code === 'provider_empty_response',
      );
    });
  }
});

test('12. réponse bloquée (sécurité) → échec explicite', async () => {
  await withProvider({ json: { promptFeedback: { blockReason: 'SAFETY' } } }, async (p) => {
    await assert.rejects(p.generateTurn({ messages: [], tools: [] }), (e) => e.code === 'provider_blocked');
  });
});

test('13. erreur HTTP → code dédié', async () => {
  await withProvider({ statusCode: 429, raw: '{"error":"quota"}' }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}),
      (e) => e.code === 'provider_http_error');
  });
});

test('14. JSON malformé → code dédié, jamais interprété', async () => {
  await withProvider({ raw: 'ceci nest pas du json' }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}),
      (e) => e.code === 'provider_invalid_json');
  });
});

// ── 15. Expurgation ─────────────────────────────────────────────────────────
test('15. aucune clé, URL ou en-tête sensible dans les erreurs', async () => {
  const leaky = `échec pour https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=${FAKE_KEY} authorization: Bearer ${FAKE_KEY}`;
  await withProvider({ statusCode: 500, raw: leaky }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.ok(!e.message.includes(FAKE_KEY), 'la clé ne doit jamais apparaître');
      assert.ok(!e.message.includes('generativelanguage.googleapis.com'), 'ni l\'URL');
      return true;
    });
  });
});

test('15b. le sanitizer neutralise clé, URL et en-tête', () => {
  process.env.GEMINI_API_KEY = FAKE_KEY;
  const out = GeminiProvider.sanitizeError(
    `https://generativelanguage.googleapis.com/v1beta?key=${FAKE_KEY} Authorization: Bearer ${FAKE_KEY}`,
  );
  assert.ok(!out.includes(FAKE_KEY));
  delete process.env.GEMINI_API_KEY;
});

// ── 16-17. Usage et modèle ──────────────────────────────────────────────────
test('16. usageMetadata conservé', async () => {
  const json = {
    candidates: [{ content: { parts: [{ text: 'ok' }] } }],
    usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 45 },
  };
  await withProvider({ json }, async (p) => {
    const turn = await p.generateTurn({ messages: [], tools: [] });
    assert.equal(turn.inputTokens, 120);
    assert.equal(turn.outputTokens, 45);
  });
});

test('17. le modèle reste propre au fournisseur (aucun modèle Claude accepté)', async () => {
  await withProvider(textResponse('ok'), async (p, t) => {
    await p.generateTurn({ messages: [], tools: [], model: undefined });
    assert.ok(t.calls[0].options.path.includes(encodeURIComponent(FAKE_MODEL)));
  });
  // Un modèle explicitement demandé est respecté (résolution par provider).
  await withProvider(textResponse('ok'), async (p, t) => {
    await p.generateTurn({ messages: [], tools: [], model: 'gemini-autre-modele' });
    assert.ok(t.calls[0].options.path.includes('gemini-autre-modele'));
  });
});

test('17b. le prompt système AZ IA (blocs) est aplati sans perte', async () => {
  await withProvider(textResponse('ok'), async (p, t) => {
    await p.generateTurn({
      systemPrompt: [{ type: 'text', text: 'Règle A' }, { type: 'text', text: 'Règle B' }],
      messages: [], tools: [],
    });
    const system = t.calls[0].body.systemInstruction.parts[0].text;
    assert.ok(system.includes('Règle A') && system.includes('Règle B'),
      'aucune règle de sécurité du prompt ne doit être perdue');
  });
});

// ── 18. Diagnostic sûr des erreurs Google ───────────────────────────────────
// Le corps d'erreur de Google était jusqu'ici intégralement jeté : un 503 ne
// disait pas s'il s'agissait d'une surcharge de modèle. Ces tests verrouillent
// l'extraction des SEULS champs sûrs, et l'absence de fuite dans tous les cas.

const googleError = (status, message, reason) => JSON.stringify({
  error: {
    code: 503,
    message,
    status,
    ...(reason ? { details: [{ '@type': 'type.googleapis.com/google.rpc.ErrorInfo', reason, domain: 'googleapis.com' }] } : {}),
  },
});

test('18.A 503 avec status et reason → métadonnées exploitables', async () => {
  const raw = googleError('UNAVAILABLE', 'The model is overloaded. Please try again later.', 'MODEL_OVERLOADED');
  await withProvider({ statusCode: 503, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.code, 'provider_http_error', 'le code existant ne change pas');
      assert.equal(e.httpStatus, 503);
      assert.equal(e.providerStatus, 'UNAVAILABLE');
      assert.equal(e.providerReason, 'MODEL_OVERLOADED');
      assert.equal(e.sanitizedMessage, 'The model is overloaded. Please try again later.');
      assert.ok(e.message.includes('status=UNAVAILABLE') && e.message.includes('reason=MODEL_OVERLOADED'));
      return true;
    });
  });
});

test('18.B 503 sans details → status seul, reason nulle (jamais devinée)', async () => {
  const raw = googleError('UNAVAILABLE', 'Service temporarily unavailable.');
  await withProvider({ statusCode: 503, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.providerStatus, 'UNAVAILABLE');
      assert.equal(e.providerReason, null, 'aucune raison inventée en l\'absence de details');
      return true;
    });
  });
});

test('18.C 429 RESOURCE_EXHAUSTED → distinct d\'une surcharge 503', async () => {
  const raw = JSON.stringify({
    error: {
      code: 429,
      message: 'Quota exceeded for quota metric.',
      status: 'RESOURCE_EXHAUSTED',
      details: [{ reason: 'RATE_LIMIT_EXCEEDED' }],
    },
  });
  await withProvider({ statusCode: 429, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.httpStatus, 429);
      assert.equal(e.providerStatus, 'RESOURCE_EXHAUSTED');
      assert.equal(e.providerReason, 'RATE_LIMIT_EXCEEDED');
      return true;
    });
  });
});

test('18.D corps JSON malformé sur une erreur HTTP → aucune métadonnée, aucun plantage', async () => {
  await withProvider({ statusCode: 503, raw: '{"error":{"status":"UNAV' }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.code, 'provider_http_error');
      assert.equal(e.providerStatus, null);
      assert.equal(e.providerReason, null);
      assert.equal(e.sanitizedMessage, null);
      assert.equal(e.message, 'gemini HTTP 503', 'statut HTTP seul, jamais le corps brut');
      return true;
    });
  });
});

test('18.E corps texte brut (HTML/proxy) → jamais journalisé', async () => {
  const html = '<html><head><title>503 Service Unavailable</title></head><body>upstream</body></html>';
  await withProvider({ statusCode: 503, raw: html }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.message, 'gemini HTTP 503');
      assert.ok(!e.message.includes('upstream'), 'aucun fragment du corps ne transite');
      return true;
    });
  });
});

test('18.F clé et URL présentes dans error.message → expurgées', async () => {
  const raw = JSON.stringify({
    error: {
      code: 400,
      status: 'INVALID_ARGUMENT',
      message: `Request to https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=${FAKE_KEY} failed; authorization: Bearer ${FAKE_KEY}`,
    },
  });
  await withProvider({ statusCode: 400, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.providerStatus, 'INVALID_ARGUMENT');
      assert.ok(!e.message.includes(FAKE_KEY), 'la clé ne doit jamais apparaître');
      assert.ok(!e.sanitizedMessage.includes(FAKE_KEY));
      assert.ok(!e.message.includes('generativelanguage.googleapis.com'), 'ni l\'URL');
      assert.ok(!e.sanitizedMessage.includes('generativelanguage.googleapis.com'));
      return true;
    });
  });
});

test('18.G message très long → tronqué', async () => {
  const raw = googleError('UNAVAILABLE', 'A'.repeat(5000), 'MODEL_OVERLOADED');
  await withProvider({ statusCode: 503, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.ok(e.sanitizedMessage.length <= 200, `message tronqué (${e.sanitizedMessage.length})`);
      assert.ok(e.message.length <= 300, 'le message final reste borné');
      return true;
    });
  });
});

test('18.H réponse 200 : comportement strictement inchangé', async () => {
  await withProvider(textResponse('AZ IA GEMINI OK'), async (p) => {
    const out = await p.generateChat([{ role: 'user', content: 'x' }], {});
    assert.equal(out.text, 'AZ IA GEMINI OK');
    assert.equal(out.model, FAKE_MODEL);
  });
});

test('18.I un status non énumératif est filtré, jamais recopié tel quel', () => {
  const out = GeminiProvider.extractGoogleError(JSON.stringify({
    error: { status: 'UNAVAILABLE <script>alert(1)</script>', details: [{ reason: 'A B;C' }] },
  }));
  assert.equal(out.status, 'UNAVAILABLEscriptalert1script');
  assert.equal(out.reason, 'ABC');
});

test('18.J en-tête x-goog-api-key dans un message Google → expurgé', async () => {
  const raw = JSON.stringify({
    error: { code: 403, status: 'PERMISSION_DENIED', message: `rejected; x-goog-api-key: ${FAKE_KEY}` },
  });
  await withProvider({ statusCode: 403, raw }, async (p) => {
    await assert.rejects(p.generateChat([{ role: 'user', content: 'x' }], {}), (e) => {
      assert.equal(e.providerStatus, 'PERMISSION_DENIED');
      assert.ok(!e.message.includes(FAKE_KEY));
      assert.ok(e.sanitizedMessage.includes('[REDACTED]'), 'l\'en-tête est neutralisé');
      return true;
    });
  });
});
