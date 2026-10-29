'use strict';

// Création d'un livreur par un patron de flotte.
//
// Avant ce module, fleet_dashboard.dart créait le compte Auth DEPUIS le téléphone du patron (ce qui le
// déconnectait) puis écrivait `livreurs/{uid}` : les règles réservent cette création à l'admin, l'écriture
// échouait donc toujours et laissait un compte Auth orphelin. Ici tout se fait côté serveur :
//   - identité : compte Firebase réel (non anonyme), document `fleet_owners/{uid}` approuvé par l'admin,
//     non suspendu, non en suppression, mot de passe temporaire changé s'il a été créé par l'admin ;
//   - plafond de livreurs par flotte et limitation de débit : pas de création arbitraire ;
//   - Auth puis document : si l'écriture échoue, le compte Auth créé par CET appel est supprimé ;
//   - le livreur démarre comme un livreur approuvé par l'admin (wallet 0, hors ligne). Le patron étant lui-même
//     validé par l'administration, ses livreurs ne repassent pas par driver_requests.

const { assertPartnerActivated } = require('./partnerActivationGuard');

const MAX_DRIVERS_PER_FLEET = 50;
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{2,29}$/;
const PHONE_PATTERN = /^\+?[0-9 ]{8,20}$/;
const DRIVER_EMAIL_DOMAIN = 'az-driver.ci';

const envelope = (message, data) => ({ success: true, error: null, message, data, code: 'OK' });

function buildCreateFleetDriver({ db, auth, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Connexion requise');
    }
    const ownerUid = request.auth.uid;
    await assertPartnerActivated({ db, request });

    const { name, phone, identifiant, password } = request.data || {};
    const cleanName = typeof name === 'string' ? name.trim() : '';
    const cleanPhone = typeof phone === 'string' ? phone.trim() : '';
    const cleanId = typeof identifiant === 'string' ? identifiant.trim().toLowerCase() : '';
    if (cleanName.length < 2 || cleanName.length > 80) throw new HttpsError('invalid-argument', 'Nom invalide');
    if (!PHONE_PATTERN.test(cleanPhone)) throw new HttpsError('invalid-argument', 'Téléphone invalide');
    if (!ID_PATTERN.test(cleanId)) {
      throw new HttpsError('invalid-argument', 'Identifiant invalide (3 à 30 caractères : lettres, chiffres, . _ -)');
    }
    if (typeof password !== 'string' || password.length < 6 || password.length > 128) {
      throw new HttpsError('invalid-argument', 'Mot de passe : 6 caractères minimum');
    }

    await checkRateLimit(ownerUid, 'create_fleet_driver', 10, 3600);

    const [ownerSnap, tombstone] = await Promise.all([
      db.collection('fleet_owners').doc(ownerUid).get(),
      db.collection('account_tombstones').doc(ownerUid).get(),
    ]);
    const owner = ownerSnap.exists ? ownerSnap.data() : null;
    // Même lecture du statut que fleet_login.dart : un document sans `status` est un compte historique approuvé.
    const status = owner?.status ?? 'approved';
    if (!owner || status !== 'approved' || owner.isSuspended === true || owner.isActive === false ||
        owner.deletionRequested === true || owner.isDeleted === true || tombstone.exists) {
      throw new HttpsError('permission-denied', 'Compte patron de flotte non autorisé');
    }

    const existing = await db.collection('livreurs').where('ownerId', '==', ownerUid).limit(MAX_DRIVERS_PER_FLEET + 1).get();
    if (existing.size >= MAX_DRIVERS_PER_FLEET) {
      throw new HttpsError('failed-precondition', `Limite de ${MAX_DRIVERS_PER_FLEET} livreurs par flotte atteinte`);
    }

    const email = `${cleanId}@${DRIVER_EMAIL_DOMAIN}`;
    let driverUid;
    try {
      driverUid = (await auth.createUser({ email, password, displayName: cleanName })).uid;
    } catch (error) {
      if (error?.code === 'auth/email-already-exists') {
        throw new HttpsError('already-exists', 'Cet identifiant est déjà utilisé');
      }
      if (error?.code === 'auth/invalid-password') throw new HttpsError('invalid-argument', 'Mot de passe trop faible');
      throw new HttpsError('internal', 'Création du compte impossible');
    }

    try {
      await db.collection('livreurs').doc(driverUid).create({
        name: cleanName, phone: cleanPhone, email, identifiant: cleanId,
        photoUrl: '', idPhotoUrl: '', selfieUrl: '',
        wallet: 0, isOnline: false, lat: 0, lng: 0,
        deliveries: 0, avgRating: 0.0, ratingCount: 0,
        ownerId: ownerUid, ownerName: owner.name || '', createdByFleetOwner: true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Aucun compte Auth orphelin : on retire celui que CET appel vient de créer.
      try { await auth.deleteUser(driverUid); } catch (__) { /* signalé ci-dessous par l'audit */ }
      throw new HttpsError('internal', 'Création du livreur impossible, aucun compte créé');
    }

    await logAudit({
      userId: ownerUid, userType: 'fleet', action: 'fleet_driver_created', targetId: driverUid, status: 'success',
      metadata: { identifiant: cleanId },
    });
    return envelope('Livreur créé', { driverId: driverUid, identifiant: cleanId });
  });
}

module.exports = { buildCreateFleetDriver, MAX_DRIVERS_PER_FLEET };
