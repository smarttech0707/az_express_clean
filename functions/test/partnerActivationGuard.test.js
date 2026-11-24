'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { assertPartnerActivated } = require('../partnerActivationGuard');
const { buildManageProfessionalSubscription } = require('../professionalSubscriptions');

function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  const reads = [];
  const snapshot = (p) => ({ exists: store.has(p), data: () => store.get(p) });
  const ref = (p) => ({
    id: p.split('/').pop(), path: p,
    get: async () => { reads.push(p); return snapshot(p); },
    collection: (name) => collection(`${p}/${name}`),
  });
  const collection = (p) => ({ doc: (id) => ref(`${p}/${id}`) });
  return {
    store, reads, collection,
    runTransaction: async (fn) => fn({
      get: async (d) => snapshot(d.path),
      update: (d, v) => store.set(d.path, { ...store.get(d.path), ...v }),
      set: (d, v) => store.set(d.path, v),
    }),
  };
}
const req = (uid, token = {}) => ({
  auth: { uid, token: { firebase: { sign_in_provider: 'password' }, ...token } },
});
const refused = (e) => e.code === 'failed-precondition' && /Activation du compte requise/.test(e.message);

test('journal serveur « changement obligatoire » : refusé, même avec un jeton ANCIEN sans revendication', async () => {
  const db = makeDb({ 'partner_provisioning/p1': { mustChangePassword: true } });
  await assert.rejects(assertPartnerActivated({ db, request: req('p1') }), refused);
});

test('revendication seule (aucun journal) : refusé', async () => {
  const db = makeDb();
  await assert.rejects(assertPartnerActivated({ db, request: req('p1', { partnerMustChangePassword: true }) }), refused);
});

test('journal levé + revendication PÉRIMÉE dans le jeton : autorisé (le serveur fait autorité)', async () => {
  const db = makeDb({ 'partner_provisioning/p1': { mustChangePassword: false } });
  await assertPartnerActivated({ db, request: req('p1', { partnerMustChangePassword: true }) });
});

test('compte historique, client, livreur, admin (ni journal ni revendication) : aucun effet', async () => {
  const db = makeDb();
  for (const uid of ['historique', 'client-1', 'driver-1', 'admin-1']) {
    await assertPartnerActivated({ db, request: req(uid) });
  }
  assert.equal(db.reads.length, 4, 'une seule lecture par appel, aucune écriture');
  assert.equal([...db.store.keys()].length, 0);
});

test('appelant sans uid : laissé à l\'authentification de la fonction appelante', async () => {
  await assertPartnerActivated({ db: makeDb(), request: { auth: null } });
});

test('la garde ne retourne aucune donnée sensible dans son message', async () => {
  const db = makeDb({ 'partner_provisioning/p1': { mustChangePassword: true, tempPasswordHash: 'salt:hash' } });
  await assert.rejects(assertPartnerActivated({ db, request: req('p1') }), (e) => !/salt|hash/.test(e.message));
});

// ── manageProfessionalSubscription ──────────────────────────────────────────
function subscriptionHandler(seed) {
  const db = makeDb(seed);
  const handler = buildManageProfessionalSubscription({
    db, auth: {},
    timestamp: { fromMillis: (value) => ({ toMillis: () => value }) },
    fieldValue: { serverTimestamp: () => 'SERVER_TIME' },
  });
  return { db, handler };
}
const renew = (uid, token) => ({
  ...req(uid, token), data: { action: 'renew', collection: 'sellers', docId: uid },
});

test('abonnement : partenaire NON activé → renouvellement refusé, wallet et abonnement intacts', async () => {
  const { db, handler } = subscriptionHandler({
    'sellers/s1': { wallet: 5000, subscriptionStatus: 'expired' },
    'partner_provisioning/s1': { mustChangePassword: true },
  });
  await assert.rejects(handler(renew('s1')), refused);
  assert.deepEqual(db.store.get('sellers/s1'), { wallet: 5000, subscriptionStatus: 'expired' });
  assert.equal([...db.store.keys()].some((k) => k.startsWith('subscription_operations/')), false);
});

test('abonnement : revendication seule (jeton) → refusé', async () => {
  const { db, handler } = subscriptionHandler({ 'sellers/s1': { wallet: 5000 } });
  await assert.rejects(handler(renew('s1', { partnerMustChangePassword: true })), refused);
  assert.equal(db.store.get('sellers/s1').wallet, 5000);
});

test('abonnement : après activation (journal levé) → traitement normal, débit autorisé', async () => {
  const { db, handler } = subscriptionHandler({
    'sellers/s1': { wallet: 5000, subscriptionStatus: 'expired', subscriptionExpiresAt: null },
    'partner_provisioning/s1': { mustChangePassword: false },
  });
  const result = await handler(renew('s1', { partnerMustChangePassword: true }));
  assert.equal(result.success, true);
  assert.ok(db.store.get('sellers/s1').wallet < 5000, 'le débit normal est appliqué');
});

test('abonnement : compte historique sans journal → comportement inchangé', async () => {
  const { handler } = subscriptionHandler({
    'sellers/s1': { wallet: 5000, subscriptionStatus: 'expired', subscriptionExpiresAt: null },
  });
  assert.equal((await handler(renew('s1'))).success, true);
});

test('abonnement : un administrateur n\'est jamais bloqué par cette garde', async () => {
  const { handler } = subscriptionHandler({
    'admins/root': { role: 'super', isActive: true },
    'sellers/s1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  const result = await handler({
    ...req('root'),
    data: { action: 'renew', collection: 'sellers', docId: 's1' },
  });
  assert.equal(result.success, true);
});

// ── garde installée dans les deux fonctions, avant toute logique ────────────
test('initiateWithdrawal : la garde précède validation, limitation de débit et débit', () => {
  const source = fs.readFileSync(path.join(__dirname, '../index.js'), 'utf8');
  const start = source.indexOf('exports.initiateWithdrawal = onCall(');
  const end = source.indexOf('exports.', start + 10);
  const body = source.slice(start, end);
  const guard = body.indexOf('await assertPartnerActivated({ db, request })');
  assert.ok(guard > 0, 'garde absente');
  for (const later of ['VALID_USER_TYPES', 'checkRateLimit(uid', 'runTransaction', 'axios.post']) {
    assert.ok(guard < body.indexOf(later), `la garde doit précéder ${later}`);
  }
});

test('manageProfessionalSubscription : la garde précède toute lecture métier', () => {
  const source = fs.readFileSync(path.join(__dirname, '../professionalSubscriptions.js'), 'utf8');
  const guard = source.indexOf('await assertPartnerActivated({ db, request })');
  assert.ok(guard > 0);
  assert.ok(guard < source.indexOf('requireAdminPermission({ request'));
  assert.ok(guard < source.indexOf('runTransaction'));
});

// ── intégrité des revendications ────────────────────────────────────────────
test('seul le serveur manipule les revendications : aucun usage côté application, trois modules serveur seulement', () => {
  const functionsDir = path.join(__dirname, '..');
  const users = fs.readdirSync(functionsDir)
    .filter((f) => f.endsWith('.js'))
    .filter((f) => fs.readFileSync(path.join(functionsDir, f), 'utf8').includes('setCustomUserClaims'));
  assert.deepEqual(users.sort(), ['adminPartnerAccounts.js', 'partnerFirstLogin.js']);
  const libDir = path.join(__dirname, '../../lib');
  const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]);
  for (const file of walk(libDir).filter((f) => f.endsWith('.dart'))) {
    assert.equal(/setCustomUserClaims|customClaims\s*=/.test(fs.readFileSync(file, 'utf8')), false, file);
  }
});

test('le seul appel client qui retire la revendication exige un changement serveur réel', () => {
  const source = fs.readFileSync(path.join(__dirname, '../partnerFirstLogin.js'), 'utf8');
  // retrait après la levée du drapeau serveur, ou en réparation d'un journal déjà levé
  const journal = source.indexOf("mustChangePassword: false,");
  const removal = source.indexOf('setCustomUserClaims(uid, null)', journal);
  assert.ok(journal > 0 && removal > journal);
  assert.ok(source.includes("state?.mustChangePassword === false"), 'réparation conditionnée au journal serveur');
});

// ── B3 : recharge FeexPay et publication Marketplace ───────────────────────
test('initiateFeexPayPayment : la garde précède validation, limitation de débit, transaction et appel FeexPay', () => {
  const source = fs.readFileSync(path.join(__dirname, '../index.js'), 'utf8');
  const start = source.indexOf('exports.initiateFeexPayPayment = onCall(');
  const end = source.indexOf('\nexports.', start + 10);
  const body = source.slice(start, end);
  const guard = body.indexOf('await assertPartnerActivated({ db, request })');
  assert.ok(guard > 0, 'garde absente');
  for (const later of ['VALID_USER_TYPES', "checkRateLimit(uid, 'payment'", 'wallet_transactions', 'axios.post']) {
    const position = body.indexOf(later);
    assert.ok(position < 0 || guard < position, `la garde doit précéder ${later}`);
  }
});

test('B3 : le périmètre financier de initiateFeexPayPayment est inchangé hors la garde (montants, statuts, webhook)', () => {
  const source = fs.readFileSync(path.join(__dirname, '../index.js'), 'utf8');
  const start = source.indexOf('exports.initiateFeexPayPayment = onCall(');
  const end = source.indexOf('\nexports.', start + 10);
  const body = source.slice(start, end);
  // les bornes et validations d'origine sont intactes
  assert.ok(body.includes("amount < 100"));
  assert.ok(body.includes("amount > 500000"));
  assert.ok(body.includes("checkRateLimit(uid, 'payment', 5, 60)"));
  assert.equal(body.split('assertPartnerActivated').length - 1, 1, 'une seule garde ajoutée');
});

test('publishMarketplaceProduct et republishMarketplaceProduct : la garde précède toute lecture ou écriture', async () => {
  const { buildPublishMarketplaceProduct, buildRepublishMarketplaceProduct } = require('../marketplacePublishing');
  for (const build of [buildPublishMarketplaceProduct, buildRepublishMarketplaceProduct]) {
    const touched = [];
    const db = {
      collection: (name) => {
        touched.push(name);
        return {
          doc: () => ({ get: async () => ({ exists: true, data: () => ({ mustChangePassword: true }) }) }),
        };
      },
      runTransaction: async () => { touched.push('transaction'); },
    };
    const handler = build({ db, admin: { firestore: { Timestamp: { now: () => ({ toMillis: () => 0 }) } } } });
    await assert.rejects(handler({
      auth: { uid: 'p1', token: { firebase: { sign_in_provider: 'password' } } },
      data: { product: { title: 'x' }, productId: 'x' },
    }), refused);
    assert.deepEqual(touched, ['partner_provisioning'], 'seul le journal est lu ; aucune écriture, aucune transaction');
  }
});

test('publication : compte activé ou historique passe la garde (rejet de validation seulement)', async () => {
  const { buildPublishMarketplaceProduct } = require('../marketplacePublishing');
  for (const journal of [null, { mustChangePassword: false }]) {
    const db = {
      collection: () => ({
        doc: () => ({ get: async () => ({ exists: journal !== null, data: () => journal }) }),
      }),
    };
    const handler = buildPublishMarketplaceProduct({ db, admin: {} });
    await assert.rejects(handler({
      auth: { uid: 'p1', token: { firebase: { sign_in_provider: 'password' } } },
      data: { product: null },
    }), (e) => e.code === 'invalid-argument');
  }
});
