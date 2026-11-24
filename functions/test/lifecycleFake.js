'use strict';

function query(store, collection, filters = []) {
  return {
    where: (field, op, value) => query(store, collection, [...filters, { field, op, value }]),
    limit: n => ({
      get: async () => {
        const docs = [...store].filter(([path, data]) =>
          path.startsWith(`${collection}/`) && !path.slice(collection.length + 1).includes('/') &&
          filters.every(({ field, op, value }) => op === '==' && data[field] === value))
          .slice(0, n).map(([path, data]) => ({ id: path.split('/').pop(), data: () => data }));
        return { docs, empty: !docs.length, size: docs.length };
      },
    }),
  };
}

const deletion = { __delete: true };
const admin = { firestore: { FieldValue: {
  delete: () => deletion, serverTimestamp: () => 'now', increment: n => ({ __increment: n }),
} } };

function fakeDb(seed) {
  const store = new Map(Object.entries(seed));
  let tail = Promise.resolve();
  let writes = 0;
  const ref = path => ({ id: path.split('/').pop(), __path: path,
    get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
    collection: name => collection(`${path}/${name}`) });
  const collection = name => ({ ...query(store, name), doc: id => ref(`${name}/${id}`) });
  const db = { collection, runTransaction: (fn, options) => {
    const execute = tail.then(async () => {
      const pending = [];
      const result = await fn({
        get: async r => {
          if (pending.length) throw Error('Read after write');
          return r.get();
        },
        update: (r, data) => pending.push([r, data]),
      });
      if (options?.readOnly && pending.length) throw Error('Read-only transaction wrote');
      for (const [r, data] of pending) {
        const next = { ...store.get(r.__path) };
        for (const [key, value] of Object.entries(data)) {
          if (value?.__delete) delete next[key];
          else if (value?.__increment != null) next[key] = (next[key] || 0) + value.__increment;
          else next[key] = value;
        }
        store.set(r.__path, next); writes++;
      }
      return result;
    });
    tail = execute.catch(() => {});
    return execute;
  } };
  return { db, store, writes: () => writes };
}
module.exports = { query, fakeDb, admin };
