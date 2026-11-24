'use strict';

// L2.1 — classement des retraits (`withdrawal_requests`) par le moteur d'obligations. Les documents de test sont produits par le VRAI
// code d'écriture (applyPayoutStatus, adminApproveWithdrawalCF) sur un faux Firestore : le statut n'est jamais jugé sur son seul libellé.
const test = require('node:test');
const assert = require('node:assert/strict');
const engine = require('../accountObligations');
const { applyPayoutStatus } = require('../feexpayPayments');
const { buildAdminApproveWithdrawal } = require('../adminWalletRequests');
const { fakeStore } = require('./support/closureWorld');

const { classifyWithdrawal, evaluateWithdrawals, CODE } = engine;
const UID = 'c1';
const base = (over = {}) => ({ userId: UID, userType: 'client', amount: 2000, status: 'processing', provider: 'FeexPay', ...over });
const verdictOf = (w, ids = [UID]) => classifyWithdrawal(w, ids);
const adminStub = { firestore: { FieldValue: { serverTimestamp: () => 'TS' } } };

// ── Matrice de décision ─────────────────────────────────────────────────────────────────────────────────────────────
test('matrice : états non finaux = OUVERTS, quel que soit le reste du document', () => {
  for (const status of ['processing', 'provider_pending', 'pending_manual']) {
    assert.deepEqual(verdictOf(base({ status })), { state: 'open', reason: `withdrawal_${status}` }, status);
    // Même avec des drapeaux « rassurants » : un retrait en cours n'est jamais clos.
    assert.equal(verdictOf(base({ status, settlementConfirmed: true })).state, 'open', status);
    assert.equal(verdictOf(base({ status, needsReview: true })).state, 'open', status);
  }
});

test('matrice : sent / processed / failed_refunded ne sont CLOS que si l’écriture financière correspondante est présente', () => {
  assert.deepEqual(verdictOf(base({ status: 'sent', settlementConfirmed: true, compensated: false, needsReview: false })), { state: 'closed', reason: 'withdrawal_settled' });
  assert.deepEqual(verdictOf(base({ status: 'sent', settlementConfirmed: true })), { state: 'closed', reason: 'withdrawal_settled' });
  assert.deepEqual(verdictOf(base({ status: 'processed', settlementConfirmed: true, processedBy: 'adm1' })), { state: 'closed', reason: 'withdrawal_settled_manually' });
  assert.deepEqual(verdictOf(base({ status: 'failed_refunded', compensated: true, settlementConfirmed: false })), { state: 'closed', reason: 'withdrawal_refunded' });
  assert.deepEqual(verdictOf(base({ status: 'failed_refunded', compensated: true })), { state: 'closed', reason: 'withdrawal_refunded' });
});

test('matrice : un statut « final » sans la preuve financière, ou contradictoire, est AMBIGU (bloquant)', () => {
  const amb = (w, reason) => assert.deepEqual(verdictOf(w), { state: 'ambiguous', reason }, JSON.stringify(w));
  amb(base({ status: 'sent' }), 'withdrawal_settlement_unconfirmed');
  amb(base({ status: 'sent', settlementConfirmed: false }), 'withdrawal_settlement_unconfirmed');
  amb(base({ status: 'processed', settlementConfirmed: true }), 'withdrawal_settlement_unconfirmed');
  amb(base({ status: 'processed', settlementConfirmed: true, processedBy: '' }), 'withdrawal_settlement_unconfirmed');
  amb(base({ status: 'failed_refunded' }), 'withdrawal_refund_unconfirmed');
  amb(base({ status: 'failed_refunded', compensated: false }), 'withdrawal_refund_unconfirmed');
  amb(base({ status: 'sent', settlementConfirmed: true, compensated: true }), 'withdrawal_flags_contradictory');
  amb(base({ status: 'failed_refunded', compensated: true, settlementConfirmed: true }), 'withdrawal_flags_contradictory');
  amb(base({ status: 'sent', settlementConfirmed: true, needsReview: true }), 'withdrawal_needs_review');
  amb(base({ status: 'failed_refunded', compensated: true, needsReview: true }), 'withdrawal_needs_review');
  amb(base({ status: 'sent', settlementConfirmed: true, anomaly: 'failed_after_success' }), 'withdrawal_anomaly');
});

test('matrice : statut inconnu, illisible, montant ou drapeau invalide, rattachement douteux, document non objet = AMBIGU', () => {
  const amb = (w, reason) => assert.deepEqual(verdictOf(w), { state: 'ambiguous', reason }, JSON.stringify(w));
  for (const status of ['pending', 'completed', 'cancelled', 'rejected', 'SENT', 'Sent ', 'settled', '']) amb(base({ status }), 'withdrawal_status_unknown');
  for (const status of [undefined, null, 1, true, {}, ['sent']]) amb(base({ status }), 'withdrawal_status_unreadable');
  for (const amount of [0, -5, 1.5, '2000', NaN, null, undefined, Infinity]) amb(base({ status: 'sent', settlementConfirmed: true, amount }), 'withdrawal_amount_invalid');
  for (const f of ['needsReview', 'compensated', 'settlementConfirmed']) amb(base({ status: 'sent', settlementConfirmed: true, [f]: 'true' }), 'withdrawal_flag_invalid');
  amb(base({ status: 'sent', settlementConfirmed: true, userId: 'other' }), 'withdrawal_not_linked_to_account');
  amb(base({ status: 'sent', settlementConfirmed: true, userId: undefined }), 'withdrawal_not_linked_to_account');
  for (const w of [null, undefined, 'sent', 5, [], true]) assert.equal(verdictOf(w).state, 'ambiguous');
  assert.equal(classifyWithdrawal(base({ status: 'sent', settlementConfirmed: true }), undefined).state, 'ambiguous', 'identifiants du compte absents');
});

// ── Documents produits par le vrai code d'écriture ──────────────────────────────────────────────────────────────────
const seedWithdrawal = (over = {}) => fakeStore({
  'clients/c1': { wallet: 0 }, 'withdrawal_requests/w1': base({ status: 'provider_pending', providerReference: 'REF1', ...over }),
});
const apply = async (db, verdict) => {
  await applyPayoutStatus({ db, admin: adminStub, withdrawId: 'w1', verdict, collectionFor: () => 'clients' });
  return db.store.get('withdrawal_requests/w1');
};

test('écrivain réel : SUCCESSFUL => « sent » clos ; FAILED => « failed_refunded » clos et wallet recrédité', async () => {
  const sent = await apply(seedWithdrawal(), { outcome: 'successful', reference: 'REF1', amount: 2000 });
  assert.equal(sent.status, 'sent');
  assert.deepEqual(verdictOf(sent), { state: 'closed', reason: 'withdrawal_settled' });
  const db = seedWithdrawal();
  const refunded = await apply(db, { outcome: 'failed', reference: 'REF1', amount: 2000 });
  assert.equal(refunded.status, 'failed_refunded');
  assert.equal(db.store.get('clients/c1').wallet, 2000, 'le montant est bien revenu sur le wallet');
  assert.deepEqual(verdictOf(refunded), { state: 'closed', reason: 'withdrawal_refunded' });
});

test('écrivain réel : en attente, inconnu, référence ou montant incohérents => jamais clos', async () => {
  const pending = await apply(seedWithdrawal({ status: 'processing' }), { outcome: 'pending' });
  assert.equal(verdictOf(pending).state, 'open');
  const unknown = await apply(seedWithdrawal({ status: 'processing' }), { outcome: 'unknown' });
  assert.equal(unknown.needsReview, true); assert.equal(verdictOf(unknown).state, 'open');
  const mismatch = await apply(seedWithdrawal(), { outcome: 'successful', reference: 'AUTRE', amount: 2000 });
  assert.equal(mismatch.status, 'pending_manual'); assert.equal(verdictOf(mismatch).state, 'open');
  const wrongAmount = await apply(seedWithdrawal(), { outcome: 'failed', reference: 'REF1', amount: 1 });
  assert.equal(wrongAmount.status, 'pending_manual'); assert.equal(verdictOf(wrongAmount).state, 'open');
});

test('écrivain réel : succès après remboursement et échec après succès => anomalie, bloquant', async () => {
  const db = seedWithdrawal();
  await apply(db, { outcome: 'failed', reference: 'REF1', amount: 2000 });
  const afterRefund = await apply(db, { outcome: 'successful', reference: 'REF1', amount: 2000 });
  assert.equal(afterRefund.anomaly, 'success_after_refund');
  assert.equal(verdictOf(afterRefund).state, 'ambiguous');
  const db2 = seedWithdrawal();
  await apply(db2, { outcome: 'successful', reference: 'REF1', amount: 2000 });
  const afterSuccess = await apply(db2, { outcome: 'failed', reference: 'REF1', amount: 2000 });
  assert.equal(afterSuccess.anomaly, 'failed_after_success');
  assert.equal(verdictOf(afterSuccess).state, 'ambiguous');
});

test('écrivain réel : adminApproveWithdrawalCF => « processed » clos ; le wallet n’est pas touché', async () => {
  const db = fakeStore({ 'clients/c1': { wallet: 7 }, 'withdrawal_requests/w1': base({ status: 'pending_manual' }) });
  class HttpsErr extends Error { constructor(code, message) { super(message); this.code = code; } }
  const handler = buildAdminApproveWithdrawal({
    db, admin: adminStub, onCall: (h) => h, HttpsError: HttpsErr, checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin: async () => {},
  });
  const res = await handler({ auth: { uid: 'adm1' }, data: { requestId: 'w1' } });
  assert.equal(res.success, true);
  const doc = db.store.get('withdrawal_requests/w1');
  assert.equal(doc.status, 'processed'); assert.equal(db.store.get('clients/c1').wallet, 7);
  assert.deepEqual(verdictOf(doc), { state: 'closed', reason: 'withdrawal_settled_manually' });
});

// ── Liste complète : couverture et agrégation ───────────────────────────────────────────────────────────────────────
const entry = (id, data) => ({ id, data });
const reads = (size, id = UID) => ({ queries: [{ key: 'userId', id, limit: 201, size }] });
const closedSent = base({ status: 'sent', settlementConfirmed: true });
const evaluate = (withdrawals, over = {}) => evaluateWithdrawals({ ids: [UID], withdrawals, reads: reads(withdrawals ? withdrawals.length : 0), ...over });

test('liste : aucun retrait ou retraits clos = non bloquant ; un seul retrait ouvert ou ambigu = bloquant avec le bon code', () => {
  assert.deepEqual([evaluate([]).blocking, evaluate([]).code], [false, CODE.NONE]);
  const closed = evaluate([entry('a', closedSent), entry('b', base({ status: 'processed', settlementConfirmed: true, processedBy: 'x' })), entry('c', base({ status: 'failed_refunded', compensated: true }))]);
  assert.deepEqual([closed.blocking, closed.summary.closed, closed.obligations.length], [false, 3, 0]);
  const open = evaluate([entry('a', closedSent), entry('b', base({ status: 'provider_pending' }))]);
  assert.deepEqual([open.blocking, open.code, open.summary.open], [true, CODE.PENDING, 1]);
  const amb = evaluate([entry('a', closedSent), entry('b', base({ status: 'provider_pending' })), entry('c', base({ status: 'mystery' }))]);
  assert.deepEqual([amb.blocking, amb.code], [true, CODE.AMBIGUOUS]);
});

test('liste : lecture incomplète, tronquée, incohérente ou sans preuve de couverture = bloquant, jamais « aucun retrait »', () => {
  const reasons = (r) => r.obligations.map((o) => o.reason).sort();
  assert.deepEqual(reasons(evaluateWithdrawals({ ids: [UID] })), ['withdrawals_not_provided']);
  assert.deepEqual(reasons(evaluateWithdrawals({ ids: [UID], withdrawals: 'x' })), ['withdrawals_not_an_array']);
  assert.deepEqual(reasons(evaluateWithdrawals({ withdrawals: [] })), ['withdrawals_account_ids_missing']);
  assert.deepEqual(reasons(evaluateWithdrawals({ ids: [UID], withdrawals: [] })), ['withdrawals_coverage_unproven']);
  assert.ok(reasons(evaluate([], { reads: { queries: [] } })).includes('withdrawals_queries_incomplete'));
  assert.ok(reasons(evaluate([], { reads: reads(201) })).includes('withdrawals_truncated'));
  assert.ok(reasons(evaluate([], { reads: { queries: [{ key: 'userId', id: UID, limit: 50, size: 0 }] } })).includes('withdrawals_query_invalid'));
  assert.ok(reasons(evaluate([], { reads: { queries: [{ key: 'other', id: UID, limit: 201, size: 0 }] } })).includes('withdrawals_query_invalid'));
  assert.ok(reasons(evaluate([], { reads: { queries: [...reads(0).queries, ...reads(0).queries] } })).includes('withdrawals_query_duplicate'));
  assert.ok(reasons(evaluate([entry('a', closedSent)], { reads: reads(0) })).includes('withdrawals_read_size_mismatch'));
  assert.ok(reasons(evaluate([entry('a', closedSent), entry('a', closedSent)], { reads: reads(2) })).includes('withdrawals_duplicate_document_id'));
  assert.ok(reasons(evaluate([{ data: closedSent }], { reads: reads(1) })).includes('withdrawals_entry_without_id'));
  for (const bad of [null, undefined, 'x', 5, []]) assert.equal(evaluateWithdrawals(bad).blocking, true);
});

test('liste : un document d’un autre compte est ambigu ; le résultat ne recopie aucun texte du document', () => {
  const r = evaluate([entry('a', { ...closedSent, userId: 'intrus', phone: '0700000000', userName: 'Awa' })]);
  assert.equal(r.blocking, true);
  const text = JSON.stringify(r);
  assert.ok(!text.includes('0700000000') && !text.includes('Awa') && !text.includes('intrus'));
  for (const o of r.obligations) assert.ok(engine.WITHDRAWAL_REASONS.includes(o.reason), o.reason);
});

test('non-régression : le moteur existant n’a pas changé de contrat (liste de retraits indépendante)', () => {
  assert.equal(typeof engine.evaluateAccountObligations, 'function');
  const r = engine.evaluateAccountObligations({ role: 'client', ids: [UID], terminalStatuses: engine.INSPECTOR_TERMINAL_STATUSES.accountDeletion, withdrawals: [entry('w', base({ status: 'processing' }))] });
  assert.equal(r.blocking, true, 'sans ses listes obligatoires le moteur reste fail-closed');
  assert.ok(!JSON.stringify(r).includes('withdrawal'), 'evaluateAccountObligations ne lit pas les retraits');
});
