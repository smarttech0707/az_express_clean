'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

function normalizePhone(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  if (digits.startsWith('225') && (digits.length === 11 || digits.length === 13)) return `+${digits}`;
  if (digits.length === 10) return `+225${digits}`;
  if (digits.length === 8) return `+225${digits}`;
  throw new HttpsError('invalid-argument', 'Numero de telephone invalide');
}

function validatePassword(value) {
  const password = String(value || '');
  if (password.length < 8 || !/[A-Z]/.test(password) || !/[0-9]/.test(password)) {
    throw new HttpsError('invalid-argument',
      'Le mot de passe doit contenir au moins 8 caracteres, une majuscule et un chiffre');
  }
  return password;
}

function phoneCandidates(rawPhone, normalizedPhone) {
  return [...new Set([String(rawPhone).trim(), normalizedPhone, normalizedPhone.slice(4)])];
}

async function findUniqueAccountByPhone(db, collectionName, rawPhone, normalizedPhone) {
  const matches = new Map();
  for (const candidate of phoneCandidates(rawPhone, normalizedPhone)) {
    const snap = await db.collection(collectionName).where('phone', '==', candidate).limit(2).get();
    for (const doc of snap.docs) matches.set(doc.id, doc);
  }
  if (matches.size === 0) throw new HttpsError('not-found', 'Compte introuvable');
  if (matches.size !== 1) {
    throw new HttpsError('failed-precondition', 'Plusieurs comptes utilisent ce numero');
  }
  return matches.values().next().value;
}

function buildResetAccountPassword({ db, auth, fieldValue, hashSecret, checkRateLimit }) {
  return async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
    const verifiedPhone = request.auth.token.phone_number;
    if (!verifiedPhone) {
      throw new HttpsError('unauthenticated', 'Verification telephonique requise');
    }
    const { userType, phone, newValue } = request.data || {};
    if (!userType || !phone || !newValue) {
      throw new HttpsError('invalid-argument', 'Parametres manquants');
    }
    const normalizedInput = normalizePhone(phone);
    if (normalizedInput !== normalizePhone(verifiedPhone)) {
      throw new HttpsError('permission-denied', 'Numero de telephone non verifie');
    }
    await checkRateLimit(request.auth.uid, 'reset_password', 5, 3600);

    const collectionName = {
      client: 'clients', fleet: 'fleet_owners', seller: 'sellers',
      restaurant: 'restaurant_owners', boulangerie: 'boulangeries',
      pharmacie: 'pharmacies', artisan: 'service_providers',
    }[userType];
    if (!collectionName) throw new HttpsError('invalid-argument', `Type invalide : ${userType}`);
    const accountDoc = await findUniqueAccountByPhone(db, collectionName, phone, normalizedInput);

    if (userType === 'artisan') {
      const pin = String(newValue);
      if (!/^\d{4,6}$/.test(pin)) {
        throw new HttpsError('invalid-argument', 'Le PIN doit contenir 4 a 6 chiffres');
      }
      await accountDoc.ref.update({ artisanPin: pin });
      return { success: true, uid: accountDoc.id };
    }
    if (userType === 'pharmacie') {
      const password = validatePassword(newValue);
      await db.collection('pharmacie_credentials').doc(accountDoc.id).set({
        hash: hashSecret(password), updatedAt: fieldValue.serverTimestamp(),
      });
      await accountDoc.ref.update({
        password: fieldValue.delete(), accessCode: fieldValue.delete(), mustChangePassword: false,
      });
      return { success: true, uid: accountDoc.id };
    }

    const password = validatePassword(newValue);
    const targetUser = await auth.getUser(accountDoc.id);
    if (!targetUser || targetUser.uid !== accountDoc.id) {
      throw new HttpsError('failed-precondition', 'Compte Firebase Auth incoherent');
    }
    await auth.updateUser(accountDoc.id, { password });
    return { success: true, uid: accountDoc.id };
  };
}

module.exports = { buildResetAccountPassword, findUniqueAccountByPhone, normalizePhone, validatePassword };
