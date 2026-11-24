'use strict';

// Données fictives du projet de test (2 livreurs, 1 client, 1 admin, 1 vendeur, produits).
// AUCUNE donnée réelle, aucun SMS : comptes e-mail + mot de passe, soldes fictifs.
//
// Émulateurs (aucun projet requis) :
//   $env:FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"; $env:FIREBASE_AUTH_EMULATOR_HOST="127.0.0.1:9099"
//   $env:AZ_TEST_PASSWORD="<12+ caractères>"; node test-env/seed-test-data.js --project demo-az-test --emulator
// Projet de test réel (déjà créé par vous, authentifié via GOOGLE_APPLICATION_CREDENTIALS) :
//   node test-env/seed-test-data.js --project <id-test> --confirm-project <id-test>
// Projet local des émulateurs : --project demo-az-express --emulator (voir test-env/emulators-seed.ps1)
//
// Refuse : projet de production, nom sans test/staging/demo, variable d'environnement visant la
// production, absence de confirmation explicite hors émulateur.

const path = require('path');
const { createRequire } = require('module');
const g = require('./lib/guards');

const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const has = (name) => args.includes(name);

function main() {
  g.assertNoProductionEnv(process.env);
  const project = g.assertTestProject(opt('--project'));
  const emulator = has('--emulator');
  if (emulator) {
    if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
      throw new Error('Mode --emulator : FIRESTORE_EMULATOR_HOST et FIREBASE_AUTH_EMULATOR_HOST requis.');
    }
  } else {
    if (opt('--confirm-project') !== project) throw new Error('Projet réel : --confirm-project <même id> requis.');
    if (process.env.FIRESTORE_EMULATOR_HOST) throw new Error('FIRESTORE_EMULATOR_HOST défini sans --emulator.');
  }
  const password = process.env.AZ_TEST_PASSWORD || '';
  // Émulateur local (comptes fictifs, jamais joignable depuis Internet) : 8 caractères suffisent ; projet réel : 12.
  const minLength = emulator ? 8 : 12;
  if (password.length < minLength) throw new Error(`AZ_TEST_PASSWORD (${minLength} caractères minimum) requis ; jamais écrit dans un fichier.`);

  const adminSdk = createRequire(path.join(__dirname, '..', 'functions', 'package.json'))('firebase-admin');
  adminSdk.initializeApp({ projectId: project });
  return run(adminSdk, project, password);
}

// Soldes fictifs. Les e-mails utilisent le domaine réservé .invalid : aucun message réel possible.
const ACCOUNTS = {
  client:  { email: 'client.test@az-test.invalid',   name: 'Client Test',   phone: '+2250100000001', wallet: 20000 },
  driverA: { email: 'livreur.a@az-test.invalid',     name: 'Livreur A Test', identifiant: 'test-livreur-a', phone: '+2250100000002', wallet: 5000 },
  driverB: { email: 'livreur.b@az-test.invalid',     name: 'Livreur B Test', identifiant: 'test-livreur-b', phone: '+2250100000003', wallet: 5000 },
  admin:   { email: 'admin.test@az-test.invalid',    name: 'Admin Test' },
  seller:  { email: 'vendeur.test@az-test.invalid',  name: 'Vendeur Test', phone: '+2250100000004', wallet: 0 },
};

async function ensureUser(auth, a, password) {
  try {
    const u = await auth.getUserByEmail(a.email);
    await auth.updateUser(u.uid, { password, emailVerified: true, displayName: a.name });
    return u.uid;
  } catch (e) {
    if (e.code !== 'auth/user-not-found') throw e;
    return (await auth.createUser({ email: a.email, password, emailVerified: true, displayName: a.name })).uid;
  }
}

async function run(adminSdk, project, password) {
  const auth = adminSdk.auth();
  const db = adminSdk.firestore();
  const now = adminSdk.firestore.FieldValue.serverTimestamp();
  const uid = {};
  for (const [key, acc] of Object.entries(ACCOUNTS)) uid[key] = await ensureUser(auth, acc, password);

  const base = { createdAt: now, isTestData: true };
  const batch = db.batch();
  const set = (ref, data) => batch.set(ref, data, { merge: true });

  set(db.doc(`clients/${uid.client}`), { ...base, name: ACCOUNTS.client.name, phone: ACCOUNTS.client.phone,
    email: ACCOUNTS.client.email, wallet: ACCOUNTS.client.wallet });
  for (const key of ['driverA', 'driverB']) {
    const a = ACCOUNTS[key];
    // Livreur approuvé, hors ligne et disponible (la position GPS réelle vient du téléphone).
    set(db.doc(`livreurs/${uid[key]}`), { ...base, name: a.name, identifiant: a.identifiant, phone: a.phone,
      email: a.email, wallet: a.wallet, status: 'approved', isApproved: true, isSuspended: false,
      isOnline: false, isAvailable: true, vehicleType: 'moto', currentCityId: 'abengourou' });
  }
  set(db.doc(`admins/${uid.admin}`), { ...base, email: ACCOUNTS.admin.email, role: 'super', isActive: true });
  set(db.doc(`sellers/${uid.seller}`), { ...base, name: ACCOUNTS.seller.name, type: 'boutique', email: ACCOUNTS.seller.email,
    phone: ACCOUNTS.seller.phone, wallet: ACCOUNTS.seller.wallet, lat: 6.7273, lng: -3.4961 });
  set(db.doc('boutique_products/test-riz'), { ...base, sellerId: uid.seller, name: 'Riz 5 kg (test)',
    category: 'Alimentation', price: 5000, stock: 10 });
  set(db.doc('marketplace_products/test-tv'), { ...base, status: 'active', title: 'Téléviseur (test)',
    price: 5000, sellerId: uid.seller, sellerName: ACCOUNTS.seller.name });
  for (const id of ['abengourou', 'centre']) {
    set(db.doc(`zones_livraison/${id}`), { ...base, type: id === 'centre' ? 'quartier' : 'ville', cityId: 'abengourou',
      isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 100 });
  }
  // Politique de facturation : nouvelle facturation, commandes historiques bloquées (défauts explicites).
  set(db.doc('config/billing'), { separateDeliveryFee: 'accepted_only', legacyPartnerAcceptance: 'block' });

  // Commandes fictives (paiement cash : aucun mouvement de wallet, soldes de départ cohérents).
  const geo = { latitude: 6.7273, longitude: -3.4961, destLat: 6.7350, destLng: -3.4900, pickupCityId: 'abengourou' };
  const order = (extra) => ({ ...base, ...geo, clientId: uid.client, type: 'livraison', status: 'pending',
    paymentMethod: 'cash', isPaid: false, budget: 500, shoppingBudget: 0, ...extra });
  set(db.doc('orders/test-livraison-cash'), order({ description: 'Colis fictif (livraison cash)' }));
  set(db.doc('orders/test-marketplace-explicite'), order({ description: 'Marketplace fictif (montants explicites)',
    type: 'marketplace', sellerId: uid.seller, sellerType: 'seller', amountsVersion: 1, productAmount: 5000,
    deliveryFee: 500, totalAmount: 5500, itemsAmount: 5000, deliveryFeePaid: false }));
  // Ancienne commande (sans montants explicites) : doit être refusée à l'acceptation et apparaître côté admin.
  set(db.doc('orders/test-marketplace-historique'), order({ description: 'Marketplace fictif (ancienne commande)',
    type: 'marketplace', sellerId: uid.seller, sellerType: 'seller', budget: 5000 }));
  await batch.commit();

  console.log(`Données fictives écrites dans « ${project} » (aucun SMS, aucun paiement réel).`);
  console.log('Comptes (même mot de passe : AZ_TEST_PASSWORD) :');
  for (const [key, acc] of Object.entries(ACCOUNTS)) console.log(` - ${key.padEnd(8)} ${acc.email}  uid=${uid[key]}`);
  console.log('Connexion livreur : identifiant test-livreur-a / test-livreur-b ; client : téléphone +2250100000001.');
}

try {
  Promise.resolve(main()).then(() => process.exit(0)).catch((e) => { console.error(`ERREUR : ${e.message}`); process.exit(1); });
} catch (e) {
  console.error(`ERREUR : ${e.message}`);
  process.exit(1);
}
