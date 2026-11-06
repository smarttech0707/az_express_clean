#!/usr/bin/env node
'use strict';

// Extension du lot de test : compte « intrus » t7e-intrus (Mission 7E-43). Un client fictif, JAMAIS dans pilotClientIds, qui sert à
// prouver en conditions réelles que le serveur refuse un client non autorisé (CLIENT_NOT_IN_PILOT) une fois le pilote ouvert.
//
//   DRY-RUN (défaut, aucun accès réseau) :
//     node scripts/restaurant-v2-pilot/intruder.js --project az-express-preprod --project-number 306761725053 --dir <dossier du lot hors dépôt>
//   Collisions en lecture seule : ajouter --check-collisions
//   Création (autorisée SEULEMENT par une mission) : --execute --confirm "ADD-INTRUDER t7e-lot-1 az-express-preprod 306761725053"
//
// Écrit exactement : 1 compte Auth, 1 document clients/t7e-intrus, manifest.base.json (copie de référence, jamais écrasée),
// credentials.intruder.json (mot de passe, hors dépôt, jamais écrasé), manifest.json étendu (version 2, extensions[]).
// Ne touche ni aux quatre comptes existants, ni aux sept documents, ni à config/partnerOrdersV2 ; aucune suppression, même en cas
// d'échec partiel (le manifeste étendu liste alors exactement ce qui a été créé).

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const lot = require('./lot');
const guard = require('./guard');
const prepare = require('./prepare');

const { LOT_ID, LOT_FIELD, TARGET } = lot;
const EXTENSION_ID = 'intruder';
const INTRUDER = Object.freeze({ role: 'intruder', uid: 't7e-intrus', email: `t7e-intrus@${lot.EMAIL_DOMAIN}`, displayName: 'Intrus Test T7E (non autorisé)' });
const OTHER_ROLE_COLLECTIONS = Object.freeze(['livreurs', 'restaurants', 'admins', 'restaurant_owners', 'sellers', 'boulangeries', 'pharmacies', 'ekbine_agents']);

const isNotFound = (err) => err && (err.code === 'auth/user-not-found' || err.errorInfo?.code === 'auth/user-not-found');

// Schéma réel d'un client (partnerOrderQuote.js : assertActiveClient lit l'existence et deletionRequested/isDeleted ; règles
// Firestore : name, email, wallet autorisés). Wallet à 0 : l'intrus ne doit jamais pouvoir payer. Aucun téléphone, aucun jeton FCM.
function buildIntruderPlan() {
  return [{
    path: `clients/${INTRUDER.uid}`,
    kind: 'client_intruder',
    data: { name: INTRUDER.displayName, email: INTRUDER.email, wallet: 0, [LOT_FIELD]: LOT_ID },
  }];
}

// Le manifeste de base doit être exactement celui des quatre comptes et sept documents créés en 7E-37.
function assertBaseManifest(manifest) {
  const bad = (why) => { throw new guard.GuardError('MANIFEST_INVALID', `Manifeste de base refusé : ${why}`); };
  if (!manifest || manifest.lot !== LOT_ID) bad('lot inconnu');
  if (!manifest.project || manifest.project.id !== TARGET.projectId || manifest.project.number !== TARGET.projectNumber) bad('projet inattendu');
  if (manifest.status !== 'complete') bad('lot de base incomplet');
  if ((manifest.extensions || []).length) bad('déjà étendu');
  for (const i of Object.values(lot.IDENTITIES)) {
    const m = manifest.identities && manifest.identities[i.role];
    if (!m || m.uid !== i.uid || m.email !== i.email) bad(`identité ${i.role} inattendue`);
  }
  const expected = lot.buildSeedPlan().map((d) => d.path).sort();
  const actual = (manifest.documents || []).map((d) => d.path).sort();
  if (JSON.stringify(expected) !== JSON.stringify(actual)) bad('inventaire des documents différent du plan (7 documents attendus)');
  if (JSON.stringify([...manifest.authUids].sort()) !== JSON.stringify([...lot.UIDS].sort())) bad('inventaire des comptes différent du plan (4 comptes attendus)');
  if (!manifest.baseline || !Array.isArray(manifest.baseline.orderIds)) bad('instantané de référence absent');
  return manifest;
}

// Lecture seule. Tout ce qui existe déjà à l'emplacement de l'intrus est une collision ; l'intrus ne doit avoir aucun autre rôle ni
// figurer dans la liste blanche du pilote.
async function checkIntruderCollisions({ db, auth, plan = buildIntruderPlan() }) {
  const collisions = [];
  for (const doc of plan) if ((await db.doc(doc.path).get()).exists) collisions.push({ type: 'firestore', id: doc.path, reason: 'document déjà présent' });
  for (const col of OTHER_ROLE_COLLECTIONS) {
    if ((await db.doc(`${col}/${INTRUDER.uid}`).get()).exists) collisions.push({ type: 'firestore', id: `${col}/${INTRUDER.uid}`, reason: 'rôle supplémentaire interdit' });
  }
  const pilot = await db.doc('config/partnerOrdersV2').get();
  if (pilot.exists && Array.isArray(pilot.data().pilotClientIds) && pilot.data().pilotClientIds.includes(INTRUDER.uid)) {
    collisions.push({ type: 'firestore', id: 'config/partnerOrdersV2', reason: 'l’intrus figure dans pilotClientIds' });
  }
  for (const [by, lookup] of [['uid', () => auth.getUser(INTRUDER.uid)], ['e-mail', () => auth.getUserByEmail(INTRUDER.email)]]) {
    try { await lookup(); collisions.push({ type: 'auth', id: INTRUDER.uid, reason: `compte déjà présent (${by})` }); } catch (err) { if (!isNotFound(err)) throw err; }
  }
  return collisions;
}

async function writeNew(fsApi, file, content) {
  await fsApi.promises.writeFile(file, content, { flag: 'wx', mode: 0o600 }); // 'wx' : jamais d'écrasement
}

async function executeIntruder({
  admin, db, auth, dir, fsApi = fs, nowMs = Date.now(), makePassword = () => crypto.randomBytes(18).toString('base64url'),
}) {
  const folder = guard.assertOutDirOutsideRepo(dir);
  const plan = buildIntruderPlan();
  const sensitive = lot.findSensitiveKeys(plan);
  if (sensitive.length) throw new guard.GuardError('SENSITIVE_FIELD', `Champs sensibles interdits : ${sensitive.join(', ')}`);

  const manifestFile = path.join(folder, 'manifest.json');
  const baseText = await fsApi.promises.readFile(manifestFile, 'utf8');
  const base = assertBaseManifest(JSON.parse(baseText));

  // Le lot de base doit être intact avant d'y ajouter quoi que ce soit.
  for (const doc of lot.buildSeedPlan()) {
    if (!(await db.doc(doc.path).get()).exists) throw new guard.GuardError('BASE_LOT_BROKEN', `Document du lot absent : ${doc.path}`);
  }
  for (const uid of lot.UIDS) {
    try { await auth.getUser(uid); } catch (err) { if (isNotFound(err)) throw new guard.GuardError('BASE_LOT_BROKEN', `Compte du lot absent : ${uid}`); throw err; }
  }
  const collisions = await checkIntruderCollisions({ db, auth, plan });
  if (collisions.length) {
    const e = new guard.GuardError('COLLISION', `Collisions détectées, aucune écriture : ${collisions.map((c) => c.id).join(', ')}`);
    e.collisions = collisions;
    throw e;
  }

  // Tout ce qui peut échouer localement passe AVANT la première écriture cloud : copie de référence, puis identifiants.
  await writeNew(fsApi, path.join(folder, 'manifest.base.json'), baseText);
  const password = makePassword();
  await writeNew(fsApi, path.join(folder, 'credentials.intruder.json'), JSON.stringify({ intruder: { uid: INTRUDER.uid, email: INTRUDER.email, password } }, null, 2));

  const extension = {
    id: EXTENSION_ID, createdAtMs: nowMs, status: 'partial', identities: { intruder: { uid: INTRUDER.uid, email: INTRUDER.email } }, authUids: [], documents: [],
  };
  try {
    const record = await auth.createUser({ uid: INTRUDER.uid, email: INTRUDER.email, emailVerified: false, password, displayName: INTRUDER.displayName });
    if (record.uid !== INTRUDER.uid) throw new Error('UID inattendu : Auth a renvoyé un autre identifiant');
    extension.authUids.push(record.uid);
    const batch = db.batch();
    for (const doc of plan) batch.create(db.doc(doc.path), prepare.toData(admin, doc.data));
    await batch.commit();
    extension.documents = plan.map((d) => ({ path: d.path, kind: d.kind, hash: lot.docHash(d.data) }));
    extension.status = 'complete';
  } finally {
    // Même en cas d'échec : le manifeste liste exactement ce qui a été créé (aucune suppression automatique). Remplacement atomique.
    const next = { ...base, version: 2, extensions: [extension] };
    const tmp = `${manifestFile}.tmp`;
    await fsApi.promises.writeFile(tmp, JSON.stringify(next, null, 2), { flag: 'wx', mode: 0o600 });
    await fsApi.promises.rename(tmp, manifestFile);
  }
  return extension;
}

function dryRun() {
  const plan = buildIntruderPlan();
  return {
    mode: 'dry-run', writes: 0, sensitiveKeys: lot.findSensitiveKeys(plan),
    auth: { uid: INTRUDER.uid, email: INTRUDER.email, provider: 'password', phone: null, customClaims: null },
    documents: plan.map((d) => ({ path: d.path, data: d.data })),
    files: ['manifest.base.json (copie de référence)', 'credentials.intruder.json (hors dépôt)', 'manifest.json (version 2, extensions[])'],
    untouched: ['4 comptes et 7 documents du lot', 'config/partnerOrdersV2', 'commandes historiques', 'jetons FCM'],
  };
}

function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : null;
    if (['execute', 'check-collisions'].includes(key)) out.flags.add(key);
    else if (['project', 'project-number', 'dir', 'confirm'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; }
    else throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${argv[i]}`);
  }
  return out;
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  const execute = args.flags.has('execute');
  log(JSON.stringify(dryRun(), null, 2));
  if (!execute && !args.flags.has('check-collisions')) { log('DRY-RUN : aucune connexion, aucune écriture.'); return 0; }
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Les accès cloud sont réservés à az-express-preprod');
  const dir = guard.assertOutDirOutsideRepo(args.values.dir); // contrôlé AVANT toute connexion
  if (execute) guard.assertConfirmation(args.values.confirm, 'ADD-INTRUDER');

  const admin = prepare.connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => prepare.onlineFetchJson(admin, url) });
  const db = admin.firestore(); const auth = admin.auth();
  if (!execute) {
    const collisions = await checkIntruderCollisions({ db, auth });
    log(JSON.stringify({ mode: 'check-collisions', writes: 0, collisions }, null, 2));
    return collisions.length ? 2 : 0;
  }
  const ext = await executeIntruder({ admin, db, auth, dir });
  log(JSON.stringify({ mode: 'execute', status: ext.status, authUids: ext.authUids, documents: ext.documents.map((d) => d.path) }, null, 2));
  return 0;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${err.message}`);
    process.exit(1);
  });
}

module.exports = {
  INTRUDER, EXTENSION_ID, OTHER_ROLE_COLLECTIONS, buildIntruderPlan, assertBaseManifest, checkIntruderCollisions, executeIntruder, dryRun, parseArgs, main,
};
