'use strict';

// Montants explicites des commandes Restaurant / Boulangerie « versionnées » (PRÉPARATION — aucune fonction de
// commande ne les écrit encore, aucun parcours existant ne les lit).
//
// Pourquoi une version distincte de `orderAmounts.js` (version 1, Marketplace/Boutique) : la version 1 déclenche déjà
// des branches de livraison/annulation propres à ces deux services. Une commande partenaire en version 2 ne peut donc
// jamais être prise, par erreur, pour une commande Marketplace.
//
// Orientations métier PROVISOIRES (à confirmer, aucun tarif modifié ici) :
//   - les produits reviennent au partenaire (aucune commission AZ sur les produits) ;
//   - les frais de livraison reviennent au livreur, moins la commission AZ existante (plafonnée aux frais) ;
//   - `budget` = frais de livraison : le dispatch, la commission d'acceptation et les notifications livreur
//     lisent déjà `budget` comme rémunération de la course (même convention que la version 1).
// Les commandes historiques (sans `amountsVersion`) gardent leur comportement.

const PARTNER_AMOUNTS_VERSION = 2;
const PARTNER_SELLER_TYPES = Object.freeze(['restaurant', 'boulangerie']);

const isMoney = (n) => Number.isSafeInteger(n) && n >= 0;

function buildPartnerAmounts(productAmount, deliveryFee) {
  if (!Number.isSafeInteger(productAmount) || productAmount <= 0) throw new Error('productAmount invalide');
  if (!Number.isSafeInteger(deliveryFee) || deliveryFee <= 0) throw new Error('deliveryFee invalide');
  if (!Number.isSafeInteger(productAmount + deliveryFee)) throw new Error('totalAmount invalide');
  return {
    amountsVersion: PARTNER_AMOUNTS_VERSION,
    productAmount,
    deliveryFee,
    totalAmount: productAmount + deliveryFee,
    budget: deliveryFee,
  };
}

// Lecture défensive : null = commande historique ou incohérente (traitée comme historique, jamais devinée).
function readPartnerAmounts(order) {
  if (!order || order.amountsVersion !== PARTNER_AMOUNTS_VERSION) return null;
  const { productAmount, deliveryFee, totalAmount } = order;
  if (!isMoney(productAmount) || !isMoney(deliveryFee) || !isMoney(totalAmount)) return null;
  if (productAmount <= 0 || deliveryFee <= 0) return null;
  if (productAmount + deliveryFee !== totalAmount) return null;
  if (Number(order.budget) !== deliveryFee) return null;
  return { productAmount, deliveryFee, totalAmount };
}

// Séparation des quatre montants. `commission` = prélèvement AZ RÉEL (tracé à l'acceptation), jamais supérieur aux
// frais de livraison : la commission ne porte jamais sur les produits.
function partnerBreakdown(amounts, { commission = 0, paymentMethod } = {}) {
  if (!amounts || !isMoney(amounts.productAmount) || !isMoney(amounts.deliveryFee)) throw new Error('montants invalides');
  if (!isMoney(commission)) throw new Error('commission invalide');
  if (commission > amounts.deliveryFee) throw new Error('la commission ne peut pas dépasser les frais de livraison');
  const base = {
    clientPays: amounts.productAmount + amounts.deliveryFee, // total accepté par le client
    partnerDue: amounts.productAmount, // dû au partenaire
    driverGross: amounts.deliveryFee, // rémunération brute du livreur
    azCommission: commission, // sur les frais de livraison uniquement
    driverNet: amounts.deliveryFee - commission,
  };
  if (paymentMethod === 'cash') {
    // Le livreur encaisse le total, garde ses frais nets et doit reverser les produits au partenaire.
    return { ...base, cashCollectedByDriver: base.clientPays, cashToRemitToPartner: base.partnerDue };
  }
  return base;
}

module.exports = { PARTNER_AMOUNTS_VERSION, PARTNER_SELLER_TYPES, buildPartnerAmounts, readPartnerAmounts, partnerBreakdown };
