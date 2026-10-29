'use strict';

// Faux Firestore minimal partagé par les tests de livreur (documents par chemin,
// transactions à écritures différées, requêtes d'égalité chaînées).
const DELETE = Symbol('delete');

// Faux Firestore minimal : documents par chemin, transactions à écritures
// différées (appliquées au commit, annulées si le callback échoue).
function fakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoSeq = 0;
  const applyPatch = (path, patch, merge = true) => {
    const next = merge ? { ...(store.get(path) || {}) } : {};
    for (const [k, v] of Object.entries(patch)) {
      if (v === DELETE) delete next[k];
      else if (v && v.__arrayUnion) next[k] = [...(Array.isArray(next[k]) ? next[k] : []), ...v.__arrayUnion.filter((x) => !(next[k] || []).some((y) => JSON.stringify(y) === JSON.stringify(x)))];
      else if (v && v.__increment !== undefined) next[k] = Number(next[k] || 0) + v.__increment;
      else next[k] = v;
    }
    store.set(path, next);
  };
  const ref = (path) => ({
    path, id: path.split('/').pop(),
    get: async () => ({ exists: store.has(path), data: () => store.get(path), id: path.split('/').pop() }),
    collection: (name) => collection(`${path}/${name}`),
    // Écritures hors transaction (journaux, compteurs) : mêmes sémantiques que l'Admin SDK.
    set: async (data, opts) => applyPatch(path, data, !!(opts && opts.merge)),
    create: async (data) => {
      if (store.has(path)) throw new Error(`create sur document existant ${path}`);
      applyPatch(path, data, false);
    },
    delete: async () => { store.delete(path); },
    update: async (patch) => {
      if (!store.has(path)) throw new Error(`update sur document absent ${path}`);
      applyPatch(path, patch, true);
    },
  });
  const collection = (name) => ({
    doc: (id) => ref(`${name}/${id}`),
    add: async (data) => {
      const id = `auto${autoSeq++}`;
      applyPatch(`${name}/${id}`, data, false);
      return ref(`${name}/${id}`);
    },
    where(field, op, value) { return makeQuery(name, [[field, value, op]]); },
    limit(n) { return makeQuery(name, []).limit(n); },
    get() { return makeQuery(name, []).get(); },
  });
  const makeQuery = (name, filters) => {
    const query = {
      limitN: Infinity,
      where(field, op, value) { return makeQuery(name, [...filters, [field, value, op]]); },
      limit(n) { query.limitN = n; return query; },
      get: async () => {
        const docs = [...store.entries()]
          .filter(([k, v]) => k.startsWith(`${name}/`) && !k.slice(name.length + 1).includes('/') &&
            filters.every(([f, val, op]) => (op === 'array-contains' ? Array.isArray(v[f]) && v[f].includes(val) : v[f] === val)))
          .slice(0, query.limitN)
          .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v }));
        return { docs, empty: docs.length === 0, size: docs.length };
      },
    };
    return query;
  };
  const db = {
    store, collection,
    runTransaction: async (callback) => {
      const writes = [];
      const tx = {
        get: async (target) => target.path ? target.get() : target.get(),
        update: (r, patch) => {
          if (!store.has(r.path)) throw new Error(`update sur document absent ${r.path}`);
          writes.push(['update', r.path, patch]);
        },
        set: (r, data) => writes.push(['set', r.path, data]),
      };
      const result = await callback(tx);
      for (const [type, path, data] of writes) applyPatch(path, data, type === 'update');
      return result;
    },
  };
  return db;
}


const arrayUnion = (...items) => ({ __arrayUnion: items });
module.exports = { fakeDb, DELETE, arrayUnion };
