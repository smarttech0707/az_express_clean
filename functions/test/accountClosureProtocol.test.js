'use strict';

// L2 — protocole de fermeture : planificateurs purs, séquence T1 -> T2 -> T2b -> F -> suppression Auth -> T3 et reprises après
// interruption, contre un faux Firestore/Auth en mémoire (aucun accès cloud). Les preuves de concurrence sont dans
// accountClosureProtocol.emulator.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const protocol = require('../accountClosureProtocol');
const { interpretTombstone } = require('../accountClosureState');
const { assertFinancialLock } = require('../accountClosureLock');
const { HttpsError } = require('firebase-functions/v2/https');
const { makeWorld, UID } = require('./support/closureWorld');
const { MAX_ATTEMPTS } = require('../accountDeletion');

const HOUR = 60 * 60 * 1000;
const HEX64 = /^[a-f0-9]{64}$/;
const tomb = (data) => ({ view: interpretTombstone(data), data });

// ── Planificateurs purs ─────────────────────────────────────────────────────────────────────────────────────────────
test('closingTombstone : schéma additif, ancien format conservé', () => {
  assert.deepEqual(protocol.closingTombstone({ createdAt: 'TS', now: 7 }), { createdAt: 'TS', state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: 7 });
  assert.equal(protocol.closingTombstone({ createdAt: 'TS', now: 7, source: 'manual' }).source, 'manual');
});

test('planEntry : absent/illisible bloquent, scellé = reprise, ancien tombstone = closing epoch 0', () => {
  assert.deepEqual(protocol.planEntry(tomb(null)), { kind: 'blocked', reason: protocol.REASON.TOMBSTONE_MISSING });
  assert.deepEqual(protocol.planEntry(tomb({ phase: 'zzz' })), { kind: 'blocked', reason: protocol.REASON.TOMBSTONE_UNREADABLE });
  assert.deepEqual(protocol.planEntry(tomb({ phase: 'sealed' })), { kind: 'sealed' });
  assert.deepEqual(protocol.planEntry(tomb({ state: 'deleting', createdAt: 'x' })), { kind: 'closing', epoch: 0 });
  assert.deepEqual(protocol.planEntry(tomb({ phase: 'closing', epoch: 4 })), { kind: 'closing', epoch: 4 });
});

test('planSeal : chaque condition de T2b est exigée, dans l’ordre du contrat', () => {
  const ok = { lease: 'L', closureEpoch: 2, snapshotDigest: 'd'.repeat(64) };
  const re = { blocking: false, digest: 'd'.repeat(64) };
  const t = tomb({ phase: 'closing', epoch: 2 });
  assert.deepEqual(protocol.planSeal({ tomb: t, job: ok, lease: 'L', reinspection: re }), { ok: true, epoch: 2 });
  const refuse = (over) => protocol.planSeal({ tomb: t, job: ok, lease: 'L', reinspection: re, ...over }).reason;
  assert.equal(refuse({ tomb: tomb(null) }), protocol.REASON.TOMBSTONE_MISSING);
  assert.equal(refuse({ tomb: tomb({ epoch: -1 }) }), protocol.REASON.TOMBSTONE_UNREADABLE);
  assert.equal(refuse({ lease: 'other' }), protocol.REASON.LEASE_LOST);
  assert.equal(refuse({ job: { ...ok, lease: undefined } }), protocol.REASON.LEASE_LOST);
  assert.equal(refuse({ job: { ...ok, closureEpoch: undefined } }), protocol.REASON.EPOCH_MISSING);
  assert.equal(refuse({ tomb: tomb({ phase: 'closing', epoch: 3 }) }), protocol.REASON.EPOCH_CHANGED);
  assert.equal(refuse({ reinspection: { blocking: true, reason: 'financial_obligation_pending' } }), 'financial_obligation_pending');
  assert.equal(refuse({ reinspection: { blocking: 'maybe', digest: ok.snapshotDigest } }), protocol.REASON.OBLIGATION, 'seul blocking === false autorise');
  assert.equal(refuse({ reinspection: undefined }), protocol.REASON.OBLIGATION);
  assert.equal(refuse({ reinspection: { blocking: false, digest: 'e'.repeat(64) } }), protocol.REASON.SNAPSHOT_CHANGED);
  assert.equal(refuse({ job: { ...ok, snapshotDigest: undefined } }), protocol.REASON.SNAPSHOT_CHANGED);
});

test('planSeal : rejeu idempotent avec le même jeton, refus pour un autre scellé', () => {
  const sealed = tomb({ phase: 'sealed', sealToken: 'T', sealEpoch: 0 });
  assert.deepEqual(protocol.planSeal({ tomb: sealed, job: { sealToken: 'T', lease: 'L' }, lease: 'L', reinspection: {} }), { ok: true, already: true });
  assert.equal(protocol.planSeal({ tomb: sealed, job: { sealToken: 'T', lease: 'L' }, lease: 'other', reinspection: {} }).reason, protocol.REASON.LEASE_LOST, 'sans le bail : jamais de succès idempotent');
  assert.equal(protocol.planSeal({ tomb: sealed, job: { sealToken: 'X' }, lease: 'L', reinspection: {} }).reason, protocol.REASON.SEAL_MISMATCH);
  assert.equal(protocol.planSeal({ tomb: sealed, job: {}, lease: 'L', reinspection: {} }).reason, protocol.REASON.SEAL_MISMATCH);
});

test('planFence : exige scellé, jeton, epoch de scellement et bail', () => {
  const t = tomb({ phase: 'sealed', sealToken: 'T', sealEpoch: 1, epoch: 1 });
  const job = { sealToken: 'T', closureEpoch: 1, lease: 'L' };
  assert.deepEqual(protocol.planFence({ tomb: t, job, lease: 'L' }), { ok: true });
  assert.equal(protocol.planFence({ tomb: tomb({ phase: 'closing' }), job, lease: 'L' }).reason, protocol.REASON.NOT_SEALED);
  assert.equal(protocol.planFence({ tomb: tomb(null), job, lease: 'L' }).reason, protocol.REASON.NOT_SEALED);
  assert.equal(protocol.planFence({ tomb: t, job: { ...job, sealToken: 'X' }, lease: 'L' }).reason, protocol.REASON.SEAL_MISMATCH);
  assert.equal(protocol.planFence({ tomb: tomb({ phase: 'sealed', sealToken: 'T', sealEpoch: 1, epoch: 2 }), job, lease: 'L' }).reason, protocol.REASON.SEAL_MISMATCH, 'epoch bougé après le scellé');
  assert.equal(protocol.planFence({ tomb: t, job: { ...job, closureEpoch: 0 }, lease: 'L' }).reason, protocol.REASON.SEAL_MISMATCH);
  assert.equal(protocol.planFence({ tomb: t, job, lease: 'other' }).reason, protocol.REASON.LEASE_LOST);
});

test('planResume : jeton, epoch, absence d’obligation et empreinte', () => {
  const d = 'd'.repeat(64);
  const t = tomb({ phase: 'sealed', sealToken: 'T', sealEpoch: 0, snapshotDigest: d });
  const job = { sealToken: 'T', closureEpoch: 0, snapshotDigest: d };
  assert.deepEqual(protocol.planResume({ tomb: t, job, reinspection: { blocking: false, digest: d } }), { ok: true });
  assert.equal(protocol.planResume({ tomb: t, job: { ...job, sealToken: 'X' }, reinspection: { blocking: false, digest: d } }).reason, protocol.REASON.SEALED_RESUME_MISMATCH);
  assert.equal(protocol.planResume({ tomb: t, job, reinspection: { blocking: true, digest: d } }).reason, protocol.REASON.SEALED_OBLIGATION);
  assert.equal(protocol.planResume({ tomb: t, job, reinspection: { blocking: false, digest: 'e'.repeat(64) } }).reason, protocol.REASON.SEALED_SNAPSHOT_CHANGED);
  assert.equal(protocol.planResume({ tomb: tomb({ phase: 'closing' }), job, reinspection: { blocking: false, digest: d } }).reason, protocol.REASON.NOT_SEALED);
});

test('blockedPatch : plafond de tentatives partagé, jamais de reprise automatique au-delà', () => {
  const opts = { reason: 'closure_epoch_changed', now: 10, retryMs: HOUR, maxAttempts: 3 };
  assert.deepEqual(protocol.blockedPatch({ attempts: 0 }, opts), { attempts: 1, state: 'blocked', reason: 'closure_epoch_changed', reviewRequired: true, nextAttemptAt: 10 + HOUR, leaseUntil: 0 });
  const last = protocol.blockedPatch({ attempts: 2 }, opts);
  assert.equal(last.reason, 'max_attempts_reached'); assert.equal(last.lastReason, 'closure_epoch_changed'); assert.equal(last.nextAttemptAt, null);
});

// ── Séquence complète, client ───────────────────────────────────────────────────────────────────────────────────────
test('T1 : tombstone « closing » epoch 0 dans la transaction de quarantaine, aucun appel Auth', async () => {
  const w = makeWorld();
  await w.quarantine();
  assert.deepEqual(w.tomb(), { createdAt: { ms: w.state.now }, state: 'deleting', phase: 'closing', epoch: 0, updatedAtMs: w.state.now });
  assert.equal(w.job().state, 'quarantined');
  assert.equal(w.db.store.get(`clients/${UID}`).isSuspended, true);
  assert.deepEqual(w.state.calls, []);
});

test('séquence nominale : T2 enregistre epoch et empreinte, T2b scelle, F pose « deleting », deleteUser voit un tombstone scellé, T3 le date', async () => {
  const w = makeWorld({ seed: { 'orders/o1': { clientId: UID, status: 'delivered', budget: 1500, paymentMethod: 'cash' } } });
  await w.quarantine();
  const out = await w.afterQuiet();
  assert.equal(out.status, 'completed');
  assert.deepEqual(w.state.calls, ['disable', 'revoke', 'delete', 'assets']);
  const t = w.tomb(); const j = w.job();
  assert.equal(t.phase, 'sealed'); assert.equal(t.epoch, 0); assert.equal(t.sealEpoch, 0); assert.equal(t.deleting, true);
  assert.match(t.sealToken, /^[0-9a-f-]{36}$/); assert.match(t.snapshotDigest, HEX64);
  assert.equal(t.snapshotDigest, j.snapshotDigest); assert.equal(t.sealToken, j.sealToken); assert.equal(j.closureEpoch, 0);
  assert.equal(typeof t.authDeletedAtMs, 'number'); assert.equal(typeof t.deleteStartedAtMs, 'number'); assert.equal(t.state, 'deleting');
  assert.equal(j.financialSnapshot.version, 1); assert.equal(j.financialSnapshot.blocking, false);
  const atDelete = w.state.snapshotsAtDelete[0];
  assert.equal(atDelete.phase, 'sealed'); assert.equal(atDelete.deleting, true, 'F doit précéder deleteUser'); assert.equal(atDelete.authDeletedAtMs, undefined);
  assert.equal(w.db.store.get(`clients/${UID}`).isDeleted, true);
});

test('un tombstone scellé n’est jamais rouvert : le verrou financier refuse B/C/D, même 100 jours plus tard', async () => {
  const w = makeWorld();
  w.state.failDelete = true;
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.tomb().phase, 'sealed');
  w.state.now += 100 * 24 * HOUR;
  const lock = (cls) => assertFinancialLock({ get: async (r) => w.db.doc(r.path).get() }, w.db, HttpsError, [{ collection: 'clients', id: UID }], cls);
  for (const cls of ['A', 'B', 'C', 'D']) await assert.rejects(lock(cls), (e) => e.details.code === 'ACCOUNT_SEALED', cls);
  assert.equal(w.tomb().phase, 'sealed');
});

test('ancien tombstone sans phase ni epoch : traité comme closing epoch 0, puis scellé', async () => {
  const w = makeWorld({ seed: {
    'account_tombstones/u1': { createdAt: { ms: 1 }, state: 'deleting' },
    'account_deletions/u1': { uid: UID, role: 'client', state: 'quarantined', consentVerified: true, quarantinedAt: 1, requestCount: 1, attempts: 0 },
  } });
  const out = await w.afterQuiet();
  assert.equal(out.status, 'completed');
  assert.equal(w.tomb().phase, 'sealed'); assert.equal(w.tomb().sealEpoch, 0);
  assert.equal(w.tomb().epoch, undefined, 'les anciens champs ne sont pas réécrits');
});

test('T1 refuse d’écraser un tombstone existant et le dit', async () => {
  const w = makeWorld({ seed: { 'account_tombstones/u1': { createdAt: { ms: 1 }, state: 'deleting', phase: 'sealed', sealToken: 'T', sealEpoch: 2, epoch: 2 } } });
  await w.quarantine();
  assert.equal(w.job().reason, 'existing_tombstone_review'); assert.equal(w.job().state, 'blocked');
  assert.equal(w.tomb().sealToken, 'T'); assert.equal(w.db.store.get(`clients/${UID}`).isSuspended, undefined);
  assert.deepEqual(w.state.calls, []);
});

// ── Moteur d'obligations ────────────────────────────────────────────────────────────────────────────────────────────
test('moteur à T1 : un signalement ouvert bloque AVANT tout tombstone, le compte reste utilisable', async () => {
  const w = makeWorld({ seed: { 'reconciliation_flags/f1': { clientId: UID, status: 'open', kind: 'cash_shortfall' } } });
  await w.quarantine();
  assert.equal(w.job().state, 'blocked'); assert.equal(w.job().reason, 'financial_obligation_pending');
  assert.equal(w.tomb(), undefined); assert.equal(w.db.store.get(`clients/${UID}`).isSuspended, undefined);
});

test('moteur à T2 : une obligation apparue pendant la quarantaine bloque avant toute action Auth', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.db.store.set('transfer_settlements/s1', { clientId: UID, status: 'pending_review', driverIds: ['d1'] });
  await w.afterQuiet();
  assert.equal(w.job().state, 'blocked'); assert.equal(w.job().reason, 'financial_obligation_pending');
  assert.deepEqual(w.state.calls, []); assert.equal(w.tomb().phase, 'closing');
});

test('moteur fail-closed : lecture impossible = aucune écriture, aucune quarantaine, jamais une liste vide', async () => {
  const w = makeWorld();
  const before = w.snapshot();
  w.db.store.queryFailure = (name) => name === 'reconciliation_flags';
  await assert.rejects(w.quarantine(), /read failure/);
  w.db.store.queryFailure = null;
  assert.equal(w.tomb(), undefined);
  assert.equal(w.db.store.get(`clients/${UID}`).isSuspended, undefined);
  assert.notEqual(w.snapshot(), before); // la demande (dossier) est enregistrée, jamais la quarantaine
  assert.deepEqual(w.state.calls, []);
});

test('requêtes du moteur plafonnées : 201 documents = lecture tronquée = blocage', async () => {
  const seed = {};
  for (let i = 0; i < 201; i += 1) seed[`reconciliation_flags/f${i}`] = { clientId: UID, status: 'closed' };
  const w = makeWorld({ seed });
  await w.quarantine();
  assert.equal(w.job().state, 'blocked'); assert.equal(w.tomb(), undefined);
});

// ── T2b : écarts d'epoch et d'état ──────────────────────────────────────────────────────────────────────────────────
test('T2b : un epoch qui a bougé depuis T2 refuse le scellement, réactive Auth, puis une nouvelle inspection aboutit', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.onDisable = async () => { w.db.store.set(`account_tombstones/${UID}`, { ...w.tomb(), epoch: 1 }); w.state.onDisable = null; };
  await w.afterQuiet();
  assert.equal(w.job().state, 'blocked'); assert.equal(w.job().reason, 'closure_epoch_changed');
  assert.deepEqual(w.state.calls, ['disable', 'revoke', 'enable']);
  assert.equal(w.tomb().phase, 'closing'); assert.equal(w.state.snapshotsAtDelete.length, 0);
  w.state.now += HOUR + 1;
  assert.equal((await w.api.process(UID)).status, 'completed');
  assert.equal(w.tomb().sealEpoch, 1, 'le nouvel epoch est celui de la nouvelle inspection');
});

test('T2b : une obligation apparue entre T2 et T2b refuse le scellement, tombstone toujours closing', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.onDisable = async () => { w.db.store.set('reconciliation_flags/late', { clientId: UID, status: 'open', kind: 'cash_shortfall' }); };
  await w.afterQuiet();
  assert.equal(w.job().reason, 'financial_obligation_pending'); assert.equal(w.tomb().phase, 'closing');
  assert.ok(w.state.calls.includes('enable')); assert.ok(!w.state.calls.includes('delete'));
});

test('T2b : un échec répété épuise les tentatives sans jamais supprimer ni sceller', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.onDisable = async () => { const t = w.tomb(); w.db.store.set(`account_tombstones/${UID}`, { ...t, epoch: (t.epoch || 0) + 1 }); };
  for (let i = 0; i < MAX_ATTEMPTS; i += 1) { await w.afterQuiet(); w.state.now += HOUR; }
  assert.equal(w.job().reason, 'max_attempts_reached'); assert.equal(w.job().lastReason, 'closure_epoch_changed');
  assert.equal(w.tomb().phase, 'closing'); assert.ok(!w.state.calls.includes('delete')); assert.equal(w.job().nextAttemptAt, null);
});

test('bail perdu à T2b : un autre processus a repris le dossier, aucun scellement', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.onDisable = async () => { w.db.store.set(`account_deletions/${UID}`, { ...w.job(), lease: 'someone-else' }); };
  await w.afterQuiet();
  assert.equal(w.job().reason, 'closure_lease_lost'); assert.equal(w.tomb().phase, 'closing');
});

test('tombstone disparu ou illisible à T2 : dossier bloqué, jamais recréé', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.db.store.delete(`account_tombstones/${UID}`);
  await w.afterQuiet();
  assert.equal(w.job().reason, 'closure_tombstone_missing'); assert.equal(w.tomb(), undefined);
  const w2 = makeWorld();
  await w2.quarantine();
  w2.db.store.set(`account_tombstones/${UID}`, { ...w2.tomb(), phase: 'zzz' });
  await w2.afterQuiet();
  assert.equal(w2.job().reason, 'closure_tombstone_unreadable'); assert.deepEqual(w2.state.calls, []);
  assert.ok(w2.audits().some((a) => a.action === 'account_deletion_closure_alert'), 'alerte journalisée');
});

// ── Reprises après interruption ─────────────────────────────────────────────────────────────────────────────────────
test('arrêt après T1 : la reprise après la quarantaine mène le dossier à son terme', async () => {
  const w = makeWorld();
  await w.quarantine();
  assert.equal(w.tomb().phase, 'closing');
  assert.equal((await w.afterQuiet()).status, 'completed');
});

test('arrêt après acquisition du bail : un second passage est refusé, puis repris à l’expiration', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.now += w.QUIET_MS + 1;
  w.db.store.set(`account_deletions/${UID}`, { ...w.job(), lease: 'crashed', leaseUntil: w.state.now + 180000, closureEpoch: 0, snapshotDigest: 'x' });
  await w.api.process(UID);
  assert.deepEqual(w.state.calls, [], 'bail actif : rien');
  w.state.now += 181000;
  assert.equal((await w.api.process(UID)).status, 'completed');
});

test('arrêt après T2 (avant Auth) : la reprise refait T2 puis termine', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.state.now += w.QUIET_MS + 1;
  w.db.store.set(`account_deletions/${UID}`, { ...w.job(), closureEpoch: 0, snapshotDigest: 'stale', financialSnapshot: {} });
  assert.equal((await w.api.process(UID)).status, 'completed');
  assert.match(w.job().snapshotDigest, HEX64);
});

test('arrêt après T2b avant deleteUser : la reprise lit le scellé, refait F et supprime, sans rouvrir', async () => {
  const w = makeWorld();
  w.state.failDelete = true;
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.job().state, 'cleanup_pending'); assert.equal(w.job().attempts, 1);
  const sealed = { ...w.tomb() };
  assert.equal(sealed.phase, 'sealed'); assert.equal(sealed.deleting, true); assert.ok(w.users.has(UID));
  w.state.failDelete = false; w.state.now += HOUR + 1;
  assert.equal((await w.api.process(UID)).status, 'completed');
  assert.equal(w.tomb().sealToken, sealed.sealToken, 'même scellé');
  assert.equal(w.tomb().deleteStartedAtMs, sealed.deleteStartedAtMs, 'F rejoué sans réécrire la date');
  assert.equal(w.state.calls.filter((c) => c === 'disable').length, 1, 'A1 et T2b ne sont pas rejoués');
  assert.equal(typeof w.tomb().authDeletedAtMs, 'number');
});

test('échecs répétés de deleteUser : dossier bloqué, tombstone scellé et protecteur', async () => {
  const w = makeWorld();
  w.state.failDelete = true;
  await w.quarantine();
  await w.afterQuiet();
  for (let i = 1; i < MAX_ATTEMPTS; i += 1) { w.state.now += HOUR + 1; await w.api.process(UID); }
  assert.equal(w.job().reason, 'max_attempts_reached'); assert.equal(w.job().state, 'blocked');
  assert.equal(w.tomb().phase, 'sealed'); assert.equal(w.tomb().authDeletedAtMs, undefined);
  assert.ok(w.users.has(UID));
});

test('état Auth incertain après deleteUser : aucune conclusion, reprise puis confirmation', async () => {
  const w = makeWorld();
  w.state.getUserFailure = true;
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.tomb().authDeletedAtMs, undefined, 'suppression non confirmée = non enregistrée');
  assert.equal(w.job().authDeleted, undefined); assert.equal(w.tomb().phase, 'sealed');
  w.state.getUserFailure = false; w.state.now += HOUR + 1;
  assert.equal((await w.api.process(UID)).status, 'completed');
  assert.equal(typeof w.tomb().authDeletedAtMs, 'number');
});

test('utilisateur Auth déjà supprimé : le protocole scelle quand même avant de conclure', async () => {
  const w = makeWorld();
  await w.quarantine();
  w.users.delete(UID);
  assert.equal((await w.afterQuiet()).status, 'completed');
  assert.equal(w.tomb().phase, 'sealed'); assert.equal(typeof w.tomb().authDeletedAtMs, 'number');
  assert.ok(!w.state.calls.includes('enable'));
});

test('reprise d’un dossier scellé : jeton falsifié, obligation nouvelle ou empreinte changée = arrêt + alerte, scellé conservé', async () => {
  const cases = [
    ['jeton', (w) => w.db.store.set(`account_tombstones/${UID}`, { ...w.tomb(), sealToken: 'forged' }), 'sealed_resume_mismatch'],
    ['obligation', (w) => w.db.store.set('reconciliation_flags/late', { clientId: UID, status: 'open', kind: 'cash_shortfall' }), 'sealed_obligation_detected'],
    ['empreinte', (w) => w.db.store.set(`account_tombstones/${UID}`, { ...w.tomb(), snapshotDigest: 'f'.repeat(64) }), 'sealed_snapshot_changed'],
  ];
  for (const [name, tamper, reason] of cases) {
    const w = makeWorld();
    w.state.failDelete = true;
    await w.quarantine();
    await w.afterQuiet();
    const deletes = w.state.calls.filter((c) => c === 'delete').length;
    tamper(w);
    w.state.failDelete = false; w.state.now += HOUR + 1;
    await w.api.process(UID);
    assert.equal(w.job().reason, reason, name); assert.equal(w.job().state, 'blocked', name); assert.equal(w.job().nextAttemptAt, null, name);
    assert.equal(w.tomb().phase, 'sealed', name);
    assert.equal(w.state.calls.filter((c) => c === 'delete').length, deletes, `${name} : pas de deleteUser`);
    assert.ok(w.audits().some((a) => a.action === 'account_deletion_closure_alert' && a.metadata.reason === reason), name);
  }
});

// ── Partenaires ─────────────────────────────────────────────────────────────────────────────────────────────────────
test('partenaire : même protocole (closing epoch 0 -> scellé -> deleting -> authDeletedAtMs), deleteUser après le scellé', async () => {
  const w = makeWorld({ role: 'seller', partner: true });
  await w.quarantine();
  assert.equal(w.tomb().phase, 'closing'); assert.equal(w.tomb().epoch, 0);
  await w.afterQuiet();
  assert.equal(w.job().state, 'completed');
  assert.equal(w.tomb().phase, 'sealed'); assert.equal(w.tomb().deleting, true); assert.equal(typeof w.tomb().authDeletedAtMs, 'number');
  assert.equal(w.state.snapshotsAtDelete[0].phase, 'sealed');
  assert.match(w.job().snapshotDigest, HEX64); assert.equal(w.job().financialSnapshot.roles[0].role, 'seller');
});

test('partenaire : le moteur bloque avant tout tombstone, et un epoch bougé refuse le scellement', async () => {
  const blocked = makeWorld({ role: 'seller', partner: true, seed: { 'reconciliation_flags/f1': { sellerId: UID, status: 'open', kind: 'seller_review' } } });
  await blocked.quarantine();
  assert.equal(blocked.job().state, 'blocked'); assert.equal(blocked.tomb(), undefined);
  const w = makeWorld({ role: 'seller', partner: true });
  await w.quarantine();
  w.state.onDisable = async () => { w.db.store.set(`account_tombstones/${UID}`, { ...w.tomb(), epoch: 5 }); };
  await w.afterQuiet();
  assert.equal(w.job().reason, 'closure_epoch_changed'); assert.equal(w.tomb().phase, 'closing');
  assert.deepEqual(w.state.calls.slice(-1), ['enable']); assert.ok(!w.state.calls.includes('delete'));
});

test('partenaire : arrêt entre T2b et deleteUser puis reprise, scellé conservé', async () => {
  const w = makeWorld({ role: 'seller', partner: true });
  w.state.failDelete = true;
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.tomb().phase, 'sealed'); assert.ok(w.users.has(UID));
  w.state.failDelete = false; w.state.now += HOUR + 1;
  await w.api.process(UID);
  assert.equal(w.job().state, 'completed'); assert.equal(typeof w.tomb().authDeletedAtMs, 'number');
});

test('partenaire : obligation découverte une fois scellé = arrêt + alerte, sans reprise automatique ni deleteUser', async () => {
  const w = makeWorld({ role: 'seller', partner: true });
  w.state.failDelete = true;
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.tomb().phase, 'sealed');
  const deletes = w.state.calls.filter((c) => c === 'delete').length;
  w.db.store.set('reconciliation_flags/late', { sellerId: UID, status: 'open', kind: 'seller_review' });
  w.state.failDelete = false; w.state.now += HOUR + 1;
  await w.api.process(UID);
  assert.equal(w.job().reason, 'sealed_obligation_detected'); assert.equal(w.job().nextAttemptAt, null);
  assert.equal(w.tomb().phase, 'sealed'); assert.equal(w.state.calls.filter((c) => c === 'delete').length, deletes);
  assert.ok(w.audits().some((a) => a.action === 'account_deletion_closure_alert'));
});

// ── Garde-fous de code ──────────────────────────────────────────────────────────────────────────────────────────────
test('le protocole ne contient aucune horloge de déverrouillage ni de réouverture sealed -> closing', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'accountClosureProtocol.js'), 'utf8');
  const code = src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
  assert.ok(!/Date\.now|setTimeout|expire/i.test(code));
});
