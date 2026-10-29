'use strict';

// Phase 1: keep the single-active-mission contract. Never touch money here.
const TERMINAL = new Set(['delivered', 'cancelled']);
const ACTIVE = new Set(['accepted', 'picked_up']);
const KNOWN = new Set(['pending', 'assigned', 'broadcast', ...ACTIVE, ...TERMINAL]);
const SCAN_LIMIT = 1001;

// A closed transaction cannot accept further writes. Some emulator/backend
// responses use INVALID_ARGUMENT rather than ABORTED for this precise case,
// which the installed Admin SDK does not retry. Retry a fresh transaction only;
// business callbacks must keep side effects inside it (logs remain post-commit).
async function runLifecycleTransaction(db, callback) {
  for (let attempt = 0; ; attempt++) {
    try { return await db.runTransaction(callback); }
    catch (error) {
      if (attempt >= 2 || error.code !== 3 ||
          error.details !== 'Transaction is invalid or closed.') throw error;
    }
  }
}

async function readDriverState(tx, db, driverId, excludingOrderId = null) {
  const ref = db.collection('livreurs').doc(driverId);
  const snapshot = await tx.get(ref);
  if (!snapshot.exists) return { ref, exists: false, active: 0, ambiguous: true, data: {} };
  const data = snapshot.data();
  // Bounded scan, fail closed if history is too large or a status is unknown.
  // Equality only: no new composite index needed. Read inside the transaction.
  const orders = await tx.get(db.collection('orders')
    .where('driverId', '==', driverId).limit(SCAN_LIMIT));
  let active = 0;
  let ambiguous = orders.docs.length >= SCAN_LIMIT;
  for (const doc of orders.docs) {
    if (doc.id === excludingOrderId) continue;
    const status = doc.data().status;
    if (ACTIVE.has(status)) active++;
    if (!KNOWN.has(status)) ambiguous = true;
  }
  const references = {};
  for (const field of ['currentOrderId', 'pendingOrderId']) {
    const id = data[field];
    if (id == null) continue;
    if (typeof id !== 'string' || !id || id.includes('/')) {
      references[field] = 'invalid';
      ambiguous = true;
      continue;
    }
    if (id === excludingOrderId) { references[field] = 'ending'; continue; }
    const order = await tx.get(db.collection('orders').doc(id));
    references[field] = !order.exists ? 'missing' : order.data().status;
    if (!order.exists || !KNOWN.has(order.data().status)) ambiguous = true;
    if (field === 'currentOrderId' && order.exists && !TERMINAL.has(order.data().status)) {
      ambiguous = true;
    }
  }
  return { ref, exists: true, data, active, ambiguous, references };
}

function terminalDriverPatch(state, orderId, admin) {
  const patch = {};
  if (!state.exists) return patch;
  if (state.active > 0) patch.isOnDelivery = true;
  else if (!state.ambiguous) patch.isOnDelivery = false;
  for (const field of ['currentOrderId', 'pendingOrderId']) {
    if (state.data[field] === orderId) patch[field] = admin.firestore.FieldValue.delete();
  }
  return patch;
}

// Also covers legacy/admin terminal transitions. Re-read the order: a delayed
// event must never release a driver for an order that has since changed state.
async function settleTerminalOrder(db, admin, orderId, previous = {}) {
  return runLifecycleTransaction(db, async tx => {
    const order = await tx.get(db.collection('orders').doc(orderId));
    if (!order.exists || !TERMINAL.has(order.data().status)) return { skipped: true };
    const data = order.data();
    const driverId = data.driverId || previous.driverId;
    const ids = new Set([driverId, ...(data.notifiedDriverIds || []),
      ...(previous.notifiedDriverIds || [])].filter(id => typeof id === 'string' && id && !id.includes('/')));
    const updates = [];
    for (const id of ids) {
      if (id === driverId) {
        const state = await readDriverState(tx, db, id, orderId);
        updates.push([state.ref, terminalDriverPatch(state, orderId, admin)]);
      } else {
        const ref = db.collection('livreurs').doc(id);
        const snap = await tx.get(ref);
        if (snap.exists && snap.data().pendingOrderId === orderId) {
          updates.push([ref, { pendingOrderId: admin.firestore.FieldValue.delete() }]);
        }
      }
    }
    for (const [ref, patch] of updates) if (Object.keys(patch).length) tx.update(ref, patch);
    return { skipped: false, checked: ids.size };
  });
}

// Read-only by construction. Missing history is NOT proof that a physical
// delivery ended. There is deliberately no corrective mode in this phase.
async function diagnoseDriver(db, driverId) {
  return db.runTransaction(async tx => {
    const state = await readDriverState(tx, db, driverId);
    const decision = !state.exists ? 'driver_missing' : state.active > 0 ? 'active_mission'
      : state.ambiguous ? 'ambiguous_references_or_history'
      : state.data.isOnDelivery === true ? 'stale_candidate_requires_manual_evidence' : 'consistent';
    return { decision, activeMissions: state.active, references: state.references || {},
      isOnDelivery: state.data.isOnDelivery === true, correctionAllowed: false };
  }, { readOnly: true });
}

module.exports = { readDriverState, terminalDriverPatch, settleTerminalOrder, diagnoseDriver, runLifecycleTransaction };

async function clearAcceptedOffers(db, admin, orderId, previous = {}) {
  return runLifecycleTransaction(db, async tx => {
    const snap = await tx.get(db.collection('orders').doc(orderId));
    if (!snap.exists || snap.data().status !== 'accepted') return;
    const ids = new Set([snap.data().driverId, ...(previous.notifiedDriverIds || [])]
      .filter(id => typeof id === 'string' && id && !id.includes('/')));
    const updates = [];
    for (const id of ids) {
      const ref = db.collection('livreurs').doc(id);
      const driver = await tx.get(ref);
      if (driver.exists && driver.data().pendingOrderId === orderId) updates.push(ref);
    }
    for (const ref of updates) tx.update(ref, { pendingOrderId: admin.firestore.FieldValue.delete() });
  });
}
module.exports.clearAcceptedOffers = clearAcceptedOffers;
