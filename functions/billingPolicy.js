'use strict';

// Activation progressive de la facturation séparée produits + livraison
// (Marketplace / Boutique) et garde « jamais plus que le montant accepté ».
//
// Les applications installées ne sont pas toutes à jour : une ancienne
// application Boutique affiche le prix des produits seul. Le serveur ne doit
// donc JAMAIS débiter plus que ce que l'application a présenté au client.
//
// Document `config/billing`, champ `separateDeliveryFee` :
//   - 'accepted_only' (défaut si absent) : la nouvelle facturation n'est
//     appliquée qu'aux appels qui déclarent `acceptedTotal` (= total affiché).
//     Les anciennes applications (sans `acceptedTotal`) restent facturées
//     comme avant (produits seuls) : jamais de débit supérieur à l'affiché.
//   - 'required' : les appels sans `acceptedTotal` sont refusés
//     (APP_UPDATE_REQUIRED) — à activer quand les anciennes versions sont
//     retirées.
//   - 'legacy' : coupe-circuit. La nouvelle facturation est suspendue ; un
//     appel qui déclare `acceptedTotal` est refusé (FACTURATION_INDISPONIBLE)
//     plutôt que facturé moins que le total affiché.
// Le défaut ne change rien au déploiement : tant qu'aucune application ne
// envoie `acceptedTotal`, tout le monde reste en facturation historique.

const MODES = ['legacy', 'accepted_only', 'required'];
const DEFAULT_MODE = 'accepted_only';

async function getBillingMode(db) {
  try {
    const snap = await db.collection('config').doc('billing').get();
    const mode = snap.exists ? snap.data().separateDeliveryFee : null;
    return MODES.includes(mode) ? mode : DEFAULT_MODE;
  } catch (_) {
    return DEFAULT_MODE;
  }
}

// Renvoie 'explicit' (nouvelle facturation, montant accepté à vérifier) ou
// 'legacy' (facturation historique). Lève une HttpsError sinon.
function decideBilling({ mode, acceptedTotal, HttpsError }) {
  const declared = acceptedTotal !== undefined && acceptedTotal !== null;
  if (!declared) {
    if (mode === 'required') {
      throw new HttpsError('failed-precondition', 'APP_UPDATE_REQUIRED');
    }
    return 'legacy';
  }
  if (!Number.isSafeInteger(acceptedTotal) || acceptedTotal <= 0) {
    throw new HttpsError('invalid-argument', 'Montant accepté invalide');
  }
  if (mode === 'legacy') {
    throw new HttpsError('failed-precondition', 'FACTURATION_INDISPONIBLE');
  }
  return 'explicit';
}

// Le montant débité doit être EXACTEMENT celui que le client a accepté (ni plus,
// ni moins : le prix présenté est le prix facturé). Format parsé côté Flutter.
function assertAcceptedTotal({ acceptedTotal, totalAmount, HttpsError }) {
  if (acceptedTotal !== totalAmount) {
    throw new HttpsError('failed-precondition', `MONTANT_MODIFIE:${totalAmount}`);
  }
}

module.exports = { MODES, DEFAULT_MODE, getBillingMode, decideBilling, assertAcceptedTotal };
