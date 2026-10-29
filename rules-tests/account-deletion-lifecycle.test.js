'use strict';
// Cycle de vie de suppression avec des profils RÉALISTES (les champs réellement créés à l'approbation de chaque
// rôle), contrairement aux profils minimaux de account-deletion-real.test.js. Données fictives, émulateurs seulement.
// Exécution : firebase emulators:exec --config firebase.account-deletion-emulators.json --project demo-account-deletion
//   --only auth,firestore,storage "node --test --test-concurrency=1 rules-tests/account-deletion-lifecycle.test.js"
const test = require('node:test'), assert = require('node:assert/strict');
for (const [key, value] of Object.entries({ FIRESTORE_EMULATOR_HOST: '127.0.0.1:8198', FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9198', FIREBASE_STORAGE_EMULATOR_HOST: '127.0.0.1:9298' })) {
  if (process.env[key] !== value) throw Error('This test requires all three local emulators: ' + key);
}
const admin = require('../functions/node_modules/firebase-admin');
const { initializeApp, deleteApp } = require('firebase/app');
const { getAuth, connectAuthEmulator, signInWithEmailAndPassword } = require('firebase/auth');
const { getFirestore, connectFirestoreEmulator, doc, setDoc, terminate } = require('firebase/firestore');
const { buildAccountDeletion, QUIET_MS } = require('../functions/accountDeletion');
const { erasePersonalAssets } = require('../functions/accountPersonalAssets');

const projectId = 'demo-account-deletion', bucketName = projectId + '.appspot.com';
const PASSWORD = 'Fictitious-only-492!';
let backend, db, auth, bucket, now, api;
class HttpsError extends Error { constructor(code, message) { super(message); this.code = code; } }

test.before(async () => {
  backend = admin.initializeApp({ projectId, storageBucket: bucketName }, 'deletion-lifecycle');
  db = backend.firestore(); auth = backend.auth(); bucket = backend.storage().bucket();
  now = Date.now();
  api = buildAccountDeletion({ db, auth, admin, HttpsError, clock: () => now,
    eraseAssets: async (uid, role) => { await erasePersonalAssets(bucket, uid, role); } });
  await db.doc('operations_control/account_deletion').set({ enabled: true, inventoryVersion: 1, partnerInventoryVersion: 1 });
});
test.after(async () => { await backend.delete(); });

async function signedAccount(uid) {
  await auth.createUser({ uid, email: uid + '@example.test', password: PASSWORD });
  const app = initializeApp({ projectId, apiKey: 'fake-api-key' }, uid), sdk = getAuth(app);
  connectAuthEmulator(sdk, 'http://127.0.0.1:9198', { disableWarnings: true });
  const signed = await signInWithEmailAndPassword(sdk, uid + '@example.test', PASSWORD);
  const token = await auth.verifyIdToken(await signed.user.getIdToken());
  now = Date.now();
  return { app, token };
}

const PERSONAL_KEYS = ['name', 'ownerName', 'phone', 'email', 'address', 'lat', 'lng', 'operatorNumbers',
  'depositAccounts', 'agencyName', 'identifiant', 'photoUrl', 'idPhotoUrl', 'idNumber'];

// Profils tels que créés à l'approbation (admin_*_requests_page.dart, ek_agent_register.dart, realestate.js, fleet_register.dart).
const realisticProfiles = {
  seller: (uid) => ({ col: 'sellers', data: { uid, ownerName: 'Fictif Vendeur', shopName: 'Boutique fictive', phone: '0700000001', address: 'Rue 1',
    category: 'mode', lat: 6.73, lng: -3.49, wallet: 0, isActive: true } }),
  restaurant: (uid) => ({ col: 'restaurant_owners', data: { uid, phone: '0700000002', ownerName: 'Fictif Resto', restaurantId: 'resto-' + uid,
    mustChangePassword: false }, business: { path: 'restaurants/resto-' + uid, data: { name: 'Resto fictif', wallet: 0, isActive: true } } }),
  boulangerie: (uid) => ({ col: 'boulangeries', data: { uid, ownerName: 'Fictif Boulanger', name: 'Boulangerie fictive', phone: '0700000003', address: 'Rue 3',
    lat: 6.73, lng: -3.49, wallet: 0, isActive: true, isOpen: false } }),
  ekbine_agent: (uid) => ({ col: 'ekbine_agents', data: { name: 'Fictif Agent', phone: '0700000004', city: 'Abengourou', operators: ['mtn'],
    operatorNumbers: { mtn: '0500000004' }, depositAccounts: [{ id: 'a', operator: 'mtn', number: '0500000004', isActive: true }],
    walletBalance: 0, isVerified: true, isSuspended: false, totalCompleted: 0 } }),
  real_estate_agent: (uid) => ({ col: 'real_estate_agents', data: { uid, name: 'Fictif Immo', phone: '0700000005', agencyName: 'Agence fictive',
    city: 'Abengourou', isVerified: true, isActive: true } }),
  fleet_owner: (uid) => ({ col: 'fleet_owners', data: { name: 'Fictif Patron', phone: '0700000006', identifiant: 'patron-fictif', status: 'approved',
    photoUrl: 'u', idPhotoUrl: 'u', idNumber: 'CI000', createdAt: new Date() } }),
};

for (const role of Object.keys(realisticProfiles)) {
  test(role + ' : après suppression, plus aucune donnée personnelle dans le profil réaliste, finances conservées', async () => {
    const uid = 'life-' + role + '-' + Date.now();
    const { app, token } = await signedAccount(uid);
    try {
      const p = realisticProfiles[role](uid);
      if (p.business) await db.doc(p.business.path).set(p.business.data);
      await db.doc(p.col + '/' + uid).set(p.data);
      const r = await api.request({ auth: { uid, token }, data: { role, recoveryToken: 'e'.repeat(64), allProfilesConsent: true } });
      assert.equal(r.status, 'quarantined');
      now += QUIET_MS + 1;
      assert.equal((await api.process(uid)).status, 'completed');
      await assert.rejects(auth.getUser(uid), (e) => e.code === 'auth/user-not-found');
      const after = (await db.doc(p.col + '/' + uid).get()).data();
      assert.equal(after.isDeleted, true);
      for (const key of PERSONAL_KEYS) assert.equal(after[key], undefined, role + ' conserve encore « ' + key + ' »');
      if ('wallet' in p.data) assert.equal(after.wallet, 0);
      if ('walletBalance' in p.data) assert.equal(after.walletBalance, 0);
    } finally { await deleteApp(app); }
  });
}

test('livreur : selfies d\'acceptation (tous les ordres) effacés de Storage, ceux des autres livreurs et les montants conservés', async () => {
  const uid = 'life-selfie-' + Date.now(), other = 'someone-else-' + Date.now();
  const { app, token } = await signedAccount(uid);
  try {
    await db.doc('livreurs/' + uid).set({ wallet: 0, name: 'Fictif Livreur', phone: '0700000007', isOnDelivery: false });
    const mine = ['o1', 'o2'].map((o) => bucket.file('acceptance_selfies/' + o + '/' + uid + '.jpg'));
    const theirs = bucket.file('acceptance_selfies/o1/' + other + '.jpg');
    for (const f of [...mine, theirs]) await f.save(Buffer.from('fictitious selfie'), { contentType: 'image/jpeg' });
    await db.doc('orders/' + uid + '-o1').set({ driverId: uid, clientId: 'fictitious-client', status: 'delivered', budget: 1000, isPaid: true,
      paymentMethod: 'cash', driverName: 'Fictif Livreur', driverAcceptanceSelfie: 'https://example.test/selfie.jpg' });
    const r = await api.request({ auth: { uid, token }, data: { role: 'livreur', recoveryToken: 'f'.repeat(64), allProfilesConsent: true } });
    assert.equal(r.status, 'quarantined', 'raison: ' + r.reason);
    now += QUIET_MS + 1;
    assert.equal((await api.process(uid)).status, 'completed');
    for (const f of mine) assert.equal((await f.exists())[0], false);
    assert.equal((await theirs.exists())[0], true);
    const order = (await db.doc('orders/' + uid + '-o1').get()).data();
    assert.equal(order.budget, 1000);
    assert.equal(order.driverAcceptanceSelfie, undefined);
    assert.equal(order.driverName, undefined);
  } finally { await deleteApp(app); }
});

test('artisan et prestataire d\'événements : la demande entre dans la file manuelle ; un rôle inconnu est refusé', async () => {
  const app = initializeApp({ projectId, apiKey: 'fake-api-key' }, 'manual-roles-' + Date.now());
  const sdkDb = getFirestore(app); connectFirestoreEmulator(sdkDb, '127.0.0.1', 8198);
  try {
    for (const role of ['artisan', 'event_provider']) {
      await setDoc(doc(sdkDb, 'account_deletion_requests', 'req-' + role + Date.now()),
        { role, contactPhone: '0700000008', status: 'pending', requestedVia: 'app' });
    }
    await assert.rejects(setDoc(doc(sdkDb, 'account_deletion_requests', 'req-forged' + Date.now()),
      { role: 'admin', contactPhone: '0700000008', status: 'pending', requestedVia: 'app' }), (e) => e.code === 'permission-denied');
  } finally { await terminate(sdkDb); await deleteApp(app); }
});
