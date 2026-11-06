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

const TEST_ID_PATTERN = /(test|staging|demo|preprod)/i;

function isProductionProject(id) {
  return PRODUCTION.projectIds.includes(String(id || '').trim().toLowerCase());
}

// Un projet de test doit être explicitement nommé comme tel ET différer de la production.
function assertTestProject(id) {
  const value = String(id || '').trim();
  if (!value) throw new Error('Projet manquant (--project <id-projet-test>).');
  if (isProductionProject(value)) throw new Error(`Refus : « ${value} » est le projet de PRODUCTION.`);
  if (!TEST_ID_PATTERN.test(value)) {
    throw new Error(`Refus : « ${value} » ne ressemble pas à un projet de test (le nom doit contenir test, staging, preprod ou demo).`);
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

// Build Android de PRÉPRODUCTION (APK installé sur téléphone). Ces projet/numéro/package sont les seuls admis ; tout écart
// (garde de démarrage absente, google-services.json d'un autre projet, UI des preuves coupée) invalide le build.
const PREPROD = Object.freeze({
  projectId: 'az-express-preprod',
  projectNumber: '306761725053',
  packageName: 'com.azexpress.app.test',
});

function checkPreprodBuild(defines, googleServices) {
  const problems = [];
  const d = defines || {};
  if (d.AZ_REQUIRED_FIREBASE_PROJECT !== PREPROD.projectId) {
    problems.push(`AZ_REQUIRED_FIREBASE_PROJECT doit valoir ${PREPROD.projectId} (garde de démarrage FirebaseProjectGuard)`);
  }
  if (d.FIREBASE_PROJECT_ID !== PREPROD.projectId) problems.push(`FIREBASE_PROJECT_ID doit valoir ${PREPROD.projectId}`);
  if (String(d.FIREBASE_MESSAGING_SENDER_ID) !== PREPROD.projectNumber) {
    problems.push(`FIREBASE_MESSAGING_SENDER_ID doit valoir ${PREPROD.projectNumber}`);
  }
  if (d.DELIVERY_PROOFS_UI !== true && d.DELIVERY_PROOFS_UI !== 'true') {
    problems.push('DELIVERY_PROOFS_UI doit valoir true dans le build de test (preuves QR/PIN)');
  }
  // Aucun jeton FCM sur les comptes fictifs (Mission 7E-55) : le build de test ne doit demander ni écrire aucun jeton.
  if (d.DISABLE_FCM !== true && d.DISABLE_FCM !== 'true') problems.push('DISABLE_FCM doit valoir true dans le build de test (aucun jeton FCM)');
  if (!googleServices) { problems.push('google-services.json de test absent ou illisible'); return problems; }
  const info = googleServices.project_info || {};
  if (info.project_id !== PREPROD.projectId) problems.push(`google-services.json : project_id doit valoir ${PREPROD.projectId}`);
  if (String(info.project_number) !== PREPROD.projectNumber) problems.push(`google-services.json : project_number doit valoir ${PREPROD.projectNumber}`);
  if (info.storage_bucket && !String(info.storage_bucket).includes(PREPROD.projectId)) problems.push('google-services.json : storage_bucket étranger à la préproduction');
  const clients = Array.isArray(googleServices.client) ? googleServices.client : [];
  if (clients.length !== 1) problems.push('google-services.json : exactement une app Android attendue');
  const c = clients[0] || {};
  const pkg = ((c.client_info || {}).android_client_info || {}).package_name;
  if (pkg !== PREPROD.packageName) problems.push(`google-services.json : package doit être ${PREPROD.packageName}`);
  if (!d.FIREBASE_ANDROID_APP_ID || (c.client_info || {}).mobilesdk_app_id !== d.FIREBASE_ANDROID_APP_ID) {
    problems.push('FIREBASE_ANDROID_APP_ID incohérent avec google-services.json');
  }
  const keys = (c.api_key || []).map((k) => k.current_key);
  if (!d.FIREBASE_ANDROID_API_KEY || !keys.includes(d.FIREBASE_ANDROID_API_KEY)) {
    problems.push('FIREBASE_ANDROID_API_KEY incohérente avec google-services.json');
  }
  return problems;
}

module.exports = {
  PREPROD, checkPreprodBuild,
  PRODUCTION, isProductionProject, assertTestProject, assertNoProductionEnv,
  findProductionReferences, checkFunctionsEnv, checkDartDefines,
};
