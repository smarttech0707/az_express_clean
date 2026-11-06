'use strict';

// Mission 7E-43 — extension du lot : compte « intrus » t7e-intrus. Partie pure (aucun accès réseau).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const intruder = require(path.join(dir, 'intruder'));
const cleanup = require(path.join(dir, 'cleanup'));

const baseManifest = () => ({
  version: 1, lot: lot.LOT_ID, project: { id: lot.TARGET.projectId, number: lot.TARGET.projectNumber }, createdAtMs: 1, status: 'complete',
  identities: Object.fromEntries(Object.values(lot.IDENTITIES).map((i) => [i.role, { uid: i.uid, email: i.email }])),
  authUids: [...lot.UIDS], documents: lot.buildSeedPlan().map((d) => ({ path: d.path, kind: d.kind, hash: lot.docHash(d.data) })),
  baseline: { orderIds: ['h1', 'h2'], counts: {} },
});
const extended = () => ({
  ...baseManifest(), version: 2,
  extensions: [{ id: 'intruder', createdAtMs: 2, status: 'complete', identities: { intruder: { uid: 't7e-intrus', email: 't7e-intrus@example.invalid' } },
    authUids: ['t7e-intrus'], documents: intruder.buildIntruderPlan().map((d) => ({ path: d.path, kind: d.kind, hash: lot.docHash(d.data) })) }],
});

test('identité et document de l’intrus : schéma client minimal, wallet 0, aucun champ sensible', () => {
  assert.deepEqual(intruder.INTRUDER, { role: 'intruder', uid: 't7e-intrus', email: 't7e-intrus@example.invalid', displayName: intruder.INTRUDER.displayName });
  const plan = intruder.buildIntruderPlan();
  assert.equal(plan.length, 1);
  assert.equal(plan[0].path, 'clients/t7e-intrus');
  assert.deepEqual(Object.keys(plan[0].data).sort(), ['email', 'name', 'testLotId', 'wallet']);
  assert.equal(plan[0].data.wallet, 0);
  assert.equal(plan[0].data.testLotId, lot.LOT_ID);
  assert.deepEqual(lot.findSensitiveKeys(plan), []);
  // Champs autorisés par les règles Firestore à la création d'un client (hors marqueur du lot, écrit par Admin SDK).
  for (const k of ['name', 'email', 'wallet']) assert.ok(['name', 'phone', 'email', 'wallet', 'cashOnDeliveryEnabled', 'fakeOrderCount', 'createdAt'].includes(k));
  // L'intrus n'est pas l'un des quatre comptes du lot et reste hors de l'inventaire de base.
  assert.ok(!lot.UIDS.includes('t7e-intrus'));
  assert.equal(lot.buildSeedPlan().length, 7);
  assert.ok(!lot.buildSeedPlan().some((d) => d.path.includes('intrus')));
});

test('DRY-RUN : aucune écriture, aucun réseau ; production, mauvais numéro et dossier dans le dépôt refusés avant toute connexion', async () => {
  const report = intruder.dryRun();
  assert.equal(report.writes, 0);
  assert.equal(report.auth.phone, null);
  assert.equal(report.auth.customClaims, null);
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit'); };
  try {
    const lines = [];
    const base = ['--project', 'az-express-preprod', '--project-number', '306761725053', '--dir', path.join(require('node:os').tmpdir(), 'x')];
    assert.equal(await intruder.main(base, {}, (l) => lines.push(l)), 0);
    assert.match(lines.join('\n'), /DRY-RUN/);
    await assert.rejects(intruder.main(['--project', 'az-express-b0469', '--project-number', '306761725053'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(intruder.main(['--project', 'az-express-preprod', '--project-number', '1'], {}, () => {}), (e) => e.code === 'PROJECT_NUMBER_MISMATCH');
    await assert.rejects(intruder.main([...base, '--execute', '--confirm', 'CREATE t7e-lot-1 az-express-preprod 306761725053'], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED');
    await assert.rejects(intruder.main(['--project', 'az-express-preprod', '--project-number', '306761725053', '--dir', path.join(guardRoot(), 'tmp'), '--execute', '--confirm', 'x'], {}, () => {}), (e) => e.code === 'OUT_DIR_IN_REPO');
    await assert.rejects(intruder.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
  } finally { globalThis.fetch = realFetch; }
});
const guardRoot = () => require(path.join(dir, 'guard')).REPO_ROOT;

test('manifeste de base : exactement 4 comptes et 7 documents ; tout écart ou extension préexistante est refusé', () => {
  assert.doesNotThrow(() => intruder.assertBaseManifest(baseManifest()));
  const mutate = (fn) => { const m = baseManifest(); fn(m); return m; };
  const cases = [
    mutate((m) => { m.lot = 'autre'; }), mutate((m) => { m.project.id = 'az-express-b0469'; }), mutate((m) => { m.status = 'partial'; }),
    mutate((m) => { m.documents.pop(); }), mutate((m) => { m.documents.push({ path: 'clients/real-client' }); }),
    mutate((m) => { m.authUids.push('t7e-intrus'); }), mutate((m) => { m.identities.client.uid = 'real-client'; }),
    mutate((m) => { m.baseline = null; }), extended(),
  ];
  for (const m of cases) assert.throws(() => intruder.assertBaseManifest(m), (e) => e.code === 'MANIFEST_INVALID');
});

test('nettoyage : manifeste étendu accepté ; extension inconnue, compte ou document hors plan refusés', () => {
  assert.doesNotThrow(() => cleanup.validateManifest(extended()));
  assert.doesNotThrow(() => cleanup.validateManifest(baseManifest()), 'manifeste de base (sans extension) toujours valide');
  const mutate = (fn) => { const m = extended(); fn(m.extensions[0]); return m; };
  for (const m of [
    mutate((e) => { e.id = 'autre'; }), mutate((e) => { e.identities.intruder.uid = 'real-client'; }), mutate((e) => { e.identities.intruder.email = 'x@example.org'; }),
    mutate((e) => { e.authUids.push('real-client'); }), mutate((e) => { e.documents.push({ path: 'clients/real-client' }); }),
    mutate((e) => { e.documents[0].path = 'orders/hist-1'; }),
  ]) assert.throws(() => cleanup.validateManifest(m), (e) => e.code === 'MANIFEST_INVALID');
});

test('liste blanche de suppression : le document de l’intrus seulement, jamais d’autres clients ni ses sous-collections', () => {
  assert.equal(cleanup.pathAllowed('clients/t7e-intrus'), true);
  for (const p of ['clients/t7e-intrus/wallet_transactions/x', 'clients/real-client', 'clients/t7e-intrus2', 'clients/t7e-intrus/', 'livreurs/t7e-intrus']) assert.equal(cleanup.pathAllowed(p), false, p);
});
