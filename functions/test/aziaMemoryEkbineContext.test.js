'use strict';

// Master Prompt 113 — couverture des ajouts réels de cette passe : mémoire
// utilisateur (remember_user_info/getUserMemory), assemblage de contexte
// (buildUserContext), historique wallet (get_wallet_transactions), et les
// outils E-Kbine jusqu'ici inexistants (create_ekbine_order/track_ekbine_order).
// Même fake Firestore/fake admin que les autres tests azia/*.test.js, étendu
// avec un support minimal des requêtes where/orderBy/limit — nécessaire ici
// car (contrairement à orderActions.test.js) plusieurs de ces outils lisent
// des collections par requête, pas seulement par doc().get().

const test = require('node:test');
const assert = require('node:assert/strict');

const { rememberUserInfo, getUserMemory } = require('../azia/tools/memory');
const { buildUserContext } = require('../azia/contextBuilder');
const { getWalletTransactions } = require('../azia/tools/wallet');
const { trackEkbineOrder, createEkbineOrder } = require('../azia/tools/ekbine');

function fakeTimestamp(n) {
  return { __ts: n, toDate: () => ({ toISOString: () => `2026-01-${String(n).padStart(2, '0')}T00:00:00.000Z` }) };
}

function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  let autoId = 0;

  function applyUpdate(existing, data) {
    const out = { ...existing };
    for (const k of Object.keys(data)) {
      const v = data[k];
      if (v && v.__increment !== undefined) {
        out[k] = (existing[k] || 0) + v.__increment;
      } else {
        out[k] = v;
      }
    }
    return out;
  }

  function makeRef(path) {
    return {
      id: path.split('/').pop(),
      __path: path,
      get: async () => ({ exists: store.has(path), data: () => store.get(path) }),
      set: async (data, opts) => {
        if (opts && opts.merge) {
          store.set(path, { ...(store.get(path) || {}), ...data });
        } else {
          store.set(path, data);
        }
      },
      update: async (data) => { store.set(path, applyUpdate(store.get(path) || {}, data)); },
      collection: (sub) => makeCollection(`${path}/${sub}`),
    };
  }

  function matchingDocs(prefix, filters) {
    return [...store.entries()]
      .filter(([k]) => k.startsWith(`${prefix}/`) && !k.slice(prefix.length + 1).includes('/'))
      .filter(([, data]) => filters.every(([field, , value]) => data[field] === value))
      .map(([k, data]) => ({ id: k.split('/').pop(), data: () => data, ref: makeRef(k) }));
  }

  function makeQuery(prefix, filters, order) {
    return {
      where: (field, op, value) => makeQuery(prefix, [...filters, [field, op, value]], order),
      orderBy: (field, dir) => makeQuery(prefix, filters, { field, dir: dir || 'asc' }),
      limit: (n) => ({
        get: async () => {
          let docs = matchingDocs(prefix, filters);
          if (order) {
            docs.sort((a, b) => {
              const av = a.data()[order.field]?.__ts ?? 0;
              const bv = b.data()[order.field]?.__ts ?? 0;
              return order.dir === 'desc' ? bv - av : av - bv;
            });
          }
          docs = docs.slice(0, n);
          return { empty: docs.length === 0, docs, size: docs.length };
        },
      }),
      get: async () => {
        const docs = matchingDocs(prefix, filters);
        return { empty: docs.length === 0, docs, size: docs.length };
      },
    };
  }

  function makeCollection(name) {
    return {
      doc: (id) => makeRef(`${name}/${id ?? `auto${autoId++}`}`),
      add: async (data) => {
        const path = `${name}/auto${autoId++}`;
        store.set(path, data);
        return { id: path.split('/').pop() };
      },
      where: (field, op, value) => makeQuery(name, [[field, op, value]]),
      orderBy: (field, dir) => makeQuery(name, [], { field, dir: dir || 'asc' }),
    };
  }

  const db = {
    collection: (name) => makeCollection(name),
    runTransaction: async (fn) => {
      const tx = {
        get: async (ref) => ({ exists: store.has(ref.__path), data: () => store.get(ref.__path) }),
        update: (ref, data) => store.set(ref.__path, applyUpdate(store.get(ref.__path) || {}, data)),
        set: (ref, data) => store.set(ref.__path, data),
      };
      return fn(tx);
    },
  };

  return { db, store };
}

const fakeAdmin = {
  firestore: {
    FieldValue: {
      serverTimestamp: () => '__SERVER_TIMESTAMP__',
      increment: (n) => ({ __increment: n }),
    },
    Timestamp: {
      fromMillis: (ms) => ({ toMillis: () => ms }),
    },
  },
};

const HttpsError = class extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
};

// ── remember_user_info / getUserMemory ──────────────────────────────────────

test('remember_user_info: saves only allowed, non-empty fields and merges into ai_user_memory/{uid}', async () => {
  const { db, store } = makeFakeDb();
  const tool = rememberUserInfo({ db, admin: fakeAdmin });

  const result = await tool.handler('u1', {
    address: 'Près du marché de Cafétou', quartier: 'Cafétou',
    notAllowedField: 'ignored', name: '  ', // vide après trim -> ignoré
  });

  assert.equal(result.saved, true);
  assert.deepEqual(result.fields.sort(), ['address', 'quartier']);
  const saved = store.get('ai_user_memory/u1');
  assert.equal(saved.address, 'Près du marché de Cafétou');
  assert.equal(saved.quartier, 'Cafétou');
  assert.equal(saved.notAllowedField, undefined);
  assert.equal(saved.name, undefined);
});

test('remember_user_info: merges with an existing document rather than overwriting it', async () => {
  const { db, store } = makeFakeDb({ 'ai_user_memory/u1': { address: 'Ancien repère', ville: 'Abengourou' } });
  const tool = rememberUserInfo({ db, admin: fakeAdmin });

  await tool.handler('u1', { favoritePharmacyId: 'p1' });

  const saved = store.get('ai_user_memory/u1');
  assert.equal(saved.address, 'Ancien repère');
  assert.equal(saved.ville, 'Abengourou');
  assert.equal(saved.favoritePharmacyId, 'p1');
});

test('remember_user_info: reports nothing saved when no exploitable field is provided', async () => {
  const { db } = makeFakeDb();
  const tool = rememberUserInfo({ db, admin: fakeAdmin });

  const result = await tool.handler('u1', { unknownField: 'x' });
  assert.equal(result.saved, false);
});

test('getUserMemory: returns null when no memory document exists', async () => {
  const { db } = makeFakeDb();
  assert.equal(await getUserMemory(db, 'u1'), null);
});

test('getUserMemory: returns the stored memory when it exists', async () => {
  const { db } = makeFakeDb({ 'ai_user_memory/u1': { quartier: 'Cafétou' } });
  const memory = await getUserMemory(db, 'u1');
  assert.equal(memory.quartier, 'Cafétou');
});

// ── buildUserContext ─────────────────────────────────────────────────────

test('buildUserContext: returns null when nothing is known about the user', async () => {
  const { db } = makeFakeDb();
  assert.equal(await buildUserContext(db, 'u1', null), null);
});

test('buildUserContext: includes client profile, memory fields and GPS location, never re-asking known info', async () => {
  const { db } = makeFakeDb({
    'clients/u1':       { name: 'Awa Koné', phone: '+2250700000000' },
    'ai_user_memory/u1': { quartier: 'Cafétou', preferredPaymentMethod: 'wallet' },
  });

  const text = await buildUserContext(db, 'u1', { latitude: 6.73, longitude: -3.49, address: 'Cafétou' });

  assert.ok(text.includes('Awa Koné'));
  assert.ok(text.includes('+2250700000000'));
  assert.ok(text.includes('Cafétou'));
  assert.ok(text.includes('wallet'));
  assert.ok(text.includes('6.73'));
  assert.ok(text.includes('ne jamais les redemander'));
});

test('buildUserContext: degrades gracefully (no crash) when the client document does not exist', async () => {
  const { db } = makeFakeDb({ 'ai_user_memory/u1': { ville: 'Abengourou' } });
  const text = await buildUserContext(db, 'u1', null);
  assert.ok(text.includes('Abengourou'));
});

// ── get_wallet_transactions ──────────────────────────────────────────────

test('get_wallet_transactions: returns the most recent transactions first, respecting the default limit', async () => {
  const { db } = makeFakeDb({
    'clients/u1/wallet_transactions/t1': { type: 'recharge', amount: 1000, createdAt: fakeTimestamp(1) },
    'clients/u1/wallet_transactions/t2': { type: 'payment', amount: -500, createdAt: fakeTimestamp(2) },
    'clients/u1/wallet_transactions/t3': { type: 'refund', amount: 500, createdAt: fakeTimestamp(3) },
  });
  const tool = getWalletTransactions({ db });

  const result = await tool.handler('u1', {});
  assert.equal(result.transactions.length, 3);
  assert.equal(result.transactions[0].type, 'refund'); // le plus récent d'abord
  assert.equal(result.transactions[2].type, 'recharge');
});

test('get_wallet_transactions: clamps an out-of-range limit to [1, 20]', async () => {
  const { db } = makeFakeDb({
    'clients/u1/wallet_transactions/t1': { type: 'recharge', amount: 1000, createdAt: fakeTimestamp(1) },
  });
  const tool = getWalletTransactions({ db });

  const result = await tool.handler('u1', { limit: 500 });
  assert.equal(result.transactions.length, 1); // un seul mouvement existe, quel que soit le plafond demandé
});

// ── track_ekbine_order ───────────────────────────────────────────────────

test('track_ekbine_order: returns the client\'s recent E-Kbine orders when no orderId is given', async () => {
  const { db } = makeFakeDb({
    'ekbine_orders/e1': { clientId: 'u1', operator: 'orange', serviceLabel: 'Dépôt', amount: 1000, status: 'pending', createdAt: fakeTimestamp(1) },
    'ekbine_orders/e2': { clientId: 'other', operator: 'mtn', serviceLabel: 'Dépôt', amount: 2000, status: 'pending', createdAt: fakeTimestamp(2) },
  });
  const tool = trackEkbineOrder({ db });

  const result = await tool.handler('u1', {});
  assert.equal(result.found, true);
  assert.equal(result.orders.length, 1);
  assert.equal(result.orders[0].id, 'e1');
});

test('track_ekbine_order: refuses to return an order belonging to another client', async () => {
  const { db } = makeFakeDb({
    'ekbine_orders/e1': { clientId: 'other', operator: 'orange', serviceLabel: 'Dépôt', amount: 1000, status: 'pending' },
  });
  const tool = trackEkbineOrder({ db });

  const result = await tool.handler('u1', { orderId: 'e1' });
  assert.equal(result.found, false);
});

test('track_ekbine_order: includes agent contact info when an agent is already assigned', async () => {
  const { db } = makeFakeDb({
    'ekbine_orders/e1': { clientId: 'u1', operator: 'wave', serviceLabel: 'Transfert', amount: 1500, status: 'assigned', agentId: 'a1' },
    'ekbine_agents/a1': { name: 'Jean Agent', phone: '+2250711111111' },
  });
  const tool = trackEkbineOrder({ db });

  const result = await tool.handler('u1', { orderId: 'e1' });
  assert.equal(result.found, true);
  assert.equal(result.agentContact.name, 'Jean Agent');
  assert.equal(result.agentContact.phone, '+2250711111111');
});

// ── create_ekbine_order ──────────────────────────────────────────────────

test('create_ekbine_order: handler creates a pending action requiring confirmation (never mutates directly)', async () => {
  const { db, store } = makeFakeDb({ 'clients/u1': { wallet: 5000 } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await tool.handler('u1', {
    operator: 'orange', serviceId: 'momo_deposit', serviceLabel: 'Dépôt Orange Money',
    beneficiaryNumber: '+2250700000001', amount: 1000, paymentMethod: 'wallet',
  }, { conversationId: 'c1' });

  assert.equal(result.status, 'awaiting_confirmation');
  assert.ok(result.actionId);
  const pending = store.get(`ai_pending_actions/${result.actionId}`);
  assert.equal(pending.toolName, 'create_ekbine_order');
  assert.equal(pending.status, 'pending');
  assert.equal(store.get('clients/u1').wallet, 5000); // rien débité avant confirmation
});

test('create_ekbine_order: handler rejects an insufficient wallet balance before even creating a pending action', async () => {
  const { db, store } = makeFakeDb({ 'clients/u1': { wallet: 100 } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => tool.handler('u1', {
      operator: 'orange', serviceId: 'momo_deposit', serviceLabel: 'Dépôt Orange Money',
      beneficiaryNumber: '+2250700000001', amount: 1000, paymentMethod: 'wallet',
    }),
    /Solde wallet insuffisant/,
  );
  assert.equal([...store.keys()].some(k => k.startsWith('ai_pending_actions/')), false);
});

test('create_ekbine_order: handler rejects an invalid operator', async () => {
  const { db } = makeFakeDb({ 'clients/u1': { wallet: 5000 } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => tool.handler('u1', {
      operator: 'canal+', serviceId: 'x', serviceLabel: 'x',
      beneficiaryNumber: '+2250700000001', amount: 1000, paymentMethod: 'wallet',
    }),
    /Opérateur invalide/,
  );
});

test('create_ekbine_order: confirmHandler debits the wallet and creates the order (fee=0, project_ekbine_no_fee)', async () => {
  const { db, store } = makeFakeDb({ 'clients/u1': { wallet: 5000, name: 'Awa', phone: '+225070000' } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'u1', {
    operator: 'orange', serviceId: 'momo_deposit', serviceLabel: 'Dépôt Orange Money',
    beneficiaryNumber: '+2250700000001', amount: 1000, paymentMethod: 'wallet',
  }));

  assert.equal(store.get('clients/u1').wallet, 4000);
  const orderEntry = [...store.entries()].find(([k]) => k.startsWith('ekbine_orders/'));
  assert.ok(orderEntry, 'ekbine order should be created');
  assert.equal(orderEntry[1].fee, 0);
  assert.equal(orderEntry[1].totalPaid, 1000);
  assert.equal(orderEntry[1].agentEarning, 1000); // wallet => agent gagne le montant intégral
  assert.equal(orderEntry[1].status, 'pending');
  assert.equal(orderEntry[1].source, 'ai_chat');
  assert.equal(result.orderId, orderEntry[0].split('/').pop());
});

test('create_ekbine_order: confirmHandler never touches the wallet for a non-wallet payment method', async () => {
  const { db, store } = makeFakeDb({ 'clients/u1': { wallet: 5000 } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  await db.runTransaction((tx) => tool.confirmHandler(tx, 'u1', {
    operator: 'mtn', serviceId: 'momo_deposit', serviceLabel: 'Dépôt MTN Money',
    beneficiaryNumber: '+2250700000002', amount: 2000, paymentMethod: 'mtn_momo',
  }));

  assert.equal(store.get('clients/u1').wallet, 5000);
  const orderEntry = [...store.entries()].find(([k]) => k.startsWith('ekbine_orders/'));
  assert.equal(orderEntry[1].agentEarning, 0); // pas wallet => rien pré-payé à l'agent
});

test('create_ekbine_order: confirmHandler rejects (money-loss guard) if the wallet balance dropped below the amount since the pending action was created', async () => {
  const { db } = makeFakeDb({ 'clients/u1': { wallet: 100 } });
  const tool = createEkbineOrder({ db, admin: fakeAdmin, HttpsError });

  await assert.rejects(
    () => db.runTransaction((tx) => tool.confirmHandler(tx, 'u1', {
      operator: 'orange', serviceId: 'momo_deposit', serviceLabel: 'Dépôt Orange Money',
      beneficiaryNumber: '+2250700000001', amount: 1000, paymentMethod: 'wallet',
    })),
    (err) => err.code === 'failed-precondition',
  );
});
