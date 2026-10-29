'use strict';

// Politique de recharge des livreurs. Le portefeuille d'un nouveau livreur
// vaut 0 FCFA ; sa première recharge doit être d'au moins 1 000 FCFA. Cette
// somme est un solde UTILISABLE (commissions), jamais des frais d'inscription.
//
// « Première recharge » = aucune recharge déjà CRÉDITÉE pour ce compte
// (`credited: true` n'est posé que par le webhook après vérification serveur
// du paiement) : une demande en attente ou échouée ne compte pas.
const DRIVER_FIRST_RECHARGE_MIN = 1000;

async function assertDriverRechargeAllowed({ db, uid, amount, HttpsError }) {
  const driver = await db.collection('livreurs').doc(uid).get();
  if (!driver.exists) {
    throw new HttpsError('failed-precondition', 'Compte livreur introuvable');
  }
  const credited = await db.collection('wallet_transactions')
    .where('userId', '==', uid)
    .where('credited', '==', true)
    .limit(1)
    .get();
  if (credited.empty && amount < DRIVER_FIRST_RECHARGE_MIN) {
    throw new HttpsError(
      'invalid-argument',
      `Première recharge minimale : ${DRIVER_FIRST_RECHARGE_MIN} FCFA (solde utilisable pour vos commissions)`,
    );
  }
}

module.exports = { DRIVER_FIRST_RECHARGE_MIN, assertDriverRechargeAllowed };
