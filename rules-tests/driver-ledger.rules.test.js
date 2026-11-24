// Journal financier du livreur : livreurs/{id}/wallet_transactions.
//
// Les Cloud Functions (annulation, libération avant récupération) lisent ce journal comme PREUVE d'un
// prélèvement de commission (`commission_<commande>_<livreur>`). Avant correctif, le propriétaire pouvait y
// créer n'importe quel document aux champs autorisés, donc fabriquer cette preuve avec le montant de son choix.
// Ce fichier verrouille : (1) les identifiants et types réservés au serveur sont refusés, (2) l'ancien flux
// client légitime (`_logTransaction` : ligne `commission`, identifiant automatique du SDK) reste accepté,
// (3) montants / champs / longueurs bornés, (4) aucune modification ni suppression par le propriétaire.
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
    await db.doc('livreurs/d1').set({ wallet: 1000 });
    await db.doc('livreurs/d2').set({ wallet: 1000 });
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('livreurs/d1/wallet_transactions/existing').set({ type: 'commission', amount: 100, orderId: 'o1' });
  });
  return e;
}

const legit = { type: 'commission', amount: 100, description: 'Commission AZ Express', orderId: 'o1' };
const journal = (db, owner = 'd1') => db.collection(`livreurs/${owner}/wallet_transactions`);

test('identifiants réservés au serveur : toute création par le livreur est refusée (preuves forgées)', async () => {
  const e = await env('az-ledger-reserved');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    const forged = { type: 'commission', amount: 100000, orderId: 'o1' };
    for (const id of [
      'commission_o1_d1', 'commission_refund_o1_d1', 'earning_o1_d1', 'fee_hold_commission_o1',
      'recharge_abc', 'forged', 'zz', 'a'.repeat(19), 'a'.repeat(21), 'aB3dE5gH7jK9mN1pQ3r_', 'aB3dE5gH7jK9mN1pQ3r-', 'aB3dE5gH7jK9mN1p.3rS',
    ]) {
      await assertFails(db.doc(`livreurs/d1/wallet_transactions/${id}`).set(forged));
    }
  } finally { await e.cleanup(); }
});

test('types réservés au serveur refusés même avec un identifiant automatique (earning, refund, recharge…)', async () => {
  const e = await env('az-ledger-types');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    for (const type of ['earning', 'refund', 'recharge', 'withdrawal', 'commission_refund', 'credit', 'COMMISSION', '', 5]) {
      await assertFails(db.doc(`livreurs/d1/wallet_transactions/${AUTO_ID}`).set({ ...legit, type }));
    }
    await assertFails(db.doc(`livreurs/d1/wallet_transactions/${AUTO_ID}`).set({ amount: 100, orderId: 'o1' }));
  } finally { await e.cleanup(); }
});

test('ancien flux client conservé : ligne `commission`, identifiant automatique du SDK (add), champs historiques', async () => {
  const e = await env('az-ledger-legacy');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    // Reproduit FirestoreService._logTransaction : .add({type, amount, description, orderId, createdAt}).
    const ref = await assertSucceeds(journal(db).add({ ...legit, createdAt: new Date() }));
    if (!/^[A-Za-z0-9]{20}$/.test(ref.id)) throw new Error(`identifiant automatique inattendu : ${ref.id}`);
    await assertSucceeds(journal(db).add({ type: 'commission', amount: 200, description: 'x', orderId: null, createdAt: new Date() }));
    await assertSucceeds(journal(db).add({ type: 'commission', amount: 0, createdAt: new Date() }));
    await assertSucceeds(db.doc(`livreurs/d1/wallet_transactions/${AUTO_ID}`).set({ type: 'commission', amount: 100 }));
  } finally { await e.cleanup(); }
});

test('montant : entier 0..1000 seulement', async () => {
  const e = await env('az-ledger-amount');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    for (const amount of [-1, 1001, 100000, 99999999999, 5.5, '100', null, true]) {
      await assertFails(journal(db).add({ ...legit, amount }));
    }
    await assertSucceeds(journal(db).add({ ...legit, amount: 1000 }));
  } finally { await e.cleanup(); }
});

test('champs : liste fermée, provider/txId/status interdits, types et longueurs bornés', async () => {
  const e = await env('az-ledger-fields');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    for (const extra of [{ provider: 'x' }, { txId: 'y' }, { status: 'ok' }, { credited: true }, { userId: 'd1' }]) {
      await assertFails(journal(db).add({ ...legit, ...extra }));
    }
    await assertFails(journal(db).add({ ...legit, description: 'x'.repeat(301) }));
    await assertFails(journal(db).add({ ...legit, description: 5 }));
    await assertFails(journal(db).add({ ...legit, orderId: 5 }));
    await assertFails(journal(db).add({ ...legit, orderId: 'o'.repeat(129) }));
    await assertFails(journal(db).add({ ...legit, createdAt: 'hier' }));
    await assertSucceeds(journal(db).add({ ...legit, description: 'x'.repeat(300), orderId: 'o'.repeat(128) }));
  } finally { await e.cleanup(); }
});

test('journal d\'un autre livreur, sans connexion, ou via un autre rôle : refusé', async () => {
  const e = await env('az-ledger-owner');
  try {
    await assertFails(journal(e.authenticatedContext('d2', password).firestore(), 'd1').add(legit));
    await assertFails(journal(e.unauthenticatedContext().firestore(), 'd1').add(legit));
    await assertFails(journal(e.authenticatedContext('d1', password).firestore(), 'd2').add(legit));
  } finally { await e.cleanup(); }
});

test('modification et suppression : refusées au propriétaire, y compris sur sa propre ligne', async () => {
  const e = await env('az-ledger-immutable');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    const ref = db.doc('livreurs/d1/wallet_transactions/existing');
    await assertFails(ref.update({ amount: 1 }));
    await assertFails(ref.set({ type: 'commission', amount: 1, orderId: 'o1' }));
    await assertFails(ref.delete());
    const created = await assertSucceeds(journal(db).add(legit));
    await assertFails(created.update({ amount: 1 }));
    await assertFails(created.delete());
  } finally { await e.cleanup(); }
});

test('lecture : propriétaire seulement ; admin : écriture et suppression inchangées (recharge, remboursement…)', async () => {
  const e = await env('az-ledger-read-admin');
  try {
    const d1 = e.authenticatedContext('d1', password).firestore();
    await assertSucceeds(d1.doc('livreurs/d1/wallet_transactions/existing').get());
    await assertSucceeds(journal(d1).orderBy('createdAt', 'desc').limit(100).get().catch(() => journal(d1).get()));
    await assertFails(e.authenticatedContext('d2', password).firestore().doc('livreurs/d1/wallet_transactions/existing').get());
    await assertFails(e.unauthenticatedContext().firestore().doc('livreurs/d1/wallet_transactions/existing').get());
    const admin = e.authenticatedContext('root', password).firestore();
    await assertSucceeds(admin.doc('livreurs/d1/wallet_transactions/recharge_abc').set({ type: 'recharge', amount: 1000, adminId: 'root' }));
    await assertSucceeds(admin.doc('livreurs/d1/wallet_transactions/existing').delete());
  } finally { await e.cleanup(); }
});

test('le solde reste protégé : la fausse ligne de journal ne change pas le wallet et le wallet ne peut pas augmenter', async () => {
  const e = await env('az-ledger-wallet');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    await assertFails(db.doc('livreurs/d1/wallet_transactions/commission_o1_d1').set({ type: 'commission', amount: 100000, orderId: 'o1' }));
    await assertFails(db.doc('livreurs/d1').update({ wallet: 99999 }));
    await e.withSecurityRulesDisabled(async (ctx) => {
      const snap = await ctx.firestore().doc('livreurs/d1').get();
      if (snap.data().wallet !== 1000) throw new Error('wallet modifié');
    });
  } finally { await e.cleanup(); }
});
