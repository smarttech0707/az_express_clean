'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildManageArtisanPhotos, storagePathFromUrl, MAX_PHOTOS, MAX_BYTES } = require('../artisanPhotos');
const { fakeDb } = require('./fakeFirestore');

const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 1)]).toString('base64');
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)]).toString('base64');
const urlFor = (docId, name) => `https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/${encodeURIComponent(`service_providers/${docId}/${name}`)}?alt=media&token=t`;

function setup({ provider = {}, extra = {}, failSave = false } = {}) {
  const db = fakeDb({
    'service_providers/s1': { name: 'Maçon', phone: '0700000001', artisanUid: 'anon-A', photos: [], ...provider },
    'service_providers/s2': { name: 'Autre', artisanUid: 'anon-B', photos: [urlFor('s2', 'photo_1.jpg')] },
    ...extra,
  });
  const files = new Map(), deleted = [], audits = [];
  const bucket = {
    name: 'demo.appspot.com',
    file: (path) => ({
      save: async (buf, opts) => { if (failSave) throw new Error('storage down'); files.set(path, { buf, opts }); },
      delete: async () => { deleted.push(path); files.delete(path); },
    }),
  };
  const run = buildManageArtisanPhotos({
    db, admin: {}, bucket, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); }, now: () => 1700000000000,
  }).run;
  const req = (data, uid = 'anon-A') => ({ auth: uid ? { uid, token: { firebase: { sign_in_provider: 'anonymous' } } } : undefined, data });
  return { db, files, deleted, audits, run, req };
}
const photos = (h, id = 's1') => h.db.store.get(`service_providers/${id}`).photos;

test('artisan lié : ajout de photo (JPEG et PNG), fichier sous son dossier, URL enregistrée, audit', async () => {
  const h = setup();
  const res = await h.run(h.req({ action: 'add', docId: 's1', imageBase64: JPEG }));
  assert.equal(res.success, true);
  assert.equal(photos(h).length, 1);
  assert.equal(photos(h)[0], res.data.url);
  const [path] = [...h.files.keys()];
  assert.match(path, /^service_providers\/s1\/photo_1700000000000_[0-9a-f]{8}\.jpg$/);
  assert.equal(h.files.get(path).opts.contentType, 'image/jpeg');
  assert.equal(storagePathFromUrl(res.data.url), path);
  await h.run(h.req({ action: 'add', docId: 's1', imageBase64: PNG }));
  assert.equal(photos(h).length, 2);
  assert.equal(h.audits.length, 2);
});

test('artisan lié : suppression d\'une de SES photos (fichier effacé, profil mis à jour)', async () => {
  const mine = urlFor('s1', 'photo_1.jpg'), other = urlFor('s1', 'photo_2.jpg');
  const h = setup({ provider: { photos: [mine, other] } });
  await h.run(h.req({ action: 'delete', docId: 's1', url: mine }));
  assert.deepEqual(photos(h), [other]);
  assert.deepEqual(h.deleted, ['service_providers/s1/photo_1.jpg']);
});

test('artisan non autorisé : autre artisan, session non liée, non connecté — aucune modification', async () => {
  const h = setup();
  const before = JSON.stringify([...h.db.store.entries()]);
  const attempts = [
    h.req({ action: 'add', docId: 's1', imageBase64: JPEG }, 'anon-B'),            // un autre artisan
    h.req({ action: 'add', docId: 's1', imageBase64: JPEG }, 'intrus'),            // session non liée
    h.req({ action: 'add', docId: 'inconnu', imageBase64: JPEG }),                 // profil inexistant
    h.req({ action: 'delete', docId: 's2', url: urlFor('s2', 'photo_1.jpg') }),    // photo d'un autre profil
    h.req({ action: 'delete', docId: 's1', url: urlFor('s2', 'photo_1.jpg') }, 'anon-B'),
  ];
  for (const request of attempts) await assert.rejects(() => h.run(request), (e) => e.code === 'permission-denied');
  await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's1', imageBase64: JPEG }, null)), (e) => e.code === 'unauthenticated');
  assert.equal(JSON.stringify([...h.db.store.entries()]), before);
  assert.equal(h.files.size, 0);
  assert.equal(h.deleted.length, 0);
});

test('profil sans liaison (artisanUid absent) : personne ne peut écrire', async () => {
  const h = setup({ extra: { 'service_providers/s3': { name: 'Sans liaison', photos: [] } } });
  await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's3', imageBase64: JPEG })),
    (e) => e.code === 'permission-denied');
});

test('suppression : refus d\'une URL hors du profil, d\'un chemin détourné ou d\'une photo non listée', async () => {
  const listed = urlFor('s1', 'photo_1.jpg');
  const h = setup({ provider: { photos: [listed] } });
  for (const url of [
    urlFor('s2', 'photo_1.jpg'),                                                         // dossier d'un autre profil
    'https://x/o/' + encodeURIComponent('service_providers/s1/../s2/photo_1.jpg') + '?alt=media',
    'https://x/o/' + encodeURIComponent('service_providers/s1/sub/photo_1.jpg') + '?alt=media',
    'pas une url', '', undefined,
  ]) {
    await assert.rejects(() => h.run(h.req({ action: 'delete', docId: 's1', url })), (e) => e.code === 'invalid-argument');
  }
  await assert.rejects(() => h.run(h.req({ action: 'delete', docId: 's1', url: urlFor('s1', 'inconnue.jpg') })), (e) => e.code === 'not-found');
  assert.deepEqual(photos(h), [listed]);
  assert.equal(h.deleted.length, 0);
});

test('fichiers invalides, trop gros, faux types ou plafond de photos : refusés sans écriture', async () => {
  const tooBig = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(MAX_BYTES)]).toString('base64');
  for (const imageBase64 of [undefined, '', 'pas du base64 valide !!', Buffer.from('<?php evil ?>').toString('base64'), tooBig]) {
    const h = setup();
    await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's1', imageBase64 })), (e) => e.code === 'invalid-argument');
    assert.equal(h.files.size, 0);
    assert.equal(photos(h).length, 0);
  }
  const full = Array.from({ length: MAX_PHOTOS }, (_, i) => urlFor('s1', `p${i}.jpg`));
  const h = setup({ provider: { photos: full } });
  await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's1', imageBase64: JPEG })), (e) => e.code === 'failed-precondition');
  assert.equal(h.files.size, 0);
});

test('compte en cours de suppression : modification refusée ; échec Storage : aucune photo enregistrée', async () => {
  let h = setup({ provider: { deletionRequested: true } });
  await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's1', imageBase64: JPEG })), (e) => e.code === 'failed-precondition');
  h = setup({ failSave: true });
  await assert.rejects(() => h.run(h.req({ action: 'add', docId: 's1', imageBase64: JPEG })));
  assert.equal(photos(h).length, 0);
});
