// Règles PROPOSÉES (non appliquées) : un partenaire qui porte la revendication
// `partnerMustChangePassword` ne peut effectuer aucune écriture professionnelle.
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-partner-activation',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => { await env.cleanup(); });
test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
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
    await db.doc('marketplace_products/p1').set({
      sellerId: 's1', status: 'active', views: 0, favoritesCount: 0, title: 'A',
    });
  });
});

const claims = (pending) => ({ firebase: { sign_in_provider: 'password' }, ...(pending ? { partnerMustChangePassword: true } : {}) });
const as = (uid, pending) => env.authenticatedContext(uid, claims(pending)).firestore();

const writes = {
  'vendeur : modifier son profil': (db) => db.doc('sellers/s1').update({ name: 'Nouveau nom' }),
  'vendeur : journal de transactions': (db) => db.doc('sellers/s1/wallet_transactions/t1').set({
    type: 'sale', amount: 100, description: 'x', orderId: 'o1', createdAt: new Date(),
  }),
  'boulangerie : modifier son profil': (db) => db.doc('boulangeries/b1').update({ name: 'Nouveau nom' }),
  'boulangerie : gérer ses articles': (db) => db.doc('boulangeries/b1/menu_items/i2').set({ name: 'Pain', price: 200 }),
  'restaurant : ouvrir/fermer': (db) => db.doc('restaurants/rest1').update({ isOpen: true }),
  'restaurant : gérer le menu': (db) => db.doc('restaurants/rest1/menu/m2').set({ name: 'Nouveau', price: 500 }),
  'vendeur : mettre à jour une commande': (db) => db.doc('orders/o1').update({ sellerStatus: 'preparing' }),
  'boulangerie : préparer une commande': (db) => db.doc('orders/o2').update({ sellerStatus: 'preparing' }),
  'vendeur : modifier une annonce': (db) => db.doc('marketplace_products/p1').update({ title: 'B' }),
};
const owner = {
  'vendeur : modifier son profil': 's1', 'vendeur : journal de transactions': 's1',
  'boulangerie : modifier son profil': 'b1', 'boulangerie : gérer ses articles': 'b1',
  'restaurant : ouvrir/fermer': 'r1', 'restaurant : gérer le menu': 'r1',
  'vendeur : mettre à jour une commande': 's1', 'boulangerie : préparer une commande': 'b1',
  'vendeur : modifier une annonce': 's1',
};

for (const [label, write] of Object.entries(writes)) {
  test(`NON activé — refusé : ${label}`, async () => {
    await assertFails(write(as(owner[label], true)));
  });
  test(`activé / historique (sans revendication) — autorisé : ${label}`, async () => {
    await assertSucceeds(write(as(owner[label], false)));
  });
}

test('NON activé — la LECTURE de son propre profil reste possible (écran de première connexion)', async () => {
  await assertSucceeds(as('s1', true).doc('sellers/s1').get());
  await assertSucceeds(as('b1', true).doc('boulangeries/b1').get());
  await assertSucceeds(as('r1', true).doc('restaurant_owners/r1').get());
  await assertSucceeds(as('r1', true).doc('restaurants/rest1').get());
});

test('une revendication à false ou absente n\'ouvre aucun droit supplémentaire', async () => {
  await assertFails(as('s1', false).doc('sellers/s1').update({ wallet: 999999 }));
  await assertFails(as('s1', false).doc('sellers/s1').update({ isActive: false }));
});

test('le client ne peut pas se « réactiver » en écrivant un drapeau sur son profil', async () => {
  // le drapeau du profil n'est pas l'autorité ; la revendication seule compte
  await assertFails(as('s1', true).doc('sellers/s1').update({ mustChangePassword: false }));
});
