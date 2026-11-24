// Inscription des comptes : les payloads réellement écrits par les écrans Flutter doivent être acceptés par
// firestore.rules, et les contournements (wallet, statut) refusés. Un écart ici = utilisateur bloqué après le
// lancement. Exécution : emulators:exec (voir package.json, test:rules).
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const anonymous = { firebase: { sign_in_provider: 'anonymous' } };

let env;
test.before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-account-registration', firestore: { rules: RULES } });
});
test.after(async () => { await env.cleanup(); });
test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('admins/root').set({ role: 'super', isActive: true });
  });
});

const real = (uid) => env.authenticatedContext(uid, password).firestore();
const anon = (uid) => env.authenticatedContext(uid, anonymous).firestore();
const ts = new Date();

// ── Client (profil_client.dart / client_auth_page.dart) ───────────────────────────────────────────
const clientCreate = { name: 'Awa', phone: '0700000000', wallet: 0, cashOnDeliveryEnabled: true, fakeOrderCount: 0, createdAt: ts };

test('client anonyme : 1re sauvegarde du profil (création conforme) acceptée', async () => {
  await assertSucceeds(anon('anon1').doc('clients/anon1').set(clientCreate));
});

test('client : l\'ancien payload {name, phone, updatedAt} sur un document absent est refusé (cause du correctif)', async () => {
  await assertFails(anon('anon2').doc('clients/anon2').set({ name: 'Awa', phone: '0700000000', updatedAt: ts }, { merge: true }));
});

test('client : création avec un wallet non nul refusée', async () => {
  await assertFails(real('c1').doc('clients/c1').set({ ...clientCreate, wallet: 5000 }));
});

test('client : mise à jour du nom/téléphone par le propriétaire acceptée, wallet inchangé exigé', async () => {
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('clients/c3').set(clientCreate));
  await assertSucceeds(anon('c3').doc('clients/c3').set({ name: 'Awa K', phone: '0711111111', updatedAt: ts }, { merge: true }));
  await assertFails(anon('c3').doc('clients/c3').update({ wallet: 99999 }));
});

test('client anonyme : aucune écriture dans le document d\'un autre', async () => {
  await assertFails(anon('anon4').doc('clients/other').set(clientCreate));
});

// ── Flotte (fleet_register.dart) ───────────────────────────────────────────────────────────────────
const fleetCreate = {
  name: 'Patron', phone: '0700000001', identifiant: 'patron1', status: 'pending',
  photoUrl: 'u', idPhotoUrl: '', idNumber: 'CI123', createdAt: ts,
};

test('flotte : inscription conforme acceptée, statut approved ou champ wallet refusés', async () => {
  await assertSucceeds(real('f1').doc('fleet_owners/f1').set(fleetCreate));
  await assertFails(real('f2').doc('fleet_owners/f2').set({ ...fleetCreate, status: 'approved' }));
  await assertFails(real('f3').doc('fleet_owners/f3').set({ ...fleetCreate, wallet: 100000 }));
  await assertFails(anon('f4').doc('fleet_owners/f4').set(fleetCreate));
});

test('flotte : un patron NE PEUT PAS créer le document livreur (fleet_dashboard._createDriver) — anomalie connue', async () => {
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('fleet_owners/f5').set({ ...fleetCreate, status: 'approved' }));
  await assertFails(real('newDriver').doc('livreurs/newDriver').set({
    name: 'Chauffeur', phone: '0700000002', identifiant: 'ch1', ownerId: 'f5', ownerName: 'Patron', wallet: 500, isOnline: false, createdAt: ts,
  }));
});

// ── Livreur (driver_register.dart) ─────────────────────────────────────────────────────────────────
test('livreur : demande d\'inscription par un compte réel acceptée, par un anonyme refusée, livreurs/ réservé à l\'admin', async () => {
  const request = { uid: 'd1', name: 'Kone', phone: '0700000003', email: 'kone@az-driver.ci', identifiant: 'kone', status: 'pending',
    photoUrl: 'u', idPhotoUrl: '', idNumber: '', createdAt: ts };
  await assertSucceeds(real('d1').doc('driver_requests/d1').set(request));
  await assertFails(anon('d9').doc('driver_requests/d9').set({ ...request, uid: 'd9' }));
  await assertFails(real('d1').doc('livreurs/d1').set({ name: 'Kone', wallet: 100000 }));
  await assertSucceeds(env.authenticatedContext('root', password).firestore().doc('livreurs/d1').set({ name: 'Kone', wallet: 0 }));
});

// ── E-Kbine (ek_agent_register.dart) ──────────────────────────────────────────────────────────────
const agentCreate = {
  name: 'Agent', phone: '0700000004', city: 'Abengourou', operators: ['mtn'], operatorNumbers: { mtn: '0500000000' },
  depositAccounts: [{ id: 'a', operator: 'mtn', number: '0500000000', isActive: true }],
  status: 'pending', isOnline: false, isVerified: false, isSuspended: false, walletBalance: 0, totalCompleted: 0,
  rating: 0.0, ratingCount: 0, createdAt: ts,
};

test('E-Kbine : inscription agent conforme acceptée ; anonyme, auto-vérification, solde ou abonnement refusés', async () => {
  await assertSucceeds(real('e1').doc('ekbine_agents/e1').set(agentCreate));
  await assertFails(anon('e2').doc('ekbine_agents/e2').set(agentCreate));
  await assertFails(real('e3').doc('ekbine_agents/e3').set({ ...agentCreate, isVerified: true }));
  await assertFails(real('e4').doc('ekbine_agents/e4').set({ ...agentCreate, walletBalance: 9000 }));
  await assertFails(real('e5').doc('ekbine_agents/e5').set({ ...agentCreate, subscriptionStatus: 'active' }));
});

// ── Immobilier : demande par fonction uniquement, agent créé par l'admin ────────────────────────────
test('immobilier : ni demande directe d\'un anonyme, ni création directe d\'un agent par le client', async () => {
  await assertFails(real('r1').doc('real_estate_agents/r1').set({ uid: 'r1', isVerified: true, isActive: true }));
  await assertFails(anon('r2').doc('real_estate_agent_requests/x').set({ uid: 'r2', status: 'pending' }));
});

// ── Événements (event_service.dart) ────────────────────────────────────────────────────────────────
test('événements : prestataire en attente accepté, auto-approbation refusée', async () => {
  const profile = {
    ownerId: 'p1', status: 'pending', isSuspended: false, requestedPlan: 'standard', planStatus: 'pending', name: 'DJ', createdAt: ts,
  };
  await assertSucceeds(real('p1').doc('event_providers/p1').set(profile));
  await assertFails(real('p2').doc('event_providers/p2').set({ ...profile, ownerId: 'p2', status: 'approved' }));
  await assertFails(anon('p3').doc('event_providers/p3').set({ ...profile, ownerId: 'p3' }));
});

// ── Artisan : session anonyme liée par artisanLogin ─────────────────────────────────────────────────
test('artisan : la session reste anonyme, donc l\'ajout de photos (update photos) est refusé — anomalie connue', async () => {
  await env.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('service_providers/s1').set({
    name: 'Maçon', phone: '0700000005', artisanUid: 'artisan-anon', photos: [], status: 'approved',
  }));
  await assertSucceeds(anon('artisan-anon').doc('service_providers/s1').get());
  await assertFails(anon('artisan-anon').doc('service_providers/s1').update({ photos: ['u'] }));
});
