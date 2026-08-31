'use strict';

// Module Immobilier (jalon M6) — calqué sur le pattern seller_requests/sellers
// pour l'approbation d'agence, et sur le pattern notifyRestaurantOnOrder pour
// les notifications. `createVisitRequest` est la logique centrale partagée
// par l'écran Flutter (via requestPropertyVisit) et l'outil AZ IA
// `request_property_visit` (appelée directement, sans aller-retour HTTP).

const VISIT_TRANSITIONS = {
  propose: { by: 'agent',  from: ['pending'],            to: 'proposed',  requiresDate: true },
  confirm: { by: 'client', from: ['proposed'],            to: 'confirmed', requiresDate: false },
  decline: { by: 'agent',  from: ['pending', 'proposed'], to: 'declined',  requiresDate: false },
  cancel:  { by: 'client', from: ['pending', 'proposed'], to: 'cancelled', requiresDate: false },
};
const { requireSuperAdmin } = require('./adminGuards');

// `tx` optionnel : fourni par le confirmHandler de l'outil AZ IA
// `request_property_visit` (déjà à l'intérieur de la transaction qui bascule
// le statut de l'action en attente — voir pendingActions.js) ; absent pour
// l'appel direct depuis l'écran Flutter (requestPropertyVisit onCall), qui
// utilise de simples lectures/écritures non transactionnelles.
async function createVisitRequest(db, admin, { uid, listingId, preferredDate, message }, tx = null) {
  if (!listingId) throw new Error('listingId manquant.');

  const listingRef  = db.collection('real_estate_listings').doc(String(listingId));
  const listingSnap = tx ? await tx.get(listingRef) : await listingRef.get();
  if (!listingSnap.exists) throw new Error('Annonce introuvable.');
  const listing = listingSnap.data();
  if (listing.status !== 'active') throw new Error("Cette annonce n'est plus disponible.");

  const ref = db.collection('real_estate_visit_requests').doc();
  const payload = {
    listingId:     listingId,
    listingTitle:  listing.title || null,
    clientId:      uid,
    agentId:       listing.agentId,
    preferredDate: preferredDate || null,
    proposedDate:  null,
    message:       message || null,
    status:        'pending',
    createdAt:     admin.firestore.FieldValue.serverTimestamp(),
  };
  if (tx) tx.set(ref, payload); else await ref.set(payload);

  return { requestId: ref.id, listingTitle: listing.title || null, agentId: listing.agentId };
}

function createRealEstateFunctions({ db, admin, onCall, onDocumentCreated, onDocumentUpdated, checkRateLimit, logAudit, HttpsError, sendToToken }) {

  // Master Prompt 122 — quota CPU Cloud Run régional : Groupe C (immobilier),
  // réduction modérée de maxInstances, cpu inchangé.
  const submitRealEstateAgentRequest = onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { name, phone, agencyName, city } = request.data || {};
    if (!String(name || '').trim() || !String(phone || '').trim()) {
      throw new HttpsError('invalid-argument', 'Nom et téléphone requis');
    }

    await checkRateLimit(uid, 'real_estate_agent_request', 3, 3600);

    const ref = db.collection('real_estate_agent_requests').doc();
    await ref.set({
      uid,
      name:       String(name).trim(),
      phone:      String(phone).trim(),
      agencyName: agencyName ? String(agencyName).trim() : null,
      city:       city ? String(city).trim() : null,
      status:     'pending',
      createdAt:  admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true, requestId: ref.id };
  });

  const approveRealEstateAgentRequest = onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
    const uid = request.auth.uid;
    await requireSuperAdmin({ request, db });

    const { requestId, decision } = request.data || {};
    if (!requestId || !['approve', 'reject'].includes(decision)) {
      throw new HttpsError('invalid-argument', 'Paramètres invalides');
    }

    const reqRef  = db.collection('real_estate_agent_requests').doc(requestId);
    const reqSnap = await reqRef.get();
    if (!reqSnap.exists) throw new HttpsError('not-found', 'Demande introuvable');
    const data = reqSnap.data();
    if (data.status !== 'pending') {
      throw new HttpsError('failed-precondition', 'Cette demande a déjà été traitée');
    }

    if (decision === 'approve') {
      await db.collection('real_estate_agents').doc(data.uid).set({
        uid:        data.uid,
        name:       data.name,
        phone:      data.phone,
        agencyName: data.agencyName,
        city:       data.city,
        isVerified: true,
        isActive:   true,
        createdAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      await reqRef.update({ status: 'approved' });
    } else {
      await reqRef.update({ status: 'rejected' });
    }

    await logAudit({
      userId: uid, userType: 'admin', action: 'real_estate_agent_request_' + decision,
      targetId: requestId, status: 'success',
    });
    return { success: true };
  });

  const requestPropertyVisit = onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    await checkRateLimit(uid, 'visit_request', 5, 3600);

    try {
      const result = await createVisitRequest(db, admin, { uid, ...(request.data || {}) });
      return { success: true, ...result };
    } catch (err) {
      throw new HttpsError('failed-precondition', err.message);
    }
  });

  const respondToVisitRequest = onCall({ maxInstances: 2 }, async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const { requestId, action, proposedDate } = request.data || {};
    const transition = VISIT_TRANSITIONS[action];
    if (!requestId || !transition) {
      throw new HttpsError('invalid-argument', 'Action invalide');
    }
    if (transition.requiresDate && !proposedDate) {
      throw new HttpsError('invalid-argument', 'Une date proposée est requise');
    }

    const ref = db.collection('real_estate_visit_requests').doc(requestId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError('not-found', 'Demande introuvable');
      const data = snap.data();

      const callerField = transition.by === 'agent' ? 'agentId' : 'clientId';
      if (data[callerField] !== uid) {
        throw new HttpsError('permission-denied', 'Non autorisé');
      }
      if (!transition.from.includes(data.status)) {
        throw new HttpsError('failed-precondition', `Transition impossible depuis le statut "${data.status}"`);
      }

      tx.update(ref, {
        status:       transition.to,
        ...(transition.requiresDate ? { proposedDate } : {}),
        resolvedAt:   admin.firestore.FieldValue.serverTimestamp(),
      });

      // Master Prompt "GPS privé V2" — accorder l'accès à la localisation
      // exacte UNIQUEMENT sur une confirmation réelle de visite, dans la
      // MÊME transaction que le changement de statut : jamais un statut
      // "confirmed" sans l'accès correspondant, ni l'inverse. La transition
      // `decline`/`cancel` ne part jamais du statut `confirmed` (voir
      // VISIT_TRANSITIONS ci-dessus), donc aucun accès déjà accordé ne peut
      // être annulé par ce chemin — rien à révoquer explicitement ici.
      if (transition.to === 'confirmed') {
        const accessRef = db.collection('real_estate_location_access')
          .doc(`${data.listingId}_${data.clientId}`);
        tx.set(accessRef, {
          listingId:      data.listingId,
          clientId:       data.clientId,
          grantedBy:      'respondToVisitRequest',
          visitRequestId: requestId,
          isActive:       true,
          expiresAt:      null,
          createdAt:      admin.firestore.FieldValue.serverTimestamp(),
          updatedAt:      admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    });

    await logAudit({
      userId: uid, userType: transition.by, action: 'real_estate_visit_' + action,
      targetId: requestId, status: 'success',
    });
    return { success: true, status: transition.to };
  });

  const notifyAgentOnVisitRequest = onDocumentCreated(
    { document: 'real_estate_visit_requests/{requestId}', maxInstances: 2 },
    async (event) => {
      const data = event.data.data();
      if (!data?.agentId) return;
      const agentSnap = await db.collection('real_estate_agents').doc(data.agentId).get();
      const token = agentSnap.data()?.fcmToken;
      if (!token) return;
      await sendToToken(token,
        '🏠 Nouvelle demande de visite',
        `${data.listingTitle || 'Une annonce'} — un client souhaite visiter.`,
        { type: 'real_estate_visit_request', requestId: event.params.requestId },
      );
    },
  );

  const notifyClientOnVisitUpdate = onDocumentUpdated(
    { document: 'real_estate_visit_requests/{requestId}', maxInstances: 2 },
    async (event) => {
      const before = event.data.before.data();
      const after  = event.data.after.data();
      if (!after || before.status === after.status) return;
      if (!['proposed', 'confirmed', 'declined'].includes(after.status)) return;

      const clientSnap = await db.collection('clients').doc(after.clientId).get();
      const token = clientSnap.data()?.fcmToken;
      if (!token) return;

      const labels = {
        proposed:  `Date de visite proposée pour "${after.listingTitle || 'votre annonce'}".`,
        confirmed: `Visite confirmée pour "${after.listingTitle || 'votre annonce'}".`,
        declined:  `La demande de visite pour "${after.listingTitle || 'votre annonce'}" a été refusée.`,
      };
      await sendToToken(token, '🏠 Visite immobilière', labels[after.status],
        { type: 'real_estate_visit_update', requestId: event.params.requestId, status: after.status });
    },
  );

  return {
    submitRealEstateAgentRequest,
    approveRealEstateAgentRequest,
    requestPropertyVisit,
    respondToVisitRequest,
    notifyAgentOnVisitRequest,
    notifyClientOnVisitUpdate,
  };
}

module.exports = { createRealEstateFunctions, createVisitRequest, VISIT_TRANSITIONS };
