'use strict';

// Public link ID is not a credential. Recovery secret travels separately.
// Everything is inside delivery_proofs, denied to ALL Firestore clients.
const crypto = require('crypto');
const {
  requireProofRollout, makeSecrets, hashToken, hashPin, getProofRefs,
  loadProofForTransaction, MAX_PROOF_GENERATIONS, PROOF_TTL_MS,
} = require('./deliveryProofs');

function buildRecipientProofAccess({ db, admin, onCall, HttpsError,
  checkRateLimit, deliveryProofPepper }) {
  const options = deliveryProofPepper ? { secrets: [deliveryProofPepper] } : {};
  const fail = () => new HttpsError('permission-denied', 'Accès invalide, expiré ou déjà utilisé');
  async function eligible(tx, orderId) {
    const snap = await tx.get(db.collection('orders').doc(orderId));
    const order = snap.exists ? snap.data() : {};
    if (!order.driverId || order.status !== 'picked_up' || order.deliveryProofMode !== 'qr_v1') throw fail();
    const pickup = await loadProofForTransaction(tx, db, orderId, 'pickup');
    if (pickup.proof?.status !== 'used') throw fail();
    return order;
  }
  const create = onCall(options, async request => {
    requireProofRollout(HttpsError);
    const uid = request.auth?.uid;
    if (!uid) throw fail();
    const { orderId } = request.data || {};
    if (typeof orderId !== 'string' || !/^[^/]{1,128}$/.test(orderId)) throw fail();
    await checkRateLimit(uid, 'recipient_access_create', 5, 3600);
    const grantId = crypto.randomBytes(16).toString('hex');
    const recovery = crypto.randomBytes(16).toString('hex');
    const ref = db.collection('delivery_proofs').doc(`guest_${grantId}`);
    const expiresAt = Date.now() + PROOF_TTL_MS;
    await db.runTransaction(async tx => {
      const order = await eligible(tx, orderId);
      if (uid !== order.clientId || uid === order.driverId) throw fail();
      const sessionRef = getProofRefs(db, orderId, 'delivery').sessionRef;
      const snap = await tx.get(sessionRef);
      const session = snap.exists ? snap.data() : {};
      const count = Number(session.guestGenerationCount || 0);
      if (count >= MAX_PROOF_GENERATIONS) throw new HttpsError('resource-exhausted', 'Limite de récupération atteinte');
      tx.set(ref, { orderId, clientId: uid, driverId: order.driverId,
        assignmentVersion: Number(order.driverAssignmentVersion || 1),
        recoveryHash: hashToken(recovery), expiresAt, attempts: 0, used: false });
      tx.set(sessionRef, { ...session, currentGuestId: grantId, guestGenerationCount: count + 1 });
    });
    return { grantId, recovery, expiresAt };
  });
  const redeem = onCall(options, async request => {
    requireProofRollout(HttpsError);
    const { grantId, recovery } = request.data || {};
    // Anonymous Firebase authentication is sufficient; no AZ Express account.
    const uid = request.auth?.uid;
    if (!uid || !/^[a-f0-9]{32}$/.test(grantId || '') || typeof recovery !== 'string' || recovery.length > 64) throw fail();
    await checkRateLimit(uid, 'recipient_access_redeem', 10, 3600);
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) throw new HttpsError('failed-precondition', 'Validation sécurisée indisponible');
    const ref = db.collection('delivery_proofs').doc(`guest_${grantId}`);
    const issued = await db.runTransaction(async tx => {
      const snap = await tx.get(ref);
      const grant = snap.exists ? snap.data() : null;
      if (!grant || grant.used || grant.expiresAt <= Date.now() || grant.attempts >= 5) throw fail();
      const order = await eligible(tx, grant.orderId);
      const driver = await tx.get(db.collection('livreurs').doc(uid));
      if (driver.exists || uid === order.driverId || grant.driverId !== order.driverId ||
          grant.clientId !== order.clientId || grant.assignmentVersion !== Number(order.driverAssignmentVersion || 1)) throw fail();
      const loaded = await loadProofForTransaction(tx, db, grant.orderId, 'delivery');
      if (loaded.session?.currentGuestId !== grantId) throw fail();
      if (hashToken(recovery) !== grant.recoveryHash) {
        tx.update(ref, { attempts: grant.attempts + 1 });
        return null; // Commit failed attempts, then throw outside transaction.
      }
      const count = Number(loaded.session?.generationCount || 0);
      if (count >= MAX_PROOF_GENERATIONS) throw new HttpsError('resource-exhausted', 'Limite de renouvellement atteinte');
      const proofId = crypto.randomBytes(16).toString('hex');
      const secrets = makeSecrets();
      const now = admin.firestore.Timestamp.fromMillis(Date.now());
      const expiresAt = Date.now() + PROOF_TTL_MS;
      if (loaded.proofRef && loaded.proof?.status === 'active') tx.update(loaded.proofRef, { status: 'revoked', updatedAt: now });
      tx.set(getProofRefs(db, grant.orderId, 'delivery', proofId).proofRef, {
        orderId: grant.orderId, type: 'delivery', tokenHash: hashToken(secrets.token),
        pinHash: hashPin(secrets.pin, pepper, grant.orderId, 'delivery'),
        driverId: order.driverId, assignmentVersion: grant.assignmentVersion,
        status: 'active', createdAt: now, expiresAt: admin.firestore.Timestamp.fromMillis(expiresAt), pinAttempts: 0,
      });
      tx.set(loaded.sessionRef, { ...loaded.session, currentProofId: proofId,
        generationCount: count + 1, driverId: order.driverId, assignmentVersion: grant.assignmentVersion });
      tx.update(ref, { used: true });
      return { success: true, orderId: grant.orderId, type: 'delivery', ...secrets, expiresAt };
    });
    if (!issued) throw fail();
    return issued;
  });
  return { create, redeem };
}
module.exports = { buildRecipientProofAccess };
