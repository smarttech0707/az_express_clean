// Portefeuilles et journaux financiers côté client (Phase A, F5/F6/F8) : clients/{id}/wallet_transactions,
// sellers/{id}/wallet_transactions, wallet_transactions de premier niveau (FeexPay), tariff_quotes.
//
// Verrouille : (1) un client ne peut pas augmenter son solde ni toucher à celui d'un autre, (2) il ne peut pas
// fabriquer de fausses lignes de journal (identifiants / types réservés au serveur), (3) les 4 écrans historiques
// (blanchisserie, colis, eau, restaurant : `.add({type:'purchase', …})`) restent acceptés, (4) un vendeur ne peut plus
// écrire son journal, (5) un client ne peut pas créer de document ressemblant à un paiement FeexPay confirmé,
// (6) `tariff_quotes` (devis officiels) n'est ni lisible ni inscriptible par un client.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const AUTO_ID = 'aB3dE5gH7jK9mN1pQ3rS'; // 20 caractères alphanumériques, comme un identifiant automatique du SDK

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('clients/c1').set({ wallet: 1000, name: 'C1', cashOnDeliveryEnabled: true, fakeOrderCount: 0 });
    await db.doc('clients/c2').set({ wallet: 1000, name: 'C2', cashOnDeliveryEnabled: true, fakeOrderCount: 0 });
    await db.doc('sellers/s1').set({ wallet: 500, name: 'S1', type: 'seller' });
    await db.doc('admins/root').set({ role: 'super', isActive: true, permissions: [] });
    await db.doc('clients/c1/wallet_transactions/existing').set({ type: 'purchase', amount: 100, orderId: 'o1' });
    await db.doc('tariff_quotes/q1').set({ uid: 'c1', status: 'open', amount: 500 });
  });
  return e;
}

// Reproduit les 4 écrans historiques : .add({type, amount, description, orderId, createdAt: Timestamp.now()}).
const purchase = { type: 'purchase', amount: 3500, description: 'Colis — standard', orderId: 'o1' };
const journal = (db, owner = 'c1') => db.collection(`clients/${owner}/wallet_transactions`);

test('F6 solde : un client ne peut pas augmenter son wallet ni modifier celui d\'un autre', async () => {
  const e = await env('az-wl-wallet');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('clients/c1').update({ wallet: 999999 }));
    await assertFails(db.doc('clients/c1').update({ wallet: 1001 }));
    await assertFails(db.doc('clients/c2').update({ wallet: 0 }));
    await assertFails(db.doc('clients/c1').set({ wallet: 5000, name: 'C1' }));
    // Débit seul (paiement wallet historique, aligné sur walletDebitMatchesPaidOrder) : toujours accepté.
    await assertSucceeds(db.doc('clients/c1').update({ wallet: 500, lastPaidOrderId: 'o9' }));
  } finally { await e.cleanup(); }
});

test('F5 clients : identifiants déterministes du serveur refusés (preuves et collisions forgées)', async () => {
  const e = await env('az-wl-ids');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    for (const id of ['order_o1', 'recharge_request_r1', 'refund_o1', 'admin_refund_o1', 'forged', 'a'.repeat(19),
      'a'.repeat(21), 'aB3dE5gH7jK9mN1pQ3r_', 'aB3dE5gH7jK9mN1pQ3r-']) {
      await assertFails(db.doc(`clients/c1/wallet_transactions/${id}`).set({ ...purchase }));
    }
  } finally { await e.cleanup(); }
});

test('F5 clients : types serveur (refund, recharge, payment…) et champs non historiques refusés', async () => {
  const e = await env('az-wl-types');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    for (const type of ['refund', 'recharge', 'payment', 'earning', 'withdrawal', 'credit', 'commission', 'PURCHASE', '', 5]) {
      await assertFails(db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`).set({ ...purchase, type }));
    }
    await assertFails(db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`).set({ ...purchase, provider: 'feexpay' }));
    await assertFails(db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`).set({ ...purchase, txId: 'x' }));
    await assertFails(db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`).set({ ...purchase, status: 'completed' }));
    await assertFails(db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`).set({ amount: 100, orderId: 'o1' }));
  } finally { await e.cleanup(); }
});

test('F5 clients : montants, longueurs et formes bornés', async () => {
  const e = await env('az-wl-bounds');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    const ref = () => db.doc(`clients/c1/wallet_transactions/${AUTO_ID}`);
    for (const amount of [-1, 1000001, 10.5, '100', null]) await assertFails(ref().set({ ...purchase, amount }));
    await assertFails(ref().set({ ...purchase, description: 'x'.repeat(301) }));
    await assertFails(ref().set({ ...purchase, orderId: 'x'.repeat(129) }));
    await assertFails(ref().set({ ...purchase, createdAt: 'hier' }));
  } finally { await e.cleanup(); }
});

test('F5 clients : le flux historique des 4 écrans (add + Timestamp) reste accepté', async () => {
  const e = await env('az-wl-legacy');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    const ref = await assertSucceeds(journal(db).add({ ...purchase, createdAt: new Date() }));
    if (!/^[A-Za-z0-9]{20}$/.test(ref.id)) throw new Error(`identifiant automatique inattendu : ${ref.id}`);
    await assertSucceeds(journal(db).add({ type: 'purchase', amount: 0, createdAt: new Date() }));
    await assertSucceeds(journal(db).add({ ...purchase, orderId: null, createdAt: new Date() }));
  } finally { await e.cleanup(); }
});

test('F5 clients : aucune modification, suppression ni écriture dans le journal d\'un autre client', async () => {
  const e = await env('az-wl-immutable');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('clients/c1/wallet_transactions/existing').update({ amount: 999999 }));
    await assertFails(db.doc('clients/c1/wallet_transactions/existing').delete());
    await assertFails(journal(db, 'c2').add({ ...purchase, createdAt: new Date() }));
    const other = e.authenticatedContext('c2', password).firestore();
    await assertFails(other.doc('clients/c1/wallet_transactions/existing').get());
    await assertSucceeds(db.doc('clients/c1/wallet_transactions/existing').get());
  } finally { await e.cleanup(); }
});

test('F5 clients : l\'administrateur principal garde l\'écriture du journal', async () => {
  const e = await env('az-wl-admin');
  try {
    const db = e.authenticatedContext('root', password).firestore();
    await assertSucceeds(db.doc('clients/c1/wallet_transactions/admin_refund_o1').set({ type: 'refund', amount: 500 }));
  } finally { await e.cleanup(); }
});

test('F5 vendeurs : le propriétaire ne peut plus écrire son journal (lecture conservée)', async () => {
  const e = await env('az-wl-seller');
  try {
    const db = e.authenticatedContext('s1', password).firestore();
    await assertFails(db.collection('sellers/s1/wallet_transactions').add({ type: 'earning', amount: 999999, createdAt: new Date() }));
    await assertFails(db.doc('sellers/s1/wallet_transactions/sale_o1').set({ type: 'credit', amount: 1 }));
    await assertSucceeds(db.collection('sellers/s1/wallet_transactions').get());
    const admin = e.authenticatedContext('root', password).firestore();
    await assertSucceeds(admin.doc('sellers/s1/wallet_transactions/admin_x').set({ type: 'debit', amount: 10 }));
  } finally { await e.cleanup(); }
});

test('F8 FeexPay : un client ne peut pas créer de document ressemblant à un paiement confirmé', async () => {
  const e = await env('az-wl-feexpay');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    const forged = { userId: 'c1', uid: 'c1', type: 'recharge', amount: 50000, status: 'completed', credited: true, createdAt: new Date() };
    await assertFails(db.doc('wallet_transactions/FX_TX_1').set(forged));
    await assertFails(db.doc('wallet_transactions/FX_TX_1').set({ uid: 'c1', type: 'recharge', amount: 50000, createdAt: new Date() }));
    await assertFails(db.doc('wallet_transactions/FX_TX_1').set({ uid: 'c1', type: 'ekbine_payment', amount: 1, status: 'completed', createdAt: new Date() }));
    await assertFails(db.doc('wallet_transactions/FX_TX_1').set({ uid: 'c2', type: 'ekbine_payment', amount: 1, createdAt: new Date() }));
    // Seule écriture cliente conservée (journal E-Kbine, 4 champs) : ne porte ni userId, ni status, ni credited.
    await assertSucceeds(db.doc('wallet_transactions/EK_1').set({ uid: 'c1', type: 'ekbine_payment', amount: 800, createdAt: new Date() }));
    await assertFails(db.doc('wallet_transactions/EK_1').update({ status: 'completed', credited: true }));
  } finally { await e.cleanup(); }
});

test('Devis officiels : tariff_quotes n\'est ni lisible ni inscriptible par un client (même propriétaire du devis)', async () => {
  const e = await env('az-wl-quotes');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.doc('tariff_quotes/q1').get());
    await assertFails(db.doc('tariff_quotes/q1').update({ amount: 1, status: 'open' }));
    await assertFails(db.doc('tariff_quotes/q2').set({ uid: 'c1', status: 'open', amount: 1, expiresAtMs: 9999999999999 }));
    await assertFails(db.doc('tariff_quotes/q1').delete());
  } finally { await e.cleanup(); }
});
