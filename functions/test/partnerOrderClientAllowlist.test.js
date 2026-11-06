'use strict';

// Mission 7E-41 — liste blanche des clients du pilote Restaurant v2 (config/partnerOrdersV2.pilotClientIds / clientAccess).
// Partie pure : lecture de la configuration, validation des modifications, refus par défaut.
const test = require('node:test');
const assert = require('node:assert/strict');
const cfg = require('../partnerOrdersConfig');

const base = { pilotPartnerIds: ['r1'], creationOpen: true };

test('mode restreint par défaut : liste absente, vide ou malformée = aucun client autorisé', () => {
  const bad = [undefined, null, [], 'c1', { c1: true }, ['c1', 5], ['c1', ''], ['c1', 'a/b'], 7];
  for (const list of bad) {
    const c = cfg.parsePilotConfig({ ...base, pilotClientIds: list });
    assert.equal(c.clientAccess, 'restricted');
    assert.equal(cfg.creationRefusal(c, 'r1', 'c1').code, 'CLIENT_NOT_IN_PILOT', JSON.stringify(list));
  }
  assert.equal(cfg.creationRefusal(cfg.parsePilotConfig(null), 'r1', 'c1').code, 'PARTNER_NOT_IN_PILOT');
});

test('client listé autorisé, tout autre uid refusé, uid absent refusé', () => {
  const c = cfg.parsePilotConfig({ ...base, pilotClientIds: ['c1', 'c2'] });
  assert.equal(cfg.creationRefusal(c, 'r1', 'c1'), null);
  assert.equal(cfg.creationRefusal(c, 'r1', 'c2'), null);
  for (const uid of ['c3', '', undefined, null, 5, ['c1']]) assert.equal(cfg.creationRefusal(c, 'r1', uid).code, 'CLIENT_NOT_IN_PILOT', String(uid));
  assert.equal(cfg.creationRefusal(c, 'autre', 'c1').code, 'PARTNER_NOT_IN_PILOT', 'partenaire hors liste prioritaire');
  assert.equal(cfg.creationRefusal(cfg.parsePilotConfig({ ...base, pilotClientIds: ['c1'], creationOpen: false }), 'r1', 'c1').code, 'CREATION_CLOSED');
});

test('accessRefusal ignore creationOpen (rejeu) mais pas le partenaire ni le client', () => {
  const closed = cfg.parsePilotConfig({ pilotPartnerIds: ['r1'], pilotClientIds: ['c1'], creationOpen: false });
  assert.equal(cfg.accessRefusal(closed, 'r1', 'c1'), null);
  assert.equal(cfg.accessRefusal(closed, 'r1', 'c9').code, 'CLIENT_NOT_IN_PILOT');
  assert.equal(cfg.accessRefusal(closed, 'r9', 'c1').code, 'PARTNER_NOT_IN_PILOT');
});

test('ouverture générale : seul clientAccess === "open" exact ; toute autre valeur reste restreinte', () => {
  const open = cfg.parsePilotConfig({ ...base, clientAccess: 'open' });
  assert.equal(cfg.creationRefusal(open, 'r1', 'n’importe-qui'), null);
  for (const v of ['OPEN', true, 'true', 1, 'restricted', null, {}]) {
    assert.equal(cfg.creationRefusal(cfg.parsePilotConfig({ ...base, clientAccess: v }), 'r1', 'c1').code, 'CLIENT_NOT_IN_PILOT', String(v));
  }
});

test('validation des modifications : liste de clients, mode d’accès, confirmation d’ouverture générale', () => {
  const ok = (patch, extra = {}) => cfg.validateConfigChange({ patch, expectedVersion: 0, reason: 'Justification suffisante', ...extra });
  assert.deepEqual(ok({ pilotClientIds: ['b', 'a'] }).patch, { pilotClientIds: ['a', 'b'] });
  assert.deepEqual(ok({ pilotClientIds: [] }).patch, { pilotClientIds: [] });
  for (const list of ['a', ['a', 'a'], ['a/b'], [''], [5], Array.from({ length: 51 }, (_, i) => `c${i}`), null]) {
    assert.throws(() => ok({ pilotClientIds: list }), (e) => e.code === 'INVALID_CONFIG', JSON.stringify(list));
  }
  assert.throws(() => ok({ clientAccess: 'tous' }), (e) => e.code === 'INVALID_CONFIG');
  assert.deepEqual(ok({ clientAccess: 'restricted' }).patch, { clientAccess: 'restricted' });
  assert.throws(() => ok({ clientAccess: 'open' }), (e) => e.code === 'GENERAL_OPENING_NOT_CONFIRMED');
  assert.throws(() => ok({ clientAccess: 'open' }, { confirmGeneralOpening: 'true' }), (e) => e.code === 'GENERAL_OPENING_NOT_CONFIRMED');
  assert.deepEqual(ok({ clientAccess: 'open' }, { confirmGeneralOpening: true }).patch, { clientAccess: 'open' });
  assert.throws(() => ok({ clientIds: ['a'] }), (e) => e.code === 'INVALID_CONFIG', 'champ inconnu');
});

test('applyConfigChange : versionné, audité, ancien document complété en mode restreint, ouverture générale signalée', async () => {
  const store = new Map([['config/partnerOrdersV2', { pilotPartnerIds: ['r1'], creationOpen: true, version: 4 }]]);
  const db = {
    collection: (c) => ({ doc: (d) => ({ path: `${c}/${d}` }) }),
    runTransaction: async (fn) => fn({ get: async (r) => ({ exists: store.has(r.path), data: () => store.get(r.path) }), set: (r, v) => store.set(r.path, v) }),
  };
  const set = (patch, expectedVersion, extra = {}) => cfg.applyConfigChange({ db, uid: 'root', input: { patch, expectedVersion, reason: 'Modification de test', ...extra }, nowMs: 1 });
  const r1 = await set({ pilotClientIds: ['c1'] }, 4);
  assert.deepEqual(r1.before, { pilotPartnerIds: ['r1'], pilotClientIds: [], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 4 });
  assert.deepEqual(r1.after.pilotClientIds, ['c1']);
  assert.equal(r1.generalOpening, false);
  await assert.rejects(set({ pilotClientIds: ['c2'] }, 4), (e) => e.code === 'CONFIG_CONFLICT');
  const r2 = await set({ clientAccess: 'open' }, 5, { confirmGeneralOpening: true });
  assert.equal(r2.generalOpening, true);
  assert.equal(store.get('config/partnerOrdersV2').lastChange.after.clientAccess, 'open');
  const r3 = await set({ clientAccess: 'restricted' }, 6);
  assert.equal(r3.generalOpening, false);
  assert.deepEqual(store.get('config/partnerOrdersV2').pilotClientIds, ['c1'], 'la liste survit à une réouverture/fermeture du mode');
});
