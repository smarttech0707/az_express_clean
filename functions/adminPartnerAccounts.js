'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { requireAdminPermission } = require('./adminGuards');

// ─────────────────────────────────────────────────────────────────────────────
// Liste blanche fermée des partenaires administrables.
//
// CORRECTIF DE SÉCURITÉ (escalade de privilège confirmée par audit) : avant ce
// correctif, `kind` ne servait QU'À choisir la permission exigée, et l'`uid`
// fourni par l'application Admin était passé tel quel à
// `auth.updateUser(uid, { password })`. Rien ne vérifiait que cet UID
// correspondait réellement à un document `sellers`/`boulangeries`. Un
// sous-admin porteur de la seule permission `demandes_vendeurs` (ou
// `boulangeries`) — le rang le plus bas — pouvait donc réécrire le mot de passe
// Firebase Auth de N'IMPORTE QUEL compte, y compris celui d'un super-admin
// (dont l'e-mail est lisible via `admins`), soit une prise de contrôle
// complète. Sans rate limit ni journalisation, l'opération ne laissait aucune
// trace.
//
// `collection` est désormais la seule source de vérité de la cible : elle vient
// de cette table côté serveur, jamais d'un champ de la requête.
// ─────────────────────────────────────────────────────────────────────────────
const PARTNER_KINDS = {
  seller: { permission: 'demandes_vendeurs', collection: 'sellers' },
  boulangerie: { permission: 'boulangeries', collection: 'boulangeries' },
};

// Conservé pour les appelants existants qui importaient la table des
// permissions (forme inchangée : kind -> clé de permission).
const PERMISSIONS = Object.fromEntries(
  Object.entries(PARTNER_KINDS).map(([kind, { permission }]) => [kind, permission]),
);

const PASSWORD_RESET_ACTION = 'admin_partner_password_reset';
// 10 opérations par heure et par admin : reprend exactement la convention
// déjà en place pour une opération de compte initiée par un admin
// (`createSubAdmin` : checkRateLimit(uid, 'create_admin', 10, 3600)), le
// précédent le plus proche du projet. Volontairement distinct du 5/heure de
// `resetAccountPassword`/`setPharmaciePassword`, qui plafonnent un UTILISATEUR
// agissant sur son propre compte, pas un admin faisant du support.
const PASSWORD_RESET_MAX = 10;
const PASSWORD_RESET_WINDOW_SECONDS = 3600;

// Champs de formulaire métier. Les appelants Flutter actuels envoient {},
// puis complètent le profil. Aucun indicateur de sécurité n'est accepté ici.
const PROFILE_FIELDS = Object.freeze({
  seller: Object.freeze(['name', 'phone', 'type', 'lat', 'lng']),
  boulangerie: Object.freeze(['name', 'address', 'phone', 'openTime', 'closeTime', 'lat', 'lng']),
});

function validatedProfile(kind, profile) {
  if (!profile || typeof profile !== 'object' || Array.isArray(profile)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(profile))) {
    throw new HttpsError('invalid-argument', 'Profil invalide.');
  }
  const result = {};
  for (const key of Object.keys(profile)) {
    // Ne jamais inclure le nom ou la valeur du champ refusé dans une erreur.
    if (!PROFILE_FIELDS[kind].includes(key)) {
      throw new HttpsError('invalid-argument', 'Champ de profil non autorisé.');
    }
    const value = profile[key];
    if (key === 'lat' || key === 'lng') {
      const limit = key === 'lat' ? 90 : 180;
      if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > limit) {
        throw new HttpsError('invalid-argument', 'Coordonnées invalides.');
      }
    } else if (typeof value !== 'string' || !value.trim() || value.length > 500) {
      throw new HttpsError('invalid-argument', 'Champ de profil invalide.');
    }
    if (key === 'type' && !['boutique', 'restaurant', 'pharmacie', 'eau_boissons', 'blanchisserie'].includes(value)) {
      throw new HttpsError('invalid-argument', 'Type de commerce invalide.');
    }
    result[key] = value;
  }
  return result;
}

function requiredString(data, key) {
  const value = data?.[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new HttpsError('invalid-argument', `Champ ${key} requis.`);
  }
  return value.trim();
}

// `doc(uid)` sur une valeur contenant '/' viserait un document d'un autre
// chemin que celui annoncé par `kind` — même garde que artisanCredentials.setPin.
function requiredTargetUid(data) {
  const uid = requiredString(data, 'uid');
  if (uid.includes('/') || uid.length > 128 || /[\r\n]/.test(uid)) {
    throw new HttpsError('invalid-argument', 'Identifiant cible invalide.');
  }
  return uid;
}

/// Vérifie côté serveur que `uid` est bien un partenaire du `kind` annoncé, et
/// qu'il n'est pas un compte Admin. Lève avant tout appel à `auth.updateUser`.
///
/// Les deux refus partagent volontairement le même message : l'appelant ne doit
/// pas pouvoir distinguer « UID inconnu » de « UID administrateur » (sinon la
/// fonction devient un oracle d'énumération des comptes admin). La distinction
/// vit uniquement dans la trace serveur.
async function assertTargetBelongsToKind({
  db, kind, uid, actorUid, logSecurityEvent,
}) {
  const { collection } = PARTNER_KINDS[kind];
  const [adminSnapshot, partnerSnapshot] = await Promise.all([
    db.collection('admins').doc(uid).get(),
    db.collection(collection).doc(uid).get(),
  ]);

  const refuse = () => {
    throw new HttpsError('permission-denied', 'Cible invalide pour ce type de partenaire.');
  };

  // Un compte Admin/sous-admin n'est jamais une cible valide, même s'il
  // possède par ailleurs un document partenaire : vérifié en premier.
  if (adminSnapshot.exists) {
    await logSecurityEvent(
      actorUid,
      'admin_partner_password_admin_target',
      'high',
      `Tentative de réinitialisation du mot de passe d'un compte Admin via `
      + `manageAdminPartnerAccount (kind=${kind}, cible=${uid}).`,
    );
    refuse();
  }

  if (!partnerSnapshot.exists) {
    refuse();
  }
}

function buildManageAdminPartnerAccount({
  db, auth, fieldValue, checkRateLimit, logAudit, logSecurityEvent,
}) {
  if (typeof checkRateLimit !== 'function'
      || typeof logAudit !== 'function'
      || typeof logSecurityEvent !== 'function') {
    // Dépendances obligatoires : une valeur par défaut silencieuse
    // désactiverait le rate limit ou la trace d'audit sans que personne ne le
    // remarque — exactement ce qui manquait avant ce correctif.
    throw new TypeError(
      'buildManageAdminPartnerAccount requiert checkRateLimit, logAudit et logSecurityEvent.',
    );
  }

  return async (request) => {
    // Les métadonnées sont construites explicitement, jamais depuis un spread
    // de request.data, profile, ou une exception Firebase Auth.
    const actorUid = request.auth?.uid || null;
    let action = 'invalid';
    let kind = null;
    let targetUid = null;
    let stage = 'validation';
    const audit = (status) => logAudit({
      userId: actorUid, userType: 'admin',
      action: action === 'updatePassword' ? PASSWORD_RESET_ACTION
        : action === 'create' ? 'admin_partner_create' : 'admin_partner_rejected',
      targetId: targetUid, status, metadata: { kind, stage },
    });
    try {
      const requestedAction = requiredString(request.data, 'action');
      if (!['create', 'updatePassword'].includes(requestedAction)) {
        throw new HttpsError('invalid-argument', 'Action invalide.');
      }
      action = requestedAction;
      const requestedKind = requiredString(request.data, 'kind');
      // Une propriété héritée (constructor, __proto__...) n'est pas un kind.
      if (!Object.hasOwn(PARTNER_KINDS, requestedKind)) {
        throw new HttpsError('invalid-argument', 'Type de partenaire invalide.');
      }
      kind = requestedKind;
      const partner = PARTNER_KINDS[kind];
      if (action === 'updatePassword') targetUid = requiredTargetUid(request.data);
      stage = 'authorization';
      await requireAdminPermission({ request, db, permission: partner.permission });
      stage = 'rate_limit';
      await checkRateLimit(actorUid,
        action === 'create' ? 'admin_partner_create' : 'admin_partner_password',
        PASSWORD_RESET_MAX, PASSWORD_RESET_WINDOW_SECONDS);
      stage = 'validation';
      const password = requiredString(request.data, 'password');
      // Politique historique conservée : minimum 6 après trim.
      if (password.length < 6) throw new HttpsError('invalid-argument', 'Mot de passe trop court.');
      if (action === 'updatePassword') {
        stage = 'target_validation';
        await assertTargetBelongsToKind({ db, kind, uid: targetUid, actorUid, logSecurityEvent });
        stage = 'auth_update';
        await auth.updateUser(targetUid, { password });
      } else {
        const email = requiredString(request.data, 'email');
        const profile = validatedProfile(kind, request.data.profile);
        stage = 'auth_create';
        const user = await auth.createUser({ email, password });
        targetUid = user.uid;
        stage = 'profile_create';
        try {
          // Solde initial identique aux formulaires existants. create() refuse
          // tout écrasement et ne copie aucun indicateur de rôle/sécurité.
          await db.collection(partner.collection).doc(targetUid).create({
            ...profile, wallet: 0, createdAt: fieldValue.serverTimestamp(),
          });
        } catch (error) {
          try {
            await auth.deleteUser(targetUid);
          } catch (_) {
            stage = 'creation_rollback_failed';
            await logSecurityEvent(actorUid, 'admin_partner_creation_rollback_failed', 'high',
              `Compte partenaire à réconcilier (kind=${kind}, cible=${targetUid}).`);
          }
          throw new HttpsError('internal', 'Création du profil impossible. Contactez le support.');
        }
      }
      stage = 'completed';
      await audit('success');
      return { uid: targetUid };
    } catch (error) {
      await audit('error');
      // Les erreurs Auth peuvent inclure des valeurs d'entrée : ne pas les
      // journaliser ni les retourner. Codes usuels uniquement, message fixe.
      if (error instanceof HttpsError) throw error;
      if (error.code === 'auth/email-already-exists') {
        throw new HttpsError('already-exists', 'Ce compte existe déjà.');
      }
      throw new HttpsError('internal', 'Opération partenaire impossible. Contactez le support.');
    }
  };
}

module.exports = {
  buildManageAdminPartnerAccount,
  requireAdminPermission,
  PARTNER_KINDS,
  PERMISSIONS,
};
