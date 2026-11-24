'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseArgs, validateInput, checkTarget, describePlan, applyUpdate, main, confirmationToken } = require('../scripts/appReleaseRegistry');

const NOW = new Date('2026-11-12T12:00:00Z');
const base = ['--project', 'az-express-b0469', '--platform', 'android', '--build', '11',
  '--source', 'google-play-console', '--detail', 'piste production, Disponible', '--verified-at', '2026-11-12T09:30:00+00:00',
  '--evidence', 'capture-play.png', '--operator', 'op'];
const args = (patch = {}) => ({ ...parseArgs(base), ...patch });
const refuses = (fn, code) => assert.throws(fn, (e) => e.code === code, code);

test('entrée valide normalisée', () => {
  const e = validateInput(args(), NOW);
  assert.equal(e.latestBuild, 11); assert.equal(e.platform, 'android');
  assert.equal(e.verifiedAt.toISOString(), '2026-11-12T09:30:00.000Z');
  assert.equal(confirmationToken(e), 'az-express-b0469:android:11');
});

test('projet : absent ou non reconnu refusé, demo-* accepté', () => {
  refuses(() => validateInput(args({ project: undefined }), NOW), 'MISSING_FIELD');
  for (const p of ['az-express-clean', 'prod', 'az-express-b0469-x', 'demo_x', 'DEMO-x']) refuses(() => validateInput(args({ project: p }), NOW), 'UNKNOWN_PROJECT');
  assert.equal(validateInput(args({ project: 'demo-m23' }), NOW).project, 'demo-m23');
});

test('plateforme et build : valeurs manquantes ou incohérentes refusées', () => {
  refuses(() => validateInput(args({ platform: 'web' }), NOW), 'INVALID_PLATFORM');
  refuses(() => validateInput(args({ platform: undefined }), NOW), 'MISSING_FIELD');
  for (const b of ['0', '-1', '1.5', '14.0', '011', '1e3', 'abc', '', ' ', '2100000001', '+5', '99999999999']) {
    assert.throws(() => validateInput(args({ build: b }), NOW), (e) => ['INVALID_BUILD', 'MISSING_FIELD'].includes(e.code), b);
  }
  refuses(() => validateInput(args({ build: undefined }), NOW), 'MISSING_FIELD');
  assert.equal(validateInput(args({ build: '2100000000' }), NOW).latestBuild, 2100000000);
});

test('source, détail, preuve, opérateur obligatoires', () => {
  refuses(() => validateInput(args({ source: undefined }), NOW), 'MISSING_FIELD');
  refuses(() => validateInput(args({ detail: undefined }), NOW), 'MISSING_FIELD');
  refuses(() => validateInput(args({ detail: 'court' }), NOW), 'INVALID_DETAIL');
  refuses(() => validateInput(args({ evidence: undefined }), NOW), 'MISSING_FIELD');
  refuses(() => validateInput(args({ operator: '  ' }), NOW), 'MISSING_FIELD');
});

test('verifiedAt : fuseau obligatoire, ni futur, ni périmé, ni invalide', () => {
  for (const d of ['2026-11-12', '2026-11-12T09:30:00', '12/11/2026', 'hier', '2026-13-45T00:00:00Z']) {
    refuses(() => validateInput(args({ verifiedAt: d }), NOW), 'INVALID_VERIFIED_AT');
  }
  refuses(() => validateInput(args({ verifiedAt: undefined }), NOW), 'MISSING_FIELD');
  refuses(() => validateInput(args({ verifiedAt: '2026-11-13T09:30:00Z' }), NOW), 'VERIFIED_AT_IN_FUTURE');
  refuses(() => validateInput(args({ verifiedAt: '2026-09-01T09:30:00Z' }), NOW), 'VERIFIED_AT_STALE');
});

test('parseArgs : argument inconnu, valeur manquante, doublon', () => {
  refuses(() => parseArgs(['--enforce', 'true']), 'UNKNOWN_ARGUMENT');
  refuses(() => parseArgs(['--project']), 'MISSING_VALUE');
  refuses(() => parseArgs(['--project', '--platform', 'ios']), 'MISSING_VALUE');
  refuses(() => parseArgs(['--build', '1', '--build', '2']), 'DUPLICATE_ARGUMENT');
});

test('cible : demo sans émulateur et projet réel avec émulateur refusés', () => {
  const real = validateInput(args(), NOW); const demo = validateInput(args({ project: 'demo-x' }), NOW);
  refuses(() => checkTarget(demo, {}), 'EMULATOR_REQUIRED');
  refuses(() => checkTarget(real, { FIRESTORE_EMULATOR_HOST: 'localhost:8080' }), 'TARGET_MISMATCH');
  assert.doesNotThrow(() => checkTarget(demo, { FIRESTORE_EMULATOR_HOST: 'localhost:8080' }));
  assert.doesNotThrow(() => checkTarget(real, {}));
});

test('simulation par défaut : aucun accès au SDK, texte explicite, jamais enforce', async () => {
  const lines = [];
  const before = require.cache[require.resolve('firebase-admin')];
  assert.equal(await main(base, {}, (l) => lines.push(l), NOW), 'dry-run');
  assert.match(lines.join('\n'), /SIMULATION/); assert.match(lines.join('\n'), /--confirm az-express-b0469:android:11/);
  assert.match(lines.join('\n'), /enforce : jamais écrit/);
  assert.equal(require.cache[require.resolve('firebase-admin')], before); // SDK non chargé par la simulation
  assert.match(describePlan(validateInput(args(), NOW)), /android\.latestBuild = 11/);
});

test('--apply sans confirmation ou avec mauvaise confirmation refusé avant tout accès', async () => {
  await assert.rejects(main([...base, '--apply'], {}, () => {}, NOW), (e) => e.code === 'CONFIRMATION_REQUIRED');
  await assert.rejects(main([...base, '--apply', '--confirm', 'az-express-b0469:android:12'], {}, () => {}, NOW), (e) => e.code === 'CONFIRMATION_MISMATCH');
  await assert.rejects(main([...base, '--apply', '--confirm', 'x'], { FIRESTORE_EMULATOR_HOST: 'h:1' }, () => {}, NOW), (e) => e.code === 'TARGET_MISMATCH');
});

// Faux Firestore en mémoire pour applyUpdate.
function fakeDb(initial) {
  const store = new Map(initial ? [['config/app_release_registry', initial]] : []);
  const audits = [];
  const ref = (p) => ({ p, get: async () => ({ exists: store.has(p), data: () => store.get(p) }) });
  return {
    store, audits,
    collection: (c) => ({ doc: (d) => ref(`${c}/${d}`), add: async (x) => { audits.push(x); } }),
    runTransaction: async (fn) => fn({
      get: (r) => r.get(),
      set: (r, data) => { store.set(r.p, { ...(store.get(r.p) || {}), ...data }); },
    }),
  };
}
const deps = { fieldValue: { serverTimestamp: () => 'TS' }, Timestamp: { fromDate: (d) => ({ ts: d.toISOString() }) } };

test('applyUpdate : écrit la plateforme, conserve l’autre, audite, n’écrit pas enforce', async () => {
  const db = fakeDb({ ios: { latestBuild: 3, source: 's' } });
  const entry = validateInput(args(), NOW);
  await applyUpdate({ db, ...deps, entry, confirm: confirmationToken(entry) });
  const doc = db.store.get('config/app_release_registry');
  assert.equal(doc.android.latestBuild, 11); assert.equal(doc.ios.latestBuild, 3);
  assert.equal(doc.android.verifiedAt.ts, '2026-11-12T09:30:00.000Z');
  assert.ok(!('enforce' in doc) && !('enforce' in doc.android));
  assert.equal(db.audits[0].action, 'app_release_registry_update');
  assert.equal(db.audits[0].metadata.before, null); assert.equal(db.audits[0].metadata.after.latestBuild, 11);
});

test('applyUpdate : mauvaise confirmation et baisse de build refusées sans écriture', async () => {
  const db = fakeDb({ android: { latestBuild: 20, source: 's' } });
  const entry = validateInput(args(), NOW);
  await assert.rejects(applyUpdate({ db, ...deps, entry, confirm: 'non' }), (e) => e.code === 'CONFIRMATION_MISMATCH');
  await assert.rejects(applyUpdate({ db, ...deps, entry, confirm: confirmationToken(entry) }), (e) => e.code === 'BUILD_DECREASE');
  assert.equal(db.store.get('config/app_release_registry').android.latestBuild, 20);
  assert.equal(db.audits.length, 0);
});

const ios = (patch = {}) => args({ platform: 'ios', source: 'app-store-connect', ...patch });

test('sources officielles acceptées : Play pour Android, App Store pour iOS', () => {
  assert.equal(validateInput(args(), NOW).source, 'google-play-console');
  assert.equal(validateInput(ios(), NOW).source, 'app-store-connect');
});

test('Android : toute source autre que Google Play refusée, APK direct compris', () => {
  for (const src of ['apk-direct', 'APK direct latest.json', 'direct-apk', 'app-store-connect', 'testflight', 'firebase-app-distribution',
    'internal-testing', 'Google Play Console', 'google-play-console ,apk', 'google-play-console,apk', 'latest.json']) {
    refuses(() => validateInput(args({ source: src }), NOW), 'UNAUTHORIZED_SOURCE');
  }
  refuses(() => validateInput(args({ source: '' }), NOW), 'MISSING_FIELD');
  // La source seule décide : un détail qui mentionne Google Play ne rend pas valide un APK direct.
  refuses(() => validateInput(args({ source: 'apk-direct', detail: 'google-play-console production' }), NOW), 'UNAUTHORIZED_SOURCE');
});

test('iOS : toute source autre qu’App Store Connect refusée (Play, TestFlight, APK)', () => {
  for (const src of ['google-play-console', 'testflight', 'apk-direct', 'App Store Connect', 'app-store']) {
    refuses(() => validateInput(ios({ source: src }), NOW), 'UNAUTHORIZED_SOURCE');
  }
});

test('build APK direct (latest.json) jamais enregistrable comme build Play, en simulation comme en écriture', async () => {
  const apk = ['--project', 'az-express-b0469', '--platform', 'android', '--build', '11', '--source', 'apk-direct',
    '--detail', 'web/distribution/latest.json', '--verified-at', '2026-11-12T09:30:00Z', '--evidence', 'e', '--operator', 'op'];
  await assert.rejects(main(apk, {}, () => {}, NOW), (e) => e.code === 'UNAUTHORIZED_SOURCE');
  await assert.rejects(main([...apk, '--apply', '--confirm', 'az-express-b0469:android:11'], {}, () => {}, NOW), (e) => e.code === 'UNAUTHORIZED_SOURCE');
});

test('seconde vérification : facultative mais, si fournie, différente de l’opérateur', async () => {
  assert.equal(validateInput(args(), NOW).secondVerifier, null);
  assert.equal(validateInput(args({ secondVerifier: 'Autre' }), NOW).secondVerifier, 'Autre');
  refuses(() => validateInput(args({ secondVerifier: 'OP' }), NOW), 'SAME_VERIFIER');
  refuses(() => validateInput(args({ secondVerifier: ' ' }), NOW), 'MISSING_FIELD');
  const lines = [];
  await main(base, {}, (l) => lines.push(l), NOW);
  assert.match(lines.join('\n'), /aucune seconde vérification/);
  const withSecond = [];
  await main([...base, '--second-verifier', 'Autre'], {}, (l) => withSecond.push(l), NOW);
  assert.match(withSecond.join('\n'), /Seconde vérification déclarée : Autre/);
});

test('applyUpdate : source, détail et seconde vérification conservés dans le registre et l’audit', async () => {
  const db = fakeDb(null);
  const entry = validateInput(ios({ secondVerifier: 'Autre' }), NOW);
  await applyUpdate({ db, ...deps, entry, confirm: confirmationToken(entry) });
  const doc = db.store.get('config/app_release_registry').ios;
  assert.equal(doc.source, 'app-store-connect'); assert.equal(doc.sourceDetail, 'piste production, Disponible'); assert.equal(doc.secondVerifier, 'Autre');
  assert.equal(db.audits[0].metadata.secondVerifier, 'Autre');
});
