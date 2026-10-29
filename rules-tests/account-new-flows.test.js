'use strict';
// Nouveaux flux (patron de flotte, photos artisan, suppression manuelle) sur de VRAIS Auth/Firestore/Storage émulés.
// Données fictives. Exécution :
//   firebase emulators:exec --config firebase.account-deletion-emulators.json --project demo-account-deletion
//     --only auth,firestore,storage "node --test --test-concurrency=1 rules-tests/account-new-flows.test.js"
const test = require('node:test'), assert = require('node:assert/strict');
for (const [key, value] of Object.entries({ FIRESTORE_EMULATOR_HOST: '127.0.0.1:8198', FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9198', FIREBASE_STORAGE_EMULATOR_HOST: '127.0.0.1:9298' })) {
  if (process.env[key] !== value) throw Error('This test requires all three local emulators: ' + key);
}
const admin = require('../functions/node_modules/firebase-admin');
const fnRequire = require('node:module').createRequire(require('node:path').join(__dirname, '../functions/package.json'));
const { HttpsError } = fnRequire('firebase-functions/v2/https');
const { buildCreateFleetDriver } = require('../functions/fleetDriverCreation');
const { buildManageArtisanPhotos } = require('../functions/artisanPhotos');
const { buildManualAccountDeletion } = require('../functions/manualAccountDeletion');
const { requireSuperAdmin } = require('../functions/adminGuards');

const projectId = 'demo-account-deletion', bucketName = projectId + '.appspot.com';
let backend, db, auth, bucket;
const noLimit = async () => {};
const audits = [];
const logAudit = async (a) => { audits.push(a); };
const onCall = (h) => ({ run: h });
const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200, 7)]);

test.before(() => {
  backend = admin.initializeApp({ projectId, storageBucket: bucketName }, 'new-flows');
  db = backend.firestore(); auth = backend.auth(); bucket = backend.storage().bucket();
});
test.after(async () => { await backend.delete(); });

const callerAuth = (uid, extra = {}) => ({ uid, token: { auth_time: Date.now() / 1000, firebase: { sign_in_provider: 'password' }, ...extra } });
const userExists = async (uid) => { try { await auth.getUser(uid); return true; } catch (e) { if (e.code === 'auth/user-not-found') return false; throw e; } };

// ── Patron de flotte ─────────────────────────────────────────────────────────────────────────────────
test('patron de flotte : compte Auth + document livreur créés, puis aucun orphelin si Firestore échoue', async () => {
  const owner = 'fleet-' + Date.now();
  await db.doc('fleet_owners/' + owner).set({ name: 'Patron Fictif', status: 'approved' });
  const build = (database) => buildCreateFleetDriver({ db: database, auth, admin, onCall, HttpsError, checkRateLimit: noLimit, logAudit }).run;
  const data = (id) => ({ name: 'Chauffeur Fictif', phone: '0700000011', identifiant: id, password: 'Fictitious-492' });
  const id = 'chauf' + Date.now();
  const res = await build(db)({ auth: callerAuth(owner), data: data(id) });
  const user = await auth.getUser(res.data.driverId);
  assert.equal(user.email, id + '@az-driver.ci');
  const driver = (await db.doc('livreurs/' + res.data.driverId).get()).data();
  assert.equal(driver.ownerId, owner);
  assert.equal(driver.wallet, 0);

  // Identifiant déjà pris : refus, pas de second compte.
  await assert.rejects(() => build(db)({ auth: callerAuth(owner), data: data(id) }), (e) => e.code === 'already-exists');

  // Échec Firestore : le compte Auth créé par l'appel est supprimé.
  const failing = new Proxy(db, { get: (target, prop) => prop === 'collection'
    ? (name) => name === 'livreurs' && true
      ? { ...target.collection(name), doc: () => ({ create: async () => { throw new Error('firestore down'); } }), where: (...a) => target.collection(name).where(...a) }
      : target.collection(name)
    : Reflect.get(target, prop).bind ? Reflect.get(target, prop).bind(target) : Reflect.get(target, prop) });
  const orphanId = 'orphan' + Date.now();
  await assert.rejects(() => build(failing)({ auth: callerAuth(owner), data: data(orphanId) }), (e) => e.code === 'internal');
  await assert.rejects(auth.getUserByEmail(orphanId + '@az-driver.ci'), (e) => e.code === 'auth/user-not-found');
});

// ── Photos artisan (vrai Storage) ────────────────────────────────────────────────────────────────────
test('artisan : ajout puis suppression de photo dans Storage ; un autre artisan est refusé', async () => {
  const docId = 'art-' + Date.now();
  await db.doc('service_providers/' + docId).set({ name: 'Maçon Fictif', phone: '0700000012', artisanUid: 'anon-mine', photos: [] });
  const run = buildManageArtisanPhotos({ db, admin, bucket, onCall, HttpsError, checkRateLimit: noLimit, logAudit }).run;
  const asArtisan = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'anonymous' } } }, data });
  const added = await run(asArtisan('anon-mine', { action: 'add', docId, imageBase64: JPEG.toString('base64') }));
  const path = decodeURIComponent(/\/o\/([^?]+)/.exec(added.data.url)[1]);
  assert.match(path, new RegExp('^service_providers/' + docId + '/photo_'));
  assert.equal((await bucket.file(path).exists())[0], true);
  assert.deepEqual((await db.doc('service_providers/' + docId).get()).data().photos, [added.data.url]);
  await assert.rejects(() => run(asArtisan('anon-other', { action: 'delete', docId, url: added.data.url })), (e) => e.code === 'permission-denied');
  assert.equal((await bucket.file(path).exists())[0], true);
  await run(asArtisan('anon-mine', { action: 'delete', docId, url: added.data.url }));
  assert.equal((await bucket.file(path).exists())[0], false);
  assert.deepEqual((await db.doc('service_providers/' + docId).get()).data().photos, []);
});

// ── Suppression manuelle (vrais Auth + Storage) ──────────────────────────────────────────────────────
const sup = 'root-' + Date.now();
const manual = () => buildManualAccountDeletion({ db, auth, admin, bucket, onCall, HttpsError, checkRateLimit: noLimit, logAudit, requireSuperAdmin }).run;
const verification = { method: 'in_person', note: 'Titulaire présent au bureau avec sa pièce' };
const ask = async (id, role, extra = {}) => db.doc('account_deletion_requests/' + id).set({ role, contactPhone: extra.phone || '0700000099', status: 'pending', requestedVia: 'app', ...extra.fields });
test('préparation super-admin', async () => { await db.doc('admins/' + sup).set({ role: 'super', isActive: true }); });

test('artisan : profil, hash du PIN, photos Storage et session anonyme réellement supprimés', async () => {
  const id = 'art-del-' + Date.now(), phone = '0700' + String(Date.now()).slice(-6);
  const anon = await auth.createUser({});
  await db.doc('service_providers/' + id).set({ name: 'Maçon', phone, artisanUid: anon.uid, photos: ['x'] });
  await db.doc('artisan_credentials/' + id).set({ hash: 'secret-hash' });
  const photo = bucket.file('service_providers/' + id + '/photo_1.jpg'); await photo.save(JPEG, { contentType: 'image/jpeg' });
  await ask(id, 'artisan', { phone });
  const res = await manual()({ auth: callerAuth(sup), data: { requestId: id, identityVerification: verification } });
  assert.equal(res.data.status, 'completed');
  assert.equal((await db.doc('service_providers/' + id).get()).exists, false);
  assert.equal((await db.doc('artisan_credentials/' + id).get()).exists, false);
  assert.equal((await photo.exists())[0], false);
  assert.equal(await userExists(anon.uid), false);
  const receipt = (await db.doc('account_deletion_requests/' + id).get()).data();
  assert.equal(receipt.status, 'completed');
  assert.equal(receipt.contactPhone, undefined);
});

test('pharmacie historique : identifiants et session supprimés, solde 0 et commandes conservés ; solde non nul bloque', async () => {
  const id = 'ph-del-' + Date.now(), phone = '0701' + String(Date.now()).slice(-6);
  const anon = await auth.createUser({});
  await db.doc('pharmacies/' + id).set({ name: 'Pharmacie Fictive', ownerName: 'Titulaire', phone, address: 'Rue', currentUid: anon.uid, wallet: 0 });
  await db.doc('pharmacie_credentials/' + id).set({ hash: 'secret-hash' });
  await db.doc('orders/' + id + '-o1').set({ pharmacieId: id, status: 'delivered', budget: 2500 });
  const logo = bucket.file('pharmacie_logos/' + id + '/logo.jpg'); await logo.save(JPEG, { contentType: 'image/jpeg' });
  await ask(id, 'pharmacie', { phone });
  assert.equal((await manual()({ auth: callerAuth(sup), data: { requestId: id, identityVerification: verification } })).data.status, 'completed');
  const after = (await db.doc('pharmacies/' + id).get()).data();
  assert.equal(after.isDeleted, true);
  assert.equal(after.wallet, 0);
  for (const key of ['name', 'ownerName', 'phone', 'address', 'currentUid']) assert.equal(after[key], undefined, key);
  assert.equal((await db.doc('pharmacie_credentials/' + id).get()).exists, false);
  assert.equal((await logo.exists())[0], false);
  assert.equal(await userExists(anon.uid), false);
  assert.equal((await db.doc('orders/' + id + '-o1').get()).data().budget, 2500);

  const idB = 'ph-bal-' + Date.now(), phoneB = '0702' + String(Date.now()).slice(-6);
  await db.doc('pharmacies/' + idB).set({ name: 'Avec solde', phone: phoneB, wallet: 400 });
  await db.doc('pharmacie_credentials/' + idB).set({ hash: 'kept' });
  await ask(idB, 'pharmacie', { phone: phoneB });
  assert.equal((await manual()({ auth: callerAuth(sup), data: { requestId: idB, identityVerification: verification } })).data.status, 'blocked');
  assert.equal((await db.doc('pharmacie_credentials/' + idB).get()).exists, true);
  assert.equal((await db.doc('pharmacies/' + idB).get()).data().wallet, 400);
});

test('prestataire d\'événements : compte Auth, fichiers, offres supprimés ; reconnexion impossible ; réservations conservées', async () => {
  const stamp = Date.now(), pid = 'ev-' + stamp, phone = '0703' + String(stamp).slice(-6);
  const owner = await auth.createUser({ email: 'owner' + stamp + '@example.test', password: 'Fictitious-492!' });
  await db.doc('event_providers/' + pid).set({ ownerId: owner.uid, shopName: 'DJ Fictif', phone, description: 'desc', status: 'approved' });
  await db.doc('event_offers/' + pid + '-o1').set({ providerId: pid, ownerId: owner.uid, title: 'Offre' });
  await db.doc('event_reservations/' + pid + '-r1').set({ providerIds: [pid], status: 'completed', totalAmount: 30000 });
  const files = ['event_providers/' + owner.uid + '/' + pid + '/logo/a.jpg', 'event_offers/' + owner.uid + '/o1/b.jpg'].map((p) => bucket.file(p));
  for (const f of files) await f.save(JPEG, { contentType: 'image/jpeg' });
  await ask(pid, 'event_provider', { phone, fields: { uid: owner.uid } });
  assert.equal((await manual()({ auth: callerAuth(sup), data: { requestId: pid, identityVerification: verification } })).data.status, 'completed');
  assert.equal(await userExists(owner.uid), false);
  await assert.rejects(auth.getUserByEmail('owner' + stamp + '@example.test'), (e) => e.code === 'auth/user-not-found');
  for (const f of files) assert.equal((await f.exists())[0], false);
  assert.equal((await db.doc('event_offers/' + pid + '-o1').get()).exists, false);
  const profile = (await db.doc('event_providers/' + pid).get()).data();
  assert.equal(profile.isDeleted, true);
  assert.equal(profile.shopName, undefined);
  assert.equal((await db.doc('event_reservations/' + pid + '-r1').get()).data().totalAmount, 30000);
  assert.equal((await db.doc('account_tombstones/' + owner.uid).get()).exists, true);
});

test('prestataire d\'événements avec réservation active : bloqué, compte Auth intact', async () => {
  const stamp = Date.now() + 1, pid = 'ev-busy-' + stamp, phone = '0704' + String(stamp).slice(-6);
  const owner = await auth.createUser({ email: 'busy' + stamp + '@example.test', password: 'Fictitious-492!' });
  await db.doc('event_providers/' + pid).set({ ownerId: owner.uid, shopName: 'DJ Occupé', phone, status: 'approved' });
  await db.doc('event_reservations/' + pid + '-r1').set({ providerIds: [pid], status: 'pending', totalAmount: 1000 });
  await ask(pid, 'event_provider', { phone, fields: { uid: owner.uid } });
  assert.equal((await manual()({ auth: callerAuth(sup), data: { requestId: pid, identityVerification: verification } })).data.status, 'blocked');
  assert.equal(await userExists(owner.uid), true);
  assert.equal((await db.doc('event_providers/' + pid).get()).data().shopName, 'DJ Occupé');
});
