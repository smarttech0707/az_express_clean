'use strict';

const crypto = require('crypto');
const { readDriverState, terminalDriverPatch, runLifecycleTransaction } = require('./driverLifecycle');
const {
  requireProofRollout, makeSecrets, getProofRefs, loadProofForTransaction,
  verifyProofInTransaction, hashToken, hashPin, PROOF_TTL_MS, MAX_PROOF_GENERATIONS,
} = require('./deliveryProofs');
const { captureHandoverPoint } = require('./earningsSettlement');

// Transfert d'une course APRÈS récupération du colis (cas 2).
//
// Le livreur A (responsable) demande un remplaçant B de la même ville. A reste
// responsable de la course, du colis et du cash jusqu'à la remise physique :
//   request         A -> crée delivery_transfers/{orderId_n}, verrou order.activeTransferId
//   accept          B -> premier accepté gagne (transaction) ; B est réservé (isOnDelivery)
//   decline         B -> refus, ou retrait après acceptation (la demande se rouvre)
//   cancel          A -> annule tant que la remise n'a pas eu lieu
//   prepareHandover B -> émet la preuve `handover` (QR + PIN 6 chiffres), liée à A
//   confirmHandover A -> A scanne/saisit le code de B ; échange atomique A -> B
//
// Moteur de preuves réutilisé tel quel (verifyProofInTransaction : TTL, PIN limité
// à 5 essais, usage unique, version d'affectation). Au changement,
// driverAssignmentVersion + 1 invalide d'office la preuve de livraison, les accès
// destinataire (grant.assignmentVersion) et l'état SMS (matches()).
//
// Finances : aucune seconde commission (commissionPayerId/Amount/Status restent
// ceux d'origine), aucun remboursement de A, aucun crédit à B. La course passe en
// `settlementHold` : la livraison ne crédite personne tant que le partage n'est pas
// validé (voir orderActions.js). Aucune distance GPS n'est inventée : seule la
// dernière position connue de A est copiée, marquée non vérifiée.

const REASONS = Object.freeze([
  'vehicle_problem', 'emergency', 'fatigue', 'customer_unreachable', 'other',
]);
const ACTIONS = Object.freeze([
  'request', 'accept', 'decline', 'cancel', 'prepareHandover', 'confirmHandover', 'expire',
]);
const MAX_TRANSFERS = 2;
const MAX_ATTEMPTS = 6;
const MAX_CANDIDATES = 10;
const REQUEST_TTL_MS = 10 * 60 * 1000;
const HANDOVER_TTL_MS = 30 * 60 * 1000;
const OPEN = new Set(['requested', 'accepted']);

const isId = (v) => typeof v === 'string' && v.length > 0 && v.length <= 160 && !v.includes('/');

// Position serveur d'un livreur : lat/lng + date de la dernière mise à jour GPS.
function positionOf(snap) {
  const d = snap && snap.exists ? snap.data() : null;
  if (!d) return null;
  const ts = d.updatedAt;
  return { lat: Number(d.lat), lng: Number(d.lng),
    updatedAtMs: ts && typeof ts.toMillis === 'function' ? ts.toMillis() : NaN };
}

function eligibleDriver(d) {
  return !!d && d.isOnline === true && d.isOnDelivery !== true && d.isAvailable !== false &&
    d.isSuspended !== true && d.deletionRequested !== true;
}

// Expiration d'un transfert (demande ou remise non confirmée à temps) :
//  - le transfert passe 'expired' (la validation tardive du QR/PIN est refusée) ;
//  - B est libéré de sa réservation ;
//  - A reste responsable et le verrou de la commande est levé (nouvelle recherche
//    possible dans la limite de transferts/demandes).
// Idempotent et sûr en concurrence : tout est relu dans la transaction.
async function expireTransfer(db, admin, transferId, now = Date.now()) {
  const FieldValue = admin.firestore.FieldValue;
  const tRef = db.collection('delivery_transfers').doc(transferId);
  let expired = false;
  await runLifecycleTransaction(db, async (tx) => {
    expired = false;
    const tSnap = await tx.get(tRef);
    if (!tSnap.exists) return;
    const t = tSnap.data();
    if (!OPEN.has(t.status) || !(t.expiresAtMs <= now)) return;
    const orderRef = db.collection('orders').doc(t.orderId);
    const orderSnap = await tx.get(orderRef);
    const reserved = t.status === 'accepted' && isId(t.toDriverId)
      ? await readDriverState(tx, db, t.toDriverId, t.orderId) : null;
    tx.update(tRef, { status: 'expired', closedAtMs: now });
    if (reserved) {
      const patch = terminalDriverPatch(reserved, t.orderId, admin);
      if (Object.keys(patch).length) tx.update(reserved.ref, patch);
    }
    if (orderSnap.exists && orderSnap.data().activeTransferId === transferId) {
      tx.update(orderRef, { activeTransferId: FieldValue.delete() });
    }
    expired = true;
  });
  return expired;
}

// Balayage planifié : libère B même si personne n'ouvre l'application.
async function expireDueTransfers(db, admin, now = Date.now()) {
  let expired = 0;
  for (const status of ['accepted', 'requested']) {
    const snap = await db.collection('delivery_transfers').where('status', '==', status).limit(200).get();
    for (const doc of snap.docs) {
      if (!(doc.data().expiresAtMs <= now)) continue;
      if (await expireTransfer(db, admin, doc.id, now)) expired++;
    }
  }
  return { expired };
}

function buildDeliveryTransfer({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, deliveryProofPepper, notify,
}) {
  const options = deliveryProofPepper ? { secrets: [deliveryProofPepper] } : {};
  const FieldValue = admin.firestore.FieldValue;
  const safeNotify = async (args) => {
    if (typeof notify !== 'function') return;
    try { await notify(args); } catch (e) { console.error(`[transfer] notify : ${e.message}`); }
  };
  const orderRef = (id) => db.collection('orders').doc(id);
  const driverRef = (id) => db.collection('livreurs').doc(id);
  const transferRef = (id) => db.collection('delivery_transfers').doc(id);

  async function doRequest(uid, data) {
    const { orderId, reason } = data;
    if (!isId(orderId)) throw new HttpsError('invalid-argument', 'orderId invalide');
    if (!REASONS.includes(reason)) throw new HttpsError('invalid-argument', 'Motif invalide');

    // Candidats : hors transaction (requête) ; revérifiés à l'acceptation.
    const preOrder = await orderRef(orderId).get();
    const preDriver = await driverRef(uid).get();
    if (!preOrder.exists) throw new HttpsError('not-found', 'Commande introuvable');
    if (!preDriver.exists) throw new HttpsError('permission-denied', 'Compte livreur introuvable');
    const cityId = preDriver.data().currentCityId || preOrder.data().pickupCityId;
    if (typeof cityId !== 'string' || !cityId) {
      throw new HttpsError('failed-precondition', 'Ville du livreur indéterminée');
    }
    const online = await db.collection('livreurs')
      .where('isOnline', '==', true).where('currentCityId', '==', cityId).limit(100).get();
    const excluded = new Set([uid, ...(preOrder.data().excludedDriverIds || []),
      ...(preOrder.data().driverHistory || []).map((h) => h.driverId)]);
    const candidateIds = online.docs
      .filter((doc) => !excluded.has(doc.id) && eligibleDriver(doc.data()))
      .slice(0, MAX_CANDIDATES).map((doc) => doc.id);

    let result;
    await runLifecycleTransaction(db, async (tx) => {
      result = null;
      const orderSnap = await tx.get(orderRef(orderId));
      const driverSnap = await tx.get(driverRef(uid));
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();
      if (order.driverId !== uid) throw new HttpsError('permission-denied', 'Cette commande ne vous est pas assignée');
      if (order.status !== 'picked_up') {
        throw new HttpsError('failed-precondition', order.status === 'accepted'
          ? 'Le colis n’est pas encore récupéré : utilisez « libérer la course ».'
          : 'Cette commande ne peut pas être transférée');
      }
      if (Number(order.shoppingBudget || 0) > 0) {
        throw new HttpsError('failed-precondition',
          'Cette course comporte une avance d’achat : contactez l’administration (SHOPPING_BUDGET_REVIEW).');
      }
      // Marketplace / boutique : `budget` y est le prix du produit, déjà versé au
      // vendeur — ce n'est pas un gain de livraison partageable.
      if (['seller', 'boutique'].includes(order.sellerType)) {
        throw new HttpsError('failed-precondition',
          'Commande marketplace/boutique : contactez l’administration (PARTNER_ORDER_REVIEW).');
      }
      if (Number(order.transferCount || 0) >= MAX_TRANSFERS) {
        throw new HttpsError('resource-exhausted', 'Limite de transferts atteinte : contactez l’administration.');
      }
      const attempts = Number(order.transferAttempts || 0);
      let lockedByExpired = null;
      let expiredB = null;
      if (order.activeTransferId) {
        const activeSnap = await tx.get(transferRef(order.activeTransferId));
        const active = activeSnap.exists ? activeSnap.data() : null;
        if (active && OPEN.has(active.status) && active.expiresAtMs > Date.now()) {
          if (active.fromDriverId === uid && active.status === 'requested') {
            result = { success: true, replay: true, transferId: order.activeTransferId };
            return;
          }
          throw new HttpsError('failed-precondition', 'Un transfert est déjà en cours pour cette commande');
        }
        if (active) {
          lockedByExpired = { id: order.activeTransferId, ...active };
          if (active.status === 'accepted' && isId(active.toDriverId)) {
            expiredB = await readDriverState(tx, db, active.toDriverId, orderId);
          }
        }
      }
      if (attempts >= MAX_ATTEMPTS) {
        throw new HttpsError('resource-exhausted', 'Trop de demandes de transfert : contactez l’administration.');
      }
      if (candidateIds.length === 0) {
        throw new HttpsError('failed-precondition', 'Aucun livreur disponible dans votre ville pour le moment');
      }
      const now = Date.now();
      if (lockedByExpired) {
        tx.update(transferRef(lockedByExpired.id), { status: 'expired', closedAtMs: now });
        if (expiredB) {
          const patch = terminalDriverPatch(expiredB, orderId, admin);
          if (Object.keys(patch).length) tx.update(expiredB.ref, patch);
        }
      }
      const transferId = `${orderId}_${attempts + 1}`;
      const a = driverSnap.exists ? driverSnap.data() : {};
      const hasPos = Number.isFinite(Number(a.lat)) && Number.isFinite(Number(a.lng)) && (a.lat || a.lng);
      tx.set(transferRef(transferId), {
        orderId, fromDriverId: uid, toDriverId: null, status: 'requested', reason,
        cityId, candidateIds, declinedBy: [], attempt: attempts + 1,
        assignmentVersion: Number(order.driverAssignmentVersion || 1),
        createdAtMs: now, expiresAtMs: now + REQUEST_TTL_MS,
        // Dernière position connue de A, NON vérifiée : base du futur partage,
        // jamais une distance déjà calculée.
        fromDriverLastKnown: hasPos
          ? { lat: Number(a.lat), lng: Number(a.lng), source: 'driver_last_known', verified: false } : null,
      });
      tx.update(orderRef(orderId), { activeTransferId: transferId, transferAttempts: attempts + 1 });
      result = { success: true, replay: false, transferId, candidates: candidateIds.length };
    });
    if (!result.replay) {
      await logAudit({ userId: uid, userType: 'driver', action: 'delivery_transfer_request',
        targetId: orderId, status: 'success', metadata: { transferId: result.transferId, reason } });
      await safeNotify({ collection: 'livreurs', ids: candidateIds, event: 'transfer_requested',
        orderId, transferId: result.transferId });
    }
    return result;
  }

  async function doAccept(uid, transferId) {
    let result;
    let orderId;
    await runLifecycleTransaction(db, async (tx) => {
      result = null;
      const tSnap = await tx.get(transferRef(transferId));
      if (!tSnap.exists) throw new HttpsError('not-found', 'Transfert introuvable');
      const t = tSnap.data();
      orderId = t.orderId;
      const orderSnap = await tx.get(orderRef(t.orderId));
      const bSnap = await tx.get(driverRef(uid));
      if (t.status === 'accepted' && t.toDriverId === uid) { result = { success: true, replay: true }; return; }
      if (!bSnap.exists) throw new HttpsError('permission-denied', 'Compte livreur introuvable');
      const order = orderSnap.exists ? orderSnap.data() : {};
      if (t.status !== 'requested') throw new HttpsError('failed-precondition', 'Ce transfert n’est plus disponible');
      if (t.expiresAtMs <= Date.now()) throw new HttpsError('failed-precondition', 'Cette demande a expiré');
      if (t.fromDriverId === uid || !t.candidateIds.includes(uid) || (t.declinedBy || []).includes(uid)) {
        throw new HttpsError('permission-denied', 'Cette demande ne vous est pas destinée');
      }
      if (order.status !== 'picked_up' || order.driverId !== t.fromDriverId ||
          order.activeTransferId !== transferId ||
          Number(order.driverAssignmentVersion || 1) !== t.assignmentVersion) {
        throw new HttpsError('failed-precondition', 'La commande a changé : transfert impossible');
      }
      const b = bSnap.data();
      if (b.currentCityId !== t.cityId) {
        throw new HttpsError('failed-precondition', 'Vous n’êtes pas dans la ville de la mission');
      }
      if (!eligibleDriver(b)) throw new HttpsError('failed-precondition', 'Vous n’êtes pas disponible');
      const state = await readDriverState(tx, db, uid, orderId);
      if (state.active > 0) throw new HttpsError('failed-precondition', 'Vous avez déjà une livraison en cours.');
      const now = Date.now();
      tx.update(transferRef(transferId), {
        status: 'accepted', toDriverId: uid, acceptedAtMs: now, expiresAtMs: now + HANDOVER_TTL_MS,
      });
      tx.update(driverRef(uid), { isOnDelivery: true, pendingOrderId: orderId });
      result = { success: true, replay: false, expiresAtMs: now + HANDOVER_TTL_MS };
    });
    if (!result.replay) {
      await logAudit({ userId: uid, userType: 'driver', action: 'delivery_transfer_accept',
        targetId: orderId, status: 'success', metadata: { transferId } });
    }
    return result;
  }

  async function doDeclineOrCancel(uid, action, transferId) {
    let result;
    let orderId;
    await runLifecycleTransaction(db, async (tx) => {
      result = null;
      const tSnap = await tx.get(transferRef(transferId));
      if (!tSnap.exists) throw new HttpsError('not-found', 'Transfert introuvable');
      const t = tSnap.data();
      orderId = t.orderId;
      const isFrom = t.fromDriverId === uid;
      if (action === 'cancel' && !isFrom) throw new HttpsError('permission-denied', 'Action non autorisée');
      if (action === 'decline' && (isFrom || !t.candidateIds.includes(uid))) {
        throw new HttpsError('permission-denied', 'Action non autorisée');
      }
      if (!OPEN.has(t.status)) { result = { success: true, replay: true }; return; }
      if (action === 'decline' && t.status === 'accepted' && t.toDriverId !== uid) {
        throw new HttpsError('permission-denied', 'Action non autorisée');
      }
      const orderSnap = await tx.get(orderRef(orderId));
      const reserved = t.status === 'accepted' && isId(t.toDriverId)
        ? await readDriverState(tx, db, t.toDriverId, orderId) : null;
      const now = Date.now();
      const release = () => {
        if (!reserved) return;
        const patch = terminalDriverPatch(reserved, orderId, admin);
        if (Object.keys(patch).length) tx.update(reserved.ref, patch);
      };
      const unlock = () => {
        if (orderSnap.exists && orderSnap.data().activeTransferId === transferId) {
          tx.update(orderRef(orderId), { activeTransferId: FieldValue.delete() });
        }
      };
      if (action === 'cancel') {
        tx.update(transferRef(transferId), { status: 'cancelled', closedAtMs: now });
        release(); unlock();
      } else {
        const declinedBy = [...new Set([...(t.declinedBy || []), uid])];
        const remaining = t.candidateIds.filter((id) => !declinedBy.includes(id));
        if (remaining.length === 0) {
          tx.update(transferRef(transferId), { status: 'declined', declinedBy, closedAtMs: now });
          release(); unlock();
        } else {
          // Retrait de B après acceptation : la demande se rouvre pour les autres.
          tx.update(transferRef(transferId), {
            declinedBy,
            ...(t.status === 'accepted'
              ? { status: 'requested', toDriverId: null, expiresAtMs: now + REQUEST_TTL_MS } : {}),
          });
          release();
        }
      }
      result = { success: true, replay: false };
    });
    if (!result.replay) {
      await logAudit({ userId: uid, userType: 'driver', action: `delivery_transfer_${action}`,
        targetId: orderId, status: 'success', metadata: { transferId } });
    }
    return result;
  }

  async function doPrepareHandover(uid, transferId) {
    requireProofRollout(HttpsError);
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
    let issued;
    await runLifecycleTransaction(db, async (tx) => {
      const tSnap = await tx.get(transferRef(transferId));
      if (!tSnap.exists) throw new HttpsError('not-found', 'Transfert introuvable');
      const t = tSnap.data();
      if (t.toDriverId !== uid || t.status !== 'accepted') {
        throw new HttpsError('permission-denied', 'Action non autorisée');
      }
      if (t.expiresAtMs <= Date.now()) throw new HttpsError('failed-precondition', 'Transfert expiré');
      const orderSnap = await tx.get(orderRef(t.orderId));
      const order = orderSnap.exists ? orderSnap.data() : {};
      const version = Number(order.driverAssignmentVersion || 1);
      if (order.status !== 'picked_up' || order.driverId !== t.fromDriverId ||
          order.activeTransferId !== transferId || version !== t.assignmentVersion) {
        throw new HttpsError('failed-precondition', 'La commande a changé : transfert impossible');
      }
      const { sessionRef } = getProofRefs(db, t.orderId, 'handover');
      const sessionSnap = await tx.get(sessionRef);
      const session = sessionSnap.exists ? sessionSnap.data() : {};
      const same = session.transferId === transferId;
      const generationCount = same ? Number(session.generationCount || 0) : 0;
      if (generationCount >= MAX_PROOF_GENERATIONS) {
        throw new HttpsError('resource-exhausted', 'Limite de renouvellement atteinte');
      }
      let previous = null;
      if (same && session.currentProofId) {
        const prevRef = getProofRefs(db, t.orderId, 'handover', session.currentProofId).proofRef;
        const prevSnap = await tx.get(prevRef);
        if (prevSnap.exists && prevSnap.data().status === 'active') previous = prevRef;
      }
      const now = Date.now();
      const ts = admin.firestore.Timestamp.fromMillis(now);
      const expiresAt = admin.firestore.Timestamp.fromMillis(now + PROOF_TTL_MS);
      const secrets = makeSecrets();
      const proofId = crypto.randomBytes(16).toString('hex');
      if (previous) tx.update(previous, { status: 'revoked', revokedAt: ts, updatedAt: ts });
      tx.set(getProofRefs(db, t.orderId, 'handover', proofId).proofRef, {
        orderId: t.orderId, type: 'handover', transferId,
        tokenHash: hashToken(secrets.token),
        pinHash: hashPin(secrets.pin, pepper, t.orderId, 'handover'),
        status: 'active', createdAt: ts, expiresAt,
        // Validé par A (le livreur responsable) : la preuve est liée à lui.
        driverId: t.fromDriverId, issuedBy: uid, assignmentVersion: version,
        pinAttempts: 0, validatedAt: null, validatedBy: null,
      });
      tx.set(sessionRef, {
        ...session, orderId: t.orderId, type: 'handover', transferId, currentProofId: proofId,
        generationCount: generationCount + 1, driverId: t.fromDriverId,
        assignmentVersion: version, updatedAt: ts,
      });
      issued = { token: secrets.token, pin: secrets.pin, expiresAt: expiresAt.toMillis() };
    });
    await logAudit({ userId: uid, userType: 'driver', action: 'delivery_handover_proof_issued',
      targetId: transferId, status: 'success', metadata: { proofType: 'handover' } });
    return { success: true, transferId, ...issued };
  }

  async function doConfirmHandover(uid, data) {
    requireProofRollout(HttpsError);
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
    const { transferId, token, pin } = data;
    if ((typeof token === 'string') === (typeof pin === 'string')) {
      throw new HttpsError('invalid-argument', 'Fournissez le QR ou le PIN');
    }
    let result = null;
    let failure = null;
    let orderId;
    let toDriverId;
    await runLifecycleTransaction(db, async (tx) => {
      result = null; failure = null;
      const tSnap = await tx.get(transferRef(transferId));
      if (!tSnap.exists) throw new HttpsError('not-found', 'Transfert introuvable');
      const t = tSnap.data();
      orderId = t.orderId; toDriverId = t.toDriverId;
      if (t.fromDriverId !== uid) throw new HttpsError('permission-denied', 'Action non autorisée');
      if (t.status === 'completed') { result = { success: true, replay: true }; return; }
      if (t.status !== 'accepted') throw new HttpsError('failed-precondition', 'Ce transfert n’est pas prêt');
      if (t.expiresAtMs <= Date.now()) throw new HttpsError('failed-precondition', 'Transfert expiré');
      const orderSnap = await tx.get(orderRef(orderId));
      const order = orderSnap.exists ? orderSnap.data() : {};
      const version = Number(order.driverAssignmentVersion || 1);
      if (order.status !== 'picked_up' || order.driverId !== uid ||
          order.activeTransferId !== transferId || version !== t.assignmentVersion) {
        throw new HttpsError('failed-precondition', 'La commande a changé : transfert impossible');
      }
      if (Number(order.transferCount || 0) >= MAX_TRANSFERS) {
        throw new HttpsError('resource-exhausted', 'Limite de transferts atteinte');
      }
      const bSnap = await tx.get(driverRef(t.toDriverId));
      if (!bSnap.exists || bSnap.data().isSuspended === true || bSnap.data().deletionRequested === true) {
        throw new HttpsError('failed-precondition', 'Le livreur remplaçant n’est plus disponible');
      }
      const aSnap = await tx.get(driverRef(uid));
      const stateA = await readDriverState(tx, db, uid, orderId);
      const now = Date.now();
      const verdict = await verifyProofInTransaction({
        tx, db, orderId, type: 'handover', driverId: uid, assignmentVersion: version,
        token, pin, pepper, now, admin,
      });
      // Preuve de livraison éventuellement déjà émise pour A : révoquée.
      const delivery = await loadProofForTransaction(tx, db, orderId, 'delivery');
      if (!verdict.ok) {
        if (verdict.proofRef && verdict.failureUpdate) tx.update(verdict.proofRef, verdict.failureUpdate);
        failure = verdict;
        return;
      }
      const handoverSession = (await tx.get(verdict.sessionRef)).data();
      if (handoverSession.transferId !== transferId) {
        throw new HttpsError('failed-precondition', 'Code invalide ou expiré');
      }
      const ts = admin.firestore.Timestamp.fromMillis(now);
      tx.update(verdict.proofRef, verdict.consumeUpdate);
      if (delivery.proofRef && delivery.proof?.status === 'active') {
        tx.update(delivery.proofRef, { status: 'revoked', revokedAt: ts, updatedAt: ts });
      }
      const aPatch = terminalDriverPatch(stateA, orderId, admin);
      if (Object.keys(aPatch).length) tx.update(driverRef(uid), aPatch);
      tx.update(driverRef(t.toDriverId), { isOnDelivery: true, pendingOrderId: FieldValue.delete() });
      tx.update(orderRef(orderId), {
        driverId: t.toDriverId,
        driverAssignmentVersion: version + 1,
        transferCount: Number(order.transferCount || 0) + 1,
        activeTransferId: FieldValue.delete(),
        previousDriverId: uid,
        lastTransferAt: FieldValue.serverTimestamp(),
        driverAcceptanceSelfie: FieldValue.delete(),
        driverPhotoUrl: FieldValue.delete(),
        // Partage des gains non réglé : aucune livraison ne crédite ce trajet.
        settlementHold: true,
        settlementStatus: 'pending_admin_review',
        driverHistory: FieldValue.arrayUnion({
          driverId: uid, phase: 'after_pickup', reason: t.reason, version, transferId,
          handedOverTo: t.toDriverId, endedAtMs: now,
          // Positions des DEUX livreurs au moment de la remise confirmée : base
          // du partage des gains (jamais une distance déjà calculée).
          handover: captureHandoverPoint(positionOf(aSnap), positionOf(bSnap), now),
        }),
      });
      tx.update(transferRef(transferId), {
        status: 'completed', completedAtMs: now, closedAtMs: now,
        handoverMethod: typeof token === 'string' ? 'qr' : 'pin',
      });
      result = { success: true, replay: false, newDriverId: t.toDriverId, assignmentVersion: version + 1 };
    });
    if (failure) throw new HttpsError(failure.code, failure.message);
    if (!result.replay) {
      await logAudit({ userId: uid, userType: 'driver', action: 'delivery_handover_confirmed',
        targetId: orderId, status: 'success', metadata: { transferId, toDriverId } });
      await safeNotify({ event: 'driver_changed', orderId, transferId });
    }
    return result;
  }

  return onCall(options, async (request) => {
    if (!request.auth?.uid ||
        request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const data = request.data || {};
    const { action } = data;
    if (!ACTIONS.includes(action)) throw new HttpsError('invalid-argument', 'Action invalide');
    await checkRateLimit(uid, `delivery_transfer_${action}`, action === 'confirmHandover' ? 15 : 20, 600);
    if (action === 'request') return doRequest(uid, data);
    if (!isId(data.transferId)) throw new HttpsError('invalid-argument', 'transferId invalide');
    // Un transfert échu est d'abord clos (B libéré) : plus aucune validation tardive.
    if (action === 'expire') {
      const tSnap = await transferRef(data.transferId).get();
      const t = tSnap.exists ? tSnap.data() : null;
      if (!t || ![t.fromDriverId, t.toDriverId].includes(uid) && !(t.candidateIds || []).includes(uid)) {
        throw new HttpsError('permission-denied', 'Action non autorisée');
      }
      return { success: true, expired: await expireTransfer(db, admin, data.transferId) };
    }
    if (['accept', 'prepareHandover', 'confirmHandover'].includes(action) &&
        await expireTransfer(db, admin, data.transferId)) {
      throw new HttpsError('failed-precondition', 'Transfert expiré : la course reste au livreur d’origine.');
    }
    if (action === 'accept') return doAccept(uid, data.transferId);
    if (action === 'decline' || action === 'cancel') return doDeclineOrCancel(uid, action, data.transferId);
    if (action === 'prepareHandover') return doPrepareHandover(uid, data.transferId);
    return doConfirmHandover(uid, data);
  });
}

module.exports = { buildDeliveryTransfer, expireTransfer, expireDueTransfers, REASONS, MAX_TRANSFERS, ACTIONS };
