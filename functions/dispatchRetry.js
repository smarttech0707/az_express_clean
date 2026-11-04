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

const { requeueUnansweredAssignment } = require('./assignedTimeout');

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
  // Commande partenaire v2 : la file commence à l'ACCEPTATION du partenaire (les paliers 30 s/90 s... et l'abandon à 9 min
  // se comptent depuis ce moment, pas depuis la création).
  const accepted = order.amountsVersion === 2 ? millisOf(order.partnerAcceptedAtMs) : null;
  return Math.max(created || 0, requeued || 0, accepted || 0);
}

// Mission 7C-2 — commandes Restaurant/Boulangerie v2 PRÉPARÉES ou PRÊTES : la recherche d'un livreur ne s'arrête plus à
// 9 minutes (l'expiration ne les annule jamais, une commande bloquée restait sans issue). Phase 2 BORNÉE, après l'échelle
// initiale : au plus PHASE2_MAX_ATTEMPTS essais supplémentaires espacés d'au moins PHASE2_GAP_MS, toujours au rayon maximal et
// par élargissement (uniquement de NOUVEAUX livreurs, jamais de rappel ni de remplacement), dans une fenêtre absolue de
// PARTNER_WINDOW_MS depuis l'acceptation du partenaire et au plus MAX_LIFETIME_ATTEMPTS essais cumulés par commande, y compris
// après remises en file (compteurs conservés dans le bail, pas remis à zéro par une nouvelle file). Fin de fenêtre ou plafond :
// alerte administrative unique (onExhausted), aucune annulation ni remboursement automatique.
const PHASE2_MAX_ATTEMPTS = 8;
const PHASE2_GAP_MS = 3 * 60 * 1000;
const PARTNER_WINDOW_MS = 45 * 60 * 1000;
const MAX_LIFETIME_ATTEMPTS = 20;
const PREPARING = Object.freeze(['preparing', 'ready']);

const isPreparedPartnerOrder = (order) => order.amountsVersion === 2 && PREPARING.includes(order.sellerStatus)
  && Number(order.partnerAcceptedAtMs) > 0;

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
    if (order.amountsVersion === 2 && !order.partnerAcceptedAtMs) return { reserved: false, reason: 'awaiting_partner' };

    const queued = queuedAtMs(order);
    if (queued == null) return { reserved: false, reason: 'no_timestamp' };
    const ageMs = nowMs - queued;
    const prepared = isPreparedPartnerOrder(order);
    if (ageMs > GIVE_UP_AGE_MS && !prepared) return { reserved: false, reason: 'too_old' };

    const retrySnap = await tx.get(retryRef);
    const prev = retrySnap.exists ? retrySnap.data() : null;
    let lease = prev;
    // Nouvelle mise en file (refus / libération) : l'échelle repart de zéro, mais les compteurs cumulés sont conservés.
    if (lease && lease.queuedAtMs !== queued) lease = null;
    if (lease && lease.stopped) return { reserved: false, reason: 'stopped' };
    const lifetime = Number(prev?.lifetimeAttempts || 0);
    const phase2Done = Number(prev?.phase2Attempts || 0);

    if (prepared) {
      if (nowMs - Number(order.partnerAcceptedAtMs) > PARTNER_WINDOW_MS) return { reserved: false, reason: 'window_closed', exhausted: true };
      if (lifetime >= MAX_LIFETIME_ATTEMPTS) return { reserved: false, reason: 'attempts_exhausted', exhausted: true };
    }

    // Phase 2 : commande préparée en file depuis plus longtemps que l'échelle initiale.
    if (prepared && ageMs > GIVE_UP_AGE_MS) {
      if (phase2Done >= PHASE2_MAX_ATTEMPTS) return { reserved: false, reason: 'phase2_exhausted', exhausted: true };
      if (nowMs - Number(prev?.lastAttemptAtMs || 0) < PHASE2_GAP_MS) return { reserved: false, reason: 'gap' };
      tx.set(retryRef, {
        orderId: orderRef.id, queuedAtMs: queued, attempts: Number(lease?.attempts || 0), lastAttemptAtMs: nowMs, stopped: false,
        lifetimeAttempts: lifetime + 1, phase2Attempts: phase2Done + 1,
      });
      return { reserved: true, order, radiusKm: STAGES[STAGES.length - 1].radiusKm, attempt: lifetime + 1, expand: broadcast, phase: 2 };
    }

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
      lifetimeAttempts: lifetime + 1, phase2Attempts: phase2Done,
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

// Sélection des commandes v2 préparées à relancer. Requête DÉDIÉE (le lot général de 50 ne doit pas être occupé par de vieilles
// commandes bloquées) et BORNÉE dans le temps : acceptation datant de moins de la fenêtre absolue, donc une commande dont la
// fenêtre est close sort d'elle-même de la requête. Cette requête (égalité + in + intervalle sur trois champs différents)
// exige l'index composite amountsVersion/status/partnerAcceptedAtMs (firestore.indexes.json). Index absent (non déployé) :
// repli sur la requête sans intervalle, qui n'a besoin d'aucun index composite.
async function loadPreparedPartnerOrders(db, nowMs, logger) {
  const base = () => db.collection('orders').where('amountsVersion', '==', 2).where('status', 'in', ['pending', 'broadcast']);
  let snap;
  try {
    snap = await base().where('partnerAcceptedAtMs', '>=', nowMs - PARTNER_WINDOW_MS).limit(BATCH_LIMIT).get();
  } catch (err) {
    logger.error(`[dispatchRetry] requête v2 bornée indisponible (index ?) : ${err.message} — repli sans intervalle`);
    snap = await base().limit(BATCH_LIMIT).get();
  }
  return snap.docs.filter((d) => isPreparedPartnerOrder(d.data()));
}

// Livreurs assignés qui ne répondent pas (v2 préparées) : remise en file, voir assignedTimeout.js.
async function requeueSilentAssignments(db, admin, nowMs, summary, logger, onExhausted) {
  let docs;
  try {
    const snap = await db.collection('orders').where('amountsVersion', '==', 2).where('status', '==', 'assigned').limit(BATCH_LIMIT).get();
    docs = snap.docs.filter((d) => PREPARING.includes(d.data().sellerStatus));
  } catch (err) {
    summary.errors += 1;
    logger.error(`[dispatchRetry] lecture des assignations impossible : ${err.message}`);
    return;
  }
  for (const doc of docs) {
    try {
      const r = await requeueUnansweredAssignment({
        db, admin, orderId: doc.id, nowMs, windowMs: PARTNER_WINDOW_MS, maxLifetimeAttempts: MAX_LIFETIME_ATTEMPTS, retryCollection: COLLECTION,
      });
      if (r.requeued) summary.requeued += 1;
      else if (r.exhausted && typeof onExhausted === 'function') await Promise.resolve(onExhausted(doc.id, doc.data(), r.reason)).catch(() => {});
    } catch (err) {
      summary.errors += 1;
      logger.error(`[dispatchRetry] assignation orderId=${doc.id} : ${err.message}`);
    }
  }
}

// Passe unique, appelée une fois par minute. Ne lève jamais : un échec ici ne
// doit pas empêcher l'expiration / le remboursement qui s'exécutent avant.
async function retryPendingDispatch({
  db, admin, dispatchOrder, DispatchError, observe, onExhausted, nowMs = Date.now(), logger = console,
}) {
  const summary = { scanned: 0, attempted: 0, dispatched: 0, skipped: 0, errors: 0, requeued: 0 };
  // Livreurs assignés silencieux d'abord : la commande remise en file est reprise par la passe de la minute suivante.
  await requeueSilentAssignments(db, admin, nowMs, summary, logger, onExhausted);
  let docs;
  try {
    const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - STAGES[0].minAgeMs);
    // Plus récentes d'abord : de vieilles commandes restées bloquées ne peuvent pas occuper les 50 places devant les nouvelles
    // (l'expiration retire de toute façon les commandes historiques ; les v2 préparées ont leur propre requête ci-dessous).
    // Index existant : orders (status, createdAt DESCENDING).
    const snap = await db.collection('orders')
      .where('status', 'in', ['pending', 'broadcast'])
      .where('createdAt', '<=', cutoff)
      .orderBy('createdAt', 'desc')
      .limit(BATCH_LIMIT)
      .get();
    docs = snap.docs;
  } catch (err) {
    logger.error(`[dispatchRetry] lecture impossible : ${err.message}`);
    return { ...summary, errors: 1 };
  }
  try {
    const seen = new Set(docs.map((d) => d.id));
    for (const d of await loadPreparedPartnerOrders(db, nowMs, logger)) if (!seen.has(d.id)) docs.push(d);
  } catch (err) {
    summary.errors += 1;
    logger.error(`[dispatchRetry] lecture des v2 préparées impossible : ${err.message}`);
  }

  for (const doc of docs) {
    summary.scanned += 1;
    const orderRef = db.collection('orders').doc(doc.id);
    const retryRef = db.collection(COLLECTION).doc(doc.id);
    try {
      const slot = await reserveAttempt(db, { orderRef, retryRef, nowMs });
      if (!slot.reserved) {
        summary.skipped += 1;
        if (slot.exhausted && typeof onExhausted === 'function') await Promise.resolve(onExhausted(doc.id, doc.data(), slot.reason)).catch(() => {});
        continue;
      }
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
  if (summary.attempted > 0 || summary.errors > 0 || summary.requeued > 0) {
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
  PHASE2_MAX_ATTEMPTS, PHASE2_GAP_MS, PARTNER_WINDOW_MS, MAX_LIFETIME_ATTEMPTS, isPreparedPartnerOrder,
};
