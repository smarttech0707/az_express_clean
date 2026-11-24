'use strict';

// Dispatch d'une commande Restaurant/Boulangerie v2 APRÈS acceptation du partenaire (Mission 7C-1).
//
// Une commande v2 n'est jamais proposée aux livreurs avant que le partenaire l'ait acceptée (garde centrale dans
// dispatch.js, relue dans la transaction d'attribution). Dès la première acceptation, partnerOrderActionCF appelle cette
// fonction une fois ; si elle ne trouve aucun livreur ou échoue, la reprise serveur (dispatchRetry.js, scheduler existant)
// prend le relais avec le délai compté depuis l'acceptation. Pas de trigger onCreate (double appel, quota Cloud Run).
//
// Ne lève JAMAIS : un échec de dispatch ne doit ni annuler ni retarder l'acceptation du partenaire. Aucun wallet touché.

async function dispatchAcceptedPartnerOrder({ db, admin, dispatchOrder, orderId, logger = console }) {
  const snap = await db.collection('orders').doc(orderId).get();
  if (!snap.exists) return { dispatched: false, mode: 'not_found' };
  const o = snap.data();
  if (o.amountsVersion !== 2 || !o.partnerAcceptedAtMs || o.status !== 'pending' || o.driverId) {
    return { dispatched: false, mode: 'not_eligible' };
  }
  try {
    const result = await dispatchOrder(db, admin, {
      orderId,
      lat: Number(o.latitude ?? o.deliveryLatitude ?? 0),
      lng: Number(o.longitude ?? o.deliveryLongitude ?? 0),
      budget: Number(o.budget || 0),
      pickupCityId: o.pickupCityId,
      cityResolutionStatus: o.cityResolutionStatus,
      excludedDriverIds: Array.isArray(o.excludedDriverIds) ? o.excludedDriverIds : [],
    });
    return { dispatched: result?.dispatched === true, mode: result?.mode || 'none' };
  } catch (err) {
    logger.error(`[partnerDispatch] ${orderId} : ${err.message}`);
    return { dispatched: false, mode: 'error', code: err.code || 'dispatch_error' };
  }
}

module.exports = { dispatchAcceptedPartnerOrder };
