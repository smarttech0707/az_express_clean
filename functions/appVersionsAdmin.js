'use strict';

// Modification SÉCURISÉE de `config/app_versions` (version minimale des applications) — Mission M2.2.
//
// Les règles Firestore interdisent toute écriture cliente de ce document, même super-administrateur : cette fonction
// (Admin SDK) est la seule voie. Elle ne rend AUCUNE politique active : `enforce: true` est refusé (l'activation d'un
// blocage reste une décision distincte, hors de cette fonction).
//
// Contrôles : super-administrateur actif (readValidAdmin, MFA selon ADMIN_MFA_MODE) ; limitation de débit ; validation
// stricte (rôles, champs connus, builds entiers, message, liens https d'hôtes connus) alignée sur MinVersionService
// (lib/services/min_version_service.dart) ; version du document (concurrence optimiste) ; journal d'audit avant/après.
//
// Garde « dernier build publié » : le dépôt ne peut PAS connaître le dernier build réellement publié sur Play / App Store.
// Il n'est donc jamais déduit ni inventé. Il est lu dans `config/app_release_registry` (écrit uniquement par l'Admin SDK,
// après vérification humaine dans la console du store) :
//   { android: { latestBuild: 11, source: "Play Console, piste production", verifiedAt: <Timestamp> }, ios: { ... } }
// Définir ou RELEVER un minBuild exige une entrée vérifiée de chaque plateforme concernée et minBuild <= latestBuild.
// Registre absent ou invalide = refus (code PUBLISHED_BUILD_UNVERIFIED). Baisser ou retirer une contrainte reste permis.

const CONFIG = 'config';
const DOC = 'app_versions';
const REGISTRY_DOC = 'app_release_registry';

const ROLES = Object.freeze(['driver', 'client', 'restaurant', 'seller', 'boulangerie', 'pharmacie', 'artisan',
  'fleet', 'immobilier', 'ekbine', 'admin']);
const MAX_BUILD = 2100000000;
const MAX_MESSAGE = 500;
const UPDATE_HOSTS = new Set(['az-express-b0469.web.app', 'play.google.com', 'apps.apple.com']);
const BUILD_FIELDS = ['minBuild', 'minBuildAndroid', 'minBuildIos'];
const URL_FIELDS = ['updateUrl', 'updateUrlAndroid', 'updateUrlIos'];
const ALLOWED_FIELDS = new Set([...BUILD_FIELDS, ...URL_FIELDS, 'message', 'enforce']);

class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const isBuild = (v) => Number.isInteger(v) && v >= 1 && v <= MAX_BUILD;

/** Valide l'entrée d'un rôle ; retourne l'objet normalisé ou lève Refusal. */
function validateRoleValues(values) {
  if (!values || typeof values !== 'object' || Array.isArray(values)) {
    throw new Refusal('INVALID_VALUES', 'values doit être une table (ou null pour retirer l’entrée).');
  }
  const out = {};
  for (const [key, value] of Object.entries(values)) {
    if (!ALLOWED_FIELDS.has(key)) throw new Refusal('UNKNOWN_FIELD', `Champ inconnu : ${key}.`);
    if (BUILD_FIELDS.includes(key)) {
      if (!isBuild(value)) throw new Refusal('INVALID_BUILD', `${key} doit être un entier de 1 à ${MAX_BUILD}.`);
      out[key] = value;
    } else if (URL_FIELDS.includes(key)) {
      let url = null;
      try { url = typeof value === 'string' ? new URL(value.trim()) : null; } catch (_) { url = null; }
      if (!url || url.protocol !== 'https:' || url.username || url.password || !UPDATE_HOSTS.has(url.hostname)) {
        throw new Refusal('INVALID_URL', `${key} : lien https vers un hôte autorisé requis.`);
      }
      out[key] = url.toString();
    } else if (key === 'message') {
      const text = typeof value === 'string' ? value.trim() : '';
      if (!text || text.length > MAX_MESSAGE) throw new Refusal('INVALID_MESSAGE', `message : 1 à ${MAX_MESSAGE} caractères.`);
      out.message = text;
    } else if (key === 'enforce') {
      if (value === true) {
        throw new Refusal('ENFORCE_NOT_ALLOWED', 'enforce: true ne peut pas être activé par cette fonction.');
      }
      if (value !== false) throw new Refusal('INVALID_ENFORCE', 'enforce doit valoir false.');
      out.enforce = false;
    }
  }
  return out;
}

const validRegistryEntry = (e) => e && typeof e === 'object' && isBuild(e.latestBuild)
  && typeof e.source === 'string' && e.source.trim() !== '' && e.verifiedAt != null;

/** Garde du dernier build publié vérifié : seuls les minBuild définis ou relevés sont contrôlés. */
function checkPublishedBuild({ before, after, registry }) {
  const reg = registry && typeof registry === 'object' ? registry : {};
  const limits = { minBuild: ['android', 'ios'], minBuildAndroid: ['android'], minBuildIos: ['ios'] };
  for (const field of BUILD_FIELDS) {
    const next = after[field];
    if (next === undefined) continue;
    const prev = before && isBuild(before[field]) ? before[field] : null;
    if (prev !== null && next <= prev) continue; // baisse ou valeur inchangée : jamais plus restrictif
    for (const platform of limits[field]) {
      const entry = reg[platform];
      if (!validRegistryEntry(entry)) {
        throw new Refusal('PUBLISHED_BUILD_UNVERIFIED',
          `Dernier build ${platform} publié non vérifié (config/${REGISTRY_DOC}) : ${field} ne peut pas être défini ni relevé.`);
      }
      if (next > entry.latestBuild) {
        throw new Refusal('BUILD_ABOVE_PUBLISHED',
          `${field} (${next}) dépasse le dernier build ${platform} publié vérifié (${entry.latestBuild}).`);
      }
    }
  }
}

const fail = (error) => ({ success: false, error: error.code, message: error.message, data: null, code: error.code });

function buildSetAppVersionsConfig({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin }) {
  return onCall(async (request) => {
    const adminData = await requireSuperAdmin({ request, db });
    const uid = request.auth.uid;
    await checkRateLimit(uid, 'app_versions_config', 10, 3600);

    const input = request.data && typeof request.data === 'object' ? request.data : {};
    const { role, values, expectedVersion } = input;
    const audit = (status, metadata) => logAudit({
      userId: uid, userType: 'admin', action: 'app_versions_config_update', targetId: String(role || ''), status, metadata,
    });
    try {
      if (!ROLES.includes(role)) throw new Refusal('INVALID_ROLE', 'Rôle inconnu.');
      if (!Number.isInteger(expectedVersion) || expectedVersion < 0) {
        throw new Refusal('INVALID_VERSION', 'expectedVersion (entier >= 0) requis.');
      }
      const after = values === null ? null : validateRoleValues(values);

      const ref = db.collection(CONFIG).doc(DOC);
      const registryRef = db.collection(CONFIG).doc(REGISTRY_DOC);
      const result = await db.runTransaction(async (tx) => {
        const [snap, regSnap] = await Promise.all([tx.get(ref), tx.get(registryRef)]);
        const data = snap.exists ? snap.data() : {};
        const currentVersion = Number.isInteger(data.version) ? data.version : 0;
        if (currentVersion !== expectedVersion) {
          throw new Refusal('VERSION_CONFLICT', `Le document a changé (version ${currentVersion}). Relisez-le.`);
        }
        const rawBefore = data[role];
        const before = rawBefore && typeof rawBefore === 'object' ? rawBefore : null;
        if (before && before.enforce === true && !(after && after.enforce === false)) {
          throw new Refusal('ENFORCE_EXPLICIT_REQUIRED', 'Ce rôle est en blocage : fournir enforce:false explicitement.');
        }
        if (after) checkPublishedBuild({ before, after, registry: regSnap.exists ? regSnap.data() : null });
        const update = {
          [role]: after === null ? admin.firestore.FieldValue.delete() : after,
          version: currentVersion + 1,
          updatedBy: uid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        tx.set(ref, update, { merge: true });
        return { before, version: currentVersion + 1 };
      });
      await audit('success', { role, before: result.before, after, version: result.version, adminRole: adminData.role });
      return { success: true, error: null, message: 'Configuration enregistrée.', data: { role, version: result.version }, code: 'OK' };
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      await audit('refused', { role: String(role || ''), reason: error.code });
      return fail(error);
    }
  });
}

module.exports = {
  buildSetAppVersionsConfig, validateRoleValues, checkPublishedBuild, Refusal, ROLES, REGISTRY_DOC,
};
