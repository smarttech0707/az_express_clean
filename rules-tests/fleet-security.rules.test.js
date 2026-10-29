// Patrons de flotte : inscription, validation administrateur et affiliation
// des livreurs. Les règles Firestore sont la seule barrière serveur (aucune
// fonction dédiée à ce stade).
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { Timestamp } = require('firebase/firestore');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-express-fleet-security',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => { await env.cleanup(); });

const password = { firebase: { sign_in_provider: 'password' } };
const as = (uid, token = password) => env.authenticatedContext(uid, token).firestore();

// Champs exacts écrits par lib/screens/fleet/fleet_register.dart.
const registration = (overrides = {}) => ({
  name: 'Patron', phone: '0700000001', identifiant: 'patron1', status: 'pending',
  photoUrl: 'https://x/selfie.jpg', idPhotoUrl: 'https://x/id.jpg', idNumber: 'CI123',
  createdAt: Timestamp.now(), ...overrides,
});

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('fleet_owners/pending1').set(registration());
    await db.doc('fleet_owners/ok1').set(registration({ status: 'approved' }));
    await db.doc('livreurs/d1').set({
      name: 'Driver', wallet: 500, isOnline: false, ownerId: 'ok1', ownerName: 'Patron',
      isSuspended: false,
    });
    await db.doc('livreurs/free').set({ name: 'Free', wallet: 100, isOnline: false });
  });
});

// ── fleet_owners : inscription ──────────────────────────────────────────────
test('inscription normale : profil propre en pending autorisé', async () => {
  await assertSucceeds(as('new1').doc('fleet_owners/new1').set(registration()));
});

test("inscription au nom d'un autre uid refusée", async () => {
  await assertFails(as('new1').doc('fleet_owners/other').set(registration()));
});

test('inscription anonyme refusée', async () => {
  await assertFails(as('anon1', { firebase: { sign_in_provider: 'anonymous' } })
    .doc('fleet_owners/anon1').set(registration()));
});

test('création avec status approved refusée (et rejected, absent, ou autre valeur)', async () => {
  for (const status of ['approved', 'rejected', 'suspended']) {
    await assertFails(as('new1').doc('fleet_owners/new1').set(registration({ status })));
  }
  const withoutStatus = registration();
  delete withoutStatus.status;
  await assertFails(as('new1').doc('fleet_owners/new1').set(withoutStatus));
});

test('création avec wallet arbitraire refusée', async () => {
  await assertFails(as('new1').doc('fleet_owners/new1').set(registration({ wallet: 1000000 })));
  await assertFails(as('new1').doc('fleet_owners/new1').set(registration({ wallet: 0 })));
});

test('création avec VIP, plan ou abonnement forgé refusée', async () => {
  const forged = [
    { vipStatus: 'active' }, { vipExpiresAt: Timestamp.fromMillis(4102444800000) },
    { plan: 'vip' }, { priorityLevel: 10 }, { paymentStatus: 'paid' },
    { subscriptionStatus: 'active' }, { subscriptionExpiresAt: Timestamp.fromMillis(4102444800000) },
    { approvedAt: Timestamp.now() }, { isSuspended: false },
  ];
  for (const extra of forged) {
    await assertFails(as('new1').doc('fleet_owners/new1').set(registration(extra)));
  }
});

// ── fleet_owners : modification ─────────────────────────────────────────────
test('auto-approbation par modification refusée', async () => {
  await assertFails(as('pending1').doc('fleet_owners/pending1').update({ status: 'approved' }));
  await assertFails(as('pending1').doc('fleet_owners/pending1').update({
    status: 'approved', approvedAt: Timestamp.now(),
  }));
});

test('un patron rejeté ou approuvé ne peut pas changer son statut', async () => {
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('fleet_owners/pending1').update({ status: 'rejected' }));
  await assertFails(as('pending1').doc('fleet_owners/pending1').update({ status: 'approved' }));
  await assertFails(as('ok1').doc('fleet_owners/ok1').update({ status: 'pending' }));
});

test('champs financiers et administratifs inchangeables par le patron', async () => {
  const db = as('ok1');
  for (const patch of [
    { wallet: 999 }, { plan: 'vip' }, { vipStatus: 'active' }, { subscriptionStatus: 'active' },
    { priorityLevel: 5 }, { isSuspended: false }, { approvedAt: Timestamp.now() },
    { rejectedAt: Timestamp.now() },
  ]) {
    await assertFails(db.doc('fleet_owners/ok1').update(patch));
  }
});

test('modification légitime du profil autorisée (photo, jeton de notification)', async () => {
  await assertSucceeds(as('ok1').doc('fleet_owners/ok1').update({ photoUrl: 'https://x/new.jpg' }));
  await assertSucceeds(as('ok1').doc('fleet_owners/ok1').set({ fcmToken: 'tok' }, { merge: true }));
  await assertSucceeds(as('pending1').doc('fleet_owners/pending1').update({ name: 'Nouveau nom' }));
});

test("un patron ne modifie pas le profil d'un autre", async () => {
  await assertFails(as('ok1').doc('fleet_owners/pending1').update({ name: 'X' }));
});

test('approbation, rejet et réactivation par un administrateur autorisés', async () => {
  const admin = as('root');
  await assertSucceeds(admin.doc('fleet_owners/pending1').update({ status: 'approved', approvedAt: Timestamp.now() }));
  await assertSucceeds(admin.doc('fleet_owners/pending1').update({ status: 'rejected', rejectedAt: Timestamp.now() }));
  await assertSucceeds(admin.doc('fleet_owners/pending1').update({ status: 'approved', approvedAt: Timestamp.now() }));
});

test("un utilisateur ordinaire ne peut pas approuver un patron", async () => {
  await assertFails(as('someone').doc('fleet_owners/pending1').update({ status: 'approved' }));
});

// ── livreurs : affiliation ──────────────────────────────────────────────────
test("un livreur ne peut pas changer son ownerId (flotte tierce, ou départ de la sienne)", async () => {
  await assertFails(as('d1').doc('livreurs/d1').update({ ownerId: 'autre-flotte' }));
  await assertFails(as('free').doc('livreurs/free').update({ ownerId: 'ok1' }));
});

test('un livreur ne peut pas changer son ownerName', async () => {
  await assertFails(as('d1').doc('livreurs/d1').update({ ownerName: 'Pirate' }));
  await assertFails(as('free').doc('livreurs/free').update({ ownerName: 'Pirate' }));
});

test("ownerId ne peut pas être supprimé par le livreur", async () => {
  const { deleteField } = require('firebase/firestore');
  await assertFails(as('d1').doc('livreurs/d1').update({ ownerId: deleteField(), ownerName: deleteField() }));
});

test("la branche « diminution du wallet » ne permet pas non plus de changer l'affiliation", async () => {
  await assertFails(as('d1').doc('livreurs/d1').update({ wallet: 400, ownerId: 'autre-flotte' }));
  await assertSucceeds(as('d1').doc('livreurs/d1').update({ wallet: 400 }));
});

test('mise à jour légitime du livreur (disponibilité, position, jeton) autorisée', async () => {
  await assertSucceeds(as('d1').doc('livreurs/d1').update({ isOnline: true, lat: 6.7, lng: -3.5 }));
  await assertSucceeds(as('d1').doc('livreurs/d1').set({ fcmToken: 'tok' }, { merge: true }));
  await assertSucceeds(as('free').doc('livreurs/free').update({ isOnline: true }));
});

test('un livreur ne peut toujours pas augmenter son wallet ni se réactiver', async () => {
  await assertFails(as('d1').doc('livreurs/d1').update({ wallet: 9999 }));
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('livreurs/d1').update({ isSuspended: true }));
  await assertFails(as('d1').doc('livreurs/d1').update({ isSuspended: false }));
});

test('affectation et libération par un administrateur autorisées', async () => {
  const admin = as('root');
  await assertSucceeds(admin.doc('livreurs/free').update({ ownerId: 'ok1', ownerName: 'Patron' }));
  const { deleteField } = require('firebase/firestore');
  await assertSucceeds(admin.doc('livreurs/d1').update({ ownerId: deleteField(), ownerName: deleteField() }));
});

test("la création d'un livreur reste réservée à l'administrateur", async () => {
  await assertFails(as('ok1').doc('livreurs/nouveau').set({ name: 'N', ownerId: 'ok1', wallet: 500 }));
  await assertFails(as('nouveau').doc('livreurs/nouveau').set({ name: 'N', wallet: 0 }));
  await assertSucceeds(as('root').doc('livreurs/nouveau').set({ name: 'N', ownerId: 'ok1', wallet: 0 }));
});
