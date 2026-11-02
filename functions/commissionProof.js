'use strict';

// Preuve de prélèvement de commission pour les commandes SANS trace sur la commande
// (`commissionStatus` absent : acceptées avant acceptOrderCF).
//
// Le livreur peut écrire dans son propre journal `wallet_transactions` (règle historique), donc un
// document `commission_<commande>_<livreur>` n'est PAS une preuve à lui seul. Cette fonction pure ne
// retient que ce qui est compatible avec ce que le serveur a réellement pu écrire :
//   - type `commission`, même commande, montant entier > 0 ;
//   - aucun champ réservé à l'écriture client (`provider`, `txId`) : le prélèvement serveur n'en pose pas ;
//   - montant jamais supérieur à la commission du barème pour le budget de la commande.
// Si l'une des conditions échoue, aucun remboursement automatique : le signalement
// `reconciliation_flags` (vérification administrative) prend le relais.

function verifyLegacyCommissionProof({ proof, orderId, expected }) {
  if (!proof || typeof proof !== 'object') return { amount: null, reason: 'proof_missing' };
  if (proof.type !== 'commission') return { amount: null, reason: 'proof_type_invalid' };
  if (proof.orderId !== orderId) return { amount: null, reason: 'proof_order_mismatch' };
  if (!Number.isSafeInteger(proof.amount) || proof.amount <= 0) return { amount: null, reason: 'proof_amount_invalid' };
  if (proof.provider !== undefined || proof.txId !== undefined) return { amount: null, reason: 'proof_client_shape' };
  if (!Number.isSafeInteger(expected) || expected <= 0) return { amount: null, reason: 'expected_unknown' };
  if (proof.amount > expected) return { amount: null, reason: 'proof_exceeds_policy' };
  return { amount: proof.amount, reason: null };
}

// Commission attendue pour la commande, calculée comme au prélèvement (acceptOrderCF : budget).
async function expectedLegacyCommission(db, order, calculateCommission) {
  const budget = Number(order && order.budget);
  if (!Number.isFinite(budget) || budget <= 0) return null;
  const value = Math.floor(Number(await calculateCommission(db, budget)));
  return Number.isSafeInteger(value) && value > 0 ? value : null;
}

module.exports = { verifyLegacyCommissionProof, expectedLegacyCommission };
