'use strict';

// Mission 7C-1 — activation et dispatch des commandes Restaurant/Boulangerie v2 : interrupteurs séparés, dispatch
// uniquement après acceptation du partenaire, expiration, alertes d'attente, garde AZ IA. Fonctions RÉELLES sur faux
// Firestore sérialisé ; données fictives, aucun accès Firebase.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildPartnerOrderAction } = require('../partnerOrderActions');
const { buildCancelOrder } = require('../orderActions');
const { calculateCommission, dispatchOrder: rawDispatchOrder } = require('../dispatch');
const { expireOrderTx, PARTNER_RESPONSE_TIMEOUT_MS } = require('../orderRefunds');
const fs = require('node:fs');
const path = require('node:path');
const { reserveAttempt, queuedAtMs } = require('../dispatchRetry');
const { dispatchAcceptedPartnerOrder } = require('../partnerDispatch');
const cfg = require('../partnerOrdersConfig');
const { scanPartnerOrderWaits, PARTNER_WAIT_MS, COLLECTION } = require('../stuckOrderAlerts');
const { createRestaurantOrder } = require('../azia/tools/restaurants');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const NOW = 1_800_000_000_000;
const silent = { log() {}, error() {}, warn() {} };

const pendingV2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: null, status: 'pending', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000,
  budget: 500, shoppingBudget: 0, latitude: 6.73, longitude: -3.49, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved',
  ...extra,
});

function world(order = pendingV2(), { dispatch, clock = { t: NOW } } = {}) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya' },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'admins/root': { role: 'super', isActive: true },
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const calls = [];
  const dispatchOrder = dispatch || (async (_d, _a, args) => { calls.push(args); return { dispatched: true, mode: 'sequential' }; });
  const wrapped = async (d, a, args) => { if (dispatch) calls.push(args); return dispatchOrder(d, a, args); };
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission };
  const act = buildPartnerOrderAction({
    ...common, onCall: oc, now: () => clock.t, isEnabled: () => true,
    dispatchAccepted: (orderId) => dispatchAcceptedPartnerOrder({ db, admin, dispatchOrder: wrapped, orderId, logger: silent }),
  }).run;
  const cancel = buildCancelOrder({ ...common, onCall: oc }).run;
  return {
    db, calls, s: db.store, order: () => db.store.get('orders/o1'),
    call: (action, uid = 'r1', extra = {}) => act({ auth: authOf(uid), data: { orderId: 'o1', action, ...extra } }),
    clientCancel: () => cancel({ auth: authOf('c1'), data: { orderId: 'o1' } }),
    refunds: () => [...db.store.keys()].filter((k) => k.startsWith('clients/c1/wallet_transactions/')).map((k) => db.store.get(k)).filter((x) => x.type === 'refund'),
  };
}
const expire = (t) => t.db.runTransaction((tx) => expireOrderTx(tx, { db: t.db, admin, orderRef: t.db.collection('orders').doc('o1'), orderId: 'o1' }));

// ── Interrupteurs et liste pilote ─────────────────────────────────────────────────────────────────────

test('interrupteurs : création désactivée par défaut, gestion activée par défaut, gel d’urgence indépendant', () => {
  const prev = { c: process.env.PARTNER_ORDERS_V2, m: process.env.PARTNER_ORDERS_V2_MANAGE };
  try {
    delete process.env.PARTNER_ORDERS_V2; delete process.env.PARTNER_ORDERS_V2_MANAGE;
    assert.equal(cfg.creationEnabled(), false);
    assert.equal(cfg.managementEnabled(), true);
    process.env.PARTNER_ORDERS_V2 = 'on';
    assert.equal(cfg.creationEnabled(), true);
    process.env.PARTNER_ORDERS_V2 = 'yes';
    assert.equal(cfg.creationEnabled(), false);
    process.env.PARTNER_ORDERS_V2_MANAGE = 'off';
    assert.equal(cfg.managementEnabled(), false);
    process.env.PARTNER_ORDERS_V2_MANAGE = 'on';
    assert.equal(cfg.managementEnabled(), true);
  } finally {
    for (const [k, v] of [['PARTNER_ORDERS_V2', prev.c], ['PARTNER_ORDERS_V2_MANAGE', prev.m]]) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
});

test('liste pilote (sécurité par défaut) : document absent, liste absente/invalide/vide = aucune création v2 ; seuls les partenaires listés', () => {
  for (const data of [null, {}, { pilotPartnerIds: 'r1' }, { pilotPartnerIds: [] }, { pilotPartnerIds: [5, '', 'a/b'] }]) {
    const c = cfg.parsePilotConfig(data);
    assert.equal(cfg.v2CreationAllowed(c, 'r1'), false, JSON.stringify(data));
    assert.equal(cfg.legacyCreationBlocked(c, 'r1'), false, 'aucun pilote : ancien parcours intact');
  }
  const pilot = cfg.parsePilotConfig({ pilotPartnerIds: ['r1', '', 5, 'a/b'] });
  assert.deepEqual([...pilot.ids], ['r1']);
  assert.equal(cfg.v2CreationAllowed(pilot, 'r1'), true);
  assert.equal(cfg.v2CreationAllowed(pilot, 'r2'), false);
  // Même définition pour le parcours historique (et pour firestore.rules) : exactement les partenaires listés.
  assert.equal(cfg.legacyCreationBlocked(pilot, 'r1'), true);
  assert.equal(cfg.legacyCreationBlocked(pilot, 'r2'), false, 'partenaire hors pilote : ancien parcours intact');
});

// ── Dispatch uniquement après acceptation ─────────────────────────────────────────────────────────────

test('dispatch : jamais avant l’acceptation ; une seule fois à l’acceptation ; rejeu sans second dispatch', async () => {
  const t = world();
  assert.deepEqual(await dispatchAcceptedPartnerOrder({ db: t.db, admin, dispatchOrder: async () => { throw new Error('ne doit pas être appelé'); }, orderId: 'o1', logger: silent }),
    { dispatched: false, mode: 'not_eligible' });
  assert.equal(t.calls.length, 0);
  const r = await t.call('acceptPartnerOrder');
  assert.equal(r.success, true);
  assert.deepEqual(r.data.dispatch, { dispatched: true, mode: 'sequential' });
  assert.equal(t.calls.length, 1);
  assert.deepEqual([t.calls[0].orderId, t.calls[0].budget, t.calls[0].pickupCityId], ['o1', 500, 'abengourou']);
  const again = await t.call('acceptPartnerOrder');
  assert.equal(again.data.replay, true);
  assert.equal(again.data.dispatch, undefined);
  assert.equal(t.calls.length, 1);
  // startPreparation après acceptation : pas de second dispatch.
  await t.call('startPreparation');
  assert.equal(t.calls.length, 1);
});

test('dispatch : startPreparation sans acceptation préalable vaut acceptation et dispatche une fois', async () => {
  const t = world();
  const r = await t.call('startPreparation');
  assert.equal(r.success, true);
  assert.equal(t.order().sellerStatus, 'preparing');
  assert.equal(t.calls.length, 1);
  await t.call('markReady');
  await t.call('startPreparation');
  assert.equal(t.calls.length, 1);
});

test('dispatch : 8 acceptations simultanées → un seul dispatch', async () => {
  const t = world();
  const res = await Promise.allSettled(Array.from({ length: 8 }, () => t.call(Math.random() < 0.5 ? 'acceptPartnerOrder' : 'startPreparation')));
  assert.ok(res.every((x) => x.status === 'fulfilled'));
  assert.equal(t.calls.length, 1);
  assert.ok(t.order().partnerAcceptedAtMs);
});

test('dispatch : un échec ou une absence de livreur ne bloque jamais l’acceptation', async () => {
  const t = world(pendingV2(), { dispatch: async () => { throw new Error('panne'); } });
  const r = await t.call('acceptPartnerOrder');
  assert.equal(r.success, true);
  assert.equal(r.data.dispatch.dispatched, false);
  assert.equal(t.order().partnerAcceptedAtMs, NOW);
});

test('dispatch : refus du partenaire → aucun dispatch, remboursement unique', async () => {
  const t = world();
  const r = await t.call('refusePartnerOrder', 'r1', { reason: 'Rupture de stock' });
  assert.equal(r.success, true);
  assert.equal(t.calls.length, 0);
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.refunds().length, 1);
});

test('dispatch : garde centrale — une v2 non acceptée n’est jamais attribuée, même appelée directement', async () => {
  const t = world();
  const out = await rawDispatchOrder(t.db, admin, {
    orderId: 'o1', lat: 6.73, lng: -3.49, budget: 500, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved',
  }).catch((e) => ({ error: e.code || e.message }));
  assert.notEqual(out.dispatched, true);
  assert.equal(t.order().status, 'pending');
  assert.equal(t.order().driverId, null);
});

test('dispatch : concurrence acceptation partenaire / annulation client → un seul état final, un seul remboursement', async () => {
  for (let i = 0; i < 4; i++) {
    const t = world();
    const calls = [t.call('acceptPartnerOrder'), t.clientCancel()];
    await Promise.allSettled(i % 2 ? calls.reverse() : calls);
    const o = t.order();
    assert.ok(['pending', 'cancelled'].includes(o.status), `tour ${i} : ${o.status}`);
    assert.equal(t.refunds().length, o.status === 'cancelled' ? 1 : 0, `tour ${i} : remboursements`);
    assert.equal(o.driverId, null);
    // Après annulation, plus aucun dispatch possible.
    const after = await dispatchAcceptedPartnerOrder({ db: t.db, admin, dispatchOrder: async () => ({ dispatched: true }), orderId: 'o1', logger: silent });
    assert.equal(after.dispatched, o.status === 'pending' && !!o.partnerAcceptedAtMs);
    // Annulations rejouées : jamais de second remboursement.
    await t.clientCancel().catch(() => {});
    await t.clientCancel().catch(() => {});
    assert.ok(t.refunds().length <= 1);
  }
});

test('reprise serveur : v2 non acceptée jamais relancée ; v2 acceptée comptée depuis l’acceptation ; historique inchangé', async () => {
  const ts = (ms) => ({ toMillis: () => ms });
  const mk = (extra) => {
    const t = world(pendingV2({ createdAt: ts(NOW - 8 * 60_000), ...extra }));
    return reserveAttempt(t.db, { orderRef: t.db.collection('orders').doc('o1'), retryRef: t.db.collection('order_dispatch_retries').doc('o1'), nowMs: NOW });
  };
  assert.deepEqual(await mk({}), { reserved: false, reason: 'awaiting_partner' });
  const accepted = await mk({ partnerAcceptedAtMs: NOW - 60_000 });
  assert.equal(accepted.reserved, true, 'acceptée il y a 1 min : la reprise démarre malgré un âge de commande de 8 min');
  assert.equal(queuedAtMs(pendingV2({ createdAt: ts(NOW - 8 * 60_000), partnerAcceptedAtMs: NOW - 60_000 })), NOW - 60_000);
  const legacy = await mk({ amountsVersion: undefined });
  assert.equal(legacy.reserved, true, 'historique : comportement inchangé');
  assert.equal(queuedAtMs({ createdAt: ts(NOW - 5000) }), NOW - 5000);
});

// ── Expiration ────────────────────────────────────────────────────────────────────────────────────────

test('expiration : v2 non acceptée < 60 min, acceptée depuis < 10 min, ou préparation commencée → jamais expirée', async () => {
  for (const [extra, reason] of [
    [{ createdAt: { toMillis: () => Date.now() - PARTNER_RESPONSE_TIMEOUT_MS + 120_000 } }, 'awaiting_partner'],
    [{ createdAt: undefined }, 'awaiting_partner'],
    [{ partnerAcceptedAtMs: Date.now() - 60_000 }, 'awaiting_driver'],
    [{ partnerAcceptedAtMs: 1, sellerStatus: 'preparing' }, 'preparation_started'],
    [{ partnerAcceptedAtMs: 1, sellerStatus: 'ready' }, 'preparation_started'],
  ]) {
    const t = world(pendingV2({ createdAt: { toMillis: () => 1 }, ...extra }));
    const e = await expire(t);
    assert.deepEqual([e.expired, e.reason], [false, reason]);
    assert.equal(t.order().status, 'pending');
    assert.equal(t.refunds().length, 0);
  }
});

test('expiration : v2 acceptée il y a plus de 10 min sans préparation → annulée, remboursement unique et exact', async () => {
  const t = world(pendingV2({ partnerAcceptedAtMs: 1 }));
  const e = await expire(t);
  assert.equal(e.expired, true);
  assert.equal(t.order().status, 'cancelled');
  assert.deepEqual(t.refunds().map((x) => x.amount), [4000]);
  const again = await expire(t);
  assert.equal(again.expired, false);
  assert.equal(t.refunds().length, 1, 'aucun double remboursement');
});

test('expiration : commande historique sans amountsVersion toujours expirée comme avant', async () => {
  const t = world({
    id: 'o1', clientId: 'c1', driverId: null, status: 'pending', type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
    paymentMethod: 'wallet', isPaid: true, budget: 4000, shoppingBudget: 0,
  });
  const e = await expire(t);
  assert.equal(e.expired, true);
  assert.equal(t.order().status, 'cancelled');
});

// ── Alertes d'attente ─────────────────────────────────────────────────────────────────────────────────

function alertDb(orders) {
  const alerts = new Map();
  const admins = [{ data: () => ({ role: 'super', isActive: true, fcmToken: 'token-root-0000000' }) }];
  const db = {
    collection(name) {
      if (name === 'orders') {
        return {
          where(f1, o1, v1) {
            assert.deepEqual([f1, o1, v1], ['amountsVersion', '==', 2]);
            return { where: (f2, o2, v2) => {
              assert.deepEqual([f2, o2], ['status', 'in']);
              return { limit: () => ({ get: async () => ({ docs: Object.entries(orders).filter(([, o]) => o.amountsVersion === 2 && v2.includes(o.status)).map(([id, o]) => ({ id, data: () => o })) }) }) };
            } };
          },
        };
      }
      if (name === 'admins') return { where: () => ({ get: async () => ({ docs: admins }) }) };
      if (name === COLLECTION) return { doc: (id) => ({ create: async (d) => { if (alerts.has(id)) throw new Error('ALREADY_EXISTS'); alerts.set(id, d); } }) };
      throw new Error(`collection inattendue : ${name}`);
    },
  };
  const sent = [];
  const run = (nowMs = NOW) => scanPartnerOrderWaits({ db, nowMs, logger: silent, sendToToken: async (...a) => { sent.push(a); }, logAudit: async () => {} });
  return { run, alerts, sent };
}

test('alertes : partenaire sans réponse et commande préparée sans livreur, une fois chacune, aucune écriture sur la commande', async () => {
  const ts = (ms) => ({ toMillis: () => ms });
  const t = alertDb({
    noReply: pendingV2({ createdAt: ts(NOW - PARTNER_WAIT_MS - 1000) }),
    recent: pendingV2({ createdAt: ts(NOW - 60_000) }),
    prepared: pendingV2({ createdAt: ts(NOW - 3_600_000), partnerAcceptedAtMs: NOW - PARTNER_WAIT_MS - 5000, sellerStatus: 'preparing' }),
    preparedRecent: pendingV2({ createdAt: ts(NOW - 3_600_000), partnerAcceptedAtMs: NOW - 60_000, sellerStatus: 'ready' }),
    acceptedNotPrepared: pendingV2({ createdAt: ts(NOW - 3_600_000), partnerAcceptedAtMs: NOW - 3_600_000 }),
    withDriver: pendingV2({ createdAt: ts(NOW - 3_600_000), driverId: 'dA', status: 'broadcast', partnerAcceptedAtMs: 1, sellerStatus: 'preparing' }),
    legacy: { status: 'pending', createdAt: ts(1) },
  });
  const first = await t.run();
  assert.deepEqual([first.alerted, first.errors], [2, 0]);
  assert.deepEqual([...t.alerts.keys()].map((k) => k.replace(/_\d+$/, '')).sort(), ['noReply_partner_no_response', 'prepared_prepared_no_driver']);
  assert.equal(t.sent.length, 2);
  const second = await t.run();
  assert.deepEqual([second.alerted, second.duplicates], [0, 2]);
});

// ── AZ IA : ancien parcours ───────────────────────────────────────────────────────────────────────────

function aziaDb(seed) {
  const store = new Map(Object.entries(seed));
  const ref = (path) => ({ id: path.split('/').pop(), __path: path, get: async () => ({ exists: store.has(path), data: () => store.get(path) }), set: async (d) => { store.set(path, d); }, update: async (d) => { store.set(path, { ...store.get(path), ...d }); }, collection: (s) => coll(`${path}/${s}`) });
  const coll = (name) => ({ doc: (id) => ref(`${name}/${id ?? 'auto'}`), add: async (d) => { store.set(`${name}/auto${store.size}`, d); return { id: 'x' }; } });
  return {
    store,
    collection: coll,
    runTransaction: async (fn) => fn({
      get: async (r) => ({ exists: store.has(r.__path), data: () => store.get(r.__path) }),
      set: (r, d) => store.set(r.__path, d), update: (r, d) => store.set(r.__path, { ...store.get(r.__path), ...d }),
    }),
  };
}
const fakeAdmin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', increment: (n) => ({ __increment: n }), arrayUnion: (...a) => a } } };

test('AZ IA create_restaurant_order : refusé pour un partenaire pilote, intact hors pilote, sans liste et après retrait de la liste', async () => {
  const db = aziaDb({
    'clients/c1': { wallet: 5000 }, 'restaurants/r1': { name: 'Chez Awa', wallet: 0 }, 'restaurants/r2': { name: 'Autre', wallet: 0 },
    'config/partnerOrdersV2': { pilotPartnerIds: ['r1'] },
  });
  const tool = createRestaurantOrder({ db, admin: fakeAdmin, HttpsError });
  const input = (id) => ({ restaurantId: id, items: [{ name: 'Plat', price: 1000, quantity: 1 }], deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'cash' });
  const conf = (id, name) => ({ restaurantId: id, restaurantName: name, items: [{ name: 'Plat', price: 1000, quantity: 1 }], budget: 1000, deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'cash' });

  assert.ok((await tool.handler('c1', input('r1'))).error, 'pilote : proposition refusée');
  await assert.rejects(() => db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', conf('r1', 'Chez Awa'))), (e) => e.code === 'failed-precondition');
  assert.equal([...db.store.keys()].filter((k) => k.startsWith('orders/')).length, 0, 'aucune commande historique créée');
  const ok = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', conf('r2', 'Autre')));
  assert.equal(ok.budget, 1000, 'partenaire hors pilote : ancien parcours intact');

  db.store.set('config/partnerOrdersV2', { pilotPartnerIds: [] }); // retiré de la liste : l’ancien parcours revient
  assert.equal((await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', conf('r1', 'Chez Awa')))).budget, 1000);
  db.store.delete('config/partnerOrdersV2'); // document absent : aucun pilote
  assert.equal((await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', conf('r1', 'Chez Awa')))).budget, 1000);
});

// ── Mission 7C-1-S : annulation à 60 minutes d’une v2 jamais acceptée ────────────────────────────────────

const stale = (extra = {}) => pendingV2({ createdAt: { toMillis: () => Date.now() - PARTNER_RESPONSE_TIMEOUT_MS - 60_000 }, ...extra });

test('expiration 60 min : v2 jamais acceptée → annulée, remboursement intégral unique, rien au partenaire, rejeu sans effet', async () => {
  const t = world(stale());
  const e = await expire(t);
  assert.deepEqual([e.expired, e.refunded], [true, 4000]);
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.order().cancelReason, 'partner_no_response');
  assert.deepEqual(t.refunds().map((x) => [x.type, x.amount]), [['refund', 4000]]);
  assert.equal(t.s.get('restaurants/r1').wallet, 1000, 'partenaire jamais touché');
  for (let i = 0; i < 3; i++) assert.equal((await expire(t)).expired, false);
  assert.equal(t.refunds().length, 1);
  assert.equal((await t.clientCancel().catch((e2) => ({ success: false, e: e2 }))).success === true, false, 'annulation client rejouée : pas de second remboursement');
  assert.equal(t.refunds().length, 1);
});

test('expiration 60 min : paiement cash → annulée sans aucun mouvement de wallet', async () => {
  const t = world(stale({ paymentMethod: 'cash', isPaid: false }));
  assert.equal((await expire(t)).expired, true);
  assert.equal(t.refunds().length, 0);
  assert.equal(t.s.get('clients/c1').wallet, 16000);
});

test('expiration 60 min : aucune annulation si le partenaire a accepté ou commencé la préparation', async () => {
  for (const extra of [{ partnerAcceptedAtMs: Date.now() - 1000 }, { partnerAcceptedAtMs: 1, sellerStatus: 'preparing' }]) {
    const t = world(stale(extra));
    assert.equal((await expire(t)).expired, false);
    assert.equal(t.order().status, 'pending');
    assert.equal(t.refunds().length, 0);
  }
});

test('expiration 60 min : acceptation et expiration simultanées → un seul état final cohérent, jamais de remboursement après acceptation', async () => {
  for (let i = 0; i < 6; i++) {
    const t = world(stale());
    const jobs = [t.call(i % 2 ? 'startPreparation' : 'acceptPartnerOrder'), expire(t), expire(t)];
    await Promise.allSettled(i % 3 ? jobs.reverse() : jobs);
    const o = t.order();
    if (o.status === 'cancelled') {
      assert.equal(o.cancelReason, 'partner_no_response', `tour ${i}`);
      assert.equal(o.partnerAcceptedAtMs, undefined, `tour ${i} : annulée donc jamais acceptée`);
      assert.equal(t.refunds().length, 1);
    } else {
      assert.ok(o.partnerAcceptedAtMs, `tour ${i} : acceptée donc non annulée`);
      assert.equal(t.refunds().length, 0);
    }
  }
});

test('expiration 60 min : refus du partenaire, annulation client et expiration en concurrence → un seul remboursement', async () => {
  for (let i = 0; i < 6; i++) {
    const t = world(stale());
    const jobs = [t.call('refusePartnerOrder', 'r1', { reason: 'Fermé aujourd’hui' }), t.clientCancel(), expire(t)];
    await Promise.allSettled(i % 2 ? jobs.reverse() : jobs);
    assert.equal(t.order().status, 'cancelled');
    assert.equal(t.refunds().length, 1, `tour ${i}`);
    assert.equal(t.refunds()[0].amount, 4000);
    assert.equal(t.s.get('clients/c1').wallet.__inc ?? 4000, 4000);
  }
});

test('expiration 60 min : acceptation tardive après annulation refusée ; commande historique inchangée', async () => {
  const t = world(stale());
  await expire(t);
  const late = await t.call('acceptPartnerOrder');
  assert.equal(late.success, false);
  assert.equal(t.calls.length, 0, 'aucun dispatch d’une commande annulée');
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.refunds().length, 1);
});

test('branchements serveur : filtre 60 min dans le scheduler, notification client dédiée, constante partagée', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.ok(src.includes('< PARTNER_RESPONSE_TIMEOUT_MS) continue;'), 'filtre 60 min du scheduler');
  const at = src.indexOf("cancelReason === 'partner_no_response'");
  assert.ok(at > 0 && src.slice(at, at + 500).includes("type: 'partner_no_response'"), 'notification client dédiée');
  assert.equal(PARTNER_RESPONSE_TIMEOUT_MS, 60 * 60 * 1000);
});
