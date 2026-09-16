'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  ref, uploadBytes, deleteObject, getBytes,
} = require('firebase/storage');

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'az-express-b0469',
    storage: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'storage.rules'), 'utf8'),
    },
    firestore: {},
  });
});

test.after(async () => testEnv.cleanup());

function storageFor(uid, provider = 'password') {
  return testEnv.authenticatedContext(uid, {
    firebase: { sign_in_provider: provider },
  }).storage();
}

async function seedAdmin(uid, data) {
  await testEnv.withSecurityRulesDisabled((context) =>
    context.firestore().doc(`admins/${uid}`).set(data));
}

const image = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const video = new Uint8Array([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70]);

test('Auto Moto Storage: propriétaire peut uploader une image valide', async () => {
  await assertSucceeds(uploadBytes(
    ref(storageFor('seller1'), 'vehicle_listings/seller1/listing1/images/p1.jpg'),
    image,
    { contentType: 'image/jpeg' },
  ));
});

test('Auto Moto Storage: autre utilisateur, anonyme et non authentifié refusés', async () => {
  const path = 'vehicle_listings/seller1/listing1/images/p1.jpg';
  await assertFails(uploadBytes(ref(storageFor('seller2'), path), image, {
    contentType: 'image/jpeg',
  }));
  await assertFails(uploadBytes(ref(storageFor('seller1', 'anonymous'), path), image, {
    contentType: 'image/jpeg',
  }));
  await assertFails(uploadBytes(ref(testEnv.unauthenticatedContext().storage(), path), image, {
    contentType: 'image/jpeg',
  }));
});

test('Auto Moto Storage: image trop grosse et mauvais contentType refusés', async () => {
  const storage = storageFor('seller1');
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_listings/seller1/listing1/images/large.jpg'),
    new Uint8Array(5 * 1024 * 1024),
    { contentType: 'image/jpeg' },
  ));
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_listings/seller1/listing1/images/text.jpg'),
    image,
    { contentType: 'text/plain' },
  ));
});

test('Auto Moto Storage: vidéo valide autorisée et vidéo trop grosse refusée', async () => {
  const storage = storageFor('seller1');
  await assertSucceeds(uploadBytes(
    ref(storage, 'vehicle_listings/seller1/listing1/videos/v1.mp4'),
    video,
    { contentType: 'video/mp4' },
  ));
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_listings/seller1/listing1/videos/large.mp4'),
    new Uint8Array(20 * 1024 * 1024),
    { contentType: 'video/mp4' },
  ));
});

test('Auto Moto Storage: assertions du harnais exécutées', () => {
  assert.ok(testEnv);
});

test('Auto Moto logo: propriétaire upload et supprime une image valide', async () => {
  const logo = ref(
    storageFor('seller1'),
    'vehicle_seller_profiles/seller1/logo/logo1.jpg',
  );
  await assertSucceeds(uploadBytes(logo, image, { contentType: 'image/jpeg' }));
  await assertSucceeds(deleteObject(logo));
});

test('Auto Moto logo: cross-user, anonyme et non authentifié refusés', async () => {
  const path = 'vehicle_seller_profiles/seller1/logo/logo1.jpg';
  await assertFails(uploadBytes(ref(storageFor('seller2'), path), image, {
    contentType: 'image/jpeg',
  }));
  await assertFails(uploadBytes(
    ref(storageFor('seller1', 'anonymous'), path),
    image,
    { contentType: 'image/jpeg' },
  ));
  await assertFails(uploadBytes(
    ref(testEnv.unauthenticatedContext().storage(), path),
    image,
    { contentType: 'image/jpeg' },
  ));
});

test('Auto Moto logo: vidéo, faux type et image trop volumineuse refusés', async () => {
  const storage = storageFor('seller1');
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_seller_profiles/seller1/logo/video.jpg'),
    video,
    { contentType: 'video/mp4' },
  ));
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_seller_profiles/seller1/logo/text.jpg'),
    image,
    { contentType: 'text/plain' },
  ));
  await assertFails(uploadBytes(
    ref(storage, 'vehicle_seller_profiles/seller1/logo/large.jpg'),
    new Uint8Array(2 * 1024 * 1024 + 1),
    { contentType: 'image/jpeg' },
  ));
});

test('Auto Moto logo: suppression cross-user refusée', async () => {
  const path = 'vehicle_seller_profiles/seller1/logo/logo1.jpg';
  await assertSucceeds(uploadBytes(ref(storageFor('seller1'), path), image, {
    contentType: 'image/jpeg',
  }));
  await assertFails(deleteObject(ref(storageFor('seller2'), path)));
});

test('Services simples Storage: client lit photo.jpg mais jamais id_photo.jpg', async () => {
  await seedAdmin('admin-simple', { role: 'super', isActive: true });
  const adminStorage = storageFor('admin-simple');
  const publicPhoto = 'simple_services/s1/photo.jpg';
  const privatePhoto = 'simple_services/s1/id_photo.jpg';
  await assertSucceeds(uploadBytes(ref(adminStorage, publicPhoto), image, {
    contentType: 'image/jpeg',
  }));
  await assertSucceeds(uploadBytes(ref(adminStorage, privatePhoto), image, {
    contentType: 'image/jpeg',
  }));
  await assertSucceeds(getBytes(ref(storageFor('client1'), publicPhoto)));
  await assertFails(getBytes(ref(storageFor('client1'), privatePhoto)));
  await assertFails(getBytes(
    ref(testEnv.unauthenticatedContext().storage(), publicPhoto),
  ));
});

test('Services simples Storage: sous-admin habilité gère les justificatifs, client refusé', async () => {
  await seedAdmin('sub-simple', {
    role: 'sub', isActive: true, permissions: ['tricycle'],
  });
  const privatePhoto = 'simple_services/s2/id_photo.jpg';
  await assertSucceeds(uploadBytes(
    ref(storageFor('sub-simple'), privatePhoto),
    image,
    { contentType: 'image/jpeg' },
  ));
  await assertSucceeds(getBytes(ref(storageFor('sub-simple'), privatePhoto)));
  await assertFails(uploadBytes(
    ref(storageFor('client2'), privatePhoto),
    image,
    { contentType: 'image/jpeg' },
  ));
});
