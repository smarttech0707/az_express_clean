'use strict';

/**
 * Payout FeexPay V2 — machine d'états et idempotence financière.
 * 100 % hors ligne : le client HTTP est un bouchon, aucun appel réseau n'est
 * possible, et aucun secret réel n'est utilisé (jeton factice injecté).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  resolvePayoutEndpoint,
  sanitizePayoutMotif,
  applyPayoutStatus,
  PAYOUT_MOTIF_MAX_LENGTH,
} = require('../feexpayPayments');
const {
  createPayoutStatusVerifier,
  createFakePayoutVerifier,
  normalizePayoutStatus,
  isValidReference,
} = require('../feexpayVerification');

const SERVER_TS = '__ts__';
const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => SERVER_TS } } };
const collectionFor = (userType) => (userType === 'driver' ? 'livreurs' : 'clients');
const FAKE_TOKEN = 'jeton-de-test-non-sensible';

// Firestore en mémoire ; les transactions sont sérialisées comme le fait
// réellement Firestore, sans quoi la doublure testerait elle-même.
function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;
  const makeRef = (path) => ({
    id: path.split('/').pop(),
    path,
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
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

const seedWithdrawal = (over = {}, wallet = 0) => makeDb({
  'withdrawal_requests/WD1': {
    userId: 'u1', userType: 'client', amount: 2000, status: 'provider_pending',
    provider: 'feexpay', providerReference: 'REF-123', providerStatus: 'PENDING',
    settlementConfirmed: false, autoRetryBlocked: true, ...over,
  },
  'clients/u1': { wallet },
});
const apply = (db, verdict) => applyPayoutStatus({
  db, admin: fakeAdmin, withdrawId: 'WD1', verdict, collectionFor,
});
const wd = (db) => db.store.get('withdrawal_requests/WD1');
const wallet = (db) => db.store.get('clients/u1').wallet;

// Bouchon HTTP : enregistre l'appel, ne sort jamais du processus.
function fakeAxios(handler) {
  const calls = [];
  return {
    calls,
    get: async (url, config) => {
      calls.push({ url, config });
      return handler(url, config);
    },
  };
}

// ── 1. Initiation PENDING stockée comme non finale ──────────────────────────
test('1. une initiation PENDING n\'est jamais un état final', () => {
  const db = seedWithdrawal();
  assert.equal(wd(db).status, 'provider_pending');
  assert.equal(wd(db).settlementConfirmed, false);
  assert.equal(wd(db).autoRetryBlocked, true);
  assert.ok(wd(db).providerReference, 'une référence de suivi est conservée');
});

// ── 2-3. PENDING reste pending ──────────────────────────────────────────────
test('2. statut PENDING → reste en cours, aucun mouvement financier', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'pending', providerStatus: 'PENDING' });
  assert.equal(r.state, 'still_pending');
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).settlementConfirmed, false);
});

test('3. statut "IN PENDING STATE" → également en cours', async () => {
  assert.equal(normalizePayoutStatus('IN PENDING STATE'), 'pending');
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'pending', providerStatus: 'IN PENDING STATE' });
  assert.equal(r.state, 'still_pending');
  assert.equal(wallet(db), 500);
});

// ── 4. SUCCESSFUL finalise ──────────────────────────────────────────────────
test('4. SUCCESSFUL → finalisation, jamais de recrédit du wallet', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, {
    outcome: 'successful', providerStatus: 'SUCCESSFUL', reference: 'REF-123', amount: 2000,
    meta: { transref: 'T1', responsemsg: 'SUCCESSFUL' },
  });
  assert.equal(r.state, 'settled');
  assert.equal(wd(db).status, 'sent');
  assert.equal(wd(db).settlementConfirmed, true);
  assert.equal(wallet(db), 500, 'le solde ne bouge pas lors d\'un règlement réussi');
  assert.equal(wd(db).providerMeta.transref, 'T1');
});

// ── 5. FAILED compense exactement une fois ──────────────────────────────────
test('5. FAILED → compensation du wallet exactement une fois', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'failed', providerStatus: 'FAILED', reference: 'REF-123', amount: 2000 });
  assert.equal(r.state, 'compensated');
  assert.equal(wallet(db), 2500);
  assert.equal(wd(db).status, 'failed_refunded');
  assert.equal(wd(db).compensated, true);
});

// ── 6-8. Idempotence ────────────────────────────────────────────────────────
test('6. SUCCESSFUL répété → idempotent', async () => {
  const db = seedWithdrawal({}, 500);
  const v = { outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 };
  await apply(db, v);
  const second = await apply(db, v);
  assert.equal(second.state, 'already_successful');
  assert.equal(wallet(db), 500);
});

test('7. FAILED répété → un seul remboursement', async () => {
  const db = seedWithdrawal({}, 500);
  const v = { outcome: 'failed', providerStatus: 'FAILED', amount: 2000 };
  await apply(db, v);
  const second = await apply(db, v);
  assert.equal(second.state, 'already_compensated');
  assert.equal(wallet(db), 2500, 'jamais de double remboursement');
});

test('8. PENDING répété → aucun changement de solde', async () => {
  const db = seedWithdrawal({}, 500);
  for (let i = 0; i < 3; i++) await apply(db, { outcome: 'pending', providerStatus: 'PENDING' });
  assert.equal(wallet(db), 500);
});

// ── 9-12. Résultats non concluants : jamais de remboursement ────────────────
test('9. timeout de vérification → aucun remboursement', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'network_error', reason: 'no_response' });
  assert.equal(wallet(db), 500);
  assert.equal(r.state, 'unresolved_network_error');
});

test('10. HTTP 5xx de vérification → aucun remboursement', async () => {
  const axios = fakeAxios(async () => { const e = new Error('boom'); e.response = { status: 503 }; throw e; });
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const verdict = await verifier.checkPayoutStatus('REF-123');
  assert.equal(verdict.outcome, 'network_error');
  const db = seedWithdrawal({}, 500);
  await apply(db, verdict);
  assert.equal(wallet(db), 500);
});

test('11. JSON invalide → aucun remboursement', async () => {
  const axios = fakeAxios(async () => ({ data: 'ceci n\'est pas du JSON objet' }));
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const verdict = await verifier.checkPayoutStatus('REF-123');
  assert.equal(verdict.outcome, 'unknown');
  const db = seedWithdrawal({}, 500);
  await apply(db, verdict);
  assert.equal(wallet(db), 500);
});

test('12. statut inconnu → aucun remboursement, mise en revue', async () => {
  const db = seedWithdrawal({}, 500);
  await apply(db, { outcome: 'unknown', providerStatus: 'SOMETHING_NEW' });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).needsReview, true);
});

// ── 13-14. Cohérence référence et montant ───────────────────────────────────
test('13. référence différente → anomalie, aucun mouvement financier', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'failed', reference: 'AUTRE-REF', amount: 2000 });
  assert.equal(r.state, 'reference_mismatch');
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).needsReview, true);
});

test('14. montant différent → anomalie, aucun mouvement financier', async () => {
  const db = seedWithdrawal({}, 500);
  const r = await apply(db, { outcome: 'successful', reference: 'REF-123', amount: 999 });
  assert.equal(r.state, 'amount_mismatch');
  assert.equal(wd(db).settlementConfirmed, false);
  assert.equal(wallet(db), 500);
});

// ── 15-16. Validation des références ────────────────────────────────────────
test('15. référence vide refusée avant tout appel réseau', async () => {
  const axios = fakeAxios(async () => ({ data: {} }));
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const r = await verifier.checkPayoutStatus('');
  assert.equal(r.outcome, 'invalid_reference');
  assert.equal(axios.calls.length, 0, 'aucun appel ne doit partir');
});

test('16. référence malformée refusée (injection de chemin)', async () => {
  const axios = fakeAxios(async () => ({ data: {} }));
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  for (const bad of ['../../admin', 'a b', 'x', null, 'ref?token=1']) {
    const r = await verifier.checkPayoutStatus(bad);
    assert.equal(r.outcome, 'invalid_reference', `référence acceptée à tort : ${bad}`);
  }
  assert.equal(axios.calls.length, 0);
  assert.equal(isValidReference('REF-123'), true);
});

// ── 17. Opérateurs ──────────────────────────────────────────────────────────
test('17. opérateur inconnu refusé, opérateurs documentés acceptés', () => {
  assert.equal(resolvePayoutEndpoint('bitcoin').ok, false);
  assert.equal(resolvePayoutEndpoint('').ok, false);
  assert.equal(resolvePayoutEndpoint(undefined).ok, false);
  const expected = { mtn: 'mtn_ci', orange: 'orange_ci', moov: 'moov_ci', wave: 'wave_ci' };
  for (const [operator, slug] of Object.entries(expected)) {
    const r = resolvePayoutEndpoint(operator);
    assert.equal(r.ok, true);
    assert.equal(r.url, `https://api-v2.feexpay.me/api/payouts/public/${slug}`);
  }
});

// ── 18, 24. Secret jamais exposé ────────────────────────────────────────────
test('18/24. le jeton n\'apparaît ni dans l\'URL ni dans une erreur remontée', async () => {
  const axios = fakeAxios(async () => { const e = new Error(`échec avec ${FAKE_TOKEN}`); e.response = { status: 500 }; throw e; });
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const r = await verifier.checkPayoutStatus('REF-123');
  assert.ok(!JSON.stringify(r).includes(FAKE_TOKEN), 'le jeton ne doit jamais ressortir');
  assert.ok(!axios.calls[0].url.includes(FAKE_TOKEN), 'jamais de jeton dans l\'URL');
  // Le secret est injecté, jamais codé en dur dans le module.
  const fs = require('node:fs');
  const source = fs.readFileSync(require.resolve('../feexpayVerification'), 'utf8');
  assert.ok(!source.includes(FAKE_TOKEN));
});

// ── 19-20. Contradictions détectées, jamais de mouvement silencieux ─────────
test('19. FAILED après SUCCESSFUL → incohérence signalée, aucun remboursement', async () => {
  const db = seedWithdrawal({ settlementConfirmed: true, status: 'sent' }, 500);
  const events = [];
  const r = await applyPayoutStatus({
    db, admin: fakeAdmin, withdrawId: 'WD1', collectionFor,
    verdict: { outcome: 'failed', providerStatus: 'FAILED', amount: 2000 },
    logSecurityEvent: async (...a) => events.push(a),
  });
  assert.equal(r.state, 'inconsistent_failed_after_success');
  assert.equal(wallet(db), 500, 'aucun remboursement après un règlement confirmé');
  assert.equal(events[0][1], 'payout_failed_after_success');
});

test('20. SUCCESSFUL après FAILED compensé → incohérence signalée, aucun redébit', async () => {
  const db = seedWithdrawal({ compensated: true, status: 'failed_refunded' }, 2500);
  const events = [];
  const r = await applyPayoutStatus({
    db, admin: fakeAdmin, withdrawId: 'WD1', collectionFor,
    verdict: { outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 },
    logSecurityEvent: async (...a) => events.push(a),
  });
  assert.equal(r.state, 'inconsistent_success_after_refund');
  assert.equal(wallet(db), 2500, 'aucun redébit silencieux');
  assert.equal(events[0][1], 'payout_success_after_refund');
});

// ── 21-22. Concurrence ──────────────────────────────────────────────────────
test('21. deux vérifications FAILED concurrentes → une seule compensation', async () => {
  const db = seedWithdrawal({}, 500);
  const v = { outcome: 'failed', providerStatus: 'FAILED', amount: 2000 };
  const results = await Promise.all([apply(db, v), apply(db, v)]);
  assert.equal(results.filter((r) => r.state === 'compensated').length, 1);
  assert.equal(wallet(db), 2500);
});

test('22. deux vérifications SUCCESSFUL concurrentes → une seule finalisation', async () => {
  const db = seedWithdrawal({}, 500);
  const v = { outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 };
  const results = await Promise.all([apply(db, v), apply(db, v)]);
  assert.equal(results.filter((r) => r.state === 'settled').length, 1);
  assert.equal(wallet(db), 500);
});

// ── 23. Construction de l'appel de statut ───────────────────────────────────
test('23. l\'endpoint de statut documenté est correctement construit', async () => {
  const axios = fakeAxios(async () => ({
    data: { reference: 'REF-123', status: 'SUCCESSFUL', amount: 2000, transref: 'T9' },
  }));
  const verifier = createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN });
  const r = await verifier.checkPayoutStatus('REF-123');
  assert.equal(axios.calls[0].url,
    'https://api-v2.feexpay.me/api/payouts/status/public/REF-123');
  assert.equal(axios.calls[0].config.headers.Authorization, `Bearer ${FAKE_TOKEN}`);
  assert.ok(axios.calls[0].config.timeout > 0, 'un délai d\'expiration est imposé');
  assert.equal(r.outcome, 'successful');
  assert.equal(r.amount, 2000);
  assert.equal(r.meta.transref, 'T9');
});

// ── Motif documenté : obligatoire, ≤ 30 caractères, sans caractère spécial ──
test('motif normalisé selon la documentation (30 max, sans caractère spécial)', () => {
  const motif = sanitizePayoutMotif('Retrait AZ Express WD_1758000000000_abcdef01 #@!');
  assert.ok(motif.length <= PAYOUT_MOTIF_MAX_LENGTH);
  assert.ok(/^[A-Za-z0-9 ]+$/.test(motif), `caractère spécial résiduel : ${motif}`);
  assert.equal(sanitizePayoutMotif(''), 'Retrait AZ Express');
});

// ── Garde-fou global : aucun appel réseau réel possible ─────────────────────
test('le vérificateur exige un client HTTP injecté (aucun réseau par défaut)', () => {
  assert.equal(createPayoutStatusVerifier({ token: () => FAKE_TOKEN }), null);
  assert.equal(createPayoutStatusVerifier({ axios: {} }), null);
});
