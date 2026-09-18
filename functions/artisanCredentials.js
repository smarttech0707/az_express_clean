'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { hashSecret, verifySecret } = require('./passwordHash');

function validCredential(data) {
  return typeof data?.hash === 'string' && /^[a-f0-9]{32}:[a-f0-9]{128}$/.test(data.hash);
}

// Only safe classifications leave this function. Existing private credentials
// are authoritative; a conflicting public value requires explicit resolution.
function planDocument(data, credential) {
  const hasField = Object.prototype.hasOwnProperty.call(data, 'artisanPin');
  const legacy = hasField ? data.artisanPin : null;
  const hasPlainPin = legacy != null && String(legacy).length > 0;
  const hasCredential = credential != null;
  const result = (outcome, reason = null) => ({ outcome, reason, hasPlainPin, hasCredential });
  if (hasCredential && !validCredential(credential)) return result('anomaly', 'invalid_credential');
  if (hasPlainPin) {
    // Preserve the exact historical value, including leading zeros. Never trim
    // a value that authentication previously compared verbatim.
    if (typeof legacy !== 'string' && typeof legacy !== 'number') return result('anomaly', 'invalid_legacy');
    if (!hasCredential) return result('needs_migration');
    return verifySecret(String(legacy), credential.hash)
      ? result('resume_cleanup') : result('anomaly', 'credential_mismatch');
  }
  if (!hasCredential && data.status === 'approved') return result('anomaly', 'missing_credential');
  if (hasField && hasCredential) return result('resume_cleanup');
  return result('clean');
}

function credentialFor(pin, fieldValue, extra = {}) {
  const hash = hashSecret(pin);
  if (!verifySecret(pin, hash)) throw new HttpsError('internal', 'Credential non vérifiable');
  return { hash, updatedAt: fieldValue.serverTimestamp(), ...extra };
}

async function migrateProvider({ db, fieldValue, providerId, dryRun = true }) {
  const providerRef = db.collection('service_providers').doc(providerId);
  const credentialRef = db.collection('artisan_credentials').doc(providerId);
  return db.runTransaction(async (tx) => {
    const provider = await tx.get(providerRef);
    const credential = await tx.get(credentialRef);
    if (!provider.exists) return { outcome: 'clean', reason: 'removed', hasPlainPin: false, hasCredential: credential.exists };
    const plan = planDocument(provider.data(), credential.exists ? credential.data() : null);
    if (dryRun || !['needs_migration', 'resume_cleanup'].includes(plan.outcome)) return plan;
    if (plan.outcome === 'needs_migration') {
      tx.set(credentialRef, credentialFor(String(provider.data().artisanPin), fieldValue,
        { migratedVia: 'artisan_pin_v2' }));
    }
    // For a partial old migration, planDocument has verified the existing hash.
    // Both reads participate in conflict detection; no stale PIN can overwrite
    // a concurrent rotation, and deletion cannot commit without its credential.
    tx.update(providerRef, { artisanPin: fieldValue.delete() });
    return plan;
  });
}

async function setPin({ db, fieldValue, providerId, pin, approve = false, actorUid = null, expectedPhone }) {
  if (typeof providerId !== 'string' || !providerId || providerId.includes('/') ||
      !/^\d{4,6}$/.test(String(pin))) {
    throw new HttpsError('invalid-argument', 'Prestataire requis et PIN de 4 à 6 chiffres');
  }
  const providerRef = db.collection('service_providers').doc(providerId);
  const credentialRef = db.collection('artisan_credentials').doc(providerId);
  const auditRef = db.collection('audit_logs').doc();
  const nextCredential = credentialFor(String(pin), fieldValue);
  return db.runTransaction(async (tx) => {
    const provider = await tx.get(providerRef);
    const current = await tx.get(credentialRef);
    if (!provider.exists) throw new HttpsError('not-found', 'Prestataire introuvable');
    const data = provider.data();
    if (expectedPhone !== undefined && data.phone !== expectedPhone) {
      throw new HttpsError('failed-precondition', 'Le compte a changé, recommencez la vérification');
    }
    if (approve && data.status === 'approved') {
      if (!validCredential(current.data())) {
        throw new HttpsError('failed-precondition', 'Compte approuvé sans credential valide : réinitialisation requise');
      }
      // A repeated approval must never rotate a PIN changed after approval.
      return { success: true, alreadyApproved: true, pinSet: verifySecret(String(pin), current.data().hash) };
    }
    if (approve && data.status !== 'pending') {
      throw new HttpsError('failed-precondition', 'Seule une demande en attente peut être approuvée');
    }
    tx.set(credentialRef, nextCredential);
    tx.update(providerRef, {
      artisanPin: fieldValue.delete(),
      ...(approve ? { status: 'approved', isAvailable: true, approvedAt: fieldValue.serverTimestamp() } : {}),
    });
    tx.set(auditRef, {
      userId: actorUid, userType: approve ? 'admin' : 'authenticated',
      action: approve ? 'approve_artisan' : 'set_artisan_pin',
      targetId: providerId, status: 'success', createdAt: fieldValue.serverTimestamp(),
    });
    return { success: true, alreadyApproved: false, pinSet: true };
  });
}

module.exports = { validCredential, planDocument, credentialFor, migrateProvider, setPin };
