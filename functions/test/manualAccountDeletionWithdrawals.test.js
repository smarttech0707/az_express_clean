'use strict';

// L2.3 — la suppression manuelle (artisan, pharmacie historique, prestataire d'événements) contrôle les retraits avec le MÊME inspecteur
// que les suppressions automatiques (accountObligationsInspector.inspectWithdrawals). Faux Firestore en mémoire, aucun cloud.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildManualAccountDeletion } = require('../manualAccountDeletion');
const { requireSuperAdmin } = require('../adminGuards');
const { fakeDb } = require('./fakeFirestore');

const NOW = 1_800_000_000_000;
const DELETE_MARK = Symbol('field-delete');
const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE_MARK } } };
const verification = { method: 'callback', note: 'Rappel au numéro du dossier, identité confirmée' };

function setup({ seed = {}, users = {} } = {}) {
  const db = fakeDb({ 'admins/root': { role: 'super', isActive: true }, ...seed });
  const authUsers = new Map(Object.entries(users));
  const auth = {
    getUser: async (uid) => { if (!authUsers.has(uid)) throw Object.assign(new Error('nf'), { code: 'auth/user-not-found' }); return authUsers.get(uid); },
    deleteUser: async (uid) => { authUsers.delete(uid); },
    updateUser: async () => {},
    revokeRefreshTokens: async (uid) => { authUsers.get(uid).revoked = true; },
  };
  const run = buildManualAccountDeletion({
    db, auth, admin, bucket: { deleteFiles: async () => {} }, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin, clock: () => NOW,
  }).run;
  const req = () => ({ auth: { uid: 'root', token: { auth_time: NOW / 1000 - 30, firebase: { sign_in_provider: 'password' } } }, data: { requestId: 'r1', identityVerification: verification } });
  return { db, run, req, authUsers };
}
const doc = (h, path) => h.db.store.get(path);
const request = (role, extra = {}) => ({ 'account_deletion_requests/r1': { role, contactPhone: '0700000001', status: 'pending', requestedVia: 'app', ...extra } });

// Un jeu de données par rôle manuel ; `userId` = identifiant de profil OU de session (les deux sont contrôlés).
const ROLES = {
  artisan: {
    seed: { ...request('artisan'), 'service_providers/s1': { phone: '0700000001', artisanUid: 'anon-A' }, 'artisan_credentials/s1': { hash: 'h' } },
    users: { 'anon-A': { providerData: [] } }, profile: 'service_providers/s1', ids: ['s1', 'anon-A'],
  },
  pharmacie: {
    seed: { ...request('pharmacie'), 'pharmacies/p1': { phone: '0700000001', currentUid: 'anon-P', wallet: 0 }, 'pharmacie_credentials/p1': { hash: 'h' } },
    users: { 'anon-P': { providerData: [] } }, profile: 'pharmacies/p1', ids: ['p1', 'anon-P'],
  },
  event_provider: {
    seed: { ...request('event_provider', { uid: 'owner1' }), 'event_providers/e1': { ownerId: 'owner1', phone: '0700000001', status: 'approved' }, 'event_provider_documents/e1': { ownerId: 'owner1' } },
    users: { owner1: { providerData: [{ providerId: 'password' }] } }, profile: 'event_providers/e1', ids: ['e1', 'owner1'],
  },
};
const wd = (userId, over = {}) => ({ userId, userType: 'client', amount: 2000, provider: 'FeexPay', ...over });
const SETTLED = { status: 'sent', settlementConfirmed: true, needsReview: false };
const MANUAL = { status: 'processed', settlementConfirmed: true, processedBy: 'adm1' };
const REFUNDED = { status: 'failed_refunded', compensated: true, settlementConfirmed: false };
const CASES = [
  ['sent confirmé', [SETTLED], false],
  ['processed confirmé', [MANUAL], false],
  ['failed_refunded compensé', [REFUNDED], false],
  ['plusieurs retraits tous réglés', [SETTLED, MANUAL, REFUNDED], false],
  ['sent sans preuve', [{ status: 'sent' }], true, 'financial_regularization_required'],
  ['processed sans preuve', [{ status: 'processed' }], true, 'financial_regularization_required'],
  ['processed sans processedBy', [{ status: 'processed', settlementConfirmed: true }], true, 'financial_regularization_required'],
  ['failed_refunded sans preuve de compensation', [{ status: 'failed_refunded' }], true, 'financial_regularization_required'],
  ['processing', [{ status: 'processing' }], true, 'active_or_unresolved_operation'],
  ['provider_pending', [{ status: 'provider_pending' }], true, 'active_or_unresolved_operation'],
  ['pending_manual', [{ status: 'pending_manual' }], true, 'active_or_unresolved_operation'],
  ['réglé + en attente', [SETTLED, { status: 'processing' }], true, 'active_or_unresolved_operation'],
  ['statut inconnu', [{ status: 'weird' }], true, 'financial_regularization_required'],
  ['statut absent', [{ status: undefined }], true, 'financial_regularization_required'],
  ['montant absent (données incomplètes)', [{ ...SETTLED, amount: undefined }], true, 'financial_regularization_required'],
  ['drapeaux contradictoires', [{ status: 'sent', settlementConfirmed: true, compensated: true }], true, 'financial_regularization_required'],
  ['needsReview', [{ ...SETTLED, needsReview: true }], true, 'financial_regularization_required'],
];

for (const [role, cfg] of Object.entries(ROLES)) {
  for (const idIndex of [0, 1]) {
    for (const [label, parts, blocks, reason] of CASES) {
      test(`${role} : retrait ${label} (userId = ${idIndex === 0 ? 'profil' : 'session'}) -> ${blocks ? 'bloque' : 'autorise'}`, async () => {
        const userId = cfg.ids[idIndex];
        const withdrawals = Object.fromEntries(parts.map((p, i) => [`withdrawal_requests/w${i}`, wd(userId, p)]));
        const h = setup({ seed: { ...cfg.seed, ...withdrawals }, users: cfg.users });
        const res = await h.run(h.req());
        if (blocks) {
          assert.equal(res.data.status, 'blocked');
          assert.equal(res.data.reason, reason);
          assert.equal(doc(h, 'account_deletion_requests/r1').status, 'blocked');
          assert.equal(doc(h, 'account_deletion_requests/r1').reviewRequired, true);
          assert.ok(doc(h, cfg.profile), 'profil conservé');
          assert.notEqual(doc(h, cfg.profile).isDeleted, true);
          assert.equal(h.authUsers.size, Object.keys(cfg.users).length, 'aucun compte Auth supprimé');
        } else {
          assert.equal(res.data.status, 'completed');
        }
        // Les retraits ne sont jamais supprimés par la suppression manuelle (conservation financière).
        for (const key of Object.keys(withdrawals)) assert.ok(doc(h, key), key);
      });
    }
  }
}

test('un retrait d’un autre compte n’est pas pris en compte (suppression autorisée)', async () => {
  const h = setup({ seed: { ...ROLES.artisan.seed, 'withdrawal_requests/w1': wd('someone-else', { status: 'processing' }) }, users: ROLES.artisan.users });
  assert.equal((await h.run(h.req())).data.status, 'completed');
});

test('plafond de lecture : 201 retraits (même réglés) -> revue manuelle, rien n’est supprimé', async () => {
  const withdrawals = Object.fromEntries(Array.from({ length: 201 }, (_, i) => [`withdrawal_requests/w${i}`, wd('s1', SETTLED)]));
  const h = setup({ seed: { ...ROLES.artisan.seed, ...withdrawals }, users: ROLES.artisan.users });
  const res = await h.run(h.req());
  assert.deepEqual([res.data.status, res.data.reason], ['blocked', 'history_requires_manual_review']);
  assert.ok(doc(h, 'service_providers/s1'));
  assert.equal(h.authUsers.size, 1);
});

test('200 retraits réglés : sous le plafond, suppression autorisée', async () => {
  const withdrawals = Object.fromEntries(Array.from({ length: 200 }, (_, i) => [`withdrawal_requests/w${i}`, wd('s1', SETTLED)]));
  const h = setup({ seed: { ...ROLES.artisan.seed, ...withdrawals }, users: ROLES.artisan.users });
  assert.equal((await h.run(h.req())).data.status, 'completed');
});

test('erreur de lecture des retraits : la demande échoue, aucun nettoyage, jamais une liste vide', async () => {
  for (const [role, cfg] of Object.entries(ROLES)) {
    const h = setup({ seed: { ...cfg.seed, 'withdrawal_requests/w1': wd(cfg.ids[0], SETTLED) }, users: cfg.users });
    const original = h.db.collection;
    h.db.collection = (name) => {
      if (name !== 'withdrawal_requests') return original(name);
      const failing = { limit: () => failing, where: () => failing, get: async () => { throw new Error('read failure withdrawal_requests'); } };
      return failing;
    };
    await assert.rejects(() => h.run(h.req()), /read failure withdrawal_requests/, role);
    assert.notEqual(doc(h, 'account_deletion_requests/r1').status, 'completed', role);
    assert.notEqual(doc(h, cfg.profile).isDeleted, true, role);
    assert.equal(h.authUsers.size, Object.keys(cfg.users).length, role);
  }
});

test('contrôles d’autorisation inchangés : sans super-admin récent, aucun contrôle de retrait n’est même atteint', async () => {
  const h = setup({ seed: { ...ROLES.artisan.seed, 'withdrawal_requests/w1': wd('s1', SETTLED) }, users: ROLES.artisan.users });
  const bad = () => ({ ...h.req(), auth: { uid: 'inconnu', token: { auth_time: NOW / 1000 - 30, firebase: { sign_in_provider: 'password' } } } });
  await assert.rejects(() => h.run(bad()), (e) => e.code === 'permission-denied');
  assert.ok(doc(h, 'service_providers/s1'));
});
