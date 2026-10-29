'use strict';

// Garde-fous communs aux scripts du projet de test : aucun ne doit pouvoir viser la
// production. Logique pure (testée dans functions/test/testEnvGuards.test.js).

// Identifiants de PRODUCTION (ancien et actuel) et marqueurs qui en dérivent.
const PRODUCTION = Object.freeze({
  projectIds: ['az-express-b0469', 'az-express-clean'],
  projectNumber: '697217052961',
  appIdFragments: ['c645fe608310b5f6ea4e60', 'f7b1b0d0f2e67372ea4e60', 'b382306111515c80ea4e60',
    '01c30533de15cda1ea4e60', '6ebbf16cc8131e53ea4e60'],
});

const TEST_ID_PATTERN = /(test|staging|demo)/i;

function isProductionProject(id) {
  return PRODUCTION.projectIds.includes(String(id || '').trim().toLowerCase());
}

// Un projet de test doit être explicitement nommé comme tel ET différer de la production.
function assertTestProject(id) {
  const value = String(id || '').trim();
  if (!value) throw new Error('Projet manquant (--project <id-projet-test>).');
  if (isProductionProject(value)) throw new Error(`Refus : « ${value} » est le projet de PRODUCTION.`);
  if (!TEST_ID_PATTERN.test(value)) {
    throw new Error(`Refus : « ${value} » ne ressemble pas à un projet de test (le nom doit contenir test, staging ou demo).`);
  }
  return value;
}

// Variables d'environnement qui redirigeraient silencieusement le SDK vers la production.
function assertNoProductionEnv(env) {
  for (const key of ['GOOGLE_CLOUD_PROJECT', 'GCLOUD_PROJECT', 'FIREBASE_PROJECT_ID']) {
    if (isProductionProject(env[key])) throw new Error(`Refus : ${key} pointe la production.`);
  }
}

// Retourne la liste des occurrences de ressources de production dans un texte.
function findProductionReferences(text) {
  const hits = [];
  const lower = String(text).toLowerCase();
  for (const id of PRODUCTION.projectIds) if (lower.includes(id)) hits.push(id);
  if (lower.includes(PRODUCTION.projectNumber)) hits.push(PRODUCTION.projectNumber);
  for (const f of PRODUCTION.appIdFragments) if (lower.includes(f)) hits.push(f);
  return hits;
}

// Paramètres qui doivent désactiver SMS payants et paiements réels dans functions/.env.<projet>.
function checkFunctionsEnv(text) {
  const problems = [];
  const map = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i > 0) map[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, '');
  }
  if (map.DELIVERY_SMS_ENABLED !== 'false') problems.push('DELIVERY_SMS_ENABLED doit valoir false');
  if (map.DELIVERY_SMS_PROVIDER && !['none', 'disabled', 'mock'].includes(map.DELIVERY_SMS_PROVIDER)) {
    problems.push('DELIVERY_SMS_PROVIDER ne doit pas désigner un fournisseur réel');
  }
  // Le CLI charge functions/.env (production) PUIS functions/.env.<projet> : sans surcharge explicite,
  // l'identifiant de boutique FeexPay réel serait déployé dans le projet de test.
  if (!/^(DISABLED|disabled)$/.test(map.FEEXPAY_SHOP_ID || '')) {
    problems.push('FEEXPAY_SHOP_ID doit valoir DISABLED (sinon la valeur de functions/.env est héritée)');
  }
  for (const key of ['FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET']) {
    if (map[key] && !/^(DISABLED|disabled|none)$/.test(map[key])) {
      problems.push(`${key} doit être absent ou DISABLED (paiements réels interdits)`);
    }
  }
  return problems;
}

// dart-defines du client de test.
function checkDartDefines(json) {
  const problems = [];
  const id = json.FIREBASE_PROJECT_ID;
  if (!id || isProductionProject(id) || !TEST_ID_PATTERN.test(id)) {
    problems.push('FIREBASE_PROJECT_ID doit être un projet de test');
  }
  for (const key of ['FIREBASE_ANDROID_APP_ID', 'FIREBASE_ANDROID_API_KEY', 'FIREBASE_MESSAGING_SENDER_ID', 'FIREBASE_STORAGE_BUCKET']) {
    if (!json[key] || /^<.*>$/.test(String(json[key]))) problems.push(`${key} non renseigné`);
  }
  if (typeof json.FIREBASE_STORAGE_BUCKET === 'string' &&
      !json.FIREBASE_STORAGE_BUCKET.toLowerCase().includes(String(id || '').toLowerCase())) {
    problems.push('FIREBASE_STORAGE_BUCKET ne correspond pas au projet');
  }
  return problems;
}

module.exports = {
  PRODUCTION, isProductionProject, assertTestProject, assertNoProductionEnv,
  findProductionReferences, checkFunctionsEnv, checkDartDefines,
};
