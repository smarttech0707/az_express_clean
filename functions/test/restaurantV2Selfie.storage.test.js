'use strict';

// Mission 7E-39 — le selfie synthétique face aux VRAIES règles storage.rules (émulateurs Storage + Firestore, projet demo-az-t7e-st).
//   firebase emulators:exec --config <config alternative> --only firestore,storage --project demo-az-t7e-st \
//     "node --test functions/test/restaurantV2Selfie.storage.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const emulated = Boolean(process.env.FIREBASE_STORAGE_EMULATOR_HOST) && Boolean(process.env.FIRESTORE_EMULATOR_HOST) && process.env.GCLOUD_PROJECT === 'demo-az-t7e-st';
const options = { skip: emulated ? false : 'émulateurs Storage et Firestore requis (projet demo-az-t7e-st)' };
const root = path.join(__dirname, '..', '..');
const selfie = require(path.join(root, 'scripts', 'restaurant-v2-pilot', 'selfie'));
const { storageObjectOfUrl } = require('../proofStorage');

const PROJECT = 'demo-az-t7e-st';
const BUCKET = `${PROJECT}.appspot.com`;
const ORDER = 'order-selfie-1';
let env; let fbStorage;

test.before(async () => {
  if (!emulated) return;
  const { initializeTestEnvironment } = require(path.join(root, 'node_modules', '@firebase', 'rules-unit-testing'));
  fbStorage = require(path.join(root, 'node_modules', 'firebase', 'storage'));
  const [fHost, fPort] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
  const [sHost, sPort] = process.env.FIREBASE_STORAGE_EMULATOR_HOST.split(':');
  env = await initializeTestEnvironment({
    projectId: PROJECT,
    firestore: { host: fHost, port: Number(fPort) },
    storage: { host: sHost, port: Number(sPort), rules: fs.readFileSync(path.join(root, 'storage.rules'), 'utf8') },
  });
});
test.after(async () => { if (env) await env.cleanup(); });

const as = (uid, provider = 'password') => env.authenticatedContext(uid, { firebase: { sign_in_provider: provider } }).storage(`gs://${BUCKET}`);
const put = (storage, objectPath, bytes, contentType) => fbStorage.uploadBytes(fbStorage.ref(storage, objectPath), bytes, { contentType });

test('le selfie synthétique est accepté par storage.rules sous le chemin exact du livreur fictif', options, async () => {
  const bytes = new Uint8Array(selfie.selfieBytes());
  const objectPath = selfie.selfiePath(ORDER);
  assert.equal(objectPath, `acceptance_selfies/${ORDER}/t7e-driver.jpg`);
  await put(as('t7e-driver'), objectPath, bytes, selfie.CONTENT_TYPE);
  // L'URL de téléchargement attendue par acceptOrderCF désigne bien cet objet.
  const url = selfie.downloadUrl(objectPath, 'tok', BUCKET);
  assert.equal(storageObjectOfUrl(url, BUCKET), objectPath);
  // Le livreur relit son propre selfie ; un autre compte ne le lit pas.
  await fbStorage.getMetadata(fbStorage.ref(as('t7e-driver'), objectPath));
  await assert.rejects(fbStorage.getMetadata(fbStorage.ref(as('t7e-client'), objectPath)));
});

test('refus : autre compte, anonyme, mauvais nom, mauvais type, 5 Mo ou plus', options, async () => {
  const bytes = new Uint8Array(selfie.selfieBytes());
  const objectPath = selfie.selfiePath('order-selfie-2');
  await assert.rejects(put(as('t7e-client'), objectPath, bytes, 'image/jpeg'), 'autre compte');
  await assert.rejects(put(as('t7e-driver', 'anonymous'), objectPath, bytes, 'image/jpeg'), 'anonyme');
  await assert.rejects(put(as('t7e-driver'), 'acceptance_selfies/order-selfie-2/autre.jpg', bytes, 'image/jpeg'), 'mauvais nom');
  await assert.rejects(put(as('t7e-driver'), objectPath, bytes, 'text/plain'), 'mauvais type');
  await assert.rejects(put(as('t7e-driver'), objectPath, new Uint8Array(selfie.MAX_BYTES), 'image/jpeg'), '5 Mo');
  await assert.rejects(put(env.unauthenticatedContext().storage(`gs://${BUCKET}`), objectPath, bytes, 'image/jpeg'), 'sans compte');
});
