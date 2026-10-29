'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { verifySecret: defaultVerifySecret } = require('./passwordHash');
const { meetsPasswordPolicy, MUST_CHANGE_CLAIM } = require('./partnerTemporaryPassword');

// Collection du profil professionnel qui prouve qu'un compte Auth est bien un
// partenaire du type annoncé par le journal de provisionnement.
const PROFILE_COLLECTIONS = Object.freeze({
  seller: 'sellers',
  boulangerie: 'boulangeries',
  restaurant: 'restaurant_owners',
});

const PROVISIONING_COLLECTION = 'partner_provisioning';
// L'utilisateur vient de se (ré)authentifier avec le mot de passe temporaire :
// une session plus ancienne ne peut pas changer le mot de passe.
const MAX_AUTH_AGE_SECONDS = 10 * 60;
const MAX_ATTEMPTS = 5;
const ATTEMPT_WINDOW_SECONDS = 3600;
const STATUS_MAX = 30;
// Verrou anti double changement : bien supérieur à la durée d'une exécution
// (quelques secondes), expire seul si l'instance est interrompue.
const LOCK_MS = 60 * 1000;

/// Première connexion des partenaires créés par l'administration (restaurant,
/// vendeur, boulangerie).
///
/// Deux usages, tous deux AUTORITAIRES côté serveur :
///  - `{ statusOnly: true }` : le changement est-il encore obligatoire ? Répare
///    aussi une revendication d'authentification périmée (changement déjà
///    effectué, retrait de la revendication interrompu).
///  - `{ newPassword }` : changement OBLIGATOIRE du mot de passe temporaire.
///
/// Le drapeau `mustChangePassword` vit dans `partner_provisioning/{uid}`,
/// collection réservée aux fonctions (aucune règle ne l'expose à un client) :
/// il n'est levé QUE ici, juste après que le serveur a lui-même changé le mot de
/// passe Firebase Auth (jamais sur simple déclaration du client).
///
/// Ordre des écritures, pensé pour ne laisser aucun état incohérent durable :
///   verrou → mot de passe Auth → drapeau levé → révocation des sessions →
///   retrait de la revendication. Les deux dernières étapes sont répétables
///   (le mode statut les répare) ; seule une panne Firestore EXACTEMENT entre
///   l'étape Auth et la levée du drapeau laisse un compte à réinitialiser par
///   l'administrateur (nouveau mot de passe temporaire).
function buildCompletePartnerFirstPasswordChange({
  db, auth, fieldValue, checkRateLimit, logAudit,
  verifySecret = defaultVerifySecret, now = Date.now,
}) {
  if (typeof checkRateLimit !== 'function' || typeof logAudit !== 'function') {
    throw new TypeError('buildCompletePartnerFirstPasswordChange requiert checkRateLimit et logAudit.');
  }
  return async (request) => {
    const uid = request.auth?.uid || null;
    let stage = 'authentication';
    let kind = null;
    let action = 'partner_first_password_change';
    let locked = false;
    // Métadonnées fixes : jamais de mot de passe, de hachage ni de valeur de requête.
    const audit = (status) => logAudit({
      userId: uid, userType: kind || 'partner', action,
      targetId: uid, status, metadata: { kind, stage },
    });
    const markerRef = uid ? db.collection(PROVISIONING_COLLECTION).doc(uid) : null;
    const releaseLock = async () => {
      if (!locked) return;
      try {
        await markerRef.set({ changeLockUntilMs: fieldValue.delete() }, { merge: true });
      } catch (_) { /* le verrou expire seul */ }
    };
    try {
      if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
        throw new HttpsError('unauthenticated', 'Authentification requise.');
      }

      // ── Mode statut : lecture autoritaire + réparation de la revendication ──
      if (request.data?.statusOnly === true) {
        action = 'partner_first_password_status';
        stage = 'rate_limit';
        await checkRateLimit(uid, 'partner_first_status', STATUS_MAX, ATTEMPT_WINDOW_SECONDS);
        stage = 'status';
        const snapshot = await markerRef.get();
        const state = snapshot.exists ? snapshot.data() : null;
        const required = state?.mustChangePassword === true
          && Object.hasOwn(PROFILE_COLLECTIONS, state.kind);
        if (!required && state?.mustChangePassword === false
            && request.auth.token?.[MUST_CHANGE_CLAIM] === true) {
          stage = 'claims';
          await auth.setCustomUserClaims(uid, null);
        }
        stage = 'completed';
        return { required };
      }

      stage = 'rate_limit';
      await checkRateLimit(uid, 'partner_first_password', MAX_ATTEMPTS, ATTEMPT_WINDOW_SECONDS);

      stage = 'validation';
      const newPassword = request.data?.newPassword;
      if (typeof newPassword !== 'string' || newPassword.length > 128) {
        throw new HttpsError('invalid-argument', 'Nouveau mot de passe invalide.');
      }
      if (!meetsPasswordPolicy(newPassword)) {
        throw new HttpsError('invalid-argument',
          'Le mot de passe doit contenir au moins 8 caractères, une majuscule et un chiffre.');
      }

      stage = 'state_check';
      const marker = await markerRef.get();
      const state = marker.exists ? marker.data() : null;
      if (!state || state.mustChangePassword !== true
          || !Object.hasOwn(PROFILE_COLLECTIONS, state.kind)) {
        // Compte historique ou déjà activé : rien à changer par cette voie.
        throw new HttpsError('failed-precondition', 'Aucun changement de mot de passe requis.');
      }
      kind = state.kind;
      const [profile, adminSnapshot] = await Promise.all([
        db.collection(PROFILE_COLLECTIONS[kind]).doc(uid).get(),
        db.collection('admins').doc(uid).get(),
      ]);
      if (adminSnapshot.exists || !profile.exists || profile.data()?.isDeleted === true) {
        throw new HttpsError('permission-denied', 'Compte non éligible.');
      }

      stage = 'recent_authentication';
      const authTime = Number(request.auth.token?.auth_time);
      const ageSeconds = now() / 1000 - authTime;
      if (!Number.isFinite(authTime) || ageSeconds < -60 || ageSeconds > MAX_AUTH_AGE_SECONDS) {
        throw new HttpsError('unauthenticated', 'Reconnexion récente requise.');
      }

      stage = 'not_temporary';
      if (verifySecret(newPassword, state.tempPasswordHash)) {
        throw new HttpsError('invalid-argument',
          'Choisissez un mot de passe différent du mot de passe temporaire.');
      }

      // Verrou transactionnel : deux changements simultanés ne peuvent pas
      // s'exécuter ensemble (un seul gagne, l'autre est refusé sans effet).
      stage = 'lock';
      await db.runTransaction(async (tx) => {
        const current = await tx.get(markerRef);
        const data = current.exists ? current.data() : null;
        if (!data || data.mustChangePassword !== true) {
          throw new HttpsError('failed-precondition', 'Aucun changement de mot de passe requis.');
        }
        if (Number(data.changeLockUntilMs) > now()) {
          throw new HttpsError('aborted', 'Un changement est déjà en cours. Patientez un instant.');
        }
        tx.set(markerRef, { changeLockUntilMs: now() + LOCK_MS }, { merge: true });
      });
      locked = true;

      // Le serveur change LUI-MÊME le mot de passe : la levée du drapeau n'est
      // jamais une déclaration du client. `updateUser` ne se résout qu'une fois
      // la modification appliquée.
      stage = 'auth_update';
      await auth.updateUser(uid, { password: newPassword });
      // Le drapeau est levé IMMÉDIATEMENT après le changement effectif.
      stage = 'journal';
      const activated = {
        mustChangePassword: false,
        passwordChangedAt: fieldValue.serverTimestamp(),
        tempPasswordHash: fieldValue.delete(),
        changeLockUntilMs: fieldValue.delete(),
      };
      if (kind === 'restaurant') {
        // Journal et projection (restaurant_owners, lue par storage.rules) sont
        // levés dans UN lot atomique : jamais l'un sans l'autre. `update` (et non
        // `set`) : le profil existe (vérifié plus haut), jamais recréé ici. En
        // cas d'échec, les deux restent à true (fail-closed) et le verrou est
        // libéré ; le mot de passe Auth étant déjà changé, un nouvel essai aboutit.
        const batch = db.batch();
        batch.set(markerRef, activated, { merge: true });
        batch.update(db.collection(PROFILE_COLLECTIONS.restaurant).doc(uid),
          { mustChangePassword: false });
        await batch.commit();
      } else {
        await markerRef.set(activated, { merge: true });
      }
      locked = false;

      // Étapes répétables : une panne ici n'invalide pas le changement (le mode
      // statut retire une revendication périmée à la prochaine vérification).
      stage = 'revoke_sessions';
      let degraded = false;
      try { await auth.revokeRefreshTokens(uid); } catch (_) { degraded = true; }
      stage = 'claims';
      try { await auth.setCustomUserClaims(uid, null); } catch (_) { degraded = true; }

      stage = degraded ? 'completed_degraded' : 'completed';
      await audit('success');
      return { success: true };
    } catch (error) {
      await releaseLock();
      await audit('error');
      if (error instanceof HttpsError) throw error;
      // Les erreurs Auth peuvent embarquer des valeurs d'entrée : message fixe.
      throw new HttpsError('internal', 'Changement de mot de passe impossible. Réessayez.');
    }
  };
}

module.exports = {
  buildCompletePartnerFirstPasswordChange,
  PROFILE_COLLECTIONS,
  PROVISIONING_COLLECTION,
};
