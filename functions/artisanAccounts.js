'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { requireAdminPermission } = require('./adminGuards');
const { verifySecret } = require('./passwordHash');
const { validCredential, planDocument, setPin } = require('./artisanCredentials');

// LOT 7.4 / phase A: dual reader only. Login never creates, rotates or
// cleans up credentials. Private credentials remain authoritative, even
// when malformed or accompanied by a conflicting historical public PIN.
function buildArtisanLogin({ db, checkRateLimit }) {
  return async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
    const { phone, pin } = request.data || {};
    if (!phone || !pin) throw new HttpsError('invalid-argument', 'Téléphone et PIN requis');
    await checkRateLimit(`artisan_login_${phone}`, 'artisan_login', 10, 300);
    const candidates = await db.collection('service_providers').where('phone', '==', phone).limit(10).get();
    for (const candidate of candidates.docs) {
      const credentialRef = db.collection('artisan_credentials').doc(candidate.id);
      const result = await db.runTransaction(async (tx) => {
        // Read both documents in one transaction RPC. This reduces round trips,
        // but does not eliminate contention or guarantee retryable errors.
        const [provider, credential] = await tx.getAll(candidate.ref, credentialRef);
        if (!provider.exists || provider.data().phone !== phone) return null;
        const data = provider.data();
        const plan = planDocument(data, credential.exists ? credential.data() : null);
        if (credential.exists) {
          if (!validCredential(credential.data()) || !verifySecret(String(pin), credential.data().hash)) return null;
        } else {
          if (plan.outcome !== 'needs_migration' || String(data.artisanPin) !== String(pin)) return null;
        }
        if (data.artisanUid !== request.auth.uid) {
          tx.update(candidate.ref, { artisanUid: request.auth.uid });
        }
        // Explicit response contract: unknown legacy fields must not leak
        // credentials, identity documents or notification tokens.
        const safeData = {};
        for (const key of ['name', 'phone', 'address', 'description', 'subcategory',
          'category', 'photos', 'lat', 'lng', 'isAvailable', 'isVerified',
          'status', 'rating', 'ratingCount', 'createdAt', 'approvedAt']) {
          if (Object.hasOwn(data, key)) safeData[key] = data[key];
        }
        return { success: true, docId: candidate.id, data: { ...safeData, artisanUid: request.auth.uid } };
      });
      if (result) return result;
    }
    return { success: false };
  };
}

function buildSetArtisanPin({ db, fieldValue }) {
  return async (request) => {
    await requireAdminPermission({ request, db, permission: 'services' });
    const { providerId, pin, approve = false } = request.data || {};
    if (typeof approve !== 'boolean') throw new HttpsError('invalid-argument', 'Approbation invalide');
    return setPin({ db, fieldValue, providerId, pin, approve, actorUid: request.auth.uid });
  };
}

module.exports = { buildArtisanLogin, buildSetArtisanPin };
