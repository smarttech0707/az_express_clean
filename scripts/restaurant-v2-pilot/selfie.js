'use strict';

// Selfie d'acceptation SYNTHÉTIQUE du livreur fictif (Mission 7E-38). Préparation locale uniquement : rien n'est téléversé ici.
// acceptOrderCF refuse l'acceptation sans objet Storage `acceptance_selfies/<commande>/<uid du livreur>.jpg` (driverAcceptance.js,
// SELFIE_REQUIRED) ; storage.rules n'autorise l'écriture que par le livreur lui-même, image/*, moins de 5 Mo.
// L'image (selfie.b64.txt) est un dégradé géométrique : aucune personne, aucune métadonnée EXIF.

const fs = require('node:fs');
const path = require('node:path');
const { IDENTITIES, TARGET } = require('./lot');

const MAX_BYTES = 5 * 1024 * 1024; // storage.rules : request.resource.size < 5 Mo
const CONTENT_TYPE = 'image/jpeg';

const selfieBytes = () => Buffer.from(fs.readFileSync(path.join(__dirname, 'selfie.b64.txt'), 'ascii'), 'base64');
const selfiePath = (orderId) => `acceptance_selfies/${orderId}/${IDENTITIES.driver.uid}.jpg`;

// Reproduit les conditions de storage.rules (match /acceptance_selfies/{orderId}/{file}) ; retourne la liste des violations.
function validateUpload({ objectPath, contentType, size, uid, signInProvider = 'password' }) {
  const violations = [];
  const m = /^acceptance_selfies\/([^/]+)\/([^/]+)$/.exec(objectPath || '');
  if (!m) violations.push('chemin hors acceptance_selfies/<commande>/<fichier>');
  if (signInProvider === 'anonymous' || !uid) violations.push('utilisateur non réel');
  if (m && m[2] !== `${uid}.jpg`) violations.push('le fichier doit s’appeler <uid du livreur>.jpg');
  if (!/^image\/.*/.test(contentType || '')) violations.push('type MIME image/* exigé');
  if (!(Number.isFinite(size) && size < MAX_BYTES)) violations.push('taille < 5 Mo exigée');
  return violations;
}

// URL de téléchargement attendue par acceptOrderCF (hôte, bucket et chemin vérifiés par proofStorage.js).
const downloadUrl = (objectPath, token, bucket = TARGET.storageBucket) =>
  `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/${encodeURIComponent(objectPath)}?alt=media&token=${encodeURIComponent(token)}`;

// Requête de téléversement (API REST Firebase Storage), exécutée plus tard par le livreur avec SON jeton ; le jeton n'est jamais
// stocké ici : `authorization` est un modèle à compléter au moment de l'appel.
function buildSelfieUpload(orderId, bucket = TARGET.storageBucket) {
  const bytes = selfieBytes();
  const objectPath = selfiePath(orderId);
  const violations = validateUpload({ objectPath, contentType: CONTENT_TYPE, size: bytes.length, uid: IDENTITIES.driver.uid });
  if (violations.length) throw new Error(`selfie invalide : ${violations.join(', ')}`);
  return {
    caller: 'driver',
    method: 'POST',
    url: `https://firebasestorage.googleapis.com/v0/b/${bucket}/o?name=${encodeURIComponent(objectPath)}`,
    headers: { 'Content-Type': CONTENT_TYPE, Authorization: 'Firebase <ID token du livreur, fourni à l’exécution>' },
    objectPath, contentType: CONTENT_TYPE, size: bytes.length, bytes,
  };
}

module.exports = { MAX_BYTES, CONTENT_TYPE, selfieBytes, selfiePath, validateUpload, downloadUrl, buildSelfieUpload };
