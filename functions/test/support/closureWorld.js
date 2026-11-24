'use strict';

// Monde de test en mémoire pour le protocole de fermeture (L2) : faux Firestore (transactions, requêtes, array-contains) et faux Auth
// avec points d'injection. AUCUN accès cloud. Les écritures d'une transaction sont appliquées au commit, comme dans accountDeletionHardening.
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAccountDeletion, QUIET_MS } = require('../../accountDeletion');

const DELETE = Symbol('delete');
const UID = 'u1';
const TOKEN = 'a'.repeat(64);

function fakeStore(seed = {}) {
  const store = new Map(Object.entries(seed));
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
    return {
      where: (f, op, v) => query(name, [...filters, [f, op, v]], limitN, after),
      limit: (n) => query(name, filters, n, after),
      startAfter: (d) => query(name, filters, limitN, d),
      get: async () => {
        if (store.queryFailure && store.queryFailure(name)) throw new Error('read failure ' + name);
        const match = (v, [f, op, val]) => (op === 'array-contains' ? Array.isArray(v[f]) && v[f].includes(val) : v[f] === val);
        let docs = [...store.entries()]
          .filter(([k]) => k.startsWith(name + '/') && !k.slice(name.length + 1).includes('/'))
          .filter(([, v]) => filters.every((flt) => match(v, flt)))
          .map(([k]) => snapOf(k)).sort((a, b) => (a.id < b.id ? -1 : 1));
        if (after) docs = docs.filter((d) => d.id > after.id);
        docs = docs.slice(0, limitN);
        return { docs, empty: docs.length === 0, size: docs.length };
      },
    };
  }
  let seq = 0;
  function colRef(name) {
    return {
      id: name.split('/').pop(), path: name,
      doc: (id) => docRef(`${name}/${id || 'auto' + (++seq)}`),
      add: async (d) => { const r = docRef(`${name}/auto${++seq}`); apply(r.path, d, false); return r; },
      where: (f, op, v) => query(name, [[f, op, v]], Infinity, null),
      limit: (n) => query(name, [], n, null),
      get: () => query(name, [], Infinity, null).get(),
    };
  }
  return {
    store, collection: colRef, doc: (p) => docRef(p),
    batch: () => { const ops = []; return { delete: (r) => ops.push(r.path), commit: async () => { for (const p of ops) store.delete(p); } }; },
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
}

const admin = { firestore: { Timestamp: { fromMillis: (ms) => ({ ms }) }, FieldValue: { serverTimestamp: () => 'TS', delete: () => DELETE } } };
const missing = () => Object.assign(new Error('missing'), { code: 'auth/user-not-found' });

// role : 'client' | 'livreur' (moteur client/livreur) ou 'seller' (moteur partenaires, config partnerInventoryVersion:1).
function makeWorld({ role = 'client', seed = {}, partner = false } = {}) {
  const profileCol = { client: 'clients', livreur: 'livreurs', seller: 'sellers' }[role];
  const docs = { [`${profileCol}/${UID}`]: { wallet: 0, name: 'Awa', phone: '0700000000', fcmToken: 'tok' }, ...seed };
  docs['operations_control/account_deletion'] = { enabled: true, inventoryVersion: 1, ...(partner ? { partnerInventoryVersion: 1 } : {}) };
  const db = fakeStore(docs);
  const users = new Map([[UID, { uid: UID }]]);
  const state = { now: 1_000_000_000_000, calls: [], failDelete: false, getUserFailure: false, onDisable: null, snapshotsAtDelete: [] };
  const auth = {
    updateUser: async (_uid, patch) => {
      if (!users.has(UID)) throw missing();
      state.calls.push(patch.disabled ? 'disable' : 'enable');
      if (patch.disabled && state.onDisable) await state.onDisable();
    },
    revokeRefreshTokens: async () => { state.calls.push('revoke'); },
    deleteUser: async () => {
      state.calls.push('delete');
      state.snapshotsAtDelete.push({ ...db.store.get(`account_tombstones/${UID}`) });
      if (state.failDelete) throw new Error('transient');
      users.delete(UID);
    },
    getUser: async () => {
      if (state.getUserFailure) throw Object.assign(new Error('auth unavailable'), { code: 'auth/internal-error' });
      if (!users.has(UID)) throw missing();
      return {};
    },
  };
  const api = buildAccountDeletion({
    db, auth, admin, HttpsError, clock: () => state.now, checkRateLimit: async () => {}, eraseAssets: async () => { state.calls.push('assets'); },
  });
  const req = () => ({
    auth: { uid: UID, token: { auth_time: Math.floor(state.now / 1000), firebase: { sign_in_provider: 'password' } } },
    data: { role, recoveryToken: TOKEN, allProfilesConsent: true },
  });
  const tomb = () => db.store.get(`account_tombstones/${UID}`);
  const job = () => db.store.get(`account_deletions/${UID}`);
  const audits = () => [...db.store.entries()].filter(([k]) => k.startsWith('audit_logs/')).map(([, v]) => v);
  const quarantine = async () => api.request(req());
  const afterQuiet = async () => { state.now += QUIET_MS + 1; return api.process(UID); };
  const snapshot = () => JSON.stringify([...db.store.entries()]);
  return { db, users, state, auth, api, req, tomb, job, audits, quarantine, afterQuiet, snapshot, UID, QUIET_MS };
}

module.exports = { makeWorld, fakeStore, UID, TOKEN, DELETE };
