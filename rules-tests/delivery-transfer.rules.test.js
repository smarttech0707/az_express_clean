// Transferts de livraison : lecture restreinte aux acteurs, écriture serveur
// uniquement ; champs de transfert/retenue verrouillés pour le livreur.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-express-delivery-transfer',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => { await env.cleanup(); });

const password = { firebase: { sign_in_provider: 'password' } };
const as = (uid) => env.authenticatedContext(uid, password).firestore();

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('delivery_transfers/o1_1').set({
      orderId: 'o1', fromDriverId: 'dA', toDriverId: 'dB', candidateIds: ['dB', 'dC'], status: 'accepted',
    });
    await db.doc('transfer_settlements/o1').set({ orderId: 'o1', driverIds: ['dA', 'dB'], status: 'pending_review' });
    await db.doc('orders/o1').set({
      clientId: 'c1', driverId: 'dA', status: 'picked_up', budget: 500, isPaid: false, paymentMethod: 'cash',
    });
  });
});

test('lecture : acteurs et admin seulement', async () => {
  for (const uid of ['dA', 'dB', 'dC', 'root']) await assertSucceeds(as(uid).doc('delivery_transfers/o1_1').get());
  for (const uid of ['dX', 'c1']) await assertFails(as(uid).doc('delivery_transfers/o1_1').get());
  await assertFails(env.unauthenticatedContext().firestore().doc('delivery_transfers/o1_1').get());
});

test('écriture interdite à tous, y compris livreur et admin', async () => {
  for (const uid of ['dA', 'dB', 'root']) {
    await assertFails(as(uid).doc('delivery_transfers/o1_1').update({ status: 'completed' }));
    await assertFails(as(uid).doc('delivery_transfers/new').set({ orderId: 'o1' }));
  }
});

test('le livreur ne peut pas toucher aux champs de transfert ni de retenue', async () => {
  for (const patch of [
    { settlementHold: true }, { settlementStatus: 'paid' }, { heldDriverEarning: 1 },
    { transferAttempts: 0 }, { previousDriverId: 'dA' }, { lastTransferAt: new Date() },
    { activeTransferId: 'x' }, { driverId: 'dB' }, { driverAssignmentVersion: 9 },
  ]) {
    await assertFails(as('dA').doc('orders/o1').update(patch));
  }
});

test('transfer_settlements : lecture super-admin et livreurs concernés seulement, écriture interdite', async () => {
  for (const uid of ['root', 'dA', 'dB']) await assertSucceeds(as(uid).doc('transfer_settlements/o1').get());
  for (const uid of ['dX', 'c1']) await assertFails(as(uid).doc('transfer_settlements/o1').get());
  await assertFails(env.unauthenticatedContext().firestore().doc('transfer_settlements/o1').get());
  for (const uid of ['dA', 'dB', 'root', 'c1']) {
    await assertFails(as(uid).doc('transfer_settlements/o1').update({ status: 'settled' }));
    await assertFails(as(uid).doc('transfer_settlements/new').set({ driverIds: [uid] }));
    await assertFails(as(uid).doc('transfer_settlements/o1').delete());
  }
});

test('un livreur ne peut pas libérer lui-même la retenue d’une commande', async () => {
  await assertFails(as('dA').doc('orders/o1').update({ settlementHold: false }));
  await assertFails(as('dA').doc('orders/o1').update({ settlementStatus: 'settled' }));
});
