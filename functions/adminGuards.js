'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

function requireAuthenticatedUser(request) {
  if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
    throw new HttpsError('unauthenticated', 'Authentification Admin requise.');
  }
}

// Second facteur (MFA Firebase, TOTP ou SMS) : le jeton porte
// `firebase.sign_in_second_factor` uniquement si la connexion l'a réellement
// franchi. Le contrôle côté application (écran de connexion) ne suffit pas :
// un compte admin pas encore enrôlé obtient un jeton valide avec le seul mot
// de passe. Modes (variable ADMIN_MFA_MODE) :
//   off     : aucun contrôle ;
//   log     : défaut, journalise (une fois par compte et par instance) sans bloquer ;
//   enforce : refuse toute opération admin sans second facteur — à n'activer
//             qu'après avoir vérifié que chaque admin est enrôlé.
// Aucun code, secret ni jeton n'est journalisé : seulement l'uid et le rôle.
const warnedAdmins = new Set();
function enforceAdminSecondFactor({ request, role, mode = process.env.ADMIN_MFA_MODE || 'log', warn = console.warn }) {
  if (mode === 'off') return;
  if (request.auth?.token?.firebase?.sign_in_second_factor) return;
  if (mode === 'enforce') {
    throw new HttpsError('permission-denied', 'Second facteur d’authentification requis.');
  }
  if (!warnedAdmins.has(request.auth.uid)) {
    warnedAdmins.add(request.auth.uid);
    warn('admin_without_second_factor', JSON.stringify({ uid: request.auth.uid, role }));
  }
}

async function readValidAdmin({ request, db }) {
  requireAuthenticatedUser(request);
  const snapshot = await db.collection('admins').doc(request.auth.uid).get();
  const data = snapshot.data();
  if (!snapshot.exists || data?.isActive !== true || !['super', 'sub'].includes(data?.role)) {
    throw new HttpsError('permission-denied', 'Compte Admin invalide ou désactivé.');
  }
  enforceAdminSecondFactor({ request, role: data.role });
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

// Vérifier le statut d'un retrait peut le régler ou le rembourser : seul son
// propriétaire ou le super-administrateur y est autorisé (jamais un sous-admin).
async function requireWithdrawalAccess({ request, db, withdrawal }) {
  if (withdrawal?.userId && withdrawal.userId === request.auth?.uid) return;
  await requireSuperAdmin({ request, db });
}

module.exports = { requireAdminPermission, requireSuperAdmin, requireWithdrawalAccess, enforceAdminSecondFactor };
