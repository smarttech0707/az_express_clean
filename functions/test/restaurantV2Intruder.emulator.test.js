'use strict';

// Mission 7E-43 — création du compte intrus, extension du manifeste et nettoyage, contre l'ÉMULATEUR (projet demo-az-t7e).
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-t7e \
//     "node --test functions/test/restaurantV2Intruder.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && process.env.GCLOUD_PROJECT === 'demo-az-t7e';
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-az-t7e)' };
const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const guard = require(path.join(dir, 'guard'));
const prepare = require(path.join(dir, 'prepare'));
const intruder = require(path.join(dir, 'intruder'));
const cleanup = require(path.join(dir, 'cleanup'));

const NOW = Date.UTC(2026, 10, 6, 10, 0, 0);
const { client: CLIENT, restaurant: RESTO } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const INTRUS = intruder.INTRUDER.uid;

let admin; let db; let auth; let outDir; let users; let files;
const notFound = () => Object.assign(new Error('user-not-found'), { code: 'auth/user-not-found' });
function fakeAuth() {
  users = new Map();
  return {
    getUser: async (uid) => { if (!users.has(uid)) throw notFound(); return users.get(uid); },
    getUserByEmail: async (email) => { const u = [...users.values()].find((x) => x.email === email); if (!u) throw notFound(); return u; },
    createUser: async (p) => { const rec = { uid: p.uid, email: p.email, displayName: p.displayName, phoneNumber: undefined }; users.set(p.uid, rec); return rec; },
    deleteUser: async (uid) => { users.delete(uid); },
  };
}
async function dumpAll() {
  const out = {};
  const walk = async (col) => { for (const d of (await col.get()).docs) { out[d.ref.path] = JSON.stringify(d.data()); for (const sub of await d.ref.listCollections()) await walk(sub); } };
  for (const c of await db.listCollections()) await walk(c);
  return out;
}
const only = (dump, test) => Object.fromEntries(Object.entries(dump).filter(([k]) => test(k)));
const readJson = (f) => JSON.parse(fs.readFileSync(path.join(outDir, f), 'utf8'));
const bucket = { file: (p) => ({ exists: async () => [files.has(p)], delete: async () => { files.delete(p); } }) };

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  files = new Set();
  outDir = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-intruder-'));
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${process.env.GCLOUD_PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  await db.doc('zones_livraison/abengourou-test').set({ type: 'ville', name: 'Abengourou', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 8 });
  for (const id of ['hist-1', 'hist-2']) await db.doc(`orders/${id}`).set({ clientId: 'real-client', sellerId: 'real-resto', driverId: 'real-driver', status: 'delivered', totalAmount: 3000 });
  await db.doc('clients/real-client').set({ name: 'Client existant', wallet: 12345, fcmToken: 'PLACEHOLDER-NOT-A-REAL-TOKEN' });
  auth = fakeAuth();
  await prepare.executePrepare({ admin, db, auth, outDir }); // lot de base : 4 comptes, 7 documents
});

const isHistoric = (p) => /^(orders\/hist-|clients\/real-)/.test(p);
const isBase = (p) => /^(clients\/t7e-client|restaurants\/t7e-resto|restaurant_owners\/t7e-resto|livreurs\/t7e-driver|admins\/t7e-admin)/.test(p);

test('1. collisions : tout élément déjà présent bloque, sans aucune écriture ni fichier', options, async () => {
  const before = await dumpAll();
  const cases = [
    ['document', async () => db.doc(`clients/${INTRUS}`).set({ name: 'x' }), async () => db.doc(`clients/${INTRUS}`).delete(), 'document déjà présent'],
    ['rôle en trop', async () => db.doc(`admins/${INTRUS}`).set({ role: 'super' }), async () => db.doc(`admins/${INTRUS}`).delete(), 'rôle supplémentaire'],
    ['liste blanche', async () => db.doc('config/partnerOrdersV2').set({ pilotClientIds: [INTRUS] }), async () => db.doc('config/partnerOrdersV2').delete(), 'pilotClientIds'],
  ];
  for (const [label, arm, disarm, reason] of cases) {
    await arm();
    try {
      await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'COLLISION' && e.collisions.some((c) => c.reason.includes(reason)), label);
    } finally { await disarm(); }
  }
  users.set(INTRUS, { uid: INTRUS, email: 'autre@example.invalid' });
  await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'COLLISION' && e.collisions.some((c) => c.type === 'auth'));
  users.delete(INTRUS);
  users.set('quelquun', { uid: 'quelquun', email: intruder.INTRUDER.email });
  await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'COLLISION' && e.collisions.some((c) => c.reason.includes('e-mail')));
  users.delete('quelquun');

  assert.deepEqual(await dumpAll(), before, 'aucune écriture Firestore');
  assert.equal(users.size, 4, 'aucun compte créé');
  assert.deepEqual(fs.readdirSync(outDir).sort(), ['credentials.json', 'manifest.json'], 'aucun fichier ajouté');
});

test('2. lot de base endommagé ou manifeste invalide : refus avant toute écriture', options, async () => {
  const text = fs.readFileSync(path.join(outDir, 'manifest.json'), 'utf8');
  await db.doc(`restaurants/${RESTO}/menu/t7e-plat-b`).delete().then(async () => {
    try { await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'BASE_LOT_BROKEN'); }
    finally { await db.doc(`restaurants/${RESTO}/menu/t7e-plat-b`).set({ name: 'Plat test B', price: 1500, description: 'Article fictif du lot de test', available: true, testLotId: lot.LOT_ID }); }
  });
  const bad = JSON.parse(text); bad.status = 'partial';
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(bad));
  try { await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'MANIFEST_INVALID'); }
  finally { fs.writeFileSync(path.join(outDir, 'manifest.json'), text); }
  assert.equal(users.size, 4);
  assert.equal((await db.doc(`clients/${INTRUS}`).get()).exists, false);
  assert.equal(fs.existsSync(path.join(outDir, 'manifest.base.json')), false);
});

test('2b. échec partiel (compte créé, document refusé) : manifeste « partial » fidèle, aucune suppression automatique', options, async () => {
  const dir2 = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-intruder-partial-'));
  for (const f of ['manifest.json', 'credentials.json']) fs.copyFileSync(path.join(outDir, f), path.join(dir2, f));
  const failingDb = new Proxy(db, { get: (t, k) => (k === 'batch' ? () => ({ create: () => {}, commit: async () => { throw new Error('écriture refusée (simulée)'); } }) : (typeof t[k] === 'function' ? t[k].bind(t) : t[k])) });
  await assert.rejects(intruder.executeIntruder({ admin, db: failingDb, auth, dir: dir2 }), /écriture refusée/);
  const m = JSON.parse(fs.readFileSync(path.join(dir2, 'manifest.json'), 'utf8'));
  assert.equal(m.extensions[0].status, 'partial');
  assert.deepEqual(m.extensions[0].authUids, [INTRUS]);
  assert.deepEqual(m.extensions[0].documents, []);
  assert.ok(users.has(INTRUS), 'le compte créé n’est pas supprimé automatiquement');
  assert.equal((await db.doc(`clients/${INTRUS}`).get()).exists, false);
  assert.equal(users.size, 5);
  assert.ok(fs.existsSync(path.join(dir2, 'manifest.base.json')) && fs.existsSync(path.join(dir2, 'credentials.intruder.json')));
  // Le manifeste partiel reste exploitable par le nettoyage (le compte orphelin est inventorié).
  const inv = await cleanup.collectInventory({ admin, db, auth, bucket, manifest: m });
  assert.deepEqual(inv.conflicts, []);
  assert.ok(inv.items.some((i) => i.type === 'auth' && i.uid === INTRUS));
  users.delete(INTRUS); // remise à zéro de l'émulateur pour la suite (action du test, pas du script)
});

test('3. création : exactement 1 compte + 1 document ; lot de base et historique intacts ; manifeste étendu avec copie de référence', options, async () => {
  const before = await dumpAll();
  const originalText = fs.readFileSync(path.join(outDir, 'manifest.json'), 'utf8');
  const ext = await intruder.executeIntruder({ admin, db, auth, dir: outDir, nowMs: NOW, makePassword: () => 'Fictif-Test-Seulement-24ch!' });
  assert.equal(ext.status, 'complete');

  const after = await dumpAll();
  const added = Object.keys(after).filter((p) => !(p in before));
  assert.deepEqual(added, [`clients/${INTRUS}`], 'un seul document écrit');
  for (const p of Object.keys(before)) assert.equal(after[p], before[p], `inchangé : ${p}`);
  assert.deepEqual([...users.keys()].sort(), [...lot.UIDS, INTRUS].sort(), 'cinq comptes, dont l’intrus ; les quatre autres inchangés');
  assert.equal(users.get(INTRUS).email, 't7e-intrus@example.invalid');
  assert.equal(users.get(INTRUS).phoneNumber, undefined);
  const doc = (await db.doc(`clients/${INTRUS}`).get()).data();
  assert.deepEqual(doc, { name: intruder.INTRUDER.displayName, email: intruder.INTRUDER.email, wallet: 0, testLotId: lot.LOT_ID });
  assert.equal((await db.doc('config/partnerOrdersV2').get()).exists, false, 'pilote toujours fermé');
  assert.deepEqual(only(after, isHistoric), only(before, isHistoric));

  // Manifeste : copie de référence identique à l'original, nouveau manifeste = original + extension (inventaire de base conservé).
  assert.equal(fs.readFileSync(path.join(outDir, 'manifest.base.json'), 'utf8'), originalText);
  const next = readJson('manifest.json');
  const base = JSON.parse(originalText);
  assert.equal(next.version, 2);
  assert.deepEqual({ ...next, version: base.version, extensions: undefined }, { ...base, extensions: undefined });
  assert.equal(next.documents.length, 7);
  assert.equal(next.authUids.length, 4);
  assert.deepEqual(next.extensions[0].authUids, [INTRUS]);
  assert.deepEqual(next.extensions[0].documents.map((d) => d.path), [`clients/${INTRUS}`]);
  assert.equal(JSON.stringify(next).includes('Fictif-Test-Seulement'), false, 'aucun mot de passe dans le manifeste');
  // Identifiants à part ; le fichier des quatre autres comptes est intact.
  const creds = readJson('credentials.intruder.json');
  assert.deepEqual(Object.keys(creds), ['intruder']);
  assert.equal(creds.intruder.password.length, 27);
  assert.deepEqual(Object.keys(readJson('credentials.json')).sort(), ['admin', 'client', 'driver', 'restaurant']);
  assert.ok(!fs.existsSync(path.join(outDir, 'manifest.json.tmp')));

  // Relance : refusée (déjà étendu), rien n'est réécrit.
  await assert.rejects(intruder.executeIntruder({ admin, db, auth, dir: outDir }), (e) => e.code === 'MANIFEST_INVALID');
  assert.deepEqual(await dumpAll(), after);
});

test('4. l’intrus n’a aucun accès : absent de pilotClientIds, un devis (pilote restreint ouvert) est refusé sans aucune écriture', options, async () => {
  const { HttpsError } = require('firebase-functions/v2/https');
  const { buildQuotePartnerOrderCF } = require('../partnerOrderQuote');
  const quote = buildQuotePartnerOrderCF({ db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, isEnabled: () => true, now: () => NOW }).run;
  const user = (uid) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { sellerType: 'restaurant', sellerId: RESTO, items: lot.BASKET, destination: lot.DELIVERY_POINT } });
  await db.doc('config/partnerOrdersV2').set({ pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 1 });
  try {
    const before = await dumpAll();
    const denied = await quote(user(INTRUS));
    assert.deepEqual([denied.success, denied.error], [false, 'CLIENT_NOT_IN_PILOT']);
    assert.deepEqual(await dumpAll(), before, 'aucun devis, aucun mouvement');
    const allowed = await quote(user(CLIENT));
    assert.equal(allowed.success, true, JSON.stringify(allowed));
    await db.doc(`tariff_quotes/${allowed.data.quoteId}`).delete();
    const cfg = (await db.doc('config/partnerOrdersV2').get()).data();
    assert.ok(!cfg.pilotClientIds.includes(INTRUS));
  } finally { await db.doc('config/partnerOrdersV2').delete(); }
  const doc = (await db.doc(`clients/${INTRUS}`).get()).data();
  for (const role of intruder.OTHER_ROLE_COLLECTIONS) assert.equal((await db.doc(`${role}/${INTRUS}`).get()).exists, false, role);
  assert.ok(!('fcmToken' in doc) && !('phone' in doc));
});

test('5. nettoyage DRY-RUN : l’intrus est inventorié avec le lot, historique protégé, aucune écriture', options, async () => {
  const manifest = readJson('manifest.json');
  const ctx = { admin, db, auth, bucket, manifest };
  const before = await dumpAll();
  const inv = await cleanup.collectInventory(ctx);
  assert.deepEqual(inv.conflicts, [], JSON.stringify(inv.conflicts));
  const keys = inv.items.map((i) => i.path || i.uid);
  assert.ok(keys.includes(`clients/${INTRUS}`));
  assert.ok(keys.includes(INTRUS));
  for (const uid of lot.UIDS) assert.ok(keys.includes(uid), uid);
  for (const p of lot.buildSeedPlan().map((d) => d.path)) assert.ok(keys.includes(p), p);
  assert.ok(!keys.some((k) => /hist-|real-|audit_logs|rate_limits/.test(k)), 'aucune ressource historique');
  const report = cleanup.dryRun(inv);
  assert.deepEqual([report.writes, report.executable], [0, true]);
  assert.deepEqual(await dumpAll(), before);
  // Sans extension, le manifeste de base ne contient pas l'intrus (les deux manifestes restent exploitables).
  const baseInv = await cleanup.collectInventory({ ...ctx, manifest: JSON.parse(fs.readFileSync(path.join(outDir, 'manifest.base.json'), 'utf8')) });
  assert.ok(!baseInv.items.some((i) => (i.path || i.uid) === INTRUS));
  assert.deepEqual(baseInv.conflicts, []);
});

test('6. nettoyage : toute activité ou mauvaise configuration liée à l’intrus bloque tout, rien n’est supprimé', options, async () => {
  const manifest = readJson('manifest.json');
  const ctx = { admin, db, auth, bucket, manifest };
  const confirm = guard.confirmationFor('DELETE');
  const refuses = async (label, mutate, revert, reason) => {
    await mutate();
    try {
      const before = await dumpAll();
      const inv = await cleanup.collectInventory(ctx);
      assert.ok(inv.conflicts.some((c) => reason.test(c.reason)), `${label} : ${JSON.stringify(inv.conflicts)}`);
      await assert.rejects(cleanup.executeCleanup({ ...ctx, expectedHash: inv.hash, confirm }), (e) => e.code === 'CONFLICTS', label);
      assert.deepEqual(await dumpAll(), before);
      assert.equal(users.size, 5);
    } finally { await revert(); }
  };
  await refuses('commande de l’intrus', () => db.doc('orders/intrus-1').set({ clientId: INTRUS, sellerId: RESTO, status: 'delivered' }), () => db.doc('orders/intrus-1').delete(), /commande de l’intrus/);
  await refuses('devis de l’intrus', () => db.doc('tariff_quotes/intrus-q').set({ uid: INTRUS, sellerId: RESTO }), () => db.doc('tariff_quotes/intrus-q').delete(), /devis/);
  await refuses('wallet de l’intrus', () => db.doc(`clients/${INTRUS}/wallet_transactions/x`).set({ amount: 1 }), () => db.doc(`clients/${INTRUS}/wallet_transactions/x`).delete(), /mouvement de wallet/);
  await refuses('intrus dans la liste blanche', () => db.doc('config/partnerOrdersV2').set({ pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT, INTRUS], creationOpen: false }), () => db.doc('config/partnerOrdersV2').delete(), /autres clients/);
  await refuses('ouverture générale', () => db.doc('config/partnerOrdersV2').set({ pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'open', creationOpen: false }), () => db.doc('config/partnerOrdersV2').delete(), /ouvert à tous/);
  await refuses('document de l’intrus sans marqueur', () => db.doc(`clients/${INTRUS}`).update({ testLotId: admin.firestore.FieldValue.delete() }), () => db.doc(`clients/${INTRUS}`).update({ testLotId: lot.LOT_ID }), /sans marqueur/);
  await refuses('jeton FCM sur l’intrus', () => db.doc(`clients/${INTRUS}`).update({ fcmToken: 'PLACEHOLDER' }), () => db.doc(`clients/${INTRUS}`).update({ fcmToken: admin.firestore.FieldValue.delete() }), /sensible/);
  const email = users.get(INTRUS).email;
  await refuses('compte Auth intrus d’un autre e-mail', async () => { users.get(INTRUS).email = 'intrus@example.org'; }, async () => { users.get(INTRUS).email = email; }, /ne correspondant pas/);
  // Commande historique rattachée à l'intrus : protégée.
  const hist = (await db.doc('orders/hist-1').get()).data();
  await refuses('commande historique protégée', () => db.doc('orders/hist-1').update({ clientId: INTRUS }), () => db.doc('orders/hist-1').set(hist), /historique protégée|intrus/);
});

test('7. nettoyage exécuté : intrus supprimé avec le lot, comptes et données hors lot intacts', options, async () => {
  const manifest = readJson('manifest.json');
  const ctx = { admin, db, auth, bucket, manifest };
  await db.doc('clients/t7e-intrus-hors-lot').set({ name: 'Même préfixe, hors inventaire', wallet: 1 });
  const protectedBefore = only(await dumpAll(), (p) => isHistoric(p) || /hors-lot/.test(p));
  const inv = await cleanup.collectInventory(ctx);
  assert.deepEqual(inv.conflicts, []);
  const result = await cleanup.executeCleanup({ ...ctx, expectedHash: inv.hash, confirm: guard.confirmationFor('DELETE') });
  assert.equal(result.clean, true, JSON.stringify(result));
  assert.equal(users.size, 0);
  const after = await dumpAll();
  assert.equal(`clients/${INTRUS}` in after, false);
  assert.equal(Object.keys(after).some(isBase), false);
  assert.deepEqual(only(after, (p) => isHistoric(p) || /hors-lot/.test(p)), protectedBefore, 'historique et préfixe hors lot intacts');
});
