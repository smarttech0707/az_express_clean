'use strict';

// Tests automatiques des Firestore Security Rules — n'existaient pas du tout
// avant cette passe. Couvre les patterns les plus sensibles plutôt que les
// ~70 collections de manière exhaustive (voir FIRESTORE_RULES.md pour le
// reste, documenté mais non testé). Exécution : `npm run test:rules`
// (démarre l'émulateur Firestore via `firebase emulators:exec`).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const { deleteField, serverTimestamp } = require('firebase/firestore');

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'az-express-rules-test',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
  });
});

test.after(async () => {
  await testEnv.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

test('places: un utilisateur ne peut pas créer un lieu verified true', async () => {
  await assertFails(asClient('u1').doc('places/p1').set({
    name: 'Gabriel', latitude: 7.13, longitude: -3.2, source: 'nominatim', verified: true,
  }));
});

test('places: un utilisateur peut créer un lieu non vérifié avec ville et alias', async () => {
  await assertSucceeds(asClient('u1').doc('places/p1').set({
    name: 'Gabriel', latitude: 7.13, longitude: -3.2, source: 'nominatim',
    cityId: 'agnibilekrou', normalizedName: 'gabriel', aliases: ['pharmacie gabriel'],
    verified: false,
  }));
});

test('places: un utilisateur doit renseigner la source et ne peut pas écrire coordinateSource', async () => {
  const base = { name: 'Gabriel', latitude: 7.13, longitude: -3.2, source: 'nominatim' };
  await assertFails(asClient('u1').doc('places/source-missing').set({
    name: 'Gabriel', latitude: 7.13, longitude: -3.2,
  }));
  await assertFails(asClient('u1').doc('places/source').set({
    ...base, coordinateSource: 'own',
  }));
});

test('places: un utilisateur reste limité à searchCount et updatedAt en update', async () => {
  await seed((db) => db.doc('places/p1').set({
    name: 'Gabriel', latitude: 7.13, longitude: -3.2,
    source: 'nominatim', verified: false,
  }));
  const ref = asClient('u1').doc('places/p1');
  await assertSucceeds(ref.update({ searchCount: 2, updatedAt: new Date() }));
  await assertFails(ref.update({ verified: true }));
  await assertFails(ref.update({ cityId: 'agnibilekrou' }));
  await assertFails(ref.update({ aliases: ['gabriel'] }));
  await assertFails(ref.update({ coordinateSource: 'own' }));
});

test('places et zones_livraison: un admin conserve les droits d’écriture', async () => {
  await seed((db) => db.doc('admins/admin1').set({
    role: 'super', isActive: true,
  }));
  await assertSucceeds(asAdmin('admin1').doc('places/p1').set({
    name: 'Gabriel', latitude: 7.13, longitude: -3.2, verified: true,
    cityId: 'agnibilekrou', aliases: ['gabriel'],
  }));
  await assertSucceeds(asAdmin('admin1').doc('zones_livraison/z1').set({
    name: 'Agnibilékrou', type: 'ville', isServiceable: false,
  }));
});

test('zones_livraison: un utilisateur ne peut pas écrire', async () => {
  await assertFails(asClient('u1').doc('zones_livraison/z1').set({
    name: 'Agnibilékrou', type: 'ville', isServiceable: false,
  }));
});

test('admin deny-by-default: rôle absent, inconnu ou inactif refusé', async () => {
  await seed(async (db) => {
    await db.doc('sellers/s1').set({ name: 'S' });
    await db.doc('admins/missing-role').set({ isActive: true, permissions: [] });
    await db.doc('admins/unknown-role').set({ role: 'client', isActive: true, permissions: [] });
    await db.doc('admins/inactive').set({ role: 'super', isActive: false });
  });
  await assertFails(asAdmin('missing-role').doc('sellers/s1').get());
  await assertFails(asAdmin('unknown-role').doc('sellers/s1').get());
  await assertFails(asAdmin('inactive').doc('sellers/s1').get());
});

test('permissions: sous-admin sans permission vendeurs refusé, super autorisé', async () => {
  await seed(async (db) => {
    await db.doc('sellers/s1').set({ name: 'S' });
    await db.doc('admins/sub1').set({ role: 'sub', isActive: true, permissions: [] });
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
  });
  await assertFails(asAdmin('sub1').doc('sellers/s1').get());
  await assertSucceeds(asAdmin('super1').doc('sellers/s1').get());
});

function asClient(uid) {
  return testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore();
}
function asAnonymous(uid) {
  return testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: 'anonymous' } }).firestore();
}
function asAdmin(uid) {
  return testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore();
}
function unauth() {
  return testEnv.unauthenticatedContext().firestore();
}
async function seed(fn) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => fn(ctx.firestore()));
}

test('boutique_orders: le client ne peut pas modifier les statuts ou liens critiques', async () => {
  await seed((db) => db.doc('boutique_orders/o1').set({
    clientId: 'u1', sellerId: 's1', productId: 'p1', deliveryOrderId: 'd1',
    status: 'paid', totalPrice: 1000,
  }));
  const ref = asClient('u1').doc('boutique_orders/o1');
  await assertFails(ref.update({ status: 'delivered' }));
  await assertFails(ref.update({ sellerId: 's2' }));
  await assertFails(ref.update({ deliveryOrderId: 'd2' }));
});

test('sellers: le propriétaire ne peut pas créditer son wallet', async () => {
  await seed((db) => db.doc('sellers/s1').set({ wallet: 100, type: 'boutique' }));
  await assertFails(asClient('s1').doc('sellers/s1').update({ wallet: 500 }));
});

test('subscriptions: un vendeur ne peut modifier aucun champ sensible', async () => {
  await seed((db) => db.doc('sellers/s1').set({
    wallet: 5000,
    subscriptionStatus: 'active',
    subscriptionExpiresAt: new Date('2026-08-01T00:00:00Z'),
    vipStatus: 'none',
    priorityLevel: 1,
    paymentStatus: 'unpaid',
  }));
  const ref = asClient('s1').doc('sellers/s1');
  await assertFails(ref.update({ subscriptionExpiresAt: new Date('2030-01-01') }));
  await assertFails(ref.update({ vipStatus: 'active', vipExpiresAt: new Date('2030-01-01') }));
  await assertFails(ref.update({ priorityLevel: 3 }));
  await assertFails(ref.update({ paymentStatus: 'paid' }));
});

test('subscriptions: un agent E-Kbine ne peut injecter ni modifier son abonnement', async () => {
  const createData = {
    isVerified: false,
    isSuspended: false,
    walletBalance: 0,
    totalCompleted: 0,
    status: 'pending',
  };
  await assertFails(asClient('agent1').doc('ekbine_agents/agent1').set({
    ...createData,
    subscriptionStatus: 'trial',
  }));
  await assertSucceeds(asClient('agent1').doc('ekbine_agents/agent1').set(createData));
  await assertFails(asClient('agent1').doc('ekbine_agents/agent1').update({
    subscriptionStatus: 'active',
    subscriptionExpiresAt: new Date('2030-01-01'),
  }));
});

const realEstateListing = {
  agentId: 'agent1', status: 'active', price: 25000000, views: 0,
};

test('real estate: unverified user cannot publish a listing', async () => {
  await assertFails(asClient('agent1').doc('real_estate_listings/l1').set(realEstateListing));
});

test('real estate: only a verified active agent can publish a listing', async () => {
  await seed((db) => db.doc('real_estate_agents/agent1').set({
    isVerified: true, isActive: true,
  }));
  await assertSucceeds(asClient('agent1').doc('real_estate_listings/l1').set(realEstateListing));
});

test('real estate: a public view update is limited to one increment', async () => {
  await seed((db) => db.doc('real_estate_listings/l1').set(realEstateListing));
  await assertSucceeds(asClient('visitor').doc('real_estate_listings/l1').update({ views: 1 }));
  await assertFails(asClient('visitor').doc('real_estate_listings/l1').update({ views: 999999 }));
  await assertFails(asClient('visitor').doc('real_estate_listings/l1').update({ views: -1 }));
});

// ── Master Prompt "Immobilier V6.2" — Mission 13 : édition d'annonce ────────
// Autorisé : le propriétaire modifie titre/prix/champs métier. Refusé :
// un autre agent, un changement d'agentId/createdAt, une coordonnée
// publique exacte écrite directement, un client (non-agent) qui édite.

async function seedVerifiedListing(agentId = 'agent1', listingId = 'l1') {
  await seed(async (db) => {
    await db.doc(`real_estate_agents/${agentId}`).set({ isVerified: true, isActive: true });
    await db.doc(`real_estate_listings/${listingId}`).set({
      agentId, status: 'active', price: 25000000, views: 0,
      title: 'Villa initiale', propertyType: 'villa', createdAt: new Date('2026-01-01'),
    });
  });
}

test('real estate edit: le propriétaire peut modifier le titre', async () => {
  await seedVerifiedListing();
  await assertSucceeds(
    asClient('agent1').doc('real_estate_listings/l1').update({ title: 'Villa rénovée' }),
  );
});

test('real estate edit: le propriétaire peut modifier le prix (valide)', async () => {
  await seedVerifiedListing();
  await assertSucceeds(
    asClient('agent1').doc('real_estate_listings/l1').update({ price: 30000000 }),
  );
});

test('real estate edit: le propriétaire peut modifier un champ métier autorisé (rooms)', async () => {
  await seedVerifiedListing();
  await assertSucceeds(
    asClient('agent1').doc('real_estate_listings/l1').update({ rooms: 5 }),
  );
});

test('real estate edit: un autre agent ne peut PAS modifier l\'annonce', async () => {
  await seedVerifiedListing();
  await seed((db) => db.doc('real_estate_agents/agent2').set({ isVerified: true, isActive: true }));
  await assertFails(
    asClient('agent2').doc('real_estate_listings/l1').update({ title: 'Volée' }),
  );
});

test('real estate edit: agentId ne peut jamais être remplacé', async () => {
  await seedVerifiedListing();
  await assertFails(
    asClient('agent1').doc('real_estate_listings/l1').update({ agentId: 'agent2' }),
  );
});

test('real estate edit: createdAt ne peut jamais être modifié (Mission 11, V6.2)', async () => {
  await seedVerifiedListing();
  await assertFails(
    asClient('agent1').doc('real_estate_listings/l1').update({ createdAt: new Date() }),
  );
});

test('real estate edit: le propriétaire ne peut pas écrire publicLatitude directement (contournement GPS)', async () => {
  await seedVerifiedListing();
  await assertFails(
    asClient('agent1').doc('real_estate_listings/l1').update({ publicLatitude: 6.73, publicLongitude: -3.49 }),
  );
});

test('real estate edit: un client (non-agent) ne peut pas éditer une annonce', async () => {
  await seedVerifiedListing();
  await seed((db) => db.doc('clients/client1').set({ wallet: 0 }));
  await assertFails(
    asClient('client1').doc('real_estate_listings/l1').update({ title: 'Piraté' }),
  );
});

// ── clients — protection du wallet ──────────────────────────────────────────

const normalMobileClient = {
  name: 'Client mobile',
  phone: '0700000001',
  email: 'client@example.com',
  wallet: 0,
  cashOnDeliveryEnabled: true,
  fakeOrderCount: 0,
  createdAt: new Date(),
};

const normalWebClient = {
  name: 'Client web',
  phone: '0700000002',
  wallet: 0,
  cashOnDeliveryEnabled: true,
  fakeOrderCount: 0,
  createdAt: new Date(),
};

test('clients: création mobile normale avec email et wallet initial à zéro autorisée', async () => {
  await assertSucceeds(
    asClient('client-mobile').doc('clients/client-mobile').set(normalMobileClient),
  );
});

test('clients: création web normale sans email et wallet initial à zéro autorisée', async () => {
  await assertSucceeds(
    asClient('client-web').doc('clients/client-web').set(normalWebClient),
  );
});

test('clients: création refusée pour un wallet initial non nul ou de mauvais type', async () => {
  for (const [id, wallet] of [
    ['wallet-one', 1],
    ['wallet-large', 1000000],
    ['wallet-negative', -1],
    ['wallet-string', '0'],
  ]) {
    await assertFails(
      asClient(id).doc(`clients/${id}`).set({ ...normalMobileClient, wallet }),
    );
  }
});

test('clients: création refusée si un champ financier ou de privilège est ajouté', async () => {
  for (const [id, extra] of [
    ['balance', { balance: 0 }],
    ['wallet-balance', { walletBalance: 0 }],
    ['credit', { credit: 0 }],
    ['commission', { commission: 0 }],
    ['role', { role: 'admin' }],
    ['is-admin', { isAdmin: true }],
    ['is-active', { isActive: true }],
  ]) {
    await assertFails(
      asClient(id).doc(`clients/${id}`).set({ ...normalMobileClient, ...extra }),
    );
  }
});

test('clients: le propriétaire peut lire son propre profil', async () => {
  await seed((db) => db.doc('clients/u1').set({ wallet: 1000 }));
  await assertSucceeds(asClient('u1').doc('clients/u1').get());
});

test('clients: un autre utilisateur ne peut PAS lire le profil de quelqu\'un d\'autre', async () => {
  await seed((db) => db.doc('clients/u1').set({ wallet: 1000 }));
  await assertFails(asClient('u2').doc('clients/u1').get());
});

test('clients: le propriétaire ne peut PAS augmenter son propre wallet', async () => {
  await seed((db) => db.doc('clients/u1').set({ wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  await assertFails(asClient('u1').doc('clients/u1').update({ wallet: 5000 }));
});

test('clients: le propriétaire PEUT diminuer son propre wallet (paiement direct)', async () => {
  await seed((db) => db.doc('clients/u1').set({ wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  await assertSucceeds(asClient('u1').doc('clients/u1').update({ wallet: 500 }));
});

test('clients: le propriétaire ne peut PAS modifier fakeOrderCount', async () => {
  await seed((db) => db.doc('clients/u1').set({ wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  await assertFails(asClient('u1').doc('clients/u1').update({ fakeOrderCount: 99 }));
});

test('clients/wallet_transactions: append-only — aucune mise à jour, même par le propriétaire', async () => {
  await seed((db) => db.doc('clients/u1/wallet_transactions/tx1').set({ type: 'refund', amount: 100, createdAt: new Date() }));
  await assertFails(asClient('u1').doc('clients/u1/wallet_transactions/tx1').update({ amount: 999 }));
});

// ── livreurs — trouvaille documentée : lecture large ────────────────────────

test('livreurs: un utilisateur anonyme PEUT lire n\'importe quel profil livreur (trouvaille documentée, pas un test de non-régression souhaité)', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, lat: 6.7, lng: -3.4 }));
  // Ce test décrit le comportement RÉEL actuel (accès large), pas un idéal —
  // voir FIRESTORE_RULES.md section 5. S'il se met à échouer après un
  // resserrement de la règle, c'est un changement voulu, pas une régression.
  await assertSucceeds(asAnonymous('anon1').doc('livreurs/d1').get());
});

test('livreurs: le propriétaire ne peut PAS augmenter son propre wallet directement', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true }));
  await assertFails(asClient('d1').doc('livreurs/d1').update({ wallet: 5000 }));
});

test('livreurs: le propriétaire PEUT mettre à jour sa position sans toucher au wallet', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, lat: 6.7, lng: -3.4 }));
  await assertSucceeds(asClient('d1').doc('livreurs/d1').update({ lat: 6.71, lng: -3.41, isOnline: false }));
});

// ── orders — state machine ──────────────────────────────────────────────────

test('orders: création valide par le client propriétaire', async () => {
  await assertSucceeds(asClient('c1').doc('orders/o1').set({
    clientId: 'c1', budget: 1000, isPaid: false, status: 'pending',
  }));
});

test('orders: création refusée si clientId ne correspond pas à l\'auteur', async () => {
  await assertFails(asClient('c1').doc('orders/o1').set({
    clientId: 'c2', budget: 1000, isPaid: false, status: 'pending',
  }));
});

test('orders: création refusée si budget < 500', async () => {
  await assertFails(asClient('c1').doc('orders/o1').set({
    clientId: 'c1', budget: 100, isPaid: false, status: 'pending',
  }));
});

test('orders: création refusée si driverId déjà présent', async () => {
  await assertFails(asClient('c1').doc('orders/o1').set({
    clientId: 'c1', budget: 1000, isPaid: false, status: 'pending', driverId: 'd1',
  }));
});

test('orders: le client propriétaire peut lire sa commande', async () => {
  await seed((db) => db.doc('orders/o1').set({ clientId: 'c1', budget: 1000, isPaid: false, status: 'pending' }));
  await assertSucceeds(asClient('c1').doc('orders/o1').get());
});

test('orders: un autre client ne peut PAS lire une commande qui ne lui appartient pas', async () => {
  await seed((db) => db.doc('orders/o1').set({ clientId: 'c1', budget: 1000, isPaid: false, status: 'pending' }));
  await assertFails(asClient('c2').doc('orders/o1').get());
});

test('orders: le livreur assigné peut faire avancer assigned→accepted', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'assigned',
  }));
  await assertSucceeds(asClient('d1').doc('orders/o1').update({ status: 'accepted' }));
});

test('orders: le livreur assigné ne peut PAS sauter directement à "delivered" depuis "assigned"', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'assigned',
  }));
  await assertFails(asClient('d1').doc('orders/o1').update({ status: 'delivered' }));
});

test('orders: le livreur ne peut PAS modifier le budget en faisant avancer le statut', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'assigned',
  }));
  await assertFails(asClient('d1').doc('orders/o1').update({ status: 'accepted', budget: 9999 }));
});

test('orders: un livreur non assigné ne peut PAS faire avancer une commande qui ne lui est pas attribuée', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'assigned',
  }));
  await assertFails(asClient('d2').doc('orders/o1').update({ status: 'accepted' }));
});

test('orders: le client peut annuler sa commande encore pending', async () => {
  await seed((db) => db.doc('orders/o1').set({ clientId: 'c1', budget: 1000, isPaid: false, status: 'pending' }));
  await assertSucceeds(asClient('c1').doc('orders/o1').update({ status: 'cancelled' }));
});

test('orders boulangerie: le propriétaire peut uniquement démarrer la préparation puis marquer prête', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', sellerId: 'b1', sellerType: 'boulangerie',
    budget: 500, totalAmount: 2500, items: [{ name: 'Pain', price: 2000 }],
    isPaid: false, paymentMethod: 'cash', status: 'pending', sellerStatus: null,
  }));
  const ref = asClient('b1').doc('orders/o1');
  await assertSucceeds(ref.update({ sellerStatus: 'preparing' }));
  await assertSucceeds(ref.update({ sellerStatus: 'ready' }));
});

test('orders boulangerie: le propriétaire ne peut pas modifier le total, les articles ou l’adresse', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', sellerId: 'b1', sellerType: 'boulangerie',
    budget: 500, totalAmount: 2500, items: [{ name: 'Pain', price: 2000 }],
    description: 'Adresse client', isPaid: false, paymentMethod: 'cash',
    status: 'pending', sellerStatus: null,
  }));
  const ref = asClient('b1').doc('orders/o1');
  await assertFails(ref.update({ totalAmount: 999999 }));
  await assertFails(ref.update({ items: [{ name: 'Pain', price: 1 }] }));
  await assertFails(ref.update({ description: 'Autre adresse' }));
  await assertFails(ref.update({ sellerStatus: 'ready' }));
});

// ── ai_conversations / ai_pending_actions — CF-only ─────────────────────────

test('ai_conversations: le propriétaire peut lire ses messages', async () => {
  await seed((db) => db.doc('ai_conversations/u1/messages/m1').set({ role: 'user', content: 'salut' }));
  await assertSucceeds(asClient('u1').doc('ai_conversations/u1/messages/m1').get());
});

test('ai_conversations: un autre utilisateur ne peut jamais lire les messages', async () => {
  await seed((db) => db.doc('ai_conversations/u1/messages/m1').set({ role: 'user', content: 'privé' }));
  await assertFails(asClient('u2').doc('ai_conversations/u1/messages/m1').get());
});

test('ai_conversations: personne ne peut écrire directement, même le propriétaire', async () => {
  await assertFails(asClient('u1').doc('ai_conversations/u1/messages/m1').set({ role: 'user', content: 'x' }));
});

test('ai_pending_actions: le propriétaire peut lire son action en attente', async () => {
  await seed((db) => db.doc('ai_pending_actions/a1').set({ uid: 'u1', status: 'pending' }));
  await assertSucceeds(asClient('u1').doc('ai_pending_actions/a1').get());
});

test('ai_pending_actions: un autre utilisateur ne peut jamais lire l’action', async () => {
  await seed((db) => db.doc('ai_pending_actions/a1').set({ uid: 'u1', status: 'pending' }));
  await assertFails(asClient('u2').doc('ai_pending_actions/a1').get());
});

test('ai_pending_actions: personne ne peut écrire directement', async () => {
  await assertFails(asClient('u1').doc('ai_pending_actions/a1').set({ uid: 'u1', status: 'pending' }));
});

// ── audit_logs / security_events / rate_limits — CF-only strict ────────────

test('audit_logs: un super-admin peut lire', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('audit_logs/log1').set({ action: 'test' });
  });
  await assertSucceeds(asAdmin('admin1').doc('audit_logs/log1').get());
});

test('audit_logs: un sous-admin ne peut PAS lire (restreint au super-admin depuis le 2026-07-01)', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'sub', isActive: true });
    await db.doc('audit_logs/log1').set({ action: 'test' });
  });
  await assertFails(asAdmin('admin1').doc('audit_logs/log1').get());
});

test('audit_logs: un client non-admin ne peut PAS lire', async () => {
  await seed((db) => db.doc('audit_logs/log1').set({ action: 'test' }));
  await assertFails(asClient('u1').doc('audit_logs/log1').get());
});

test('audit_logs: personne ne peut écrire directement, même un admin', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertFails(asAdmin('admin1').doc('audit_logs/log1').set({ action: 'fake' }));
});

test('rate_limits: lecture et écriture interdites même à un admin', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('rate_limits/u1_payment').set({ requests: [] });
  });
  await assertFails(asAdmin('admin1').doc('rate_limits/u1_payment').get());
});

// ── admins — super-admin vs sous-admin ──────────────────────────────────────

test('admins: un sous-admin ne peut PAS modifier le rôle d\'un autre admin', async () => {
  await seed(async (db) => {
    await db.doc('admins/sub1').set({ role: 'sub', isActive: true });
    await db.doc('admins/target').set({ role: 'sub', isActive: true });
  });
  await assertFails(asAdmin('sub1').doc('admins/target').update({ role: 'super' }));
});

test('admins: un super-admin PEUT modifier le rôle d\'un autre admin', async () => {
  await seed(async (db) => {
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
    await db.doc('admins/target').set({ role: 'sub', isActive: true });
  });
  await assertSucceeds(asAdmin('super1').doc('admins/target').update({ role: 'super' }));
});

test('admins: un admin peut mettre à jour son propre champ OTP', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'sub', isActive: true, permissions: [] }));
  await assertSucceeds(asAdmin('admin1').doc('admins/admin1').update({ otpCode: '123456' }));
});

// ── pharmacies — mot de passe jamais en écriture directe (corrigé cette session) ──

test('pharmacies: un admin ne peut PAS écrire le champ password directement', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertFails(asAdmin('admin1').doc('pharmacies/ph1').set({ name: 'Pharmacie X', password: 'plaintext123' }));
});

test('pharmacies: un admin PEUT écrire les autres champs (sans password/accessCode)', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertSucceeds(asAdmin('admin1').doc('pharmacies/ph1').set({ name: 'Pharmacie X', isOnDuty: true }));
});

test('pharmacie_credentials: lecture et écriture interdites à tout client, même le propriétaire présumé', async () => {
  await seed((db) => db.doc('pharmacie_credentials/ph1').set({ hash: 'salt:hash' }));
  await assertFails(asClient('anyone').doc('pharmacie_credentials/ph1').get());
});

// ── config vs app_config — la seule règle publique du fichier ──────────────

test('config: lecture publique, même sans authentification (règle intentionnelle)', async () => {
  await seed((db) => db.doc('config/commission').set({ commissionBasic: 100 }));
  await assertSucceeds(unauth().doc('config/commission').get());
});

test('app_config: lecture refusée sans être admin (contrairement à config)', async () => {
  await seed((db) => db.doc('app_config/business').set({ someThreshold: 42 }));
  await assertFails(asClient('u1').doc('app_config/business').get());
});

test('boulangeries: catalogue lisible par une session authentifiée, écriture client refusée', async () => {
  await seed((db) => db.doc('boulangeries/b1').set({
    name: 'Boulangerie Test', isActive: true,
  }));
  await assertSucceeds(
    asAnonymous('anon1').collection('boulangeries')
      .where('isActive', '==', true).orderBy('name').get(),
  );
  await assertFails(
    asClient('u1').doc('boulangeries/b1').update({ name: 'Détournée' }),
  );
});

test('app_config: seul blanchisserie est lisible par le client et reste non modifiable', async () => {
  await seed(async (db) => {
    await db.doc('app_config/blanchisserie').set({
      services: ['Lavage'], pricePerKg: 1000,
    });
    await db.doc('app_config/payment').set({ privateNumber: 'secret' });
  });
  const db = asClient('u1');
  await assertSucceeds(db.doc('app_config/blanchisserie').get());
  await assertFails(db.doc('app_config/payment').get());
  await assertFails(unauth().doc('app_config/blanchisserie').get());
  await assertFails(
    db.doc('app_config/blanchisserie').update({ pricePerKg: 1 }),
  );
});

test('simple_services: un client authentifié lit les catalogues Tricycle et Taxi disponibles', async () => {
  await seed(async (db) => {
    await db.doc('simple_services/tricycle-1').set({
      name: 'Prestataire Tricycle', phone: '0700000000', photoUrl: '',
      serviceType: 'tricycle', isAvailable: true,
    });
    await db.doc('simple_services/taxi-1').set({
      name: 'Prestataire Taxi', phone: '0500000000', photoUrl: '',
      serviceType: 'taxi_nuit', isAvailable: true,
    });
  });
  const db = asClient('u1');
  await assertSucceeds(db.collection('simple_services')
    .where('serviceType', '==', 'tricycle')
    .where('isAvailable', '==', true).get());
  await assertSucceeds(db.collection('simple_services')
    .where('serviceType', '==', 'taxi_nuit')
    .where('isAvailable', '==', true).get());
});

test('simple_services: session non authentifiée refusée et fiche indisponible invisible au client', async () => {
  await seed(async (db) => {
    await db.doc('simple_services/public').set({
      name: 'Visible', phone: '0700000000', photoUrl: '',
      serviceType: 'tricycle', isAvailable: true,
    });
    await db.doc('simple_services/hidden').set({
      name: 'Masqué', phone: '0700000000', photoUrl: '',
      serviceType: 'tricycle', isAvailable: false,
    });
  });
  await assertFails(unauth().doc('simple_services/public').get());
  await assertFails(asClient('u1').doc('simple_services/hidden').get());
});

test('simple_service_private: client sans lecture et sans écriture', async () => {
  await seed((db) => db.doc('simple_service_private/s1').set({
    idNumber: 'CI-SECRET', idPhotoUrl: 'private/id.jpg', lat: 6.7, lng: -3.4,
  }));
  const db = asClient('u1');
  await assertFails(db.doc('simple_service_private/s1').get());
  await assertFails(db.doc('simple_service_private/s1').update({ idNumber: 'X' }));
  await assertFails(db.doc('simple_service_private/s1').delete());
});

test('simple_services: client sans création, modification, suppression ni réinjection privée', async () => {
  await seed((db) => db.doc('simple_services/s1').set({
    name: 'Prestataire', phone: '0700000000', photoUrl: '',
    serviceType: 'tricycle', isAvailable: true,
  }));
  const db = asClient('u1');
  await assertFails(db.doc('simple_services/s2').set({
    name: 'Faux', phone: '0700000000', photoUrl: '',
    serviceType: 'tricycle', isAvailable: true,
  }));
  await assertFails(db.doc('simple_services/s1').update({ name: 'Détourné' }));
  await assertFails(db.doc('simple_services/s1').update({ idNumber: 'INJECTÉ' }));
  await assertFails(db.doc('simple_services/s1').delete());
});

test('simple_services: admin tricycle administre catalogue et identité, autre sous-admin refusé', async () => {
  await seed(async (db) => {
    await db.doc('admins/sub-tricycle').set({
      role: 'sub', isActive: true, permissions: ['tricycle'],
    });
    await db.doc('admins/sub-other').set({
      role: 'sub', isActive: true, permissions: ['services'],
    });
  });
  await assertSucceeds(asAdmin('sub-tricycle').doc('simple_services/s1').set({
    name: 'Prestataire', phone: '0700000000', serviceType: 'tricycle',
    isAvailable: true, photoUrl: '',
  }));
  await assertSucceeds(asAdmin('sub-tricycle').doc('simple_service_private/s1').set({
    idNumber: 'CI-SECRET', idPhotoUrl: 'private/id.jpg', lat: 6.7, lng: -3.4,
  }));
  await assertFails(asAdmin('sub-other').doc('simple_services/s2').set({
    name: 'Prestataire', phone: '0700000000', photoUrl: '',
    serviceType: 'tricycle', isAvailable: true,
  }));
  await assertFails(asAdmin('sub-other').doc('simple_service_private/s1').get());
});

test('simple_services: même un admin ne peut réinjecter un justificatif dans le catalogue', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertFails(asAdmin('admin1').doc('simple_services/s1').set({
    name: 'Prestataire', phone: '0700000000', photoUrl: '',
    serviceType: 'tricycle', isAvailable: true, idNumber: 'INTERDIT',
  }));
});

test('simple_services: cycle admin atomique conserve puis supprime les deux documents', async () => {
  await seed((db) => db.doc('admins/sub-tricycle').set({
    role: 'sub', isActive: true, permissions: ['tricycle'],
  }));
  const db = asAdmin('sub-tricycle');
  const publicRef = db.doc('simple_services/atomic-service');
  const privateRef = db.doc('simple_service_private/atomic-service');

  const create = db.batch();
  create.set(publicRef, {
    name: 'Prestataire test', phone: '0700000000', photoUrl: '',
    serviceType: 'tricycle', isAvailable: true,
  });
  create.set(privateRef, {
    idNumber: 'TEST-ID', idPhotoUrl: 'simple_services/test/id_photo.jpg',
    lat: 6.7, lng: -3.4,
  });
  await assertSucceeds(create.commit());

  const update = db.batch();
  update.update(publicRef, { name: 'Prestataire modifié' });
  update.update(privateRef, { lat: 6.8 });
  await assertSucceeds(update.commit());
  assert.equal((await publicRef.get()).data().name, 'Prestataire modifié');
  assert.equal((await privateRef.get()).data().lat, 6.8);

  const remove = db.batch();
  remove.delete(publicRef);
  remove.delete(privateRef);
  await assertSucceeds(remove.commit());
  assert.equal((await publicRef.get()).exists, false);
  assert.equal((await privateRef.get()).exists, false);
});

test('orders: a paid wallet order without an atomic debit is rejected', async () => {
  await seed((db) => db.doc('clients/c1').set({ wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  await assertFails(asClient('c1').doc('orders/o1').set({
    clientId: 'c1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  }));
});

// LOT 6 SECURITY (2026-09) : le débit atomique seul ne suffit plus — la
// transaction doit désormais aussi écrire `lastPaidOrderId` sur le client,
// égal à l'ID de la commande créée (voir walletDebitMatchesPaidOrder ci-
// dessus et la section "LOT 6 SECURITY" en fin de fichier pour le test de
// régression complet sur la réutilisation d'un même débit).
test('orders: a paid wallet order with the exact atomic debit AND matching lastPaidOrderId is allowed', async () => {
  await seed((db) => db.doc('clients/c1').set({ wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  const db = asClient('c1');
  const batch = db.batch();
  batch.update(db.doc('clients/c1'), { wallet: 1000, lastPaidOrderId: 'o1' });
  batch.set(db.doc('orders/o1'), {
    clientId: 'c1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertSucceeds(batch.commit());
});

test('orders: a paid wallet order with the exact atomic debit but WITHOUT lastPaidOrderId is rejected (LOT 6 SECURITY)', async () => {
  await seed((db) => db.doc('clients/c1').set({ wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  const db = asClient('c1');
  const batch = db.batch();
  batch.update(db.doc('clients/c1'), { wallet: 1000 });
  batch.set(db.doc('orders/o1'), {
    clientId: 'c1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertFails(batch.commit());
});

// ═══════════════════════════════════════════════════════════════════════════
// E-Kbine — multi-numéros (depositAccounts) — Mission "FINALISATION ET
// VALIDATION DU MODULE MULTI-NUMÉROS E-KBINE".
// ═══════════════════════════════════════════════════════════════════════════

function seedEligibleAgent(db, id, overrides = {}) {
  return db.doc(`ekbine_agents/${id}`).set({
    name: 'Agent Test', phone: '0700000000', isOnline: true,
    isVerified: true, isSuspended: false, subscriptionStatus: 'active',
    walletBalance: 0, totalCompleted: 0, rating: 0, ratingCount: 0,
    depositAccounts: [{ id: 'acc1', operator: 'orange', phoneNumber: '0700000000', isPrimary: true, isActive: true }],
    ...overrides,
  });
}

function seedDepositConfirmedOrder(db, overrides = {}) {
  return db.doc('ekbine_orders/o1').set({
    clientId: 'c1', agentId: 'a1', amount: 1000, fee: 0, totalPaid: 1000,
    operator: 'orange', status: 'deposit_confirmed',
    agentDepositAccountId: 'acc1', agentDepositNumber: '0700000000', agentDepositOperator: 'orange',
    ...overrides,
  });
}

// ── 1. Agent modifie uniquement son propre depositAccounts ─────────────────
test('ekbine_agents.depositAccounts: l\'agent propriétaire peut modifier ses propres numéros de dépôt', async () => {
  await seed((db) => seedEligibleAgent(db, 'a1'));
  await assertSucceeds(asClient('a1').doc('ekbine_agents/a1').update({
    depositAccounts: [{ id: 'acc1', operator: 'orange', phoneNumber: '0711111111', isPrimary: true, isActive: true }],
  }));
});

// ── 2. Autre utilisateur refusé ─────────────────────────────────────────────
test('ekbine_agents.depositAccounts: un autre utilisateur ne peut PAS modifier les numéros d\'un agent qui n\'est pas le sien', async () => {
  await seed((db) => seedEligibleAgent(db, 'a1'));
  await assertFails(asClient('a2').doc('ekbine_agents/a1').update({
    depositAccounts: [{ id: 'hack', operator: 'wave', phoneNumber: '0799999999', isPrimary: true, isActive: true }],
  }));
});

// ── 3. Champs administratifs protégés ───────────────────────────────────────
test('ekbine_agents.depositAccounts: l\'agent ne peut PAS s\'auto-vérifier en modifiant ses numéros dans la même écriture', async () => {
  await seed((db) => seedEligibleAgent(db, 'a1', { isVerified: false }));
  await assertFails(asClient('a1').doc('ekbine_agents/a1').update({
    depositAccounts: [{ id: 'acc1', operator: 'orange', phoneNumber: '0700000000', isPrimary: true, isActive: true }],
    isVerified: true,
  }));
});

test('ekbine_agents.depositAccounts: l\'agent ne peut PAS s\'auto-créditer walletBalance en modifiant ses numéros dans la même écriture', async () => {
  await seed((db) => seedEligibleAgent(db, 'a1'));
  await assertFails(asClient('a1').doc('ekbine_agents/a1').update({
    depositAccounts: [{ id: 'acc1', operator: 'orange', phoneNumber: '0700000000', isPrimary: true, isActive: true }],
    walletBalance: 999999,
  }));
});

// ── 4. Numéro figé dans la commande — immuable pour l'agent lui-même ───────
test('ekbine_orders: l\'agent ne peut PAS modifier agentDepositNumber en démarrant le service (deposit_confirmed→in_progress)', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1');
    await seedDepositConfirmedOrder(db);
  });
  await assertFails(asClient('a1').doc('ekbine_orders/o1').update({
    status: 'in_progress', agentDepositNumber: '0799999999',
  }));
});

test('ekbine_orders: l\'agent éligible PEUT démarrer le service (deposit_confirmed→in_progress) sans toucher au numéro figé', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1');
    await seedDepositConfirmedOrder(db);
  });
  await assertSucceeds(asClient('a1').doc('ekbine_orders/o1').update({ status: 'in_progress' }));
});

// ── 5. Client ne peut pas modifier agentDepositNumber (ex. en annulant) ────
test('ekbine_orders: le client ne peut PAS modifier agentDepositNumber en annulant sa commande', async () => {
  await seed((db) => db.doc('ekbine_orders/o1').set({
    clientId: 'c1', agentId: 'a1', amount: 1000, status: 'awaiting_deposit',
    agentDepositAccountId: 'acc1', agentDepositNumber: '0700000000', agentDepositOperator: 'orange',
  }));
  await assertFails(asClient('c1').doc('ekbine_orders/o1').update({
    status: 'cancelled', agentDepositNumber: '0799999999',
  }));
});

test('ekbine_orders: le client PEUT annuler sa commande sans toucher au numéro figé', async () => {
  await seed((db) => db.doc('ekbine_orders/o1').set({
    clientId: 'c1', agentId: 'a1', amount: 1000, status: 'awaiting_deposit',
    agentDepositAccountId: 'acc1', agentDepositNumber: '0700000000', agentDepositOperator: 'orange',
  }));
  await assertSucceeds(asClient('c1').doc('ekbine_orders/o1').update({ status: 'cancelled' }));
});

// ── 6. Agent suspendu refusé ─────────────────────────────────────────────────
test('ekbine_orders: un agent SUSPENDU ne peut PAS démarrer le service même sur sa propre commande assignée', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1', { isSuspended: true });
    await seedDepositConfirmedOrder(db);
  });
  await assertFails(asClient('a1').doc('ekbine_orders/o1').update({ status: 'in_progress' }));
});

// ── 7. Abonnement suspendu refusé ───────────────────────────────────────────
test('ekbine_orders: un agent avec subscriptionStatus="suspended" ne peut PAS démarrer le service', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1', { subscriptionStatus: 'suspended' });
    await seedDepositConfirmedOrder(db);
  });
  await assertFails(asClient('a1').doc('ekbine_orders/o1').update({ status: 'in_progress' }));
});

// ── 8. Agent trial/active autorisé ──────────────────────────────────────────
test('ekbine_orders: un agent en essai gratuit (subscriptionStatus="trial") PEUT démarrer le service', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1', { subscriptionStatus: 'trial' });
    await seedDepositConfirmedOrder(db);
  });
  await assertSucceeds(asClient('a1').doc('ekbine_orders/o1').update({ status: 'in_progress' }));
});

test('ekbine_orders: un agent avec abonnement actif (subscriptionStatus="active") PEUT démarrer le service', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1', { subscriptionStatus: 'active' });
    await seedDepositConfirmedOrder(db);
  });
  await assertSucceeds(asClient('a1').doc('ekbine_orders/o1').update({ status: 'in_progress' }));
});

// ── Numéro figé — également protégé quand l'agent envoie sa propre preuve
// de service (in_progress→proof_sent), pas seulement au démarrage ─────────
test('ekbine_orders: l\'agent ne peut PAS modifier agentDepositNumber en envoyant sa preuve de service', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1');
    await db.doc('ekbine_orders/o1').set({
      clientId: 'c1', agentId: 'a1', amount: 1000, status: 'in_progress',
      agentDepositAccountId: 'acc1', agentDepositNumber: '0700000000', agentDepositOperator: 'orange',
    });
  });
  await assertFails(asClient('a1').doc('ekbine_orders/o1').update({
    status: 'proof_sent', agentDepositNumber: '0799999999',
  }));
});

test('ekbine_orders: l\'agent PEUT envoyer sa preuve de service sans toucher au numéro figé', async () => {
  await seed(async (db) => {
    await seedEligibleAgent(db, 'a1');
    await db.doc('ekbine_orders/o1').set({
      clientId: 'c1', agentId: 'a1', amount: 1000, status: 'in_progress',
      agentDepositAccountId: 'acc1', agentDepositNumber: '0700000000', agentDepositOperator: 'orange',
    });
  });
  await assertSucceeds(asClient('a1').doc('ekbine_orders/o1').update({ status: 'proof_sent' }));
});

// ── Immobilier — GPS privé / confidentialité réelle V2 ──────────────────────
// (real_estate_listings location fields, real_estate_private_locations,
// real_estate_location_access)

const verifiedAgent = { isVerified: true, isActive: true };
const hiddenListing = {
  agentId: 'agent1', status: 'active', price: 100000, views: 0,
  locationPrivacy: 'hidden', hasExactLocation: false,
};
const approxListing = {
  agentId: 'agent1', status: 'active', price: 100000, views: 0,
  locationPrivacy: 'approximate', hasExactLocation: false,
  publicLatitude: 6.745, publicLongitude: -3.493, publicGeohash: 'ecjw2',
};
const privateLocation = {
  listingId: 'l1', ownerId: 'agent1', agentId: 'agent1',
  exactLatitude: 6.7273, exactLongitude: -3.4961, exactGeohash: 'ecjw22wjq',
  locationVerified: true,
};

test('real estate: lecture publique d\'une annonce active fonctionne toujours (non régressé)', async () => {
  await seed((db) => db.doc('real_estate_listings/l1').set(hiddenListing));
  await assertSucceeds(asClient('visitor').doc('real_estate_listings/l1').get());
});

test('real estate private location: le propriétaire/agent de l\'annonce peut lire la position exacte', async () => {
  await seed((db) => db.doc('real_estate_private_locations/l1').set(privateLocation));
  await assertSucceeds(asClient('agent1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un AUTRE agent ne peut PAS lire la position exacte', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('real_estate_agents/agent2').set(verifiedAgent);
  });
  await assertFails(asClient('agent2').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un admin peut lire la position exacte', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
  });
  await assertSucceeds(asAdmin('admin1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un utilisateur anonyme ne peut PAS lire la position exacte', async () => {
  await seed((db) => db.doc('real_estate_private_locations/l1').set(privateLocation));
  await assertFails(asAnonymous('anon1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un client SANS aucune demande de visite ne peut PAS lire la position exacte', async () => {
  await seed((db) => db.doc('real_estate_private_locations/l1').set(privateLocation));
  await assertFails(asClient('client1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un client avec une visite encore "pending" ne peut PAS lire la position exacte', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('real_estate_visit_requests/r1').set({
      listingId: 'l1', clientId: 'client1', agentId: 'agent1', status: 'pending',
    });
    // Aucun real_estate_location_access créé — c'est exactement le
    // comportement réel de respondToVisitRequest tant que rien n'est confirmé.
  });
  await assertFails(asClient('client1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un client avec une visite "declined" ne peut PAS lire la position exacte', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('real_estate_visit_requests/r1').set({
      listingId: 'l1', clientId: 'client1', agentId: 'agent1', status: 'declined',
    });
  });
  await assertFails(asClient('client1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un client avec une visite "confirmed" (accès accordé) PEUT lire la position exacte', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('real_estate_visit_requests/r1').set({
      listingId: 'l1', clientId: 'client1', agentId: 'agent1', status: 'confirmed',
    });
    // Ce document est normalement créé par respondToVisitRequest (Admin SDK,
    // hors Rules) dans la même transaction que le passage à "confirmed" —
    // simulé ici directement pour tester la lecture qui en dépend.
    await db.doc('real_estate_location_access/l1_client1').set({
      listingId: 'l1', clientId: 'client1', isActive: true, visitRequestId: 'r1',
    });
  });
  await assertSucceeds(asClient('client1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: un accès désactivé (isActive:false) refuse quand même la lecture', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_private_locations/l1').set(privateLocation);
    await db.doc('real_estate_location_access/l1_client1').set({
      listingId: 'l1', clientId: 'client1', isActive: false,
    });
  });
  await assertFails(asClient('client1').doc('real_estate_private_locations/l1').get());
});

test('real estate private location: écriture directe par le client TOUJOURS refusée (Cloud-Function-only)', async () => {
  await seed((db) => db.doc('real_estate_agents/agent1').set(verifiedAgent));
  await assertFails(asClient('agent1').doc('real_estate_private_locations/l1').set(privateLocation));
});

test('real estate location access: seul le client concerné (ou un admin) peut lire son propre accès', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_location_access/l1_client1').set({
      listingId: 'l1', clientId: 'client1', isActive: true,
    });
  });
  await assertSucceeds(asClient('client1').doc('real_estate_location_access/l1_client1').get());
  await assertFails(asClient('client2').doc('real_estate_location_access/l1_client1').get());
});

test('real estate location access: écriture directe par le client refusée (Cloud-Function-only)', async () => {
  await assertFails(asClient('client1').doc('real_estate_location_access/l1_client1').set({
    listingId: 'l1', clientId: 'client1', isActive: true,
  }));
});

test('real estate: création directe avec des coordonnées publiques exactes est refusée (doit passer par upsertRealEstateLocation)', async () => {
  await seed((db) => db.doc('real_estate_agents/agent1').set(verifiedAgent));
  await assertFails(asClient('agent1').doc('real_estate_listings/l2').set({
    ...realEstateListing, publicLatitude: 6.7273, publicLongitude: -3.4961,
  }));
  await assertFails(asClient('agent1').doc('real_estate_listings/l3').set({
    ...realEstateListing, lat: 6.7273, lng: -3.4961,
  }));
});

test('real estate: le propriétaire ne peut PAS modifier directement les champs de localisation publique', async () => {
  await seed(async (db) => {
    await db.doc('real_estate_agents/agent1').set(verifiedAgent);
    await db.doc('real_estate_listings/l1').set(approxListing);
  });
  const ref = asClient('agent1').doc('real_estate_listings/l1');
  await assertFails(ref.update({ publicLatitude: 6.7273, publicLongitude: -3.4961 }));
  await assertFails(ref.update({ locationPrivacy: 'exact' }));
  await assertFails(ref.update({ hasExactLocation: true }));
  await assertFails(ref.update({ lat: 6.7273, lng: -3.4961 }));
});

test('real estate: hidden — aucun champ de coordonnée publique exacte présent sur le document public', async () => {
  await seed((db) => db.doc('real_estate_listings/l1').set(hiddenListing));
  const snap = await asClient('visitor').doc('real_estate_listings/l1').get();
  const data = snap.data();
  assert.equal(data.publicLatitude, undefined);
  assert.equal(data.publicLongitude, undefined);
  assert.equal(data.hasExactLocation, false);
});

test('real estate: approximate — la position publique n\'est jamais la coordonnée exacte', async () => {
  await seed((db) => db.doc('real_estate_listings/l1').set(approxListing));
  const snap = await asClient('visitor').doc('real_estate_listings/l1').get();
  const data = snap.data();
  assert.notEqual(data.publicLatitude, 6.7273);
  assert.notEqual(data.publicLongitude, -3.4961);
  assert.equal(data.hasExactLocation, false);
});

// ── Événementiel ──────────────────────────────────────────────────────────
test('event: un prestataire réel peut créer une boutique pending mais pas auto-valider', async () => {
  const provider = {
    ownerId: 'event-owner',
    shopName: 'Fêtes & Co',
    description: 'Location et décoration',
    zone: 'Abengourou',
    status: 'pending',
    isSuspended: false,
    requestedPlan: 'premium',
    planStatus: 'pending',
  };
  await assertSucceeds(
    asClient('event-owner').doc('event_providers/event-owner').set(provider),
  );
  await assertFails(
    asClient('event-owner').doc('event_providers/event-owner').update({ status: 'approved' }),
  );
});

test('event: seul un prestataire approuvé peut publier une prestation', async () => {
  const offer = {
    ownerId: 'event-owner',
    providerId: 'p1',
    providerName: 'Fêtes & Co',
    title: '200 chaises',
    category: 'rental',
    subcategory: 'Chaises',
    unitPrice: 250,
    availableQuantity: 500,
    isActive: true,
  };
  await seed((db) => db.doc('event_providers/p1').set({
    ownerId: 'event-owner',
    status: 'pending',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o1').set(offer),
  );
  await seed((db) => db.doc('event_providers/p1').update({ status: 'approved' }));
  await assertSucceeds(
    asClient('event-owner').doc('event_offers/o1').set(offer),
  );
});

// Correction ciblée "Protection à la création des event_offers" : un client
// ne doit pouvoir injecter aucun champ administratif/tarifaire/priorité dès
// la création d'une prestation, pas seulement à la modification.
test('event: création d\'offre — un prestataire approuvé ne peut pas injecter priorityLevel', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-priority').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      priorityLevel: 3,
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé ne peut pas injecter plan: "vvip"', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-plan').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      plan: 'vvip',
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé ne peut pas injecter planStatus: "active"', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-planstatus').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      planStatus: 'active',
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé ne peut pas injecter featuredUntil', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  const future = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-featured').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      featuredUntil: future,
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé ne peut pas injecter paymentStatus: "paid"', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-payment').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      paymentStatus: 'paid',
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé ne peut pas injecter monthlyPrice: 0', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertFails(
    asClient('event-owner').doc('event_offers/o-bad-monthly').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
      monthlyPrice: 0,
    }),
  );
});

test('event: création d\'offre — un prestataire approuvé peut créer une offre normale sans champs protégés', async () => {
  await seed((db) => db.doc('event_providers/p-approved').set({
    ownerId: 'event-owner',
    status: 'approved',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  }));
  await assertSucceeds(
    asClient('event-owner').doc('event_offers/o-good').set({
      ownerId: 'event-owner',
      providerId: 'p-approved',
      providerName: 'Fêtes & Co',
      title: '200 chaises',
      category: 'rental',
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      isActive: false,
    }),
  );
});

test('event: inscription atomique autorise les prestations initiales inactives', async () => {
  const db = asClient('event-owner');
  const batch = db.batch();
  batch.set(db.doc('event_providers/event-owner'), {
    ownerId: 'event-owner',
    shopName: 'Events AZ',
    status: 'pending',
    isSuspended: false,
    requestedPlan: 'standard',
    planStatus: 'pending',
  });
  batch.set(db.doc('event_offers/o-new'), {
    ownerId: 'event-owner',
    providerId: 'event-owner',
    providerName: 'Events AZ',
    title: 'Décoration mariage',
    category: 'decoration',
    subcategory: 'Mariage',
    unitPrice: 150000,
    availableQuantity: 1,
    isActive: false,
  });
  await assertSucceeds(batch.commit());
});

test('event: le client ne peut pas activer ni tarifer son plan', async () => {
  const base = {
    ownerId: 'event-owner',
    shopName: 'Events AZ',
    status: 'pending',
    isSuspended: false,
    requestedPlan: 'vvip',
    planStatus: 'pending',
  };
  await assertSucceeds(
    asClient('event-owner').doc('event_providers/event-owner').set(base),
  );
  await assertFails(
    asClient('event-owner').doc('event_providers/event-owner').update({
      planStatus: 'active',
      plan: 'vvip',
      priorityLevel: 3,
      monthlyPrice: 0,
      paymentStatus: 'paid',
    }),
  );
  await assertFails(
    asClient('other-owner').doc('event_providers/other-owner').set({
      ...base,
      ownerId: 'other-owner',
      plan: 'vvip',
      priorityLevel: 3,
    }),
  );
});

test('event: un administrateur peut gérer le plan et les dates protégées', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ isActive: true, role: 'super' });
    await db.doc('event_providers/event-owner').set({
      ownerId: 'event-owner',
      status: 'approved',
      isSuspended: false,
      requestedPlan: 'premium',
      planStatus: 'pending',
    });
  });
  await assertSucceeds(
    asAdmin('admin1').doc('event_providers/event-owner').update({
      plan: 'premium',
      planStatus: 'active',
      priorityLevel: 2,
      monthlyPrice: 1000,
      isLaunchPrice: true,
      planEndsAt: new Date('2026-09-01T00:00:00Z'),
    }),
  );
});

test('event: les documents KYC ne sont jamais publics', async () => {
  await seed((db) => db.doc('event_provider_documents/event-owner').set({
    ownerId: 'event-owner',
    providerId: 'event-owner',
    identityUrl: 'private',
  }));
  await assertSucceeds(
    asClient('event-owner')
      .doc('event_provider_documents/event-owner')
      .get(),
  );
  await assertFails(
    asClient('other-client')
      .doc('event_provider_documents/event-owner')
      .get(),
  );
});

// LOT 6.3 SECURITY (2026-09) : plus aucune création directe côté client,
// quelle que soit sa forme — même un document parfaitement correct (débit
// atomique exact, lastPaidReservationId correspondant, montant réel) est
// désormais refusé, puisque seule createEventReservationCF (Admin SDK) peut
// créer ce document. Remplace l'ancien test LOT 6.1/6.2 qui vérifiait le
// mécanisme lastPaidReservationId, devenu obsolète (walletDebitMatchesPaidReservation
// supprimée — voir l'historique juste avant isPharmacieOwnerOfOrder() dans
// firestore.rules). La couverture du calcul de prix/anti-réutilisation de
// débit vit désormais dans functions/test/eventReservations.test.js
// (12 tests dédiés à createEventReservationCF).
test('event: la création directe côté client est TOUJOURS refusée, même avec un débit atomique exact et un marqueur correspondant (LOT 6.3 : CF-only)', async () => {
  await seed((db) => db.doc('clients/client-event').set({ wallet: 100000 }));
  const reservation = {
    clientId: 'client-event',
    providerIds: ['p1'],
    items: [{ offerId: 'o1', providerId: 'p1', quantity: 2 }],
    totalAmount: 50000,
    paymentMethod: 'wallet',
    isPaid: true,
    status: 'pending',
  };
  await assertFails(
    asClient('client-event').doc('event_reservations/r-bad').set(reservation),
  );

  const clientDb = asClient('client-event');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/client-event'), {
    wallet: 50000, lastPaidReservationId: 'r-ok',
  });
  batch.set(clientDb.doc('event_reservations/r-ok'), reservation);
  await assertFails(batch.commit());

  // Même une réservation cash (jamais concernée par le débit) est refusée.
  await assertFails(asClient('client-event').doc('event_reservations/r-cash').set({
    clientId: 'client-event', providerIds: ['p1'], items: [{ offerId: 'o1', quantity: 1 }],
    totalAmount: 5000, paymentMethod: 'cash', isPaid: false, status: 'pending',
  }));
});

test('event: un client ne peut qu’annuler sa réservation sans altérer le montant', async () => {
  await seed((db) => db.doc('event_reservations/r1').set({
    clientId: 'client-event',
    providerIds: ['p1'],
    status: 'pending',
    totalAmount: 50000,
  }));
  const ref = asClient('client-event').doc('event_reservations/r1');
  await assertSucceeds(ref.update({ status: 'cancelled', updatedAt: new Date() }));
  await assertFails(ref.update({ totalAmount: 1 }));
});

test('marketplace: la création directe est refusée au vendeur', async () => {
  await assertFails(asClient('seller1').doc('marketplace_products/p1').set({
    sellerId: 'seller1',
    title: 'Téléphone',
    price: 10000,
    status: 'active',
    expiresAt: new Date('2026-09-08T00:00:00Z'),
  }));
});

test('marketplace: le vendeur peut masquer mais pas republier directement', async () => {
  await seed((db) => db.doc('marketplace_products/p1').set({
    sellerId: 'seller1',
    title: 'Téléphone',
    price: 10000,
    status: 'active',
    expiresAt: new Date('2026-09-08T00:00:00Z'),
    sellerVerified: false,
    sellerVipStatus: 'none',
    priorityLevel: 0,
    views: 0,
    favoritesCount: 0,
  }));
  const ref = asClient('seller1').doc('marketplace_products/p1');
  await assertSucceeds(ref.update({ status: 'hidden' }));
  await assertFails(ref.update({ status: 'active' }));
});

test('marketplace: les champs système restent immuables pour le vendeur', async () => {
  await seed((db) => db.doc('marketplace_products/p1').set({
    sellerId: 'seller1',
    title: 'Téléphone',
    price: 10000,
    status: 'active',
    expiresAt: new Date('2026-09-08T00:00:00Z'),
    sellerVerified: false,
    sellerVipStatus: 'none',
    priorityLevel: 0,
    views: 0,
    favoritesCount: 0,
  }));
  const ref = asClient('seller1').doc('marketplace_products/p1');
  await assertFails(ref.update({ expiresAt: new Date('2099-01-01T00:00:00Z') }));
  await assertFails(ref.update({ sellerVerified: true }));
  await assertFails(ref.update({ sellerVipStatus: 'active' }));
  await assertFails(ref.update({ priorityLevel: 999 }));
});

test('notifications partenaires: le propriétaire restaurant ne modifie que son fcmToken', async () => {
  await seed(async (db) => {
    await db.doc('restaurant_owners/owner1').set({ restaurantId: 'restaurant1' });
    await db.doc('restaurant_owners/owner2').set({ restaurantId: 'restaurant2' });
    await db.doc('restaurants/restaurant1').set({
      name: 'Restaurant 1',
      fcmToken: 'ancien-token-restaurant',
    });
  });

  const ownerRef = asClient('owner1').doc('restaurants/restaurant1');
  await assertSucceeds(ownerRef.update({ fcmToken: 'nouveau-token-restaurant' }));
  await assertFails(ownerRef.update({
    fcmToken: 'autre-token-restaurant',
    name: 'Nom modifié',
  }));
  await assertFails(
    asClient('owner2')
      .doc('restaurants/restaurant1')
      .update({ fcmToken: 'token-cross-user-refuse' }),
  );
});

test('notifications partenaires: seule la session pharmacie liée modifie fcmToken', async () => {
  await seed((db) => db.doc('pharmacies/pharmacie1').set({
    name: 'Pharmacie 1',
    currentUid: 'session-pharmacie',
    fcmToken: 'ancien-token-pharmacie',
  }));

  const ownerRef = asAnonymous('session-pharmacie').doc('pharmacies/pharmacie1');
  await assertSucceeds(ownerRef.update({ fcmToken: 'nouveau-token-pharmacie' }));
  await assertFails(ownerRef.update({
    fcmToken: 'autre-token-pharmacie',
    name: 'Nom modifié',
  }));
  await assertFails(
    asAnonymous('autre-session')
      .doc('pharmacies/pharmacie1')
      .update({ fcmToken: 'token-cross-user-refuse' }),
  );
  await assertFails(
    asAnonymous('autre-session')
      .doc('pharmacies/pharmacie1')
      .update({ currentUid: 'autre-session' }),
  );
});

test('notifications partenaires: un agent E-Kbine ne modifie que son document', async () => {
  await seed((db) => db.doc('ekbine_agents/agent1').set({
    isVerified: true,
    isSuspended: false,
    walletBalance: 0,
    totalCompleted: 0,
    fcmToken: 'ancien-token-ekbine',
  }));

  await assertSucceeds(
    asClient('agent1')
      .doc('ekbine_agents/agent1')
      .update({ fcmToken: 'nouveau-token-ekbine' }),
  );
  await assertFails(
    asClient('agent2')
      .doc('ekbine_agents/agent1')
      .update({ fcmToken: 'token-cross-user-refuse' }),
  );
});

function validVehicleListing(sellerId = 'seller1', overrides = {}) {
  return {
    sellerId,
    sellerType: 'individual',
    vehicleType: 'car',
    offerType: 'sale',
    title: 'Toyota Corolla',
    description: 'Véhicule propre et régulièrement entretenu.',
    brand: 'Toyota',
    model: 'Corolla',
    year: 2024,
    condition: 'used',
    color: 'Gris',
    mileageKm: 25000,
    transmission: 'automatic',
    fuelType: 'petrol',
    seats: 5,
    salePrice: 2500000,
    rentalWithDriver: false,
    rentalWithoutDriver: false,
    price: 2500000,
    currency: 'XOF',
    cityId: 'agnibilekrou',
    cityName: 'Agnibilékrou',
    status: 'draft',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

test('vehicle_listings: le propriétaire réel crée et lit son annonce valide', async () => {
  const ref = asClient('seller1').doc('vehicle_listings/v1');
  await assertSucceeds(ref.set(validVehicleListing()));
  await assertSucceeds(ref.get());
});

test('vehicle_listings: une annonce active est lisible par une session authentifiée', async () => {
  await seed((db) => db.doc('vehicle_listings/v1').set(
    validVehicleListing('seller1', {
      createdAt: new Date(),
      updatedAt: new Date(),
      status: 'active',
    }),
  ));
  await assertSucceeds(asClient('reader1').doc('vehicle_listings/v1').get());
  await assertFails(unauth().doc('vehicle_listings/v1').get());
});

test('vehicle_listings: création non authentifiée, anonyme ou cross-user refusée', async () => {
  await assertFails(
    unauth().doc('vehicle_listings/v1').set(validVehicleListing()),
  );
  await assertFails(
    asAnonymous('seller1')
      .doc('vehicle_listings/v2')
      .set(validVehicleListing()),
  );
  await assertFails(
    asClient('seller1')
      .doc('vehicle_listings/v3')
      .set(validVehicleListing('seller2')),
  );
});

test('vehicle_listings: propriétaire modifie et archive, tiers et changement de propriétaire refusés', async () => {
  await seed((db) => db.doc('vehicle_listings/v1').set(
    validVehicleListing('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
      status: 'active',
    }),
  ));
  const ownerRef = asClient('seller1').doc('vehicle_listings/v1');
  await assertSucceeds(ownerRef.update({
    title: 'Toyota Corolla révisée',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(asClient('seller2').doc('vehicle_listings/v1').update({
    title: 'Annonce détournée',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ownerRef.update({
    sellerId: 'seller2',
    updatedAt: serverTimestamp(),
  }));
  await assertSucceeds(ownerRef.update({
    status: 'archived',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ownerRef.delete());
});

test('vehicle_listings: enum, prix et champs critiques invalides sont refusés', async () => {
  const ref = asClient('seller1').doc('vehicle_listings/v1');
  await assertFails(ref.set(validVehicleListing('seller1', {
    vehicleType: 'boat',
  })));
  await assertFails(ref.set(validVehicleListing('seller1', { price: -1 })));
  await assertFails(ref.set(validVehicleListing('seller1', {
    cityId: 'Agnibilékrou',
  })));
  await assertFails(ref.set(validVehicleListing('seller1', {
    verified: true,
  })));
  await assertFails(ref.set(validVehicleListing('seller1', {
    status: 'sold',
  })));
  await assertFails(ref.set(validVehicleListing('seller1', {
    salePrice: -1,
    price: -1,
  })));
  await assertFails(ref.set(validVehicleListing('seller1', {
    rentalPricePerDay: 15000,
  })));
});

test('vehicle_listings: location cohérente autorisée et options invalides refusées', async () => {
  const validRental = validVehicleListing('seller1', {
    offerType: 'rental',
    price: 15000,
    salePrice: undefined,
    rentalPricePerDay: 15000,
    rentalWithDriver: false,
    rentalWithoutDriver: true,
  });
  delete validRental.salePrice;
  await assertSucceeds(
    asClient('seller1').doc('vehicle_listings/rental-ok').set(validRental),
  );

  await assertFails(
    asClient('seller1').doc('vehicle_listings/rental-no-option').set({
      ...validRental,
      rentalWithoutDriver: false,
    }),
  );
});

test('vehicle_listings: références médias bornées autorisées, liste excessive refusée', async () => {
  const media = {
    id: 'photo1',
    type: 'image',
    storagePath: 'vehicle_listings/seller1/media-ok/images/photo1.jpg',
    downloadUrl: 'https://example.test/photo1',
    position: 0,
  };
  await assertSucceeds(
    asClient('seller1').doc('vehicle_listings/media-ok').set(
      validVehicleListing('seller1', {
        media: [media],
        coverMediaId: 'photo1',
      }),
    ),
  );
  await assertFails(
    asClient('seller1').doc('vehicle_listings/media-too-many').set(
      validVehicleListing('seller1', {
        media: Array.from({ length: 10 }, (_, index) => ({
          ...media,
          id: `photo${index}`,
          position: index,
        })),
        coverMediaId: 'photo0',
      }),
    ),
  );
});

test('vehicle_listings: createdAt et champs conditionnels restent protégés', async () => {
  await seed((db) => db.doc('vehicle_listings/v-conditional').set(
    validVehicleListing('seller1', {
      status: 'active',
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
    }),
  ));
  const ref = asClient('seller1').doc('vehicle_listings/v-conditional');
  await assertFails(ref.update({
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.update({
    mileageKm: deleteField(),
    updatedAt: serverTimestamp(),
  }));
});

test('vehicle_listings: le super-admin modifie et supprime sans changer sellerId', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('vehicle_listings/v1').set(validVehicleListing('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
      status: 'active',
    }));
  });
  const ref = asAdmin('admin1').doc('vehicle_listings/v1');
  await assertSucceeds(ref.update({
    status: 'archived',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.update({
    sellerId: 'admin1',
    updatedAt: serverTimestamp(),
  }));
  await assertSucceeds(ref.delete());
});

function validVehicleSellerProfile(ownerId = 'seller1', overrides = {}) {
  return {
    ownerId,
    sellerType: 'individual',
    displayName: 'Aya Koné',
    phone: '0700000000',
    cityId: 'abengourou',
    verificationStatus: 'unverified',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

function validProfessionalProfile(ownerId = 'seller1', overrides = {}) {
  return validVehicleSellerProfile(ownerId, {
    sellerType: 'professional',
    shopName: 'AZ Motors',
    businessType: 'dealership',
    professionalPhone: '0100000000',
    address: 'Quartier Commerce',
    locationVisibility: 'approximate',
    ...overrides,
  });
}

function validVehiclePrivateLocation(ownerId = 'seller1', overrides = {}) {
  return {
    ownerId,
    latitude: 6.7297,
    longitude: -3.4964,
    cityId: 'abengourou',
    addressLabel: 'Près du marché',
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

function validVehicleConversation(buyerId = 'buyer1', overrides = {}) {
  return {
    listingId: 'v-chat',
    buyerId,
    sellerId: 'seller1',
    participantIds: [buyerId, 'seller1'],
    listingTitle: 'Toyota Corolla',
    listingPrice: 6500000,
    currency: 'XOF',
    sellerDisplayName: 'Aya Koné',
    sellerType: 'individual',
    sellerVerificationStatus: 'unverified',
    lastMessagePreview: '',
    lastSenderId: null,
    buyerUnreadCount: 0,
    sellerUnreadCount: 0,
    status: 'active',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    lastMessageAt: serverTimestamp(),
    ...overrides,
  };
}

async function seedVehicleChatBase() {
  await seed(async (db) => {
    await db.doc('vehicle_seller_profiles/seller1').set(
      validVehicleSellerProfile('seller1', {
        createdAt: new Date(),
        updatedAt: new Date(),
      }),
    );
    await db.doc('vehicle_listings/v-chat').set(
      validVehicleListing('seller1', {
        title: 'Toyota Corolla',
        price: 6500000,
        status: 'active',
        createdAt: new Date(),
        updatedAt: new Date(),
      }),
    );
  });
}

test('vehicle_conversations: acheteur crée une conversation valide et déterministe', async () => {
  await seedVehicleChatBase();
  await assertSucceeds(
    asClient('buyer1')
      .doc('vehicle_conversations/vc_v-chat_buyer1')
      .set(validVehicleConversation()),
  );
});

test('vehicle_conversations: vendeur lui-même, faux buyer/seller et annonce archivée refusés', async () => {
  await seedVehicleChatBase();
  await assertFails(
    asClient('seller1')
      .doc('vehicle_conversations/vc_v-chat_seller1')
      .set(validVehicleConversation('seller1', {
        buyerId: 'seller1',
        participantIds: ['seller1', 'seller1'],
      })),
  );
  await assertFails(
    asClient('buyer1')
      .doc('vehicle_conversations/vc_v-chat_other')
      .set(validVehicleConversation('other')),
  );
  await assertFails(
    asClient('buyer1')
      .doc('vehicle_conversations/vc_v-chat_buyer1')
      .set(validVehicleConversation('buyer1', { sellerId: 'intruder' })),
  );
  await seed((db) => db.doc('vehicle_listings/v-chat').update({ status: 'archived' }));
  await assertFails(
    asClient('buyer1')
      .doc('vehicle_conversations/vc_v-chat_buyer1')
      .set(validVehicleConversation()),
  );
});

test('vehicle_conversations: non authentifié refusé', async () => {
  await seedVehicleChatBase();
  const path = 'vehicle_conversations/vc_v-chat_buyer1';
  await assertFails(unauth().doc(path).set(validVehicleConversation()));
});

test('vehicle_conversations: participants lisent, tiers refusé', async () => {
  await seed((db) => db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
    validVehicleConversation('buyer1', {
      createdAt: new Date(), updatedAt: new Date(), lastMessageAt: new Date(),
    }),
  ));
  const path = 'vehicle_conversations/vc_v-chat_buyer1';
  await assertSucceeds(asClient('buyer1').doc(path).get());
  await assertSucceeds(asClient('seller1').doc(path).get());
  await assertFails(asClient('other').doc(path).get());
});

test('vehicle_conversations: identités et participants sont immuables', async () => {
  await seed((db) => db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
    validVehicleConversation('buyer1', {
      createdAt: new Date(), updatedAt: new Date(), lastMessageAt: new Date(),
    }),
  ));
  const ref = asClient('buyer1').doc('vehicle_conversations/vc_v-chat_buyer1');
  await assertFails(ref.update({ listingId: 'other', updatedAt: serverTimestamp() }));
  await assertFails(ref.update({ participantIds: ['buyer1', 'other'], updatedAt: serverTimestamp() }));
});

test('vehicle_conversations: incrément unread opposé et reset personnel autorisés', async () => {
  await seed((db) => db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
    validVehicleConversation('buyer1', {
      createdAt: new Date(), updatedAt: new Date(), lastMessageAt: new Date(),
    }),
  ));
  const buyer = asClient('buyer1').doc('vehicle_conversations/vc_v-chat_buyer1');
  await assertSucceeds(buyer.update({
    lastMessagePreview: 'Bonjour', lastSenderId: 'buyer1',
    sellerUnreadCount: 1, lastMessageAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  }));
  await assertFails(buyer.update({
    buyerUnreadCount: 4, updatedAt: serverTimestamp(),
  }));
  const seller = asClient('seller1').doc('vehicle_conversations/vc_v-chat_buyer1');
  await assertSucceeds(seller.update({
    sellerUnreadCount: 0, updatedAt: serverTimestamp(),
  }));
});

test('vehicle messages: participants envoient/lisent, tiers et sender falsifié refusés', async () => {
  await seed((db) => db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
    validVehicleConversation('buyer1', {
      createdAt: new Date(), updatedAt: new Date(), lastMessageAt: new Date(),
    }),
  ));
  const path = 'vehicle_conversations/vc_v-chat_buyer1/messages/m1';
  await assertSucceeds(asClient('buyer1').doc(path).set({
    senderId: 'buyer1', text: 'Bonjour', type: 'text',
    createdAt: serverTimestamp(),
  }));
  await assertSucceeds(asClient('seller1').doc(path).get());
  await assertFails(asClient('other').doc(path).get());
  await assertFails(asClient('buyer1').doc(
    'vehicle_conversations/vc_v-chat_buyer1/messages/m2',
  ).set({ senderId: 'seller1', text: 'Faux', type: 'text', createdAt: serverTimestamp() }));
});

test('vehicle messages: vide, espaces, trop long et mauvais type refusés', async () => {
  await seed((db) => db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
    validVehicleConversation('buyer1', {
      createdAt: new Date(), updatedAt: new Date(), lastMessageAt: new Date(),
    }),
  ));
  const messages = asClient('buyer1')
    .collection('vehicle_conversations/vc_v-chat_buyer1/messages');
  for (const [text, type] of [['', 'text'], ['   ', 'text'], ['x'.repeat(1001), 'text'], ['ok', 'audio']]) {
    await assertFails(messages.add({
      senderId: 'buyer1', text, type, createdAt: serverTimestamp(),
    }));
  }
});

test('vehicle_favorites: ajout, lecture et suppression réservés au propriétaire', async () => {
  await seed((db) => db.doc('vehicle_listings/v-favorite').set(
    validVehicleListing('seller1', {
      status: 'active',
      createdAt: new Date(),
      updatedAt: new Date(),
    }),
  ));
  const data = {
    userId: 'buyer1',
    listingId: 'v-favorite',
    listingSnapshot: { title: 'Toyota Corolla', sellerId: 'seller1' },
    createdAt: serverTimestamp(),
  };
  const path = 'vehicle_favorites/buyer1/items/v-favorite';
  const owner = asClient('buyer1').doc(path);
  await assertSucceeds(owner.set(data));
  await assertSucceeds(owner.get());
  await assertFails(asClient('other').doc(path).get());
  await assertFails(asClient('other').doc(path).delete());
  await assertSucceeds(owner.delete());
});

test('vehicle_favorites: non authentifié, UID usurpé et annonce inactive refusés', async () => {
  await seed(async (db) => {
    await db.doc('vehicle_listings/active').set(validVehicleListing('seller1', {
      status: 'active', createdAt: new Date(), updatedAt: new Date(),
    }));
    await db.doc('vehicle_listings/archived').set(validVehicleListing('seller1', {
      status: 'archived', createdAt: new Date(), updatedAt: new Date(),
    }));
  });
  const favorite = (userId, listingId) => ({
    userId,
    listingId,
    listingSnapshot: { title: 'Annonce' },
    createdAt: serverTimestamp(),
  });
  await assertFails(unauth().doc('vehicle_favorites/buyer1/items/active')
    .set(favorite('buyer1', 'active')));
  await assertFails(asClient('other').doc('vehicle_favorites/buyer1/items/active')
    .set(favorite('buyer1', 'active')));
  await assertFails(asClient('buyer1').doc('vehicle_favorites/buyer1/items/active')
    .set(favorite('other', 'active')));
  await assertFails(asClient('buyer1').doc('vehicle_favorites/buyer1/items/archived')
    .set(favorite('buyer1', 'archived')));
});

test('vehicle_reports: annonce/vendeur valides, doublon et usurpation refusés', async () => {
  await seed(async (db) => {
    await db.doc('vehicle_seller_profiles/seller1').set(
      validVehicleSellerProfile('seller1'),
    );
    await db.doc('vehicle_listings/v-report').set(validVehicleListing('seller1', {
      status: 'active', createdAt: new Date(), updatedAt: new Date(),
    }));
  });
  const listing = asClient('buyer1').doc('vehicle_reports/listing_v-report_buyer1');
  await assertSucceeds(listing.set({
    targetType: 'listing', targetId: 'v-report', sellerId: 'seller1',
    reporterUid: 'buyer1', reason: 'Prix trompeur', status: 'pending',
    createdAt: serverTimestamp(),
  }));
  await assertFails(listing.set({
    targetType: 'listing', targetId: 'v-report', sellerId: 'seller1',
    reporterUid: 'buyer1', reason: 'Doublon', status: 'pending',
    createdAt: serverTimestamp(),
  }));
  await assertSucceeds(asClient('buyer1')
    .doc('vehicle_reports/seller_seller1_buyer1').set({
      targetType: 'seller', targetId: 'seller1', sellerId: 'seller1',
      reporterUid: 'buyer1', reason: 'Spam', status: 'pending',
      createdAt: serverTimestamp(),
    }));
  await assertFails(asClient('buyer1')
    .doc('vehicle_reports/listing_v-report_other').set({
      targetType: 'listing', targetId: 'v-report', sellerId: 'seller1',
      reporterUid: 'other', reason: 'Spam', status: 'pending',
      createdAt: serverTimestamp(),
    }));
  await assertFails(unauth().doc('vehicle_reports/listing_v-report_u').set({}));
});

test('vehicle_user_blocks: propriétaire bloque/débloque, tiers et auto-blocage refusés', async () => {
  const ref = asClient('buyer1')
    .doc('vehicle_user_blocks/buyer1/blocked/seller1');
  await assertSucceeds(ref.set({
    ownerUid: 'buyer1', blockedUid: 'seller1', createdAt: serverTimestamp(),
  }));
  await assertSucceeds(ref.get());
  await assertFails(asClient('other')
    .doc('vehicle_user_blocks/buyer1/blocked/seller1').get());
  await assertFails(asClient('buyer1')
    .doc('vehicle_user_blocks/buyer1/blocked/buyer1').set({
      ownerUid: 'buyer1', blockedUid: 'buyer1', createdAt: serverTimestamp(),
    }));
  await assertSucceeds(ref.delete());
});

test('vehicle_conversations: blocage bilatéral refuse création et nouveaux messages, historique reste lisible', async () => {
  await seed(async (db) => {
    await db.doc('vehicle_seller_profiles/seller1').set(
      validVehicleSellerProfile('seller1'),
    );
    await db.doc('vehicle_listings/v-chat').set(validVehicleListing('seller1', {
      status: 'active', createdAt: new Date(), updatedAt: new Date(),
    }));
    await db.doc('vehicle_conversations/vc_v-chat_buyer1').set(
      validVehicleConversation(),
    );
    await db.doc('vehicle_conversations/vc_v-chat_buyer1/messages/old').set({
      senderId: 'buyer1', text: 'Historique', type: 'text', createdAt: new Date(),
    });
    await db.doc('vehicle_user_blocks/seller1/blocked/buyer1').set({
      ownerUid: 'seller1', blockedUid: 'buyer1', createdAt: new Date(),
    });
  });
  await assertSucceeds(asClient('buyer1')
    .doc('vehicle_conversations/vc_v-chat_buyer1/messages/old').get());
  await assertFails(asClient('buyer1')
    .doc('vehicle_conversations/vc_v-chat_buyer1/messages/new').set({
      senderId: 'buyer1', text: 'Nouveau', type: 'text',
      createdAt: serverTimestamp(),
    }));
});

test('vehicle moderation: vendeur ne lève pas suspension et ne s’auto-vérifie pas', async () => {
  await seed(async (db) => {
    await db.doc('vehicle_seller_profiles/seller1').set(
      validVehicleSellerProfile('seller1', {
        suspended: true, suspensionReason: 'Fraude', suspendedAt: new Date(),
      }),
    );
    await db.doc('vehicle_seller_suspensions/seller1').set({
      sellerId: 'seller1', createdAt: new Date(),
    });
    await db.doc('vehicle_listings/v-suspended').set(validVehicleListing('seller1', {
      status: 'suspended', suspensionReason: 'Fraude', suspendedAt: new Date(),
      createdAt: new Date(), updatedAt: new Date(),
    }));
  });
  await assertFails(asClient('seller1').doc('vehicle_listings/v-suspended')
    .update({ status: 'active', updatedAt: serverTimestamp() }));
  await assertFails(asClient('seller1').doc('vehicle_seller_profiles/seller1')
    .update({ suspended: false, verificationStatus: 'verified', updatedAt: serverTimestamp() }));
  await assertFails(asClient('seller1').doc('vehicle_listings/new')
    .set(validVehicleListing('seller1')));
});

test('vehicle_seller_profiles: création individual et professional valide autorisée', async () => {
  await assertSucceeds(
    asClient('seller1')
      .doc('vehicle_seller_profiles/seller1')
      .set(validVehicleSellerProfile()),
  );
  await assertSucceeds(
    asClient('seller2')
      .doc('vehicle_seller_profiles/seller2')
      .set(validProfessionalProfile('seller2')),
  );
});

test('vehicle_seller_profiles: écriture non authentifiée, mauvais UID et ownerId falsifié refusés', async () => {
  await assertFails(
    unauth()
      .doc('vehicle_seller_profiles/seller1')
      .set(validVehicleSellerProfile()),
  );
  await assertFails(
    asClient('seller1')
      .doc('vehicle_seller_profiles/seller2')
      .set(validVehicleSellerProfile('seller1')),
  );
  await assertFails(
    asClient('seller1')
      .doc('vehicle_seller_profiles/seller1')
      .set(validVehicleSellerProfile('seller2')),
  );
});

test('vehicle_seller_profiles: propriétaire modifie ses champs publics, tiers refusé', async () => {
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validVehicleSellerProfile('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
    }),
  ));
  await assertSucceeds(
    asClient('seller1').doc('vehicle_seller_profiles/seller1').update({
      displayName: 'Aya K. Koné',
      updatedAt: serverTimestamp(),
    }),
  );
  await assertFails(
    asClient('seller2').doc('vehicle_seller_profiles/seller1').update({
      displayName: 'Profil détourné',
      updatedAt: serverTimestamp(),
    }),
  );
});

test('vehicle_seller_profiles: token FCM limité au propriétaire et à ce seul champ', async () => {
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validVehicleSellerProfile('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
    }),
  ));
  const owner = asClient('seller1')
    .doc('vehicle_seller_profiles/seller1');
  await assertSucceeds(owner.update({ fcmToken: 'seller-token-12345' }));
  await assertFails(
    asClient('seller2').doc('vehicle_seller_profiles/seller1')
      .update({ fcmToken: 'stolen-token-12345' }),
  );
  await assertFails(owner.update({ fcmToken: 'court' }));
  await assertFails(owner.update({
    fcmToken: 'seller-token-67890',
    displayName: 'Modification couplée interdite',
  }));
});

test('vehicle_seller_profiles: auto-vérification et champs Admin interdits', async () => {
  await assertFails(
    asClient('seller1')
      .doc('vehicle_seller_profiles/seller1')
      .set(validProfessionalProfile('seller1', {
        verificationStatus: 'verified',
      })),
  );
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validProfessionalProfile('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
    }),
  ));
  const ref = asClient('seller1').doc('vehicle_seller_profiles/seller1');
  await assertFails(ref.update({
    verificationStatus: 'verified',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.update({
    isSuspended: false,
    updatedAt: serverTimestamp(),
  }));
});

test('vehicle_seller_profiles: type vendeur immuable et chemin logo propriétaire uniquement', async () => {
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validVehicleSellerProfile('seller1', {
      createdAt: new Date('2026-09-01T00:00:00Z'),
      updatedAt: new Date('2026-09-01T00:00:00Z'),
    }),
  ));
  const ref = asClient('seller1').doc('vehicle_seller_profiles/seller1');
  await assertFails(ref.update({
    sellerType: 'professional',
    shopName: 'AZ Motors',
    businessType: 'dealership',
    professionalPhone: '0100000000',
    address: 'Quartier Commerce',
    locationVisibility: 'hidden',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.update({
    logoStoragePath: 'vehicle_seller_profiles/seller2/logo/logo.jpg',
    updatedAt: serverTimestamp(),
  }));
});

test('vehicle_seller_profiles: super-admin peut modérer sans changer ownerId', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('vehicle_seller_profiles/seller1').set(
      validProfessionalProfile('seller1', {
        createdAt: new Date('2026-09-01T00:00:00Z'),
        updatedAt: new Date('2026-09-01T00:00:00Z'),
      }),
    );
  });
  const ref = asAdmin('admin1').doc('vehicle_seller_profiles/seller1');
  await assertSucceeds(ref.update({
    verificationStatus: 'verified',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.update({
    ownerId: 'admin1',
    updatedAt: serverTimestamp(),
  }));
});

test('vehicle_seller_private_locations: propriétaire professionnel écrit et lit', async () => {
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validProfessionalProfile('seller1', {
      createdAt: new Date(),
      updatedAt: new Date(),
    }),
  ));
  const ref = asClient('seller1')
    .doc('vehicle_seller_private_locations/seller1');
  await assertSucceeds(ref.set(validVehiclePrivateLocation()));
  await assertSucceeds(ref.get());
});

test('vehicle_seller_private_locations: lecture et écriture cross-user refusées', async () => {
  await seed(async (db) => {
    await db.doc('vehicle_seller_profiles/seller1').set(
      validProfessionalProfile('seller1', {
        createdAt: new Date(),
        updatedAt: new Date(),
      }),
    );
    await db.doc('vehicle_seller_profiles/seller2').set(
      validProfessionalProfile('seller2', {
        createdAt: new Date(),
        updatedAt: new Date(),
      }),
    );
    await db.doc('vehicle_seller_private_locations/seller1').set(
      validVehiclePrivateLocation('seller1', { updatedAt: new Date() }),
    );
  });
  const otherRef = asClient('seller2')
    .doc('vehicle_seller_private_locations/seller1');
  await assertFails(otherRef.get());
  await assertFails(otherRef.set(validVehiclePrivateLocation('seller2')));
});

test('vehicle_seller_private_locations: un particulier ne peut pas enregistrer de coordonnées', async () => {
  await seed((db) => db.doc('vehicle_seller_profiles/seller1').set(
    validVehicleSellerProfile('seller1', {
      createdAt: new Date(),
      updatedAt: new Date(),
    }),
  ));
  await assertFails(
    asClient('seller1')
      .doc('vehicle_seller_private_locations/seller1')
      .set(validVehiclePrivateLocation()),
  );
});

test('vehicle_seller_private_locations: super-admin lit, utilisateur non authentifié refusé', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('vehicle_seller_private_locations/seller1').set(
      validVehiclePrivateLocation('seller1', { updatedAt: new Date() }),
    );
  });
  const path = 'vehicle_seller_private_locations/seller1';
  await assertSucceeds(asAdmin('admin1').doc(path).get());
  await assertFails(unauth().doc(path).get());
});

// ═══════════════════════════════════════════════════════════════════════════
// LOT 6 SECURITY (2026-09) — régression pour les 4 failles auditées :
// 1) livreur modifiant shoppingBudget/sellerId d'une commande assignée
// 2) un seul débit wallet validant plusieurs commandes
// 3) PIN artisan lisible par tout utilisateur authentifié
// 4) livreur modifiant isSuspended sur son propre document
// ═══════════════════════════════════════════════════════════════════════════

// ── 1) orders : sellerId / shoppingBudget non modifiables par le livreur ──

test('LOT 6 : un livreur assigné NE PEUT PAS réécrire sellerId pendant une transition de statut légitime (détournement du bénéficiaire du paiement)', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', sellerId: 's_legit', sellerType: 'restaurant',
    budget: 2000, shoppingBudget: 0, isPaid: true, paymentMethod: 'wallet',
    status: 'accepted',
  }));
  await assertFails(asClient('d1').doc('orders/o1').update({
    status: 'picked_up', sellerId: 's_attacker',
  }));
});

test('LOT 6 : un livreur assigné NE PEUT PAS réécrire shoppingBudget pendant une transition de statut légitime', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', budget: 1000, shoppingBudget: 0,
    isPaid: true, paymentMethod: 'wallet', status: 'accepted',
  }));
  await assertFails(asClient('d1').doc('orders/o1').update({
    status: 'picked_up', shoppingBudget: 50000,
  }));
});

test('LOT 6 : un livreur assigné NE PEUT PAS réécrire pharmacieId (route le crédit médicaments)', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', pharmacieId: 'ph_legit', budget: 500,
    isPaid: false, paymentMethod: 'wallet', status: 'accepted',
  }));
  await assertFails(asClient('d1').doc('orders/o1').update({
    status: 'picked_up', pharmacieId: 'ph_attacker',
  }));
});

test('LOT 6 (contrôle) : un livreur assigné peut toujours faire avancer le statut sans toucher aux champs financiers/bénéficiaire', async () => {
  await seed((db) => db.doc('orders/o1').set({
    clientId: 'c1', driverId: 'd1', sellerId: 's1', sellerType: 'restaurant',
    budget: 2000, shoppingBudget: 0, isPaid: true, paymentMethod: 'wallet',
    status: 'accepted',
  }));
  await assertSucceeds(asClient('d1').doc('orders/o1').update({ status: 'picked_up' }));
});

// ── 2) orders : un débit wallet ne peut plus valider plusieurs commandes ──

test('LOT 6 : un unique débit wallet ne peut PAS valider deux commandes dans la même transaction client (réutilisation de débit)', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  // Un seul débit de 500 FCFA — mais DEUX commandes à 500 FCFA chacune
  // tentent de s'appuyer sur ce même débit (ancien contournement : chaque
  // commande vérifiait indépendamment "solde après == solde avant - SON
  // montant", satisfiable simultanément par les deux si leurs montants sont
  // identiques au débit réel).
  batch.update(clientDb.doc('clients/c1'), { wallet: 500, lastPaidOrderId: 'o1' });
  batch.set(clientDb.doc('orders/o1'), {
    clientId: 'c1', budget: 500, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  batch.set(clientDb.doc('orders/o2'), {
    clientId: 'c1', budget: 500, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertFails(batch.commit());
});

test('LOT 6 : un débit wallet sans lastPaidOrderId correspondant est refusé (repli sans le marqueur)', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500 }); // pas de lastPaidOrderId
  batch.set(clientDb.doc('orders/o1'), {
    clientId: 'c1', budget: 500, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertFails(batch.commit());
});

test('LOT 6 (contrôle) : un paiement wallet légitime (un débit, une commande, lastPaidOrderId correspondant) reste autorisé', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500, lastPaidOrderId: 'o1' });
  batch.set(clientDb.doc('orders/o1'), {
    clientId: 'c1', budget: 500, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertSucceeds(batch.commit());
});

// ── 3) artisan_credentials : PIN jamais lisible côté client, quel que soit le rôle ──

test('LOT 6 : artisan_credentials est totalement verrouillé (lecture) — client, artisan lié et admin tous refusés', async () => {
  await seed(async (db) => {
    await db.doc('artisan_credentials/p1').set({ hash: 'salt:hash', updatedAt: new Date() });
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
  });
  await assertFails(asClient('someone').doc('artisan_credentials/p1').get());
  await assertFails(asClient('p1').doc('artisan_credentials/p1').get());
  await assertFails(asAdmin('admin1').doc('artisan_credentials/p1').get());
  await assertFails(unauth().doc('artisan_credentials/p1').get());
});

test('LOT 6 : artisan_credentials est totalement verrouillé (écriture) — même un admin ne peut pas écrire directement (CF-only, Admin SDK uniquement)', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertFails(asAdmin('admin1').doc('artisan_credentials/p1').set({ hash: 'x' }));
  await assertFails(asClient('p1').doc('artisan_credentials/p1').set({ hash: 'x' }));
});

test('LOT 6 (contrôle) : service_providers reste lisible pour l\'annuaire public (nom/téléphone/photos), fonctionnement légitime inchangé', async () => {
  await seed((db) => db.doc('service_providers/p1').set({
    name: 'Kouassi Plomberie', phone: '0700000000', subcategory: 'plombier',
    photos: [], status: 'approved', isAvailable: true,
  }));
  await assertSucceeds(asClient('anyone').doc('service_providers/p1').get());
});

// Note : la liaison artisanUid à la première connexion et le renouvellement
// du PIN passent tous deux par artisanLogin/setArtisanPin (Cloud Functions,
// Admin SDK — bypass des règles Firestore par construction), pas par une
// écriture directe côté client sur ce document — non testable au niveau des
// règles seules, cohérent avec l'architecture déjà documentée dans
// firestore.rules (le login artisan reste explicitement anonyme).

// ── 4) livreurs : isSuspended non modifiable par le livreur lui-même ──

test('LOT 6 : un livreur ne peut PAS s\'auto-réactiver (isSuspended: false) après suspension', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: false, isSuspended: true }));
  await assertFails(asClient('d1').doc('livreurs/d1').update({ isSuspended: false }));
});

test('LOT 6 : un livreur ne peut PAS non plus s\'auto-suspendre ou toucher isSuspended dans un sens ou l\'autre', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, isSuspended: false }));
  await assertFails(asClient('d1').doc('livreurs/d1').update({ isSuspended: true }));
});

test('LOT 6 : isSuspended reste protégé même quand le livreur diminue légitimement son propre wallet (branche acceptation de commande)', async () => {
  await seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, isSuspended: true }));
  await assertFails(asClient('d1').doc('livreurs/d1').update({ wallet: 400, isSuspended: false }));
});

test('LOT 6 (contrôle) : un admin peut toujours suspendre/réactiver un livreur', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, isSuspended: false });
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
  });
  await assertSucceeds(asAdmin('admin1').doc('livreurs/d1').update({ isSuspended: true }));
});

test('LOT 6 (contrôle) : un livreur peut toujours mettre à jour sa position/isOnline sans toucher isSuspended (fonctionnement légitime inchangé)', async () => {
  await seed((db) => db.doc('livreurs/d1').set({
    wallet: 500, isOnline: true, isSuspended: false, lat: 6.7, lng: -3.4,
  }));
  await assertSucceeds(
    asClient('d1').doc('livreurs/d1').update({ lat: 6.71, lng: -3.41, isOnline: false }),
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// LOT 6.1 SECURITY (2026-09, suite) — event_reservations (même faille que
// orders, trouvée en cartographiant tous les producteurs wallet), robustesse
// de wallet_transactions falsifiées, et compatibilité "ancien" client wallet.
// ═══════════════════════════════════════════════════════════════════════════

// ── event_reservations : même correctif que orders (lastPaidReservationId) ──

test('LOT 6.1 : un unique débit wallet ne peut PAS valider deux réservations événementielles (même faille que orders)', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500, lastPaidReservationId: 'r1' });
  batch.set(clientDb.doc('event_reservations/r1'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 500,
    paymentMethod: 'wallet', isPaid: true,
  });
  batch.set(clientDb.doc('event_reservations/r2'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 500,
    paymentMethod: 'wallet', isPaid: true,
  });
  await assertFails(batch.commit());
});

test('LOT 6.1 : une réservation événementielle payée par wallet sans lastPaidReservationId est refusée', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500 }); // pas de lastPaidReservationId
  batch.set(clientDb.doc('event_reservations/r1'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 500,
    paymentMethod: 'wallet', isPaid: true,
  });
  await assertFails(batch.commit());
});

// LOT 6.3 : superseded — voir le test "la création directe côté client est
// TOUJOURS refusée" plus haut. Ce qui était "légitime" en LOT 6.1 (débit
// exact + marqueur correspondant) est désormais refusé lui aussi : seule
// createEventReservationCF crée ce document. Conservé comme test explicite
// pour ne jamais laisser une future régression rouvrir ce chemin par erreur.
test('LOT 6.3 : même le motif exact validé au LOT 6.1 (débit + lastPaidReservationId corrects) est désormais refusé côté client — CF-only', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500, lastPaidReservationId: 'r1' });
  batch.set(clientDb.doc('event_reservations/r1'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 500,
    paymentMethod: 'wallet', isPaid: true,
  });
  await assertFails(batch.commit());
});

test('LOT 6.1 (contrôle) : un ID de commande (lastPaidOrderId) ne peut PAS valider une réservation, ni l\'inverse (champs distincts, aucune confusion inter-collections)', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  // Le client débite pour une COMMANDE (o1) mais tente de faire passer une
  // RÉSERVATION (r1) du même montant sur ce même débit.
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/c1'), { wallet: 500, lastPaidOrderId: 'o1' });
  batch.set(clientDb.doc('event_reservations/r1'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 500,
    paymentMethod: 'wallet', isPaid: true,
  });
  await assertFails(batch.commit());
});

// ── wallet_transactions : falsification sans impact sur le solde réel ──────

test('LOT 6.1 : une écriture wallet_transactions falsifiée (montant fantaisiste) n\'affecte jamais le solde réel du client — champs distincts, règles distinctes', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 100, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  // Le client PEUT écrire une entrée d'historique fantaisiste sur son propre
  // journal (déjà accepté comme risque cosmétique — voir CLAUDE.md, aucun
  // consommateur ne s'appuie dessus pour créditer/rembourser) ...
  await assertSucceeds(clientDb.doc('clients/c1/wallet_transactions/fake1').set({
    type: 'earning', amount: 999999999, description: 'faux gain', createdAt: new Date(),
  }));
  // ... mais ne peut PAS s'en servir pour augmenter son propre solde réel :
  // la règle `clients.wallet` reste indépendante de `wallet_transactions`.
  await assertFails(clientDb.doc('clients/c1').update({ wallet: 999999999 }));
});

test('LOT 6.1 : livreurs/wallet_transactions est aussi append-only (aucune mise à jour, même par le propriétaire)', async () => {
  await seed((db) => db.doc('livreurs/d1/wallet_transactions/tx1').set({
    type: 'earning', amount: 200, createdAt: new Date(),
  }));
  await assertFails(asClient('d1').doc('livreurs/d1/wallet_transactions/tx1').update({ amount: 99999 }));
});

test('LOT 6.1 : sellers/wallet_transactions est aussi append-only (aucune mise à jour, même par le propriétaire)', async () => {
  await seed((db) => db.doc('sellers/s1/wallet_transactions/tx1').set({
    type: 'sale', amount: 200, createdAt: new Date(),
  }));
  await assertFails(asClient('s1').doc('sellers/s1/wallet_transactions/tx1').update({ amount: 99999 }));
});

test('LOT 6.1 : wallet_transactions (top-level) est append-only — falsifier une transaction déjà écrite est refusé', async () => {
  await seed((db) => db.doc('wallet_transactions/tx1').set({
    uid: 'u1', type: 'ekbine_payment', amount: -500, createdAt: new Date(),
  }));
  await assertFails(asClient('u1').doc('wallet_transactions/tx1').update({ amount: -1 }));
});

test('LOT 6.1 : wallet_transactions (top-level) — un client ne peut PAS créer une entrée au nom d\'un autre utilisateur', async () => {
  await assertFails(asClient('u1').doc('wallet_transactions/tx1').set({
    uid: 'u2', type: 'ekbine_payment', amount: -500, createdAt: new Date(),
  }));
});

test('LOT 6.1 : wallet_transactions (top-level) — même une entrée auto-attribuée ne permet aucune lecture par un tiers', async () => {
  await seed((db) => db.doc('wallet_transactions/tx1').set({
    uid: 'u1', type: 'ekbine_payment', amount: -500, createdAt: new Date(),
  }));
  await assertFails(asClient('u2').doc('wallet_transactions/tx1').get());
});

// ── Compatibilité "ancien" vs "nouveau" client wallet ──────────────────────

test('LOT 6.1 : un compte client "ancien" (créé avant ce correctif, sans jamais avoir eu de champ lastPaidOrderId) peut toujours payer par wallet aujourd\'hui', async () => {
  // Simule un document clients/{uid} pré-existant, créé bien avant l'ajout
  // de lastPaidOrderId — aucun champ de ce type n'a jamais existé dessus.
  await seed((db) => db.doc('clients/legacy1').set({
    wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
    createdAt: new Date('2026-01-01'),
  }));
  const clientDb = asClient('legacy1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/legacy1'), { wallet: 1000, lastPaidOrderId: 'o1' });
  batch.set(clientDb.doc('orders/o1'), {
    clientId: 'legacy1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertSucceeds(batch.commit());
});

test('LOT 6.1 : un compte client "nouveau" (créé via la règle create actuelle) paie par wallet dès sa première commande', async () => {
  await assertSucceeds(asClient('new1').doc('clients/new1').set({
    name: 'Nouveau', phone: '0700000000', wallet: 0,
    cashOnDeliveryEnabled: true, fakeOrderCount: 0, createdAt: new Date(),
  }));
  await seed((db) => db.doc('clients/new1').update({ wallet: 2000 }));
  const clientDb = asClient('new1');
  const batch = clientDb.batch();
  batch.update(clientDb.doc('clients/new1'), { wallet: 1000, lastPaidOrderId: 'o1' });
  batch.set(clientDb.doc('orders/o1'), {
    clientId: 'new1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertSucceeds(batch.commit());
});

// ── artisan_credentials : lecture verrouillée aussi après une migration simulée ──

test('LOT 6.1 : un compte artisan "migré" (artisanPin absent, hash présent dans artisan_credentials) — le PIN historique reste illisible pour tout client', async () => {
  await seed(async (db) => {
    await db.doc('service_providers/p1').set({
      name: 'Kouassi Plomberie', phone: '0700000000', status: 'approved',
      // Pas de champ artisanPin — comme après une migration réussie.
    });
    await db.doc('artisan_credentials/p1').set({ hash: 'salt:hash', updatedAt: new Date() });
  });
  // L'annuaire public reste lisible (fonctionnement légitime inchangé) ...
  await assertSucceeds(asClient('anyone').doc('service_providers/p1').get());
  // ... mais le hash migré reste totalement hors de portée d'un client,
  // exactement comme avant la migration (voir section LOT 6 plus haut).
  await assertFails(asClient('anyone').doc('artisan_credentials/p1').get());
  await assertFails(asClient('p1').doc('artisan_credentials/p1').get());
});

// ═══════════════════════════════════════════════════════════════════════════
// LOT 6.2 — revue finale : concurrence réelle (pas seulement un même batch),
// plancher anti-"paiement gratuit" event_reservations, et blocage de la
// réintroduction d'un PIN artisan en clair même par un admin.
// ═══════════════════════════════════════════════════════════════════════════

test('LOT 6.2 : deux VRAIES transactions Firestore concurrentes (pas un même batch) ne peuvent jamais partager un débit — sérialisées par Firestore, une seule aboutit', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 500, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const clientRef = clientDb.doc('clients/c1');

  async function attemptPay(orderId) {
    try {
      await clientDb.runTransaction(async (tx) => {
        const snap = await tx.get(clientRef);
        const balance = snap.data().wallet;
        if (balance < 500) throw new Error('SOLDE_INSUFFISANT');
        tx.update(clientRef, { wallet: balance - 500, lastPaidOrderId: orderId });
        tx.set(clientDb.doc(`orders/${orderId}`), {
          clientId: 'c1', budget: 500, isPaid: true, paymentMethod: 'wallet', status: 'pending',
        });
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // Le wallet ne couvre qu'UN SEUL débit de 500 — deux tentatives réellement
  // concurrentes (Promise.all, pas un batch) doivent voir Firestore les
  // sérialiser : exactement une réussit, l'autre échoue (solde insuffisant
  // après relecture lors du retry de transaction), jamais les deux.
  const [resultA, resultB] = await Promise.all([attemptPay('oA'), attemptPay('oB')]);
  assert.equal([resultA, resultB].filter(Boolean).length, 1,
    'exactement une des deux transactions concurrentes doit réussir, jamais les deux ni aucune');

  const finalWallet = (await clientRef.get()).data().wallet;
  assert.equal(finalWallet, 0, 'le wallet ne doit être débité qu\'une seule fois au total');
});

// ── event_reservations : plancher anti-"paiement gratuit" (LOT 6.2) ───────

test('LOT 6.2 : une réservation événementielle "payée" par wallet avec totalAmount:0 est refusée (débit trivialement nul, sinon "payée" sans jamais rien coûter)', async () => {
  await seed((db) => db.doc('clients/c1').set({
    wallet: 1000, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
  }));
  const clientDb = asClient('c1');
  const batch = clientDb.batch();
  // Débit nul (wallet inchangé) — mathématiquement cohérent avec
  // totalAmount:0, mais ne doit plus jamais donner isPaid:true.
  batch.update(clientDb.doc('clients/c1'), { lastPaidReservationId: 'r1' });
  batch.set(clientDb.doc('event_reservations/r1'), {
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 0,
    paymentMethod: 'wallet', isPaid: true,
  });
  await assertFails(batch.commit());
});

// LOT 6.3 : superseded — même une réservation cash (jamais concernée par le
// débit/plancher) ne peut plus être créée directement par le client.
test('LOT 6.3 : une réservation cash/future, même à montant nul, est désormais refusée en écriture directe (CF-only)', async () => {
  await assertFails(asClient('c1').doc('event_reservations/r1').set({
    clientId: 'c1', status: 'pending', items: [{ x: 1 }], totalAmount: 0,
    paymentMethod: 'cash', isPaid: false,
  }));
});

// ── service_providers : artisanPin ne peut plus jamais être réécrit en clair, même par un admin (compatibilité "vieux build admin") ──

test('LOT 6.2 : même un admin (simulant un ancien build qui écrivait encore artisanPin en clair) ne peut plus réintroduire ce champ', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/p1').set({ name: 'Kouassi', phone: '0700000000', status: 'pending' });
  });
  await assertFails(asAdmin('admin1').doc('service_providers/p1').update({
    status: 'approved', isAvailable: true, artisanPin: '1234',
  }));
});

test('LOT 6.2 (contrôle) : un admin peut toujours approuver un artisan tant qu\'il ne touche pas artisanPin (fonctionnement légitime inchangé)', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/p1').set({ name: 'Kouassi', phone: '0700000000', status: 'pending' });
  });
  await assertSucceeds(asAdmin('admin1').doc('service_providers/p1').update({
    status: 'approved', isAvailable: true,
  }));
});

test('LOT 6.2 (contrôle) : un admin peut toujours supprimer un artisanPin résiduel (nettoyage/migration), la suppression n\'est jamais bloquée', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/p1').set({
      name: 'Kouassi', phone: '0700000000', status: 'approved', artisanPin: '1234',
    });
  });
  await assertSucceeds(asAdmin('admin1').doc('service_providers/p1').update({
    artisanPin: deleteField(),
  }));
});

test('LOT 6.3 DIAGNOSTIC : un admin qui met à jour un champ SANS RAPPORT sur un ancien document qui a encore artisanPin en clair — vérifie si le blocage LOT 6.2 bloque aussi les mises à jour légitimes avant migration', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/p1').set({
      name: 'Kouassi', phone: '0700000000', status: 'pending', artisanPin: '1234',
    });
  });
  // Ne touche jamais artisanPin — seulement status/isAvailable.
  await assertSucceeds(asAdmin('admin1').doc('service_providers/p1').update({
    status: 'approved', isAvailable: true,
  }));
});

test('LOT 7.1: admin create accepts a public profile without a plaintext PIN', async () => {
  await seed((db) => db.doc('admins/admin1').set({ role: 'super', isActive: true }));
  await assertSucceeds(asAdmin('admin1').doc('service_providers/new').set({ name: 'Provider', status: 'pending' }));
  await assertFails(asAdmin('admin1').doc('service_providers/unsafe').set({ name: 'Provider', artisanPin: 'forbidden' }));
  await assertFails(asClient('client').doc('service_providers/other').set({ name: 'Provider' }));
});

test('LOT 7.1: admin update preserves public edits but rejects plaintext introduction or change', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/clean').set({ name: 'Provider' });
    await db.doc('service_providers/legacy').set({ name: 'Provider', artisanPin: 'fixture-only' });
  });
  await assertSucceeds(asAdmin('admin1').doc('service_providers/clean').update({ name: 'Edited' }));
  await assertSucceeds(asAdmin('admin1').doc('service_providers/legacy').update({ name: 'Edited' }));
  await assertFails(asAdmin('admin1').doc('service_providers/clean').update({ artisanPin: 'forbidden' }));
  await assertFails(asAdmin('admin1').doc('service_providers/legacy').update({ artisanPin: 'changed' }));
});

test('LOT 7.1: admin delete works for clean and legacy profiles; other users cannot delete', async () => {
  await seed(async (db) => {
    await db.doc('admins/admin1').set({ role: 'super', isActive: true });
    await db.doc('service_providers/clean').set({ name: 'Provider' });
    await db.doc('service_providers/legacy').set({ name: 'Provider', artisanPin: 'fixture-only' });
  });
  await assertFails(asClient('client').doc('service_providers/clean').delete());
  await assertFails(unauth().doc('service_providers/legacy').delete());
  await assertSucceeds(asAdmin('admin1').doc('service_providers/clean').delete());
  await assertSucceeds(asAdmin('admin1').doc('service_providers/legacy').delete());
});
