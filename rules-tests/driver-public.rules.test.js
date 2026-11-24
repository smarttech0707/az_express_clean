// SEC-01 / driver_public (phase additive S2) : projection publique de `livreurs`, sans
// AUCUN champ privé (wallet, phone, fcmToken, token, isSuspended, deletionRequested,
// ownerId/ownerName, pendingOrderId, identifiant, pièces KYC). `livreurs` lui-même n'est
// pas touché par cette phase (voir driver-ledger.rules.test.js / fleet-security.rules.test.js
// pour sa propre couverture) : ce fichier ne teste que la nouvelle collection.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const anonymous = { firebase: { sign_in_provider: 'anonymous' } };

// Document complet, tel que posé par le SEED de test (bypass des règles) ou utilisé comme
// base pour les tests de champs interdits/types incorrects (qui testent un champ à la fois,
// en l'ajoutant à un GPS valide — voir `gpsDoc()` pour ce que le livreur peut réellement
// envoyer lui-même depuis S5.3.5).
const publicDoc = (overrides = {}) => ({
  name: 'Driver', photoUrl: 'https://x/photo.jpg',
  lat: 6.73, lng: -3.49, heading: 180.0, speed: 0.0,
  isOnline: true,
  ...overrides,
});

// S5.3.5 : seuls ces 5 champs GPS restent écrits directement par le livreur dans
// `driver_public` (lib/services/driver_public_projection.dart, phase S4) — `name`,
// `photoUrl` et `isOnline` sont désormais exclusivement synchronisés par le serveur
// (functions/driverPublicSync.js) et ne doivent plus être acceptés depuis le client.
const gpsDoc = (overrides = {}) => ({
  lat: 6.73, lng: -3.49, heading: 180.0, speed: 0.0,
  ...overrides,
});

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['livreurs'] });
    // `driver_public` exige un compte déjà créé par l'administration dans `livreurs`
    // (voir firestore.rules : exists(livreurs/driverId)) : les livreurs réels du jeu de
    // test doivent y exister, exactement comme dans la vraie vie (driver_requests_page.dart).
    await db.doc('livreurs/d1').set({ name: 'Driver', wallet: 500, isOnline: true });
    await db.doc('livreurs/d2').set({ name: 'Driver 2', wallet: 500, isOnline: true });
    await db.doc('livreurs/newDriver').set({ name: 'New Driver', wallet: 0, isOnline: false });
    await db.doc('driver_public/d1').set(publicDoc());
  });
  return e;
}

// ── Lecture ──────────────────────────────────────────────────────────────────────────
test('lecture : anonyme, authentifié classique, livreur et admin tous autorisés', async () => {
  const e = await env('az-dp-read');
  try {
    const anon = e.authenticatedContext('anon1', anonymous).firestore();
    const client = e.authenticatedContext('c1', password).firestore();
    const driver = e.authenticatedContext('d2', password).firestore();
    const admin = e.authenticatedContext('root', password).firestore();
    for (const db of [anon, client, driver, admin]) {
      await assertSucceeds(db.doc('driver_public/d1').get());
    }
  } finally { await e.cleanup(); }
});

test('lecture : utilisateur non authentifié refusé (isAuth exige un token, même anonyme)', async () => {
  const e = await env('az-dp-read-unauth');
  try {
    await assertFails(e.unauthenticatedContext().firestore().doc('driver_public/d1').get());
  } finally { await e.cleanup(); }
});

// ── Écriture : propriétaire ──────────────────────────────────────────────────────────
test('création par le livreur propriétaire, champs GPS conformes : autorisée', async () => {
  const e = await env('az-dp-create-ok');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    await assertSucceeds(db.doc('driver_public/newDriver').set(gpsDoc()));
  } finally { await e.cleanup(); }
});

test('mise à jour par le livreur propriétaire, champs GPS conformes : autorisée', async () => {
  const e = await env('az-dp-update-ok');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertSucceeds(db.doc('driver_public/d1').set(
      gpsDoc({ lat: 6.74, lng: -3.5 }), { merge: true }));
  } finally { await e.cleanup(); }
});

test("écriture du document d'un autre livreur refusée", async () => {
  const e = await env('az-dp-other-driver');
  try {
    const db = e.authenticatedContext('d2', password).firestore();
    await assertFails(db.doc('driver_public/d1').set(gpsDoc(), { merge: true }));
    await assertFails(db.doc('driver_public/d1').update({ lat: 1, lng: 1 }));
  } finally { await e.cleanup(); }
});

test('écriture anonyme refusée (création et mise à jour)', async () => {
  const e = await env('az-dp-anon-write');
  try {
    const db = e.authenticatedContext('d1', anonymous).firestore();
    await assertFails(db.doc('driver_public/d1').set(gpsDoc(), { merge: true }));
    await assertFails(db.doc('driver_public/newAnon').set(gpsDoc()));
  } finally { await e.cleanup(); }
});

test("client ordinaire (sans fiche livreurs) : ne peut pas fabriquer une fiche publique à son propre uid", async () => {
  const e = await env('az-dp-client-write');
  try {
    // Aucun document `livreurs/c1` : un client ne peut pas se faire passer pour un livreur.
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('driver_public/c1').set(gpsDoc()));
  } finally { await e.cleanup(); }
});

test('admin (super) : écriture refusée si non propriétaire', async () => {
  const e = await env('az-dp-admin-write');
  try {
    const db = e.authenticatedContext('root', password).firestore();
    await assertFails(db.doc('driver_public/d1').set(gpsDoc(), { merge: true }));
    await assertFails(db.doc('driver_public/d1').update({ lat: 1, lng: 1 }));
  } finally { await e.cleanup(); }
});

test("sous-admin (même avec la permission 'livreurs') : écriture refusée si non propriétaire", async () => {
  const e = await env('az-dp-subadmin-write');
  try {
    const db = e.authenticatedContext('sub', password).firestore();
    await assertFails(db.doc('driver_public/d1').set(gpsDoc(), { merge: true }));
    await assertFails(db.doc('driver_public/d1').update({ lat: 1, lng: 1 }));
  } finally { await e.cleanup(); }
});

// ── Champs interdits ─────────────────────────────────────────────────────────────────
test('création : chaque champ privé listé individuellement fait échouer l\'écriture', async () => {
  const e = await env('az-dp-forbidden-create');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    const forbidden = [
      { wallet: 1000 }, { phone: '0700000000' }, { fcmToken: 'tok' }, { token: 'tok' },
      { isSuspended: false }, { ownerId: 'x' }, { deletionRequested: false },
      { pendingOrderId: 'o1' }, { identifiant: 'ID-1' }, { clefInconnue: 'x' },
    ];
    for (const extra of forbidden) {
      await assertFails(db.doc('driver_public/newDriver').set({ ...gpsDoc(), ...extra }));
    }
  } finally { await e.cleanup(); }
});

test('mise à jour : chaque champ privé listé individuellement fait échouer l\'écriture', async () => {
  const e = await env('az-dp-forbidden-update');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    const forbidden = [
      { wallet: 1000 }, { phone: '0700000000' }, { fcmToken: 'tok' }, { token: 'tok' },
      { isSuspended: false }, { ownerId: 'x' }, { deletionRequested: false },
      { pendingOrderId: 'o1' }, { identifiant: 'ID-1' }, { clefInconnue: 'x' },
    ];
    for (const extra of forbidden) {
      await assertFails(db.doc('driver_public/d1').update(extra));
    }
  } finally { await e.cleanup(); }
});

// ── Champs serveur : jamais modifiables par le livreur ──────────────────────────────
test('création : avgRating, ratingCount, isAvailable, isOnDelivery refusés même seuls', async () => {
  const e = await env('az-dp-create-server-fields');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    for (const extra of [
      { avgRating: 4.5 }, { ratingCount: 3 }, { isAvailable: true }, { isOnDelivery: false },
    ]) {
      await assertFails(db.doc('driver_public/newDriver').set({ ...gpsDoc(), ...extra }));
    }
  } finally { await e.cleanup(); }
});

test('mise à jour : le livreur ne peut jamais changer avgRating/ratingCount/isAvailable/isOnDelivery', async () => {
  const e = await env('az-dp-update-server-fields');
  try {
    await e.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('driver_public/d1')
      .set({ avgRating: 4.2, ratingCount: 10, isAvailable: true, isOnDelivery: false }, { merge: true }));
    const db = e.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('driver_public/d1').update({ avgRating: 5 }));
    await assertFails(db.doc('driver_public/d1').update({ ratingCount: 11 }));
    await assertFails(db.doc('driver_public/d1').update({ isAvailable: false }));
    await assertFails(db.doc('driver_public/d1').update({ isOnDelivery: true }));
    // Une mise à jour légitime qui laisse ces 4 champs inchangés reste autorisée.
    await assertSucceeds(db.doc('driver_public/d1').update({ lat: 6.8, lng: -3.4 }));
  } finally { await e.cleanup(); }
});

// S5.3.5 (R1) : `name`/`photoUrl`/`isOnline` rejoignent les champs réservés au serveur —
// la synchronisation `functions/driverPublicSync.js` les pose désormais seule, depuis
// `livreurs`. Avant S5.3.5 ces 3 champs étaient directement modifiables par le livreur
// (voir l'ancien test "modification conforme du document propriétaire autorisée" :
// assertSucceeds sur isOnline/photoUrl) ; ce test prouve maintenant le contraire.
test('création : name, photoUrl, isOnline refusés même seuls (désormais réservés au serveur)', async () => {
  const e = await env('az-dp-create-server-synced-fields');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    for (const extra of [
      { name: 'Nouveau Nom' }, { photoUrl: 'https://x/new.jpg' }, { isOnline: true },
    ]) {
      await assertFails(db.doc('driver_public/newDriver').set({ ...gpsDoc(), ...extra }));
    }
  } finally { await e.cleanup(); }
});

test('mise à jour : le livreur ne peut plus changer name/photoUrl/isOnline directement', async () => {
  const e = await env('az-dp-update-server-synced-fields');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    // d1 a été seedé avec name: 'Driver', photoUrl: '.../photo.jpg', isOnline: true.
    await assertFails(db.doc('driver_public/d1').update({ name: 'Autre Nom' }));
    await assertFails(db.doc('driver_public/d1').update({ photoUrl: 'https://x/new.jpg' }));
    await assertFails(db.doc('driver_public/d1').update({ isOnline: false }));
    // Une mise à jour GPS qui laisse ces 3 champs inchangés reste autorisée.
    await assertSucceeds(db.doc('driver_public/d1').update({ lat: 6.8, lng: -3.4 }));
  } finally { await e.cleanup(); }
});

// ── Types incorrects ─────────────────────────────────────────────────────────────────
test('types incorrects refusés un par un', async () => {
  const e = await env('az-dp-types');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    const bad = [
      { lat: 'nord' }, { lat: 200 }, { lat: -200 },
      { lng: 'est' }, { lng: 400 }, { lng: -400 },
      { heading: '180' }, { speed: 'vite' },
      // isOnline/name/photoUrl sont désormais refusés à la création même avec un type
      // valide (S5.3.5, champs réservés au serveur) : la validation de type reste
      // couverte séparément par le test de mise à jour ci-dessous, où ces champs
      // préexistent déjà sur le document (seed hors-règles) sans être "changés" ici.
    ];
    for (const extra of bad) {
      await assertFails(db.doc('driver_public/newDriver').set({ ...gpsDoc(), ...extra }));
    }
  } finally { await e.cleanup(); }
});

test('updatedAt : seule la valeur serveur (request.time) est acceptée', async () => {
  const { Timestamp } = require('firebase/firestore');
  const e = await env('az-dp-updatedat');
  try {
    const db = e.authenticatedContext('newDriver', password).firestore();
    await assertFails(db.doc('driver_public/newDriver').set(
      { ...gpsDoc(), updatedAt: Timestamp.now() }));
    const { serverTimestamp } = require('firebase/firestore');
    await assertSucceeds(db.doc('driver_public/newDriver').set(
      { ...gpsDoc(), updatedAt: serverTimestamp() }));
  } finally { await e.cleanup(); }
});

// ── Modification / suppression ──────────────────────────────────────────────────────
// Avant S5.3.5, ce test prouvait que le livreur pouvait modifier isOnline/photoUrl
// directement (assertSucceeds) ; voir le test dédié "name/photoUrl/isOnline" ci-dessus,
// qui prouve maintenant l'inverse. Conservé ici pour la modification GPS conforme.
test('modification GPS conforme du document propriétaire autorisée', async () => {
  const e = await env('az-dp-mod-ok');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertSucceeds(db.doc('driver_public/d1').update({ lat: 6.75, lng: -3.51 }));
  } finally { await e.cleanup(); }
});

test('suppression : admin autorisé, livreur propriétaire refusé, non-propriétaire refusé', async () => {
  const e = await env('az-dp-delete');
  try {
    await assertFails(e.authenticatedContext('d1', password).firestore().doc('driver_public/d1').delete());
    await assertFails(e.authenticatedContext('d2', password).firestore().doc('driver_public/d1').delete());
    await assertSucceeds(e.authenticatedContext('root', password).firestore().doc('driver_public/d1').delete());
  } finally { await e.cleanup(); }
});
