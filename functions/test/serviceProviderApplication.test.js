'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { sanitizeApplication, enforceApplicationLimits } = require('../serviceProviderApplication');

const DOC = 'AbCdEfGhIjKlMnOpQrSt';
const valid = (extra = {}) => ({
  docId: DOC, name: ' Kouassi Jean ', phone: '07 98 05 13 97', address: 'Quartier Dioulabougou',
  description: 'Plomberie et sanitaires', subcategory: 'plombier', category: 'artisans',
  photos: [`https://firebasestorage.googleapis.com/v0/b/x/o/service_providers%2F${DOC}%2Fphoto_1_0.jpg?alt=media&token=t`],
  lat: 6.73, lng: -3.49, ...extra,
});
const invalid = (e) => e.code === 'invalid-argument';

test('demande légitime acceptée et normalisée', () => {
  const out = sanitizeApplication(valid());
  assert.equal(out.name, 'Kouassi Jean');
  assert.equal(out.photos.length, 1);
  assert.equal(out.docId, DOC);
});

test('photo facultative et description facultative', () => {
  const out = sanitizeApplication(valid({ photos: undefined, description: undefined }));
  assert.deepEqual(out.photos, []);
  assert.equal(out.description, '');
});

test('une demande sans docId ni photo reste acceptée (ancien client)', () => {
  const out = sanitizeApplication(valid({ docId: undefined, photos: [] }));
  assert.equal(out.docId, undefined);
});

test('champs trop longs, vides ou de mauvais type refusés', () => {
  for (const bad of [
    { name: 'x'.repeat(101) }, { name: '' }, { name: 42 },
    { address: 'x'.repeat(201) }, { description: 'x'.repeat(1001) },
    { phone: 'abcdefghij' }, { phone: '123' }, { phone: '1'.repeat(16) },
    { subcategory: 'Plombier!' }, { subcategory: '../x' }, { category: 'A B' },
    { docId: 'court' }, { docId: '../etc/passwd/xxxxxx' },
  ]) {
    assert.throws(() => sanitizeApplication(valid(bad)), invalid, JSON.stringify(bad).slice(0, 40));
  }
});

test('photos: pas plus de 10, uniquement le dossier Storage de cette demande', () => {
  const ok = valid().photos[0];
  assert.throws(() => sanitizeApplication(valid({ photos: Array(11).fill(ok) })), invalid);
  assert.throws(() => sanitizeApplication(valid({ photos: ['https://evil.example/x.jpg'] })), invalid);
  assert.throws(() => sanitizeApplication(valid({
    photos: [ok.replace(DOC, 'ZZZZZZZZZZZZZZZZZZZZ')] })), invalid);
  assert.throws(() => sanitizeApplication(valid({ docId: undefined })), invalid, 'photo sans docId');
  assert.throws(() => sanitizeApplication(valid({ photos: 'x' })), invalid);
});

test('coordonnées hors limites ramenées à 0', () => {
  const out = sanitizeApplication(valid({ lat: 999, lng: Infinity }));
  assert.equal(out.lat, 0);
  assert.equal(out.lng, 0);
});

test('limites: par numéro, et par compte seulement s\'il est identifié', async () => {
  const calls = [];
  const check = async (key, action, max, window) => { calls.push([key, action, max, window]); };
  await enforceApplicationLimits({ checkRateLimit: check, request: {}, phone: '0798051397' });
  assert.equal(calls.length, 1);
  await enforceApplicationLimits({ checkRateLimit: check, request: { auth: { uid: 'u1' } }, phone: '0798051397' });
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[2], ['u1', 'service_provider_apply_uid', 5, 86400]);
});

test('le blocage d\'un abuseur ne bloque pas un autre artisan', async () => {
  const seen = new Set();
  const check = async (key) => { if (seen.has(key)) throw new Error('limit'); seen.add(key); };
  await enforceApplicationLimits({ checkRateLimit: check, request: { auth: { uid: 'a' } }, phone: '0100000001' });
  await enforceApplicationLimits({ checkRateLimit: check, request: { auth: { uid: 'b' } }, phone: '0100000002' });
});
