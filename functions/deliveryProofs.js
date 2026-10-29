'use strict';
const crypto = require('crypto');
const PROOF_TTL_MS = 15 * 60 * 1000;
const MAX_PROOF_GENERATIONS = 3;
const MAX_PIN_ATTEMPTS = 5;
const PIN_LENGTH = 6;
function sessionId(orderId, type) {
  return `${Buffer.from(String(orderId)).toString('base64url')}_${type}`;
}
function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}
function hashPin(pin, pepper, orderId, type) {
  return crypto.createHmac('sha256', pepper)
    .update(`${orderId}:${type}:${pin}`, 'utf8')
    .digest('hex');
}
function safeEqualHex(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string' ||
      !/^[a-f0-9]{64}$/i.test(left) || !/^[a-f0-9]{64}$/i.test(right)) {
    return false;
  }
  return crypto.timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}
function makeSecrets() {
  return {
    token: crypto.randomBytes(32).toString('base64url'),
    pin: crypto.randomInt(0, 10 ** PIN_LENGTH).toString().padStart(PIN_LENGTH, '0'),
  };
}
function validType(type) {
  return type === 'pickup' || type === 'delivery';
}
function requireProofRollout(HttpsError) {
  if (process.env.DELIVERY_PROOFS_ENABLED !== 'true') {
    throw new HttpsError('failed-precondition', 'Validation QR non activ?e');
  }
}
function authUid(request, HttpsError) {
  if (!request.auth?.uid) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  return request.auth.uid;
}
function getProofRefs(db, orderId, type, proofId) {
  const sessionRef = db.collection('delivery_proofs').doc(sessionId(orderId, type));
  return {
    sessionRef,
    proofRef: proofId
      ? sessionRef.collection('versions').doc(proofId)
      : null,
  };
}
async function authorizePickupIssuer(tx, db, order, uid, HttpsError) {
  if (!order.sellerId) {
    if (order.clientId === uid) return;
    throw new HttpsError('permission-denied', 'Action non autorisée');
  }
  const sellerId = String(order.sellerId);
  const sellerType = order.sellerType || 'seller';
  if (sellerType === 'restaurant') {
    const ownerSnap = await tx.get(db.collection('restaurant_owners').doc(uid));
    if (ownerSnap.exists && ownerSnap.data()?.restaurantId === sellerId) return;
  } else if (sellerType === 'pharmacie') {
    const pharmacySnap = await tx.get(db.collection('pharmacies').doc(sellerId));
    if (pharmacySnap.exists && pharmacySnap.data()?.currentUid === uid) return;
  } else if (sellerType === 'boutique') {
    const seller = await tx.get(db.collection('sellers').doc(sellerId));
    const data = seller.exists ? seller.data() : {};
    if (sellerId === uid && data.type === 'boutique' && data.isActive === true &&
        data.isSuspended !== true && data.status !== 'suspended') return;
  } else if (sellerType === 'seller' || sellerType === 'boulangerie') {
    if (sellerId === uid) return;
  }
  throw new HttpsError(
    'failed-precondition',
    'La validation QR partenaire n’est pas disponible pour ce compte',
  );
}
async function loadProofForTransaction(tx, db, orderId, type) {
  const { sessionRef } = getProofRefs(db, orderId, type);
  const sessionSnap = await tx.get(sessionRef);
  if (!sessionSnap.exists) return { sessionRef, session: null, proofRef: null, proof: null };
  const session = sessionSnap.data();
  if (!session.currentProofId) {
    return { sessionRef, session, proofRef: null, proof: null };
  }
  const { proofRef } = getProofRefs(db, orderId, type, session.currentProofId);
  const proofSnap = await tx.get(proofRef);
  return {
    sessionRef,
    session,
    proofRef,
    proof: proofSnap.exists ? proofSnap.data() : null,
  };
}
function buildPrepareOrderProof({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, deliveryProofPepper,
}) {
  const options = deliveryProofPepper ? { secrets: [deliveryProofPepper] } : {};
  return onCall(options, async (request) => {
    const uid = authUid(request, HttpsError);
    requireProofRollout(HttpsError);
    const { orderId: rawOrderId, type } = request.data || {};
    if (typeof rawOrderId !== 'string' || !rawOrderId.trim() || rawOrderId.length > 128 ||
        !validType(type)) {
      throw new HttpsError('invalid-argument', 'Commande ou type de preuve invalide');
    }
    const orderId = rawOrderId.trim();
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) {
      throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
    }
    await checkRateLimit(uid, 'delivery_proof_prepare', 10, 3600);
    const orderRef = db.collection('orders').doc(orderId);
    let issued;
    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();
      if (!order.driverId || order.driverId === uid) {
        throw new HttpsError('permission-denied', 'Action non autorisée');
      }
      if (type === 'pickup') {
        if (order.status !== 'accepted') {
          throw new HttpsError('failed-precondition', 'La commande ne peut pas être préparée');
        }
        await authorizePickupIssuer(tx, db, order, uid, HttpsError);
      } else {
        if (order.status !== 'picked_up' || order.deliveryProofMode !== 'qr_v1') {
          throw new HttpsError('failed-precondition', 'La commande ne peut pas être préparée');
        }
        if (order.clientId !== uid) {
          throw new HttpsError('permission-denied', 'Action non autorisée');
        }
        const pickup = await loadProofForTransaction(tx, db, orderId, 'pickup');
        if (pickup.proof?.status !== 'used') {
          throw new HttpsError('failed-precondition', 'La récupération doit être confirmée');
        }
      }
      const { sessionRef } = getProofRefs(db, orderId, type);
      const sessionSnap = await tx.get(sessionRef);
      const session = sessionSnap.exists ? sessionSnap.data() : {};
      const assignmentVersion = Number(order.driverAssignmentVersion || 1);
      const sameAssignment = session.driverId === order.driverId &&
        Number(session.assignmentVersion || 0) === assignmentVersion;
      const generationCount = sameAssignment ? Number(session.generationCount || 0) : 0;
      if (generationCount >= MAX_PROOF_GENERATIONS) {
        throw new HttpsError('resource-exhausted', 'Limite de renouvellement atteinte');
      }
      let previousProofRef = null;
      let previousProof = null;
      if (session.currentProofId) {
        previousProofRef = getProofRefs(db, orderId, type, session.currentProofId).proofRef;
        const previousSnap = await tx.get(previousProofRef);
        previousProof = previousSnap.exists ? previousSnap.data() : null;
      }
      const secrets = makeSecrets();
      const proofId = crypto.randomBytes(16).toString('hex');
      const proofRef = getProofRefs(db, orderId, type, proofId).proofRef;
      const now = Date.now();
      const timestamp = admin.firestore.Timestamp.fromMillis(now);
      const expiresAt = admin.firestore.Timestamp.fromMillis(now + PROOF_TTL_MS);
      if (previousProofRef && previousProof?.status === 'active') {
        const previousExpiry = previousProof.expiresAt?.toMillis?.() || 0;
        tx.update(previousProofRef, previousExpiry <= now
          ? { status: 'expired', updatedAt: timestamp }
          : { status: 'revoked', revokedAt: timestamp, updatedAt: timestamp });
      }
      tx.set(proofRef, {
        orderId,
        type,
        tokenHash: hashToken(secrets.token),
        pinHash: hashPin(secrets.pin, pepper, orderId, type),
        status: 'active',
        createdAt: timestamp,
        expiresAt,
        driverId: order.driverId,
        assignmentVersion,
        pinAttempts: 0,
        validatedAt: null,
        validatedBy: null,
      });
      tx.set(sessionRef, {
        ...session,
        orderId,
        type,
        currentProofId: proofId,
        generationCount: generationCount + 1,
        driverId: order.driverId,
        assignmentVersion,
        updatedAt: timestamp,
      });
      if (type === 'pickup') {
        tx.update(orderRef, {
          deliveryProofMode: 'qr_v1',
          driverAssignmentVersion: assignmentVersion,
        });
      }
      issued = { token: secrets.token, pin: secrets.pin, expiresAt: expiresAt.toMillis() };
    });
    await logAudit({
      userId: uid,
      userType: 'user',
      action: 'delivery_proof_issued',
      targetId: orderId,
      status: 'success',
      metadata: { proofType: type },
    });
    return { success: true, orderId, type, ...issued };
  });
}
async function verifyProofInTransaction({
  tx, db, orderId, type, driverId, assignmentVersion, token, pin, pepper, now, admin,
}) {
  const loaded = await loadProofForTransaction(tx, db, orderId, type);
  const { session, sessionRef, proofRef, proof } = loaded;
  const invalid = { ok: false, code: 'failed-precondition', message: 'Code invalide ou expiré' };
  if (!session || !proofRef || !proof || session.driverId !== driverId ||
      Number(session.assignmentVersion) !== Number(assignmentVersion) ||
      proof.driverId !== driverId ||
      Number(proof.assignmentVersion) !== Number(assignmentVersion) ||
      !['active', 'used', 'expired'].includes(proof.status)) {
    return { ...invalid };
  }
  if (proof.status === 'used') return { ...invalid, message: 'Code d?j? utilis?' };
  const expiresAt = proof.expiresAt?.toMillis?.() || 0;
  if (expiresAt <= now) {
    return {
      ok: false,
      code: invalid.code,
      message: 'Code expir?',
      proofRef,
      failureUpdate: { status: 'expired', updatedAt: admin.firestore.Timestamp.fromMillis(now) },
    };
  }
  if ((typeof token === 'string') === (typeof pin === 'string')) return { ...invalid };
  const authMethod = typeof token === 'string' ? 'qr' : 'pin';
  if (authMethod === 'pin') {
    if (Number(proof.pinAttempts || 0) >= MAX_PIN_ATTEMPTS) {
      return { ok: false, code: 'resource-exhausted', message: 'Trop de tentatives' };
    }
    if (!/^\d{6}$/.test(pin)) {
      return { ...invalid, proofRef, failureUpdate: {
        pinAttempts: Number(proof.pinAttempts || 0) + 1,
        ...(Number(proof.pinAttempts || 0) + 1 >= MAX_PIN_ATTEMPTS
          ? { pinLocked: true }
          : {}),
      } };
    }
    const suppliedHash = hashPin(pin, pepper, orderId, type);
    if (!safeEqualHex(suppliedHash, proof.pinHash)) {
      const attempts = Number(proof.pinAttempts || 0) + 1;
      return {
        ...invalid,
        proofRef,
        failureUpdate: { pinAttempts: attempts, ...(attempts >= MAX_PIN_ATTEMPTS ? { pinLocked: true } : {}) },
      };
    }
  } else {
    if (token.length > 128 || !safeEqualHex(hashToken(token), proof.tokenHash)) {
      return { ...invalid };
    }
  }
  return {
    ok: true,
    proofRef,
    sessionRef,
    proofId: session.currentProofId,
    consumeUpdate: {
      status: 'used',
      validatedAt: admin.firestore.Timestamp.fromMillis(now),
      validatedBy: driverId,
      validationMethod: authMethod,
      updatedAt: admin.firestore.Timestamp.fromMillis(now),
    },
  };
}
function buildConfirmPickupWithProof({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, deliveryProofPepper,
}) {
  const options = deliveryProofPepper ? { secrets: [deliveryProofPepper] } : {};
  return onCall(options, async (request) => {
    const uid = authUid(request, HttpsError);
    const { orderId: rawOrderId, token, pin } = request.data || {};
    if (typeof rawOrderId !== 'string' || !rawOrderId.trim() || rawOrderId.length > 128) {
      throw new HttpsError('invalid-argument', 'Commande invalide');
    }
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
    await checkRateLimit(uid, 'delivery_proof_confirm_pickup', 30, 3600);
    const orderId = rawOrderId.trim();
    const orderRef = db.collection('orders').doc(orderId);
    let result;
    let proofFailure;
    await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      const order = orderSnap.data();
      if (order.driverId !== uid) {
        throw new HttpsError('permission-denied', 'Cette commande ne vous est pas assignée');
      }
      if (order.deliveryProofMode === 'qr_v1' &&
          ['picked_up', 'delivered'].includes(order.status)) {
        throw new HttpsError('failed-precondition', 'Code déjà utilisé');
      }
      if (order.deliveryProofMode !== 'qr_v1' || order.status !== 'accepted') {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut pas être confirmée');
      }
      const checked = await verifyProofInTransaction({
        tx, db, orderId, type: 'pickup', driverId: uid,
        assignmentVersion: Number(order.driverAssignmentVersion || 1),
        token, pin, pepper, now: Date.now(), admin,
      });
      if (!checked.ok) {
        if (checked.failureUpdate && checked.proofRef) {
          tx.update(checked.proofRef, checked.failureUpdate);
        }
        proofFailure = checked;
        return;
      }
      tx.update(checked.proofRef, checked.consumeUpdate);
      tx.update(orderRef, {
        status: 'picked_up',
        pickedUpAt: admin.firestore.FieldValue.serverTimestamp(),
        pickupProofValidatedAt: checked.consumeUpdate.validatedAt,
        pickupProofValidatedBy: uid,
      });
      result = { success: true, status: 'picked_up' };
    });
    if (proofFailure) {
      await logAudit({
        userId: uid,
        userType: 'driver',
        action: 'delivery_proof_validation',
        targetId: orderId,
        status: 'error',
        metadata: { proofType: 'pickup', errorCode: proofFailure.code },
      });
      throw new HttpsError(proofFailure.code, proofFailure.message);
    }
    await logAudit({
      userId: uid,
      userType: 'driver',
      action: 'delivery_proof_validation',
      targetId: orderId,
      status: 'success',
      metadata: { proofType: 'pickup' },
    });
    return result;
  });
}
module.exports = {
  requireProofRollout,
  makeSecrets,
  getProofRefs,
  loadProofForTransaction,
  MAX_PIN_ATTEMPTS,
  MAX_PROOF_GENERATIONS,
  PROOF_TTL_MS,
  buildConfirmPickupWithProof,
  buildPrepareOrderProof,
  hashPin,
  hashToken,
  sessionId,
  verifyProofInTransaction,
};
