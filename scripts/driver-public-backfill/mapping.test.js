'use strict';

// Tests du mapping pur `livreurs` → `driver_public` (SEC-01, préparation S3).
// Fixtures entièrement locales, en mémoire — aucun accès Firebase.
//
// Exécution : node --test scripts/driver-public-backfill/mapping.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const { mapDriverToPublic, FIELD_MAP, FORBIDDEN_FIELDS } = require('./mapping');

test('mapping correct des champs autorisés, document complet et valide', () => {
  const { included, excluded, warnings, ok } = mapDriverToPublic('d1', {
    name: 'Driver', photoUrl: 'https://x/p.jpg', lat: 6.73, lng: -3.49,
    heading: 180, speed: 0, updatedAt: 1732000000000,
    isOnline: true, isAvailable: true, isOnDelivery: false,
    avgRating: 4.6, ratingCount: 12,
  });
  assert.equal(ok, true);
  assert.equal(excluded.length, 0);
  assert.deepEqual(included, {
    name: 'Driver', photoUrl: 'https://x/p.jpg', lat: 6.73, lng: -3.49,
    heading: 180, speed: 0, updatedAt: 1732000000000,
    isOnline: true, isAvailable: true, isOnDelivery: false,
    avgRating: 4.6, ratingCount: 12,
  });
  assert.equal(warnings.length, 0);
});

test('absence de champs sensibles : jamais recopiés même présents dans la source', () => {
  const source = {
    name: 'Driver', wallet: 5000, phone: '0700000000', fcmToken: 'tok', token: 'tok2',
    ownerId: 'fleet-1', ownerName: 'Patron', isSuspended: true, deletionRequested: true,
    pendingOrderId: 'o1', identifiant: 'ID-1', idPhotoUrl: 'https://x/id.jpg',
    selfieUrl: 'https://x/selfie.jpg', email: 'a@b.c', currentCityId: 'abengourou',
    registeredCityId: 'abengourou', createdAt: 123, deliveries: 7,
  };
  const { included } = mapDriverToPublic('d1', source);
  for (const forbidden of FORBIDDEN_FIELDS) {
    assert.equal(forbidden in included, false, `${forbidden} ne doit jamais apparaître`);
  }
  // Seul le champ whitelisté (name) doit être présent.
  assert.deepEqual(Object.keys(included), ['name']);
});

test('omission des champs source manquants : jamais fabriqués, tracés en avertissement', () => {
  const { included, warnings } = mapDriverToPublic('d1', { name: 'Driver' });
  assert.deepEqual(included, { name: 'Driver' });
  assert.ok(warnings.some((w) => w.includes('lat/lng absents')));
  assert.ok(warnings.some((w) => w.includes('heading absent')));
  assert.ok(warnings.some((w) => w.includes('speed absent')));
  assert.ok(warnings.some((w) => w.includes('updatedAt absent')));
  assert.ok(warnings.some((w) => w.includes('isOnline absent')));
  assert.ok(warnings.some((w) => w.includes('photoUrl absent')));
  assert.ok(warnings.some((w) => w.includes('avgRating absent')));
  assert.ok(warnings.some((w) => w.includes('ratingCount absent')));
});

test('document source absent ou invalide : aucune fabrication, ok=false', () => {
  for (const bad of [null, undefined, 'x', 42, ['a']]) {
    const r = mapDriverToPublic('d1', bad);
    assert.deepEqual(r.included, {});
    assert.equal(r.ok, false);
  }
});

test('validation des types : chaque champ de type incorrect est exclu, jamais copié tel quel', () => {
  const { included, excluded } = mapDriverToPublic('d1', {
    name: 12345, photoUrl: 999, heading: 'nord', speed: 'vite',
    isOnline: 'oui', isAvailable: 1, isOnDelivery: 0,
    avgRating: 'quatre', ratingCount: 'douze',
  });
  assert.deepEqual(included, {});
  const reasons = excluded.map((e) => e.field);
  for (const f of ['heading', 'speed', 'isOnline', 'isAvailable', 'isOnDelivery', 'avgRating', 'ratingCount']) {
    assert.ok(reasons.includes(f), `${f} doit être exclu, pas copié`);
  }
});

test('coordonnées invalides rejetées (hors plage, non numériques)', () => {
  for (const bad of [
    { lat: 200, lng: 0 }, { lat: 0, lng: 400 }, { lat: -200, lng: -400 },
    { lat: 'nord', lng: -3 }, { lat: 6, lng: 'est' },
  ]) {
    const { included, excluded } = mapDriverToPublic('d1', bad);
    assert.equal('lat' in included, false);
    assert.equal('lng' in included, false);
    assert.ok(excluded.some((e) => e.field === 'lat/lng'));
  }
});

test('placeholder de création lat=0,lng=0 : exclu comme non-position, pas une erreur de type', () => {
  const { included, excluded, warnings } = mapDriverToPublic('d1', { lat: 0, lng: 0 });
  assert.equal('lat' in included, false);
  assert.equal('lng' in included, false);
  assert.equal(excluded.length, 0); // ce n'est pas un type invalide, c'est un avertissement
  assert.ok(warnings.some((w) => w.startsWith('lat/lng = 0,0')));
});

test('timestamp invalide rejeté (ni Timestamp Firestore, ni nombre de millisecondes)', () => {
  for (const bad of ['hier', {}, [], true]) {
    const { included, excluded } = mapDriverToPublic('d1', { updatedAt: bad });
    assert.equal('updatedAt' in included, false);
    assert.ok(excluded.some((e) => e.field === 'updatedAt'));
  }
});

test('timestamp valide : nombre de millisecondes ou objet avec toMillis()', () => {
  const r1 = mapDriverToPublic('d1', { updatedAt: 1732000000000 });
  assert.equal(r1.included.updatedAt, 1732000000000);
  const fakeTimestamp = { toMillis: () => 1732000000000 };
  const r2 = mapDriverToPublic('d1', { updatedAt: fakeTimestamp });
  assert.equal(r2.included.updatedAt, fakeTimestamp);
});

test('ratingCount négatif ou non entier rejeté', () => {
  for (const bad of [-1, 1.5, '12']) {
    const { included, excluded } = mapDriverToPublic('d1', { ratingCount: bad });
    assert.equal('ratingCount' in included, false);
    assert.ok(excluded.some((e) => e.field === 'ratingCount'));
  }
});

test('toute clé produite est dans la liste blanche FIELD_MAP (cohérence interne)', () => {
  const { included } = mapDriverToPublic('d1', {
    name: 'D', photoUrl: 'https://x/p.jpg', lat: 6.73, lng: -3.49, heading: 1, speed: 1,
    updatedAt: 1, isOnline: true, isAvailable: true, isOnDelivery: false, avgRating: 4, ratingCount: 1,
  });
  for (const key of Object.keys(included)) {
    assert.ok(key in FIELD_MAP, `${key} doit être dans FIELD_MAP`);
  }
});

test('photoUrl et name vides (chaîne vide) sont omis, pas copiés tels quels', () => {
  const { included, warnings } = mapDriverToPublic('d1', { name: '', photoUrl: '   ' });
  assert.equal('name' in included, false);
  assert.equal('photoUrl' in included, false);
  assert.ok(warnings.some((w) => w.includes('name vide')));
  assert.ok(warnings.some((w) => w.includes('photoUrl vide')));
});
