'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { CITIES, planSeed, parseArguments } = require('../scripts/seedAzMarketCities');

test('initial AZ Market catalogue has stable unique city ids', () => {
  assert.equal(CITIES.length, 61);
  assert.equal(new Set(CITIES.map(([cityId]) => cityId)).size, CITIES.length);
  assert.ok(CITIES.every(([cityId, name]) =>
    /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(cityId) && name.length > 0));
});

test('seed reuses an existing city document without enabling delivery', () => {
  const plan = planSeed([{ id: 'legacy-abidjan', data: {
    type: 'ville', cityId: 'abidjan', isServiceable: false,
  } }]);
  const abidjan = plan.find((entry) => entry.cityId === 'abidjan');
  assert.deepEqual(abidjan, {
    cityId: 'abidjan',
    documentId: 'legacy-abidjan',
    operation: 'update',
    patch: { isMarketplaceEnabled: true },
  });
});

test('seed creates a market-only city without geometry or delivery service', () => {
  const plan = planSeed([]);
  const abidjan = plan.find((entry) => entry.cityId === 'abidjan');
  assert.equal(abidjan.operation, 'create');
  assert.equal(abidjan.patch.isMarketplaceEnabled, true);
  assert.equal(abidjan.patch.isServiceable, false);
  assert.equal(abidjan.patch.coordinateSource, 'unknown');
  assert.equal(Object.hasOwn(abidjan.patch, 'lat'), false);
  assert.equal(Object.hasOwn(abidjan.patch, 'lng'), false);
});

test('apply requires the explicit CLI mode and confirmation', () => {
  assert.deepEqual(parseArguments([]), { mode: 'dry-run', confirmation: undefined });
  assert.deepEqual(parseArguments(['--apply', '--confirm=AZ_MARKET_CI']), {
    mode: 'apply', confirmation: 'AZ_MARKET_CI',
  });
});
