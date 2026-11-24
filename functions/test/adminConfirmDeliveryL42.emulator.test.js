'use strict';

// L4.2 — adminConfirmDeliveryCF contre l'émulateur Firestore (vraies transactions Admin SDK). Exige FIRESTORE_EMULATOR_HOST et un
// projet « demo-* » : ignoré sinon. Prouve (sur N entrelacements tirés) qu'un tombstone créé pendant la confirmation n'est jamais
// suivi d'un crédit : soit le crédit est validé AVANT le tombstone (horodatages serveur), soit la confirmation est refusée et le
// portefeuille du partenaire est inchangé. Aucun double crédit au rejeu.
const test = require('node:test');
const assert = require('node:assert/strict');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT = process.env.GCLOUD_PROJECT || '';
const skip = !HOST ? 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)'
  : (!/^demo-/.test(PROJECT) || /az-express/.test(PROJECT) ? 'projet non « demo-* » : refus de tourner' : false);

if (!skip) {
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  const db = admin.firestore();
  const { Timestamp, FieldValue } = admin.firestore;
  const { onCall, HttpsError } = require('firebase-functions/v2/https');
  const { buildDeliverOrder } = require('../orderActions');
  const { requireSuperAdmin } = require('../adminGuards');

  const RUN = `l42${Date.now().toString(36)}`;
  const ROUNDS = 30;
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const confirmFn = buildDeliverOrder({
    db, admin, HttpsError, onCall, checkRateLimit: async () => {}, logAudit: async () => {}, adminConfirm: true, requireSuperAdmin,
  });
  const adminUid = `${RUN}root`;
  const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
  const data = async (p) => (await db.doc(p).get()).data();
  const seed = async (id) => {
    const r = `${id}r`; const d = `${id}d`;
    await db.doc(`admins/${adminUid}`).set({ role: 'super', isActive: true });
    await db.doc(`orders/${id}`).set({
      clientId: `${id}c`, driverId: d, status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant', sellerId: r,
      paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000, budget: 500,
      shoppingBudget: 0, acceptedAt: Timestamp.fromMillis(Date.now() - 60_000), createdAt: Timestamp.fromMillis(Date.now() - 60_000),
    });
    await db.doc(`restaurants/${r}`).set({ wallet: 1000 });
    await db.doc(`livreurs/${d}`).set({ wallet: 900, isOnDelivery: true, currentOrderId: id });
    return { r, d };
  };
  const confirm = (id, requestId) => confirmFn.run({ auth: authOf(adminUid), data: { orderId: id, requestId, justification: 'Confirmation vérifiée avec le client', evidence: 'client_confirmed' } });

  test('émulateur : partenaire en quarantaine / scellé / anonymisé / absent -> aucun crédit, commande inchangée, retry sans effet', async () => {
    const states = {
      quarantine: (r) => db.doc(`account_tombstones/${r}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0 }),
      sealed: (r) => db.doc(`account_tombstones/${r}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'sealed', epoch: 0 }),
      anonymized: (r) => db.doc(`restaurants/${r}`).set({ wallet: 1000, isDeleted: true }),
      absent: (r) => db.doc(`restaurants/${r}`).delete(),
      unreadable: (r) => db.doc(`account_tombstones/${r}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'bogus' }),
    };
    for (const [name, arrange] of Object.entries(states)) {
      const id = `${RUN}s${name}`; const { r, d } = await seed(id);
      await arrange(r);
      for (let i = 0; i < 2; i += 1) {
        await assert.rejects(() => confirm(id, `req-${id}-0000001`), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED', name);
      }
      assert.equal((await data(`orders/${id}`)).status, 'picked_up', name);
      assert.equal((await data(`livreurs/${d}`)).wallet, 900, name);
      if (name !== 'absent' && name !== 'anonymized') assert.equal((await data(`restaurants/${r}`)).wallet, 1000, name);
      if (name === 'anonymized') assert.equal((await data(`restaurants/${r}`)).wallet, 1000);
      assert.equal((await db.collection(`restaurants/${r}/wallet_transactions`).get()).size, 0, `${name} : aucun journal`);
    }
  });

  test('émulateur : partenaire actif -> crédité une fois, rejeu du même requestId sans double crédit', async () => {
    const id = `${RUN}ok`; const { r } = await seed(id);
    await confirm(id, `req-${id}-0000001`);
    await confirm(id, `req-${id}-0000001`);
    assert.equal((await data(`restaurants/${r}`)).wallet, 4500);
    assert.equal((await db.collection(`restaurants/${r}/wallet_transactions`).get()).size, 1);
  });

  test('émulateur : tombstone créé pendant la confirmation -> jamais de crédit après le tombstone (transaction invalidée puis refus)', async () => {
    const tally = { credited: 0, refused: 0 };
    for (let i = 0; i < ROUNDS; i += 1) {
      const id = `${RUN}r${i}`; const { r } = await seed(id);
      const jitter = Math.floor(Math.random() * 250);
      // Le scelleur est une transaction qui relit le portefeuille du partenaire et inscrit sa valeur dans le tombstone : sérialisable,
      // donc `walletAtSeal` dit sans ambiguïté si le crédit a été validé AVANT (4500) ou APRÈS (1000) la création du tombstone.
      const seal = (async () => {
        await sleep(jitter);
        await db.runTransaction(async (tx) => {
          const w0 = (await tx.get(db.doc(`restaurants/${r}`))).data().wallet;
          tx.set(db.doc(`account_tombstones/${r}`), { createdAt: FieldValue.serverTimestamp(), state: 'deleting', phase: 'closing', epoch: 0, walletAtSeal: w0 });
        });
      })();
      const op = confirm(id, `req-${id}-0000001`).then(() => 'credited', (e) => { assert.equal(e.details && e.details.code, 'BENEFICIARY_ACCOUNT_CLOSED'); return 'refused'; });
      const [outcome] = await Promise.all([op, seal]);
      tally[outcome] += 1;
      const w = (await data(`restaurants/${r}`)).wallet;
      const atSeal = (await data(`account_tombstones/${r}`)).walletAtSeal;
      if (outcome === 'credited') {
        assert.equal(w, 4500);
        assert.equal(atSeal, 4500, `crédit validé AVANT le tombstone (round ${i})`);
      } else {
        assert.equal(w, 1000, `refus : portefeuille inchangé (round ${i})`);
        assert.equal(atSeal, 1000);
        assert.equal((await data(`orders/${id}`)).status, 'picked_up');
      }
    }
    console.log(`# L42-race ${JSON.stringify(tally)}`);
  });
} else {
  test('adminConfirmDeliveryL42.emulator', { skip }, () => {});
}
