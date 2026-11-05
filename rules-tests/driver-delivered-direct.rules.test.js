// Clôture directe INTERDITE : picked_up -> delivered n'est plus une écriture du livreur (Mission 7E-17).
//
// Le crédit du livreur, la commission journalisée (`commissions`, `config/az_wallet`) et le compteur de livraisons ne sont
// produits QUE par deliverOrderCF, qui refuse une commande déjà `delivered`. Une écriture directe clôturait la commande SANS
// créditer personne : l'argent payé par le client restait sans bénéficiaire. Ces tests s'exécutent contre firestore.rules TEL
// QUEL (plus de transformation de règle) et échouent si la branche est rétablie.
//
// ATTENTION production : les très anciennes versions de l'application livreur clôturaient ainsi
// (docs/DRIVER_ACCEPT_RULE_MIGRATION.md). Ne pas publier ce fichier de règles en production avant leur retrait.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const CURRENT = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');

const password = { firebase: { sign_in_provider: 'password' } };

// Commande payée par wallet, commission déjà prélevée à l'acceptation : état réel avant livraison.
const paidPickedUp = {
  clientId: 'c1', driverId: 'd1', status: 'picked_up', budget: 500, shoppingBudget: 0, isPaid: true,
  paymentMethod: 'wallet', commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100,
  commissionTxId: 'commission_paid1_d1',
};

async function envFor(rules, projectId) {
  const env = await initializeTestEnvironment({ projectId, firestore: { rules } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('clients/c1').set({ wallet: 19500 });
    await db.doc('livreurs/d1').set({ wallet: 4900, isOnDelivery: true, deliveries: 0 });
    await db.doc('orders/paid1').set(paidPickedUp);
    await db.doc('orders/paid2').set(paidPickedUp);
    await db.doc('orders/accepted1').set({ ...paidPickedUp, status: 'accepted' });
    await db.doc('orders/qr1').set({ ...paidPickedUp, deliveryProofMode: 'qr_v1' });
  });
  return env;
}

test('l’écriture directe picked_up -> delivered est refusée pour le livreur, le client et un tiers', async () => {
  const env = await envFor(CURRENT, 'az-delivered-closed');
  try {
    const driver = env.authenticatedContext('d1', password).firestore();
    await assertFails(driver.doc('orders/paid1').update({ status: 'delivered' }));
    await assertFails(driver.doc('orders/accepted1').update({ status: 'delivered' })); // saut d'étape
    const other = env.authenticatedContext('d2', password).firestore();
    await assertFails(other.doc('orders/paid1').update({ status: 'delivered' }));
    const client = env.authenticatedContext('c1', password).firestore();
    await assertFails(client.doc('orders/paid1').update({ status: 'delivered' }));
  } finally { await env.cleanup(); }
});

test('transitions légitimes inchangées (picked_up, mise à jour sans statut, QR, administrateur)', async () => {
  const env = await envFor(CURRENT, 'az-delivered-closed-ok');
  try {
    const driver = env.authenticatedContext('d1', password).firestore();
    await assertSucceeds(driver.doc('orders/accepted1').update({ status: 'picked_up' }));
    await assertSucceeds(driver.doc('orders/paid2').update({ driverLat: 6.7, driverLng: -3.4 })); // même statut
    await assertFails(driver.doc('orders/qr1').update({ status: 'delivered' })); // QR : par fonction
    const admin = env.authenticatedContext('root', password).firestore();
    await assertSucceeds(admin.doc('orders/paid2').update({ status: 'delivered' }));
  } finally { await env.cleanup(); }
});

// Mission 7E-17 : preuves négatives exhaustives des DEUX transitions fermées, toutes formes de commande et tous les rôles.
// Le contrôle passe par acceptOrderCF / deliverOrderCF (Admin SDK) ; l'administrateur garde son accès pour le support.
test('transitions directes assigned->accepted et picked_up->delivered refusées : toutes formes de commande, tous les rôles, avec ou sans champs forgés', async () => {
  const env = await initializeTestEnvironment({ projectId: 'az-direct-closed-all', firestore: { rules: CURRENT } });
  const bases = {
    cash: { paymentMethod: 'cash', isPaid: false },
    wallet: { paymentMethod: 'wallet', isPaid: true, commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100 },
    v2: { paymentMethod: 'cash', isPaid: false, amountsVersion: 2, sellerStatus: 'ready', sellerId: 's1', sellerType: 'restaurant' },
    traced: { paymentMethod: 'cash', isPaid: false, commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100, acceptedAt: 1 },
  };
  try {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('admins/root').set({ role: 'super', isActive: true });
      await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
      for (const [name, b] of Object.entries(bases)) {
        for (const status of ['assigned', 'accepted', 'picked_up']) {
          await db.doc(`orders/${name}_${status}`).set({ clientId: 'c1', driverId: 'd1', budget: 500, shoppingBudget: 0, status, ...b });
        }
      }
    });
    const as = (uid) => env.authenticatedContext(uid, password).firestore();
    for (const name of Object.keys(bases)) {
      for (const uid of ['d1', 'd2', 'c1', 's1', 'sub']) {
        await assertFails(as(uid).doc(`orders/${name}_assigned`).update({ status: 'accepted' }), `${name} ${uid} assigned->accepted`);
        await assertFails(as(uid).doc(`orders/${name}_picked_up`).update({ status: 'delivered' }), `${name} ${uid} picked_up->delivered`);
      }
      const d1 = as('d1');
      // Champs forgés ajoutés à la transition (commission, paiement, preuve, horodatage) : toujours refusés.
      await assertFails(d1.doc(`orders/${name}_assigned`).update({ status: 'accepted', commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 0, acceptedAt: 5 }));
      await assertFails(d1.doc(`orders/${name}_picked_up`).update({ status: 'delivered', isPaid: true, deliveredAt: 5, deliveryPhoto: 'https://x/p.jpg', driverAcceptanceSelfie: 'https://x/s.jpg' }));
      // Sauts d'étape.
      await assertFails(d1.doc(`orders/${name}_assigned`).update({ status: 'delivered' }));
      await assertFails(d1.doc(`orders/${name}_accepted`).update({ status: 'delivered' }));
      await assertFails(d1.doc(`orders/${name}_accepted`).update({ status: 'assigned' }));
      await assertFails(d1.doc(`orders/${name}_picked_up`).update({ status: 'accepted' }));
      // Les commandes n'ont pas été modifiées par les tentatives refusées.
      await env.withSecurityRulesDisabled(async (ctx) => {
        const a = (await ctx.firestore().doc(`orders/${name}_assigned`).get()).data();
        const p = (await ctx.firestore().doc(`orders/${name}_picked_up`).get()).data();
        if (a.status !== 'assigned' || p.status !== 'picked_up') throw new Error(`${name} : statut modifié malgré le refus`);
      });
    }
    // Les mises à jour légitimes du livreur subsistent (GPS sur le même statut, accepted -> picked_up hors v2 non prêt).
    await assertSucceeds(as('d1').doc('orders/cash_picked_up').update({ driverLat: 6.7, driverLng: -3.4 }));
    await assertSucceeds(as('d1').doc('orders/cash_accepted').update({ status: 'picked_up' }));
    await assertSucceeds(as('d1').doc('orders/v2_accepted').update({ status: 'picked_up' })); // v2 prête (sellerStatus ready)
    // Support : le super-administrateur peut toujours intervenir.
    await assertSucceeds(as('root').doc('orders/wallet_picked_up').update({ status: 'delivered' }));
  } finally { await env.cleanup(); }
});
