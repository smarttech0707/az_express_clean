// Mission 7E-11-T — URL des preuves (driverAcceptanceSelfie, deliveryPhoto) dans les commandes :
//  1. lecture : seulement les personnes liées à la commande (client, livreur assigné, vendeur) et le super-administrateur ;
//     un tiers connecté, un autre livreur ou un anonyme ne lit ni le document ni ces URL (jeton inclus), même par requête ;
//  2. écriture : ces champs sont posés par le SERVEUR (acceptOrderCF, deliverOrderCF) après validation ; le livreur, le client et
//     le vendeur ne peuvent ni les écrire ni les supprimer, mais leurs mises à jour légitimes restent possibles même quand ils existent.
//
// Exécution : firebase emulators:exec --only firestore "node --test rules-tests/proof-urls-server-only.rules.test.js"
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(process.env.FIRESTORE_RULES_PATH || path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const anonymous = { firebase: { sign_in_provider: 'anonymous' } };
const SELFIE = 'https://firebasestorage.googleapis.com/v0/b/demo-proof.firebasestorage.app/o/acceptance_selfies%2Fo1%2Fd1.jpg?alt=media&token=secret-1';
const PHOTO = 'https://firebasestorage.googleapis.com/v0/b/demo-proof.firebasestorage.app/o/delivery_photos%2Fd1%2Fo1.jpg?alt=media&token=secret-2';

let env;
test.before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-proof-urls', firestore: { rules: RULES } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
    const base = { clientId: 'c1', driverId: 'd1', sellerId: 's1', budget: 1500, shoppingBudget: 0, isPaid: false, paymentMethod: 'cash' };
    await db.doc('orders/proof1').set({ ...base, status: 'accepted', driverAcceptanceSelfie: SELFIE });
    await db.doc('orders/proof2').set({ ...base, status: 'accepted', driverAcceptanceSelfie: SELFIE });
    await db.doc('orders/proof3').set({ ...base, status: 'picked_up', driverAcceptanceSelfie: SELFIE, deliveryPhoto: PHOTO });
    await db.doc('orders/pending1').set({ ...base, status: 'pending', driverId: null });
    await db.doc('orders/noproof').set({ ...base, status: 'accepted' });
  });
});
test.after(async () => env?.cleanup());
const as = (uid, token = password) => env.authenticatedContext(uid, token).firestore();

test('lecture : client, livreur assigné, vendeur et super-administrateur lisent les URL ; un tiers connecté ne lit rien', async () => {
  for (const uid of ['c1', 'd1', 's1', 'root']) {
    const snap = await assertSucceeds(as(uid).doc('orders/proof3').get());
    if (snap.data().deliveryPhoto !== PHOTO || snap.data().driverAcceptanceSelfie !== SELFIE) throw new Error(`URL absente pour ${uid}`);
  }
  for (const [label, db] of [['autre livreur', as('d2')], ['autre client', as('c2')], ['autre vendeur', as('s2')],
    ['sous-administrateur', as('sub')], ['anonyme', as('anon', anonymous)], ['non connecté', env.unauthenticatedContext().firestore()]]) {
    await assertFails(db.doc('orders/proof3').get()), label;
  }
});

test('lecture par requête : impossible d\'énumérer les commandes portant une preuve sans en être partie prenante', async () => {
  const outsider = as('d2');
  await assertFails(outsider.collection('orders').where('deliveryPhoto', '!=', null).get());
  await assertFails(outsider.collection('orders').where('driverId', '==', 'd1').get());
  await assertFails(outsider.collection('orders').get());
  await assertSucceeds(as('d1').collection('orders').where('driverId', '==', 'd1').get());
  await assertSucceeds(as('c1').collection('orders').where('clientId', '==', 'c1').get());
});

test('livreur assigné : ne peut ni poser, ni modifier, ni supprimer une URL de preuve (même avec une transition légitime)', async () => {
  const d = as('d1');
  await assertFails(d.doc('orders/noproof').update({ deliveryPhoto: PHOTO }));
  await assertFails(d.doc('orders/noproof').update({ driverAcceptanceSelfie: SELFIE }));
  await assertFails(d.doc('orders/proof1').update({ driverAcceptanceSelfie: 'https://evil.example/x.jpg' }));
  await assertFails(d.doc('orders/proof3').update({ deliveryPhoto: 'https://evil.example/x.jpg' }));
  await assertFails(d.doc('orders/proof3').update({ deliveryPhoto: null }));
  await assertFails(d.doc('orders/proof1').update({ status: 'picked_up', deliveryPhoto: PHOTO }));
});

test('livreur assigné : ses mises à jour légitimes restent possibles quand les preuves existent déjà', async () => {
  const d = as('d1');
  await assertSucceeds(d.doc('orders/proof2').update({ driverLat: 6.7, driverLng: -3.4 })); // même statut, URL inchangées
  await assertSucceeds(d.doc('orders/proof1').update({ status: 'picked_up' })); // transition normale après acceptation
});

test('client et vendeur : aucune écriture d\'URL de preuve ; l\'annulation et la note du client restent possibles', async () => {
  await assertFails(as('c1').doc('orders/pending1').update({ status: 'cancelled', deliveryPhoto: PHOTO }));
  await assertFails(as('c1').doc('orders/pending1').update({ status: 'cancelled', driverAcceptanceSelfie: SELFIE }));
  await assertFails(as('c1').doc('orders/proof3').update({ deliveryPhoto: PHOTO }));
  await assertFails(as('s1').doc('orders/noproof').update({ deliveryPhoto: PHOTO }));
  await assertFails(as('s1').doc('orders/noproof').update({ driverAcceptanceSelfie: SELFIE }));
  await assertFails(as('d2').doc('orders/noproof').update({ deliveryPhoto: PHOTO }));
  await assertSucceeds(as('c1').doc('orders/pending1').update({ status: 'cancelled' }));
});

test('super-administrateur : peut corriger une preuve (support) ; un sous-administrateur ne peut pas', async () => {
  await assertSucceeds(as('root').doc('orders/noproof').update({ deliveryPhoto: PHOTO }));
  await assertFails(as('sub').doc('orders/proof3').update({ deliveryPhoto: 'https://evil.example/x.jpg' }));
});

test('les règles restent évaluables sur les chemins de refus : limite de 1000 expressions non atteinte (refus franc, pas d\'erreur de règle)', async () => {
  // Un refus par dépassement de limite serait indistinguable d'un refus normal : on vérifie en plus qu'une écriture valide
  // du même chemin (transition + champs non protégés) réussit après l'ajout des deux clés.
  await assertSucceeds(as('d1').doc('orders/proof2').update({ status: 'picked_up', pickedUpNote: 'ok' }));
});
