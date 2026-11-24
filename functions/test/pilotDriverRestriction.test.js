'use strict';

// Restriction des livreurs du pilote Restaurant/Boulangerie v2 (Mission 7E-55) : `pilotDriverIds` appliqué au dispatch, à
// l'acceptation et au transfert, liste absente/vide/malformée = personne, commandes historiques inchangées. Aucun Firestore
// réel : faux Firestore en mémoire.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { dispatchOrder: rawDispatchOrder, calculateCommission } = require('../dispatch');
const { buildAcceptOrder } = require('../driverAcceptance');
const cfg = require('../partnerOrdersConfig');
const { fakeDb, DELETE } = require('./fakeFirestore');
const { withSelfie } = require('./selfieHelper');

const CENTER = { lat: 6.7273, lng: -3.4961 };
const CITY = { id: 'city-abengourou', cityId: 'abengourou', type: 'ville', isActive: true, isServiceable: true,
  coordinateSource: 'own', lat: CENTER.lat, lng: CENTER.lng, radiusKm: 25 };
const adminDispatch = { firestore: { FieldValue: { arrayUnion: (...a) => ({ __arrayUnion: a }) } } };

const V2_ORDER = { status: 'pending', amountsVersion: 2, sellerType: 'restaurant', partnerAcceptedAtMs: 1, budget: 500 };
const driver = (id, off, extra = {}) => ({ id, isOnline: true, isAvailable: true, wallet: 5000, lat: CENTER.lat + off, lng: CENTER.lng + off, ...extra });
const ABSENT = Symbol('config absente');
const pilot = (over = {}) => ({ pilotPartnerIds: ['t7e-resto'], pilotClientIds: ['t7e-client'], pilotDriverIds: ['t7e-driver'], clientAccess: 'restricted', version: 4, ...over });

// Faux Firestore propre au dispatch : config/commission + config/partnerOrdersV2 (valeur ou fonction appelée à chaque lecture).
function dispatchDb({ drivers, order = V2_ORDER, pilotConfig = pilot() }) {
  const orders = new Map([['o1', { ...order }]]);
  const reads = { pilot: 0 };
  const batches = [];
  const cfgGet = (name) => async () => {
    if (name !== 'partnerOrdersV2') return { exists: false, data: () => undefined };
    reads.pilot += 1;
    const value = typeof pilotConfig === 'function' ? pilotConfig(reads.pilot) : pilotConfig;
    return { exists: value !== ABSENT, data: () => (value === ABSENT ? undefined : value) };
  };
  const driverQuery = (filters = []) => ({
    where: (field, op, value) => driverQuery([...filters, { field, op, value }]),
    limit: () => driverQuery(filters),
    get: async () => {
      const sel = drivers.map((d) => ({ currentCityId: 'abengourou', registeredCityId: 'abengourou', ...d }))
        .filter((d) => filters.every((f) => (f.op === 'in' ? f.value.includes(d[f.field]) : d[f.field] === f.value)));
      const docs = sel.map((d) => ({ id: d.id, data: () => d }));
      return { docs, size: docs.length };
    },
  });
  const db = {
    collection(name) {
      if (name === 'account_deletions') return { doc: (id) => ({ __deletion: id }) };
      if (name === 'config') return { doc: (id) => ({ __cfg: id, get: cfgGet(id) }) };
      if (name === 'livreurs') return { where: (f, o, v) => driverQuery().where(f, o, v), doc: (id) => ({ __ref: `livreurs/${id}` }) };
      if (name === 'zones_livraison') {
        const q = () => ({ where: () => q(), limit: () => q(), get: async () => ({ docs: [{ id: CITY.id, data: () => CITY }], size: 1 }) });
        return { where: () => q() };
      }
      if (name === 'orders') return { doc: (id) => ({ __path: id, get: async () => ({ exists: orders.has(id), data: () => orders.get(id) }) }) };
      throw new Error(`Collection inattendue : ${name}`);
    },
    batch: () => { const ops = []; return { update: (ref, data) => ops.push({ ref, data }), commit: async () => batches.push(...ops) }; },
    runTransaction: async (fn) => fn({
      get: async (ref) => {
        if (ref.__cfg) return ref.get();
        if (ref.__deletion) return { exists: false, data: () => undefined };
        return { exists: orders.has(ref.__path), data: () => orders.get(ref.__path) };
      },
      update: (ref, data) => {
        const cur = { ...orders.get(ref.__path) };
        for (const [k, v] of Object.entries(data)) cur[k] = v && v.__arrayUnion ? [...(cur[k] || []), ...v.__arrayUnion] : v;
        orders.set(ref.__path, cur);
      },
    }),
  };
  return { db, orders, reads, batches };
}

const dispatch = (db) => rawDispatchOrder(db, adminDispatch, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500, pickupCityId: 'abengourou', cityResolutionStatus: 'resolved' });

test('dispatch : le livreur du pilote est choisi même si un livreur extérieur est plus proche', async () => {
  const h = dispatchDb({ drivers: [driver('t7e-driver', 0.004), driver('outsider', 0.0005)] });
  const r = await dispatch(h.db);
  assert.deepEqual({ dispatched: r.dispatched, mode: r.mode }, { dispatched: true, mode: 'assigned' });
  assert.equal(h.orders.get('o1').driverId, 't7e-driver');
  assert.equal(h.batches.length, 0);
});

test('dispatch : livreur extérieur seul = aucune attribution, commande intacte', async () => {
  const h = dispatchDb({ drivers: [driver('outsider', 0.0005)] });
  const r = await dispatch(h.db);
  assert.deepEqual({ dispatched: r.dispatched, mode: r.mode }, { dispatched: false, mode: 'none' });
  assert.equal(h.orders.get('o1').status, 'pending');
  assert.equal(h.orders.get('o1').driverId, undefined);
});

test('dispatch : liste absente, vide ou mal formée = aucun livreur (mode fermé)', async () => {
  const noList = pilot(); delete noList.pilotDriverIds;
  const variants = { absente: noList, vide: pilot({ pilotDriverIds: [] }), 'non tableau': pilot({ pilotDriverIds: 't7e-driver' }),
    'entrée invalide': pilot({ pilotDriverIds: ['t7e-driver', 'a/b'] }), 'entrée non texte': pilot({ pilotDriverIds: ['t7e-driver', 12] }),
    'config absente': ABSENT };
  for (const [name, value] of Object.entries(variants)) {
    const h = dispatchDb({ drivers: [driver('t7e-driver', 0.001)], pilotConfig: value });
    const r = await dispatch(h.db);
    assert.equal(r.dispatched, false, name);
    assert.equal(h.orders.get('o1').status, 'pending', name);
  }
});

test('dispatch : diffusion limitée aux livreurs de la liste', async () => {
  const h = dispatchDb({ pilotConfig: pilot({ pilotDriverIds: ['t7e-driver', 'd2'] }),
    drivers: [driver('t7e-driver', 0.001), driver('d2', 0.002), driver('outsider', 0.0005)] });
  const r = await dispatch(h.db);
  assert.equal(r.mode, 'broadcast');
  assert.deepEqual([...h.orders.get('o1').notifiedDriverIds].sort(), ['d2', 't7e-driver']);
  assert.deepEqual(h.batches.map((b) => b.ref.__ref).sort(), ['livreurs/d2', 'livreurs/t7e-driver']);
});

test('dispatch : ouverture générale (clientAccess open) lève la restriction', async () => {
  const h = dispatchDb({ pilotConfig: pilot({ clientAccess: 'open', pilotDriverIds: [] }), drivers: [driver('outsider', 0.001)] });
  assert.equal((await dispatch(h.db)).mode, 'assigned');
});

test('dispatch : commande historique ou autre service inchangée (aucune lecture du pilote)', async () => {
  for (const order of [{ status: 'pending', budget: 500 }, { status: 'pending', amountsVersion: 1, sellerType: 'marketplace', budget: 500 },
    { status: 'pending', amountsVersion: 2, sellerType: 'pharmacie', partnerAcceptedAtMs: 1, budget: 500 }]) {
    const h = dispatchDb({ order, drivers: [driver('outsider', 0.001)], pilotConfig: pilot({ pilotDriverIds: [] }) });
    const r = await dispatch(h.db);
    assert.equal(r.mode, 'assigned', JSON.stringify(order));
    assert.equal(h.reads.pilot, 0, 'la configuration du pilote ne doit pas être lue');
  }
});

test('dispatch : la liste est relue dans la transaction (changement entre sélection et attribution)', async () => {
  // 1re lecture (sélection) : l'extérieur est autorisé ; 2e lecture (transaction) : retiré.
  const h = dispatchDb({ drivers: [driver('outsider', 0.001)],
    pilotConfig: (n) => pilot({ pilotDriverIds: n === 1 ? ['outsider'] : ['t7e-driver'] }) });
  const r = await dispatch(h.db);
  assert.equal(r.dispatched, false);
  assert.equal(h.orders.get('o1').status, 'pending');
  assert.equal(h.reads.pilot, 2);
});

test('dispatch : réessai concurrent ou répété, même résultat, jamais de livreur extérieur', async () => {
  const h = dispatchDb({ drivers: [driver('t7e-driver', 0.003), driver('outsider', 0.0005)] });
  const [a, b] = await Promise.all([dispatch(h.db), dispatch(h.db)]);
  assert.equal(h.orders.get('o1').driverId, 't7e-driver');
  assert.ok([a, b].every((r) => r.mode === 'assigned' || r.mode === 'already_assigned'));
  assert.equal((await dispatch(h.db)).mode, 'already_assigned');
  assert.equal(h.orders.get('o1').driverId, 't7e-driver');
});

// ── Acceptation ─────────────────────────────────────────────────────────────

const walletOf = (h, id) => h.db.store.get(`livreurs/${id}`).wallet;
function acceptHarness({ order = {}, pilotDoc = pilot(), drivers = ['t7e-driver', 'outsider'], extra = {} } = {}) {
  const seed = {
    'orders/o1': { status: 'assigned', driverId: 't7e-driver', amountsVersion: 2, sellerType: 'restaurant', budget: 500, description: 'Commande', ...order },
    ...Object.fromEntries(drivers.map((id) => [`livreurs/${id}`, { wallet: 1000, isOnline: true }])),
    ...(pilotDoc === ABSENT ? {} : { 'config/partnerOrdersV2': pilotDoc }),
    ...extra,
  };
  const db = fakeDb(seed);
  const run = withSelfie(buildAcceptOrder({
    db, admin: { firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE } } },
    onCall: (handler) => ({ run: handler }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run);
  const call = (uid) => run({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: 'o1' } });
  return { db, call };
}
const refusedAs = (code) => (e) => e instanceof HttpsError && e.code === 'permission-denied' && e.message === code;

test('acceptation : le livreur du pilote accepte, commission prélevée une seule fois', async () => {
  const h = acceptHarness();
  const r = await h.call('t7e-driver');
  assert.equal(r.success, true);
  assert.equal(h.db.store.get('orders/o1').status, 'accepted');
  assert.equal(walletOf(h, 't7e-driver'), 900);
  assert.equal((await h.call('t7e-driver')).alreadyAccepted, true);
  assert.equal(walletOf(h, 't7e-driver'), 900);
});

test('acceptation directe par un livreur extérieur : refusée, aucun prélèvement, commande intacte', async () => {
  for (const order of [{ status: 'assigned', driverId: 'outsider' }, { status: 'broadcast', driverId: undefined, notifiedDriverIds: ['outsider'] }]) {
    const h = acceptHarness({ order });
    await assert.rejects(h.call('outsider'), refusedAs('DRIVER_NOT_IN_PILOT'));
    assert.equal(walletOf(h, 'outsider'), 1000);
    assert.equal(h.db.store.get('orders/o1').status, order.status);
    // Réessai : même refus, toujours aucun effet.
    await assert.rejects(h.call('outsider'), refusedAs('DRIVER_NOT_IN_PILOT'));
    assert.equal(walletOf(h, 'outsider'), 1000);
  }
});

test('acceptation : liste absente, vide ou mal formée = refus, même pour le livreur du lot', async () => {
  const noList = pilot(); delete noList.pilotDriverIds;
  for (const doc of [noList, pilot({ pilotDriverIds: [] }), pilot({ pilotDriverIds: 'x' }), pilot({ pilotDriverIds: ['t7e-driver', ''] }), ABSENT]) {
    const h = acceptHarness({ pilotDoc: doc });
    await assert.rejects(h.call('t7e-driver'), refusedAs('DRIVER_NOT_IN_PILOT'));
    assert.equal(walletOf(h, 't7e-driver'), 1000);
  }
});

test('acceptation concurrente : seul le livreur de la liste obtient la commande diffusée', async () => {
  const h = acceptHarness({ order: { status: 'broadcast', driverId: undefined, notifiedDriverIds: ['t7e-driver', 'outsider'] } });
  const results = await Promise.allSettled([h.call('outsider'), h.call('t7e-driver')]);
  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].status, 'fulfilled');
  assert.equal(h.db.store.get('orders/o1').driverId, 't7e-driver');
  assert.equal(walletOf(h, 'outsider'), 1000);
});

test('acceptation : commandes historiques et ouverture générale non concernées', async () => {
  const legacy = acceptHarness({ order: { amountsVersion: undefined, sellerType: undefined, driverId: 'outsider' }, pilotDoc: pilot({ pilotDriverIds: [] }) });
  assert.equal((await legacy.call('outsider')).success, true);
  const open = acceptHarness({ order: { driverId: 'outsider' }, pilotDoc: pilot({ clientAccess: 'open', pilotDriverIds: [] }) });
  assert.equal((await open.call('outsider')).success, true);
});

// ── Configuration ───────────────────────────────────────────────────────────

test('configuration : pilotDriverIds validé, trié et écrit avec version et traçabilité', async () => {
  const good = cfg.validateConfigChange({ patch: { pilotDriverIds: ['b', 'a'] }, expectedVersion: 4, reason: 'Restriction livreurs du pilote' });
  assert.deepEqual(good.patch.pilotDriverIds, ['a', 'b']);
  const bad = (list) => assert.throws(() => cfg.validateConfigChange({ patch: { pilotDriverIds: list }, expectedVersion: 4, reason: 'Restriction livreurs du pilote' }), /Liste de livreurs/);
  for (const list of ['x', [1], ['a/b'], ['a', 'a'], [''], Array.from({ length: 51 }, (_, i) => `d${i}`)]) bad(list);
  const db = fakeDb({ 'config/partnerOrdersV2': { pilotPartnerIds: ['t7e-resto'], pilotClientIds: ['t7e-client'], clientAccess: 'restricted', creationOpen: false, managementFrozen: false, version: 4 } });
  const r = await cfg.applyConfigChange({ db, uid: 'admin', input: { patch: { pilotDriverIds: ['t7e-driver'] }, expectedVersion: 4, reason: 'Restriction livreurs du pilote' } });
  assert.deepEqual(r.before.pilotDriverIds, []);
  assert.deepEqual(r.after.pilotDriverIds, ['t7e-driver']);
  const saved = db.store.get('config/partnerOrdersV2');
  assert.deepEqual(saved.pilotDriverIds, ['t7e-driver']);
  assert.equal(saved.version, 5);
  assert.deepEqual(saved.pilotPartnerIds, ['t7e-resto']);
  assert.equal(saved.creationOpen, false);
});

test('configuration : un patch sans pilotDriverIds conserve la liste existante ; version périmée refusée', async () => {
  const db = fakeDb({ 'config/partnerOrdersV2': { pilotPartnerIds: ['t7e-resto'], pilotClientIds: ['t7e-client'], pilotDriverIds: ['t7e-driver'], clientAccess: 'restricted', creationOpen: false, managementFrozen: false, version: 5 } });
  await cfg.applyConfigChange({ db, uid: 'admin', input: { patch: { creationOpen: true }, expectedVersion: 5, reason: 'Réouverture contrôlée du pilote' } });
  assert.deepEqual(db.store.get('config/partnerOrdersV2').pilotDriverIds, ['t7e-driver']);
  await assert.rejects(cfg.applyConfigChange({ db, uid: 'admin', input: { patch: { pilotDriverIds: [] }, expectedVersion: 5, reason: 'Réouverture contrôlée du pilote' } }), { code: 'CONFIG_CONFLICT' });
});

test('driverRefusal : mode restreint exige la liste, jamais un paramètre client', () => {
  const p = (doc) => cfg.parsePilotConfig(doc);
  assert.equal(cfg.driverRefusal(p(pilot()), 't7e-driver'), null);
  assert.equal(cfg.driverRefusal(p(pilot()), 'outsider').code, 'DRIVER_NOT_IN_PILOT');
  assert.equal(cfg.driverRefusal(p(null), 't7e-driver').code, 'DRIVER_NOT_IN_PILOT');
  assert.equal(cfg.driverRefusal(p(pilot()), undefined).code, 'DRIVER_NOT_IN_PILOT');
  assert.equal(cfg.driverRefusal(p(pilot({ clientAccess: 'weird' })), 'outsider').code, 'DRIVER_NOT_IN_PILOT');
  assert.equal(cfg.isPartnerV2Order({ amountsVersion: 2, sellerType: 'boulangerie' }), true);
  assert.equal(cfg.isPartnerV2Order({ amountsVersion: 2, sellerType: 'pharmacie' }), false);
  assert.equal(cfg.isPartnerV2Order(null), false);
});
