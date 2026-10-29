'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { requireAdminPermission, requireSuperAdmin } = require('./adminGuards');
const { hashSecret: defaultHashSecret } = require('./passwordHash');
const {
  generateTemporaryPassword: defaultGeneratePassword,
  MUST_CHANGE_CLAIM,
} = require('./partnerTemporaryPassword');

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
//
// `actions` : le type `restaurant` n'expose PAS `updatePassword` à cette étape
// (la cible d'un mot de passe restaurateur est `restaurant_owners`, pas
// `restaurants` : chantier distinct). Il expose `create` et `assignOwner`.
// ─────────────────────────────────────────────────────────────────────────────
const PARTNER_KINDS = {
  seller: {
    permission: 'demandes_vendeurs', collection: 'sellers',
    actions: ['create', 'updatePassword'],
  },
  boulangerie: {
    permission: 'boulangeries', collection: 'boulangeries',
    actions: ['create', 'updatePassword'],
  },
  restaurant: {
    permission: 'restaurants', collection: 'restaurants',
    actions: ['create', 'assignOwner'],
  },
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

// Journal de provisionnement (Admin SDK uniquement : aucune règle Firestore ne
// l'expose, donc refus par défaut pour tout client). Il porte la preuve qu'un
// compte Auth a été créé PAR cette fonction, ce qui est la seule condition
// sous laquelle une nouvelle tentative a le droit de reprendre ce compte.
const PROVISIONING_COLLECTION = 'partner_provisioning';
// Verrou « un responsable par restaurant » : `create()` échoue si le restaurant
// a déjà un responsable, même sous deux requêtes concurrentes.
const OWNER_LOCK_COLLECTION = 'restaurant_owner_locks';
// Une création encore "en cours" ne doit JAMAIS être reprise par une seconde
// requête (exécution concurrente) : sinon la compensation de la première
// pourrait supprimer un compte que la seconde vient de terminer. Une reprise
// n'est permise qu'une fois le journal plus ancien que ce délai (très
// supérieur au timeout d'une exécution de la fonction).
const RESUME_AFTER_MS = 5 * 60 * 1000;

// Domaine technique des identifiants restaurateur (voir restaurant_owner_login).
const RESTAURANT_EMAIL_SUFFIX = '@az-restaurant.ci';

// Champs de formulaire métier. La finalisation du profil se fait désormais ICI
// (plus de seconde écriture Flutter) : tous les champs `required` sont donc
// obligatoires. Aucun indicateur de sécurité n'est accepté dans `profile`
// (isActive/isOpen/wallet/role... sont fixés par le serveur).
const PROFILE_SPECS = Object.freeze({
  seller: Object.freeze({
    allowed: ['name', 'phone', 'type', 'lat', 'lng'],
    required: ['name', 'phone', 'type', 'lat', 'lng'],
  }),
  boulangerie: Object.freeze({
    allowed: ['name', 'address', 'phone', 'openTime', 'closeTime', 'lat', 'lng'],
    required: ['name', 'address', 'phone', 'openTime', 'closeTime', 'lat', 'lng'],
  }),
  restaurant: Object.freeze({
    allowed: ['name', 'ownerName', 'phone', 'address', 'category', 'lat', 'lng', 'minDelivery'],
    required: ['name', 'ownerName', 'phone', 'address', 'category', 'lat', 'lng'],
  }),
});

function validatedProfile(kind, profile) {
  if (!profile || typeof profile !== 'object' || Array.isArray(profile)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(profile))) {
    throw new HttpsError('invalid-argument', 'Profil invalide.');
  }
  const spec = PROFILE_SPECS[kind];
  const result = {};
  for (const key of Object.keys(profile)) {
    // Ne jamais inclure le nom ou la valeur du champ refusé dans une erreur.
    if (!spec.allowed.includes(key)) {
      throw new HttpsError('invalid-argument', 'Champ de profil non autorisé.');
    }
    const value = profile[key];
    if (key === 'lat' || key === 'lng') {
      const limit = key === 'lat' ? 90 : 180;
      if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > limit) {
        throw new HttpsError('invalid-argument', 'Coordonnées invalides.');
      }
    } else if (key === 'minDelivery') {
      if (!Number.isInteger(value) || value < 0 || value > 1000000) {
        throw new HttpsError('invalid-argument', 'Champ de profil invalide.');
      }
    } else if (typeof value !== 'string' || !value.trim() || value.length > 500) {
      throw new HttpsError('invalid-argument', 'Champ de profil invalide.');
    }
    if (key === 'type' && !['boutique', 'restaurant', 'pharmacie', 'eau_boissons', 'blanchisserie'].includes(value)) {
      throw new HttpsError('invalid-argument', 'Type de commerce invalide.');
    }
    result[key] = typeof value === 'string' ? value.trim() : value;
  }
  for (const key of spec.required) {
    if (!(key in result)) {
      throw new HttpsError('invalid-argument', 'Profil incomplet.');
    }
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

function optionalBoolean(data, key, defaultValue) {
  const value = data?.[key];
  if (value === undefined) return defaultValue;
  if (typeof value !== 'boolean') {
    throw new HttpsError('invalid-argument', 'Indicateur invalide.');
  }
  return value;
}

// `doc(uid)` sur une valeur contenant '/' viserait un document d'un autre
// chemin que celui annoncé par `kind` — même garde que artisanCredentials.setPin.
function validDocumentId(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 128
    && !value.includes('/') && !/[\r\n]/.test(value);
}

function requiredDocumentId(data, key) {
  const value = requiredString(data, key);
  if (!validDocumentId(value)) {
    throw new HttpsError('invalid-argument', 'Identifiant cible invalide.');
  }
  return value;
}

function requiredEmail(data, kind) {
  const email = requiredString(data, 'email');
  if (email.length > 128 || /\s/.test(email)) {
    throw new HttpsError('invalid-argument', 'Identifiant de connexion invalide.');
  }
  // Pour un restaurateur, l'identifiant doit être celui que l'écran de
  // connexion reconstruit ('<téléphone>@az-restaurant.ci') : sinon le compte
  // serait créé mais inutilisable.
  if (kind === 'restaurant' && !(email.endsWith(RESTAURANT_EMAIL_SUFFIX)
      && email.length > RESTAURANT_EMAIL_SUFFIX.length)) {
    throw new HttpsError('invalid-argument', 'Identifiant de connexion invalide.');
  }
  return email;
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

  if (!partnerSnapshot.exists || partnerSnapshot.data()?.isDeleted === true) {
    refuse();
  }
}

const ALREADY_EXISTS = () => new HttpsError('already-exists', 'Ce compte existe déjà.');

// Documents Firestore à créer (tous en `create()`, jamais d'écrasement) pour une
// opération donnée. Pur : ne touche ni Auth ni Firestore.
function buildDocuments({
  db, fieldValue, kind, operation, uid, profile, restaurantId, rootFlags,
}) {
  const timestamp = fieldValue.serverTimestamp();
  if (kind === 'seller') {
    return [{
      ref: db.collection('sellers').doc(uid),
      data: { ...profile, isActive: rootFlags.isActive, wallet: 0, createdAt: timestamp },
    }];
  }
  if (kind === 'boulangerie') {
    return [{
      ref: db.collection('boulangeries').doc(uid),
      data: {
        ...profile, isOpen: false, wallet: 0, isActive: true, createdAt: timestamp,
      },
    }];
  }
  // Restaurant : schéma réel de approvePartnerOnce (profile + ownerProfile).
  const documents = [];
  if (operation === 'create') {
    documents.push({
      ref: db.collection('restaurants').doc(restaurantId),
      data: {
        ...profile, isOpen: rootFlags.isOpen, isActive: true,
        createdAt: timestamp, id: restaurantId,
      },
    });
  }
  documents.push({
    ref: db.collection('restaurant_owners').doc(uid),
    data: {
      uid, phone: rootFlags.ownerPhone, ownerName: rootFlags.ownerName,
      createdAt: timestamp, restaurantId,
      // Projection en lecture seule de partner_provisioning/{uid}.mustChangePassword,
      // lue par storage.rules (limite de 2 documents par évaluation). Créée dans le
      // MÊME lot que la clôture du journal ; un client ne peut pas l'écrire
      // (restaurant_owners : write admin seulement).
      mustChangePassword: true,
    },
  });
  documents.push({
    ref: db.collection(OWNER_LOCK_COLLECTION).doc(restaurantId),
    data: { ownerUid: uid, createdAt: timestamp },
  });
  return documents;
}

/// Création Auth + documents, avec gestion explicite des échecs :
///  - Auth et Firestore ne sont pas atomiques ;
///  - les documents métier et la clôture du journal sont écrits dans UN SEUL
///    lot Firestore atomique (tout ou rien) ;
///  - la compensation (suppression du compte Auth) ne vise QUE le compte créé
///    par cet appel ;
///  - si le compte existe déjà, il n'est repris que s'il a été créé par cette
///    fonction (journal présent, même opération, non terminé) et sans aucun
///    document métier : jamais supprimé, jamais écrasé.
async function provisionAccount({
  db, auth, fieldValue, logSecurityEvent, actorUid, kind, operation, email, password,
  profile, rootFlags, restaurantId: knownRestaurantId, setStage, setTarget, now, hashSecret,
}) {
  // Première connexion : le mot de passe temporaire est généré par le serveur
  // (jamais choisi par l'administrateur). Seul son HACHAGE est conservé, dans le
  // journal réservé aux fonctions, pour refuser plus tard un « nouveau » mot de
  // passe identique au temporaire. Jamais en clair.
  const firstLogin = () => ({
    mustChangePassword: true,
    tempPasswordHash: hashSecret(password),
    passwordIssuedAt: now(),
  });
  let uid;
  let fresh = true;
  let restaurantId = knownRestaurantId;
  try {
    const user = await auth.createUser({ email, password });
    uid = user.uid;
  } catch (error) {
    if (error?.code !== 'auth/email-already-exists') throw error;
    fresh = false;
    setStage('resume_check');
    const existing = await auth.getUserByEmail(email);
    uid = existing.uid;
    setTarget(uid);
    const [markerSnapshot, adminSnapshot] = await Promise.all([
      db.collection(PROVISIONING_COLLECTION).doc(uid).get(),
      db.collection('admins').doc(uid).get(),
    ]);
    const marker = markerSnapshot.exists ? markerSnapshot.data() : null;
    if (adminSnapshot.exists || !marker || marker.kind !== kind
        || marker.operation !== operation || marker.status === 'completed') {
      throw ALREADY_EXISTS();
    }
    const ageMs = now() - Number(marker.createdAtMs);
    if (!Number.isFinite(ageMs) || ageMs < RESUME_AFTER_MS) {
      // Création probablement encore en cours (ou trop récente) : ne rien toucher.
      throw ALREADY_EXISTS();
    }
    if (kind === 'restaurant') {
      restaurantId = marker.restaurantId;
      if (!validDocumentId(restaurantId)) throw ALREADY_EXISTS();
    }
    const probe = buildDocuments({
      db, fieldValue, kind, operation, uid, profile, restaurantId, rootFlags,
    });
    const present = await Promise.all(probe.map((document) => document.ref.get()));
    if (present.some((snapshot) => snapshot.exists)) throw ALREADY_EXISTS();
    setStage('resume_auth_update');
    await auth.updateUser(uid, { password });
    setStage('resume_claims');
    await auth.setCustomUserClaims(uid, { [MUST_CHANGE_CLAIM]: true });
  }
  setTarget(uid);

  const markerRef = db.collection(PROVISIONING_COLLECTION).doc(uid);
  const compensate = async () => {
    // Uniquement le compte créé par CET appel.
    if (!fresh) return;
    try {
      await auth.deleteUser(uid);
    } catch (_) {
      setStage('creation_rollback_failed');
      await logSecurityEvent(actorUid, 'admin_partner_creation_rollback_failed', 'high',
        `Compte partenaire à réconcilier (kind=${kind}, cible=${uid}).`);
      // Le journal est conservé : il autorise une reprise sécurisée.
      return;
    }
    try { await markerRef.delete(); } catch (_) { /* journal inerte sans compte */ }
  };

  try {
    if (fresh) {
      setStage('marker_create');
      if (kind === 'restaurant' && !restaurantId) {
        restaurantId = db.collection('restaurants').doc().id;
      }
      await markerRef.set({
        kind, operation, status: 'auth_created', actorUid, createdAtMs: now(),
        ...(kind === 'restaurant' ? { restaurantId } : {}),
        ...firstLogin(),
        createdAt: fieldValue.serverTimestamp(),
      });
      setStage('claims');
      await auth.setCustomUserClaims(uid, { [MUST_CHANGE_CLAIM]: true });
    }
    setStage('profile_create');
    const documents = buildDocuments({
      db, fieldValue, kind, operation, uid, profile, restaurantId, rootFlags,
    });
    const batch = db.batch();
    for (const document of documents) batch.create(document.ref, document.data);
    batch.set(markerRef, {
      status: 'completed', completedAt: fieldValue.serverTimestamp(), ...firstLogin(),
    }, { merge: true });
    await batch.commit();
  } catch (_) {
    await compensate();
    throw new HttpsError('internal', 'Création du profil impossible. Contactez le support.');
  }
  return { uid, restaurantId };
}

function buildManageAdminPartnerAccount({
  db, auth, fieldValue, checkRateLimit, logAudit, logSecurityEvent, now = Date.now,
  hashSecret = defaultHashSecret, generatePassword = defaultGeneratePassword,
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
        : action === 'create' ? 'admin_partner_create'
          : action === 'assignOwner' ? 'admin_partner_assign_owner'
            : 'admin_partner_rejected',
      targetId: targetUid, status, metadata: { kind, stage },
    });
    try {
      const requestedAction = requiredString(request.data, 'action');
      if (!['create', 'updatePassword', 'assignOwner'].includes(requestedAction)) {
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
      if (!partner.actions.includes(action)) {
        throw new HttpsError('invalid-argument', 'Action invalide pour ce type de partenaire.');
      }
      if (action === 'updatePassword') targetUid = requiredDocumentId(request.data, 'uid');
      stage = 'authorization';
      if (action === 'assignOwner') {
        // Attribuer un responsable à un établissement existant est plus
        // sensible qu'une création : réservé à l'administrateur principal.
        await requireSuperAdmin({ request, db });
      } else {
        await requireAdminPermission({ request, db, permission: partner.permission });
      }
      stage = 'rate_limit';
      await checkRateLimit(actorUid,
        action === 'create' ? 'admin_partner_create'
          : action === 'assignOwner' ? 'admin_partner_assign' : 'admin_partner_password',
        PASSWORD_RESET_MAX, PASSWORD_RESET_WINDOW_SECONDS);
      stage = 'validation';
      // Aucun mot de passe choisi ni transmis par l'administrateur : le serveur
      // génère un mot de passe TEMPORAIRE (le partenaire en définit un
      // personnel à sa première connexion). Valeur refusée sans l'écho.
      if (request.data?.password !== undefined || request.data?.newPassword !== undefined) {
        throw new HttpsError('invalid-argument', 'Mot de passe non accepté : il est généré par le serveur.');
      }
      const password = generatePassword();

      if (action === 'updatePassword') {
        stage = 'target_validation';
        await assertTargetBelongsToKind({ db, kind, uid: targetUid, actorUid, logSecurityEvent });
        stage = 'auth_update';
        await auth.updateUser(targetUid, { password });
        stage = 'claims';
        await auth.setCustomUserClaims(targetUid, { [MUST_CHANGE_CLAIM]: true });
        stage = 'journal';
        await db.collection(PROVISIONING_COLLECTION).doc(targetUid).set({
          kind, mustChangePassword: true, tempPasswordHash: hashSecret(password),
          passwordIssuedAt: now(), resetBy: actorUid,
        }, { merge: true });
        stage = 'completed';
        await audit('success');
        return { uid: targetUid, tempPassword: password };
      }

      const email = requiredEmail(request.data, kind);
      const rootFlags = {};
      let profile;
      let restaurantId;
      if (action === 'create') {
        profile = validatedProfile(kind, request.data.profile);
        if (kind === 'seller') {
          rootFlags.isActive = optionalBoolean(request.data, 'isActive', true);
        }
        if (kind === 'restaurant') {
          rootFlags.isOpen = optionalBoolean(request.data, 'isOpen', false);
          rootFlags.ownerPhone = profile.phone;
          rootFlags.ownerName = profile.ownerName;
        }
      } else {
        // assignOwner : l'établissement DOIT déjà exister ; jamais créé ici.
        restaurantId = requiredDocumentId(request.data, 'restaurantId');
        rootFlags.ownerName = requiredString(request.data, 'ownerName');
        rootFlags.ownerPhone = requiredString(request.data, 'phone');
        if (rootFlags.ownerName.length > 500 || rootFlags.ownerPhone.length > 500) {
          throw new HttpsError('invalid-argument', 'Champ de profil invalide.');
        }
        stage = 'target_validation';
        const restaurant = await db.collection('restaurants').doc(restaurantId).get();
        if (!restaurant.exists || restaurant.data()?.isDeleted === true) {
          throw new HttpsError('failed-precondition', 'Établissement introuvable.');
        }
        const [lock, bound] = await Promise.all([
          db.collection(OWNER_LOCK_COLLECTION).doc(restaurantId).get(),
          db.collection('restaurant_owners').where('restaurantId', '==', restaurantId).limit(1).get(),
        ]);
        if (lock.exists || !bound.empty) {
          throw new HttpsError('already-exists', 'Cet établissement a déjà un responsable.');
        }
      }

      stage = 'auth_create';
      const created = await provisionAccount({
        db, auth, fieldValue, logSecurityEvent, actorUid, kind, operation: action,
        email, password, profile, rootFlags, restaurantId,
        setStage: (value) => { stage = value; },
        setTarget: (value) => { targetUid = value; },
        now,
        hashSecret,
      });
      targetUid = created.uid;
      stage = 'completed';
      await audit('success');
      return kind === 'restaurant'
        ? { uid: created.uid, restaurantId: created.restaurantId, tempPassword: password }
        : { uid: created.uid, tempPassword: password };
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
  PROVISIONING_COLLECTION,
  OWNER_LOCK_COLLECTION,
};
