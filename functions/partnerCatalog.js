'use strict';

// Menus Restaurant / Boulangerie lus CÔTÉ SERVEUR (Mission 7B-1). Aucun prix ne vient jamais du client : il fournit des
// identifiants d'articles et des quantités, le serveur relit les prix et la disponibilité dans Firestore.
//
// Structures réelles inspectées (écrans de saisie et de commande, mission 7B-1) :
//   restaurants/{restaurantId}/menu/{itemId}        : name, price, description, stock, available, imageUrl
//     - `available` est un booléen ; absent (anciens documents) = disponible. `stock` n'est jamais décrémenté
//       (le tableau de bord écrit `available && (stock == 0 || stock > 0)`, toujours vrai) : il n'est pas lu ici.
//   boulangeries/{boulangerieId}/menu_items/{itemId} : name, price, description, category, isAvailable, imageUrl
//     - le client n'affiche que `isAvailable == true` : ici une valeur autre que `true` = indisponible.
//   Propriétaire : restaurant_owners/{uid}.restaurantId -> restaurants/{id} ; la boulangerie EST son propriétaire
//   (boulangeries/{uid}). Seul le document du partenaire désigné par la commande est lu.
//   Suppression : un article supprimé n'existe plus (document absent) = indisponible.

const crypto = require('crypto');
const { validPoint } = require('./officialTariff');

const PARTNER_KINDS = Object.freeze({
  restaurant: Object.freeze({
    collection: 'restaurants', menu: 'menu', availableField: 'available', availableWhenMissing: true,
  }),
  boulangerie: Object.freeze({
    collection: 'boulangeries', menu: 'menu_items', availableField: 'isAvailable', availableWhenMissing: false,
  }),
});

// Plafonds PROVISOIRES de lancement (aucun n'existait) : à confirmer par le propriétaire.
const PARTNER_LIMITS = Object.freeze({ maxLines: 30, maxQtyPerLine: 20, maxProductAmount: 500000, maxItemPrice: 500000 });

class PartnerRefusal extends Error {
  constructor(code, message, data = null) { super(message); this.code = code; this.data = data; }
}

const isId = (s) => typeof s === 'string' && s.length > 0 && s.length <= 128 && !s.includes('/');

// Panier canonique : [{itemId, qty}] trié, sans doublon. Jamais de prix.
function parseItems(raw) {
  if (!Array.isArray(raw) || raw.length === 0) throw new PartnerRefusal('INVALID_ITEMS', 'Panier invalide');
  if (raw.length > PARTNER_LIMITS.maxLines) {
    throw new PartnerRefusal('TOO_MANY_LINES', `Maximum ${PARTNER_LIMITS.maxLines} articles différents`, { maxLines: PARTNER_LIMITS.maxLines });
  }
  const seen = new Set();
  const out = [];
  for (const it of raw) {
    if (!it || !isId(it.itemId)) throw new PartnerRefusal('INVALID_ITEM', 'Article invalide');
    if (seen.has(it.itemId)) throw new PartnerRefusal('DUPLICATE_ITEM', 'Article en double dans le panier');
    seen.add(it.itemId);
    if (!Number.isSafeInteger(it.qty) || it.qty < 1) throw new PartnerRefusal('INVALID_QUANTITY', 'Quantité invalide');
    if (it.qty > PARTNER_LIMITS.maxQtyPerLine) {
      throw new PartnerRefusal('QUANTITY_TOO_HIGH', `Maximum ${PARTNER_LIMITS.maxQtyPerLine} unités par article`, { maxQty: PARTNER_LIMITS.maxQtyPerLine });
    }
    out.push({ itemId: it.itemId, qty: it.qty });
  }
  return out.sort((a, b) => (a.itemId < b.itemId ? -1 : 1));
}

function parseClock(value) {
  const m = /^(\d{1,2})\s*[:hH]\s*(\d{2})$/.exec(String(value || '').trim());
  if (!m) return null;
  const h = Number(m[1]); const min = Number(m[2]);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

// Le partenaire peut-il recevoir une commande maintenant ? null = oui, sinon { code, message }.
// Fuseau : Abidjan (UTC, sans heure d'été), comme le barème officiel.
function partnerRefusal(kind, data, nowMs) {
  if (!data) return { code: 'PARTNER_NOT_FOUND', message: 'Partenaire introuvable' };
  if (data.deletionRequested === true || data.isDeleted === true || data.isSuspended === true || data.subscriptionStatus === 'suspended') {
    return { code: 'PARTNER_UNAVAILABLE', message: 'Ce partenaire n\'est pas disponible' };
  }
  if (kind === 'boulangerie') {
    if (data.isActive !== true) return { code: 'PARTNER_UNAVAILABLE', message: 'Ce partenaire n\'est pas disponible' };
    if (data.isOpen !== true) return { code: 'PARTNER_CLOSED', message: 'Ce partenaire est fermé' };
  } else {
    if (data.isActive === false) return { code: 'PARTNER_UNAVAILABLE', message: 'Ce partenaire n\'est pas disponible' };
    if (data.isOpen === false) return { code: 'PARTNER_CLOSED', message: 'Ce partenaire est fermé' };
  }
  const open = parseClock(data.openTime); const close = parseClock(data.closeTime);
  if (open !== null && close !== null) {
    const d = new Date(nowMs);
    const now = d.getUTCHours() * 60 + d.getUTCMinutes();
    const inside = open <= close ? now >= open && now < close : now >= open || now < close;
    if (!inside) return { code: 'PARTNER_CLOSED', message: 'Ce partenaire est fermé' };
  }
  return null;
}

function partnerPoint(data) {
  const p = { lat: Number(data && data.lat), lng: Number(data && data.lng) };
  return validPoint(p) ? p : null;
}

function itemAvailable(kind, data) {
  if (!data) return false;
  const cfg = PARTNER_KINDS[kind];
  const v = data[cfg.availableField];
  return v === undefined || v === null ? cfg.availableWhenMissing : v === true;
}

// `menuData` : Map itemId -> données du document (ou null si absent). Retourne les lignes tarifées par le serveur.
function priceItems(kind, items, menuData) {
  const lines = [];
  let productAmount = 0;
  for (const it of items) {
    const data = menuData.get(it.itemId) || null;
    if (!itemAvailable(kind, data)) throw new PartnerRefusal('ITEM_UNAVAILABLE', 'Un article n\'est plus disponible', { itemId: it.itemId });
    const price = data.price;
    if (!Number.isSafeInteger(price) || price < 1 || price > PARTNER_LIMITS.maxItemPrice) {
      throw new PartnerRefusal('INVALID_PRICE', 'Prix de l\'article invalide', { itemId: it.itemId });
    }
    const name = typeof data.name === 'string' && data.name.trim() ? data.name.trim().slice(0, 120) : 'Article';
    const subtotal = price * it.qty;
    productAmount += subtotal;
    lines.push({ itemId: it.itemId, name, qty: it.qty, unitPrice: price, subtotal });
  }
  if (productAmount > PARTNER_LIMITS.maxProductAmount) {
    throw new PartnerRefusal('BASKET_TOO_HIGH', `Panier limité à ${PARTNER_LIMITS.maxProductAmount} FCFA`, { maxProductAmount: PARTNER_LIMITS.maxProductAmount });
  }
  return { lines, productAmount };
}

// Empreinte des lignes devisées : détecte toute modification du document de devis après sa création.
function itemsFingerprint(lines) {
  const canon = lines.map((l) => [l.itemId, l.qty, l.unitPrice, l.subtotal]);
  return crypto.createHash('sha256').update(JSON.stringify(canon)).digest('hex');
}

module.exports = {
  PARTNER_KINDS, PARTNER_LIMITS, PartnerRefusal, parseItems, partnerRefusal, partnerPoint, itemAvailable, priceItems, itemsFingerprint,
};
