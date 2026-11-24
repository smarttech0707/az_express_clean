'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { loadAuthorizedKeys, labelKey, auditDirectory } = require('./audit-apk-content');

// Formes plausibles de cles API Google (fausses, memes gabarit "AIza" + 35 caracteres).
const FIREBASE_KEY = 'AIza' + 'F'.repeat(35);
const MAPS_TEST_KEY = 'AIza' + 'M'.repeat(35);
const PROD_KEY = 'AIza' + 'P'.repeat(35);
const UNKNOWN_KEY = 'AIza' + 'U'.repeat(35);

function tmpDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function writeGoogleServices(dir, key) {
  const file = path.join(dir, 'google-services.json');
  fs.writeFileSync(file, JSON.stringify({ client: [{ api_key: [{ current_key: key }] }] }));
  return file;
}

function writeKeyFile(dir, value) {
  const file = path.join(dir, 'test_maps_key.txt');
  fs.writeFileSync(file, value);
  return file;
}

test('loadAuthorizedKeys refuses a test Maps key file with an invalid shape', () => {
  const dir = tmpDir('az-audit-');
  const gs = writeGoogleServices(dir, FIREBASE_KEY);
  const keyFile = writeKeyFile(dir, 'not-a-real-key');
  assert.throws(() => loadAuthorizedKeys(gs, keyFile), /n'a pas la forme/);
});

test('loadAuthorizedKeys accepts no test Maps key file (maps-disabled case)', () => {
  const dir = tmpDir('az-audit-');
  const gs = writeGoogleServices(dir, FIREBASE_KEY);
  const { testKey, mapsKey } = loadAuthorizedKeys(gs, null);
  assert.ok(testKey.includes(FIREBASE_KEY));
  assert.equal(mapsKey, null);
});

test('loadAuthorizedKeys accepts a well-formed test Maps key', () => {
  const dir = tmpDir('az-audit-');
  const gs = writeGoogleServices(dir, FIREBASE_KEY);
  const keyFile = writeKeyFile(dir, MAPS_TEST_KEY);
  const { mapsKey } = loadAuthorizedKeys(gs, keyFile);
  assert.equal(mapsKey, MAPS_TEST_KEY);
});

test('labelKey authorizes the exact preprod test Maps key only', () => {
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  assert.equal(labelKey(MAPS_TEST_KEY, authorized), 'cle Maps de TEST (attendue)');
  assert.equal(labelKey(FIREBASE_KEY, authorized), 'cle Firebase de TEST (attendue)');
  // Une cle differente, meme proche (un seul caractere change), reste inconnue : comparaison stricte,
  // jamais par prefixe.
  const almost = MAPS_TEST_KEY.slice(0, -1) + 'x';
  assert.equal(labelKey(almost, authorized), null);
});

test('labelKey refuses an unknown key', () => {
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  assert.equal(labelKey(UNKNOWN_KEY, authorized), null);
});

test('labelKey never authorizes the production key as a client key', () => {
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  assert.equal(labelKey(PROD_KEY, authorized), null);
});

test('labelKey never treats GOOGLE_MAPS_SERVER_KEY as an authorized client key', () => {
  // Le script ne lit jamais GOOGLE_MAPS_SERVER_KEY : meme si sa valeur apparaissait par erreur dans
  // l'APK, elle n'est dans aucune des deux listes autorisees et reste donc inconnue.
  const serverKeyFoundByMistake = 'AIza' + 'S'.repeat(35);
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  assert.equal(labelKey(serverKeyFoundByMistake, authorized), null);
});

test('auditDirectory accepts the preprod test Maps key embedded in the APK content', () => {
  const dir = tmpDir('az-apk-');
  fs.writeFileSync(path.join(dir, 'AndroidManifest.xml'), `key=${MAPS_TEST_KEY}`);
  fs.writeFileSync(path.join(dir, 'kernel_blob.bin'), `fb=${FIREBASE_KEY}`);
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  const report = auditDirectory(dir, authorized);
  assert.equal(report.bad, 0);
  assert.deepEqual(report.unknownKeys, []);
});

test('auditDirectory flags an unknown key and fails the audit', () => {
  const dir = tmpDir('az-apk-');
  fs.writeFileSync(path.join(dir, 'AndroidManifest.xml'), `key=${UNKNOWN_KEY}`);
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  const report = auditDirectory(dir, authorized);
  assert.equal(report.bad, 1);
  assert.deepEqual(report.unknownKeys, [UNKNOWN_KEY]);
});

test('auditDirectory flags the production key as unknown (defense in depth)', () => {
  const dir = tmpDir('az-apk-');
  fs.writeFileSync(path.join(dir, 'AndroidManifest.xml'), `key=${PROD_KEY}`);
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: MAPS_TEST_KEY };
  const report = auditDirectory(dir, authorized);
  assert.equal(report.bad, 1);
  assert.deepEqual(report.unknownKeys, [PROD_KEY]);
});

test('auditDirectory accepts no Maps key at all when none is required (maps-disabled)', () => {
  const dir = tmpDir('az-apk-');
  fs.writeFileSync(path.join(dir, 'kernel_blob.bin'), `fb=${FIREBASE_KEY}`);
  const authorized = { testKey: [FIREBASE_KEY], mapsKey: null };
  const report = auditDirectory(dir, authorized);
  assert.equal(report.bad, 0);
});
