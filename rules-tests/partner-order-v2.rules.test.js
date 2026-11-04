// Commandes Restaurant/Boulangerie version 2 (amountsVersion == 2, Mission 7B-3B-S) :
// montants, paiement, état de préparation et reversement cash sont posés par le serveur
// uniquement. Sans ces verrous, un restaurateur ou un livreur pouvait gonfler
// productAmount/totalAmount avant la livraison et faire créditer un montant jamais payé.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

const v2 = (over = {}) => ({
  clientId: 'c1', driverId: 'd1', sellerId: 'r1', sellerType: 'restaurant', type: 'livraison',
  status: 'accepted', paymentMethod: 'wallet', isPaid: true, amountsVersion: 2,
  productAmount: 3500, deliveryFee: 500, totalAmount: 4000, budget: 500, itemsAmount: 3500,
  tariffQuoteId: 'q1', sellerStatus: 'preparing', ...over,
});

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('orders/preparing').set(v2());
    await db.doc('orders/ready').set(v2({ sellerStatus: 'ready' }));
    await db.doc('orders/pending').set(v2({ status: 'pending', driverId: null, sellerStatus: 'preparing' }));
    await db.doc('orders/cash').set(v2({ paymentMethod: 'cash', isPaid: false, status: 'picked_up', sellerStatus: 'ready' }));
    await db.doc('orders/bakery').set(v2({ sellerId: 'b1', sellerType: 'boulangerie', sellerStatus: null }));
    // Commandes historiques : aucune régression.
    await db.doc('orders/legacy_resto').set({
      clientId: 'c1', driverId: 'd1', sellerId: 'r1', sellerType: 'restaurant', status: 'accepted',
      paymentMethod: 'cash', isPaid: false, budget: 500, sellerStatus: 'preparing',
    });
    await db.doc('orders/legacy_bakery').set({
      clientId: 'c1', driverId: 'd1', sellerId: 'b1', sellerType: 'boulangerie', status: 'accepted',
      paymentMethod: 'cash', isPaid: false, budget: 500, sellerStatus: null,
    });
    await db.doc('orders/legacy_pending').set({
      clientId: 'c1', status: 'pending', paymentMethod: 'cash', isPaid: false, budget: 500,
    });
  });
  return e;
}

const FORGED = [
  { productAmount: 999999 }, { totalAmount: 999999 }, { deliveryFee: 1 }, { itemsAmount: 1 }, { budget: 99999 },
  { shoppingBudget: 5 }, { isPaid: false }, { paymentMethod: 'cash' }, { tariffQuoteId: 'forge' },
  { quotedAmount: 1 }, { amountsVersion: 1 }, { amountsVersion: 0 }, { sellerType: 'seller' }, { sellerId: 'x' },
  { clientId: 'x' }, { type: 'courses' }, { items: [] },
  { productAmount: 99999, totalAmount: 100499, itemsAmount: 99999 }, // gonflement cohérent multi-champs
  { cashRemittance: { status: 'confirmed', amountDue: 3500, partnerConfirmedAtMs: 1 } },
  { cashPayment: { status: 'confirmed', verification: 'refuted' } },
  { merchantCashSettled: true }, { merchantCashSettledAt: 1 }, { merchantCashSettledBy: 'x' },
  { partnerAcceptedAtMs: 1 }, { preparationStartedAtMs: 1 }, { readyAtMs: 1 }, { partnerRefusal: { reason: 'x' } },
  { commissionStatus: 'refunded' }, { commissionAmount: 0 }, { deliveryFeePaid: false },
  { cashBreakdown: { driverNet: 99999 } },
];

test('livreur : aucun champ financier / serveur d’une commande v2 n’est modifiable, même combiné à une transition légitime', async () => {
  const e = await env('az-v2-driver');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    for (const patch of FORGED) {
      await assertFails(db.doc('orders/ready').update({ ...patch, status: 'picked_up' }));
      await assertFails(db.doc('orders/ready').update(patch));
    }
    // Suppression du marqueur de version : interdite (sinon le verrou tomberait).
    // set() sans le champ = suppression de amountsVersion (même diff que deleteField).
    const { amountsVersion, ...sansVersion } = v2({ sellerStatus: 'ready' });
    await assertFails(db.doc('orders/ready').set(sansVersion));
    await assertFails(db.doc('orders/ready').set({ ...sansVersion, totalAmount: 99999, status: 'picked_up' }));
  } finally { await e.cleanup(); }
});

test('restaurateur : ne peut modifier ni montants, ni paiement, ni préparation, ni cash d’une commande v2', async () => {
  const e = await env('az-v2-resto');
  try {
    const db = e.authenticatedContext('r1', password).firestore();
    for (const patch of FORGED) await assertFails(db.doc('orders/preparing').update(patch));
    await assertFails(db.doc('orders/preparing').update({ sellerStatus: 'ready' }));
    await assertFails(db.doc('orders/pending').update({ sellerStatus: 'ready' }));
    await assertFails(db.doc('orders/preparing').update({ status: 'delivered' }));
    // Témoin : un champ non financier reste écrivable (le verrou ne bloque pas tout).
    await assertSucceeds(db.doc('orders/preparing').update({ partnerNote: 'ok' }));
  } finally { await e.cleanup(); }
});

test('boulanger : la préparation d’une commande v2 passe par le serveur, l’historique garde son flux', async () => {
  const e = await env('az-v2-bakery');
  try {
    const db = e.authenticatedContext('b1', password).firestore();
    await assertFails(db.doc('orders/bakery').update({ sellerStatus: 'preparing' }));
    await assertFails(db.doc('orders/bakery').update({ totalAmount: 99999 }));
    await assertFails(db.doc('orders/bakery').update({ amountsVersion: 1 }));
    // Historique : transitions inchangées.
    await assertSucceeds(db.doc('orders/legacy_bakery').update({ sellerStatus: 'preparing' }));
    await assertSucceeds(db.doc('orders/legacy_bakery').update({ sellerStatus: 'ready' }));
  } finally { await e.cleanup(); }
});

test('client : ne peut ni gonfler, ni annuler directement (remboursement = cancelOrderCF), ni toucher au cash d’une commande v2', async () => {
  const e = await env('az-v2-client');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('orders/pending').update({ status: 'cancelled' }));
    for (const patch of FORGED) await assertFails(db.doc('orders/pending').update({ ...patch, status: 'cancelled' }));
    for (const patch of FORGED) await assertFails(db.doc('orders/pending').update(patch));
    // Création : ni v2 ni champs serveur.
    const base = { clientId: 'c1', budget: 500, isPaid: false, paymentMethod: 'cash', status: 'pending', type: 'livraison', description: 'x' };
    await assertSucceeds(db.doc('orders/ctl').set(base));
    for (const extra of [{ amountsVersion: 2 }, { cashRemittance: { status: 'confirmed' } }, { cashPayment: { status: 'confirmed' } }, { merchantCashSettled: true },
      { partnerAcceptedAtMs: 1 }, { preparationStartedAtMs: 1 }, { readyAtMs: 1 }, { partnerRefusal: { reason: 'x' } },
      { cancelRequestAfterPreparation: {} }]) {
      await assertFails(db.doc(`orders/new_${Object.keys(extra)[0]}`).set({ ...base, ...extra }));
    }
    // Historique : l'annulation directe d'une commande en attente reste possible.
    await assertSucceeds(db.doc('orders/legacy_pending').update({ status: 'cancelled' }));
  } finally { await e.cleanup(); }
});

test('utilisateur non autorisé (autre client, autre livreur, autre partenaire, anonyme) : refus total', async () => {
  const e = await env('az-v2-stranger');
  try {
    const anon = e.authenticatedContext('a1', { firebase: { sign_in_provider: 'anonymous' } }).firestore();
    for (const uid of ['c2', 'd2', 'r2', 'b2']) {
      const db = e.authenticatedContext(uid, password).firestore();
      await assertFails(db.doc('orders/ready').update({ totalAmount: 1 }));
      await assertFails(db.doc('orders/ready').update({ status: 'picked_up' }));
      await assertFails(db.doc('orders/pending').update({ status: 'cancelled' }));
      await assertFails(db.doc('orders/cash').update({ cashRemittance: { status: 'confirmed' } }));
      await assertFails(db.doc('orders/cash').update({ cashPayment: { status: 'confirmed', verification: 'refuted' } }));
    }
    await assertFails(anon.doc('orders/ready').update({ totalAmount: 1 }));
  } finally { await e.cleanup(); }
});

test('récupération directe v2 : refusée avant ready, acceptée une fois ready ; livraison directe v2 refusée', async () => {
  const e = await env('az-v2-pickup');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('orders/preparing').update({ status: 'picked_up' }));
    await assertSucceeds(db.doc('orders/ready').update({ status: 'picked_up' }));
    // La livraison (crédits partenaire/livreur, cash) ne passe que par deliverOrderCF.
    await assertFails(db.doc('orders/ready').update({ status: 'delivered' }));
    await assertFails(db.doc('orders/cash').update({ status: 'delivered' }));
  } finally { await e.cleanup(); }
});

test('historique : livreur et restaurateur gardent leurs transitions sur une commande sans amountsVersion', async () => {
  const e = await env('az-v2-legacy');
  try {
    const driver = e.authenticatedContext('d1', password).firestore();
    await assertSucceeds(driver.doc('orders/legacy_resto').update({ status: 'picked_up' }));
    await assertSucceeds(driver.doc('orders/legacy_resto').update({ status: 'delivered' }));
    const resto = e.authenticatedContext('r1', password).firestore();
    await assertSucceeds(resto.doc('orders/legacy_resto').update({ sellerStatus: 'ready' }));
  } finally { await e.cleanup(); }
});

test('administrateur : reste libre sur une commande v2 (résolution de litiges)', async () => {
  const e = await env('az-v2-admin');
  try {
    const db = e.authenticatedContext('root', password).firestore();
    await assertSucceeds(db.doc('orders/ready').update({ adminNote: 'ok' }));
  } finally { await e.cleanup(); }
});
