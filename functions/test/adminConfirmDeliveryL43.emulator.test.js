'use strict';

// L4.3 — adminConfirmDeliveryCF contre l'émulateur Firestore (vraies transactions Admin SDK) : partenaire ET livreur. Exige
// FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Aucun projet réel, aucun appel réseau.
//
// Concurrence : le scelleur est une TRANSACTION qui relit les deux portefeuilles et inscrit leurs valeurs dans le tombstone
// (sérialisable : aucune comparaison d'horodatages). `…AtSeal` = valeur vue au moment du scellement. Crédit validé AVANT le scellement
// => le scelleur voit les valeurs créditées (4500 / 1400) ; scellement AVANT => il voit les valeurs d'origine (1000 / 900) et la
// confirmation doit être refusée, aucun des deux bénéficiaires crédité. Violation = crédité alors qu'un scelleur a vu l'état d'avant.
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

  const RUN = `l43${Date.now().toString(36)}`;
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
  const journalCount = async (r, d) => (await db.collection(`restaurants/${r}/wallet_transactions`).get()).size + (await db.collection(`livreurs/${d}/wallet_transactions`).get()).size;

  test('émulateur : partenaire OU livreur fermé (ou les deux) -> refus intégral, ni l’un ni l’autre crédité, retry sans effet', async () => {
    const arrangers = {
      quarantine: (u, col) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0 }),
      sealed: (u, col) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'sealed', epoch: 0 }),
      anonymized: (u, col) => db.doc(`${col}/${u}`).update({ isDeleted: true }),
      absent: (u, col) => db.doc(`${col}/${u}`).delete(),
      unreadable: (u) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'bogus' }),
    };
    for (const [name, arrange] of Object.entries(arrangers)) {
      for (const target of ['partner', 'driver', 'both']) {
        const id = `${RUN}m${name}${target}`; const { r, d } = await seed(id);
        if (target !== 'driver') await arrange(r, 'restaurants');
        if (target !== 'partner') await arrange(d, 'livreurs');
        for (let i = 0; i < 2; i += 1) {
          await assert.rejects(() => confirm(id, `req-${id}-0000001`), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED', `${name}/${target}`);
        }
        assert.equal((await data(`orders/${id}`)).status, 'picked_up', `${name}/${target}`);
        if (name !== 'absent' && name !== 'anonymized') {
          assert.equal((await data(`restaurants/${r}`)).wallet, 1000, `${name}/${target} partenaire`);
          assert.equal((await data(`livreurs/${d}`)).wallet, 900, `${name}/${target} livreur`);
        } else {
          if (target !== 'driver' && name === 'anonymized') assert.equal((await data(`restaurants/${r}`)).wallet, 1000);
          if (target !== 'partner' && name === 'anonymized') assert.equal((await data(`livreurs/${d}`)).wallet, 900);
          if (target === 'driver') assert.equal((await data(`restaurants/${r}`)).wallet, 1000, 'partenaire actif non crédité');
          if (target === 'partner') assert.equal((await data(`livreurs/${d}`)).wallet, 900, 'livreur actif non crédité');
        }
        assert.equal(await journalCount(r, d), 0, `${name}/${target} : aucun journal`);
      }
    }
  });

  test('émulateur : partenaire et livreur actifs -> chacun crédité une fois, rejeu du même requestId sans doublon', async () => {
    const id = `${RUN}ok`; const { r, d } = await seed(id);
    await confirm(id, `req-${id}-0000001`);
    await confirm(id, `req-${id}-0000001`);
    assert.equal((await data(`restaurants/${r}`)).wallet, 4500);
    assert.equal((await data(`livreurs/${d}`)).wallet, 1400);
    assert.equal(await journalCount(r, d), 2);
  });

  for (const target of ['partner', 'driver', 'both']) {
    test(`émulateur : scellement (${target}) concurrent à la confirmation -> jamais de crédit après le tombstone, jamais de crédit partiel`, async () => {
      const tally = { credited: 0, refused: 0, emulatorRejects: 0 };
      for (let i = 0; i < ROUNDS; i += 1) {
        const id = `${RUN}c${target}${i}`; const { r, d } = await seed(id);
        const jitter = Math.floor(Math.random() * 250);
        const seal = (async () => {
          await sleep(jitter);
          await db.runTransaction(async (tx) => {
            const rw = (await tx.get(db.doc(`restaurants/${r}`))).data().wallet;
            const dw = (await tx.get(db.doc(`livreurs/${d}`))).data().wallet;
            const mark = { createdAt: FieldValue.serverTimestamp(), state: 'deleting', phase: 'closing', epoch: 0, partnerAtSeal: rw, driverAtSeal: dw };
            if (target !== 'driver') tx.set(db.doc(`account_tombstones/${r}`), mark);
            if (target !== 'partner') tx.set(db.doc(`account_tombstones/${d}`), mark);
          });
        })();
        const [op, sl] = await Promise.allSettled([confirm(id, `req-${id}-0000001`), seal]);
        const rw = (await data(`restaurants/${r}`)).wallet;
        const dw = (await data(`livreurs/${d}`)).wallet;
        const delivered = (await data(`orders/${id}`)).status === 'delivered';
        // Rejet d'infrastructure de l'émulateur (« Transaction is invalid or closed ») : compté, jamais confondu avec un succès ;
        // l'opération rejetée ne doit alors RIEN avoir validé. Un rejet métier doit être BENEFICIARY_ACCOUNT_CLOSED.
        if (op.status === 'rejected') {
          if (!(op.reason && op.reason.details && op.reason.details.code === 'BENEFICIARY_ACCOUNT_CLOSED')) tally.emulatorRejects += 1;
          assert.equal(delivered, false, `rejet mais livraison validée (${i}) : ${op.reason && op.reason.message}`);
        }
        assert.equal(delivered, op.status === 'fulfilled', `livrée si et seulement si la fonction a répondu (${i})`);
        if (sl.status === 'rejected') tally.emulatorRejects += 1;
        const sealers = [target !== 'driver' ? r : null, target !== 'partner' ? d : null].filter(Boolean);
        if (delivered) {
          tally.credited += 1;
          assert.equal(rw, 4500, `partenaire crédité (${i})`); assert.equal(dw, 1400, `livreur crédité (${i})`);
          for (const u of sealers) {
            const t = (await db.doc(`account_tombstones/${u}`).get()).data();
            if (t) { assert.equal(t.partnerAtSeal, 4500, `crédit validé AVANT le scellement (${i})`); assert.equal(t.driverAtSeal, 1400); }
          }
        } else {
          tally.refused += 1;
          assert.equal(rw, 1000, `refus : partenaire inchangé (${i})`); assert.equal(dw, 900, `refus : livreur inchangé (${i})`);
          assert.equal(await journalCount(r, d), 0);
        }
      }
      console.log(`# L43-race-${target} ${JSON.stringify(tally)}`);
      assert.ok(tally.credited + tally.refused === ROUNDS);
    });
  }
} else {
  test('adminConfirmDeliveryL43.emulator', { skip }, () => {});
}
