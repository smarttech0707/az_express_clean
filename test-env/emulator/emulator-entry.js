'use strict';

// Point d'entrée des Cloud Functions dans l'émulateur (copié dans test-env/runtime/functions).
// 1) Garde de sortie réseau chargé AVANT tout code applicatif.
require('./egressGuard');

// 2) Émulateur Functions : son proxy de firebase-admin lie admin.firestore (bind) et en retire les propriétés
//    statiques (FieldValue, Timestamp, GeoPoint…), ce que le code de production utilise. On les restaure ;
//    sans effet si elles sont déjà présentes.
const admin = require('firebase-admin');
if (!admin.firestore.FieldValue) {
  const gcf = require(require.resolve('@google-cloud/firestore', { paths: [require.resolve('firebase-admin')] }));
  const wrapped = admin.firestore;
  // « function » (pas une flèche) : le proxy ne re-lie pas les constructeurs, donc les propriétés restent.
  // eslint-disable-next-line func-names
  const firestore = function firestore(app) { return wrapped(app); };
  Object.assign(firestore, gcf);
  Object.defineProperty(admin, 'firestore', { value: firestore, configurable: true, enumerable: true });
}

// 3) Fournisseur d'IA simulé : aucun appel à Anthropic/Gemini, requêtes journalisées localement.
require('./ai-sim').install();

module.exports = require('./index.js');
