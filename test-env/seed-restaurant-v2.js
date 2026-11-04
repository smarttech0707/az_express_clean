'use strict';

// Données fictives du pilote Restaurant v2 pour la PRÉPRODUCTION (restaurant, menu, client, livreur, super-admin, soldes de test).
// SIMULATION PAR DÉFAUT : sans --execute, le script affiche seulement ce qu'il écrirait (aucun module Firebase chargé, aucun réseau).
//
//   node test-env/seed-restaurant-v2.js --project az-express-preprod                          (simulation)
//   $env:AZ_TEST_PASSWORD="<12+ caractères>"   (jamais écrit dans un fichier)
//   node test-env/seed-restaurant-v2.js --project az-express-preprod --confirm-project az-express-preprod --execute   (RÉEL, après autorisation)
//   Émulateurs : --project demo-az-test --emulator --execute  (FIRESTORE_EMULATOR_HOST et FIREBASE_AUTH_EMULATOR_HOST requis)
//
// Refuse : production, projet qui n'est pas az-express-preprod (hors émulateur), variable d'environnement visant la production,
// absence de confirmation, données ressemblant à du réel. N'écrit JAMAIS config/partnerOrdersV2 : le pilote reste fermé.

const path = require('path');
const { createRequire } = require('module');
const g = require('./lib/guards');
const seed = require('./lib/restaurantV2Seed');

const PREPROD = 'az-express-preprod';

function parseArgs(argv) {
  const opt = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  return { project: opt('--project'), confirm: opt('--confirm-project'), emulator: argv.includes('--emulator'), execute: argv.includes('--execute') };
}

// Validation sans effet de bord (testée) : lève une erreur au moindre doute, retourne la configuration retenue.
function validate(args, env) {
  g.assertNoProductionEnv(env);
  const project = g.assertTestProject(args.project);
  if (!args.emulator && project !== PREPROD) throw new Error(`Refus : seul « ${PREPROD} » est autorisé hors émulateur (reçu « ${project} »).`);
  if (args.emulator) {
    if (!/^demo-/.test(project)) throw new Error('Mode --emulator : le projet doit commencer par « demo- ».');
    if (args.execute && (!env.FIRESTORE_EMULATOR_HOST || !env.FIREBASE_AUTH_EMULATOR_HOST)) {
      throw new Error('Mode --emulator : FIRESTORE_EMULATOR_HOST et FIREBASE_AUTH_EMULATOR_HOST requis.');
    }
  } else {
    if (env.FIRESTORE_EMULATOR_HOST) throw new Error('FIRESTORE_EMULATOR_HOST défini sans --emulator.');
    if (args.execute && args.confirm !== project) throw new Error('Projet réel : --confirm-project <même id> requis.');
  }
  return { project, emulator: !!args.emulator, execute: !!args.execute };
}

function describePlan(plan) {
  return plan.map((d) => ` - ${d.path}${d.keepIfExists.length ? `  (champs conservés s'ils existent : ${d.keepIfExists.join(', ')})` : ''}`);
}

async function run(cfg, env) {
  // Plan avec des uid factices pour la simulation : aucun compte n'est créé tant que --execute n'est pas fourni.
  const placeholder = { client: '<uid-client>', driver: '<uid-livreur>', admin: '<uid-admin>', restaurant: '<uid-restaurateur>' };
  const dry = seed.buildPlan(placeholder);
  const markers = seed.findRealDataMarkers(dry);
  if (markers.length) throw new Error(`Données refusées : ${markers.join(', ')}.`);
  if (dry.some((d) => d.path.startsWith('config/partnerOrdersV2'))) throw new Error('Le seed ne doit jamais écrire config/partnerOrdersV2.');

  if (!cfg.execute) {
    console.log(`SIMULATION (projet « ${cfg.project} ») : aucune écriture, aucun compte créé, aucun accès réseau.`);
    console.log('Comptes qui seraient assurés (e-mail fictif, mot de passe = AZ_TEST_PASSWORD) :');
    for (const [k, a] of Object.entries(seed.ACCOUNTS)) console.log(` - ${k.padEnd(10)} ${a.email}`);
    console.log('Documents (identifiants déterministes, écriture en fusion) :');
    for (const line of describePlan(dry)) console.log(line);
    console.log('config/partnerOrdersV2 : NON écrit (pilote fermé, aucun restaurant listé).');
    return;
  }

  const password = env.AZ_TEST_PASSWORD || '';
  const minLength = cfg.emulator ? 8 : 12;
  if (password.length < minLength) throw new Error(`AZ_TEST_PASSWORD (${minLength} caractères minimum) requis ; jamais écrit dans un fichier.`);
  const adminSdk = createRequire(path.join(__dirname, '..', 'functions', 'package.json'))('firebase-admin');
  adminSdk.initializeApp({ projectId: cfg.project });
  const auth = adminSdk.auth();
  const db = adminSdk.firestore();

  const uids = {};
  for (const [key, acc] of Object.entries(seed.ACCOUNTS)) {
    try {
      const u = await auth.getUserByEmail(acc.email);
      await auth.updateUser(u.uid, { password, emailVerified: true, displayName: acc.name });
      uids[key] = u.uid;
    } catch (e) {
      if (e.code !== 'auth/user-not-found') throw e;
      uids[key] = (await auth.createUser({ email: acc.email, password, emailVerified: true, displayName: acc.name })).uid;
    }
  }
  const plan = seed.buildPlan(uids);
  const stamp = adminSdk.firestore.FieldValue.serverTimestamp();
  for (const d of plan) {
    const ref = db.doc(d.path);
    const data = { ...d.data, createdAt: stamp };
    // Idempotence : un solde déjà présent n'est jamais réécrit (aucune recharge à la relance) et la date de création est conservée.
    const snap = await ref.get();
    if (snap.exists) {
      delete data.createdAt;
      for (const f of d.keepIfExists) if (snap.get(f) !== undefined) delete data[f];
    }
    await ref.set(data, { merge: true });
  }
  console.log(`Données fictives écrites dans « ${cfg.project} » (${plan.length} documents, aucun paiement réel, aucun SMS).`);
  console.log('Pilote : config/partnerOrdersV2 non écrit (création fermée, aucun restaurant listé).');
}

if (require.main === module) {
  try {
    const cfg = validate(parseArgs(process.argv.slice(2)), process.env);
    run(cfg, process.env).then(() => process.exit(0)).catch((e) => { console.error(`ERREUR : ${e.message}`); process.exit(1); });
  } catch (e) {
    console.error(`ERREUR : ${e.message}`);
    process.exit(1);
  }
}

module.exports = { parseArgs, validate, describePlan };
