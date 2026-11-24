#!/usr/bin/env node
'use strict';

// Backfill `livreurs` → `driver_public` — DRY-RUN SEULEMENT (SEC-01, préparation S3).
//
//   node scripts/driver-public-backfill/backfill.js --source <fixture.json>
//
// La fixture est un fichier JSON LOCAL : un tableau [{ id, data }, ...] représentant des
// documents `livreurs` (par exemple un export fait séparément, hors de ce script). Ce script ne
// se connecte à AUCUN Firebase, réel ou émulé : il n'existe aucun code de connexion Firestore
// dans ce dossier. Il affiche uniquement un résumé agrégé (compteurs), jamais les données
// personnelles individuelles (nom, photo, position) d'un livreur précis.
//
// Une future phase (S4, hors périmètre ici) devra ajouter, sous sa propre autorisation
// explicite, (a) une lecture réelle de `livreurs` et (b) un mode d'écriture réelle vers
// `driver_public` — aucun des deux n'existe dans ce fichier aujourd'hui.

const fs = require('node:fs');
const path = require('node:path');
const { mapDriverToPublic } = require('./mapping');
const guard = require('./guard');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--source') { out.source = argv[i + 1]; i += 1; }
    else if (arg === '--project' || arg === '--project-id' || arg === '--credentials' || arg === '--service-account') {
      throw new guard.BackfillGuardError(
        `Argument ${arg} refusé : ce script ne se connecte à aucun projet ni n'accepte aucun identifiant Firebase.`);
    } else {
      throw new guard.BackfillGuardError(`Argument inconnu : ${arg}`);
    }
  }
  return out;
}

function loadFixture(sourcePath) {
  guard.assertFixtureSource(sourcePath);
  const abs = path.resolve(sourcePath);
  if (!fs.existsSync(abs)) {
    throw new guard.BackfillGuardError(`Fixture introuvable : ${abs}`);
  }
  const raw = JSON.parse(fs.readFileSync(abs, 'utf8'));
  if (!Array.isArray(raw)) {
    throw new guard.BackfillGuardError('La fixture doit être un tableau [{ id, data }, ...].');
  }
  for (const entry of raw) {
    if (entry && typeof entry.id === 'string') guard.assertNoForbiddenProjectId(entry.id);
  }
  return raw;
}

function summarize(results) {
  const summary = {
    total: results.length,
    documentsAvecErreurDeType: results.filter((r) => !r.ok).length,
    champsInclusParDocument: {},
    raisonsExclusion: {},
    avertissements: {},
    positionPlaceholderIgnoree: 0,
  };
  for (const r of results) {
    for (const f of Object.keys(r.included)) {
      summary.champsInclusParDocument[f] = (summary.champsInclusParDocument[f] || 0) + 1;
    }
    for (const e of r.excluded) {
      const key = `${e.field}:${e.reason}`;
      summary.raisonsExclusion[key] = (summary.raisonsExclusion[key] || 0) + 1;
    }
    for (const w of r.warnings) {
      summary.avertissements[w] = (summary.avertissements[w] || 0) + 1;
    }
    if (r.warnings.some((w) => w.startsWith('lat/lng = 0,0'))) {
      summary.positionPlaceholderIgnoree += 1;
    }
  }
  return summary;
}

function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  guard.assertNoRealFirebaseEnvironment(env);
  guard.assertDryRun('dry-run'); // valeur fixe : aucun chemin de code ne peut produire autre chose
  const args = parseArgs(argv);
  guard.assertNoCredentialsProvided(args);
  const fixtures = loadFixture(args.source);

  const results = fixtures.map((entry) => mapDriverToPublic(entry.id, entry.data));
  const summary = summarize(results);

  log(JSON.stringify({ mode: 'dry-run', ...summary }, null, 2));
  log(`${results.length} fiche(s) analysée(s) depuis la fixture locale — 0 écriture effectuée (dry-run uniquement, aucune connexion Firebase).`);
  return 0;
}

if (require.main === module) {
  try {
    process.exit(main());
  } catch (err) {
    console.error(`${err.name || 'ERREUR'} : ${err.message}`);
    process.exit(1);
  }
}

module.exports = { main, loadFixture, summarize, parseArgs };
