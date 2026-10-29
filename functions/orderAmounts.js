'use strict';

// Montants explicites des commandes Marketplace / Boutique.
//
// Décision métier : le client paie séparément (1) le prix des produits et
// (2) les frais de livraison. Avant, `orders.budget` valait le prix du produit
// (marketplace) ou 500 sans jamais être facturé (boutique) : la commission et
// le gain livreur étaient donc faux. Pour les NOUVELLES commandes :
//   productAmount = prix des produits (revient au vendeur, 0 % commission)
//   deliveryFee   = frais de livraison (revient au livreur, moins la commission)
//   totalAmount   = productAmount + deliveryFee (ce que le client règle)
//   budget        = deliveryFee  (le dispatch, la commission d'acceptation et les
//                                 notifications livreur lisent déjà `budget`)
// Les anciennes commandes (sans `amountsVersion`) gardent leur comportement.

const AMOUNTS_VERSION = 1;

function isMoney(n) {
  return Number.isSafeInteger(n) && n >= 0;
}

function buildAmounts(productAmount, deliveryFee) {
  if (!Number.isSafeInteger(productAmount) || productAmount <= 0) {
    throw new Error('productAmount invalide');
  }
  if (!Number.isSafeInteger(deliveryFee) || deliveryFee <= 0) {
    throw new Error('deliveryFee invalide');
  }
  return {
    amountsVersion: AMOUNTS_VERSION,
    productAmount,
    deliveryFee,
    totalAmount: productAmount + deliveryFee,
    budget: deliveryFee,
  };
}

// Lecture défensive : renvoie les montants explicites si (et seulement si) la
// commande est cohérente ; sinon null (= commande historique).
function readAmounts(order) {
  if (!order || order.amountsVersion !== AMOUNTS_VERSION) return null;
  const { productAmount, deliveryFee, totalAmount } = order;
  if (!isMoney(productAmount) || !isMoney(deliveryFee) || !isMoney(totalAmount)) return null;
  if (productAmount + deliveryFee !== totalAmount) return null;
  if (Number(order.budget) !== deliveryFee) return null;
  return { productAmount, deliveryFee, totalAmount };
}

// Détail de l'encaissement cash d'une commande à montants explicites : le
// livreur encaisse le total, reverse les produits au vendeur et garde les frais
// (la commission AZ a déjà été prélevée sur son wallet à l'acceptation).
function cashBreakdown(amounts, commissionAmount) {
  const commission = Number.isSafeInteger(commissionAmount) && commissionAmount >= 0
    ? commissionAmount : null;
  return {
    productAmount: amounts.productAmount,
    deliveryFee: amounts.deliveryFee,
    cashCollected: amounts.totalAmount,
    dueToSeller: amounts.productAmount,
    driverGross: amounts.deliveryFee,
    commissionAmount: commission,
    driverNet: commission == null ? null : amounts.deliveryFee - commission,
  };
}

module.exports = { AMOUNTS_VERSION, buildAmounts, readAmounts, cashBreakdown };
