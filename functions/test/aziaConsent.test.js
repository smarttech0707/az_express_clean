'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const createAzIa = require('../azia');
const ClaudeProvider = require('../azia/providers/ClaudeProvider');
const GeminiProvider = require('../azia/providers/GeminiProvider');
const { CONSENT_VERSION } = require('../azia/consent');

// Consentement serveur et minimisation des données d'AZ IA (App Store
// 5.1.1(i)/5.1.2(i)). Les transports Anthropic/Gemini sont factices : chaque
// test compte les appels sortants pour prouver qu'AUCUN n'a lieu sans accord.
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

const PERSONAL = { phone: '+2250700000123', name: 'Awa Koné', wallet: 424242, quartier: 'Zorrobougou-Test', gps: '6.7311' };

function harness({ consent, scripts = {} } = {}) {
  const seed = {
    'clients/u': { name: PERSONAL.name, phone: PERSONAL.phone, wallet: PERSONAL.wallet },
    'ai_user_memory/u': { quartier: PERSONAL.quartier, addresses: [{ label: 'maison', address: PERSONAL.quartier }] },
    'orders/o1': { clientId: 'u', sellerName: 'Chez Awa', description: 'Colis-test-42', status: 'pending', budget: 2000, createdAt: { toDate: () => new Date('2026-01-01T00:00:00Z') } },
    'settings/ai': { defaultProvider: 'claude', allowedProviders: ['claude', 'gemini'], fallbackEnabled: true },
  };
  if (consent) seed['ai_consents/u'] = consent;
  const data = database(seed);
  const bodies = [], audits = [], counts = { claude: 0, gemini: 0 };
  const claude = new ClaudeProvider();
  claude.isConfigured = () => true;
  claude._getClient = () => ({ messages: { create: async (body) => {
    bodies.push(JSON.parse(JSON.stringify(body)));
    const value = (scripts.claude || [])[counts.claude++];
    assert.notEqual(value, undefined, 'unexpected Anthropic call');
    return { content: Array.isArray(value)
      ? value.map(c => ({ type: 'tool_use', id: c.id, name: c.name, input: c.input }))
      : [{ type: 'text', text: value }], usage: { input_tokens: 1, output_tokens: 1 } };
  } } });
  const gemini = new GeminiProvider();
  gemini.isConfigured = () => true;
  gemini.generateTurn = async () => { counts.gemini++; throw new Error('Gemini must not be called'); };
  const app = createAzIa({ db: data.db, admin, HttpsError, providers: { claude, gemini },
    onCall: (_o, handler) => handler, onSchedule: (_o, handler) => handler,
    checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, sendToToken: async () => {},
    axios: { post: async () => ({ data: {} }) },
    FEEXPAY_TOKEN: { value: () => 'x' }, FEEXPAY_API_URL: 'https://payment.invalid',
    WEBHOOK_URL: () => 'https://callback.invalid', feexpayOperatorCode: () => 'x',
  });
  const chat = (extra = {}, uid = 'u') => app.azIaChat({ auth: { uid }, data: { message: 'Bonjour, comment ça marche ?', ...extra } });
  const consentCall = (consentAction, extra = {}, uid = 'u') => app.azIaChat({ auth: { uid }, data: { consentAction, ...extra } });
  const touched = () => [...data.reads.keys()];
  return { ...data, bodies, audits, counts, chat, consentCall, touched, app };
}

const rejects = (promise, message) => assert.rejects(promise, (e) => e.code === 'failed-precondition' && e.message === message);
const noModelCall = (h) => { assert.equal(h.counts.claude, 0); assert.equal(h.counts.gemini, 0); assert.equal(h.bodies.length, 0); };
const OK = { granted: true, version: CONSENT_VERSION };

test('absence de consentement : refus CONSENT_REQUIRED, aucun appel Anthropic/Gemini, aucune lecture de données', async () => {
  const h = harness();
  await rejects(h.chat(), 'CONSENT_REQUIRED');
  noModelCall(h);
  assert.deepEqual(h.touched().filter(p => !p.startsWith('ai_consents/')), []);
  assert.ok(!h.writes.some(p => p.startsWith('ai_conversations')));
});

test('ancienne application (aucun champ de consentement) : bloquée pour AZ IA, y compris avec image et position', async () => {
  const h = harness();
  await rejects(h.chat({ imageBase64: 'Zml4dHVyZQ==', imageMediaType: 'image/png', location: { latitude: 6.7311, longitude: -3.49 } }), 'CONSENT_REQUIRED');
  noModelCall(h);
});

test('consentement accepté : état, audit, puis réponse du modèle', async () => {
  const h = harness({ scripts: { claude: ['Voici comment ça marche.'] } });
  const granted = await h.consentCall('grant', { consentVersion: CONSENT_VERSION });
  assert.deepEqual(granted.consent, { granted: true, version: CONSENT_VERSION });
  assert.deepEqual(h.store.get('ai_consents/u').providers, ['anthropic', 'google']);
  assert.equal(h.audits.at(-1).action, 'ai_consent_granted');
  noModelCall(h); // accepter n'envoie rien aux fournisseurs
  assert.equal((await h.consentCall('status')).consent.granted, true);
  const reply = await h.chat();
  assert.equal(reply.reply, 'Voici comment ça marche.');
  assert.equal(h.counts.claude, 1);
});

test('consentement refusé : respecté, aucun appel', async () => {
  const h = harness({ consent: { granted: false, version: CONSENT_VERSION } });
  assert.equal((await h.consentCall('status')).consent.granted, false);
  await rejects(h.chat(), 'CONSENT_REQUIRED');
  noModelCall(h);
});

test('consentement retiré : les messages suivants sont bloqués, audit enregistré', async () => {
  const h = harness({ scripts: { claude: ['ok'] } });
  await h.consentCall('grant', { consentVersion: CONSENT_VERSION });
  await h.chat();
  const callsBefore = h.counts.claude;
  const revoked = await h.consentCall('revoke');
  assert.equal(revoked.consent.granted, false);
  assert.equal(h.store.get('ai_consents/u').granted, false);
  assert.equal(h.audits.at(-1).action, 'ai_consent_revoked');
  await rejects(h.chat(), 'CONSENT_REQUIRED');
  assert.equal(h.counts.claude, callsBefore);
  assert.equal(h.counts.gemini, 0);
});

test('version de consentement périmée (serveur ou client) : refus', async () => {
  const stale = harness({ consent: { granted: true, version: CONSENT_VERSION - 1 } });
  await rejects(stale.chat(), 'CONSENT_REQUIRED');
  noModelCall(stale);
  const h = harness();
  await rejects(h.consentCall('grant', { consentVersion: CONSENT_VERSION + 1 }), 'APP_UPDATE_REQUIRED');
  await rejects(h.consentCall('grant'), 'APP_UPDATE_REQUIRED'); // version absente
  assert.equal(h.store.has('ai_consents/u'), false);
});

test('le consentement est lié au compte : un autre compte reste bloqué', async () => {
  const h = harness({ consent: OK });
  await rejects(h.chat({}, 'autre'), 'CONSENT_REQUIRED');
  noModelCall(h);
});

test('action de consentement inconnue et utilisateur non connecté : rejetés', async () => {
  const h = harness();
  await assert.rejects(h.consentCall('hack'), (e) => e.code === 'invalid-argument');
  await assert.rejects(h.app.azIaChat({ data: { message: 'x' } }), (e) => e.code === 'unauthenticated');
  noModelCall(h);
});

test("question générale : aucune donnée personnelle n'atteint le fournisseur", async () => {
  const h = harness({ consent: OK, scripts: { claude: ['Réponse générale.'] } });
  await h.chat({ message: 'Comment fonctionne la livraison ?', location: { latitude: 6.7311, longitude: -3.49, address: PERSONAL.quartier } });
  assert.equal(h.bodies.length, 1);
  const sent = JSON.stringify(h.bodies[0]);
  for (const v of Object.values(PERSONAL)) assert.ok(!sent.includes(String(v)), `fuite : ${v}`);
  assert.ok(!sent.includes('Colis-test-42'));
  assert.ok(!h.touched().includes('clients/u'));
  assert.ok(!h.touched().includes('ai_user_memory/u'));
  assert.ok(!h.touched().some(p => p.startsWith('orders/')));
});

test('rubrique demandée par le modèle : seule cette rubrique est transmise (GPS uniquement si demandé)', async () => {
  const h = harness({ consent: OK, scripts: { claude: [
    [{ id: 't1', name: 'get_user_context', input: { fields: ['location'] } }], 'Je vous localise.'] } });
  await h.chat({ message: 'Trouve une pharmacie près de moi', location: { latitude: 6.7311, longitude: -3.49 } });
  assert.equal(h.bodies.length, 2);
  assert.ok(!JSON.stringify(h.bodies[0]).includes('6.7311')); // pas de GPS avant la demande de l'outil
  const second = JSON.stringify(h.bodies[1]);
  assert.ok(second.includes('6.7311')); // GPS renvoyé car nécessaire
  for (const v of [PERSONAL.phone, PERSONAL.name, String(PERSONAL.wallet), PERSONAL.quartier]) assert.ok(!second.includes(v), v);
});

test('localisation non autorisée : la rubrique location ne renvoie aucune position', async () => {
  const h = harness({ consent: OK, scripts: { claude: [
    [{ id: 't1', name: 'get_user_context', input: { fields: ['location'] } }], 'Quelle adresse ?'] } });
  await h.chat({ message: 'Livre-moi quelque chose' });
  assert.ok(!JSON.stringify(h.bodies[1]).includes('6.7311'));
});

test("aucun autre chemin d'appel vers Anthropic ou Gemini hors de functions/azia", () => {
  const root = path.join(__dirname, '..');
  const offenders = [];
  const scan = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (dir === root && ['node_modules', 'test', 'scripts', 'azia'].includes(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { scan(full); continue; }
      if (!entry.name.endsWith('.js')) continue;
      const text = fs.readFileSync(full, 'utf8');
      if (/@anthropic-ai|generativelanguage\.googleapis|api\.anthropic\.com/.test(text)
        || /require\(['"]\.\/azia\/(providers|claudeClient|AIProviderService|aiGateway)/.test(text)) offenders.push(path.relative(root, full));
    }
  };
  scan(root);
  assert.deepEqual(offenders, []);
});

// ── Scénarios par fonctionnalité : seul ce qui sert la demande atteint le fournisseur ──
const toolTurn = (name, input) => [{ id: `t-${name}`, name, input }];

test('demande sur une commande : le suivi renvoie la commande, sans téléphone, solde, adresse ni GPS', async () => {
  const h = harness({ consent: OK, scripts: { claude: [toolTurn('track_order', {}), 'Votre commande est en cours.'] } });
  await h.chat({ message: 'Où en est ma commande ?', location: { latitude: 6.7311, longitude: -3.49 } });
  assert.equal(h.bodies.length, 2);
  const second = JSON.stringify(h.bodies[1]);
  assert.ok(second.includes('Colis-test-42'));
  for (const v of [PERSONAL.phone, String(PERSONAL.wallet), PERSONAL.quartier, '6.7311']) assert.ok(!second.includes(v), v);
});

test('demande sur le portefeuille : seul le solde est transmis, ni profil ni GPS', async () => {
  const h = harness({ consent: OK, scripts: { claude: [toolTurn('get_wallet_balance', {}), 'Votre solde est affiché.'] } });
  await h.chat({ message: 'Quel est mon solde ?', location: { latitude: 6.7311, longitude: -3.49 } });
  const second = JSON.stringify(h.bodies[1]);
  assert.ok(second.includes(String(PERSONAL.wallet)));
  for (const v of [PERSONAL.phone, PERSONAL.name, PERSONAL.quartier, '6.7311', 'Colis-test-42']) assert.ok(!second.includes(v), v);
});

test('demande nécessitant une adresse : seule la rubrique addresses est transmise', async () => {
  const h = harness({ consent: OK, scripts: { claude: [toolTurn('get_user_context', { fields: ['addresses'] }), 'Je livre chez vous.'] } });
  await h.chat({ message: 'Livre chez moi', location: { latitude: 6.7311, longitude: -3.49 } });
  const second = JSON.stringify(h.bodies[1]);
  assert.ok(second.includes(PERSONAL.quartier));
  for (const v of [PERSONAL.phone, PERSONAL.name, String(PERSONAL.wallet), '6.7311', 'Colis-test-42']) assert.ok(!second.includes(v), v);
});

test('rubriques inconnues demandées au modèle : rien de personnel renvoyé', async () => {
  const h = harness({ consent: OK, scripts: { claude: [toolTurn('get_user_context', { fields: ['wallet', 'password'] }), 'Impossible.'] } });
  await h.chat({ message: 'Donne-moi tout' });
  const second = JSON.stringify(h.bodies[1]);
  for (const v of [PERSONAL.phone, PERSONAL.name, String(PERSONAL.wallet), PERSONAL.quartier]) assert.ok(!second.includes(v), v);
});

test('retrait du consentement en cours de conversation : le message suivant ne touche ni données ni fournisseurs', async () => {
  const h = harness({ consent: OK, scripts: { claude: ['Bonjour !'] } });
  await h.chat();
  await h.consentCall('revoke');
  const bodiesBefore = h.bodies.length;
  const readsBefore = new Map(h.reads);
  await rejects(h.chat({ message: 'Et mon solde ?' }), 'CONSENT_REQUIRED');
  assert.equal(h.bodies.length, bodiesBefore);
  assert.equal(h.counts.gemini, 0);
  for (const [p, n] of h.reads) if (!p.startsWith('ai_consents/')) assert.equal(n, readsBefore.get(p) || 0, `lecture inattendue : ${p}`);
});
