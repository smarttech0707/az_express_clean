'use strict';

// Régénère test-env/runtime/storage.rules (copie pour émulateur, sans le contrôle tombstone de isAuth()).
// N'arrête rien : l'émulateur en cours recharge le fichier de règles tout seul.
// Usage : node test-env/stage-storage-rules.js

const fs = require('fs');
const path = require('path');
const { toEmulatorStorageRules } = require('./lib/storageRulesForEmulator');

const root = path.resolve(__dirname, '..');
const target = path.join(__dirname, 'runtime', 'storage.rules');

try {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, toEmulatorStorageRules(fs.readFileSync(path.join(root, 'storage.rules'), 'utf8')));
  console.log(`Règles Storage (émulateur) écrites : ${path.relative(root, target)}`);
} catch (e) {
  console.error(`ERREUR : ${e.message}`);
  process.exit(1);
}
