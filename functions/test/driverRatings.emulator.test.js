'use strict';

// Intégration contre l'émulateur Firestore (jamais la production) : la
// concurrence réelle des transactions, que le faux Firestore ne simule pas.
//   npx firebase emulators:exec --only firestore --project demo-driver-ratings \
//     "node --test functions/test/driverRatings.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const { applyDriverRating } = require('../driverRatings');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let db;
test.before(() => {
  if (!emulated) return;
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'demo-driver-ratings' });
  db = admin.firestore();
});

// La fonction est déclarée `retry: true` : une transaction annulée par la
// contention (ABORTED) est rejouée par la plateforme. On rejoue de même ici ;
// l'idempotence garantit que le résultat final est exact.
async function withRetry(fn, attempts = 15) {
  for (let i = 1; ; i++) {
    try { return await fn(); } catch (e) {
      // L'émulateur (pas Firestore de production) répond parfois INVALID_ARGUMENT « Transaction is
      // invalid or closed » sous forte contention : même cause qu'ABORTED, rejouable de la même façon.
      const emulatorClosedTx = e.code === 3 && /Transaction is invalid or closed/.test(String(e.message));
      if (i >= attempts || !([10, 4].includes(e.code) || emulatorClosedTx)) throw e; // ABORTED, DEADLINE
    }
  }
}

const seed = async (suffix, orders, driver) => {
  const driverId = `d-${suffix}`;
  await db.doc(`livreurs/${driverId}`).set({ wallet: 700, avgRating: 4, ratingCount: 3, ...driver });
  for (const [id, data] of Object.entries(orders)) {
    await db.doc(`orders/${id}-${suffix}`).set({
      status: 'delivered', driverId, clientId: 'c1', budget: 1500, ...data,
    });
  }
  return driverId;
};

test('vingt exécutions simultanées sur la même commande : une seule note comptée', options, async () => {
  const driverId = await seed('same', { o: { rating: 5 } });
  const results = await Promise.all(
    Array.from({ length: 20 }, () => withRetry(() => applyDriverRating({ db, orderId: 'o-same' }))));
  assert.equal(results.filter((r) => r.applied).length, 1);
  const driver = (await db.doc(`livreurs/${driverId}`).get()).data();
  assert.equal(driver.ratingCount, 4);
  assert.equal(driver.avgRating, 4.3);
  assert.equal(driver.wallet, 700);
  const order = (await db.doc('orders/o-same').get()).data();
  assert.equal(order.driverRatingApplied, true);
  assert.equal(order.status, 'delivered');
  assert.equal(order.budget, 1500);
});

test('dix commandes du même livreur notées en même temps : compteur exact, sans perte', options, async () => {
  const orders = {};
  for (let i = 1; i <= 10; i++) orders[`o${i}`] = { rating: 5 };
  const driverId = await seed('many', orders, { avgRating: 0, ratingCount: 0 });
  await Promise.all(Object.keys(orders).flatMap((id) => [
    withRetry(() => applyDriverRating({ db, orderId: `${id}-many` })),
    withRetry(() => applyDriverRating({ db, orderId: `${id}-many` })),
  ]));
  const driver = (await db.doc(`livreurs/${driverId}`).get()).data();
  assert.equal(driver.ratingCount, 10);
  assert.equal(driver.avgRating, 5);
});

test('commande notée avant le module : jamais recomptée', options, async () => {
  const driverId = await seed('legacy', { o: { rating: 5 } });
  const before = { status: 'delivered', driverId, rating: 5 };
  const result = await applyDriverRating({ db, orderId: 'o-legacy', before });
  assert.equal(result.applied, false);
  assert.equal((await db.doc(`livreurs/${driverId}`).get()).data().ratingCount, 3);
});
