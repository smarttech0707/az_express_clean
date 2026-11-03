'use strict';

// Configuration tarifaire OFFICIELLE (multi-villes) — Phase 1, locale.
//
// Les valeurs ci-dessous reprennent à l'identique celles du code existant
// (lib/services/tarif_service.dart et functions/tarifService.js). Aucun prix
// commercial n'est modifié par ce fichier : un test de parité le garantit.
//
// Ajouter une ville = ajouter une entrée dans `cities` (en pratique dans le
// document Firestore `config/tariffs`, validé par validateConfig avant usage).
// Le moteur (officialTariff.js) ne contient aucune valeur de prix ni de ville.

const TARIFF_CONFIG_VERSION = 1;

const ABENGOUROU = Object.freeze({
  name: 'Abengourou',
  center: Object.freeze({ lat: 6.7273, lng: -3.4961 }),
  // Abidjan est en UTC, sans heure d'été.
  timezoneOffsetMinutes: 0,
  // null = pas de limite de service (comportement actuel : aucun plafond de distance).
  maxServiceKm: null,
  hours: Object.freeze({ nightStartHour: 20, nightEndHour: 6, lateNightStartHour: 21, lateNightMaxKm: 10 }),
  // Zones concentriques depuis le centre : première zone dont maxKm >= distance.
  // Au-delà de la dernière zone, formule kilométrique `outside`.
  zones: Object.freeze([
    Object.freeze({
      id: 'center', maxKm: 8,
      standard: Object.freeze({ day: 500, night: 1000 }),
      // BUSINESS RULE (inchangée) : Express jour 1000, nuit 1500.
      express: Object.freeze({ day: 1000, night: 1500 }),
    }),
  ]),
  outside: Object.freeze({ baseFcfa: 500, perKmFcfa: 150, expressMultiplier: 1.4, roundTo: 50 }),
});

// pricing.delivery : 'scale' (barème ci-dessus) | 'flat' (frais fixe) ;
// items : ce que le serveur peut garantir sur le prix des articles —
//   'none'            : pas d'article ;
//   'official_catalog': prix lus dans le catalogue officiel (jamais fournis par le client) ;
//   'free_budget'     : budget d'achat librement choisi par le client (jamais transformé en prix imposé).
// review : true = le prix actuel de l'application n'est pas établi dans le code (décision métier requise).
const SERVICES = Object.freeze({
  livraison:    Object.freeze({ delivery: 'scale', items: 'none' }),
  courses:      Object.freeze({ delivery: 'scale', items: 'free_budget' }),
  pharmacie:    Object.freeze({ delivery: 'scale', items: 'free_budget' }),
  restaurant:   Object.freeze({ delivery: 'scale', items: 'official_catalog' }),
  boulangerie:  Object.freeze({ delivery: 'scale', items: 'official_catalog' }),
  // Montants explicites déjà calculés côté serveur (orderActions.js : BOUTIQUE_DELIVERY_FEE = 500).
  marketplace:  Object.freeze({ delivery: 'flat', flatFeeFcfa: 500, items: 'official_catalog' }),
  boutique:     Object.freeze({ delivery: 'flat', flatFeeFcfa: 500, items: 'official_catalog' }),
  // Valeur de repli de l'application (eau_boissons_page.dart) ; le document app_config n'est pas lisible.
  eau_boissons: Object.freeze({ delivery: 'flat', flatFeeFcfa: 500, items: 'official_catalog', review: true }),
  // Barèmes propres à l'écran (tableau de types / prix au kilo) : à confirmer avant tout blocage.
  colis:        Object.freeze({ delivery: 'scale', items: 'none', review: true }),
  blanchisserie: Object.freeze({ delivery: 'scale', items: 'official_catalog', review: true }),
});

const DEFAULT_TARIFF_CONFIG = Object.freeze({
  version: TARIFF_CONFIG_VERSION,
  currency: 'XOF',
  cities: Object.freeze({ abengourou: ABENGOUROU }),
  services: SERVICES,
  distance: Object.freeze({
    // Distance routière acceptée au plus = distance à vol d'oiseau × ce facteur.
    maxRoadFactor: 1.6,
    // 'destination' = comportement actuel (zone/distance mesurées vers le point de livraison uniquement).
    // 'farther_point' = le plus éloigné du centre entre départ et livraison (CHANGE des prix : décision métier).
    basis: 'destination',
    // Un contrôle d'itinéraire (service externe) n'est utile que si l'écart de prix
    // entre plancher et plafond dépasse ce seuil (FCFA).
    routeCheckMinGapFcfa: 100,
  }),
  quote: Object.freeze({ ttlSeconds: 600, maxShoppingBudgetFcfa: 500000 }),
});

const fail = (msg) => { throw new Error(`Configuration tarifaire invalide : ${msg}`); };
const isInt = (n) => Number.isSafeInteger(n);
const isHour = (n) => Number.isInteger(n) && n >= 0 && n <= 23;

// Refuse toute configuration qui pourrait produire un prix nul, négatif ou une ville sans centre.
function validateConfig(config) {
  if (!config || typeof config !== 'object') fail('absente');
  if (!isInt(config.version) || config.version < 1) fail('version');
  const ids = Object.keys(config.cities || {});
  if (!ids.length) fail('aucune ville');
  for (const id of ids) {
    const c = config.cities[id];
    if (!/^[a-z][a-z0-9_]{1,40}$/.test(id)) fail(`identifiant de ville ${id}`);
    const { lat, lng } = (c && c.center) || {};
    if (!(Number.isFinite(lat) && Math.abs(lat) <= 90 && Number.isFinite(lng) && Math.abs(lng) <= 180)) fail(`${id}: centre`);
    if (!Number.isInteger(c.timezoneOffsetMinutes) || Math.abs(c.timezoneOffsetMinutes) > 14 * 60) fail(`${id}: fuseau`);
    if (c.maxServiceKm !== null && !(Number.isFinite(c.maxServiceKm) && c.maxServiceKm > 0)) fail(`${id}: maxServiceKm`);
    const h = c.hours || {};
    if (![h.nightStartHour, h.nightEndHour, h.lateNightStartHour].every(isHour)) fail(`${id}: heures`);
    if (!(Number.isFinite(h.lateNightMaxKm) && h.lateNightMaxKm > 0)) fail(`${id}: lateNightMaxKm`);
    if (!Array.isArray(c.zones) || !c.zones.length) fail(`${id}: zones`);
    let prev = 0;
    for (const z of c.zones) {
      if (!(Number.isFinite(z.maxKm) && z.maxKm > prev)) fail(`${id}: zones non croissantes`);
      prev = z.maxKm;
      for (const mode of ['standard', 'express']) {
        for (const slot of ['day', 'night']) {
          if (!isInt(z[mode] && z[mode][slot]) || z[mode][slot] < 500) fail(`${id}/${z.id}: prix ${mode}.${slot}`);
        }
      }
    }
    const o = c.outside || {};
    if (!isInt(o.baseFcfa) || o.baseFcfa < 500 || !(o.perKmFcfa >= 0) || !(o.expressMultiplier >= 1) || !isInt(o.roundTo) || o.roundTo < 1) fail(`${id}: hors zone`);
  }
  for (const [name, s] of Object.entries(config.services || {})) {
    if (!['scale', 'flat'].includes(s.delivery)) fail(`service ${name}: delivery`);
    if (s.delivery === 'flat' && (!isInt(s.flatFeeFcfa) || s.flatFeeFcfa < 500)) fail(`service ${name}: frais fixe`);
    if (!['none', 'official_catalog', 'free_budget'].includes(s.items)) fail(`service ${name}: items`);
  }
  const d = config.distance || {};
  if (!(d.maxRoadFactor >= 1 && d.maxRoadFactor <= 3)) fail('maxRoadFactor');
  if (!['destination', 'farther_point'].includes(d.basis)) fail('basis');
  const q = config.quote || {};
  if (!(isInt(q.ttlSeconds) && q.ttlSeconds >= 30 && q.ttlSeconds <= 3600)) fail('ttlSeconds');
  return config;
}

module.exports = { DEFAULT_TARIFF_CONFIG, TARIFF_CONFIG_VERSION, validateConfig };
