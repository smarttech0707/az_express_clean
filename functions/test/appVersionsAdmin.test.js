'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { requireSuperAdmin } = require('../adminGuards');
const { buildSetAppVersionsConfig, validateRoleValues, checkPublishedBuild } = require('../appVersionsAdmin');

const DELETE = Symbol('delete');
const admin = { firestore: { FieldValue: { delete: () => DELETE, serverTimestamp: () => 'TS' } } };
const verified = (latestBuild) => ({ latestBuild, source: 'Play Console', verifiedAt: 'T' });

// Faux Firestore en mémoire : admins/root, config/app_versions, config/app_release_registry.
function makeEnv({ adminDoc = { role: 'super', isActive: true }, versions, registry } = {}) {
  const store = new Map();
  if (adminDoc) store.set('admins/root', adminDoc);
  if (versions) store.set('config/app_versions', versions);
  if (registry) store.set('config/app_release_registry', registry);
  const audits = []; const limits = [];
  const ref = (path) => ({
    path,
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
  });
  const db = {
    collection: (c) => ({ doc: (d) => ref(`${c}/${d}`) }),
    runTransaction: async (fn) => fn({
      get: (r) => r.get(),
      set: (r, data) => {
        const cur = { ...(store.get(r.path) || {}) };
        for (const [k, v] of Object.entries(data)) { if (v === DELETE) delete cur[k]; else cur[k] = v; }
        store.set(r.path, cur);
      },
    }),
  };
  const fn = buildSetAppVersionsConfig({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async (...a) => { limits.push(a); },
    logAudit: async (d) => { audits.push(d); },
    requireSuperAdmin,
  });
  return { fn, store, audits, limits };
}
const req = (data, uid = 'root', provider = 'password') => ({ auth: { uid, token: { firebase: { sign_in_provider: provider } } }, data });
const okRegistry = { android: verified(20), ios: verified(5) };

test('accepte une valeur valide, incrémente la version et journalise avant/après', async () => {
  const e = makeEnv({ registry: okRegistry, versions: { driver: { minBuild: 3 }, version: 2 } });
  const r = await e.fn.run(req({ role: 'driver', expectedVersion: 2, values: { minBuild: 5, enforce: false, message: ' Mettez à jour ' } }));
  assert.equal(r.success, true); assert.equal(r.data.version, 3);
  assert.deepEqual(e.store.get('config/app_versions').driver, { minBuild: 5, enforce: false, message: 'Mettez à jour' });
  assert.equal(e.store.get('config/app_versions').updatedBy, 'root');
  assert.equal(e.audits.length, 1);
  assert.equal(e.audits[0].action, 'app_versions_config_update');
  assert.deepEqual(e.audits[0].metadata.before, { minBuild: 3 });
  assert.equal(e.audits[0].metadata.after.minBuild, 5);
  assert.deepEqual(e.limits[0], ['root', 'app_versions_config', 10, 3600]);
});

test('refuse anonyme, non-admin, sous-admin et super désactivé', async () => {
  for (const [adminDoc, r] of [
    [{ role: 'super', isActive: true }, req({}, 'root', 'anonymous')],
    [undefined, req({})],
    [{ role: 'sub', isActive: true, permissions: ['commandes'] }, req({})],
    [{ role: 'super', isActive: false }, req({})],
  ]) {
    const e = makeEnv({ adminDoc: adminDoc || null });
    await assert.rejects(e.fn.run(r), (err) => ['permission-denied', 'unauthenticated'].includes(err.code));
    assert.equal(e.store.has('config/app_versions'), false);
  }
  const noAuth = makeEnv();
  await assert.rejects(noAuth.fn.run({ data: {} }), (err) => err.code === 'unauthenticated');
});

test('refuse enforce:true, champs inconnus, rôle inconnu et valeurs invalides sans rien écrire', async () => {
  const cases = [
    [{ role: 'driver', values: { enforce: true } }, 'ENFORCE_NOT_ALLOWED'],
    [{ role: 'driver', values: { enforce: 'true' } }, 'INVALID_ENFORCE'],
    [{ role: 'driver', values: { foo: 1 } }, 'UNKNOWN_FIELD'],
    [{ role: 'hacker', values: { minBuild: 1 } }, 'INVALID_ROLE'],
    [{ role: 'driver', values: { minBuild: 0 } }, 'INVALID_BUILD'],
    [{ role: 'driver', values: { minBuild: -3 } }, 'INVALID_BUILD'],
    [{ role: 'driver', values: { minBuild: 1.5 } }, 'INVALID_BUILD'],
    [{ role: 'driver', values: { minBuild: '5' } }, 'INVALID_BUILD'],
    [{ role: 'driver', values: { minBuildIos: 2100000001 } }, 'INVALID_BUILD'],
    [{ role: 'driver', values: { message: '' } }, 'INVALID_MESSAGE'],
    [{ role: 'driver', values: { message: 'x'.repeat(501) } }, 'INVALID_MESSAGE'],
    [{ role: 'driver', values: { updateUrl: 'http://play.google.com/x' } }, 'INVALID_URL'],
    [{ role: 'driver', values: { updateUrl: 'https://evil.example/x' } }, 'INVALID_URL'],
    [{ role: 'driver', values: { updateUrl: 'https://u:p@play.google.com/x' } }, 'INVALID_URL'],
    [{ role: 'driver', values: [1] }, 'INVALID_VALUES'],
    [{ role: 'driver', values: 'x' }, 'INVALID_VALUES'],
  ];
  for (const [data, code] of cases) {
    const e = makeEnv({ registry: okRegistry });
    const r = await e.fn.run(req({ expectedVersion: 0, ...data }));
    assert.equal(r.success, false, JSON.stringify(data)); assert.equal(r.code, code, JSON.stringify(data));
    assert.equal(e.store.has('config/app_versions'), false);
    assert.equal(e.audits[0].status, 'refused');
  }
  const e = makeEnv({ registry: okRegistry });
  assert.equal((await e.fn.run(req({ role: 'driver', values: { minBuild: 1 } }))).code, 'INVALID_VERSION');
});

test('registre absent ou invalide : impossible de définir ou relever un minBuild (jamais de build inventé)', async () => {
  for (const registry of [undefined, { android: verified(20) }, { android: verified(20), ios: { latestBuild: 5 } },
    { android: verified(20), ios: { latestBuild: 5.5, source: 's', verifiedAt: 'T' } }]) {
    const e = makeEnv({ registry });
    const r = await e.fn.run(req({ role: 'driver', expectedVersion: 0, values: { minBuild: 3 } }));
    assert.equal(r.code, 'PUBLISHED_BUILD_UNVERIFIED');
    assert.equal(e.store.has('config/app_versions'), false);
  }
  const noIos = makeEnv({ registry: { android: verified(20) } });
  assert.equal((await noIos.fn.run(req({ role: 'driver', expectedVersion: 0, values: { minBuildAndroid: 3 } }))).success, true);
  assert.equal((await noIos.fn.run(req({ role: 'driver', expectedVersion: 1, values: { minBuildIos: 3 } }))).code, 'PUBLISHED_BUILD_UNVERIFIED');
});

test('minBuild au-dessus du dernier build publié vérifié refusé ; égal accepté ; plateforme par plateforme', async () => {
  const e = makeEnv({ registry: okRegistry });
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 0, values: { minBuild: 6 } }))).code, 'BUILD_ABOVE_PUBLISHED');
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 0, values: { minBuildAndroid: 21 } }))).code, 'BUILD_ABOVE_PUBLISHED');
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 0, values: { minBuildAndroid: 20, minBuildIos: 5 } }))).success, true);
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 1, values: { minBuildAndroid: 20, minBuildIos: 6 } }))).code, 'BUILD_ABOVE_PUBLISHED');
});

test('baisser, conserver ou retirer une contrainte reste permis sans registre ; retirer le rôle aussi', async () => {
  const e = makeEnv({ versions: { driver: { minBuild: 9, minBuildIos: 4 }, version: 1 } });
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 1, values: { minBuild: 9, minBuildIos: 2, message: 'm' } }))).success, true);
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 2, values: { message: 'seul' } }))).success, true);
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 3, values: { minBuild: 4 } }))).code, 'PUBLISHED_BUILD_UNVERIFIED');
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 3, values: null }))).success, true);
  assert.equal('driver' in e.store.get('config/app_versions'), false);
});

test('concurrence : mauvaise version refusée, autres rôles intacts', async () => {
  const e = makeEnv({ registry: okRegistry, versions: { client: { minBuild: 2 }, version: 4 } });
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 3, values: { minBuild: 1 } }))).code, 'VERSION_CONFLICT');
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 4, values: { minBuild: 1 } }))).success, true);
  assert.deepEqual(e.store.get('config/app_versions').client, { minBuild: 2 });
});

test('un rôle déjà en blocage exige enforce:false explicite', async () => {
  const e = makeEnv({ registry: okRegistry, versions: { driver: { minBuild: 3, enforce: true }, version: 1 } });
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 1, values: { minBuild: 2 } }))).code, 'ENFORCE_EXPLICIT_REQUIRED');
  assert.equal((await e.fn.run(req({ role: 'driver', expectedVersion: 1, values: { minBuild: 2, enforce: false } }))).success, true);
  assert.equal(e.store.get('config/app_versions').driver.enforce, false);
});

test('validateRoleValues normalise le lien et checkPublishedBuild est pur', () => {
  assert.equal(validateRoleValues({ updateUrl: ' https://play.google.com/store/apps/details?id=x ' }).updateUrl,
    'https://play.google.com/store/apps/details?id=x');
  assert.doesNotThrow(() => checkPublishedBuild({ before: null, after: { message: 'x' }, registry: null }));
});
