'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { relatedPersonalPatch } = require('../accountRelatedPersonalData');
const roles = new Set(['client', 'livreur', 'seller']);
const removed = Symbol('delete');
test('multirole seller preserves another customer and driver personal data', () => {
  assert.deepEqual(relatedPersonalPatch({sellerId:'u',clientId:'other',driverId:'other',clientPhone:'private',driverPhone:'private'}, 'u', roles, removed), {});
});
test('customer cleanup preserves driver and financial fields', () => {
  const data={clientId:'u',driverId:'other',clientPhone:'private',driverPhone:'private',wallet:400,commission:100};
  assert.deepEqual(relatedPersonalPatch(data,'u',roles,removed), {clientPhone:removed});
  assert.equal(data.wallet,400); assert.equal(data.commission,100);
});
test('driver cleanup preserves customer personal data', () => {
  assert.deepEqual(relatedPersonalPatch({clientId:'other',driverId:'u',clientName:'private',driverName:'private'},'u',roles,removed), {driverName:removed});
});
test('missing identity is not inferred and repeated cleanup is empty', () => {
  assert.deepEqual(relatedPersonalPatch({clientName:'private'},'u',roles,removed),{});
  assert.deepEqual(relatedPersonalPatch({clientId:'u',driverId:'u'},'u',roles,removed),{});
});
