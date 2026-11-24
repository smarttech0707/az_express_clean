'use strict';

// Mission 7E-68 : garde de quarantaine d'AZ IA (confirmation d'action), traitement d'un paiement tardif par le webhook
// FeexPay, barrière « compte administrateur » du moteur de suppression et refus des cibles en suppression.
// Faux Firestore en mémoire : AUCUN accès cloud, aucune donnée réelle, aucune suppression réelle.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { fakeDb, DELETE } = require('./fakeFirestore');
const { buildConfirmAction } = require('../azia/pendingActions');
const { processFeexPayWebhookEvent, shouldHoldPayment, HELD_STATUS } = require('../feexpayPayments');
const { createFakeVerifier } = require('../feexpayVerification');
const { buildAccountDeletion } = require('../accountDeletion');
const { assertTargetNotClosing } = require('../accountAdmission');

const ts = (ms) => ({ toMillis: () => ms, toDate: () => new Date(ms) });
const NOW = 1_800_000_000_000;
const admin = {
  firestore: {
    FieldValue: { serverTimestamp: () => ts(NOW), increment: (n) => ({ __increment: n }), delete: () => DELETE },
    Timestamp: { fromMillis: ts },
  },
};
const rejectsWith = (p, pattern) => assert.rejects(p, (e) => pattern.test(`${e.code} ${e.message}`));

// ── AZ IA : confirmation d'une action préparée ──────────────────────────────────────────────────────────────────────
function aiSetup(seed = {}) {
  const db = fakeDb({
    'ai_pending_actions/a1': { uid: 'u1', toolName: 'create_delivery_order', toolInput: { x: 1 }, status: 'pending', amount: 500, expiresAt: ts(Date.now() + 60000) },
    ...seed,
  });
  const executed = [];
  const toolsByName = new Map([['create_delivery_order', {
    confirmHandler: async (tx, uid) => { executed.push(uid); return { orderId: 'o1' }; },
  }]]);
  const fn = buildConfirmAction({ db, admin, onCall, logAudit: async () => {}, HttpsError, toolsByName });
  return { db, executed, confirm: (uid = 'u1', actionId = 'a1') => fn.run({ auth: { uid }, data: { actionId } }) };
}

test('AZ IA : un compte actif confirme son action (comportement inchangé)', async () => {
  const { confirm, executed, db } = aiSetup();
  const r = await confirm();
  assert.equal(r.status, 'completed');
  assert.deepEqual(executed, ['u1']);
  assert.equal(db.store.get('ai_pending_actions/a1').status, 'completed');
});

test('AZ IA : action préparée AVANT la quarantaine → confirmation refusée, rien exécuté, action toujours en attente', async () => {
  const { confirm, executed, db } = aiSetup({ 'account_tombstones/u1': { createdAt: ts(NOW), state: 'deleting' } });
  await rejectsWith(confirm(), /suppression/i);
  assert.equal(executed.length, 0, 'aucun confirmHandler (commande, débit, recharge) exécuté');
  assert.equal(db.store.get('ai_pending_actions/a1').status, 'pending');
});

test('AZ IA : profil client en cours de suppression sans tombstone → refus ; profil anonymisé → refus', async () => {
  for (const profile of [{ deletionRequested: true }, { isDeleted: true }]) {
    const { confirm, executed } = aiSetup({ 'clients/u1': profile });
    await rejectsWith(confirm(), /suppression/i);
    assert.equal(executed.length, 0);
  }
});

test('AZ IA : la même action ne peut pas être confirmée deux fois (séquentiel)', async () => {
  const { confirm, executed } = aiSetup();
  await confirm();
  await rejectsWith(confirm(), /d[ée]j[àa] [ée]t[ée] trait/i);
  assert.equal(executed.length, 1);
});

test('AZ IA : erreur de lecture du tombstone → confirmation refusée (fail-closed)', async () => {
  const { db, confirm, executed } = aiSetup();
  const base = db.runTransaction;
  db.runTransaction = (cb) => base((tx) => cb({ ...tx, get: async (t) => { if (String(t.path).startsWith('account_tombstones/')) throw new Error('unavailable'); return tx.get(t); } }));
  await assert.rejects(confirm());
  assert.equal(executed.length, 0);
  assert.equal(db.store.get('ai_pending_actions/a1').status, 'pending');
});

test('AZ IA : un autre compte, non concerné, confirme normalement', async () => {
  const { confirm, executed } = aiSetup({
    'ai_pending_actions/a2': { uid: 'u2', toolName: 'create_delivery_order', toolInput: {}, status: 'pending', amount: 1, expiresAt: ts(Date.now() + 60000) },
    'account_tombstones/u1': { createdAt: ts(NOW) },
  });
  assert.equal((await confirm('u2', 'a2')).status, 'completed');
  assert.deepEqual(executed, ['u2']);
});

// ── Webhook FeexPay : paiement tardif ──────────────────────────────────────────────────────────────────────────────
const verifier = createFakeVerifier(async () => ({ confirmed: true }));
const collectionFor = (t) => (t === 'driver' ? 'livreurs' : 'clients');
const hookCalls = () => { const c = { security: [], audit: [] }; c.logSecurityEvent = async (...a) => c.security.push(a); c.logAudit = async (d) => c.audit.push(d); return c; };
const payment = (createdMs, over = {}) => ({
  userId: 'u1', userType: 'client', amount: 1000, status: 'pending', paymentMethod: 'mtn', provider: 'FeexPay', credited: false,
  createdAt: ts(createdMs), ...over,
});
const webhook = (db, c) => processFeexPayWebhookEvent({
  db, admin, body: { order_id: 'TX1', status: 'SUCCESSFUL', amount: 1000 }, nowMs: NOW, collectionFor, verifier,
  logAudit: c.logAudit, logSecurityEvent: c.logSecurityEvent,
});

test('webhook : paiement antérieur à la quarantaine, compte non anonymisé → crédité normalement (réconciliable)', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 3600000), 'clients/u1': { wallet: 0 }, 'account_tombstones/u1': { createdAt: ts(NOW - 600000) } });
  const r = await webhook(db, hookCalls());
  assert.equal(r.outcome, 'credited');
  assert.equal(db.store.get('clients/u1').wallet, 1000, 'le solde non nul bloquera ensuite la suppression (inspection du moteur)');
});

test('webhook : paiement créé APRÈS la quarantaine → conservé, vérifié, NON crédité, revue administrative tracée', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 60000), 'clients/u1': { wallet: 0 }, 'account_tombstones/u1': { createdAt: ts(NOW - 600000) } });
  const c = hookCalls();
  const r = await webhook(db, c);
  assert.equal(r.outcome, 'held_for_review');
  assert.equal(r.httpStatus, 200);
  assert.equal(db.store.get('clients/u1').wallet, 0, 'aucun crédit silencieux');
  const tx = db.store.get('wallet_transactions/TX1');
  assert.equal(tx.status, HELD_STATUS);
  assert.equal(tx.needsReview, true);
  assert.equal(tx.credited, false);
  assert.equal(tx.reviewReason, 'payment_created_after_quarantine');
  assert.equal(c.security.length, 1);
  assert.equal(c.audit[0].action, 'payment_held_account_deletion');
});

test('webhook : profil anonymisé → jamais crédité, même pour un paiement ancien', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 3600000), 'clients/u1': { wallet: 0, isDeleted: true } });
  const r = await webhook(db, hookCalls());
  assert.equal(r.outcome, 'held_for_review');
  assert.equal(db.store.get('clients/u1').wallet, 0);
  assert.equal(db.store.get('wallet_transactions/TX1').reviewReason, 'profile_anonymized');
});

test('webhook : webhook dupliqué → aucun double crédit ; rejeu après mise en attente → inchangé', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 3600000), 'clients/u1': { wallet: 0 } });
  assert.equal((await webhook(db, hookCalls())).outcome, 'credited');
  assert.equal((await webhook(db, hookCalls())).outcome, 'already_processed');
  assert.equal(db.store.get('clients/u1').wallet, 1000);
  const held = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 60000), 'clients/u1': { wallet: 0, isDeleted: true } });
  assert.equal((await webhook(held, hookCalls())).outcome, 'held_for_review');
  assert.equal((await webhook(held, hookCalls())).outcome, 'already_processed');
  assert.equal(held.store.get('clients/u1').wallet, 0);
});

// Mission 7E-71 : l'échec de lecture du tombstone pendant la transaction de crédit ne doit JAMAIS aboutir à un crédit : la
// transaction échoue, le paiement reste 'pending' (le fournisseur rejouera), aucune mise en attente ni crédit silencieux.
test('webhook : erreur de lecture du tombstone → aucun crédit, transaction en échec, paiement inchangé (fail-closed)', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 3600000), 'clients/u1': { wallet: 0 } });
  const base = db.runTransaction;
  db.runTransaction = (cb) => base((tx) => cb({ ...tx, get: async (t) => { if (String(t.path).startsWith('account_tombstones/')) throw new Error('unavailable'); return tx.get(t); } }));
  const c = hookCalls();
  await assert.rejects(webhook(db, c));
  assert.equal(db.store.get('clients/u1').wallet, 0, 'aucun crédit');
  const tx = db.store.get('wallet_transactions/TX1');
  assert.equal(tx.status, 'pending');
  assert.equal(tx.credited, false);
  assert.notEqual(tx.status, HELD_STATUS, 'une panne de lecture n’est pas une décision de mise en attente');
  assert.equal(c.audit.length, 0);
});

test('webhook : compte actif sans tombstone, et compte d’un autre utilisateur en quarantaine → crédit normal', async () => {
  const db = fakeDb({ 'wallet_transactions/TX1': payment(NOW - 60000), 'clients/u1': { wallet: 200 }, 'account_tombstones/u2': { createdAt: ts(1) } });
  assert.equal((await webhook(db, hookCalls())).outcome, 'credited');
  assert.equal(db.store.get('clients/u1').wallet, 1200);
});

test('shouldHoldPayment : règles pures (date illisible = prudence)', () => {
  assert.equal(shouldHoldPayment({ tx: { createdAt: ts(10) }, profile: {}, tombstone: null }), null);
  assert.equal(shouldHoldPayment({ tx: { createdAt: ts(10) }, profile: { isDeleted: true }, tombstone: null }), 'profile_anonymized');
  assert.equal(shouldHoldPayment({ tx: { createdAt: ts(10) }, profile: {}, tombstone: { createdAt: ts(20) } }), null);
  assert.equal(shouldHoldPayment({ tx: { createdAt: ts(30) }, profile: {}, tombstone: { createdAt: ts(20) } }), 'payment_created_after_quarantine');
  assert.equal(shouldHoldPayment({ tx: {}, profile: {}, tombstone: { createdAt: ts(20) } }), 'tombstone_date_unreadable');
});

// ── Décision D3 : aucun compte administrateur supprimé automatiquement ─────────────────────────────────────────────
const TOKEN = 'a'.repeat(64);
function engine(seed) {
  const db = fakeDb({ 'operations_control/account_deletion': { enabled: true, inventoryVersion: 1 }, ...seed });
  const calls = [];
  const auth = { updateUser: async () => calls.push('disable'), revokeRefreshTokens: async () => calls.push('revoke'), deleteUser: async () => calls.push('delete') };
  const api = buildAccountDeletion({ db, auth, admin, HttpsError, clock: () => NOW, checkRateLimit: async () => {}, eraseAssets: async () => {} });
  const req = (uid) => ({ auth: { uid, token: { auth_time: NOW / 1000, firebase: { sign_in_provider: 'password' } } }, data: { role: 'client', recoveryToken: TOKEN, allProfilesConsent: true } });
  return { db, calls, api, req };
}

test('D3 : un super-administrateur (même titulaire d’un profil client) ne peut pas demander sa suppression automatique', async () => {
  const { db, calls, api, req } = engine({ 'clients/adm': { wallet: 0 }, 'admins/adm': { role: 'super_admin', isActive: true } });
  await rejectsWith(api.request(req('adm')), /ADMIN_ACCOUNT_MANUAL_PROCESS/);
  assert.equal(db.store.has('account_deletions/adm'), false, 'aucun dossier créé');
  assert.equal(db.store.has('account_tombstones/adm'), false);
  assert.deepEqual(calls, []);
});

test('D3 : un dossier déjà existant devenu administrateur est bloqué avant toute quarantaine ou suppression Auth', async () => {
  const { db, calls, api, req } = engine({ 'clients/c1': { wallet: 0 } });
  await api.request(req('c1')); // dossier créé : le compte est alors encore un client ordinaire
  assert.ok(db.store.get('account_deletions/c1'));
  // Promotion en administrateur APRÈS la demande, avant la fin du traitement.
  db.store.set('account_deletions/c1', { ...db.store.get('account_deletions/c1'), state: 'pending', reason: null, nextAttemptAt: NOW - 1, quarantinedAt: undefined });
  db.store.delete('account_tombstones/c1');
  db.store.set('admins/c1', { role: 'super_admin', isActive: true });
  calls.length = 0;
  await api.process('c1');
  assert.equal(db.store.get('account_deletions/c1').reason, 'admin_account_manual_process');
  assert.equal(db.store.has('account_tombstones/c1'), false);
  assert.deepEqual(calls, []);
});

test('D3 : un client ordinaire non administrateur n’est pas bloqué par la barrière', async () => {
  const { db, api, req } = engine({ 'clients/c2': { wallet: 0 } });
  await api.request(req('c2'));
  assert.ok(db.store.get('account_deletions/c2'));
  assert.notEqual(db.store.get('account_deletions/c2').reason, 'admin_account_manual_process');
});

// ── Cibles d'opérations d'administration ───────────────────────────────────────────────────────────────────────────
test('cible en suppression : tombstone sur l’un des identifiants ou profil anonymisé → refus ; autre cible → accepté', async () => {
  const db = fakeDb({ 'account_tombstones/owner-uid': { createdAt: ts(1) } });
  await rejectsWith(assertTargetNotClosing(db, HttpsError, ['pharma-1', 'owner-uid']), /suppression/i);
  await rejectsWith(assertTargetNotClosing(db, HttpsError, ['pharma-1'], { isDeleted: true }), /supprime/i);
  await assertTargetNotClosing(db, HttpsError, ['pharma-2', undefined]);
});
