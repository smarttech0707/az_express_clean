// Étape B3 — fermeture des contournements restants : annonces Marketplace,
// conversations Marketplace (côté vendeur), produits Boutique et annonces de
// véhicules. Même autorité que partner-activation.rules.test.js : journal
// serveur `partner_provisioning/{uid}` s'il existe, sinon revendication.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { serverTimestamp } = require('firebase/firestore');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-express-partner-activation-b3',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => { await env.cleanup(); });

function vehicle(sellerId, overrides = {}) {
  return {
    sellerId, sellerType: 'individual', vehicleType: 'car', offerType: 'sale',
    title: 'Toyota Corolla', description: 'Véhicule propre et régulièrement entretenu.',
    brand: 'Toyota', model: 'Corolla', year: 2024, condition: 'used', color: 'Gris',
    mileageKm: 25000, transmission: 'automatic', fuelType: 'petrol', seats: 5,
    salePrice: 2500000, rentalWithDriver: false, rentalWithoutDriver: false,
    price: 2500000, currency: 'XOF', cityId: 'agnibilekrou', cityName: 'Agnibilékrou',
    status: 'draft', createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...overrides,
  };
}

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('sellers/s1').set({ name: 'Boutique', isActive: true, wallet: 100, type: 'boutique' });
    await db.doc('marketplace_products/p1').set({
      sellerId: 's1', status: 'active', views: 0, favoritesCount: 0, title: 'A',
    });
    await db.doc('marketplace_chats/mp_p1_buyer1').set({ sellerId: 's1', buyerId: 'buyer1', productId: 'p1' });
    await db.doc('boutique_products/bp1').set({ sellerId: 's1', name: 'Savon', price: 100, stock: 3 });
    await db.doc('vehicle_listings/v1').set(vehicle('s1'));
  });
});

const password = { firebase: { sign_in_provider: 'password' } };
const withClaim = { ...password, partnerMustChangePassword: true };
const as = (uid, token = password) => env.authenticatedContext(uid, token).firestore();
const seedJournal = (uid, mustChangePassword) => env.withSecurityRulesDisabled(
  (ctx) => ctx.firestore().doc(`partner_provisioning/${uid}`).set({ kind: 'seller', mustChangePassword }));

const message = (uid) => ({ senderUid: uid, type: 'text', text: 'Bonjour' });
const professional = [
  ['Marketplace : modifier une annonce', (db) => db.doc('marketplace_products/p1').update({ title: 'B' })],
  ['Marketplace : supprimer une annonce', (db) => db.doc('marketplace_products/p1').delete()],
  ['Marketplace : conversation côté vendeur', (db) => db.doc('marketplace_chats/mp_p1_buyer1').update({ lastMessage: 'x' })],
  ['Marketplace : répondre à un acheteur', (db) => db.doc('marketplace_chats/mp_p1_buyer1/messages/m1').set(message('s1'))],
  ['Boutique : créer un produit', (db) => db.doc('boutique_products/bp2').set({ sellerId: 's1', name: 'Nouveau', price: 50 })],
  ['Boutique : modifier un produit', (db) => db.doc('boutique_products/bp1').update({ price: 120 })],
  ['Boutique : supprimer un produit', (db) => db.doc('boutique_products/bp1').delete()],
  ['Véhicules : créer une annonce', (db) => db.doc('vehicle_listings/v2').set(vehicle('s1'))],
  ['Véhicules : modifier une annonce', (db) => db.doc('vehicle_listings/v1').update({ title: 'Titre modifié', updatedAt: serverTimestamp() })],
];

for (const [label, write] of professional) {
  test(`NON activé (revendication seule) — refusé : ${label}`, async () => {
    await assertFails(write(as('s1', withClaim)));
  });
  test(`NON activé (journal serveur, jeton ANCIEN sans revendication) — refusé : ${label}`, async () => {
    await seedJournal('s1', true);
    await assertFails(write(as('s1', password)));
  });
  test(`activé (journal levé, revendication périmée) — autorisé : ${label}`, async () => {
    await seedJournal('s1', false);
    await assertSucceeds(write(as('s1', withClaim)));
  });
  test(`compte historique / client ordinaire (ni journal ni revendication) — préservé : ${label}`, async () => {
    await assertSucceeds(write(as('s1', password)));
  });
}

test('administrateur — préservé sur toutes les ressources, avec ou sans revendication sur son jeton', async () => {
  for (const token of [password, withClaim]) {
    const db = as('root', token);
    await assertSucceeds(db.doc('marketplace_products/p1').update({ title: `Admin ${Object.keys(token).length}` }));
    await assertSucceeds(db.doc('marketplace_chats/mp_p1_buyer1').update({ lastMessage: 'admin' }));
    await assertSucceeds(db.doc('boutique_products/bp1').update({ price: 111 }));
    await assertSucceeds(db.doc('vehicle_listings/v1').update({ title: 'Admin titre', updatedAt: serverTimestamp() }));
  }
});

test('opérations d\'ACHETEUR inchangées : message, conversation, vues et favoris', async () => {
  await seedJournal('s1', true);
  const buyer = as('buyer1');
  await assertSucceeds(buyer.doc('marketplace_chats/mp_p1_buyer1/messages/m2').set(message('buyer1')));
  await assertSucceeds(buyer.doc('marketplace_chats/mp_p1_buyer1').update({ lastMessage: 'acheteur' }));
  await assertSucceeds(buyer.doc('marketplace_products/p1').update({ views: 1 }));
  await assertSucceeds(buyer.doc('marketplace_products/p1').update({ favoritesCount: 1 }));
  await assertSucceeds(buyer.doc('marketplace_chats/mp_p1_buyer1/messages/m3').set(message('buyer1')));
});

test('un acheteur qui est aussi un vendeur non activé garde ses droits d\'acheteur', async () => {
  // s1 est vendeur NON activé ; il écrit dans la conversation dont il est ACHETEUR
  await seedJournal('s1', true);
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('marketplace_chats/mp_p9_s1').set({ sellerId: 'other', buyerId: 's1', productId: 'p9' });
  });
  await assertSucceeds(as('s1', withClaim).doc('marketplace_chats/mp_p9_s1/messages/m1').set(message('s1')));
  await assertSucceeds(as('s1', withClaim).doc('marketplace_chats/mp_p9_s1').update({ lastMessage: 'x' }));
});

test('aucun élargissement : un autre utilisateur ne peut toujours pas toucher les ressources du vendeur', async () => {
  await assertFails(as('intrus').doc('marketplace_products/p1').update({ title: 'Pirate' }));
  await assertFails(as('intrus').doc('marketplace_products/p1').delete());
  await assertFails(as('intrus').doc('boutique_products/bp1').update({ price: 1 }));
  await assertFails(as('intrus').doc('boutique_products/bp1').delete());
  await assertFails(as('intrus').doc('vehicle_listings/v1').update({ title: 'Pirate', updatedAt: serverTimestamp() }));
  await assertFails(as('intrus').doc('marketplace_chats/mp_p1_buyer1').update({ lastMessage: 'pirate' }));
});

test('le client ne peut pas se réactiver ni contourner par le journal', async () => {
  await seedJournal('s1', true);
  await assertFails(as('s1', withClaim).doc('partner_provisioning/s1').set({ mustChangePassword: false }));
  await assertFails(as('s1', withClaim).doc('boutique_products/bp1').update({ price: 1 }));
});

test('lectures inchangées pour un partenaire non activé', async () => {
  await seedJournal('s1', true);
  await assertSucceeds(as('s1', withClaim).doc('marketplace_products/p1').get());
  await assertSucceeds(as('s1', withClaim).doc('marketplace_chats/mp_p1_buyer1').get());
  await assertSucceeds(as('s1', withClaim).doc('boutique_products/bp1').get());
  await assertSucceeds(as('s1', withClaim).doc('vehicle_listings/v1').get());
});
