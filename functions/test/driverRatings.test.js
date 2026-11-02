'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb } = require('./lifecycleFake');
const { isValidRating, nextAverage, shouldProcess, applyDriverRating } = require('../driverRatings');

function fixture(order = {}, driver = {}) {
  return fakeDb({
    'orders/o1': { status: 'delivered', driverId: 'd1', clientId: 'c1', budget: 1500, rating: 5, ...order },
    'livreurs/d1': { wallet: 700, avgRating: 4, ratingCount: 3, ...driver },
  });
}

test('seules les notes entières 1..5 sont valides', () => {
  for (const ok of [1, 2, 3, 4, 5]) assert.equal(isValidRating(ok), true);
  for (const bad of [0, 6, -1, 4.5, '5', null, undefined, NaN, Infinity]) {
    assert.equal(isValidRating(bad), false, String(bad));
  }
});

test('moyenne : même arrondi à 1 décimale que l\'ancien calcul client', () => {
  assert.deepEqual(nextAverage(4, 3, 5), { avgRating: 4.3, ratingCount: 4 });
  assert.deepEqual(nextAverage(0, 0, 3), { avgRating: 3, ratingCount: 1 });
  assert.deepEqual(nextAverage(NaN, NaN, 4), { avgRating: 4, ratingCount: 1 });
});

test('la première note valide met à jour le livreur et pose le marqueur', async () => {
  const { db, store } = fixture();
  const result = await applyDriverRating({ db, orderId: 'o1' });
  assert.deepEqual(result, {
    applied: true, driverId: 'd1', previous: { avgRating: 4, ratingCount: 3 },
    avgRating: 4.3, ratingCount: 4,
  });
  assert.equal(store.get('livreurs/d1').avgRating, 4.3);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
  assert.equal(store.get('orders/o1').driverRatingApplied, true);
});

test('ne touche ni au wallet, ni au statut, ni au montant', async () => {
  const { db, store } = fixture();
  await applyDriverRating({ db, orderId: 'o1' });
  assert.equal(store.get('livreurs/d1').wallet, 700);
  assert.equal(store.get('orders/o1').status, 'delivered');
  assert.equal(store.get('orders/o1').budget, 1500);
});

test('idempotent : un second passage ou un retry ne recompte pas', async () => {
  const { db, store, writes } = fixture();
  await applyDriverRating({ db, orderId: 'o1' });
  const before = writes();
  const again = await applyDriverRating({ db, orderId: 'o1' });
  assert.deepEqual(again, { applied: false, reason: 'not-eligible' });
  assert.equal(writes(), before);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
});

test('une note modifiée après coup n\'est pas recomptée', async () => {
  const { db, store } = fixture();
  await applyDriverRating({ db, orderId: 'o1' });
  store.set('orders/o1', { ...store.get('orders/o1'), rating: 1 });
  await applyDriverRating({ db, orderId: 'o1' });
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
  assert.equal(store.get('livreurs/d1').avgRating, 4.3);
});

test('notes invalides ignorées (0, 6, décimale, texte)', async () => {
  for (const rating of [0, 6, 4.5, '5', null]) {
    const { db, store, writes } = fixture({ rating });
    const result = await applyDriverRating({ db, orderId: 'o1' });
    assert.equal(result.applied, false, String(rating));
    assert.equal(writes(), 0);
    assert.equal(store.get('livreurs/d1').ratingCount, 3);
  }
});

test('une note invalide corrigée ensuite est comptée une fois', async () => {
  const { db, store } = fixture({ rating: 9 });
  assert.equal((await applyDriverRating({ db, orderId: 'o1' })).applied, false);
  store.set('orders/o1', { ...store.get('orders/o1'), rating: 4 });
  const result = await applyDriverRating({ db, orderId: 'o1' });
  assert.equal(result.applied, true);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
});

test('commande non livrée, sans livreur, ou livreur absent : rien n\'est écrit', async () => {
  for (const order of [{ status: 'accepted' }, { status: 'cancelled' }, { driverId: null }, { driverId: undefined }]) {
    const { db, writes } = fixture(order);
    const result = await applyDriverRating({ db, orderId: 'o1' });
    assert.equal(result.applied, false, JSON.stringify(order));
    assert.equal(writes(), 0);
  }
  const missingDriver = fakeDb({ 'orders/o1': { status: 'delivered', driverId: 'ghost', rating: 5 } });
  assert.deepEqual(await applyDriverRating({ db: missingDriver.db, orderId: 'o1' }),
    { applied: false, reason: 'driver-missing' });
  assert.equal(missingDriver.writes(), 0);
});

test('commande inexistante : sans erreur', async () => {
  const { db } = fakeDb({});
  assert.deepEqual(await applyDriverRating({ db, orderId: 'nope' }),
    { applied: false, reason: 'order-missing' });
});

test('shouldProcess : pré-filtre de l\'événement', () => {
  assert.equal(shouldProcess({ status: 'delivered', driverId: 'd', rating: 3 }), true);
  assert.equal(shouldProcess({ status: 'delivered', driverId: 'd', rating: 3, driverRatingApplied: true }), false);
  assert.equal(shouldProcess({ status: 'delivered', driverId: 'd' }), false);
  assert.equal(shouldProcess(undefined), false);
});

test('deux notes successives sur deux commandes cumulent correctement', async () => {
  const { db, store } = fakeDb({
    'orders/o1': { status: 'delivered', driverId: 'd1', rating: 5 },
    'orders/o2': { status: 'delivered', driverId: 'd1', rating: 3 },
    'livreurs/d1': { avgRating: 0, ratingCount: 0 },
  });
  await applyDriverRating({ db, orderId: 'o1' });
  await applyDriverRating({ db, orderId: 'o2' });
  assert.equal(store.get('livreurs/d1').ratingCount, 2);
  assert.equal(store.get('livreurs/d1').avgRating, 4);
});

test('concurrence : dix exécutions simultanées sur la même commande ne comptent qu\'une note', async () => {
  const { db, store } = fixture();
  const results = await Promise.all(
    Array.from({ length: 10 }, () => applyDriverRating({ db, orderId: 'o1' })));
  assert.equal(results.filter(r => r.applied).length, 1);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
  assert.equal(store.get('livreurs/d1').avgRating, 4.3);
  assert.equal(store.get('orders/o1').driverRatingApplied, true);
});

test('concurrence : plusieurs commandes du même livreur notées en même temps restent cohérentes', async () => {
  const orders = {};
  for (let i = 1; i <= 5; i++) orders[`orders/o${i}`] = { status: 'delivered', driverId: 'd1', rating: i };
  const { db, store } = fakeDb({ ...orders, 'livreurs/d1': { avgRating: 0, ratingCount: 0 } });
  await Promise.all([1, 2, 3, 4, 5].flatMap(i => [
    applyDriverRating({ db, orderId: `o${i}` }),
    applyDriverRating({ db, orderId: `o${i}` }),
  ]));
  assert.equal(store.get('livreurs/d1').ratingCount, 5);
  assert.equal(store.get('livreurs/d1').avgRating, 3);
});

test('la fonction ne touche jamais aux champs financiers ni au statut (clés écrites)', async () => {
  const { db, store } = fixture({ commission: 150, isPaid: true });
  const before = JSON.stringify({ ...store.get('orders/o1'), driverRatingApplied: undefined });
  await applyDriverRating({ db, orderId: 'o1' });
  const after = JSON.stringify({ ...store.get('orders/o1'), driverRatingApplied: undefined });
  assert.equal(after, before);
  assert.equal(store.get('livreurs/d1').wallet, 700);
});

test('commande notée AVANT le module (ancien client) : jamais recomptée', async () => {
  // Rating déjà présent avant la mise à jour, pas de marqueur : sa note est
  // déjà dans la moyenne du livreur.
  const { db, store, writes } = fixture();
  const legacy = { status: 'delivered', driverId: 'd1', rating: 5 };
  const result = await applyDriverRating({ db, orderId: 'o1', before: legacy });
  assert.deepEqual(result, { applied: false, reason: 'not-eligible' });
  assert.equal(writes(), 0);
  assert.equal(store.get('livreurs/d1').ratingCount, 3);
  assert.equal(shouldProcess(legacy, legacy), false);
});

test('transition absent → valide : comptée ; le marqueur posé par la fonction ne relance rien', async () => {
  const { db, store } = fixture();
  const before = { status: 'delivered', driverId: 'd1' };
  assert.equal(shouldProcess({ ...before, rating: 4 }, before), true);
  assert.equal((await applyDriverRating({ db, orderId: 'o1', before })).applied, true);
  // Événement déclenché par l'écriture du marqueur : before.rating est valide.
  const after = store.get('orders/o1');
  assert.equal(shouldProcess(after, { ...after, driverRatingApplied: undefined }), false);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
});

test('échec avant validation : rien d\'écrit, la nouvelle tentative compte une seule fois', async () => {
  const { db, store, writes } = fixture();
  let failures = 1;
  const flaky = {
    collection: db.collection,
    runTransaction: async (fn, opts) => {
      if (failures-- > 0) {
        // la transaction lit puis échoue avant le commit (contention, panne…)
        await fn({ get: r => r.get(), update() {} });
        throw new Error('ABORTED');
      }
      return db.runTransaction(fn, opts);
    },
  };
  await assert.rejects(applyDriverRating({ db: flaky, orderId: 'o1' }), /ABORTED/);
  assert.equal(writes(), 0);
  assert.equal(store.get('livreurs/d1').ratingCount, 3);
  assert.equal((await applyDriverRating({ db: flaky, orderId: 'o1' })).applied, true);
  assert.equal((await applyDriverRating({ db: flaky, orderId: 'o1' })).applied, false);
  assert.equal(store.get('livreurs/d1').ratingCount, 4);
});
