'use strict';

// L3 — concurrence réelle des cinq exceptions contrôlées avec le scellement (T2b), contre l'émulateur Firestore (vraies transactions
// de l'Admin SDK). Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Aucun projet réel, aucun appel réseau.
//
// Propriété prouvée sur N entrelacements tirés (pas l'absence de toute course en production) : pour chaque fonction, l'opération engagée
// et le scellement ne sont jamais validés ENSEMBLE, jamais aucun des deux ; si l'opération a réussi, l'epoch est passé à 1 et le
// scellement a été refusé (closure_epoch_changed) ; sinon le compte est scellé et l'argent n'a pas bougé (aucun double débit ni crédit).
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT = process.env.GCLOUD_PROJECT || '';
const skip = !HOST ? 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)'
  : (!/^demo-/.test(PROJECT) || /az-express/.test(PROJECT) ? 'projet non « demo-* » : refus de tourner' : false);

if (!skip) {
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  const db = admin.firestore();
  const { Timestamp } = admin.firestore;
  const { onCall, HttpsError } = require('firebase-functions/v2/https');
  const protocol = require('../accountClosureProtocol');
  const { buildPayOrderFromWallet, buildCancelOrder, buildDeliverOrder, buildDeliverOrderWithProof } = require('../orderActions');
  const { buildEkClientConfirmOrder } = require('../ekbineOrders');
  const { hashPin, hashToken, sessionId } = require('../deliveryProofs');

  const ROUNDS = 15;
  const RUN = `l3${Date.now().toString(36)}`;
  const DIGEST = 'd'.repeat(64);
  const PEPPER = 'emulator-test-only-pepper';
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const jitter = () => sleep(Math.floor(Math.random() * 40));
  const before = () => Timestamp.fromMillis(Date.now() - 60_000);
  const deps = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  process.env.DELIVERY_PROOF_PEPPER = PEPPER;
  const fns = {
    pay: buildPayOrderFromWallet({ ...deps, onCall }),
    cancel: buildCancelOrder({ ...deps, onCall, calculateCommission: async () => 100 }),
    deliver: buildDeliverOrder({ ...deps, onCall }),
    proof: buildDeliverOrderWithProof({ ...deps, onCall, calculateCommission: async () => 100, deliveryProofPepper: { name: 'p' } }),
    ek: buildEkClientConfirmOrder({ ...deps, onCall: (h) => ({ run: h }) }),
  };

  const seedQuarantine = async (uid, collection) => {
    await db.doc(`account_tombstones/${uid}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: 1 });
    await db.doc(`account_deletions/${uid}`).set({ uid, role: collection, state: 'quarantined', lease: 'L', leaseUntil: Date.now() + 180000, closureEpoch: 0, snapshotDigest: DIGEST });
  };

  // Chaque scénario : seed(id, uid) crée les documents et retourne l'appel ; done(id) dit si l'opération a été validée ; money(id) les soldes.
  const SCENARIOS = {
    payOrderFromWalletCF: {
      collection: 'clients',
      seed: async (id, uid) => {
        await db.doc(`orders/${id}`).set({ clientId: uid, driverId: `${id}d`, budget: 500, isPaid: false, status: 'accepted', createdAt: before() });
        await db.doc(`clients/${uid}`).set({ wallet: 1000 });
        await db.doc(`livreurs/${id}d`).set({ wallet: 200 });
        return () => fns.pay.run({ auth: { uid }, data: { orderId: id } });
      },
      done: async (id) => (await db.doc(`orders/${id}`).get()).data().isPaid === true,
      money: async (id, uid) => [(await db.doc(`clients/${uid}`).get()).data().wallet, (await db.doc(`livreurs/${id}d`).get()).data().wallet],
      okMoney: [500, 700], untouched: [1000, 200],
    },
    cancelOrderCF: {
      collection: 'clients',
      seed: async (id, uid) => {
        await db.doc(`orders/${id}`).set({
          clientId: uid, driverId: `${id}d`, status: 'accepted', paymentMethod: 'wallet', isPaid: true, budget: 1000, createdAt: before(),
          commissionStatus: 'charged', commissionPayerId: `${id}d`, commissionAmount: 100,
        });
        await db.doc(`clients/${uid}`).set({ wallet: 0 });
        await db.doc(`livreurs/${id}d`).set({ wallet: 500 });
        return () => fns.cancel.run({ auth: { uid }, data: { orderId: id } });
      },
      done: async (id) => (await db.doc(`orders/${id}`).get()).data().status === 'cancelled',
      money: async (id, uid) => [(await db.doc(`clients/${uid}`).get()).data().wallet, (await db.doc(`livreurs/${id}d`).get()).data().wallet],
      okMoney: [1000, 600], untouched: [0, 500],
    },
    deliverOrderCF: {
      collection: 'livreurs',
      seed: async (id, uid) => {
        await db.doc(`orders/${id}`).set({
          clientId: 'c', driverId: uid, status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: true, sellerId: `${id}r`,
          sellerType: 'restaurant', acceptedAt: before(),
        });
        await db.doc(`livreurs/${uid}`).set({ wallet: 0 });
        await db.doc(`restaurants/${id}r`).set({ wallet: 100 });
        return () => fns.deliver.run({ auth: { uid }, data: { orderId: id } });
      },
      done: async (id) => (await db.doc(`orders/${id}`).get()).data().status === 'delivered',
      money: async (id, uid) => [(await db.doc(`livreurs/${uid}`).get()).data().wallet, (await db.doc(`restaurants/${id}r`).get()).data().wallet],
    },
    confirmOrderDeliveryWithProof: {
      collection: 'livreurs',
      seed: async (id, uid) => {
        const token = crypto.randomBytes(32).toString('base64url');
        const session = `delivery_proofs/${sessionId(id, 'delivery')}`;
        await db.doc(`orders/${id}`).set({
          clientId: 'c', driverId: uid, status: 'picked_up', paymentMethod: 'wallet', budget: 1000, isPaid: true, sellerId: `${id}r`,
          sellerType: 'restaurant', acceptedAt: before(), deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1,
        });
        await db.doc(session).set({ orderId: id, type: 'delivery', currentProofId: 'proof-v1', driverId: uid, assignmentVersion: 1 });
        await db.doc(`${session}/versions/proof-v1`).set({
          orderId: id, type: 'delivery', tokenHash: hashToken(token), pinHash: hashPin('987654', PEPPER, id, 'delivery'), status: 'active',
          expiresAt: Timestamp.fromMillis(Date.now() + 600_000), driverId: uid, assignmentVersion: 1, pinAttempts: 0,
        });
        await db.doc(`livreurs/${uid}`).set({ wallet: 0 });
        await db.doc(`restaurants/${id}r`).set({ wallet: 100 });
        return () => fns.proof.run({ auth: { uid }, data: { orderId: id, proofToken: token } });
      },
      done: async (id) => (await db.doc(`orders/${id}`).get()).data().status === 'delivered',
      money: async (id, uid) => [(await db.doc(`livreurs/${uid}`).get()).data().wallet, (await db.doc(`restaurants/${id}r`).get()).data().wallet],
    },
    ekClientConfirmOrder: {
      collection: 'clients',
      seed: async (id, uid) => {
        await db.doc(`ekbine_orders/${id}`).set({
          clientId: uid, agentId: `${id}a`, status: 'proof_sent', paymentMethod: 'wallet', amount: 1000, walletDebited: true, debitedAmount: 1000,
          debitLedgerId: `ekorder_${id}`, assignedAt: before(),
        });
        await db.doc(`clients/${uid}`).set({ wallet: 4000 });
        await db.doc(`clients/${uid}/wallet_transactions/ekorder_${id}`).set({ type: 'payment', amount: -1000, orderId: id, source: 'ekbine_order' });
        await db.doc(`ekbine_agents/${id}a`).set({ walletBalance: 0, totalCompleted: 0 });
        return () => fns.ek.run({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: id } });
      },
      done: async (id) => (await db.doc(`ekbine_orders/${id}`).get()).data().status === 'completed',
      money: async (id, uid) => [(await db.doc(`clients/${uid}`).get()).data().wallet, (await db.doc(`ekbine_agents/${id}a`).get()).data().walletBalance],
      okMoney: [4000, 1000], untouched: [4000, 0],
    },
  };

  for (const [fn, sc] of Object.entries(SCENARIOS)) {
    test(`L3-${fn} : opération engagée contre T2b (${ROUNDS} rondes) : jamais les deux, jamais aucun, argent exact`, { skip }, async () => {
      const tally = { opWon: 0, sealWon: 0, emulatorRejects: 0 };
      for (let i = 0; i < ROUNDS; i += 1) {
        const id = `${RUN}${fn.slice(0, 3)}${i}`;
        const uid = `${id}u`;
        const call = await sc.seed(id, uid);
        const initial = await sc.money(id, uid);
        await seedQuarantine(uid, sc.collection);
        const reinspect = async () => ({ blocking: false, reason: null, digest: DIGEST });
        const [op, seal] = await Promise.allSettled([
          jitter().then(call),
          jitter().then(() => protocol.sealTx(db, { uid, lease: 'L', reinspect, now: Date.now() })),
        ]);
        const tomb = (await db.doc(`account_tombstones/${uid}`).get()).data();
        const sealed = tomb.phase === 'sealed';
        const done = await sc.done(id);
        const money = await sc.money(id, uid);
        if (seal.status === 'rejected') assert.fail(`${fn}${i} : T2b a levé ${seal.reason.message}`);
        if (op.status === 'rejected') {
          const code = op.reason && op.reason.details && op.reason.details.code;
          if (code !== 'ACCOUNT_DELETION_IN_PROGRESS') {
            // Rejet de l'émulateur (transaction invalide / contention) : l'opération ne doit alors RIEN avoir validé.
            tally.emulatorRejects += 1;
            assert.equal(done, false, `${fn}${i} : rejet émulateur mais opération validée (${op.reason && op.reason.message})`);
          }
        }
        assert.equal(done, op.status === 'fulfilled', `${fn}${i} : opération validée si et seulement si elle a répondu`);
        assert.equal(sealed, seal.value.ok === true, 'scellé si et seulement si T2b a réussi');
        assert.notEqual(done && sealed, true, `${fn}${i} : opération ET scellement validés = violation`);
        assert.equal(done || sealed, true, `${fn}${i} : ni l’un ni l’autre`);
        if (done) {
          assert.equal(tomb.epoch, 1, 'epoch+1 écrit avec l’opération');
          assert.equal(seal.value.reason, 'closure_epoch_changed');
          if (sc.okMoney) assert.deepEqual(money, sc.okMoney, 'débit et crédit exactement une fois');
          tally.opWon += 1;
        } else {
          assert.deepEqual(money, initial, 'aucune écriture financière sans validation');
          if (sealed) tally.sealWon += 1;
        }
        // Le tombstone n'est jamais supprimé ni rouvert.
        assert.ok(['closing', 'sealed'].includes(tomb.phase));
        assert.ok(tomb.createdAt);
        if (sealed) assert.equal(tomb.epoch, 0);
      }
      console.log(`L3-${fn}`, JSON.stringify(tally));
    });
  }
}
