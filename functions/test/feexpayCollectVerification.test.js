'use strict';

/**
 * Collecte FeexPay — la vérification serveur est OBLIGATOIRE (fail closed).
 *
 * Le webhook n'est qu'une notification : même annonçant SUCCESSFUL avec le
 * montant exact, il ne doit JAMAIS suffire à créditer un wallet. La seule
 * source de vérité est
 *   GET /api/transactions/public/single/status/{reference}
 *
 * 100 % hors ligne : client HTTP bouchonné, jeton factice, aucun appel réel.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { processFeexPayWebhookEvent } = require('../feexpayPayments');
const {
  createStatusVerifier,
  createFakeVerifier,
  normalizeAmount,
  TRANSACTION_STATUS_PATH,
} = require('../feexpayVerification');

const FAKE_TOKEN = 'jeton-de-test-non-sensible';
const SERVER_TS = '__ts__';
const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => SERVER_TS } } };
const collectionFor = () => 'clients';
const HOUR = 3600 * 1000;
const NOW = 1_800_000_000_000;

function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;
  const makeRef = (path) => ({
    id: path.split('/').pop(),
    path,
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
    set: async (data) => { store.set(path, data); },
    update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
    collection: (sub) => makeCollection(`${path}/${sub}`),
  });
  const makeCollection = (base) => ({ doc: (id) => makeRef(`${base}/${id || `auto_${++autoId}`}`) });
  let queue = Promise.resolve();
  return {
    store,
    collection: makeCollection,
    runTransaction: (fn) => {
      const result = queue.then(() => fn({
        get: async (ref) => ref.get(),
        set: (ref, data) => store.set(ref.path, data),
        update: (ref, data) => store.set(ref.path, { ...(store.get(ref.path) || {}), ...data }),
      }));
      queue = result.catch(() => {});
      return result;
    },
  };
}

const seed = (over = {}) => makeDb({
  'wallet_transactions/TXa1B2c3D4e5F6g7H8i9': {
    userId: 'u1', userType: 'client', amount: 1000, status: 'pending',
    paymentMethod: 'mtn', provider: 'FeexPay', credited: false,
    createdAt: { toDate: () => new Date(NOW - HOUR) }, ...over,
  },
  'clients/u1': { wallet: 0 },
});
const wallet = (db) => db.store.get('clients/u1').wallet;
const tx = (db) => db.store.get('wallet_transactions/TXa1B2c3D4e5F6g7H8i9');

// Webhook annonçant un succès parfait : montant exact, statut SUCCESSFUL.
const PERFECT_WEBHOOK = { order_id: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 1000 };

const run = (db, body, extra = {}) => processFeexPayWebhookEvent({
  db, admin: fakeAdmin, body, nowMs: NOW, collectionFor, ...extra,
});
// Bouchon HTTP : enregistre les appels, ne sort jamais du processus.
function fakeAxios(handler) {
  const calls = [];
  return { calls, get: async (url, config) => { calls.push({ url, config }); return handler(url, config); } };
}
const verifierReturning = (result) => createFakeVerifier(async () => result);

// ── MATRICE OFFICIELLE : webhook | vérification | résultat ─────────────────

test('SUCCESSFUL | SUCCESSFUL + ref/montant OK → crédit unique', async () => {
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, { verifier: verifierReturning({ confirmed: true, amount: 1000 }) });
  assert.equal(r.outcome, 'credited');
  assert.equal(wallet(db), 1000);
  assert.equal(tx(db).independentlyVerified, true);
});

test('SUCCESSFUL | PENDING → aucun crédit', async () => {
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, { verifier: verifierReturning({ confirmed: false, reason: 'status:PENDING' }) });
  assert.equal(r.outcome, 'verification_failed');
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | FAILED → aucun crédit', async () => {
  const db = seed();
  await run(db, PERFECT_WEBHOOK, { verifier: verifierReturning({ confirmed: false, reason: 'status:FAILED' }) });
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | erreur réseau → aucun crédit', async () => {
  const axios = fakeAxios(async () => { const e = new Error('timeout'); e.request = {}; throw e; });
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.outcome, 'verification_failed');
  assert.equal(r.reason, 'verification_unavailable');
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | 5xx → aucun crédit', async () => {
  const axios = fakeAxios(async () => { const e = new Error('boom'); e.response = { status: 502 }; throw e; });
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.reason, 'verification_http_502');
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | JSON invalide → aucun crédit', async () => {
  for (const payload of ['pas du json', [], null, 42]) {
    const axios = fakeAxios(async () => ({ data: payload }));
    const db = seed();
    const r = await run(db, PERFECT_WEBHOOK, {
      verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
    });
    assert.equal(wallet(db), 0, `crédit accordé à tort pour ${JSON.stringify(payload)}`);
    assert.equal(r.outcome, 'verification_failed');
  }
});

test('SUCCESSFUL | référence différente → aucun crédit', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'AUTRE-REF', status: 'SUCCESSFUL', amount: 1000 } }));
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.reason, 'reference_mismatch');
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | montant différent → aucun crédit', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 100 } }));
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.reason, 'amount_mismatch');
  assert.equal(wallet(db), 0);
});

test('SUCCESSFUL | vérificateur ABSENT → aucun crédit (fail closed)', async () => {
  const db = seed();
  const events = [];
  const r = await run(db, PERFECT_WEBHOOK, { logSecurityEvent: async (...a) => events.push(a) });
  assert.equal(r.outcome, 'verification_unavailable');
  assert.equal(r.httpStatus, 503);
  assert.equal(wallet(db), 0, 'aucun crédit sans vérification serveur');
  assert.equal(events[0][1], 'webhook_verifier_unavailable');
});

test('SUCCESSFUL | vérificateur malformé (sans confirmPayment) → aucun crédit', async () => {
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, { verifier: {} });
  assert.equal(r.outcome, 'verification_unavailable');
  assert.equal(wallet(db), 0);
});

test('PENDING (webhook) | n\'importe quoi → aucun crédit définitif', async () => {
  const db = seed();
  const r = await run(db, { order_id: 'TXa1B2c3D4e5F6g7H8i9', status: 'PENDING', amount: 1000 },
    { verifier: verifierReturning({ confirmed: true, amount: 1000 }) });
  assert.equal(r.outcome, 'unknown_status');
  assert.equal(wallet(db), 0);
  assert.equal(tx(db).status, 'pending');
});

test('FAILED (webhook) | n\'importe quoi → aucun crédit', async () => {
  const db = seed();
  await run(db, { order_id: 'TXa1B2c3D4e5F6g7H8i9', status: 'FAILED' },
    { verifier: verifierReturning({ confirmed: true, amount: 1000 }) });
  assert.equal(wallet(db), 0);
  assert.equal(tx(db).status, 'failed');
});

// ── Idempotence et concurrence, vérification comprise ──────────────────────
test('webhook dupliqué vérifié → un seul crédit', async () => {
  const db = seed();
  const verifier = verifierReturning({ confirmed: true, amount: 1000 });
  await run(db, PERFECT_WEBHOOK, { verifier });
  const second = await run(db, PERFECT_WEBHOOK, { verifier });
  assert.equal(second.outcome, 'already_processed');
  assert.equal(wallet(db), 1000);
});

test('deux webhooks vérifiés concurrents → un seul crédit', async () => {
  const db = seed();
  const verifier = verifierReturning({ confirmed: true, amount: 1000 });
  const results = await Promise.all([
    run(db, PERFECT_WEBHOOK, { verifier }), run(db, PERFECT_WEBHOOK, { verifier }),
  ]);
  assert.equal(results.filter((r) => r.outcome === 'credited').length, 1);
  assert.equal(wallet(db), 1000);
});

// ── Contrôle défensif du montant ───────────────────────────────────────────
test('montant non numérique ou ambigu jamais accepté', () => {
  for (const bad of [null, undefined, true, false, {}, [], 'abc', '', '1e3', NaN, Infinity, '12,5,6']) {
    assert.equal(normalizeAmount(bad), null, `valeur acceptée à tort : ${JSON.stringify(bad)}`);
  }
  assert.equal(normalizeAmount(1000), 1000);
  assert.equal(normalizeAmount('1000'), 1000);
  assert.equal(normalizeAmount('1 000,00'), 1000);
});

test('montant vérifié illisible → aucun crédit', async () => {
  for (const bad of [null, 'abc', true, {}]) {
    const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: bad } }));
    const db = seed();
    const r = await run(db, PERFECT_WEBHOOK, {
      verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
    });
    assert.equal(r.reason, 'amount_unreadable', `montant ${JSON.stringify(bad)} accepté à tort`);
    assert.equal(wallet(db), 0);
  }
});

test('comparaison stricte : 1000 attendu ≠ 1000.4 vérifié n\'est pas un crédit fortuit', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 1000 } }));
  const db = seed({ amount: 999 });
  const r = await run(db, { order_id: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL' }, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.reason, 'amount_mismatch');
  assert.equal(wallet(db), 0);
});

// ── Champs non décisionnels : jamais des préconditions ─────────────────────
test('une réponse SUCCESSFUL minimale (reference/amount/status) suffit', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 1000 } }));
  const db = seed();
  const r = await run(db, PERFECT_WEBHOOK, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.outcome, 'credited', 'aucun champ optionnel ne doit être exigé');
  assert.equal(wallet(db), 1000);
});

test('aucune devise n\'est exigée (FeexPay n\'en fournit pas)', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 1000 } }));
  const db = seed();
  const r = await run(db, { order_id: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL' }, {
    verifier: createStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(r.outcome, 'credited');
});

// ── Construction de l'appel et confidentialité ─────────────────────────────
test('endpoint officiel, Authorization serveur, timeout, aucune fuite de jeton', async () => {
  const axios = fakeAxios(async () => ({ data: { reference: 'TXa1B2c3D4e5F6g7H8i9', status: 'SUCCESSFUL', amount: 1000 } }));
  const verifier = createStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const confirmation = await verifier.confirmPayment({ txId: 'TXa1B2c3D4e5F6g7H8i9', expectedAmount: 1000 });
  assert.equal(confirmation.confirmed, true);
  assert.equal(axios.calls[0].url,
    `https://api-v2.feexpay.me${TRANSACTION_STATUS_PATH}/TXa1B2c3D4e5F6g7H8i9`);
  assert.equal(axios.calls[0].config.headers.Authorization, `Bearer ${FAKE_TOKEN}`);
  assert.ok(axios.calls[0].config.timeout > 0);
  assert.ok(!JSON.stringify(confirmation).includes(FAKE_TOKEN));
});

test('référence malformée refusée avant tout appel réseau', async () => {
  const axios = fakeAxios(async () => ({ data: {} }));
  const verifier = createStatusVerifier({ axios, token: () => FAKE_TOKEN });
  for (const bad of ['', '../admin', 'a b', null, 'x']) {
    const r = await verifier.confirmPayment({ txId: bad, expectedAmount: 1000 });
    assert.equal(r.confirmed, false);
  }
  assert.equal(axios.calls.length, 0);
});

test('le vérificateur exige un client HTTP ET un jeton injectés', () => {
  assert.equal(createStatusVerifier({ token: () => FAKE_TOKEN }), null);
  assert.equal(createStatusVerifier({ axios: {} }), null);
  assert.equal(createStatusVerifier(), null);
});
