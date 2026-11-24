'use strict';
// Mission 7E-11-U — garde-fou de complexité de la règle orders.update (limite Firestore : 1000 expressions évaluées par requête).
//
// Constat : toute écriture REFUSÉE sur orders épuise la limite (toutes les branches `||` sont évaluées) et revient en erreur
// « maximum of 1000 expressions » au lieu d'un refus simple : c'est un refus (fail-closed) dans les deux cas, identique avant
// 7E-11-T. Ce qui compte est qu'un chemin LÉGITIME ne s'approche jamais de la limite : on ajoute ici MARGIN blocs neutres
// `(1 == 1) &&` en tête de la règle (copie en mémoire, firestore.rules n'est pas modifié) et chaque chemin légitime doit encore
// passer. Si une évolution des règles consomme cette marge, ce test échoue AVANT que la production ne refuse une vraie action.
// Mesure 7E-11-U : tous les chemins ci-dessous passent avec 70 blocs ; la compilation est refusée à 100 (« too complex »).
//
// Exécution : firebase emulators:exec --only firestore "node --test rules-tests/orders-update-expression-budget.rules.test.js"
const test = require('node:test');
const fs = require('node:fs');
const { initializeTestEnvironment, assertSucceeds } = require('@firebase/rules-unit-testing');

const MARGIN = 40;
const SRC = fs.readFileSync(process.env.FIRESTORE_RULES_PATH || require('node:path').join(__dirname, '..', 'firestore.rules'), 'utf8');
const HEAD = "allow update: if unchanged('cashPayment') && (isAdmin() ||";
if (SRC.split(HEAD).length !== 2) throw new Error('ancre de règle introuvable');
const withPadding = (n) => SRC.replace(HEAD, `allow update: if unchanged('cashPayment') && ${'(1 == 1) && '.repeat(n)}(isAdmin() ||`);

const v2 = {
  clientId: 'c', driverId: 'd', sellerId: 's', sellerType: 'restaurant', isPaid: true, paymentMethod: 'wallet', budget: 3500, shoppingBudget: 0,
  amountsVersion: 2, sellerStatus: 'ready', deliveryProofMode: 'qr_v1', productAmount: 3000, deliveryFee: 500, totalAmount: 3500,
  cashPayment: { status: 'unknown' }, cashRemittance: { status: 'pending' }, commissionStatus: 'charged', commissionPayerId: 'd', commissionAmount: 100,
  driverHistory: [{ driverId: 'd' }], partnerAcceptedAtMs: 1, readyAtMs: 2, deliveryFeePaid: 500, cashBreakdown: { a: 1 }, driverAcceptanceSelfie: 'u', deliveryPhoto: 'p',
};
const v1 = { clientId: 'c', driverId: 'd', sellerId: 's', isPaid: true, paymentMethod: 'wallet', budget: 500, shoppingBudget: 0, amountsVersion: 1, productAmount: 300, deliveryFee: 200, totalAmount: 500 };
// Mission 7E-17 : assigned->accepted et picked_up->delivered ne sont plus des chemins légitimes du client (acceptOrderCF / deliverOrderCF).
const CASES = [
  ['livreur v1 accepted->picked_up', 'd', { ...v1, status: 'accepted' }, { status: 'picked_up' }],
  ['livreur v1 meme statut', 'd', { ...v1, status: 'picked_up' }, { driverLat: 6.7 }],
  ['livreur v2 meme statut (commande pleine)', 'd', { ...v2, status: 'picked_up' }, { driverLat: 6.7 }],
  ['livreur v2 accepted->picked_up (pret, pleine)', 'd', { ...v2, status: 'accepted', deliveryProofMode: undefined }, { status: 'picked_up' }],
  ['client v1 annule pending', 'c', { ...v1, status: 'pending', driverId: null, isPaid: false }, { status: 'cancelled' }],
  ['client v1 note apres livraison', 'c', { ...v1, status: 'delivered' }, { rating: 5 }],
  ['client v2 note apres livraison (pleine)', 'c', { ...v2, status: 'delivered' }, { rating: 5 }],
  ['vendeur v1 sellerStatus', 's', { ...v1, status: 'accepted', sellerType: 'marketplace' }, { sellerStatus: 'preparing' }],
  ['boulangerie v1 preparing', 's', { ...v1, status: 'accepted', sellerType: 'boulangerie' }, { sellerStatus: 'preparing' }],
  ['super-admin', 'root', { ...v2, status: 'accepted' }, { status: 'cancelled' }],
];
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));


test('chaque chemin légitime de orders.update passe avec la marge de sécurité', async () => {
  const env = await initializeTestEnvironment({ projectId: 'demo-orders-budget', firestore: { rules: withPadding(MARGIN) } });
  try {
    for (const [label, uid, order, patch] of CASES) {
      await env.clearFirestore();
      await env.withSecurityRulesDisabled(async (ctx) => {
        await ctx.firestore().doc('admins/root').set({ role: 'super', isActive: true });
        await ctx.firestore().doc('partner_provisioning/s').set({ mustChangePassword: false });
        await ctx.firestore().doc('orders/o').set(clean(order));
      });
      await assertSucceeds(env.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore().doc('orders/o').update(patch))
        .catch((e) => { throw new Error(`${label} : ${String(e.message).slice(0, 160)}`); });
    }
  } finally { await env.cleanup(); }
});
