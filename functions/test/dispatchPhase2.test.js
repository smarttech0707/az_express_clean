'use strict';

// Mission 7C-2 — reprise BORNÉE du dispatch des commandes Restaurant/Boulangerie v2 préparées ou prêtes (phase 2), livreur
// assigné sans réponse, alerte d'épuisement. `dispatchOrder` est simulé (sa garde « encore pending / diffusée » est couverte par
// dispatch.test.js). Faux Firestore sérialisé : modélise la garantie transactionnelle, ce n'est pas un test sur émulateur
// (voir dispatchRetry.emulator.test.js pour la concurrence réelle).

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { withSelfie } = require('./selfieHelper');
const { DispatchError, calculateCommission } = require('../dispatch');
const { buildAcceptOrder } = require('../driverAcceptance');
const {
  retryPendingDispatch, reserveAttempt, GIVE_UP_AGE_MS, PHASE2_MAX_ATTEMPTS, PHASE2_GAP_MS, PARTNER_WINDOW_MS, MAX_LIFETIME_ATTEMPTS,
} = require('../dispatchRetry');
const { requeueUnansweredAssignment, ASSIGNMENT_TIMEOUT_MS } = require('../assignedTimeout');
const { alertDispatchExhausted, scanPartnerOrderWaits, COLLECTION: ALERTS } = require('../stuckOrderAlerts');

const T0 = 1_800_000_000_000;
const MIN = 60_000;
const ts = (ms) => ({ toMillis: () => ms });
const silent = { log() {}, error() {}, warn() {} };

function makeDb(seed) {
  const db = fakeDb(seed);
  const run = db.runTransaction;
  let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  db.rangeQueryFails = false;
  const base = db.collection;
  db.collection = (name) => {
    const c = base(name);
    if (name !== 'orders') return c;
    const query = (filters, desc = false) => {
      const get = async () => {
        if (db.rangeQueryFails && filters.some(([f, op]) => f === 'partnerAcceptedAtMs' && op === '>=')) {
          throw new Error('9 FAILED_PRECONDITION: The query requires an index');
        }
        const docs = [...db.store.entries()]
          .filter(([k, v]) => k.startsWith('orders/') && !k.slice(7).includes('/') && filters.every(([f, op, val]) => {
            const x = f === 'createdAt' ? v.createdAt.toMillis() : v[f];
            const y = f === 'createdAt' ? val.toMillis() : val;
            return op === '==' ? x === y : op === 'in' ? y.includes(x) : op === '<=' ? x <= y : op === '>=' ? x !== undefined && x >= y : false;
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

// Commande v2 préparée en file : créée à T0, acceptée par le partenaire à T0 + 20 s, préparation commencée.
const prepared = (extra = {}) => ({
  clientId: 'c1', status: 'pending', createdAt: ts(T0), partnerAcceptedAtMs: T0 + 20_000, sellerStatus: 'preparing',
  amountsVersion: 2, sellerId: 'r1', sellerType: 'restaurant', latitude: 6.73, longitude: -3.49, budget: 500,
  pickupCityId: 'abengourou', cityResolutionStatus: 'resolved', paymentMethod: 'wallet', isPaid: true, ...extra,
});

function setup(orders, extraSeed = {}) {
  const seed = { 'clients/c1': { wallet: 5000 }, 'livreurs/dA': { wallet: 900 }, 'admins/root': { role: 'super', isActive: true, fcmToken: 'token-root-0000000' }, ...extraSeed };
  for (const [id, o] of Object.entries(orders)) seed[`orders/${id}`] = o;
  const db = makeDb(seed);
  const calls = []; const exhausted = []; const pushes = []; const audits = [];
  const dispatchOrder = async (_d, _a, args) => { calls.push({ ...args, at: db.now }); return { dispatched: false, mode: 'none' }; };
  const onExhausted = async (id, o, reason) => {
    exhausted.push([id, reason]);
    await alertDispatchExhausted({ db, sendToToken: async (...a) => { pushes.push(a); }, logAudit: async (a) => { audits.push(a); }, orderId: id, order: o, reason, nowMs: db.now });
  };
  const run = (nowMs) => { db.now = nowMs; return retryPendingDispatch({ db, admin, dispatchOrder, DispatchError, onExhausted, nowMs, logger: silent }); };
  return { db, calls, exhausted, pushes, audits, run, lease: (id) => db.store.get(`order_dispatch_retries/${id}`), order: (id) => db.store.get(`orders/${id}`) };
}

// Simule le scheduler : une passe par minute.
async function everyMinute(t, fromMs, toMs) {
  for (let now = fromMs; now <= toMs; now += MIN) await t.run(now);
}

// ── Phase 2 : plafonds, espacement, fenêtre ──────────────────────────────────────────────────────────

test('phase 2 (commande pending préparée) : échelle initiale puis au plus 8 essais espacés de 3 min, rayon max, jamais après 45 min', async () => {
  const t = setup({ o1: prepared() });
  await everyMinute(t, T0 + 30_000, T0 + 60 * MIN);
  const afterLadder = t.calls.filter((c) => c.at - (T0 + 20_000) > GIVE_UP_AGE_MS);
  assert.ok(t.calls.length - afterLadder.length <= 5, 'échelle initiale : au plus 5 essais');
  assert.equal(afterLadder.length, PHASE2_MAX_ATTEMPTS, 'phase 2 : exactement le maximum, pas un de plus');
  assert.ok(afterLadder.every((c) => c.radiusKm === 30), 'toujours au rayon maximal');
  for (let i = 1; i < afterLadder.length; i++) assert.ok(afterLadder[i].at - afterLadder[i - 1].at >= PHASE2_GAP_MS, 'espacement minimal de 3 min');
  assert.ok(t.calls.every((c) => c.at - T0 <= PARTNER_WINDOW_MS), 'aucun essai après la fenêtre absolue');
  assert.ok(t.lease('o1').lifetimeAttempts <= MAX_LIFETIME_ATTEMPTS);
  assert.equal(t.lease('o1').phase2Attempts, PHASE2_MAX_ATTEMPTS);
  // Aucune annulation ni remboursement automatique, aucun wallet touché.
  assert.equal(t.order('o1').status, 'pending');
  assert.equal(t.db.store.get('clients/c1').wallet, 5000);
});

test('phase 2 (commande diffusée) : élargissement uniquement (expandBroadcast), jamais un nouveau broadcast ni un rappel', async () => {
  const t = setup({ o1: prepared({ status: 'broadcast', notifiedDriverIds: ['dA', 'dB'], lastDispatchAtMs: T0 }) });
  await everyMinute(t, T0 + 30_000, T0 + 50 * MIN);
  assert.ok(t.calls.length > 0);
  assert.ok(t.calls.every((c) => c.expandBroadcast === true), 'chaque essai est un élargissement : seuls de nouveaux livreurs sont ajoutés');
  assert.ok(t.calls.length <= 4 + PHASE2_MAX_ATTEMPTS);
});

test('fenêtre absolue : acceptation il y a plus de 45 min → aucun essai, alerte d’épuisement unique, aucune annulation', async () => {
  const t = setup({ o1: prepared({ createdAt: ts(T0 - 50 * MIN), partnerAcceptedAtMs: T0 - 46 * MIN }) });
  for (let i = 0; i < 4; i++) await t.run(T0 + i * MIN);
  assert.equal(t.calls.length, 0);
  assert.ok(t.exhausted.length >= 1 && t.exhausted.every(([, reason]) => reason === 'window_closed'));
  const alerts = [...t.db.store.keys()].filter((k) => k.startsWith(`${ALERTS}/`));
  assert.equal(alerts.length, 1, 'une seule alerte malgré plusieurs passes');
  assert.equal(t.pushes.length, 1);
  assert.equal(t.audits.filter((a) => a.action === 'dispatch_exhausted_alert').length, 1);
  assert.equal(t.order('o1').status, 'pending');
  assert.equal(t.db.store.get('clients/c1').wallet, 5000);
});

test('plafond cumulé : 20 essais maximum par commande, y compris après remises en file', async () => {
  const t = setup({ o1: prepared() });
  let attempts = 0;
  for (let round = 0; round < 12 && attempts < 40; round++) {
    // Nouvelle mise en file toutes les 10 minutes (refus / libération simulés) : l'échelle repart, pas les compteurs.
    const start = T0 + 30_000 + round * 10 * MIN;
    t.db.store.set('orders/o1', { ...t.order('o1'), requeuedAt: ts(start - 30_000), partnerAcceptedAtMs: T0 + 20_000 });
    await everyMinute(t, start, start + 9 * MIN);
    attempts = t.calls.length;
  }
  assert.ok(t.calls.length <= MAX_LIFETIME_ATTEMPTS, `essais cumulés : ${t.calls.length}`);
  assert.ok(t.lease('o1').lifetimeAttempts <= MAX_LIFETIME_ATTEMPTS);
  assert.ok(t.calls.every((c) => c.at - T0 <= PARTNER_WINDOW_MS + MIN));
});

test('compatibilité : commande v2 non préparée, v2 non acceptée et commande historique gardent leur comportement (abandon à 9 min)', async () => {
  const t = setup({
    notPrepared: prepared({ sellerStatus: undefined }),
    unaccepted: prepared({ partnerAcceptedAtMs: undefined, sellerStatus: undefined }),
    legacy: { clientId: 'c1', status: 'pending', createdAt: ts(T0), latitude: 6.7, longitude: -3.4, budget: 1000, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved' },
  });
  await everyMinute(t, T0 + 30_000, T0 + 30 * MIN);
  const by = (id) => t.calls.filter((c) => c.orderId === id);
  assert.ok(by('unaccepted').length === 0);
  assert.ok(by('notPrepared').length <= 5 && by('notPrepared').every((c) => c.at - (T0 + 20_000) <= GIVE_UP_AGE_MS));
  assert.ok(by('legacy').length <= 5 && by('legacy').every((c) => c.at - T0 <= GIVE_UP_AGE_MS));
  assert.deepEqual(t.exhausted, [], 'aucune alerte d’épuisement pour ces commandes');
});

test('deux schedulers simultanés en phase 2 : un seul essai', async () => {
  const t = setup({ o1: prepared() });
  await everyMinute(t, T0 + 30_000, T0 + 9 * MIN + 30_000); // échelle terminée
  const before = t.calls.length;
  const at = T0 + 12 * MIN + 30_000;
  t.db.now = at;
  const results = await Promise.all([t.run(at), t.run(at), t.run(at)]);
  assert.equal(t.calls.length - before, 1);
  assert.equal(results.reduce((n, r) => n + r.attempted, 0), 1);
  assert.equal(t.lease('o1').phase2Attempts, 1);
});

test('annulation ou acceptation livreur pendant la reprise : aucune relance', async () => {
  for (const patch of [{ status: 'cancelled' }, { status: 'accepted', driverId: 'dA' }, { status: 'assigned', driverId: 'dA' }]) {
    const t = setup({ o1: prepared(patch) });
    await everyMinute(t, T0 + 10 * MIN, T0 + 20 * MIN);
    assert.equal(t.calls.length, 0, JSON.stringify(patch));
  }
});

test('sélection : 50 anciennes commandes bloquées ne cachent pas une commande préparée plus récente', async () => {
  const orders = {};
  for (let i = 0; i < 60; i++) {
    orders[`old${i}`] = prepared({ createdAt: ts(T0 - 120 * MIN + i), partnerAcceptedAtMs: T0 - 100 * MIN, sellerStatus: 'preparing' });
  }
  orders.fresh = prepared({ createdAt: ts(T0 - 5 * MIN), partnerAcceptedAtMs: T0 - 4 * MIN });
  const t = setup(orders);
  await t.run(T0);
  assert.ok(t.calls.some((c) => c.orderId === 'fresh'), 'la commande récente est traitée');
  assert.ok(t.calls.every((c) => !c.orderId.startsWith('old')), 'aucun essai sur les commandes dont la fenêtre est close');
});

test('requête v2 bornée indisponible (index non déployé) : repli sans intervalle, les commandes préparées sont encore traitées', async () => {
  const t = setup({ o1: prepared({ createdAt: ts(T0 - 20 * MIN), partnerAcceptedAtMs: T0 - 12 * MIN }) });
  t.db.rangeQueryFails = true;
  const errors = [];
  t.db.now = T0;
  const r = await retryPendingDispatch({
    db: t.db, admin, dispatchOrder: async (_d, _a, args) => { t.calls.push(args); return { dispatched: false }; }, DispatchError, nowMs: T0,
    logger: { log() {}, warn() {}, error: (m) => errors.push(m) },
  });
  assert.ok(errors.some((m) => /repli/.test(m)));
  assert.ok(r.scanned >= 1);
});

// ── Alerte d’épuisement (balayage) ───────────────────────────────────────────────────────────────────

test('balayage d’alertes : fenêtre de 45 min close → alerte d’épuisement unique, partagée avec la reprise', async () => {
  const t = setup({ o1: prepared({ createdAt: ts(T0 - 60 * MIN), partnerAcceptedAtMs: T0 - 50 * MIN }) });
  const pushes = [];
  const scan = () => scanPartnerOrderWaits({ db: t.db, nowMs: T0, logger: silent, sendToToken: async (...a) => { pushes.push(a); }, logAudit: async () => {} });
  await scan();
  await scan();
  await t.run(T0); // la reprise observe aussi l’épuisement : même document d’alerte
  const exhaustedAlerts = [...t.db.store.keys()].filter((k) => k.includes('_dispatch_exhausted_'));
  assert.equal(exhaustedAlerts.length, 1);
});

// ── Livreur assigné sans réponse ─────────────────────────────────────────────────────────────────────

const assigned = (extra = {}) => prepared({ status: 'assigned', driverId: 'dA', assignedAtMs: T0 - 4 * MIN, ...extra });
const requeue = (t, nowMs = T0, extra = {}) => requeueUnansweredAssignment({
  db: t.db, admin, orderId: 'o1', nowMs, windowMs: PARTNER_WINDOW_MS, maxLifetimeAttempts: MAX_LIFETIME_ATTEMPTS, retryCollection: 'order_dispatch_retries', ...extra,
});
const withDriver = { 'livreurs/dA': { wallet: 900, isOnline: true, isOnDelivery: false, pendingOrderId: 'o1' } };

test('assigné sans réponse après 3 min : remis en file, livreur retiré et exclu, aucun wallet ni transfert touché', async () => {
  const t = setup({ o1: assigned() }, withDriver);
  const before = JSON.stringify([t.db.store.get('livreurs/dA').wallet, t.db.store.get('clients/c1').wallet]);
  const r = await requeue(t);
  assert.deepEqual([r.requeued, r.driverId], [true, 'dA']);
  const o = t.order('o1');
  assert.equal(o.status, 'pending');
  assert.equal(o.driverId, undefined);
  assert.ok(o.excludedDriverIds.includes('dA'));
  assert.equal(o.transferCount, undefined);
  assert.equal(o.driverHistory[0].phase, 'assignment_timeout');
  assert.equal(t.db.store.get('livreurs/dA').pendingOrderId, undefined, 'marqueur de proposition retiré');
  assert.equal(JSON.stringify([t.db.store.get('livreurs/dA').wallet, t.db.store.get('clients/c1').wallet]), before);
  // Rejeu : plus assigné, rien ne se passe.
  assert.equal((await requeue(t)).requeued, false);
  assert.equal(t.order('o1').excludedDriverIds.length, 1);
});

test('assigné : pas avant 3 min, pas si non préparée, pas historique, pas si déjà acceptée', async () => {
  const cases = [
    [assigned({ assignedAtMs: T0 - 2 * MIN }), 'too_early'],
    [assigned({ sellerStatus: undefined }), 'not_prepared'],
    [assigned({ amountsVersion: undefined }), 'not_assigned'],
    [assigned({ status: 'accepted', commissionStatus: 'charged' }), 'not_assigned'],
    [assigned({ commissionStatus: 'charged' }), 'already_charged'],
    [assigned({ assignedAtMs: undefined }), 'no_timestamp'],
  ];
  for (const [order, reason] of cases) {
    const t = setup({ o1: order }, withDriver);
    const r = await requeue(t);
    assert.deepEqual([r.requeued, r.reason], [false, reason]);
    assert.equal(t.order('o1').driverId, order.driverId);
  }
  assert.ok(ASSIGNMENT_TIMEOUT_MS === 3 * MIN);
});

test('assigné : fenêtre de 45 min close ou plafond cumulé atteint → attribution conservée, épuisement signalé', async () => {
  const closed = setup({ o1: assigned({ partnerAcceptedAtMs: T0 - 46 * MIN }) }, withDriver);
  assert.deepEqual([(await requeue(closed)).requeued, (await requeue(closed)).reason], [false, 'window_closed']);
  assert.equal(closed.order('o1').status, 'assigned');
  const capped = setup({ o1: assigned() }, { ...withDriver, 'order_dispatch_retries/o1': { lifetimeAttempts: MAX_LIFETIME_ATTEMPTS } });
  const r = await requeue(capped);
  assert.deepEqual([r.requeued, r.reason, r.exhausted], [false, 'attempts_exhausted', true]);
  // Via la passe du scheduler : alerte d’épuisement émise.
  await closed.run(T0);
  assert.ok(closed.exhausted.some(([, reason]) => reason === 'window_closed'));
});

test('assigné silencieux via la passe du scheduler : remis en file puis relancé en excluant le livreur', async () => {
  const t = setup({ o1: assigned() }, withDriver);
  const r1 = await t.run(T0);
  assert.equal(r1.requeued, 1);
  // La production pose requeuedAt (horodatage serveur) ; le faux Firestore en fait une chaîne : on simule la valeur.
  t.db.store.set('orders/o1', { ...t.order('o1'), requeuedAt: ts(T0) });
  await everyMinute(t, T0 + MIN, T0 + 3 * MIN);
  assert.ok(t.calls.length >= 1);
  assert.ok(t.calls.every((c) => c.excludedDriverIds.includes('dA')), 'le livreur silencieux n’est jamais re-proposé');
});

test('concurrence acceptation livreur / remise en file (10 tours) : un seul gagnant, commission prélevée au plus une fois', async () => {
  for (let i = 0; i < 10; i++) {
    const t = setup({ o1: assigned() }, { 'livreurs/dA': { wallet: 900, isOnline: true, isAvailable: true, isOnDelivery: false, pendingOrderId: 'o1' } });
    const common = { db: t.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, onCall: (...a) => ({ run: a[a.length - 1] }) };
    const accept = withSelfie(buildAcceptOrder(common).run);
    const jobs = [
      accept({ auth: { uid: 'dA', token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: 'o1' } }),
      requeue(t),
      requeue(t),
    ];
    await Promise.allSettled(i % 2 ? jobs.reverse() : jobs);
    const o = t.order('o1');
    const wallet = t.db.store.get('livreurs/dA').wallet;
    if (o.status === 'accepted') {
      assert.equal(o.driverId, 'dA', `tour ${i}`);
      assert.equal(o.excludedDriverIds, undefined, `tour ${i} : jamais exclu après acceptation`);
      assert.equal(wallet, 900 - 100, `tour ${i} : commission prélevée une fois`);
    } else {
      assert.equal(o.status, 'pending', `tour ${i}`);
      assert.equal(o.driverId, undefined);
      assert.ok(o.excludedDriverIds.includes('dA'));
      assert.equal(wallet, 900, `tour ${i} : aucune commission si remise en file`);
    }
  }
});

test('réservation : compteurs cumulés conservés quand la file est renouvelée, bail en erreur de données non relancé', async () => {
  const t = setup({ o1: prepared({ requeuedAt: ts(T0 + 5 * MIN) }) }, { 'order_dispatch_retries/o1': { queuedAtMs: T0, attempts: 3, lifetimeAttempts: 7, phase2Attempts: 2, lastAttemptAtMs: T0 } });
  const slot = await reserveAttempt(t.db, { orderRef: t.db.collection('orders').doc('o1'), retryRef: t.db.collection('order_dispatch_retries').doc('o1'), nowMs: T0 + 6 * MIN });
  assert.equal(slot.reserved, true);
  const lease = t.lease('o1');
  assert.deepEqual([lease.attempts, lease.lifetimeAttempts, lease.phase2Attempts], [1, 8, 2]);
});

// ── Correctif 7C-2 : assigné sans réponse en fin de fenêtre, plafonds cumulés, relances du client ─────

test('assigné sans réponse à la fin de la fenêtre : alerte explicite « assignation ≠ acceptation », unique, rien n’est accepté ni prélevé', async () => {
  const t = setup({ o1: assigned({ partnerAcceptedAtMs: T0 - 46 * MIN }) }, withDriver);
  for (let i = 0; i < 3; i++) await t.run(T0 + i * MIN);
  const alerts = [...t.db.store.entries()].filter(([k]) => k.startsWith(`${ALERTS}/`));
  assert.equal(alerts.length, 1, 'une seule alerte malgré plusieurs passes');
  const [key, doc] = alerts[0];
  assert.match(key, /_assignment_unanswered_/);
  assert.deepEqual([doc.type, doc.orderStatus, doc.driverAccepted, doc.commissionCharged, doc.driverId], ['assignment_unanswered', 'assigned', false, false, 'dA']);
  assert.equal(t.pushes.length, 1);
  assert.match(t.pushes[0][2], /n’est pas une acceptation/);
  assert.equal(t.pushes[0][3].type, 'assignment_unanswered');
  assert.equal(t.audits.filter((a) => a.action === 'assignment_unanswered_alert').length, 1);
  // L’état reste « assigned » : jamais « accepted », aucun acceptedAt, aucune commission, wallet du livreur intact.
  const o = t.order('o1');
  assert.deepEqual([o.status, o.driverId, o.acceptedAt, o.commissionStatus], ['assigned', 'dA', undefined, undefined]);
  assert.equal(t.db.store.get('livreurs/dA').wallet, 900);
  assert.equal(t.calls.length, 0, 'aucune nouvelle proposition');
});

test('plafond cumulé atteint avec un livreur assigné silencieux : même alerte explicite, attribution conservée', async () => {
  const t = setup({ o1: assigned() }, { ...withDriver, 'order_dispatch_retries/o1': { queuedAtMs: T0 - 10 * MIN, lifetimeAttempts: MAX_LIFETIME_ATTEMPTS } });
  await t.run(T0);
  const alert = [...t.db.store.entries()].find(([k]) => k.includes('_assignment_unanswered_'));
  assert.ok(alert);
  assert.equal(alert[1].reason, 'attempts_exhausted');
  assert.equal(t.order('o1').status, 'assigned');
});

test('cycles assigné → silencieux → remis en file : jamais plus de 20 essais cumulés ni de remise en file au-delà du plafond', async () => {
  const t = setup({ o1: prepared() }, { 'order_dispatch_retries/o1': { queuedAtMs: 0, lifetimeAttempts: 0 } });
  let requeues = 0;
  let now = T0 + 30_000;
  for (let round = 0; round < 40; round++) {
    // Chaque tour : la commande est proposée à un nouveau livreur muet, la passe le retire, la reprise relance (nouveaux essais).
    const driverId = `silent${round}`;
    t.db.store.set(`livreurs/${driverId}`, { wallet: 900, isOnline: true, pendingOrderId: 'o1' });
    t.db.store.set('orders/o1', { ...t.order('o1'), status: 'assigned', driverId, assignedAtMs: now - 4 * MIN });
    const before = t.order('o1').excludedDriverIds?.length || 0;
    const r = await t.run(now);
    if (r.requeued) {
      requeues += 1;
      t.db.store.set('orders/o1', { ...t.order('o1'), requeuedAt: ts(now) });
    } else {
      t.db.store.set('orders/o1', { ...t.order('o1'), status: 'pending', driverId: undefined });
    }
    for (let i = 1; i <= 12; i++) await t.run(now + i * MIN);
    now += 13 * MIN;
    assert.ok((t.lease('o1')?.lifetimeAttempts || 0) <= MAX_LIFETIME_ATTEMPTS, `tour ${round}`);
    assert.ok(t.calls.length <= MAX_LIFETIME_ATTEMPTS, `tour ${round} : essais ${t.calls.length}`);
    void before;
  }
  assert.ok(t.calls.length > 5 && t.calls.length <= MAX_LIFETIME_ATTEMPTS, 'des essais ont bien eu lieu, plafonnés : ' + t.calls.length);
  assert.ok(requeues < 40, 'les remises en file s’arrêtent avec la fenêtre / le plafond');
  assert.ok(t.calls.every((c) => c.at - (T0 + 20_000) <= PARTNER_WINDOW_MS + MIN));
});

test('relances du client : une commande v2 ne peut pas contourner les plafonds par dispatchOrderToDriver (administrateur seulement)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'index.js'), 'utf8');
  const at = src.indexOf("order.amountsVersion === 2 && !isCallerAdmin) return { dispatched: false, mode: 'server_managed' }");
  const track = src.indexOf('await observeOrderTariff(db, String(orderId), order);');
  const auth = src.indexOf("await requireAdminPermission({ request, db, permission: 'commandes' });");
  assert.ok(at > auth && at < track, 'garde placée après l’autorisation et avant tout dispatch');
});
