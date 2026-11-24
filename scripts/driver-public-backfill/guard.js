'use strict';

// Garde-fous absolus pour la préparation du backfill `driver_public` (SEC-01, phase S3).
//
// Ce script ne doit JAMAIS pouvoir toucher un Firebase réel à ce stade. La garantie la plus
// forte possible n'est pas un indicateur `--dry-run` qu'on pourrait retirer un jour par erreur :
// c'est l'ABSENCE TOTALE de code de connexion Firestore/Admin SDK dans ce dossier. La seule
// source de données acceptée est un fichier fixture JSON local. Connecter une vraie lecture
// Firestore (même en lecture seule, même sur préproduction) est explicitement reporté à une
// phase ultérieure (S4), qui devra être autorisée séparément et ajoutera son propre mécanisme
// de garde — ce n'est pas un détail à contourner ici.

class BackfillGuardError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BackfillGuardError';
  }
}

// Présence de l'une de ces variables = signe que l'environnement pourrait atteindre un projet
// Firebase réel. Ce script n'en a besoin d'aucune pour fonctionner (il ne lit qu'un fichier
// local) : leur présence est donc toujours un signal à refuser, jamais à ignorer.
const FORBIDDEN_ENV_VARS = Object.freeze([
  'GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_CONFIG', 'GCLOUD_PROJECT',
  'FIRESTORE_EMULATOR_HOST', 'FIREBASE_PROJECT_ID', 'FIREBASE_TOKEN',
]);

// Identifiants de projet jamais autorisés, même mentionnés dans un argument ou une fixture, par
// précaution si une phase future réutilisait ce module sans retirer cette liste.
const FORBIDDEN_PROJECT_IDS = Object.freeze(['az-express-b0469', 'az-express-clean', 'az-express-preprod']);

function assertNoRealFirebaseEnvironment(env = process.env) {
  for (const key of FORBIDDEN_ENV_VARS) {
    if (env[key]) {
      throw new BackfillGuardError(
        `Variable d'environnement ${key} détectée. Ce script ne doit jamais s'exécuter dans un `
        + 'environnement pouvant atteindre un projet Firebase réel, même par accident — '
        + 'aucune valeur de cette variable n\'est jamais légitime ici.');
    }
  }
}

function assertFixtureSource(sourcePath) {
  if (typeof sourcePath !== 'string' || sourcePath.trim().length === 0) {
    throw new BackfillGuardError('Un chemin de fixture locale est obligatoire (--source <fichier.json>).');
  }
  if (/^(gs:|https?:|firestore:|projects\/)/i.test(sourcePath)) {
    throw new BackfillGuardError(
      `Source distante refusée (« ${sourcePath} ») : seul un fichier JSON local est accepté à ce stade.`);
  }
}

function assertNoForbiddenProjectId(value) {
  if (typeof value !== 'string') return;
  if (FORBIDDEN_PROJECT_IDS.includes(value)) {
    throw new BackfillGuardError(
      `Identifiant de projet « ${value} » explicitement interdit (production ou préproduction). `
      + 'Ce script ne cible aucun projet Firebase, quel qu\'il soit, à ce stade.');
  }
}

// Volontairement : il n'existe aucune fonction `assertRealExecutionAllowed()` qui renverrait
// `true` dans un cas quelconque. Tant qu'elle n'existe pas, aucun appelant ne peut légitimement
// sortir du dry-run — ajouter ce mécanisme sera, en soi, la décision d'autoriser une phase
// d'écriture, pas une case à cocher dans celui-ci.
function assertDryRun(mode) {
  if (mode !== 'dry-run') {
    throw new BackfillGuardError(
      `Mode « ${mode} » refusé : seul le dry-run est implémenté à ce stade (S3). `
      + 'Ce n\'est pas une option à retirer : aucun code d\'écriture n\'existe dans ce module.');
  }
}

function assertNoCredentialsProvided(options = {}) {
  const suspicious = ['credentials', 'credential', 'serviceAccount', 'keyFile', 'adc', 'token'];
  const present = suspicious.filter((k) => k in options);
  if (present.length) {
    throw new BackfillGuardError(
      `Option(s) de credentials refusée(s) : ${present.join(', ')}. `
      + 'Ce script ne charge et n\'accepte jamais d\'identifiants Firebase.');
  }
}

module.exports = {
  BackfillGuardError,
  FORBIDDEN_ENV_VARS,
  FORBIDDEN_PROJECT_IDS,
  assertNoRealFirebaseEnvironment,
  assertFixtureSource,
  assertNoForbiddenProjectId,
  assertDryRun,
  assertNoCredentialsProvided,
};
