'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fakeDb } = require('./fakeFirestore');
const tarif = require('../tarifService');
const { evaluateTariff, recordTariffObservation, observeOrderTariff } = require('../tariffObservation');

const at = (h, m = 0) => Date.UTC(2026, 9, 30, h, m, 0);
const ts = (ms) => ({ toMillis: () => ms });
const INSIDE = { destLat: 6.73, destLng: -3.49 };          // zone centrale
const OUTSIDE = { destLat: 6.95, destLng: -3.25 };         // ~35 km
const order = (extra) => ({ type: 'shopping', budget: 500, createdAt: ts(at(10)), ...INSIDE, ...extra });

test('tarifs officiels inchangés (référence de la phase d’observation)', () => {
  const day = tarif.compute({ clientLat: 6.73, clientLng: -3.49, time: { getHours: () => 10 } });
  const night = tarif.compute({ clientLat: 6.73, clientLng: -3.49, time: { getHours: () => 22 } });
  assert.deepEqual([day.standardPrice, day.expressPrice, night.standardPrice, night.expressPrice], [500, 1000, 1000, 1500]);
});

test('jour, zone centrale : 500 et 1000 conformes ; 300 sous le minimum ; 700 hors grille', () => {
  assert.equal(evaluateTariff(order({ budget: 500 })), null);
  assert.equal(evaluateTariff(order({ budget: 1000 })), null);
  const low = evaluateTariff(order({ budget: 300 }));
  assert.deepEqual([low.kind, low.expectedMin, low.expectedStandard, low.expectedExpress, low.isNight], ['below_minimum', 500, 500, 1000, false]);
  assert.equal(evaluateTariff(order({ budget: 700 })).kind, 'off_grid_inside_zone');
});

test('nuit, zone centrale : 500 devient insuffisant (min 1000), 1000 et 1500 conformes', () => {
  const night = (b) => evaluateTariff(order({ budget: b, createdAt: ts(at(22)) }));
  assert.equal(night(500).kind, 'below_minimum');
  assert.equal(night(500).expectedMin, 1000);
  assert.equal(night(1000), null);
  assert.equal(night(1500), null);
  assert.equal(evaluateTariff(order({ budget: 500, createdAt: ts(at(3)) })).kind, 'below_minimum');
});

test('autour de 20 h : tolérance ±10 min (horloge de l’appareil ≠ serveur) — aucun faux positif', () => {
  for (const [h, m] of [[19, 55], [20, 0], [20, 5], [19, 51]]) {
    assert.equal(evaluateTariff(order({ budget: 500, createdAt: ts(at(h, m)) })), null, `${h}:${m}`);
  }
  assert.equal(evaluateTariff(order({ budget: 500, createdAt: ts(at(20, 30)) })).kind, 'below_minimum');
});

test('hors ville : seul un budget sous 500 est signalé (distance routière inconnue, aucun appel Google Maps)', () => {
  assert.equal(evaluateTariff(order({ ...OUTSIDE, budget: 2000 })), null);
  assert.equal(evaluateTariff(order({ ...OUTSIDE, budget: 500 })), null);
  assert.equal(evaluateTariff(order({ ...OUTSIDE, budget: 450 })).kind, 'below_minimum');
  const r = evaluateTariff(order({ ...OUTSIDE, budget: 450 }));
  assert.equal(r.isOutside, true);
  assert.ok(r.distanceFromCenterKm > 8);
});

test('hors ville de nuit au-delà de 10 km : commande normalement refusée par l’application → signalée', () => {
  const r = evaluateTariff(order({ ...OUTSIDE, budget: 3000, createdAt: ts(at(22)) }));
  assert.equal(r.kind, 'forbidden_late_night');
  assert.equal(r.expectedStandard, null);
});

test('types non concernés ou données incomplètes : jamais observés', () => {
  for (const o of [order({ type: 'restaurant', budget: 100 }), order({ type: 'pharmacie', budget: 100 }),
    order({ type: 'marketplace', budget: 100 }), order({ destLat: undefined, destLng: undefined, budget: 100 }),
    order({ budget: 'abc' }), null, undefined]) {
    assert.equal(evaluateTariff(o), null);
  }
});

test('aucune donnée personnelle dans le journal ; écriture unique et idempotente ; le serveur ne modifie jamais la commande', async () => {
  const db = fakeDb({ 'orders/o1': { ...order({ budget: 300, clientId: 'c1', clientName: 'Aya', clientPhone: '0700000000', latitude: 6.7, longitude: -3.5 }) } });
  const before = JSON.stringify(db.store.get('orders/o1'));
  assert.equal(await observeOrderTariff(db, 'o1', db.store.get('orders/o1')), true);
  assert.equal(await observeOrderTariff(db, 'o1', db.store.get('orders/o1')), false); // déjà journalisé
  const rec = db.store.get('tariff_observations/o1');
  assert.equal(rec.kind, 'below_minimum');
  assert.equal(rec.mode, 'observe');
  assert.doesNotMatch(JSON.stringify(rec), /c1|Aya|0700000000|clientId|destLat|destLng|latitude|longitude/);
  assert.equal(JSON.stringify(db.store.get('orders/o1')), before);
  assert.equal([...db.store.keys()].filter((k) => k.startsWith('tariff_observations/')).length, 1);
});

test('échec d’écriture du journal : ne lève jamais (le dispatch n’est jamais bloqué)', async () => {
  const db = { collection: () => ({ doc: () => ({ create: async () => { throw new Error('indisponible'); } }) }) };
  assert.equal(await observeOrderTariff(db, 'o1', order({ budget: 300 })), false);
  assert.equal(await recordTariffObservation(db, 'o1', null), false);
});

test('branchement : observation seulement, jamais un refus (dispatchOrderToDriver) ; tarifService.js non modifié par ce chantier', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const i = src.indexOf('exports.dispatchOrderToDriver');
  const body = src.slice(i, src.indexOf('PAIEMENT WALLET / ANNULATION', i));
  assert.match(body, /await observeOrderTariff\(db, String\(orderId\), order\);/);
  assert.doesNotMatch(body.slice(body.indexOf('observeOrderTariff'), body.indexOf('assertValidDispatchPoint')), /throw/);
});
