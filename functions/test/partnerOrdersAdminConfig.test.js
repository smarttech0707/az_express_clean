'use strict';

// Mission 7C-2 — configuration administrative config/partnerOrdersV2 (pilotPartnerIds / creationOpen / managementFrozen) :
// contrôle super-administrateur, validation stricte, version (concurrence), journal avant/après, gel de gestion.
// Fonctions réelles (partnerOrderActionCF, requireSuperAdmin) sur faux Firestore sérialisé.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildPartnerOrderAction, PARTNER_ACTIONS } = require('../partnerOrderActions');
const { calculateCommission } = require('../dispatch');
const { requireSuperAdmin } = require('../adminGuards');
const cfg = require('../partnerOrdersConfig');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const NOW = 1_800_000_000_000;

const pendingV2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: null, status: 'pending', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000,
  budget: 500, shoppingBudget: 0, latitude: 6.73, longitude: -3.49, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved', ...extra,
});

function world(seed = {}) {
  const db = fakeDb({
    'orders/o1': pendingV2(),
    'clients/c1': { wallet: 16000 },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'admins/root': { role: 'super', isActive: true },
    'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = []; const limits = []; const dispatches = [];
  const fn = buildPartnerOrderAction({
    db, admin, HttpsError, onCall: oc, checkRateLimit: async (...a) => { limits.push(a); }, logAudit: async (a) => { audits.push(a); },
    calculateCommission, requireSuperAdmin, now: () => NOW,
    dispatchAccepted: async (id) => { dispatches.push(id); return { dispatched: false, mode: 'none' }; },
  }).run;
  const call = (uid, data, provider) => fn({ auth: authOf(uid, provider), data });
  const set = (uid, patch, expectedVersion, reason = 'Ouverture du pilote validée par la direction') => call(uid, { action: 'setPartnerOrdersConfig', patch, expectedVersion, reason });
  return {
    db, audits, limits, dispatches, call, set, store: db.store,
    config: () => db.store.get('config/partnerOrdersV2'),
    order: () => db.store.get('orders/o1'),
    snapshot: () => JSON.stringify([db.store.get('orders/o1'), db.store.get('clients/c1'), db.store.get('restaurants/r1')]),
  };
}

test('contrôle d’accès : seul le super-administrateur modifie la configuration ; client, partenaire, sous-admin et anonyme refusés', async () => {
  const w = world();
  for (const uid of ['c1', 'r1', 'sub', 'nobody']) {
    await assert.rejects(() => w.set(uid, { creationOpen: true }, 0), (e) => e.code === 'permission-denied', uid);
  }
  await assert.rejects(() => w.set('root', { creationOpen: true }, 0, undefined).then(() => w.call('root', { action: 'setPartnerOrdersConfig' }, 'anonymous')), (e) => e.code === 'unauthenticated');
  assert.equal(w.store.has('config/partnerOrdersV2') && w.config().creationOpen === true && w.config().version === 1, true, 'seul l’appel du super-admin a abouti');
  const clean = world();
  for (const uid of ['c1', 'r1', 'sub']) await assert.rejects(() => clean.set(uid, { creationOpen: true }, 0));
  assert.equal(clean.store.has('config/partnerOrdersV2'), false, 'aucune écriture par un non super-administrateur');
});

test('validation stricte : champs inconnus, types, liste pilote, justification et version — refus sans écriture, tracé', async () => {
  const w = world();
  const bad = [
    [{}, 0], [{ unknown: true }, 0], [{ creationOpen: 'true' }, 0], [{ creationOpen: 1 }, 0], [{ managementFrozen: null }, 0],
    [{ pilotPartnerIds: 'r1' }, 0], [{ pilotPartnerIds: ['r1', 'r1'] }, 0], [{ pilotPartnerIds: ['a/b'] }, 0], [{ pilotPartnerIds: [''] }, 0],
    [{ pilotPartnerIds: [5] }, 0], [{ pilotPartnerIds: Array.from({ length: 51 }, (_, i) => `p${i}`) }, 0], [{ creationOpen: true }, -1],
    [{ creationOpen: true }, 1.5], [{ creationOpen: true }, '0'], [{ creationOpen: true, extra: 1 }, 0],
  ];
  for (const [patch, version] of bad) {
    const r = await w.set('root', patch, version);
    assert.deepEqual([r.success, r.code], [false, 'INVALID_CONFIG'], JSON.stringify([patch, version]));
  }
  for (const reason of [undefined, '', 'court', 'x'.repeat(301)]) {
    const r = await w.call('root', { action: 'setPartnerOrdersConfig', patch: { creationOpen: true }, expectedVersion: 0, reason });
    assert.equal(r.code, 'INVALID_CONFIG');
  }
  assert.equal(w.store.has('config/partnerOrdersV2'), false);
  assert.ok(w.audits.every((a) => a.status === 'denied'));
});

test('modification : version incrémentée, trace dans le document, audit avant/après avec auteur et justification', async () => {
  const w = world();
  const r = await w.set('root', { pilotPartnerIds: ['r2', 'r1'], creationOpen: true }, 0);
  assert.equal(r.success, true);
  assert.deepEqual(r.data.config, { pilotPartnerIds: ['r1', 'r2'], creationOpen: true, managementFrozen: false, version: 1 });
  const c = w.config();
  assert.deepEqual([c.version, c.updatedBy, c.updatedAtMs, c.managementFrozen], [1, 'root', NOW, false]);
  assert.deepEqual(c.lastChange.before, { pilotPartnerIds: [], creationOpen: false, managementFrozen: false, version: 0 });
  assert.equal(c.lastChange.after.creationOpen, true);
  const audit = w.audits.find((a) => a.action === 'partner_orders_config_update' && !a.status);
  assert.equal(audit.userId, 'root');
  assert.equal(audit.metadata.before.version, 0);
  assert.equal(audit.metadata.after.version, 1);
  assert.match(audit.metadata.reason, /direction/);
  assert.deepEqual(w.limits[w.limits.length - 1].slice(1), ['partner_orders_config', 10, 600]);
  // Modification partielle : les champs absents du patch sont conservés.
  const r2 = await w.set('root', { creationOpen: false }, 1);
  assert.deepEqual(r2.data.config, { pilotPartnerIds: ['r1', 'r2'], creationOpen: false, managementFrozen: false, version: 2 });
});

test('modifications concurrentes : même version attendue → une seule réussit, l’autre CONFIG_CONFLICT, version +1', async () => {
  for (let i = 0; i < 4; i++) {
    const w = world();
    const calls = [w.set('root', { creationOpen: true }, 0), w.set('root', { managementFrozen: true }, 0), w.set('root', { pilotPartnerIds: ['r1'] }, 0)];
    const res = await Promise.all(i % 2 ? calls.reverse() : calls);
    assert.equal(res.filter((r) => r.success).length, 1, `tour ${i}`);
    assert.equal(res.filter((r) => r.code === 'CONFIG_CONFLICT').length, 2);
    assert.equal(w.config().version, 1);
  }
  const w = world({ 'config/partnerOrdersV2': { pilotPartnerIds: ['r1'], creationOpen: true, version: 4 } });
  assert.equal((await w.set('root', { creationOpen: false }, 3)).code, 'CONFIG_CONFLICT');
  assert.equal(w.config().creationOpen, true);
});

test('creationOpen=false : commandes existantes toujours gérables, liste pilote intacte, blocage historique maintenu', async () => {
  const w = world({ 'config/partnerOrdersV2': { pilotPartnerIds: ['r1'], creationOpen: true, version: 1 } });
  assert.equal((await w.set('root', { creationOpen: false }, 1)).success, true);
  const c = cfg.parsePilotConfig(w.config());
  assert.equal(cfg.v2CreationAllowed(c, 'r1'), false, 'plus aucune création v2');
  assert.equal(cfg.creationRefusal(c, 'r1').code, 'CREATION_CLOSED');
  assert.equal(cfg.creationRefusal(c, 'autre').code, 'PARTNER_NOT_IN_PILOT', 'hors pilote : jamais CREATION_CLOSED');
  assert.equal(cfg.legacyCreationBlocked(c, 'r1'), true, 'le blocage historique du pilote subsiste');
  assert.deepEqual([...c.ids], ['r1'], 'la liste pilote n’a pas été vidée');
  // Gestion d’une commande existante : accepter, préparer, prête, tout fonctionne.
  assert.equal((await w.call('r1', { orderId: 'o1', action: 'acceptPartnerOrder' })).success, true);
  assert.equal((await w.call('r1', { orderId: 'o1', action: 'startPreparation' })).success, true);
  assert.equal((await w.call('r1', { orderId: 'o1', action: 'markReady' })).success, true);
  assert.equal(w.order().sellerStatus, 'ready');
  assert.equal(w.dispatches.length, 1);
});

test('managementFrozen=true : les 9 actions de gestion refusées, aucun effet financier, config reste modifiable pour dégeler', async () => {
  const w = world({ 'config/partnerOrdersV2': { pilotPartnerIds: ['r1'], creationOpen: true, version: 1 } });
  assert.equal((await w.set('root', { managementFrozen: true }, 1)).success, true);
  const before = w.snapshot();
  const extra = { reason: 'Rupture de stock', amount: 3500, requestId: 'resolve-request-0001', justification: 'Décision après appel', finalAmount: 3500 };
  for (const action of PARTNER_ACTIONS) {
    for (const uid of ['r1', 'root', 'dA']) {
      const r = await w.call(uid, { orderId: 'o1', action, ...extra });
      assert.deepEqual([r.success, r.code], [false, 'MANAGEMENT_FROZEN'], `${action}/${uid}`);
    }
  }
  assert.equal(w.snapshot(), before, 'aucune écriture, aucun solde modifié');
  assert.equal(w.dispatches.length, 0);
  // Dégel : opération de configuration exemptée du gel, puis la gestion reprend.
  assert.equal((await w.set('root', { managementFrozen: false }, 2)).success, true);
  assert.equal((await w.call('r1', { orderId: 'o1', action: 'acceptPartnerOrder' })).success, true);
});

test('politique du gel : chemins financiers indépendants documentés et toujours possibles (annulation client, expiration)', async () => {
  const { buildCancelOrder } = require('../orderActions');
  const { expireOrderTx } = require('../orderRefunds');
  const w = world({ 'config/partnerOrdersV2': { pilotPartnerIds: ['r1'], creationOpen: true, managementFrozen: true, version: 3 } });
  assert.equal(cfg.MANAGEMENT_FREEZE_POLICY, 'all_partner_order_actions_except_config');
  const cancel = buildCancelOrder({ db: w.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, onCall: oc }).run;
  const r = await cancel({ auth: authOf('c1'), data: { orderId: 'o1' } });
  assert.equal(r.success, true, 'le client peut toujours annuler et être remboursé pendant un gel');
  assert.equal(w.order().status, 'cancelled');
  // Expiration d’une commande acceptée il y a plus de 10 min : indépendante du gel.
  const w2 = world({ 'orders/o1': pendingV2({ partnerAcceptedAtMs: 1 }), 'config/partnerOrdersV2': { managementFrozen: true } });
  const orderRef = w2.db.collection('orders').doc('o1');
  const e = await w2.db.runTransaction((tx) => expireOrderTx(tx, { db: w2.db, admin, orderRef, orderId: 'o1' }));
  assert.equal(e.expired, true);
});

test('variable d’environnement PARTNER_ORDERS_V2_MANAGE=off : gestion gelée, configuration toujours modifiable', async () => {
  const prev = process.env.PARTNER_ORDERS_V2_MANAGE;
  try {
    process.env.PARTNER_ORDERS_V2_MANAGE = 'off';
    const db = fakeDb({ 'orders/o1': pendingV2(), 'admins/root': { role: 'super', isActive: true } });
    const fn = buildPartnerOrderAction({
      db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, requireSuperAdmin,
    }).run;
    const r = await fn({ auth: authOf('r1'), data: { orderId: 'o1', action: 'acceptPartnerOrder' } });
    assert.equal(r.code, 'FEATURE_DISABLED');
    const c = await fn({ auth: authOf('root'), data: { action: 'setPartnerOrdersConfig', patch: { creationOpen: true }, expectedVersion: 0, reason: 'Réouverture progressive du pilote' } });
    assert.equal(c.success, true);
  } finally {
    if (prev === undefined) delete process.env.PARTNER_ORDERS_V2_MANAGE; else process.env.PARTNER_ORDERS_V2_MANAGE = prev;
  }
});

test('commandes historiques et soldes : la configuration ne touche aucune commande ni aucun wallet', async () => {
  const w = world({ 'orders/legacy': { clientId: 'c1', status: 'pending', sellerType: 'restaurant', sellerId: 'r1', budget: 1500 } });
  const before = JSON.stringify([w.store.get('orders/legacy'), w.store.get('clients/c1'), w.store.get('restaurants/r1'), w.order()]);
  assert.equal((await w.set('root', { pilotPartnerIds: ['r1'], creationOpen: true, managementFrozen: true }, 0)).success, true);
  assert.equal(JSON.stringify([w.store.get('orders/legacy'), w.store.get('clients/c1'), w.store.get('restaurants/r1'), w.order()]), before);
});
