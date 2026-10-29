'use strict';

// Test d'intégration contre les émulateurs Auth + Firestore (jamais la
// production). Ignoré automatiquement hors émulateur, donc sans effet sur
// `npm test`. Exécution :
//   npx firebase emulators:exec --only auth,firestore \
//     "node --test functions/test/adminPartnerAccounts.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST && process.env.FIREBASE_AUTH_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateurs Auth/Firestore requis' };

let admin; let db; let auth; let run; let audits;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  // Même projet que l'émulateur (--project) : sinon l'API REST d'authentification
  // cherche les comptes dans un autre projet que celui où Admin SDK les crée.
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'az-partner-accounts-test' });
  db = admin.firestore();
  auth = admin.auth();
  audits = [];
  const { buildManageAdminPartnerAccount } = require('../adminPartnerAccounts');
  run = buildManageAdminPartnerAccount({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {},
    logAudit: async (data) => { audits.push(data); },
    logSecurityEvent: async () => {},
  });
});

const asAdmin = (data) => ({
  auth: { uid: 'root', token: { firebase: { sign_in_provider: 'password' } } },
  data,
});
const profile = {
  name: 'Chez Awa', ownerName: 'Awa K', phone: '0700000011', address: 'Rue 1',
  category: 'Ivoirien', lat: 6.7, lng: -3.5, minDelivery: 500,
};

test.beforeEach(async () => {
  if (!emulated) return;
  await db.collection('admins').doc('root').set({ role: 'super', isActive: true });
});

test('émulateur: création restaurant complète (Auth réel + lot Firestore réel)', options, async () => {
  const email = '0700000011@az-restaurant.ci';
  const result = await run(asAdmin({
    action: 'create', kind: 'restaurant', email, profile,
  }));
  const user = await auth.getUserByEmail(email);
  assert.equal(user.uid, result.uid);
  const restaurant = (await db.collection('restaurants').doc(result.restaurantId).get()).data();
  assert.equal(restaurant.id, result.restaurantId);
  assert.equal(restaurant.isActive, true);
  assert.equal(restaurant.isOpen, false);
  assert.equal(restaurant.name, 'Chez Awa');
  const owner = (await db.collection('restaurant_owners').doc(result.uid).get()).data();
  assert.equal(owner.restaurantId, result.restaurantId);
  assert.equal(owner.uid, result.uid);
  const marker = (await db.collection('partner_provisioning').doc(result.uid).get()).data();
  assert.equal(marker.status, 'completed');
  assert.equal(JSON.stringify(marker).includes(result.tempPassword), false, 'mot de passe jamais en clair dans Firestore');
  assert.equal(marker.mustChangePassword, true);
  assert.equal((await auth.getUser(result.uid)).customClaims.partnerMustChangePassword, true);
});

test('émulateur: second appel avec le même identifiant → already-exists, rien d\'écrasé', options, async () => {
  const email = '0700000012@az-restaurant.ci';
  const first = await run(asAdmin({
    action: 'create', kind: 'restaurant', email, profile: { ...profile, phone: '0700000012' },
  }));
  await assert.rejects(run(asAdmin({
    action: 'create', kind: 'restaurant', email, profile: { ...profile, phone: '0700000012', name: 'Autre' },
  })), (e) => e.code === 'already-exists');
  const restaurant = (await db.collection('restaurants').doc(first.restaurantId).get()).data();
  assert.equal(restaurant.name, 'Chez Awa');
  const snapshot = await db.collection('restaurants').where('phone', '==', '0700000012').get();
  assert.equal(snapshot.size, 1);
});

test('émulateur: assignOwner réel — établissement existant intact, un seul responsable, second appel refusé', options, async () => {
  await db.collection('restaurants').doc('rest-hist').set({ name: 'Historique', phone: '0700000013', isActive: true });
  const base = {
    action: 'assignOwner', kind: 'restaurant', restaurantId: 'rest-hist',
    ownerName: 'Moussa', phone: '0700000013',
  };
  const result = await run(asAdmin({ ...base, email: '0700000013@az-restaurant.ci' }));
  assert.equal(result.restaurantId, 'rest-hist');
  assert.deepEqual((await db.collection('restaurants').doc('rest-hist').get()).data(),
    { name: 'Historique', phone: '0700000013', isActive: true });
  assert.equal((await db.collection('restaurants').get()).docs
    .filter((doc) => doc.data().phone === '0700000013').length, 1);
  const owner = (await db.collection('restaurant_owners').doc(result.uid).get()).data();
  assert.equal(owner.restaurantId, 'rest-hist');
  await assert.rejects(run(asAdmin({ ...base, email: '0700000014@az-restaurant.ci' })),
    (e) => e.code === 'already-exists');
  assert.equal((await db.collection('restaurant_owners').where('restaurantId', '==', 'rest-hist').get()).size, 1);
  await assert.rejects(auth.getUserByEmail('0700000014@az-restaurant.ci'));
});

test('émulateur: vendeur et boulangerie complets, isActive posé par le serveur', options, async () => {
  const seller = await run(asAdmin({
    action: 'create', kind: 'seller', email: '0700000015@az-seller.ci',
    profile: { name: 'Boutique A', phone: '0700000015', type: 'boutique', lat: 6.7, lng: -3.5 },
  }));
  const sellerDoc = (await db.collection('sellers').doc(seller.uid).get()).data();
  assert.equal(sellerDoc.isActive, true);
  assert.equal(sellerDoc.wallet, 0);
  const bakery = await run(asAdmin({
    action: 'create', kind: 'boulangerie', email: '0700000016@az-boulangerie.ci',
    profile: { name: 'Pain', address: 'Rue', phone: '0700000016', openTime: '06:00', closeTime: '20:00', lat: 6.7, lng: -3.5 },
  }));
  const bakeryDoc = (await db.collection('boulangeries').doc(bakery.uid).get()).data();
  assert.equal(bakeryDoc.isActive, true);
  assert.equal(bakeryDoc.isOpen, false);
  assert.equal(bakeryDoc.wallet, 0);
});

test('émulateur: échec du lot (document déjà présent) → compte Auth neuf supprimé, aucun orphelin', options, async () => {
  // Force un échec réel de `create()` : le verrou du futur établissement existe déjà.
  const original = db.collection('restaurants').doc;
  let forcedId;
  db.collection('restaurants').constructor.prototype.doc = function patched(...args) {
    const ref = original.apply(this, args);
    if (!args.length) {
      forcedId = ref.id;
      db.collection('restaurant_owner_locks').doc(forcedId).set({ ownerUid: 'blocker' });
    }
    return ref;
  };
  const email = '0700000017@az-restaurant.ci';
  try {
    await assert.rejects(run(asAdmin({
      action: 'create', kind: 'restaurant', email, profile: { ...profile, phone: '0700000017' },
    })), (e) => e.code === 'internal');
  } finally {
    db.collection('restaurants').constructor.prototype.doc = original;
  }
  await new Promise((resolve) => setTimeout(resolve, 200));
  await assert.rejects(auth.getUserByEmail(email), 'le compte Auth neuf doit avoir été supprimé');
  assert.equal((await db.collection('restaurants').doc(forcedId).get()).exists, false);
});

// ── Première connexion de bout en bout (Auth émulé réel) ────────────────────
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST;
async function signIn(email, password) {
  const response = await fetch(
    `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-key`,
    {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    });
  return { ok: response.ok, body: await response.json() };
}
function requestFromToken(decoded, data) {
  return { auth: { uid: decoded.uid, token: decoded }, data };
}

test("émulateur: première connexion complète — mot de passe temporaire, changement obligatoire, reconnexion, ancien mot de passe invalide", options, async () => {
  const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');
  const complete = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {},
  });
  const email = '0700000021@az-seller.ci';
  const created = await run(asAdmin({
    action: 'create', kind: 'seller', email,
    profile: { name: 'Boutique B', phone: '0700000021', type: 'boutique', lat: 6.7, lng: -3.5 },
  }));
  const temp = created.tempPassword;
  assert.match(temp, /^(?=.*[A-Z])(?=.*[a-z])(?=.*[0-9]).{12}$/);

  // 1. connexion avec le mot de passe temporaire : le jeton porte le claim
  const first = await signIn(email, temp);
  assert.equal(first.ok, true);
  const decoded = await auth.verifyIdToken(first.body.idToken);
  assert.equal(decoded.partnerMustChangePassword, true);

  // 2. nouveau mot de passe faible / identique au temporaire → refus, rien ne change
  await assert.rejects(complete(requestFromToken(decoded, { newPassword: 'faible' })), (e) => e.code === 'invalid-argument');
  await assert.rejects(complete(requestFromToken(decoded, { newPassword: temp })), (e) => e.code === 'invalid-argument');
  assert.equal((await db.collection('partner_provisioning').doc(created.uid).get()).data().mustChangePassword, true);

  // 3. changement réussi (par le serveur)
  assert.deepEqual(await complete(requestFromToken(decoded, { newPassword: 'MonNouveau9' })), { success: true });
  const journal = (await db.collection('partner_provisioning').doc(created.uid).get()).data();
  assert.equal(journal.mustChangePassword, false);
  assert.equal(journal.tempPasswordHash, undefined, 'hachage du temporaire supprimé');
  assert.equal(journal.passwordChangedAt !== undefined, true);
  assert.equal((await auth.getUser(created.uid)).customClaims?.partnerMustChangePassword, undefined);

  // 4. l'ancien mot de passe ne fonctionne plus ; le nouveau oui, sans claim
  assert.equal((await signIn(email, temp)).ok, false);
  const second = await signIn(email, 'MonNouveau9');
  assert.equal(second.ok, true);
  const decodedAfter = await auth.verifyIdToken(second.body.idToken);
  assert.equal(decodedAfter.partnerMustChangePassword, undefined);

  // 5. un second appel (compte désormais activé) est refusé
  await assert.rejects(complete(requestFromToken(decodedAfter, { newPassword: 'Autre1Password' })),
    (e) => e.code === 'failed-precondition');
});

test('émulateur: compte historique (sans journal) — aucun changement obligatoire, fonction refusée', options, async () => {
  const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');
  const complete = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {},
  });
  const email = '0700000022@az-seller.ci';
  const user = await auth.createUser({ email, password: 'Historique1A' });
  await db.collection('sellers').doc(user.uid).set({ name: 'Ancien', isActive: true, wallet: 10 });
  const signed = await signIn(email, 'Historique1A');
  const decoded = await auth.verifyIdToken(signed.body.idToken);
  assert.equal(decoded.partnerMustChangePassword, undefined);
  await assert.rejects(complete(requestFromToken(decoded, { newPassword: 'Nouveau1Passw' })),
    (e) => e.code === 'failed-precondition');
  assert.equal((await signIn(email, 'Historique1A')).ok, true, 'mot de passe historique inchangé');
});

test("émulateur: réinitialisation admin → nouveau temporaire, ancien mot de passe invalide, changement de nouveau obligatoire", options, async () => {
  const email = '0700000023@az-seller.ci';
  const created = await run(asAdmin({
    action: 'create', kind: 'seller', email,
    profile: { name: 'Boutique C', phone: '0700000023', type: 'boutique', lat: 6.7, lng: -3.5 },
  }));
  const reset = await run(asAdmin({ action: 'updatePassword', kind: 'seller', uid: created.uid }));
  assert.notEqual(reset.tempPassword, created.tempPassword);
  assert.equal((await signIn(email, created.tempPassword)).ok, false);
  const signed = await signIn(email, reset.tempPassword);
  assert.equal(signed.ok, true);
  assert.equal((await auth.verifyIdToken(signed.body.idToken)).partnerMustChangePassword, true);
});

test("émulateur: mode statut — obligatoire avant le changement, puis réparation d'une revendication périmée", options, async () => {
  const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');
  const complete = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {},
  });
  const email = '0700000024@az-seller.ci';
  const created = await run(asAdmin({
    action: 'create', kind: 'seller', email,
    profile: { name: 'Boutique D', phone: '0700000024', type: 'boutique', lat: 6.7, lng: -3.5 },
  }));
  const first = await auth.verifyIdToken((await signIn(email, created.tempPassword)).body.idToken);
  assert.deepEqual(await complete(requestFromToken(first, { statusOnly: true })), { required: true });

  await complete(requestFromToken(first, { newPassword: 'MonNouveau9' }));
  // Simule un retrait de revendication interrompu : le jeton affirme encore « obligatoire »
  await auth.setCustomUserClaims(created.uid, { partnerMustChangePassword: true });
  const stale = await auth.verifyIdToken((await signIn(email, 'MonNouveau9')).body.idToken);
  assert.equal(stale.partnerMustChangePassword, true);
  assert.deepEqual(await complete(requestFromToken(stale, { statusOnly: true })), { required: false });
  assert.equal((await auth.getUser(created.uid)).customClaims?.partnerMustChangePassword, undefined);
});

test('émulateur: deux changements simultanés avec le vrai verrou transactionnel — un seul gagne', options, async () => {
  const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');
  const complete = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {},
  });
  const email = '0700000025@az-seller.ci';
  const created = await run(asAdmin({
    action: 'create', kind: 'seller', email,
    profile: { name: 'Boutique E', phone: '0700000025', type: 'boutique', lat: 6.7, lng: -3.5 },
  }));
  const decoded = await auth.verifyIdToken((await signIn(email, created.tempPassword)).body.idToken);
  const results = await Promise.allSettled([
    complete(requestFromToken(decoded, { newPassword: 'PremierNouveau9' })),
    complete(requestFromToken(decoded, { newPassword: 'SecondNouveau9' })),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const winnerPassword = results[0].status === 'fulfilled' ? 'PremierNouveau9' : 'SecondNouveau9';
  const loserPassword = winnerPassword === 'PremierNouveau9' ? 'SecondNouveau9' : 'PremierNouveau9';
  assert.equal((await signIn(email, winnerPassword)).ok, true);
  assert.equal((await signIn(email, loserPassword)).ok, false);
  assert.equal((await db.collection('partner_provisioning').doc(created.uid).get()).data().mustChangePassword, false);
});

// ── B5 de bout en bout : restaurateur, Storage réel (règles storage.rules) ─────
const STORAGE_HOST = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
const storageOptions = {
  skip: emulated && STORAGE_HOST ? false : 'émulateurs Auth/Firestore/Storage requis',
};
/// Téléversement avec le VRAI SDK client (connexion + Storage émulés) : un jeton
/// réel, les règles storage.rules réellement évaluées. (Un appel REST brut est
/// refusé même pour un compte légitime : il ne prouve donc rien.)
let sdkApps = 0;
async function uploadLogoAs(email, password, restaurantId) {
  const { initializeApp } = require('../../node_modules/firebase/app');
  const { getAuth, connectAuthEmulator, signInWithEmailAndPassword } = require('../../node_modules/firebase/auth');
  const { getStorage, connectStorageEmulator, ref, uploadBytes } = require('../../node_modules/firebase/storage');
  const project = process.env.GCLOUD_PROJECT || 'az-partner-accounts-test';
  const app = initializeApp({
    projectId: project, apiKey: 'fake-key', storageBucket: `${project}.appspot.com`,
  }, `b5-${sdkApps += 1}`);
  const clientAuth = getAuth(app);
  connectAuthEmulator(clientAuth, `http://${AUTH_HOST}`, { disableWarnings: true });
  await signInWithEmailAndPassword(clientAuth, email, password);
  const storage = getStorage(app);
  const [host, port] = STORAGE_HOST.split(':');
  connectStorageEmulator(storage, host, Number(port));
  try {
    await uploadBytes(ref(storage, `restaurant_logos/${restaurantId}/logo.jpg`),
      new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), { contentType: 'image/jpeg' });
    return 'ok';
  } catch (error) {
    return error.code;
  }
}

test('B5 émulateur: restaurateur — projection, journal, Storage refusé avant activation puis autorisé', storageOptions, async () => {
  const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');
  const complete = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: admin.firestore.FieldValue,
    checkRateLimit: async () => {}, logAudit: async () => {},
  });
  // 1. création par l'administration
  const email = '0700000041@az-restaurant.ci';
  const created = await run(asAdmin({
    action: 'create', kind: 'restaurant', email,
    profile: { ...profile, phone: '0700000041' },
  }));
  // 2-3. projection et journal levés ensemble
  const owner = () => db.collection('restaurant_owners').doc(created.uid).get().then((s) => s.data());
  const journal = () => db.collection('partner_provisioning').doc(created.uid).get().then((s) => s.data());
  assert.equal((await owner()).mustChangePassword, true);
  assert.equal((await journal()).mustChangePassword, true);
  assert.equal((await journal()).kind, 'restaurant');
  assert.equal((await owner()).restaurantId, created.restaurantId);

  // 4. Storage refusé avant activation (jeton avec revendication ET projection true)
  const first = await signIn(email, created.tempPassword);
  assert.equal(first.ok, true);
  assert.equal(await uploadLogoAs(email, created.tempPassword, created.restaurantId), 'storage/unauthorized');

  // 5. changement obligatoire par le serveur
  const decoded = await auth.verifyIdToken(first.body.idToken);
  assert.deepEqual(await complete(requestFromToken(decoded, { newPassword: 'MonNouveau9' })), { success: true });

  // 6-7. projection et journal levés dans la même opération
  assert.equal((await owner()).mustChangePassword, false);
  assert.equal((await journal()).mustChangePassword, false);
  assert.equal((await owner()).restaurantId, created.restaurantId, 'autres champs préservés');

  // Le jeton d'AVANT activation (revendication périmée) n'est plus pénalisé non plus :
  // la projection fait autorité. Mais le temporaire ne se connecte plus.
  assert.equal((await signIn(email, created.tempPassword)).ok, false);

  // 8. Storage autorisé après activation (nouveau jeton, nouveau mot de passe)
  assert.equal(await uploadLogoAs(email, 'MonNouveau9', created.restaurantId), 'ok');
  // Un autre établissement reste refusé : la projection n'élargit aucun accès.
  assert.equal(await uploadLogoAs(email, 'MonNouveau9', 'autre-restaurant'), 'storage/unauthorized');
});
