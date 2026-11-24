'use strict';

const { getUserMemory } = require('./tools/memory');

// Minimisation des données (App Store 5.1.1(i)/5.1.2(i)) : AZ IA n'injecte PLUS
// automatiquement le profil, les adresses, les commandes, le solde ni le GPS
// dans chaque appel aux fournisseurs d'IA (Anthropic / Google). Le modèle
// demande uniquement les rubriques utiles à la demande en cours via l'outil
// `get_user_context` ; la sélection reste décidée par la demande, et chaque
// rubrique n'est lue que si elle est demandée.
//
// Le solde du wallet reste accessible par les outils `get_wallet_*`, qui ne
// s'exécutent que si l'utilisateur pose une question qui le concerne.

const RECENT_ORDERS_SAMPLE_SIZE = 10;
const FREQUENT_SELLER_MIN_COUNT = 3;
const CONTEXT_FIELDS = Object.freeze(['name', 'phone', 'addresses', 'preferences', 'last_order', 'location']);

async function getLastOrderAndFrequentSeller(db, uid) {
  try {
    const snap = await db.collection('orders')
      .where('clientId', '==', uid)
      .orderBy('createdAt', 'desc')
      .limit(RECENT_ORDERS_SAMPLE_SIZE)
      .get();
    if (snap.empty) return { lastOrder: null, frequentSeller: null };

    const docs = snap.docs.map(d => d.data());
    const lastOrder = docs[0];

    // Vendeur/restaurant/pharmacie fréquent — compte par sellerName (ou
    // description à défaut, pour les livraisons/courses sans vendeur
    // identifié) sur l'échantillon récent, réellement lu, jamais deviné.
    const counts = new Map();
    for (const o of docs) {
      const key = o.sellerName || o.description;
      if (!key) continue;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    let frequentSeller = null;
    for (const [key, count] of counts.entries()) {
      if (count >= FREQUENT_SELLER_MIN_COUNT && (!frequentSeller || count > frequentSeller.count)) {
        frequentSeller = { name: key, count };
      }
    }

    return { lastOrder, frequentSeller };
  } catch (_) {
    return { lastOrder: null, frequentSeller: null };
  }
}

// Texte constant, sans aucune donnée personnelle : seul rappel au modèle de
// l'existence de l'outil.
const BASE_CONTEXT = "Aucune donnée personnelle n'est jointe à cette conversation. "
  + "Si (et seulement si) la demande exige une information sur l'utilisateur, appelle l'outil get_user_context "
  + "en ne demandant que les rubriques strictement nécessaires.";

async function buildUserContext() {
  return BASE_CONTEXT;
}

// Rubriques demandées par le modèle. Aucune lecture hors des rubriques
// listées : une question générale n'atteint jamais Firestore ici.
async function collectUserContext(db, uid, fields, location) {
  const wanted = new Set((Array.isArray(fields) ? fields : []).filter((f) => CONTEXT_FIELDS.includes(f)));
  const out = {};
  if (wanted.size === 0) return { error: 'Aucune rubrique valide demandée.', fieldsAvailable: CONTEXT_FIELDS };

  if (wanted.has('name') || wanted.has('phone')) {
    try {
      const snap = await db.collection('clients').doc(uid).get();
      const c = snap.exists ? snap.data() : {};
      if (wanted.has('name')) out.name = c.name || null;
      if (wanted.has('phone')) out.phone = c.phone || null;
    } catch (_) { /* best-effort */ }
  }

  if (wanted.has('name') || wanted.has('addresses') || wanted.has('preferences')) {
    const m = (await getUserMemory(db, uid)) || {};
    if (wanted.has('name')) {
      if (m.firstName) out.firstName = m.firstName;
      if (m.nickname) out.nickname = m.nickname;
    }
    if (wanted.has('addresses')) {
      out.address = m.address || null;
      out.quartier = m.quartier || null;
      out.ville = m.ville || null;
      out.namedAddresses = Array.isArray(m.addresses) ? m.addresses.map((a) => ({ label: a.label, address: a.address })) : [];
    }
    if (wanted.has('preferences')) {
      for (const k of ['language', 'preferredPaymentMethod', 'foodPreferences', 'voicePreference',
        'favoritePharmacyId', 'favoriteRestaurantId', 'favoriteSellerId', 'favoriteDriverId']) {
        if (m[k]) out[k] = m[k];
      }
    }
  }

  if (wanted.has('last_order')) {
    const { lastOrder, frequentSeller } = await getLastOrderAndFrequentSeller(db, uid);
    out.lastOrder = lastOrder
      ? { label: lastOrder.sellerName || lastOrder.description || null, budget: lastOrder.budget ?? null }
      : null;
    out.frequentSeller = frequentSeller;
  }

  if (wanted.has('location')) {
    out.location = (location && typeof location.latitude === 'number' && typeof location.longitude === 'number')
      ? { latitude: location.latitude, longitude: location.longitude, address: location.address || null }
      : null;
    if (!out.location) out.locationNote = "Position GPS non disponible (localisation non autorisée) : demande l'adresse à l'utilisateur.";
  }
  return out;
}

module.exports = { buildUserContext, collectUserContext, CONTEXT_FIELDS, BASE_CONTEXT };
