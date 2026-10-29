'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildCreateFleetDriver, MAX_DRIVERS_PER_FLEET } = require('../fleetDriverCreation');
const { fakeDb } = require('./fakeFirestore');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts' } } };
const valid = { name: 'Chauffeur Test', phone: '0700000001', identifiant: 'Chauffeur1', password: 'secret1' };

function setup({ seed = {}, authFailure = null, existingEmails = [] } = {}) {
  const db = fakeDb({ 'fleet_owners/f1': { name: 'Patron', status: 'approved' }, ...seed });
  const users = new Map(existingEmails.map((email, i) => [`pre${i}`, { email }]));
  const deleted = [];
  const auth = {
    createUser: async ({ email, password }) => {
      if (authFailure) throw authFailure;
      if ([...users.values()].some((u) => u.email === email)) throw Object.assign(new Error('exists'), { code: 'auth/email-already-exists' });
      const uid = `drv${users.size}`;
      users.set(uid, { email, password });
      return { uid };
    },
    deleteUser: async (uid) => { deleted.push(uid); users.delete(uid); },
  };
  const audits = [], limits = [];
  const run = buildCreateFleetDriver({
    db, auth, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async (...a) => { limits.push(a); },
    logAudit: async (a) => { audits.push(a); },
  }).run;
  const req = (data, uid = 'f1', provider = 'password') => ({
    auth: uid ? { uid, token: { firebase: { sign_in_provider: provider } } } : undefined,
    data: { ...valid, ...data },
  });
  return { db, auth, users, deleted, audits, limits, run, req };
}
const drivers = (h) => [...h.db.store.keys()].filter((k) => k.startsWith('livreurs/'));
const refuses = async (h, request, code) => {
  await assert.rejects(() => h.run(request), (e) => e.code === code);
  assert.equal(drivers(h).length, 0);
  assert.equal(h.users.size, 0);
};

test('patron approuvé : compte Auth et document livreur créés, rattachés à la flotte, solde 0, hors ligne', async () => {
  const h = setup();
  const res = await h.run(h.req());
  assert.equal(res.success, true);
  assert.equal(res.code, 'OK');
  const [path] = drivers(h);
  const d = h.db.store.get(path);
  assert.equal(path, `livreurs/${res.data.driverId}`);
  assert.equal(d.ownerId, 'f1');
  assert.equal(d.ownerName, 'Patron');
  assert.equal(d.wallet, 0);
  assert.equal(d.isOnline, false);
  assert.equal(d.email, 'chauffeur1@az-driver.ci');
  assert.equal(d.identifiant, 'chauffeur1');
  assert.equal(h.users.size, 1);
  assert.equal(h.audits[0].action, 'fleet_driver_created');
  assert.deepEqual(h.limits[0], ['f1', 'create_fleet_driver', 10, 3600]);
});

test('aucun compte Auth orphelin : si le document échoue, le compte créé par cet appel est supprimé', async () => {
  const h = setup();
  const original = h.db.collection;
  h.db.collection = (name) => {
    const col = original(name);
    if (name !== 'livreurs') return col;
    return { ...col, doc: (id) => ({ ...col.doc(id), create: async () => { throw new Error('firestore down'); } }) };
  };
  await assert.rejects(() => h.run(h.req()), (e) => e.code === 'internal');
  assert.equal(h.users.size, 0);
  assert.deepEqual(h.deleted, ['drv0']);
  assert.equal(drivers(h).length, 0);
});

test('identifiant déjà pris : refus, aucun document, aucun second compte', async () => {
  const h = setup({ existingEmails: ['chauffeur1@az-driver.ci'] });
  await assert.rejects(() => h.run(h.req()), (e) => e.code === 'already-exists');
  assert.equal(drivers(h).length, 0);
  assert.equal(h.users.size, 1);
});

test('autorisation : non connecté, anonyme, simple livreur/client, patron en attente/refusé/suspendu/en suppression', async () => {
  let h = setup();
  await refuses(h, h.req({}, null), 'unauthenticated');
  await refuses(h, h.req({}, 'f1', 'anonymous'), 'unauthenticated');
  await refuses(h, h.req({}, 'client9'), 'permission-denied');
  for (const owner of [
    { status: 'pending' }, { status: 'rejected' }, { status: 'approved', isSuspended: true },
    { status: 'approved', isActive: false }, { status: 'approved', deletionRequested: true }, { status: 'approved', isDeleted: true },
  ]) {
    h = setup({ seed: { 'fleet_owners/f1': { name: 'Patron', ...owner } } });
    await refuses(h, h.req(), 'permission-denied');
  }
  h = setup({ seed: { 'account_tombstones/f1': { state: 'deleting' } } });
  await refuses(h, h.req(), 'permission-denied');
  // Compte historique sans champ status : approuvé (même lecture que fleet_login.dart).
  h = setup({ seed: { 'fleet_owners/f1': { name: 'Ancien patron' } } });
  assert.equal((await h.run(h.req())).success, true);
});

test('patron créé par l\'admin : refus tant que le mot de passe temporaire n\'est pas changé', async () => {
  const h = setup({ seed: { 'partner_provisioning/f1': { mustChangePassword: true } } });
  await refuses(h, h.req(), 'failed-precondition');
});

test('plafond de livreurs par flotte', async () => {
  const seed = {};
  for (let i = 0; i < MAX_DRIVERS_PER_FLEET; i++) seed[`livreurs/old${i}`] = { ownerId: 'f1' };
  seed['livreurs/autre'] = { ownerId: 'f2' };
  const h = setup({ seed });
  await assert.rejects(() => h.run(h.req()), (e) => e.code === 'failed-precondition');
  assert.equal(h.users.size, 0);
});

test('entrées invalides refusées avant toute création', async () => {
  for (const bad of [
    { name: '' }, { name: 'x'.repeat(81) }, { phone: 'abc' }, { phone: '' },
    { identifiant: 'ab' }, { identifiant: 'a/b/c' }, { identifiant: 'avec espace' }, { identifiant: 'x'.repeat(31) },
    { password: '123' }, { password: undefined }, { password: 'x'.repeat(129) },
  ]) {
    const h = setup();
    await refuses(h, h.req(bad), 'invalid-argument');
  }
});
