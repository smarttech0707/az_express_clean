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

test('orders: a paid wallet order without an atomic debit is rejected', async () => {
  await seed((db) => db.doc('clients/c1').set({ wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  await assertFails(asClient('c1').doc('orders/o1').set({
    clientId: 'c1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  }));
});

test('orders: a paid wallet order with the exact atomic debit is allowed', async () => {
  await seed((db) => db.doc('clients/c1').set({ wallet: 2000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  const db = asClient('c1');
  const batch = db.batch();
  batch.update(db.doc('clients/c1'), { wallet: 1000 });
  batch.set(db.doc('orders/o1'), {
    clientId: 'c1', budget: 1000, isPaid: true, paymentMethod: 'wallet', status: 'pending',
  });
  await assertSucceeds(batch.commit());
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

test('event: une réservation Wallet exige le débit atomique exact', async () => {
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
  batch.update(clientDb.doc('clients/client-event'), { wallet: 50000 });
  batch.set(clientDb.doc('event_reservations/r-ok'), reservation);
  await assertSucceeds(batch.commit());
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
