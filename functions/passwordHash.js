'use strict';

// Hachage de mot de passe (comptes non-Firebase-Auth, ex. pharmacies) —
// scrypt (Node crypto natif, pas de dépendance supplémentaire) + sel
// aléatoire par mot de passe + comparaison à temps constant. Extrait de
// functions/index.js pour rester testable sans initialiser Firebase Admin.
const crypto = require('crypto');

function hashSecret(secret) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(secret), salt, 64).toString('hex');
  return `${salt}:${hash}`;
}

function verifySecret(secret, stored) {
  if (!stored || typeof stored !== 'string' || !stored.includes(':')) return false;
  const [salt, hash] = stored.split(':');
  try {
    const candidate = crypto.scryptSync(String(secret), salt, 64).toString('hex');
    const a = Buffer.from(hash, 'hex');
    const b = Buffer.from(candidate, 'hex');
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch (_) {
    return false;
  }
}

module.exports = { hashSecret, verifySecret };
