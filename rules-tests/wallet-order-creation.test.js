// Création de commande payée par wallet — create_order.dart et
// eau_boissons_page.dart (correctif 2026-10-27).
//
// Ces tests exécutent, contre l'émulateur Firestore et les VRAIES règles, la
// même transaction que les deux écrans Flutter : lecture du solde, contrôle de
// solde, débit + `lastPaidOrderId`, création de la commande. Les formules de
// montant (buildCreateOrder / buildEauBoissons) reproduisent le code Dart ;
// ils ne testent pas l'interface elle-même (aucun test d'écran Flutter).
//
// Exécution : npx firebase emulators:exec --only firestore \
//   "node --test rules-tests/wallet-order-creation.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertFails,
} = require('@firebase/rules-unit-testing');

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'az-express-wallet-orders',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
  });
});
test.after(async () => { await testEnv.cleanup(); });
test.beforeEach(async () => { await testEnv.clearFirestore(); });

function asClient(uid) {
  return testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore();
}
async function seedWallet(wallet) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('clients/c1').set({
      wallet, fakeOrderCount: 0, cashOnDeliveryEnabled: true,
    });
  });
}
async function read(p) {
  let out;
  await testEnv.withSecurityRulesDisabled(async (ctx) => { out = await ctx.firestore().doc(p).get(); });
  return out;
}

// ── create_order.dart ───────────────────────────────────────────────────────
// totalAmount = deliveryFee + shoppingBudget ; budget = deliveryFee.
async function createOrderScreen({ deliveryFee, shoppingBudget, payment, orderId }) {
  const db = asClient('c1');
  const totalAmount = deliveryFee + shoppingBudget;
  const order = {
    clientId: 'c1', budget: deliveryFee, shoppingBudget, status: 'pending',
    type: 'shopping', paymentMethod: payment, isPaid: payment === 'wallet',
  };
  if (payment !== 'wallet') {
    await db.doc(`orders/${orderId}`).set(order);
    return;
  }
  const clientRef = db.doc('clients/c1');
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(clientRef);
    const balance = snap.data().wallet;
    if (balance < totalAmount) throw new Error('SOLDE_INSUFFISANT');
    tx.update(clientRef, { wallet: balance - totalAmount, lastPaidOrderId: orderId });
    tx.set(db.doc(`orders/${orderId}`), order);
  });
}

// ── eau_boissons_page.dart ──────────────────────────────────────────────────
// totalToPay = totalPrice + deliveryFee ; budget = deliveryFee ;
// shoppingBudget = totalPrice.
async function eauBoissonsScreen({ totalPrice, deliveryFee, payment, orderId, budgetOverride }) {
  const db = asClient('c1');
  const totalToPay = totalPrice + deliveryFee;
  const order = {
    clientId: 'c1', budget: budgetOverride ?? deliveryFee, shoppingBudget: totalPrice,
    status: 'pending', type: 'eau_boissons', paymentMethod: payment, isPaid: payment === 'wallet',
  };
  if (payment !== 'wallet') {
    await db.doc(`orders/${orderId}`).set(order);
    return;
  }
  const clientRef = db.doc('clients/c1');
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(clientRef);
    const wallet = snap.data().wallet;
    if (wallet < totalToPay) throw new Error('SOLDE_INSUFFISANT');
    tx.update(clientRef, { wallet: wallet - totalToPay, lastPaidOrderId: orderId });
    tx.set(db.doc(`orders/${orderId}`), order);
  });
}

test('1. create_order wallet avec budget articles : débit = livraison + articles, commande créée', async () => {
  await seedWallet(10000);
  await createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'o1' });
  assert.equal((await read('clients/c1')).data().wallet, 7500);
  assert.equal((await read('clients/c1')).data().lastPaidOrderId, 'o1');
  const o = (await read('orders/o1')).data();
  assert.equal(o.budget + o.shoppingBudget, 2500);
  assert.equal(o.isPaid, true);
});

test('2. create_order wallet sans budget articles (shoppingBudget = 0) : débit = livraison', async () => {
  await seedWallet(10000);
  await createOrderScreen({ deliveryFee: 1000, shoppingBudget: 0, payment: 'wallet', orderId: 'o2' });
  assert.equal((await read('clients/c1')).data().wallet, 9000);
  assert.equal((await read('orders/o2')).exists, true);
});

test('3. create_order wallet solde insuffisant : refus, aucun débit, aucune commande', async () => {
  await seedWallet(2000);
  await assert.rejects(
    createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'o3' }),
    /SOLDE_INSUFFISANT/);
  assert.equal((await read('clients/c1')).data().wallet, 2000);
  assert.equal((await read('orders/o3')).exists, false);
});

test('3b. ancien comportement (débit = livraison seule alors que shoppingBudget > 0) reste refusé par les règles', async () => {
  await seedWallet(10000);
  const db = asClient('c1');
  await assertFails((async () => {
    await db.runTransaction(async (tx) => {
      const ref = db.doc('clients/c1');
      const snap = await tx.get(ref);
      tx.update(ref, { wallet: snap.data().wallet - 1000, lastPaidOrderId: 'o3b' });
      tx.set(db.doc('orders/o3b'), {
        clientId: 'c1', budget: 1000, shoppingBudget: 1500, status: 'pending',
        paymentMethod: 'wallet', isPaid: true,
      });
    });
  })());
  assert.equal((await read('clients/c1')).data().wallet, 10000);
});

test('4. create_order wallet solde exactement égal au total : accepté, solde 0', async () => {
  await seedWallet(2500);
  await createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'o4' });
  assert.equal((await read('clients/c1')).data().wallet, 0);
  assert.equal((await read('orders/o4')).exists, true);
});

test('5. paiement cash (create_order, avec budget articles) : commande créée, wallet intact', async () => {
  await seedWallet(300);
  await createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'cash', orderId: 'o5' });
  assert.equal((await read('clients/c1')).data().wallet, 300);
  const o = (await read('orders/o5')).data();
  assert.equal(o.isPaid, false);
  assert.equal(o.paymentMethod, 'cash');
});

test('5b. paiement cash (eau et boissons, frais 700) : commande créée, wallet intact', async () => {
  await seedWallet(0);
  await eauBoissonsScreen({ totalPrice: 3000, deliveryFee: 700, payment: 'cash', orderId: 'o5b' });
  assert.equal((await read('clients/c1')).data().wallet, 0);
  const o = (await read('orders/o5b')).data();
  assert.equal(o.budget, 700);
  assert.equal(o.isPaid, false);
});

test('6. eau et boissons wallet, frais 500 : débit 3500, budget 500', async () => {
  await seedWallet(10000);
  await eauBoissonsScreen({ totalPrice: 3000, deliveryFee: 500, payment: 'wallet', orderId: 'o6' });
  assert.equal((await read('clients/c1')).data().wallet, 6500);
  const o = (await read('orders/o6')).data();
  assert.equal(o.budget, 500);
  assert.equal(o.budget + o.shoppingBudget, 3500);
});

test('7. eau et boissons wallet, frais 700 (≠ 500) : accepté, budget enregistré = 700, débit 3700', async () => {
  await seedWallet(10000);
  await eauBoissonsScreen({ totalPrice: 3000, deliveryFee: 700, payment: 'wallet', orderId: 'o7' });
  assert.equal((await read('clients/c1')).data().wallet, 6300);
  const o = (await read('orders/o7')).data();
  assert.equal(o.budget, 700);
  assert.equal(o.budget + o.shoppingBudget, 3700);
});

test('7b. ancien code eau et boissons (budget codé en dur 500, frais 700) reste refusé par les règles', async () => {
  await seedWallet(10000);
  await assertFails(eauBoissonsScreen({
    totalPrice: 3000, deliveryFee: 700, payment: 'wallet', orderId: 'o7b', budgetOverride: 500,
  }));
  assert.equal((await read('clients/c1')).data().wallet, 10000);
});

test('8. transaction refusée : aucun débit partiel, aucune commande', async () => {
  await seedWallet(10000);
  const db = asClient('c1');
  await assertFails((async () => {
    await db.runTransaction(async (tx) => {
      const ref = db.doc('clients/c1');
      const snap = await tx.get(ref);
      tx.update(ref, { wallet: snap.data().wallet - 2500, lastPaidOrderId: 'o8' });
      // commande incohérente (budget < 500) -> règle refuse tout le lot
      tx.set(db.doc('orders/o8'), {
        clientId: 'c1', budget: 100, shoppingBudget: 2400, status: 'pending',
        paymentMethod: 'wallet', isPaid: true,
      });
    });
  })());
  assert.equal((await read('clients/c1')).data().wallet, 10000);
  assert.equal((await read('orders/o8')).exists, false);
});

test('9a. double débit : même commande rejouée, un seul débit', async () => {
  await seedWallet(10000);
  await createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'o9' });
  await assert.rejects(
    createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'o9' }));
  assert.equal((await read('clients/c1')).data().wallet, 7500);
});

test('9b. double débit : deux transactions réellement concurrentes sur un solde pour une seule commande', async () => {
  await seedWallet(2500);
  const results = await Promise.allSettled([
    createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'oA' }),
    createOrderScreen({ deliveryFee: 1000, shoppingBudget: 1500, payment: 'wallet', orderId: 'oB' }),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal((await read('clients/c1')).data().wallet, 0);
});

test('9c. double débit : un même débit ne valide pas deux commandes dans un même lot', async () => {
  await seedWallet(10000);
  const db = asClient('c1');
  const batch = db.batch();
  batch.update(db.doc('clients/c1'), { wallet: 7500, lastPaidOrderId: 'oX' });
  for (const id of ['oX', 'oY']) {
    batch.set(db.doc(`orders/${id}`), {
      clientId: 'c1', budget: 1000, shoppingBudget: 1500, status: 'pending',
      paymentMethod: 'wallet', isPaid: true,
    });
  }
  await assertFails(batch.commit());
  assert.equal((await read('clients/c1')).data().wallet, 10000);
});
