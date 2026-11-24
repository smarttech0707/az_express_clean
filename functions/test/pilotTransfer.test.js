'use strict';

// Mission 7E-56 : transfert de livreur et restriction pilotDriverIds (Restaurant/Boulangerie v2), plus effet de clientAccess=open.
// Faux Firestore en mémoire ; aucun accès cloud.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildDeliveryTransfer } = require('../driverTransfer');
const cfg = require('../partnerOrdersConfig');

process.env.DELIVERY_PROOFS_ENABLED = 'true';
process.env.DELIVERY_PROOF_PEPPER = 'test-pepper';

const ts = (ms) => ({ toMillis: () => ms });
const admin = { firestore: { Timestamp: { fromMillis: ts }, FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion } } };
const driver = (extra = {}) => ({ wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou', lat: 6.73, lng: -3.49, ...extra });
const CFG = 'config/partnerOrdersV2';
const pilot = (over = {}) => ({ pilotPartnerIds: ['t7e-resto'], pilotClientIds: ['t7e-client'], pilotDriverIds: ['t7e-driver'], clientAccess: 'restricted', creationOpen: false, version: 5, ...over });
const V2 = { amountsVersion: 2, sellerType: 'restaurant' };
const ABSENT = Symbol('absent');

function setup({ order = V2, config = pilot(), extra = {} } = {}) {
  const docs = {
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'picked_up', budget: 1500, paymentMethod: 'cash', isPaid: false,
      pickupCityId: 'abengourou', deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1, transferCount: 0,
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200, commissionTxId: 'commission_o1_dA', ...order,
    },
    'livreurs/dA': driver({ isOnDelivery: true }),
    'livreurs/t7e-driver': driver(),
    'livreurs/outsider': driver(),
    ...extra,
  };
  if (config !== ABSENT) docs[CFG] = config;
  const db = fakeDb(docs);
  const run = buildDeliveryTransfer({
    db, admin, onCall: (...args) => ({ run: args[args.length - 1] }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, deliveryProofPepper: null, notify: async () => {},
  }).run;
  const call = (uid, data) => run({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const get = (p) => db.store.get(p);
  return { db, call, get };
}
const request = (h) => h.call('dA', { action: 'request', orderId: 'o1', reason: 'emergency' });
const refused = (e) => e.code === 'permission-denied' && /DRIVER_NOT_IN_PILOT/.test(e.message);
const withCandidates = (h, id, ids) => h.db.store.set(`delivery_transfers/${id}`, { ...h.get(`delivery_transfers/${id}`), candidateIds: ids });

test('1. t7e-driver autorisé : candidat, acceptation, remise confirmée, la course lui est transférée', async () => {
  const h = setup();
  const r = await request(h);
  assert.deepEqual(h.get(`delivery_transfers/${r.transferId}`).candidateIds, ['t7e-driver']);
  await h.call('t7e-driver', { action: 'accept', transferId: r.transferId });
  const p = await h.call('t7e-driver', { action: 'prepareHandover', transferId: r.transferId });
  const res = await h.call('dA', { action: 'confirmHandover', transferId: r.transferId, token: p.token });
  assert.equal(res.newDriverId, 't7e-driver');
  assert.equal(h.get('orders/o1').driverId, 't7e-driver');
});

test('2. livreur hors pilotDriverIds : jamais candidat ; acceptation directe refusée sans réservation', async () => {
  const h = setup();
  const r = await request(h);
  assert.equal(h.get(`delivery_transfers/${r.transferId}`).candidateIds.includes('outsider'), false);
  // Contournement : le livreur figure (hypothétiquement) parmi les candidats, ou appelle directement la fonction.
  withCandidates(h, r.transferId, ['t7e-driver', 'outsider']);
  await assert.rejects(h.call('outsider', { action: 'accept', transferId: r.transferId }), refused);
  assert.equal(h.get(`delivery_transfers/${r.transferId}`).status, 'requested');
  assert.notEqual(h.get('livreurs/outsider').isOnDelivery, true);
  await assert.rejects(h.call('outsider', { action: 'prepareHandover', transferId: r.transferId }));
  await assert.rejects(h.call('outsider', { action: 'confirmHandover', transferId: r.transferId, token: 'x' }));
  assert.equal(h.get('orders/o1').driverId, 'dA');
});

test('3. liste absente, vide ou document de config absent : aucun candidat, transfert refusé', async () => {
  for (const config of [pilot({ pilotDriverIds: undefined }), pilot({ pilotDriverIds: [] }), ABSENT]) {
    const h = setup({ config });
    await assert.rejects(request(h), (e) => e.code === 'failed-precondition');
    assert.equal(h.get('orders/o1').activeTransferId, undefined);
  }
});

test('4. liste mal formée : refus (aucun candidat) même si elle contient t7e-driver', async () => {
  for (const bad of [['t7e-driver', 42], 't7e-driver', { 0: 't7e-driver' }, ['t7e-driver', '']]) {
    const h = setup({ config: pilot({ pilotDriverIds: bad }) });
    await assert.rejects(request(h), (e) => e.code === 'failed-precondition', JSON.stringify(bad));
  }
});

test('5. config modifiée entre proposition et acceptation / finalisation : le livreur devenu non autorisé est refusé', async () => {
  const hA = setup();
  const r1 = await request(hA);
  hA.db.store.set(CFG, pilot({ pilotDriverIds: ['autre'], version: 6 }));
  await assert.rejects(hA.call('t7e-driver', { action: 'accept', transferId: r1.transferId }), refused);
  assert.notEqual(hA.get('livreurs/t7e-driver').isOnDelivery, true);

  const hB = setup();
  const r2 = await request(hB);
  await hB.call('t7e-driver', { action: 'accept', transferId: r2.transferId });
  const p = await hB.call('t7e-driver', { action: 'prepareHandover', transferId: r2.transferId });
  hB.db.store.set(CFG, pilot({ pilotDriverIds: [], version: 6 }));
  await assert.rejects(hB.call('dA', { action: 'confirmHandover', transferId: r2.transferId, token: p.token }), refused);
  assert.equal(hB.get('orders/o1').driverId, 'dA', 'A reste responsable');
  assert.equal(hB.get('orders/o1').transferCount, 0);
});

test('6. commandes ordinaires, historiques et autres services : aucune restriction, même liste vide', async () => {
  for (const order of [{}, { amountsVersion: 1, sellerType: 'restaurant' }, { amountsVersion: 2, sellerType: 'pharmacie' }, { sellerType: 'restaurant' }]) {
    const h = setup({ order, config: pilot({ pilotDriverIds: [] }) });
    const r = await request(h);
    assert.ok(h.get(`delivery_transfers/${r.transferId}`).candidateIds.includes('outsider'), JSON.stringify(order));
    await h.call('outsider', { action: 'accept', transferId: r.transferId });
    assert.equal(h.get(`delivery_transfers/${r.transferId}`).status, 'accepted');
  }
});

test('7. clientAccess=open : liste de livreurs déclarée = restriction maintenue ; liste vidée = livreurs libres', async () => {
  const h = setup({ config: pilot({ clientAccess: 'open' }) });
  const r = await request(h);
  assert.deepEqual(h.get(`delivery_transfers/${r.transferId}`).candidateIds, ['t7e-driver']);
  withCandidates(h, r.transferId, ['t7e-driver', 'outsider']);
  await assert.rejects(h.call('outsider', { action: 'accept', transferId: r.transferId }), refused);
  h.db.store.set(CFG, pilot({ clientAccess: 'open', pilotDriverIds: [], version: 7 }));
  await h.call('outsider', { action: 'accept', transferId: r.transferId });
  assert.equal(h.get(`delivery_transfers/${r.transferId}`).toDriverId, 'outsider');
});

test('8. driverRefusal : restreint/ouvert × liste absente, vide, valide, malformée', () => {
  const c = (over) => cfg.parsePilotConfig({ pilotPartnerIds: ['p'], clientAccess: 'restricted', ...over });
  const ok = (config, id) => cfg.driverRefusal(config, id) === null;
  assert.equal(ok(c({ pilotDriverIds: ['d'] }), 'd'), true);
  assert.equal(ok(c({ pilotDriverIds: ['d'] }), 'x'), false);
  assert.equal(ok(c({}), 'd'), false);
  assert.equal(ok(c({ pilotDriverIds: [] }), 'd'), false);
  assert.equal(ok(c({ clientAccess: 'open', pilotDriverIds: ['d'] }), 'x'), false);
  assert.equal(ok(c({ clientAccess: 'open', pilotDriverIds: ['d'] }), 'd'), true);
  assert.equal(ok(c({ clientAccess: 'open', pilotDriverIds: ['d', 3] }), 'd'), false);
  assert.equal(ok(c({ clientAccess: 'open', pilotDriverIds: 'd' }), 'd'), false);
  assert.equal(ok(c({ clientAccess: 'open', pilotDriverIds: [] }), 'x'), true);
  assert.equal(ok(c({ clientAccess: 'open' }), 'x'), true);
  assert.equal(ok(c({ pilotDriverIds: ['d'] }), undefined), false);
});
