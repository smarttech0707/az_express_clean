'use strict';

// Vérifie, AVANT de démarrer les émulateurs ou d'installer un APK, que la configuration locale ne peut pas
// atteindre la production ni un service externe. Lecture seule ; code retour 1 au moindre problème.
//
// Usage : node test-env/verify-emulator-isolation.js [--android] [--strict-env]
//   --android     vérifie aussi android/app/src/debug/google-services.json (configuration factice)
//   --strict-env  échoue (au lieu d'avertir) si le shell contient des clés/identifiants externes

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const g = require('./lib/guards');
const { toEmulatorStorageRules } = require('./lib/storageRulesForEmulator');
const { isSecretFile } = require('./stage-functions');

const root = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const problems = [];
const warnings = [];
const ok = [];
const fail = (m) => problems.push(m);
const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'));

// 1. Configuration des émulateurs
const cfgRel = 'test-env/firebase.emulators.json';
let cfg = null;
try {
  const text = fs.readFileSync(path.join(root, cfgRel), 'utf8');
  cfg = JSON.parse(text);
  const refs = g.findProductionReferences(text);
  if (refs.length) fail(`${cfgRel} : référence de production ${refs.join(', ')}`);
} catch (e) { fail(`${cfgRel} illisible : ${e.message}`); }
if (cfg) {
  if (cfg.functions?.source !== 'runtime/functions') fail('functions.source doit être runtime/functions (copie sans .env, relatif à test-env/)');
  for (const name of ['auth', 'firestore', 'functions', 'storage']) {
    if (!cfg.emulators?.[name]?.port) fail(`émulateur ${name} non configuré`);
  }
  if (!['127.0.0.1', 'localhost'].includes(cfg.emulators?.ui?.host)) fail('l’interface (ui) ne doit écouter que sur 127.0.0.1');
  // Règles : copies (identiques) des fichiers de production, dans test-env/runtime.
  if (cfg.firestore?.rules !== 'runtime/firestore.rules' || cfg.storage?.rules !== 'runtime/storage.rules') fail('les règles doivent pointer runtime/firestore.rules et runtime/storage.rules');
  for (const name of ['firestore.rules', 'storage.rules']) {
    const copy = path.join(__dirname, 'runtime', name);
    const original = fs.readFileSync(path.join(root, name), 'utf8');
    // storage.rules : copie d'émulateur = original sans le contrôle tombstone de isAuth() (seule différence autorisée).
    const expected = name === 'storage.rules' ? toEmulatorStorageRules(original) : original;
    const normalize = (s) => s.replace(/\r\n/g, '\n');
    if (!fs.existsSync(copy) || normalize(fs.readFileSync(copy, 'utf8')) !== normalize(expected)) {
      fail(`runtime/${name} différent de ${name} : relancez node test-env/stage-functions.js`);
    }
  }
  if (Object.keys(cfg).some((k) => ['hosting', 'extensions'].includes(k))) fail('hosting/extensions ne doivent pas figurer dans la configuration des émulateurs');
  ok.push('configuration des émulateurs');
}

// 2. Fichiers de production non modifiés par ce chantier
const gitDiff = spawnSync('git', ['diff', '--quiet', '--', '.firebaserc'], { cwd: root });
if (gitDiff.status !== 0) fail('.firebaserc a été modifié (le projet actif ne doit pas changer)');
else ok.push('.firebaserc inchangé');

// 3. Dossier d'exécution des fonctions
const stage = path.join(__dirname, 'runtime', 'functions');
if (!fs.existsSync(stage)) {
  fail('dossier d’exécution absent : lancez « node test-env/stage-functions.js »');
} else {
  const leaked = fs.readdirSync(stage).filter((f) => isSecretFile(f) && !['.env.demo-az-express', '.secret.local'].includes(f));
  if (leaked.length) fail(`fichiers d’environnement/secrets dans le dossier d’exécution : ${leaked.join(', ')}`);
  const pkg = JSON.parse(fs.readFileSync(path.join(stage, 'package.json'), 'utf8'));
  if (pkg.main !== 'emulator-entry.js') fail('package.json du dossier d’exécution : main doit être emulator-entry.js');
  const entry = fs.readFileSync(path.join(stage, 'emulator-entry.js'), 'utf8');
  const guardAt = entry.indexOf("require('./egressGuard')");
  if (guardAt < 0 || guardAt > entry.indexOf("require('firebase-admin')") || guardAt > entry.indexOf("require('./index.js')")) fail('emulator-entry.js doit charger egressGuard avant tout autre module');
  const envPath = path.join(stage, '.env.demo-az-express');
  if (!fs.existsSync(envPath)) fail('.env.demo-az-express absent');
  else {
    const envText = fs.readFileSync(envPath, 'utf8');
    g.checkFunctionsEnv(envText).forEach((m) => fail(`.env.demo-az-express : ${m}`));
    g.findProductionReferences(envText).forEach((h) => fail(`.env.demo-az-express : référence de production ${h}`));
  }
  const secretFile = path.join(stage, '.secret.local');
  if (!fs.existsSync(secretFile)) fail('.secret.local absent (l’émulateur interrogerait Secret Manager)');
  else {
    for (const line of fs.readFileSync(secretFile, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)) {
      const value = line.slice(line.indexOf('=') + 1);
      if (value !== 'DISABLED' && !/^[0-9a-f]{32}$/.test(value)) fail(`.secret.local : valeur inattendue pour ${line.split('=')[0]} (seuls DISABLED ou un pepper aléatoire sont permis)`);
    }
  }
  // Aucun identifiant de production ne doit être injecté par la copie elle-même (configuration, pas le code applicatif).
  if (!fs.existsSync(path.join(stage, 'node_modules'))) fail('node_modules absent du dossier d’exécution');
  ok.push('dossier d’exécution des fonctions');
}

// 4. Auto-test du garde de sortie réseau
const probe = spawnSync(process.execPath, ['-e', `
  require(${JSON.stringify(path.join(__dirname, 'emulator', 'egressGuard.js'))});
  const t = (c) => setTimeout(() => process.exit(c), 4000);
  require('https').get('https://api.feexpay.me/')
    .on('error', (e) => process.exit(e.code === 'AZ_EGRESS_BLOCKED' ? 0 : 4))
    .on('response', () => process.exit(2)); t(3);`], { encoding: 'utf8', timeout: 15000 });
if (probe.status !== 0) fail(`le garde de sortie réseau ne bloque pas api.feexpay.me (code ${probe.status})`);
else ok.push('garde de sortie réseau opérationnel (FeexPay bloqué)');

// 5. Environnement du shell
try { g.assertNoProductionEnv(process.env); } catch (e) { fail(e.message); }
const SENSITIVE = ['ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'DEEPSEEK_API_KEY', 'MISTRAL_API_KEY', 'GROQ_API_KEY',
  'FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET', 'FEEXPAY_SHOP_ID', 'GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_TOKEN',
  'DELIVERY_SMS_ENABLED', 'ORANGE_SMS_CLIENT_ID', 'ORANGE_SMS_CLIENT_SECRET'];
const present = SENSITIVE.filter((k) => process.env[k]);
if (present.length) {
  (args.includes('--strict-env') ? fail : (m) => warnings.push(m))(`variables sensibles présentes dans le shell : ${present.join(', ')}`);
} else ok.push('aucune clé externe dans le shell');

// 5b. Identifiants Google par défaut (ADC) : le CLI les signale comme accès « production » pour les services non émulés.
const adcHome = process.env.CLOUDSDK_CONFIG || path.join(process.env.APPDATA || '', 'gcloud');
if (fs.existsSync(path.join(adcHome, 'application_default_credentials.json'))) {
  (args.includes('--strict-env') ? fail : (m) => warnings.push(m))('identifiants Google par défaut (ADC) présents : définir CLOUDSDK_CONFIG sur un dossier vide');
} else ok.push('aucun identifiant Google par défaut accessible');

// 6. Configuration Android factice (optionnelle)
if (args.includes('--android')) {
  const gsRel = 'android/app/src/debug/google-services.json';
  try {
    const text = fs.readFileSync(path.join(root, gsRel), 'utf8');
    const j = JSON.parse(text);
    if (j.project_info?.project_id !== 'demo-az-express') fail(`${gsRel} : projet non factice (${j.project_info?.project_id})`);
    g.findProductionReferences(text).forEach((h) => fail(`${gsRel} : référence de production ${h}`));
    const pkgs = (j.client || []).map((c) => c.client_info?.android_client_info?.package_name);
    if (pkgs.length !== 1 || pkgs[0] !== 'com.azexpress.app.test') fail(`${gsRel} : paquet attendu com.azexpress.app.test`);
    ok.push('google-services.json factice');
  } catch (e) { fail(`${gsRel} : ${e.message}`); }
  const mf = path.join(root, 'android/app/src/azTest/AndroidManifest.xml');
  if (!fs.existsSync(mf) || !/usesCleartextTraffic="true"/.test(fs.readFileSync(mf, 'utf8'))) fail('manifeste android/app/src/azTest manquant ou sans HTTP clair local');
  // Bibliothèques Firebase natives qui contacteraient Google (FID, réglages, télémétrie) : toutes coupées dans le manifeste de test.
  if (fs.existsSync(mf)) {
    const manifest = fs.readFileSync(mf, 'utf8');
    for (const flag of ['firebase_sessions_enabled', 'firebase_messaging_auto_init_enabled', 'firebase_analytics_collection_enabled',
      'firebase_crashlytics_collection_enabled', 'google_analytics_adid_collection_enabled']) {
      if (!new RegExp(`android:name="${flag}"\\s+android:value="false"`).test(manifest)) fail(`manifeste de test : ${flag} doit valoir false`);
    }
  }
  // Clé API factice : format exigé par firebase-installations, reconnaissable, jamais une clé réelle du dépôt.
  try {
    const demoKey = JSON.parse(fs.readFileSync(path.join(root, gsRel), 'utf8')).client?.[0]?.api_key?.[0]?.current_key || '';
    if (!/^A[\w-]{38}$/.test(demoKey)) fail(`${gsRel} : clé API factice au mauvais format (firebase-installations l'exige : ^A[\\w-]{38}$)`);
    if (!/DEMO/.test(demoKey)) fail(`${gsRel} : la clé factice doit contenir « DEMO »`);
    const realKeys = new Set();
    for (const f of ['android/app/google-services.json', 'android/local.properties', 'lib/constants/app_constants.dart',
      'lib/constants/maps_key.dart', 'functions/.env']) {
      try { for (const m of fs.readFileSync(path.join(root, f), 'utf8').matchAll(/AIza[0-9A-Za-z_-]{30,}/g)) realKeys.add(m[0]); } catch { /* absent */ }
    }
    if (realKeys.has(demoKey)) fail(`${gsRel} : la clé factice est une clé réelle du dépôt`);
    const dart = fs.readFileSync(path.join(root, 'lib/services/firebase_emulator_config.dart'), 'utf8');
    if (!dart.includes(`apiKey: '${demoKey}'`)) fail('firebase_emulator_config.dart : apiKey différente de la clé factice du google-services.json');
    ok.push('clé API factice valide et distincte des clés réelles ; bibliothèques Firebase natives coupées');
  } catch (e) { fail(`contrôle clé factice : ${e.message}`); }
}

for (const m of ok) console.log(`  OK  ${m}`);
for (const m of warnings) console.warn(`  ATTENTION  ${m} (elles seront retirées par emulators-start.ps1)`);
if (problems.length) {
  console.error('ISOLATION NON VALIDÉE :');
  problems.forEach((p) => console.error(` - ${p}`));
  process.exit(1);
}
console.log('Isolation validée : émulateurs locaux uniquement, aucun service externe joignable.');
