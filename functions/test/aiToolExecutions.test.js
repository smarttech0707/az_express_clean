'use strict';

/**
 * Supervision admin des exécutions d'outils AZ IA — 100 % hors ligne.
 * Firestore est une doublure ; aucun appel réseau, aucun modèle, aucun secret.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const {
  buildListAiToolExecutions, toSafeRow, VALID_STATUSES, MAX_LIMIT, REPLAY_WARNING,
} = require('../aiToolExecutions');
const { COLLECTION, STALE_RUNNING_MS } = require('../azia/persistentToolLedger');

const NOW = 1_800_000_000_000;
const MINUTE = 60 * 1000;
const ts = (ms) => ({ toMillis: () => ms, toDate: () => new Date(ms) });

/** Doublure Firestore : documents + requête filtrée/triée/paginée en JS. */
function makeDb({ admins = {}, executions = [] } = {}) {
  const mutations = [];
  const makeQuery = (rows) => {
    let filtered = rows;
    let max = Infinity;
    const api = {
      where: (field, op, value) => makeQuery(filtered.filter((r) => r[field] === value)),
      orderBy: (field, dir) => makeQuery([...filtered].sort((a, b) => {
        const av = a[field]?.toMillis?.() ?? 0;
        const bv = b[field]?.toMillis?.() ?? 0;
        return dir === 'desc' ? bv - av : av - bv;
      })),
      limit: (n) => { max = n; return api; },
      startAfter: (date) => makeQuery(filtered.filter((r) => (r.createdAt?.toMillis?.() ?? 0) < date.getTime())),
      get: async () => ({
        docs: filtered.slice(0, max).map((r) => ({ id: r.id, data: () => r })),
      }),
    };
    return api;
  };
  return {
    mutations,
    collection: (name) => {
      if (name === 'admins') {
        return {
          doc: (id) => ({
            get: async () => ({ exists: !!admins[id], data: () => admins[id] }),
            set: async (d) => { mutations.push(['set', name, id, d]); },
            update: async (d) => { mutations.push(['update', name, id, d]); },
            delete: async () => { mutations.push(['delete', name, id]); },
          }),
        };
      }
      const q = makeQuery(executions);
      return Object.assign(q, {
        doc: (id) => ({
          get: async () => ({ exists: false, data: () => undefined }),
          set: async (d) => { mutations.push(['set', name, id, d]); },
          update: async (d) => { mutations.push(['update', name, id, d]); },
          delete: async () => { mutations.push(['delete', name, id]); },
        }),
      });
    },
  };
}

const SUPER_ADMIN = { admin1: { role: 'super', isActive: true } };
const adminRequest = (uid = 'admin1', data = {}) => ({
  auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
  data,
});

const execution = (over = {}) => ({
  id: over.id || 'tool_abc',
  uid: 'u1',
  toolName: 'initiate_wallet_recharge',
  conversationId: 'c1',
  status: 'completed',
  startedAtMs: NOW - MINUTE,
  createdAt: ts(NOW - MINUTE),
  expiresAt: ts(NOW + 30 * 24 * 3600 * 1000),
  ...over,
});

const listFor = (db) => buildListAiToolExecutions({ db, onCall, HttpsError, now: () => NOW });

// ── Contrôle d'accès ────────────────────────────────────────────────────────
test('un appelant non authentifié est refusé', async () => {
  const fn = listFor(makeDb({ admins: SUPER_ADMIN }));
  await assert.rejects(fn.run({ data: {} }), (e) => e.code === 'unauthenticated');
});

test('un client authentifié non-admin est refusé', async () => {
  const fn = listFor(makeDb({ admins: SUPER_ADMIN, executions: [execution()] }));
  await assert.rejects(fn.run(adminRequest('client1')), (e) => e.code === 'permission-denied');
});

test('un compte anonyme est refusé', async () => {
  const fn = listFor(makeDb({ admins: SUPER_ADMIN }));
  await assert.rejects(
    fn.run({ auth: { uid: 'admin1', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: {} }),
    (e) => e.code === 'unauthenticated',
  );
});

test('un admin désactivé est refusé', async () => {
  const fn = listFor(makeDb({ admins: { admin1: { role: 'super', isActive: false } } }));
  await assert.rejects(fn.run(adminRequest()), (e) => e.code === 'permission-denied');
});

test('un sous-admin sans la permission ai_dashboard est refusé', async () => {
  const fn = listFor(makeDb({ admins: { sub1: { role: 'sub', isActive: true, permissions: ['support'] } } }));
  await assert.rejects(fn.run(adminRequest('sub1')), (e) => e.code === 'permission-denied');
});

test('un sous-admin avec la permission ai_dashboard est autorisé', async () => {
  const db = makeDb({
    admins: { sub1: { role: 'sub', isActive: true, permissions: ['ai_dashboard'] } },
    executions: [execution()],
  });
  const out = await listFor(db).run(adminRequest('sub1'));
  assert.equal(out.count, 1);
});

test('un super-admin est autorisé', async () => {
  const db = makeDb({ admins: SUPER_ADMIN, executions: [execution()] });
  const out = await listFor(db).run(adminRequest());
  assert.equal(out.rows[0].toolName, 'initiate_wallet_recharge');
});

// ── Lecture seule ───────────────────────────────────────────────────────────
test('aucune mutation n\'est effectuée sur ai_tool_executions', async () => {
  const db = makeDb({ admins: SUPER_ADMIN, executions: [execution({ status: 'failed' })] });
  await listFor(db).run(adminRequest());
  const touched = db.mutations.filter(([, collection]) => collection === COLLECTION);
  assert.equal(touched.length, 0, 'la supervision ne doit jamais écrire');
  assert.equal(db.mutations.length, 0);
});

test('la réponse se déclare explicitement en lecture seule et n\'expose aucune action', async () => {
  const db = makeDb({ admins: SUPER_ADMIN, executions: [execution()] });
  const out = await listFor(db).run(adminRequest());
  assert.equal(out.readOnly, true);
  const serialized = JSON.stringify(out);
  // Aucune CLÉ d'action ne doit exister. `replayWarning` est au contraire un
  // avertissement CONTRE la relance : sa présence est attendue, pas interdite.
  for (const actionKey of ['"retry"', '"canRetry"', '"replay"', '"actions"',
    '"forceComplete"', '"forceFailed"', '"delete"']) {
    assert.ok(!serialized.includes(actionKey), `aucune action ${actionKey} ne doit être proposée`);
  }
  assert.ok(serialized.includes('replayWarning') === false || out.replayWarning === REPLAY_WARNING);
});

// ── Données sensibles ───────────────────────────────────────────────────────
test('aucune donnée sensible n\'est renvoyée', async () => {
  const db = makeDb({
    admins: SUPER_ADMIN,
    executions: [execution({
      // Champs qui ne doivent JAMAIS ressortir, même s'ils existaient.
      result: { phone: '0700000000', token: 'secret-token', actionId: 'a1' },
      input: { phone: '0700000000', amount: 1000 },
    })],
  });
  const out = await listFor(db).run(adminRequest());
  const serialized = JSON.stringify(out);
  assert.ok(!serialized.includes('0700000000'), 'aucun numéro de téléphone');
  assert.ok(!serialized.includes('secret-token'), 'aucun jeton');
  assert.ok(!serialized.includes('"input"'), 'aucun argument brut');
  assert.ok(!serialized.includes('"result"'), 'aucun résultat métier détaillé');
});

test('le motif d\'échec est borné', () => {
  const row = toSafeRow({ id: 'x', data: () => ({ status: 'failed', failureReason: 'e'.repeat(500) }) }, NOW);
  assert.equal(row.failureReason.length, 200);
});

// ── Filtres ─────────────────────────────────────────────────────────────────
test('filtrage par statut : failed, abandoned, running, completed', async () => {
  const db = makeDb({
    admins: SUPER_ADMIN,
    executions: [
      execution({ id: 'a', status: 'failed' }),
      execution({ id: 'b', status: 'abandoned' }),
      execution({ id: 'c', status: 'running' }),
      execution({ id: 'd', status: 'completed' }),
    ],
  });
  for (const status of VALID_STATUSES) {
    const out = await listFor(db).run(adminRequest('admin1', { status }));
    assert.equal(out.count, 1, `filtre ${status}`);
    assert.equal(out.rows[0].status, status);
  }
  const all = await listFor(db).run(adminRequest());
  assert.equal(all.count, 4, 'sans filtre, tout est listé');
});

test('un statut de filtre invalide est rejeté', async () => {
  const db = makeDb({ admins: SUPER_ADMIN });
  await assert.rejects(listFor(db).run(adminRequest('admin1', { status: 'deleted' })),
    (e) => e.code === 'invalid-argument');
});

// ── Tri et pagination ───────────────────────────────────────────────────────
test('les plus récents sont renvoyés en premier', async () => {
  const db = makeDb({
    admins: SUPER_ADMIN,
    executions: [
      execution({ id: 'vieux', createdAt: ts(NOW - 10 * MINUTE) }),
      execution({ id: 'recent', createdAt: ts(NOW - MINUTE) }),
    ],
  });
  const out = await listFor(db).run(adminRequest());
  assert.deepEqual(out.rows.map((r) => r.id), ['recent', 'vieux']);
});

test('pagination bornée : limite plafonnée et curseur fourni', async () => {
  const executions = Array.from({ length: 5 }, (_, i) => execution({
    id: `e${i}`, createdAt: ts(NOW - i * MINUTE),
  }));
  const db = makeDb({ admins: SUPER_ADMIN, executions });
  const page1 = await listFor(db).run(adminRequest('admin1', { limit: 2 }));
  assert.equal(page1.count, 2);
  assert.ok(page1.nextStartAfterMs, 'un curseur est proposé tant qu\'il reste des pages');

  const page2 = await listFor(db).run(adminRequest('admin1', { limit: 2, startAfterMs: page1.nextStartAfterMs }));
  assert.equal(page2.count, 2);
  assert.ok(!page2.rows.some((r) => page1.rows.some((p) => p.id === r.id)), 'aucun doublon entre pages');

  const huge = await listFor(db).run(adminRequest('admin1', { limit: 10_000 }));
  assert.ok(huge.count <= MAX_LIMIT);
});

// ── running bloqué / avertissement ──────────────────────────────────────────
test('running depuis plus de 5 minutes → signalé STALE, sans modification', async () => {
  const db = makeDb({
    admins: SUPER_ADMIN,
    executions: [
      execution({ id: 'frais', status: 'running', startedAtMs: NOW - MINUTE }),
      execution({ id: 'bloque', status: 'running', startedAtMs: NOW - STALE_RUNNING_MS - MINUTE }),
    ],
  });
  const out = await listFor(db).run(adminRequest('admin1', { status: 'running' }));
  const frais = out.rows.find((r) => r.id === 'frais');
  const bloque = out.rows.find((r) => r.id === 'bloque');
  assert.equal(frais.stale, false);
  assert.equal(bloque.stale, true, 'à vérifier');
  assert.equal(bloque.needsManualReview, true);
  assert.equal(db.mutations.length, 0, 'aucun document modifié automatiquement');
});

test('failed et abandoned portent l\'avertissement anti-relance', async () => {
  const db = makeDb({
    admins: SUPER_ADMIN,
    executions: [execution({ id: 'f', status: 'failed' }), execution({ id: 'a', status: 'abandoned' })],
  });
  const out = await listFor(db).run(adminRequest());
  for (const row of out.rows) {
    assert.equal(row.replayWarning, REPLAY_WARNING);
    assert.ok(row.replayWarning.includes("peut déjà avoir été appliqué"));
    assert.equal(row.needsManualReview, true);
  }
});

test('un statut completed ne porte aucun avertissement', async () => {
  const db = makeDb({ admins: SUPER_ADMIN, executions: [execution({ status: 'completed' })] });
  const out = await listFor(db).run(adminRequest());
  assert.equal(out.rows[0].replayWarning, null);
  assert.equal(out.rows[0].needsManualReview, false);
});

// ── Champs de diagnostic attendus ───────────────────────────────────────────
test('les champs de diagnostic demandés sont présents', async () => {
  const db = makeDb({ admins: SUPER_ADMIN, executions: [execution({ status: 'failed', failureReason: 'timeout' })] });
  const [row] = (await listFor(db).run(adminRequest())).rows;
  for (const field of ['toolName', 'status', 'uid', 'conversationId',
    'createdAtMs', 'startedAtMs', 'expiresAtMs', 'failureReason']) {
    assert.ok(field in row, `champ manquant : ${field}`);
  }
});
