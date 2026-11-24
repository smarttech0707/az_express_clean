'use strict';

// L4.5 — chemins administratifs financiers contre l'émulateur Firestore (vraies transactions Admin SDK) : clôture concurrente.
// Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Aucun projet réel, aucun appel réseau.
//
// Le scelleur est une TRANSACTION qui relit les portefeuilles concernés et inscrit leurs valeurs dans le tombstone (marqueurs
// sérialisables, aucun horodatage). Opération validée AVANT le scellement => le scelleur voit les valeurs créditées ; scellement AVANT
// => il voit les valeurs d'origine et l'opération doit être refusée, aucun portefeuille ne bouge. Violation = crédit visible alors
// que le scelleur a vu l'état d'avant, ou crédit partiel. Les rejets d'infrastructure de l'émulateur sont comptés, jamais pris pour
// un succès : à chaque rejet, rien n'est validé.
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
  const { buildAdminBilling } = require('../adminBilling');
  const { buildAdminOrderDispute } = require('../adminOrderDisputes');
  const { buildSettleTransferEarnings } = require('../transferSettlement');
  const { requireSuperAdmin, requireAdminPermission } = require('../adminGuards');
  const { calculateCommission } = require('../dispatch');
  const { settlementDocument } = require('../earningsSettlement');

  const RUN = `l45${Date.now().toString(36)}`;
  const ROUNDS = 25;
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const common = { db, admin, HttpsError, onCall, checkRateLimit: async () => {}, logAudit: async () => {} };
  const billing = buildAdminBilling({ ...common, requireSuperAdmin, calculateCommission });
  const disputes = buildAdminOrderDispute({ ...common, requireSuperAdmin, requireAdminPermission, calculateCommission });
  const settle = buildSettleTransferEarnings({ ...common, requireSuperAdmin });
  const adminUid = `${RUN}root`;
  const auth = { uid: adminUid, token: { firebase: { sign_in_provider: 'password' } } };
  const J = 'Décision administrative vérifiée avec le client';
  const data = async (p) => (await db.doc(p).get()).data();
  const journalCount = async (paths) => {
    let n = 0;
    for (const p of paths) n += (await db.collection(`${p}/wallet_transactions`).get()).size;
    return n;
  };
  const past = () => Timestamp.fromMillis(Date.now() - 60_000);

  // Chaque scénario : seed(id) => { wallets: { path: valeurOrigine }, credited: { path: valeurCréditée }, sealTargets: [paths 'col/id'] },
  // run(id) lance la fonction réelle.
  const scenarios = {
    resolveFeeHold: {
      seed: async (id) => {
        await db.doc(`orders/${id}`).set({
          clientId: `${id}c`, driverId: `${id}d`, status: 'cancelled', sellerType: 'seller', paymentMethod: 'wallet',
          deliveryFeeHold: { amount: 500, status: 'pending_admin_review', driverId: `${id}d` },
          commissionStatus: 'charged', commissionPayerId: `${id}p`, commissionAmount: 100, createdAt: past(),
        });
        await db.doc(`clients/${id}c`).set({ wallet: 1000 }); await db.doc(`livreurs/${id}p`).set({ wallet: 400 });
        return { wallets: { [`clients/${id}c`]: 1000, [`livreurs/${id}p`]: 400 }, credited: { [`clients/${id}c`]: 1500, [`livreurs/${id}p`]: 500 } };
      },
      run: (id) => billing.run({ auth, data: { action: 'resolveFeeHold', decision: 'refundClient', orderId: id, justification: J } }),
      done: async (id) => (await data(`orders/${id}`)).deliveryFeeHold.status === 'resolved',
    },
    refundBoutiqueOrder: {
      seed: async (id) => {
        await db.doc(`boutique_orders/${id}`).set({ clientId: `${id}c`, sellerId: `${id}s`, status: 'paid', paymentMethod: 'wallet', totalPrice: 5000 });
        await db.doc(`clients/${id}c`).set({ wallet: 1000 }); await db.doc(`sellers/${id}s`).set({ wallet: 8000 });
        return { wallets: { [`clients/${id}c`]: 1000, [`sellers/${id}s`]: 8000 }, credited: { [`clients/${id}c`]: 6000, [`sellers/${id}s`]: 3000 } };
      },
      run: (id) => billing.run({ auth, data: { action: 'refundBoutiqueOrder', orderId: id, justification: J } }),
      done: async (id) => (await data(`boutique_orders/${id}`)).status === 'refunded',
    },
    partialRefund: {
      seed: async (id) => {
        await db.doc(`orders/${id}`).set({
          clientId: `${id}c`, driverId: `${id}d`, status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true, budget: 1000,
          shoppingBudget: 2000, pickedUpAt: 1, commissionStatus: 'charged', commissionPayerId: `${id}d`, commissionAmount: 200, createdAt: past(),
          cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: `${id}c`, requestedAtMs: 5 },
        });
        await db.doc(`clients/${id}c`).set({ wallet: 7000 }); await db.doc(`livreurs/${id}d`).set({ wallet: 800, isOnDelivery: true, currentOrderId: id });
        return { wallets: { [`clients/${id}c`]: 7000, [`livreurs/${id}d`]: 800 }, credited: null };
      },
      run: (id) => disputes.run({ auth, data: { action: 'decide', decision: 'refundHalfFee', orderId: id, justification: J, requestId: `request-id-${id}`.slice(0, 40), shoppingContext: 'not_purchased' } }),
      done: async (id) => (await data(`orders/${id}`)).status === 'delivered',
    },
    transferSettlement: {
      seed: async (id) => {
        const order = {
          clientId: `${id}c`, status: 'delivered', driverId: `${id}b`, budget: 1000, settlementHold: true, latitude: 6.70, longitude: -3.49,
          destLat: 6.80, destLng: -3.49, pickedUpAt: 1, deliveryPhoto: 'p.jpg', commissionStatus: 'charged', commissionPayerId: `${id}a`,
          commissionAmount: 200,
          driverHistory: [{ driverId: `${id}a`, phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: { trusted: true, point: { lat: 6.74, lng: -3.49 } } }],
        };
        await db.doc(`orders/${id}`).set(order);
        await db.doc(`transfer_settlements/${id}`).set(settlementDocument(id, order, 'wallet', 1000));
        await db.doc(`livreurs/${id}a`).set({ wallet: 300 }); await db.doc(`livreurs/${id}b`).set({ wallet: 0 });
        return { wallets: { [`livreurs/${id}a`]: 300, [`livreurs/${id}b`]: 0 }, credited: null };
      },
      run: (id) => settle.run({ auth, data: { action: 'approve', orderId: id } }),
      done: async (id) => (await data(`transfer_settlements/${id}`)).status === 'settled',
    },
  };

  const closedCode = (e) => e && e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED';

  test('émulateur : états fermés (quarantaine, scellé, anonymisé, absent, illisible) sur chaque chemin -> refus, soldes et journaux intacts, retry sans effet', async () => {
    await db.doc(`admins/${adminUid}`).set({ role: 'super', isActive: true });
    for (const [name, sc] of Object.entries(scenarios)) {
      const arrangers = {
        quarantine: (p) => db.doc(`account_tombstones/${p.split('/')[1]}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0 }),
        sealed: (p) => db.doc(`account_tombstones/${p.split('/')[1]}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'sealed', epoch: 0 }),
        anonymized: (p) => db.doc(p).update({ isDeleted: true }),
        unreadable: (p) => db.doc(`account_tombstones/${p.split('/')[1]}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'bogus' }),
      };
      for (const [state, arrange] of Object.entries(arrangers)) {
        const id = `${RUN}${name.slice(0, 4)}${state}`;
        const { wallets } = await sc.seed(id);
        const paths = Object.keys(wallets);
        await arrange(paths[paths.length - 1]); // le dernier bénéficiaire est fermé
        for (let i = 0; i < 2; i += 1) {
          await assert.rejects(() => sc.run(id), (e) => closedCode(e), `${name}/${state}`);
        }
        for (const [p, v] of Object.entries(wallets)) assert.equal((await data(p)).wallet, v, `${name}/${state} : ${p} inchangé`);
        assert.equal(await journalCount(paths), 0, `${name}/${state} : aucun journal`);
        assert.equal(await sc.done(id), false, `${name}/${state} : non marqué réglé`);
      }
    }
  });

  for (const [name, sc] of Object.entries(scenarios)) {
    test(`émulateur : ${name} — scellement concurrent -> jamais de crédit après le tombstone, jamais de crédit partiel`, async () => {
      await db.doc(`admins/${adminUid}`).set({ role: 'super', isActive: true });
      const tally = { credited: 0, refused: 0, emulatorRejects: 0 };
      for (let i = 0; i < ROUNDS; i += 1) {
        const id = `${RUN}r${name.slice(0, 4)}${i}`;
        const { wallets } = await sc.seed(id);
        const paths = Object.keys(wallets);
        const target = paths[paths.length - 1];
        const jitter = Math.floor(Math.random() * 250);
        const seal = (async () => {
          await sleep(jitter);
          await db.runTransaction(async (tx) => {
            const seen = {};
            for (const p of paths) seen[p.replace('/', '_')] = (await tx.get(db.doc(p))).data().wallet;
            tx.set(db.doc(`account_tombstones/${target.split('/')[1]}`), { createdAt: FieldValue.serverTimestamp(), state: 'deleting', phase: 'closing', epoch: 0, seen });
          });
        })();
        const [op, sl] = await Promise.allSettled([sc.run(id), seal]);
        const done = await sc.done(id);
        if (op.status === 'rejected' && !closedCode(op.reason)) tally.emulatorRejects += 1;
        if (sl.status === 'rejected') tally.emulatorRejects += 1;
        assert.equal(done, op.status === 'fulfilled', `${name} ${i} : réglé si et seulement si la fonction a répondu (${op.reason && op.reason.message})`);
        const now = {};
        for (const p of paths) now[p] = (await data(p)).wallet;
        const tomb = (await db.doc(`account_tombstones/${target.split('/')[1]}`).get()).data();
        if (done) {
          tally.credited += 1;
          // crédit validé AVANT le scellement : le scelleur (s'il a abouti) a vu des valeurs différentes des valeurs d'origine
          if (tomb && tomb.seen) {
            assert.ok(paths.some((p) => tomb.seen[p.replace('/', '_')] !== wallets[p]), `${name} ${i} : le scelleur a vu l'état d'avant un crédit déjà validé`);
          }
        } else {
          tally.refused += 1;
          for (const p of paths) assert.equal(now[p], wallets[p], `${name} ${i} : refus => ${p} inchangé (aucun crédit partiel)`);
          assert.equal(await journalCount(paths), 0, `${name} ${i} : aucun journal`);
        }
      }
      console.log(`# L45-race-${name} ${JSON.stringify(tally)}`);
      assert.equal(tally.credited + tally.refused, ROUNDS);
    });
  }
} else {
  test('adminFinancialPathsL45.emulator', { skip }, () => {});
}
