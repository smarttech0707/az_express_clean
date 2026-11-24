'use strict';

// Mission 7E-69 : scénarios de CONCURRENCE de la quarantaine contre l'émulateur Firestore (vraies transactions de l'Admin SDK).
// Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Aucune donnée réelle, aucun projet réel, aucun appel
// réseau (axios est remplacé). Les timestamps serveur donnent l'ordre de validation (commit) de chaque écriture.
//
// Limite assumée : l'émulateur reproduit la sérialisation transactionnelle de Firestore mais pas sa charge ni sa latence réelles ;
// ces tests prouvent l'ABSENCE de violation sur N entrelacements tirés, pas l'absence de toute course possible en production.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT = process.env.GCLOUD_PROJECT || '';
const skip = !HOST ? 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)'
  : (!/^demo-/.test(PROJECT) || /az-express/.test(PROJECT) ? 'projet non « demo-* » : refus de tourner' : false);

process.env.FUNCTIONS_EMULATOR = 'true';
process.env.FEEXPAY_SHOP_ID = 'shop-test';
for (const k of ['FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'OPENAI_API_KEY', 'DELIVERY_PROOF_PEPPER']) {
  process.env[k] = 'test-only-not-a-secret';
}

if (!skip) {
  const here = createRequire(require.resolve('../index.js'));
  const axiosKey = here.resolve('axios');
  const axiosCalls = [];
  require.cache[axiosKey] = { id: axiosKey, filename: axiosKey, loaded: true, exports: {
    post: async (u) => { axiosCalls.push(u); return { data: { token: 'tok', url: 'https://pay.example/x', reference: 'REF' } }; },
    get: async () => ({ data: {} }),
  } };
  const { HttpsError, onCall } = require('firebase-functions/v2/https');
  const fns = require('../index.js');
  const admin = require('firebase-admin');
  const db = admin.firestore();
  const { FieldValue, Timestamp } = admin.firestore;
  const { buildConfirmAction } = require('../azia/pendingActions');
  const { buildAccountDeletion } = require('../accountDeletion');
  const { processFeexPayWebhookEvent } = require('../feexpayPayments');
  const { createFakeVerifier } = require('../feexpayVerification');

  const ROUNDS = 25;
  const ms = (t) => (t && t.toMillis ? t.toMillis() : null);
  // Ordre de VALIDATION : createTime/updateTime attribués par le serveur au commit (un serverTimestamp, lui, peut être évalué
  // avant l'obtention des verrous et ne prouve donc pas l'ordre de sérialisation).
  const committed = (snap) => BigInt(snap.createTime.seconds) * 1000000000n + BigInt(snap.createTime.nanoseconds);
  const refused = { A: [], A2: [], B2: [] };
  const wipe = async (...paths) => { for (const p of paths) await db.doc(p).delete(); };
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  // Même forme que le moteur (accountDeletion.js) : lecture du profil, création durable du tombstone ET mise à jour du profil
  // (isSuspended) dans la même transaction — c'est cette écriture du profil qui entre en conflit avec une garde ayant lu le profil.
  // Décalage aléatoire 0-80 ms pour couvrir des entrelacements différents.
  const quarantine = async (uid) => {
    await sleep(Math.floor(Math.random() * 80));
    return db.runTransaction(async (tx) => {
      await tx.get(db.collection('clients').doc(uid));
      tx.create(db.collection('account_tombstones').doc(uid), { createdAt: FieldValue.serverTimestamp(), state: 'deleting' });
      tx.update(db.collection('clients').doc(uid), { isSuspended: true, isOnline: false });
    });
  };

  test('A. recharge contre quarantaine : aucune demande validée APRÈS le tombstone', { skip }, async () => {
    let created = 0, refusedN = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_ca${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 0 });
      const [r] = await Promise.allSettled([
        fns.initiateFeexPayPayment.run({ auth: { uid, token: {} }, data: { amount: 1000, phone: '+2250700000000', operator: 'mtn', userType: 'client' } }),
        quarantine(uid),
      ]);
      const tombSnap = await db.doc(`account_tombstones/${uid}`).get();
      const pays = await db.collection('wallet_transactions').where('userId', '==', uid).get();
      assert.ok(tombSnap.exists, 'le tombstone est toujours créé');
      for (const d of pays.docs) assert.ok(committed(d) <= committed(tombSnap), `${uid}: paiement validé après la quarantaine`);
      if (r.status === 'fulfilled') created += 1; else { refusedN += 1; refused.A.push(String(r.reason.message).slice(0, 70)); }
      if (r.status === 'rejected') assert.equal(pays.size, 0, 'refus ⇒ aucune demande');
    }
    console.log(`  A: ${created} créées avant, ${refusedN} refusées ; motifs : ${JSON.stringify([...new Set(refused.A)])}`);
  });

  test('A2. retrait contre quarantaine : le solde n’est débité que si le retrait précède le tombstone', { skip }, async () => {
    let done = 0, refusedN = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_cw${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 5000 });
      const [r] = await Promise.allSettled([
        fns.initiateWithdrawal.run({ auth: { uid, token: {} }, data: { amount: 500, phone: '+2250700000000', operator: 'mtn', userType: 'client', userName: 'T' } }),
        quarantine(uid),
      ]);
      const tombSnap = await db.doc(`account_tombstones/${uid}`).get();
      const wds = await db.collection('withdrawal_requests').where('userId', '==', uid).get();
      for (const d of wds.docs) assert.ok(committed(d) <= committed(tombSnap), `${uid}: retrait validé après la quarantaine`);
      if (r.status === 'rejected') { assert.equal(wds.size, 0, 'refus ⇒ aucune demande de retrait'); assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 5000, 'refus ⇒ solde intact'); refusedN += 1; refused.A2.push(String(r.reason.message).slice(0, 70)); } else { done += 1; assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 4500, 'retrait validé ⇒ débit unique'); }
    }
    console.log(`  A2: ${done} retraits avant, ${refusedN} refusés ; motifs : ${JSON.stringify([...new Set(refused.A2)])}`);
  });

  test('B. AZ IA : deux confirmations simultanées → une seule exécution', { skip }, async () => {
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_cb${i}`, actionId = `qz71_act${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 0 });
      await db.doc(`ai_pending_actions/${actionId}`).set({ uid, toolName: 'create_delivery_order', toolInput: {}, status: 'pending', amount: 1, expiresAt: Timestamp.fromMillis(Date.now() + 60000) });
      // confirmHandler s'exécute DANS la transaction, que le SDK peut rejouer : seul l'effet VALIDÉ compte (compteur transactionnel).
      const toolsByName = new Map([['create_delivery_order', { confirmHandler: async (tx) => { tx.set(db.doc(`exec_marks/${uid}`), { n: FieldValue.increment(1) }, { merge: true }); return { orderId: 'o' }; } }]]);
      const confirm = buildConfirmAction({ db, admin, onCall, logAudit: async () => {}, HttpsError, toolsByName });
      const res = await Promise.allSettled([1, 2, 3].map(() => confirm.run({ auth: { uid }, data: { actionId } })));
      assert.equal(res.filter((x) => x.status === 'fulfilled').length, 1, 'une seule confirmation réussit');
      assert.equal((await db.doc(`exec_marks/${uid}`).get()).data().n, 1, 'effet validé une seule fois');
    }
  });

  test('B2. AZ IA : confirmation contre quarantaine → jamais exécutée après le tombstone', { skip }, async () => {
    let ran = 0, blocked = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_cc${i}`, actionId = `qz71_actq${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 0 });
      await db.doc(`ai_pending_actions/${actionId}`).set({ uid, toolName: 't', toolInput: {}, status: 'pending', amount: 1, expiresAt: Timestamp.fromMillis(Date.now() + 60000) });
      const stamps = {};
      const toolsByName = new Map([['t', { confirmHandler: async (tx) => { tx.set(db.doc(`exec_marks/${uid}`), { at: FieldValue.serverTimestamp() }); return {}; } }]]);
      const confirm = buildConfirmAction({ db, admin, onCall, logAudit: async () => {}, HttpsError, toolsByName });
      const [r] = await Promise.allSettled([confirm.run({ auth: { uid }, data: { actionId } }), quarantine(uid)]);
      const tombSnap = await db.doc(`account_tombstones/${uid}`).get();
      const mark = await db.doc(`exec_marks/${uid}`).get();
      if (mark.exists) { assert.ok(BigInt(mark.updateTime.seconds) * 1000000000n + BigInt(mark.updateTime.nanoseconds) <= committed(tombSnap), `${uid}: action exécutée après la quarantaine`); ran += 1; } else blocked += 1;
      if (r.status === 'rejected') { assert.equal((await db.doc(`ai_pending_actions/${actionId}`).get()).data().status, 'pending'); refused.B2.push(String(r.reason.message).slice(0, 70)); }
      void stamps;
    }
    console.log(`  B2: ${ran} exécutées avant, ${blocked} bloquées ; motifs : ${JSON.stringify([...new Set(refused.B2)])}`);
  });

  test('E. caractérisation : lecture d’un tombstone ABSENT seule vs lecture du profil EXISTANT (primitive transactionnelle)', { skip }, async () => {
    // Informatif : documente ce que l'émulateur garantit. La conception retenue ne dépend PAS du premier cas (voir rapport).
    const outcome = { absentOnly: 'committed-without-conflict', withProfile: 'committed-without-conflict' };
    for (const mode of ['absentOnly', 'withProfile']) {
      const uid = `qz71_ce_${mode}`;
      await db.doc(`clients/${uid}`).set({ wallet: 0 });
      let attempts = 0;
      await db.runTransaction(async (tx) => {
        attempts += 1;
        await tx.get(db.doc(`account_tombstones/${uid}`));
        if (mode === 'withProfile') await tx.get(db.doc(`clients/${uid}`));
        if (attempts === 1) await quarantine(uid); // quarantaine validée pendant que la garde a déjà lu
        tx.set(db.doc(`exec_marks/${uid}`), { attempts });
      });
      if (attempts > 1) outcome[mode] = 'conflict-detected-and-retried';
    }
    console.log('  E:', JSON.stringify(outcome));
    assert.equal(outcome.withProfile, 'conflict-detected-and-retried', 'la lecture du profil existant, écrit par la quarantaine, doit provoquer un conflit');
  });

  // ── C. Webhook FeexPay ────────────────────────────────────────────────────────────────────────────────────────
  const verifier = createFakeVerifier(async () => ({ confirmed: true }));
  const collectionFor = (t) => (t === 'driver' ? 'livreurs' : 'clients');
  const hook = (body, over = {}) => processFeexPayWebhookEvent({
    db, admin, body, collectionFor, verifier, logAudit: async () => {}, logSecurityEvent: async () => {}, ...over,
  });
  const seedPay = async (id, uid, over = {}, profile = { wallet: 0 }) => {
    await db.doc(`clients/${uid}`).set(profile);
    await db.doc(`wallet_transactions/${id}`).set({ userId: uid, userType: 'client', amount: 1000, status: 'pending', paymentMethod: 'mtn', provider: 'FeexPay', credited: false, createdAt: Timestamp.fromMillis(Date.now() - 60000), ...over });
  };

  test('C1. trois webhooks identiques concurrents (+ nouvelle livraison) → exactement un crédit, jamais de double', { skip }, async () => {
    // L'émulateur peut rejeter une transaction en cas d'interblocage (INVALID_ARGUMENT « Transaction is invalid or closed »),
    // là où Firestore renvoie ABORTED et où le SDK réessaie. Constaté AUSSI sur le code d'avant 7E-68 (comparaison 7E-69) : on
    // vérifie donc l'invariant financier, en rejouant le webhook comme le ferait FeexPay après un échec (idempotence).
    let engineErrors = 0;
    for (let i = 0; i < 6; i++) {
      await seedPay(`qz71_P${i}`, `qz71_cu${i}`);
      const r = await Promise.allSettled([1, 2, 3].map(() => hook({ order_id: `qz71_P${i}`, status: 'SUCCESSFUL', amount: 1000 })));
      engineErrors += r.filter((x) => x.status === 'rejected').length;
      assert.ok(r.filter((x) => x.status === 'fulfilled' && x.value.outcome === 'credited').length <= 1, 'jamais deux crédits');
      const redelivery = await hook({ order_id: `qz71_P${i}`, status: 'SUCCESSFUL', amount: 1000 });
      assert.ok(['credited', 'already_processed'].includes(redelivery.outcome));
      assert.equal((await db.doc(`clients/qz71_cu${i}`).get()).data().wallet, 1000, 'solde = un seul crédit');
      assert.equal((await db.doc(`wallet_transactions/qz71_P${i}`).get()).data().status, 'completed');
    }
    console.log(`  C1: 6 rondes, ${engineErrors} rejet(s) de transaction par l'émulateur, aucun double crédit`);
  });

  test('C2. webhook vs quarantaine : crédit si antérieur au tombstone, sinon mise en attente — jamais de crédit perdu ni double', { skip }, async () => {
    let credited = 0, held = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_cq${i}`;
      await seedPay(`qz71_Q${i}`, uid);
      await Promise.all([hook({ order_id: `qz71_Q${i}`, status: 'SUCCESSFUL', amount: 1000 }), quarantine(uid)]);
      const pay = (await db.doc(`wallet_transactions/qz71_Q${i}`).get()).data();
      const wallet = (await db.doc(`clients/${uid}`).get()).data().wallet;
      // Payé avant la quarantaine (demande créée il y a 60 s) ⇒ toujours crédité ; jamais « held » ni perdu.
      assert.equal(pay.status, 'completed'); assert.equal(wallet, 1000); credited += 1;
    }
    // Paiement créé APRÈS le tombstone ⇒ mis en attente, solde inchangé.
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz71_ch${i}`;
      await db.doc(`account_tombstones/${uid}`).set({ createdAt: Timestamp.fromMillis(Date.now() - 600000), state: 'deleting' });
      await seedPay(`qz71_H${i}`, uid, { createdAt: Timestamp.fromMillis(Date.now() - 1000) });
      const r = await Promise.all([1, 2].map(() => hook({ order_id: `qz71_H${i}`, status: 'SUCCESSFUL', amount: 1000 })));
      assert.equal(r.filter((x) => x.outcome === 'held_for_review').length, 1);
      assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 0);
      assert.equal((await db.doc(`wallet_transactions/qz71_H${i}`).get()).data().status, 'held_for_review'); held += 1;
    }
    console.log(`  C2: ${credited} crédités (antérieurs), ${held} mis en attente (postérieurs)`);
  });

  test('C3. profil anonymisé : webhook ne crédite pas ; référence inconnue → 404 ; montant incorrect → 400 sans crédit', { skip }, async () => {
    await seedPay('qz71_AN1', 'qz71_can1', {}, { wallet: 0, isDeleted: true });
    assert.equal((await hook({ order_id: 'qz71_AN1', status: 'SUCCESSFUL', amount: 1000 })).outcome, 'held_for_review');
    assert.equal((await db.doc('clients/qz71_can1').get()).data().wallet, 0);
    const unknown = await hook({ order_id: 'NOPE', status: 'SUCCESSFUL', amount: 1000 });
    assert.equal(unknown.httpStatus, 404);
    await seedPay('qz71_AM1', 'qz71_cam1');
    const wrong = await hook({ order_id: 'qz71_AM1', status: 'SUCCESSFUL', amount: 1 }, { strictAmount: true });
    assert.equal(wrong.httpStatus, 400);
    assert.equal((await db.doc('clients/qz71_cam1').get()).data().wallet, 0);
  });

  // ── D. Moteur : l'inspection finale tient compte des opérations non terminales ────────────────────────────────────
  test('D. quarantaine puis opération financière tardive : la suppression est bloquée, Auth intact, profil non anonymisé', { skip }, async () => {
    const uid = 'qz71_cd1';
    await db.doc('operations_control/account_deletion').set({ enabled: true, inventoryVersion: 1 });
    await db.doc(`clients/${uid}`).set({ wallet: 0, name: 'Test', phone: '0700000000' });
    let now = Date.now();
    const authCalls = [];
    const auth = { updateUser: async () => authCalls.push('disable'), revokeRefreshTokens: async () => authCalls.push('revoke'), deleteUser: async () => authCalls.push('delete') };
    const api = buildAccountDeletion({ db, auth, admin, HttpsError, clock: () => now, checkRateLimit: async () => {}, eraseAssets: async () => {} });
    const req = { auth: { uid, token: { auth_time: Math.floor(now / 1000), firebase: { sign_in_provider: 'password' } } }, data: { role: 'client', recoveryToken: 'a'.repeat(64), allProfilesConsent: true } };
    await api.request(req);
    assert.ok((await db.doc(`account_tombstones/${uid}`).get()).exists, 'quarantaine posée');
    // Opération tardive : une recharge créditée (solde non nul) PUIS un retrait en cours.
    await db.doc(`clients/${uid}`).update({ wallet: 1000 });
    now += 16 * 60 * 1000;
    await api.process(uid);
    let job = (await db.doc(`account_deletions/${uid}`).get()).data();
    assert.notEqual(job.state, 'completed');
    assert.equal(job.reason, 'balance_regularization_required');
    assert.deepEqual(authCalls, [], 'aucune suppression Auth');
    assert.notEqual((await db.doc(`clients/${uid}`).get()).data().isDeleted, true);
    // Solde remis à zéro MAIS retrait non terminal : toujours bloqué.
    await db.doc(`clients/${uid}`).update({ wallet: 0 });
    await db.doc('withdrawal_requests/qz71_WD1').set({ userId: uid, userType: 'client', amount: 500, status: 'processing' });
    now += 61 * 60 * 1000;
    await api.process(uid);
    job = (await db.doc(`account_deletions/${uid}`).get()).data();
    assert.notEqual(job.state, 'completed');
    assert.equal(job.reason, 'active_or_unresolved_operation');
    assert.deepEqual(authCalls, []);
  });
} else {
  // Sans émulateur, aucun scénario n'est enregistré : on le DIT (ignoré) plutôt que de compter un faux « réussi ».
  test('concurrence quarantaine/paiement (lot 2A) — émulateur Firestore requis', { skip }, () => {});
}
