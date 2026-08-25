'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { createRealEstateLocationFunctions, isValidLatLng } = require('../realEstateLocation');

// Même fake Firestore minimaliste que test/realestate.test.js.
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        if (opts && opts.merge && store.has(path)) {
          store.set(path, { ...store.get(path), ...data });
        } else {
          store.set(path, data);
        }
      },
      update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
      __path: path,
    };
  }
  const db = { collection(name) { return { doc: (id) => makeRef(`${name}/${id}`) }; } };
  return { db, store };
}

const DELETE_SENTINEL = '__FIELD_DELETE__';
const SERVER_TS = '__SERVER_TIMESTAMP__';
const fakeAdmin = {
  firestore: {
    FieldValue: {
      serverTimestamp: () => SERVER_TS,
      delete: () => DELETE_SENTINEL,
    },
  },
};

async function noopCheckRateLimit() {}
function noopLogAudit() {}

function buildFns(seedStore) {
  const { db, store } = makeFakeDb(seedStore);
  const fns = createRealEstateLocationFunctions({
    db, admin: fakeAdmin, onCall, HttpsError,
    logAudit: noopLogAudit, checkRateLimit: noopCheckRateLimit,
  });
  return { fns, store };
}

const AGENT = { 'real_estate_agents/agent1': { isVerified: true, isActive: true } };
const LISTING = { 'real_estate_listings/l1': { agentId: 'agent1', title: 'Villa', status: 'active', city: 'Abengourou' } };

// ── Authentification / autorisation ─────────────────────────────────────────

test('upsertRealEstateLocation: refuse un appel non authentifié', async () => {
  const { fns } = buildFns({});
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({ auth: null, data: {} }),
    (err) => err.code === 'unauthenticated',
  );
});

test('upsertRealEstateLocation: refuse un tiers qui n\'est ni l\'agent de l\'annonce ni admin', async () => {
  const { fns } = buildFns({ ...LISTING, ...AGENT, 'real_estate_agents/other': { isVerified: true, isActive: true } });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'other' },
      data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'permission-denied',
  );
});

test('upsertRealEstateLocation: autorise l\'agent propriétaire de l\'annonce', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  const result = await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.7273, longitude: -3.4961, locationPrivacy: 'exact' },
  });
  assert.equal(result.success, true);
  assert.ok(store.get('real_estate_private_locations/l1'));
});

test('upsertRealEstateLocation: autorise un admin même sans être l\'agent de l\'annonce', async () => {
  const { fns } = buildFns({ ...LISTING, 'admins/admin1': { isActive: true } });
  const result = await fns.upsertRealEstateLocation.run({
    auth: { uid: 'admin1' },
    data: { listingId: 'l1', latitude: 6.7273, longitude: -3.4961, locationPrivacy: 'hidden' },
  });
  assert.equal(result.success, true);
});

test('upsertRealEstateLocation: refuse un agent non vérifié/inactif', async () => {
  const { fns } = buildFns({ ...LISTING, 'real_estate_agents/agent1': { isVerified: false, isActive: true } });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'permission-denied',
  );
});

test('upsertRealEstateLocation: annonce introuvable refusée', async () => {
  const { fns } = buildFns({});
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'ghost', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'not-found',
  );
});

// ── Validation des paramètres ────────────────────────────────────────────────

test('upsertRealEstateLocation: latitude invalide (hors plage) refusée', async () => {
  const { fns } = buildFns({ ...LISTING, ...AGENT });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'l1', latitude: 120, longitude: -3.49, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('upsertRealEstateLocation: longitude invalide (hors plage) refusée', async () => {
  const { fns } = buildFns({ ...LISTING, ...AGENT });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'l1', latitude: 6.72, longitude: 200, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('upsertRealEstateLocation: (0,0) toujours refusé, même authentifié et autorisé', async () => {
  const { fns } = buildFns({ ...LISTING, ...AGENT });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'l1', latitude: 0, longitude: 0, locationPrivacy: 'exact' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

test('upsertRealEstateLocation: locationPrivacy invalide refusée', async () => {
  const { fns } = buildFns({ ...LISTING, ...AGENT });
  await assert.rejects(
    () => fns.upsertRealEstateLocation.run({
      auth: { uid: 'agent1' },
      data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'public' },
    }),
    (err) => err.code === 'invalid-argument',
  );
});

// ── Stratégies de confidentialité ────────────────────────────────────────────

test('upsertRealEstateLocation: exact écrit la coordonnée réelle dans le document public', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.7273, longitude: -3.4961, locationPrivacy: 'exact' },
  });
  const pub = store.get('real_estate_listings/l1');
  assert.equal(pub.publicLatitude, 6.7273);
  assert.equal(pub.publicLongitude, -3.4961);
  assert.equal(pub.hasExactLocation, true);
  const priv = store.get('real_estate_private_locations/l1');
  assert.equal(priv.exactLatitude, 6.7273);
  assert.equal(priv.exactLongitude, -3.4961);
});

test('upsertRealEstateLocation: approximate n\'expose jamais la coordonnée exacte publiquement', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.7273, longitude: -3.4961, locationPrivacy: 'approximate' },
  });
  const pub = store.get('real_estate_listings/l1');
  assert.notEqual(pub.publicLatitude, 6.7273);
  assert.notEqual(pub.publicLongitude, -3.4961);
  assert.equal(pub.hasExactLocation, false);
  assert.equal(pub.publicAddress, DELETE_SENTINEL);
  // La coordonnée exacte, elle, reste bien dans le document privé.
  const priv = store.get('real_estate_private_locations/l1');
  assert.equal(priv.exactLatitude, 6.7273);
});

test('upsertRealEstateLocation: hidden n\'expose aucune coordonnée publique', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.7273, longitude: -3.4961, locationPrivacy: 'hidden' },
  });
  const pub = store.get('real_estate_listings/l1');
  assert.equal(pub.publicLatitude, DELETE_SENTINEL);
  assert.equal(pub.publicLongitude, DELETE_SENTINEL);
  assert.equal(pub.publicGeohash, DELETE_SENTINEL);
  assert.equal(pub.hasExactLocation, false);
});

// ── Timestamps serveur + nettoyage des anciens champs ───────────────────────

test('upsertRealEstateLocation: utilise des timestamps serveur, jamais une date envoyée par le client', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact', locationUpdatedAt: '2020-01-01' },
  });
  const pub = store.get('real_estate_listings/l1');
  assert.equal(pub.locationUpdatedAt, SERVER_TS);
  const priv = store.get('real_estate_private_locations/l1');
  assert.equal(priv.locationUpdatedAt, SERVER_TS);
});

test('upsertRealEstateLocation: nettoie les anciens champs publics hérités (lat/lng/latitude/longitude)', async () => {
  const { fns, store } = buildFns({
    'real_estate_listings/l1': { agentId: 'agent1', status: 'active', lat: 6.7, lng: -3.5 },
    ...AGENT,
  });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'approximate' },
  });
  const pub = store.get('real_estate_listings/l1');
  assert.equal(pub.lat, DELETE_SENTINEL);
  assert.equal(pub.lng, DELETE_SENTINEL);
  assert.equal(pub.latitude, DELETE_SENTINEL);
  assert.equal(pub.longitude, DELETE_SENTINEL);
});

// ── Immuabilité ownerId/agentId + idempotence ───────────────────────────────

test('upsertRealEstateLocation: ownerId/agentId proviennent de l\'annonce, jamais du payload client', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: {
      listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact',
      ownerId: 'attacker', agentId: 'attacker',
    },
  });
  const priv = store.get('real_estate_private_locations/l1');
  assert.equal(priv.ownerId, 'agent1');
  assert.equal(priv.agentId, 'agent1');
});

test('upsertRealEstateLocation: idempotente — deux appels identiques ne dupliquent rien et préservent createdAt', async () => {
  const { fns, store } = buildFns({ ...LISTING, ...AGENT });
  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact' },
  });
  const firstCreatedAt = store.get('real_estate_private_locations/l1').createdAt;

  await fns.upsertRealEstateLocation.run({
    auth: { uid: 'agent1' },
    data: { listingId: 'l1', latitude: 6.72, longitude: -3.49, locationPrivacy: 'exact' },
  });
  const priv = store.get('real_estate_private_locations/l1');
  assert.equal(priv.createdAt, firstCreatedAt, 'createdAt ne doit jamais être réécrit par un second appel');
  // Un seul document privé pour cette annonce (clé fixe = listingId, jamais
  // un id auto-généré qui pourrait dupliquer un enregistrement).
  const privateKeys = [...store.keys()].filter((k) => k.startsWith('real_estate_private_locations/'));
  assert.deepEqual(privateKeys, ['real_estate_private_locations/l1']);
});

// ── isValidLatLng (unité pure) ───────────────────────────────────────────────

test('isValidLatLng: rejette (0,0), les valeurs hors plage et les non-nombres', () => {
  assert.equal(isValidLatLng(0, 0), false);
  assert.equal(isValidLatLng(91, 0), false);
  assert.equal(isValidLatLng(0, -181), false);
  assert.equal(isValidLatLng('6.72', -3.49), false);
  assert.equal(isValidLatLng(NaN, -3.49), false);
  assert.equal(isValidLatLng(6.72, -3.49), true);
});
