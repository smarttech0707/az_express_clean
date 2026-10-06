'use strict';

/**
 * Tests de régression du parcours financier FeexPay — 100 % hors ligne.
 * Aucun appel réseau, aucun secret réel : Firestore est une doublure en
 * mémoire et FeexPay n'est jamais contacté (voir aussi le garde-fou
 * "aucun appel réseau" en fin de fichier).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyPaymentStatus,
  extractTransactionId,
  isAuthorizedWebhookCall,
  verifyPaidAmount,
  classifyPayoutInitiation,
  processFeexPayWebhookEvent,
  compensateFailedWithdrawal,
} = require('../feexpayPayments');
const { createStatusVerifier, createFakeVerifier } = require('../feexpayVerification');

// ── Doublures ───────────────────────────────────────────────────────────────
const SERVER_TS = '__server_ts__';
const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => SERVER_TS } } };
const collectionFor = (userType) => (userType === 'driver' ? 'livreurs' : 'clients');

// Firestore en mémoire : la référence conserve son chemin complet, ce qui
// permet aux écritures transactionnelles de viser le bon document.
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

  // Firestore sérialise réellement les transactions concurrentes (le résultat
  // net équivaut toujours à un ordre séquentiel). Sans modéliser cette
  // garantie, une doublure naïve laisserait passer deux crédits et testerait
  // la doublure plutôt que le code. On enchaîne donc les transactions.
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

const HOUR = 3600 * 1000;
const NOW = 1_800_000_000_000;
const freshTx = (over = {}) => ({
  userId: 'u1', userType: 'client', amount: 1000, status: 'pending',
  paymentMethod: 'mtn', provider: 'FeexPay', credited: false,
  createdAt: { toDate: () => new Date(NOW - HOUR) },
  ...over,
});
const baseSeed = (txOver = {}, walletStart = 0) => ({
  'wallet_transactions/TX1': freshTx(txOver),
  'clients/u1': { wallet: walletStart },
});
// La vérification serveur est désormais OBLIGATOIRE (fail closed) : sans
// vérificateur, aucun crédit n'est possible. Les tests de ce fichier portent
// sur l'idempotence, les montants et les statuts du webhook — ils injectent
// donc par défaut un vérificateur confirmant, et peuvent l'écraser via
// `extra`. Le comportement fail-closed lui-même est couvert en détail par
// functions/test/feexpayCollectVerification.test.js.
const confirmingVerifier = createFakeVerifier(async () => ({ confirmed: true }));
const run = (db, body, extra = {}) => processFeexPayWebhookEvent({
  db, admin: fakeAdmin, body, nowMs: NOW, collectionFor,
  verifier: confirmingVerifier, ...extra,
});

// ── 1-2. Authentification du webhook ────────────────────────────────────────
test('1. secret webhook absent → 401, jamais de traitement', () => {
  const r = isAuthorizedWebhookCall({ method: 'POST', receivedSecret: undefined, expectedSecret: 'attendu' });
  assert.equal(r.ok, false);
  assert.equal(r.httpStatus, 401);
});

test('2. secret webhook incorrect → 401', () => {
  const r = isAuthorizedWebhookCall({ method: 'POST', receivedSecret: 'faux', expectedSecret: 'attendu' });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'invalid_secret');
});

test('2b. secret non configuré côté serveur → 503 (fail-closed)', () => {
  const r = isAuthorizedWebhookCall({ method: 'POST', receivedSecret: 'x', expectedSecret: '' });
  assert.equal(r.httpStatus, 503);
});

test('2c. méthode non POST refusée', () => {
  assert.equal(isAuthorizedWebhookCall({ method: 'GET', receivedSecret: 'a', expectedSecret: 'a' }).httpStatus, 405);
});

// ── 3-4. Idempotence et concurrence ─────────────────────────────────────────
test('3. callback répété → un seul crédit', async () => {
  const db = makeDb(baseSeed());
  const first = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 });
  const second = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 });
  assert.equal(first.outcome, 'credited');
  assert.equal(second.outcome, 'already_processed');
  assert.equal(db.store.get('clients/u1').wallet, 1000);
});

test('4. deux callbacks concurrents → un seul crédit', async () => {
  const db = makeDb(baseSeed());
  const body = { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 };
  const results = await Promise.all([run(db, body), run(db, body)]);
  const credited = results.filter((r) => r.outcome === 'credited');
  assert.equal(credited.length, 1, 'un seul crédit autorisé');
  assert.equal(db.store.get('clients/u1').wallet, 1000);
});

// ── 5-6. Échecs et attentes ─────────────────────────────────────────────────
test('5. paiement refusé → aucun crédit, statut failed', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'FAILED', reason: 'insufficient' });
  assert.equal(r.outcome, 'failed');
  assert.equal(db.store.get('clients/u1').wallet, 0);
  assert.equal(db.store.get('wallet_transactions/TX1').credited, false);
});

test('5b. paiement annulé → statut cancelled, aucun crédit', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'CANCELLED' });
  assert.equal(r.outcome, 'cancelled');
  assert.equal(db.store.get('clients/u1').wallet, 0);
});

test('6. paiement en attente (PENDING) → reste en attente, aucun crédit', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'PENDING' });
  assert.equal(r.outcome, 'unknown_status');
  assert.equal(db.store.get('clients/u1').wallet, 0);
  assert.equal(db.store.get('wallet_transactions/TX1').status, 'pending');
});

// ── 7-9. Références, expiration, statut inconnu ─────────────────────────────
test('7. transaction inexistante → 404, aucun crédit', async () => {
  const db = makeDb({ 'clients/u1': { wallet: 0 } });
  const r = await run(db, { order_id: 'INCONNU', status: 'SUCCESSFUL', amount: 1000 });
  assert.equal(r.httpStatus, 404);
  assert.equal(db.store.get('clients/u1').wallet, 0);
});

test('7b. référence invalide (chemin injecté) → 400', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: '../clients/u1', status: 'SUCCESSFUL' });
  assert.equal(r.httpStatus, 400);
  assert.equal(r.outcome, 'invalid_reference');
});

test('7c. aucune référence → 400', async () => {
  assert.equal(extractTransactionId({}), null);
});

test('8. transaction expirée (> 24 h) → rejet + événement de sécurité', async () => {
  const db = makeDb(baseSeed({ createdAt: { toDate: () => new Date(NOW - 30 * HOUR) } }));
  const seen = [];
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 },
    { logSecurityEvent: async (...a) => seen.push(a) });
  assert.equal(r.outcome, 'expired');
  assert.equal(db.store.get('clients/u1').wallet, 0);
  assert.equal(seen[0][1], 'webhook_replay_attempt');
});

test('9. statut inconnu → aucun crédit ET journalisation explicite', async () => {
  const db = makeDb(baseSeed());
  const seen = [];
  const r = await run(db, { order_id: 'TX1', status: 'WEIRD_NEW_STATE' },
    { logSecurityEvent: async (...a) => seen.push(a) });
  assert.equal(r.outcome, 'unknown_status');
  assert.equal(db.store.get('clients/u1').wallet, 0);
  assert.equal(seen[0][1], 'webhook_unknown_status', 'un statut inconnu ne doit jamais être silencieux');
});

// ── 10. Montants ────────────────────────────────────────────────────────────
test('10. montant payé différent du montant attendu → refus du crédit', async () => {
  const db = makeDb(baseSeed());
  const seen = [];
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 100 },
    { logSecurityEvent: async (...a) => seen.push(a) });
  assert.equal(r.outcome, 'amount_rejected');
  assert.equal(db.store.get('clients/u1').wallet, 0, 'aucun crédit sur montant incohérent');
  assert.equal(seen[0][1], 'webhook_amount_mismatch');
});

test('10b. montant identique → crédit, marqué vérifié', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 });
  assert.equal(r.amountVerified, true);
  assert.equal(db.store.get('wallet_transactions/TX1').amountVerified, true);
});

test('10c. montant absent → crédité mais explicitement NON vérifié', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL' });
  assert.equal(r.outcome, 'credited');
  assert.equal(r.amountVerified, false, 'un champ absent ne vaut jamais validation');
  assert.equal(db.store.get('wallet_transactions/TX1').amountVerified, false);
});

test('10d. mode strict : montant absent → refus (prêt pour la production)', async () => {
  const db = makeDb(baseSeed());
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL' }, { strictAmount: true });
  assert.equal(r.outcome, 'amount_rejected');
  assert.equal(db.store.get('clients/u1').wallet, 0);
});

test('10e. devise inattendue → refus', () => {
  const r = verifyPaidAmount({ expectedAmount: 1000, body: { amount: 1000, currency: 'EUR' } });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'currency_mismatch');
});

test('10f. montant "1 500,00" normalisé sans erreur d\'arrondi', () => {
  const r = verifyPaidAmount({ expectedAmount: 1500, body: { amount: '1 500,00' } });
  assert.equal(r.ok, true);
  assert.equal(r.paidAmount, 1500);
});

test('10g. montant illisible → refus, jamais accepté par défaut', () => {
  assert.equal(verifyPaidAmount({ expectedAmount: 1000, body: { amount: 'abc' } }).ok, false);
});

// ── Vérification indépendante ───────────────────────────────────────────────
test('vérificateur de collecte : construit si et seulement si client HTTP + jeton', () => {
  // L'endpoint officiel étant désormais confirmé, un vérificateur RÉEL est
  // construit dès que ses dépendances sont injectées ; il reste `null` (donc
  // fail-closed en amont) si l'une d'elles manque.
  assert.notEqual(createStatusVerifier({ axios: {}, token: () => 'jeton-factice' }), null);
  assert.equal(createStatusVerifier({ axios: {} }), null);
  assert.equal(createStatusVerifier({ token: () => 'jeton-factice' }), null);
  assert.equal(createStatusVerifier(), null);
});

test('vérificateur refusant → aucun crédit', async () => {
  const db = makeDb(baseSeed());
  const verifier = createFakeVerifier(async () => ({ confirmed: false, reason: 'status:FAILED' }));
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 }, { verifier });
  assert.equal(r.outcome, 'verification_failed');
  assert.equal(db.store.get('clients/u1').wallet, 0);
});

test('vérificateur confirmant → crédit marqué vérifié indépendamment', async () => {
  const db = makeDb(baseSeed());
  const verifier = createFakeVerifier(async () => ({ confirmed: true }));
  const r = await run(db, { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 }, { verifier });
  assert.equal(r.outcome, 'credited');
  assert.equal(db.store.get('wallet_transactions/TX1').independentlyVerified, true);
});

// ── 11-13, 15. Payout ───────────────────────────────────────────────────────
// Sémantique RÉVISÉE après réception de la documentation V2 : un code HTTP ne
// suffit plus à conclure un échec. Seule l'absence totale de référence permet
// d'affirmer qu'aucun transfert n'a pu partir (donc de compenser).
test('12. refus FeexPay SANS référence (4xx) → rejet prouvé, compensation sûre', () => {
  const r = classifyPayoutInitiation({ error: { response: { status: 400, data: { message: 'bad request' } } } });
  assert.equal(r.outcome, 'rejected_no_reference');
});

test('12a. 4xx AVEC référence → ambigu : le payout a pu être créé', () => {
  const r = classifyPayoutInitiation({ error: { response: { status: 409, data: { reference: 'REF-1' } } } });
  assert.equal(r.outcome, 'ambiguous');
  assert.equal(r.reference, 'REF-1');
});

test('13. acceptation SANS référence → ambigu (aucun suivi possible)', () => {
  assert.equal(classifyPayoutInitiation({ response: { data: { status: 'PENDING' } } }).outcome, 'ambiguous');
});

test('14. interruption réseau après envoi → ambigu, JAMAIS un échec certain', () => {
  const r = classifyPayoutInitiation({ error: { code: 'ECONNABORTED', request: {} } });
  assert.equal(r.outcome, 'ambiguous',
    'une erreur réseau ne prouve pas que le transfert n\'a pas eu lieu');
});

test('12b. erreur serveur 5xx → ambigu (pas de remboursement automatique)', () => {
  assert.equal(classifyPayoutInitiation({ error: { response: { status: 502 } } }).outcome, 'ambiguous');
});

test('initiation acceptée (PENDING + référence) → état NON final', () => {
  const r = classifyPayoutInitiation({
    response: { data: { reference: 'REF-2', status: 'PENDING', message: 'Payout request accepted' } },
  });
  assert.equal(r.outcome, 'accepted');
  assert.equal(r.reference, 'REF-2');
  assert.equal(r.providerStatus, 'PENDING');
});

test('compensation d\'un échec prouvé → wallet recrédité une seule fois', async () => {
  const db = makeDb({
    'withdrawal_requests/WD1': { userId: 'u1', userType: 'client', amount: 2000, status: 'processing' },
    'clients/u1': { wallet: 500 },
  });
  const args = { db, admin: fakeAdmin, withdrawId: 'WD1', collectionFor };
  const first = await compensateFailedWithdrawal(args);
  const second = await compensateFailedWithdrawal(args);
  assert.equal(first.compensated, true);
  assert.equal(second.compensated, false, 'compensation idempotente');
  assert.equal(db.store.get('clients/u1').wallet, 2500, 'jamais de double remboursement');
  assert.equal(db.store.get('withdrawal_requests/WD1').status, 'failed_refunded');
});

test('15. aucune compensation sur un retrait déjà réglé (anti double remboursement)', async () => {
  const db = makeDb({
    'withdrawal_requests/WD1': { userId: 'u1', userType: 'client', amount: 2000, status: 'sent' },
    'clients/u1': { wallet: 500 },
  });
  const r = await compensateFailedWithdrawal({ db, admin: fakeAdmin, withdrawId: 'WD1', collectionFor });
  assert.equal(r.compensated, false);
  assert.equal(db.store.get('clients/u1').wallet, 500);
});

// ── 16. Recharge AZ IA : même infrastructure, mêmes garanties ───────────────
test('16. recharge initiée par AZ IA → même idempotence (source ai_chat)', async () => {
  const db = makeDb(baseSeed({ source: 'ai_chat' }));
  const body = { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 };
  await run(db, body);
  await run(db, body);
  assert.equal(db.store.get('clients/u1').wallet, 1000);
  assert.equal(db.store.get('wallet_transactions/TX1').source, 'ai_chat');
});

// ── Classement des statuts ──────────────────────────────────────────────────
test('classification des statuts : succès / échec / inconnu', () => {
  assert.equal(classifyPaymentStatus('successful').kind, 'success');
  assert.equal(classifyPaymentStatus('  Paid ').kind, 'success');
  assert.equal(classifyPaymentStatus('REJECTED').kind, 'failure');
  assert.equal(classifyPaymentStatus('').kind, 'unknown');
  assert.equal(classifyPaymentStatus(undefined).kind, 'unknown');
});

// ── Garde-fou : aucun secret, aucun appel réseau ────────────────────────────
test('aucun secret ni client HTTP dans le module de paiement', () => {
  const fs = require('node:fs');
  const source = fs.readFileSync(require.resolve('../feexpayPayments'), 'utf8');
  // Le module ne doit contenir ni client HTTP, ni jeton. L'URL publique des
  // endpoints Payout V2 y est en revanche légitime : c'est une constante
  // documentée, pas un secret, et elle est injectable dans les tests.
  for (const token of ['axios', 'require(\'http', 'Bearer ', 'Authorization']) {
    assert.ok(!source.includes(token), `le module ne doit pas contenir « ${token} »`);
  }
  assert.ok(!/https:\/\/api-v2\.feexpay\.me\S*\?/.test(source),
    'aucune URL ne doit embarquer de paramètre (donc jamais de secret en query)');
});

// ── PATCH DIAGNOSTIC 502 ────────────────────────────────────────────────────
// Un test réel de collecte a échoué sur un HTTP 502 : l'ancien chemin ne
// retenait que `data.message || err.message`, donc rien d'exploitable côté
// serveur et un message axios brut affiché à l'utilisateur. Ces tests
// verrouillent l'extraction sûre, la qualification de l'ambiguïté et
// l'absence de fuite.

const {
  sanitizeProviderMessage,
  extractProviderError,
  classifyCollectInitiationFailure,
  buildInitiationFailureLog,
  COLLECT_UNCERTAIN_STATUS,
} = require('../feexpayPayments');

const axiosError = ({ status = null, data = undefined, code = undefined } = {}) => {
  const err = new Error(status
    ? `Request failed with status code ${status}`
    : 'connect ETIMEDOUT');
  if (status !== null) err.response = { status, data };
  if (code) err.code = code;
  return err;
};
const FAKE_TOKEN = 'faux-jeton-de-test-non-sensible';

test('502.A corps JSON structuré → status, code et message exploitables', () => {
  const v = classifyCollectInitiationFailure(axiosError({
    status: 502,
    data: { status: 'ERROR', code: 'UPSTREAM_TIMEOUT', message: 'Operator gateway unreachable' },
  }));
  assert.equal(v.httpStatus, 502);
  assert.equal(v.providerStatus, 'ERROR');
  assert.equal(v.providerCode, 'UPSTREAM_TIMEOUT');
  assert.equal(v.providerMessage, 'Operator gateway unreachable');
  assert.equal(v.bodyKind, 'json');
  assert.equal(v.ambiguous, true, '502 = jamais un échec définitif');
  assert.equal(v.txStatus, COLLECT_UNCERTAIN_STATUS);
});

test('502.B corps texte/HTML → aucun fragment du corps ne transite', () => {
  const html = '<html><head><title>502 Bad Gateway</title></head><body>nginx/1.24.0</body></html>';
  const v = classifyCollectInitiationFailure(axiosError({ status: 502, data: html }));
  assert.equal(v.httpStatus, 502);
  assert.equal(v.bodyKind, 'text');
  assert.equal(v.providerMessage, null);
  assert.equal(v.providerCode, null);
  assert.equal(v.ambiguous, true);
  const line = buildInitiationFailureLog(v, 'TXLOG');
  assert.ok(!line.includes('nginx') && !line.includes('<html>'),
    'le corps brut ne doit jamais atteindre les journaux');
});

test('502.C HTTP 500 → ambigu, jamais définitif', () => {
  const v = classifyCollectInitiationFailure(axiosError({ status: 500, data: { message: 'Internal error' } }));
  assert.equal(v.httpStatus, 500);
  assert.equal(v.ambiguous, true);
  assert.equal(v.txStatus, COLLECT_UNCERTAIN_STATUS);
});

test('502.D timeout → ambigu avec code de transport', () => {
  const v = classifyCollectInitiationFailure(axiosError({ code: 'ECONNABORTED' }));
  assert.equal(v.httpStatus, null);
  assert.equal(v.transportCode, 'ECONNABORTED');
  assert.equal(v.reason, 'timeout');
  assert.equal(v.ambiguous, true);
});

test('502.E erreur réseau sans réponse → ambigu', () => {
  const v = classifyCollectInitiationFailure(axiosError({ code: 'ENOTFOUND' }));
  assert.equal(v.httpStatus, null);
  assert.equal(v.reason, 'no_response');
  assert.equal(v.ambiguous, true);
  assert.equal(v.providerMessage, null);
});

test('502.E bis 4xx sans référence → refus définitif (seul cas sûr)', () => {
  const v = classifyCollectInitiationFailure(axiosError({
    status: 400, data: { message: 'Invalid phone number' },
  }));
  assert.equal(v.ambiguous, false, 'un 4xx sans référence prouve que rien na été créé');
  assert.equal(v.txStatus, 'error');
  assert.equal(v.reason, 'provider_rejected');
});

test('502.E ter 4xx AVEC référence → redevient ambigu', () => {
  const v = classifyCollectInitiationFailure(axiosError({
    status: 409, data: { message: 'Duplicate', reference: 'FP-REF-123' },
  }));
  assert.equal(v.providerReference, 'FP-REF-123');
  assert.equal(v.ambiguous, true, 'une référence existe : la transaction a pu être créée');
  assert.equal(v.txStatus, COLLECT_UNCERTAIN_STATUS);
});

test('502.F jeton, Authorization, wh_secret, URL et téléphone sont expurgés', () => {
  process.env.FEEXPAY_TOKEN = FAKE_TOKEN;
  try {
    const leaky = 'POST https://api.feexpay.me/api/v1/request/inline?wh_secret=s3cr3t '
      + `Authorization: Bearer ${FAKE_TOKEN} failed for +2250798051397 token: ${FAKE_TOKEN}`;
    const out = sanitizeProviderMessage(leaky);
    assert.ok(!out.includes(FAKE_TOKEN), 'le jeton ne doit jamais apparaître');
    assert.ok(!out.includes('s3cr3t'), 'le secret du webhook ne doit jamais apparaître');
    assert.ok(!out.includes('0798051397'), 'le téléphone ne doit jamais apparaître');
    assert.ok(!out.includes('/api/v1/request/inline'), 'aucune URL complète');
    assert.ok(out.includes('[PHONE]') && out.includes('[REDACTED]'));
  } finally {
    delete process.env.FEEXPAY_TOKEN;
  }
});

test('502.F bis message très long → borné', () => {
  const out = sanitizeProviderMessage('X'.repeat(5000));
  assert.ok(out.length <= 200, `message borné (${out.length})`);
});

test('502.G aucun secret ni corps brut dans le journal structuré', () => {
  process.env.FEEXPAY_TOKEN = FAKE_TOKEN;
  try {
    const v = classifyCollectInitiationFailure(axiosError({
      status: 502,
      data: { message: `Bearer ${FAKE_TOKEN} refused for +2250700000000`, code: 'GW' },
    }));
    const line = buildInitiationFailureLog(v, 'TX502');
    for (const forbidden of [FAKE_TOKEN, '0700000000', 'wh_secret=s']) {
      assert.ok(!line.includes(forbidden), `le journal ne doit pas contenir ${forbidden}`);
    }
    assert.ok(line.startsWith('event=feexpay_initiation_failed provider=FeexPay'));
    assert.ok(line.includes('httpStatus=502') && line.includes('ambiguous=true'));
  } finally {
    delete process.env.FEEXPAY_TOKEN;
  }
});

test('502.H un document laissé en provider_uncertain reste créditable par le webhook', async () => {
  // Garantie centrale : un 502 ambigu ne doit pas fermer la porte à un
  // paiement réellement abouti dont le webhook arrive plus tard.
  const db = makeDb({
    'wallet_transactions/TX1': freshTx({ status: COLLECT_UNCERTAIN_STATUS, ambiguous: true }),
    'clients/u1': { wallet: 0 },
  });
  const result = await processFeexPayWebhookEvent({
    db, admin: fakeAdmin, body: { id: 'TX1', status: 'SUCCESSFUL', amount: 1000 },
    nowMs: NOW, collectionFor,
    verifier: createFakeVerifier(async () => ({ confirmed: true, amount: 1000, reference: 'TX1' })),
  });
  assert.equal(result.outcome, 'credited');
  assert.equal(db.store.get('clients/u1').wallet, 1000);
  assert.equal(db.store.get('wallet_transactions/TX1').status, 'completed');
});

test('502.H bis un provider_uncertain nest jamais crédité sans vérification serveur', async () => {
  const db = makeDb({
    'wallet_transactions/TX1': freshTx({ status: COLLECT_UNCERTAIN_STATUS }),
    'clients/u1': { wallet: 0 },
  });
  const result = await processFeexPayWebhookEvent({
    db, admin: fakeAdmin, body: { id: 'TX1', status: 'SUCCESSFUL', amount: 1000 },
    nowMs: NOW, collectionFor, verifier: null,
  });
  assert.equal(result.httpStatus, 503);
  assert.equal(result.outcome, 'verification_unavailable');
  assert.equal(db.store.get('clients/u1').wallet, 0, 'aucun crédit sans vérificateur');
});

test('502.I le txId reste stable et rapprochable après un échec ambigu', () => {
  // Le txId est l'identifiant Firestore envoyé à FeexPay dans le champ `id`.
  // Il n'est jamais régénéré par le chemin d'erreur : la transaction reste
  // donc rapprochable, et le webhook la retrouve via extractTransactionId.
  const v = classifyCollectInitiationFailure(axiosError({ status: 502 }));
  assert.equal(v.txStatus, COLLECT_UNCERTAIN_STATUS);
  for (const field of ['order_id', 'id', 'custom_id', 'reference']) {
    assert.equal(extractTransactionId({ [field]: 'TX_STABLE_1' }), 'TX_STABLE_1');
  }
});

test('502.J succès : aucune qualification derreur produite', () => {
  // `classifyCollectInitiationFailure` nest jamais invoquée sur un succès ;
  // appelée sans erreur, elle ne fabrique aucun faux diagnostic.
  const v = classifyCollectInitiationFailure(null);
  assert.equal(v.httpStatus, null);
  assert.equal(v.providerMessage, null);
  assert.equal(v.bodyKind, 'none');
  const safe = extractProviderError(undefined);
  assert.deepEqual(
    { s: safe.httpStatus, c: safe.providerCode, m: safe.providerMessage },
    { s: null, c: null, m: null },
  );
});
