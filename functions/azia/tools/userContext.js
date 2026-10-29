'use strict';

const { collectUserContext, CONTEXT_FIELDS } = require('../contextBuilder');

// Lecture à la demande des données personnelles nécessaires à UNE demande.
// Remplace l'ancienne injection automatique du profil dans chaque appel aux
// fournisseurs d'IA (minimisation des données). La position GPS n'est
// renvoyée que si le client l'a transmise (localisation autorisée).
function getUserContext({ db }) {
  return {
    name: 'get_user_context',
    description: "Lit des informations personnelles de l'utilisateur, uniquement celles dont la demande a besoin. "
      + "N'appelle cet outil que si l'information est indispensable (ex. adresse de livraison, « chez moi », téléphone du destinataire, position pour une recherche de proximité) ; "
      + "jamais pour une question générale. Demande le minimum de rubriques.",
    input_schema: {
      type: 'object',
      properties: {
        fields: {
          type: 'array',
          items: { type: 'string', enum: CONTEXT_FIELDS },
          description: "Rubriques nécessaires : name (nom/prénom/surnom), phone, addresses (adresses et quartier/ville connus), preferences (moyen de paiement, favoris, langue), last_order (dernière commande, pour « comme hier »), location (position GPS actuelle, si autorisée).",
        },
      },
      required: ['fields'],
    },
    handler: async (uid, input, ctx) => collectUserContext(db, uid, input?.fields, ctx?.location),
  };
}

module.exports = { getUserContext };
