'use strict';

// Mission 7E-11-U — l'URL du selfie d'acceptation est validée comme celle de la photo de livraison (proofStorage.js) :
// hôte Firebase Storage, bucket du projet (alias .appspot.com / .firebasestorage.app tolérés), chemin exact
// acceptance_selfies/<commande>/<livreur>.jpg. Le parcours d'acceptation légitime et ses rejeux restent inchangés.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAcceptOrder } = require('../driverAcceptance');
const { calculateCommission } = require('../dispatch');
const { fakeDb, DELETE } = require('./fakeFirestore');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE } } };
const BUCKET = 'demo-proj.firebasestorage.app';
const urlOf = (objectPath, { bucket = BUCKET, host = 'firebasestorage.googleapis.com', scheme = 'https', query = 'alt=media&token=t1' } = {}) =>
  `${scheme}://${host}/v0/b/${bucket}/o/${encodeURIComponent(objectPath)}?${query}`;
const GOOD = urlOf('acceptance_selfies/o1/d1.jpg');

function setup({ bucketName = () => BUCKET, selfieExists = async () => true } = {}) {
  const db = fakeDb({
    'orders/o1': { status: 'assigned', driverId: 'd1', budget: 500, description: 'Course test' },
    'livreurs/d1': { wallet: 1000, isOnline: true },
  });
  const run = buildAcceptOrder({
    db, admin, onCall: (handler) => ({ run: handler }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
    selfieExists, selfieBucketName: bucketName,
  }).run;
  const call = (acceptanceSelfieUrl) => run({
    auth: { uid: 'd1', token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: 'o1', acceptanceSelfieUrl },
  });
  return { db, call, order: () => db.store.get('orders/o1'), wallet: () => db.store.get('livreurs/d1').wallet };
}
const required = (e) => e.code === 'failed-precondition' && e.message === 'SELFIE_REQUIRED';

test('URL Firebase conforme (bon bucket, alias du bucket, paramètres supplémentaires) : acceptée, une seule commission', async () => {
  for (const url of [GOOD, urlOf('acceptance_selfies/o1/d1.jpg', { bucket: 'demo-proj.appspot.com' }),
    urlOf('acceptance_selfies/o1/d1.jpg', { query: 'alt=media&token=a-b-c&extra=1' }), urlOf('acceptance_selfies/o1/d1.jpg', { query: 'alt=media' })]) {
    const t = setup();
    assert.equal((await t.call(url)).success, true, url);
    assert.equal(t.order().status, 'accepted');
    assert.equal(t.order().driverAcceptanceSelfie, url);
    assert.equal(t.wallet(), 900);
  }
});

test('URL étrangère contenant le bon chemin, schéma http, bucket d\'un autre projet, chemin détourné : refusée, aucun prélèvement', async () => {
  const bad = [
    'https://evil.example/acceptance_selfies/o1/d1.jpg',
    `https://evil.example/v0/b/${BUCKET}/o/acceptance_selfies%2Fo1%2Fd1.jpg?alt=media`,
    urlOf('acceptance_selfies/o1/d1.jpg', { scheme: 'http' }),
    urlOf('acceptance_selfies/o1/d1.jpg', { bucket: 'autre-projet.firebasestorage.app' }),
    urlOf('acceptance_selfies/o1/d1.jpg', { host: 'evil.example' }),
    `https://u:p@firebasestorage.googleapis.com/v0/b/${BUCKET}/o/acceptance_selfies%2Fo1%2Fd1.jpg`,
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/acceptance_selfies/o1/d1.jpg`,
    `https://evil.example/x?u=${encodeURIComponent(GOOD)}`,
    urlOf('acceptance_selfies/o2/d1.jpg'), urlOf('acceptance_selfies/o1/d2.jpg'), urlOf('acceptance_selfies/o1/d1.jpg.evil'),
    urlOf('delivery_photos/d1/o1.jpg'), urlOf('x/acceptance_selfies/o1/d1.jpg'), 'not a url',
  ];
  for (const url of bad) {
    const t = setup();
    await assert.rejects(t.call(url), required, String(url).slice(0, 80));
    assert.equal(t.order().status, 'assigned');
    assert.equal(t.wallet(), 1000);
  }
});

test('valeur qui n est pas une chaîne : refus de forme existant (invalid-argument), aucun prélèvement', async () => {
  for (const url of [42, {}, true]) {
    const t = setup();
    await assert.rejects(t.call(url), (e) => e.code === 'invalid-argument');
    assert.equal(t.wallet(), 1000);
  }
});

test('nom du bucket indisponible (absent, erreur, vide) : le bucket n\'est pas vérifié, jamais un motif de refus de l\'acceptation', async () => {
  for (const bucketName of [null, () => { throw new Error('indisponible'); }, () => undefined, () => '']) {
    const t = setup({ bucketName });
    assert.equal((await t.call(urlOf('acceptance_selfies/o1/d1.jpg', { bucket: 'peu-importe.appspot.com' }))).success, true);
  }
});

test('fichier absent de Storage : toujours refusé même avec une URL conforme', async () => {
  const t = setup({ selfieExists: async () => false });
  await assert.rejects(t.call(GOOD), required);
  assert.equal(t.wallet(), 1000);
});

test('rejeu par le même livreur sans photo : succès sans second prélèvement (inchangé)', async () => {
  const t = setup();
  await t.call(GOOD);
  const replay = await t.call(undefined);
  assert.equal(replay.alreadyAccepted, true);
  assert.equal(t.wallet(), 900);
});

test('index.js fournit le nom du bucket à acceptOrderCF', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const at = src.indexOf('exports.acceptOrderCF');
  assert.match(src.slice(at, src.indexOf('\nexports.', at + 10)), /selfieBucketName:/);
});
