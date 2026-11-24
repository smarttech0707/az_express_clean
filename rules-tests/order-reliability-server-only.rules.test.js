// Collections créées par le chantier de fiabilité des commandes (2026-10-30) :
// écriture et lecture réservées au serveur (Admin SDK). Aucune règle dédiée :
// l'accès est refusé par défaut, ces tests le figent pour client, livreur et admin.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const COLLECTIONS = [
  'order_dispatch_retries', 'order_dispute_decisions', 'reconciliation_flags', 'tariff_observations', 'stuck_order_alerts',
];

test('collections serveur : aucune lecture ni écriture depuis un client, un livreur ou un administrateur', async () => {
  const e = await initializeTestEnvironment({ projectId: 'az-order-reliability', firestore: { rules: RULES } });
  try {
    await e.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('admins/root').set({ role: 'super', isActive: true });
      await db.doc('clients/c1').set({ wallet: 0 });
      await db.doc('livreurs/d1').set({ wallet: 0 });
      for (const c of COLLECTIONS) await db.doc(`${c}/x`).set({ seed: true });
    });
    const actors = {
      client: e.authenticatedContext('c1', password).firestore(),
      livreur: e.authenticatedContext('d1', password).firestore(),
      admin: e.authenticatedContext('root', password).firestore(),
      anonyme: e.authenticatedContext('anon', { firebase: { sign_in_provider: 'anonymous' } }).firestore(),
    };
    for (const [who, db] of Object.entries(actors)) {
      for (const c of COLLECTIONS) {
        await assertFails(db.doc(`${c}/x`).get());
        await assertFails(db.doc(`${c}/x`).set({ forged: who }));
        await assertFails(db.doc(`${c}/new`).set({ forged: who }));
        await assertFails(db.doc(`${c}/x`).delete());
      }
    }
  } finally { await e.cleanup(); }
});

test('un client ne peut pas modifier le montant ni le statut de sa commande récupérée pour forcer un remboursement', async () => {
  const e = await initializeTestEnvironment({ projectId: 'az-order-reliability-2', firestore: { rules: RULES } });
  try {
    await e.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc('orders/o1').set({
        clientId: 'c1', driverId: 'd1', status: 'picked_up', paymentMethod: 'wallet', isPaid: true, budget: 1000,
      });
    });
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/o1').update({ status: 'cancelled' }));
    await assertFails(db.doc('orders/o1').update({ budget: 99999 }));
    await assertFails(db.doc('orders/o1').update({ isPaid: false }));
  } finally { await e.cleanup(); }
});

test('ni le client ni le livreur ne peuvent forger une décision de litige, une demande ou une confirmation administrative', async () => {
  const e = await initializeTestEnvironment({ projectId: 'az-order-reliability-3', firestore: { rules: RULES } });
  try {
    await e.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('orders/o1').set({ clientId: 'c1', driverId: 'd1', status: 'picked_up', paymentMethod: 'wallet', isPaid: true, budget: 1000 });
      await db.doc('orders/o2').set({ clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'cash', isPaid: false, budget: 1000 });
    });
    const client = e.authenticatedContext('c1', password).firestore();
    const driver = e.authenticatedContext('d1', password).firestore();
    const forged = [
      { disputeDecision: { decision: 'exceptionalCancel' } },
      { adminDeliveryConfirmation: { byUid: 'root' } },
      { deliveryClosedBy: 'admin_dispute' },
      { cancelRequestAfterPickup: { status: 'resolved_cancelled' } },
    ];
    for (const extra of forged) {
      await assertFails(driver.doc('orders/o1').update(extra));
      await assertFails(client.doc('orders/o1').update(extra));
      await assertFails(driver.doc('orders/o2').update({ status: 'picked_up', ...extra }));
    }
  } finally { await e.cleanup(); }
});
