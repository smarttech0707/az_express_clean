// La commission AZ et les transferts sont écrits par le serveur uniquement :
// un livreur ne peut pas réécrire le payeur, le montant ni l'historique.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

let env;
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'az-express-driver-commission',
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
    await db.doc('livreurs/d1').set({ wallet: 500, isOnline: true });
    await db.doc('orders/o1').set({
      clientId: 'c1', driverId: 'd1', status: 'accepted', budget: 500, isPaid: false,
      paymentMethod: 'cash', commissionAmount: 100, commissionPayerId: 'd1',
      commissionTxId: 'commission_o1_d1', commissionStatus: 'charged',
    });
    await db.doc('orders/assigned1').set({
      clientId: 'c1', driverId: 'd1', status: 'assigned', budget: 500, isPaid: false, paymentMethod: 'cash',
    });
  });
});

test('un livreur ne peut pas modifier les champs de commission de sa course', async () => {
  for (const patch of [
    { commissionAmount: 0 }, { commissionPayerId: 'autre' }, { commissionStatus: 'refunded' },
    { commissionTxId: null }, { driverHistory: [] }, { activeTransferId: 't1' }, { transferCount: 0 },
    { acceptedAt: new Date() }, { excludedDriverIds: [] }, { requeuedAt: new Date() },
  ]) {
    await assertFails(as('d1').doc('orders/o1').update(patch));
  }
});

test('le livreur ne peut pas s’attribuer une commission en acceptant directement', async () => {
  await assertFails(as('d1').doc('orders/assigned1').update({
    status: 'accepted', commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 0,
  }));
});

test('transition légitime inchangée (picked_up sur une course classique)', async () => {
  await assertSucceeds(as('d1').doc('orders/o1').update({ status: 'picked_up' }));
});
