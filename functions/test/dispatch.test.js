'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  dispatchOrder: rawDispatchOrder,
  calculateCommission,
  haversineMeters,
  DispatchError,
  DRIVER_QUERY_LIMIT,
  resolveDispatchGeography,
} = require('../dispatch');

// Point de référence Abengourou (utilisé par TarifService côté Dart).
const CENTER = { lat: 6.7273, lng: -3.4961 };
const ABENGOUROU = {
  id: 'city-abengourou',
  cityId: 'abengourou',
  type: 'ville',
  isActive: true,
  isServiceable: true,
  coordinateSource: 'own',
  lat: CENTER.lat,
  lng: CENTER.lng,
  radiusKm: 25,
};

function dispatchOrder(db, admin, args) {
  return rawDispatchOrder(db, admin, {
    pickupCityId: 'abengourou',
    cityResolutionStatus: 'resolved',
    ...args,
  });
}

function nearby(offsetDeg) {
  // ~0.001° ≈ 111 m — largement dans le rayon par défaut de 2 km.
  return { lat: CENTER.lat + offsetDeg, lng: CENTER.lng + offsetDeg };
}

const fakeAdmin = {
  firestore: {
    FieldValue: {
      arrayUnion: (...args) => ({ __arrayUnion: args }),
    },
  },
};

// Fake Firestore minimaliste couvrant exactement ce que dispatch.js touche :
// config/commission (lecture), livreurs (requête isOnline + batch update),
// orders (transaction get/update). Pas de dépendance à l'émulateur Firestore.
// Les commandes vivent dans un store en mémoire (statut initial 'pending' par
// défaut) pour que la transaction de dispatchOrder() puisse lire/écrire un
// état réaliste — nécessaire depuis l'ajout du verrouillage transactionnel.
function makeFakeDb({
  commissionConfig = null,
  drivers = [],
  cities = [ABENGOUROU],
  orders = {},
} = {}) {
  const orderStore = new Map(
    Object.entries(Object.keys(orders).length ? orders : { o1: { status: 'pending' } })
  );
  const orderUpdates = [];
  const driverBatchUpdates = [];
  const cityScopedDrivers = drivers.map((driver) => ({
    currentCityId: 'abengourou',
    registeredCityId: 'abengourou',
    ...driver,
  }));

  const db = {
    collection(name) {
      if (name === 'config') {
        return {
          doc: () => ({
            get: async () => ({
              exists: !!commissionConfig,
              data: () => commissionConfig,
            }),
          }),
        };
      }
      if (name === 'livreurs') {
        const query = (filters = [], queryLimit = null) => ({
          where: (field, op, value) =>
            query([...filters, { field, op, value }], queryLimit),
          limit: (value) => query(filters, value),
          get: async () => {
            let selected = cityScopedDrivers.filter((driver) => filters.every((filter) => {
              if (filter.op === '==') return driver[filter.field] === filter.value;
              if (filter.op === 'in') return filter.value.includes(driver[filter.field]);
              throw new Error(`Opérateur inattendu: ${filter.op}`);
            }));
            if (queryLimit != null) selected = selected.slice(0, queryLimit);
            const docs = selected.map((d) => ({ id: d.id, data: () => d }));
            return { docs, size: docs.length };
          },
        });
        return {
          where: (field, op, value) => query().where(field, op, value),
          doc: (id) => ({ __ref: `livreurs/${id}`, id }),
        };
      }
      if (name === 'zones_livraison') {
        const query = (filters = [], queryLimit = null) => ({
          where: (field, op, value) =>
            query([...filters, { field, op, value }], queryLimit),
          limit: (value) => query(filters, value),
          get: async () => {
            let selected = cities.filter((city) => filters.every((filter) =>
              filter.op === '==' && city[filter.field] === filter.value));
            if (queryLimit != null) selected = selected.slice(0, queryLimit);
            const docs = selected.map((city) => ({ id: city.id, data: () => city }));
            return { docs, size: docs.length };
          },
        });
        return {
          where: (field, op, value) => query().where(field, op, value),
        };
      }
      if (name === 'orders') {
        return {
          doc: (id) => ({
            __path: id,
            get: async () => ({
              exists: orderStore.has(id),
              data: () => orderStore.get(id),
            }),
            update: async (data) => {
              orderStore.set(id, { ...(orderStore.get(id) || {}), ...data });
              orderUpdates.push({ id, data });
            },
          }),
        };
      }
      throw new Error(`Collection inattendue dans le test : ${name}`);
    },
    batch() {
      const ops = [];
      return {
        update: (ref, data) => ops.push({ ref, data }),
        commit: async () => ops.forEach((op) => driverBatchUpdates.push(op)),
      };
    },
    runTransaction: async (fn) => {
      const tx = {
        get: async (ref) => ({
          exists: orderStore.has(ref.__path),
          data: () => orderStore.get(ref.__path),
        }),
        update: (ref, data) => {
          orderStore.set(ref.__path, { ...(orderStore.get(ref.__path) || {}), ...data });
          orderUpdates.push({ id: ref.__path, data });
        },
      };
      return fn(tx);
    },
  };

  return { db, orderUpdates, driverBatchUpdates, orderStore };
}

test('haversineMeters returns ~0 for the same point', () => {
  assert.ok(haversineMeters(CENTER.lat, CENTER.lng, CENTER.lat, CENTER.lng) < 1);
});

test('haversineMeters returns a sane distance for two known nearby points', () => {
  // ~0.01° de latitude ≈ 1.1 km à cette latitude.
  const d = haversineMeters(CENTER.lat, CENTER.lng, CENTER.lat + 0.01, CENTER.lng);
  assert.ok(d > 900 && d < 1300, `distance inattendue: ${d}`);
});

test('resolveDispatchGeography returns both cities, zones and sources', async () => {
  const quartier = {
    id: 'zone-centre', cityId: 'abengourou', type: 'quartier',
    isActive: true, isServiceable: true, coordinateSource: 'own',
    lat: CENTER.lat, lng: CENTER.lng, radiusKm: 2,
  };
  const { db } = makeFakeDb({ cities: [ABENGOUROU, quartier] });
  const result = await resolveDispatchGeography(db, {
    pickupLat: CENTER.lat,
    pickupLng: CENTER.lng,
    deliveryLat: CENTER.lat + 0.001,
    deliveryLng: CENTER.lng + 0.001,
    pickupCoordinateSource: 'local_place',
    deliveryCoordinateSource: 'gps',
  });
  assert.deepEqual(result, {
    pickupCityId: 'abengourou',
    pickupZoneId: 'zone-centre',
    deliveryCityId: 'abengourou',
    deliveryZoneId: 'zone-centre',
    pickupCoordinateSource: 'local_place',
    deliveryCoordinateSource: 'gps',
    cityResolutionStatus: 'resolved',
  });
});

test('resolveDispatchGeography refuses 0/0 before querying Firestore', async () => {
  const { db } = makeFakeDb();
  await assert.rejects(
    () => resolveDispatchGeography(db, {
      pickupLat: 0,
      pickupLng: 0,
      deliveryLat: CENTER.lat,
      deliveryLng: CENTER.lng,
      pickupCoordinateSource: 'local_place',
      deliveryCoordinateSource: 'gps',
    }),
    (error) => error instanceof DispatchError &&
      error.code === 'invalid-coordinates' && error.message.includes('collecte'),
  );
});

test('calculateCommission uses default tiers when config/commission is absent', async () => {
  const { db } = makeFakeDb({ commissionConfig: null });
  assert.equal(await calculateCommission(db, 500), 100);
  assert.equal(await calculateCommission(db, 999), 100);
  assert.equal(await calculateCommission(db, 1000), 200);
  assert.equal(await calculateCommission(db, 5000), 200);
});

test('calculateCommission honors a configured threshold/tiers', async () => {
  const { db } = makeFakeDb({
    commissionConfig: { commissionBasic: 150, commissionStandard: 300, threshold: 2000 },
  });
  assert.equal(await calculateCommission(db, 1999), 150);
  assert.equal(await calculateCommission(db, 2000), 300);
});

test('dispatchOrder assigns directly when exactly one eligible driver is nearby', async () => {
  const p = nearby(0.001);
  const { db, orderUpdates } = makeFakeDb({
    drivers: [
      { id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p.lat, lng: p.lng },
    ],
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });

  assert.deepEqual(result, { dispatched: true, mode: 'assigned' });
  assert.equal(orderUpdates.length, 1);
  assert.equal(orderUpdates[0].data.driverId, 'd1');
  assert.equal(orderUpdates[0].data.status, 'assigned');
});

test('dispatchOrder broadcasts when 2+ eligible drivers are nearby', async () => {
  const p1 = nearby(0.001);
  const p2 = nearby(0.0015);
  const { db, orderUpdates, driverBatchUpdates } = makeFakeDb({
    drivers: [
      { id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p1.lat, lng: p1.lng },
      { id: 'd2', isOnline: true, isOnDelivery: false, wallet: 500, lat: p2.lat, lng: p2.lng },
    ],
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });

  assert.deepEqual(result, { dispatched: true, mode: 'broadcast' });
  assert.equal(orderUpdates[0].data.status, 'broadcast');
  assert.deepEqual(orderUpdates[0].data.notifiedDriverIds.__arrayUnion.sort(), ['d1', 'd2']);
  assert.equal(driverBatchUpdates.length, 2);
  assert.ok(driverBatchUpdates.every((u) => u.data.pendingOrderId === 'o1'));
});

test('dispatchOrder reports none when no driver is online nearby', async () => {
  const { db, orderUpdates } = makeFakeDb({ drivers: [] });
  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });
  assert.deepEqual(result, { dispatched: false, mode: 'none' });
  assert.equal(orderUpdates.length, 0);
});

test('dispatchOrder excludes drivers that are on delivery, suspended, unavailable, or under-funded', async () => {
  const p = nearby(0.001);
  const base = { isOnline: true, lat: p.lat, lng: p.lng, wallet: 500 };
  const { db, orderUpdates } = makeFakeDb({
    drivers: [
      { ...base, id: 'busy',      isOnDelivery: true },
      { ...base, id: 'suspended', isSuspended: true },
      { ...base, id: 'unavail',   isAvailable: false },
      { ...base, id: 'poor',      wallet: 0 },
    ],
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });
  assert.deepEqual(result, { dispatched: false, mode: 'none' });
  assert.equal(orderUpdates.length, 0);
});

test('dispatchOrder excludes drivers outside the search radius', async () => {
  const far = { lat: CENTER.lat + 1, lng: CENTER.lng + 1 }; // ~150 km away
  const { db } = makeFakeDb({
    drivers: [{ id: 'far', isOnline: true, isOnDelivery: false, wallet: 500, lat: far.lat, lng: far.lng }],
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500, radiusKm: 2 });
  assert.deepEqual(result, { dispatched: false, mode: 'none' });
});

test('dispatchOrder excludes a driver whose GPS is stale (>3 min)', async () => {
  const p = nearby(0.001);
  const staleTimestamp = { toMillis: () => Date.now() - 10 * 60 * 1000 };
  const { db } = makeFakeDb({
    drivers: [{ id: 'stale', isOnline: true, isOnDelivery: false, wallet: 500, lat: p.lat, lng: p.lng, updatedAt: staleTimestamp }],
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });
  assert.deepEqual(result, { dispatched: false, mode: 'none' });
});

// ── Verrouillage transactionnel (Prompt 26) ─────────────────────────────

test('dispatchOrder refuses to assign a driver if the order is no longer pending (race guard)', async () => {
  const p = nearby(0.001);
  const { db, orderUpdates } = makeFakeDb({
    drivers: [{ id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p.lat, lng: p.lng }],
    orders: { o1: { status: 'assigned', driverId: 'already-there' } },
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });

  assert.deepEqual(result, { dispatched: false, mode: 'already_assigned' });
  assert.equal(orderUpdates.length, 0, 'must not overwrite an order that is no longer pending');
});

test('dispatchOrder refuses to broadcast if the order is no longer pending (race guard)', async () => {
  const p1 = nearby(0.001);
  const p2 = nearby(0.0015);
  const { db, orderUpdates, driverBatchUpdates } = makeFakeDb({
    drivers: [
      { id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p1.lat, lng: p1.lng },
      { id: 'd2', isOnline: true, isOnDelivery: false, wallet: 500, lat: p2.lat, lng: p2.lng },
    ],
    orders: { o1: { status: 'cancelled' } },
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });

  assert.deepEqual(result, { dispatched: false, mode: 'already_assigned' });
  assert.equal(orderUpdates.length, 0);
  assert.equal(driverBatchUpdates.length, 0, 'must not mark drivers pending for a cancelled order');
});

test('dispatchOrder still assigns normally when the order is genuinely pending', async () => {
  const p = nearby(0.001);
  const { db, orderStore } = makeFakeDb({
    drivers: [{ id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p.lat, lng: p.lng }],
    orders: { o1: { status: 'pending' } },
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });

  assert.deepEqual(result, { dispatched: true, mode: 'assigned' });
  assert.equal(orderStore.get('o1').driverId, 'd1');
  assert.equal(orderStore.get('o1').status, 'assigned');
});

test('dispatchOrder reports none (not already_assigned) when the order does not exist', async () => {
  const p = nearby(0.001);
  const { db } = makeFakeDb({
    drivers: [{ id: 'd1', isOnline: true, isOnDelivery: false, wallet: 500, lat: p.lat, lng: p.lng }],
    orders: { other: { status: 'pending' } },
  });

  const result = await dispatchOrder(db, fakeAdmin, { orderId: 'ghost', lat: CENTER.lat, lng: CENTER.lng, budget: 500 });
  assert.deepEqual(result, { dispatched: false, mode: 'none' });
});

test('un livreur d’une autre ville éloignée est exclu par la requête de ville', async () => {
  const { db } = makeFakeDb({
    drivers: [{
      id: 'far-city',
      isOnline: true,
      wallet: 500,
      lat: CENTER.lat,
      lng: CENTER.lng,
      currentCityId: 'agnibilekrou',
    }],
  });

  const result = await dispatchOrder(db, fakeAdmin, {
    orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
  });

  assert.deepEqual(result, { dispatched: false, mode: 'none' });
});

test('registered Abengourou mais current Agnibilékrou reste éligible', async () => {
  const borderCity = {
    ...ABENGOUROU,
    id: 'city-agnibilekrou',
    cityId: 'agnibilekrou',
    lat: CENTER.lat + 0.01,
    radiusKm: 2,
  };
  const { db, orderStore } = makeFakeDb({
    cities: [ABENGOUROU, borderCity],
    drivers: [{
      id: 'mobile-driver',
      isOnline: true,
      wallet: 500,
      lat: borderCity.lat,
      lng: borderCity.lng,
      currentCityId: 'agnibilekrou',
      registeredCityId: 'abengourou',
    }],
  });

  const result = await dispatchOrder(db, fakeAdmin, {
    orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
  });

  assert.deepEqual(result, { dispatched: true, mode: 'assigned' });
  assert.equal(orderStore.get('o1').driverId, 'mobile-driver');
});

test('une ville inactive refuse explicitement le dispatch', async () => {
  const inactive = { ...ABENGOUROU, isActive: false };
  const { db } = makeFakeDb({ cities: [inactive] });

  await assert.rejects(
    () => dispatchOrder(db, fakeAdmin, {
      orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
    }),
    (error) => error instanceof DispatchError && error.code === 'inactive-city',
  );
});

test('outside_service et unknown ne lancent aucune requête livreur', async () => {
  for (const status of ['outside_service', 'unknown']) {
    const { db } = makeFakeDb();
    await assert.rejects(
      () => rawDispatchOrder(db, fakeAdmin, {
        orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng,
        pickupCityId: 'abengourou', cityResolutionStatus: status,
      }),
      (error) => error instanceof DispatchError && error.code === 'unresolved-city',
    );
  }
});

test('la frontière inclut une ville dont le disque touche le rayon existant', async () => {
  const borderCity = {
    ...ABENGOUROU,
    id: 'city-border',
    cityId: 'border-city',
    lat: CENTER.lat + 0.015,
    radiusKm: 1,
  };
  const { db, orderStore } = makeFakeDb({
    cities: [ABENGOUROU, borderCity],
    drivers: [{
      id: 'border-driver',
      isOnline: true,
      wallet: 500,
      lat: borderCity.lat,
      lng: borderCity.lng,
      currentCityId: 'border-city',
      registeredCityId: 'abengourou',
    }],
  });

  await dispatchOrder(db, fakeAdmin, {
    orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
  });

  assert.equal(orderStore.get('o1').driverId, 'border-driver');
});

test('la limite de 50 livreurs est appliquée et journalisée', async () => {
  const drivers = Array.from({ length: DRIVER_QUERY_LIMIT + 1 }, (_, index) => ({
    id: `driver-${index}`,
    isOnline: true,
    wallet: 500,
    ...nearby(0.001 + index * 0.000001),
  }));
  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (message) => warnings.push(message);
  try {
    const { db } = makeFakeDb({ drivers });
    const result = await dispatchOrder(db, fakeAdmin, {
      orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
    });
    assert.equal(result.dispatched, true);
    assert.ok(warnings.some((message) => message.includes('driverLimit=50')));
  } finally {
    console.warn = originalWarn;
  }
});

test('à distance égale currentCity puis registeredCity départagent', async () => {
  const borderCity = {
    ...ABENGOUROU,
    id: 'city-border-tie',
    cityId: 'border-city',
    radiusKm: 25,
  };
  const point = nearby(0.001);
  const { db, orderUpdates } = makeFakeDb({
    cities: [ABENGOUROU, borderCity],
    drivers: [
      {
        id: 'registered-only', isOnline: true, wallet: 500,
        ...point, currentCityId: 'border-city', registeredCityId: 'abengourou',
      },
      {
        id: 'current-match', isOnline: true, wallet: 500,
        ...point, currentCityId: 'abengourou', registeredCityId: 'border-city',
      },
    ],
  });

  await dispatchOrder(db, fakeAdmin, {
    orderId: 'o1', lat: CENTER.lat, lng: CENTER.lng, budget: 500,
  });

  assert.deepEqual(
    orderUpdates[0].data.notifiedDriverIds.__arrayUnion,
    ['current-match', 'registered-only'],
  );
});
