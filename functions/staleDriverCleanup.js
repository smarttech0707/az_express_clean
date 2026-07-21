'use strict';

// Corrige le flag `isOnline` des livreurs "fantômes" — trouvaille d'un audit
// dispatch en conditions réelles (2026-07-19) : `dispatch.js` exclut déjà
// correctement tout livreur dont `updatedAt` a dépassé STALE_MINUTES de
// l'éligibilité au dispatch (Master Prompt 129), mais rien ne corrige jamais
// le champ `isOnline` lui-même côté Firestore. Un livreur dont l'app a été
// tuée/fermée sans passer par `goOffline()` (crash, téléphone éteint,
// désinstallation, simple oubli) reste donc marqué `isOnline: true`
// indéfiniment — invisible au dispatch réel (correctement filtré), mais
// visible comme "en ligne" partout ailleurs (tableau de bord admin, liste
// des livreurs, carte client) sans aucune correction ni alerte. Si ce
// livreur fantôme est le seul "en ligne" à un instant donné, 100% des
// commandes échouent silencieusement à être attribuées — symptôme
// observable côté client comme "le livreur est connecté mais ne reçoit
// jamais la commande", sans qu'aucune donnée ne révèle la cause réelle.
//
// Ce module rend le flag auto-cicatrisant : périodiquement, tout livreur
// `isOnline: true` dont `updatedAt` est absent ou dépasse le même seuil que
// `dispatch.js` (STALE_MINUTES, importé — jamais dupliqué) est repassé à
// `isOnline: false`. Ne touche à aucune autre logique (wallet, statut de
// commande, suspension) — un correctif de visibilité/cohérence, pas une
// nouvelle règle métier.

const { STALE_MINUTES } = require('./dispatch');

const MAX_PER_RUN = 400; // même marge de sécurité que fcmTokenCleanup.js (limite batch Firestore = 500)

// { checked, corrected }
async function runStaleDriverCleanup(db, admin, { staleMinutes = STALE_MINUTES, now } = {}) {
  const staleMs = (now ?? Date.now()) - staleMinutes * 60 * 1000;

  const snap = await db.collection('livreurs')
    .where('isOnline', '==', true)
    .limit(MAX_PER_RUN)
    .get();

  if (snap.empty) return { checked: 0, corrected: 0 };

  const batch = db.batch();
  let corrected = 0;

  snap.docs.forEach((doc) => {
    const d  = doc.data();
    const ua = d.updatedAt;
    const isStale = !ua || typeof ua.toMillis !== 'function' || ua.toMillis() < staleMs;
    if (isStale) {
      batch.update(doc.ref, { isOnline: false });
      corrected++;
    }
  });

  if (corrected > 0) await batch.commit();
  return { checked: snap.size, corrected };
}

function buildStaleDriverCleanup({ db, admin, onSchedule }) {
  return onSchedule({
    schedule:       'every 5 minutes',
    timeZone:       'Africa/Abidjan',
    timeoutSeconds: 120,
    memory:         '256MiB',
    // Même discipline de quota Cloud Run que les autres schedulers de
    // maintenance (Master Prompt 122) — tâche légère, une seule instance.
    maxInstances:   1,
    cpu:            0.5,
  }, async () => {
    try {
      const result = await runStaleDriverCleanup(db, admin);
      if (result.corrected > 0) {
        console.log(`🧹 Livreurs "en ligne" fantômes corrigés : ${result.corrected}/${result.checked} (GPS obsolète > ${STALE_MINUTES} min).`);
      }
    } catch (err) {
      console.error('staleDriverCleanup error:', err.message);
    }
  });
}

module.exports = { runStaleDriverCleanup, buildStaleDriverCleanup, MAX_PER_RUN };
