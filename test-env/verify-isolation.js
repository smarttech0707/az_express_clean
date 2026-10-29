'use strict';

// Vérifie que la configuration du projet de test ne pointe vers AUCUNE ressource de production.
// Usage : node test-env/verify-isolation.js [--env functions/.env.<projet-test>]
//                                           [--defines test-env/dart-defines.test.json]
//                                           [--google-services android/app/src/debug/google-services.json]
// Code retour 1 au moindre problème. Lecture seule.

const fs = require('fs');
const path = require('path');
const g = require('./lib/guards');

const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const root = path.resolve(__dirname, '..');
const problems = [];

function read(rel) {
  const p = path.resolve(root, rel);
  if (!fs.existsSync(p)) { problems.push(`Fichier absent : ${rel}`); return null; }
  return fs.readFileSync(p, 'utf8');
}

try { g.assertNoProductionEnv(process.env); } catch (e) { problems.push(e.message); }

const envFile = opt('--env', null);
if (envFile) {
  const text = read(envFile);
  if (text !== null) {
    g.checkFunctionsEnv(text).forEach((m) => problems.push(`${envFile} : ${m}`));
    g.findProductionReferences(text).forEach((h) => problems.push(`${envFile} : référence de production « ${h} »`));
  }
}
const definesFile = opt('--defines', 'test-env/dart-defines.test.json');
const defines = read(definesFile);
if (defines !== null) {
  let json = null;
  try { json = JSON.parse(defines); } catch (_) { problems.push(`${definesFile} : JSON invalide`); }
  if (json) g.checkDartDefines(json).forEach((m) => problems.push(`${definesFile} : ${m}`));
  g.findProductionReferences(defines).forEach((h) => problems.push(`${definesFile} : référence de production « ${h} »`));
}
const gsFile = opt('--google-services', 'android/app/src/debug/google-services.json');
const gs = read(gsFile);
if (gs !== null) {
  g.findProductionReferences(gs).forEach((h) => problems.push(`${gsFile} : référence de production « ${h} »`));
  try {
    const pkgs = JSON.parse(gs).client.map((c) => c.client_info.android_client_info.package_name);
    if (!pkgs.includes('com.azexpress.app.test')) problems.push(`${gsFile} : aucune app Android com.azexpress.app.test`);
  } catch (_) { problems.push(`${gsFile} : format inattendu`); }
}

if (problems.length) {
  console.error('ISOLATION NON VALIDÉE :');
  problems.forEach((p) => console.error(` - ${p}`));
  process.exit(1);
}
console.log('Isolation validée : aucune référence de production, SMS et paiements réels désactivés.');
