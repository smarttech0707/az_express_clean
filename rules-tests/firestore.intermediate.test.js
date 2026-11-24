'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const { deleteField } = require('firebase/firestore');
const host = process.env.FIRESTORE_EMULATOR_HOST || '';
assert.match(host, /^(127\.0\.0\.1|localhost):\d+$/, 'Local emulator required');
const source = fs.readFileSync(path.join(__dirname, '../docs/firestore-production/cloud.firestore.9b96657d-bc14-4dc0-bc25-4e52671b6178.rules'), 'utf8');
const rules = fs.readFileSync(path.join(__dirname, '../firestore.intermediate.rules'), 'utf8');
let env;
const user = uid => env.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore();
const seed = fn => env.withSecurityRulesDisabled(ctx => fn(ctx.firestore()));
const order = (extra = {}) => ({ clientId: 'client', driverId: 'driver', sellerId: 'seller',
  sellerType: 'seller', pharmacieId: 'pharmacy', shoppingBudget: 1000,
  budget: 1000, isPaid: false, paymentMethod: 'cash', status: 'assigned', ...extra });

test.before(async () => {
  const [hostname, port] = host.split(':');
  env = await initializeTestEnvironment({ projectId: 'demo-lot74-rules',
    firestore: { host: hostname, port: Number(port), rules } });
});
test.beforeEach(() => env.clearFirestore());
test.after(async () => { if (env) await env.cleanup(); });

test('reference hash and exact preservation outside the two update clauses', () => {
  assert.equal(createHash('sha256').update(source).digest('hex'), '30f9e39e175d82c63becd0ed148a6930e1582ba0db0412a7b3f359467a02ae6a');
  function eraseUpdates(text) {
    for (const marker of ['    match /livreurs/{livreurId} {', '    match /orders/{orderId} {']) {
      const m = text.indexOf(marker);
      const helper = text.indexOf('      // LOT 7.4:', m);
      const update = text.indexOf('      allow update: if ', m);
      const start = helper >= 0 && helper < update ? helper : update;
      const end = text.indexOf('      allow delete: if isAdmin();', update);
      assert.ok(m >= 0 && start > m && end > start);
      text = text.slice(0, start) + '<UPDATE>\n' + text.slice(end);
    }
    return text;
  }
  assert.equal(eraseUpdates(rules), eraseUpdates(source));
});

for (const decrease of [false, true]) {
  for (const suspended of [true, false, null, deleteField()]) {
    test(`suspension is immutable even with a wallet debit: ${decrease}/${String(suspended)}`, async () => {
      await seed(db => db.doc('livreurs/driver').set({ wallet: 1000, isSuspended: suspended === true ? false : true }));
      await assertFails(user('driver').doc('livreurs/driver').update({ isSuspended: suspended, ...(decrease ? { wallet: 900 } : {}) }));
    });
  }
}
test('missing suspension cannot be introduced, but GPS, online and legitimate debit remain allowed', async () => {
  await seed(db => db.doc('livreurs/driver').set({ wallet: 1000 }));
  await assertFails(user('driver').doc('livreurs/driver').update({ isSuspended: null }));
  await assertSucceeds(user('driver').doc('livreurs/driver').update({ lat: 1, lng: 2, isOnline: true }));
  await assertSucceeds(user('driver').doc('livreurs/driver').update({ wallet: 900 }));
  await assertFails(user('driver').doc('livreurs/driver').update({ wallet: 1100 }));
});
test('authorized administrator retains suspension and financial correction privileges', async () => {
  await seed(async db => {
    await db.doc('admins/admin').set({ role: 'super', isActive: true });
    await db.doc('livreurs/driver').set({ wallet: 1000 });
    await db.doc('orders/order').set(order());
  });
  await assertSucceeds(user('admin').doc('livreurs/driver').update({ isSuspended: true }));
  await assertSucceeds(user('admin').doc('livreurs/driver').update({ isSuspended: false }));
  await assertSucceeds(user('admin').doc('orders/order').update({ sellerId: 'corrected' }));
  await assertFails(user('outsider').doc('livreurs/driver').update({ isSuspended: false }));
});

for (const role of ['driver', 'driver-seller', 'driver-client', 'driver-seller-client']) {
  for (const field of ['shoppingBudget', 'sellerId', 'sellerType', 'pharmacieId']) {
    test(`${role} cannot change, remove or add ${field} through another authorization`, async () => {
      const extra = { ...(role.includes('seller') ? { sellerId: 'driver' } : {}),
        ...(role.includes('client') ? { clientId: 'driver', status: 'pending' } : {}) };
      await seed(db => db.doc('orders/order').set(order(extra)));
      const ref = user('driver').doc('orders/order');
      const status = role.includes('client') ? 'cancelled' : role.includes('seller') ? 'assigned' : 'accepted';
      for (const value of [field === 'shoppingBudget' ? 1 : 'changed', null, deleteField()]) {
        await assertFails(ref.update({ [field]: value, status }));
      }
      // Preserve sellerId when it establishes the overlapping seller identity.
      if (field !== 'sellerId' || !role.includes('seller')) {
        await seed(db => db.doc('orders/order').update({ [field]: deleteField() }));
        await assertFails(ref.update({ [field]: null, status }));
      }
    });
  }
}
test('assigned driver transitions and metadata remain allowed; other drivers remain denied', async () => {
  await seed(db => db.doc('orders/order').set(order()));
  const ref = user('driver').doc('orders/order');
  await assertFails(user('outsider').doc('orders/order').update({ status: 'accepted' }));
  for (const status of ['accepted', 'picked_up', 'delivered']) await assertSucceeds(ref.update({ status }));
  await assertSucceeds(ref.update({ driverNote: 'fixture' }));
});
test('overlapping seller/client roles retain legitimate unchanged-finance operations', async () => {
  await seed(async db => {
    await db.doc('orders/seller').set(order({ sellerId: 'driver' }));
    await db.doc('orders/client').set(order({ clientId: 'driver', status: 'pending' }));
  });
  await assertSucceeds(user('driver').doc('orders/seller').update({ sellerStatus: 'ready' }));
  await assertSucceeds(user('driver').doc('orders/client').update({ status: 'cancelled' }));
});
test('old cash and wallet order contracts remain allowed without lastPaidOrderId', async () => {
  await seed(db => db.doc('clients/client').set({ wallet: 5000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
  const db = user('client');
  await assertSucceeds(db.doc('orders/cash').set({ clientId: 'client', budget: 1000, status: 'pending', isPaid: false, paymentMethod: 'cash' }));
  const batch = db.batch();
  batch.update(db.doc('clients/client'), { wallet: 4000 });
  batch.set(db.doc('orders/wallet'), { clientId: 'client', budget: 1000, shoppingBudget: 0, status: 'pending', isPaid: true, paymentMethod: 'wallet' });
  await assertSucceeds(batch.commit());
});
for (const method of ['cash', 'wallet']) {
  test(`legacy direct ${method} reservation remains allowed`, async () => {
    await seed(db => db.doc('clients/client').set({ wallet: 5000, fakeOrderCount: 0, cashOnDeliveryEnabled: true }));
    const db = user('client'), batch = db.batch();
    if (method === 'wallet') batch.update(db.doc('clients/client'), { wallet: 4000 });
    batch.set(db.doc('event_reservations/reservation'), { clientId: 'client', status: 'pending', items: [{ offerId: 'fixture' }],
      totalAmount: 1000, paymentMethod: method, isPaid: method === 'wallet' });
    await assertSucceeds(batch.commit());
  });
}
test('legacy public credential writes remain unchanged at this intermediate stage', async () => {
  await seed(db => db.doc('admins/admin').set({ role: 'super', isActive: true }));
  const ref = user('admin').doc('service_providers/provider');
  await assertSucceeds(ref.set({ status: 'pending', artisanPin: 'fixture-only' }));
  await assertSucceeds(ref.update({ artisanPin: 'fixture-changed', status: 'approved' }));
  await assertSucceeds(ref.delete());
});
