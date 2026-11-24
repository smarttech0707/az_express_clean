'use strict';

// Synchronisation serveur `livreurs` → `driver_public` (SEC-01, Mission driver_public).
// Projette UNIQUEMENT les 7 champs non-GPS déjà whitelistés par `firestore.rules`
// (driverPublicKeysValid/driverPublicTypesValid, phase S2) : name, photoUrl, isOnline,
// isAvailable, isOnDelivery, avgRating, ratingCount. Les champs GPS (lat/lng/heading/speed/
// updatedAt) restent exclusivement gérés par la double écriture client (S4/S4.1, déjà validée,
// 64 tests) — ce module ne les lit, ne les écrit et ne les efface JAMAIS.
//
// SEC-01 / S5.3.3 — RECONCILIATION PAR LECTURE LIVE (remplace la version S5.2/S5.3.1 qui
// faisait confiance au couple before/after de l'événement déclencheur) :
//
// S5.3.2 a démontré que Cloud Firestore/Cloud Functions ne garantissent aucun ordre
// d'exécution entre événements rapprochés sur un même document (RISK A), et qu'un événement
// retardé après une suppression peut recréer une fiche `driver_public` fantôme (RISK B). La
// correction retenue : ne plus jamais faire confiance aux données `before`/`after` portées par
// l'événement — chaque exécution relit l'état COURANT de `livreurs` et de `driver_public` dans
// une transaction Firestore, et reconstruit la projection à partir de cet état réel. L'événement
// devient un simple signal de réveil (« quelque chose a changé, va vérifier »), jamais un
// porteur de données. Un événement en retard lit donc forcément l'état le plus récent au moment
// où il s'exécute enfin — il ne peut plus écraser `driver_public` avec une valeur périmée.
//
// Fonctions pures, testables sans Firebase (même pattern que driverRatings.js) : la logique de
// calcul du correctif (computeDriverPublicPatch) ne dépend d'aucun SDK et reste inchangée depuis
// S5.2 — seule la source de son paramètre `before` change (voir plus bas).

const DRIVER_PUBLIC_FIELDS = Object.freeze([
  'name', 'photoUrl', 'isOnline', 'isAvailable', 'isOnDelivery', 'avgRating', 'ratingCount',
]);

// Champs GPS gérés exclusivement par S4/S4.1 (double écriture client) : jamais lus, jamais
// écrits par ce module. Utilisé uniquement pour détecter leur PRÉSENCE dans `driver_public`
// (sans jamais lire leur valeur) lors d'une invalidation après suppression de la source (RISK B).
const GPS_PROJECTION_FIELDS = Object.freeze(['lat', 'lng', 'heading', 'speed', 'updatedAt']);

// Validation de type strictement alignée sur `driverPublicTypesValid()` (firestore.rules, S2) :
// l'Admin SDK ignore les règles à l'écriture, donc cette vérification est la SEULE protection
// contre l'écriture d'une valeur mal typée dans `driver_public` depuis ce chemin serveur.
function isValidFieldValue(field, value) {
  switch (field) {
    case 'name':
      return typeof value === 'string' && value.trim().length > 0;
    case 'photoUrl':
      return typeof value === 'string' && value.trim().length > 0;
    case 'isOnline':
    case 'isAvailable':
    case 'isOnDelivery':
      return typeof value === 'boolean';
    case 'avgRating':
      return typeof value === 'number' && Number.isFinite(value);
    case 'ratingCount':
      return typeof value === 'number' && Number.isInteger(value) && value >= 0;
    default:
      return false;
  }
}

function clamp(field, value) {
  if (field === 'name') return value.length > 160 ? value.slice(0, 160) : value;
  if (field === 'photoUrl') return value.length > 2048 ? value.slice(0, 2048) : value;
  return value;
}

/**
 * Calcule le correctif à écrire dans `driver_public/{driverId}`. Fonction PURE : ne lit ni
 * n'écrit Firestore, ne connaît pas `FieldValue`.
 *
 * Depuis S5.3.3, `before` n'est plus l'état HISTORIQUE de `livreurs` porté par l'événement :
 * c'est l'état COURANT de `driver_public` (les 7 champs déjà projetés), lu dans la même
 * transaction que `after`. La sémantique de comparaison reste identique (champ inchangé → pas
 * de réécriture, champ disparu → suppression), mais la comparaison porte maintenant sur « ce
 * qui est déjà projeté » vs « ce que la source dit maintenant », ce qui rend la fonction
 * idempotente et sûre face à un ordre d'exécution quelconque : peu importe quel événement a
 * déclenché l'exécution, le résultat ne dépend que de l'état réel au moment de la lecture.
 *
 * Pour chacun des 7 champs whitelistés :
 * - présent et valide dans `after`, différent de la projection actuelle → inclus (nouvelle
 *   valeur) ;
 * - présent et valide dans `after`, identique à la projection actuelle → ignoré (pas de
 *   réécriture inutile) ;
 * - présent mais de type invalide dans `after` → ignoré, jamais écrit tel quel (tracé dans
 *   `skipped`, sans bloquer la synchronisation des autres champs) ;
 * - absent de `after` alors qu'il était déjà projeté (ex. anonymisation RGPD de
 *   `accountDeletion.js`, qui retire `name`/`photoUrl` via FieldValue.delete()) → marqué pour
 *   suppression (`toDelete`) ;
 * - absent des deux côtés → ignoré.
 *
 * Retourne `{ fields: {champ: valeur}, toDelete: [champs...], hasChanges: bool, skipped: [...] }`.
 * `hasChanges` conditionne l'écriture elle-même : aucune écriture Firestore si rien n'a changé.
 */
function computeDriverPublicPatch({ before, after }) {
  const b = before && typeof before === 'object' ? before : {};
  const a = after && typeof after === 'object' ? after : {};
  const fields = {};
  const toDelete = [];
  const skipped = [];

  for (const field of DRIVER_PUBLIC_FIELDS) {
    const wasPresent = Object.hasOwn(b, field);
    const isPresent = Object.hasOwn(a, field);

    if (!isPresent) {
      if (wasPresent) toDelete.push(field);
      continue;
    }

    const value = a[field];
    if (!isValidFieldValue(field, value)) {
      skipped.push({ field, reason: 'invalid-type' });
      continue;
    }

    const clamped = clamp(field, value);
    if (wasPresent && b[field] === clamped) continue; // déjà projeté, rien à réécrire
    fields[field] = clamped;
  }

  return {
    fields,
    toDelete,
    skipped,
    hasChanges: Object.keys(fields).length > 0 || toDelete.length > 0,
  };
}

/**
 * Construit le payload Firestore réel (avec `FieldValue.delete()`) à partir du correctif pur
 * ci-dessus. Seule fonction de ce module qui connaît `admin`.
 */
function buildFirestorePatch(admin, patch) {
  const data = { ...patch.fields };
  for (const field of patch.toDelete) data[field] = admin.firestore.FieldValue.delete();
  return data;
}

/**
 * Invalidation contrôlée de `driver_public/{driverId}` lorsque `livreurs/{driverId}` n'existe
 * plus au moment de la lecture (RISK B, S5.3.2 §9) — appelée UNIQUEMENT depuis l'intérieur
 * d'une transaction déjà ouverte (voir `reconcileDriverPublicFromSource`). Ne recrée jamais la
 * fiche : au mieux, elle la nettoie ; au pire (déjà absente), elle ne fait rien.
 *
 * Stratégie retenue (S5.3.3, Phase 3) : si aucun champ GPS (S4) n'est présent, le document
 * entier est supprimé (cas normal : plus rien à projeter publiquement). Si des champs GPS
 * existent encore (cas marginal : un événement non-GPS en retard croise une projection GPS
 * encore fraîche), seuls les 7 champs non-GPS sont effacés — jamais le document entier, pour ne
 * jamais supprimer une position GPS encore valide que S4 continue d'alimenter séparément.
 */
function invalidateIfOrphaned({ tx, admin, publicRef, publicSnap }) {
  if (!publicSnap.exists) return { written: false, reason: 'already-absent' };
  const data = publicSnap.data() || {};
  const hasGps = GPS_PROJECTION_FIELDS.some((field) => Object.hasOwn(data, field));

  if (!hasGps) {
    tx.delete(publicRef);
    return { deleted: true, reason: 'source-missing-no-gps' };
  }

  const invalidation = {};
  let any = false;
  for (const field of DRIVER_PUBLIC_FIELDS) {
    if (Object.hasOwn(data, field)) {
      invalidation[field] = admin.firestore.FieldValue.delete();
      any = true;
    }
  }
  if (!any) return { written: false, reason: 'already-clean' };
  tx.set(publicRef, invalidation, { merge: true });
  return { invalidated: true, reason: 'source-missing-gps-preserved' };
}

/**
 * Point d'entrée commun aux triggers `onDocumentCreated`/`onDocumentUpdated` (SEC-01, S5.3.3).
 * Ignore volontairement les données de l'événement déclencheur : relit `livreurs/{driverId}`
 * ET `driver_public/{driverId}` dans une seule transaction Firestore, puis écrit le correctif
 * dans la même transaction. La transaction garantit que si l'un des deux documents lus change
 * avant que l'écriture ne soit validée, Firestore rejoue automatiquement toute la fonction avec
 * un état relu à jour (voir `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md`, §7, pour l'analyse précise
 * de ce que cette garantie couvre et ne couvre pas).
 */
async function reconcileDriverPublicFromSource({ db, admin, driverId }) {
  const sourceRef = db.collection('livreurs').doc(driverId);
  const publicRef = db.collection('driver_public').doc(driverId);

  return db.runTransaction(async (tx) => {
    const [sourceSnap, publicSnap] = await Promise.all([tx.get(sourceRef), tx.get(publicRef)]);

    if (!sourceSnap.exists) {
      return invalidateIfOrphaned({ tx, admin, publicRef, publicSnap });
    }

    const after = sourceSnap.data() || {};
    const before = publicSnap.exists ? (publicSnap.data() || {}) : {};
    const patch = computeDriverPublicPatch({ before, after });
    if (!patch.hasChanges) return { written: false, reason: 'no-changes' };

    tx.set(publicRef, buildFirestorePatch(admin, patch), { merge: true });
    return { written: true, patch };
  });
}

/**
 * Point d'entrée appelé par le trigger `onDocumentCreated('livreurs/{driverId}')`. Délègue
 * intégralement à `reconcileDriverPublicFromSource` — aucune logique propre : la création n'est
 * qu'un cas particulier de reconciliation où `driver_public` n'existe généralement pas encore.
 */
async function syncDriverPublicOnCreate({ db, admin, driverId }) {
  return reconcileDriverPublicFromSource({ db, admin, driverId });
}

/**
 * Point d'entrée appelé par le trigger `onDocumentUpdated('livreurs/{driverId}')`. Même
 * délégation que `syncDriverPublicOnCreate` — depuis S5.3.3, création et mise à jour exécutent
 * exactement le même code (reconciliation depuis l'état courant), ce qui élimine par
 * construction tout traitement différencié qui pourrait diverger entre les deux triggers.
 */
async function syncDriverPublicOnUpdate({ db, admin, driverId }) {
  return reconcileDriverPublicFromSource({ db, admin, driverId });
}

/**
 * Point d'entrée appelé par le trigger `onDocumentDeleted('livreurs/{driverId}')`. La clôture
 * de compte normale (accountDeletion.js) n'efface jamais `livreurs` (anonymisation en place) :
 * ce chemin ne couvre que la suppression directe et définitive (ex. admin, drivers_page.dart).
 *
 * SEC-01 / S5.3.3 — garde de recréation (RISK B, scénario « suppression répétée ») : si cet
 * événement de suppression est en retard et que `livreurs/{driverId}` existe À NOUVEAU au
 * moment de l'exécution (le même identifiant a été recréé avant que cet événement obsolète ne
 * s'exécute), la suppression est annulée — supprimer `driver_public` effacerait la projection
 * d'un livreur qui existe de nouveau. Le trigger `onDocumentCreated`/`onDocumentUpdated`
 * correspondant à cette recréation se chargera de la (re)projeter correctement.
 */
async function syncDriverPublicOnDelete({ db, driverId }) {
  const sourceRef = db.collection('livreurs').doc(driverId);
  const publicRef = db.collection('driver_public').doc(driverId);

  return db.runTransaction(async (tx) => {
    const sourceSnap = await tx.get(sourceRef);
    if (sourceSnap.exists) {
      return { deleted: false, reason: 'source-recreated' };
    }
    tx.delete(publicRef);
    return { deleted: true };
  });
}

module.exports = {
  DRIVER_PUBLIC_FIELDS,
  GPS_PROJECTION_FIELDS,
  isValidFieldValue,
  computeDriverPublicPatch,
  buildFirestorePatch,
  reconcileDriverPublicFromSource,
  syncDriverPublicOnCreate,
  syncDriverPublicOnUpdate,
  syncDriverPublicOnDelete,
};
