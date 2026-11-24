'use strict';

// Tests bout-en-bout de la CLI dry-run (SEC-01, préparation S3), sur la fixture locale fournie.
// Aucun accès Firebase — uniquement lecture d'un fichier JSON local.
//
// Exécution : node --test scripts/driver-public-backfill/backfill.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { main, loadFixture, summarize, parseArgs } = require('./backfill');
const guard = require('./guard');

const FIXTURE = path.join(__dirname, 'fixtures', 'sample-livreurs.json');

test('dry-run sur la fixture : aucune écriture, résumé agrégé uniquement', () => {
  const logs = [];
  const code = main(['--source', FIXTURE], {}, (msg) => logs.push(msg));
  assert.equal(code, 0);
  assert.equal(logs.length, 2);
  const summary = JSON.parse(logs[0]);
  assert.equal(summary.mode, 'dry-run');
  assert.equal(summary.total, 4);
  // Jamais de donnée personnelle individuelle dans la sortie (pas de nom, pas d'URL de photo).
  assert.equal(JSON.stringify(summary).includes('Livreur Actif'), false);
  assert.equal(JSON.stringify(summary).includes('photo2.jpg'), false);
  assert.ok(logs[1].includes('0 écriture effectuée'));
});

test('le résumé compte correctement les champs inclus et les exclusions de types', () => {
  const fixtures = loadFixture(FIXTURE);
  const { mapDriverToPublic } = require('./mapping');
  const results = fixtures.map((e) => mapDriverToPublic(e.id, e.data));
  const summary = summarize(results);
  // driver-active a une position réelle, driver-fresh a 0,0 (placeholder) : une seule comptée.
  assert.equal(summary.positionPlaceholderIgnoree, 1);
  // driver-bad-types produit plusieurs raisons d'exclusion distinctes.
  assert.ok(Object.keys(summary.raisonsExclusion).length >= 3);
  assert.equal(summary.documentsAvecErreurDeType, 1);
});

test('refuse --project même avec un chemin de fixture par ailleurs valide', () => {
  assert.throws(() => parseArgs(['--source', FIXTURE, '--project', 'az-express-b0469']),
    guard.BackfillGuardError);
});

test('refuse --credentials', () => {
  assert.throws(() => parseArgs(['--credentials', './fake.json']), guard.BackfillGuardError);
});

test('refuse un argument inconnu', () => {
  assert.throws(() => parseArgs(['--execute']), guard.BackfillGuardError);
});

test('main refuse l\'exécution si une variable d\'environnement Firebase réelle est présente', () => {
  assert.throws(
    () => main(['--source', FIXTURE], { GOOGLE_APPLICATION_CREDENTIALS: '/x/sa.json' }, () => {}),
    guard.BackfillGuardError);
});

test('refuse une fixture inexistante', () => {
  assert.throws(() => loadFixture(path.join(__dirname, 'fixtures', 'absent.json')), guard.BackfillGuardError);
});

test('refuse une fixture qui n\'est pas un tableau', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const tmp = path.join(os.tmpdir(), `az-dp-backfill-bad-${Date.now()}.json`);
  fs.writeFileSync(tmp, JSON.stringify({ notAnArray: true }));
  try {
    assert.throws(() => loadFixture(tmp), guard.BackfillGuardError);
  } finally {
    fs.unlinkSync(tmp);
  }
});
