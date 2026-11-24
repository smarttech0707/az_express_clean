#!/usr/bin/env node
'use strict';

// Préparation du lot de test Restaurant v2 (Mission 7E-36).
//
//   DRY-RUN (défaut, aucun accès réseau) :
//     node scripts/restaurant-v2-pilot/prepare.js --project az-express-preprod --project-number 306761725053
//   Collisions en lecture seule (identifiants Google par défaut requis) : ajouter --check-collisions
//   Création (mission autorisée SEULEMENT) : ajouter --execute --out <dossier hors dépôt> --confirm "CREATE t7e-lot-1 az-express-preprod 306761725053"
//
// Ce script ne crée JAMAIS config/partnerOrdersV2 (ouverture du pilote = autre étape, via partnerOrderActionCF), ne pose aucun
// jeton FCM, aucun téléphone, et ne touche à aucun document existant (create() échoue si le document existe).

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const lot = require('./lot');
const guard = require('./guard');

const { LOT_ID, IDENTITIES, TARGET } = lot;

const toData = (admin, data) => Object.fromEntries(Object.entries(data).map(([k, v]) => [
  k, v && v.__serverTimestamp ? admin.firestore.FieldValue.serverTimestamp() : v,
]));
const isNotFound = (err) => err && (err.code === 'auth/user-not-found' || err.errorInfo?.code === 'auth/user-not-found');
const generatePassword = () => crypto.randomBytes(18).toString('base64url');

// Lecture seule : tout ce qui existe déjà à l'emplacement d'une ressource du lot est une collision.
async function checkCollisions({ db, auth, plan }) {
  const collisions = [];
  for (const doc of plan) {
    if ((await db.doc(doc.path).get()).exists) collisions.push({ type: 'firestore', id: doc.path, reason: 'document déjà présent' });
  }
  if ((await db.doc('config/partnerOrdersV2').get()).exists) {
    collisions.push({ type: 'firestore', id: 'config/partnerOrdersV2', reason: 'configuration du pilote déjà présente (ne pas écraser)' });
  }
  for (const { uid, email } of Object.values(IDENTITIES)) {
    for (const [by, lookup] of [['uid', () => auth.getUser(uid)], ['e-mail', () => auth.getUserByEmail(email)]]) {
      try {
        await lookup();
        collisions.push({ type: 'auth', id: uid, reason: `compte déjà présent (${by})` });
      } catch (err) {
        if (!isNotFound(err)) throw err;
      }
    }
  }
  return collisions;
}

// Instantané de référence : les données historiques ne doivent jamais être touchées. Le nettoyage refuse tout document listé ici.
async function baselineSnapshot({ db }) {
  const orders = await db.collection('orders').select().get();
  const counts = {};
  for (const name of ['clients', 'livreurs', 'restaurants', 'admins']) {
    counts[name] = (await db.collection(name).count().get()).data().count;
  }
  return { orderIds: orders.docs.map((d) => d.id).sort(), counts };
}

async function writeNew(fsApi, file, content) {
  await fsApi.promises.writeFile(file, content, { flag: 'wx', mode: 0o600 }); // 'wx' : jamais d'écrasement
}

// Exécute le plan. Tout-ou-rien côté Firestore (lot unique de create()), comptes Auth créés avant avec uid explicite.
async function executePrepare({
  admin, db, auth, plan = lot.buildSeedPlan(), outDir, fsApi = fs, nowMs = Date.now(), makePassword = generatePassword,
}) {
  const dir = guard.assertOutDirOutsideRepo(outDir);
  const sensitive = lot.findSensitiveKeys(plan);
  if (sensitive.length) throw new guard.GuardError('SENSITIVE_FIELD', `Champs sensibles interdits : ${sensitive.join(', ')}`);

  const collisions = await checkCollisions({ db, auth, plan });
  if (collisions.length) {
    const e = new guard.GuardError('COLLISION', `Collisions détectées, aucune écriture : ${collisions.map((c) => c.id).join(', ')}`);
    e.collisions = collisions;
    throw e;
  }
  const baseline = await baselineSnapshot({ db });

  await fsApi.promises.mkdir(dir, { recursive: true });
  const passwords = Object.fromEntries(Object.values(IDENTITIES).map((i) => [i.role, makePassword()]));
  // Identifiants écrits AVANT la création des comptes : si l'écriture échoue, rien n'a été créé.
  await writeNew(fsApi, path.join(dir, 'credentials.json'), JSON.stringify(
    Object.fromEntries(Object.values(IDENTITIES).map((i) => [i.role, { uid: i.uid, email: i.email, password: passwords[i.role] }])), null, 2));

  const createdUids = [];
  const manifest = {
    version: 1, lot: LOT_ID, project: { id: TARGET.projectId, number: TARGET.projectNumber }, createdAtMs: nowMs, status: 'partial',
    identities: Object.fromEntries(Object.values(IDENTITIES).map((i) => [i.role, { uid: i.uid, email: i.email }])),
    authUids: createdUids, documents: [], baseline,
  };
  try {
    for (const i of Object.values(IDENTITIES)) {
      const record = await auth.createUser({ uid: i.uid, email: i.email, emailVerified: false, password: passwords[i.role], displayName: i.displayName });
      if (record.uid !== i.uid) throw new Error(`UID inattendu pour ${i.role} : Auth a renvoyé un autre identifiant`);
      createdUids.push(record.uid);
    }
    const batch = db.batch();
    for (const doc of plan) batch.create(db.doc(doc.path), toData(admin, doc.data));
    await batch.commit();
    manifest.documents = plan.map((d) => ({ path: d.path, kind: d.kind, hash: lot.docHash(d.data) }));
    manifest.status = 'complete';
  } finally {
    // Même en cas d'échec : le manifeste liste exactement ce qui a été créé, pour que le nettoyage puisse le défaire.
    await writeNew(fsApi, path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  }
  return manifest;
}

// Le GPS du livreur doit dater de moins de 3 minutes au moment du dispatch (dispatch.js, STALE_MINUTES) : à rafraîchir juste avant S6.
async function refreshDriverGps({ admin, db }) {
  const ref = db.doc(`livreurs/${IDENTITIES.driver.uid}`);
  const snap = await ref.get();
  if (!snap.exists || snap.data()[lot.LOT_FIELD] !== LOT_ID) throw new guard.GuardError('NOT_IN_LOT', 'Livreur absent ou hors du lot : aucune écriture');
  await ref.update({ lat: lot.DRIVER_POINT.lat, lng: lot.DRIVER_POINT.lng, isOnline: true, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
}

function dryRun({ plan = lot.buildSeedPlan() } = {}) {
  const sensitive = lot.findSensitiveKeys(plan);
  return { mode: 'dry-run', writes: 0, sensitiveKeys: sensitive, inventory: lot.buildInventory(plan) };
}

// ── Ligne de commande ────────────────────────────────────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${a}`);
    const key = a.slice(2);
    if (['execute', 'check-collisions', 'refresh-driver-gps'].includes(key)) out.flags.add(key);
    else if (['project', 'project-number', 'out', 'confirm'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; }
    else throw new guard.GuardError('BAD_ARGUMENT', `Option inconnue : ${a}`);
  }
  return out;
}

function connect(target) {
  const admin = require(path.join(guard.REPO_ROOT, 'functions', 'node_modules', 'firebase-admin'));
  admin.initializeApp({ projectId: target.projectId, credential: admin.credential.applicationDefault(), storageBucket: TARGET.storageBucket });
  return admin;
}

async function onlineFetchJson(admin, url) {
  const { access_token: token } = await admin.credential.applicationDefault().getAccessToken();
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`Lecture ${url} refusée (${res.status})`);
  return res.json();
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  const execute = args.flags.has('execute');
  const needsCloud = execute || args.flags.has('check-collisions') || args.flags.has('refresh-driver-gps');

  log(JSON.stringify(dryRun(), null, 2));
  if (!needsCloud) { log('DRY-RUN : aucune connexion, aucune écriture.'); return 0; }
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Les accès cloud sont réservés à az-express-preprod');
  // Confirmations et dossier de sortie contrôlés AVANT toute connexion : une commande incomplète ne touche jamais le réseau.
  if (execute) { guard.assertConfirmation(args.values.confirm, 'CREATE'); guard.assertOutDirOutsideRepo(args.values.out); }
  if (args.flags.has('refresh-driver-gps')) guard.assertConfirmation(args.values.confirm, 'REFRESH');

  const admin = connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => onlineFetchJson(admin, url) });
  const db = admin.firestore(); const auth = admin.auth();

  if (args.flags.has('refresh-driver-gps')) {
    await refreshDriverGps({ admin, db });
    log('GPS du livreur fictif rafraîchi.');
    return 0;
  }
  if (!execute) {
    const collisions = await checkCollisions({ db, auth, plan: lot.buildSeedPlan() });
    log(JSON.stringify({ mode: 'check-collisions', writes: 0, collisions }, null, 2));
    return collisions.length ? 2 : 0;
  }
  const manifest = await executePrepare({ admin, db, auth, outDir: args.values.out });
  log(JSON.stringify({ mode: 'execute', status: manifest.status, authUids: manifest.authUids, documents: manifest.documents.map((d) => d.path) }, null, 2));
  return 0;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${err.message}`);
    process.exit(1);
  });
}

module.exports = {
  checkCollisions, baselineSnapshot, executePrepare, refreshDriverGps, dryRun, parseArgs, main, toData, connect, onlineFetchJson,
};
