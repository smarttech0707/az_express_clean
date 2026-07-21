'use strict';

// Journalisation des événements d'identité dans `audit_logs` — la pièce
// manquante identifiée lors de l'audit IAM (Master Prompt 24) : l'infra
// (logAudit/checkRateLimit) existe déjà et sert déjà les paiements/wallet/
// outils IA, mais rien n'alimentait les connexions/déconnexions/changements
// de rôle. Le client appelle `logAuthEvent` juste après un signIn réussi ou
// juste avant un signOut (toujours authentifié à ce moment — pas besoin
// d'une fonction bloquante Identity Platform). Les échecs de connexion ne
// sont PAS couverts ici : les journaliser nécessiterait un point d'entrée
// non-authentifié avec sa propre surface d'abus (rate-limit par IP, pas par
// uid) — chantier séparé, pas dans cette passe.

const AUTH_EVENTS = ['login', 'logout'];
const KNOWN_USER_TYPES = [
  'client', 'livreur', 'seller', 'restaurant', 'pharmacie', 'boulangerie',
  'ekbine_agent', 'real_estate_agent', 'fleet_owner', 'admin', 'artisan',
];

function buildLogAuthEvent({ onCall, HttpsError, checkRateLimit, logAudit }) {
  // Master Prompt 122 — quota CPU Cloud Run régional : Groupe C (logs),
  // réduction modérée de maxInstances, cpu inchangé.
  return onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { event, userType } = request.data || {};
    if (!AUTH_EVENTS.includes(event)) {
      throw new HttpsError('invalid-argument', 'event invalide (login|logout attendu)');
    }
    const type = KNOWN_USER_TYPES.includes(userType) ? userType : 'unknown';

    await checkRateLimit(uid, 'auth_event', 30, 60);

    await logAudit({
      userId: uid, userType: type, action: `auth_${event}`, status: 'success',
    });

    return { success: true };
  });
}

// Changements de rôle/permission — réservé aux admins actifs (pas au
// self-service, contrairement à login/logout). Couvre l'édition des
// permissions de sous-admin et l'activation/désactivation d'un sous-admin
// (`admin_sub_admins_page.dart`), toutes deux déjà des écritures Firestore
// directes admin-only côté client — ce CF n'ajoute que la trace d'audit, il
// ne remplace pas ces écritures existantes.
const ADMIN_AUDIT_ACTIONS = ['permissions_changed', 'admin_activated', 'admin_deactivated'];

function buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;

    const adminSnap = await db.collection('admins').doc(uid).get();
    if (!adminSnap.exists || adminSnap.data().isActive === false) {
      throw new HttpsError('permission-denied', 'Réservé aux administrateurs');
    }

    const { action, targetId, metadata } = request.data || {};
    if (!ADMIN_AUDIT_ACTIONS.includes(action)) {
      throw new HttpsError('invalid-argument', 'action invalide');
    }

    await checkRateLimit(uid, 'admin_audit_event', 60, 60);

    await logAudit({
      userId: uid, userType: 'admin', action,
      targetId: targetId || null,
      metadata: (metadata && typeof metadata === 'object') ? metadata : {},
    });

    return { success: true };
  });
}

module.exports = {
  buildLogAuthEvent,
  buildLogAdminAuditEvent,
  AUTH_EVENTS,
  KNOWN_USER_TYPES,
  ADMIN_AUDIT_ACTIONS,
};
