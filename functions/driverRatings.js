'use strict';

// Note client → moyenne du livreur.
//
// Le client n'a (à raison) aucun droit d'écriture sur `livreurs/{id}` : il note
// la commande (`orders.rating`, autorisé par les règles), et c'est CE module,
// exécuté côté serveur, qui répercute la note dans `avgRating`/`ratingCount`.
// Avant, l'app cliente tentait les deux écritures dans une seule transaction :
// la seconde était refusée par les règles et faisait échouer toute la note.
//
// Aucun montant, aucune commission, aucun statut n'est lu ni modifié ici.

const isValidRating = value =>
  Number.isInteger(value) && value >= 1 && value <= 5;

// Même arrondi (1 décimale) que l'ancien calcul côté client.
function nextAverage(currentAvg, currentCount, rating) {
  const count = (Number.isFinite(currentCount) ? currentCount : 0) + 1;
  const avg = Number.isFinite(currentAvg) ? currentAvg : 0;
  return {
    avgRating: Number(((avg * (count - 1) + rating) / count).toFixed(1)),
    ratingCount: count,
  };
}

// Pré-filtre bon marché sur l'événement, avant toute lecture.
//
// `before` (état de la commande avant la mise à jour) protège les commandes
// notées AVANT ce module : l'ancien client avait déjà incorporé leur note dans
// la moyenne du livreur, sans poser `driverRatingApplied`. Sans cette garde,
// la moindre mise à jour ultérieure d'une telle commande (règlement, revue
// admin…) la recompterait. On n'agit donc que sur la transition
// « pas de note valide → note valide ».
function shouldProcess(after, before) {
  if (before && isValidRating(before.rating)) return false;
  return !!after
    && after.status === 'delivered'
    && typeof after.driverId === 'string' && after.driverId.length > 0
    && after.driverRatingApplied !== true
    && isValidRating(after.rating);
}

/**
 * Applique UNE fois la note d'une commande livrée à son livreur.
 * Idempotent (retry de la fonction, mises à jour répétées de la commande) :
 * le marqueur `driverRatingApplied` est posé dans la même transaction.
 * Une note modifiée après coup n'est jamais recomptée.
 */
async function applyDriverRating({ db, orderId, before }) {
  const orderRef = db.collection('orders').doc(orderId);
  return db.runTransaction(async tx => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) return { applied: false, reason: 'order-missing' };
    const order = orderSnap.data();
    if (!shouldProcess(order, before)) return { applied: false, reason: 'not-eligible' };

    const driverRef = db.collection('livreurs').doc(order.driverId);
    const driverSnap = await tx.get(driverRef);
    if (!driverSnap.exists) return { applied: false, reason: 'driver-missing' };
    const driver = driverSnap.data() || {};

    const next = nextAverage(Number(driver.avgRating), Number(driver.ratingCount), order.rating);
    tx.update(driverRef, next);
    tx.update(orderRef, { driverRatingApplied: true });
    // Valeurs avant/après : seule trace permettant de corriger a posteriori une
    // moyenne (retour arrière de données), la fonction ne gardant aucun historique.
    return {
      applied: true, driverId: order.driverId,
      previous: { avgRating: Number.isFinite(Number(driver.avgRating)) ? Number(driver.avgRating) : 0,
        ratingCount: Number.isFinite(Number(driver.ratingCount)) ? Number(driver.ratingCount) : 0 },
      ...next,
    };
  });
}

module.exports = { isValidRating, nextAverage, shouldProcess, applyDriverRating };
