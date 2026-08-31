'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

function requireAuthenticatedUser(request) {
  if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
    throw new HttpsError('unauthenticated', 'Authentification Admin requise.');
  }
}

async function readValidAdmin({ request, db }) {
  requireAuthenticatedUser(request);
  const snapshot = await db.collection('admins').doc(request.auth.uid).get();
  const data = snapshot.data();
  if (!snapshot.exists || data?.isActive !== true || !['super', 'sub'].includes(data?.role)) {
    throw new HttpsError('permission-denied', 'Compte Admin invalide ou désactivé.');
  }
  return data;
}

async function requireAdminPermission({ request, db, permission }) {
  const data = await readValidAdmin({ request, db });
  if (data.role === 'sub' &&
      (!Array.isArray(data.permissions) || !data.permissions.includes(permission))) {
    throw new HttpsError('permission-denied', 'Permission Admin insuffisante.');
  }
  return data;
}

async function requireSuperAdmin({ request, db }) {
  const data = await readValidAdmin({ request, db });
  if (data.role !== 'super') {
    throw new HttpsError('permission-denied', 'Réservé à l’administrateur principal.');
  }
  return data;
}

module.exports = { requireAdminPermission, requireSuperAdmin };
