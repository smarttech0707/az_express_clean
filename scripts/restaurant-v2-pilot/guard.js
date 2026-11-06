'use strict';

// Garde-fous communs à prepare.js et cleanup.js (Mission 7E-36). Tout est refusé par défaut : une seule cible est acceptée
// (az-express-preprod / 306761725053) ou l'émulateur local (projet demo-*). La production n'est jamais atteignable.

const path = require('node:path');
const { TARGET, FORBIDDEN_PROJECT_IDS, LOT_ID } = require('./lot');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

class GuardError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// Variables d'environnement qui désignent un projet : aucune ne doit contredire la cible demandée.
const PROJECT_ENV = ['GCLOUD_PROJECT', 'GOOGLE_CLOUD_PROJECT', 'CLOUDSDK_CORE_PROJECT', 'FIREBASE_PROJECT'];

function envProjects(env) {
  const found = PROJECT_ENV.map((k) => env[k]).filter(Boolean);
  if (env.FIREBASE_CONFIG) {
    try { const id = JSON.parse(env.FIREBASE_CONFIG).projectId; if (id) found.push(id); } catch (_) { /* ignoré */ }
  }
  return found;
}

// Retourne { mode: 'preprod' | 'emulator', projectId }. Lève GuardError pour tout le reste.
function assertTarget({ projectId, projectNumber, env = process.env } = {}) {
  if (typeof projectId !== 'string' || !projectId) throw new GuardError('PROJECT_REQUIRED', 'Projet explicite requis (--project)');
  const all = [projectId, ...envProjects(env)];
  const prod = all.find((p) => FORBIDDEN_PROJECT_IDS.includes(p));
  if (prod) throw new GuardError('PRODUCTION_FORBIDDEN', `Le projet de production (${prod}) est interdit`);

  if (/^demo-/.test(projectId)) {
    if (!env.FIRESTORE_EMULATOR_HOST) throw new GuardError('EMULATOR_REQUIRED', 'Un projet demo-* exige l’émulateur Firestore');
    if (env.GCLOUD_PROJECT && env.GCLOUD_PROJECT !== projectId) throw new GuardError('ENV_MISMATCH', 'GCLOUD_PROJECT contredit le projet demandé');
    return { mode: 'emulator', projectId };
  }
  if (projectId !== TARGET.projectId) throw new GuardError('PROJECT_NOT_ALLOWED', `Seul ${TARGET.projectId} est autorisé`);
  if (projectNumber !== TARGET.projectNumber) throw new GuardError('PROJECT_NUMBER_MISMATCH', `Numéro de projet attendu : ${TARGET.projectNumber}`);
  if (env.FIRESTORE_EMULATOR_HOST || env.FIREBASE_AUTH_EMULATOR_HOST) {
    throw new GuardError('EMULATOR_ENV_WITH_REAL_PROJECT', 'Variables d’émulateur présentes avec un projet réel : refus');
  }
  const other = envProjects(env).find((p) => p !== projectId);
  if (other) throw new GuardError('ENV_MISMATCH', `Une variable d’environnement désigne un autre projet (${other})`);
  return { mode: 'preprod', projectId };
}

// Vérifie en LECTURE SEULE que l'identifiant désigne bien le numéro attendu (Resource Manager v3). fetchJson est injecté.
async function verifyProjectNumberOnline({ projectId, fetchJson }) {
  const body = await fetchJson(`https://cloudresourcemanager.googleapis.com/v3/projects/${encodeURIComponent(projectId)}`);
  const number = String(body && body.name || '').replace(/^projects\//, '');
  if (number !== TARGET.projectNumber) {
    throw new GuardError('PROJECT_NUMBER_MISMATCH', `Le projet ${projectId} porte le numéro ${number || 'inconnu'}, attendu ${TARGET.projectNumber}`);
  }
  return number;
}

// Les identifiants générés (mots de passe) ne doivent jamais se retrouver dans le dépôt Git.
function assertOutDirOutsideRepo(outDir) {
  if (typeof outDir !== 'string' || !outDir) throw new GuardError('OUT_DIR_REQUIRED', 'Dossier de sortie requis (--out)');
  const resolved = path.resolve(outDir);
  const rel = path.relative(REPO_ROOT, resolved);
  if (!rel || (!rel.startsWith('..') && !path.isAbsolute(rel))) {
    throw new GuardError('OUT_DIR_IN_REPO', 'Le dossier de sortie doit être hors du dépôt (identifiants générés)');
  }
  return resolved;
}

const confirmationFor = (verb, target = TARGET) => `${verb} ${LOT_ID} ${target.projectId} ${target.projectNumber}`;

function assertConfirmation(given, verb) {
  const expected = confirmationFor(verb);
  if (given !== expected) throw new GuardError('CONFIRMATION_REQUIRED', `Confirmation exacte requise : "${expected}"`);
}

module.exports = {
  GuardError, assertTarget, verifyProjectNumberOnline, assertOutDirOutsideRepo, assertConfirmation, confirmationFor, REPO_ROOT,
};
