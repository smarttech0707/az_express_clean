'use strict';

// Catalogue tarifaire serveur — Colis, Blanchisserie, Eau & Boissons.
//
// Les montants ci-dessous RECOPIENT les prix actuellement appliqués par les écrans Flutter (colis_page.dart,
// blanchisserie_page.dart, eau_boissons_page.dart). Vérification en lecture seule de la production (2026-11-03) :
// `app_config/colis`, `app_config/blanchisserie` et `app_config/eau_boissons` n'existent PAS — les clients paient donc
// exactement ces constantes. Aucun prix n'est modifié par ce module.
//
// Pure (aucun accès réseau) : testable sans émulateur. Aucun montant ne vient jamais du client : il fournit seulement
// des choix (type, kilos, identifiants de produits, quantités) que le serveur valide puis tarifie.

const CATALOG_VERSION = 'catalog-2026-11-03.1';

// Montant minimal d'une commande (`budget`) : 500 FCFA (règle de création client de `orders`, firestore.rules).
// DÉROGATION UNIQUE (décision du propriétaire, 2026-11-03) : « Document / Enveloppe » reste à 300 FCFA et devient
// réellement commandable. Le minimum global des autres services et types ne change pas. La création par ce module
// passe par l'Admin SDK : la règle client budget >= 500 n'est pas traversée, donc aucune règle à modifier ; commission
// (palier 100 FCFA sous 1000), annulation (remboursement du budget) et livraison (crédit du budget) n'ont aucun seuil.
const MIN_ORDER_BUDGET = 500;
const DOCUMENT_ENVELOPE_TYPE = 'Document / Enveloppe';
const DOCUMENT_ENVELOPE_MIN_BUDGET = 300;
const minBudgetFor = (service, params) => (service === 'colis' && params.colisType === DOCUMENT_ENVELOPE_TYPE
  ? DOCUMENT_ENVELOPE_MIN_BUDGET : MIN_ORDER_BUDGET);

// PLAFONDS PROVISOIRES validés par le propriétaire (jamais présents avant : aucune limite côté application ni règles).
// Toujours vérifiés ICI, côté serveur. `eauMaxWeightGrams` est une garde supplémentaire de transport à moto : voir EAU.
const LIMITS = Object.freeze({
  blanchisserieMaxKg: 30,
  eauMaxPerProduct: 20,
  eauMaxCasiers: 5,
  eauMaxBasketFcfa: 50000,
  // Poids estimé maximal d'un panier (une livraison = un trajet de moto). Valeur provisoire À CONFIRMER par l'équipe
  // d'Abengourou : 5 casiers (≈ 95 kg) ne sont pas transportables en un trajet.
  eauMaxWeightGrams: 50000,
});

const COLIS = Object.freeze({
  types: Object.freeze({
    'Colis standard': 500,
    'Cadeau emballé': 700,
    'Document / Enveloppe': 300,
    'Gros colis': 1000,
  }),
  fragileSurcharge: 200,
});

const BLANCHISSERIE_DEFAULTS = Object.freeze({
  services: Object.freeze(['Lavage + Repassage', 'Lavage uniquement', 'Repassage uniquement', 'Pressing']),
  pricePerKg: 1000,
});
// Bornes de validation du prix au kilo MODIFIABLE par un administrateur (app_config/blanchisserie) : hors bornes,
// le serveur ignore la valeur et applique le prix par défaut (un administrateur ne peut pas, par erreur de saisie,
// vendre à 1 FCFA ni à un montant démesuré).
const PRICE_PER_KG_BOUNDS = Object.freeze({ min: 100, max: 10000 });

// weightG : poids ESTIMÉ en grammes (contenu + emballage), déduit de la désignation du produit — pas mesuré.
const EAU = Object.freeze({
  deliveryFee: 500,
  products: Object.freeze({
    eau_500: { name: 'Eau 500ml', price: 200, weightG: 550 },
    eau_1500: { name: 'Eau 1.5L', price: 400, weightG: 1550 },
    casier_eau: { name: "Casier d'eau (12×1.5L)", price: 3500, weightG: 19000, maxQty: LIMITS.eauMaxCasiers },
    coca_33: { name: 'Coca-Cola 33cl', price: 500, weightG: 500 },
    fanta_33: { name: 'Fanta 33cl', price: 500, weightG: 500 },
    sprite_33: { name: 'Sprite 33cl', price: 500, weightG: 500 },
    jus_tropics: { name: 'Jus de fruits 50cl', price: 600, weightG: 550 },
    lait_500: { name: 'Lait 500ml', price: 700, weightG: 550 },
    energie: { name: 'Boisson énergisante', price: 800, weightG: 500 },
  }),
});

class CatalogRefusal extends Error {
  constructor(code, message, data = null) { super(message); this.code = code; this.data = data; }
}

const isQty = (n) => Number.isSafeInteger(n) && n >= 1;
const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

// Configuration de la blanchisserie : défauts, surchargés par le document admin SI valide.
function resolveBlanchisserieConfig(doc) {
  const cfg = { services: [...BLANCHISSERIE_DEFAULTS.services], pricePerKg: BLANCHISSERIE_DEFAULTS.pricePerKg, source: 'default', issues: [] };
  if (!doc || typeof doc !== 'object') return cfg;
  const p = doc.pricePerKg;
  if (p !== undefined) {
    if (Number.isSafeInteger(p) && p >= PRICE_PER_KG_BOUNDS.min && p <= PRICE_PER_KG_BOUNDS.max) {
      cfg.pricePerKg = p;
      cfg.source = 'app_config';
    } else {
      cfg.issues.push('pricePerKg_invalid');
    }
  }
  const s = doc.services;
  if (s !== undefined) {
    if (Array.isArray(s) && s.length >= 1 && s.length <= 10 && s.every((x) => typeof x === 'string' && x.trim() && x.length <= 60)) {
      cfg.services = s.map((x) => x.trim());
      cfg.source = 'app_config';
    } else {
      cfg.issues.push('services_invalid');
    }
  }
  return cfg;
}

// Retourne { budget, shoppingBudget, lines, orderFields, params } ou lève CatalogRefusal.
// `params` est la forme canonique (utilisée pour lier le devis à la commande).
function priceCatalogRequest(service, input, { blanchisserieConfig } = {}) {
  const i = input && typeof input === 'object' ? input : {};
  let result;
  if (service === 'colis') {
    if (typeof i.colisType !== 'string' || !has(COLIS.types, i.colisType)) throw new CatalogRefusal('INVALID_ITEM', 'Type de colis invalide');
    if (i.fragile !== undefined && typeof i.fragile !== 'boolean') throw new CatalogRefusal('INVALID_PARAMS', 'Paramètre « fragile » invalide');
    const fragile = i.fragile === true;
    const base = COLIS.types[i.colisType];
    const budget = base + (fragile ? COLIS.fragileSurcharge : 0);
    result = {
      budget, shoppingBudget: 0,
      lines: [{ label: i.colisType, amount: base }, ...(fragile ? [{ label: 'Fragile', amount: COLIS.fragileSurcharge }] : [])],
      params: { colisType: i.colisType, fragile },
      orderFields: { colisType: i.colisType, fragile },
    };
  } else if (service === 'blanchisserie') {
    const cfg = blanchisserieConfig || resolveBlanchisserieConfig(null);
    if (typeof i.serviceType !== 'string' || !cfg.services.includes(i.serviceType)) throw new CatalogRefusal('INVALID_ITEM', 'Service de blanchisserie invalide');
    if (!isQty(i.quantity)) throw new CatalogRefusal('INVALID_QUANTITY', 'Quantité invalide');
    if (i.quantity > LIMITS.blanchisserieMaxKg) {
      throw new CatalogRefusal('QUANTITY_TOO_HIGH', `Maximum ${LIMITS.blanchisserieMaxKg} kg par commande`, { maxKg: LIMITS.blanchisserieMaxKg });
    }
    const budget = i.quantity * cfg.pricePerKg;
    result = {
      budget, shoppingBudget: 0,
      lines: [{ label: `${i.serviceType} — ${i.quantity} kg`, amount: budget }],
      params: { serviceType: i.serviceType, quantity: i.quantity },
      orderFields: { serviceType: i.serviceType, quantity: i.quantity },
      pricePerKg: cfg.pricePerKg, configSource: cfg.source,
    };
  } else if (service === 'eau_boissons') {
    if (!Array.isArray(i.items) || i.items.length === 0 || i.items.length > Object.keys(EAU.products).length) {
      throw new CatalogRefusal('INVALID_ITEMS', 'Panier invalide');
    }
    const seen = new Set();
    const lines = [];
    const canonical = [];
    let shoppingBudget = 0;
    let weightG = 0;
    for (const it of i.items) {
      if (!it || typeof it.id !== 'string' || !has(EAU.products, it.id)) throw new CatalogRefusal('INVALID_ITEM', 'Produit inconnu');
      if (seen.has(it.id)) throw new CatalogRefusal('DUPLICATE_ITEM', 'Produit en double dans le panier');
      seen.add(it.id);
      if (!isQty(it.qty)) throw new CatalogRefusal('INVALID_QUANTITY', 'Quantité invalide');
      if (it.qty > LIMITS.eauMaxPerProduct) {
        throw new CatalogRefusal('QUANTITY_TOO_HIGH', `Maximum ${LIMITS.eauMaxPerProduct} unités par produit`, { maxPerProduct: LIMITS.eauMaxPerProduct });
      }
      const p = EAU.products[it.id];
      if (p.maxQty !== undefined && it.qty > p.maxQty) {
        throw new CatalogRefusal('QUANTITY_TOO_HIGH', `Maximum ${p.maxQty} × ${p.name} par commande`, { product: it.id, maxQty: p.maxQty });
      }
      weightG += it.qty * p.weightG;
      const subtotal = it.qty * p.price;
      shoppingBudget += subtotal;
      lines.push({ id: it.id, label: p.name, qty: it.qty, unitPrice: p.price, amount: subtotal });
      canonical.push({ id: it.id, qty: it.qty });
    }
    if (shoppingBudget > LIMITS.eauMaxBasketFcfa) {
      throw new CatalogRefusal('BASKET_TOO_HIGH', `Panier limité à ${LIMITS.eauMaxBasketFcfa} FCFA`, { maxBasketFcfa: LIMITS.eauMaxBasketFcfa });
    }
    if (weightG > LIMITS.eauMaxWeightGrams) {
      throw new CatalogRefusal('BASKET_TOO_HEAVY', `Panier trop lourd pour une livraison à moto (maximum ${LIMITS.eauMaxWeightGrams / 1000} kg estimés)`, { estimatedKg: weightG / 1000, maxKg: LIMITS.eauMaxWeightGrams / 1000 });
    }
    canonical.sort((a, b) => (a.id < b.id ? -1 : 1));
    result = {
      budget: EAU.deliveryFee, shoppingBudget,
      lines: [...lines, { label: 'Livraison', amount: EAU.deliveryFee }],
      params: { items: canonical },
      // Forme exacte de l'écran actuel : { id, name, price, qty, subtotal }.
      orderFields: { items: lines.map((l) => ({ id: l.id, name: l.label, price: l.unitPrice, qty: l.qty, subtotal: l.amount })) },
    };
  } else {
    throw new CatalogRefusal('SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
  }
  const minimum = minBudgetFor(service, result.params);
  if (result.budget < minimum) {
    throw new CatalogRefusal('BELOW_MINIMUM_ORDER', `Montant minimal d'une commande : ${minimum} FCFA`, { budget: result.budget, minimum });
  }
  return { ...result, total: result.budget + result.shoppingBudget };
}

// Comparaison stable des paramètres (devis ↔ commande).
function canonicalParams(params) { return JSON.stringify(params); }

module.exports = {
  CATALOG_VERSION, MIN_ORDER_BUDGET, DOCUMENT_ENVELOPE_TYPE, DOCUMENT_ENVELOPE_MIN_BUDGET, LIMITS, COLIS, BLANCHISSERIE_DEFAULTS, PRICE_PER_KG_BOUNDS, EAU,
  CatalogRefusal, resolveBlanchisserieConfig, priceCatalogRequest, canonicalParams,
};
