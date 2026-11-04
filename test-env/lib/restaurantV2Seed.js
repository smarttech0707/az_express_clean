'use strict';

// Données fictives du pilote Restaurant v2 (Mission 7E-9) : logique PURE, sans accès réseau, testée dans
// functions/test/restaurantV2Preprod.test.js. Les comptes de base (client, livreur, administrateur) sont ceux de
// test-env/seed-test-data.js (mêmes e-mails .invalid, mêmes identifiants de documents) : les deux scripts se complètent sans doublon.
//
// Idempotence : identifiants de documents déterministes + écriture en fusion ; un champ marqué `keepIfExists` (wallet) n'est écrit que
// s'il n'existe pas encore : relancer le script ne recharge jamais un solde. Aucune recharge réelle : les soldes de départ sont
// fixés directement par le script de test.
//
// Volontairement ABSENT : config/partnerOrdersV2. Un document absent = création FERMÉE, aucun restaurant pilote, gel inactif, version 0.
// Seul l'outil super-administrateur (setPartnerOrdersConfig) y écrit, avec version attendue, motif et audit.

const RESTAURANT_ID = 'test-resto-v2';

// E-mails du domaine réservé .invalid (aucun message réel possible), sauf le restaurateur : l'application impose
// <téléphone>@az-restaurant.ci (restaurant_owner_login.dart) avec un numéro FICTIF.
const ACCOUNTS = Object.freeze({
  client:     { email: 'client.test@az-test.invalid',  name: 'Client Test',      phone: '+2250100000001', wallet: 20000 },
  driver:     { email: 'livreur.a@az-test.invalid',    name: 'Livreur A Test',   phone: '+2250100000002', wallet: 5000, identifiant: 'test-livreur-a' },
  admin:      { email: 'admin.test@az-test.invalid',   name: 'Admin Test' },
  restaurant: { email: '0100000005@az-restaurant.ci',  name: 'Restaurateur Test', phone: '0100000005' },
});

// Menu de test : prix entiers en FCFA (le serveur relit ces prix, jamais ceux du client).
const MENU = Object.freeze([
  { id: 'poulet-braise', name: 'Poulet braisé (test)', price: 3500, category: 'Plats' },
  { id: 'attieke-poisson', name: 'Attiéké poisson (test)', price: 2500, category: 'Plats' },
  { id: 'jus-bissap', name: 'Jus de bissap (test)', price: 500, category: 'Boissons' },
]);

const POINT = Object.freeze({ lat: 6.7273, lng: -3.4961 });

// uids : { client, driver, admin, restaurant } (identifiants d'authentification). Retourne la liste ordonnée des écritures.
function buildPlan(uids) {
  for (const k of Object.keys(ACCOUNTS)) {
    if (!uids || typeof uids[k] !== 'string' || !uids[k]) throw new Error(`uid manquant pour « ${k} »`);
  }
  const base = { isTestData: true };
  const docs = [];
  const add = (path, data, keepIfExists = []) => docs.push({ path, data: { ...base, ...data }, keepIfExists });

  add(`clients/${uids.client}`, { name: ACCOUNTS.client.name, phone: ACCOUNTS.client.phone, email: ACCOUNTS.client.email,
    wallet: ACCOUNTS.client.wallet }, ['wallet']);
  add(`livreurs/${uids.driver}`, { name: ACCOUNTS.driver.name, identifiant: ACCOUNTS.driver.identifiant, phone: ACCOUNTS.driver.phone,
    email: ACCOUNTS.driver.email, wallet: ACCOUNTS.driver.wallet, status: 'approved', isApproved: true, isSuspended: false,
    isOnline: false, isAvailable: true, vehicleType: 'moto', currentCityId: 'abengourou' }, ['wallet']);
  add(`admins/${uids.admin}`, { email: ACCOUNTS.admin.email, role: 'super', isActive: true });
  for (const id of ['abengourou', 'centre']) {
    add(`zones_livraison/${id}`, { type: id === 'centre' ? 'quartier' : 'ville', cityId: 'abengourou', isActive: true,
      isServiceable: true, coordinateSource: 'own', lat: POINT.lat, lng: POINT.lng, radiusKm: 100 });
  }
  add('config/billing', { separateDeliveryFee: 'accepted_only', legacyPartnerAcceptance: 'block' });

  add(`restaurants/${RESTAURANT_ID}`, { id: RESTAURANT_ID, name: 'Restaurant Test v2', phone: ACCOUNTS.restaurant.phone,
    ownerId: uids.restaurant, lat: POINT.lat, lng: POINT.lng, isActive: true, isOpen: true, wallet: 0, cuisine: 'Ivoirienne' }, ['wallet']);
  for (const item of MENU) {
    add(`restaurants/${RESTAURANT_ID}/menu/${item.id}`, { name: item.name, price: item.price, category: item.category, available: true });
  }
  add(`restaurant_owners/${uids.restaurant}`, { uid: uids.restaurant, phone: ACCOUNTS.restaurant.phone,
    ownerName: ACCOUNTS.restaurant.name, restaurantId: RESTAURANT_ID, mustChangePassword: false });
  add(`restaurant_owner_locks/${RESTAURANT_ID}`, { ownerUid: uids.restaurant });
  return docs;
}

// Marqueurs de ressources réelles qui ne doivent jamais apparaître dans les données semées.
function findRealDataMarkers(plan) {
  const text = JSON.stringify(plan);
  const hits = [];
  if (/az-express-b0469|az-express-clean|697217052961/.test(text)) hits.push('référence de production');
  if (/@(gmail|yahoo|hotmail|outlook)\./i.test(text)) hits.push('adresse e-mail personnelle');
  return hits;
}

module.exports = { RESTAURANT_ID, ACCOUNTS, MENU, buildPlan, findRealDataMarkers };
