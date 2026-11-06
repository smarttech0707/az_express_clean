'use strict';

// Mission 7E-47 — sécurité du nettoyage contre l'ÉMULATEUR Firestore (projet demo-az-t7e) : lot cohérent fabriqué à la main,
// conflits bloquants, génération Storage, interruption puis reprise. Comptes Auth et Storage simulés. Aucun accès cloud.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-t7e \
//     "node --test functions/test/restaurantV2CleanupSafety.emulator.test.js"
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
const cleanup = require(path.join(dir, 'cleanup'));

const { client: CLIENT, restaurant: RESTO, driver: DRIVER } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const OID = 'ord-0001';
const SELFIE = `acceptance_selfies/${OID}/t7e-driver.jpg`;
const DELETE = () => guard.confirmationFor('DELETE');

let admin; let db; let auth; let bucket; let files; let manifest;

function fakeAuth() {
  const users = new Map();
  const notFound = () => Object.assign(new Error('user-not-found'), { code: 'auth/user-not-found' });
  return {
    users, failOnDelete: null,
    getUser: async (uid) => { if (!users.has(uid)) throw notFound(); return users.get(uid); },
    getUserByEmail: async (email) => { const u = [...users.values()].find((x) => x.email === email); if (!u) throw notFound(); return u; },
    createUser: async (p) => { const rec = { uid: p.uid, email: p.email, displayName: p.displayName }; users.set(p.uid, rec); return rec; },
    deleteUser: async (uid) => { if (auth.failOnDelete === uid) { auth.failOnDelete = null; throw new Error('interruption simulée'); } users.delete(uid); },
  };
}
function fakeBucket(set) {
  const gens = new Map(); let counter = 1000;
  const gen = (p) => { if (!gens.has(p)) { counter += 1; gens.set(p, String(counter)); } return gens.get(p); };
  const deny = async () => { throw Object.assign(new Error('403 storage.objects.get denied'), { code: 403 }); };
  return {
    name: lot.TARGET.storageBucket,
    bump: (p) => { counter += 1; gens.set(p, String(counter)); },
    getFiles: async ({ prefix = '' } = {}) => [[...set].filter((p) => p.startsWith(prefix)).sort().map((name) => ({ name, metadata: { bucket: lot.TARGET.storageBucket, name, generation: gen(name), size: '1976', contentType: 'image/jpeg' } }))],
    file: (p, opts = {}) => ({
      exists: deny, getMetadata: deny,
      delete: async (o = {}) => {
        if ((opts.generation && opts.generation !== gen(p)) || (o.ifGenerationMatch && o.ifGenerationMatch !== gen(p))) throw Object.assign(new Error('412'), { code: 412 });
        if (!set.has(p)) throw Object.assign(new Error('404'), { code: 404 });
        set.delete(p); gens.delete(p);
      },
    }),
  };
}
async function dumpAll() {
  const out = {};
  const walk = async (col) => { for (const d of (await col.get()).docs) { out[d.ref.path] = JSON.stringify(d.data()); for (const sub of await d.ref.listCollections()) await walk(sub); } };
  for (const c of await db.listCollections()) await walk(c);
  return out;
}

// Lot préparé + UNE commande livrée, cohérente (jour : 6500 + 500 = 7000, commission 100), preuves validées, selfie.
async function setup({ withIntruder = false } = {}) {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${process.env.GCLOUD_PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  files = new Set(); bucket = fakeBucket(files); auth = fakeAuth();
  for (const id of ['hist-1', 'hist-2']) await db.doc(`orders/${id}`).set({ clientId: 'real-client', sellerId: 'real-resto', driverId: 'real-driver', status: 'delivered', totalAmount: 3000 });
  await db.doc('clients/real-client').set({ name: 'Client existant', wallet: 12345, fcmToken: 'PLACEHOLDER-NOT-A-REAL-TOKEN' });
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-clean-safety-'));
  manifest = await prepare.executePrepare({ admin, db, auth, outDir });
  if (withIntruder) manifest = { ...manifest, version: 2, extensions: [] }; // l'intrus n'est pas exercé ici
  const T = admin.firestore.Timestamp.now();
  await db.doc(`orders/${OID}`).set({ clientId: CLIENT, sellerId: RESTO, driverId: DRIVER, status: 'delivered', type: 'restaurant', paymentMethod: 'wallet', isPaid: true, productAmount: 6500, deliveryFee: 500, totalAmount: 7000, commissionAmount: 100, tariffQuoteId: 'q1', createdAt: T });
  await db.doc(`clients/${CLIENT}`).update({ wallet: 33000 });
  await db.doc(`livreurs/${DRIVER}`).update({ wallet: 5400 });
  await db.doc(`restaurants/${RESTO}`).update({ wallet: 6500 });
  await db.doc(`clients/${CLIENT}/wallet_transactions/order_${OID}`).set({ type: 'payment', amount: 7000, orderId: OID, createdAt: T });
  await db.doc(`livreurs/${DRIVER}/wallet_transactions/commission_${OID}`).set({ type: 'commission', amount: 100, orderId: OID, createdAt: T });
  await db.doc(`livreurs/${DRIVER}/wallet_transactions/earning_${OID}`).set({ type: 'earning', amount: 500, orderId: OID, createdAt: T });
  await db.doc(`restaurants/${RESTO}/wallet_transactions/earning_${OID}`).set({ type: 'earning', amount: 6500, orderId: OID, createdAt: T });
  await db.doc('commissions/c1').set({ orderId: OID, amount: 100, driverId: DRIVER });
  await db.doc('tariff_quotes/q1').set({ uid: CLIENT, sellerId: RESTO, kind: 'partner', status: 'used', orderId: OID, amount: 7000 });
  for (const type of ['pickup', 'delivery']) {
    await db.doc(`delivery_proofs/p_${type}`).set({ orderId: OID, type, driverId: DRIVER, generationCount: 1 });
    await db.doc(`delivery_proofs/p_${type}/versions/v1`).set({ orderId: OID, status: 'used', validatedAt: T, pinHash: 'SECRET-PIN-HASH', tokenHash: 'SECRET-TOKEN-HASH' });
  }
  await db.doc('config/partnerOrdersV2').set({ pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'restricted', creationOpen: false, managementFrozen: false, version: 4 });
  files.add(SELFIE);
}
const ctx = () => ({ admin, db, auth, bucket, manifest });

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
});

test('1. lot cohérent : aucun conflit, objet Storage inventorié par génération sans storage.objects.get, rapport sans secret', options, async () => {
  await setup();
  const inv = await cleanup.collectInventory(ctx());
  assert.deepEqual(inv.conflicts, [], JSON.stringify(inv.conflicts));
  const storage = inv.items.filter((i) => i.type === 'storage');
  assert.equal(storage.length, 1);
  assert.equal(storage[0].path, SELFIE);
  assert.match(storage[0].generation, /^\d+$/);
  assert.equal(storage[0].bucket, lot.TARGET.storageBucket);
  assert.deepEqual(inv.lotOrderIds, [OID]);
  assert.equal(cleanup.dryRun(inv).executable, true);
  const finance = require(path.join(dir, 'financialReport'));
  const report = finance.buildReport(await finance.gather({ db, orderIds: inv.lotOrderIds }), { project: 'demo' });
  assert.equal(report.coherent, true, JSON.stringify(report.problems));
  assert.deepEqual(report.wallets.after, { client: 33000, driver: 5400, restaurant: 6500, intruder: null });
  assert.equal(Object.values(report.walletTransactions).flat().length, 4);
  assert.ok(!/SECRET|pinHash|tokenHash/.test(JSON.stringify(report)));
});

test('2. conflits bloquants : pilote ouvert, commande non terminale, wallet incohérent, commission double, voisin Storage, ressource hors lot', options, async () => {
  await setup();
  const before = await dumpAll();
  const attempts = [
    ['pilote encore ouvert', () => db.doc('config/partnerOrdersV2').update({ creationOpen: true }), () => db.doc('config/partnerOrdersV2').update({ creationOpen: false }), /encore ouvert/],
    ['commande non terminale', () => db.doc(`orders/${OID}`).update({ status: 'picked_up' }), () => db.doc(`orders/${OID}`).update({ status: 'delivered' }), /non terminée/],
    ['wallet incohérent', () => db.doc(`clients/${CLIENT}`).update({ wallet: 33001 }), () => db.doc(`clients/${CLIENT}`).update({ wallet: 33000 }), /solde client/],
    ['commission double', () => db.doc('commissions/c2').set({ orderId: OID, amount: 100 }), () => db.doc('commissions/c2').delete(), /commission/],
    ['écriture de wallet sans commande du lot', () => db.doc(`clients/${CLIENT}/wallet_transactions/stray`).set({ type: 'payment', amount: 1, orderId: 'autre' }), () => db.doc(`clients/${CLIENT}/wallet_transactions/stray`).delete(), /wallet|commande du lot/],
    ['devis d’un autre partenaire', () => db.doc('tariff_quotes/q9').set({ uid: CLIENT, sellerId: 'real-resto', status: 'open' }), () => db.doc('tariff_quotes/q9').delete(), /autre partenaire/],
    ['objet Storage voisin', async () => { files.add(`${SELFIE}.bak`); }, async () => { files.delete(`${SELFIE}.bak`); }, /voisins/],
    ['preuve de livraison non validée', () => db.doc('delivery_proofs/p_delivery/versions/v1').update({ validatedAt: null, status: 'open' }), () => db.doc('delivery_proofs/p_delivery/versions/v1').update({ validatedAt: admin.firestore.Timestamp.now(), status: 'used' }), /non validée/],
  ];
  for (const [label, apply, undo, why] of attempts) {
    await apply();
    const inv = await cleanup.collectInventory(ctx());
    assert.match(inv.conflicts.map((c) => c.reason).join(';'), why, label);
    assert.equal(cleanup.dryRun(inv).executable, false, label);
    const snapshot = [...files].sort();
    await assert.rejects(cleanup.executeCleanup({ ...ctx(), expectedHash: inv.hash, confirm: DELETE() }), (e) => e.code === 'CONFLICTS', label);
    assert.deepEqual([...files].sort(), snapshot, `${label} : Storage intact`);
    await undo();
  }
  const clean = await cleanup.collectInventory(ctx());
  assert.deepEqual(clean.conflicts, []);
  const after = await dumpAll();
  delete after['config/partnerOrdersV2']; const b = { ...before }; delete b['config/partnerOrdersV2'];
  const strip = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, v.replace(/"validatedAt":\{[^}]*\}/, '')]));
  assert.deepEqual(Object.keys(strip(after)).sort(), Object.keys(strip(b)).sort(), 'aucune suppression ni création résiduelle');
});

test('3. génération Storage modifiée entre le dry-run et l’exécution : empreinte différente, rien supprimé', options, async () => {
  await setup();
  const inv = await cleanup.collectInventory(ctx());
  bucket.bump(SELFIE); // objet remplacé (même nom, autre génération)
  const dump = await dumpAll();
  await assert.rejects(cleanup.executeCleanup({ ...ctx(), expectedHash: inv.hash, confirm: DELETE() }), (e) => e.code === 'INVENTORY_CHANGED');
  assert.ok(files.has(SELFIE));
  assert.deepEqual(await dumpAll(), dump);
  // Remplacement APRÈS la relecture finale (course) : précondition de génération, rien de Firestore supprimé.
  const again = await cleanup.collectInventory(ctx());
  const realFiles = bucket.getFiles; let calls = 0;
  bucket.getFiles = async (o) => { const r = await realFiles(o); calls += 1; if (calls === 2) bucket.bump(SELFIE); return r; }; // 1re liste = exécution, 2e = relecture de deleteObject
  await assert.rejects(cleanup.executeCleanup({ ...ctx(), expectedHash: again.hash, confirm: DELETE() }), (e) => e.code === 'OBJECT_REPLACED');
  assert.ok(files.has(SELFIE), 'objet remplacé conservé');
  assert.deepEqual(await dumpAll(), dump, 'aucun document supprimé : Storage vérifié AVANT Firestore');
});

test('4. interruption pendant la suppression Firestore puis reprise : état reprenable, nettoyage terminé, historique intact', options, async () => {
  await setup();
  const inv = await cleanup.collectInventory(ctx());
  const historic = JSON.stringify((await db.doc('orders/hist-1').get()).data()) + JSON.stringify((await db.doc('clients/real-client').get()).data());
  // Le commit atomique échoue une fois (interruption) : rien de Firestore n'est supprimé, l'objet Storage l'est déjà.
  let failed = false;
  const flaky = new Proxy(db, { get: (t, k) => {
    if (k === 'batch') return () => { const b = t.batch(); return { delete: (r) => b.delete(r), commit: async () => { if (!failed) { failed = true; throw new Error('interruption simulée'); } return b.commit(); } }; };
    const v = t[k]; return typeof v === 'function' ? v.bind(t) : v;
  } });
  await assert.rejects(cleanup.executeCleanup({ ...ctx(), db: flaky, expectedHash: inv.hash, confirm: DELETE() }), /interruption simulée/);
  assert.equal(files.has(SELFIE), false, 'Storage déjà nettoyé');
  assert.equal((await db.doc(`orders/${OID}`).get()).exists, true, 'Firestore intact (lot atomique)');
  // Reprise : nouveau dry-run (sans objet Storage), cohérent, puis exécution avec la nouvelle empreinte.
  const resumed = await cleanup.collectInventory(ctx());
  assert.deepEqual(resumed.conflicts, [], JSON.stringify(resumed.conflicts));
  assert.equal(resumed.items.filter((i) => i.type === 'storage').length, 0);
  assert.notEqual(resumed.hash, inv.hash);
  const result = await cleanup.executeCleanup({ ...ctx(), expectedHash: resumed.hash, confirm: DELETE() });
  assert.equal(result.clean, true, JSON.stringify(result));
  assert.equal(JSON.stringify((await db.doc('orders/hist-1').get()).data()) + JSON.stringify((await db.doc('clients/real-client').get()).data()), historic);
});

test('5. interruption pendant la suppression des comptes Auth puis reprise', options, async () => {
  await setup();
  const inv = await cleanup.collectInventory(ctx());
  auth.failOnDelete = DRIVER;
  await assert.rejects(cleanup.executeCleanup({ ...ctx(), expectedHash: inv.hash, confirm: DELETE() }), /interruption simulée/);
  assert.equal((await db.doc(`orders/${OID}`).get()).exists, false, 'Firestore déjà supprimé');
  const resumed = await cleanup.collectInventory(ctx());
  assert.deepEqual(resumed.conflicts, [], 'plus de réconciliation sans grand livre');
  assert.ok(resumed.items.length > 0 && resumed.items.every((i) => i.type === 'auth'));
  const result = await cleanup.executeCleanup({ ...ctx(), expectedHash: resumed.hash, confirm: DELETE() });
  assert.equal(result.clean, true);
  assert.equal(auth.users.size, 0);
});

test('6. exécution complète : Storage supprimé avec précondition, lot supprimé en un lot atomique, rien d’autre touché', options, async () => {
  await setup();
  const inv = await cleanup.collectInventory(ctx());
  const deleted = [];
  const real = bucket.file;
  bucket.file = (p, o) => { const f = real(p, o); return { ...f, delete: async (x) => { deleted.push({ p, o, x }); return f.delete(x); } }; };
  const result = await cleanup.executeCleanup({ ...ctx(), expectedHash: inv.hash, confirm: DELETE() });
  assert.equal(result.clean, true, JSON.stringify(result));
  assert.equal(deleted.length, 1);
  assert.equal(deleted[0].p, SELFIE);
  assert.match(deleted[0].x.ifGenerationMatch, /^\d+$/);
  assert.equal(deleted[0].o.generation, deleted[0].x.ifGenerationMatch);
  assert.equal((await db.doc('orders/hist-1').get()).exists, true);
  assert.equal(JSON.parse(JSON.stringify((await db.doc('clients/real-client').get()).data())).fcmToken, 'PLACEHOLDER-NOT-A-REAL-TOKEN');
});
