'use strict';

// L2 — preuves de concurrence du protocole de fermeture contre l'émulateur Firestore (vraies transactions de l'Admin SDK).
// Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Aucun projet réel, aucun appel réseau.
//
// Limite assumée (D-1, H1–H3) : l'émulateur reproduit la sérialisation transactionnelle mais pas la charge ni la latence de
// Firestore ; ces tests prouvent l'ABSENCE de violation sur N entrelacements tirés, pas l'absence de toute course en production.
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertSafeSealState } = require('./support/sealStateChecker');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT = process.env.GCLOUD_PROJECT || '';
const skip = !HOST ? 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)'
  : (!/^demo-/.test(PROJECT) || /az-express/.test(PROJECT) ? 'projet non « demo-* » : refus de tourner' : false);

if (!skip) {
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  const db = admin.firestore();
  const { Timestamp } = admin.firestore;
  const { HttpsError } = require('firebase-functions/v2/https');
  const protocol = require('../accountClosureProtocol');
  const { assertFinancialLock } = require('../accountClosureLock');
  const { buildAccountDeletion, QUIET_MS } = require('../accountDeletion');
  const { processFeexPayWebhookEvent } = require('../feexpayPayments');
  const { createFakeVerifier } = require('../feexpayVerification');

  const ROUNDS = 25;
  const RUN = `l2${Date.now().toString(36)}`;
  const DIGEST = 'd'.repeat(64);
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const jitter = () => sleep(Math.floor(Math.random() * 40));
  const seedClosing = async (uid, { epoch = 0, lease = 'L' } = {}) => {
    await db.doc(`clients/${uid}`).set({ wallet: 0 });
    await db.doc(`account_tombstones/${uid}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch, updatedAtMs: 1 });
    await db.doc(`account_deletions/${uid}`).set({ uid, role: 'client', state: 'quarantined', lease, leaseUntil: Date.now() + 180000, closureEpoch: epoch, snapshotDigest: DIGEST });
  };
  const reinspect = async () => ({ blocking: false, reason: null, digest: DIGEST });
  // Writer de catégorie B/C/D minimal : lit le verrou commun, écrit une marque ET l'epoch+1 dans la MÊME transaction.
  const writer = (uid, cls) => db.runTransaction(async (tx) => {
    const lock = await assertFinancialLock(tx, db, HttpsError, [{ collection: 'clients', id: uid }], cls);
    lock.applyTo(tx);
    tx.set(db.doc(`settlements_marker/${uid}`), { at: Date.now() });
    return lock;
  });

  test('L2-C1. writer B/C/D contre T2b : jamais les deux, jamais aucun (25 rondes par catégorie)', { skip }, async () => {
    const tally = { writerWon: 0, sealWon: 0 };
    for (const cls of ['B', 'C', 'D']) {
      for (let i = 0; i < ROUNDS; i += 1) {
        const uid = `${RUN}_c1${cls}${i}`;
        await seedClosing(uid);
        const [w, s] = await Promise.allSettled([
          jitter().then(() => writer(uid, cls)),
          jitter().then(() => protocol.sealTx(db, { uid, lease: 'L', reinspect, now: Date.now() })),
        ]);
        const marker = (await db.doc(`settlements_marker/${uid}`).get()).exists;
        const tomb = (await db.doc(`account_tombstones/${uid}`).get()).data();
        const sealed = tomb.phase === 'sealed';
        // Un rejet inattendu (hors refus métier) invaliderait la preuve.
        if (w.status === 'rejected') assert.equal(w.reason.details?.code, 'ACCOUNT_SEALED', `${cls}${i} : ${w.reason.message}`);
        if (s.status === 'rejected') assert.fail(`${cls}${i} : T2b a levé ${s.reason.message}`);
        assert.equal(marker, w.status === 'fulfilled', 'la marque existe si et seulement si le writer a validé');
        assert.equal(sealed, s.value.ok === true, 'scellé si et seulement si T2b a réussi');
        assert.notEqual(marker && sealed, true, `${cls}${i} : writer ET scellement validés = violation`);
        assert.equal(marker || sealed, true, `${cls}${i} : ni l'un ni l'autre`);
        if (marker) { assert.equal(tomb.epoch, 1, 'epoch+1 écrit avec le writer'); assert.equal(s.value.reason, 'closure_epoch_changed'); tally.writerWon += 1; } else { assert.equal(w.reason.details.code, 'ACCOUNT_SEALED'); tally.sealWon += 1; }
      }
    }
    console.log(`  L2-C1: ${JSON.stringify(tally)} sur ${3 * ROUNDS} rondes, aucune violation`);
  });

  test('L2-C1b. writer de catégorie A contre le tombstone « closing » : toujours refusé, aucune écriture', { skip }, async () => {
    for (let i = 0; i < 10; i += 1) {
      const uid = `${RUN}_c1a${i}`;
      await seedClosing(uid);
      await assert.rejects(writer(uid, 'A'), (e) => e.details?.code === 'ACCOUNT_CLOSING');
      assert.equal((await db.doc(`settlements_marker/${uid}`).get()).exists, false);
      assert.equal((await db.doc(`account_tombstones/${uid}`).get()).data().epoch, 0);
    }
  });

  // L'émulateur n'arbitre pas toujours deux transactions de même forme (lecture puis écriture des mêmes documents) : il rejette
  // l'une d'elles par INVALID_ARGUMENT « Transaction is invalid or closed » (code 3, non rejoué par le SDK), là où Firestore
  // renvoie ABORTED et où le SDK rejoue (cf. L0-F, et C1 de accountQuarantineConcurrency).
  // Ce rejet n'est JAMAIS un résultat métier valide en soi. Il n'est toléré que si, pour la même ronde :
  //   1. l'état final est sûr (assertSafeSealState : ni état à moitié écrit, ni suppression amorcée, ni compte modifié) ;
  //   2. le processus rejeté, rejoué comme le ferait la reprise, converge vers le résultat que le protocole prévoit
  //      (détenteur du bail : scellé ; sans bail : closure_lease_lost, jamais un succès).
  // Toute autre erreur échoue le test. Détail par ronde dans le fichier désigné par L2_DETAIL_FILE (hors dépôt), si défini.
  const EMU_REJECT = (e) => e && e.code === 3 && /Transaction is invalid or closed/.test(String(e.message));
  const detailLines = [];
  const note = (name, o) => { detailLines.push(JSON.stringify({ test: name, ...o })); };
  const flushDetail = () => { if (process.env.L2_DETAIL_FILE && detailLines.length) require('node:fs').appendFileSync(process.env.L2_DETAIL_FILE, `${detailLines.splice(0).join('\n')}\n`); };
  // Un processus de test : compte les tentatives de transaction (une lecture `reinspect` par exécution du callback, SDK compris).
  const runSeal = async (uid, lease, token, tally) => {
    const proc = { lease, token, attempts: 0, outcome: null, rejected: false };
    const counted = async (tx) => { proc.attempts += 1; return reinspect(tx); };
    try {
      proc.outcome = await jitter().then(() => protocol.sealTx(db, { uid, lease, reinspect: counted, now: Date.now(), token }));
    } catch (e) {
      if (!EMU_REJECT(e)) throw e;
      proc.rejected = true; tally.emulatorRejects += 1;
    }
    tally.attempts.push(proc.attempts);
    return proc;
  };
  const readState = async (uid) => ({
    tomb: (await db.doc(`account_tombstones/${uid}`).get()).data(),
    job: (await db.doc(`account_deletions/${uid}`).get()).data(),
    profile: (await db.doc(`clients/${uid}`).get()).data(),
  });

  test('L2-C7. deux T2b concurrents (même bail) : état final sûr, aucun succès sans bail, rejets rejoués jusqu’à convergence', { skip }, async () => {
    const tally = { emulatorRejects: 0, attempts: [], bothOk: 0, oneOk: 0, noneOk: 0, committedDespiteReject: 0, replays: 0 };
    for (let i = 0; i < 10; i += 1) {
      const uid = `${RUN}_c7${i}`;
      await seedClosing(uid);
      const procs = await Promise.all([runSeal(uid, 'L', 'tok-a', tally), runSeal(uid, 'L', 'tok-b', tally)]);
      const ok = procs.filter((p) => p.outcome && p.outcome.ok === true);
      const effective = ok.filter((p) => !p.outcome.already);
      assert.ok(effective.length <= 1, 'jamais deux scellements effectifs');
      if (ok.length === 2) tally.bothOk += 1; else if (ok.length === 1) tally.oneOk += 1; else tally.noneOk += 1;
      let state = await readState(uid);
      assertSafeSealState(state, { uid, digest: DIGEST });
      // Un rejet de l'émulateur après un commit réel serait un signal à part : on le compte et on exige la cohérence.
      if (state.tomb.phase === 'sealed' && effective.length === 0) tally.committedDespiteReject += 1;
      // Rejeu des processus rejetés (la reprise réelle) : le résultat doit être sûr et attendu.
      for (const p of procs.filter((x) => x.rejected)) {
        tally.replays += 1;
        const again = await protocol.sealTx(db, { uid, lease: p.lease, reinspect, now: Date.now(), token: p.token });
        assert.equal(again.ok, true, 'le détenteur du bail converge vers un scellé');
      }
      state = await readState(uid);
      assertSafeSealState(state, { uid, digest: DIGEST, expectSealed: true });
      assert.ok([`tok-a`, `tok-b`].includes(state.tomb.sealToken));
      note('C7', { round: i, outcomes: procs.map((p) => ({ lease: p.lease, rejected: p.rejected, ok: p.outcome && p.outcome.ok, already: p.outcome && p.outcome.already, attempts: p.attempts })), finalPhase: state.tomb.phase, sealToken: state.tomb.sealToken });
    }
    flushDetail();
    console.log(`  L2-C7: ${JSON.stringify({ ...tally, attempts: undefined, maxAttempts: Math.max(...tally.attempts), meanAttempts: +(tally.attempts.reduce((a, b) => a + b, 0) / tally.attempts.length).toFixed(2) })}`);
  });

  test('L2-C7b. deux processus avec des baux différents : seul le détenteur du bail peut sceller, jamais l’autre', { skip }, async () => {
    const tally = { emulatorRejects: 0, attempts: [], holderRejected: 0, otherRejected: 0, replays: 0, committedDespiteReject: 0 };
    for (let i = 0; i < 10; i += 1) {
      const uid = `${RUN}_c7b${i}`;
      await seedClosing(uid, { lease: 'mine' });
      const [mine, other] = await Promise.all([runSeal(uid, 'mine', 'tok-mine', tally), runSeal(uid, 'theirs', 'tok-theirs', tally)]);
      if (mine.rejected) tally.holderRejected += 1;
      if (other.rejected) tally.otherRejected += 1;
      // Aucun succès pour celui qui n'a pas le bail, quel que soit l'entrelacement.
      assert.notEqual(other.outcome && other.outcome.ok, true, 'succès sans bail valide');
      if (other.outcome) assert.equal(other.outcome.reason, 'closure_lease_lost');
      let state = await readState(uid);
      assertSafeSealState(state, { uid, digest: DIGEST });
      assert.notEqual(state.tomb.sealToken, 'tok-theirs');
      if (state.tomb.phase === 'sealed' && !(mine.outcome && mine.outcome.ok)) tally.committedDespiteReject += 1;
      // Rejeu : le détenteur converge ; l'autre reste refusé (bail perdu) même une fois le scellé posé.
      const holder = await protocol.sealTx(db, { uid, lease: 'mine', reinspect, now: Date.now(), token: 'tok-mine' });
      assert.equal(holder.ok, true);
      const intruder = await protocol.sealTx(db, { uid, lease: 'theirs', reinspect, now: Date.now(), token: 'tok-theirs' });
      assert.deepEqual([intruder.ok, intruder.reason], [false, 'closure_lease_lost']);
      tally.replays += 2;
      state = await readState(uid);
      assertSafeSealState(state, { uid, digest: DIGEST, expectSealed: true });
      assert.equal(state.tomb.sealToken, 'tok-mine'); assert.equal(state.job.sealToken, 'tok-mine');
      note('C7b', { round: i, holder: { rejected: mine.rejected, ok: mine.outcome && mine.outcome.ok, attempts: mine.attempts }, other: { rejected: other.rejected, ok: other.outcome && other.outcome.ok, reason: other.outcome && other.outcome.reason, attempts: other.attempts } });
    }
    flushDetail();
    console.log(`  L2-C7b: ${JSON.stringify({ ...tally, attempts: undefined, maxAttempts: Math.max(...tally.attempts) })}`);
  });

  // ── Suppression réelle (Auth simulé) sur Firestore émulé ────────────────────────────────────────────────────────
  const makeAuth = (calls, hooks = {}) => {
    let present = true;
    const missing = () => Object.assign(new Error('missing'), { code: 'auth/user-not-found' });
    return {
      updateUser: async (_u, p) => { if (!present) throw missing(); calls.push(p.disabled ? 'disable' : 'enable'); if (p.disabled && hooks.onDisable) await hooks.onDisable(); },
      revokeRefreshTokens: async () => { calls.push('revoke'); },
      deleteUser: async (uid) => { calls.push('delete'); hooks.atDelete && await hooks.atDelete(uid); present = false; },
      getUser: async () => { if (!present) throw missing(); return {}; },
    };
  };
  const apiFor = (auth, clock) => buildAccountDeletion({ db, auth, admin, HttpsError, clock, checkRateLimit: async () => {}, eraseAssets: async () => {} });
  const requestFor = (uid, now) => ({ auth: { uid, token: { auth_time: Math.floor(now / 1000), firebase: { sign_in_provider: 'password' } } }, data: { role: 'client', recoveryToken: 'a'.repeat(64), allProfilesConsent: true } });

  test('L2-flow. T1 -> T2 -> T2b -> F -> deleteUser -> T3 sur Firestore émulé, tombstone scellé à l’appel Auth', { skip }, async () => {
    await db.doc('operations_control/account_deletion').set({ enabled: true, inventoryVersion: 1 });
    const uid = `${RUN}_flow`;
    await db.doc(`clients/${uid}`).set({ wallet: 0, name: 'Test', phone: '0700000000' });
    let now = Date.now(); const calls = []; let atDelete = null;
    const api = apiFor(makeAuth(calls, { atDelete: async (u) => { atDelete = (await db.doc(`account_tombstones/${u}`).get()).data(); } }), () => now);
    await api.request(requestFor(uid, now));
    assert.deepEqual((({ phase, epoch, state }) => ({ phase, epoch, state }))((await db.doc(`account_tombstones/${uid}`).get()).data()), { phase: 'closing', epoch: 0, state: 'deleting' });
    now += QUIET_MS + 1;
    assert.equal((await api.process(uid)).status, 'completed');
    assert.equal(atDelete.phase, 'sealed'); assert.equal(atDelete.deleting, true); assert.equal(atDelete.authDeletedAtMs, undefined);
    const tomb = (await db.doc(`account_tombstones/${uid}`).get()).data();
    assert.equal(tomb.phase, 'sealed'); assert.equal(typeof tomb.authDeletedAtMs, 'number'); assert.match(tomb.snapshotDigest, /^[a-f0-9]{64}$/);
    assert.deepEqual(calls.slice(0, 3), ['disable', 'revoke', 'delete']);
    assert.equal((await db.doc(`clients/${uid}`).get()).data().isDeleted, true);
  });

  test('L2-flow-epoch. un vrai writer C validé entre T2 et T2b : T2b refuse, Auth réactivé, tombstone « closing » epoch+1, puis reprise', { skip }, async () => {
    await db.doc('operations_control/account_deletion').set({ enabled: true, inventoryVersion: 1 });
    const uid = `${RUN}_flowep`;
    await db.doc(`clients/${uid}`).set({ wallet: 0 });
    let now = Date.now(); const calls = []; let fired = false;
    const api = apiFor(makeAuth(calls, { onDisable: async () => { if (fired) return; fired = true; await writer(uid, 'C'); } }), () => now);
    await api.request(requestFor(uid, now));
    now += QUIET_MS + 1;
    await api.process(uid);
    let job = (await db.doc(`account_deletions/${uid}`).get()).data();
    assert.equal(job.reason, 'closure_epoch_changed');
    assert.deepEqual(calls, ['disable', 'revoke', 'enable']);
    const t = (await db.doc(`account_tombstones/${uid}`).get()).data();
    assert.equal(t.phase, 'closing'); assert.equal(t.epoch, 1);
    now += 60 * 60 * 1000 + 1;
    assert.equal((await api.process(uid)).status, 'completed');
    job = (await db.doc(`account_deletions/${uid}`).get()).data();
    assert.equal(job.closureEpoch, 1); assert.equal((await db.doc(`account_tombstones/${uid}`).get()).data().sealEpoch, 1);
  });

  // ── Réserve C2 (L0-F) : la VRAIE quarantaine/scellement du moteur contre le VRAI webhook ─────────────────────────
  // Mesure, ne conclut pas sur le seul émulateur. Invariants vérifiés (crédit unique, rien de perdu) ; les rejets de transaction
  // du webhook par l'émulateur (INVALID_ARGUMENT) sont comptés, leur message conservé, et rejoués comme le fait FeexPay.
  const verifier = createFakeVerifier(async () => ({ confirmed: true }));
  const collectionFor = (t) => (t === 'driver' ? 'livreurs' : 'clients');
  const hook = (body) => processFeexPayWebhookEvent({ db, admin, body, collectionFor, verifier, logAudit: async () => {}, logSecurityEvent: async () => {} });
  const seedPayment = async (uid, id) => {
    await db.doc(`clients/${uid}`).set({ wallet: 0 });
    await db.doc(`wallet_transactions/${id}`).set({ userId: uid, userType: 'client', amount: 1000, status: 'pending', paymentMethod: 'mtn', provider: 'FeexPay', credited: false, createdAt: Timestamp.fromMillis(Date.now() - 60000) });
  };
  const checkCredited = async (uid, id, label) => {
    assert.equal((await db.doc(`wallet_transactions/${id}`).get()).data().status, 'completed', `${label} : crédit perdu`);
    assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 1000, `${label} : solde ≠ un seul crédit`);
  };
  const replayIfRejected = async (h, id, errors) => {
    if (h.status !== 'rejected') return;
    errors.count += 1; errors.messages.add(String(h.reason.message));
    await hook({ order_id: id, status: 'SUCCESSFUL', amount: 1000 });
  };

  test('L2-C2real-T1. webhook contre le T1 réel : le moteur exclut T1 tant qu’un paiement est en attente ou crédité, invariants intacts', { skip }, async () => {
    await db.doc('operations_control/account_deletion').set({ enabled: true, inventoryVersion: 1 });
    const api = apiFor(makeAuth([]), Date.now);
    const rounds = Number(process.env.L2_C2_ROUNDS || ROUNDS);
    const errors = { count: 0, messages: new Set() }; let quarantined = 0;
    for (let i = 0; i < rounds; i += 1) {
      const uid = `${RUN}_c2t${i}`; const id = `${RUN}_payt${i}`;
      await seedPayment(uid, id);
      await db.doc(`account_deletions/${uid}`).set({ uid, role: 'client', state: 'pending', consentVerified: true, allProfilesConsent: true, requestCount: 1, attempts: 0, nextAttemptAt: Date.now() });
      const t1 = (async () => { await sleep(Math.floor(Math.random() * 80)); return api.process(uid); })();
      const [h] = await Promise.allSettled([hook({ order_id: id, status: 'SUCCESSFUL', amount: 1000 }), t1]);
      await replayIfRejected(h, id, errors);
      await checkCredited(uid, id, `T1 ronde ${i}`);
      if ((await db.doc(`account_tombstones/${uid}`).get()).exists) quarantined += 1;
    }
    assert.equal(quarantined, 0, 'un paiement en attente ou crédité empêche T1 (inspect) : aucun tombstone créé');
    console.log(`  L2-C2real-T1: ${rounds} rondes, ${errors.count} rejet(s) du webhook par l'émulateur ${errors.count ? JSON.stringify([...errors.messages]) : ''}`);
  });

  test('L2-C2real-T2b. webhook contre le scellement réel (profil lu comme inspect) : crédit unique, jamais perdu', { skip }, async () => {
    const rounds = Number(process.env.L2_C2_ROUNDS || ROUNDS);
    const errors = { count: 0, messages: new Set() }; let sealed = 0;
    for (let i = 0; i < rounds; i += 1) {
      const uid = `${RUN}_c2s${i}`; const id = `${RUN}_pays${i}`;
      await seedPayment(uid, id);
      await db.doc(`account_tombstones/${uid}`).set({ createdAt: Timestamp.now(), state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: 1 });
      await db.doc(`account_deletions/${uid}`).set({ uid, role: 'client', state: 'quarantined', lease: 'L', leaseUntil: Date.now() + 180000, closureEpoch: 0, snapshotDigest: DIGEST });
      const seal = (async () => { await sleep(Math.floor(Math.random() * 80)); return protocol.sealTx(db, { uid, lease: 'L', now: Date.now(),
        reinspect: async (tx) => { await tx.get(db.doc(`clients/${uid}`)); return { blocking: false, reason: null, digest: DIGEST }; } }); })();
      const [h, s] = await Promise.allSettled([hook({ order_id: id, status: 'SUCCESSFUL', amount: 1000 }), seal]);
      if (s.status === 'rejected') assert.fail(`ronde ${i} : T2b a levé ${s.reason.message}`);
      if (s.value.ok) sealed += 1;
      await replayIfRejected(h, id, errors);
      await checkCredited(uid, id, `T2b ronde ${i}`);
    }
    console.log(`  L2-C2real-T2b: ${rounds} rondes, ${sealed} scellée(s), ${errors.count} rejet(s) du webhook par l'émulateur ${errors.count ? JSON.stringify([...errors.messages]) : ''}`);
  });
} else {
  test('protocole de fermeture L2 (concurrence) — émulateur Firestore requis', { skip }, () => {});
}
