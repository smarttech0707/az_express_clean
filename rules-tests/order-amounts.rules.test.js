// Montants explicites Marketplace / Boutique (amountsVersion == 1) : posés par
// le serveur uniquement. Sans ce verrou, un client pourrait créer une commande
// avec deliveryFeePaid:true (livreur complice crédité de frais jamais payés), ou
// un livreur / vendeur réécrire les montants d'une commande existante.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

const explicit = {
  clientId: 'c1', driverId: 'd1', sellerId: 's1', sellerType: 'seller', status: 'accepted',
  paymentMethod: 'wallet', isPaid: true, amountsVersion: 1, productAmount: 5000,
  deliveryFee: 500, totalAmount: 5500, budget: 500, itemsAmount: 5000, deliveryFeePaid: true,
};

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('sellers/s1').set({ isActive: true, isApproved: true, status: 'active' });
    await db.doc('orders/ex1').set(explicit);
    // Commande historique (boulangerie) : écrit déjà ses propres montants, sans amountsVersion.
    await db.doc('orders/legacy1').set({
      clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'cash', isPaid: false,
      budget: 500, itemsAmount: 2000, deliveryFee: 500, totalAmount: 2500,
    });
  });
  return e;
}

test('le livreur ne peut réécrire aucun montant d’une commande à montants explicites', async () => {
  const e = await env('az-amounts-driver');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    for (const patch of [
      { deliveryFee: 5000 }, { totalAmount: 1 }, { productAmount: 1 }, { itemsAmount: 1 },
      { deliveryFeePaid: false }, { amountsVersion: 2 }, { cashBreakdown: { driverNet: 99999 } },
    ]) {
      await assertFails(db.doc('orders/ex1').update({ ...patch, status: 'picked_up' }));
    }
    // Transition légitime inchangée.
    await assertSucceeds(db.doc('orders/ex1').update({ status: 'picked_up' }));
  } finally { await e.cleanup(); }
});

test('la commande historique garde ses champs de montants modifiables comme avant (pas de régression)', async () => {
  const e = await env('az-amounts-legacy');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertSucceeds(db.doc('orders/legacy1').update({ totalAmount: 2500 }));
  } finally { await e.cleanup(); }
});

test('un client ne peut pas créer une commande avec les marqueurs réservés au serveur', async () => {
  const e = await env('az-amounts-create');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    const base = {
      clientId: 'c1', budget: 500, isPaid: false, paymentMethod: 'cash', status: 'pending',
      type: 'livraison', description: 'x',
    };
    // Témoin : sans les marqueurs réservés, la même commande est acceptée —
    // les refus ci-dessous viennent donc bien de ces champs.
    await assertSucceeds(db.doc('orders/control').set(base));
    for (const extra of [{ deliveryFeePaid: true }, { amountsVersion: 1 }, { cashBreakdown: { driverNet: 1 } },
      { deliveryFeeHold: { amount: 500, status: 'pending_admin_review', driverId: 'd1' } }, { adminReview: { byUid: 'x' } }]) {
      await assertFails(db.doc(`orders/new_${Object.keys(extra)[0]}`).set({ ...base, ...extra }));
    }
  } finally { await e.cleanup(); }
});

test('ni le livreur ni le client ne peuvent poser ou modifier une retenue de frais / un examen administratif', async () => {
  const e = await env('az-amounts-hold');
  try {
    await e.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('orders/pend1').set({ clientId: 'c1', status: 'pending', paymentMethod: 'cash', isPaid: false, budget: 500 });
      await db.doc('orders/pend2').set({ clientId: 'c1', status: 'pending', paymentMethod: 'cash', isPaid: false, budget: 500 });
    });
    const fake = { deliveryFeeHold: { amount: 500, status: 'pending_admin_review', driverId: 'd1' } };
    const driver = e.authenticatedContext('d1', password).firestore();
    await assertFails(driver.doc('orders/ex1').update({ ...fake, status: 'picked_up' }));
    await assertFails(driver.doc('orders/ex1').update({ adminReview: { byUid: 'x' }, status: 'picked_up' }));
    const client = e.authenticatedContext('c1', password).firestore();
    // Témoin : l'annulation légitime reste possible.
    await assertSucceeds(client.doc('orders/pend1').update({ status: 'cancelled' }));
    await assertFails(client.doc('orders/pend2').update({ status: 'cancelled', ...fake }));
    await assertFails(client.doc('orders/pend2').update({ status: 'cancelled', deliveryFeePaid: true }));
  } finally { await e.cleanup(); }
});
