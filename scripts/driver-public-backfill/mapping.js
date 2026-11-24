'use strict';

// Mapping PUR `livreurs` → `driver_public` (SEC-01, Mission driver_public, préparation S3).
// Aucun accès Firebase ici : fonction pure sur un objet déjà en mémoire (fixture locale
// aujourd'hui ; un futur export réel, hors périmètre de cette phase, devra passer par le
// même format d'entrée). Liste blanche strictement alignée sur `firestore.rules`
// (driverPublicKeysValid / driverPublicTypesValid) : toute divergence entre les deux doit
// être corrigée dans les deux, jamais contournée.
//
// Référence de provenance des champs sources (lecture directe du code, Phase 1 — pas de
// supposition) :
//   - name, photoUrl, idPhotoUrl, selfieUrl, email, identifiant, wallet, isOnline, lat, lng,
//     deliveries, avgRating, ratingCount, createdAt : posés à la création par l'admin
//     (lib/screens/admin/driver_requests_page.dart:30-48). `lat`/`lng` valent 0/0 à la
//     création : ce n'est PAS une position réelle (voir traitement ci-dessous).
//   - lat, lng, heading, speed, isOnline, updatedAt, currentCityId, registeredCityId,
//     fcmToken : réécrits ensuite par lib/services/driver_location_service.dart (GPS),
//     absents tant que le livreur ne s'est jamais connecté/géolocalisé une première fois.
//   - photoUrl : peut aussi être modifié par lib/screens/driver/driver_profil.dart (ou
//     supprimé via FieldValue.delete()).
//   - isOnDelivery : jamais écrit par un écran livreur ; posé uniquement par
//     functions/driverAcceptance.js et functions/driverTransfer.js.
//   - isAvailable : jamais mis à `true` par le code de production (seuls des tests le font) ;
//     mis à `false` uniquement par functions/accountDeletion.js et
//     functions/partnerAccountDeletion.js (suspension/suppression). Absent dans l'immense
//     majorité des documents réels.
//   - avgRating / ratingCount : recalculés par functions/driverRatings.js après chaque
//     commande notée ; jamais écrits par un écran livreur.
//
// NOTE IMPORTANTE (documentée, pas contournée) : `functions/lot.js` n'existe pas dans ce
// dépôt. Le seul fichier `lot.js` du dépôt est `scripts/restaurant-v2-pilot/lot.js`, qui
// définit le lot de test T7E (Restaurant V2) — sans rapport avec `livreurs`/`driver_public`,
// et explicitement hors périmètre de cette mission (« Ne pas toucher au pilote T7E »). Il n'a
// donc pas été lu ni utilisé pour ce mapping ; l'inventaire ci-dessus s'appuie uniquement sur
// le code source réel qui écrit `livreurs`.

const FIELD_MAP = Object.freeze({
  name: 'string', photoUrl: 'string', lat: 'geo-lat', lng: 'geo-lng',
  heading: 'number', speed: 'number', updatedAt: 'timestamp',
  isOnline: 'boolean', isAvailable: 'boolean', isOnDelivery: 'boolean',
  avgRating: 'number', ratingCount: 'non-negative-int',
});

// Champs sources qui ne doivent JAMAIS apparaître dans la sortie — recopiés depuis
// l'inventaire S1/S1.1/S2 et la lecture directe de driver_requests_page.dart.
const FORBIDDEN_FIELDS = Object.freeze([
  'wallet', 'phone', 'fcmToken', 'token', 'ownerId', 'ownerName', 'isSuspended',
  'deletionRequested', 'pendingOrderId', 'identifiant', 'idPhotoUrl', 'selfieUrl',
  'email', 'currentCityId', 'registeredCityId', 'createdAt', 'deliveries',
]);

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Transforme UN document source `livreurs` en projection `driver_public`.
 * Ne fabrique jamais une valeur absente ; chaque omission est tracée dans `warnings`.
 * Toute valeur de type incorrect est tracée dans `excluded` (pas silencieusement ignorée).
 */
function mapDriverToPublic(driverId, source) {
  if (!isPlainObject(source)) {
    return { driverId, included: {}, excluded: [], warnings: ['document source absent ou invalide'], ok: false };
  }

  const included = {};
  const excluded = [];
  const warnings = [];

  // lat/lng traités ensemble : {0,0} est le placeholder de création
  // (driver_requests_page.dart), jamais une position réelle — ne jamais la recopier comme telle.
  if ('lat' in source || 'lng' in source) {
    const lat = source.lat;
    const lng = source.lng;
    const bothNumbers = typeof lat === 'number' && typeof lng === 'number';
    if (bothNumbers && lat === 0 && lng === 0) {
      warnings.push('lat/lng = 0,0 (placeholder de création, jamais une position réelle) : exclus');
    } else if (!bothNumbers || !Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      excluded.push({ field: 'lat/lng', reason: 'valeur hors plage ou non numérique' });
    } else {
      included.lat = lat;
      included.lng = lng;
    }
  } else {
    warnings.push('lat/lng absents de la source : omis, jamais fabriqués');
  }

  for (const field of ['heading', 'speed']) {
    if (!(field in source)) { warnings.push(`${field} absent de la source : omis`); continue; }
    const v = source[field];
    if (typeof v === 'number' && Number.isFinite(v)) included[field] = v;
    else excluded.push({ field, reason: 'non numérique' });
  }

  if ('updatedAt' in source) {
    const ts = source.updatedAt;
    const ms = ts && typeof ts.toMillis === 'function' ? ts.toMillis() : (typeof ts === 'number' ? ts : null);
    if (ms !== null && Number.isFinite(ms)) included.updatedAt = ts;
    else excluded.push({ field: 'updatedAt', reason: 'format non reconnu (ni Timestamp, ni nombre de millisecondes)' });
  } else {
    warnings.push('updatedAt absent de la source : omis (jamais fixé à « maintenant » par ce mapping)');
  }

  for (const field of ['isOnline', 'isAvailable', 'isOnDelivery']) {
    if (!(field in source)) { warnings.push(`${field} absent de la source : omis`); continue; }
    if (typeof source[field] === 'boolean') included[field] = source[field];
    else excluded.push({ field, reason: 'non booléen' });
  }

  if ('name' in source) {
    if (typeof source.name === 'string' && source.name.trim().length > 0) included.name = source.name.slice(0, 160);
    else warnings.push('name vide ou non textuel : omis');
  } else {
    warnings.push('name absent de la source : omis');
  }

  if ('photoUrl' in source) {
    if (typeof source.photoUrl === 'string' && source.photoUrl.trim().length > 0) included.photoUrl = source.photoUrl.slice(0, 2048);
    else warnings.push('photoUrl vide ou non textuel : omis (pas d\'URL cassée copiée)');
  } else {
    warnings.push('photoUrl absent de la source : omis');
  }

  if ('avgRating' in source) {
    const v = source.avgRating;
    if (typeof v === 'number' && Number.isFinite(v)) included.avgRating = v;
    else excluded.push({ field: 'avgRating', reason: 'non numérique' });
  } else {
    warnings.push('avgRating absent de la source : omis');
  }

  if ('ratingCount' in source) {
    const v = source.ratingCount;
    if (typeof v === 'number' && Number.isInteger(v) && v >= 0) included.ratingCount = v;
    else excluded.push({ field: 'ratingCount', reason: 'non entier ou négatif' });
  } else {
    warnings.push('ratingCount absent de la source : omis');
  }

  // Garde-fous redondants et volontaires : même si un bug apparaissait ci-dessus, la sortie
  // ne doit jamais contenir un champ interdit ni une clé hors liste blanche.
  const forbiddenPresent = FORBIDDEN_FIELDS.filter((f) => f in included);
  if (forbiddenPresent.length) {
    throw new Error(`BUG mapping : champ interdit présent dans la sortie : ${forbiddenPresent.join(',')}`);
  }
  const unknown = Object.keys(included).filter((k) => !(k in FIELD_MAP));
  if (unknown.length) {
    throw new Error(`BUG mapping : clé non whitelistée produite : ${unknown.join(',')}`);
  }

  return { driverId, included, excluded, warnings, ok: excluded.length === 0 };
}

module.exports = { mapDriverToPublic, FIELD_MAP, FORBIDDEN_FIELDS };
