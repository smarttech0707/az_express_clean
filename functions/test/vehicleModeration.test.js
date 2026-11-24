'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildModerateVehicleEntity } = require('../vehicleModeration');

function harness({ exists = true, sellerType = 'professional', adminAllowed = true } = {}) {
  const writes = [];
  const refs = new Map();
  const db = {
    collection(name) {
      return { doc(id = 'audit') { const ref = { name, id }; refs.set(`${name}/${id}`, ref); return ref; } };
    },
    async runTransaction(callback) {
      await callback({
        get: async () => ({ exists, data: () => ({ sellerType }) }),
        update: (ref, data) => writes.push(['update', ref, data]),
        set: (ref, data) => writes.push(['set', ref, data]),
        delete: (ref) => writes.push(['delete', ref]),
      });
    },
  };
  const callable = buildModerateVehicleEntity({
    db,
    admin: { firestore: { FieldValue: { serverTimestamp: () => 'SERVER_TIME', delete: () => 'DELETE' } } },
    requireAdminPermission: async () => {
      if (!adminAllowed) throw new Error('denied');
    },
    HttpsError: class extends Error { constructor(code, message) { super(message); this.code = code; } },
  });
  return { callable, writes };
}

test('suspension annonce écrit le statut et un audit atomique', async () => {
  const h = harness();
  await h.callable({ auth: { uid: 'admin1' }, data: {
    targetType: 'listing', targetId: 'v1', action: 'suspend', reason: 'Fraude',
  } });
  assert.equal(h.writes[0][2].status, 'suspended');
  assert.equal(h.writes[1][2].action, 'vehicle_listing_suspend');
});

test('non admin refusé et professionnel obligatoire pour vérifier', async () => {
  await assert.rejects(() => harness({ adminAllowed: false }).callable({
    auth: { uid: 'u1' }, data: { targetType: 'listing', targetId: 'v1', action: 'restore' },
  }));
  await assert.rejects(() => harness({ sellerType: 'individual' }).callable({
    auth: { uid: 'admin1' }, data: { targetType: 'verification', targetId: 'u1', action: 'verify' },
  }), (error) => error.code === 'failed-precondition');
});
