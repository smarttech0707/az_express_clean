'use strict';

// Mission 7E-36 — scripts du lot de test Restaurant v2 (scripts/restaurant-v2-pilot). Aucun accès Firebase : tout est local.
// Les parties qui lisent/écrivent Firestore sont dans restaurantV2Pilot.emulator.test.js (émulateur, projet demo-*).
const test = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');

const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const guard = require(path.join(dir, 'guard'));
const prepare = require(path.join(dir, 'prepare'));
const cleanup = require(path.join(dir, 'cleanup'));
const { partnerRefusal, partnerPoint, parseItems, priceItems } = require('../partnerCatalog');
const { creationRefusal, parsePilotConfig, validateConfigChange } = require('../partnerOrdersConfig');
const { buildPartnerAmounts } = require('../partnerOrderAmounts');
const { calculateCommission } = require('../dispatch');

const clean = { /* environnement sans aucune variable de projet */ };
const throwsCode = (fn, code) => assert.throws(fn, (e) => e.code === code, `code ${code} attendu`);
const rejectsCode = (p, code) => assert.rejects(p, (e) => e.code === code, `code ${code} attendu`);
// Faux Firestore/Auth qui échouent à TOUT accès : prouve qu'un chemin de code n'touche jamais au cloud.
const forbidden = new Proxy({}, { get: (_, k) => { throw new Error(`accès interdit (${String(k)})`); } });

// ── Garde : la production n'est jamais atteignable ───────────────────────────────────────────────────────────────────────────
test('production et ancien identifiant refusés, quel que soit le numéro', () => {
  for (const projectId of ['az-express-b0469', 'az-express-clean']) {
    throwsCode(() => guard.assertTarget({ projectId, projectNumber: lot.TARGET.projectNumber, env: clean }), 'PRODUCTION_FORBIDDEN');
  }
});

test('une variable d’environnement qui désigne la production bloque même une cible valide', () => {
  for (const env of [{ GCLOUD_PROJECT: 'az-express-b0469' }, { GOOGLE_CLOUD_PROJECT: 'az-express-b0469' },
    { FIREBASE_CONFIG: JSON.stringify({ projectId: 'az-express-b0469' }) }]) {
    throwsCode(() => guard.assertTarget({ projectId: lot.TARGET.projectId, projectNumber: lot.TARGET.projectNumber, env }), 'PRODUCTION_FORBIDDEN');
  }
  throwsCode(() => guard.assertTarget({ projectId: lot.TARGET.projectId, projectNumber: lot.TARGET.projectNumber, env: { GCLOUD_PROJECT: 'autre-projet' } }), 'ENV_MISMATCH');
});

test('seule la préproduction avec le bon numéro est acceptée', () => {
  assert.deepEqual(guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '306761725053', env: clean }), { mode: 'preprod', projectId: 'az-express-preprod' });
  throwsCode(() => guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '123', env: clean }), 'PROJECT_NUMBER_MISMATCH');
  throwsCode(() => guard.assertTarget({ projectId: 'az-express-preprod', env: clean }), 'PROJECT_NUMBER_MISMATCH');
  throwsCode(() => guard.assertTarget({ projectId: 'un-autre-projet', projectNumber: '306761725053', env: clean }), 'PROJECT_NOT_ALLOWED');
  throwsCode(() => guard.assertTarget({ env: clean }), 'PROJECT_REQUIRED');
});

test('émulateur : projet demo-* seulement avec l’hôte d’émulateur ; jamais mélangé à un projet réel', () => {
  throwsCode(() => guard.assertTarget({ projectId: 'demo-x', env: clean }), 'EMULATOR_REQUIRED');
  assert.equal(guard.assertTarget({ projectId: 'demo-x', env: { FIRESTORE_EMULATOR_HOST: 'localhost:8987' } }).mode, 'emulator');
  throwsCode(() => guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '306761725053', env: { FIRESTORE_EMULATOR_HOST: 'localhost:8987' } }), 'EMULATOR_ENV_WITH_REAL_PROJECT');
});

test('numéro de projet vérifié en ligne (lecture seule) : un autre numéro est refusé', async () => {
  const urls = [];
  const ok = await guard.verifyProjectNumberOnline({ projectId: 'az-express-preprod', fetchJson: async (u) => { urls.push(u); return { name: 'projects/306761725053' }; } });
  assert.equal(ok, '306761725053');
  assert.match(urls[0], /cloudresourcemanager\.googleapis\.com\/v3\/projects\/az-express-preprod$/);
  await rejectsCode(guard.verifyProjectNumberOnline({ projectId: 'az-express-preprod', fetchJson: async () => ({ name: 'projects/999' }) }), 'PROJECT_NUMBER_MISMATCH');
});

test('identifiants générés : dossier de sortie hors du dépôt obligatoire ; confirmation exacte obligatoire', () => {
  throwsCode(() => guard.assertOutDirOutsideRepo(path.join(guard.REPO_ROOT, 'tmp')), 'OUT_DIR_IN_REPO');
  throwsCode(() => guard.assertOutDirOutsideRepo(guard.REPO_ROOT), 'OUT_DIR_IN_REPO');
  throwsCode(() => guard.assertOutDirOutsideRepo(undefined), 'OUT_DIR_REQUIRED');
  assert.ok(guard.assertOutDirOutsideRepo(path.join(os.tmpdir(), 't7e')).startsWith(path.resolve(os.tmpdir())));
  assert.equal(guard.confirmationFor('CREATE'), 'CREATE t7e-lot-1 az-express-preprod 306761725053');
  throwsCode(() => guard.assertConfirmation('CREATE', 'CREATE'), 'CONFIRMATION_REQUIRED');
  throwsCode(() => guard.assertConfirmation('DELETE t7e-lot-1 az-express-preprod 306761725053', 'CREATE'), 'CONFIRMATION_REQUIRED');
  guard.assertConfirmation('CREATE t7e-lot-1 az-express-preprod 306761725053', 'CREATE');
});

// ── Identités et documents ────────────────────────────────────────────────────────────────────────────────────────────────
test('quatre identités fictives : uid t7e-, e-mail @example.invalid, aucun téléphone', () => {
  const ids = Object.values(lot.IDENTITIES);
  assert.equal(ids.length, 4);
  assert.deepEqual(ids.map((i) => i.role).sort(), ['admin', 'client', 'driver', 'restaurant']);
  for (const i of ids) {
    assert.match(i.uid, /^t7e-[a-z]+$/);
    assert.equal(i.email, `${i.uid}@example.invalid`);
  }
  assert.equal(new Set(ids.map((i) => i.uid)).size, 4);
});

test('plan de départ : marqueur du lot partout, aucun champ sensible, aucun jeton FCM, aucun téléphone', () => {
  const plan = lot.buildSeedPlan();
  assert.deepEqual(lot.findSensitiveKeys(plan), []);
  assert.equal(new Set(plan.map((d) => d.path)).size, plan.length);
  for (const d of plan) assert.equal(d.data[lot.LOT_FIELD], lot.LOT_ID, d.path);
  const everything = JSON.stringify(plan);
  assert.ok(!/fcm|phone|password|token/i.test(everything.replace(/testLotId/g, '')));
  for (const email of everything.match(/[\w.+-]+@[\w.-]+/g) || []) assert.ok(email.endsWith('@example.invalid'), email);
  // Un jeton ou un numéro injecté est détecté.
  assert.deepEqual(lot.findSensitiveKeys([{ path: 'clients/x', data: { fcmToken: 'x' } }, { path: 'clients/y', data: { phone: '1' } }]), ['clients/x:fcmToken', 'clients/y:phone']);
});

test('les ressources du plan appartiennent toutes aux quatre comptes du lot (aucune écriture ailleurs)', () => {
  const allowed = [
    /^clients\/t7e-client$/, /^restaurants\/t7e-resto(\/menu\/t7e-plat-[ab])?$/, /^restaurant_owners\/t7e-resto$/,
    /^livreurs\/t7e-driver$/, /^admins\/t7e-admin$/,
  ];
  for (const { path: p } of lot.buildSeedPlan()) assert.ok(allowed.some((re) => re.test(p)), p);
});

test('schémas conformes aux consommateurs réels (catalogue, tarif, administrateur, client)', () => {
  const plan = Object.fromEntries(lot.buildSeedPlan().map((d) => [d.path, d.data]));
  const resto = plan['restaurants/t7e-resto'];
  assert.equal(partnerRefusal('restaurant', resto, Date.now()), null, 'le restaurant peut recevoir une commande à toute heure (pas de plage horaire)');
  assert.deepEqual(partnerPoint(resto), lot.RESTAURANT_POINT);
  const menu = new Map(lot.MENU.map((m) => [m.id, plan[`restaurants/t7e-resto/menu/${m.id}`]]));
  const { productAmount, lines } = priceItems('restaurant', parseItems(lot.BASKET), menu);
  assert.equal(productAmount, 6500);
  assert.deepEqual(lines.map((l) => l.subtotal), [5000, 1500]);
  const admin = plan['admins/t7e-admin'];
  assert.ok(admin.isActive === true && ['super', 'sub'].includes(admin.role) && admin.role === 'super', 'admin valide au sens de adminGuards.readValidAdmin');
  assert.equal(plan['restaurant_owners/t7e-resto'].restaurantId, 't7e-resto', 'authorizePickupIssuer : restaurant_owners/<uid>.restaurantId == sellerId');
  const client = plan['clients/t7e-client'];
  assert.ok(Number.isSafeInteger(client.wallet) && client.wallet >= 0 && !client.deletionRequested && !client.isDeleted);
});

test('livreur éligible au sens de dispatch.js et driverAcceptance.js (champs, GPS frais, solde ≥ commission)', () => {
  const d = lot.buildSeedPlan().find((x) => x.path === 'livreurs/t7e-driver').data;
  assert.equal(d.isOnline, true);
  assert.notEqual(d.isOnDelivery, true);
  assert.notEqual(d.isAvailable, false);
  assert.notEqual(d.isSuspended, true);
  assert.ok(d.lat && d.lng && d.currentCityId === lot.CITY_ID);
  assert.deepEqual(d.updatedAt, lot.SERVER_TIMESTAMP, 'GPS horodaté par le serveur à l’écriture (moins de 3 minutes au dispatch)');
  assert.ok(d.wallet >= 200, 'couvre la commission maximale (200)');
});

// ── Montants (calculés par les modules réels) ─────────────────────────────────────────────────────────────────────────────
test('montants attendus : jour 500 FCFA / nuit 1000 FCFA, commission 100 / 200', () => {
  const day = lot.expectedAmounts({ nowMs: Date.UTC(2026, 10, 6, 10) });
  const night = lot.expectedAmounts({ nowMs: Date.UTC(2026, 10, 6, 23) });
  assert.deepEqual([day.productAmount, day.deliveryFee, day.totalAmount, day.commission], [6500, 500, 7000, 100]);
  assert.deepEqual([night.productAmount, night.deliveryFee, night.totalAmount, night.commission], [6500, 1000, 7500, 200]);
  assert.deepEqual(day, { ...buildPartnerAmounts(6500, 500), commission: 100 });
});

test('la commission du plan est celle de la fonction réelle (config/commission absente)', async () => {
  const noConfig = { collection: () => ({ doc: () => ({ get: async () => ({ exists: false }) }) }) };
  for (const budget of [1, 500, 999, 1000, 1500, 7000]) {
    assert.equal(lot.commissionFor(budget), await calculateCommission(noConfig, budget), `budget ${budget}`);
  }
});

test('soldes attendus : débit client, commission unique, crédits restaurant et livreur, conservation', () => {
  for (const hour of [10, 23]) {
    const a = lot.expectedAmounts({ nowMs: Date.UTC(2026, 10, 6, hour) });
    const l = lot.expectedLedger(a);
    assert.equal(l.start.client - l.afterCreate.client, a.totalAmount, 'débit client à la création');
    assert.equal(l.afterAccept.driver, lot.WALLETS.driver - a.commission, 'commission prélevée une seule fois');
    assert.equal(l.afterDelivery.restaurant, a.productAmount, 'restaurant : produits seulement');
    assert.equal(l.afterDelivery.driver, lot.WALLETS.driver - a.commission + a.deliveryFee, 'livreur : frais moins commission');
    const sum = (w) => w.client + w.driver + w.restaurant;
    assert.equal(sum(l.start) - sum(l.afterDelivery), a.commission, 'seule la commission quitte les wallets');
    for (const stage of Object.values(l)) for (const v of Object.values(stage)) assert.ok(Number.isSafeInteger(v) && v >= 0);
  }
});

// ── Pilote ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
test('configuration du pilote : acceptée par la validation réelle, limitée au seul restaurant du lot, jamais écrite', () => {
  const plan = lot.pilotConfigPlan();
  assert.doesNotThrow(() => validateConfigChange(plan.request));
  assert.deepEqual(plan.request.patch.pilotPartnerIds, ['t7e-resto']);
  assert.equal(plan.request.expectedVersion, 0);
  assert.equal(lot.buildInventory().pilotConfig.written, false);
  // Une demande qui désignerait un autre partenaire, ou plusieurs, ne correspond pas au plan.
  assert.deepEqual(plan.expectedDocument.pilotPartnerIds, ['t7e-resto']);
});

test('porte de création : fermée sans configuration, ouverte pour le seul restaurant du lot une fois configurée', () => {
  const absent = parsePilotConfig(null);
  assert.equal(creationRefusal(absent, 't7e-resto').code, 'PARTNER_NOT_IN_PILOT', 'document absent = fermé');
  const open = parsePilotConfig(lot.pilotConfigPlan().expectedDocument);
  assert.equal(creationRefusal(open, 't7e-resto', 't7e-client'), null);
  for (const other of ['pr1', 'real-restaurant', 't7e-client']) assert.equal(creationRefusal(open, other, 't7e-client').code, 'PARTNER_NOT_IN_PILOT', other);
  // Isolation des clients (Mission 7E-41) : seul le client fictif passe, tout autre uid est refusé.
  for (const other of ['real-client', 't7e-resto', '', undefined, null]) assert.equal(creationRefusal(open, 't7e-resto', other).code, 'CLIENT_NOT_IN_PILOT', String(other));
  assert.equal(creationRefusal(open, 't7e-resto').code, 'CLIENT_NOT_IN_PILOT', 'uid absent = refus');
  const closing = parsePilotConfig({ ...lot.pilotConfigPlan().expectedDocument, ...lot.pilotConfigPlan().closing.patch });
  assert.equal(creationRefusal(closing, 't7e-resto', 't7e-client').code, 'CREATION_CLOSED', 'fermeture : creationOpen=false, liste inchangée');
  assert.equal(creationRefusal(parsePilotConfig({ pilotPartnerIds: ['t7e-resto'], creationOpen: false }), 't7e-resto').code, 'CREATION_CLOSED');
});

// ── Scripts : DRY-RUN, refus, aucune écriture ─────────────────────────────────────────────────────────────────────────────
test('prepare en DRY-RUN : inventaire complet, zéro écriture, aucun accès Firestore/Auth', () => {
  const report = prepare.dryRun();
  assert.equal(report.mode, 'dry-run');
  assert.equal(report.writes, 0);
  assert.equal(report.inventory.authUsers.length, 4);
  assert.equal(report.inventory.documents.length, lot.buildSeedPlan().length);
  assert.ok(report.inventory.authUsers.every((u) => !/^[A-Za-z0-9_-]{20,}$/.test(u.password)), 'aucun mot de passe dans l’inventaire');
  assert.ok(report.inventory.dynamicAtTestTime.some((l) => l.includes('acceptance_selfies')), 'selfie d’acceptation inventorié');
});

test('prepare : arguments inconnus, projet de production et mauvais numéro refusés avant toute connexion', async () => {
  const logs = [];
  const log = (s) => logs.push(s);
  await rejectsCode(prepare.main(['--project', 'az-express-b0469', '--project-number', '306761725053'], clean, log), 'PRODUCTION_FORBIDDEN');
  await rejectsCode(prepare.main(['--project', 'az-express-preprod', '--project-number', '1'], clean, log), 'PROJECT_NUMBER_MISMATCH');
  await rejectsCode(prepare.main(['--project', 'az-express-preprod', '--project-number', '306761725053', '--force'], clean, log), 'BAD_ARGUMENT');
  // Sans --execute : DRY-RUN pur, retourne 0 sans connexion.
  assert.equal(await prepare.main(['--project', 'az-express-preprod', '--project-number', '306761725053'], clean, log), 0);
  assert.ok(logs.some((l) => String(l).includes('DRY-RUN')));
});

test('prepare --execute : confirmation et dossier hors dépôt exigés avant toute connexion', async () => {
  const base = ['--project', 'az-express-preprod', '--project-number', '306761725053', '--execute'];
  await rejectsCode(prepare.main(base, clean, () => {}), 'CONFIRMATION_REQUIRED');
  await rejectsCode(prepare.main([...base, '--confirm', 'oui'], clean, () => {}), 'CONFIRMATION_REQUIRED');
  await rejectsCode(prepare.main([...base, '--confirm', guard.confirmationFor('CREATE')], clean, () => {}), 'OUT_DIR_REQUIRED');
  await rejectsCode(prepare.main([...base, '--confirm', guard.confirmationFor('CREATE'), '--out', path.join(guard.REPO_ROOT, 'creds')], clean, () => {}), 'OUT_DIR_IN_REPO');
  await rejectsCode(prepare.main(['--project', 'az-express-preprod', '--project-number', '306761725053', '--refresh-driver-gps'], clean, () => {}), 'CONFIRMATION_REQUIRED');
});

test('prepare refuse un plan contenant un champ sensible, avant tout accès', async () => {
  const plan = lot.buildSeedPlan();
  plan[0].data.fcmToken = 'jeton';
  await rejectsCode(prepare.executePrepare({ admin: forbidden, db: forbidden, auth: forbidden, plan, outDir: path.join(os.tmpdir(), 't7e-x') }), 'SENSITIVE_FIELD');
});

test('cleanup : refus avant connexion (production, manifeste absent, confirmation, empreinte)', async () => {
  const fs = require('node:fs');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-m-'));
  const manifest = path.join(tmp, 'manifest.json');
  const good = {
    version: 1, lot: lot.LOT_ID, project: { id: 'az-express-preprod', number: '306761725053' }, status: 'complete',
    identities: Object.fromEntries(Object.values(lot.IDENTITIES).map((i) => [i.role, { uid: i.uid, email: i.email }])),
    documents: lot.buildSeedPlan().map((d) => ({ path: d.path })), baseline: { orderIds: [], counts: {} },
  };
  fs.writeFileSync(manifest, JSON.stringify(good));
  const base = ['--project', 'az-express-preprod', '--project-number', '306761725053'];
  await rejectsCode(cleanup.main(['--project', 'az-express-b0469', '--project-number', '306761725053', '--manifest', manifest], clean, () => {}), 'PRODUCTION_FORBIDDEN');
  await rejectsCode(cleanup.main(base, clean, () => {}), 'MANIFEST_REQUIRED');
  await rejectsCode(cleanup.main([...base, '--manifest', manifest, '--execute'], clean, () => {}), 'CONFIRMATION_REQUIRED');
  await rejectsCode(cleanup.main([...base, '--manifest', manifest, '--execute', '--confirm', guard.confirmationFor('DELETE')], clean, () => {}), 'HASH_REQUIRED');
  await rejectsCode(cleanup.main([...base, '--manifest', manifest, '--execute', '--confirm', guard.confirmationFor('CREATE'), '--inventory-hash', 'x'], clean, () => {}), 'CONFIRMATION_REQUIRED');
});

test('manifeste falsifié refusé : mauvais lot, projet, identité, document hors plan, instantané absent', () => {
  const good = () => ({
    lot: lot.LOT_ID, project: { id: 'az-express-preprod', number: '306761725053' },
    identities: Object.fromEntries(Object.values(lot.IDENTITIES).map((i) => [i.role, { uid: i.uid, email: i.email }])),
    documents: lot.buildSeedPlan().map((d) => ({ path: d.path })), baseline: { orderIds: ['h1'], counts: {} },
  });
  assert.doesNotThrow(() => cleanup.validateManifest(good()));
  const mutations = {
    lot: (m) => { m.lot = 'autre-lot'; },
    projet: (m) => { m.project.id = 'az-express-b0469'; },
    numero: (m) => { m.project.number = '1'; },
    identite: (m) => { m.identities.client.uid = 'client-reel'; },
    email: (m) => { m.identities.admin.email = 'intrus@example.org'; },
    document: (m) => { m.documents.push({ path: 'clients/un-vrai-client' }); },
    baseline: (m) => { delete m.baseline; },
  };
  for (const [name, mutate] of Object.entries(mutations)) {
    const m = good(); mutate(m);
    throwsCode(() => cleanup.validateManifest(m), 'MANIFEST_INVALID');
    assert.ok(name);
  }
});

test('liste blanche de suppression : seules les ressources du lot, jamais audit_logs, rate_limits ni un autre compte', () => {
  const yes = [
    'orders/0b5a1c1e-1111-4222-8333-444455556666', 'tariff_quotes/abc', 'delivery_proofs/abc123', 'delivery_proofs/abc123/versions/pv1',
    'clients/t7e-client', 'clients/t7e-client/wallet_transactions/order_x', 'livreurs/t7e-driver', 'livreurs/t7e-driver/wallet_transactions/earning_x',
    'restaurants/t7e-resto', 'restaurants/t7e-resto/menu/t7e-plat-a', 'restaurants/t7e-resto/wallet_transactions/earning_x',
    'restaurant_owners/t7e-resto', 'admins/t7e-admin', 'commissions/abc', 'reconciliation_flags/o_partner_credit_missing', 'config/partnerOrdersV2',
  ];
  const no = [
    'audit_logs/abc', 'rate_limits/t7e-client_x', 'clients/un-vrai-client', 'clients/t7e-driver', 'livreurs/t7e-client', 'livreurs/autre',
    'restaurants/autre', 'restaurants/autre/menu/m1', 'admins/znm', 'restaurant_owners/autre', 'config/commission', 'config/partnerOrdersV2/x',
    'users/t7e-client', 'orders', 'orders/a/b', 'clients/t7e-client/favorite_providers/x', 'zones_livraison/abengourou-test', 'sellers/t7e-resto',
  ];
  for (const p of yes) assert.equal(cleanup.pathAllowed(p), true, p);
  for (const p of no) assert.equal(cleanup.pathAllowed(p), false, p);
});
