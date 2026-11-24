'use strict';

// L4.5.1 — refusePartnerOrder contre l'émulateur Firestore (vraies transactions Admin SDK) : refus concurrent au scellement du
// client et/ou du payeur de commission. Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon.
// Le scelleur est une TRANSACTION qui relit les deux portefeuilles et les inscrit dans le tombstone (marqueurs sérialisables, aucun
// horodatage). Refus validé AVANT le scellement => le scelleur voit des valeurs créditées ; scellement AVANT => valeurs d'origine et
// refus obligatoire, rien ne bouge. Les rejets d'infrastructure de l'émulateur sont comptés, jamais pris pour un succès.
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
  const { buildPartnerOrderAction } = require('../partnerOrderActions');
  const { requireSuperAdmin } = require('../adminGuards');
  const { calculateCommission } = require('../dispatch');

  const RUN = `l451${Date.now().toString(36)}`;
  const ROUNDS = 25;
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const fn = buildPartnerOrderAction({
    db, admin, HttpsError, onCall, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
    requireSuperAdmin, now: Date.now, isEnabled: () => true,
  });
  const data = async (p) => (await db.doc(p).get()).data();
  const seed = async (id) => {
    const c = `${id}c`; const d = `${id}d`; const r = `${id}r`;
    await db.doc(`orders/${id}`).set({
      clientId: c, driverId: d, status: 'accepted', type: 'restaurant', sellerType: 'restaurant', sellerId: r, paymentMethod: 'wallet',
      isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000, budget: 500, shoppingBudget: 0,
      commissionStatus: 'charged', commissionPayerId: d, commissionAmount: 100, createdAt: Timestamp.fromMillis(Date.now() - 60_000),
    });
    await db.doc(`clients/${c}`).set({ wallet: 16000 });
    await db.doc(`restaurants/${r}`).set({ wallet: 1000, isActive: true });
    await db.doc(`livreurs/${d}`).set({ wallet: 900, isOnDelivery: true, currentOrderId: id, isOnline: true });
    return { c, d, r };
  };
  const refuse = (id, r) => fn.run({ auth: { uid: r, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: id, action: 'refusePartnerOrder', reason: 'Rupture' } });
  const journalCount = async (c, d) => (await db.collection(`clients/${c}/wallet_transactions`).get()).size + (await db.collection(`livreurs/${d}/wallet_transactions`).get()).size;

  test('émulateur : client ou payeur fermé (5 états) -> refus, soldes et journaux intacts, retry sans effet', async () => {
    const arrangers = {
      quarantine: (u) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0 }),
      sealed: (u) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'sealed', epoch: 0 }),
      anonymized: (u, col) => db.doc(`${col}/${u}`).update({ isDeleted: true }),
      absent: (u, col) => db.doc(`${col}/${u}`).delete(),
      unreadable: (u) => db.doc(`account_tombstones/${u}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'bogus' }),
    };
    for (const [name, arrange] of Object.entries(arrangers)) {
      for (const target of ['client', 'payer']) {
        const id = `${RUN}m${name}${target}`; const { c, d, r } = await seed(id);
        if (target === 'client') await arrange(c, 'clients'); else await arrange(d, 'livreurs');
        for (let i = 0; i < 2; i += 1) {
          const res = await refuse(id, r);
          assert.equal(res.success, false, `${name}/${target}`);
          assert.equal(res.code, 'BENEFICIARY_ACCOUNT_CLOSED', `${name}/${target}`);
        }
        assert.equal((await data(`orders/${id}`)).status, 'accepted', `${name}/${target}`);
        if (!(name === 'absent' && target === 'client')) assert.equal((await data(`clients/${c}`)).wallet, 16000, `${name}/${target} client`);
        if (!(name === 'absent' && target === 'payer')) assert.equal((await data(`livreurs/${d}`)).wallet, 900, `${name}/${target} payeur`);
        assert.equal(await journalCount(c, d), 0, `${name}/${target} : aucun journal`);
      }
    }
  });

  test('émulateur : comptes actifs -> remboursement et commission rendus une fois, rejeu sans doublon', async () => {
    const id = `${RUN}ok`; const { c, d, r } = await seed(id);
    assert.equal((await refuse(id, r)).success, true);
    assert.equal((await refuse(id, r)).data.replay, true);
    assert.equal((await data(`clients/${c}`)).wallet, 20000);
    assert.equal((await data(`livreurs/${d}`)).wallet, 1000);
    assert.equal(await journalCount(c, d), 2);
  });

  for (const target of ['client', 'payer', 'both']) {
    test(`émulateur : scellement (${target}) concurrent au refus -> jamais de crédit après le tombstone, jamais de crédit partiel`, async () => {
      const tally = { credited: 0, refused: 0, emulatorRejects: 0 };
      for (let i = 0; i < ROUNDS; i += 1) {
        const id = `${RUN}c${target}${i}`; const { c, d, r } = await seed(id);
        const jitter = Math.floor(Math.random() * 250);
        const seal = (async () => {
          await sleep(jitter);
          await db.runTransaction(async (tx) => {
            const cw = (await tx.get(db.doc(`clients/${c}`))).data().wallet;
            const dw = (await tx.get(db.doc(`livreurs/${d}`))).data().wallet;
            const mark = { createdAt: FieldValue.serverTimestamp(), state: 'deleting', phase: 'closing', epoch: 0, clientAtSeal: cw, payerAtSeal: dw };
            if (target !== 'payer') tx.set(db.doc(`account_tombstones/${c}`), mark);
            if (target !== 'client') tx.set(db.doc(`account_tombstones/${d}`), mark);
          });
        })();
        const [op, sl] = await Promise.allSettled([refuse(id, r), seal]);
        const cw = (await data(`clients/${c}`)).wallet; const dw = (await data(`livreurs/${d}`)).wallet;
        const cancelled = (await data(`orders/${id}`)).status === 'cancelled';
        const ok = op.status === 'fulfilled' && op.value.success === true;
        if (op.status === 'rejected') { tally.emulatorRejects += 1; assert.equal(cancelled, false, `rejet mais commande annulée (${i})`); }
        if (sl.status === 'rejected') tally.emulatorRejects += 1;
        assert.equal(cancelled, ok, `annulée si et seulement si le refus a abouti (${i})`);
        if (ok) {
          tally.credited += 1;
          assert.equal(cw, 20000, `client crédité (${i})`); assert.equal(dw, 1000, `payeur crédité (${i})`);
          for (const u of [target !== 'payer' ? c : null, target !== 'client' ? d : null].filter(Boolean)) {
            const t = (await db.doc(`account_tombstones/${u}`).get()).data();
            if (t) { assert.equal(t.clientAtSeal, 20000, `crédit validé AVANT le scellement (${i})`); assert.equal(t.payerAtSeal, 1000); }
          }
        } else {
          tally.refused += 1;
          assert.equal(cw, 16000, `refus : client inchangé (${i})`); assert.equal(dw, 900, `refus : payeur inchangé (${i})`);
          assert.equal(await journalCount(c, d), 0);
        }
      }
      console.log(`# L451-race-${target} ${JSON.stringify(tally)}`);
      assert.equal(tally.credited + tally.refused + tally.emulatorRejects >= ROUNDS, true);
    });
  }
} else {
  test('partnerOrderRefusalL451.emulator', { skip }, () => {});
}
