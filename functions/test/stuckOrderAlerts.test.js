'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { scanStuckOrders, THRESHOLDS_MS } = require('../stuckOrderAlerts');

const T0 = 1_800_000_000_000;
const ts = (ms) => ({ toMillis: () => ms });
const silent = { log() {}, error() {} };
const MIN = 60_000;

function setup(orders) {
  const seed = {
    'admins/root': { role: 'super', isActive: true, fcmToken: 'token-root-0000000' },
    'admins/subCmd': { role: 'sub', isActive: true, permissions: ['commandes'], fcmToken: 'token-sub-cmd-00000' },
    'admins/subOther': { role: 'sub', isActive: true, permissions: ['restaurants'], fcmToken: 'token-sub-other-000' },
    'admins/off': { role: 'super', isActive: false, fcmToken: 'token-off-0000000' },
  };
  for (const [id, o] of Object.entries(orders)) seed[`orders/${id}`] = o;
  const db = fakeDb(seed);
  // Le faux Firestore ne gère pas les comparaisons : requêtes simulées.
  const base = db.collection;
  db.collection = (name) => {
    const c = base(name);
    if (!['orders', 'admins'].includes(name)) return c;
    const query = (filters) => {
      const get = async () => {
        const docs = [...db.store.entries()]
          .filter(([k, v]) => k.startsWith(`${name}/`) && !k.slice(name.length + 1).includes('/') && filters.every(([f, op, val]) => {
            const x = f === 'createdAt' ? v.createdAt?.toMillis() : v[f];
            const y = f === 'createdAt' ? val.toMillis() : val;
            return op === '==' ? x === y : op === 'in' ? y.includes(x) : op === '<=' ? x <= y : false;
          }))
          .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v }));
        return { docs, empty: !docs.length };
      };
      return { where: (f, op, v) => query([...filters, [f, op, v]]), limit: () => ({ get }), get };
    };
    return { ...c, where: (f, op, v) => query([[f, op, v]]) };
  };
  const sent = []; const audits = [];
  const run = (nowMs) => scanStuckOrders({
    db, admin, nowMs, logger: silent,
    sendToToken: async (token, title, body, data) => { sent.push({ token, title, body, data }); },
    logAudit: async (d) => { audits.push(d); },
  });
  return { db, run, sent, audits };
}

const accepted = (ageMin, extra = {}) => ({
  status: 'accepted', driverId: 'dA', createdAt: ts(T0 - 200 * MIN), acceptedAt: ts(T0 - ageMin * MIN), ...extra,
});
const pickedUp = (ageMin, extra = {}) => ({
  status: 'picked_up', driverId: 'dA', createdAt: ts(T0 - 400 * MIN), acceptedAt: ts(T0 - 300 * MIN), pickedUpAt: ts(T0 - ageMin * MIN), ...extra,
});

test('seuils : accepted ≥ 30 min, picked_up ≥ 90 min ; en dessous, aucune alerte', async () => {
  const t = setup({ a1: accepted(29), a2: accepted(31), p1: pickedUp(89), p2: pickedUp(91) });
  const s = await t.run(T0);
  assert.equal(s.alerted, 2);
  assert.deepEqual([...new Set(t.sent.map((x) => x.data.orderId))].sort(), ['a2', 'p2']);
  assert.equal(THRESHOLDS_MS.accepted, 30 * MIN);
  assert.equal(THRESHOLDS_MS.picked_up, 90 * MIN);
});

test('destinataires : super-admin et sous-admin « commandes » seulement (ni autre sous-admin, ni compte désactivé)', async () => {
  const t = setup({ a2: accepted(40) });
  await t.run(T0);
  assert.deepEqual(t.sent.map((x) => x.token).sort(), ['token-root-0000000', 'token-sub-cmd-00000']);
});

test('aucune répétition : 20 passes successives → une seule alerte par commande', async () => {
  const t = setup({ a2: accepted(40), p2: pickedUp(120) });
  for (let i = 0; i < 20; i += 1) await t.run(T0 + i * 5 * MIN);
  assert.equal(t.audits.length, 2);
  assert.equal(t.sent.length, 4); // 2 commandes × 2 destinataires, une seule fois
});

test('nouvel épisode (ré-acceptation par un autre livreur) → nouvelle alerte', async () => {
  const t = setup({ a2: accepted(40) });
  await t.run(T0);
  t.db.store.set('orders/a2', accepted(35, { driverId: 'dB', acceptedAt: ts(T0 + 100 * MIN - 35 * MIN) }));
  await t.run(T0 + 100 * MIN);
  assert.equal(t.audits.length, 2);
});

test('lecture seule : aucune commande modifiée (picked_up jamais annulée, réattribuée ni remboursée), aucun wallet touché', async () => {
  const t = setup({ a2: accepted(40), p2: pickedUp(500) });
  t.db.store.set('clients/c1', { wallet: 100 }); t.db.store.set('livreurs/dA', { wallet: 100 });
  const before = JSON.stringify([...t.db.store.entries()].filter(([k]) => !k.startsWith('stuck_order_alerts/')));
  await t.run(T0);
  const after = JSON.stringify([...t.db.store.entries()].filter(([k]) => !k.startsWith('stuck_order_alerts/')));
  assert.equal(after, before);
});

test('autres statuts ignorés ; échec d’envoi ou de lecture : la passe ne lève pas', async () => {
  const t = setup({ x1: { status: 'pending', createdAt: ts(T0 - 500 * MIN) }, x2: { status: 'delivered', createdAt: ts(T0 - 500 * MIN) }, x3: { status: 'cancelled', createdAt: ts(T0 - 500 * MIN) } });
  assert.equal((await t.run(T0)).alerted, 0);
  const bad = { collection: () => { throw new Error('indisponible'); } };
  const s = await scanStuckOrders({ db: bad, admin, nowMs: T0, logger: silent, sendToToken: async () => {}, logAudit: async () => {} });
  assert.equal(s.errors, 2);
});

test('branchement : passe toutes les 5 min, après l’expiration et la reprise, sans pouvoir les bloquer', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(src, /Math\.floor\(Date\.now\(\) \/ 60000\) % 5 === 0\) \{\s*await scanStuckOrders\(/);
  assert.match(src, /scanStuckOrders\(\{ db, admin, sendToToken, logAudit \}\)\s*\.catch\(/);
});
