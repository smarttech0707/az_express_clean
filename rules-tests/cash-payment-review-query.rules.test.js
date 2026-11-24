// Mission 7E-2 — la liste « Incidents paiement cash » interroge orders par cashPayment.verification == 'pending_review'
// (une égalité sur un champ imbriqué, fenêtre limit). Les administrateurs peuvent la lister ; clients, livreurs et partenaires
// ne peuvent PAS énumérer les commandes d'autrui ; un incident reste dans le résultat même quand le reversement est clos
// (merchantCashSettled = true). Aucune écriture directe de cashPayment (déjà couvert par partner-order-v2.rules.test.js).
//
// Exécution : npm run test:rules
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

const order = (id, verification, settled) => ({
  clientId: 'c1', sellerId: 'r1', sellerType: 'restaurant', driverId: 'd1', status: 'delivered', paymentMethod: 'cash',
  amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000, isPaid: false, merchantCashSettled: settled,
  cashPayment: { status: 'non_payment_declared', verification, declaredAtMs: 1 },
  cashRemittance: { status: settled ? 'confirmed' : 'pending', amountDue: 3500, partnerId: 'r1' },
});

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
    await db.doc('orders/p1').set(order('p1', 'pending_review', false));
    await db.doc('orders/p2').set(order('p2', 'pending_review', true)); // reversement clos : doit rester listé
    await db.doc('orders/x1').set(order('x1', 'confirmed_unpaid', false));
    await db.doc('orders/x2').set(order('x2', 'refuted', true));
  });
  return e;
}

const query = (ctx, limit = 50) => ctx.firestore().collection('orders').where('cashPayment.verification', '==', 'pending_review').limit(limit).get();

test('super-administrateur : liste des incidents en attente, y compris reversement clos (merchantCashSettled=true)', async () => {
  const e = await env('az-cash-review-query');
  try {
    const snap = await assertSucceeds(query(e.authenticatedContext('root', password)));
    assert.deepEqual(snap.docs.map((d) => d.id).sort(), ['p1', 'p2']);
    // Fenêtre : limit respecté (pagination par élargissement de la fenêtre).
    const first = await assertSucceeds(query(e.authenticatedContext('root', password), 1));
    assert.equal(first.size, 1);
  } finally { await e.cleanup(); }
});

test('sous-admin et non-administrateurs : ni sous-admin, client, ni livreur, ni partenaire, ni anonyme ne peuvent énumérer les incidents', async () => {
  const e = await env('az-cash-review-query-deny');
  try {
    // Le sous-administrateur n'est pas isAdmin() : la page est réservée au super-administrateur (comme l'examen côté serveur).
    for (const uid of ['sub', 'c1', 'd1', 'r1', 'stranger']) {
      await assertFails(query(e.authenticatedContext(uid, password)));
    }
    await assertFails(query(e.unauthenticatedContext()));
    await assertFails(query(e.authenticatedContext('anon', { firebase: { sign_in_provider: 'anonymous' } })));
  } finally { await e.cleanup(); }
});

// ── Mission 7E-2-S : cashPayment écrit par le serveur uniquement (Admin SDK), pour TOUS les rôles ──────────────────────────
const legacy = (status) => ({
  clientId: 'c1', sellerId: 'r1', sellerType: 'restaurant', driverId: 'd1', status, paymentMethod: 'cash',
  budget: 4000, isPaid: false, merchantCashSettled: false,
});
// Volontairement différent de la valeur semée (declaredAtMs: 1) : une écriture identique serait un no-op légitime.
const cp = { status: 'non_payment_declared', verification: 'pending_review', declaredAtMs: 2 };

async function writeEnv(projectId) {
  const e = await env(projectId);
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('orders/legacy-pending').set(legacy('pending'));
    await db.doc('orders/legacy-assigned').set(legacy('assigned'));
    await db.doc('orders/legacy-accepted').set(legacy('accepted'));
    await db.doc('orders/legacy-delivered').set(legacy('delivered'));
  });
  return e;
}
const as = (e, uid) => e.authenticatedContext(uid, password).firestore();
const { deleteField } = require('firebase/firestore');

test('super-administrateur : ajout, modification et suppression directs de cashPayment refusés', async () => {
  const e = await writeEnv('az-cashpayment-super');
  try {
    const db = as(e, 'root');
    await assertFails(db.doc('orders/legacy-delivered').update({ cashPayment: cp }));              // ajout (historique)
    await assertFails(db.doc('orders/legacy-delivered').update({ 'cashPayment.verification': 'x' })); // ajout par chemin
    await assertFails(db.doc('orders/p1').update({ cashPayment: { ...cp, verification: 'refuted' } })); // modification
    await assertFails(db.doc('orders/p1').update({ 'cashPayment.verification': 'refuted' }));
    await assertFails(db.doc('orders/p1').update({ cashPayment: deleteField() }));                  // suppression
    await assertFails(db.doc('orders/p1').set({ ...order('p1', 'refuted', false) }));               // remplacement complet
    await assertFails(db.doc('orders/p1').delete());                                                 // suppression du document
  } finally { await e.cleanup(); }
});

test('sous-admin, livreur, restaurateur, client : écriture de cashPayment refusée (commandes v2 ET historiques)', async () => {
  const e = await writeEnv('az-cashpayment-roles');
  try {
    for (const uid of ['sub', 'd1', 'r1', 'c1', 'stranger']) {
      for (const id of ['p1', 'legacy-accepted', 'legacy-delivered', 'legacy-pending']) {
        const ref = as(e, uid).doc(`orders/${id}`);
        await assertFails(ref.update({ cashPayment: cp }), `${uid} ${id} ajout`);
        await assertFails(ref.update({ 'cashPayment.verification': 'refuted' }), `${uid} ${id} chemin`);
      }
      await assertFails(as(e, uid).doc('orders/p1').update({ cashPayment: deleteField() }), `${uid} suppression`);
    }
    // Aussi à travers une transition par ailleurs légitime (le garde ne doit pas être contournable en la combinant).
    await assertFails(as(e, 'd1').doc('orders/legacy-assigned').update({ status: 'accepted', cashPayment: cp }));
    await assertFails(as(e, 'c1').doc('orders/legacy-pending').update({ status: 'cancelled', cashPayment: cp }));
    await assertFails(as(e, 'r1').doc('orders/legacy-accepted').update({ sellerStatus: 'preparing', cashPayment: cp }));
  } finally { await e.cleanup(); }
});

test('opérations légitimes inchangées : lecture admin, actions admin hors cashPayment, transitions livreur/client/partenaire historiques', async () => {
  const e = await writeEnv('az-cashpayment-legit');
  try {
    // Lecture administrative.
    await assertSucceeds(as(e, 'root').doc('orders/p1').get());
    // Action administrative sur un autre champ, y compris sur une commande v2 portant un cashPayment (le champ est renvoyé tel quel).
    await assertSucceeds(as(e, 'root').doc('orders/p1').update({ adminNote: 'vu' }));
    await assertSucceeds(as(e, 'root').doc('orders/legacy-delivered').update({ adminNote: 'vu' }));
    // Commandes historiques (sans cashPayment) : transitions habituelles préservées.
    // Mission 7E-17 : l'acceptation passe par acceptOrderCF ; l'écriture directe est refusée.
    await assertFails(as(e, 'd1').doc('orders/legacy-assigned').update({ status: 'accepted' }));
    await assertSucceeds(as(e, 'c1').doc('orders/legacy-pending').update({ status: 'cancelled' }));
    await assertSucceeds(as(e, 'r1').doc('orders/legacy-accepted').update({ sellerStatus: 'preparing' }));
  } finally { await e.cleanup(); }
});

test('cashRemittance et montants v2 restent protégés (livreur, restaurateur, client) ; création avec cashPayment refusée', async () => {
  const e = await writeEnv('az-cashpayment-protected');
  try {
    for (const uid of ['d1', 'r1', 'c1']) {
      const ref = as(e, uid).doc('orders/p1');
      await assertFails(ref.update({ 'cashRemittance.status': 'confirmed' }), `${uid} cashRemittance`);
      await assertFails(ref.update({ productAmount: 9999, totalAmount: 10499 }), `${uid} montants`);
      await assertFails(ref.update({ merchantCashSettled: true }), `${uid} merchantCashSettled`);
    }
    const create = { clientId: 'c1', status: 'pending', budget: 1000, isPaid: false, paymentMethod: 'cash' };
    await assertFails(as(e, 'c1').doc('orders/new1').set({ ...create, cashPayment: cp }));
    await assertFails(as(e, 'root').doc('orders/new2').set({ ...create, cashPayment: cp })); // le super-admin non plus
  } finally { await e.cleanup(); }
});
