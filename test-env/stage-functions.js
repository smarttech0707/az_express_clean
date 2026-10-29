'use strict';

// Prépare le dossier d'exécution des Cloud Functions pour les émulateurs : test-env/runtime/functions.
//
// Pourquoi une copie : le CLI Firebase charge automatiquement functions/.env (production : FEEXPAY_SHOP_ID réel…)
// et tout .env.* du dossier source. La copie exclut TOUS les fichiers d'environnement et de secrets, ajoute le
// garde de sortie réseau, et change le point d'entrée pour le charger avant le code applicatif. Le code de
// production (functions/) n'est jamais modifié.
//
// Copie aussi les règles Firestore/Storage et les index dans test-env/runtime/ (lecture seule des originaux).
// Usage : node test-env/stage-functions.js          (idempotent, recrée la copie)

const fs = require('fs');
const path = require('path');
const { toEmulatorStorageRules } = require('./lib/storageRulesForEmulator');

const root = path.resolve(__dirname, '..');
const source = path.join(root, 'functions');
const target = path.join(__dirname, 'runtime', 'functions');
const SKIP_DIRS = new Set(['node_modules', 'test', 'test-emulator', 'scripts', 'coverage', '.git']);
const isSecretFile = (name) => name === '.env' || name.startsWith('.env.') || name.startsWith('.secret') ||
  name.endsWith('.pem') || name.endsWith('.key') || name === 'serviceAccountKey.json' || name.startsWith('.runtimeconfig');

function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) copyTree(path.join(from, entry.name), path.join(to, entry.name));
    } else if (!isSecretFile(entry.name) && /\.(js|json)$/.test(entry.name) && entry.name !== 'package-lock.json') {
      fs.copyFileSync(path.join(from, entry.name), path.join(to, entry.name));
    }
  }
}

function main() {
  fs.rmSync(target, { recursive: true, force: true });
  copyTree(source, target);

  // Dépendances : jonction vers functions/node_modules (aucune copie, aucun npm install).
  const modules = path.join(source, 'node_modules');
  if (!fs.existsSync(modules)) throw new Error('functions/node_modules absent : lancez « npm ci » dans functions/.');
  fs.symlinkSync(modules, path.join(target, 'node_modules'), 'junction');

  // Point d'entrée : garde de sortie AVANT index.js.
  fs.copyFileSync(path.join(__dirname, 'emulator', 'egressGuard.js'), path.join(target, 'egressGuard.js'));
  fs.copyFileSync(path.join(__dirname, 'emulator', 'emulator-entry.js'), path.join(target, 'emulator-entry.js'));
  fs.copyFileSync(path.join(__dirname, 'emulator', 'ai-sim.js'), path.join(target, 'ai-sim.js'));

  // Secrets factices : sans .secret.local, l'émulateur interroge Google Secret Manager avec les identifiants
  // de connexion du CLI. Le pepper des preuves de livraison est aléatoire (QR/PIN utilisables en test).
  const secrets = ['FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY']
    .map((name) => `${name}=DISABLED`);
  secrets.push(`DELIVERY_PROOF_PEPPER=${require('crypto').randomBytes(16).toString('hex')}`);
  fs.writeFileSync(path.join(target, '.secret.local'), `${secrets.join('\n')}\n`);
  const pkg = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
  pkg.main = 'emulator-entry.js';
  fs.writeFileSync(path.join(target, 'package.json'), `${JSON.stringify(pkg, null, 2)}\n`);

  // Environnement dédié (le seul chargé pour --project demo-az-express).
  fs.copyFileSync(path.join(__dirname, 'emulator', 'functions.env.demo'), path.join(target, '.env.demo-az-express'));
  // Règles : copie en lecture seule des fichiers de production (le CLI refuse les chemins hors du dossier test-env/).
  for (const name of ['firestore.rules', 'firestore.indexes.json']) {
    fs.copyFileSync(path.join(root, name), path.join(__dirname, 'runtime', name));
  }
  // Storage : copie pour émulateur (sans le contrôle tombstone de isAuth(), voir lib/storageRulesForEmulator.js).
  fs.writeFileSync(path.join(__dirname, 'runtime', 'storage.rules'),
    toEmulatorStorageRules(fs.readFileSync(path.join(root, 'storage.rules'), 'utf8')));
  console.log(`Fonctions préparées pour les émulateurs : ${path.relative(root, target)}`);
}

if (require.main === module) {
  try { main(); } catch (e) { console.error(`ERREUR : ${e.message}`); process.exit(1); }
}

module.exports = { isSecretFile, target };
