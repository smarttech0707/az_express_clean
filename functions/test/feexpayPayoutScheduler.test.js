'use strict';

/**
 * Vérification automatique des retraits FeexPay — 100 % hors ligne.
 * Le client HTTP est un bouchon : aucun appel réseau n'est possible, aucun
 * secret réel n'est utilisé, et aucune initiation de payout n'est jamais
 * déclenchée (un test le vérifie explicitement).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  STATUS_CHECK_DELAYS_MINUTES,
  MAX_STATUS_CHECKS,
  MAX_TRACKING_AGE_MS,
  ELIGIBLE_STATUSES,
  delayMsForCheck,
  planNextCheck,
  verifyAndApplyWithdrawal,
  runPendingWithdrawalCheck,
} = require('../feexpayPayoutScheduler');
const { assertWithdrawalCanStart } = require('../feexpayPayments');
const { createPayoutStatusVerifier, createFakePayoutVerifier } = require('../feexpayVerification');

const FAKE_TOKEN = 'jeton-de-test-non-sensible';
const FAKE_SHOP = 'shop-de-test';
const NOW = 1_800_000_000_000;
const MINUTE = 60 * 1000;
const collectionFor = (userType) => (userType === 'driver' ? 'livreurs' : 'clients');

const ts = (ms) => ({ toMillis: () => ms, toDate: () => new Date(ms) });
const fakeAdmin = {
  firestore: {
    FieldValue: { serverTimestamp: () => '__ts__' },
    Timestamp: { fromMillis: (ms) => ts(ms) },
  },
};

// Firestore en mémoire, transactions sérialisées comme le fait réellement
// Firestore, et requêtes filtrées en JS pour refléter la requête du planificateur.
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
  const makeCollection = (base) => {
    const filters = [];
    let max = Infinity;
    const api = {
      doc: (id) => makeRef(`${base}/${id || `auto_${++autoId}`}`),
      where: (field, op, value) => { filters.push([field, op, value]); return api; },
      orderBy: () => api,
      limit: (n) => { max = n; return api; },
      get: async () => {
        const docs = [...store.entries()]
          .filter(([path]) => path.startsWith(`${base}/`) && path.split('/').length === base.split('/').length + 1)
          .filter(([, data]) => filters.every(([field, op, value]) => {
            const actual = data[field];
            if (op === 'in') return value.includes(actual);
            if (op === '<=') {
              const ms = actual && typeof actual.toMillis === 'function' ? actual.toMillis() : actual;
              return ms != null && ms <= (value.toMillis ? value.toMillis() : value);
            }
            return actual === value;
          }))
          .slice(0, max)
          .map(([path, data]) => ({ id: path.split('/').pop(), data: () => data }));
        return { docs };
      },
    };
    return api;
  };
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

const seedPending = (over = {}, walletStart = 500) => makeDb({
  'withdrawal_requests/WD1': {
    userId: 'u1', userType: 'client', amount: 2000, status: 'provider_pending',
    provider: 'feexpay', providerReference: 'REF-123', providerStatus: 'PENDING',
    settlementConfirmed: false, autoRetryBlocked: true,
    statusCheckCount: 0, statusCheckStopped: false,
    createdAt: ts(NOW - 10 * MINUTE), nextStatusCheckAt: ts(NOW - MINUTE),
    ...over,
  },
  'clients/u1': { wallet: walletStart },
});
const wd = (db) => db.store.get('withdrawal_requests/WD1');
const wallet = (db) => db.store.get('clients/u1').wallet;

const verifierFor = (verdict) => createFakePayoutVerifier(async () => verdict);
const runOnce = (db, verdict, over = {}) => runPendingWithdrawalCheck({
  db, admin: fakeAdmin, collectionFor, nowMs: NOW,
  createVerifier: () => verifierFor(verdict), ...over,
});

// ── 1. Shop ID absent → refus AVANT tout débit ──────────────────────────────
test('1. shop absent → refus avant débit (aucune initiation possible)', () => {
  const r = assertWithdrawalCanStart({ operator: 'wave', shopId: '' });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'shop_id_missing');
  assert.equal(r.code, 'failed-precondition');
  assert.equal(assertWithdrawalCanStart({ operator: 'wave', shopId: '   ' }).ok, false);
  assert.equal(assertWithdrawalCanStart({ operator: 'wave', shopId: undefined }).ok, false);
});

test('1b. shop présent + opérateur connu → initiation autorisée', () => {
  const r = assertWithdrawalCanStart({ operator: 'orange', shopId: FAKE_SHOP });
  assert.equal(r.ok, true);
  assert.equal(r.endpoint.url, 'https://api-v2.feexpay.me/api/payouts/public/orange_ci');
});

test('1c. opérateur inconnu refusé même avec un shop valide', () => {
  assert.equal(assertWithdrawalCanStart({ operator: 'bitcoin', shopId: FAKE_SHOP }).reason, 'unknown_operator');
});

// ── 2-5. Transitions depuis provider_pending ────────────────────────────────
test('2. provider_pending → SUCCESSFUL : réglé, suivi arrêté, wallet intact', async () => {
  const db = seedPending();
  const s = await runOnce(db, { outcome: 'successful', providerStatus: 'SUCCESSFUL', reference: 'REF-123', amount: 2000 });
  assert.equal(s.settled, 1);
  assert.equal(wd(db).status, 'sent');
  assert.equal(wd(db).settlementConfirmed, true);
  assert.equal(wallet(db), 500, 'un règlement réussi ne recrédite jamais le wallet');
  assert.equal(wd(db).statusCheckStopped, true);
  assert.equal(wd(db).nextStatusCheckAt, null);
});

test('3. provider_pending → FAILED : compensé une fois, suivi arrêté', async () => {
  const db = seedPending();
  const s = await runOnce(db, { outcome: 'failed', providerStatus: 'FAILED', reference: 'REF-123', amount: 2000 });
  assert.equal(s.compensated, 1);
  assert.equal(wallet(db), 2500);
  assert.equal(wd(db).status, 'failed_refunded');
  assert.equal(wd(db).statusCheckStopped, true);
});

test('4. provider_pending → PENDING : rien ne bouge, nouvelle vérification programmée', async () => {
  const db = seedPending();
  await runOnce(db, { outcome: 'pending', providerStatus: 'PENDING' });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).statusCheckCount, 1);
  assert.equal(wd(db).statusCheckStopped, false);
  assert.ok(wd(db).nextStatusCheckAt.toMillis() > NOW, 'la prochaine vérification est dans le futur');
});

test('5. IN PENDING STATE traité comme en cours', async () => {
  const db = seedPending();
  await runOnce(db, { outcome: 'pending', providerStatus: 'IN PENDING STATE' });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).status, 'provider_pending');
});

// ── 6-9. Résultats non concluants : jamais de mouvement ─────────────────────
for (const [label, verdict] of [
  ['6. timeout', { outcome: 'network_error', reason: 'no_response' }],
  ['7. HTTP 5xx', { outcome: 'network_error', reason: 'http_502' }],
  ['8. JSON invalide', { outcome: 'unknown', reason: 'unparsable_payload' }],
  ['9. statut inconnu', { outcome: 'unknown', providerStatus: 'SOMETHING_NEW' }],
]) {
  test(`${label} → aucun remboursement, aucune finalisation`, async () => {
    const db = seedPending();
    await runOnce(db, verdict);
    assert.equal(wallet(db), 500);
    assert.equal(wd(db).settlementConfirmed, false);
    assert.notEqual(wd(db).status, 'failed_refunded');
    assert.ok(wd(db).nextStatusCheckAt.toMillis() > NOW, 'une reprise prudente est programmée');
  });
}

// ── 10-11. Cohérence montant / référence ────────────────────────────────────
test('10. montant différent → anomalie, aucun mouvement financier', async () => {
  const db = seedPending();
  await runOnce(db, { outcome: 'successful', reference: 'REF-123', amount: 999 });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).needsReview, true);
  assert.equal(wd(db).settlementConfirmed, false);
});

test('11. référence différente → anomalie, aucun mouvement financier', async () => {
  const db = seedPending();
  await runOnce(db, { outcome: 'failed', reference: 'AUTRE', amount: 2000 });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).anomaly, 'reference_mismatch');
  assert.equal(wd(db).statusCheckStopped, true, 'on cesse d\'interroger : intervention humaine requise');
});

// ── 12-13. Concurrence ──────────────────────────────────────────────────────
test('12. double exécution du planificateur → une seule compensation', async () => {
  const db = seedPending();
  const verdict = { outcome: 'failed', providerStatus: 'FAILED', reference: 'REF-123', amount: 2000 };
  const [a, b] = await Promise.all([runOnce(db, verdict), runOnce(db, verdict)]);
  assert.equal(a.compensated + b.compensated, 1, 'une seule compensation sur deux exécutions');
  assert.equal(wallet(db), 2500);
});

test('13. deux vérifications concurrentes SUCCESSFUL → une seule finalisation', async () => {
  const db = seedPending();
  const verifier = verifierFor({ outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 });
  const call = () => verifyAndApplyWithdrawal({
    db, admin: fakeAdmin, withdrawId: 'WD1', data: wd(db), verifier, collectionFor, nowMs: NOW,
  });
  const results = await Promise.all([call(), call()]);
  assert.equal(results.filter((r) => r.state === 'settled').length, 1);
  assert.equal(wallet(db), 500);
});

// ── 14-17. Idempotence et contradictions ────────────────────────────────────
test('14. SUCCESSFUL reçu deux fois → idempotent', async () => {
  const db = seedPending();
  const v = { outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 };
  await runOnce(db, v);
  db.store.set('withdrawal_requests/WD1', { ...wd(db), status: 'provider_pending', nextStatusCheckAt: ts(NOW - MINUTE) });
  await runOnce(db, v);
  assert.equal(wallet(db), 500);
});

test('15. FAILED reçu deux fois → un seul remboursement', async () => {
  const db = seedPending();
  const v = { outcome: 'failed', providerStatus: 'FAILED', amount: 2000 };
  await runOnce(db, v);
  db.store.set('withdrawal_requests/WD1', { ...wd(db), status: 'pending_manual', nextStatusCheckAt: ts(NOW - MINUTE) });
  await runOnce(db, v);
  assert.equal(wallet(db), 2500, 'jamais de double remboursement');
});

test('16. FAILED après SUCCESSFUL → incohérence signalée, aucun remboursement', async () => {
  const db = seedPending({ settlementConfirmed: true, status: 'pending_manual' }, 500);
  const events = [];
  await runOnce(db, { outcome: 'failed', providerStatus: 'FAILED', amount: 2000 },
    { logSecurityEvent: async (...a) => events.push(a) });
  assert.equal(wallet(db), 500);
  assert.equal(events.length, 0, 'le retrait déjà final est ignoré avant tout appel');
});

test('17. SUCCESSFUL après compensation → aucun redébit', async () => {
  const db = seedPending({ compensated: true, status: 'pending_manual' }, 2500);
  await runOnce(db, { outcome: 'successful', providerStatus: 'SUCCESSFUL', amount: 2000 });
  assert.equal(wallet(db), 2500);
});

// ── 18-21. Éligibilité et bornes ────────────────────────────────────────────
test('18. retrait sans référence ignoré par l\'automatisation', async () => {
  const db = seedPending({ providerReference: null });
  const s = await runOnce(db, { outcome: 'successful', amount: 2000 });
  assert.equal(s.checked, 0);
  assert.equal(s.skipped, 1);
  assert.equal(wallet(db), 500);
});

test('19. retrait déjà finalisé ignoré (sent / failed_refunded hors périmètre)', async () => {
  const db = seedPending({ status: 'sent', settlementConfirmed: true });
  const s = await runOnce(db, { outcome: 'failed', amount: 2000 });
  assert.equal(s.scanned, 0, 'un état final n\'est jamais réinterrogé');
  assert.equal(wallet(db), 500);
  assert.ok(!ELIGIBLE_STATUSES.includes('sent'));
  assert.ok(!ELIGIBLE_STATUSES.includes('failed_refunded'));
});

test('20. backoff respecté : espacement croissant, plafonné', () => {
  assert.equal(delayMsForCheck(0), 3 * MINUTE);
  assert.equal(delayMsForCheck(1), 5 * MINUTE);
  for (let i = 1; i < STATUS_CHECK_DELAYS_MINUTES.length; i++) {
    assert.ok(delayMsForCheck(i) >= delayMsForCheck(i - 1), 'le délai ne diminue jamais');
  }
  assert.equal(delayMsForCheck(999), delayMsForCheck(STATUS_CHECK_DELAYS_MINUTES.length - 1));
  assert.equal(planNextCheck({ checkCount: MAX_STATUS_CHECKS, createdAtMs: NOW, nowMs: NOW }).exhausted, true);
  assert.equal(
    planNextCheck({ checkCount: 1, createdAtMs: NOW - MAX_TRACKING_AGE_MS - 1, nowMs: NOW }).reason,
    'max_age_reached',
  );
});

test('20b. plafond atteint → bascule en revue manuelle, sans mouvement financier', async () => {
  const db = seedPending({ statusCheckCount: MAX_STATUS_CHECKS });
  await runOnce(db, { outcome: 'pending', providerStatus: 'PENDING' });
  assert.equal(wallet(db), 500);
  assert.equal(wd(db).status, 'pending_manual');
  assert.equal(wd(db).needsReview, true);
  assert.equal(wd(db).statusCheckStopped, true);
});

test('21. retrait pas encore éligible ignoré (prochaine vérification future)', async () => {
  const db = seedPending({ nextStatusCheckAt: ts(NOW + 30 * MINUTE) });
  const s = await runOnce(db, { outcome: 'failed', amount: 2000 });
  assert.equal(s.scanned, 0);
  assert.equal(wallet(db), 500);
});

// ── 22-23. Aucune ré-initiation, aucun secret exposé ────────────────────────
test('22. aucune ré-initiation de payout : seul l\'endpoint de STATUT est appelé', async () => {
  const calls = [];
  const axios = {
    get: async (url) => { calls.push(['GET', url]); return { data: { reference: 'REF-123', status: 'PENDING' } }; },
    post: async (url) => { calls.push(['POST', url]); throw new Error('aucune initiation ne doit être déclenchée'); },
  };
  const db = seedPending();
  await runPendingWithdrawalCheck({
    db, admin: fakeAdmin, collectionFor, nowMs: NOW,
    createVerifier: () => createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN }),
  });
  assert.equal(calls.filter(([method]) => method === 'POST').length, 0, 'aucun POST payout');
  assert.equal(calls[0][0], 'GET');
  assert.ok(calls[0][1].includes('/api/payouts/status/public/'));
});

test('23. aucun secret dans les journaux ni dans les erreurs', async () => {
  const logs = [];
  const axios = {
    get: async () => { const e = new Error(`échec ${FAKE_TOKEN}`); e.response = { status: 500 }; throw e; },
  };
  const db = seedPending();
  await runPendingWithdrawalCheck({
    db, admin: fakeAdmin, collectionFor, nowMs: NOW,
    createVerifier: () => createPayoutStatusVerifier({ axios, token: () => FAKE_TOKEN }),
    log: (message) => logs.push(message),
  });
  const everything = JSON.stringify({ logs, doc: wd(db) });
  assert.ok(!everything.includes(FAKE_TOKEN), 'le jeton ne doit jamais être journalisé ni stocké');
  assert.ok(!logs.join(' ').includes('REF-123'), 'aucune référence fournisseur dans les journaux');
});

test('24. vérificateur non configuré → aucun appel, aucun mouvement', async () => {
  const db = seedPending();
  const s = await runPendingWithdrawalCheck({
    db, admin: fakeAdmin, collectionFor, nowMs: NOW, createVerifier: () => null,
  });
  assert.equal(s.checked, 0);
  assert.equal(wallet(db), 500);
});
