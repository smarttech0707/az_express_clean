'use strict';

const { readDriverState, terminalDriverPatch, runLifecycleTransaction } = require('./driverLifecycle');

// Refus d'une mission PROPOSÉE (assigned) ou diffusée (broadcast), avant
// acceptation. Aucune commission n'a été prélevée à ce stade (elle l'est à
// l'acceptation, acceptOrderCF) : aucun remboursement, aucun mouvement de
// wallet. Ce n'est pas un transfert : transferCount n'est pas incrémenté.
//  - assigned à ce livreur : remise en file `pending`, livreur exclu, redispatch ;
//  - broadcast : le livreur est seulement exclu des nouvelles propositions.
// Contrat : { success:true, replay:boolean, recoveryPending?:boolean }.
function buildDeclineLegacyOrder({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, dispatchOrder, DispatchError,
}) {
  return onCall(async (request) => {
    if (!request.auth?.uid ||
        request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const raw = request.data?.orderId;
    if (typeof raw !== 'string' || !raw.trim() || raw.length > 128 || raw.includes('/')) {
      throw new HttpsError('invalid-argument', 'orderId invalide');
    }
    const orderId = raw.trim();
    await checkRateLimit(uid, 'decline_order', 20, 600);

    const orderRef = db.collection('orders').doc(orderId);
    const driverRef = db.collection('livreurs').doc(uid);
    const FieldValue = admin.firestore.FieldValue;
    let outcome;
    let requeued = null;

    await runLifecycleTransaction(db, async (tx) => {
      outcome = null;
      requeued = null;
      const [orderSnap, driverSnap] = await Promise.all([tx.get(orderRef), tx.get(driverRef)]);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      if (!driverSnap.exists) throw new HttpsError('permission-denied', 'Compte livreur introuvable');
      const order = orderSnap.data();
      const excluded = Array.isArray(order.excludedDriverIds) ? order.excludedDriverIds : [];

      if (excluded.includes(uid) && order.driverId !== uid) {
        outcome = { success: true, replay: true };
        return;
      }
      if (order.status === 'assigned' && order.driverId === uid) {
        const state = await readDriverState(tx, db, uid, orderId);
        const patch = terminalDriverPatch(state, orderId, admin);
        if (Object.keys(patch).length) tx.update(driverRef, patch);
        tx.update(orderRef, {
          status: 'pending',
          driverId: FieldValue.delete(),
          notifiedDriverIds: FieldValue.delete(),
          excludedDriverIds: FieldValue.arrayUnion(uid),
          requeuedAt: FieldValue.serverTimestamp(),
          driverHistory: FieldValue.arrayUnion({
            driverId: uid, phase: 'declined', reason: 'declined',
            version: Number(order.driverAssignmentVersion || 1), endedAtMs: Date.now(),
          }),
        });
        outcome = { success: true, replay: false };
        requeued = {
          lat: Number(order.latitude ?? order.deliveryLatitude ?? 0),
          lng: Number(order.longitude ?? order.deliveryLongitude ?? 0),
          budget: Number(order.budget || 0),
          pickupCityId: order.pickupCityId,
          cityResolutionStatus: order.cityResolutionStatus,
          excludedDriverIds: [...new Set([...excluded, uid])],
        };
        return;
      }
      if (order.status === 'broadcast' && !order.driverId) {
        tx.update(orderRef, { excludedDriverIds: FieldValue.arrayUnion(uid) });
        outcome = { success: true, replay: false };
        return;
      }
      throw new HttpsError('failed-precondition',
        ['accepted', 'picked_up'].includes(order.status) && order.driverId === uid
          ? 'Mission déjà acceptée : utilisez « Signaler un problème ».'
          : 'Cette commande ne peut pas être refusée');
    });

    if (outcome.replay) return outcome;
    await logAudit({
      userId: uid, userType: 'driver', action: 'decline_order',
      targetId: orderId, status: 'success', metadata: { phase: 'before_acceptance' },
    });
    if (!requeued) return { ...outcome, recoveryPending: false };

    let dispatched = false;
    try {
      dispatched = (await dispatchOrder(db, admin, { orderId, ...requeued })).dispatched === true;
    } catch (error) {
      if (!(DispatchError && error instanceof DispatchError)) {
        console.error(`[decline] redispatch orderId=${orderId} : ${error.message}`);
      }
    }
    return { ...outcome, recoveryPending: !dispatched };
  });
}

module.exports = { buildDeclineLegacyOrder };
