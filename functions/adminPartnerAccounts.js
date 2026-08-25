'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

const PERMISSIONS = {
  seller: 'demandes_vendeurs',
  boulangerie: 'boulangeries',
};

async function requireAdminPermission({ request, db, permission }) {
  if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
    throw new HttpsError('unauthenticated', 'Authentification Admin requise.');
  }
  const snapshot = await db.collection('admins').doc(request.auth.uid).get();
  const data = snapshot.data();
  if (!snapshot.exists || data?.isActive !== true || !['super', 'sub'].includes(data?.role)) {
    throw new HttpsError('permission-denied', 'Compte Admin invalide ou désactivé.');
  }
  if (data.role === 'sub' &&
      (!Array.isArray(data.permissions) || !data.permissions.includes(permission))) {
    throw new HttpsError('permission-denied', 'Permission Admin insuffisante.');
  }
}

function requiredString(data, key) {
  const value = data?.[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new HttpsError('invalid-argument', `Champ ${key} requis.`);
  }
  return value.trim();
}

function buildManageAdminPartnerAccount({ db, auth, fieldValue }) {
  return async (request) => {
    const action = requiredString(request.data, 'action');
    const kind = requiredString(request.data, 'kind');
    const permission = PERMISSIONS[kind];
    if (!permission) throw new HttpsError('invalid-argument', 'Type de partenaire invalide.');
    await requireAdminPermission({ request, db, permission });

    if (action === 'updatePassword') {
      const uid = requiredString(request.data, 'uid');
      const password = requiredString(request.data, 'password');
      if (password.length < 6) throw new HttpsError('invalid-argument', 'Mot de passe trop court.');
      await auth.updateUser(uid, { password });
      return { uid };
    }
    if (action !== 'create') throw new HttpsError('invalid-argument', 'Action invalide.');

    const email = requiredString(request.data, 'email');
    const password = requiredString(request.data, 'password');
    const profile = request.data.profile;
    if (password.length < 6 || profile == null || typeof profile !== 'object' || Array.isArray(profile)) {
      throw new HttpsError('invalid-argument', 'Profil ou mot de passe invalide.');
    }

    const user = await auth.createUser({ email, password });
    try {
      if (Object.keys(profile).length > 0) {
        await db.collection(kind === 'seller' ? 'sellers' : 'boulangeries')
          .doc(user.uid).set({ ...profile, createdAt: fieldValue.serverTimestamp() });
      }
    } catch (error) {
      await auth.deleteUser(user.uid).catch(() => {});
      throw error;
    }
    return { uid: user.uid };
  };
}

module.exports = { buildManageAdminPartnerAccount, requireAdminPermission };
