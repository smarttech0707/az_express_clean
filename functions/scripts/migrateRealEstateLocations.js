'use strict';

// Master Prompt "IMMOBILIER GPS PRIVÉ ET CONFIDENTIALITÉ RÉELLE V2" — Mission 7.
//
// Script de migration IDEMPOTENT pour les annonces `real_estate_listings`
// créées AVANT ce chantier (donc encore susceptibles d'exposer lat/lng/
// latitude/longitude EXACTS publiquement, aucun `real_estate_private_locations`
// correspondant).
//
// ⚠️ CE SCRIPT N'A JAMAIS ÉTÉ EXÉCUTÉ EN MODE ÉCRITURE DANS CETTE PASSE —
// conformément à l'instruction explicite du prompt ("créer... mais ne pas
// l'exécuter"). Seule sa logique pure est couverte par des tests unitaires
// (functions/test/migrateRealEstateLocations.test.js) contre un faux
// Firestore en mémoire — jamais contre le projet réel.
//
// Usage prévu (PAS exécuté ici) :
//   node functions/scripts/migrateRealEstateLocations.js            (dry-run, défaut)
//   node functions/scripts/migrateRealEstateLocations.js --apply    (écriture réelle)
//
// Stratégie de confidentialité par défaut — décision explicite documentée,
// PAS devinée automatiquement au nom du propriétaire (Mission 7 : "ne pas
// inventer automatiquement la préférence de confidentialité") : chaque
// annonce migrée reçoit `locationPrivacy: 'hidden'`, la stratégie la PLUS
// PRUDENTE possible (aucune coordonnée publique laissée en ligne). Ce
// script ne "devine" jamais que l'agent voulait rester en position exacte —
// un agent qui le souhaite doit repasser explicitement par le formulaire
// (upsertRealEstateLocation) pour choisir 'exact' lui-même, en connaissance
// de cause.
const MIGRATION_MARKER = 'migrateRealEstateLocations_v1';
const DEFAULT_PRIVACY = 'hidden';
const EXPECTED_PROJECT_ID = 'az-express-b0469';

const LEGACY_LOCATION_FIELDS = ['lat', 'lng', 'latitude', 'longitude'];

function hasLegacyExactLocation(data) {
  return LEGACY_LOCATION_FIELDS.some((f) => typeof data[f] === 'number' && Number.isFinite(data[f]));
}

function extractLegacyLatLng(data) {
  const lat = typeof data.lat === 'number' ? data.lat : (typeof data.latitude === 'number' ? data.latitude : null);
  const lng = typeof data.lng === 'number' ? data.lng : (typeof data.longitude === 'number' ? data.longitude : null);
  return { lat, lng };
}

function isValidLatLng(lat, lng) {
  return typeof lat === 'number' && typeof lng === 'number'
    && Number.isFinite(lat) && Number.isFinite(lng)
    && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
    && !(lat === 0 && lng === 0);
}

/**
 * Traite UN document `real_estate_listings` et retourne le plan de migration
 * (jamais l'exécute lui-même — voir `runMigration` pour l'écriture réelle).
 * Retourne { outcome: 'migrated'|'skipped'|'invalid', ... } sans jamais lancer.
 */
function planMigrationForListing(listingId, data, { geohash }) {
  if (data.__migration === MIGRATION_MARKER) {
    return { listingId, outcome: 'skipped', reason: 'already_migrated' };
  }
  if (!hasLegacyExactLocation(data)) {
    return { listingId, outcome: 'skipped', reason: 'no_legacy_location' };
  }
  const { lat, lng } = extractLegacyLatLng(data);
  if (!isValidLatLng(lat, lng)) {
    return { listingId, outcome: 'invalid', reason: 'invalid_coordinates', lat, lng };
  }

  const exactGeohash = geohash.encodeGeohash(lat, lng, geohash.EXACT_PRECISION);
  const privateDoc = {
    listingId,
    ownerId: data.agentId || null,
    agentId: data.agentId || null,
    exactLatitude: lat,
    exactLongitude: lng,
    exactGeohash,
    exactAddress: null,
    exactCity: data.city || null,
    exactQuartier: null,
    locationVerified: false, // migré automatiquement, jamais re-confirmé par l'agent
    __migration: MIGRATION_MARKER,
  };

  // Stratégie la plus prudente par défaut (voir en-tête de fichier) : hidden,
  // donc AUCUNE coordonnée publique dans le document public migré.
  const publicPatch = {
    locationPrivacy: DEFAULT_PRIVACY,
    hasExactLocation: false,
    __migration: MIGRATION_MARKER,
    // Nettoyage explicite des anciens champs publics exacts (Mission 6).
    lat: null, lng: null, latitude: null, longitude: null,
    publicLatitude: null, publicLongitude: null, publicGeohash: null, publicAddress: null,
  };

  return { listingId, outcome: 'migrated', privateDoc, publicPatch };
}

/**
 * Exécute la migration sur une liste de documents déjà chargés (pas de
 * requête Firestore ici — le chargement/l'écriture réelle appartiennent à
 * `runMigration`, ce qui rend cette fonction facilement testable en isolation).
 */
function planMigration(listings, { geohash }) {
  const report = { analyzed: 0, migrated: [], skipped: [], invalid: [] };
  for (const { id, data } of listings) {
    report.analyzed++;
    const plan = planMigrationForListing(id, data, { geohash });
    if (plan.outcome === 'migrated') report.migrated.push(plan);
    else if (plan.outcome === 'invalid') report.invalid.push(plan);
    else report.skipped.push(plan);
  }
  return report;
}

/**
 * Point d'entrée réel (Admin SDK) — jamais appelé automatiquement par ce
 * fichier lui-même (voir garde `require.main === module` tout en bas).
 * `dryRun: true` par défaut — n'écrit jamais sans `--apply` explicite.
 */
async function runMigration({ db, admin, geohash, dryRun = true, log = console.log }) {
  const snap = await db.collection('real_estate_listings').get();
  const listings = snap.docs.map((doc) => ({ id: doc.id, data: doc.data() }));
  const report = planMigration(listings, { geohash });
  const errors = [];

  if (!dryRun) {
    for (const plan of report.migrated) {
      try {
        const now = admin.firestore.FieldValue.serverTimestamp();
        await db.collection('real_estate_private_locations').doc(plan.listingId)
          .set({ ...plan.privateDoc, createdAt: now, updatedAt: now, locationUpdatedAt: now }, { merge: true });
        await db.collection('real_estate_listings').doc(plan.listingId)
          .update({ ...plan.publicPatch, locationUpdatedAt: now, updatedAt: now });
      } catch (err) {
        errors.push({ listingId: plan.listingId, error: err.message });
      }
    }
  }

  const summary = {
    dryRun,
    analyzed: report.analyzed,
    migrated: report.migrated.length,
    skipped: report.skipped.length,
    invalid: report.invalid.length,
    errors: errors.length,
    errorDetails: errors,
  };
  log('[migrateRealEstateLocations] Rapport :', JSON.stringify(summary, null, 2));
  return { summary, report };
}

module.exports = {
  MIGRATION_MARKER,
  DEFAULT_PRIVACY,
  hasLegacyExactLocation,
  extractLegacyLatLng,
  isValidLatLng,
  planMigrationForListing,
  planMigration,
  runMigration,
};

// ── CLI (jamais invoqué automatiquement — garde explicite) ─────────────────
if (require.main === module) {
  const dryRun = !process.argv.includes('--apply');
  console.log(`[migrateRealEstateLocations] Démarrage — mode ${dryRun ? 'DRY-RUN (aucune écriture)' : 'APPLY (écriture réelle)'}.`);
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp();
  const configuredProjectId = admin.app().options.projectId ||
    process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
  if (!configuredProjectId) {
    throw new Error('[migrateRealEstateLocations] ProjectId Firebase indetectable: execution refused.');
  }
  console.log(`[migrateRealEstateLocations] Projet cible: ${configuredProjectId}`);
  if (configuredProjectId !== EXPECTED_PROJECT_ID) {
    throw new Error(`[migrateRealEstateLocations] Projet inattendu (${configuredProjectId}), attendu: ${EXPECTED_PROJECT_ID}. Execution refusee.`);
  }
  const db = admin.firestore();
  const geohash = require('../geohash');
  runMigration({ db, admin, geohash, dryRun })
    .then(() => process.exit(0))
    .catch((err) => { console.error('[migrateRealEstateLocations] ERREUR FATALE:', err); process.exit(1); });
}
