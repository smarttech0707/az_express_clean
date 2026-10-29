'use strict';

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

function setup({ seed = {}, bucketFailures = 0, users = {} } = {}) {
  const db = fakeDb({ 'admins/root': { role: 'super', isActive: true }, ...seed });
  // Le faux Firestore ne connaît pas FieldValue.delete() : on le traduit en suppression de clé.
  const baseUpdate = db.collection;
  const authUsers = new Map(Object.entries(users));
  const deletedPrefixes = [];
  let failures = bucketFailures;
  const bucket = {
    deleteFiles: async ({ prefix }) => { if (failures-- > 0) throw new Error('storage down'); deletedPrefixes.push(prefix); },
  };
  const auth = {
    getUser: async (uid) => { if (!authUsers.has(uid)) throw Object.assign(new Error('nf'), { code: 'auth/user-not-found' }); return authUsers.get(uid); },
    deleteUser: async (uid) => { authUsers.delete(uid); },
    updateUser: async () => {},
    revokeRefreshTokens: async (uid) => { authUsers.get(uid).revoked = true; },
  };
  const audits = [];
  const run = buildManualAccountDeletion({
    db, auth, admin, bucket, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); },
    requireSuperAdmin, clock: () => NOW,
  }).run;
  const req = (data, { uid = 'root', provider = 'password', authTime = NOW / 1000 - 30 } = {}) => ({
    auth: uid ? { uid, token: { auth_time: authTime, firebase: { sign_in_provider: provider } } } : undefined,
    data: { requestId: 'r1', identityVerification: verification, ...data },
  });
  void baseUpdate;
  return { db, run, req, authUsers, deletedPrefixes, audits };
}
const doc = (h, path) => h.db.store.get(path);
const request = (role, extra = {}) => ({ 'account_deletion_requests/r1': { role, contactPhone: '0700000001', status: 'pending', requestedVia: 'app', ...extra } });

// ── Autorisation et vérification d'identité (communes) ────────────────────────────────────────────────
test('autorisation : seul un super-admin récemment authentifié peut supprimer ; aucune suppression sinon', async () => {
  const seed = { ...request('artisan'), 'service_providers/s1': { phone: '0700000001', artisanUid: 'anon-A' }, 'artisan_credentials/s1': { hash: 'h' },
    'admins/sub1': { role: 'sub', isActive: true, permissions: ['services'] } };
  const cases = [
    [{ uid: null }, 'unauthenticated'],
    [{ provider: 'anonymous' }, 'unauthenticated'],
    [{ uid: 'inconnu' }, 'permission-denied'],
    [{ uid: 'sub1' }, 'permission-denied'],
    [{ authTime: NOW / 1000 - 3600 }, 'permission-denied'],
  ];
  for (const [opts, code] of cases) {
    const h = setup({ seed, users: { 'anon-A': { providerData: [] } } });
    await assert.rejects(() => h.run(h.req({}, opts)), (e) => e.code === code, JSON.stringify(opts));
    assert.ok(doc(h, 'service_providers/s1'));
    assert.ok(doc(h, 'artisan_credentials/s1'));
    assert.equal(h.authUsers.size, 1);
  }
});

test('attestation d\'identité obligatoire (méthode connue + note de 10 à 300 caractères)', async () => {
  for (const identityVerification of [undefined, {}, { method: 'sms', note: 'x'.repeat(20) }, { method: 'callback', note: 'court' },
    { method: 'callback', note: 'x'.repeat(301) }, { method: 'callback' }]) {
    const h = setup({ seed: { ...request('artisan'), 'service_providers/s1': { phone: '0700000001' } } });
    await assert.rejects(() => h.run(h.req({ identityVerification })), (e) => e.code === 'invalid-argument');
    assert.ok(doc(h, 'service_providers/s1'));
  }
});

test('demande inconnue, rôle géré par le moteur automatique, ou déjà terminée', async () => {
  let h = setup();
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'not-found');
  h = setup({ seed: request('client') });
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'failed-precondition');
  h = setup({ seed: request('artisan', { status: 'completed' }) });
  assert.equal((await h.run(h.req({}))).data.alreadyDone, true);
});

// ── Artisan (sans Firebase Auth) ───────────────────────────────────────────────────────────────────
test('artisan : suppression effective — profil, hash du PIN, fichiers et session anonyme ; reçu sans donnée personnelle', async () => {
  const h = setup({
    seed: { ...request('artisan', { contactEmail: 'a@b.test', uid: 'x', reason: 'Je veux partir' }),
      'service_providers/s1': { name: 'Maçon', phone: '07 00 00 00 01', artisanUid: 'anon-A', photos: ['u'] },
      'artisan_credentials/s1': { hash: 'h' }, 'service_providers/s2': { name: 'Autre', phone: '0799999999', artisanUid: 'anon-B' } },
    users: { 'anon-A': { providerData: [] }, 'anon-B': { providerData: [] } },
  });
  const res = await h.run(h.req({}));
  assert.equal(res.data.status, 'completed');
  assert.equal(doc(h, 'service_providers/s1'), undefined);
  assert.equal(doc(h, 'artisan_credentials/s1'), undefined);
  assert.ok(doc(h, 'service_providers/s2'), 'les autres artisans ne sont pas touchés');
  assert.deepEqual(h.deletedPrefixes, ['service_providers/s1/']);
  assert.equal(h.authUsers.has('anon-A'), false);
  assert.equal(h.authUsers.has('anon-B'), true);
  const receipt = doc(h, 'account_deletion_requests/r1');
  assert.equal(receipt.status, 'completed');
  assert.equal(receipt.processedBy, 'root');
  assert.equal(receipt.identityVerification.method, 'callback');
  for (const key of ['contactPhone', 'contactEmail', 'uid']) assert.ok(receipt[key] === DELETE_MARK || receipt[key] === undefined, key);
  assert.equal(h.audits[0].action, 'manual_account_deletion');
});

test('artisan : téléphone inconnu ou partagé par deux profils → refus sans suppression', async () => {
  let h = setup({ seed: { ...request('artisan'), 'service_providers/s1': { phone: '0711111111' } } });
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'failed-precondition');
  assert.ok(doc(h, 'service_providers/s1'));
  h = setup({ seed: { ...request('artisan'), 'service_providers/s1': { phone: '0700000001' }, 'service_providers/s2': { phone: '0700000001' } } });
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'failed-precondition');
  assert.ok(doc(h, 'service_providers/s1'));
  assert.ok(doc(h, 'service_providers/s2'));
});

test('échec Storage : rien n\'est annoncé comme supprimé, la reprise termine le travail', async () => {
  const h = setup({
    seed: { ...request('artisan'), 'service_providers/s1': { phone: '0700000001', artisanUid: 'anon-A' }, 'artisan_credentials/s1': { hash: 'h' } },
    users: { 'anon-A': { providerData: [] } }, bucketFailures: 1,
  });
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'internal');
  assert.equal(doc(h, 'account_deletion_requests/r1').status, 'cleanup_pending');
  assert.ok(doc(h, 'service_providers/s1'));
  assert.equal((await h.run(h.req({}))).data.status, 'completed');
  assert.equal(doc(h, 'service_providers/s1'), undefined);
  assert.equal(doc(h, 'artisan_credentials/s1'), undefined);
});

// ── Pharmacie historique (sans Firebase Auth) ────────────────────────────────────────────────────────
const pharmacy = { name: 'Pharmacie Test', ownerName: 'Titulaire', phone: '0700000001', address: 'Rue 9', lat: 6.7, lng: -3.4, currentUid: 'anon-P', wallet: 0, isActive: true };

test('pharmacie historique : identifiants et données personnelles supprimés, finances et commandes conservées', async () => {
  const h = setup({
    seed: { ...request('pharmacie'), 'pharmacies/p1': { ...pharmacy }, 'pharmacie_credentials/p1': { hash: 'h' },
      'orders/o1': { pharmacieId: 'p1', status: 'delivered', budget: 1500 } },
    users: { 'anon-P': { providerData: [] } },
  });
  assert.equal((await h.run(h.req({}))).data.status, 'completed');
  assert.equal(doc(h, 'pharmacie_credentials/p1'), undefined);
  assert.equal(h.authUsers.has('anon-P'), false);
  const after = doc(h, 'pharmacies/p1');
  assert.equal(after.isDeleted, true);
  assert.equal(after.isActive, false);
  assert.equal(after.wallet, 0);
  for (const key of ['ownerName', 'phone', 'address', 'lat', 'lng', 'currentUid', 'name']) assert.equal(after[key], DELETE_MARK, key);
  assert.equal(doc(h, 'orders/o1').budget, 1500);
  assert.deepEqual(h.deletedPrefixes, ['pharmacie_logos/p1/']);
});

test('pharmacie : solde non nul, commande en cours ou responsable lié → bloquée, aucun identifiant supprimé', async () => {
  const blocked = [
    [{ 'pharmacies/p1': { ...pharmacy, wallet: 400 } }, 'balance_regularization_required'],
    [{ 'pharmacies/p1': { ...pharmacy }, 'orders/o1': { pharmacieId: 'p1', status: 'accepted' } }, 'active_or_unresolved_operation'],
    [{ 'pharmacies/p1': { ...pharmacy }, 'pharmacy_owners/u1': { pharmacyId: 'p1', uid: 'u1' } }, 'linked_owner_uses_automatic_deletion'],
  ];
  for (const [extra, reason] of blocked) {
    const h = setup({ seed: { ...request('pharmacie'), 'pharmacie_credentials/p1': { hash: 'h' }, ...extra }, users: { 'anon-P': { providerData: [] } } });
    const res = await h.run(h.req({}));
    assert.equal(res.data.status, 'blocked');
    assert.equal(res.data.reason, reason);
    assert.equal(doc(h, 'account_deletion_requests/r1').status, 'blocked');
    assert.ok(doc(h, 'pharmacie_credentials/p1'));
    assert.equal(h.authUsers.has('anon-P'), true);
    assert.equal(doc(h, 'pharmacies/p1').isDeleted, undefined);
    assert.equal(h.deletedPrefixes.length, 0);
  }
});

// ── Prestataire d'événements ────────────────────────────────────────────────────────────────────────
const eventProvider = { ownerId: 'owner1', shopName: 'DJ Test', phone: '0700000001', description: 'desc', status: 'approved' };

test('prestataire d\'événements : compte Auth, fichiers, offres et profil supprimés ; réservations conservées', async () => {
  const h = setup({
    seed: { ...request('event_provider', { uid: 'owner1' }), 'event_providers/e1': { ...eventProvider },
      'event_provider_documents/e1': { ownerId: 'owner1' },
      'event_reservations/res1': { providerIds: ['e1'], status: 'completed', totalAmount: 50000 } },
    users: { owner1: { providerData: [{ providerId: 'password' }] } },
  });
  const res = await h.run(h.req({}));
  assert.equal(res.data.status, 'completed');
  assert.equal(h.authUsers.has('owner1'), false);
  assert.ok(doc(h, 'account_tombstones/owner1'));
  assert.equal(doc(h, 'event_provider_documents/e1'), undefined);
  assert.deepEqual(h.deletedPrefixes.sort(), ['event_offers/owner1/', 'event_providers/owner1/']);
  const after = doc(h, 'event_providers/e1');
  assert.equal(after.isDeleted, true);
  assert.equal(after.isSuspended, true);
  for (const key of ['shopName', 'phone', 'description']) assert.equal(after[key], DELETE_MARK, key);
  assert.equal(doc(h, 'event_reservations/res1').totalAmount, 50000);
  assert.equal(doc(h, 'account_deletion_requests/r1').identityVerification.ownerSessionProof, true);
});

test('prestataire d\'événements : réservation active, compte multirôle ou profil introuvable → rien n\'est supprimé', async () => {
  let h = setup({
    seed: { ...request('event_provider', { uid: 'owner1' }), 'event_providers/e1': { ...eventProvider },
      'event_reservations/res1': { providerIds: ['e1'], status: 'pending', totalAmount: 1000 } },
    users: { owner1: { providerData: [{ providerId: 'password' }] } },
  });
  let res = await h.run(h.req({}));
  assert.equal(res.data.reason, 'active_or_unresolved_operation');
  assert.equal(h.authUsers.has('owner1'), true);
  assert.equal(doc(h, 'event_providers/e1').deletionRequested, true); // plus de nouvelle activité pendant le blocage
  assert.equal(doc(h, 'event_providers/e1').shopName, 'DJ Test');

  h = setup({
    seed: { ...request('event_provider', { uid: 'owner1' }), 'event_providers/e1': { ...eventProvider }, 'clients/owner1': { wallet: 0 } },
    users: { owner1: { providerData: [] } },
  });
  res = await h.run(h.req({}));
  assert.equal(res.data.reason, 'multiple_roles_manual_review');
  assert.equal(h.authUsers.has('owner1'), true);

  h = setup({ seed: { ...request('event_provider', { uid: 'autre' }), 'event_providers/e1': { ...eventProvider, phone: '0711111111' } } });
  await assert.rejects(() => h.run(h.req({})), (e) => e.code === 'failed-precondition');
});

test('prestataire d\'événements : demande sans uid (web) = preuve par téléphone seulement, journalisée comme telle', async () => {
  const h = setup({
    seed: { ...request('event_provider'), 'event_providers/e1': { ...eventProvider } },
    users: { owner1: { providerData: [] } },
  });
  await h.run(h.req({}));
  assert.equal(doc(h, 'account_deletion_requests/r1').identityVerification.ownerSessionProof, false);
  assert.equal(h.authUsers.has('owner1'), false);
});
