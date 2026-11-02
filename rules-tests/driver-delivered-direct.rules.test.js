// Brèche « picked_up -> delivered écrit directement par le livreur ».
//
// firestore.rules autorise le livreur assigné à passer lui-même une commande
// `picked_up` à `delivered` (hors preuve QR). Or le crédit du livreur, la
// commission journalisée (`commissions`, `config/az_wallet`) et le compteur de
// livraisons ne sont produits QUE par deliverOrderCF, qui refuse une commande
// déjà `delivered`. Une écriture directe clôt donc la commande SANS jamais
// créditer personne : l'argent payé par le client reste sans bénéficiaire.
// L'application actuelle appelle deliverOrderCF (firestore_service.dart) et
// n'écrit plus `delivered` : la branche ne sert qu'aux très anciennes versions.
//
// Ce fichier (même méthode que driver-accept-closed.rules.test.js) :
//  1. documente la brèche telle qu'elle est dans firestore.rules aujourd'hui ;
//  2. valide la règle CIBLE (branche remplacée par `false`) sans modifier
//     firestore.rules : refus de l'écriture directe, transitions légitimes inchangées.
//
// Exécution : firebase emulators:exec --only firestore "node --test rules-tests/driver-delivered-direct.rules.test.js"
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const CURRENT = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');

// Le découpage est strict : si le texte de la règle change, ce test échoue au
// lieu de valider une transformation vide.
function closedRules(source) {
  const re = /\|\|\s*\(resource\.data\.status == 'picked_up'\s*&&\s*resource\.data\.get\('deliveryProofMode', ''\) != 'qr_v1'\s*&&\s*request\.resource\.data\.status == 'delivered'\)/g;
  const found = source.match(re);
  if (!found || found.length !== 1) throw new Error('branche picked_up->delivered introuvable (ou ambiguë) dans firestore.rules');
  return source.replace(re, '|| false');
}

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

test('ÉTAT ACTUEL (brèche documentée) : le livreur clôt seul une commande wallet payée', async () => {
  const env = await envFor(CURRENT, 'az-delivered-current');
  try {
    const db = env.authenticatedContext('d1', password).firestore();
    await assertSucceeds(db.doc('orders/paid1').update({ status: 'delivered' }));
    // Conséquence : aucun crédit, aucun journal, aucun compteur n'a été produit par cette écriture.
    await env.withSecurityRulesDisabled(async (ctx) => {
      const d = ctx.firestore();
      const order = (await d.doc('orders/paid1').get()).data();
      const driver = (await d.doc('livreurs/d1').get()).data();
      const client = (await d.doc('clients/c1').get()).data();
      if (order.status !== 'delivered') throw new Error('statut non clos');
      if (driver.wallet !== 4900 || driver.deliveries !== 0 || client.wallet !== 19500) throw new Error('solde modifié');
      if ((await d.collection('commissions').get()).size !== 0) throw new Error('commission inattendue');
    });
  } finally { await env.cleanup(); }
});

test('ÉTAT ACTUEL : les champs financiers serveur restent protégés (la brèche est le statut seul)', async () => {
  const env = await envFor(CURRENT, 'az-delivered-current-fields');
  try {
    const db = env.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('orders/paid1').update({ status: 'delivered', commissionStatus: 'refunded' }));
    await assertFails(db.doc('orders/paid1').update({ status: 'delivered', isPaid: false }));
    await assertFails(db.doc('orders/paid1').update({ status: 'delivered', budget: 5000 }));
  } finally { await env.cleanup(); }
});

test('RÈGLE CIBLE : l’écriture directe picked_up -> delivered est refusée pour le livreur, le client et un tiers', async () => {
  const env = await envFor(closedRules(CURRENT), 'az-delivered-closed');
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

test('RÈGLE CIBLE : transitions légitimes inchangées (picked_up, mise à jour sans statut, QR, administrateur)', async () => {
  const env = await envFor(closedRules(CURRENT), 'az-delivered-closed-ok');
  try {
    const driver = env.authenticatedContext('d1', password).firestore();
    await assertSucceeds(driver.doc('orders/accepted1').update({ status: 'picked_up' }));
    await assertSucceeds(driver.doc('orders/paid2').update({ driverLat: 6.7, driverLng: -3.4 })); // même statut
    await assertFails(driver.doc('orders/qr1').update({ status: 'delivered' })); // QR : par fonction
    const admin = env.authenticatedContext('root', password).firestore();
    await assertSucceeds(admin.doc('orders/paid2').update({ status: 'delivered' }));
  } finally { await env.cleanup(); }
});
