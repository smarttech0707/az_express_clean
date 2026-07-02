'use strict';

const { createPendingAction } = require('../pendingActions');
const { createVisitRequest } = require('../../realestate');

const RESULT_LIMIT = 10;

// Recherche calquée sur search_marketplace (mêmes limites Firestore côté
// requête simple, filtrage texte/prix côté serveur) — real_estate_listings
// existe désormais réellement (jalon M6), ce n'est plus un stub.
function searchRealEstate({ db }) {
  return {
    name: 'search_real_estate',
    description: "Recherche un bien immobilier (maison, terrain, appartement...) à louer ou à acheter sur AZ Express.",
    input_schema: {
      type: 'object',
      properties: {
        query:        { type: 'string', description: 'Mot-clé de recherche (titre ou description).' },
        propertyType: { type: 'string', description: 'Type de bien (ex. Maison, Terrain, Appartement).' },
        city:         { type: 'string', description: 'Ville ou quartier recherché.' },
        priceType:    { type: 'string', enum: ['sale', 'rent'], description: 'Vente ou location.' },
        minPrice:     { type: 'number', description: 'Prix minimum en FCFA (optionnel).' },
        maxPrice:     { type: 'number', description: 'Prix maximum en FCFA (optionnel).' },
      },
    },
    handler: async (_uid, input) => {
      let q = db.collection('real_estate_listings').where('status', '==', 'active');
      if (input?.propertyType) {
        q = q.where('propertyType', '==', String(input.propertyType));
      }

      const snap = await q.orderBy('createdAt', 'desc').limit(80).get();
      let results = snap.docs.map(d => ({ id: d.id, ...d.data() }));

      if (input?.query) {
        const needle = String(input.query).toLowerCase().trim();
        results = results.filter(r =>
          String(r.title || '').toLowerCase().includes(needle) ||
          String(r.description || '').toLowerCase().includes(needle)
        );
      }
      if (input?.city) {
        const needle = String(input.city).toLowerCase();
        results = results.filter(r => String(r.city || '').toLowerCase().includes(needle));
      }
      if (input?.priceType) {
        results = results.filter(r => r.priceType === input.priceType);
      }
      if (typeof input?.minPrice === 'number') {
        results = results.filter(r => (r.price ?? 0) >= input.minPrice);
      }
      if (typeof input?.maxPrice === 'number') {
        results = results.filter(r => (r.price ?? Infinity) <= input.maxPrice);
      }

      if (results.length === 0) {
        return { available: true, count: 0, results: [], message: 'Aucun bien ne correspond à cette recherche pour le moment.' };
      }

      const trimmed = results.slice(0, RESULT_LIMIT).map(r => ({
        id:           r.id,
        title:        r.title || null,
        propertyType: r.propertyType || null,
        priceType:    r.priceType || null,
        price:        r.price ?? null,
        city:         r.city || null,
      }));

      return { available: true, count: trimmed.length, results: trimmed };
    },
  };
}

// Demande de visite — outil sensible : commet un vrai rendez-vous et notifie
// un agent réel, donc gaté par confirmation comme toute création de commande
// (cf. règle AZ IA « aucune commande sans confirmation explicite »).
function requestPropertyVisit({ db, admin, HttpsError }) {
  return {
    name: 'request_property_visit',
    description: "Demande une visite pour un bien immobilier. Nécessite une confirmation explicite avant tout envoi réel à l'agent.",
    input_schema: {
      type: 'object',
      properties: {
        listingId:     { type: 'string', description: "Identifiant de l'annonce." },
        preferredDate: { type: 'string', description: 'Date/moment souhaité par le client (texte libre, ex. "samedi matin").' },
        message:       { type: 'string', description: "Message optionnel pour l'agent." },
      },
      required: ['listingId'],
    },
    handler: async (uid, input, ctx) => {
      const listingId = String(input?.listingId || '').trim();
      if (!listingId) throw new Error('listingId manquant.');

      const listingSnap = await db.collection('real_estate_listings').doc(listingId).get();
      if (!listingSnap.exists) return { error: 'Annonce introuvable.' };
      const listing = listingSnap.data();
      if (listing.status !== 'active') return { error: "Cette annonce n'est plus disponible." };

      const summaryFr = `Demander une visite pour "${listing.title || 'ce bien'}"${input?.preferredDate ? ` (${input.preferredDate})` : ''}.`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'request_property_visit',
        toolInput: {
          listingId,
          preferredDate: input?.preferredDate || null,
          message: input?.message || null,
        },
        summaryFr,
        amount: null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      try {
        const result = await createVisitRequest(db, admin, { uid, ...toolInput }, tx);
        return result;
      } catch (err) {
        throw new HttpsError('failed-precondition', err.message);
      }
    },
  };
}

module.exports = { searchRealEstate, requestPropertyVisit };
