'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { MUST_CHANGE_CLAIM } = require('./partnerTemporaryPassword');

const PROVISIONING_COLLECTION = 'partner_provisioning';

/// Refuse une opération sensible tant qu'un partenaire créé par l'administration
/// n'a pas remplacé son mot de passe temporaire.
///
/// Même logique d'autorité que `partnerActivated()` dans firestore.rules :
///  - si le journal serveur `partner_provisioning/{uid}` existe, il FAIT
///    AUTORITÉ (seul le serveur l'écrit). Il couvre un jeton ANCIEN émis avant
///    la pose de la revendication, et ne pénalise pas un jeton dont la
///    revendication est périmée après le changement ;
///  - sinon, la revendication du jeton (`partnerMustChangePassword`) décide.
///
/// Les autres catégories d'utilisateurs (clients, livreurs, pharmacies, admins,
/// comptes historiques...) n'ont ni revendication ni journal : aucun effet.
/// Aucune écriture ; une seule lecture de document.
async function assertPartnerActivated({ db, request }) {
  const uid = request.auth?.uid;
  if (!uid) return; // l'appelant a déjà exigé l'authentification
  const snapshot = await db.collection(PROVISIONING_COLLECTION).doc(uid).get();
  const mustChange = snapshot.exists
    ? snapshot.data()?.mustChangePassword === true
    : request.auth.token?.[MUST_CHANGE_CLAIM] === true;
  if (mustChange) {
    throw new HttpsError('failed-precondition',
      'Activation du compte requise : définissez d\'abord votre mot de passe personnel.');
  }
}

module.exports = { assertPartnerActivated, PROVISIONING_COLLECTION };
