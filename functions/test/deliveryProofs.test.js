'use strict';
const { query: lifecycleQuery } = require('./lifecycleFake');

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const {
  buildConfirmPickupWithProof,
  buildPrepareOrderProof,
  hashPin,
  hashToken,
  sessionId,
} = require('../deliveryProofs');
const { buildDeliverOrderWithProof } = require('../orderActions');

const PEPPER = 'unit-test-only-delivery-proof-pepper';

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
      ...lifecycleQuery(store, path),
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
          get: async (ref) => ref.__path ? ({
            exists: store.has(ref.__path),
            data: () => store.get(ref.__path),
          }) : ref.get(),
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
      delete: () => ({ __delete: true }),
      serverTimestamp: () => timestamp(Date.now()),
      increment: (amount) => ({ __increment: amount }),
    },
  },
};

function makeProofSeed({ orderId = 'o1', type = 'pickup', status = 'active',
  token = 'valid-one-time-token', pin = '123456', expiresAt = Date.now() + 60_000,
  pinAttempts = 0, driverId = 'd1', assignmentVersion = 1 } = {}) {
  const id = 'proof-v1';
  const sessionPath = `delivery_proofs/${sessionId(orderId, type)}`;
  return {
    [`orders/${orderId}`]: {
      clientId: 'c1',
      driverId,
      status: type === 'pickup' ? 'accepted' : 'picked_up',
      deliveryProofMode: 'qr_v1',
      driverAssignmentVersion: assignmentVersion,
    },
    [sessionPath]: {
      orderId,
      type,
      currentProofId: id,
      driverId,
      assignmentVersion,
    },
    [`${sessionPath}/versions/${id}`]: {
      orderId,
      type,
      tokenHash: hashToken(token),
      pinHash: hashPin(pin, PEPPER, orderId, type),
      status,
      expiresAt: timestamp(expiresAt),
      driverId,
      assignmentVersion,
      pinAttempts,
    },
  };
}

async function withPepper(callback) {
  const enabled = process.env.DELIVERY_PROOFS_ENABLED;
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  const previous = process.env.DELIVERY_PROOF_PEPPER;
  process.env.DELIVERY_PROOF_PEPPER = PEPPER;
  try {
    return await callback();
  } finally {
    if (enabled === undefined) delete process.env.DELIVERY_PROOFS_ENABLED;
    else process.env.DELIVERY_PROOFS_ENABLED = enabled;
    if (previous === undefined) delete process.env.DELIVERY_PROOF_PEPPER;
    else process.env.DELIVERY_PROOF_PEPPER = previous;
  }
}

function makeLogAudit() {
  const calls = [];
  const logAudit = async (entry) => calls.push(entry);
  logAudit.calls = calls;
  return logAudit;
}

test('prepareOrderProof emits random secrets but stores only hashes', async () => {
  await withPepper(async () => {
    const { db, store } = makeFakeDb({
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', sellerId: 'partner1',
        sellerType: 'seller', status: 'accepted',
      },
    });
    const fn = buildPrepareOrderProof({
      db,
      admin: fakeAdmin,
      onCall,
      HttpsError,
      checkRateLimit: async () => {},
      logAudit: makeLogAudit(),
    });

    const result = await fn.run({
      auth: { uid: 'partner1' },
      data: { orderId: 'o1', type: 'pickup' },
    });

    assert.equal(result.success, true);
    assert.match(result.token, /^[A-Za-z0-9_-]{40,}$/);
    assert.match(result.pin, /^\d{6}$/);
    const savedProof = [...store.entries()].find(([path]) =>
      path.startsWith('delivery_proofs/') && path.includes('/versions/'))[1];
    assert.equal(savedProof.tokenHash, hashToken(result.token));
    assert.equal(savedProof.pinHash, hashPin(result.pin, PEPPER, 'o1', 'pickup'));
    assert.equal(Object.values(savedProof).includes(result.token), false);
    assert.equal(Object.values(savedProof).includes(result.pin), false);
    assert.equal(savedProof.status, 'active');
  });
});

test('prepareOrderProof refuses the assigned driver from issuing their own pickup secret', async () => {
  await withPepper(async () => {
    const { db } = makeFakeDb({
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', sellerId: 'partner1',
        sellerType: 'seller', status: 'accepted',
      },
    });
    const fn = buildPrepareOrderProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });
    await assert.rejects(
      fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1', type: 'pickup' } }),
      (error) => error.code === 'permission-denied',
    );
  });
});

test('prepareOrderProof lets the client issue a delivery proof after pickup was verified', async () => {
  await withPepper(async () => {
    const seed = {
      ...makeProofSeed({ type: 'pickup', status: 'used' }),
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', status: 'picked_up',
        deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1,
      },
    };
    const { db, store } = makeFakeDb(seed);
    const fn = buildPrepareOrderProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });

    const result = await fn.run({
      auth: { uid: 'c1' },
      data: { orderId: 'o1', type: 'delivery' },
    });

    assert.equal(result.success, true);
    assert.match(result.token, /^[A-Za-z0-9_-]{40,}$/);
    assert.match(result.pin, /^\d{6}$/);
    const proof = store.get(
      `delivery_proofs/${sessionId('o1', 'delivery')}/versions/${store.get(
        `delivery_proofs/${sessionId('o1', 'delivery')}`,
      ).currentProofId}`,
    );
    assert.equal(proof.status, 'active');
    assert.equal(proof.tokenHash, hashToken(result.token));
  });
});

test('delivery proof cannot be used for a different order', async () => {
  await withPepper(async () => {
    const token = 'valid-one-time-token';
    const seed = {
      ...makeProofSeed({ type: 'delivery', token }),
      'orders/o2': {
        clientId: 'c1', driverId: 'd1', status: 'picked_up',
        deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1,
      },
    };
    const { db } = makeFakeDb(seed);
    const fn = buildDeliverOrderWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
      calculateCommission: async () => 100,
      deliveryProofPepper: { name: 'deliveryProofPepper' },
    });

    await assert.rejects(
      fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o2', proofToken: token } }),
      (error) => error.code === 'failed-precondition',
    );
  });
});

test('delivery proof confirmation rejects a driver who is not assigned', async () => {
  await withPepper(async () => {
    const seed = {
      ...makeProofSeed({ type: 'delivery', driverId: 'd2' }),
    };
    const { db } = makeFakeDb(seed);
    const fn = buildDeliverOrderWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
      calculateCommission: async () => 100,
      deliveryProofPepper: { name: 'deliveryProofPepper' },
    });

    await assert.rejects(
      fn.run({
        auth: { uid: 'd1' },
        data: { orderId: 'o1', proofToken: 'valid-one-time-token' },
      }),
      (error) => error.code === 'permission-denied',
    );
  });
});

test('delivery proof confirmation rejects an order that is not picked up', async () => {
  await withPepper(async () => {
    const seed = {
      ...makeProofSeed({ type: 'delivery' }),
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', status: 'accepted',
        deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1,
      },
    };
    const { db } = makeFakeDb(seed);
    const fn = buildDeliverOrderWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
      calculateCommission: async () => 100,
      deliveryProofPepper: { name: 'deliveryProofPepper' },
    });

    await assert.rejects(
      fn.run({
        auth: { uid: 'd1' },
        data: { orderId: 'o1', proofToken: 'valid-one-time-token' },
      }),
      (error) => error.code === 'failed-precondition',
    );
  });
});

test('pickup proof accepts a valid QR once and moves the order atomically', async () => {
  await withPepper(async () => {
    const { db, store } = makeFakeDb(makeProofSeed());
    const fn = buildConfirmPickupWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });

    const result = await fn.run({
      auth: { uid: 'd1' },
      data: { orderId: 'o1', token: 'valid-one-time-token' },
    });

    assert.deepEqual(result, { success: true, status: 'picked_up' });
    assert.equal(store.get('orders/o1').status, 'picked_up');
    const proofPath = `delivery_proofs/${sessionId('o1', 'pickup')}/versions/proof-v1`;
    assert.equal(store.get(proofPath).status, 'used');
    assert.equal(store.get(proofPath).validatedBy, 'd1');
    assert.ok(store.get('orders/o1').pickupProofValidatedAt);
  });
});

test('expired pickup proof is marked expired and rejected', async () => {
  await withPepper(async () => {
    const seed = makeProofSeed({ expiresAt: Date.now() - 1 });
    const { db, store } = makeFakeDb(seed);
    const fn = buildConfirmPickupWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });

    await assert.rejects(
      fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1', token: 'valid-one-time-token' } }),
      (error) => error.code === 'failed-precondition',
    );
    assert.equal(
      store.get(`delivery_proofs/${sessionId('o1', 'pickup')}/versions/proof-v1`).status,
      'expired',
    );
    assert.equal(store.get('orders/o1').status, 'accepted');
  });
});

test('used pickup proof cannot be replayed', async () => {
  await withPepper(async () => {
    const { db } = makeFakeDb(makeProofSeed({ status: 'used' }));
    const fn = buildConfirmPickupWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });
    await assert.rejects(
      fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1', token: 'valid-one-time-token' } }),
      (error) => error.code === 'failed-precondition',
    );
  });
});

test('wrong pickup PIN increments attempts; a fifth failure locks further attempts', async () => {
  await withPepper(async () => {
    const { db, store } = makeFakeDb(makeProofSeed());
    const fn = buildConfirmPickupWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });
    const data = { orderId: 'o1', pin: '000000' };
    for (let attempt = 1; attempt <= 5; attempt += 1) {
      await assert.rejects(
        fn.run({ auth: { uid: 'd1' }, data }),
        (error) => error.code === 'failed-precondition',
      );
    }
    const proofPath = `delivery_proofs/${sessionId('o1', 'pickup')}/versions/proof-v1`;
    assert.equal(store.get(proofPath).pinAttempts, 5);
    assert.equal(store.get(proofPath).pinLocked, true);
    await assert.rejects(
      fn.run({ auth: { uid: 'd1' }, data }),
      (error) => error.code === 'resource-exhausted',
    );
    assert.equal(store.get(proofPath).pinAttempts, 5);
  });
});

test('simultaneous pickup scans serialize so only one consumes the proof', async () => {
  await withPepper(async () => {
    const { db, store } = makeFakeDb(makeProofSeed());
    const fn = buildConfirmPickupWithProof({
      db, admin: fakeAdmin, onCall, HttpsError,
      checkRateLimit: async () => {}, logAudit: makeLogAudit(),
    });
    const request = {
      auth: { uid: 'd1' },
      data: { orderId: 'o1', token: 'valid-one-time-token' },
    };

    const results = await Promise.allSettled([fn.run(request), fn.run(request)]);
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    assert.equal(results.filter((result) => result.status === 'rejected').length, 1);
    assert.equal(store.get('orders/o1').status, 'picked_up');
    assert.equal(
      store.get(`delivery_proofs/${sessionId('o1', 'pickup')}/versions/proof-v1`).status,
      'used',
    );
  });
});

test('concurrent delivery proof confirmations finalize and credit exactly once', async () => {
  await withPepper(async () => {
    const token = crypto.randomBytes(32).toString('base64url');
    const order = {
      clientId: 'c1',
      driverId: 'd1',
      sellerId: 'r1',
      sellerType: 'restaurant',
      status: 'picked_up',
      deliveryProofMode: 'qr_v1',
      driverAssignmentVersion: 1,
      paymentMethod: 'wallet',
      isPaid: true,
      budget: 1000,
    };
    const seed = {
      ...makeProofSeed({
        type: 'delivery',
        token,
        pin: '987654',
      }),
      'orders/o1': order,
      'livreurs/d1': { wallet: 300, isOnDelivery: true },
      'restaurants/r1': { wallet: 100 },
    };
    const { db, store } = makeFakeDb(seed);
    const fn = buildDeliverOrderWithProof({
      db,
      admin: fakeAdmin,
      onCall,
      HttpsError,
      checkRateLimit: async () => {},
      logAudit: makeLogAudit(),
      calculateCommission: async () => 100,
      deliveryProofPepper: { name: 'deliveryProofPepper' },
    });
    const request = {
      auth: { uid: 'd1' },
      data: { orderId: 'o1', proofToken: token },
    };

    const results = await Promise.allSettled([fn.run(request), fn.run(request)]);
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    assert.equal(results.filter((result) => result.status === 'rejected').length, 1);
    assert.deepEqual(results.find((result) => result.status === 'fulfilled').value, { success: true });
    assert.equal(store.get('orders/o1').status, 'delivered');
    assert.equal(store.get('restaurants/r1').wallet, 1100);
    assert.equal(store.get('livreurs/d1').wallet, 300);
    assert.equal(store.get('livreurs/d1').isOnDelivery, false);
    assert.equal(
      store.get(`delivery_proofs/${sessionId('o1', 'delivery')}/versions/proof-v1`).status,
      'used',
    );
    await assert.rejects(fn.run(request), (error) => error.code === 'failed-precondition');
    assert.equal(store.get('restaurants/r1').wallet, 1100);
  });
});

const { buildRecipientProofAccess } = require('../deliveryProofGuests');
function guestHarness() {
  const seed = makeProofSeed({ type: 'pickup', status: 'used' });
  seed['orders/o1'].status = 'picked_up';
  const { db, store } = makeFakeDb(seed);
  const api = buildRecipientProofAccess({ db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: async () => {} });
  return { api, store, db };
}
const guestRequest = (access, recovery = access.recovery, uid = 'guest1') => ({
  auth: { uid }, data: { grantId: access.grantId, recovery },
});
test('guest access requires owner; assigned driver cannot create or redeem', async () => withPepper(async () => {
  const { api } = guestHarness();
  await assert.rejects(api.create.run({auth:{uid:'d1'},data:{orderId:'o1'}}));
  await assert.rejects(api.create.run({auth:{uid:'stranger'},data:{orderId:'o1'}}));
  const access = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  await assert.rejects(api.redeem.run(guestRequest(access, access.recovery, 'd1')));
}));
test('guest redemption stores no secrets and is single use', async () => withPepper(async () => {
  const { api, store } = guestHarness();
  const access = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  const proof = await api.redeem.run(guestRequest(access));
  assert.equal(proof.type, 'delivery'); assert.equal(proof.orderId, 'o1');
  const serialized = JSON.stringify([...store]);
  for (const secret of [access.recovery, proof.token, proof.pin]) assert.equal(serialized.includes(JSON.stringify(secret)), false);
  await assert.rejects(api.redeem.run(guestRequest(access)));
}));
test('five wrong recovery codes lock guest access', async () => withPepper(async () => {
  const { api, store } = guestHarness();
  const access = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  for(let i=0;i<5;i++) await assert.rejects(api.redeem.run(guestRequest(access, 'wrong')));
  assert.equal(store.get('delivery_proofs/guest_'+access.grantId).attempts,5);
  await assert.rejects(api.redeem.run(guestRequest(access)));
}));
test('guest expiry, renewal and driver reassignment revoke access', async () => withPepper(async () => {
  const { api, store } = guestHarness();
  const a = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  const b = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  await assert.rejects(api.redeem.run(guestRequest(a)));
  store.get('delivery_proofs/guest_'+b.grantId).expiresAt = 0;
  await assert.rejects(api.redeem.run(guestRequest(b)));
  const c = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  store.get('orders/o1').driverAssignmentVersion++;
  await assert.rejects(api.redeem.run(guestRequest(c)));
  await assert.rejects(api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}}));
}));
test('guest cannot redeem without authentication or with a driver account', async () => withPepper(async () => {
  const { api, store } = guestHarness();
  const a = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  await assert.rejects(api.redeem.run({data:{grantId:a.grantId,recovery:a.recovery}}));
  store.set('livreurs/other-driver', {});
  await assert.rejects(api.redeem.run(guestRequest(a,a.recovery,'other-driver')));
}));
test('guest proof matches the existing delivery verifier contract', async () => withPepper(async () => {
  const { api, db } = guestHarness();
  const a = await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  const proof = await api.redeem.run(guestRequest(a));
  const { verifyProofInTransaction } = require('../deliveryProofs');
  const result = await db.runTransaction(tx => verifyProofInTransaction({tx,db,orderId:'o1',type:'delivery',driverId:'d1',assignmentVersion:1,token:proof.token,pepper:PEPPER,now:Date.now(),admin:fakeAdmin}));
  assert.equal(result.ok,true);
}));
test('rollout is disabled by default without mutating historical orders', async () => {
  const previous = process.env.DELIVERY_PROOFS_ENABLED;
  delete process.env.DELIVERY_PROOFS_ENABLED;
  try {
    const { api, store } = guestHarness(); const before=JSON.stringify([...store]);
    await assert.rejects(api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}}));
    assert.equal(JSON.stringify([...store]),before);
  } finally { if(previous !== undefined) process.env.DELIVERY_PROOFS_ENABLED=previous; }
});
test('boutique pickup requires active seller document and matching identity', async () => withPepper(async () => {
  const {db,store}=makeFakeDb({'orders/o1':{clientId:'c1',driverId:'d1',sellerId:'b1',sellerType:'boutique',status:'accepted'}});
  const fn=buildPrepareOrderProof({db,admin:fakeAdmin,onCall,HttpsError,checkRateLimit:async()=>{},logAudit:makeLogAudit()});
  const req={auth:{uid:'b1'},data:{orderId:'o1',type:'pickup'}};
  await assert.rejects(fn.run(req));
  store.set('sellers/b1',{type:'boutique',isActive:true});
  const proof=await fn.run(req); assert.equal(proof.success,true);
  store.get('sellers/b1').isSuspended=true;
  await assert.rejects(fn.run(req));
}));

test('pickup issuers match restaurant pharmacy bakery and private sender identities', async () => withPepper(async () => {
  for (const spec of [
    {sellerType:'restaurant',sellerId:'r1',uid:'owner1',path:'restaurant_owners/owner1',record:{restaurantId:'r1'}},
    {sellerType:'pharmacie',sellerId:'p1',uid:'pharmacist1',path:'pharmacies/p1',record:{currentUid:'pharmacist1'}},
    {sellerType:'boulangerie',sellerId:'baker1',uid:'baker1'},
    {uid:'c1'},
  ]) {
    const order={clientId:'c1',driverId:'d1',status:'accepted',...(spec.sellerId ? {sellerId:spec.sellerId,sellerType:spec.sellerType}:{})};
    const {db}=makeFakeDb({'orders/o1':order,...(spec.path?{[spec.path]:spec.record}:{})});
    const fn=buildPrepareOrderProof({db,admin:fakeAdmin,onCall,HttpsError,checkRateLimit:async()=>{},logAudit:makeLogAudit()});
    await assert.rejects(fn.run({auth:{uid:'outsider'},data:{orderId:'o1',type:'pickup'}}));
    const result=await fn.run({auth:{uid:spec.uid},data:{orderId:'o1',type:'pickup'}});
    assert.equal(result.success,true);
  }
}));
test('concurrent guest redemption returns only one proof', async () => withPepper(async () => {
  const {api}=guestHarness();
  const access=await api.create.run({auth:{uid:'c1'},data:{orderId:'o1'}});
  const results=await Promise.allSettled([api.redeem.run(guestRequest(access)),api.redeem.run(guestRequest(access))]);
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);
}));
test('renewal rejects the fourth proof generation', async () => withPepper(async () => {
  const {db}=makeFakeDb({'orders/o1':{clientId:'c1',driverId:'d1',status:'accepted'}});
  const fn=buildPrepareOrderProof({db,admin:fakeAdmin,onCall,HttpsError,checkRateLimit:async()=>{},logAudit:makeLogAudit()});
  const req={auth:{uid:'c1'},data:{orderId:'o1',type:'pickup'}};
  for(let i=0;i<3;i++) await fn.run(req);
  await assert.rejects(fn.run(req),e=>e.code==='resource-exhausted');
}));

test('accès invité émis avant un transfert refusé après le changement de livreur ; nouvel accès lié à la nouvelle affectation', async () => withPepper(async () => {
  const { api, store } = guestHarness();
  const old = await api.create.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  // Transfert après récupération : B reprend la course, version d’affectation + 1.
  store.set('orders/o1', { ...store.get('orders/o1'), driverId: 'd2', driverAssignmentVersion: 2 });
  await assert.rejects(api.redeem.run(guestRequest(old)));
  await assert.rejects(api.redeem.run(guestRequest(old, old.recovery, 'guest2')));
  // Un nouvel accès est émis pour le nouveau livreur et donne un nouveau code final.
  const fresh = await api.create.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.notEqual(fresh.grantId, old.grantId);
  const proof = await api.redeem.run(guestRequest(fresh));
  assert.equal(proof.type, 'delivery');
  const versions = [...store.entries()].filter(([k]) => k.includes('/versions/') && k.includes(sessionId('o1', 'delivery')));
  assert.ok(versions.some(([, v]) => v.driverId === 'd2' && v.assignmentVersion === 2));
  // L’ancien code (ancien accès) reste refusé même après émission du nouveau.
  await assert.rejects(api.redeem.run(guestRequest(old)));
}));
