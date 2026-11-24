'use strict';
// M1.1 — fonctions callable JETABLES, pour l'ÉMULATEUR Functions local uniquement. Copiées par run-m1-local.js dans
// un dossier temporaire ; jamais déployées ni référencées par firebase.json du dépôt. Elles enrobent le prototype M1.
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { makeClientPhoneLogin } = require('./clientPhoneLoginPrototype');

// Garde : sans les trois hôtes d'émulateur, on refuse de s'exécuter (jamais de repli vers un service réel).
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST;
if (!AUTH_HOST || !process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error('M1.1: émulateurs Auth et Firestore requis, exécution refusée');
}
initializeApp();
const auth = getAuth();
const db = getFirestore();

// Annuaire réel (Firestore émulé) : la page de connexion actuelle sert clients et vendeurs.
async function directory(phone) {
  const out = [];
  for (const [collection, role] of [['clients', 'client'], ['sellers', 'seller']]) {
    const snap = await db.collection(collection).where('phone', '==', phone).get();
    snap.forEach((d) => out.push({ uid: d.id, phone, email: d.get('email'), role }));
  }
  return out;
}

const login = makeClientPhoneLogin({
  auth, directory, restBase: `http://${AUTH_HOST}`, apiKey: 'fake-api-key', extraClaims: true,
});
const OPTS = { region: 'europe-west1' };

// Plancher de latence : TOUTES les issues (succès, échec, entrée invalide, erreur interne) mettent au moins ce temps, pour que
// la durée ne révèle ni l'existence d'un compte ni la validité d'une entrée. Valeur d'émulateur ; à recalibrer sur la latence réelle
// (p95 d'un succès en préproduction) avant tout usage réel.
const FLOOR_MS = Number(process.env.M1_LATENCY_FLOOR_MS || 400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function withFloor(fn) {
  const t0 = Date.now();
  try { return await fn(); } finally { await sleep(Math.max(0, FLOOR_MS - (Date.now() - t0))); }
}

// Volontairement ignore request.auth : une session (même anonyme) n'est jamais une preuve d'identité ici.
exports.clientPhoneLoginM1 = onCall(OPTS, (request) => withFloor(async () => {
  const data = request.data;
  if (!data || typeof data !== 'object') throw new HttpsError('invalid-argument', 'Requête invalide');
  const { identifier, password } = data; // tout autre champ (role, claims…) est ignoré
  if (typeof identifier === 'string' && identifier.length > 32) return login({});
  try {
    return await login({ identifier, password });
  } catch (e) {
    console.error('clientPhoneLoginM1: erreur interne', e && e.code ? e.code : 'inconnue'); // ni jeton, ni mot de passe
    throw new HttpsError('internal', 'Erreur interne');
  }
}));

// Fonction protégée type : session non anonyme requise, rôle relu côté serveur (jamais lu dans le jeton).
exports.m1WhoAmI = onCall(OPTS, async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Connexion requise');
  if (request.auth.token.firebase && request.auth.token.firebase.sign_in_provider === 'anonymous') {
    throw new HttpsError('permission-denied', 'Session anonyme refusée');
  }
  const uid = request.auth.uid;
  for (const [collection, role] of [['clients', 'client'], ['sellers', 'seller']]) {
    if ((await db.collection(collection).doc(uid).get()).exists) return { uid, role };
  }
  throw new HttpsError('permission-denied', 'Aucun profil');
});
