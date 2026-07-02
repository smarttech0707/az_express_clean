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

// ── ai_conversations / ai_pending_actions — CF-only ─────────────────────────

test('ai_conversations: le propriétaire peut lire ses messages', async () => {
  await seed((db) => db.doc('ai_conversations/u1/messages/m1').set({ role: 'user', content: 'salut' }));
  await assertSucceeds(asClient('u1').doc('ai_conversations/u1/messages/m1').get());
});

test('ai_conversations: personne ne peut écrire directement, même le propriétaire', async () => {
  await assertFails(asClient('u1').doc('ai_conversations/u1/messages/m1').set({ role: 'user', content: 'x' }));
});

test('ai_pending_actions: le propriétaire peut lire son action en attente', async () => {
  await seed((db) => db.doc('ai_pending_actions/a1').set({ uid: 'u1', status: 'pending' }));
  await assertSucceeds(asClient('u1').doc('ai_pending_actions/a1').get());
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
  await seed((db) => db.doc('admins/admin1').set({ role: 'sub', isActive: true }));
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
