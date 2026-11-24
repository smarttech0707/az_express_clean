'use strict';

// Livreur ASSIGNÉ qui ne répond pas (Mission 7C-2), commandes Restaurant/Boulangerie v2 PRÉPARÉES ou PRÊTES seulement.
//
// Avec un seul livreur éligible, dispatchOrder passe la commande en `assigned` (proposition, pas encore acceptée). Une v2 en
// préparation n'expire plus (orderRefunds.js) : sans ce mécanisme un livreur qui ne répond jamais la bloquerait indéfiniment.
// Au bout de ASSIGNMENT_TIMEOUT_MS sans acceptation, on reprend EXACTEMENT la transition du refus volontaire d'une mission
// proposée (driverDecline.js, branche `assigned`) : statut `pending`, livreur retiré, EXCLU des prochaines propositions,
// `requeuedAt` posé ; la reprise de dispatch (dispatchRetry.js) fait le reste dans ses plafonds et sa fenêtre absolue.
//
// Garanties : tout est relu et décidé DANS la transaction du document de commande. Si le livreur a accepté entre-temps
// (statut `accepted`, commission prélevée par acceptOrderCF), la transaction ne fait rien ; si l'acceptation est écrite pendant
// celle-ci, Firestore rejoue la perdante. Aucune commission n'existe à ce stade (prélevée à l'acceptation) : aucun wallet n'est
// touché, transferCount n'est pas incrémenté, les transferts de livraison (statut `picked_up`) et les commandes historiques
// (amountsVersion absent) ne sont jamais concernés.

const { readDriverState, terminalDriverPatch, runLifecycleTransaction } = require('./driverLifecycle');

const ASSIGNMENT_TIMEOUT_MS = 3 * 60 * 1000;
const PREPARING = Object.freeze(['preparing', 'ready']);

async function requeueUnansweredAssignment({
  db, admin, orderId, nowMs = Date.now(), timeoutMs = ASSIGNMENT_TIMEOUT_MS, windowMs, maxLifetimeAttempts, retryCollection,
}) {
  const FieldValue = admin.firestore.FieldValue;
  const orderRef = db.collection('orders').doc(orderId);
  const retryRef = db.collection(retryCollection).doc(orderId);
  return runLifecycleTransaction(db, async (tx) => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) return { requeued: false, reason: 'missing' };
    const order = orderSnap.data();
    if (order.amountsVersion !== 2 || order.status !== 'assigned' || typeof order.driverId !== 'string' || !order.driverId) {
      return { requeued: false, reason: 'not_assigned' };
    }
    if (order.commissionStatus === 'charged') return { requeued: false, reason: 'already_charged' };
    if (!PREPARING.includes(order.sellerStatus)) return { requeued: false, reason: 'not_prepared' };
    const assignedAt = Number(order.assignedAtMs);
    if (!Number.isFinite(assignedAt) || assignedAt <= 0) return { requeued: false, reason: 'no_timestamp' };
    if (nowMs - assignedAt < timeoutMs) return { requeued: false, reason: 'too_early' };

    // Fenêtre absolue et plafond cumulé : au-delà, la reprise ne relancerait rien ; on ne retire pas l'attribution.
    const accepted = Number(order.partnerAcceptedAtMs);
    if (!Number.isFinite(accepted) || nowMs - accepted > windowMs) return { requeued: false, reason: 'window_closed', exhausted: true };
    const leaseSnap = await tx.get(retryRef);
    const lifetime = leaseSnap.exists ? Number(leaseSnap.data().lifetimeAttempts || 0) : 0;
    if (lifetime >= maxLifetimeAttempts) return { requeued: false, reason: 'attempts_exhausted', exhausted: true };

    const driverId = order.driverId;
    const state = await readDriverState(tx, db, driverId, orderId);
    const patch = terminalDriverPatch(state, orderId, admin);
    if (Object.keys(patch).length) tx.update(db.collection('livreurs').doc(driverId), patch);
    tx.update(orderRef, {
      status: 'pending',
      driverId: FieldValue.delete(),
      notifiedDriverIds: FieldValue.delete(),
      excludedDriverIds: FieldValue.arrayUnion(driverId),
      requeuedAt: FieldValue.serverTimestamp(),
      driverHistory: FieldValue.arrayUnion({
        driverId, phase: 'assignment_timeout', reason: 'no_response',
        version: Number(order.driverAssignmentVersion || 1), endedAtMs: nowMs,
      }),
    });
    return { requeued: true, driverId };
  });
}

module.exports = { requeueUnansweredAssignment, ASSIGNMENT_TIMEOUT_MS };
