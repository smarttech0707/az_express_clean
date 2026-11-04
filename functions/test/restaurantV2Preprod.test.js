// Mission 7E-9 — préparation locale du déploiement Restaurant v2 en préproduction. Aucun accès réseau, aucune commande Firebase :
// le script de déploiement n'est exécuté qu'en SIMULATION (ou refusé avant toute action), jamais en réel.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..', '..');
const read = (...p) => fs.readFileSync(path.join(ROOT, ...p), 'utf8');
const SCRIPT = path.join(ROOT, 'test-env', 'deploy-restaurant-v2-preprod.ps1');
const guards = require(path.join(ROOT, 'test-env', 'lib', 'guards.js'));
const seed = require(path.join(ROOT, 'test-env', 'lib', 'restaurantV2Seed.js'));
const seedCli = require(path.join(ROOT, 'test-env', 'seed-restaurant-v2.js'));

const parseEnv = (text) => Object.fromEntries(text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#') && l.includes('='))
  .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]));

// ── Script de déploiement ───────────────────────────────────────────────────────────────────────────────────────────────
const windows = process.platform === 'win32';
const runScript = (...args) => spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, ...args], { encoding: 'utf8', timeout: 180000 });

test('script : liste blanche exacte, exportée par index.js, sans fonction hors pilote', () => {
  const src = read('test-env', 'deploy-restaurant-v2-preprod.ps1');
  const stages = {};
  for (const m of src.matchAll(/'(functions-[a-z]+)'\s*=\s*@\(([^)]*)\)/g)) stages[m[1]] = [...m[2].matchAll(/'([A-Za-z]+)'/g)].map((x) => x[1]);
  assert.deepEqual(Object.keys(stages), ['functions-existing', 'functions-new', 'functions-proofs', 'functions-notify']);
  assert.deepEqual(stages['functions-proofs'], ['prepareOrderProof', 'confirmOrderPickupWithProof', 'confirmOrderDeliveryWithProof']);
  const all = Object.values(stages).flat();
  assert.equal(new Set(all).size, all.length, 'aucun doublon');
  const index = read('functions', 'index.js');
  for (const n of all) assert.match(index, new RegExp(`exports\\.${n}\\s*=`), n);
  for (const forbidden of ['payOrderFromWalletCF', 'payBoutiqueOrderCF', 'requestAccountDeletionCF', 'createSubAdmin', 'deleteSubAdmin']) {
    assert.ok(!all.includes(forbidden), forbidden);
  }
});

test('script : aucune suppression, aucun --force, aucun « firebase use », aucun gcloud, --project partout', () => {
  const src = read('test-env', 'deploy-restaurant-v2-preprod.ps1').split(/\r?\n/).filter((l) => !l.trim().startsWith('#')).join('\n');
  for (const forbidden of ['--force', 'firebase use', 'functions:delete', 'gcloud', 'firestore:delete', 'Remove-Item -Recurse', 'only functions\'']) {
    assert.ok(!src.includes(forbidden) || forbidden === '--force', forbidden);
  }
  // --force n'apparaît que dans le garde-fou qui le refuse.
  assert.equal([...src.matchAll(/--force/g)].length, 2);
  assert.match(src, /if \(\$cliArgs -contains '--force'\) \{ Fail/);
  assert.match(src, /if \(\$cliArgs -notcontains '--project'\) \{ Fail/);
  // Chaque commande de déploiement construite porte --project et --non-interactive ; jamais « functions » seul.
  for (const m of src.matchAll(/return ,@\(([^)]*)\)/g)) {
    if (m[1].includes("'deploy'")) { assert.match(m[1], /'--project', \$Project/); assert.match(m[1], /'--non-interactive'/); }
  }
  assert.ok(!/--only',\s*'functions'\s*[,)]/.test(src));
});

test('script : simulation par défaut — plan complet, aucune commande distante', { skip: !windows && 'PowerShell Windows requis' }, () => {
  const r = runScript();
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.match(r.stdout, /Mode: SIMULATION \| projet: az-express-preprod \(306761725053\)/);
  assert.match(r.stdout, /maxInstances = 1/);
  for (const s of ['rules', 'indexes', 'functions-existing', 'functions-new', 'functions-proofs', 'functions-notify']) assert.match(r.stdout, new RegExp(`--- Etape: ${s} ---`));
  assert.match(r.stdout, /Simulation: firebase deploy --project az-express-preprod --only firestore:rules --non-interactive/);
  assert.ok(!/projects:list|Etape .* terminee|Identite du projet confirmee/.test(r.stdout), 'aucune commande distante en simulation');
  assert.ok(!r.stdout.includes('az-express-b0469'));
});

test('script : refuse la production, tout autre projet, un mauvais numéro et un -Execute mal formé (avant toute action)', { skip: !windows && 'PowerShell Windows requis' }, () => {
  const cases = [
    [['-Project', 'az-express-b0469'], /projet de production/],
    [['-Project', 'az-express-clean'], /projet de production/],
    [['-Project', 'az-express-preprod-1'], /seul 'az-express-preprod'/],
    [['-ProjectNumber', '697217052961'], /numero 697217052961 est celui de la production/],
    [['-ProjectNumber', '111'], /numero de projet attendu est 306761725053/],
    [['-Execute'], /UNE etape precise/],
    [['-Execute', '-Stage', 'all', '-ConfirmProject', 'az-express-preprod'], /UNE etape precise/],
    [['-Execute', '-Stage', 'rules'], /-ConfirmProject az-express-preprod/],
    [['-Execute', '-Stage', 'rules', '-ConfirmProject', 'autre'], /-ConfirmProject az-express-preprod/],
  ];
  for (const [args, pattern] of cases) {
    const r = runScript(...args);
    assert.notEqual(r.status, 0, args.join(' '));
    assert.match(r.stdout + r.stderr, pattern, args.join(' '));
    assert.ok(!/> firebase /.test(r.stdout), `aucune commande lancée : ${args.join(' ')}`);
  }
});

// ── Variables et configuration QR/PIN sans SMS ──────────────────────────────────────────────────────────────────────────
test('modèle .env de préproduction : QR/PIN activés, SMS coupés, paiements désactivés, pilote fermé, aucun secret', () => {
  const text = read('test-env', 'env', 'functions.env.az-express-preprod.example');
  const env = parseEnv(text);
  assert.deepEqual(guards.checkFunctionsEnv(text), []);
  assert.equal(env.DELIVERY_PROOFS_ENABLED, 'true');
  assert.equal(env.DELIVERY_SMS_ENABLED, 'false');
  assert.equal(env.DELIVERY_SMS_PROVIDER, 'none');
  assert.equal(env.FEEXPAY_SHOP_ID, 'DISABLED');
  assert.equal(env.PARTNER_ORDERS_V2, 'on');
  assert.equal(env.PILOT_MAX_INSTANCES, '1');
  assert.ok(!('PARTNER_ORDERS_V2_MANAGE' in env), 'pas de gel par variable au départ');
  for (const secret of ['DELIVERY_PROOF_PEPPER', 'FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY']) assert.ok(!(secret in env), secret);
  assert.deepEqual(guards.findProductionReferences(text), []);
});

test('fichiers .env locaux : la préproduction est conforme, la production ne porte ni le plafond ni l\'activation', { skip: !fs.existsSync(path.join(ROOT, 'functions', '.env.az-express-preprod')) && 'fichier local absent (ignoré par Git)' }, () => {
  const pre = parseEnv(read('functions', '.env.az-express-preprod'));
  assert.deepEqual(guards.checkFunctionsEnv(read('functions', '.env.az-express-preprod')), []);
  assert.equal(pre.PILOT_MAX_INSTANCES, '1');
  assert.equal(pre.PARTNER_ORDERS_V2, 'on');
  assert.equal(pre.DELIVERY_PROOFS_ENABLED, 'true');
  assert.ok(!('DELIVERY_PROOF_PEPPER' in pre));
  if (fs.existsSync(path.join(ROOT, 'functions', '.env'))) {
    const base = parseEnv(read('functions', '.env'));
    assert.ok(!('PILOT_MAX_INSTANCES' in base), 'functions/.env (production) ne doit pas porter le plafond');
    assert.notEqual(base.PARTNER_ORDERS_V2, 'on', 'functions/.env (production) ne doit pas activer le pilote');
  }
});

test('dart-defines de test : interface QR/PIN active, interface SMS coupée', () => {
  const defines = JSON.parse(read('test-env', 'env', 'dart-defines.test.example.json'));
  assert.equal(defines.DELIVERY_PROOFS_UI, true);
  assert.equal(defines.DELIVERY_SMS_UI, false);
});

test('QR/PIN sans SMS : les fonctions de preuve n\'appellent aucun SMS ; le déclencheur SMS sort si coupé ; tests de preuves verts SMS coupés', () => {
  const proofs = read('functions', 'deliveryProofs.js');
  assert.ok(!/deliveryProofSms|sendSms|smsProvider|fetch\(|https?\.request/i.test(proofs));
  const index = read('functions', 'index.js');
  assert.match(index, /process\.env\.DELIVERY_SMS_ENABLED !== 'true' \|\| process\.env\.DELIVERY_PROOFS_ENABLED !== 'true'\) return;/);
  const env = { ...process.env, DELIVERY_PROOFS_ENABLED: 'true', DELIVERY_SMS_ENABLED: 'false', DELIVERY_SMS_PROVIDER: 'none', DELIVERY_PROOF_PEPPER: 'test-only-not-a-secret' };
  delete env.NODE_TEST_CONTEXT; // sinon le sous-processus rapporte au test parent et n'écrit rien sur stdout
  const out = execFileSync(process.execPath, ['--test', path.join(__dirname, 'deliveryProofs.test.js')], { env, encoding: 'utf8', timeout: 180000 });
  assert.match(out, /ℹ fail 0/);
  assert.match(out, /ℹ pass [1-9]/);
});

// ── Pilote fermé au départ ──────────────────────────────────────────────────────────────────────────────────────────────
test('pilote : document de configuration absent = création fermée, aucun restaurant, aucun gel, version 0', () => {
  const cfg = require('../partnerOrdersConfig');
  const c = cfg.parsePilotConfig(null);
  assert.equal(c.creationOpen, false);
  assert.equal(c.managementFrozen, false);
  assert.equal(c.ids.size, 0);
  assert.equal(c.version, 0);
  // Même avec PARTNER_ORDERS_V2=on, un restaurant non listé reste refusé ; listé mais création fermée aussi.
  assert.equal(cfg.creationRefusal(c, seed.RESTAURANT_ID).code, 'PARTNER_NOT_IN_PILOT');
  const listedButClosed = cfg.parsePilotConfig({ pilotPartnerIds: [seed.RESTAURANT_ID], creationOpen: false });
  assert.equal(cfg.creationRefusal(listedButClosed, seed.RESTAURANT_ID).code, 'CREATION_CLOSED');
  assert.equal(cfg.creationRefusal(cfg.parsePilotConfig({ pilotPartnerIds: [seed.RESTAURANT_ID], creationOpen: 'true' }), seed.RESTAURANT_ID).code, 'CREATION_CLOSED');
  const prev = process.env.PARTNER_ORDERS_V2;
  delete process.env.PARTNER_ORDERS_V2;
  assert.equal(cfg.creationEnabled(), false, 'variable absente = jamais de création');
  process.env.PARTNER_ORDERS_V2 = 'on';
  assert.equal(cfg.creationEnabled(), true);
  if (prev === undefined) delete process.env.PARTNER_ORDERS_V2; else process.env.PARTNER_ORDERS_V2 = prev;
  // Fermeture d'urgence : le gel est lu à chaque appel et refusé côté serveur par le même module.
  assert.equal(cfg.parsePilotConfig({ managementFrozen: true }).managementFrozen, true);
});

// ── Seed ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
const UIDS = { client: 'uid-c', driver: 'uid-d', admin: 'uid-a', restaurant: 'uid-r' };

test('seed : plan déterministe, idempotent (soldes conservés), sans donnée réelle, sans configuration du pilote', () => {
  const a = seed.buildPlan(UIDS);
  assert.deepEqual(seed.buildPlan(UIDS), a);
  assert.deepEqual(seed.findRealDataMarkers(a), []);
  assert.ok(a.every((d) => d.data.isTestData === true));
  assert.ok(!a.some((d) => d.path.startsWith('config/partnerOrdersV2')), 'le pilote n\'est jamais configuré par le seed');
  for (const d of a.filter((x) => 'wallet' in x.data)) assert.deepEqual(d.keepIfExists, ['wallet'], d.path);
  for (const acc of Object.values(seed.ACCOUNTS)) assert.match(acc.email, /@(az-test\.invalid|az-restaurant\.ci)$/);
  assert.ok(!/orders\//.test(JSON.stringify(a.map((d) => d.path))), 'aucune commande semée');
  assert.throws(() => seed.buildPlan({ client: 'x' }), /uid manquant/);
});

test('seed : le restaurant et le menu sont acceptés par les règles serveur du devis (partenaire ouvert, prix entiers, tarif officiel)', () => {
  const { partnerRefusal, partnerPoint, priceItems } = require('../partnerCatalog');
  const { computeOfficialTariff } = require('../officialTariff');
  const { DEFAULT_TARIFF_CONFIG } = require('../tariffConfig');
  const plan = seed.buildPlan(UIDS);
  const resto = plan.find((d) => d.path === `restaurants/${seed.RESTAURANT_ID}`).data;
  const nowMs = Date.UTC(2026, 10, 5, 12, 0, 0);
  assert.equal(partnerRefusal('restaurant', resto, nowMs), null);
  const pickup = partnerPoint(resto);
  assert.ok(pickup);
  const menu = new Map(plan.filter((d) => d.path.startsWith(`restaurants/${seed.RESTAURANT_ID}/menu/`)).map((d) => [d.path.split('/').pop(), d.data]));
  const { productAmount, lines } = priceItems('restaurant', [{ itemId: 'attieke-poisson', qty: 2 }, { itemId: 'jus-bissap', qty: 1 }], menu);
  assert.equal(productAmount, 5500);
  assert.equal(lines.length, 2);
  const tariff = computeOfficialTariff({ serviceType: 'restaurant', mode: 'standard', pickup, destination: { lat: 6.735, lng: -3.49 }, nowMs, config: DEFAULT_TARIFF_CONFIG });
  assert.equal(tariff.ok, true, JSON.stringify(tariff));
  assert.ok(Number.isSafeInteger(tariff.deliveryFee) && tariff.deliveryFee > 0);
});

test('seed : simulation par défaut (aucun réseau) et refus de la production, de tout autre projet, d\'une exécution non confirmée', () => {
  const run = (...args) => spawnSync(process.execPath, [path.join(ROOT, 'test-env', 'seed-restaurant-v2.js'), ...args], { encoding: 'utf8', env: { PATH: process.env.PATH } });
  const ok = run('--project', 'az-express-preprod');
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /SIMULATION .*aucune écriture, aucun compte créé, aucun accès réseau/);
  assert.match(ok.stdout, /config\/partnerOrdersV2 : NON écrit/);
  for (const [args, pattern] of [
    [['--project', 'az-express-b0469'], /PRODUCTION/],
    [['--project', 'az-express-b0469', '--execute', '--confirm-project', 'az-express-b0469'], /PRODUCTION/],
    [['--project', 'mon-projet'], /ne ressemble pas à un projet de test/],
    [['--project', 'az-express-preprod-2'], /seul « az-express-preprod » est autorisé/],
    [['--project', 'az-express-preprod', '--execute'], /--confirm-project/],
    [['--project', 'az-express-preprod', '--execute', '--confirm-project', 'autre'], /--confirm-project/],
  ]) {
    const r = run(...args);
    assert.notEqual(r.status, 0, args.join(' '));
    assert.match(r.stderr, pattern, args.join(' '));
  }
  // Variables d'environnement visant la production, ou émulateur incohérent.
  assert.throws(() => seedCli.validate({ project: 'az-express-preprod' }, { GCLOUD_PROJECT: 'az-express-b0469' }), /production/i);
  assert.throws(() => seedCli.validate({ project: 'az-express-preprod' }, { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' }), /sans --emulator/);
  assert.throws(() => seedCli.validate({ project: 'demo-az', emulator: true, execute: true }, {}), /FIRESTORE_EMULATOR_HOST/);
  assert.deepEqual(seedCli.validate({ project: 'az-express-preprod', confirm: 'az-express-preprod', execute: true }, {}), { project: 'az-express-preprod', emulator: false, execute: true });
});
