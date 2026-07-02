'use strict';

const crypto = require('crypto');

// Enveloppe légère d'observabilité par requête — trouvaille du Master Prompt
// 25 : aucune corrélation requestId/utilisateur/durée/résultat n'existait sur
// les Cloud Functions (seules les actions explicitement instrumentées
// écrivent dans `audit_logs` — paiements, wallet, IA, sous-admins, événements
// d'identité). Décision actée (2026-07-02) : appliquer uniquement aux
// NOUVELLES fonctions à partir de maintenant, ne jamais retrofiter les
// fonctions déjà déployées (même principe que l'enveloppe de réponse
// unifiée, voir CLAUDE.md section « API — conventions »).
//
// Écrit dans `request_logs` — une collection distincte d'`audit_logs` :
// volume potentiellement bien plus élevé (une entrée par appel, pas par
// action sensible) et signal différent (diagnostic technique, pas piste
// d'audit métier) — ne pas mélanger les deux sémantiques.
//
// N'enregistre jamais le payload de la requête ni celui de la réponse,
// uniquement des métadonnées (requestId, nom de fonction, uid appelant,
// durée, statut, code/message d'erreur) — évite de stocker des données
// sensibles (mot de passe, montants bruts non nécessaires au diagnostic)
// dans un journal à séparé d'`audit_logs`.
//
// Usage : composer AVANT `onCall(...)`, pas à la place :
//   exports.maFonction = onCall(withObservability({ db, admin }, 'maFonction', async (request) => { ... }));
//
// L'écriture du log est fire-and-forget (jamais `await`ée dans le chemin
// critique) pour ne pas ajouter de latence à la réponse — cohérent avec la
// section Performance de CLAUDE.md.
function withObservability({ db, admin }, functionName, handler) {
  return async (request) => {
    const requestId = crypto.randomUUID();
    const start = Date.now();
    const uid = request.auth?.uid || null;

    try {
      const result = await handler(request);
      logRequestNonBlocking(db, admin, {
        requestId, functionName, userId: uid,
        durationMs: Date.now() - start, status: 'success',
      });
      return (result && typeof result === 'object') ? { ...result, requestId } : result;
    } catch (err) {
      logRequestNonBlocking(db, admin, {
        requestId, functionName, userId: uid,
        durationMs: Date.now() - start, status: 'error',
        errorCode: err.code || 'internal', errorMessage: err.message || null,
      });
      throw err;
    }
  };
}

function logRequestNonBlocking(db, admin, entry) {
  db.collection('request_logs').add({
    ...entry,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }).catch((err) => console.error('request_logs write failed:', err.message));
}

module.exports = { withObservability };
