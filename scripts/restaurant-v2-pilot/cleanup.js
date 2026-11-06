#!/usr/bin/env node
'use strict';

// Nettoyage du lot de test Restaurant v2 (Mission 7E-36).
//
//   DRY-RUN (défaut, lecture seule) : inventaire exact + empreinte
//     node scripts/restaurant-v2-pilot/cleanup.js --project az-express-preprod --project-number 306761725053 --manifest <dossier>/manifest.json
//   Suppression (mission autorisée SEULEMENT, après relecture de l'inventaire) :
//     ... --execute --inventory-hash <empreinte du dry-run> --confirm "DELETE t7e-lot-1 az-express-preprod 306761725053"
//
// Règles : jamais de suppression « au préfixe t7e- ». Une ressource n'est supprimée que si (1) elle figure au manifeste ou se rattache
// par référence croisée exacte à une commande du lot, (2) elle passe les contrôles d'appartenance, (3) son chemin est dans la liste
// blanche, (4) l'inventaire relu au moment de l'exécution a EXACTEMENT l'empreinte relue par l'humain. Tout conflit bloque tout.
// Jamais touchés : commandes historiques (manifeste), comptes existants, jetons FCM, audit_logs, rate_limits.

const fs = require('node:fs');
const path = require('node:path');
const lot = require('./lot');
const guard = require('./guard');
const prepare = require('./prepare');
const intruder = require('./intruder');
const storageInventory = require('./storageInventory');
const financialReport = require('./financialReport');
const knownChanges = require('./knownChanges');

const { LOT_ID, LOT_FIELD, IDENTITIES, UIDS } = lot;
// Extension 7E-43 : le compte intrus fait partie du lot (même cycle de vie), mais n'a droit à AUCUNE activité.
const INTRUDER_UID = intruder.INTRUDER.uid;
const ALL_UIDS = Object.freeze([...UIDS, INTRUDER_UID]);
const SWEEP_COLLECTIONS = Object.freeze([
  'wallet_transactions', 'commissions', 'reconciliation_flags', 'order_dispute_decisions', 'stuck_order_alerts',
  'dispatch_metrics', 'delivery_transfers', 'transfer_settlements',
]);
const TERMINAL_STATUSES = Object.freeze(['delivered', 'cancelled']);
const PRESERVED = Object.freeze(['audit_logs (écriture serveur seule)', 'rate_limits (expirent seuls)', 'commandes et comptes historiques']);
const PILOT_CONFIG = 'config/partnerOrdersV2';
const MAX_BATCH = 450; // limite Firestore : 500 opérations par lot

const ID = '[A-Za-z0-9_-]{1,128}';
const ALLOWED_PATHS = Object.freeze([
  new RegExp(`^orders/${ID}$`),
  new RegExp(`^tariff_quotes/${ID}$`),
  new RegExp(`^delivery_proofs/${ID}(/versions/${ID})?$`),
  new RegExp(`^clients/${IDENTITIES.client.uid}(/wallet_transactions/${ID})?$`),
  new RegExp(`^livreurs/${IDENTITIES.driver.uid}(/wallet_transactions/${ID})?$`),
  new RegExp(`^restaurants/${IDENTITIES.restaurant.uid}(/(wallet_transactions|menu)/${ID})?$`),
  new RegExp(`^restaurant_owners/${IDENTITIES.restaurant.uid}$`),
  new RegExp(`^admins/${IDENTITIES.admin.uid}$`),
  new RegExp(`^clients/${INTRUDER_UID}$`),
  new RegExp(`^(${SWEEP_COLLECTIONS.join('|')})/${ID}$`),
  new RegExp(`^notification_dedupe/${ID}$`),
  /^config\/partnerOrdersV2$/,
]);
const pathAllowed = (p) => ALLOWED_PATHS.some((re) => re.test(p));

const chunk = (list, n) => Array.from({ length: Math.ceil(list.length / n) }, (_, i) => list.slice(i * n, i * n + n));
const isNotFound = (err) => err && (err.code === 'auth/user-not-found' || err.errorInfo?.code === 'auth/user-not-found');
// Un objet Storage est identifié par son chemin ET sa génération : un objet remplacé change l'empreinte de l'inventaire.
const itemKey = (i) => `${i.type}:${i.path || i.uid}${i.generation ? `@${i.generation}` : ''}`;

function validateManifest(manifest) {
  const bad = (why) => { throw new guard.GuardError('MANIFEST_INVALID', `Manifeste refusé : ${why}`); };
  if (!manifest || manifest.lot !== LOT_ID) bad('lot inconnu');
  if (!manifest.project || manifest.project.id !== lot.TARGET.projectId || manifest.project.number !== lot.TARGET.projectNumber) bad('projet inattendu');
  for (const i of Object.values(IDENTITIES)) {
    const m = manifest.identities && manifest.identities[i.role];
    if (!m || m.uid !== i.uid || m.email !== i.email) bad(`identité ${i.role} inattendue`);
  }
  const seeds = new Set(lot.buildSeedPlan().map((d) => d.path));
  for (const d of manifest.documents || []) if (!seeds.has(d.path)) bad(`document hors plan : ${d.path}`);
  // Extensions : uniquement le compte intrus, uid/e-mail exacts, documents du plan d'extension seulement.
  const extSeeds = new Set(intruder.buildIntruderPlan().map((d) => d.path));
  for (const ext of manifest.extensions || []) {
    if (!ext || ext.id !== intruder.EXTENSION_ID) bad('extension inconnue');
    const id = ext.identities && ext.identities.intruder;
    if (!id || id.uid !== INTRUDER_UID || id.email !== intruder.INTRUDER.email) bad('identité d’extension inattendue');
    for (const u of ext.authUids || []) if (u !== INTRUDER_UID) bad(`compte d’extension hors plan : ${u}`);
    for (const d of ext.documents || []) if (!extSeeds.has(d.path)) bad(`document d’extension hors plan : ${d.path}`);
  }
  if (!manifest.baseline || !Array.isArray(manifest.baseline.orderIds)) bad('instantané de référence absent');
  return manifest;
}

// Lecture seule. Retourne l'inventaire exact des ressources du lot, les conflits (qui bloquent toute suppression) et l'empreinte.
// `annex` (Mission 7E-55, optionnelle) : changements automatiques connus et vérifiés (voir knownChanges.js). Sans annexe : comportement strict.
async function collectInventory({ admin, db, auth, bucket, manifest, annex = null }) {
  if (annex) knownChanges.validateAnnex(annex, LOT_ID);
  validateManifest(manifest);
  const items = []; const conflicts = []; const missingSeeds = [];
  const baseline = new Set(manifest.baseline.orderIds);
  const add = (item) => { if (!items.some((i) => itemKey(i) === itemKey(item))) items.push(item); };
  const conflict = (type, id, reason) => conflicts.push({ type, id, reason });
  const sensitive = (data) => Object.keys(data).filter((k) => /fcm|token|phone|password|secret/i.test(k));

  // 1. Documents de départ (manifeste) : marqueur du lot et absence de champ sensible (jeton FCM...).
  const extensionDocs = (manifest.extensions || []).flatMap((e) => e.documents || []);
  for (const { path: p } of [...manifest.documents, ...extensionDocs]) {
    const snap = await db.doc(p).get();
    if (!snap.exists) { missingSeeds.push(p); continue; }
    const data = snap.data();
    if (data[LOT_FIELD] !== LOT_ID) { conflict('firestore', p, 'document sans marqueur du lot'); continue; }
    // Seule l'exception exacte de l'annexe (chemin + champ + empreinte vérifiée) cesse d'être un conflit ; tout autre champ sensible bloque.
    const s = knownChanges.classifySensitive({ docPath: p, data, sensitiveFields: sensitive(data), annex }).unexplained;
    if (s.length) { conflict('firestore', p, `champ sensible présent (${s.map((x) => x.field).join(',')})`); continue; }
    add({ type: 'firestore', path: p, group: 'seed' });
  }

  // 2. Comptes Auth : uid ET e-mail du manifeste, domaine .invalid, sans téléphone.
  const authIdentities = [...Object.values(IDENTITIES), ...((manifest.extensions || []).length ? [intruder.INTRUDER] : [])];
  for (const i of authIdentities) {
    try {
      const user = await auth.getUser(i.uid);
      if (user.email !== i.email || !String(user.email).endsWith(`@${lot.EMAIL_DOMAIN}`) || user.phoneNumber) {
        conflict('auth', i.uid, 'compte ne correspondant pas à l’identité du lot');
      } else add({ type: 'auth', uid: i.uid, group: 'seed' });
    } catch (err) { if (!isNotFound(err)) throw err; }
  }

  // 3. Commandes : trouvées par les trois références possibles, puis vérifiées une par une.
  const found = new Map();
  for (const [field, uid] of [['clientId', IDENTITIES.client.uid], ['sellerId', IDENTITIES.restaurant.uid], ['driverId', IDENTITIES.driver.uid]]) {
    for (const d of (await db.collection('orders').where(field, '==', uid).get()).docs) found.set(d.id, d.data());
  }
  const lotOrderIds = [];
  for (const [id, o] of found) {
    const p = `orders/${id}`;
    if (baseline.has(id)) { conflict('firestore', p, 'commande historique protégée'); continue; }
    const driverOk = !o.driverId || o.driverId === IDENTITIES.driver.uid;
    if (o.clientId !== IDENTITIES.client.uid || o.sellerId !== IDENTITIES.restaurant.uid || !driverOk) {
      conflict('firestore', p, 'commande liée au lot mais aussi à un autre compte'); continue;
    }
    if (!TERMINAL_STATUSES.includes(o.status)) { conflict('firestore', p, `commande non terminée (${o.status})`); continue; }
    lotOrderIds.push(id);
    add({ type: 'firestore', path: p, group: 'order' });
  }

  // 3b. L'intrus ne doit avoir AUCUNE activité : ni commande, ni devis, ni écriture de wallet. Toute trace bloque le nettoyage.
  if ((manifest.extensions || []).length) {
    for (const d of (await db.collection('orders').where('clientId', '==', INTRUDER_UID).get()).docs) conflict('firestore', `orders/${d.id}`, 'commande de l’intrus (interdite)');
    for (const d of (await db.collection('tariff_quotes').where('uid', '==', INTRUDER_UID).get()).docs) conflict('firestore', `tariff_quotes/${d.id}`, 'devis de l’intrus (interdit)');
    for (const d of (await db.collection(`clients/${INTRUDER_UID}/wallet_transactions`).get()).docs) conflict('firestore', `clients/${INTRUDER_UID}/wallet_transactions/${d.id}`, 'mouvement de wallet de l’intrus (interdit)');
  }

  // 4. Devis du client du lot, pour le restaurant du lot seulement.
  for (const d of (await db.collection('tariff_quotes').where('uid', '==', IDENTITIES.client.uid).get()).docs) {
    if (d.data().sellerId !== IDENTITIES.restaurant.uid) { conflict('firestore', `tariff_quotes/${d.id}`, 'devis d’un autre partenaire'); continue; }
    add({ type: 'firestore', path: `tariff_quotes/${d.id}`, group: 'quote' });
  }

  // 5. Preuves QR/PIN des commandes du lot (session + versions), rattachées par l'identifiant de commande.
  const { sessionId } = require(path.join(guard.REPO_ROOT, 'functions', 'deliveryProofs'));
  for (const orderId of lotOrderIds) {
    for (const type of ['pickup', 'delivery']) {
      const sid = sessionId(orderId, type);
      const session = await db.doc(`delivery_proofs/${sid}`).get();
      if (!session.exists) continue;
      if (session.data().orderId !== orderId) { conflict('firestore', `delivery_proofs/${sid}`, 'session rattachée à une autre commande'); continue; }
      add({ type: 'firestore', path: `delivery_proofs/${sid}`, group: 'proof' });
      for (const v of (await db.collection(`delivery_proofs/${sid}/versions`).get()).docs) {
        if (v.data().orderId !== orderId) { conflict('firestore', `delivery_proofs/${sid}/versions/${v.id}`, 'version rattachée à une autre commande'); continue; }
        add({ type: 'firestore', path: `delivery_proofs/${sid}/versions/${v.id}`, group: 'proof' });
      }
    }
  }

  // 6. Journaux de wallet des trois comptes : chaque écriture doit référencer une commande du lot.
  for (const [col, uid] of [['clients', IDENTITIES.client.uid], ['livreurs', IDENTITIES.driver.uid], ['restaurants', IDENTITIES.restaurant.uid]]) {
    for (const d of (await db.collection(`${col}/${uid}/wallet_transactions`).get()).docs) {
      const p = `${col}/${uid}/wallet_transactions/${d.id}`;
      if (!lotOrderIds.includes(d.data().orderId)) { conflict('firestore', p, 'écriture de wallet sans commande du lot'); continue; }
      add({ type: 'firestore', path: p, group: 'ledger' });
    }
  }

  // 7. Documents liés à une commande du lot dans les autres collections : champ orderId OU identifiant préfixé par l'UUID de la commande.
  const FieldPath = admin.firestore.FieldPath;
  for (const col of SWEEP_COLLECTIONS) {
    for (const ids of chunk(lotOrderIds, 10)) {
      for (const d of (await db.collection(col).where('orderId', 'in', ids).get()).docs) add({ type: 'firestore', path: `${col}/${d.id}`, group: 'linked' });
    }
    for (const orderId of lotOrderIds) {
      const q = db.collection(col).orderBy(FieldPath.documentId()).startAt(orderId).endAt(`${orderId}`);
      for (const d of (await q.get()).docs) add({ type: 'firestore', path: `${col}/${d.id}`, group: 'linked' });
    }
  }
  for (const uids of chunk([...ALL_UIDS], 10)) {
    for (const d of (await db.collection('notification_dedupe').where('recipientId', 'in', uids).get()).docs) {
      add({ type: 'firestore', path: `notification_dedupe/${d.id}`, group: 'linked' });
    }
  }

  // 8. Objets Storage par commande (selfie d'acceptation exigé par acceptOrderCF, photo de livraison).
  // Listing seul (storage.objects.list) : le compte CLI n'a pas storage.objects.get. Voir storageInventory.js.
  const stored = await storageInventory.inventoryOrders({ bucket, orderIds: lotOrderIds });
  for (const o of stored.items) add(o);
  conflicts.push(...stored.conflicts);

  // 8b. Réconciliation financière des commandes du lot : aucun nettoyage tant que les montants ne concordent pas (lecture seule).
  const includeIntruder = (manifest.extensions || []).length > 0;
  const walletDocs = await Promise.all(Object.entries(financialReport.WALLET_OWNERS).filter(([k]) => k !== 'intruder' || includeIntruder).map(([, p]) => db.doc(p).get()));
  if (lotOrderIds.length || walletDocs.some((s) => s.exists)) {
    const verdict = financialReport.reconcile(await financialReport.gather({ db, orderIds: lotOrderIds, includeIntruder }));
    for (const why of verdict.problems) conflict('finance', 'reconciliation', why);
  }

  // 9. Configuration du pilote : supprimée seulement si elle ne désigne que le restaurant du lot.
  const pilot = await db.doc(PILOT_CONFIG).get();
  if (pilot.exists) {
    const ids = Array.isArray(pilot.data().pilotPartnerIds) ? pilot.data().pilotPartnerIds : [];
    // Mission 7E-41 : un pilote ouvert à d’autres clients (liste étrangère, intrus compris, ou ouverture générale) n’est plus un pilote du lot.
    const clients = pilot.data().pilotClientIds;
    const foreignPartners = ids.some((id) => id !== IDENTITIES.restaurant.uid);
    // Mission 7E-55 : idem pour les livreurs pilotes (seul le livreur du lot est admis).
    const drivers = pilot.data().pilotDriverIds;
    const foreignDrivers = Array.isArray(drivers) && drivers.some((id) => id !== IDENTITIES.driver.uid);
    const foreignClients = (Array.isArray(clients) && clients.some((id) => id !== IDENTITIES.client.uid)) || pilot.data().clientAccess === 'open';
    if (foreignPartners) conflict('firestore', PILOT_CONFIG, 'le pilote désigne d’autres partenaires : ne pas toucher');
    if (foreignClients) conflict('firestore', PILOT_CONFIG, 'le pilote désigne d’autres clients ou est ouvert à tous : ne pas toucher');
    if (foreignDrivers) conflict('firestore', PILOT_CONFIG, 'le pilote désigne d’autres livreurs : ne pas toucher');
    // Pilote encore ouvert : aucune suppression tant que la création n'est pas refermée par le chemin audité (CLOSE / emergencyClose.js).
    if (pilot.data().creationOpen === true) conflict('firestore', PILOT_CONFIG, 'pilote encore ouvert : fermer par le chemin audité avant tout nettoyage');
    if (!foreignPartners && !foreignClients && !foreignDrivers) add({ type: 'firestore', path: PILOT_CONFIG, group: 'pilot' });
  }

  items.sort((a, b) => (itemKey(a) < itemKey(b) ? -1 : 1));
  const hash = lot.sha256(lot.canonical(items.map(itemKey)));
  return { lot: LOT_ID, items, conflicts, missingSeeds, lotOrderIds: lotOrderIds.sort(), preserved: [...PRESERVED], hash };
}

function dryRun(inventory) {
  const byGroup = {};
  for (const i of inventory.items) byGroup[i.group] = (byGroup[i.group] || 0) + 1;
  return {
    mode: 'dry-run', writes: 0, hash: inventory.hash, total: inventory.items.length, byGroup, conflicts: inventory.conflicts,
    executable: inventory.conflicts.length === 0, items: inventory.items, missingSeeds: inventory.missingSeeds, preserved: inventory.preserved,
  };
}

async function executeCleanup({ admin, db, auth, bucket, manifest, annex = null, expectedHash, confirm, log = () => {} }) {
  guard.assertConfirmation(confirm, 'DELETE');
  const inventory = await collectInventory({ admin, db, auth, bucket, manifest, annex });
  if (inventory.conflicts.length) {
    throw new guard.GuardError('CONFLICTS', `Suppression refusée, conflits : ${inventory.conflicts.map((c) => `${c.id} (${c.reason})`).join('; ')}`);
  }
  if (!expectedHash || inventory.hash !== expectedHash) {
    throw new guard.GuardError('INVENTORY_CHANGED', 'L’inventaire diffère de celui relu (empreinte) : refaire un dry-run');
  }
  for (const i of inventory.items) {
    if (i.type === 'firestore' && !pathAllowed(i.path)) throw new guard.GuardError('PATH_NOT_ALLOWED', `Chemin hors liste blanche : ${i.path}`);
    if (i.type === 'auth' && !ALL_UIDS.includes(i.uid)) throw new guard.GuardError('UID_NOT_ALLOWED', `Compte hors lot : ${i.uid}`);
    if (i.type === 'storage') {
      if (!storageInventory.pathAllowed(i.path) || !inventory.lotOrderIds.includes(storageInventory.orderIdOf(i.path))) throw new guard.GuardError('PATH_NOT_ALLOWED', `Objet Storage hors liste blanche : ${i.path}`);
      if (i.bucket !== lot.TARGET.storageBucket) throw new guard.GuardError('WRONG_BUCKET', `Bucket inattendu : ${i.bucket}`);
    }
  }

  // Ordre choisi pour qu'une interruption à n'importe quel point reste REPRENABLE (relancer dry-run puis exécution) :
  // 1. Objets Storage d'abord, tant que la commande existe encore (leur appartenance au lot en dérive) ; chaque objet est relu et supprimé
  //    avec précondition de génération, un échec arrête tout avant la moindre suppression Firestore.
  for (const s of inventory.items.filter((i) => i.type === 'storage')) {
    await storageInventory.deleteObject({ bucket, item: s, orderIds: inventory.lotOrderIds });
    log(`objet supprimé : ${s.path}`);
  }
  // 2. Fermeture de la création (le pilote doit déjà être fermé : conflit sinon) et vidage des listes avant la suppression.
  if (inventory.items.some((i) => i.path === PILOT_CONFIG)) {
    await db.doc(PILOT_CONFIG).update({ creationOpen: false, pilotPartnerIds: [], pilotClientIds: [], pilotDriverIds: [], clientAccess: 'restricted' });
    log('pilote fermé');
  }
  // 3. Tous les documents Firestore en UN lot atomique : la réconciliation financière ne voit jamais un grand livre à moitié supprimé.
  const docs = inventory.items.filter((i) => i.type === 'firestore');
  if (docs.length > MAX_BATCH) throw new guard.GuardError('TOO_LARGE', `${docs.length} documents : plus que le lot atomique autorisé (${MAX_BATCH})`);
  if (docs.length) {
    const batch = db.batch();
    for (const d of docs) batch.delete(db.doc(d.path));
    await batch.commit();
  }
  // 4. Comptes Auth en dernier (un compte déjà supprimé lors d'une reprise n'est plus dans l'inventaire).
  for (const u of inventory.items.filter((i) => i.type === 'auth')) await auth.deleteUser(u.uid);

  const after = await collectInventory({ admin, db, auth, bucket, manifest, annex });
  return { deleted: inventory.items.length, remaining: after.items.length, conflictsAfter: after.conflicts, clean: after.items.length === 0 && after.conflicts.length === 0 };
}

function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : null;
    if (key === 'execute') out.flags.add(key);
    else if (['project', 'project-number', 'manifest', 'known-changes', 'confirm', 'inventory-hash', 'report-dir'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; }
    else throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${argv[i]}`);
  }
  return out;
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Les accès cloud sont réservés à az-express-preprod');
  if (!args.values.manifest) throw new guard.GuardError('MANIFEST_REQUIRED', 'Manifeste requis (--manifest)');
  const manifest = validateManifest(JSON.parse(fs.readFileSync(args.values.manifest, 'utf8')));
  // Confirmation et empreinte contrôlées AVANT toute connexion.
  if (args.flags.has('execute')) {
    guard.assertConfirmation(args.values.confirm, 'DELETE');
    if (!args.values['inventory-hash']) throw new guard.GuardError('HASH_REQUIRED', 'Empreinte d’inventaire requise (--inventory-hash)');
  }

  const admin = prepare.connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => prepare.onlineFetchJson(admin, url) });
  const annex = knownChanges.loadAnnex(fs, args.values['known-changes'], LOT_ID);
  const ctx = { admin, db: admin.firestore(), auth: admin.auth(), bucket: admin.storage().bucket(), manifest, annex };

  if (!args.flags.has('execute')) {
    const inventory = await collectInventory(ctx);
    const report = dryRun(inventory);
    // Preuve locale (hors dépôt, droits 0600) : rapport financier sans secret + empreinte de l'inventaire. Lecture seule côté cloud.
    if (args.values['report-dir']) {
      const dir = guard.assertOutDirOutsideRepo(args.values['report-dir']);
      const finance = financialReport.buildReport(await financialReport.gather({ db: ctx.db, orderIds: inventory.lotOrderIds, includeIntruder: (manifest.extensions || []).length > 0 }), { project: target.projectId });
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, `restaurant-v2-first-run-report-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
      fs.writeFileSync(file, JSON.stringify({ finance, inventory: { hash: report.hash, total: report.total, byGroup: report.byGroup, items: report.items, conflicts: report.conflicts } }, null, 2), { mode: 0o600 });
      log(`Rapport local écrit : ${file}`);
    }
    log(JSON.stringify(report, null, 2));
    log(`Pour exécuter : --execute --inventory-hash ${report.hash} --confirm "${guard.confirmationFor('DELETE')}"`);
    return report.executable ? 0 : 2;
  }
  const result = await executeCleanup({ ...ctx, expectedHash: args.values['inventory-hash'], confirm: args.values.confirm, log });
  log(JSON.stringify(result, null, 2));
  return result.clean ? 0 : 2;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${err.message}`);
    process.exit(1);
  });
}

module.exports = { collectInventory, dryRun, executeCleanup, validateManifest, pathAllowed, parseArgs, main, SWEEP_COLLECTIONS, PILOT_CONFIG };
