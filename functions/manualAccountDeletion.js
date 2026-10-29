'use strict';

// Suppression MANUELLE sécurisée des comptes que le moteur automatique (accountDeletion.js) ne couvre pas :
//   - artisan                : pas de compte Firebase personnel (session anonyme liée par PIN) ;
//   - pharmacie historique   : pas de compte Firebase personnel (mot de passe haché, session `currentUid`) ;
//   - prestataire d'événements : compte Firebase réel mais profil hors du moteur partenaires.
// Déclenchée par un super-admin récemment authentifié, à partir d'une demande déjà déposée dans
// `account_deletion_requests`. L'identité du demandeur est vérifiée côté serveur AVANT toute suppression :
//   1. le téléphone de la demande doit correspondre au profil trouvé (et à lui seul : homonyme = refus) ;
//   2. l'admin atteste la vérification (méthode + note) ; l'attestation est journalisée ;
//   3. prestataire d'événements : si la demande a été faite connectée, son uid doit être le propriétaire du profil.
// Rien de financier n'est supprimé : soldes, transactions, commandes et réservations sont conservés (politique de
// conservation non validée). Les mots de passe hachés, fichiers personnels et sessions sont supprimés.

const MANUAL_ROLES = Object.freeze(['artisan', 'pharmacie', 'event_provider']);
const METHODS = Object.freeze(['callback', 'in_person', 'document']);
const FINANCIAL = ['wallet', 'walletBalance', 'balance', 'debt', 'pendingBalance', 'reservedBalance', 'pendingWithdrawal', 'commissionDebt'];
const TERMINAL = new Set(['delivered', 'cancelled', 'expired', 'completed', 'refunded', 'failed_refunded', 'failed', 'rejected', 'declined', 'closed']);
const OTHER_ROLE_COLLECTIONS = ['clients', 'livreurs', 'admins', 'sellers', 'restaurant_owners', 'boulangeries', 'ekbine_agents',
  'real_estate_agents', 'fleet_owners'];
const PHARMACY_PERSONAL = ['name', 'ownerName', 'phone', 'email', 'address', 'lat', 'lng', 'latitude', 'longitude', 'photoUrl', 'logoUrl',
  'password', 'accessCode', 'currentUid', 'fcmToken', 'token', 'licenseNumber', 'licenseUrl', 'contactPhone'];
const EVENT_PERSONAL = ['shopName', 'description', 'zone', 'logoUrl', 'phone', 'email', 'address', 'rejectionReason', 'suspensionReason',
  'categories', 'subcategories', 'fcmToken', 'token', 'documents'];
const PAGE = 400;
const SCAN_LIMIT = 1000;
const RECENT_AUTH_SECONDS = 300;

const digits = (value) => String(value ?? '').replace(/\D/g, '');
const samePhone = (a, b) => digits(a).length >= 8 && digits(a).slice(-9) === digits(b).slice(-9);
const envelope = (message, data) => ({ success: true, error: null, message, data, code: 'OK' });

function buildManualAccountDeletion({
  db, auth, admin, bucket, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin, clock = Date.now,
}) {
  const FieldValue = admin.firestore.FieldValue;

  async function candidates(collection, request, extraEquals) {
    const found = new Map();
    for (const [field, value] of extraEquals) {
      if (value == null || value === '') continue;
      const snap = await db.collection(collection).where(field, '==', value).limit(5).get();
      for (const doc of snap.docs) found.set(doc.id, doc);
    }
    return [...found.values()];
  }

  async function locate(role, req) {
    const raw = req.contactPhone;
    const phones = [raw, digits(raw), digits(raw).slice(-10), `+225${digits(raw).slice(-10)}`];
    if (role === 'artisan' || role === 'pharmacie') {
      const collection = role === 'artisan' ? 'service_providers' : 'pharmacies';
      let matches = (await candidates(collection, req, [...new Set(phones)].map((p) => ['phone', p])))
        .filter((doc) => samePhone(doc.data().phone, raw) && doc.data().isDeleted !== true);
      if (!matches.length) {
        // Numéros enregistrés avec espaces ou indicatif : balayage borné (opération admin rare). Une collection plus
        // grande que la borne n'est jamais devinée : vérification manuelle.
        const scan = await db.collection(collection).limit(SCAN_LIMIT + 1).get();
        if (scan.size > SCAN_LIMIT) throw new HttpsError('failed-precondition', 'Recherche par téléphone impossible : vérification manuelle');
        matches = scan.docs.filter((doc) => samePhone(doc.data().phone, raw) && doc.data().isDeleted !== true);
      }
      if (matches.length !== 1) {
        throw new HttpsError('failed-precondition', matches.length ? 'Plusieurs profils portent ce téléphone : vérification manuelle' : 'Aucun profil ne correspond à ce téléphone');
      }
      return { id: matches[0].id, data: matches[0].data() };
    }
    // Prestataire d'événements : le propriétaire connecté lors de la demande est la preuve la plus forte.
    const byOwner = typeof req.uid === 'string' && req.uid ? await candidates('event_providers', req, [['ownerId', req.uid]]) : [];
    const matches = byOwner.length ? byOwner
      : (await candidates('event_providers', req, [...new Set(phones)].map((p) => ['phone', p]))).filter((doc) => samePhone(doc.data().phone, raw));
    if (matches.length !== 1) {
      throw new HttpsError('failed-precondition', matches.length ? 'Plusieurs profils : vérification manuelle' : 'Aucun profil ne correspond à cette demande');
    }
    return { id: matches[0].id, data: matches[0].data(), ownerStrongProof: byOwner.length === 1 };
  }

  async function financialBlocker(role, target) {
    for (const field of FINANCIAL) {
      const value = target.data[field];
      if (value != null && (!Number.isSafeInteger(value) || value !== 0)) return 'balance_regularization_required';
    }
    const query = role === 'pharmacie'
      ? db.collection('orders').where('pharmacieId', '==', target.id)
      : role === 'event_provider' ? db.collection('event_reservations').where('providerIds', 'array-contains', target.id) : null;
    if (!query) return null;
    const snap = await query.limit(201).get();
    if (snap.size >= 201) return 'history_requires_manual_review';
    for (const doc of snap.docs) {
      const d = doc.data();
      if (!TERMINAL.has(d.status) || d.refundPending === true || d.needsReview === true || d.paymentStatus === 'pending') {
        return 'active_or_unresolved_operation';
      }
    }
    return null;
  }

  async function deleteQuery(query) {
    for (;;) {
      const snap = await query.limit(PAGE).get();
      if (snap.empty) return;
      const batch = db.batch();
      for (const doc of snap.docs) batch.delete(doc.ref);
      await batch.commit();
      if (snap.size < PAGE) return;
    }
  }

  // Session anonyme sans donnée personnelle (artisan, pharmacie historique) : supprimée ; sinon seulement révoquée.
  async function closeSession(uid) {
    if (typeof uid !== 'string' || !uid) return;
    try {
      const user = await auth.getUser(uid);
      if ((user.providerData || []).length === 0) await auth.deleteUser(uid);
      else await auth.revokeRefreshTokens(uid);
    } catch (error) {
      if (error?.code !== 'auth/user-not-found') throw error;
    }
  }

  async function cleanup(role, target, req) {
    const FieldDelete = FieldValue.delete();
    if (role === 'artisan') {
      await bucket.deleteFiles({ prefix: `service_providers/${target.id}/` });
      await db.collection('artisan_credentials').doc(target.id).delete();
      const ref = db.collection('service_providers').doc(target.id);
      if (typeof ref.listCollections === 'function' && (await ref.listCollections()).length) throw new Error('PERSONAL_DATA_INVENTORY_REQUIRED');
      await closeSession(target.data.artisanUid);
      await ref.delete();
    } else if (role === 'pharmacie') {
      await bucket.deleteFiles({ prefix: `pharmacie_logos/${target.id}/` });
      await db.collection('pharmacie_credentials').doc(target.id).delete();
      await closeSession(target.data.currentUid);
      const patch = { isDeleted: true, deletionRequested: true, isActive: false, isOpen: false, deletedAt: FieldValue.serverTimestamp() };
      for (const key of PHARMACY_PERSONAL) if (Object.hasOwn(target.data, key)) patch[key] = FieldDelete;
      // Soldes, transactions et commandes restent en place : seules les données personnelles et l'accès disparaissent.
      await db.collection('pharmacies').doc(target.id).update(patch);
    } else {
      const ownerId = target.data.ownerId;
      if (typeof ownerId !== 'string' || !ownerId || ownerId.includes('/')) throw new Error('OWNER_INVALID');
      await bucket.deleteFiles({ prefix: `event_providers/${ownerId}/` });
      await bucket.deleteFiles({ prefix: `event_offers/${ownerId}/` });
      await deleteQuery(db.collection('event_offers').where('providerId', '==', target.id));
      await db.collection('event_provider_documents').doc(target.id).delete();
      await db.collection('account_tombstones').doc(ownerId).set({ createdAt: FieldValue.serverTimestamp(), state: 'deleting', source: 'manual_event_provider' });
      try {
        await auth.updateUser(ownerId, { disabled: true });
        await auth.revokeRefreshTokens(ownerId);
        await auth.deleteUser(ownerId);
      } catch (error) {
        if (error?.code !== 'auth/user-not-found') throw error;
      }
      try {
        await auth.getUser(ownerId);
        throw new Error('AUTH_NOT_DELETED');
      } catch (error) {
        if (error?.code !== 'auth/user-not-found') throw error;
      }
      const patch = { isDeleted: true, deletionRequested: true, isSuspended: true, deletedAt: FieldValue.serverTimestamp() };
      for (const key of EVENT_PERSONAL) if (Object.hasOwn(target.data, key)) patch[key] = FieldDelete;
      await db.collection('event_providers').doc(target.id).update(patch);
    }
  }

  return onCall(async (request) => {
    if (!request.auth || request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Connexion requise');
    }
    await requireSuperAdmin({ request, db });
    const adminUid = request.auth.uid;
    const authTime = Number(request.auth.token?.auth_time);
    if (!Number.isFinite(authTime) || clock() / 1000 - authTime > RECENT_AUTH_SECONDS) {
      throw new HttpsError('permission-denied', 'Reconnexion récente requise');
    }
    const { requestId, identityVerification } = request.data || {};
    if (typeof requestId !== 'string' || !requestId || requestId.length > 128 || requestId.includes('/')) {
      throw new HttpsError('invalid-argument', 'Demande invalide');
    }
    const method = identityVerification?.method;
    const note = typeof identityVerification?.note === 'string' ? identityVerification.note.trim() : '';
    if (!METHODS.includes(method) || note.length < 10 || note.length > 300) {
      throw new HttpsError('invalid-argument', 'Vérification d\'identité requise (méthode et note de 10 à 300 caractères)');
    }
    await checkRateLimit(adminUid, 'manual_account_deletion', 20, 3600);

    const requestRef = db.collection('account_deletion_requests').doc(requestId);
    const requestSnap = await requestRef.get();
    if (!requestSnap.exists) throw new HttpsError('not-found', 'Demande introuvable');
    const req = requestSnap.data();
    if (!MANUAL_ROLES.includes(req.role)) {
      throw new HttpsError('failed-precondition', 'Ce rôle utilise la suppression automatique');
    }
    if (req.status === 'completed') return envelope('Déjà supprimé', { status: 'completed', alreadyDone: true });

    // Reprise : la cible est mémorisée dès la première exécution (le profil peut déjà avoir été supprimé).
    let target;
    if (typeof req.targetId === 'string' && req.targetId && req.status === 'cleanup_pending') {
      const col = req.role === 'artisan' ? 'service_providers' : req.role === 'pharmacie' ? 'pharmacies' : 'event_providers';
      const snap = await db.collection(col).doc(req.targetId).get();
      target = { id: req.targetId, data: snap.exists ? snap.data() : {}, resumed: true };
    } else {
      target = await locate(req.role, req);
      if (req.role === 'event_provider') {
        // Un compte partagé avec un autre rôle (client, livreur, admin...) ne doit pas perdre son accès à cause de ce profil.
        for (const col of OTHER_ROLE_COLLECTIONS) {
          if ((await db.collection(col).doc(target.data.ownerId).get()).exists) {
            await requestRef.update({ status: 'blocked', reason: 'multiple_roles_manual_review', reviewRequired: true });
            return envelope('Bloqué : compte multirôle', { status: 'blocked', reason: 'multiple_roles_manual_review' });
          }
        }
      }
      if (req.role === 'pharmacie') {
        const linked = await db.collection('pharmacy_owners').where('pharmacyId', '==', target.id).limit(1).get();
        if (!linked.empty) {
          await requestRef.update({ status: 'blocked', reason: 'linked_owner_uses_automatic_deletion', reviewRequired: true });
          return envelope('Bloqué : responsable lié', { status: 'blocked', reason: 'linked_owner_uses_automatic_deletion' });
        }
      }
      // Quarantaine : plus aucune nouvelle opération pendant les contrôles et le nettoyage.
      const col = req.role === 'artisan' ? 'service_providers' : req.role === 'pharmacie' ? 'pharmacies' : 'event_providers';
      await db.collection(col).doc(target.id).update({ deletionRequested: true });
      const blocker = await financialBlocker(req.role, target);
      if (blocker) {
        await requestRef.update({ status: 'blocked', reason: blocker, reviewRequired: true, targetId: target.id });
        return envelope('Bloqué : régularisation requise', { status: 'blocked', reason: blocker });
      }
    }

    await requestRef.update({
      status: 'cleanup_pending', reason: 'personal_data_cleanup', targetId: target.id, reviewRequired: false,
      identityVerification: { method, verifiedBy: adminUid, note, ownerSessionProof: target.ownerStrongProof === true },
    });
    try {
      await cleanup(req.role, target, req);
    } catch (error) {
      await requestRef.update({ status: 'cleanup_pending', reason: 'server_retry_required', reviewRequired: true });
      throw new HttpsError('internal', 'Nettoyage incomplet : relancez la procédure (aucune suppression annoncée)');
    }
    // Reçu minimal : plus de téléphone, e-mail ni motif conservés sur la demande.
    await requestRef.update({
      status: 'completed', reason: null, completedAt: FieldValue.serverTimestamp(), processedBy: adminUid,
      contactPhone: FieldValue.delete(), contactEmail: FieldValue.delete(), uid: FieldValue.delete(),
      docId: FieldValue.delete(),
    });
    await logAudit({
      userId: adminUid, userType: 'admin', action: 'manual_account_deletion', targetId: target.id, status: 'success',
      metadata: { role: req.role, method, requestId },
    });
    return envelope('Compte supprimé', { status: 'completed', role: req.role });
  });
}

module.exports = { buildManualAccountDeletion, MANUAL_ROLES };
