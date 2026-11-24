'use strict';

// Saisie contrôlée de `config/app_release_registry` (dernier build publié VÉRIFIÉ par plateforme) — Mission M2.3.
// Ce registre conditionne setAppVersionsConfigCF : sans entrée vérifiée, aucun minBuild ne peut être défini ni relevé.
// Procédure, droits et preuves : docs/APP_RELEASE_REGISTRY_PROCEDURE.md.
//
// Usage (depuis functions/) :
//   Simulation (défaut, AUCUN accès réseau, rien n'est écrit) :
//     node scripts/appReleaseRegistry.js --project az-express-b0469 --platform android --build 11 \
//       --source google-play-console --detail "piste production, état Disponible, versionCode" \
//       --verified-at 2026-11-12T09:30:00+00:00 --evidence "capture-play-2026-11-12.png" --operator "prénom.nom" \
//       [--second-verifier "autre.personne"]
//   Écriture : mêmes arguments + --apply --confirm <projet>:<plateforme>:<build>
//     - projet réel (az-express-b0469) : identifiants Admin SDK par défaut de l'opérateur, FIRESTORE_EMULATOR_HOST absent ;
//     - projet démo (demo-*, émulateur uniquement) : FIRESTORE_EMULATOR_HOST obligatoire, jamais d'accès réel.
// Politique des sources (M2.4) : Android = Google Play uniquement (`--source google-play-console`), iOS = Apple App Store
// uniquement (`--source app-store-connect`). APK direct, TestFlight, distribution interne ou toute autre valeur : refusés.
// L'outil ne déduit, ne devine et n'arrondit jamais un numéro de build, et n'écrit jamais `enforce`.

const REGISTRY_PATH = ['config', 'app_release_registry'];
const REAL_PROJECTS = Object.freeze(['az-express-b0469']);
const PLATFORMS = Object.freeze(['android', 'ios']);
// Sources officielles acceptées par plateforme. Valeur fermée (pas de texte libre) : une comparaison de texte libre laisserait
// passer « APK direct » déguisé. Le texte libre va dans `--detail` (piste, état, version), sans effet sur l'autorisation.
const OFFICIAL_SOURCES = Object.freeze({ android: 'google-play-console', ios: 'app-store-connect' });
const MAX_BUILD = 2100000000;
const MAX_AGE_DAYS = 30;
const FUTURE_TOLERANCE_MS = 5 * 60 * 1000;
const TOOL_ID = 'tool:appReleaseRegistry';

class ToolError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const isDemoProject = (id) => typeof id === 'string' && /^demo-[a-z0-9-]+$/.test(id);

function parseArgs(argv) {
  const out = { apply: false };
  const valued = { '--project': 'project', '--platform': 'platform', '--build': 'build', '--source': 'source', '--detail': 'detail', '--second-verifier': 'secondVerifier',
    '--verified-at': 'verifiedAt', '--evidence': 'evidence', '--operator': 'operator', '--confirm': 'confirm' };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') { out.apply = true; continue; }
    const key = valued[arg];
    if (!key) throw new ToolError('UNKNOWN_ARGUMENT', `Argument inconnu : ${arg}`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) throw new ToolError('MISSING_VALUE', `Valeur manquante pour ${arg}`);
    if (out[key] !== undefined) throw new ToolError('DUPLICATE_ARGUMENT', `Argument répété : ${arg}`);
    out[key] = value;
    i += 1;
  }
  return out;
}

/** Valide les arguments ; retourne l'entrée normalisée. Aucune valeur par défaut : tout champ manquant est refusé. */
function validateInput(args, now = new Date()) {
  const need = (name, label) => {
    if (typeof args[name] !== 'string' || args[name].trim() === '') throw new ToolError('MISSING_FIELD', `${label} est obligatoire.`);
    return args[name].trim();
  };
  const project = need('project', '--project');
  if (!REAL_PROJECTS.includes(project) && !isDemoProject(project)) {
    throw new ToolError('UNKNOWN_PROJECT', `Projet non reconnu : ${project} (autorisés : ${REAL_PROJECTS.join(', ')}, demo-*).`);
  }
  const platform = need('platform', '--platform');
  if (!PLATFORMS.includes(platform)) throw new ToolError('INVALID_PLATFORM', 'Plateforme : android ou ios.');
  const rawBuild = need('build', '--build');
  if (!/^[1-9][0-9]{0,9}$/.test(rawBuild) || Number(rawBuild) > MAX_BUILD) {
    throw new ToolError('INVALID_BUILD', `--build : entier de 1 à ${MAX_BUILD}, sans signe, décimale ni zéro initial.`);
  }
  const source = need('source', '--source');
  if (source !== OFFICIAL_SOURCES[platform]) {
    throw new ToolError('UNAUTHORIZED_SOURCE',
      `--source "${source}" refusée pour ${platform} : seule la source officielle "${OFFICIAL_SOURCES[platform]}" est acceptée `
      + '(APK direct, TestFlight, distribution interne et autres canaux sont exclus du registre).');
  }
  const detail = need('detail', '--detail');
  if (detail.length < 10 || detail.length > 200) throw new ToolError('INVALID_DETAIL', '--detail : 10 à 200 caractères (piste, état, version).');
  const evidence = need('evidence', '--evidence');
  if (evidence.length > 200) throw new ToolError('INVALID_EVIDENCE', '--evidence : 200 caractères au plus.');
  const operator = need('operator', '--operator');
  if (operator.length > 100) throw new ToolError('INVALID_OPERATOR', '--operator : 100 caractères au plus.');
  // Seconde vérification : recommandée, jamais simulée. Si fournie, elle doit venir d'une AUTRE personne que l'opérateur.
  let secondVerifier = null;
  if (args.secondVerifier !== undefined) {
    secondVerifier = need('secondVerifier', '--second-verifier');
    if (secondVerifier.length > 100) throw new ToolError('INVALID_VERIFIER', '--second-verifier : 100 caractères au plus.');
    if (secondVerifier.toLowerCase() === operator.toLowerCase()) {
      throw new ToolError('SAME_VERIFIER', '--second-verifier doit être une autre personne que --operator.');
    }
  }

  const rawDate = need('verifiedAt', '--verified-at');
  // Fuseau horaire obligatoire : une date sans fuseau serait interprétée selon la machine de l'opérateur.
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(rawDate) || Number.isNaN(Date.parse(rawDate))) {
    throw new ToolError('INVALID_VERIFIED_AT', '--verified-at : date ISO 8601 avec fuseau (ex. 2026-11-12T09:30:00+00:00).');
  }
  const verifiedAt = new Date(rawDate);
  if (verifiedAt.getTime() > now.getTime() + FUTURE_TOLERANCE_MS) throw new ToolError('VERIFIED_AT_IN_FUTURE', '--verified-at est dans le futur.');
  if (now.getTime() - verifiedAt.getTime() > MAX_AGE_DAYS * 86400000) {
    throw new ToolError('VERIFIED_AT_STALE', `--verified-at date de plus de ${MAX_AGE_DAYS} jours : revérifier le store.`);
  }
  return { project, platform, latestBuild: Number(rawBuild), source, detail, verifiedAt, evidence, operator, secondVerifier };
}

const confirmationToken = (e) => `${e.project}:${e.platform}:${e.latestBuild}`;

/** Garde de cible : cohérence projet / émulateur. Appelée avant tout accès Firestore. */
function checkTarget(entry, env = process.env) {
  const emulator = env.FIRESTORE_EMULATOR_HOST;
  if (isDemoProject(entry.project)) {
    if (!emulator) throw new ToolError('EMULATOR_REQUIRED', 'Projet demo-* : FIRESTORE_EMULATOR_HOST obligatoire (aucun accès réel).');
  } else if (emulator) {
    throw new ToolError('TARGET_MISMATCH', `Projet réel ${entry.project} avec un émulateur actif : écriture refusée.`);
  }
}

/** Texte de simulation : décrit ce qui serait écrit, sans aucun accès réseau. */
function describePlan(entry) {
  return [
    `SIMULATION — aucune écriture (ajouter --apply --confirm ${confirmationToken(entry)} pour écrire).`,
    `Projet : ${entry.project}   Document : ${REGISTRY_PATH.join('/')}`,
    `${entry.platform}.latestBuild = ${entry.latestBuild}`,
    `${entry.platform}.source = ${entry.source}   (${entry.detail})`,
    `${entry.platform}.verifiedAt = ${entry.verifiedAt.toISOString()}`,
    `${entry.platform}.evidence = ${entry.evidence}   (opérateur : ${entry.operator})`,
    entry.secondVerifier
      ? `Seconde vérification déclarée : ${entry.secondVerifier}`
      : 'ATTENTION : aucune seconde vérification déclarée (--second-verifier recommandé).',
    'enforce : jamais écrit par cet outil.',
  ].join('\n');
}

/** Écriture transactionnelle + audit. `db` et `fieldValue` sont injectés (testables sans Firebase). */
async function applyUpdate({ db, fieldValue, Timestamp, entry, confirm }) {
  if (confirm !== confirmationToken(entry)) {
    throw new ToolError('CONFIRMATION_MISMATCH', `Confirmation attendue : --confirm ${confirmationToken(entry)}`);
  }
  const ref = db.collection(REGISTRY_PATH[0]).doc(REGISTRY_PATH[1]);
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const before = snap.exists ? snap.data()[entry.platform] || null : null;
    if (before && Number.isInteger(before.latestBuild) && entry.latestBuild < before.latestBuild) {
      throw new ToolError('BUILD_DECREASE', `Le registre indique déjà ${before.latestBuild} pour ${entry.platform} : une baisse est refusée.`);
    }
    tx.set(ref, {
      [entry.platform]: {
        latestBuild: entry.latestBuild, source: entry.source, sourceDetail: entry.detail, evidence: entry.evidence,
        secondVerifier: entry.secondVerifier, verifiedAt: Timestamp.fromDate(entry.verifiedAt), enteredBy: entry.operator,
      },
      updatedAt: fieldValue.serverTimestamp(), updatedBy: TOOL_ID,
    }, { merge: true });
    return { before };
  });
  const clean = (b) => (b ? { latestBuild: b.latestBuild ?? null, source: b.source ?? null } : null);
  await db.collection('audit_logs').add({
    userId: null, userType: 'operator', action: 'app_release_registry_update', targetId: entry.platform, amount: null,
    status: 'success', createdAt: fieldValue.serverTimestamp(),
    metadata: { project: entry.project, operator: entry.operator, secondVerifier: entry.secondVerifier, before: clean(result.before),
      after: { latestBuild: entry.latestBuild, source: entry.source, evidence: entry.evidence }, tool: TOOL_ID },
  });
  return result;
}

async function main(argv, env = process.env, log = console.log, now = new Date()) {
  const args = parseArgs(argv);
  const entry = validateInput(args, now);
  checkTarget(entry, env);
  if (!args.apply) { log(describePlan(entry)); return 'dry-run'; }
  if (!args.confirm) throw new ToolError('CONFIRMATION_REQUIRED', `--apply exige --confirm ${confirmationToken(entry)}`);
  if (args.confirm !== confirmationToken(entry)) {
    throw new ToolError('CONFIRMATION_MISMATCH', `Confirmation attendue : --confirm ${confirmationToken(entry)}`);
  }
  const admin = require('firebase-admin'); // chargé seulement ici : la simulation n'initialise jamais le SDK
  // Une app déjà initialisée dans ce processus n'est réutilisée que si elle vise exactement le projet demandé.
  const app = admin.apps.length ? admin.app() : admin.initializeApp({ projectId: entry.project });
  if (app.options.projectId !== entry.project) throw new ToolError('TARGET_MISMATCH', 'App Admin déjà initialisée sur un autre projet.');
  await applyUpdate({ db: admin.firestore(), fieldValue: admin.firestore.FieldValue, Timestamp: admin.firestore.Timestamp, entry, confirm: args.confirm });
  log(`OK — ${entry.platform}.latestBuild = ${entry.latestBuild} écrit dans ${REGISTRY_PATH.join('/')} (${entry.project}).`);
  return 'applied';
}

if (require.main === module) {
  main(process.argv.slice(2)).then(() => process.exit(0), (error) => {
    console.error(error instanceof ToolError ? `REFUSÉ [${error.code}] ${error.message}` : `ERREUR ${error.message}`);
    process.exit(error instanceof ToolError ? 2 : 1);
  });
}

module.exports = { OFFICIAL_SOURCES, parseArgs, validateInput, checkTarget, describePlan, applyUpdate, main, ToolError, confirmationToken, REAL_PROJECTS };
