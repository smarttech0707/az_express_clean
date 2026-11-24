'use strict';

// Mission 7E-47 — inventaire et suppression Storage SANS storage.objects.get, réconciliation financière. Partie pure (aucun réseau).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const storage = require(path.join(dir, 'storageInventory'));
const finance = require(path.join(dir, 'financialReport'));
const cleanup = require(path.join(dir, 'cleanup'));

const OID = 'a3d800b1-8790-46c6-811e-89bf5c056ce2';
const NAME = `acceptance_selfies/${OID}/t7e-driver.jpg`;
const BUCKET = lot.TARGET.storageBucket;
const GEN = '1793936103492821';

// Bucket fidèle au compte CLI : list/delete seulement ; exists()/getMetadata() (storage.objects.get) → 403 comme en préproduction.
function fakeBucket(initial, { name = BUCKET } = {}) {
  const objects = new Map(initial.map((o) => [o.name, { bucket: BUCKET, generation: GEN, size: '1976', contentType: 'image/jpeg', md5Hash: 'x', ...o }]));
  const calls = { list: [], del: [], get: 0 };
  const deny = async () => { calls.get += 1; throw Object.assign(new Error('403 storage.objects.get denied'), { code: 403 }); };
  return {
    name, objects, calls,
    getFiles: async (opts) => { calls.list.push(opts); return [[...objects.values()].filter((o) => o.name.startsWith(opts.prefix || '')).map((o) => ({ name: o.name, metadata: { ...o, name: o.metadata_name || o.name } }))]; },
    file: (n, fopts = {}) => ({
      exists: deny, getMetadata: deny,
      delete: async (o = {}) => {
        calls.del.push({ name: n, fopts, o });
        const cur = objects.get(n);
        if (!cur) throw Object.assign(new Error('404'), { code: 404 });
        if ((fopts.generation && fopts.generation !== cur.generation) || (o.ifGenerationMatch && o.ifGenerationMatch !== cur.generation)) throw Object.assign(new Error('412'), { code: 412 });
        objects.delete(n);
      },
    }),
  };
}
const obj = (over = {}) => ({ name: NAME, ...over });

test('listing sans get : métadonnées complètes (bucket, nom exact, génération, taille, type) ; aucun appel get', async () => {
  const bucket = fakeBucket([obj()]);
  const r = await storage.inventoryObject({ bucket, name: NAME, orderIds: [OID] });
  assert.deepEqual(r.item, { type: 'storage', path: NAME, bucket: BUCKET, generation: GEN, size: 1976, md5Hash: 'x', group: 'storage' });
  assert.equal(bucket.calls.get, 0);
  assert.equal(bucket.calls.list.length, 1);
  assert.deepEqual(bucket.calls.list[0], { prefix: NAME, versions: true, autoPaginate: false, maxResults: 20 });
  const all = await storage.inventoryOrders({ bucket, orderIds: [OID] });
  assert.deepEqual([all.items.length, all.conflicts.length], [1, 0]);
  assert.equal(bucket.calls.get, 0, 'jamais storage.objects.get');
});

test('objet absent ; mauvais bucket ; chemin hors liste blanche ; commande hors lot ; identifiant invalide', async () => {
  assert.deepEqual(await storage.inventoryObject({ bucket: fakeBucket([]), name: NAME, orderIds: [OID] }), { absent: true });
  await assert.rejects(storage.inventoryObject({ bucket: fakeBucket([obj()], { name: 'autre-bucket' }), name: NAME, orderIds: [OID] }), (e) => e.code === 'WRONG_BUCKET');
  await assert.rejects(storage.inventoryObject({ bucket: fakeBucket([obj()], { name: 'az-express-b0469.firebasestorage.app' }), name: NAME, orderIds: [OID] }), (e) => e.code === 'WRONG_BUCKET');
  for (const bad of ['acceptance_selfies/x/other.jpg', `acceptance_selfies/${OID}/t7e-driver.png`, `acceptance_selfies/${OID}/../t7e-driver.jpg`, 'delivery_photos/real-driver/x.jpg', `acceptance_selfies/${OID}/`, 'acceptance_selfies/']) {
    await assert.rejects(storage.inventoryObject({ bucket: fakeBucket([obj({ name: bad })]), name: bad, orderIds: [OID] }), (e) => e.code === 'PATH_NOT_ALLOWED', bad);
  }
  await assert.rejects(storage.inventoryObject({ bucket: fakeBucket([obj()]), name: NAME, orderIds: ['hist-1'] }), (e) => e.code === 'PATH_NOT_ALLOWED', 'commande non listée dans le lot');
  assert.throws(() => storage.candidateNames('a/b'), (e) => e.code === 'BAD_ORDER_ID');
  assert.deepEqual(storage.candidateNames(OID), [NAME, `delivery_photos/t7e-driver/${OID}.jpg`]);
});

test('collision et ambiguïté : objet voisin partageant le préfixe, plusieurs générations, métadonnées incohérentes → conflit, jamais de suppression', async () => {
  const cases = [
    [[obj(), { name: `${NAME}.bak` }], /voisins/],
    [[obj({ bucket: 'autre-bucket' })], /bucket/],
    [[obj({ metadata_name: 'acceptance_selfies/autre/t7e-driver.jpg' })], /nom/],
    [[obj({ generation: 'abc' })], /génération/],
    [[obj({ size: '0' })], /taille/],
    [[obj({ size: String(6 * 1024 * 1024) })], /taille/],
    [[obj({ contentType: 'text/plain' })], /type/],
    [[obj({ timeDeleted: '2026-11-06T00:00:00Z' })], /non courante/],
  ];
  for (const [objects, why] of cases) {
    const bucket = fakeBucket(objects);
    const r = await storage.inventoryObject({ bucket, name: NAME, orderIds: [OID] });
    assert.ok(r.conflicts && !r.item, JSON.stringify(r));
    assert.match(r.conflicts.map((c) => c.reason).join(';'), why);
  }
  // Deux versions du même nom : le fake ne les expose pas toutes (Map) → simulé par un listing qui renvoie deux entrées.
  const twice = fakeBucket([obj()]);
  twice.getFiles = async () => [[{ name: NAME, metadata: { bucket: BUCKET, name: NAME, generation: '1', size: '10', contentType: 'image/jpeg' } }, { name: NAME, metadata: { bucket: BUCKET, name: NAME, generation: '2', size: '10', contentType: 'image/jpeg' } }]];
  assert.match((await storage.inventoryObject({ bucket: twice, name: NAME, orderIds: [OID] })).conflicts[0].reason, /ambiguë/);
});

test('suppression : génération vérifiée puis supprimée avec précondition ; objet remplacé, précondition refusée, absent, voisin → refus', async () => {
  const item = (await storage.inventoryObject({ bucket: fakeBucket([obj()]), name: NAME, orderIds: [OID] })).item;
  // Cas nominal : un seul appel de suppression, pour CETTE génération, jamais par préfixe.
  let bucket = fakeBucket([obj(), obj({ name: 'acceptance_selfies/autre/t7e-driver.jpg' })]);
  assert.deepEqual(await storage.deleteObject({ bucket, item, orderIds: [OID] }), { deleted: true });
  assert.deepEqual(bucket.calls.del, [{ name: NAME, fopts: { generation: GEN }, o: { ifGenerationMatch: GEN } }]);
  assert.deepEqual([...bucket.objects.keys()], ['acceptance_selfies/autre/t7e-driver.jpg'], 'objet voisin intact');
  assert.equal(bucket.calls.get, 0);
  // Remplacé entre inventaire et suppression (nouvelle génération) : refus, rien supprimé.
  bucket = fakeBucket([obj({ generation: '1793936999999999' })]);
  await assert.rejects(storage.deleteObject({ bucket, item, orderIds: [OID] }), (e) => e.code === 'OBJECT_REPLACED');
  assert.equal(bucket.calls.del.length, 0);
  // Remplacé APRÈS la relecture (course) : le serveur refuse la précondition (412).
  bucket = fakeBucket([obj()]);
  const list = bucket.getFiles;
  bucket.getFiles = async (o) => { const r = await list(o); bucket.objects.get(NAME).generation = '777'; return r; };
  await assert.rejects(storage.deleteObject({ bucket, item, orderIds: [OID] }), (e) => e.code === 'OBJECT_REPLACED');
  assert.ok(bucket.objects.has(NAME), 'objet remplacé conservé');
  // Absent (reprise) : sans erreur ; voisin ou collision : conflit.
  assert.deepEqual(await storage.deleteObject({ bucket: fakeBucket([]), item, orderIds: [OID] }), { deleted: false, alreadyAbsent: true });
  bucket = fakeBucket([obj(), { name: `${NAME}.bak` }]);
  await assert.rejects(storage.deleteObject({ bucket, item, orderIds: [OID] }), (e) => e.code === 'CONFLICTS');
  assert.equal(bucket.calls.del.length, 0);
  // Mauvais bucket dans l'élément, mauvais bucket réel.
  await assert.rejects(storage.deleteObject({ bucket: fakeBucket([obj()]), item: { ...item, bucket: 'autre' }, orderIds: [OID] }), (e) => e.code === 'WRONG_BUCKET');
  await assert.rejects(storage.deleteObject({ bucket: fakeBucket([obj()], { name: 'autre' }), item, orderIds: [OID] }), (e) => e.code === 'WRONG_BUCKET');
});

test('empreinte de l’inventaire : un objet remplacé (autre génération) change l’empreinte', () => {
  const a = lot.sha256(lot.canonical([`storage:${NAME}@${GEN}`]));
  const b = lot.sha256(lot.canonical([`storage:${NAME}@999`]));
  assert.notEqual(a, b);
});

const day = () => ({
  orders: { o1: { status: 'delivered', clientId: 't7e-client', sellerId: 't7e-resto', driverId: 't7e-driver', paymentMethod: 'wallet', isPaid: true, productAmount: 6500, deliveryFee: 500, totalAmount: 7000, commissionAmount: 100, type: 'restaurant', tariffQuoteId: 'q1' } },
  quotes: [{ id: 'q1', status: 'used', orderId: 'o1', amount: 7000 }, { id: 'q0', status: 'open', amount: 7000 }],
  commissions: [{ id: 'c1', orderId: 'o1', amount: 100 }],
  txs: {
    client: [{ id: 'order_o1', type: 'payment', amount: 7000, orderId: 'o1' }],
    driver: [{ id: 'commission_o1', type: 'commission', amount: 100, orderId: 'o1' }, { id: 'earning_o1', type: 'earning', amount: 500, orderId: 'o1' }],
    restaurant: [{ id: 'earning_o1', type: 'earning', amount: 6500, orderId: 'o1' }], intruder: [],
  },
  wallets: { client: 33000, driver: 5400, restaurant: 6500, intruder: 0 }, walletDocs: { client: true, driver: true, restaurant: true, intruder: true },
  proofs: ['pickup', 'delivery'].map((type) => ({ id: type, session: { orderId: 'o1', type, generationCount: 1 }, versions: [{ status: 'used', validatedAt: { toMillis: () => 1 }, pinHash: 'SECRET-PIN-HASH', tokenHash: 'SECRET-TOKEN-HASH', validationMethod: 'pin' }] })),
  audit: [{ action: 'deliver_order', userId: 't7e-driver', targetId: 'o1', metadata: { orderId: 'o1' } }],
});

test('réconciliation : jour et nuit cohérents ; chaque écart (wallet, commission, écriture, devis, preuve, statut, intrus) est signalé', () => {
  assert.deepEqual(finance.reconcile(day()), { coherent: true, problems: [], expectedWallets: { client: 33000, driver: 5400, restaurant: 6500, intruder: 0 } });
  const night = day();
  Object.assign(night.orders.o1, { deliveryFee: 1000, totalAmount: 7500, commissionAmount: 200 });
  night.quotes[0].amount = 7500; night.commissions[0].amount = 200;
  night.txs.client[0].amount = 7500; night.txs.driver[0].amount = 200; night.txs.driver[1].amount = 1000;
  Object.assign(night.wallets, { client: 32500, driver: 5800 });
  assert.equal(finance.reconcile(night).coherent, true);
  const broken = (fn, why) => { const d = day(); fn(d); const r = finance.reconcile(d); assert.equal(r.coherent, false); assert.match(r.problems.join(';'), why); };
  broken((d) => { d.wallets.client = 33001; }, /solde client/);
  broken((d) => { d.wallets.restaurant = 0; }, /solde restaurant/);
  broken((d) => { d.commissions.push({ id: 'c2', orderId: 'o1', amount: 100 }); }, /2 commission/);
  broken((d) => { d.txs.client.push({ id: 'dup', type: 'payment', amount: 7000, orderId: 'o1' }); d.wallets.client = 26000; }, /2 écriture/);
  broken((d) => { d.txs.driver[0].amount = 150; }, /commission/);
  broken((d) => { d.txs.client.push({ id: 'x', type: 'mystery', amount: 1, orderId: 'o1' }); }, /inconnue/);
  broken((d) => { d.txs.client.push({ id: 'y', type: 'payment', amount: 1, orderId: 'autre' }); }, /sans commande du lot/);
  broken((d) => { d.quotes[0].amount = 6000; }, /devis/);
  broken((d) => { d.quotes[0].status = 'open'; }, /devis utilisé/);
  broken((d) => { d.proofs.pop(); }, /preuve delivery absente/);
  broken((d) => { d.proofs[0].versions = [{ status: 'open' }]; }, /non validée/);
  broken((d) => { d.orders.o1.status = 'picked_up'; }, /statut/);
  broken((d) => { d.orders.o1.totalAmount = 7001; }, /total/);
  broken((d) => { d.orders.o1.driverId = 'real-driver'; }, /acteurs hors lot/);
  broken((d) => { d.txs.intruder.push({ id: 'z', type: 'payment', amount: 5, orderId: 'o1' }); }, /intrus|intruder/);
  // Commande annulée avec remboursement : contrôle par la somme des écritures.
  const cancelled = day();
  cancelled.orders.o1.status = 'cancelled';
  cancelled.txs.client.push({ id: 'refund_o1', type: 'refund', amount: 7000, orderId: 'o1' });
  cancelled.txs.driver = []; cancelled.txs.restaurant = [];
  Object.assign(cancelled.wallets, { client: 40000, driver: 5000, restaurant: 0 });
  assert.equal(finance.reconcile(cancelled).coherent, true);
});

test('rapport local : montants, quatre mouvements, soldes avant/après, preuves ; aucun PIN, jeton ni empreinte', () => {
  const report = finance.buildReport(day(), { project: 'az-express-preprod', generatedAtMs: 1793936000000 });
  assert.equal(report.coherent, true);
  assert.deepEqual(report.orders[0].amounts, { productAmount: 6500, deliveryFee: 500, totalAmount: 7000, commissionAmount: 100 });
  assert.deepEqual(report.wallets.before, { client: 40000, driver: 5000, restaurant: 0, intruder: 0 });
  assert.deepEqual(report.wallets.after, { client: 33000, driver: 5400, restaurant: 6500, intruder: 0 });
  assert.equal(Object.values(report.walletTransactions).flat().length, 4);
  assert.equal(report.deliveryProofs.length, 2);
  assert.equal(report.quotes.length, 2);
  const text = JSON.stringify(report);
  assert.ok(!/SECRET|pinHash|tokenHash|eyJ/.test(text), 'aucun secret dans le rapport');
  assert.equal(report.idempotence.replaysNotRunInCloud, true);
});

test('CLI du nettoyage : production, mauvais numéro, manifeste corrompu, exécution sans confirmation ni empreinte refusés avant toute connexion', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit'); };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-clean-'));
  const write = (name, v) => { const f = path.join(tmp, name); fs.writeFileSync(f, typeof v === 'string' ? v : JSON.stringify(v)); return f; };
  const base = ['--project', 'az-express-preprod', '--project-number', '306761725053'];
  try {
    await assert.rejects(cleanup.main(['--project', 'az-express-b0469', '--project-number', '306761725053', '--manifest', 'x'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(cleanup.main(['--project', 'az-express-clean', '--project-number', '306761725053', '--manifest', 'x'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(cleanup.main(['--project', 'az-express-preprod', '--project-number', '1', '--manifest', 'x'], {}, () => {}), (e) => e.code === 'PROJECT_NUMBER_MISMATCH');
    await assert.rejects(cleanup.main(base, {}, () => {}), (e) => e.code === 'MANIFEST_REQUIRED');
    await assert.rejects(cleanup.main([...base, '--manifest', write('bad.json', '{ pas du json')], {}, () => {}));
    for (const m of [{}, { lot: 'autre' }, { lot: lot.LOT_ID, project: { id: 'az-express-b0469', number: '1' } }, { lot: lot.LOT_ID, project: { id: lot.TARGET.projectId, number: lot.TARGET.projectNumber }, identities: {} }]) {
      await assert.rejects(cleanup.main([...base, '--manifest', write('m.json', m)], {}, () => {}), (e) => e.code === 'MANIFEST_INVALID');
    }
    const good = write('ok.json', { lot: lot.LOT_ID });
    await assert.rejects(cleanup.main([...base, '--manifest', good, '--execute', '--confirm', 'DELETE'], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED' || e.code === 'MANIFEST_INVALID');
    await assert.rejects(cleanup.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
    await assert.rejects(cleanup.main([...base, '--manifest', good, '--report-dir', path.join(require(path.join(dir, 'guard')).REPO_ROOT, 'tmp')], {}, () => {}), (e) => ['OUT_DIR_IN_REPO', 'MANIFEST_INVALID'].includes(e.code));
  } finally { globalThis.fetch = realFetch; fs.rmSync(tmp, { recursive: true, force: true }); }
});
