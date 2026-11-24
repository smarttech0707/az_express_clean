'use strict';

// Mission 7E-64 : anti-abus, inventaire avant suppression Auth, effacement AZ IA et plafond de tentatives de la
// suppression de compte client/livreur. Faux Firestore et faux Auth en mémoire : AUCUN accès cloud, aucune suppression réelle.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAccountDeletion, QUIET_MS, MAX_ATTEMPTS, MAX_REQUESTS, REPEAT_WINDOW_MS } = require('../accountDeletion');
const { buildAccountDeletionSupport } = require('../accountDeletionSupport');
const cleanup = require('../accountCleanup');

const DELETE = Symbol('delete');
const UID = 'u1';
const TOKEN = 'a'.repeat(64);
const HOUR = 60 * 60 * 1000;

function fakeStore(seed = {}) {
  const store = new Map(Object.entries(seed));
  const failures = { auditAdd: false };
  const apply = (p, patch, merge) => {
    const next = merge ? { ...(store.get(p) || {}) } : {};
    for (const [k, v] of Object.entries(patch)) { if (v === DELETE) delete next[k]; else next[k] = v; }
    store.set(p, next);
  };
  const childrenOf = (p) => [...new Set([...store.keys()].filter((k) => k.startsWith(p + '/')).map((k) => k.slice(p.length + 1).split('/')[0]))];
  const snapOf = (p) => ({ exists: store.has(p), id: p.split('/').pop(), data: () => store.get(p), ref: docRef(p) });
  function docRef(p) {
    return {
      path: p, id: p.split('/').pop(), parent: { id: p.split('/').slice(-2)[0] },
      get: async () => snapOf(p),
      set: async (d, o) => apply(p, d, !!(o && o.merge)),
      update: async (d) => { if (!store.has(p)) throw new Error('update absent ' + p); apply(p, d, true); },
      delete: async () => { store.delete(p); },
      collection: (n) => colRef(`${p}/${n}`),
      listCollections: async () => childrenOf(p).map((n) => colRef(`${p}/${n}`)),
    };
  }
  function query(name, filters, limitN, after) {
    const q = {
      where: (f, _op, v) => query(name, [...filters, [f, v]], limitN, after),
      limit: (n) => query(name, filters, n, after),
      startAfter: (d) => query(name, filters, limitN, d),
      get: async () => {
        let docs = [...store.entries()]
          .filter(([k]) => k.startsWith(name + '/') && !k.slice(name.length + 1).includes('/'))
          .filter(([, v]) => filters.every(([f, val]) => v[f] === val))
          .map(([k]) => snapOf(k)).sort((a, b) => (a.id < b.id ? -1 : 1));
        if (after) docs = docs.filter((d) => d.id > after.id);
        docs = docs.slice(0, limitN);
        return { docs, empty: docs.length === 0, size: docs.length };
      },
    };
    return q;
  }
  let seq = 0;
  function colRef(name) {
    return {
      id: name.split('/').pop(), path: name,
      doc: (id) => docRef(`${name}/${id || 'auto' + (++seq)}`),
      add: async (d) => {
        if (name === 'audit_logs' && failures.auditAdd) throw new Error('audit unavailable');
        const r = docRef(`${name}/auto${++seq}`); apply(r.path, d, false); return r;
      },
      where: (f, _op, v) => query(name, [[f, v]], Infinity, null),
      limit: (n) => query(name, [], n, null),
      get: () => query(name, [], Infinity, null).get(),
    };
  }
  const db = {
    store, failures,
    collection: colRef,
    doc: (p) => docRef(p),
    batch: () => {
      const ops = [];
      return { delete: (r) => ops.push(r.path), commit: async () => { for (const p of ops) store.delete(p); } };
    },
    runTransaction: async (cb) => {
      const writes = [];
      const tx = {
        get: async (t) => (t.path ? snapOf(t.path) : t.get()),
        update: (r, d) => { if (!store.has(r.path)) throw new Error('update absent ' + r.path); writes.push(['u', r.path, d]); },
        create: (r, d) => { if (store.has(r.path)) throw Object.assign(new Error('exists'), { code: 6 }); writes.push(['c', r.path, d]); },
        set: (r, d) => writes.push(['s', r.path, d]),
      };
      const result = await cb(tx);
      for (const [t, p, d] of writes) apply(p, d, t === 'u');
      return result;
    },
  };
  return db;
}

const admin = { firestore: { Timestamp: { fromMillis: (ms) => ({ ms }) }, FieldValue: { serverTimestamp: () => 'TS', delete: () => DELETE } } };
const missing = () => Object.assign(new Error('missing'), { code: 'auth/user-not-found' });

function setup({ seed = {}, config = { enabled: true, inventoryVersion: 1 }, role = 'client', limiter = true, logAudit } = {}) {
  const col = role === 'client' ? 'clients' : 'livreurs';
  const docs = { [`${col}/${UID}`]: { wallet: 0, name: 'Awa', phone: '0700000000', fcmToken: 'tok', ...(role === 'livreur' ? { isOnline: true } : {}) }, ...seed };
  if (config) docs['operations_control/account_deletion'] = config;
  const db = fakeStore(docs);
  const users = new Map([[UID, { uid: UID }]]);
  const state = { now: 1_000_000_000_000, failDelete: false, failAssets: false, calls: [], limiterCalls: [], limiterError: null };
  const auth = {
    updateUser: async () => { if (!users.has(UID)) throw missing(); state.calls.push('disable'); },
    revokeRefreshTokens: async () => { state.calls.push('revoke'); },
    deleteUser: async () => { state.calls.push('delete'); if (state.failDelete) throw new Error('transient'); users.delete(UID); },
    getUser: async () => { if (!users.has(UID)) throw missing(); return {}; },
  };
  const api = buildAccountDeletion({
    db, auth, admin, HttpsError, clock: () => state.now,
    checkRateLimit: limiter ? async (...a) => { state.limiterCalls.push(a); if (state.limiterError) throw state.limiterError; } : undefined,
    logAudit,
    eraseAssets: async () => { state.calls.push('assets'); if (state.failAssets) throw new Error('storage unavailable'); },
  });
  const req = (over = {}, authTime = Math.floor(state.now / 1000)) => ({
    auth: { uid: UID, token: { auth_time: authTime, firebase: { sign_in_provider: 'password' } } },
    data: { role, recoveryToken: TOKEN, allProfilesConsent: true, ...over },
  });
  const job = () => db.store.get(`account_deletions/${UID}`);
  const audits = () => [...db.store.entries()].filter(([k]) => k.startsWith('audit_logs/')).map(([, v]) => v);
  // Mène un dossier jusqu'à la suppression effective : demande, fin de quarantaine, traitement.
  const run = async () => { await api.request(req()); state.now += QUIET_MS + 1; return api.process(UID); };
  return { db, users, state, api, req, job, audits, run };
}

// ── Anti-abus ───────────────────────────────────────────────────────────────

test('limitation de débit : le limiteur du projet est appelé avec la clé dédiée et son refus bloque tout', async () => {
  const h = setup();
  await h.api.request(h.req());
  assert.deepEqual(h.state.limiterCalls[0], [UID, 'account_deletion_request', 5, 3600]);
  const h2 = setup();
  h2.state.limiterError = new HttpsError('resource-exhausted', 'Trop de tentatives');
  await assert.rejects(h2.api.request(h2.req()), { code: 'resource-exhausted' });
  assert.equal(h2.job(), undefined, 'aucun dossier créé');
  assert.deepEqual(h2.state.calls, []);
});

test('sans limiteur injecté la fonction refuse de traiter (jamais de suppression sans anti-abus)', async () => {
  const h = setup({ limiter: false });
  await assert.rejects(h.api.request(h.req()), { code: 'failed-precondition', message: 'RATE_LIMITER_REQUIRED' });
  assert.equal(h.job(), undefined);
});

test('demande répétée dans la fenêtre : absorbée, aucun retraitement, journalisée', async () => {
  const h = setup();
  await h.api.request(h.req());
  const before = { ...h.job() };
  const callsBefore = h.state.calls.length;
  h.state.now += REPEAT_WINDOW_MS - 1;
  const r = await h.api.request(h.req());
  assert.equal(r.status, before.state);
  assert.equal(h.job().requestCount, 1, 'compteur inchangé');
  assert.equal(h.state.calls.length, callsBefore);
  assert.ok(h.audits().some((a) => a.action === 'account_deletion_request_repeated'));
});

test('une réauthentification récente juste après une demande ancienne n’est PAS absorbée', async () => {
  const h = setup();
  const stale = Math.floor(h.state.now / 1000) - 3600;
  const first = await h.api.request(h.req({}, stale));
  assert.equal(first.reason, 'reauthentication_required');
  assert.equal(h.job().consentVerified, false);
  h.state.now += 5000;
  await h.api.request(h.req());
  assert.equal(h.job().consentVerified, true);
  assert.equal(h.job().requestCount, 2);
});

test('plafond de demandes cumulées par dossier', async () => {
  const h = setup();
  await h.api.request(h.req());
  h.db.store.set(`account_deletions/${UID}`, { ...h.job(), requestCount: MAX_REQUESTS });
  h.state.now += REPEAT_WINDOW_MS + 1;
  await assert.rejects(h.api.request(h.req()), { code: 'resource-exhausted', message: 'ACCOUNT_DELETION_REQUEST_LIMIT' });
});

test('anonyme, rôle invalide et jeton invalide sont refusés avant tout limiteur', async () => {
  const h = setup();
  await assert.rejects(h.api.request({ auth: { uid: UID, token: { firebase: { sign_in_provider: 'anonymous' } } }, data: { role: 'client', recoveryToken: TOKEN } }), { code: 'unauthenticated' });
  await assert.rejects(h.api.request(h.req({ role: 'admin' })), { code: 'invalid-argument' });
  await assert.rejects(h.api.request(h.req({ recoveryToken: 'x' })), { code: 'invalid-argument' });
  assert.equal(h.state.limiterCalls.length, 0);
});

// ── Plafond de tentatives et reprise ────────────────────────────────────────

test('plafond de tentatives : après MAX_ATTEMPTS échecs techniques, plus de reprise automatique, compte non recréé', async () => {
  const h = setup();
  h.state.failDelete = true;
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  for (let i = 1; i <= MAX_ATTEMPTS; i++) {
    const r = await h.api.process(UID);
    assert.equal(h.job().attempts, i);
    if (i < MAX_ATTEMPTS) { assert.equal(r.status, 'cleanup_pending'); assert.ok(h.job().nextAttemptAt > h.state.now); }
    h.state.now += 200_000;
  }
  assert.equal(h.job().state, 'blocked');
  assert.equal(h.job().reason, 'max_attempts_reached');
  assert.equal(h.job().nextAttemptAt, null);
  const deletes = h.state.calls.filter((c) => c === 'delete').length;
  await h.api.process(UID);
  await h.api.request(h.req());
  assert.equal(h.state.calls.filter((c) => c === 'delete').length, deletes, 'plus aucune tentative');
  assert.ok(h.audits().some((a) => a.action === 'account_deletion_failed'));
});

test('reprise du support après le plafond : compteur remis à zéro, le dossier repart et aboutit', async () => {
  const h = setup();
  h.state.failDelete = true;
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  for (let i = 0; i < MAX_ATTEMPTS; i++) { await h.api.process(UID); h.state.now += 200_000; }
  assert.equal(h.job().reason, 'max_attempts_reached');
  h.db.store.set('admins/admin', { role: 'super', isActive: true });
  const support = buildAccountDeletionSupport({ db: h.db, HttpsError, clock: () => h.state.now, admin, process: h.api.process });
  h.state.failDelete = false;
  const r = await support({ auth: { uid: 'admin', token: { firebase: { sign_in_provider: 'password' } } }, data: { action: 'retry', id: UID, resolution: 'technical_retry' } });
  assert.equal(r.result.status, 'completed');
  assert.equal(h.users.has(UID), false);
});

test('reprise après échec de nettoyage : Auth supprimé une seule fois, dossier terminé au passage suivant', async () => {
  const h = setup();
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  h.state.failAssets = true;
  let r = await h.api.process(UID);
  assert.equal(r.status, 'cleanup_pending');
  assert.equal(h.job().authDeleted, true);
  h.state.failAssets = false;
  h.state.now += HOUR + 1;
  r = await h.api.process(UID);
  assert.equal(r.status, 'completed');
  assert.equal(h.state.calls.filter((c) => c === 'delete').length, 1);
});

// ── Inventaire avant suppression Auth ───────────────────────────────────────

test('sous-collection inconnue du profil : dossier bloqué AVANT Auth, compte et profil intacts, motif explicite', async () => {
  const h = setup({ seed: { [`clients/${UID}/secret_docs/d1`]: { note: 'x' } } });
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  const r = await h.api.process(UID);
  assert.equal(r.status, 'blocked');
  assert.equal(r.reason, 'unknown_personal_data_review_required');
  assert.deepEqual(h.job().blockedDetail, ['clients/*/secret_docs']);
  assert.equal(h.job().reviewRequired, true);
  assert.equal(h.job().nextAttemptAt, null);
  assert.equal(h.users.has(UID), true, 'compte Auth intact');
  assert.deepEqual(h.state.calls, []);
  assert.equal(h.db.store.get(`clients/${UID}`).name, 'Awa');
  assert.ok(h.audits().some((a) => a.action === 'account_deletion_blocked' && a.metadata.collections[0] === 'clients/*/secret_docs'));
});

test('dossier bloqué récupérable : après résolution manuelle et reprise du support, la suppression aboutit', async () => {
  const h = setup({ seed: { [`clients/${UID}/secret_docs/d1`]: { note: 'x' } } });
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  await h.api.process(UID);
  h.db.store.delete(`clients/${UID}/secret_docs/d1`);
  h.db.store.set('admins/admin', { role: 'super', isActive: true });
  const support = buildAccountDeletionSupport({ db: h.db, HttpsError, clock: () => h.state.now, admin, process: h.api.process });
  const r = await support({ auth: { uid: 'admin', token: { firebase: { sign_in_provider: 'password' } } }, data: { action: 'retry', id: UID, resolution: 'identity_reviewed' } });
  assert.equal(r.result.status, 'completed');
});

test('sous-collection inconnue côté AZ IA : même blocage avant Auth', async () => {
  const h = setup({ seed: { [`ai_conversations/${UID}/extra/e1`]: { v: 1 }, [`ai_conversations/${UID}/messages/m1`]: { content: 'bonjour' } } });
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  const r = await h.api.process(UID);
  assert.equal(r.reason, 'unknown_personal_data_review_required');
  assert.deepEqual(h.job().blockedDetail, ['ai_conversations/*/extra']);
  assert.equal(h.users.has(UID), true);
  assert.ok(h.db.store.has(`ai_conversations/${UID}/messages/m1`), 'rien n’est effacé tant que le dossier est bloqué');
});

test('échec du journal d’audit avant l’étape irréversible : Auth NON supprimé, reprise planifiée', async () => {
  const h = setup();
  await h.api.request(h.req());
  h.state.now += QUIET_MS + 1;
  h.db.failures.auditAdd = true;
  const r = await h.api.process(UID);
  assert.equal(r.status, 'cleanup_pending');
  assert.equal(h.job().reason, 'server_retry_required');
  assert.equal(h.users.has(UID), true);
  assert.ok(!h.state.calls.includes('delete'));
  h.db.failures.auditAdd = false;
  h.state.now += HOUR + 1;
  assert.equal((await h.api.process(UID)).status, 'completed');
});

test('journal « informatif » défaillant (logAudit injecté) : jamais bloquant', async () => {
  const h = setup({ logAudit: async () => { throw new Error('boom'); } });
  const r = await h.run();
  assert.equal(r.status, 'completed');
});

test('journal d’audit : actions clés présentes, sans jeton ni donnée personnelle', async () => {
  const h = setup();
  await h.run();
  const actions = h.audits().map((a) => a.action);
  for (const a of ['account_deletion_requested', 'account_deletion_auth_delete', 'account_deletion_completed']) assert.ok(actions.includes(a), a);
  const dump = JSON.stringify(h.audits());
  assert.ok(!dump.includes(TOKEN) && !dump.includes('0700000000') && !dump.includes('Awa') && !dump.includes('tok'));
});

// ── Données AZ IA, notifications et conservation ────────────────────────────

test('effacement AZ IA : conversation, mémoire, rappels et actions non exécutées ; consentement et actions confirmées conservés', async () => {
  const seed = {
    [`ai_conversations/${UID}`]: { updatedAt: 1 },
    [`clients/${UID}/notifications/n1`]: { title: 'x' },
    [`clients/${UID}/wallet_transactions/t1`]: { amount: 500 },
    [`ai_user_memory/${UID}`]: { preferences: { address: 'rue 1' } },
    'ai_reminders/r1': { uid: UID, message: 'm', status: 'pending' }, 'ai_reminders/r2': { uid: 'other', message: 'm' },
    'ai_pending_actions/a1': { uid: UID, status: 'pending', toolInput: { phone: '07' } },
    'ai_pending_actions/a2': { uid: UID, status: 'expired' },
    'ai_pending_actions/a3': { uid: UID, status: 'cancelled' },
    'ai_pending_actions/a4': { uid: UID, status: 'completed', amount: 1000 },
    'ai_pending_actions/a5': { uid: 'other', status: 'pending' },
    [`ai_consents/${UID}`]: { granted: true, version: 1 },
    'ai_tool_executions/e1': { uid: UID, toolName: 'create_order', status: 'completed' },
  };
  for (let i = 0; i < 250; i++) seed[`ai_conversations/${UID}/messages/m${String(i).padStart(3, '0')}`] = { content: 'secret ' + i };
  const h = setup({ seed });
  const r = await h.run();
  assert.equal(r.status, 'completed');
  const keys = [...h.db.store.keys()];
  assert.equal(keys.filter((k) => k.startsWith(`ai_conversations/${UID}`)).length, 0, 'messages (3 pages) et document supprimés');
  assert.ok(!h.db.store.has(`ai_user_memory/${UID}`));
  assert.ok(!h.db.store.has('ai_reminders/r1')); assert.ok(h.db.store.has('ai_reminders/r2'));
  for (const id of ['a1', 'a2', 'a3']) assert.ok(!h.db.store.has(`ai_pending_actions/${id}`), id);
  assert.ok(h.db.store.has('ai_pending_actions/a4'), 'action confirmée conservée (trace d’une opération confirmée)');
  assert.ok(h.db.store.has('ai_pending_actions/a5'), 'autre utilisateur intact');
  assert.ok(h.db.store.has(`ai_consents/${UID}`), 'preuve de consentement conservée en attendant la validation juridique');
  assert.ok(h.db.store.has('ai_tool_executions/e1'));
  assert.ok(!h.db.store.has(`clients/${UID}/notifications/n1`), 'notifications effacées');
  assert.ok(h.db.store.has(`clients/${UID}/wallet_transactions/t1`), 'pièces financières conservées');
  const done = h.audits().find((a) => a.action === 'account_deletion_completed');
  assert.equal(done.metadata.aiData.messages, 250);
  assert.equal(done.metadata.aiData.retainedPendingActions, 1);
});

test('données conservées : champs financiers du profil et commandes terminées gardés, champs personnels retirés', async () => {
  const h = setup({ seed: { 'orders/o1': { clientId: UID, status: 'delivered', budget: 1500, clientName: 'Awa', clientPhone: '07', paymentStatus: 'paid', paymentMethod: 'cash' } } });
  // L2 : le moteur d'obligations s'ajoute à l'inspecteur ; une commande livrée SANS moyen de paiement est « ambiguë » (fail-closed).
  await h.run();
  const profile = h.db.store.get(`clients/${UID}`);
  assert.equal(profile.wallet, 0); assert.equal(profile.isDeleted, true);
  assert.ok(!('name' in profile) && !('phone' in profile) && !('fcmToken' in profile));
  const order = h.db.store.get('orders/o1');
  assert.equal(order.budget, 1500); assert.equal(order.status, 'delivered');
  assert.ok(!('clientName' in order) && !('clientPhone' in order));
});

// ── Configuration ───────────────────────────────────────────────────────────

// ── Passerelle (Mission 7E-74) : fermée, absente ou illisible => refus AVANT toute écriture ─────────────────────────
const GATE_ERROR = (e) => e.code === 'failed-precondition' && e.message === 'ACCOUNT_DELETION_NOT_ENABLED' && e.details?.reason === 'ACCOUNT_DELETION_NOT_ENABLED';
const CLOSED_CONFIGS = [null, { enabled: false, inventoryVersion: 1 }, { enabled: true }, { enabled: true, inventoryVersion: 2 },
  { enabled: 'true', inventoryVersion: 1 }, { enabled: true, inventoryVersion: '1' }, {}];
const snapshot = (h) => JSON.stringify([...h.db.store.entries()]);

test('passerelle fermée (absente, désactivée, version incorrecte) : refus identifiable, magasin de documents strictement inchangé, aucun limiteur, aucun appel Auth', async () => {
  for (const role of ['client', 'livreur']) {
    for (const config of CLOSED_CONFIGS) {
      const h = setup({ config, role });
      const before = snapshot(h);
      await assert.rejects(() => h.api.request(h.req()), GATE_ERROR, `${role} ${JSON.stringify(config)}`);
      // L'état Firestore est relu après l'appel : pas seulement le message d'erreur.
      assert.equal(snapshot(h), before, 'aucun document créé, modifié ou supprimé');
      assert.equal(h.job(), undefined, 'aucun dossier');
      assert.equal(h.db.store.has(`account_tombstones/${UID}`), false, 'aucun tombstone');
      assert.equal(h.db.store.get(`${role === 'client' ? 'clients' : 'livreurs'}/${UID}`).deletionRequested, undefined);
      assert.equal(h.db.store.get(`${role === 'client' ? 'clients' : 'livreurs'}/${UID}`).isSuspended, undefined, 'aucune quarantaine');
      assert.equal(h.audits().length, 0, 'aucun audit');
      assert.deepEqual(h.state.limiterCalls, [], 'limiteur (qui écrit) non consommé');
      assert.deepEqual(h.state.calls, []);
      assert.equal(h.users.has(UID), true);
    }
  }
});

test('passerelle fermée : client avec demande antérieure — la nouvelle demande est refusée, le dossier existant reste intact', async () => {
  const h = setup();
  await h.api.request(h.req());
  const prior = JSON.stringify(h.job());
  h.db.store.delete('operations_control/account_deletion');
  h.state.now += HOUR;
  const before = snapshot(h);
  await assert.rejects(() => h.api.request(h.req()), GATE_ERROR);
  assert.equal(snapshot(h), before);
  assert.equal(JSON.stringify(h.job()), prior, 'requestCount et dates inchangés');
});

test('passerelle fermée : livreur avec deletionRequested déjà présent — refus, aucune modification du profil', async () => {
  const h = setup({ role: 'livreur', config: { enabled: false, inventoryVersion: 1 },
    seed: { [`livreurs/${UID}`]: { wallet: 0, name: 'Awa', isOnline: true, deletionRequested: true } } });
  const before = snapshot(h);
  await assert.rejects(() => h.api.request(h.req()), GATE_ERROR);
  assert.equal(snapshot(h), before);
  assert.equal(h.db.store.get(`livreurs/${UID}`).deletionRequested, true, 'valeur existante non touchée');
  assert.equal(h.job(), undefined);
});

test('passerelle illisible (erreur Firestore) : échec sûr, aucune écriture, jamais une autorisation implicite', async () => {
  for (const role of ['client', 'livreur']) {
    const h = setup({ role });
    const collection = h.db.collection;
    h.db.collection = (name) => (name === 'operations_control'
      ? { doc: () => ({ get: async () => { throw new Error('unavailable'); } }) } : collection(name));
    const before = snapshot(h);
    await assert.rejects(() => h.api.request(h.req()), /unavailable/);
    assert.equal(snapshot(h), before);
    assert.equal(h.job(), undefined);
    assert.deepEqual(h.state.limiterCalls, []);
    assert.equal(h.audits().length, 0);
  }
});

test('passerelle ouverte : demande valide inchangée — dossier, marqueur livreur, audit, limiteur ; répétition absorbée (idempotence)', async () => {
  for (const role of ['client', 'livreur']) {
    const h = setup({ role });
    const first = await h.api.request(h.req());
    assert.equal(first.status, 'quarantined');
    assert.equal(h.job().requestCount, 1);
    assert.equal(h.job().role, role);
    assert.equal(h.db.store.has(`account_tombstones/${UID}`), true);
    assert.equal(h.db.store.get(`${role === 'client' ? 'clients' : 'livreurs'}/${UID}`).deletionRequested, role === 'livreur' ? true : undefined);
    assert.deepEqual(h.state.limiterCalls.map((c) => c[1]), ['account_deletion_request']);
    assert.deepEqual(h.audits().map((a) => a.action), ['account_deletion_requested']);
    const again = await h.api.request(h.req());
    assert.equal(again.status, 'quarantined');
    assert.equal(h.job().requestCount, 1, 'demande répétée absorbée');
    assert.equal(h.audits().filter((a) => a.action === 'account_deletion_request_repeated').length, 1);
    assert.equal(h.state.limiterCalls.length, 2);
  }
});

test('passerelle ouverte : le limiteur reste appliqué et son refus bloque toute écriture', async () => {
  const h = setup();
  h.state.limiterError = new HttpsError('resource-exhausted', 'RATE');
  const before = snapshot(h);
  await assert.rejects(() => h.api.request(h.req()), (e) => e.code === 'resource-exhausted');
  assert.equal(snapshot(h), before);
  assert.equal(h.state.limiterCalls.length, 1);
});

test('failurePatch : compteur, reprise horaire puis arrêt ; après suppression Auth le dossier reste « cleanup_pending »', () => {
  const opts = { now: 10, retryMs: 5, maxAttempts: 3 };
  assert.deepEqual(cleanup.failurePatch({ attempts: 1 }, opts), { attempts: 2, state: 'cleanup_pending', reason: 'server_retry_required', reviewRequired: true, nextAttemptAt: 15 });
  const stop = cleanup.failurePatch({ attempts: 2 }, opts);
  assert.equal(stop.state, 'blocked'); assert.equal(stop.nextAttemptAt, null); assert.equal(stop.reason, 'max_attempts_reached');
  assert.equal(cleanup.failurePatch({ attempts: 2, authDeleted: true }, opts).state, 'cleanup_pending');
});

test('index.js câble le limiteur et le journal du projet sur le moteur de suppression', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(src, /buildAccountDeletion\(\{db,auth:admin\.auth\(\),admin,HttpsError,checkRateLimit,logAudit,/);
});

test('ces tests n’utilisent aucun accès cloud (ni SDK admin, ni émulateur, ni projet réel)', () => {
  const src = fs.readFileSync(__filename, 'utf8');
  assert.doesNotMatch(src, /require\(['"]firebase-admin['"]\)/);
  assert.doesNotMatch(src, /initializeApp\s*\(/);
  assert.doesNotMatch(src, new RegExp('EMULATOR' + '_HOST'));
});
