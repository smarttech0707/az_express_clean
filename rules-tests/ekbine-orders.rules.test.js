// E-Kbine (Mission 5) : champs financiers et preuves de débit des commandes `ekbine_orders`.
//
// Verrouille : (1) un client ne peut pas créer une commande avec une « preuve » de débit/remboursement forgée,
// (2) ni modifier montant, gain agent, mode de paiement ou preuves lors d'une annulation/litige,
// (3) un agent ne peut pas modifier `agentEarning` & co. en passant la preuve (`proof_sent`),
// (4) les parcours historiques légitimes (création sans preuve, annulation, preuve, litige) restent acceptés
//     tant que les anciens chemins directs ne sont pas fermés (voir docs/FINANCIAL_EKBINE_2026-11-03.md).
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

const legacyOrder = {
  clientId: 'c1', operator: 'orange', serviceId: 'credit', amount: 1000, fee: 0, totalPaid: 1000,
  agentEarning: 1000, paymentMethod: 'wallet', status: 'pending',
};
const proven = { walletDebited: true, debitedAmount: 1000, debitLedgerId: 'ekorder_o1' };

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('clients/c1').set({ wallet: 0 });
    await db.doc('ekbine_agents/a1').set({ isVerified: true, isSuspended: false, subscriptionStatus: 'active', walletBalance: 0 });
    await db.doc('ekbine_orders/pending1').set({ ...legacyOrder, ...proven });
    await db.doc('ekbine_orders/await1').set({ ...legacyOrder, ...proven, status: 'awaiting_deposit', agentId: 'a1' });
    await db.doc('ekbine_orders/prog1').set({ ...legacyOrder, ...proven, status: 'in_progress', agentId: 'a1' });
    await db.doc('ekbine_orders/dc1').set({ ...legacyOrder, ...proven, status: 'deposit_confirmed', agentId: 'a1' });
    await db.doc('ekbine_orders/proof1').set({ ...legacyOrder, ...proven, status: 'proof_sent', agentId: 'a1' });
  });
  return e;
}

test('création directe : preuve de débit / remboursement / crédit forgée refusée', async () => {
  const e = await env('az-ek-create');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    for (const forged of [proven, { walletDebited: true }, { debitedAmount: 99999 }, { refunded: false },
      { refundedAmount: 0 }, { agentCredited: 1000 }, { creditReason: 'proven' }, { idempotencyKey: 'k'.repeat(20) },
      { source: 'ek_create_cf' }]) {
      await assertFails(db.collection('ekbine_orders').add({ ...legacyOrder, ...forged }));
    }
    // Forme historique (ancienne application) : toujours acceptée tant que le chemin direct n'est pas fermé.
    await assertSucceeds(db.collection('ekbine_orders').add({ ...legacyOrder }));
  } finally { await e.cleanup(); }
});

test('client : annulation légitime acceptée ; montant, gain agent, preuves, mode de paiement inchangés', async () => {
  const e = await env('az-ek-client');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    for (const tamper of [{ amount: 1 }, { agentEarning: 99999 }, { totalPaid: 1 }, { fee: 500 }, { paymentMethod: 'cash' },
      { walletDebited: false }, { debitedAmount: 1 }, { refunded: true }, { refundedAmount: 1000 }, { agentCredited: 5 }]) {
      await assertFails(db.doc('ekbine_orders/pending1').update({ status: 'cancelled', ...tamper }));
    }
    await assertSucceeds(db.doc('ekbine_orders/pending1').update({ status: 'cancelled', cancellationReason: 'x' }));
    await assertFails(db.doc('ekbine_orders/proof1').update({ status: 'disputed', agentEarning: 5 }));
    await assertSucceeds(db.doc('ekbine_orders/proof1').update({ status: 'disputed' }));
    // Annulation d'une commande prépayée dont l'agent est affecté : uniquement par ekCancelOrderCF (remboursement).
    await assertFails(db.doc('ekbine_orders/dc1').update({ status: 'cancelled', cancellationReason: 'x' }));
    // Jamais de completed en direct.
    await assertFails(db.doc('ekbine_orders/await1').update({ status: 'completed' }));
  } finally { await e.cleanup(); }
});

test('agent : preuve d\'exécution acceptée, mais jamais de modification du gain ou des preuves', async () => {
  const e = await env('az-ek-agent');
  try {
    const db = e.authenticatedContext('a1', password).firestore();
    for (const tamper of [{ agentEarning: 99999 }, { amount: 5000 }, { debitedAmount: 5000 }, { walletDebited: false }, { paymentMethod: 'cash' }]) {
      await assertFails(db.doc('ekbine_orders/prog1').update({ status: 'proof_sent', proofUrl: 'u', ...tamper }));
    }
    await assertSucceeds(db.doc('ekbine_orders/prog1').update({ status: 'proof_sent', proofUrl: 'u' }));
    // Un agent ne s'octroie pas un solde.
    await assertFails(db.doc('ekbine_agents/a1').update({ walletBalance: 5000 }));
  } finally { await e.cleanup(); }
});

test('autre client / anonyme : aucune lecture ni modification', async () => {
  const e = await env('az-ek-other');
  try {
    const other = e.authenticatedContext('c2', password).firestore();
    await assertFails(other.doc('ekbine_orders/pending1').get());
    await assertFails(other.doc('ekbine_orders/pending1').update({ status: 'cancelled' }));
    const anon = e.authenticatedContext('x', { firebase: { sign_in_provider: 'anonymous' } }).firestore();
    await assertFails(anon.collection('ekbine_orders').add({ ...legacyOrder, clientId: 'x' }));
  } finally { await e.cleanup(); }
});
