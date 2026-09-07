'use strict';

function buildModerateVehicleEntity({ db, admin, requireAdminPermission, HttpsError }) {
  return async (request) => {
    await requireAdminPermission({ request, db, permission: 'auto_moto' });
    const data = request.data || {};
    const targetType = data.targetType;
    const targetId = typeof data.targetId === 'string' ? data.targetId.trim() : '';
    const action = data.action;
    const reason = typeof data.reason === 'string' ? data.reason.trim() : '';
    const allowed = {
      listing: ['suspend', 'restore', 'archive'],
      seller: ['suspend', 'restore'],
      verification: ['verify', 'reject'],
      report: ['resolve', 'dismiss'],
    };
    if (!allowed[targetType]?.includes(action) || !targetId || reason.length > 300) {
      throw new HttpsError('invalid-argument', 'Action de modération invalide.');
    }
    if (['suspend', 'reject'].includes(action) && !reason) {
      throw new HttpsError('invalid-argument', 'Un motif est obligatoire.');
    }

    const collection = targetType === 'listing'
      ? 'vehicle_listings'
      : targetType === 'report'
        ? 'vehicle_reports'
        : 'vehicle_seller_profiles';
    const ref = db.collection(collection).doc(targetId);
    const auditRef = db.collection('audit_logs').doc();
    const suspensionRef = targetType === 'seller'
      ? db.collection('vehicle_seller_suspensions').doc(targetId)
      : null;
    await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      if (!snapshot.exists) throw new HttpsError('not-found', 'Cible introuvable.');
      const now = admin.firestore.FieldValue.serverTimestamp();
      let updates;
      if (targetType === 'listing') {
        updates = action === 'suspend'
          ? { status: 'suspended', suspensionReason: reason, suspendedAt: now, updatedAt: now }
          : action === 'archive'
            ? { status: 'archived', suspensionReason: admin.firestore.FieldValue.delete(), suspendedAt: admin.firestore.FieldValue.delete(), updatedAt: now }
            : { status: 'active', suspensionReason: admin.firestore.FieldValue.delete(), suspendedAt: admin.firestore.FieldValue.delete(), updatedAt: now };
      } else if (targetType === 'seller') {
        updates = action === 'suspend'
          ? { suspended: true, suspensionReason: reason, suspendedAt: now, updatedAt: now }
          : { suspended: false, suspensionReason: admin.firestore.FieldValue.delete(), suspendedAt: admin.firestore.FieldValue.delete(), updatedAt: now };
        if (action === 'suspend') {
          tx.set(suspensionRef, { sellerId: targetId, createdAt: now });
        } else {
          tx.delete(suspensionRef);
        }
      } else if (targetType === 'verification') {
        if (snapshot.data().sellerType !== 'professional') {
          throw new HttpsError('failed-precondition', 'Seul un professionnel peut être vérifié.');
        }
        updates = { verificationStatus: action === 'verify' ? 'verified' : 'rejected', updatedAt: now };
      } else {
        updates = { status: action === 'resolve' ? 'resolved' : 'dismissed', reviewedAt: now };
      }
      tx.update(ref, updates);
      tx.set(auditRef, {
        userId: request.auth.uid,
        userType: 'admin',
        action: `vehicle_${targetType}_${action}`,
        targetId,
        status: 'success',
        metadata: reason ? { reason } : {},
        createdAt: now,
      });
    });
    return { ok: true };
  };
}

module.exports = { buildModerateVehicleEntity };
