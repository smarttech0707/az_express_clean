'use strict';

// Reprise serveur du dispatch (I2). `dispatchOrder` est simulé : sa propre
// garde « commande encore pending » est couverte par les tests de dispatch.
// Le faux Firestore est sérialisé pour modéliser la garantie transactionnelle
// de Firestore ; ce n'est pas un test sur émulateur.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { DispatchError } = require('../dispatch');
const {
  retryPendingDispatch, reserveAttempt, STAGES, MIN_GAP_MS, GIVE_UP_AGE_MS,
} = require('../dispatchRetry');

const T0 = 1_800_000_000_000;
const ts = (ms) => ({ toMillis: () => ms });
const silent = { log() {}, error() {}, warn() {} };

function makeDb(seed) {
  const db = fakeDb(seed);
  const run = db.runTransaction;
  let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const base = db.collection;
  db.failReads = false;
  db.collection = (name) => {
    const c = base(name);
    if (name !== 'orders') return c;
    const query = (filters, desc = false) => {
      const get = async () => {
        if (db.failReads) throw new Error('réseau indisponible');
        const docs = [...db.store.entries()]
          .filter(([k, v]) => k.startsWith('orders/') && !k.slice(7).includes('/') && filters.every(([f, op, val]) => {
            const x = f === 'createdAt' ? v.createdAt.toMillis() : v[f];
            const y = f === 'createdAt' ? val.toMillis() : val;
            return op === '==' ? x === y : op === 'in' ? y.includes(x) : op === '<=' ? x <= y : op === '>=' ? x >= y : false;
          }))
          .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v }));
        if (desc) docs.sort((a, b) => (b.data().createdAt?.toMillis?.() || 0) - (a.data().createdAt?.toMillis?.() || 0));
        return { docs, empty: docs.length === 0 };
      };
      return { where: (f, op, v) => query([...filters, [f, op, v]], desc), orderBy: (_f, dir) => query(filters, dir === 'desc'), limit: () => ({ get }), get };
    };
    return { ...c, where: (f, op, v) => query([[f, op, v]]) };
  };
  return db;
}

const order = (ageMs, extra = {}) => ({
  clientId: 'c1', status: 'pending', createdAt: ts(T0 - ageMs), latitude: 6.73, longitude: -3.49,
  destLat: 6.74, destLng: -3.5, budget: 1000, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved',
  paymentMethod: 'wallet', isPaid: true, ...extra,
});

function setup(orders, { dispatch } = {}) {
  const seed = { 'clients/c1': { wallet: 5000 }, 'livreurs/dA': { wallet: 900 } };
  for (const [id, o] of Object.entries(orders)) seed[`orders/${id}`] = o;
  const db = makeDb(seed);
  const calls = [];
  const dispatchOrder = dispatch || (async (_db, _admin, args) => { calls.push(args); return { dispatched: false, mode: 'none' }; });
  const wrapped = async (d, a, args) => { if (dispatch) calls.push(args); return dispatchOrder(d, a, args); };
  const run = (nowMs = T0) => retryPendingDispatch({
    db, admin, dispatchOrder: wrapped, DispatchError, nowMs, logger: silent,
  });
  const lease = (id) => db.store.get(`order_dispatch_retries/${id}`);
  return { db, calls, run, lease };
}

test('commande pending depuis 40 s : un essai à 2 km, bail posé, aucun wallet touché', async () => {
  const t = setup({ o1: order(40_000) });
  const before = JSON.stringify([t.db.store.get('clients/c1'), t.db.store.get('livreurs/dA'), t.db.store.get('orders/o1')]);
  const s = await t.run();
  assert.equal(s.attempted, 1);
  assert.equal(t.calls.length, 1);
  assert.equal(t.calls[0].radiusKm, 2);
  assert.equal(t.calls[0].orderId, 'o1');
  assert.equal(t.calls[0].pickupCityId, 'abengourou');
  assert.equal(t.lease('o1').attempts, 1);
  assert.equal(JSON.stringify([t.db.store.get('clients/c1'), t.db.store.get('livreurs/dA'), t.db.store.get('orders/o1')]), before);
});

test('trop tôt (10 s) : le premier essai du client n’est pas doublé', async () => {
  const t = setup({ o1: order(10_000) });
  assert.equal((await t.run()).attempted, 0);
  assert.equal(t.calls.length, 0);
});

test('rayons successifs 2 → 5 → 30 km, jamais deux essais rapprochés', async () => {
  const t = setup({ o1: order(0) });
  const radii = [];
  for (let sec = 0; sec <= 540; sec += 15) {
    await t.run(T0 + sec * 1000);
    if (t.calls.length > radii.length) radii.push(t.calls[t.calls.length - 1].radiusKm);
  }
  assert.deepEqual(radii, STAGES.map((s) => s.radiusKm));
  assert.deepEqual(radii.slice(0, 3), [2, 5, 30]);
});

test('pas de boucle infinie : 120 passes consécutives → au plus 5 essais', async () => {
  const t = setup({ o1: order(0) });
  for (let i = 0; i < 120; i += 1) await t.run(T0 + 30_000 + i * 4_000);
  assert.ok(t.calls.length <= STAGES.length);
  assert.equal(t.lease('o1').attempts, t.calls.length);
});

test('même instant, deux passes : un seul essai (intervalle minimal)', async () => {
  const t = setup({ o1: order(100_000) });
  await t.run(T0);
  await t.run(T0 + 1000);
  assert.equal(t.calls.length, 1);
  assert.ok(MIN_GAP_MS >= 30_000);
});

test('concurrence : deux passes simultanées (deux instances) → un seul dispatch', async () => {
  const t = setup({ o1: order(40_000) });
  await Promise.all([t.run(), t.run(), t.run()]);
  assert.equal(t.calls.length, 1);
  assert.equal(t.lease('o1').attempts, 1);
});

test('commandes annulées, acceptées, assignées, récupérées, livrées : jamais relancées', async () => {
  const orders = {};
  for (const status of ['cancelled', 'accepted', 'assigned', 'picked_up', 'delivered']) {
    orders[status] = order(60_000, { status });
  }
  const t = setup(orders);
  assert.equal((await t.run()).attempted, 0);
  assert.equal(t.calls.length, 0);
});

test('acceptée entre la lecture et la réservation → aucun essai (statut relu dans la transaction)', async () => {
  const t = setup({ o1: order(60_000) });
  const orderRef = t.db.collection('orders').doc('o1');
  const retryRef = t.db.collection('order_dispatch_retries').doc('o1');
  t.db.store.set('orders/o1', { ...t.db.store.get('orders/o1'), status: 'accepted', driverId: 'dA' });
  const r = await reserveAttempt(t.db, { orderRef, retryRef, nowMs: T0 });
  assert.deepEqual([r.reserved, r.reason], [false, 'not_pending']);
  assert.equal(t.lease('o1'), undefined);
});

test('trop ancienne (≥ 9 min) : laissée à l’expiration automatique', async () => {
  const t = setup({ o1: order(GIVE_UP_AGE_MS + 5_000) });
  assert.equal((await t.run()).attempted, 0);
});

test('remise en file par un livreur : compteur d’essais remis à zéro, exclusions transmises', async () => {
  const t = setup({ o1: order(200_000) });
  await t.run(T0);
  assert.equal(t.lease('o1').attempts, 1);
  // Le livreur dA refuse : la commande repasse pending avec un nouveau requeuedAt.
  t.db.store.set('orders/o1', { ...t.db.store.get('orders/o1'), requeuedAt: ts(T0 + 10_000), excludedDriverIds: ['dA'] });
  await t.run(T0 + 50_000);
  assert.equal(t.calls.length, 2);
  assert.deepEqual(t.calls[1].excludedDriverIds, ['dA']);
  assert.equal(t.calls[1].radiusKm, 2);
  assert.equal(t.lease('o1').attempts, 1);
});

test('erreur de données (ville non résolue) : reprise arrêtée pour cette commande', async () => {
  const t = setup({ o1: order(60_000, { cityResolutionStatus: 'outside_service' }) }, {
    dispatch: async () => { throw new DispatchError('unresolved-city', 'refusé'); },
  });
  await t.run(T0);
  await t.run(T0 + 120_000);
  await t.run(T0 + 240_000);
  assert.equal(t.calls.length, 1);
  assert.equal(t.lease('o1').stopped, true);
});

test('échec réseau pendant le dispatch : la passe ne lève pas, l’essai est compté, la reprise suivante réessaie', async () => {
  let fail = true;
  const t = setup({ o1: order(60_000) }, {
    dispatch: async () => { if (fail) throw new Error('timeout'); return { dispatched: true, mode: 'assigned' }; },
  });
  const first = await t.run(T0);
  assert.equal(first.errors, 1);
  assert.equal(t.lease('o1').attempts, 1);
  fail = false;
  const second = await t.run(T0 + 60_000);
  assert.equal(second.dispatched, 1);
  assert.equal(t.calls.length, 2);
});

test('lecture de la file impossible : la passe ne lève pas', async () => {
  const t = setup({ o1: order(60_000) });
  t.db.failReads = true;
  const s = await t.run();
  assert.equal(s.errors, 1);
  assert.equal(t.calls.length, 0);
});

test('plusieurs commandes : traitées indépendamment, uniquement celles en retard', async () => {
  const t = setup({ a: order(60_000), b: order(5_000), c: order(60_000, { status: 'cancelled' }) });
  await t.run();
  assert.deepEqual(t.calls.map((c) => c.orderId), ['a']);
});

test('branchement : l’expiration passe avant la reprise et ne peut pas être bloquée par elle', () => {
  // Fins de ligne normalisées : sous Windows le dépôt est extrait en CRLF, le comportement vérifié reste le même.
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8').replace(/\r\n/g, '\n');
  const m = src.match(/exports\.autoExpireOrders = onSchedule\([\s\S]*?\n\}\);\n/);
  assert.ok(m, 'autoExpireOrders introuvable');
  assert.match(m[0], /try \{\s*await expireStaleOrders\(\);\s*\} finally \{\s*await retryPendingDispatch\(/);
  assert.doesNotMatch(src, /exports\.\w+ = onDocumentCreated\(\{ document: 'orders\/\{orderId\}'[^)]*dispatchOrder/);
});

// ───────────────────────────── cadence réelle du scheduler ─────────────────────────────
// Mesure en production (journaux autoExpireOrders, 2026-10-30, 40 min) : une exécution
// par minute, déclenchement à :00 s avec un retard occasionnel (≤ 17 s). Les âges
// 30/90/150/300/480 s sont des SEUILS MINIMAUX, jamais des instants garantis : un essai
// n'a lieu qu'à la première exécution qui suit le seuil.
function simulate({ phaseSec, jitterSec = () => 0, skip = () => false }) {
  const t = setup({ o1: order(0, { createdAt: ts(T0) }) });
  const attempts = [];
  return (async () => {
    for (let k = 0; k < 14; k += 1) {
      if (skip(k)) continue;
      const nowMs = T0 + (phaseSec + 60 * k + jitterSec(k)) * 1000;
      const before = t.calls.length;
      await t.run(nowMs);
      if (t.calls.length > before) {
        attempts.push({ ageSec: Math.round((nowMs - T0) / 1000), radiusKm: t.calls[t.calls.length - 1].radiusKm });
      }
    }
    return attempts;
  })();
}

test('cadence 1/min, phase quelconque : 1er essai entre 30 s et 90 s (jamais « à 30 s » garanti), ≤ 5 essais, rayon croissant, aucun après 9 min', async () => {
  for (let phase = 0; phase < 60; phase += 7) {
    const jit = (k) => (k * 5) % 18; // retards 0..17 s comme mesuré
    const a = await simulate({ phaseSec: phase, jitterSec: jit });
    assert.ok(a.length >= 4 && a.length <= STAGES.length, `phase ${phase}: ${JSON.stringify(a)}`);
    assert.ok(a[0].ageSec >= 30 && a[0].ageSec <= 90 + 17, `1er essai à ${a[0].ageSec}s (phase ${phase})`);
    assert.ok(a.every((x, i) => i === 0 || x.radiusKm >= a[i - 1].radiusKm), 'rayon non décroissant');
    assert.ok(a.every((x) => x.ageSec <= GIVE_UP_AGE_MS / 1000), 'aucun essai après 9 min');
    assert.equal(a[a.length - 1].radiusKm, 30);
  }
});

test('scheduler arrêté 5 min puis relancé : le premier essai part directement au rayon de son âge (30 km), pas à 2 km', async () => {
  const a = await simulate({ phaseSec: 0, skip: (k) => k < 5 });
  assert.equal(a[0].radiusKm, 30);
  assert.ok(a.length <= STAGES.length);
});

test('scheduler très en retard (> 9 min) : aucun essai tardif, l’expiration reprend', async () => {
  const a = await simulate({ phaseSec: 0, skip: (k) => k < 10 });
  assert.deepEqual(a, []);
});

test('expiration : la requête vise createdAt ≤ now − 600 s à chaque minute (expiration entre 10 et 11 min)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(src, /new admin\.firestore\.Timestamp\(now\.seconds - 600, now\.nanoseconds\)/);
  assert.match(src, /schedule:\s+'every 1 minutes'/);
});

// ───────────────────────────── élargissement des commandes déjà diffusées ─────────────────────────────
const broadcast = (ageMs, extra = {}) => order(ageMs, {
  status: 'broadcast', notifiedDriverIds: ['x1', 'x2'], lastDispatchAtMs: T0 - ageMs + 1000, ...extra,
});

test('broadcast : pas d’élargissement avant 60 s de diffusion ni avant le palier de 90 s', async () => {
  const t = setup({ a: broadcast(70_000, { lastDispatchAtMs: T0 - 20_000 }), b: broadcast(60_000) });
  assert.equal((await t.run()).attempted, 0);
});

test('broadcast sans réponse : élargi à 5 km (jamais au rayon initial de 2 km), avec expandBroadcast', async () => {
  const t = setup({ o1: broadcast(120_000, { lastDispatchAtMs: T0 - 100_000 }) });
  await t.run();
  assert.equal(t.calls.length, 1);
  assert.equal(t.calls[0].radiusKm, 5);
  assert.equal(t.calls[0].expandBroadcast, true);
});

test('broadcast : au plus 4 élargissements, rayon croissant, aucun après 9 min', async () => {
  const t = setup({ o1: broadcast(0, { createdAt: ts(T0), lastDispatchAtMs: T0 }) });
  const radii = [];
  for (let sec = 0; sec <= 560; sec += 15) {
    const before = t.calls.length;
    await t.run(T0 + sec * 1000);
    if (t.calls.length > before) radii.push(t.calls[t.calls.length - 1].radiusKm);
  }
  assert.ok(radii.length >= 3 && radii.length <= STAGES.length - 1, JSON.stringify(radii));
  assert.deepEqual([...radii].sort((a, b) => a - b), radii);
  assert.equal(radii[0], 5);
});

test('broadcast avec livreur, acceptée, ou assignée : jamais élargie', async () => {
  const t = setup({
    a: broadcast(200_000, { driverId: 'dA', lastDispatchAtMs: T0 - 150_000 }),
    b: order(200_000, { status: 'assigned', driverId: 'dA' }),
    c: order(200_000, { status: 'accepted', driverId: 'dA' }),
  });
  assert.equal((await t.run()).attempted, 0);
});

test('notification : transition vers broadcast = tous ; élargissement = seulement les nouveaux livreurs', () => {
  const { newlyNotifiedDriverIds } = require('../dispatchRetry');
  assert.deepEqual(newlyNotifiedDriverIds({ status: 'pending' }, { status: 'broadcast', notifiedDriverIds: ['a', 'b'] }), ['a', 'b']);
  assert.deepEqual(newlyNotifiedDriverIds({ status: 'broadcast', notifiedDriverIds: ['a', 'b'] }, { status: 'broadcast', notifiedDriverIds: ['a', 'b', 'c'] }), ['c']);
  assert.deepEqual(newlyNotifiedDriverIds({ status: 'broadcast', notifiedDriverIds: ['a'] }, { status: 'broadcast', notifiedDriverIds: ['a'], excludedDriverIds: ['a'] }), []);
  assert.deepEqual(newlyNotifiedDriverIds({ status: 'broadcast', notifiedDriverIds: ['a'] }, { status: 'accepted' }), []);
});
