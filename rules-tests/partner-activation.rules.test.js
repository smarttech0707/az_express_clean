// Étape B2 — un partenaire créé par l'administration (restaurant, vendeur,
// boulangerie) ne peut effectuer AUCUNE écriture professionnelle tant que son
// mot de passe temporaire n'a pas été remplacé, même avec une application
// modifiée. Source d'autorité : journal serveur `partner_provisioning/{uid}`
// (jeton ancien compris), sinon revendication `partnerMustChangePassword`.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-express-partner-activation',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => { await env.cleanup(); });
test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('sellers/s1').set({ name: 'Boutique', isActive: true, wallet: 100, type: 'boutique' });
    await db.doc('boulangeries/b1').set({ name: 'Pain', isActive: true, wallet: 100 });
    await db.doc('boulangeries/b1/menu_items/i1').set({ name: 'Baguette', price: 150 });
    await db.doc('restaurant_owners/r1').set({ restaurantId: 'rest1', uid: 'r1' });
    await db.doc('restaurants/rest1').set({ name: 'Resto', isActive: true, isOpen: false });
    await db.doc('restaurants/rest1/menu/m1').set({ name: 'Plat', price: 1000 });
    await db.doc('orders/o1').set({
      clientId: 'c1', sellerId: 's1', sellerType: 'seller', budget: 1000,
      status: 'pending', isPaid: false, paymentMethod: 'cash',
    });
    await db.doc('orders/o2').set({
      clientId: 'c1', sellerId: 'b1', sellerType: 'boulangerie', budget: 1000,
      status: 'pending', isPaid: false, paymentMethod: 'cash',
    });
    await db.doc('clients/c1').set({ name: 'Client', wallet: 5000, fakeOrderCount: 0, cashOnDeliveryEnabled: true });
  });
});

const password = { firebase: { sign_in_provider: 'password' } };
const withClaim = { ...password, partnerMustChangePassword: true };
const as = (uid, token = password) => env.authenticatedContext(uid, token).firestore();
const seedJournal = (uid, mustChangePassword) => env.withSecurityRulesDisabled(
  (ctx) => ctx.firestore().doc(`partner_provisioning/${uid}`).set({ kind: 'seller', mustChangePassword }));

const writes = [
  ['vendeur : modifier son profil', 's1', (db) => db.doc('sellers/s1').update({ name: 'Nouveau nom' })],
  ['vendeur : journal de transactions', 's1', (db) => db.doc('sellers/s1/wallet_transactions/t1').set({
    type: 'sale', amount: 100, description: 'x', orderId: 'o1', createdAt: new Date(),
  })],
  ['vendeur : écriture sur une commande', 's1', (db) => db.doc('orders/o1').update({ sellerStatus: 'preparing' })],
  ['boulangerie : modifier son profil', 'b1', (db) => db.doc('boulangeries/b1').update({ name: 'Nouveau nom' })],
  ['boulangerie : gérer ses articles', 'b1', (db) => db.doc('boulangeries/b1/menu_items/i2').set({ name: 'Pain', price: 200 })],
  ['boulangerie : préparer une commande', 'b1', (db) => db.doc('orders/o2').update({ sellerStatus: 'preparing' })],
  ['restaurant : modifier le restaurant (ouverture)', 'r1', (db) => db.doc('restaurants/rest1').update({ isOpen: true })],
  ['restaurant : modifier le restaurant (jeton de notification)', 'r1', (db) => db.doc('restaurants/rest1').update({ fcmToken: 'x'.repeat(40) })],
  ['restaurant : gérer le menu', 'r1', (db) => db.doc('restaurants/rest1/menu/m2').set({ name: 'Nouveau', price: 500 })],
];

for (const [label, uid, write] of writes) {
  test(`NON activé (revendication seule) — refusé : ${label}`, async () => {
    await assertFails(write(as(uid, withClaim)));
  });
  test(`NON activé (journal serveur, jeton ANCIEN sans revendication) — refusé : ${label}`, async () => {
    await seedJournal(uid, true);
    await assertFails(write(as(uid, password)));
  });
  test(`activé : journal levé, jeton avec revendication PÉRIMÉE — autorisé : ${label}`, async () => {
    await seedJournal(uid, false);
    await assertSucceeds(write(as(uid, withClaim)));
  });
  test(`compte historique (ni journal ni revendication) — comportement préservé : ${label}`, async () => {
    await assertSucceeds(write(as(uid, password)));
  });
  test(`activé après changement (journal levé, jeton renouvelé) — autorisé : ${label}`, async () => {
    await seedJournal(uid, false);
    await assertSucceeds(write(as(uid, password)));
  });
}

test('NON activé — la LECTURE de son propre profil reste possible (écran de première connexion)', async () => {
  await seedJournal('s1', true);
  await seedJournal('b1', true);
  await seedJournal('r1', true);
  await assertSucceeds(as('s1', withClaim).doc('sellers/s1').get());
  await assertSucceeds(as('b1', withClaim).doc('boulangeries/b1').get());
  await assertSucceeds(as('r1', withClaim).doc('restaurant_owners/r1').get());
  await assertSucceeds(as('r1', withClaim).doc('restaurants/rest1').get());
});

test('les restrictions financières existantes restent actives pour un compte activé', async () => {
  await assertFails(as('s1').doc('sellers/s1').update({ wallet: 999999 }));
  await assertFails(as('s1').doc('sellers/s1').update({ isActive: false }));
  await assertFails(as('b1').doc('boulangeries/b1').update({ wallet: 999999 }));
  await assertFails(as('r1').doc('restaurants/rest1').update({ wallet: 999999 }));
});

test('le client ne peut pas se réactiver : ni écrire le journal serveur, ni un drapeau de profil', async () => {
  await seedJournal('s1', true);
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').set({ mustChangePassword: false }));
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').update({ mustChangePassword: false }));
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').delete());
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').get());
  await assertFails(as('s1', withClaim).doc('partner_provisioning/other').set({ mustChangePassword: false }));
  // un drapeau écrit sur le profil n'est pas l'autorité
  await assertFails(as('s1', withClaim).doc('sellers/s1').update({ mustChangePassword: false }));
});

test('un client ne peut pas créer lui-même un journal « activé » pour contourner la revendication', async () => {
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').set({ mustChangePassword: false, kind: 'seller' }));
  await assertFails(as('s1', withClaim).doc('sellers/s1').update({ name: 'Nouveau nom' }));
});

test('client ordinaire — comportement inchangé (profil et commande)', async () => {
  await assertSucceeds(as('c1').doc('clients/c1').update({ name: 'Nouveau nom' }));
  await assertSucceeds(as('c1').doc('orders/o-new').set({
    clientId: 'c1', budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'pending',
  }));
  await assertFails(as('c1').doc('clients/c1').update({ wallet: 999999 }));
});

test('administrateur autorisé — comportement inchangé (avec ou sans revendication sur son jeton)', async () => {
  for (const token of [password, withClaim]) {
    const db = as('root', token);
    await assertSucceeds(db.doc('sellers/s1').update({ name: `Admin ${Object.keys(token).length}` }));
    await assertSucceeds(db.doc('boulangeries/b1').update({ name: 'Admin' }));
    await assertSucceeds(db.doc('restaurants/rest1').update({ name: 'Admin' }));
    await assertSucceeds(db.doc('restaurants/rest1/menu/m3').set({ name: 'Admin', price: 1 }));
    await assertSucceeds(db.doc('orders/o1').update({ sellerStatus: 'ready' }));
  }
});

test('lectures publiques inchangées pour tout utilisateur authentifié', async () => {
  await seedJournal('s1', true);
  await assertSucceeds(as('c1').doc('restaurants/rest1').get());
  await assertSucceeds(as('c1').doc('boulangeries/b1').get());
});
