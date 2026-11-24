'use strict';
function timestamp(ms) {
  return { toMillis: () => ms };
}

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;
  let transactionTail = Promise.resolve();

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({
        exists: store.has(path),
        data: () => store.get(path),
      }),
      set: async (data) => store.set(path, data),
      update: async (data) => store.set(path, applyUpdate(store.get(path) || {}, data)),
      collection: (name) => makeCollection(`${path}/${name}`),
    };
  }

  function makeCollection(path) {
    return {
      doc: (id) => makeRef(`${path}/${id ?? `auto${autoId++}`}`),
      add: async (data) => {
        const ref = makeRef(`${path}/auto${autoId++}`);
        store.set(ref.__path, data);
        return { id: ref.id };
      },
    };
  }

  const db = {
    collection: (path) => makeCollection(path),
    runTransaction: (callback) => {
      const execute = transactionTail.then(async () => {
        const writes = [];
        const tx = {
          get: async (ref) => ({
            exists: store.has(ref.__path),
            data: () => store.get(ref.__path),
          }),
          set: (ref, data) => writes.push({ type: 'set', ref, data }),
          update: (ref, data) => writes.push({ type: 'update', ref, data }),
        };
        const result = await callback(tx);
        for (const write of writes) {
          if (write.type === 'set') store.set(write.ref.__path, write.data);
          else store.set(write.ref.__path, applyUpdate(store.get(write.ref.__path) || {}, write.data));
        }
        return result;
      });
      transactionTail = execute.catch(() => {});
      return execute;
    },
  };

  return { db, store };
}

function applyUpdate(existing, update) {
  const result = { ...existing };
  for (const [key, value] of Object.entries(update)) {
    if (value && value.__increment !== undefined) {
      result[key] = Number(existing[key] || 0) + value.__increment;
    } else {
      result[key] = value;
    }
  }
  return result;
}

const fakeAdmin = {
  firestore: {
    Timestamp: { fromMillis: timestamp },
    FieldValue: {
      serverTimestamp: () => timestamp(Date.now()),
      increment: (amount) => ({ __increment: amount }),
    },
  },
};


module.exports = { makeFakeDb, fakeAdmin };
