'use strict';

// Reprise côté serveur des commandes restées `pending` (I2, audit du 2026-10-30).
//
// Jusqu'ici le dispatch n'était déclenché que par l'application du client
// (création, puis timers 30 s / 60 s de l'écran de suivi). Application fermée,
// réseau coupé ou aucun livreur éligible au premier essai : la commande payée
// restait `pending` jusqu'à l'expiration (10 min) sans nouvelle tentative.
//
// Choix : une passe exécutée par le scheduler `autoExpireOrders` existant
// (déjà une fois par minute) plutôt qu'un trigger `onCreate` :
//  - un `onCreate` doublerait systématiquement l'appel du client (2 dispatchs
//    par commande), n'aiderait pas quand aucun livreur n'est en ligne à la
//    création, et ajouterait une fonction (quota Cloud Run déjà serré) ;
//  - la passe ne traite QUE les commandes encore `pending` après le premier
//    essai, donc le coût est nul pour une commande normale ;
//  - aucune nouvelle fonction déployée, aucune requête supplémentaire hors
//    d'un seul `get` borné par minute.
//
// Garanties : la commande est relue `pending` dans une transaction de
// réservation (bail) avant chaque essai ; `dispatchOrder` revérifie lui-même
// `pending` dans sa propre transaction (aucun double dispatch, aucune double
// attribution). Cette passe ne touche à AUCUN wallet : la commission reste
// prélevée une seule fois, à l'acceptation. Nombre d'essais borné par
// commande ; le bail vit dans `order_dispatch_retries/{orderId}` (jamais sur
// `orders`, pour ne déclencher aucun trigger de commande).

const COLLECTION = 'order_dispatch_retries';
// Essai n° k autorisé quand la commande est en file depuis au moins minAgeMs.
// Rayons identiques à ceux de l'application (2 km, 5 km, puis 30 km).
const STAGES = Object.freeze([
  { minAgeMs: 30 * 1000, radiusKm: 2 },
  { minAgeMs: 90 * 1000, radiusKm: 5 },
  { minAgeMs: 150 * 1000, radiusKm: 30 },
  { minAgeMs: 300 * 1000, radiusKm: 30 },
  { minAgeMs: 480 * 1000, radiusKm: 30 },
]);
const MIN_GAP_MS = 45 * 1000;          // deux essais d'une même commande : jamais plus proches
const GIVE_UP_AGE_MS = 9 * 60 * 1000;  // l'expiration (10 min) prend le relais
const BATCH_LIMIT = 50;
// Commande déjà diffusée (`broadcast`) : on laisse aux livreurs sollicités le temps de répondre
// avant d'élargir, et on n'élargit jamais au rayon initial (déjà couvert).
const BROADCAST_WAIT_MS = 60 * 1000;

function millisOf(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

// Instant de mise en file : création, ou dernière remise en file (refus /
// libération par un livreur).
function queuedAtMs(order) {
  const created = millisOf(order.createdAt);
  const requeued = millisOf(order.requeuedAt);
  if (created == null && requeued == null) return null;
  return Math.max(created || 0, requeued || 0);
}

// Réserve (ou refuse) le prochain essai. Une seule exécution gagne : la
// lecture de `orders/{id}` et du bail dans la même transaction fait rejouer
// la perdante sur l'état à jour.
async function reserveAttempt(db, { orderRef, retryRef, nowMs }) {
  return db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) return { reserved: false, reason: 'missing' };
    const order = orderSnap.data();
    const broadcast = order.status === 'broadcast';
    if ((order.status !== 'pending' && !broadcast) || order.driverId) return { reserved: false, reason: 'not_pending' };

    const queued = queuedAtMs(order);
    if (queued == null) return { reserved: false, reason: 'no_timestamp' };
    const ageMs = nowMs - queued;
    if (ageMs > GIVE_UP_AGE_MS) return { reserved: false, reason: 'too_old' };

    const retrySnap = await tx.get(retryRef);
    let lease = retrySnap.exists ? retrySnap.data() : null;
    // Nouvelle mise en file (refus / libération) : on repart de zéro.
    if (lease && lease.queuedAtMs !== queued) lease = null;
    if (lease && lease.stopped) return { reserved: false, reason: 'stopped' };

    const attempts = lease ? Number(lease.attempts || 0) : 0;
    // Une diffusion a déjà eu lieu au rayon initial : l'élargissement démarre au palier suivant.
    const base = broadcast ? 1 : 0;
    const stageIdx = attempts + base;
    if (stageIdx >= STAGES.length) return { reserved: false, reason: 'max_attempts' };
    if (ageMs < STAGES[stageIdx].minAgeMs) return { reserved: false, reason: 'too_early' };
    if (broadcast) {
      const lastDispatch = Math.max(Number(order.lastDispatchAtMs || 0), Number(lease?.lastAttemptAtMs || 0), queued);
      if (nowMs - lastDispatch < BROADCAST_WAIT_MS) return { reserved: false, reason: 'broadcast_wait' };
    }
    if (lease && nowMs - Number(lease.lastAttemptAtMs || 0) < MIN_GAP_MS) {
      return { reserved: false, reason: 'gap' };
    }

    tx.set(retryRef, {
      orderId: orderRef.id, queuedAtMs: queued, attempts: attempts + 1,
      lastAttemptAtMs: nowMs, stopped: false,
    });
    // Scheduler en retard : le rayon suit l'ÂGE de la commande, pas seulement le
    // numéro d'essai (un premier essai tardif ne repart pas de 2 km).
    let ageStage = 0;
    STAGES.forEach((stage, i) => { if (ageMs >= stage.minAgeMs) ageStage = i; });
    const radiusKm = STAGES[Math.max(stageIdx, ageStage)].radiusKm;
    return { reserved: true, order, radiusKm, attempt: attempts + 1, expand: broadcast };
  });
}

async function stopRetries(db, retryRef, reason) {
  try {
    await retryRef.set({ stopped: true, stoppedReason: reason }, { merge: true });
  } catch (_) { /* non bloquant : le plafond d'essais borne de toute façon la reprise */ }
}

// Passe unique, appelée une fois par minute. Ne lève jamais : un échec ici ne
// doit pas empêcher l'expiration / le remboursement qui s'exécutent avant.
async function retryPendingDispatch({
  db, admin, dispatchOrder, DispatchError, observe, nowMs = Date.now(), logger = console,
}) {
  const summary = { scanned: 0, attempted: 0, dispatched: 0, skipped: 0, errors: 0 };
  let docs;
  try {
    const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - STAGES[0].minAgeMs);
    const snap = await db.collection('orders')
      .where('status', 'in', ['pending', 'broadcast'])
      .where('createdAt', '<=', cutoff)
      .limit(BATCH_LIMIT)
      .get();
    docs = snap.docs;
  } catch (err) {
    logger.error(`[dispatchRetry] lecture impossible : ${err.message}`);
    return { ...summary, errors: 1 };
  }

  for (const doc of docs) {
    summary.scanned += 1;
    const orderRef = db.collection('orders').doc(doc.id);
    const retryRef = db.collection(COLLECTION).doc(doc.id);
    try {
      const slot = await reserveAttempt(db, { orderRef, retryRef, nowMs });
      if (!slot.reserved) { summary.skipped += 1; continue; }
      summary.attempted += 1;
      const order = slot.order;
      if (typeof observe === 'function') await Promise.resolve(observe(doc.id, order)).catch(() => {});
      try {
        const result = await dispatchOrder(db, admin, {
          orderId: doc.id,
          lat: Number(order.latitude ?? order.deliveryLatitude ?? 0),
          lng: Number(order.longitude ?? order.deliveryLongitude ?? 0),
          budget: Number(order.budget || 0),
          pickupCityId: order.pickupCityId,
          cityResolutionStatus: order.cityResolutionStatus,
          radiusKm: slot.radiusKm,
          excludedDriverIds: Array.isArray(order.excludedDriverIds) ? order.excludedDriverIds : [],
          ...(slot.expand ? { expandBroadcast: true } : {}),
        });
        if (result && result.dispatched === true) summary.dispatched += 1;
      } catch (err) {
        if (DispatchError && err instanceof DispatchError) {
          // Erreur de données de la commande (ville, coordonnées) : inutile de réessayer.
          await stopRetries(db, retryRef, err.code || 'dispatch_error');
        } else {
          summary.errors += 1;
          logger.error(`[dispatchRetry] orderId=${doc.id} essai ${slot.attempt} : ${err.message}`);
        }
      }
    } catch (err) {
      summary.errors += 1;
      logger.error(`[dispatchRetry] orderId=${doc.id} : ${err.message}`);
    }
  }
  if (summary.attempted > 0 || summary.errors > 0) {
    logger.log(`[dispatchRetry] ${JSON.stringify(summary)}`);
  }
  return summary;
}

// Livreurs ajoutés par une mise à jour de diffusion : seuls ceux-là reçoivent la notification
// (transition vers broadcast : tous ; élargissement broadcast → broadcast : les nouveaux).
function newlyNotifiedDriverIds(before, after) {
  if (!after || after.status !== 'broadcast') return [];
  const known = new Set(before && before.status === 'broadcast' && Array.isArray(before.notifiedDriverIds) ? before.notifiedDriverIds : []);
  return (Array.isArray(after.notifiedDriverIds) ? after.notifiedDriverIds : []).filter((id) => !known.has(id));
}

module.exports = {
  newlyNotifiedDriverIds, BROADCAST_WAIT_MS,
  retryPendingDispatch, reserveAttempt, queuedAtMs, STAGES, MIN_GAP_MS, GIVE_UP_AGE_MS, COLLECTION,
};
