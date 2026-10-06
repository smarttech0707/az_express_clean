'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const createAzIa = require('../azia');
const ClaudeProvider = require('../azia/providers/ClaudeProvider');
const GeminiProvider = require('../azia/providers/GeminiProvider');
const { createToolExecutionLedger } = require('../azia/toolExecutionLedger');
const { normalizeConfig } = require('../azia/aiRouter');

// Real callable, gateway, provider adapters, registry and confirmation code.
// Only transports, Firebase services and the payment endpoint are in-memory.
function database(seed) {
  const store = new Map(Object.entries(seed)), reads = new Map(), writes = [];
  let serial = 0;
  const apply = (path, data, merge) => {
    const old = store.get(path) || {}, next = merge ? { ...old } : {};
    for (const [key, value] of Object.entries(data)) {
      next[key] = value?.increment !== undefined ? (old[key] || 0) + value.increment : value;
    }
    writes.push(path); store.set(path, next);
  };
  function ref(path) {
    return { id: path.split('/').at(-1), path,
      get: async () => { reads.set(path, (reads.get(path) || 0) + 1);
        return { exists: store.has(path), data: () => store.get(path), id: path.split('/').at(-1) }; },
      set: async (data, opts) => apply(path, data, opts?.merge),
      update: async data => apply(path, data, true),
      collection: name => collection(`${path}/${name}`),
    };
  }
  function collection(path, filters = [], count = Infinity) {
    return { doc: id => ref(`${path}/${id || `auto${++serial}`}`),
      add: async data => { const r = ref(`${path}/auto${++serial}`); await r.set(data); return r; },
      where: (key, op, value) => { assert.equal(op, '=='); return collection(path, [...filters, [key, value]], count); },
      orderBy: () => collection(path, filters, count),
      limit: n => collection(path, filters, n), limitToLast: n => collection(path, filters, n),
      get: async () => {
        const entries = [...store].filter(([p, data]) => p.startsWith(`${path}/`)
          && !p.slice(path.length + 1).includes('/') && filters.every(([k,v]) => data[k] === v)).slice(0, count);
        return { empty: !entries.length, size: entries.length,
          docs: entries.map(([p,data]) => ({ id: p.split('/').at(-1), ref: ref(p), data: () => data })) };
      },
    };
  }
  const db = { collection, runTransaction: async fn => {
    const pending = [];
    const result = await fn({ get: r => r.get(),
      set: (r,d,opts) => pending.push(() => apply(r.path,d,opts?.merge)),
      update: (r,d) => pending.push(() => apply(r.path,d,true)) });
    pending.forEach(commit => commit()); return result;
  } };
  return { db, store, reads, writes };
}

const admin = { firestore: {
  FieldValue: { serverTimestamp: () => 1, increment: n => ({ increment: n }) },
  Timestamp: { fromMillis: ms => ({ toMillis: () => ms }) },
} };
class HttpsError extends Error { constructor(code, message) { super(message); this.code = code; } }
const call = (name, input = {}, id = 'native-1') => ({ name, input, id });
const failure = () => Object.assign(new Error('simulated provider timeout'), { code: 'provider_timeout' });

function harness({ primary = 'gemini', scripts, config = {}, seed = {} } = {}) {
  const data = database({ 'clients/u': { wallet: 10000 },
    'settings/ai': { defaultProvider: primary, allowedProviders: ['gemini', 'claude'],
      fallbackEnabled: true, ...config }, ...seed });
  const requests = [], turns = [], counts = { gemini: 0, claude: 0, openai: 0, payment: 0, recharge: 0 };
  function response(provider, body, model) {
    requests.push({ provider, body: JSON.parse(JSON.stringify(body)), model });
    const n = counts[provider]++;
    const script = scripts?.[provider] || [];
    const value = typeof script === 'function' ? script(n, body) : script[n];
    if (value instanceof Error) throw value;
    assert.notEqual(value, undefined, `Unexpected ${provider} call ${n}`);
    if (value?.raw) return value.raw;
    const calls = Array.isArray(value) ? value : [];
    return provider === 'gemini'
      ? { candidates: [{ finishReason: 'STOP', content: { parts: calls.length
        ? calls.map(c => ({ functionCall: { id: c.id, name: c.name, args: c.input }, thoughtSignature: 'fixture-signature' }))
        : [{ text: value }] } }], usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 } }
      : { content: calls.length ? calls.map(c => ({ type: 'tool_use', id: c.id, name: c.name, input: c.input }))
        : [{ type: 'text', text: value }], usage: { input_tokens: 1, output_tokens: 1 } };
  }
  const gemini = new GeminiProvider();
  gemini.isConfigured = () => config.geminiConfigured !== false;
  gemini._post = async (model, body) => response('gemini', body, model);
  const claude = new ClaudeProvider();
  claude.isConfigured = () => true;
  claude._getClient = () => ({ messages: { create: async body => response('claude', body, body.model) } });
  // generateTurn only checks presence before calling the mocked transport.
  const originalGenerate = gemini.generateTurn.bind(gemini);
  gemini.generateTurn = async turn => {
    turns.push({ provider: 'gemini', turn: JSON.parse(JSON.stringify(turn)) });
    const previous = process.env.GEMINI_API_KEY;
    const previousModel = process.env.GEMINI_MODEL;
    process.env.GEMINI_API_KEY = 'fixture-only';
    process.env.GEMINI_MODEL = 'gemini-3.8-flash';
    try { return await originalGenerate(turn); }
    finally {
      if (previous === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = previous;
      if (previousModel === undefined) delete process.env.GEMINI_MODEL; else process.env.GEMINI_MODEL = previousModel;
    }
  };
  const originalClaude = claude.generateTurn.bind(claude);
  claude.generateTurn = turn => {
    turns.push({ provider: 'claude', turn: JSON.parse(JSON.stringify(turn)) });
    return originalClaude(turn);
  };
  const openai = { isConfigured: () => true, supportsTools: () => true,
    supportsCanonicalHistory: () => false,
    generateTurn: async () => { counts.openai++; throw new Error('Incompatible history must never reach OpenAI'); } };
  const app = createAzIa({ db: data.db, admin, HttpsError, providers: { gemini, claude, openai },
    onCall: (_opts, handler) => handler, onSchedule: (_opts, handler) => handler,
    checkRateLimit: async (_uid, kind) => { if (kind === 'payment') counts.recharge++; },
    logAudit: async () => {}, sendToToken: async () => {},
    axios: { post: async () => { counts.payment++; return { data: { url: 'https://payment.invalid/fixture' } }; } },
    FEEXPAY_TOKEN: { value: () => 'fixture-only' }, FEEXPAY_API_URL: 'https://payment.invalid',
    WEBHOOK_URL: () => 'https://callback.invalid', feexpayOperatorCode: () => 'fixture',
  });
  return { ...data, ...app, counts, requests, turns,
    chat: extra => app.azIaChat({ auth: { uid: 'u' }, data: { message: 'Quel est mon solde ?', ...extra } }),
    pending: () => [...data.store].filter(([p]) => p.startsWith('ai_pending_actions/')),
  };
}

test('Gemini primary: real wallet tool once, canonical response, no financial writes', async () => {
  const h = harness({ scripts: { gemini: [[call('get_wallet_balance')], 'Solde : 10000 FCFA'] } });
  const result = await h.chat();
  assert.equal(result.reply, 'Solde : 10000 FCFA');
  assert.deepEqual(h.requests.map(r => r.provider), ['gemini', 'gemini']);
  assert.equal(h.reads.get('clients/u'), 2); // context + exactly one tool
  assert.equal(h.pending().length, 0);
  assert.ok(!h.writes.some(p => p.startsWith('clients/') || p.startsWith('wallet_transactions/')));
  assert.equal(h.requests[1].body.contents[1].parts[0].thoughtSignature, 'fixture-signature');
  assert.equal(h.requests[1].body.contents[2].parts[0].functionResponse.id, 'native-1');
});

for (const primary of ['gemini', 'claude']) {
  const other = primary === 'gemini' ? 'claude' : 'gemini';
  test(`${primary} -> ${other} before execution with canonical history`, async () => {
    const h = harness({ primary, scripts: { [primary]: [failure()], [other]: ['fallback final'] } });
    assert.equal((await h.chat()).reply, 'fallback final');
    assert.equal(h.pending().length, 0);
    assert.deepEqual(h.requests.map(r => r.provider), [primary, other]);
  });
  test(`${primary} -> ${other} after result, changed provider ID cannot replay wallet read`, async () => {
    const h = harness({ primary, scripts: {
      [primary]: [[call('get_wallet_balance')], failure(), failure()],
      [other]: [[call('get_wallet_balance', {}, 'different-native-id')], 'fallback final'],
    } });
    assert.equal((await h.chat()).reply, 'fallback final');
    assert.equal(h.reads.get('clients/u'), 2);
    for (const { turn } of h.turns) {
      assert.equal(turn.canonicalHistory, true);
      for (const message of turn.messages) for (const block of message.content) {
        assert.ok(['text', 'image', 'tool_call', 'tool_result'].includes(block.type));
        assert.equal(block.tool_use_id, undefined);
      }
    }
    const executed = h.turns.flatMap(({ turn }) => turn.messages.flatMap(m => m.content))
      .filter(b => b.type === 'tool_call');
    assert.equal(new Set(executed.map(b => b.canonicalCallId)).size, 1);
    const transferred = h.requests.find(r => r.provider === other).body;
    const serialized = JSON.stringify(transferred);
    assert.match(serialized, /10000/);
    assert.match(serialized, /native-1/);
    assert.match(serialized, other === 'gemini' ? /functionResponse/ : /tool_result/);
    if (other === 'gemini') assert.match(serialized, /skip_thought_signature_validator/);
  });
  for (const [name, input] of [
    ['initiate_wallet_recharge', { amount: 1000, phone: '0700000000', operator: 'mtn' }],
    ['cancel_order', { orderId: 'o1' }],
    ['create_shopping_order', { items: [{ name: 'riz', budgetFcfa: 2000 }], deliveryLat: 6.73, deliveryLng: -3.49, paymentMethod: 'wallet' }],
  ]) {
    test(`${primary} -> ${other}: ${name} has one pending action despite replay`, async () => {
      const h = harness({ primary, seed: { 'orders/o1': { clientId: 'u', status: 'pending', paymentMethod: 'wallet', budget: 500 } },
        scripts: { [primary]: [[call(name, input)], failure(), failure()],
          [other]: [[call(name, Object.fromEntries(Object.entries(input).reverse()), 'other-id')], 'Confirmez cette action'] } });
      await h.chat();
      assert.equal(h.pending().length, 1);
      assert.equal(h.writes.filter(p => p.startsWith('ai_pending_actions/')).length, 1);
      const logs = [...h.store].filter(([p]) => p.startsWith('request_logs/'));
      assert.equal(logs.at(-1)[1].toolsUsed.filter(tool => tool === name).length, 1, 'EXECUTE TOOL COUNT = 1');
      assert.equal(h.store.get('clients/u').wallet, 10000);
      assert.equal(h.counts.payment, 0);
      if (name === 'initiate_wallet_recharge') assert.equal(h.counts.recharge, 1);
      const beforeCalls = h.requests.length;
      const id = h.pending()[0][0].split('/').at(-1);
      const confirmed = await h.aiConfirmAction({ auth: { uid: 'u' }, data: { actionId: id, decision: 'confirm' } });
      assert.equal(confirmed.status, 'completed');
      assert.equal(h.requests.length, beforeCalls, 'Confirmation never calls any model');
      await assert.rejects(h.aiConfirmAction({ auth: { uid: 'u' }, data: { actionId: id } }), e => e.code === 'failed-precondition');
      if (name === 'cancel_order') assert.equal(h.store.get('clients/u').wallet, 10500);
      if (name === 'create_shopping_order') {
        assert.equal(h.store.get('clients/u').wallet, 8000);
        assert.equal(h.writes.filter(p => p.startsWith('orders/')).length, 1);
        // Existing dispatch requires pickupCityId, absent from this legacy
        // AZ IA order contract. Do not count the post-confirm failure as a
        // successful dispatch, or modify dispatch in this provider-only lot.
        assert.match(confirmed.afterConfirmError, /pickupCityId/);
      }
      if (name === 'initiate_wallet_recharge') {
        assert.equal(h.counts.payment, 1); assert.equal(h.store.get('clients/u').wallet, 10000);
      }
    });
  }
}

test('fallback disabled propagates controlled error, never calls Claude', async () => {
  const h = harness({ config: { fallbackEnabled: false }, scripts: { gemini: [failure()] } });
  await assert.rejects(h.chat(), e => e.code === 'internal');
  assert.equal(h.counts.claude, 0);
});
test('unconfigured Gemini falls back to Claude', async () => {
  const h = harness({ config: { geminiConfigured: false }, scripts: { claude: ['Bonjour'] } });
  assert.equal((await h.chat()).reply, 'Bonjour'); assert.equal(h.counts.gemini, 0);
});
test('explicit toolProvider remains a documented override', async () => {
  const h = harness({ config: { toolProvider: 'claude' }, scripts: { claude: ['Claude'] } });
  assert.equal((await h.chat()).reply, 'Claude'); assert.equal(h.counts.gemini, 0);
});
test('image survives Gemini tool round trip; multiple tools execute sequentially', async () => {
  const h = harness({ scripts: { gemini: [[call('get_wallet_balance'), call('get_wallet_transactions', {}, 'native-2')], 'Termine'] } });
  await h.chat({ imageBase64: 'Zml4dHVyZQ==', imageMediaType: 'image/png' });
  for (const request of h.requests) assert.equal(request.body.contents[0].parts[0].inline_data.mime_type, 'image/png');
  const results = h.requests[1].body.contents.at(-1).parts;
  assert.deepEqual(results.map(p => p.functionResponse.name), ['get_wallet_balance', 'get_wallet_transactions']);
  assert.equal(h.reads.get('clients/u'), 2);
});
test('continuous tools hit six-turn cap; closing call executes no tools', async () => {
  const h = harness({ scripts: { gemini: n => n < 6 ? [call('get_wallet_balance', {}, `id-${n}`)] : 'Fin controlee' } });
  const result = await h.chat();
  assert.equal(result.hitTurnCap, true); assert.equal(h.counts.gemini, 7);
  assert.equal(h.requests.at(-1).body.tools, undefined);
  assert.equal(h.reads.get('clients/u'), 2);
});
test('provider-specific models never transfer to fallback', async () => {
  const h = harness({ config: { models: { gemini: 'gemini-3.8-flash', claude: 'claude-fixture' } },
    scripts: { gemini: [failure()], claude: ['OK'] } });
  await h.chat();
  assert.deepEqual(h.requests.map(r => r.model), ['gemini-3.8-flash', 'claude-fixture']);
});
test('legacy routing field and default tool routing are normalized without masking', () => {
  assert.equal(normalizeConfig({ provider: 'gemini' }).toolProvider, 'gemini');
  assert.equal(normalizeConfig({ defaultProvider: 'gemini', fallbackEnabled: true }).enableFallback, true);
});
test('ledger retains failures and shares logical identity independently of IDs/key order', async () => {
  const ledger = createToolExecutionLedger(); let count = 0;
  const run = () => { count++; throw new Error('effect may already exist'); };
  await assert.rejects(ledger.execute(call('write', { a: 1, b: 2 }), run));
  await assert.rejects(ledger.execute(call('write', { b: 2, a: 1 }, 'new-id'), run));
  assert.equal(count, 1);
  let calls = 0;
  await Promise.all([ledger.execute(call('read'), () => ++calls), ledger.execute(call('read'), () => ++calls)]);
  assert.equal(calls, 1);
});

test('Claude primary remains functional through canonical text, image and tools', async () => {
  const h = harness({ primary: 'claude', scripts: { claude: [[call('get_wallet_balance')], 'Claude final'] } });
  assert.equal((await h.chat({ imageBase64: 'Zml4dHVyZQ==' })).reply, 'Claude final');
  assert.equal(h.requests[0].body.messages[0].content[0].source.type, 'base64');
  assert.equal(h.requests[1].body.messages[1].content[0].type, 'tool_use');
  assert.equal(h.requests[1].body.messages[2].content[0].tool_use_id, 'native-1');
  assert.equal(h.requests[1].body.messages[2].content[0].is_error, false);
  assert.deepEqual(h.requests[0].body.system[0].cache_control, { type: 'ephemeral' });
  assert.equal(h.turns[0].turn.systemPrompt[0].cache_control, undefined);
  assert.equal(h.counts.gemini, 0);
});
test('native errors survive Claude and Gemini history conversion without retrying the handler', async () => {
  const h = harness({ scripts: { gemini: [[call('unknown_tool')], failure()], claude: ['Outil indisponible'] } });
  await h.chat();
  const result = h.requests.at(-1).body.messages.at(-1).content[0];
  assert.equal(result.is_error, true); assert.match(result.content, /error/);
  assert.equal(h.pending().length, 0);
});
test('policy rejects a model-requested financial tool excluded by configuration', async () => {
  const h = harness({ config: { allowedTools: ['get_wallet_balance'] }, scripts: { gemini: [
    [call('initiate_wallet_recharge', { amount: 1000, phone: '0700000000', operator: 'mtn' })], 'Refuse'],
  } });
  await h.chat(); assert.equal(h.pending().length, 0); assert.equal(h.counts.recharge, 0);
});
test('confirmation after Gemini validates owner, expiry and leaves models untouched', async () => {
  const h = harness({ scripts: { gemini: [[call('initiate_wallet_recharge',
    { amount: 1000, phone: '0700000000', operator: 'mtn' })], 'Confirmez'] } });
  await h.chat(); const [path, action] = h.pending()[0]; const id = path.split('/').at(-1);
  await assert.rejects(h.aiConfirmAction({ auth: { uid: 'other' }, data: { actionId: id } }), e => e.code === 'permission-denied');
  action.expiresAt = { toMillis: () => 0 };
  await assert.rejects(h.aiConfirmAction({ auth: { uid: 'u' }, data: { actionId: id } }), e => e.code === 'deadline-exceeded');
  assert.equal(h.store.get(path).status, 'expired');
  assert.equal(h.counts.payment, 0); assert.equal(h.requests.length, 2);
});
test('failure after pending creation with fallback disabled never retries the action', async () => {
  const h = harness({ config: { fallbackEnabled: false }, scripts: { gemini: [[call('initiate_wallet_recharge',
    { amount: 1000, phone: '0700000000', operator: 'mtn' })], failure()] } });
  await assert.rejects(h.chat(), e => e.code === 'internal');
  assert.equal(h.pending().length, 1); assert.equal(h.counts.recharge, 1);
  assert.equal(h.counts.claude, 0); assert.equal(h.counts.payment, 0);
});
test('all providers fail: controlled error with no tool effects', async () => {
  const h = harness({ scripts: { gemini: [failure()], claude: [failure()] } });
  await assert.rejects(h.chat(), e => e.code === 'internal'); assert.equal(h.pending().length, 0);
});
test('provider outside allowlist fails before any transport call', async () => {
  const h = harness({ config: { allowedProviders: ['claude'] } });
  await assert.rejects(h.chat(), e => e.code === 'internal'); assert.equal(h.requests.length, 0);
});
test('replay ledger is invocation-local: a new user message may intentionally repeat', async () => {
  const h = harness({ scripts: { gemini: [[call('get_wallet_balance')], 'Premier', [call('get_wallet_balance')], 'Second'] } });
  await h.chat(); await h.chat(); assert.equal(h.reads.get('clients/u'), 4);
});
test('OpenAI tool flag alone cannot authorize an incompatible canonical adapter', async () => {
  const previous = process.env.AI_OPENAI_TOOL_CALLING_ENABLED;
  process.env.AI_OPENAI_TOOL_CALLING_ENABLED = 'true';
  try {
    const h = harness({ config: { toolProvider: 'openai', allowedProviders: ['openai','gemini'], fallbackProviders: ['gemini'] },
      scripts: { gemini: ['Compatible'] } });
    assert.equal((await h.chat()).reply, 'Compatible'); assert.equal(h.counts.openai, 0);
  } finally {
    if (previous === undefined) delete process.env.AI_OPENAI_TOOL_CALLING_ENABLED;
    else process.env.AI_OPENAI_TOOL_CALLING_ENABLED = previous;
  }
});
test('legacy preferredModel is not transferred from Claude to Gemini fallback', async () => {
  const h = harness({ primary: 'claude', config: { preferredModel: 'claude-fixture' },
    scripts: { claude: [failure()], gemini: ['Fallback'] } });
  await h.chat(); assert.deepEqual(h.requests.map(r => r.model), ['claude-fixture', 'gemini-3.8-flash']);
});
test('blank Gemini output is rejected, then compatible fallback responds', async () => {
  const h = harness({ scripts: { gemini: ['   '], claude: ['Fallback'] } });
  assert.equal((await h.chat()).reply, 'Fallback'); assert.equal(h.counts.claude, 1);
});
test('six distinct tool calls execute sequentially; closing turn cannot execute a seventh', async () => {
  const h = harness({ scripts: { gemini: n => n < 6
    ? [call('get_wallet_transactions', { limit: n + 1 }, `id-${n}`)]
    : [call('initiate_wallet_recharge', { amount: 1000, phone: '0700000000', operator: 'mtn' }, 'seventh')] } });
  const result = await h.chat();
  assert.equal(result.hitTurnCap, true); assert.equal(h.counts.gemini, 7);
  const log = [...h.store].find(([p]) => p.startsWith('request_logs/'))[1];
  assert.equal(log.toolsUsed.length, 6); assert.equal(h.pending().length, 0);
});
test('Gemini thought parts stay private to adapter while native continuation is preserved', async () => {
  const parts = [{ text: 'internal-fixture-thought', thought: true },
    { functionCall: { name: 'get_wallet_balance', args: {}, id: 'gemini-native' }, thoughtSignature: 'fixture-signature' }];
  const h = harness({ scripts: { gemini: [{ raw: { candidates: [{ content: { parts }, finishReason: 'STOP' }] } }, 'Final'] } });
  await h.chat();
  assert.deepEqual(h.requests[1].body.contents[1].parts, parts);
  assert.equal(JSON.stringify(h.turns[1]).includes('internal-fixture-thought'), false);
  assert.equal(JSON.stringify(h.turns[1]).includes('thoughtSignature'), false);
});
test('Gemini whole-request deadline fires even without socket timeout callback', async () => {
  const { EventEmitter } = require('node:events');
  const previousTransport = GeminiProvider.transport;
  const previousKey = process.env.GEMINI_API_KEY;
  let destroyed = false;
  process.env.GEMINI_API_KEY = 'fixture-only';
  GeminiProvider.transport = { request: () => {
    const req = new EventEmitter(); req.write = () => {}; req.end = () => {};
    req.setTimeout = () => {}; req.destroy = () => { destroyed = true; }; return req;
  } };
  try {
    await assert.rejects(new GeminiProvider()._post('gemini-3.8-flash', {}, { timeoutMs: 10 }), e => e.code === 'provider_timeout');
    assert.equal(destroyed, true);
  } finally {
    if (previousTransport === undefined) delete GeminiProvider.transport; else GeminiProvider.transport = previousTransport;
    if (previousKey === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = previousKey;
  }
});
