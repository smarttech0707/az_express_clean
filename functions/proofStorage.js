'use strict';

// Preuve de livraison (Mission 7E-11-T) : l'application envoie la photo dans Storage puis transmet son URL de téléchargement
// à deliverOrderCF. Seul le serveur est fiable : l'URL ne doit désigner QUE le fichier attendu pour (commande, livreur),
// dans le bucket du projet, et ce fichier doit exister. Chemin imposé par storage.rules et par l'application
// (StoragePaths.deliveryPhoto) : delivery_photos/<uid du livreur>/<commande>.jpg.

const MAX_URL_LENGTH = 2048;
const HOSTS = new Set(['firebasestorage.googleapis.com']);

// Le bucket par défaut a deux noms équivalents (<projet>.appspot.com, <projet>.firebasestorage.app) et l'application reçoit le sien à
// la compilation (FIREBASE_STORAGE_BUCKET) : on compare le projet, pas le suffixe, pour ne jamais bloquer une livraison sur un alias.
const bucketBase = (name) => String(name).replace(/\.(appspot\.com|firebasestorage\.app)$/, '');

function deliveryPhotoPath(orderId, uid) { return `delivery_photos/${uid}/${orderId}.jpg`; }

// Objet désigné par une URL de téléchargement Firebase (https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<chemin encodé>?…),
// ou null. Contrairement à une simple recherche de sous-chaîne, l'hôte, le bucket et la forme du chemin sont vérifiés :
// une URL `https://autre-site/…/delivery_photos/<uid>/<commande>.jpg` ne passe pas.
function storageObjectOfUrl(url, bucketName) {
  if (typeof url !== 'string' || !url || url.length > MAX_URL_LENGTH) return null;
  let parsed;
  try { parsed = new URL(url); } catch (_) { return null; }
  if (parsed.protocol !== 'https:' || !HOSTS.has(parsed.hostname) || parsed.username || parsed.password) return null;
  const m = /^\/v0\/b\/([^/]+)\/o\/([^/]+)$/.exec(parsed.pathname);
  if (!m) return null;
  if (bucketName && bucketBase(m[1]) !== bucketBase(bucketName)) return null;
  try { return decodeURIComponent(m[2]); } catch (_) { return null; }
}

function deliveryPhotoUrlMatches(url, orderId, uid, bucketName) {
  return storageObjectOfUrl(url, bucketName) === deliveryPhotoPath(orderId, uid);
}

module.exports = { deliveryPhotoPath, storageObjectOfUrl, deliveryPhotoUrlMatches, MAX_URL_LENGTH };
