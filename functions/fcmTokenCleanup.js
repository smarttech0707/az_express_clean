'use strict';

// Ferme la boucle de nettoyage des tokens FCM invalides — trouvaille du
// Master Prompt 30 : `sendToMultipleTokens` (functions/index.js) détecte déjà
// les tokens FCM invalides et les écrit dans `invalid_fcm_tokens`, mais rien
// ne consommait jamais cette collection — le champ `fcmToken` resté invalide
// sur le document du compte n'était jamais effacé, donc les envois futurs
// continuaient d'échouer contre le même jeton mort indéfiniment. Ce module
// lit `invalid_fcm_tokens`, retrouve le(s) compte(s) qui détiennent encore
// exactement ce token, efface le champ, puis retire l'entrée traitée.
//
// Recherche par égalité simple (`where('fcmToken','==',token)`) sur chaque
// collection connue pour porter ce champ — pas d'index composite requis
// (index à champ unique automatique côté Firestore).

const FCM_TOKEN_COLLECTIONS = [
  'clients', 'livreurs', 'sellers', 'restaurants', 'pharmacies', 'boulangeries',
  'admins', 'ekbine_agents', 'fleet_owners', 'real_estate_agents',
];

// Borne prudente : reste sous la limite de 500 opérations par batch Firestore
// même en cumulant les effacements de champ. Un éventuel surplus est repris
// la semaine suivante (le run est idempotent — pas de perte de données).
const MAX_PER_RUN = 400;

// Efface `fcmToken` sur tous les documents (généralement 0 ou 1) qui portent
// encore ce token exact, dans une des collections connues. Retourne le
// nombre de documents effacés.
async function clearTokenFromAccounts(db, admin, token) {
  let clearedCount = 0;
  for (const collectionName of FCM_TOKEN_COLLECTIONS) {
    const snap = await db.collection(collectionName)
      .where('fcmToken', '==', token)
      .limit(5)
      .get();
    if (snap.empty) continue;

    const batch = db.batch();
    snap.docs.forEach((doc) => {
      batch.update(doc.ref, { fcmToken: admin.firestore.FieldValue.delete() });
    });
    await batch.commit();
    clearedCount += snap.size;
  }
  return clearedCount;
}

// Traite jusqu'à MAX_PER_RUN entrées de `invalid_fcm_tokens` : efface le
// token correspondant partout où il traîne encore, puis retire l'entrée
// traitée (qu'un compte ait été trouvé ou non — l'entrée a fait son travail).
async function runFcmTokenCleanup(db, admin) {
  const snap = await db.collection('invalid_fcm_tokens').limit(MAX_PER_RUN).get();
  if (snap.empty) {
    return { processed: 0, accountsCleared: 0 };
  }

  let accountsCleared = 0;
  const deleteBatch = db.batch();

  for (const doc of snap.docs) {
    const token = doc.data().token;
    if (token) {
      accountsCleared += await clearTokenFromAccounts(db, admin, token);
    }
    deleteBatch.delete(doc.ref);
  }

  await deleteBatch.commit();
  return { processed: snap.size, accountsCleared };
}

function buildFcmTokenCleanup({ db, admin, onSchedule }) {
  return onSchedule({
    schedule:       'every monday 05:00',
    timeZone:       'Africa/Abidjan',
    timeoutSeconds: 300,
    memory:         '256MiB',
    // Master Prompt 122 — quota CPU Cloud Run régional : scheduler
    // hebdomadaire, tâche de nettoyage légère, une seule instance nécessaire.
    maxInstances:   1,
    cpu:            0.5,
  }, async () => {
    try {
      const result = await runFcmTokenCleanup(db, admin);
      if (result.processed > 0) {
        console.log(`🧹 Tokens FCM invalides nettoyés : ${result.processed} entrées traitées, ${result.accountsCleared} champs fcmToken effacés.`);
      }
    } catch (err) {
      console.error('fcmTokenCleanup error:', err.message);
    }
  });
}

module.exports = {
  runFcmTokenCleanup,
  clearTokenFromAccounts,
  buildFcmTokenCleanup,
  FCM_TOKEN_COLLECTIONS,
  MAX_PER_RUN,
};
