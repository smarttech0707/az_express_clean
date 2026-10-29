'use strict';

// Règles Storage utilisées UNIQUEMENT par Firebase Emulator Suite (test-env/runtime/storage.rules).
//
// Pourquoi : dans l'émulateur, un envoi sans métadonnée `contentType` explicite est enregistré en
// `application/octet-stream` (l'émulateur n'infère pas image/jpeg depuis l'extension .jpg, contrairement à
// Cloud Storage en production). La règle isImage() le refuse alors (403 « No WRITE permission »), ce qui bloque
// le selfie d'acceptation et les photos de livraison dans les tests sur téléphone.
// Preuve (émulateur jetable) : avec les règles d'origine, un envoi déclarant image/jpeg est accepté ; selfie d'un
// autre livreur, fichier text/plain et dossier d'un autre uid sont refusés. Le contrôle account_tombstones n'est pas en cause.
//
// Seule différence avec storage.rules : isImage() accepte aussi application/octet-stream.
// Les règles de production ne sont jamais modifiées par ce module. Les autres contrôles (propriétaire, taille,
// nom de fichier, tombstone, lectures Firestore des règles partenaires) sont conservés tels quels.

const IS_IMAGE = /(function isImage\(\) \{\s*return )request\.resource\.contentType\.matches\('image\/\.\*'\);/;
const BANNER = [
  '// ⚠ COPIE POUR ÉMULATEUR UNIQUEMENT — générée par test-env/lib/storageRulesForEmulator.js.',
  '// Différence avec storage.rules : isImage() accepte aussi application/octet-stream (l\'émulateur n\'infère pas le type depuis .jpg).',
  '',
].join('\n');

function toEmulatorStorageRules(source) {
  const text = source.replace(/\r\n/g, '\n');
  if (!IS_IMAGE.test(text)) throw new Error('storage.rules : fonction isImage() introuvable ou modifiée (format changé ?)');
  const body = text.replace(IS_IMAGE,
    "$1request.resource.contentType.matches('image/.*') || request.resource.contentType == 'application/octet-stream';");
  return `${BANNER}${body}`;
}

module.exports = { toEmulatorStorageRules };
