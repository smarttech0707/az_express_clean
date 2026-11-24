'use strict';

// L4 — paiement / annulation / livraison / clearBeneficiaryReview contre l'émulateur Firestore (vraies transactions Admin SDK :
// lectures avant écritures, rejeu, atomicité des journaux). Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon.
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
  const { Timestamp } = admin.firestore;
  const { onCall, HttpsError } = require('firebase-functions/v2/https');
  const { buildPayOrderFromWallet, buildCancelOrder, buildDeliverOrder } = require('../orderActions');
  const { buildAdminBilling } = require('../adminBilling');
  const { requireSuperAdmin } = require('../adminGuards');

  const RUN = `l4${Date.now().toString(36)}`;
  const deps = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const pay = buildPayOrderFromWallet({ ...deps, onCall });
  const cancel = buildCancelOrder({ ...deps, onCall, calculateCommission: async () => 100 });
  const deliver = buildDeliverOrder({ ...deps, onCall });
  const billing = buildAdminBilling({ ...deps, onCall, requireSuperAdmin, calculateCommission: async () => 100 });
  const before = () => Timestamp.fromMillis(Date.now() - 60_000);
  const tombAfter = () => ({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: 1 });
  const data = async (p) => (await db.doc(p).get()).data();
  const exists = async (p) => (await db.doc(p).get()).exists;
  const code = (e) => e && e.details && e.details.code;
  const asAdmin = { uid: `${RUN}root`, token: { firebase: { sign_in_provider: 'password' } } };

  test('émulateur : paiement -> débit, crédit et deux journaux déterministes dans la même transaction ; rejeu sans effet', async () => {
    const id = `${RUN}p1`; const c = `${id}c`; const d = `${id}d`;
    await db.doc(`orders/${id}`).set({ clientId: c, driverId: d, budget: 500, isPaid: false, status: 'accepted', createdAt: before() });
    await db.doc(`clients/${c}`).set({ wallet: 1000 }); await db.doc(`livreurs/${d}`).set({ wallet: 200 });
    await pay.run({ auth: { uid: c }, data: { orderId: id } });
    assert.equal((await data(`clients/${c}`)).wallet, 500);
    assert.equal((await data(`livreurs/${d}`)).wallet, 700);
    assert.equal((await data(`clients/${c}/wallet_transactions/pay_order_${id}`)).amount, 500);
    assert.equal((await data(`livreurs/${d}/wallet_transactions/earning_pay_order_${id}`)).amount, 500);
    await assert.rejects(() => pay.run({ auth: { uid: c }, data: { orderId: id } }));
    assert.equal((await data(`clients/${c}`)).wallet, 500);
    assert.equal((await data(`livreurs/${d}`)).wallet, 700);
  });

  test('émulateur : livreur en quarantaine / scellé -> paiement refusé, trace + verrou, puis levée admin sans crédit rétroactif', async () => {
    for (const phase of ['closing', 'sealed']) {
      const id = `${RUN}p2${phase}`; const c = `${id}c`; const d = `${id}d`;
      await db.doc(`orders/${id}`).set({ clientId: c, driverId: d, budget: 500, isPaid: false, status: 'accepted', createdAt: before() });
      await db.doc(`clients/${c}`).set({ wallet: 1000 }); await db.doc(`livreurs/${d}`).set({ wallet: 200 });
      await db.doc(`account_tombstones/${d}`).set({ ...tombAfter(), phase });
      await assert.rejects(() => pay.run({ auth: { uid: c }, data: { orderId: id } }), (e) => code(e) === 'BENEFICIARY_ACCOUNT_CLOSED');
      assert.equal((await data(`clients/${c}`)).wallet, 1000);
      assert.equal((await data(`livreurs/${d}`)).wallet, 200);
      assert.equal((await data(`reconciliation_flags/${id}_pay_beneficiary_refused`)).completed, false);
      assert.equal((await data(`orders/${id}`)).needsReview, true);
      await assert.rejects(() => pay.run({ auth: { uid: c }, data: { orderId: id } }), (e) => code(e) === 'ORDER_UNDER_REVIEW');
      await db.doc(`admins/${asAdmin.uid}`).set({ role: 'super', isActive: true });
      await assert.rejects(() => billing.run({ auth: asAdmin, data: { action: 'clearBeneficiaryReview', orderId: id, justification: 'Dossier vérifié par le support' } }), (e) => /BENEFICIARY_STILL_CLOSED/.test(e.message));
      assert.equal((await data(`orders/${id}`)).needsReview, true, 'toujours verrouillée');
      await db.doc(`account_tombstones/${d}`).delete(); // simulation d'un refus erroné : bénéficiaire en réalité actif
      const res = await billing.run({ auth: asAdmin, data: { action: 'clearBeneficiaryReview', orderId: id, justification: 'Dossier vérifié par le support' } });
      assert.equal(res.replay, false);
      assert.equal((await data(`orders/${id}`)).needsReview, false);
      assert.equal((await data(`livreurs/${d}`)).wallet, 200);
      const again = await billing.run({ auth: asAdmin, data: { action: 'clearBeneficiaryReview', orderId: id, justification: 'Dossier vérifié par le support' } });
      assert.equal(again.replay, true);
      await pay.run({ auth: { uid: c }, data: { orderId: id } });
      assert.equal((await data(`livreurs/${d}`)).wallet, 700, 'payé une seule fois après levée vérifiée');
    }
  });

  test('émulateur : annulation avec livreur scellé / absent / quarantaine -> client remboursé, aucun crédit, signalement, rejeu sans effet', async () => {
    for (const mode of ['sealed', 'closing', 'absent']) {
      const id = `${RUN}c${mode}`; const c = `${id}c`; const d = `${id}d`;
      await db.doc(`orders/${id}`).set({
        clientId: c, driverId: d, status: 'accepted', paymentMethod: 'wallet', isPaid: true, budget: 500,
        commissionStatus: 'charged', commissionAmount: 100, commissionPayerId: d, createdAt: before(),
      });
      await db.doc(`clients/${c}`).set({ wallet: 0 });
      if (mode !== 'absent') { await db.doc(`livreurs/${d}`).set({ wallet: 300 }); await db.doc(`account_tombstones/${d}`).set({ ...tombAfter(), phase: mode }); }
      await cancel.run({ auth: { uid: c }, data: { orderId: id } });
      assert.equal((await data(`orders/${id}`)).status, 'cancelled');
      assert.equal((await data(`clients/${c}`)).wallet, 500, `client remboursé (${mode})`);
      if (mode !== 'absent') assert.equal((await data(`livreurs/${d}`)).wallet, 300, `aucun crédit (${mode})`);
      else assert.equal(await exists(`livreurs/${d}`), false, 'aucun profil recréé');
      const flag = await data(`reconciliation_flags/${id}_beneficiary_closed`);
      assert.equal(flag.parties[0].amountWithheld, 100);
      assert.equal((await data(`orders/${id}`)).reviewReason, 'beneficiary_credit_omitted');
      await assert.rejects(() => cancel.run({ auth: { uid: c }, data: { orderId: id } }));
      assert.equal((await data(`clients/${c}`)).wallet, 500, 'aucun second remboursement');
    }
  });

  test('émulateur : livraison -> partenaire absent ou en quarantaine = refus sans écriture financière ; partenaire actif = crédité une fois', async () => {
    const mk = async (tag, partner) => {
      const id = `${RUN}d${tag}`; const dr = `${id}d`; const r = `${id}r`;
      await db.doc(`orders/${id}`).set({
        clientId: `${id}c`, driverId: dr, status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: true,
        sellerId: r, sellerType: 'restaurant', acceptedAt: before(), createdAt: before(),
      });
      await db.doc(`livreurs/${dr}`).set({ wallet: 0 });
      if (partner) await db.doc(`restaurants/${r}`).set({ wallet: 100 });
      return { id, dr, r };
    };
    const absent = await mk('abs', false);
    await assert.rejects(() => deliver.run({ auth: { uid: absent.dr }, data: { orderId: absent.id } }), (e) => code(e) === 'BENEFICIARY_ACCOUNT_CLOSED');
    assert.notEqual((await data(`orders/${absent.id}`)).status, 'delivered');
    assert.equal((await data(`livreurs/${absent.dr}`)).wallet, 0);
    assert.equal((await data(`reconciliation_flags/${absent.id}_deliver_beneficiary_refused`)).completed, false);

    const q = await mk('q', true);
    await db.doc(`account_tombstones/${q.r}`).set(tombAfter());
    await assert.rejects(() => deliver.run({ auth: { uid: q.dr }, data: { orderId: q.id } }), (e) => code(e) === 'BENEFICIARY_ACCOUNT_CLOSED');
    assert.notEqual((await data(`orders/${q.id}`)).status, 'delivered');
    assert.equal((await data(`restaurants/${q.r}`)).wallet, 100, 'aucun nouveau crédit');
    assert.equal((await data(`livreurs/${q.dr}`)).wallet, 0);
    assert.equal(await exists(`reconciliation_flags/${q.id}_partner_credit_held`), false);

    const ok = await mk('ok', true);
    await deliver.run({ auth: { uid: ok.dr }, data: { orderId: ok.id } });
    const w = (await data(`restaurants/${ok.r}`)).wallet;
    assert.ok(w > 100);
    await assert.rejects(() => deliver.run({ auth: { uid: ok.dr }, data: { orderId: ok.id } }));
    assert.equal((await data(`restaurants/${ok.r}`)).wallet, w, 'aucun double crédit');
  });
} else {
  test('orderActionsL4.emulator', { skip }, () => {});
}
