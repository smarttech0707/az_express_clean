'use strict';

// Master Prompt 117 — trackOrder (delivery.js) enrichi pour renvoyer le nom
// réel du livreur assigné (lecture ciblée livreurs/{driverId}), condition
// nécessaire pour que responseBuilder.js puisse remplir `payload.driver`
// avec une vraie donnée plutôt qu'une valeur devinée/absente.

const test = require('node:test');
const assert = require('node:assert/strict');
const { trackOrder } = require('../azia/tools/delivery');

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  function makeCollection(name) {
    return {
      doc: (id) => ({
        get: async () => ({ exists: store.has(`${name}/${id}`), data: () => store.get(`${name}/${id}`) }),
      }),
      where(field, _op, value) {
        const filtered = [...store.entries()]
          .filter(([k]) => k.startsWith(`${name}/`))
          .filter(([, data]) => data[field] === value);
        return {
          orderBy: () => ({
            limit: () => ({
              get: async () => ({ docs: filtered.map(([k, data]) => ({ id: k.split('/').pop(), data: () => data })) }),
            }),
          }),
        };
      },
    };
  }
  return { db: { collection: (name) => makeCollection(name) } };
}

test('track_order: enriches the order with the real driver name when driverId is present', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'u1', status: 'accepted', driverId: 'd1', budget: 700 },
    'livreurs/d1': { name: 'Jean Kouassi' },
  });
  const tool = trackOrder({ db });

  const result = await tool.handler('u1', { orderId: 'o1' });
  assert.equal(result.found, true);
  assert.equal(result.orders[0].driverName, 'Jean Kouassi');
});

test('track_order: driverName stays null when no driver is assigned yet (never invented)', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'u1', status: 'pending', budget: 700 },
  });
  const tool = trackOrder({ db });

  const result = await tool.handler('u1', { orderId: 'o1' });
  assert.equal(result.orders[0].driverId, null);
  assert.equal(result.orders[0].driverName, null);
});

test('track_order: driverName stays null when the driver document is missing (dangling driverId, no crash)', async () => {
  const { db } = makeFakeDb({
    'orders/o1': { clientId: 'u1', status: 'accepted', driverId: 'ghost', budget: 700 },
  });
  const tool = trackOrder({ db });

  const result = await tool.handler('u1', { orderId: 'o1' });
  assert.equal(result.orders[0].driverId, 'ghost');
  assert.equal(result.orders[0].driverName, null);
});
