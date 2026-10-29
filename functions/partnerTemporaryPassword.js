'use strict';

const crypto = require('node:crypto');

// Politique unique (création, réinitialisation, première connexion) :
// minimum 8 caractères, au moins une majuscule et un chiffre. Identique à
// `validatePassword` de passwordReset.js (même message d'erreur côté serveur).
const MIN_LENGTH = 8;

function meetsPasswordPolicy(value) {
  const password = String(value ?? '');
  return password.length >= MIN_LENGTH && /[A-Z]/.test(password) && /[0-9]/.test(password);
}

// Alphabet sans caractères ambigus (0/O, 1/l/I) : le mot de passe temporaire
// est transmis à la main (SMS, appel, papier).
const UPPER = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const LOWER = 'abcdefghjkmnpqrstuvwxyz';
const DIGITS = '23456789';
const ALL = UPPER + LOWER + DIGITS;
const LENGTH = 12;

function pick(alphabet, randomInt) {
  return alphabet[randomInt(alphabet.length)];
}

/// Mot de passe temporaire à entropie cryptographique (`crypto.randomInt`,
/// jamais un générateur pseudo-aléatoire non cryptographique) : 12 caractères, au moins une majuscule, une minuscule
/// et un chiffre, mélangés par Fisher-Yates sur le même générateur.
function generateTemporaryPassword(randomInt = crypto.randomInt) {
  const chars = [pick(UPPER, randomInt), pick(LOWER, randomInt), pick(DIGITS, randomInt)];
  while (chars.length < LENGTH) chars.push(pick(ALL, randomInt));
  for (let i = chars.length - 1; i > 0; i -= 1) {
    const j = randomInt(i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

// Revendication d'authentification posée sur le compte tant que le mot de passe
// temporaire n'a pas été remplacé. Elle permet à des règles ou fonctions
// FUTURES de refuser un compte non activé ; l'état AUTORITAIRE reste le journal
// serveur `partner_provisioning/{uid}.mustChangePassword` (jamais modifiable par
// un client).
const MUST_CHANGE_CLAIM = 'partnerMustChangePassword';

module.exports = {
  MIN_LENGTH,
  MUST_CHANGE_CLAIM,
  meetsPasswordPolicy,
  generateTemporaryPassword,
};
