'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { compute, CENTER_LAT, CENTER_LNG } = require('../tarifService');

// Un point clairement hors du rayon de 8 km (utilisé avec routeDistanceKm
// pour contrôler précisément la distance facturée sans dépendre de la
// géométrie haversine exacte).
const FAR_LAT = 7.5;
const FAR_LNG = -3.4961;

const DAY   = new Date(2026, 6, 2, 14, 0); // 14h00 — jour
const DUSK  = new Date(2026, 6, 2, 20, 30); // 20h30 — nuit, pas "late night"
const LATE  = new Date(2026, 6, 2, 21, 0);  // 21h00 pile — "late night"
const LATE2 = new Date(2026, 6, 2, 22, 45); // nuit tardive

test('compute: jour, dans la zone centrale (≤8km) → tarif plat 500/1000', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: DAY });
  assert.equal(r.standardPrice, 500);
  assert.equal(r.expressPrice, 1000);
  assert.equal(r.isNight, false);
  assert.equal(r.isOutside, false);
  assert.equal(r.canOrder, true);
});

test('compute: nuit, dans la zone centrale (≤8km) → tarif plat 1000/1500', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: DUSK });
  assert.equal(r.standardPrice, 1000);
  assert.equal(r.expressPrice, 1500);
  assert.equal(r.isNight, true);
  assert.equal(r.isOutside, false);
  assert.equal(r.canOrder, true);
});

// BUSINESS RULE:
// Livraison Express
// Jour = 1000 FCFA
// Nuit = 1500 FCFA
// Ne pas modifier sans décision métier.
//
// Verrouillage des 6 heures pivots exactes (Master Prompt « Verrouillage du
// tarif Express de nuit ») — zone centrale (≤8km), seul endroit où le tarif
// Express est un montant plat directement gouverné par cette règle.
test('Express à 10h → 1000 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 10, 0) });
  assert.equal(r.expressPrice, 1000);
});

test('Express à 19h59 → 1000 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 19, 59) });
  assert.equal(r.expressPrice, 1000);
});

test('Express à 20h00 → 1500 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 20, 0) });
  assert.equal(r.expressPrice, 1500);
});

test('Express à 23h30 → 1500 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 23, 30) });
  assert.equal(r.expressPrice, 1500);
});

test('Express à 05h59 → 1500 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 5, 59) });
  assert.equal(r.expressPrice, 1500);
});

test('Express à 06h00 → 1000 FCFA', () => {
  const r = compute({ clientLat: CENTER_LAT, clientLng: CENTER_LNG, time: new Date(2026, 6, 2, 6, 0) });
  assert.equal(r.expressPrice, 1000);
});

test('compute: jour, hors zone, courte distance (10 km) → tarif kilométrique', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 10, time: DAY });
  // 500 + 10*150 = 2000, arrondi à 50 -> 2000
  assert.equal(r.standardPrice, 2000);
  assert.equal(r.expressPrice, 2800); // round50(2000*1.4)
  assert.equal(r.isOutside, true);
  assert.equal(r.canOrder, true);
});

test('compute: jour, hors zone, longue distance (30 km) → tarif kilométrique plus élevé', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 30, time: DAY });
  // 500 + 30*150 = 5000, arrondi à 50 -> 5000
  assert.equal(r.standardPrice, 5000);
  assert.equal(r.isOutside, true);
  assert.equal(r.canOrder, true);
});

test('compute: nuit mais avant 21h00, hors zone, >10km → PAS refusé (le refus ne s\'applique qu\'après 21h00)', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 15, time: DUSK });
  assert.equal(r.canOrder, true);
  assert.equal(r.isNight, true);
});

test('compute: limite 21h00, hors zone, >10km → refusé', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 10.1, time: LATE });
  assert.equal(r.canOrder, false);
  assert.equal(r.standardPrice, 0);
  assert.ok(r.rejectionMessage && r.rejectionMessage.includes('21h00'));
});

test('compute: après 21h00, hors zone, mais ≤10km → PAS refusé', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 10, time: LATE2 });
  assert.equal(r.canOrder, true);
});

test('compute: routeDistanceKm prioritaire sur la distance à vol d\'oiseau quand fournie', () => {
  const withRoute    = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 20, time: DAY });
  const withoutRoute = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, time: DAY });
  assert.notEqual(withRoute.standardPrice, withoutRoute.standardPrice);
});

test('compute: distance nulle/absente retombe sur la distance à vol d\'oiseau depuis le centre', () => {
  const r = compute({ clientLat: FAR_LAT, clientLng: FAR_LNG, routeDistanceKm: 0, time: DAY });
  assert.equal(r.isOutside, true);
  assert.ok(r.standardPrice > 500); // tarif kilométrique appliqué, pas le tarif plat
});
