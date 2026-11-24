'use strict';

// Outil isolé : réinitialise UNIQUEMENT le mot de passe Auth d'un sous-ensemble fixe de
// comptes de test sur le projet de préproduction. N'appelle jamais seed-test-data.js et ne
// touche jamais Firestore. Dry-run par défaut (aucun appel Firebase tant que --execute
// n'est pas passé explicitement).
//
// Usage (dry-run, sans danger) :
//   node test-env/reset-test-passwords.js --project az-express-preprod --confirm-project az-express-preprod --email client.test@az-test.invalid --email livreur.a@az-test.invalid
// Usage réel (hors périmètre tant que non autorisé explicitement) :
//   $env:AZ_TEST_PASSWORD = "<12+ caractères>"
//   node test-env/reset-test-passwords.js --project az-express-preprod --confirm-project az-express-preprod --email client.test@az-test.invalid --email livreur.a@az-test.invalid --execute

const g = require('./lib/guards');

// Liste blanche fermée : aucun autre email n'est accepté, quel que soit l'argument fourni.
const ALLOWED_PROJECT = g.PREPROD.projectId; // 'az-express-preprod'
const ALLOWED_EMAILS = Object.freeze([
  'client.test@az-test.invalid',
  'livreur.a@az-test.invalid',
]);
const MIN_PASSWORD_LENGTH = 12;

function parseArgs(argv) {
  const emails = [];
  let project;
  let confirmProject;
  let execute = false;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--project') project = argv[++i];
    else if (a === '--confirm-project') confirmProject = argv[++i];
    else if (a === '--email') emails.push(argv[++i]);
    else if (a === '--execute') execute = true;
    else throw new Error(`Argument inconnu : ${a}`);
  }
  return { project, confirmProject, emails, execute };
}

// Validation pure, sans aucun appel réseau : lève une erreur au moindre écart.
function validateRequest({ project, confirmProject, emails, env = {} }) {
  if (!project) throw new Error('--project requis.');
  if (g.isProductionProject(project)) throw new Error(`Refus : « ${project} » est le projet de PRODUCTION.`);
  if (project !== ALLOWED_PROJECT) throw new Error(`Refus : seul « ${ALLOWED_PROJECT} » est autorisé par cet outil (reçu « ${project} »).`);
  if (confirmProject !== project) throw new Error('--confirm-project doit répéter exactement --project.');
  g.assertNoProductionEnv(env);

  if (!Array.isArray(emails) || emails.length === 0) throw new Error('Au moins un --email requis.');
  const unique = [...new Set(emails)];
  const unauthorized = unique.filter((e) => !ALLOWED_EMAILS.includes(e));
  if (unauthorized.length > 0) {
    throw new Error(`Refus : adresse(s) non autorisée(s) par cet outil : ${unauthorized.join(', ')}. Seules ${ALLOWED_EMAILS.join(' et ')} sont acceptées.`);
  }
  return { project, emails: unique };
}

function buildPlan({ project, emails }) {
  return {
    project,
    emails: [...emails],
    operation: 'Mise à jour du mot de passe Firebase Auth uniquement (aucune création de compte, aucun autre champ modifié).',
    firestore: 'Aucune opération Firestore dans cet outil.',
  };
}

function printPlan(plan, { dryRun }) {
  console.log('--- Plan de réinitialisation (mot de passe Auth uniquement) ---');
  console.log(`Projet cible : ${plan.project}`);
  console.log('Comptes ciblés :');
  for (const email of plan.emails) console.log(`  - ${email}`);
  console.log(`Opération prévue : ${plan.operation}`);
  console.log(plan.firestore);
  if (dryRun) {
    console.log('DRY-RUN : aucune modification Auth ou Firestore ne sera effectuée.');
  }
}

// N'appelle le SDK qu'ici, jamais pendant la validation/dry-run. `getAuth` est injectable
// pour les tests (aucun mock de firebase-admin requis).
async function resetPasswords({ project, emails, password, getAuth }) {
  if (!password || password.length < MIN_PASSWORD_LENGTH) {
    throw new Error(`Mot de passe requis (${MIN_PASSWORD_LENGTH} caractères minimum), jamais écrit dans un fichier ou un log.`);
  }
  const auth = getAuth();
  const results = [];
  for (const email of emails) {
    // Ne crée jamais de compte : si l'utilisateur n'existe pas, on échoue plutôt que de le créer.
    const user = await auth.getUserByEmail(email);
    await auth.updateUser(user.uid, { password });
    results.push({ email, uid: user.uid });
  }
  return results;
}

async function main(argv = process.argv.slice(2), env = process.env) {
  const { project, confirmProject, emails, execute } = parseArgs(argv);
  const { project: validProject, emails: validEmails } = validateRequest({ project, confirmProject, emails, env });
  const plan = buildPlan({ project: validProject, emails: validEmails });
  printPlan(plan, { dryRun: !execute });

  if (!execute) {
    return { executed: false, plan };
  }

  const password = env.AZ_TEST_PASSWORD || '';
  const adminSdk = require('firebase-admin');
  if (!adminSdk.apps.length) adminSdk.initializeApp({ projectId: validProject });
  const results = await resetPasswords({
    project: validProject,
    emails: validEmails,
    password,
    getAuth: () => adminSdk.auth(),
  });
  console.log(`Mot de passe mis à jour pour ${results.length} compte(s) (valeur jamais affichée).`);
  return { executed: true, plan, results };
}

module.exports = {
  ALLOWED_PROJECT, ALLOWED_EMAILS, MIN_PASSWORD_LENGTH,
  parseArgs, validateRequest, buildPlan, printPlan, resetPasswords, main,
};

if (require.main === module) {
  main().catch((e) => { console.error(`ERREUR : ${e.message}`); process.exitCode = 1; });
}
