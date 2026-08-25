'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const geohash = require('../geohash');
const {
  hasLegacyExactLocation,
  planMigrationForListing,
  planMigration,
  runMigration,
  MIGRATION_MARKER,
  DEFAULT_PRIVACY,
} = require('../scripts/migrateRealEstateLocations');

test('hasLegacyExactLocation: détecte lat/lng ou latitude/longitude numériques', () => {
  assert.equal(hasLegacyExactLocation({ lat: 6.7, lng: -3.5 }), true);
  assert.equal(hasLegacyExactLocation({ latitude: 6.7, longitude: -3.5 }), true);
  assert.equal(hasLegacyExactLocation({ city: 'Abengourou' }), false);
  assert.equal(hasLegacyExactLocation({ lat: 'six' }), false);
});

test('planMigrationForListing: ignore une annonce sans localisation héritée', () => {
  const plan = planMigrationForListing('l1', { city: 'Abengourou' }, { geohash });
  assert.equal(plan.outcome, 'skipped');
  assert.equal(plan.reason, 'no_legacy_location');
});

test('planMigrationForListing: ignore une annonce déjà migrée (idempotence)', () => {
  const plan = planMigrationForListing('l1', { lat: 6.7, lng: -3.5, __migration: MIGRATION_MARKER }, { geohash });
  assert.equal(plan.outcome, 'skipped');
  assert.equal(plan.reason, 'already_migrated');
});

test('planMigrationForListing: signale une coordonnée héritée invalide (0,0) comme "invalid", pas migrée', () => {
  const plan = planMigrationForListing('l1', { lat: 0, lng: 0 }, { geohash });
  assert.equal(plan.outcome, 'invalid');
});

test('planMigrationForListing: migre une annonce avec lat/lng exacts hérités, en HIDDEN par défaut', () => {
  const plan = planMigrationForListing('l1', { lat: 6.7273, lng: -3.4961, agentId: 'agent1', city: 'Abengourou' }, { geohash });
  assert.equal(plan.outcome, 'migrated');
  assert.equal(plan.publicPatch.locationPrivacy, DEFAULT_PRIVACY);
  assert.equal(plan.publicPatch.locationPrivacy, 'hidden', 'la stratégie par défaut doit être la plus prudente');
  assert.equal(plan.publicPatch.hasExactLocation, false);
  // Aucune coordonnée publique exacte laissée en ligne après migration.
  assert.equal(plan.publicPatch.publicLatitude, null);
  assert.equal(plan.publicPatch.publicLongitude, null);
  assert.equal(plan.publicPatch.lat, null);
  assert.equal(plan.publicPatch.lng, null);
  // La coordonnée exacte est bien préservée dans le document privé.
  assert.equal(plan.privateDoc.exactLatitude, 6.7273);
  assert.equal(plan.privateDoc.exactLongitude, -3.4961);
  assert.equal(plan.privateDoc.ownerId, 'agent1');
});

test('planMigrationForListing: accepte aussi les anciens noms latitude/longitude', () => {
  const plan = planMigrationForListing('l1', { latitude: 6.72, longitude: -3.49 }, { geohash });
  assert.equal(plan.outcome, 'migrated');
  assert.equal(plan.privateDoc.exactLatitude, 6.72);
});

test('planMigration: agrège plusieurs documents en un seul rapport (analysés/migrés/ignorés/invalides)', () => {
  const listings = [
    { id: 'ok', data: { lat: 6.72, lng: -3.49 } },
    { id: 'clean', data: { city: 'Abengourou' } },
    { id: 'bad', data: { lat: 0, lng: 0 } },
    { id: 'already', data: { lat: 6.7, lng: -3.5, __migration: MIGRATION_MARKER } },
  ];
  const report = planMigration(listings, { geohash });
  assert.equal(report.analyzed, 4);
  assert.equal(report.migrated.length, 1);
  assert.equal(report.skipped.length, 2);
  assert.equal(report.invalid.length, 1);
});

// ── runMigration (dry-run vs apply, contre un faux Firestore) ───────────────

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  function makeRef(path) {
    return {
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        if (opts && opts.merge && store.has(path)) store.set(path, { ...store.get(path), ...data });
        else store.set(path, data);
      },
      update: async (data) => { store.set(path, { ...(store.get(path) || {}), ...data }); },
    };
  }
  const db = {
    collection(name) {
      return {
        doc: (id) => makeRef(`${name}/${id}`),
        get: async () => ({
          docs: [...store.entries()]
            .filter(([k]) => k.startsWith(`${name}/`))
            .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v })),
        }),
      };
    },
  };
  return { db, store };
}

const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' } } };

test('runMigration: dry-run (défaut) n\'écrit jamais, même quand des annonces à migrer existent', async () => {
  const { db, store } = makeFakeDb({ 'real_estate_listings/l1': { lat: 6.72, lng: -3.49, agentId: 'a1' } });
  const { summary } = await runMigration({ db, admin: fakeAdmin, geohash, dryRun: true, log: () => {} });
  assert.equal(summary.dryRun, true);
  assert.equal(summary.migrated, 1);
  assert.equal(store.has('real_estate_private_locations/l1'), false, 'dry-run ne doit jamais écrire');
});

test('runMigration: mode --apply écrit réellement le document privé et nettoie le public', async () => {
  const { db, store } = makeFakeDb({ 'real_estate_listings/l1': { lat: 6.72, lng: -3.49, agentId: 'a1', status: 'active' } });
  const { summary } = await runMigration({ db, admin: fakeAdmin, geohash, dryRun: false, log: () => {} });
  assert.equal(summary.migrated, 1);
  assert.equal(summary.errors, 0);
  const priv = store.get('real_estate_private_locations/l1');
  assert.ok(priv);
  assert.equal(priv.exactLatitude, 6.72);
  const pub = store.get('real_estate_listings/l1');
  assert.equal(pub.locationPrivacy, 'hidden');
});

test('runMigration: relancer le script après un --apply ne migre plus rien (idempotent)', async () => {
  const { db, store } = makeFakeDb({ 'real_estate_listings/l1': { lat: 6.72, lng: -3.49, agentId: 'a1' } });
  await runMigration({ db, admin: fakeAdmin, geohash, dryRun: false, log: () => {} });
  // Deuxième exécution, sur le document déjà migré (marqueur déjà posé) :
  const secondRun = await runMigration({ db, admin: fakeAdmin, geohash, dryRun: false, log: () => {} });
  assert.equal(secondRun.summary.migrated, 0);
  assert.equal(secondRun.summary.skipped, 1);
});
