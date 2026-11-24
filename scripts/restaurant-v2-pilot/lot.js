'use strict';

// Lot de test « Restaurant v2 » (Mission 7E-36) : définition PURE des comptes, documents et montants fictifs.
// Rien ici ne touche à Firebase : prepare.js et cleanup.js exécutent ce plan, uniquement après autorisation explicite.
// Les formes des documents ne sont pas inventées : chaque champ est lu par une fonction déployée (référence en commentaire) et
// restaurantV2Pilot.emulator.test.js rejoue le parcours complet avec les VRAIS modules de functions/ sur ces documents.

const crypto = require('node:crypto');
const path = require('node:path');

const fn = (name) => require(path.join(__dirname, '..', '..', 'functions', name));
const { buildPartnerAmounts } = fn('partnerOrderAmounts');
const { computeOfficialTariff } = fn('officialTariff');
const { DEFAULT_TARIFF_CONFIG } = fn('tariffConfig');
const { PARTNER_KINDS, parseItems, priceItems } = fn('partnerCatalog');
const { validateConfigChange } = fn('partnerOrdersConfig');

const LOT_ID = 't7e-lot-1';
const TARGET = Object.freeze({
  projectId: 'az-express-preprod',
  projectNumber: '306761725053',
  region: 'europe-west1',
  storageBucket: 'az-express-preprod.firebasestorage.app',
});
const FORBIDDEN_PROJECT_IDS = Object.freeze(['az-express-b0469', 'az-express-clean']);
const EMAIL_DOMAIN = 'example.invalid';
// Seul champ ajouté par rapport aux schémas réels : il marque les documents du lot pour que le nettoyage vérifie l'appartenance
// autrement que par l'identifiant. Aucune fonction déployée ne le lit.
const LOT_FIELD = 'testLotId';

const identity = (role, uid, displayName) => Object.freeze({ role, uid, email: `${uid}@${EMAIL_DOMAIN}`, displayName });
const IDENTITIES = Object.freeze({
  client: identity('client', 't7e-client', 'Client Test T7E'),
  restaurant: identity('restaurant', 't7e-resto', 'Restaurant Test T7E'),
  driver: identity('driver', 't7e-driver', 'Livreur Test T7E'),
  admin: identity('admin', 't7e-admin', 'Admin Test T7E'),
});
const UIDS = Object.freeze(Object.values(IDENTITIES).map((i) => i.uid));

// Zone de service réelle de la préproduction : zones_livraison/abengourou-test (ville active, rayon 8 km, centre 6.7273 / -3.4961).
const RESTAURANT_POINT = Object.freeze({ lat: 6.73, lng: -3.493 });
const DELIVERY_POINT = Object.freeze({ lat: 6.7345, lng: -3.489 });
const DRIVER_POINT = Object.freeze({ lat: 6.7302, lng: -3.4928 }); // à ~30 m du restaurant (rayon de dispatch : 2 km)
const CITY_ID = 'abengourou';

const MENU = Object.freeze([
  Object.freeze({ id: 't7e-plat-a', name: 'Plat test A', price: 2500, description: 'Article fictif du lot de test', available: true }),
  Object.freeze({ id: 't7e-plat-b', name: 'Plat test B', price: 1500, description: 'Article fictif du lot de test', available: true }),
]);
const BASKET = Object.freeze([{ itemId: 't7e-plat-a', qty: 2 }, { itemId: 't7e-plat-b', qty: 1 }]);

// Soldes de départ (FCFA entiers). Client : ~5 commandes de ~7 000 FCFA simultanément débitées au pire du plan ; livreur : couvre
// la commission (100 ou 200) de plusieurs courses ; restaurant : crédité uniquement à la livraison.
const WALLETS = Object.freeze({ client: 40000, driver: 5000, restaurant: 0 });

const SERVER_TIMESTAMP = Object.freeze({ __serverTimestamp: true });

// ── Documents de départ ──────────────────────────────────────────────────────────────────────────────────────────────
// Références : clients (wallet, name, phone, deletionRequested/isDeleted : partnerOrderQuote.js, assertActiveClient) ;
// restaurants (name, lat/lng, isOpen, isActive, wallet, openTime/closeTime absents = pas de plage horaire : partnerCatalog.js) ;
// restaurants/{id}/menu/{itemId} (name, price entier, available : partnerCatalog.js) ; restaurant_owners/{uid}.restaurantId
// (deliveryProofs.js, authorizePickupIssuer) ; livreurs (isOnline, isOnDelivery, isAvailable, isSuspended, wallet, lat, lng,
// updatedAt < 3 min, currentCityId : dispatch.js, driverAcceptance.js) ; admins (role, isActive : adminGuards.js).
// Aucun téléphone, aucun fcmToken, aucun e-mail réel.
function buildSeedPlan() {
  const c = IDENTITIES.client; const r = IDENTITIES.restaurant; const d = IDENTITIES.driver; const a = IDENTITIES.admin;
  const mark = { [LOT_FIELD]: LOT_ID };
  const docs = [
    { path: `clients/${c.uid}`, kind: 'client', data: { name: c.displayName, email: c.email, wallet: WALLETS.client, ...mark } },
    {
      path: `restaurants/${r.uid}`,
      kind: 'restaurant',
      data: {
        name: r.displayName, address: 'Adresse fictive, Abengourou', category: 'Test', isOpen: true, isActive: true,
        lat: RESTAURANT_POINT.lat, lng: RESTAURANT_POINT.lng, wallet: WALLETS.restaurant, ...mark,
      },
    },
    ...MENU.map((m) => ({
      path: `restaurants/${r.uid}/menu/${m.id}`,
      kind: 'menu',
      data: { name: m.name, price: m.price, description: m.description, available: m.available, ...mark },
    })),
    { path: `restaurant_owners/${r.uid}`, kind: 'restaurant_owner', data: { restaurantId: r.uid, ...mark } },
    {
      path: `livreurs/${d.uid}`,
      kind: 'driver',
      data: {
        name: d.displayName, wallet: WALLETS.driver, isOnline: true, isOnDelivery: false, isAvailable: true, isSuspended: false,
        lat: DRIVER_POINT.lat, lng: DRIVER_POINT.lng, currentCityId: CITY_ID, registeredCityId: CITY_ID,
        updatedAt: SERVER_TIMESTAMP, ...mark,
      },
    },
    { path: `admins/${a.uid}`, kind: 'admin', data: { role: 'super', isActive: true, email: a.email, ...mark } },
  ];
  return docs;
}

// Aucun champ sensible dans le lot (jeton FCM, téléphone, secret) : refus de tout plan qui en contiendrait.
const SENSITIVE_KEY = /fcm|token|phone|password|secret|apikey/i;
function findSensitiveKeys(plan) {
  const found = [];
  for (const doc of plan) {
    for (const key of Object.keys(doc.data)) if (SENSITIVE_KEY.test(key)) found.push(`${doc.path}:${key}`);
  }
  return found;
}

// ── Montants attendus (calculés par les modules réels, jamais recopiés) ─────────────────────────────────────────────────
// Même règle que dispatch.calculateCommission (config/commission absente en préproduction : défauts 100 / 200 / seuil 1000) ;
// restaurantV2Pilot.test.js vérifie l'égalité avec la fonction réelle.
function commissionFor(budget, cfg = { basic: 100, standard: 200, threshold: 1000 }) {
  return budget < cfg.threshold ? cfg.basic : cfg.standard;
}

function menuMap(items = MENU) {
  return new Map(items.map((m) => [m.id, { name: m.name, price: m.price, available: m.available }]));
}

// nowMs fixe le tarif jour (500 FCFA) ou nuit (1000 FCFA) du barème officiel.
function expectedAmounts({ basket = BASKET, nowMs = Date.now() } = {}) {
  const items = parseItems(basket);
  const { productAmount } = priceItems('restaurant', items, menuMap());
  const tariff = computeOfficialTariff({
    serviceType: 'restaurant', mode: 'standard', pickup: RESTAURANT_POINT, destination: DELIVERY_POINT, nowMs, config: DEFAULT_TARIFF_CONFIG,
  });
  if (!tariff.ok) throw new Error(`tarif indisponible : ${tariff.code}`);
  const amounts = buildPartnerAmounts(productAmount, tariff.deliveryFee);
  return { ...amounts, commission: commissionFor(amounts.budget) }; // driverAcceptance.js : calculateCommission(budget), sans plafond
}

// Montants déduits du devis RÉEL retourné par le serveur (le scénario jour/nuit n'est jamais supposé). Refuse tout devis dont les frais
// ne sont pas 500 (jour) ou 1 000 (nuit), dont le drapeau isNight contredit les frais, ou dont les produits/total ne sont pas ceux du panier.
function amountsFromQuote(quote, basket = BASKET) {
  const q = quote || {};
  const base = expectedAmounts({ basket });
  if (q.productAmount !== base.productAmount) throw new Error(`produits ${q.productAmount}, attendus ${base.productAmount}`);
  if (![500, 1000].includes(q.deliveryFee) || (q.deliveryFee === 1000) !== (q.isNight === true)) throw new Error('frais de livraison incohérents avec le barème jour/nuit');
  const amounts = buildPartnerAmounts(q.productAmount, q.deliveryFee);
  if (q.total !== amounts.totalAmount) throw new Error(`total ${q.total}, attendu ${amounts.totalAmount}`);
  return { ...amounts, commission: commissionFor(amounts.budget) };
}

// Soldes attendus à chaque étape d'une commande payée en wallet (voir orderActions.js : création, acceptation, livraison).
function expectedLedger(amounts, start = WALLETS) {
  const afterCreate = { client: start.client - amounts.totalAmount, driver: start.driver, restaurant: start.restaurant };
  const afterAccept = { ...afterCreate, driver: start.driver - amounts.commission };
  const afterDelivery = {
    client: afterCreate.client,
    driver: afterAccept.driver + amounts.deliveryFee,
    restaurant: start.restaurant + amounts.productAmount,
  };
  return { start: { ...start }, afterCreate, afterAccept, afterDelivery };
}

// ── Configuration du pilote (préparée, JAMAIS écrite par ces scripts) ────────────────────────────────────────────────────
// Ouverture par le super-administrateur fictif via partnerOrderActionCF (action setPartnerOrdersConfig) : audit avant/après et
// contrôle de version intégrés. Document attendu : partnerOrdersConfig.applyConfigChange.

// Livreurs autorisés (Mission 7E-55, liste blanche pilotDriverIds) : JAMAIS déduits ni ajoutés automatiquement. L'administrateur les
// fournit explicitement : option { driverIds: [...] } ou variable d'environnement AZ_PILOT_DRIVER_IDS (identifiants séparés par des
// virgules : uid Firebase du livreur, voir docs/RESTAURANT_V2_FIRST_RUN_PLAN.md). Absente, vide ou invalide : on refuse, car le serveur
// ne dispatcherait alors à personne.
const DRIVER_IDS_ENV = 'AZ_PILOT_DRIVER_IDS';
const MAX_DRIVER_IDS = 50; // plafond de validateConfigChange (MAX_PILOT_DRIVERS)
const DRIVER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/; // même format que PARTNER_ID (partnerOrdersConfig.js)

class PilotDriverListError extends Error {
  constructor(message) { super(message); this.name = 'PilotDriverListError'; this.code = 'PILOT_DRIVER_IDS_REQUIRED'; }
}

function resolveDriverIds(source) {
  const raw = Array.isArray(source) ? source : typeof source === 'string' ? source.split(',') : null;
  if (raw === null || raw.length === 0 || (typeof source === 'string' && source.trim() === '')) {
    throw new PilotDriverListError(`Livreurs du pilote non fournis : renseignez explicitement leurs identifiants (option driverIds ou variable ${DRIVER_IDS_ENV}). Aucun livreur n'est autorisé par défaut.`);
  }
  const ids = [];
  for (const entry of raw) {
    const id = typeof entry === 'string' ? entry.trim() : entry;
    if (typeof id !== 'string' || !DRIVER_ID_PATTERN.test(id)) {
      throw new PilotDriverListError(`Identifiant de livreur invalide dans ${DRIVER_IDS_ENV} / driverIds : chaque valeur doit être un uid non vide (lettres, chiffres, _ et -, 128 caractères au plus).`);
    }
    if (!ids.includes(id)) ids.push(id);
  }
  if (ids.length > MAX_DRIVER_IDS) throw new PilotDriverListError(`Trop de livreurs pilotes (${ids.length} > ${MAX_DRIVER_IDS}).`);
  return ids.sort();
}

// La fermeture (creationOpen:false seul) ne dépend d'aucun livreur et reste TOUJOURS disponible, y compris pour l'arrêt d'urgence.
// request et expectedDocument (ouverture / réouverture) lèvent PilotDriverListError tant que la liste n'est pas fournie.
function pilotConfigPlan({ driverIds, env = process.env } = {}) {
  const source = driverIds !== undefined ? driverIds : env[DRIVER_IDS_ENV];
  const base = { pilotPartnerIds: [IDENTITIES.restaurant.uid], pilotClientIds: [IDENTITIES.client.uid], clientAccess: 'restricted', creationOpen: true, managementFrozen: false };
  let resolved = null;
  const drivers = () => (resolved === null ? (resolved = resolveDriverIds(source)) : resolved);
  const plan = {
    callable: 'partnerOrderActionCF',
    caller: IDENTITIES.admin.uid,
    // Arrêt d'urgence = creationOpen:false SEUL (la liste n'est jamais vidée pour arrêter : voir partnerOrdersConfig.js). La version
    // attendue est celle réellement retournée par S0 / lue avant l'appel : jamais supposée.
    closing: { patch: { creationOpen: false }, reason: 'Fermeture du pilote Restaurant v2 après essai fictif T7E.' },
  };
  Object.defineProperty(plan, 'request', {
    enumerable: true,
    get() {
      const request = {
        action: 'setPartnerOrdersConfig',
        // Mode « restreint » explicite (Mission 7E-41) : seul le client fictif peut commander chez le restaurant fictif, et seuls
        // les livreurs listés explicitement peuvent le recevoir ou l'accepter (Mission 7E-55).
        patch: { ...base, pilotDriverIds: drivers() },
        expectedVersion: 0, // document absent = version 0
        reason: 'Ouverture temporaire du pilote Restaurant v2 pour essai fictif T7E.',
      };
      validateConfigChange(request); // lève ConfigRefusal si la demande n'est pas acceptée par la fonction réelle
      return request;
    },
  });
  Object.defineProperty(plan, 'expectedDocument', {
    enumerable: true,
    get() { return { ...base, pilotDriverIds: drivers(), version: 1 }; },
  });
  return plan;
}

// ── Inventaire des ressources prévues ────────────────────────────────────────────────────────────────────────────────────
const canonical = (value) => JSON.stringify(value, (_, v) => (v && typeof v === 'object' && !Array.isArray(v)
  ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, v[k]])) : v));
const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');
const docHash = (data) => sha256(canonical(data));

// L'inventaire (DRY-RUN hors ligne) doit rester lisible sans liste de livreurs : on y signale alors le blocage au lieu de lever.
function inventoryPilotPlan() {
  const plan = pilotConfigPlan();
  try { return { ...plan }; } catch (err) {
    if (!(err instanceof PilotDriverListError)) throw err;
    return { callable: plan.callable, caller: plan.caller, blocked: err.message, closing: plan.closing };
  }
}

function buildInventory(plan = buildSeedPlan()) {
  return {
    lot: LOT_ID,
    project: { id: TARGET.projectId, number: TARGET.projectNumber, region: TARGET.region },
    authUsers: Object.values(IDENTITIES).map(({ role, uid, email }) => ({ role, uid, email, password: 'générée à l’exécution (fichier hors dépôt)' })),
    documents: plan.map((d) => ({ path: d.path, kind: d.kind, fields: Object.keys(d.data).sort(), hash: docHash(d.data) })),
    pilotConfig: { written: false, plan: inventoryPilotPlan() },
    dynamicAtTestTime: [
      'orders/<uuid> (une par scénario, créées par createPartnerOrderFromQuoteCF)',
      'tariff_quotes/<uuid>', 'delivery_proofs/<hash> + versions/*', 'clients|livreurs|restaurants/<uid>/wallet_transactions/*',
      'commissions/*', 'reconciliation_flags/*', 'order_dispute_decisions/*',
      'acceptance_selfies/<orderId>/t7e-driver.jpg (Storage, exigé par acceptOrderCF)',
    ],
    preserved: ['audit_logs (écriture serveur seule)', 'rate_limits (expirent seuls)'],
  };
}

module.exports = {
  LOT_ID, LOT_FIELD, TARGET, FORBIDDEN_PROJECT_IDS, EMAIL_DOMAIN, IDENTITIES, UIDS, SERVER_TIMESTAMP,
  RESTAURANT_POINT, DELIVERY_POINT, DRIVER_POINT, CITY_ID, MENU, BASKET, WALLETS, PARTNER_KINDS,
  buildSeedPlan, findSensitiveKeys, commissionFor, expectedAmounts, amountsFromQuote, expectedLedger, pilotConfigPlan, resolveDriverIds, PilotDriverListError, DRIVER_IDS_ENV, buildInventory,
  canonical, sha256, docHash,
};
