'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { requireAdminPermission } = require('./adminGuards');
const { verifySecret } = require('./passwordHash');
const { validCredential, planDocument, credentialFor, setPin } = require('./artisanCredentials');

function buildArtisanLogin({ db, fieldValue, checkRateLimit }) {
  return async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
    const { phone, pin } = request.data || {};
    if (!phone || !pin) throw new HttpsError('invalid-argument', 'Téléphone et PIN requis');
    await checkRateLimit(`artisan_login_${phone}`, 'artisan_login', 10, 300);
    const candidates = await db.collection('service_providers').where('phone', '==', phone).limit(10).get();
    for (const candidate of candidates.docs) {
      const credentialRef = db.collection('artisan_credentials').doc(candidate.id);
      const result = await db.runTransaction(async (tx) => {
        const provider = await tx.get(candidate.ref);
        const credential = await tx.get(credentialRef);
        if (!provider.exists || provider.data().phone !== phone) return null;
        const data = provider.data();
        const plan = planDocument(data, credential.exists ? credential.data() : null);
        if (credential.exists) {
          if (!validCredential(credential.data()) || !verifySecret(String(pin), credential.data().hash)) return null;
        } else {
          if (plan.outcome !== 'needs_migration' || String(data.artisanPin) !== String(pin)) return null;
          tx.set(credentialRef, credentialFor(String(pin), fieldValue));
        }
        tx.update(candidate.ref, {
          artisanUid: request.auth.uid,
          ...(['needs_migration', 'resume_cleanup'].includes(plan.outcome)
            ? { artisanPin: fieldValue.delete() } : {}),
        });
        const { artisanPin: omitted, ...safeData } = data;
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
