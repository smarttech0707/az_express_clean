'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  runWalletReconciliation,
  reconcileAccount,
  CREDIT_TYPES,
  DEBIT_TYPES,
} = require('../walletReconciliation');

// Fake Firestore couvrant exactement ce que walletReconciliation.js touche :
// collection(name).get() pour lister les comptes, et sur une sous-collection
// wallet_transactions : where('type','in',[...]).aggregate({...}).get() pour
// sommer, et where('type','not-in',[...]).count().get() pour compter les
// types non classés. Pas de dépendance à l'émulateur Firestore.
function makeFakeDb({ accounts = {}, transactions = {} } = {}) {
  const written = [];

  function txCollection(path) {
    const txs = transactions[path] || [];
    return {
      where: (field, op, value) => ({
        aggregate: (spec) => ({
          get: async () => {
            const field2 = Object.keys(spec)[0];
            const matching = txs.filter((t) => {
              if (op === 'in') return value.includes(t.type);
              if (op === 'not-in') return !value.includes(t.type);
              return true;
            });
            const total = matching.reduce((sum, t) => sum + (t.amount || 0), 0);
            return { data: () => ({ [field2]: total }) };
          },
        }),
        count: () => ({
          get: async () => {
            const matching = txs.filter((t) => {
              if (op === 'in') return value.includes(t.type);
              if (op === 'not-in') return !value.includes(t.type);
              return true;
            });
            return { data: () => ({ count: matching.length }) };
          },
        }),
      }),
    };
  }

  function makeAccountsCollection(name) {
    const docs = Object.entries(accounts[name] || {}).map(([id, data]) => ({
      id,
      data: () => data,
    }));
    return {
      get: async () => ({ size: docs.length, docs }),
      doc: (id) => ({
        collection: (sub) => (sub === 'wallet_transactions' ? txCollection(`${name}/${id}/wallet_transactions`) : null),
      }),
    };
  }

  const db = {
    collection: (name) => {
      if (name.includes('/')) return txCollection(name);
      if (name === 'wallet_reconciliation_findings') {
        return { doc: () => ({ __path: 'wallet_reconciliation_findings/auto' }) };
      }
      return makeAccountsCollection(name);
    },
    batch: () => ({
      set: (ref, data) => written.push({ ref, data }),
      commit: async () => {},
    }),
  };

  return { db, written };
}

const fakeAdmin = {
  firestore: { FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' } },
};

test('CREDIT_TYPES and DEBIT_TYPES do not overlap', () => {
  const overlap = CREDIT_TYPES.filter((t) => DEBIT_TYPES.includes(t));
  assert.deepEqual(overlap, []);
});

test('reconcileAccount: reports zero drift when wallet matches the transaction history', async () => {
  const { db } = makeFakeDb({
    transactions: {
      'clients/c1/wallet_transactions': [
        { type: 'recharge', amount: 5000 },
        { type: 'payment', amount: 2000 },
      ],
    },
  });
  const docSnap = { id: 'c1', data: () => ({ wallet: 3000 }) };

  const result = await reconcileAccount(db, 'clients', docSnap);

  assert.equal(result.computedBalance, 3000);
  assert.equal(result.drift, 0);
  assert.equal(result.unclassifiedCount, 0);
});

test('reconcileAccount: reports a non-zero drift when the wallet field disagrees with history', async () => {
  const { db } = makeFakeDb({
    transactions: {
      'livreurs/d1/wallet_transactions': [
        { type: 'recharge', amount: 1000 },
        { type: 'commission', amount: 100 },
      ],
    },
  });
  const docSnap = { id: 'd1', data: () => ({ wallet: 5000 }) }; // devrait être 900

  const result = await reconcileAccount(db, 'livreurs', docSnap);

  assert.equal(result.computedBalance, 900);
  assert.equal(result.drift, 4100);
});

test('reconcileAccount: counts unclassified transaction types without guessing their sign', async () => {
  const { db } = makeFakeDb({
    transactions: {
      'sellers/s1/wallet_transactions': [
        { type: 'sale', amount: 1000 },
        { type: 'mystery_type', amount: 500 },
      ],
    },
  });
  const docSnap = { id: 's1', data: () => ({ wallet: 1000 }) };

  const result = await reconcileAccount(db, 'sellers', docSnap);

  assert.equal(result.computedBalance, 1000); // mystery_type exclu du calcul
  assert.equal(result.drift, 0);
  assert.equal(result.unclassifiedCount, 1);
});

test('runWalletReconciliation: only writes findings for accounts with drift or unclassified transactions', async () => {
  const { db, written } = makeFakeDb({
    accounts: {
      clients:  { ok: { wallet: 100 }, bad: { wallet: 999 } },
      livreurs: {}, sellers: {}, restaurants: {}, pharmacies: {}, boulangeries: {},
    },
    transactions: {
      'clients/ok/wallet_transactions':  [{ type: 'recharge', amount: 100 }],
      'clients/bad/wallet_transactions': [{ type: 'recharge', amount: 100 }],
    },
  });
  const logAudit = async () => {};

  const result = await runWalletReconciliation(db, fakeAdmin, { logAudit });

  assert.equal(result.totalChecked, 2);
  assert.equal(result.findingsCount, 1);
  assert.equal(written.length, 1);
  assert.equal(written[0].data.docId, 'bad');
});

test('runWalletReconciliation: reports zero findings when every account reconciles cleanly', async () => {
  const { db, written } = makeFakeDb({
    accounts: {
      clients: { c1: { wallet: 500 } },
      livreurs: {}, sellers: {}, restaurants: {}, pharmacies: {}, boulangeries: {},
    },
    transactions: {
      'clients/c1/wallet_transactions': [{ type: 'recharge', amount: 500 }],
    },
  });

  const result = await runWalletReconciliation(db, fakeAdmin, {});

  assert.equal(result.findingsCount, 0);
  assert.equal(written.length, 0);
});
