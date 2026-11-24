'use strict';

// Liste OFFICIELLE des permissions administratives (S8) et routage des
// notifications admin (S5). Source unique côté serveur ; miroirs à garder
// identiques : `adminPermissionKeys` (lib/screens/admin/admin_mfa_security.dart)
// et la liste de la règle `admins` dans firestore.rules (un test de parité
// lit les trois). Le super-admin (`role == 'super'`) n'a pas besoin de clés.

const PERMISSION_KEYS = Object.freeze([
  'livreurs', 'commandes', 'gains', 'classement', 'carte', 'zones',
  'demandes', 'restaurants', 'demandes_resto', 'demandes_vendeurs',
  'demandes_boulangeries', 'demandes_pharmacies', 'pharmacies', 'boutique',
  'recharges', 'flottes', 'locations', 'residences', 'services', 'eventiel',
  'tricycle', 'sos', 'anti_fraude', 'cash_marchand', 'support', 'ai_dashboard',
  'boulangeries', 'ekbine', 'purger',
  // Exigée par moderateVehicleEntity (vehicleModeration.js). Non proposée dans
  // l'interface et menu « Auto & Moto » encore réservé au super-admin : la clé
  // est valide côté serveur, mais n'est attribuée à personne automatiquement.
  'auto_moto',
]);

const KNOWN = new Set(PERMISSION_KEYS);

function invalid(message) {
  const error = new Error(message);
  error.code = 'invalid-argument';
  return error;
}

/** Retourne la liste nettoyée (sans doublon) ou lève `invalid-argument`. */
function validatePermissions(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw invalid('Permissions invalides (liste attendue).');
  if (value.length > PERMISSION_KEYS.length) throw invalid('Trop de permissions.');
  const unknown = value.filter((key) => typeof key !== 'string' || !KNOWN.has(key));
  if (unknown.length) {
    throw invalid(`Permission(s) inconnue(s) : ${unknown.map((k) => String(k).slice(0, 40)).join(', ')}`);
  }
  return [...new Set(value)];
}

// Profils proposés (NON appliqués automatiquement, aucun admin existant n'est
// modifié). Chaque clé doit exister dans PERMISSION_KEYS (testé).
const PROFILES = Object.freeze({
  partenaires: Object.freeze([
    'demandes', 'demandes_resto', 'demandes_vendeurs', 'demandes_boulangeries',
    'demandes_pharmacies', 'restaurants', 'boulangeries', 'pharmacies', 'boutique',
    'flottes', 'ekbine', 'services', 'eventiel', 'locations', 'residences',
  ]),
  operations: Object.freeze([
    'livreurs', 'commandes', 'carte', 'classement', 'zones', 'tricycle',
  ]),
  support: Object.freeze(['support', 'sos']),
});

// Réservées au super-administrateur, jamais comprises dans un profil.
const SUPER_ONLY_KEYS = Object.freeze([
  'gains', 'recharges', 'cash_marchand', 'purger', 'anti_fraude', 'ai_dashboard', 'auto_moto',
]);

// Événement → permission requise pour être notifié. `null` = super-admin seul.
const NOTIFICATION_PERMISSION = Object.freeze({
  security_alert: null,
  admin_new_driver: 'demandes',
  admin_new_service_provider: 'services',
  event_provider_application: 'eventiel',
  stuck_order: 'commandes',
});

/**
 * Jetons FCM des admins qui doivent recevoir une notification : le
 * super-admin actif toujours ; un sous-admin actif seulement s'il porte la
 * permission (`permission == null` : super-admin seul).
 */
function adminNotificationTokens(adminDocs, permission) {
  const tokens = new Set();
  for (const doc of adminDocs) {
    const data = typeof doc?.data === 'function' ? doc.data() : doc;
    if (!data || data.isActive !== true) continue;
    const allowed = data.role === 'super'
      || (data.role === 'sub' && permission != null
        && Array.isArray(data.permissions) && data.permissions.includes(permission));
    if (allowed && typeof data.fcmToken === 'string' && data.fcmToken.length > 10) {
      tokens.add(data.fcmToken);
    }
  }
  return [...tokens];
}

module.exports = {
  PERMISSION_KEYS, PROFILES, SUPER_ONLY_KEYS, NOTIFICATION_PERMISSION,
  validatePermissions, adminNotificationTokens,
};
