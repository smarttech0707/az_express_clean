'use strict';

const { readAmounts } = require('./orderAmounts');

// Règle : aucune livraison ne doit laisser à AZ Express une commission
// définitivement conservée si le livreur n'a prévu aucune rémunération.
//
// Une commande Marketplace / Boutique « historique » (créée par une ancienne
// application, sans montants explicites) est payée au vendeur dès la création et
// le client n'a réglé que les produits : `deliverOrderCF` ne peut rien verser au
// livreur (pas de frais encaissés). Prélever la commission d'acceptation sur de
// telles courses est donc un prélèvement sans contrepartie.
//
// Document `config/billing`, champ `legacyPartnerAcceptance` :
//   - 'block' (défaut) : une commande historique ne peut plus être acceptée
//     (LEGACY_PARTNER_ORDER) et les anciennes applications ne peuvent plus créer
//     de nouvelle commande de ce type (APP_UPDATE_REQUIRED, aucun débit) — on ne
//     prend pas l'argent du client pour une course que personne ne peut accepter.
//     L'administration résout les commandes déjà créées (clôture + remboursement).
//   - 'no_commission' : mode transitoire décidé par l'exploitant — la commande
//     historique reste acceptable, mais SANS commission (le livreur ne paie rien,
//     AZ ne conserve rien). Aucune rémunération n'est inventée.
// Les courses historiques DÉJÀ acceptées (commission déjà prélevée) sont
// neutralisées à la livraison : la commission tracée est rendue à son payeur.

const PARTNER_TYPES = ['seller', 'boutique'];
const POLICIES = ['block', 'no_commission'];
const DEFAULT_POLICY = 'block';

function isLegacyPartnerOrder(order) {
  return !!order && PARTNER_TYPES.includes(order.sellerType) && !readAmounts(order);
}

async function getLegacyPartnerPolicy(db) {
  try {
    const snap = await db.collection('config').doc('billing').get();
    const value = snap.exists ? snap.data().legacyPartnerAcceptance : null;
    return POLICIES.includes(value) ? value : DEFAULT_POLICY;
  } catch (_) {
    return DEFAULT_POLICY;
  }
}

module.exports = { PARTNER_TYPES, POLICIES, DEFAULT_POLICY, isLegacyPartnerOrder, getLegacyPartnerPolicy };
