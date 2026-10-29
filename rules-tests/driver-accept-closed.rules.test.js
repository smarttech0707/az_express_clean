// Fermeture de la brèche « assigned -> accepted sans payer la commission ».
//
// firestore.rules autorise encore un livreur à écrire lui-même status:'accepted'
// sur une course qui lui est assignée : un client modifié peut ainsi accepter
// sans que acceptOrderCF ne prélève la commission. Les anciennes versions de
// l'application dépendent de cette branche (acceptation par transaction
// Flutter) : la retirer des règles EN PRODUCTION avant leur mise à jour les
// empêcherait d'accepter. Voir docs/DRIVER_ACCEPT_RULE_MIGRATION.md.
//
// Ce fichier :
//  1. documente la brèche telle qu'elle est dans firestore.rules aujourd'hui ;
//  2. valide la règle CIBLE (même fichier, branche remplacée par `false`) sans
//     toucher à firestore.rules : refus de l'acceptation directe, transitions
//     légitimes inchangées.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const CURRENT = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');

// Règle cible : la branche assigned -> accepted est supprimée. Le découpage est
// strict : si le texte de la règle change, ce test échoue au lieu de valider
// une transformation vide.
function closedRules(source) {
  const start = source.indexOf("(resource.data.status == 'assigned' && request.resource.data.status == 'accepted'");
  const endMarker = "consentVerified != true))";
  const end = source.indexOf(endMarker, start);
  if (start < 0 || end < 0) throw new Error('branche assigned->accepted introuvable dans firestore.rules');
  return `${source.slice(0, start)}false${source.slice(end + endMarker.length)}`;
}

const password = { firebase: { sign_in_provider: 'password' } };

async function envFor(rules, projectId) {
  const env = await initializeTestEnvironment({ projectId, firestore: { rules } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('orders/assigned1').set({
      clientId: 'c1', driverId: 'd1', status: 'assigned', budget: 500, isPaid: false, paymentMethod: 'cash',
    });
    await db.doc('orders/accepted1').set({
      clientId: 'c1', driverId: 'd1', status: 'accepted', budget: 500, isPaid: false, paymentMethod: 'cash',
    });
    await db.doc('orders/picked1').set({
      clientId: 'c1', driverId: 'd1', status: 'picked_up', budget: 500, isPaid: false, paymentMethod: 'cash',
    });
    await db.doc('orders/qr1').set({
      clientId: 'c1', driverId: 'd1', status: 'accepted', budget: 500, isPaid: false,
      paymentMethod: 'cash', deliveryProofMode: 'qr_v1',
    });
  });
  return env;
}

test('ÉTAT ACTUEL (brèche documentée) : l’acceptation directe sans commission est possible', async () => {
  const env = await envFor(CURRENT, 'az-accept-current');
  try {
    const db = env.authenticatedContext('d1', password).firestore();
    await assertSucceeds(db.doc('orders/assigned1').update({ status: 'accepted' }));
  } finally { await env.cleanup(); }
});

test('RÈGLE CIBLE : l’acceptation directe est refusée', async () => {
  const env = await envFor(closedRules(CURRENT), 'az-accept-closed');
  try {
    const db = env.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('orders/assigned1').update({ status: 'accepted' }));
    await assertFails(db.doc('orders/assigned1').update({
      status: 'accepted', commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 0,
    }));
    // Un autre livreur ne peut pas non plus s’attribuer la commande.
    const other = env.authenticatedContext('d2', password).firestore();
    await assertFails(other.doc('orders/assigned1').update({ status: 'accepted', driverId: 'd2' }));
  } finally { await env.cleanup(); }
});

test('RÈGLE CIBLE : transitions légitimes inchangées, administrateur inchangé', async () => {
  const env = await envFor(closedRules(CURRENT), 'az-accept-closed-ok');
  try {
    const driver = env.authenticatedContext('d1', password).firestore();
    await assertSucceeds(driver.doc('orders/accepted1').update({ status: 'picked_up' }));
    await assertSucceeds(driver.doc('orders/picked1').update({ status: 'delivered' }));
    await assertFails(driver.doc('orders/qr1').update({ status: 'picked_up' })); // QR : par fonction
    const admin = env.authenticatedContext('root', password).firestore();
    await assertSucceeds(admin.doc('orders/assigned1').update({ status: 'accepted' }));
  } finally { await env.cleanup(); }
});

test('RÈGLE CIBLE : aucune autre voie d’acceptation (diffusion, pending, usurpation, champs de commission forgés)', async () => {
  const env = await envFor(closedRules(CURRENT), 'az-accept-closed-more');
  try {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('orders/broadcast1').set({
        clientId: 'c1', status: 'broadcast', budget: 500, isPaid: false, paymentMethod: 'cash', notifiedDriverIds: ['d1'],
      });
      await db.doc('orders/pending1').set({ clientId: 'c1', status: 'pending', budget: 500, isPaid: false, paymentMethod: 'cash' });
    });
    const d1 = env.authenticatedContext('d1', password).firestore();
    await assertFails(d1.doc('orders/broadcast1').update({ status: 'accepted', driverId: 'd1' }));
    await assertFails(d1.doc('orders/broadcast1').update({ driverId: 'd1' }));
    await assertFails(d1.doc('orders/pending1').update({ status: 'accepted', driverId: 'd1' }));
    await assertFails(d1.doc('orders/assigned1').update({ status: 'picked_up' })); // saut d’étape
    await assertFails(d1.doc('orders/assigned1').update({
      status: 'accepted', commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 0, commissionTxId: 'x',
    }));
    // un client ne peut pas s’attribuer ni accepter la commande d’un livreur
    const client = env.authenticatedContext('c1', password).firestore();
    await assertFails(client.doc('orders/assigned1').update({ status: 'accepted' }));
    // un livreur ne peut pas toucher aux champs de transfert/retenue même sur sa propre course acceptée
    await assertFails(d1.doc('orders/accepted1').update({ settlementHold: true }));
    await assertFails(d1.doc('orders/accepted1').update({ driverAssignmentVersion: 5 }));
  } finally { await env.cleanup(); }
});
