'use strict';

const { readDriverState, terminalDriverPatch, runLifecycleTransaction } = require('./driverLifecycle');

// Libération d'une course AVANT récupération du colis (transfert, cas 1).
//
// Le livreur A abandonne une course acceptée mais pas encore récupérée :
//   - aucun gain de livraison pour A ;
//   - sa commission AZ est remboursée UNE fois, du montant réellement prélevé
//     (tracé par acceptOrderCF), et marquée `refunded` dans la même transaction ;
//   - la commande revient `pending` avec le MÊME identifiant, prix, client,
//     destinataire et paiement ; A est exclu des propositions suivantes ;
//   - l'historique garde A (`driverHistory`) ; la version d'affectation est
//     incrémentée, ce qui invalide toute preuve QR/PIN liée à A ;
//   - la nouvelle attribution passe par le dispatch existant : B doit avoir un
//     solde suffisant, et sa commission est prélevée une seule fois quand il
//     accepte (acceptOrderCF).
// Une course avec avance d'achat (shoppingBudget) n'est PAS libérée
// automatiquement : l'avance ne peut pas être réconciliée sans décision métier.

const REASONS = Object.freeze([
  'vehicle_problem', 'emergency', 'too_far', 'customer_unreachable', 'other',
]);
const MAX_TRANSFERS = 2;

function buildReleaseOrderBeforePickup({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  calculateCommission, dispatchOrder, DispatchError,
}) {
  return onCall(async (request) => {
    if (!request.auth?.uid ||
        request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const { orderId: rawOrderId, reason } = request.data || {};
    if (typeof rawOrderId !== 'string' || !rawOrderId.trim() || rawOrderId.length > 128 ||
        rawOrderId.includes('/')) {
      throw new HttpsError('invalid-argument', 'orderId invalide');
    }
    if (!REASONS.includes(reason)) {
      throw new HttpsError('invalid-argument', 'Motif invalide');
    }
    const orderId = rawOrderId.trim();
    await checkRateLimit(uid, 'release_order', 5, 600);

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
      const order = orderSnap.data();

      // Rejeu : déjà libérée par ce livreur, la commande a été remise en file.
      if (order.driverId !== uid && Array.isArray(order.excludedDriverIds) &&
          order.excludedDriverIds.includes(uid) &&
          !['cancelled', 'delivered'].includes(order.status)) {
        outcome = { success: true, replay: true };
        return;
      }
      if (order.driverId !== uid) {
        throw new HttpsError('permission-denied', 'Cette commande ne vous est pas assignée');
      }
      if (order.status !== 'accepted') {
        throw new HttpsError('failed-precondition',
          order.status === 'picked_up'
            ? 'Le colis est déjà récupéré : utilisez la procédure de transfert avec remise.'
            : 'Cette commande ne peut pas être libérée');
      }
      if (order.pickupProofValidatedAt || order.pickedUpAt) {
        throw new HttpsError('failed-precondition', 'Le colis est déjà récupéré');
      }
      if (Number(order.shoppingBudget || 0) > 0) {
        throw new HttpsError('failed-precondition',
          'Cette course comporte une avance d’achat : contactez l’administration (SHOPPING_BUDGET_REVIEW).');
      }
      const transfers = Number(order.transferCount || 0);
      if (transfers >= MAX_TRANSFERS) {
        throw new HttpsError('resource-exhausted',
          'Limite de transferts atteinte : contactez l’administration.');
      }
      if (!driverSnap.exists) throw new HttpsError('permission-denied', 'Compte livreur introuvable');

      // Remboursement de la commission : montant tracé si disponible, sinon
      // règle historique (commandes acceptées avant le suivi serveur).
      const traced = order.commissionStatus === 'charged' &&
        order.commissionPayerId === uid &&
        Number.isSafeInteger(order.commissionAmount) && order.commissionAmount >= 0;
      const legacyCharged = !order.commissionStatus;
      let refund = 0;
      if (traced) refund = order.commissionAmount;
      else if (legacyCharged) refund = await calculateCommission(db, Number(order.budget || 0));
      // commissionStatus 'refunded' (ou autre) : aucun remboursement.

      const state = await readDriverState(tx, db, uid, orderId);
      const wallet = Number(driverSnap.data().wallet || 0);
      const patch = {
        ...terminalDriverPatch(state, orderId, admin),
        ...(refund > 0 ? { wallet: wallet + refund } : {}),
      };
      if (Object.keys(patch).length) tx.update(driverRef, patch);
      if (refund > 0) {
        tx.set(driverRef.collection('wallet_transactions').doc(`commission_refund_${orderId}_${uid}`), {
          type: 'refund', amount: refund, orderId,
          description: 'Remboursement commission — course libérée avant récupération',
          createdAt: FieldValue.serverTimestamp(),
        });
      }

      const version = Number(order.driverAssignmentVersion || 1);
      tx.update(orderRef, {
        status: 'pending',
        driverId: FieldValue.delete(),
        driverAcceptanceSelfie: FieldValue.delete(),
        driverPhotoUrl: FieldValue.delete(),
        acceptedAt: FieldValue.delete(),
        notifiedDriverIds: FieldValue.delete(),
        commissionStatus: 'refunded',
        driverAssignmentVersion: version + 1,
        transferCount: transfers + 1,
        excludedDriverIds: FieldValue.arrayUnion(uid),
        requeuedAt: FieldValue.serverTimestamp(),
        driverHistory: FieldValue.arrayUnion({
          driverId: uid, phase: 'before_pickup', reason, version,
          commissionRefunded: refund, endedAtMs: Date.now(),
        }),
      });
      outcome = { success: true, replay: false, commissionRefunded: refund };
      requeued = {
        lat: Number(order.latitude ?? order.deliveryLatitude ?? 0),
        lng: Number(order.longitude ?? order.deliveryLongitude ?? 0),
        budget: Number(order.budget || 0),
        pickupCityId: order.pickupCityId,
        cityResolutionStatus: order.cityResolutionStatus,
        excludedDriverIds: [...new Set([...(order.excludedDriverIds || []), uid])],
      };
    });

    if (outcome.replay) return outcome;

    await logAudit({
      userId: uid, userType: 'driver', action: 'release_order_before_pickup',
      targetId: orderId, amount: outcome.commissionRefunded || null, status: 'success',
      metadata: { reason, phase: 'before_pickup' },
    });

    // Nouvelle attribution : hors transaction, comme pour la création. Un échec
    // laisse la commande `pending` (aucune perte) ; l'expiration automatique
    // repart de `requeuedAt`.
    let dispatched = false;
    try {
      const result = await dispatchOrder(db, admin, { orderId, ...requeued });
      dispatched = result.dispatched === true;
    } catch (error) {
      if (!(DispatchError && error instanceof DispatchError)) {
        console.error(`[release] redispatch orderId=${orderId} : ${error.message}`);
      }
    }
    return { ...outcome, dispatched, recoveryPending: !dispatched };
  });
}

module.exports = { buildReleaseOrderBeforePickup, REASONS, MAX_TRANSFERS };
