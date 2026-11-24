'use strict';

// Proxy Google Maps : réponses valides, erreurs Google, authentification, limitation de débit, cache,
// itinéraire réel, et surtout AUCUN secret dans les réponses ni dans les journaux.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const {
  createMapsProxy, buildMapsCallables, assertEligibleRole, parseDurationSeconds, validPoint, RATE_LIMITS, SECRET_NAME,
} = require('../mapsProxy');

// Valeur factice au FORMAT d'une clé Google : sert à prouver qu'elle ne fuit nulle part.
const FAKE_KEY = 'AIzaFAKE_test_key_0000000000000000000000';
const A = { lat: 6.7273, lng: -3.4961 };
const B = { lat: 6.74, lng: -3.48 };

class HttpsError extends Error { constructor(code, message) { super(message); this.code = code; } }
const onCall = (h) => h;

// Firestore factice minimal : deux collections (clients/livreurs), lecture simple par uid.
// `dbError` simule une panne de lecture (réseau, permission…) sur les DEUX collections.
function fakeDb({ clients = {}, drivers = {}, dbError = false } = {}) {
  const reads = [];
  const makeCollection = (name, store) => ({
    doc: (uid) => ({
      get: async () => {
        reads.push(`${name}/${uid}`);
        if (dbError) throw new Error('Firestore indisponible (simulé)');
        return { exists: Object.prototype.hasOwnProperty.call(store, uid), data: () => store[uid] };
      },
    }),
  });
  return {
    reads,
    db: { collection: (name) => makeCollection(name, name === 'clients' ? clients : drivers) },
  };
}

// Par défaut : 'alice' et 'bob' sont des clients actifs, non suspendus — ne change pas le
// comportement des tests déjà existants, qui ne portent pas sur le rôle/la suspension.
function world({
  responses = [], key = FAKE_KEY, rateLimit,
  clients = { alice: {}, bob: {} }, drivers = {}, dbError = false,
} = {}) {
  const calls = [];
  const logs = [];
  const limits = [];
  let clock = 1_000_000;
  let i = 0;
  const httpRequest = async (req) => {
    calls.push(req);
    const next = responses[Math.min(i++, responses.length - 1)];
    if (next instanceof Error) throw next;
    return next;
  };
  const proxy = createMapsProxy({ getKey: () => key, httpRequest, now: () => clock, log: (l) => logs.push(l) });
  const { db, reads } = fakeDb({ clients, drivers, dbError });
  const fns = buildMapsCallables({
    onCall, HttpsError, proxy, db,
    checkRateLimit: rateLimit || (async (...args) => { limits.push(args); }),
  });
  const call = (name, data, uid = 'alice') => fns[name]({ auth: uid ? { uid } : null, data });
  return { calls, logs, limits, call, proxy, reads, advance: (ms) => { clock += ms; } };
}

const ROUTE_OK = { status: 200, json: { routes: [{ distanceMeters: 2345, duration: '412s', polyline: { encodedPolyline: 'abc_poly' } }] } };
const AUTOCOMPLETE_OK = {
  status: 200,
  json: { suggestions: [
    { placePrediction: { placeId: 'ChIJ_place_0001', text: { text: 'Marché central, Abengourou' },
      structuredFormat: { mainText: { text: 'Marché central' }, secondaryText: { text: 'Abengourou, Côte d\'Ivoire' } } } },
    { queryPrediction: { text: { text: 'ignoré' } } },
    { placePrediction: { placeId: 'ChIJ_place_0002', text: { text: 'Gare routière' } } },
  ] },
};
const DETAILS_OK = { status: 200, json: { id: 'ChIJ_place_0001', location: { latitude: 6.731, longitude: -3.492 }, formattedAddress: 'Marché, Abengourou' } };
const GEOCODE_OK = { status: 200, json: { status: 'OK', results: [{ formatted_address: 'Abengourou, CI', geometry: { location: { lat: 6.73, lng: -3.49 } } }] } };

const assertEnvelope = (r) => assert.deepEqual(Object.keys(r).sort(), ['code', 'data', 'error', 'message', 'success']);
const assertNoSecret = (value) => assert.ok(!JSON.stringify(value).includes('AIza'), 'aucune clé ne doit apparaître');

// ── Réponses Google valides ──────────────────────────────────────────────────
test('itinéraire : réponse Routes API normalisée, marquée itinéraire réel', async () => {
  const w = world({ responses: [ROUTE_OK] });
  const r = await w.call('mapsRouteCF', { origin: A, destination: B });
  assertEnvelope(r);
  assert.equal(r.success, true); assert.equal(r.error, null); assert.equal(r.code, 'OK');
  assert.deepEqual(r.data, { encodedPolyline: 'abc_poly', distanceMeters: 2345, durationSeconds: 412, withTraffic: false, isEstimate: false });
  const req = w.calls[0];
  assert.equal(req.url, 'https://routes.googleapis.com/directions/v2:computeRoutes');
  assert.equal(req.method, 'POST');
  assert.equal(req.headers['X-Goog-Api-Key'], FAKE_KEY);
  assert.deepEqual(req.body.origin, { location: { latLng: { latitude: A.lat, longitude: A.lng } } });
  assert.equal(req.body.travelMode, 'DRIVE');
  assert.equal(req.body.routingPreference, 'TRAFFIC_UNAWARE');
});

test('itinéraire avec trafic : préférence TRAFFIC_AWARE, résultat non mis en cache', async () => {
  const w = world({ responses: [ROUTE_OK] });
  await w.call('mapsRouteCF', { origin: A, destination: B, withTraffic: true });
  await w.call('mapsRouteCF', { origin: A, destination: B, withTraffic: true });
  assert.equal(w.calls.length, 2);
  assert.equal(w.calls[0].body.routingPreference, 'TRAFFIC_AWARE');
});

test('itinéraire : distance absente (trajet nul) → 0, durée décimale arrondie', async () => {
  const w = world({ responses: [{ status: 200, json: { routes: [{ duration: '0.4s', polyline: { encodedPolyline: 'p' } }] } }] });
  const r = await w.call('mapsRouteCF', { origin: A, destination: B });
  assert.equal(r.success, true);
  assert.equal(r.data.distanceMeters, 0); assert.equal(r.data.durationSeconds, 0);
});

test('recherche : suggestions normalisées, zone et jeton transmis, entrées sans lieu ignorées', async () => {
  const w = world({ responses: [AUTOCOMPLETE_OK] });
  const r = await w.call('mapsAutocompleteCF', { input: '  marché   central ', location: A, radiusMeters: 999999, sessionToken: 'sess_token_0001' });
  assert.equal(r.success, true);
  assert.deepEqual(r.data.predictions, [
    { placeId: 'ChIJ_place_0001', mainText: 'Marché central', secondaryText: 'Abengourou, Côte d\'Ivoire', description: 'Marché central, Abengourou' },
    { placeId: 'ChIJ_place_0002', mainText: 'Gare routière', secondaryText: '', description: 'Gare routière' },
  ]);
  const body = w.calls[0].body;
  assert.equal(body.input, 'marché central');
  assert.deepEqual(body.includedRegionCodes, ['ci']);
  assert.equal(body.locationBias.circle.radius, 50000); // plafonné
  assert.equal(body.sessionToken, 'sess_token_0001');
});

test('coordonnées d\'un lieu : point et adresse renvoyés, jeton en paramètre', async () => {
  const w = world({ responses: [DETAILS_OK] });
  const r = await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001', sessionToken: 'sess_token_0001' });
  assert.deepEqual(r.data, { lat: 6.731, lng: -3.492, formattedAddress: 'Marché, Abengourou' });
  assert.equal(w.calls[0].url, 'https://places.googleapis.com/v1/places/ChIJ_place_0001?sessionToken=sess_token_0001');
  assert.equal(w.calls[0].headers['X-Goog-FieldMask'], 'id,location,formattedAddress');
});

test('géocodage direct et inverse : résultats normalisés', async () => {
  const w = world({ responses: [GEOCODE_OK] });
  const direct = await w.call('mapsGeocodeCF', { address: 'Abengourou' });
  assert.deepEqual(direct.data.results, [{ lat: 6.73, lng: -3.49, formattedAddress: 'Abengourou, CI' }]);
  const reverse = await w.call('mapsGeocodeCF', { location: A });
  assert.equal(reverse.success, true);
  assert.match(w.calls[0].url, /[?&]address=Abengourou(&|$)/);
  assert.match(w.calls[1].url, /[?&]latlng=6\.7273%2C-3\.4961(&|$)/);
});

test('géocodage : ZERO_RESULTS est un succès vide, pas une erreur', async () => {
  const w = world({ responses: [{ status: 200, json: { status: 'ZERO_RESULTS', results: [] } }] });
  const r = await w.call('mapsGeocodeCF', { address: 'lieu inexistant' });
  assert.equal(r.success, true); assert.deepEqual(r.data.results, []);
});

// ── Erreurs Google ───────────────────────────────────────────────────────────
test('erreur HTTP de Google : refus UPSTREAM_UNAVAILABLE, sans message brut ni clé', async () => {
  const denied = { status: 403, json: { error: { status: 'PERMISSION_DENIED', message: `API key ${FAKE_KEY} not valid` } } };
  for (const [name, data] of [
    ['mapsRouteCF', { origin: A, destination: B }],
    ['mapsAutocompleteCF', { input: 'marché' }],
    ['mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' }],
    ['mapsGeocodeCF', { address: 'Abengourou' }],
  ]) {
    const w = world({ responses: [denied] });
    const r = await w.call(name, data);
    assertEnvelope(r);
    assert.equal(r.success, false, name); assert.equal(r.code, 'UPSTREAM_UNAVAILABLE'); assert.equal(r.error, 'UPSTREAM_UNAVAILABLE');
    assert.equal(r.data, null);
    assertNoSecret(r); assertNoSecret(w.logs);
    assert.ok(w.logs.some((l) => l.includes('http=403') && l.includes('PERMISSION_DENIED')), 'le statut court est journalisé');
  }
});

test('géocodage refusé en HTTP 200 (REQUEST_DENIED) : traité comme une erreur', async () => {
  const w = world({ responses: [{ status: 200, json: { status: 'REQUEST_DENIED', error_message: `key ${FAKE_KEY} refused` } }] });
  const r = await w.call('mapsGeocodeCF', { address: 'Abengourou' });
  assert.equal(r.success, false); assert.equal(r.code, 'UPSTREAM_UNAVAILABLE');
  assertNoSecret(r); assertNoSecret(w.logs);
});

test('réseau coupé ou délai dépassé : aucune exception ne sort, aucun secret journalisé', async () => {
  const err = new Error(`connect failed https://maps.googleapis.com/x?key=${FAKE_KEY}`);
  err.name = 'AbortError';
  const w = world({ responses: [err] });
  const r = await w.call('mapsGeocodeCF', { address: 'Abengourou' });
  assert.equal(r.code, 'UPSTREAM_UNAVAILABLE');
  assertNoSecret(r); assertNoSecret(w.logs);
  assert.ok(w.logs[0].includes('AbortError'));
});

test('itinéraire introuvable ou réponse incomplète : NO_ROUTE, jamais un itinéraire inventé', async () => {
  for (const json of [{}, { routes: [] }, { routes: [{ distanceMeters: 10, duration: '5s' }] }, { routes: [{ polyline: { encodedPolyline: 'p' } }] }]) {
    const w = world({ responses: [{ status: 200, json }] });
    const r = await w.call('mapsRouteCF', { origin: A, destination: B });
    assert.equal(r.success, false); assert.equal(r.code, 'NO_ROUTE'); assert.equal(r.data, null);
  }
});

test('lieu sans coordonnées exploitables : NOT_FOUND', async () => {
  const w = world({ responses: [{ status: 200, json: { id: 'x' } }] });
  const r = await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' });
  assert.equal(r.code, 'NOT_FOUND');
});

test('secret absent ou illisible : MAPS_NOT_CONFIGURED, aucun appel sortant', async () => {
  // 'DISABLED' : valeur factice écrite pour les émulateurs locaux par test-env/stage-functions.js.
  for (const key of ['', '   ', null, 42, 'DISABLED', ' DISABLED ']) {
    const w = world({ responses: [ROUTE_OK], key });
    const r = await w.call('mapsRouteCF', { origin: A, destination: B });
    assert.equal(r.code, 'MAPS_NOT_CONFIGURED'); assert.equal(w.calls.length, 0);
  }
  const throwing = createMapsProxy({ getKey: () => { throw new Error('secret indisponible'); }, httpRequest: async () => ROUTE_OK, log: () => {} });
  const r = await throwing.route.run(throwing.route.validate({ origin: A, destination: B }).value);
  assert.equal(r.code, 'MAPS_NOT_CONFIGURED');
});

// ── Authentification ─────────────────────────────────────────────────────────
test('sans authentification : unauthenticated sur les quatre fonctions, aucun appel sortant ni limite consommée', async () => {
  const w = world({ responses: [ROUTE_OK] });
  for (const name of ['mapsRouteCF', 'mapsAutocompleteCF', 'mapsPlaceDetailsCF', 'mapsGeocodeCF']) {
    await assert.rejects(() => w.call(name, { origin: A, destination: B }, null), (e) => e.code === 'unauthenticated');
  }
  assert.equal(w.calls.length, 0); assert.equal(w.limits.length, 0);
});

// ── Rôle et statut (Lot 1.2.1) ────────────────────────────────────────────────
// Seuls les comptes clients/livreurs utilisent le proxy ; absence des deux documents
// ou suspension de l'un d'eux refuse, sans jamais consommer la limite de débit ni
// déclencher d'appel sortant.
test('client actif, non suspendu : autorisé', async () => {
  const w = world({ responses: [ROUTE_OK], clients: { alice: { isSuspended: false } }, drivers: {} });
  const r = await w.call('mapsRouteCF', { origin: A, destination: B });
  assert.equal(r.success, true);
});

test('livreur actif, non suspendu : autorisé', async () => {
  const w = world({ responses: [ROUTE_OK], clients: {}, drivers: { alice: {} } });
  const r = await w.call('mapsRouteCF', { origin: A, destination: B });
  assert.equal(r.success, true);
});

test('client suspendu : permission-denied, aucun appel sortant, aucune limite consommée', async () => {
  const w = world({ responses: [ROUTE_OK], clients: { alice: { isSuspended: true } }, drivers: {} });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }), (e) => e.code === 'permission-denied');
  assert.equal(w.calls.length, 0); assert.equal(w.limits.length, 0);
});

test('livreur suspendu : permission-denied', async () => {
  const w = world({ responses: [ROUTE_OK], clients: {}, drivers: { alice: { isSuspended: true } } });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }), (e) => e.code === 'permission-denied');
  assert.equal(w.calls.length, 0);
});

test('même uid, client ET livreur, un seul suspendu : permission-denied (le pire des deux)', async () => {
  const w = world({ responses: [ROUTE_OK], clients: { alice: { isSuspended: false } }, drivers: { alice: { isSuspended: true } } });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }), (e) => e.code === 'permission-denied');
});

test('un seul document existe (l\'autre absent), non suspendu : autorisé', async () => {
  const w1 = world({ responses: [ROUTE_OK], clients: { alice: {} }, drivers: {} });
  assert.equal((await w1.call('mapsRouteCF', { origin: A, destination: B })).success, true);
  const w2 = world({ responses: [ROUTE_OK], clients: {}, drivers: { alice: {} } });
  assert.equal((await w2.call('mapsRouteCF', { origin: A, destination: B })).success, true);
});

test('les deux documents absents : permission-denied (aucun rôle éligible identifié)', async () => {
  const w = world({ responses: [ROUTE_OK], clients: {}, drivers: {} });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }), (e) => e.code === 'permission-denied');
  assert.equal(w.calls.length, 0); assert.equal(w.limits.length, 0);
});

test('erreur de lecture Firestore : l\'erreur se propage, aucun accès autorisé, aucun appel sortant', async () => {
  const w = world({ responses: [ROUTE_OK], dbError: true });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }));
  assert.equal(w.calls.length, 0); assert.equal(w.limits.length, 0);
});

test('les quatre fonctions appliquent le même contrôle de rôle/statut', async () => {
  const w = world({ responses: [ROUTE_OK, AUTOCOMPLETE_OK, DETAILS_OK, GEOCODE_OK], clients: { alice: { isSuspended: true } } });
  const cases = [
    ['mapsRouteCF', { origin: A, destination: B }],
    ['mapsAutocompleteCF', { input: 'marché' }],
    ['mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' }],
    ['mapsGeocodeCF', { address: 'Abengourou' }],
  ];
  for (const [name, data] of cases) {
    await assert.rejects(() => w.call(name, data), (e) => e.code === 'permission-denied', name);
  }
  assert.equal(w.calls.length, 0);
});

test('assertEligibleRole : lit les deux collections en parallèle, sans transaction', async () => {
  const { db, reads } = fakeDb({ clients: { alice: {} }, drivers: { alice: {} } });
  await assertEligibleRole({ db, HttpsError, uid: 'alice' });
  assert.deepEqual(reads.sort(), ['clients/alice', 'livreurs/alice']);
});

// ── Validation des paramètres ────────────────────────────────────────────────
test('paramètres invalides : INVALID_ARGUMENT avant toute limite et tout appel sortant', async () => {
  const cases = [
    ['mapsRouteCF', undefined],
    ['mapsRouteCF', { origin: A }],
    ['mapsRouteCF', { origin: { lat: 0, lng: 0 }, destination: B }],
    ['mapsRouteCF', { origin: { lat: '6.7', lng: -3.4 }, destination: B }],
    ['mapsRouteCF', { origin: { lat: 91, lng: 0 }, destination: B }],
    ['mapsRouteCF', { origin: { lat: NaN, lng: 1 }, destination: B }],
    ['mapsAutocompleteCF', { input: 'a' }],
    ['mapsAutocompleteCF', { input: 42 }],
    ['mapsAutocompleteCF', { input: 'marché', location: A }],
    ['mapsAutocompleteCF', { input: 'marché', location: A, radiusMeters: -5 }],
    ['mapsAutocompleteCF', { input: 'marché', sessionToken: 'court' }],
    ['mapsAutocompleteCF', { input: 'marché', sessionToken: 'jeton avec espace!!' }],
    ['mapsPlaceDetailsCF', {}],
    ['mapsPlaceDetailsCF', { placeId: '../../v1/autre' }],
    ['mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001', sessionToken: 5 }],
    ['mapsGeocodeCF', {}],
    ['mapsGeocodeCF', { address: 'Abengourou', location: A }],
    ['mapsGeocodeCF', { address: 'ab' }],
    ['mapsGeocodeCF', { location: { lat: 6.7 } }],
  ];
  const w = world({ responses: [ROUTE_OK] });
  for (const [name, data] of cases) {
    const r = await w.call(name, data);
    assertEnvelope(r);
    assert.equal(r.code, 'INVALID_ARGUMENT', `${name} ${JSON.stringify(data)}`);
    assert.equal(r.success, false);
  }
  assert.equal(w.calls.length, 0); assert.equal(w.limits.length, 0);
});

test('entrées trop longues tronquées, jamais transmises telles quelles', async () => {
  const w = world({ responses: [AUTOCOMPLETE_OK] });
  await w.call('mapsAutocompleteCF', { input: 'x'.repeat(500) });
  assert.equal(w.calls[0].body.input.length, 120);
});

// ── Limitation de débit ──────────────────────────────────────────────────────
test('limitation de débit : une action distincte par fonction, par utilisateur', async () => {
  const w = world({ responses: [ROUTE_OK, AUTOCOMPLETE_OK, DETAILS_OK, GEOCODE_OK] });
  await w.call('mapsRouteCF', { origin: A, destination: B });
  await w.call('mapsAutocompleteCF', { input: 'marché' });
  await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' });
  await w.call('mapsGeocodeCF', { address: 'Abengourou' });
  assert.deepEqual(w.limits, [
    ['alice', 'maps_route', RATE_LIMITS.route.max, 60],
    ['alice', 'maps_autocomplete', RATE_LIMITS.autocomplete.max, 60],
    ['alice', 'maps_place_details', RATE_LIMITS.placeDetails.max, 60],
    ['alice', 'maps_geocode', RATE_LIMITS.geocode.max, 60],
  ]);
});

test('limite atteinte : resource-exhausted remonte, aucun appel sortant', async () => {
  const w = world({ responses: [ROUTE_OK], rateLimit: async () => { throw new HttpsError('resource-exhausted', 'Trop de tentatives'); } });
  await assert.rejects(() => w.call('mapsRouteCF', { origin: A, destination: B }), (e) => e.code === 'resource-exhausted');
  assert.equal(w.calls.length, 0);
});

test('la limite s\'applique aussi aux réponses servies par le cache', async () => {
  const w = world({ responses: [ROUTE_OK] });
  await w.call('mapsRouteCF', { origin: A, destination: B });
  await w.call('mapsRouteCF', { origin: A, destination: B });
  assert.equal(w.calls.length, 1); assert.equal(w.limits.length, 2);
});

// ── Cache ────────────────────────────────────────────────────────────────────
test('cache itinéraire : même trajet (à 4 décimales) servi sans rappel, puis expiré après 2 minutes', async () => {
  const w = world({ responses: [ROUTE_OK] });
  const first = await w.call('mapsRouteCF', { origin: A, destination: B });
  const near = await w.call('mapsRouteCF', { origin: { lat: A.lat + 0.00001, lng: A.lng }, destination: B }, 'bob');
  assert.equal(w.calls.length, 1);
  assert.deepEqual(near.data, first.data);
  await w.call('mapsRouteCF', { origin: { lat: A.lat + 0.01, lng: A.lng }, destination: B });
  assert.equal(w.calls.length, 2); // trajet différent
  w.advance(2 * 60 * 1000 + 1);
  await w.call('mapsRouteCF', { origin: A, destination: B });
  assert.equal(w.calls.length, 3);
});

test('cache : un échec amont n\'est jamais mis en cache', async () => {
  const w = world({ responses: [{ status: 500, json: null }, ROUTE_OK] });
  assert.equal((await w.call('mapsRouteCF', { origin: A, destination: B })).success, false);
  assert.equal((await w.call('mapsRouteCF', { origin: A, destination: B })).success, true);
  assert.equal(w.calls.length, 2);
});

test('cache recherche, lieu et géocodage : second appel identique sans rappel', async () => {
  const w = world({ responses: [AUTOCOMPLETE_OK, DETAILS_OK, GEOCODE_OK] });
  await w.call('mapsAutocompleteCF', { input: 'Marché' }); await w.call('mapsAutocompleteCF', { input: 'marché' });
  await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' }); await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' });
  await w.call('mapsGeocodeCF', { address: 'Abengourou' }); await w.call('mapsGeocodeCF', { address: 'ABENGOUROU' });
  assert.equal(w.calls.length, 3);
});

test('cache borné : les entrées les plus anciennes sont évincées', async () => {
  const w = world({ responses: [GEOCODE_OK] });
  for (let i = 0; i < 520; i++) await w.proxy.geocode.run({ address: `adresse numero ${i}` });
  assert.equal(w.proxy.cacheSize(), 500);
});

// ── Aucun secret dans les réponses ni les journaux ───────────────────────────
test('aucune clé dans les réponses de succès, y compris servies par le cache', async () => {
  const w = world({ responses: [ROUTE_OK, AUTOCOMPLETE_OK, DETAILS_OK, GEOCODE_OK] });
  const results = [
    await w.call('mapsRouteCF', { origin: A, destination: B }),
    await w.call('mapsAutocompleteCF', { input: 'marché' }),
    await w.call('mapsPlaceDetailsCF', { placeId: 'ChIJ_place_0001' }),
    await w.call('mapsGeocodeCF', { address: 'Abengourou' }),
    await w.call('mapsGeocodeCF', { address: 'Abengourou' }),
  ];
  for (const r of results) { assert.equal(r.success, true); assertNoSecret(r); }
  assertNoSecret(w.logs);
});

// ── Fonctions utilitaires ────────────────────────────────────────────────────
test('parseDurationSeconds et validPoint', () => {
  assert.equal(parseDurationSeconds('412s'), 412);
  assert.equal(parseDurationSeconds('59.6s'), 60);
  assert.equal(parseDurationSeconds(30), 30);
  for (const bad of ['412', 's', '', null, undefined, {}, '-5s']) assert.equal(parseDurationSeconds(bad), null);
  assert.equal(validPoint(A), true);
  for (const bad of [null, {}, { lat: 0, lng: 0 }, { lat: 6, lng: 181 }, { lat: Infinity, lng: 1 }]) assert.equal(validPoint(bad), false);
});

// ── Branchement dans index.js ────────────────────────────────────────────────
test('index.js exporte les quatre fonctions : callable, europe-west1, dimensionnées pour le quota, un seul secret', () => {
  const script = `
    process.env.GCLOUD_PROJECT = 'demo-wiring'; process.env.FIREBASE_CONFIG = JSON.stringify({ projectId: 'demo-wiring' });
    const m = require('./index.js'); const out = {};
    for (const n of ['mapsRouteCF','mapsAutocompleteCF','mapsPlaceDetailsCF','mapsGeocodeCF']) { const e = m[n] && m[n].__endpoint;
      out[n] = e ? { region: e.region, cpu: e.cpu ?? null, max: e.maxInstances ?? null, conc: e.concurrency ?? null,
        secrets: (e.secretEnvironmentVariables || []).map((s) => s.key), callable: !!e.callableTrigger } : null; }
    process.stdout.write(JSON.stringify(out));`;
  const e = JSON.parse(execFileSync(process.execPath, ['-e', script], { cwd: path.join(__dirname, '..'), encoding: 'utf8', maxBuffer: 1 << 24 }));
  for (const n of ['mapsRouteCF', 'mapsAutocompleteCF', 'mapsPlaceDetailsCF', 'mapsGeocodeCF']) {
    assert.ok(e[n], n); assert.equal(e[n].callable, true);
    assert.deepEqual(e[n].region, ['europe-west1']);
    assert.deepEqual([e[n].cpu, e[n].max, e[n].conc], [0.5, 2, 1]);
    assert.deepEqual(e[n].secrets, [SECRET_NAME]);
  }
});

test('émulateurs locaux : le secret Maps reçoit une valeur factice (Secret Manager jamais interrogé)', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'test-env', 'stage-functions.js'), 'utf8');
  const list = /const secrets = \[([^\]]+)\]/.exec(src);
  assert.ok(list && list[1].includes(`'${SECRET_NAME}'`), 'stage-functions.js doit lister le secret Maps');
});

test('aucune valeur de clé dans le module ni dans le branchement', () => {
  const fs = require('node:fs');
  for (const f of ['mapsProxy.js', 'index.js']) {
    const src = fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
    assert.ok(!/AIza[0-9A-Za-z_-]{20,}/.test(src), `${f} ne doit contenir aucune clé`);
  }
});
