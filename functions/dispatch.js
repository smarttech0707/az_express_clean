'use strict';

// Port Node de FirestoreService.findNearestDriver() (lib/services/firestore_service.dart)
// — même filtrage (isOnline/isOnDelivery/isAvailable/isSuspended/wallet/fraîcheur GPS),
// même tri par distance + top 5, même règle assignation directe (1 livreur) vs
// broadcast (2+) — pour que les commandes créées par AZ IA soient dispatchées
// exactement comme celles créées manuellement. Pas d'expansion progressive du
// rayon ici (ça n'existe côté Dart que sur refus d'un livreur, pas à la création).

const STALE_MINUTES     = 3;
const DEFAULT_RADIUS_KM = 2.0;
const EARTH_RADIUS_M    = 6371000;

function haversineMeters(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Même règle que FirestoreService.calculateCommission() : 100 FCFA pour
// 500-999 FCFA, 200 FCFA au-delà — piloté par config/commission si présent.
async function calculateCommission(db, budget) {
  let basic = 100, standard = 200, threshold = 1000;
  try {
    const doc = await db.collection('config').doc('commission').get();
    if (doc.exists) {
      const d = doc.data();
      if (typeof d.commissionBasic === 'number')    basic     = d.commissionBasic;
      if (typeof d.commissionStandard === 'number') standard  = d.commissionStandard;
      if (typeof d.threshold === 'number')          threshold = d.threshold;
    }
  } catch (_) { /* garder les valeurs par défaut */ }
  return budget < threshold ? basic : standard;
}

// Retourne { dispatched: boolean, mode: 'assigned'|'broadcast'|'none' }
async function dispatchOrder(db, admin, { orderId, lat, lng, budget = 0, radiusKm = DEFAULT_RADIUS_KM }) {
  const commission = await calculateCommission(db, budget);
  const staleMs     = Date.now() - STALE_MINUTES * 60 * 1000;

  const snap = await db.collection('livreurs').where('isOnline', '==', true).get();

  const nearby = [];
  snap.docs.forEach((doc) => {
    const d = doc.data();
    if (d.isOnDelivery === true)  return;
    if (d.isAvailable === false)  return;
    if (d.isSuspended === true)   return;
    if (d.pendingOrderId === orderId) return;
    const wallet = Number(d.wallet || 0);
    if (wallet < commission) return;
    const ua = d.updatedAt;
    if (ua && typeof ua.toMillis === 'function' && ua.toMillis() < staleMs) return;

    const dLat = Number(d.lat || 0);
    const dLng = Number(d.lng || 0);
    if (!dLat || !dLng) return;
    const dist = haversineMeters(lat, lng, dLat, dLng);
    if (dist > radiusKm * 1000) return;

    nearby.push({ id: doc.id, dist });
  });

  if (nearby.length === 0) {
    return { dispatched: false, mode: 'none' };
  }

  nearby.sort((a, b) => a.dist - b.dist);
  const ids      = nearby.slice(0, 5).map((r) => r.id);
  const orderRef = db.collection('orders').doc(orderId);

  // Verrouillage transactionnel (Prompt 26) : ne réattribue que si la
  // commande est encore 'pending' au moment de l'écriture — protège contre
  // un appel concurrent de dispatchOrder() pour la même commande (même
  // principe que acceptOrder() côté Dart, qui vérifie déjà le statut dans sa
  // propre transaction avant d'accepter). Si un autre appel a déjà
  // assigné/diffusé la commande entre-temps, cette attribution est
  // abandonnée silencieusement — c'est le comportement correct en cas de
  // course, pas une erreur à remonter à l'appelant.
  const result = await db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) {
      return { dispatched: false, mode: 'none' };
    }
    if (orderSnap.data().status !== 'pending') {
      return { dispatched: false, mode: 'already_assigned' };
    }

    if (ids.length === 1) {
      tx.update(orderRef, { driverId: ids[0], status: 'assigned' });
      return { dispatched: true, mode: 'assigned' };
    }

    tx.update(orderRef, {
      status:            'broadcast',
      notifiedDriverIds: admin.firestore.FieldValue.arrayUnion(...ids),
    });
    return { dispatched: true, mode: 'broadcast', ids };
  });

  // Le marquage pendingOrderId sur chaque livreur reste hors transaction :
  // ce sont des documents distincts de orders/{id}, pas nécessaires à
  // l'atomicité recherchée ici (protéger la commande contre une double
  // attribution) — le pire cas résiduel (pendingOrderId orphelin) est déjà
  // nettoyé par declineOrder()/acceptOrder()/autoExpireOrders().
  if (result.dispatched && result.mode === 'broadcast') {
    const batch = db.batch();
    result.ids.forEach((id) => {
      batch.update(db.collection('livreurs').doc(id), { pendingOrderId: orderId });
    });
    await batch.commit();
  }

  return { dispatched: result.dispatched, mode: result.mode };
}

module.exports = { dispatchOrder, calculateCommission, haversineMeters };
