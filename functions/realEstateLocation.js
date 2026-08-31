'use strict';

// Master Prompt "IMMOBILIER GPS PRIVÉ ET CONFIDENTIALITÉ RÉELLE V2" — sépare
// la coordonnée EXACTE d'une annonce (jamais publique si locationPrivacy
// vaut approximate/hidden) de ce qui est réellement affichable dans le
// document public `real_estate_listings`, lu par n'importe quel utilisateur
// authentifié. Voir CLAUDE.md pour le contexte complet.
//
// `ownerId` == `agentId` dans ce projet : il n'existe aucun rôle "propriétaire
// du bien" distinct de l'agent immobilier dans le schéma réel (`real_estate_agents`
// est le seul type de compte gérant des annonces) — documenté explicitement
// plutôt que d'inventer une distinction qui n'existe nulle part dans le code.

const { encodeGeohash, approximateCoordinates, EXACT_PRECISION } = require('./geohash');
const { requireSuperAdmin } = require('./adminGuards');

const VALID_PRIVACY = ['exact', 'approximate', 'hidden'];

function isValidLatLng(lat, lng) {
  if (typeof lat !== 'number' || typeof lng !== 'number') return false;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return false;
  // (0,0) n'est jamais une vraie position ici (golfe de Guinée, loin de toute
  // annonce réelle) — toujours le signe d'un échec GPS silencieux ou d'un
  // sentinel non voulu, jamais accepté.
  if (lat === 0 && lng === 0) return false;
  return true;
}

function createRealEstateLocationFunctions({ db, admin, onCall, HttpsError, logAudit, checkRateLimit }) {
  async function assertCallerAuthorized(request, listing) {
    const uid = request.auth.uid;
    try {
      await requireSuperAdmin({ request, db });
      return;
    } catch (error) {
      if (listing.agentId !== uid) throw error;
    }

    // Jamais un rôle envoyé par le client : toujours re-dérivé de l'annonce
    // déjà en base et du document agent déjà en base.
    if (listing.agentId !== uid) {
      throw new HttpsError('permission-denied',
        "Vous n'êtes pas autorisé à modifier la localisation de cette annonce.");
    }
    const agentSnap = await db.collection('real_estate_agents').doc(uid).get();
    if (!agentSnap.exists || agentSnap.data().isVerified !== true || agentSnap.data().isActive !== true) {
      throw new HttpsError('permission-denied', 'Compte agent non vérifié ou inactif.');
    }
  }

  const upsertRealEstateLocation = onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté.');
    const uid = request.auth.uid;
    await checkRateLimit(uid, 'real_estate_location_upsert', 20, 3600);

    const { listingId, latitude, longitude, locationPrivacy, address, city, quartier, locationLabel } =
      request.data || {};

    if (!listingId || typeof listingId !== 'string') {
      throw new HttpsError('invalid-argument', 'listingId manquant.');
    }
    if (!VALID_PRIVACY.includes(locationPrivacy)) {
      throw new HttpsError('invalid-argument', 'locationPrivacy doit être exact, approximate ou hidden.');
    }
    if (!isValidLatLng(latitude, longitude)) {
      throw new HttpsError('invalid-argument', 'Coordonnées GPS invalides (0,0 refusé).');
    }

    const listingRef = db.collection('real_estate_listings').doc(listingId);
    const listingSnap = await listingRef.get();
    if (!listingSnap.exists) throw new HttpsError('not-found', 'Annonce introuvable.');
    const listing = listingSnap.data();

    await assertCallerAuthorized(request, listing);

    // ownerId/agentId proviennent EXCLUSIVEMENT de l'annonce déjà en base —
    // jamais du payload client — pour empêcher tout changement de propriété.
    const ownerId = listing.agentId;
    const agentId = listing.agentId;

    const exactGeohash = encodeGeohash(latitude, longitude, EXACT_PRECISION);
    const now = admin.firestore.FieldValue.serverTimestamp();

    const privateRef = db.collection('real_estate_private_locations').doc(listingId);
    const privateSnap = await privateRef.get();
    const previousCreatedAt = privateSnap.exists ? privateSnap.data().createdAt : null;

    await privateRef.set({
      listingId,
      ownerId,
      agentId,
      exactLatitude: latitude,
      exactLongitude: longitude,
      exactGeohash,
      exactAddress: address ? String(address).trim() : null,
      exactCity: city ? String(city).trim() : null,
      exactQuartier: quartier ? String(quartier).trim() : null,
      locationVerified: true,
      locationUpdatedAt: now,
      createdAt: previousCreatedAt || now,
      updatedAt: now,
    }, { merge: true });

    // Payload public strictement dérivé de locationPrivacy — jamais les
    // coordonnées exactes pour approximate/hidden. Les anciens champs
    // publics exacts (lat/lng/latitude/longitude hérités) sont toujours
    // retirés par ce chemin : `publicLatitude`/`publicLongitude` devient la
    // seule source publique, pour ne jamais laisser une copie résiduelle
    // incohérente avec `locationPrivacy` (Master Prompt Mission 6).
    const publicUpdate = {
      locationPrivacy,
      quartier: quartier ? String(quartier).trim() : admin.firestore.FieldValue.delete(),
      locationLabel: locationLabel ? String(locationLabel).trim() : admin.firestore.FieldValue.delete(),
      locationUpdatedAt: now,
      updatedAt: now,
      lat: admin.firestore.FieldValue.delete(),
      lng: admin.firestore.FieldValue.delete(),
      latitude: admin.firestore.FieldValue.delete(),
      longitude: admin.firestore.FieldValue.delete(),
    };
    if (city) publicUpdate.city = String(city).trim();

    if (locationPrivacy === 'exact') {
      publicUpdate.publicLatitude = latitude;
      publicUpdate.publicLongitude = longitude;
      publicUpdate.publicGeohash = exactGeohash;
      publicUpdate.publicAddress = address
        ? String(address).trim()
        : admin.firestore.FieldValue.delete();
      publicUpdate.hasExactLocation = true;
    } else if (locationPrivacy === 'approximate') {
      const approx = approximateCoordinates(latitude, longitude);
      publicUpdate.publicLatitude = approx.latitude;
      publicUpdate.publicLongitude = approx.longitude;
      publicUpdate.publicGeohash = approx.geohash;
      // Jamais l'adresse exacte à côté d'une position volontairement floutée.
      publicUpdate.publicAddress = admin.firestore.FieldValue.delete();
      publicUpdate.hasExactLocation = false;
    } else {
      // hidden : aucune coordonnée publique, sous aucune forme.
      publicUpdate.publicLatitude = admin.firestore.FieldValue.delete();
      publicUpdate.publicLongitude = admin.firestore.FieldValue.delete();
      publicUpdate.publicGeohash = admin.firestore.FieldValue.delete();
      publicUpdate.publicAddress = admin.firestore.FieldValue.delete();
      publicUpdate.hasExactLocation = false;
    }

    await listingRef.update(publicUpdate);

    await logAudit({
      userId: uid, userType: 'real_estate_agent', action: 'real_estate_location_upsert',
      targetId: listingId, status: 'success',
      // Jamais les coordonnées elles-mêmes dans le journal d'audit.
      metadata: { locationPrivacy },
    });

    return { success: true, listingId, locationPrivacy, hasExactLocation: locationPrivacy === 'exact' };
  });

  return { upsertRealEstateLocation };
}

module.exports = { createRealEstateLocationFunctions, isValidLatLng, VALID_PRIVACY };
