'use strict';

const crypto = require('crypto');
const { normalizeCiMobile, receiptSms, configuredSmsProvider } = require('./smsProvider');
const { requireProofRollout, getProofRefs, loadProofForTransaction, makeSecrets,
  hashToken, hashPin, PROOF_TTL_MS, MAX_PROOF_GENERATIONS } = require('./deliveryProofs');

// All configuration, budgets and attempts are inside a client-denied collection.
// No PIN, token or SMS body is persisted, even for recovery after a crash.
function smsRef(db, orderId) {
  return db.collection('delivery_proofs').doc(`sms_${Buffer.from(orderId).toString('base64url')}`);
}

function buildDeliveryProofSms({ db, admin, onCall, HttpsError, checkRateLimit,
  deliveryProofPepper, providerSecrets = [], providerFactory = configuredSmsProvider, clock = Date.now }) {
  // Future selected adapter receives Secret Manager bindings, never client keys.
  const options = { secrets: [...(deliveryProofPepper ? [deliveryProofPepper] : []), ...providerSecrets] };
  const fail = (code = 'failed-precondition') => new HttpsError(code, 'SMS indisponible pour cette commande');
  function gate() {
    requireProofRollout(HttpsError);
    if (process.env.DELIVERY_SMS_ENABLED !== 'true') throw fail();
  }
  function idFrom(request) {
    const data = request.data || {};
    // No phone, PIN or message text supplied by any caller.
    if (Object.keys(data).some(k => k !== 'orderId') || typeof data.orderId !== 'string' ||
        !/^[^/]{1,128}$/.test(data.orderId)) throw fail('invalid-argument');
    if (!request.auth?.uid) throw fail('unauthenticated');
    return data.orderId;
  }
  async function orderIn(tx, id) {
    const snap = await tx.get(db.collection('orders').doc(id));
    if (!snap.exists) throw fail('not-found');
    return snap.data();
  }
  function owner(order, uid) {
    if (uid !== order.clientId || uid === order.driverId) throw fail('permission-denied');
  }
  function eligible(order) {
    if (order.status !== 'picked_up' || order.deliveryProofMode !== 'qr_v1' || !order.driverId) throw fail();
  }
  function phone(order) {
    if (typeof order.recipientName !== 'string' || !order.recipientName.trim()) throw fail('invalid-argument');
    try { return normalizeCiMobile(order.recipientPhone); } catch (_) { throw fail('invalid-argument'); }
  }
  function matches(order, state) {
    return order.clientId === state.clientId && order.driverId === state.driverId &&
      Number(order.driverAssignmentVersion || 1) === state.assignmentVersion && phone(order) === state.phone;
  }
  function publicState(state) {
    if (!state) return { status: 'not_configured', attempts: 0 };
    return { status: state.status === 'sending' && clock() - state.startedAt > 60000 ? 'unknown' : state.status,
      attempts: state.attempts || 0, expiresAt: state.expiresAt || 0,
      canRetry: (state.status === 'unavailable' && clock() - state.updatedAt >= 60000) ||
        (['accepted', 'simulated', 'failed', 'unknown', 'sending'].includes(state.status) &&
        clock() >= (state.expiresAt || Infinity) && state.attempts < MAX_PROOF_GENERATIONS) };
  }

  const configure = onCall(options, async request => {
    gate();
    const id = idFrom(request);
    await checkRateLimit(request.auth.uid, 'delivery_sms_configure', 5, 3600);
    return db.runTransaction(async tx => {
      const order = await orderIn(tx, id);
      owner(order, request.auth.uid);
      eligible(order);
      const destination = phone(order);
      const ref = smsRef(db, id);
      const old = await tx.get(ref);
      if (old.exists) {
        if (!matches(order, old.data())) throw fail();
        return publicState(old.data());
      }
      const state = { orderId: id, clientId: order.clientId, driverId: order.driverId,
        assignmentVersion: Number(order.driverAssignmentVersion || 1), phone: destination,
        status: 'waiting_arrival', attempts: 0, createdAt: clock() };
      tx.set(ref, state);
      return publicState(state);
    });
  });

  // Assigned driver can signal arrival once; cannot select a number or resend.
  const arrival = onCall(options, async request => {
    gate();
    const id = idFrom(request);
    await checkRateLimit(request.auth.uid, 'delivery_sms_arrival', 10, 3600);
    await db.runTransaction(async tx => {
      const order = await orderIn(tx, id);
      eligible(order);
      if (order.driverId !== request.auth.uid) throw fail('permission-denied');
      const ref = smsRef(db, id);
      const snap = await tx.get(ref);
      if (!snap.exists || !matches(order, snap.data())) throw fail();
      if (snap.data().status === 'waiting_arrival') tx.update(ref, { status: 'queued', queuedAt: clock() });
    });
    return { success: true }; // Never returns a code, phone or provider response.
  });

  const status = onCall(options, async request => {
    gate();
    const id = idFrom(request);
    await checkRateLimit(request.auth.uid, 'delivery_sms_status', 120, 3600);
    return db.runTransaction(async tx => {
      const order = await orderIn(tx, id);
      owner(order, request.auth.uid);
      const snap = await tx.get(smsRef(db, id));
      if (!snap.exists) return publicState(null);
      const state = snap.data();
      const proof = await loadProofForTransaction(tx, db, id, 'delivery');
      if (order.status === 'delivered') return { ...publicState(state), status: 'completed', canRetry: false };
      if (!matches(order, state)) return { status: 'blocked', canRetry: false };
      if (state.proofId && proof.session?.currentProofId !== state.proofId) {
        return { ...publicState(state), status: 'superseded', canRetry: false };
      }
      if (state.expiresAt && clock() >= state.expiresAt &&
          ['accepted', 'simulated'].includes(state.status)) {
        return { ...publicState(state), status: 'expired' };
      }
      return publicState(state);
    });
  });

  const retry = onCall(options, async request => {
    gate();
    const id = idFrom(request);
    await checkRateLimit(request.auth.uid, 'delivery_sms_retry', 3, 3600);
    return db.runTransaction(async tx => {
      const order = await orderIn(tx, id);
      owner(order, request.auth.uid);
      eligible(order);
      const ref = smsRef(db, id);
      const snap = await tx.get(ref);
      if (!snap.exists || !matches(order, snap.data()) || !publicState(snap.data()).canRetry) throw fail();
      const loaded = await loadProofForTransaction(tx, db, id, 'delivery');
      if (snap.data().proofId && loaded.session?.currentProofId !== snap.data().proofId) throw fail();
      tx.update(ref, { status: 'queued', queuedAt: clock() });
      return { status: 'queued' };
    });
  });

  async function dispatch(id) {
    // Replayed events read CURRENT state, never the event payload's stale state.
    gate();
    const ref = smsRef(db, id);
    const provider = providerFactory();
    const pepper = process.env.DELIVERY_PROOF_PEPPER;
    if (!pepper) throw fail();
    const reservation = await db.runTransaction(async tx => {
      const snapshot = await tx.get(ref);
      const state = snapshot.exists ? snapshot.data() : null;
      if (!state || state.status !== 'queued') return null;
      const order = await orderIn(tx, id);
      const pickup = await loadProofForTransaction(tx, db, id, 'pickup');
      const loaded = await loadProofForTransaction(tx, db, id, 'delivery');
      let valid = false;
      try { eligible(order); valid = matches(order, state) && pickup.proof?.status === 'used'; } catch (_) { /* safe rejection */ }
      if (!valid) { tx.update(ref, { status: 'blocked' }); return null; }
      if (!provider.available) { tx.update(ref, { status: 'unavailable', updatedAt: clock() }); return null; }
      const now = clock();
      const count = Number(loaded.session?.generationCount || 0);
      if (state.attempts >= MAX_PROOF_GENERATIONS || count >= MAX_PROOF_GENERATIONS) {
        tx.update(ref, { status: 'limited' }); return null;
      }
      const day = new Date(now).toISOString().slice(0, 10);
      const fingerprint = crypto.createHmac('sha256', pepper).update(state.phone).digest('hex');
      const budgets = [ ['global', 100], [`client_${hashToken(state.clientId)}`, 10], [`phone_${fingerprint}`, 5] ];
      const counters = [];
      for (const [key, limit] of budgets) {
        const budgetRef = db.collection('delivery_proofs').doc(`sms_budget_${day}_${key}`);
        const budgetSnap = await tx.get(budgetRef);
        counters.push({ ref: budgetRef, count: Number(budgetSnap.data()?.count || 0), limit });
      }
      if (counters.some(b => b.count >= b.limit)) { tx.update(ref, { status: 'limited' }); return null; }
      const secrets = makeSecrets();
      const proofId = crypto.randomBytes(16).toString('hex');
      const expiresAt = now + PROOF_TTL_MS;
      const stamp = admin.firestore.Timestamp.fromMillis(now);
      if (loaded.proof?.status === 'active') tx.update(loaded.proofRef, { status: 'revoked', updatedAt: stamp });
      tx.set(getProofRefs(db, id, 'delivery', proofId).proofRef, {
        orderId: id, type: 'delivery', driverId: order.driverId, assignmentVersion: state.assignmentVersion,
        tokenHash: hashToken(secrets.token), pinHash: hashPin(secrets.pin, pepper, id, 'delivery'),
        status: 'active', createdAt: stamp, expiresAt: admin.firestore.Timestamp.fromMillis(expiresAt), pinAttempts: 0,
      });
      tx.set(loaded.sessionRef, { ...loaded.session, orderId: id, type: 'delivery',
        currentProofId: proofId, generationCount: count + 1,
        driverId: order.driverId, assignmentVersion: state.assignmentVersion });
      for (const b of counters) tx.set(b.ref, { count: b.count + 1 });
      tx.update(ref, { status: 'sending', attempts: state.attempts + 1, proofId, startedAt: now, expiresAt });
      tx.set(ref.collection('attempts').doc(proofId), { status: 'sending', startedAt: now, expiresAt });
      return { phone: state.phone, pin: secrets.pin, proofId };
    });
    if (!reservation) return;
    let result = 'unknown';
    try {
      const response = await provider.send({ to: reservation.phone, body: receiptSms(reservation.pin),
        idempotencyKey: reservation.proofId });
      if (['accepted', 'failed', 'simulated'].includes(response?.status)) result = response.status;
    } catch (_) { /* Ambiguous result: never resend blindly or persist provider error. */ }
    await db.runTransaction(async tx => {
      const snap = await tx.get(ref);
      if (snap.data()?.proofId !== reservation.proofId) return;
      tx.update(ref, { status: result, updatedAt: clock() });
      tx.update(ref.collection('attempts').doc(reservation.proofId), { status: result, updatedAt: clock() });
    });
  }
  return { configure, arrival, status, retry, dispatch };
}

module.exports = { buildDeliveryProofSms, smsRef };
