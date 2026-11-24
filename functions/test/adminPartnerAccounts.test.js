'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildManageAdminPartnerAccount } = require('../adminPartnerAccounts');
const { HttpsError } = require('firebase-functions/v2/https');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const TEMP = 'TempPass9Xyz';
const { verifySecret } = require('../passwordHash');
function harness(adminData = { role: 'super', isActive: true }, options = {}) {
  const calls = [];
  const audits = [], events = [], limits = [];
  const store = new Map(Object.entries({
    ...(adminData ? { 'admins/admin-1': adminData } : {}),
    'boulangeries/b1': { name: 'B' },
    'sellers/s1': { name: 'S' },
    ...options.seed,
  }));
  const authUsers = new Map(Object.entries(options.authUsers || {}));
  let autoId = 0;
  let createdUsers = 0;
  const auth = {
    createUser: async (data) => {
      calls.push(['createUser', data]);
      if (options.authError) throw options.authError;
      if (authUsers.has(data.email)) {
        throw Object.assign(new Error('exists'), { code: 'auth/email-already-exists' });
      }
      createdUsers += 1;
      const uid = options.newUid || (createdUsers === 1 ? 'partner-1' : `partner-${createdUsers}`);
      authUsers.set(data.email, uid);
      return { uid };
    },
    getUserByEmail: async (email) => {
      calls.push(['getUserByEmail', email]);
      if (!authUsers.has(email)) throw new Error('not found');
      return { uid: authUsers.get(email) };
    },
    setCustomUserClaims: async (uid, claims) => {
      calls.push(['setCustomUserClaims', uid, claims]);
      if (options.claimsError) throw options.claimsError;
    },
    updateUser: async (uid, data) => { calls.push(['updateUser', uid, data]); if (options.authError) throw options.authError; },
    deleteUser: async (uid) => {
      calls.push(['deleteUser', uid]);
      if (options.rollbackError) throw options.rollbackError;
      for (const [email, id] of [...authUsers]) if (id === uid) authUsers.delete(email);
    },
  };
  const key = (name, id) => `${name}/${id}`;
  const docRef = (name, id) => ({
    path: key(name, id), id,
    get: async () => {
      if (options.readError && name !== 'admins') throw options.readError;
      return { exists: store.has(key(name, id)), data: () => store.get(key(name, id)) };
    },
    create: async (data) => {
      calls.push(['create', name, id, data]);
      if (options.writeError) throw options.writeError;
      if (store.has(key(name, id))) throw new Error('already exists');
      store.set(key(name, id), data);
    },
    set: async (data, opts) => {
      calls.push(['set', name, id, data]);
      if (options.markerError && name === 'partner_provisioning') throw options.markerError;
      store.set(key(name, id), opts?.merge ? { ...(store.get(key(name, id)) || {}), ...data } : data);
    },
    delete: async () => { calls.push(['delete', name, id]); store.delete(key(name, id)); },
  });
  const db = {
    collection(name) {
      return {
        doc(id) { return docRef(name, id === undefined ? `auto-${++autoId}` : id); },
        where(field, _op, value) {
          return {
            limit() {
              return {
                get: async () => {
                  const docs = [...store.entries()]
                    .filter(([k, v]) => k.startsWith(`${name}/`) && v?.[field] === value)
                    .map(([k, v]) => ({ id: k.split('/')[1], data: () => v }));
                  return { empty: docs.length === 0, docs };
                },
              };
            },
          };
        },
      };
    },
    batch() {
      const ops = [];
      return {
        create(ref, data) { ops.push(['create', ref, data]); },
        set(ref, data, opts) { ops.push(['set', ref, data, opts]); },
        commit: async () => {
          calls.push(['commit', ops.map((op) => op[1].path)]);
          if (options.writeError) throw options.writeError;
          for (const [type, ref] of ops) {
            if (type === 'create' && store.has(ref.path)) throw new Error('already exists');
          }
          for (const [type, ref, data, opts] of ops) {
            store.set(ref.path, type === 'set' && opts?.merge
              ? { ...(store.get(ref.path) || {}), ...data } : data);
          }
        },
      };
    },
  };
  let clock = 1_000_000;
  const deps = {
    now: () => clock,
    generatePassword: () => TEMP,
    db, auth, fieldValue: { serverTimestamp: () => 'timestamp' },
    checkRateLimit: async (...args) => { limits.push(args); if (options.rateError) throw options.rateError; },
    logAudit: async (data) => { audits.push({ ...data, createdAt: 'timestamp' }); },
    logSecurityEvent: async (...args) => { events.push(args); },
  };
  return {
    calls, audits, events, limits, store, deps, run: buildManageAdminPartnerAccount(deps),
    advance: (ms) => { clock += ms; },
  };
}

const request = (data) => ({
  auth: { uid: 'admin-1', token: { firebase: { sign_in_provider: 'password' } } },
  data,
});

test('création vendeur utilise Admin SDK sans changer l’identité appelante', async () => {
  const h = harness();
  const result = await h.run(request({
    action: 'create', kind: 'seller', email: 'seller@test.ci', profile: sampleProfiles.seller,
  }));
  assert.equal(result.uid, 'partner-1');
  assert.equal(h.calls[0][0], 'createUser');
  assert.equal(h.calls.some((call) => call[0] === 'signIn' || call[0] === 'signOut'), false);
});

test('création boulangerie utilise Admin SDK sans changer l’identité appelante', async () => {
  const h = harness();
  await h.run(request({
    action: 'create', kind: 'boulangerie', email: 'b@test.ci', profile: sampleProfiles.boulangerie,
  }));
  assert.equal(h.calls[0][0], 'createUser');
  assert.equal(h.calls.some((call) => call[0] === 'signIn' || call[0] === 'signOut'), false);
});

test('mot de passe boulangerie utilise updateUser sans changer la session', async () => {
  const h = harness();
  await h.run(request({ action: 'updatePassword', kind: 'boulangerie', uid: 'b1' }));
  assert.deepEqual(h.calls[0], ['updateUser', 'b1', { password: TEMP }]);
});

test('un sous-admin sans permission requise est refusé', async () => {
  const h = harness({ role: 'sub', isActive: true, permissions: [] });
  await assert.rejects(
    h.run(request({ action: 'create', kind: 'seller', email: 's@test.ci' })),
    (error) => error.code === 'permission-denied',
  );
});

const permissions = { seller: 'demandes_vendeurs', boulangerie: 'boulangeries' };
const collections = { seller: 'sellers', boulangerie: 'boulangeries' };
const sampleProfiles = {
  seller: { name: 'Commerce', phone: '0700000000', type: 'boutique', lat: 6.7, lng: -3.5 },
  boulangerie: { name: 'Pain', address: 'Rue test', phone: '0700000000', openTime: '06:00', closeTime: '20:00', lat: 6.7, lng: -3.5 },
};
const serverDefaults = {
  seller: { isActive: true },
  boulangerie: { isOpen: false, isActive: true },
};
const sub = kind => ({ role: 'sub', isActive: true, permissions: [permissions[kind]] });
const reset = (kind, uid = kind === 'seller' ? 's1' : 'b1') => request({
  action: 'updatePassword', kind, uid,
});
const create = (kind, profile = {}) => request({
  action: 'create', kind, profile, email: 'fixture@example.invalid',
});
const updates = h => h.calls.filter(c => c[0] === 'updateUser');
const creations = h => h.calls.filter(c => c[0] === 'createUser');

for (const kind of Object.keys(permissions)) {
  test(`${kind}: authorized sub resets exactly the validated UID once`, async () => {
    const h = harness(sub(kind));
    const req = reset(kind);
    assert.deepEqual(await h.run(req), { uid: req.data.uid, tempPassword: TEMP });
    assert.deepEqual(updates(h), [['updateUser', req.data.uid, { password: TEMP }]]);
    assert.deepEqual(h.limits, [['admin-1', 'admin_partner_password', 10, 3600]]);
    assert.equal(h.audits[0].status, 'success');
    assert.equal(h.audits[0].targetId, req.data.uid);
    assert.equal(h.audits[0].createdAt, 'timestamp');
  });

  for (const [label, uid, seed] of [
    ['deleted partner', 'deleted', { [`${collections[kind]}/deleted`]: {isDeleted:true} }],
    ['missing partner', 'missing', {}],
    ['other role only', kind === 'seller' ? 'b1' : 's1', {}],
    ['Auth exists without profile', 'auth-only', {}],
    ['super admin', 'super-target', { 'admins/super-target': { role: 'super', isActive: true } }],
    ['sub admin', 'sub-target', { 'admins/sub-target': { role: 'sub', isActive: true } }],
    ['admin also partner', 'both', { 'admins/both': { role: 'super', isActive: true }, [`${collections[kind]}/both`]: {} }],
    ['inactive admin also partner', 'inactive', { 'admins/inactive': { role: 'sub', isActive: false }, [`${collections[kind]}/inactive`]: {} }],
  ]) {
    test(`${kind}: ${label} denied with ZERO Auth mutations`, async () => {
      const h = harness(sub(kind), { seed });
      await assert.rejects(h.run(reset(kind, uid)), e => e.code === 'permission-denied');
      assert.equal(updates(h).length, 0);
      assert.equal(h.audits.length, 1);
      assert.equal(h.audits[0].status, 'error');
      assert.equal(h.audits[0].targetId, uid);
      assert.equal(h.events.length, Object.keys(seed).some(k => k.startsWith('admins/')) ? 1 : 0);
      if (h.events.length) assert.equal(h.events[0][1], 'admin_partner_password_admin_target');
    });
  }

  test(`${kind}: allowlisted profile and zero wallet, server timestamp`, async () => {
    const h = harness(sub(kind));
    const req = create(kind, sampleProfiles[kind]);
    req.data.uid = 'arbitrary-existing-uid';
    req.data.role = 'super'; // root fields cannot choose Auth uid or role either
    const result = await h.run(req);
    assert.deepEqual(result, { uid: 'partner-1', tempPassword: TEMP });
    assert.deepEqual(h.store.get(`${collections[kind]}/partner-1`), {
      ...sampleProfiles[kind], ...serverDefaults[kind], wallet: 0, createdAt: 'timestamp',
    });
    assert.deepEqual(creations(h), [['createUser', { email: req.data.email, password: TEMP }]]);
    assert.equal(h.store.has('admins/partner-1'), false);
    assert.deepEqual(h.limits, [['admin-1', 'admin_partner_create', 10, 3600]]);
    assert.equal(h.audits[0].status, 'success');
    assert.equal(h.audits[0].targetId, 'partner-1');
  });

  test(`${kind}: an incomplete profile is refused BEFORE createUser (no half-built account)`, async () => {
    const h = harness(sub(kind));
    await assert.rejects(h.run(create(kind)), e => e.code === 'invalid-argument');
    assert.equal(creations(h).length, 0);
    assert.equal(h.store.has(`${collections[kind]}/partner-1`), false);
  });

  test(`${kind}: create finalizes the whole profile in ONE atomic batch with the provisioning journal`, async () => {
    const h = harness(sub(kind));
    await h.run(create(kind, sampleProfiles[kind]));
    const commits = h.calls.filter(c => c[0] === 'commit');
    assert.equal(commits.length, 1);
    assert.deepEqual(commits[0][1], [`${collections[kind]}/partner-1`, 'partner_provisioning/partner-1']);
    assert.equal(h.store.get('partner_provisioning/partner-1').status, 'completed');
    assert.equal(h.calls.some(c => c[0] === 'updateUser'), false);
  });

  for (const field of ['wallet', 'walletBalance', 'balance', 'role', 'adminRole', 'permissions',
    'isAdmin', 'isSuperAdmin', 'uid', 'authUid', 'ownerUid', 'createdBy', 'approvedBy',
    'commission', 'isActive', 'isOpen', 'password', 'passwordHash', 'accessCode', 'PIN',
    'pinHash', 'OTP', 'tokens', 'createdAt', 'unexpected', '__proto__', 'constructor']) {
    test(`${kind}: rejects profile field ${field} BEFORE createUser`, async () => {
      const h = harness(sub(kind));
      const profile = JSON.parse(JSON.stringify({ name: 'Allowed' }));
      Object.defineProperty(profile, field, { value: 'SensitiveFixture9!', enumerable: true });
      await assert.rejects(h.run(create(kind, profile)), e => e.code === 'invalid-argument');
      assert.equal(creations(h).length, 0);
      assert.equal(h.store.has(`${collections[kind]}/partner-1`), false);
      assert.equal(JSON.stringify(h.audits).includes('SensitiveFixture9!'), false);
    });
  }

  for (const action of ['create', 'updatePassword']) {
    test(`${kind}/${action}: rate limit denies before Auth mutation`, async () => {
      const h = harness(sub(kind), { rateError: new HttpsError('resource-exhausted', 'Limit') });
      await assert.rejects(h.run(action === 'create' ? create(kind) : reset(kind)), e => e.code === 'resource-exhausted');
      assert.equal(h.calls.length, 0);
      assert.equal(h.audits[0].metadata.stage, 'rate_limit');
      if (action === 'updatePassword') {
        assert.equal(h.audits[0].targetId, kind === 'seller' ? 's1' : 'b1');
      }
    });
  }
}

for (const kind of ['invalid', 'admins', '__proto__', 'constructor', 'toString']) {
  for (const action of ['create', 'updatePassword']) {
    test(`${action}: kind ${kind} is outside closed allowlist`, async () => {
      const h = harness();
      await assert.rejects(h.run(action === 'create' ? create(kind) : reset(kind)), e => e.code === 'invalid-argument');
      assert.equal(h.calls.length, 0);
    });
  }
}

for (const [label, adminData, reqAuth] of [
  ['normal user', null, request({}).auth],
  ['inactive admin', { role: 'super', isActive: false }, request({}).auth],
  ['sub without permission', { role: 'sub', isActive: true, permissions: [] }, request({}).auth],
  ['anonymous', { role: 'super', isActive: true }, { uid: 'admin-1', token: { firebase: { sign_in_provider: 'anonymous' } } }],
  ['unauthenticated', null, null],
]) {
  for (const action of ['create', 'updatePassword']) {
    test(`${action}: rejects ${label}`, async () => {
      const h = harness(adminData);
      const req = action === 'create' ? create('seller') : reset('seller');
      req.auth = reqAuth;
      await assert.rejects(h.run(req), e => ['permission-denied', 'unauthenticated'].includes(e.code));
      assert.equal(h.calls.length, 0);
      assert.equal(h.audits[0].status, 'error');
    });
  }
}

for (const profile of [null, [], 'wrong', { name: { wallet: 100 } }, { lat: Infinity },
  { lng: 181 }, { type: 'admin' }, { name: '' }, { openTime: '12:00' }]) {
  test(`seller rejects invalid profile ${JSON.stringify(profile)}`, async () => {
    const h = harness();
    await assert.rejects(h.run(create('seller', profile)), e => e.code === 'invalid-argument');
    assert.equal(creations(h).length, 0);
  });
}

test('UID path injection is refused without Auth call', async () => {
  const h = harness();
  await assert.rejects(h.run(reset('seller', 'a/b/c')), e => e.code === 'invalid-argument');
  assert.equal(updates(h).length, 0);
});

test('profile read failure fails closed, no updateUser', async () => {
  const h = harness(undefined, { readError: new Error('backend unavailable') });
  await assert.rejects(h.run(reset('seller')), e => e.code === 'internal');
  assert.equal(updates(h).length, 0);
});

test('Firestore create failure deletes exactly the newly created Auth UID', async () => {
  const h = harness(undefined, { writeError: new Error('write refused') });
  await assert.rejects(h.run(create('seller', sampleProfiles.seller)), e => e.code === 'internal');
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
  assert.equal(h.audits[0].status, 'error');
});

test('rollback failure is visible in audit and security event, never successful', async () => {
  const h = harness(undefined, { writeError: new Error('write refused'), rollbackError: new Error('delete refused') });
  await assert.rejects(h.run(create('boulangerie', sampleProfiles.boulangerie)), e => e.code === 'internal');
  assert.equal(h.audits[0].metadata.stage, 'creation_rollback_failed');
  assert.equal(h.events[0][1], 'admin_partner_creation_rollback_failed');
});

test('create refuses to overwrite an existing business document', async () => {
  const h = harness(undefined, { seed: { 'sellers/partner-1': { name: 'Original', wallet: 12 } } });
  await assert.rejects(h.run(create('seller', sampleProfiles.seller)), e => e.code === 'internal');
  assert.deepEqual(h.store.get('sellers/partner-1'), { name: 'Original', wallet: 12 });
});

test('Auth failures and raw request secrets never enter audit or response', async () => {
  const marker = 'SensitiveFixture9!';
  for (const action of ['create', 'updatePassword']) {
    const h = harness(undefined, { authError: new Error(marker) });
    const req = action === 'create' ? create('seller', sampleProfiles.seller) : reset('seller');
    Object.assign(req.data, { hash: marker, PIN: marker, OTP: marker, token: marker });
    await assert.rejects(h.run(req), e => e.code === 'internal' && !e.message.includes(marker));
    assert.equal(JSON.stringify([h.audits, h.events]).includes(marker), false);
    assert.deepEqual(Object.keys(h.audits[0].metadata).sort(), ['kind', 'stage']);
  }
});

test('un mot de passe fourni par l\'administrateur est refusé AVANT Auth (le serveur le génère)', async () => {
  for (const field of ['password', 'newPassword']) {
    for (const req of [create('seller', sampleProfiles.seller), reset('seller')]) {
      const h = harness();
      req.data[field] = 'AdminChosen9X';
      await assert.rejects(h.run(req), e => e.code === 'invalid-argument' && !e.message.includes('AdminChosen9X'));
      assert.equal(h.calls.length, 0);
      assert.equal(JSON.stringify(h.audits).includes('AdminChosen9X'), false);
    }
  }
});

// Execute the actual export expression, not a hand-maintained dependency list.
const indexSource = fs.readFileSync(path.join(__dirname, '../index.js'), 'utf8');
const exportStart = indexSource.indexOf('exports.manageAdminPartnerAccount = onCall(');
const exportEnd = indexSource.indexOf('\n);', exportStart) + 4;
const exportSource = indexSource.slice(exportStart, exportEnd);
function constructIndexHandler(h, source = exportSource) {
  assert.ok(exportStart >= 0 && exportEnd > exportStart);
  const context = {
    ...h.deps, exports: {}, buildManageAdminPartnerAccount,
    admin: { auth: () => h.deps.auth, firestore: { FieldValue: h.deps.fieldValue } },
    onCall: (_options, handler) => handler,
  };
  vm.runInNewContext(source, context);
  return context.exports.manageAdminPartnerAccount;
}

test('actual index.js export constructs and runs both operations with all dependencies', async () => {
  const h = harness();
  const handler = constructIndexHandler(h);
  await handler(create('seller', sampleProfiles.seller));
  await handler(reset('seller', 'partner-1'));
  assert.equal(creations(h).length, 1);
  assert.equal(updates(h).length, 1);
  assert.equal(h.audits.length, 2);
});

for (const dependency of ['checkRateLimit', 'logAudit', 'logSecurityEvent']) {
  test(`integration test detects missing ${dependency} from index.js`, () => {
    const altered = exportSource.replace(new RegExp(`\\s+${dependency},`), '');
    assert.notEqual(altered, exportSource);
    assert.throws(() => constructIndexHandler(harness(), altered), TypeError);
  });
}

test('actual rate-limit helper shares reset quota across kinds, creation is separate', async () => {
  const h = harness();
  const counters = new Map();
  const start = indexSource.indexOf('async function checkRateLimit(');
  const end = indexSource.indexOf('async function logAudit(', start);
  const context = {
    HttpsError, Date,
    admin: { firestore: { FieldValue: h.deps.fieldValue } },
    db: {
      collection: name => ({ doc: id => `${name}/${id}` }),
      runTransaction: async run => run({
        get: async ref => ({ exists: counters.has(ref), data: () => counters.get(ref) }),
        set: (ref, value) => counters.set(ref, value),
      }),
    },
  };
  vm.runInNewContext(indexSource.slice(start, end), context);
  const run = buildManageAdminPartnerAccount({ ...h.deps, checkRateLimit: context.checkRateLimit });
  for (let i = 0; i < 10; i++) await run(reset(i % 2 ? 'seller' : 'boulangerie'));
  await assert.rejects(run(reset('seller')), e => e.code === 'resource-exhausted');
  assert.equal(updates(h).length, 10);
  await run(create('seller', sampleProfiles.seller));
  assert.equal(creations(h).length, 1);
});

test('actual logAudit helper writes only safe metadata with server timestamp', async () => {
  const h = harness();
  const rows = [];
  const start = indexSource.indexOf('async function logAudit(');
  const end = indexSource.indexOf('async function logSecurityEvent(', start);
  const context = { admin: { firestore: { FieldValue: h.deps.fieldValue } },
    db: { collection: name => ({ add: async data => rows.push({ name, data }) }) },
    console: { error: () => assert.fail('unexpected audit error') },
  };
  vm.runInNewContext(indexSource.slice(start, end), context);
  const run = buildManageAdminPartnerAccount({ ...h.deps, logAudit: context.logAudit });
  await run(reset('seller'));
  await assert.rejects(run(reset('seller', 'admin-1')));
  assert.equal(rows.length, 2);
  for (const row of rows) {
    assert.equal(row.name, 'audit_logs');
    assert.equal(row.data.createdAt, 'timestamp');
    assert.equal(JSON.stringify(row).includes(TEMP), false);
    assert.deepEqual(Object.keys(row.data.metadata).sort(), ['kind', 'stage']);
  }
});

test('successful create and reset never log raw profile or extra sensitive inputs', async () => {
  const marker = 'PrivateFixture9!';
  const h = harness();
  for (const req of [create('seller', { ...sampleProfiles.seller, name: marker }), reset('seller')]) {
    Object.assign(req.data, { hash: marker, PIN: marker, OTP: marker, token: marker });
    await h.run(req);
  }
  assert.equal(h.audits.length, 2);
  assert.equal(JSON.stringify(h.audits).includes(marker), false);
  assert.equal(h.events.length, 0);
});

// ═════════════════════════════════════════════════════════════════════════════
// Étape A (2026-10) : restaurants, finalisation serveur, reprise idempotente.
// ═════════════════════════════════════════════════════════════════════════════
const restaurantProfile = {
  name: 'Chez Awa', ownerName: 'Awa K', phone: '0700000001', address: 'Rue 1',
  category: 'Ivoirien', lat: 6.7, lng: -3.5, minDelivery: 500,
};
const restaurantSub = { role: 'sub', isActive: true, permissions: ['restaurants'] };
const createRestaurant = (overrides = {}, profile = restaurantProfile) => request({
  action: 'create', kind: 'restaurant', profile,
  email: '0700000001@az-restaurant.ci', ...overrides,
});
const assignOwner = (overrides = {}) => request({
  action: 'assignOwner', kind: 'restaurant', restaurantId: 'rest-1',
  ownerName: 'Awa K', phone: '0700000001',
  email: '0700000001@az-restaurant.ci', ...overrides,
});
const noAuthMutation = h => assert.equal(
  h.calls.some(c => ['createUser', 'updateUser', 'deleteUser'].includes(c[0])), false);
const restaurantDocs = h => [...h.store.keys()].filter(k => k.startsWith('restaurants/'));

test('restaurant: création complète = compte Auth + restaurants + restaurant_owners + verrou, un seul lot', async () => {
  const h = harness(restaurantSub);
  const result = await h.run(createRestaurant());
  assert.equal(result.uid, 'partner-1');
  const restaurantId = result.restaurantId;
  assert.ok(restaurantId && restaurantId !== 'partner-1', "identifiant d'établissement distinct de l'UID");
  assert.deepEqual(h.store.get(`restaurants/${restaurantId}`), {
    ...restaurantProfile, isOpen: false, isActive: true, createdAt: 'timestamp', id: restaurantId,
  });
  assert.deepEqual(h.store.get('restaurant_owners/partner-1'), {
    uid: 'partner-1', phone: '0700000001', ownerName: 'Awa K', createdAt: 'timestamp', restaurantId,
    mustChangePassword: true,
  });
  assert.deepEqual(h.store.get(`restaurant_owner_locks/${restaurantId}`), { ownerUid: 'partner-1', createdAt: 'timestamp' });
  assert.equal(h.store.get('partner_provisioning/partner-1').status, 'completed');
  assert.equal(h.calls.filter(c => c[0] === 'commit').length, 1);
  assert.deepEqual(creations(h), [['createUser', { email: '0700000001@az-restaurant.ci', password: TEMP }]]);
  assert.deepEqual(h.limits, [['admin-1', 'admin_partner_create', 10, 3600]]);
  assert.equal(h.audits[0].status, 'success');
  assert.equal(JSON.stringify(h.audits).includes(TEMP), false);
  assert.equal(result.tempPassword, TEMP);
});

test("restaurant: l'ouverture optionnelle est un booléen validé", async () => {
  const h = harness(restaurantSub);
  const result = await h.run(createRestaurant({ isOpen: true }));
  assert.equal(h.store.get(`restaurants/${result.restaurantId}`).isOpen, true);
  await assert.rejects(harness(restaurantSub).run(createRestaurant({ isOpen: 'oui' })), e => e.code === 'invalid-argument');
});

test('restaurant: sous-admin sans la permission « restaurants » refusé, zéro mutation', async () => {
  for (const data of [{ role: 'sub', isActive: true, permissions: ['demandes_vendeurs'] },
    { role: 'sub', isActive: true, permissions: [] }]) {
    const h = harness(data);
    await assert.rejects(h.run(createRestaurant()), e => e.code === 'permission-denied');
    noAuthMutation(h);
    assert.equal(restaurantDocs(h).length, 0);
  }
});

test('restaurant: identifiant hors domaine restaurateur refusé AVANT Auth', async () => {
  const h = harness(restaurantSub);
  await assert.rejects(h.run(createRestaurant({ email: 'x@az-seller.ci' })), e => e.code === 'invalid-argument');
  await assert.rejects(h.run(createRestaurant({ email: '@az-restaurant.ci' })), e => e.code === 'invalid-argument');
  noAuthMutation(h);
});

test('restaurant: profil incomplet ou champ de sécurité refusé AVANT Auth', async () => {
  for (const profile of [{ name: 'X' }, { ...restaurantProfile, isActive: true },
    { ...restaurantProfile, wallet: 5 }, { ...restaurantProfile, restaurantId: 'x' },
    { ...restaurantProfile, minDelivery: -1 }, { ...restaurantProfile, minDelivery: 1.5 }]) {
    const h = harness(restaurantSub);
    await assert.rejects(h.run(createRestaurant({}, profile)), e => e.code === 'invalid-argument');
    noAuthMutation(h);
  }
});

test("restaurant: updatePassword n'est pas exposé à cette étape", async () => {
  const h = harness();
  await assert.rejects(h.run(request({ action: 'updatePassword', kind: 'restaurant', uid: 'r1', password: 'DummyTest9!' })),
    e => e.code === 'invalid-argument');
  noAuthMutation(h);
});

test("restaurant: échec du lot Firestore après création Auth → suppression du seul compte neuf, rien d'écrit", async () => {
  const h = harness(restaurantSub, { writeError: new Error('refused') });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
  assert.equal(h.store.has('partner_provisioning/partner-1'), false);
  assert.equal(restaurantDocs(h).length, 0);
  assert.equal(h.store.has('restaurant_owners/partner-1'), false);
  assert.equal(h.audits[0].status, 'error');
});

test("restaurant: échec d'écriture du journal après création Auth → compensation, aucun orphelin", async () => {
  const h = harness(restaurantSub, { markerError: new Error('refused') });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
  assert.equal(h.calls.some(c => c[0] === 'commit'), false);
  assert.equal(restaurantDocs(h).length, 0);
});

test('restaurant: compensation impossible → journal conservé, événement de sécurité, jamais un succès', async () => {
  const h = harness(restaurantSub, { writeError: new Error('refused'), rollbackError: new Error('refused') });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.equal(h.audits[0].metadata.stage, 'creation_rollback_failed');
  assert.equal(h.events[0][1], 'admin_partner_creation_rollback_failed');
  assert.equal(h.store.get('partner_provisioning/partner-1').status, 'auth_created');
});

test("restaurant: nouvelle tentative après compensation échouée = reprise du même compte et du même établissement, sans doublon", async () => {
  const options = { writeError: new Error('refused'), rollbackError: new Error('refused') };
  const h = harness(restaurantSub, options);
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  const plannedId = h.store.get('partner_provisioning/partner-1').restaurantId;
  options.writeError = null; options.rollbackError = null;
  h.advance(10 * 60 * 1000);
  const result = await h.run(createRestaurant());
  assert.deepEqual(result, { uid: 'partner-1', restaurantId: plannedId, tempPassword: TEMP });
  assert.deepEqual(h.calls.filter(c => c[0] === 'updateUser'), [['updateUser', 'partner-1', { password: TEMP }]]);
  assert.equal(h.calls.filter(c => c[0] === 'deleteUser').length, 1, 'aucune suppression lors de la reprise');
  assert.equal(restaurantDocs(h).length, 1);
  assert.equal(h.store.get('restaurant_owners/partner-1').restaurantId, plannedId);
  assert.equal(h.store.get('partner_provisioning/partner-1').status, 'completed');
});

test("restaurant: un compte Auth existant SANS journal n'est jamais repris, modifié ni supprimé", async () => {
  const h = harness(restaurantSub, { authUsers: { '0700000001@az-restaurant.ci': 'someone-else' } });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'already-exists');
  assert.equal(h.calls.some(c => ['updateUser', 'deleteUser'].includes(c[0])), false);
  assert.equal(h.calls.some(c => c[0] === 'commit'), false);
  assert.equal(restaurantDocs(h).length, 0);
});

test("restaurant: un compte déjà terminé ou d'une autre opération/type n'est pas repris", async () => {
  for (const marker of [
    { kind: 'restaurant', operation: 'create', status: 'completed', restaurantId: 'r9' },
    { kind: 'seller', operation: 'create', status: 'auth_created' },
    { kind: 'restaurant', operation: 'assignOwner', status: 'auth_created', restaurantId: 'r9' },
  ]) {
    const h = harness(restaurantSub, {
      authUsers: { '0700000001@az-restaurant.ci': 'u9' },
      seed: { 'partner_provisioning/u9': marker },
    });
    await assert.rejects(h.run(createRestaurant()), e => e.code === 'already-exists');
    assert.equal(h.calls.some(c => ['updateUser', 'deleteUser', 'commit'].includes(c[0])), false);
  }
});

test('restaurant: reprise refusée si un document métier existe déjà (aucun écrasement)', async () => {
  const h = harness(restaurantSub, {
    authUsers: { '0700000001@az-restaurant.ci': 'u9' },
    seed: {
      'partner_provisioning/u9': { kind: 'restaurant', operation: 'create', status: 'auth_created', restaurantId: 'r9', createdAtMs: 0 },
      'restaurants/r9': { name: 'Original', wallet: 12 },
    },
  });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'already-exists');
  assert.deepEqual(h.store.get('restaurants/r9'), { name: 'Original', wallet: 12 });
  assert.equal(h.calls.some(c => ['updateUser', 'deleteUser', 'commit'].includes(c[0])), false);
});

test("restaurant: la création n'associe jamais un établissement existant sur la seule correspondance du téléphone", async () => {
  const existing = { name: 'Historique', phone: '0700000001', isActive: true };
  const h = harness(restaurantSub, { seed: { 'restaurants/rest-old': existing } });
  const result = await h.run(createRestaurant());
  assert.notEqual(result.restaurantId, 'rest-old');
  assert.deepEqual(h.store.get('restaurants/rest-old'), existing);
  assert.equal([...h.store.entries()].some(([k, v]) => k.startsWith('restaurant_owners/') && v.restaurantId === 'rest-old'), false);
});

// ── attribution d'un responsable à un établissement existant ───────────────
const seededRestaurant = { 'restaurants/rest-1': { name: 'Historique', phone: '0700000001', isActive: true } };

test("assignOwner: super-admin attribue un responsable SANS créer ni modifier l'établissement", async () => {
  const h = harness(undefined, { seed: seededRestaurant });
  const result = await h.run(assignOwner());
  assert.deepEqual(result, { uid: 'partner-1', restaurantId: 'rest-1', tempPassword: TEMP });
  assert.deepEqual(h.store.get('restaurants/rest-1'), seededRestaurant['restaurants/rest-1']);
  assert.deepEqual(restaurantDocs(h), ['restaurants/rest-1']);
  assert.deepEqual(h.store.get('restaurant_owners/partner-1'), {
    uid: 'partner-1', phone: '0700000001', ownerName: 'Awa K', createdAt: 'timestamp', restaurantId: 'rest-1',
    mustChangePassword: true,
  });
  assert.equal(h.store.get('restaurant_owner_locks/rest-1').ownerUid, 'partner-1');
  assert.deepEqual(h.limits, [['admin-1', 'admin_partner_assign', 10, 3600]]);
  assert.equal(h.audits[0].action, 'admin_partner_assign_owner');
  assert.equal(h.audits[0].status, 'success');
});

test("assignOwner: réservé au super-admin (un sous-admin « restaurants » est refusé)", async () => {
  const h = harness(restaurantSub, { seed: seededRestaurant });
  await assert.rejects(h.run(assignOwner()), e => e.code === 'permission-denied');
  noAuthMutation(h);
});

test('assignOwner: établissement absent ou supprimé → refus avant Auth', async () => {
  for (const seed of [{}, { 'restaurants/rest-1': { name: 'X', isDeleted: true } }]) {
    const h = harness(undefined, { seed });
    await assert.rejects(h.run(assignOwner()), e => e.code === 'failed-precondition');
    noAuthMutation(h);
  }
});

test('assignOwner: établissement déjà lié (restaurant_owners historique ou verrou) → refus avant Auth', async () => {
  for (const seed of [
    { ...seededRestaurant, 'restaurant_owners/old-owner': { restaurantId: 'rest-1' } },
    { ...seededRestaurant, 'restaurant_owner_locks/rest-1': { ownerUid: 'old-owner' } },
  ]) {
    const h = harness(undefined, { seed });
    await assert.rejects(h.run(assignOwner()), e => e.code === 'already-exists');
    noAuthMutation(h);
    assert.equal(h.store.has('restaurant_owners/partner-1'), false);
  }
});

test("assignOwner: identifiant d'établissement invalide ou identifiant de connexion hors domaine → refus avant Auth", async () => {
  for (const o of [{ restaurantId: 'a/b' }, { restaurantId: '' }, { email: 'x@example.invalid' }, { ownerName: '' }]) {
    const h = harness(undefined, { seed: seededRestaurant });
    await assert.rejects(h.run(assignOwner(o)), e => e.code === 'invalid-argument');
    noAuthMutation(h);
  }
});

test("assignOwner: échec du lot → compte neuf supprimé, établissement intact, aucun responsable", async () => {
  const h = harness(undefined, { seed: seededRestaurant, writeError: new Error('refused') });
  await assert.rejects(h.run(assignOwner()), e => e.code === 'internal');
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
  assert.deepEqual(h.store.get('restaurants/rest-1'), seededRestaurant['restaurants/rest-1']);
  assert.equal(h.store.has('restaurant_owners/partner-1'), false);
});

test('assignOwner: reprise après compensation échouée, sans doublon de responsable', async () => {
  const options = { seed: seededRestaurant, writeError: new Error('refused'), rollbackError: new Error('refused') };
  const h = harness(undefined, options);
  await assert.rejects(h.run(assignOwner()), e => e.code === 'internal');
  options.writeError = null; options.rollbackError = null;
  h.advance(10 * 60 * 1000);
  assert.deepEqual(await h.run(assignOwner()), { uid: 'partner-1', restaurantId: 'rest-1', tempPassword: TEMP });
  assert.equal([...h.store.keys()].filter(k => k.startsWith('restaurant_owners/')).length, 1);
  assert.deepEqual(restaurantDocs(h), ['restaurants/rest-1']);
});

test('assignOwner: seul « restaurant » expose cette action', async () => {
  for (const kind of ['seller', 'boulangerie']) {
    const h = harness();
    await assert.rejects(h.run(assignOwner({ kind })), e => e.code === 'invalid-argument');
    noAuthMutation(h);
  }
});

// ── vendeur / boulangerie : reprise et absence d'orphelins ──────────────────
for (const kind of ['seller', 'boulangerie']) {
  test(`${kind}: échec du profil → aucun compte Auth ni document orphelin, puis nouvelle tentative réussie`, async () => {
    const options = { writeError: new Error('refused') };
    const h = harness(sub(kind), options);
    await assert.rejects(h.run(create(kind, sampleProfiles[kind])), e => e.code === 'internal');
    assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
    assert.equal(h.store.has(`${collections[kind]}/partner-1`), false);
    assert.equal(h.store.has('partner_provisioning/partner-1'), false);
    options.writeError = null;
    assert.deepEqual(await h.run(create(kind, sampleProfiles[kind])), { uid: 'partner-2', tempPassword: TEMP });
    assert.equal(h.store.get(`${collections[kind]}/partner-2`).wallet, 0);
  });

  test(`${kind}: reprise après compensation échouée = même UID, profil complet, un seul document`, async () => {
    const options = { writeError: new Error('refused'), rollbackError: new Error('refused') };
    const h = harness(sub(kind), options);
    await assert.rejects(h.run(create(kind, sampleProfiles[kind])), e => e.code === 'internal');
    options.writeError = null; options.rollbackError = null;
    h.advance(10 * 60 * 1000);
    assert.deepEqual(await h.run(create(kind, sampleProfiles[kind])), { uid: 'partner-1', tempPassword: TEMP });
    assert.deepEqual(h.store.get(`${collections[kind]}/partner-1`), {
      ...sampleProfiles[kind], ...serverDefaults[kind], wallet: 0, createdAt: 'timestamp',
    });
    assert.equal([...h.store.keys()].filter(k => k.startsWith(`${collections[kind]}/partner`)).length, 1);
    assert.equal(h.calls.filter(c => c[0] === 'deleteUser').length, 1);
  });

  test(`${kind}: compte déjà existant (sans journal, ex. auto-inscription en attente) → refus, mot de passe jamais changé`, async () => {
    const h = harness(sub(kind), { authUsers: { 'fixture@example.invalid': 'self-registered' } });
    await assert.rejects(h.run(create(kind, sampleProfiles[kind])), e => e.code === 'already-exists');
    assert.equal(h.calls.some(c => ['updateUser', 'deleteUser', 'commit'].includes(c[0])), false);
  });

  test(`${kind}: partenaire déjà créé (journal terminé) → refus sans écrasement`, async () => {
    const existing = { name: 'Original', wallet: 40, isActive: true };
    const h = harness(sub(kind), {
      authUsers: { 'fixture@example.invalid': 'u9' },
      seed: {
        'partner_provisioning/u9': { kind, operation: 'create', status: 'completed' },
        [`${collections[kind]}/u9`]: existing,
      },
    });
    await assert.rejects(h.run(create(kind, sampleProfiles[kind])), e => e.code === 'already-exists');
    assert.deepEqual(h.store.get(`${collections[kind]}/u9`), existing);
  });
}

test('seller: isActive optionnel posé par le serveur (booléen validé), défaut true', async () => {
  const inactive = create('seller', sampleProfiles.seller);
  inactive.data.isActive = false;
  const h = harness();
  await h.run(inactive);
  assert.equal(h.store.get('sellers/partner-1').isActive, false);
  const bad = create('seller', sampleProfiles.seller);
  bad.data.isActive = 'non';
  await assert.rejects(harness().run(bad), e => e.code === 'invalid-argument');
});

test('le journal de provisionnement ne contient ni mot de passe ni identifiant de connexion', async () => {
  const h = harness(restaurantSub);
  await h.run(createRestaurant());
  const marker = JSON.stringify(h.store.get('partner_provisioning/partner-1'));
  assert.equal(marker.includes(TEMP), false);
  assert.equal(marker.includes('az-restaurant.ci'), false);
  assert.equal(marker.includes('0700000001'), false);
});

// ── Concurrence, échecs intermédiaires, parité de schéma ────────────────────
test('restaurant: reprise REFUSÉE tant que le journal est récent (création possiblement en cours)', async () => {
  const options = { writeError: new Error('refused'), rollbackError: new Error('refused') };
  const h = harness(restaurantSub, options);
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  options.writeError = null; options.rollbackError = null;
  h.advance(60 * 1000); // 1 minute seulement
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'already-exists');
  assert.equal(h.calls.some(c => c[0] === 'updateUser'), false);
  assert.equal(restaurantDocs(h).length, 0);
});

test('restaurant: deux créations CONCURRENTES du même identifiant → une seule aboutit, aucun doublon, aucune suppression de compte', async () => {
  const h = harness(restaurantSub);
  const results = await Promise.allSettled([h.run(createRestaurant()), h.run(createRestaurant())]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  const rejected = results.find(r => r.status === 'rejected');
  assert.equal(rejected.reason.code, 'already-exists');
  assert.equal(restaurantDocs(h).length, 1);
  assert.equal([...h.store.keys()].filter(k => k.startsWith('restaurant_owners/')).length, 1);
  assert.equal(h.calls.some(c => c[0] === 'deleteUser'), false);
  assert.equal(h.store.get('partner_provisioning/partner-1').status, 'completed');
});

test('restaurant: deux créations concurrentes d\'identifiants différents → deux restaurants distincts', async () => {
  const h = harness(restaurantSub);
  const other = createRestaurant({ email: '0700000002@az-restaurant.ci' }, { ...restaurantProfile, phone: '0700000002' });
  const results = await Promise.all([h.run(createRestaurant()), h.run(other)]);
  assert.notEqual(results[0].restaurantId, results[1].restaurantId);
  assert.notEqual(results[0].uid, results[1].uid);
  assert.equal(restaurantDocs(h).length, 2);
});

test('assignOwner: deux attributions concurrentes pour le même établissement → un seul responsable', async () => {
  const h = harness(undefined, { seed: seededRestaurant });
  const results = await Promise.allSettled([
    h.run(assignOwner()),
    h.run(assignOwner({ email: '0700000009@az-restaurant.ci', phone: '0700000009' })),
  ]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal([...h.store.keys()].filter(k => k.startsWith('restaurant_owners/')).length, 1);
  assert.equal([...h.store.keys()].filter(k => k.startsWith('restaurant_owner_locks/')).length, 1);
  // le compte perdant (créé avant l'échec du lot) est supprimé : un seul compte Auth survit
  const deleted = h.calls.filter(c => c[0] === 'deleteUser');
  assert.equal(deleted.length <= 1, true);
});

test('restaurant: association restaurant_owners déjà présente pour ce compte → lot refusé, compte neuf supprimé, aucun restaurant créé', async () => {
  const h = harness(restaurantSub, { seed: { 'restaurant_owners/partner-1': { restaurantId: 'someone-elses' } } });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
  assert.equal(restaurantDocs(h).length, 0, 'lot atomique : aucun restaurant sans responsable');
  assert.deepEqual(h.store.get('restaurant_owners/partner-1'), { restaurantId: 'someone-elses' });
});

test('restaurant: identifiant d\'établissement déjà pris (collision) → refus, établissement existant intact', async () => {
  const h = harness(restaurantSub);
  // Le journal prévoit un identifiant déjà occupé : le lot échoue en entier.
  h.store.set('restaurants/auto-1', { name: 'Existant', wallet: 5 });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.deepEqual(h.store.get('restaurants/auto-1'), { name: 'Existant', wallet: 5 });
  assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
});

test('compatibilité tableau de bord : mêmes champs que approvePartnerOnce + lien propriétaire → établissement', async () => {
  const h = harness(restaurantSub);
  const { uid, restaurantId } = await h.run(createRestaurant());
  const restaurant = h.store.get(`restaurants/${restaurantId}`);
  const owner = h.store.get(`restaurant_owners/${uid}`);
  // Champs écrits par admin_restaurant_requests_page.dart (approvePartnerOnce)
  for (const key of ['name', 'ownerName', 'phone', 'address', 'category', 'lat', 'lng', 'isOpen', 'isActive', 'createdAt', 'id']) {
    assert.ok(key in restaurant, `restaurants.${key} manquant`);
  }
  for (const key of ['uid', 'phone', 'ownerName', 'createdAt', 'restaurantId']) {
    assert.ok(key in owner, `restaurant_owners.${key} manquant`);
  }
  // Chemin de restaurant_owner_login : owner.restaurantId → restaurants/{id} existe
  assert.equal(h.store.has(`restaurants/${owner.restaurantId}`), true);
  assert.equal(owner.uid, uid);
  assert.equal(restaurant.id, restaurantId);
  assert.equal(typeof restaurant.name, 'string');
  assert.equal(typeof restaurant.isOpen, 'boolean');
  // Pas de champs financiers ni de sécurité inattendus
  for (const forbidden of ['wallet', 'password', 'role', 'permissions']) {
    assert.equal(forbidden in restaurant, false);
    assert.equal(forbidden in owner, false);
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// Étape B : mot de passe temporaire généré par le serveur + première connexion
// ═════════════════════════════════════════════════════════════════════════════
const policyOk = value => value.length >= 8 && /[A-Z]/.test(value) && /[0-9]/.test(value);

test('le mot de passe temporaire par défaut respecte la politique (8+, majuscule, chiffre) et vient de crypto.randomInt', () => {
  const { generateTemporaryPassword, meetsPasswordPolicy } = require('../partnerTemporaryPassword');
  const seen = new Set();
  for (let i = 0; i < 300; i++) {
    const value = generateTemporaryPassword();
    assert.equal(value.length, 12);
    assert.equal(policyOk(value), true);
    assert.equal(/[a-z]/.test(value), true);
    assert.equal(meetsPasswordPolicy(value), true);
    assert.equal(/[0OIl1]/.test(value), false, 'alphabet sans caractères ambigus');
    seen.add(value);
  }
  assert.equal(seen.size, 300, 'aucune répétition sur 300 tirages');
  const source = require('node:fs').readFileSync(require.resolve('../partnerTemporaryPassword'), 'utf8');
  assert.equal(source.includes('Math.random'), false);
  assert.equal(source.includes('crypto.randomInt') || source.includes('randomInt'), true);
});

test('la politique refuse trop court, sans majuscule ou sans chiffre', () => {
  const { meetsPasswordPolicy } = require('../partnerTemporaryPassword');
  for (const bad of ['Abc1234', 'abcdefgh1', 'ABCDEFGHI', 'abcdefghi', '', null]) {
    assert.equal(meetsPasswordPolicy(bad), false);
  }
  assert.equal(meetsPasswordPolicy('Abcdefg1'), true);
});

for (const kind of ['seller', 'boulangerie']) {
  test(`${kind}: création = mot de passe temporaire serveur, claim de changement obligatoire, journal avec hachage seul`, async () => {
    const h = harness(sub(kind));
    const result = await h.run(create(kind, sampleProfiles[kind]));
    assert.equal(result.tempPassword, TEMP);
    assert.deepEqual(h.calls.filter(c => c[0] === 'setCustomUserClaims'),
      [['setCustomUserClaims', 'partner-1', { partnerMustChangePassword: true }]]);
    const journal = h.store.get('partner_provisioning/partner-1');
    assert.equal(journal.mustChangePassword, true);
    assert.equal(verifySecret(TEMP, journal.tempPasswordHash), true);
    assert.equal(JSON.stringify([...h.store.values()]).includes(TEMP), false, 'jamais en clair dans Firestore');
    assert.equal(JSON.stringify([h.audits, h.events]).includes(TEMP), false, 'jamais dans les journaux');
  });

  test(`${kind}: échec de la pose du claim → compensation, aucun compte à moitié activé`, async () => {
    const h = harness(sub(kind), { claimsError: new Error('claims refused') });
    await assert.rejects(h.run(create(kind, sampleProfiles[kind])), e => e.code === 'internal');
    assert.deepEqual(h.calls.filter(c => c[0] === 'deleteUser'), [['deleteUser', 'partner-1']]);
    assert.equal(h.store.has(`${collections[kind]}/partner-1`), false);
  });
}

test('restaurant: la création pose aussi le claim et le journal de première connexion', async () => {
  const h = harness(restaurantSub);
  const { uid } = await h.run(createRestaurant());
  assert.equal(h.store.get(`partner_provisioning/${uid}`).mustChangePassword, true);
  assert.equal(h.calls.some(c => c[0] === 'setCustomUserClaims' && c[2].partnerMustChangePassword === true), true);
});

test('réinitialisation admin : nouveau mot de passe TEMPORAIRE serveur, changement de nouveau obligatoire', async () => {
  const h = harness(sub('seller'));
  const result = await h.run(reset('seller'));
  assert.equal(result.tempPassword, TEMP);
  assert.equal(h.calls.some(c => c[0] === 'setCustomUserClaims' && c[1] === 's1'), true);
  const journal = h.store.get('partner_provisioning/s1');
  assert.equal(journal.mustChangePassword, true);
  assert.equal(journal.resetBy, 'admin-1');
  assert.equal(JSON.stringify([...h.store.values()]).includes(TEMP), false);
});

test('reprise : le nouveau mot de passe temporaire remplace le précédent (claim reposé, hachage mis à jour)', async () => {
  const options = { writeError: new Error('refused'), rollbackError: new Error('refused') };
  const h = harness(restaurantSub, options);
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  options.writeError = null; options.rollbackError = null;
  h.advance(10 * 60 * 1000);
  await h.run(createRestaurant());
  assert.equal(h.calls.filter(c => c[0] === 'setCustomUserClaims').length, 2);
  assert.equal(verifySecret(TEMP, h.store.get('partner_provisioning/partner-1').tempPasswordHash), true);
});

// ── completePartnerFirstPasswordChange ──────────────────────────────────────
const { buildCompletePartnerFirstPasswordChange } = require('../partnerFirstLogin');

function firstLoginHarness(seed = {}, options = {}) {
  const deleteSentinel = Symbol('delete');
  const store = new Map(Object.entries({
    'sellers/s-new': { name: 'Boutique', isActive: true },
    'partner_provisioning/s-new': {
      kind: 'seller', mustChangePassword: true, tempPasswordHash: require('../passwordHash').hashSecret(TEMP),
    },
    ...seed,
  }));
  const calls = [], audits = [], limits = [];
  const clock = 2_000_000_000_000;
  const key = (n, i) => `${n}/${i}`;
  const merge = (path, data) => {
    const next = { ...(store.get(path) || {}), ...data };
    for (const [k, v] of Object.entries(next)) if (v === deleteSentinel) delete next[k];
    store.set(path, next);
  };
  const db = {
    collection: (name) => ({
      doc: (id) => ({
        get: async () => ({ exists: store.has(key(name, id)), data: () => store.get(key(name, id)) }),
        set: async (data) => {
          calls.push(['journal', data]);
          if (options.journalError && data.mustChangePassword === false) throw options.journalError;
          merge(key(name, id), data);
        },
        path: key(name, id),
      }),
    }),
    batch: () => {
      const ops = [];
      return {
        set: (ref, data) => ops.push(['set', ref.path, data]),
        update: (ref, data) => ops.push(['update', ref.path, data]),
        commit: async () => {
          calls.push(['batch', ops.map(op => op[1])]);
          if (options.batchError) throw options.batchError;
          // Atomique : tout est validé avant la moindre écriture.
          for (const [type, path] of ops) {
            if (type === 'update' && !store.has(path)) throw new Error('NOT_FOUND');
          }
          for (const [, path, data] of ops) merge(path, data);
        },
      };
    },
    runTransaction: async (fn) => {
      calls.push(['lock']);
      const writes = [];
      const result = await fn({
        get: async (ref) => ({ exists: store.has(ref.path), data: () => store.get(ref.path) }),
        set: (ref, data) => writes.push([ref.path, data]),
      });
      for (const [path, data] of writes) merge(path, data);
      return result;
    },
  };
  const auth = {
    updateUser: async (uid, data) => {
      calls.push(['updateUser', uid, data]);
      if (options.slowAuth) await options.slowAuth();
      if (options.authError) throw options.authError;
    },
    revokeRefreshTokens: async (uid) => { calls.push(['revoke', uid]); if (options.revokeError) throw options.revokeError; },
    setCustomUserClaims: async (uid, claims) => { calls.push(['claims', uid, claims]); if (options.claimsError) throw options.claimsError; },
  };
  const run = buildCompletePartnerFirstPasswordChange({
    db, auth, fieldValue: { serverTimestamp: () => 'timestamp', delete: () => deleteSentinel },
    checkRateLimit: async (...args) => { limits.push(args); if (options.rateError) throw options.rateError; },
    logAudit: async (data) => { audits.push(data); },
    now: () => clock,
  });
  const req = (data, overrides = {}) => ({
    auth: {
      uid: 's-new',
      token: { firebase: { sign_in_provider: 'password' }, auth_time: clock / 1000 - 30, ...(overrides.token || {}) },
      ...Object.fromEntries(Object.entries(overrides).filter(([k]) => k !== 'token')),
    },
    data,
  });
  return { store, calls, audits, limits, run, req, clock };
}
const journalOf = h => h.store.get('partner_provisioning/s-new');
const mutations = h => h.calls.filter(c => ['updateUser', 'revoke', 'claims'].includes(c[0]));

test('première connexion : changement réussi — verrou, SERVEUR change le mot de passe, drapeau levé, sessions révoquées, claim retiré', async () => {
  const h = firstLoginHarness();
  assert.deepEqual(await h.run(h.req({ newPassword: 'MonNouveau9' })), { success: true });
  assert.deepEqual(h.calls.map(c => c[0]), ['lock', 'updateUser', 'journal', 'revoke', 'claims']);
  assert.deepEqual(h.calls.find(c => c[0] === 'updateUser'), ['updateUser', 's-new', { password: 'MonNouveau9' }]);
  assert.deepEqual(h.calls.find(c => c[0] === 'claims'), ['claims', 's-new', null]);
  const journal = journalOf(h);
  assert.equal(journal.mustChangePassword, false);
  assert.equal(journal.passwordChangedAt, 'timestamp');
  assert.equal('tempPasswordHash' in journal, false, 'le hachage du temporaire est supprimé');
  assert.equal('changeLockUntilMs' in journal, false, 'verrou libéré');
  assert.equal(JSON.stringify([h.audits, [...h.store.values()]]).includes('MonNouveau9'), false);
  assert.equal(h.audits[0].status, 'success');
  assert.deepEqual(h.limits, [['s-new', 'partner_first_password', 5, 3600]]);
});

test('le drapeau n\'est JAMAIS levé si la mise à jour Auth échoue (réseau/serveur) ; le verrou est libéré pour réessayer', async () => {
  const h = firstLoginHarness({}, { authError: new Error('network down MonNouveau9') });
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'internal' && !e.message.includes('MonNouveau9'));
  assert.equal(journalOf(h).mustChangePassword, true);
  assert.equal('changeLockUntilMs' in journalOf(h), false);
  assert.equal(h.calls.some(c => c[0] === 'revoke' || c[0] === 'claims'), false);
  assert.equal(JSON.stringify(h.audits).includes('MonNouveau9'), false);
  // nouvelle tentative possible
  const retry = firstLoginHarness({ 'partner_provisioning/s-new': { ...journalOf(h) } });
  assert.deepEqual(await retry.run(retry.req({ newPassword: 'MonNouveau9' })), { success: true });
});

test('nouveau mot de passe trop faible ou invalide → refus avant toute mutation', async () => {
  for (const bad of ['court1A', 'minuscule123', 'SansChiffreAbc', '', null, 12345678, 'A1'.repeat(80)]) {
    const h = firstLoginHarness();
    await assert.rejects(h.run(h.req({ newPassword: bad })), e => e.code === 'invalid-argument');
    assert.equal(h.calls.length, 0);
  }
});

test('un mot de passe identique au temporaire est refusé', async () => {
  const h = firstLoginHarness();
  await assert.rejects(h.run(h.req({ newPassword: TEMP })), e => e.code === 'invalid-argument');
  assert.equal(h.calls.length, 0);
  assert.equal(journalOf(h).mustChangePassword, true);
});

test('session ancienne (pas de ré-authentification récente) → refus', async () => {
  const h = firstLoginHarness();
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' }, { token: { auth_time: 1 } })), e => e.code === 'unauthenticated');
  const missing = h.req({ newPassword: 'MonNouveau9' });
  delete missing.auth.token.auth_time;
  await assert.rejects(h.run(missing), e => e.code === 'unauthenticated');
  assert.equal(h.calls.length, 0);
});

test('anonyme ou non authentifié → refus (changement ET statut)', async () => {
  const h = firstLoginHarness();
  await assert.rejects(h.run({ auth: null, data: { newPassword: 'MonNouveau9' } }), e => e.code === 'unauthenticated');
  await assert.rejects(h.run({ auth: null, data: { statusOnly: true } }), e => e.code === 'unauthenticated');
  const anon = h.req({ newPassword: 'MonNouveau9' }, { token: { firebase: { sign_in_provider: 'anonymous' } } });
  await assert.rejects(h.run(anon), e => e.code === 'unauthenticated');
  assert.equal(h.calls.length, 0);
});

test('compte historique ou déjà activé : aucun changement par cette voie, mot de passe intact', async () => {
  for (const mode of ['activated', 'absent']) {
    const h = firstLoginHarness(mode === 'activated'
      ? { 'partner_provisioning/s-new': { kind: 'seller', mustChangePassword: false } } : {});
    if (mode === 'absent') h.store.delete('partner_provisioning/s-new');
    await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'failed-precondition');
    assert.equal(mutations(h).length, 0);
  }
});

test('un journal sans profil partenaire, un compte admin ou un journal falsifié sont refusés', async () => {
  const noProfile = firstLoginHarness();
  noProfile.store.delete('sellers/s-new');
  await assert.rejects(noProfile.run(noProfile.req({ newPassword: 'MonNouveau9' })), e => e.code === 'permission-denied');
  const admin = firstLoginHarness({ 'admins/s-new': { role: 'sub', isActive: true } });
  await assert.rejects(admin.run(admin.req({ newPassword: 'MonNouveau9' })), e => e.code === 'permission-denied');
  const forged = firstLoginHarness({ 'partner_provisioning/s-new': { kind: '__proto__', mustChangePassword: true } });
  await assert.rejects(forged.run(forged.req({ newPassword: 'MonNouveau9' })), e => e.code === 'failed-precondition');
  for (const h of [noProfile, admin, forged]) assert.equal(mutations(h).length, 0);
});

test('tentatives répétées : limitation de débit avant toute lecture ou mutation', async () => {
  const { HttpsError: Err } = require('firebase-functions/v2/https');
  const h = firstLoginHarness({}, { rateError: new Err('resource-exhausted', 'Limit') });
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'resource-exhausted');
  assert.equal(h.calls.length, 0);
});

test('chaque type (vendeur, boulangerie, restaurant) est vérifié sur SON profil', async () => {
  for (const [kind, collection] of [['seller', 'sellers'], ['boulangerie', 'boulangeries'], ['restaurant', 'restaurant_owners']]) {
    const h = firstLoginHarness({
      'partner_provisioning/s-new': { kind, mustChangePassword: true, tempPasswordHash: require('../passwordHash').hashSecret(TEMP) },
    });
    h.store.delete('sellers/s-new');
    h.store.set(`${collection}/s-new`, { name: 'X' });
    assert.deepEqual(await h.run(h.req({ newPassword: 'MonNouveau9' })), { success: true });
  }
});

// ── doubles changements et états incohérents ───────────────────────────────
test('deux changements SIMULTANÉS : un seul s\'exécute, l\'autre est refusé, un seul changement de mot de passe', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const h = firstLoginHarness({}, { slowAuth: () => gate });
  const first = h.run(h.req({ newPassword: 'PremierNouveau9' }));
  await new Promise(r => setImmediate(r));
  const second = h.run(h.req({ newPassword: 'SecondNouveau9' }));
  await assert.rejects(second, e => e.code === 'aborted');
  release();
  assert.deepEqual(await first, { success: true });
  assert.equal(h.calls.filter(c => c[0] === 'updateUser').length, 1);
  assert.deepEqual(h.calls.find(c => c[0] === 'updateUser')[2], { password: 'PremierNouveau9' });
  assert.equal(journalOf(h).mustChangePassword, false);
});

test('changement répété APRÈS activation : refusé, mot de passe inchangé', async () => {
  const h = firstLoginHarness();
  await h.run(h.req({ newPassword: 'MonNouveau9' }));
  const before = h.calls.filter(c => c[0] === 'updateUser').length;
  await assert.rejects(h.run(h.req({ newPassword: 'EncoreAutre9' })), e => e.code === 'failed-precondition');
  assert.equal(h.calls.filter(c => c[0] === 'updateUser').length, before);
});

test('verrou expiré (instance interrompue) : un nouveau changement est possible ; verrou actif : refusé', async () => {
  const active = firstLoginHarness({ 'partner_provisioning/s-new': {
    kind: 'seller', mustChangePassword: true, tempPasswordHash: require('../passwordHash').hashSecret(TEMP),
    changeLockUntilMs: 2_000_000_000_000 + 30_000,
  } });
  await assert.rejects(active.run(active.req({ newPassword: 'MonNouveau9' })), e => e.code === 'aborted');
  assert.equal(mutations(active).length, 0);
  const expired = firstLoginHarness({ 'partner_provisioning/s-new': {
    kind: 'seller', mustChangePassword: true, tempPasswordHash: require('../passwordHash').hashSecret(TEMP),
    changeLockUntilMs: 2_000_000_000_000 - 1,
  } });
  assert.deepEqual(await expired.run(expired.req({ newPassword: 'MonNouveau9' })), { success: true });
});

test('retrait du claim ou révocation en échec : le changement est QUAND MÊME acquis (drapeau levé), succès dégradé journalisé', async () => {
  const h = firstLoginHarness({}, { claimsError: new Error('claims down'), revokeError: new Error('revoke down') });
  assert.deepEqual(await h.run(h.req({ newPassword: 'MonNouveau9' })), { success: true });
  assert.equal(journalOf(h).mustChangePassword, false);
  assert.equal(h.audits[0].metadata.stage, 'completed_degraded');
});

test('statut : obligatoire tant que le drapeau serveur est levé par personne', async () => {
  const h = firstLoginHarness();
  assert.deepEqual(await h.run(h.req({ statusOnly: true })), { required: true });
  assert.equal(mutations(h).length, 0);
  assert.deepEqual(h.limits, [['s-new', 'partner_first_status', 30, 3600]]);
});

test('statut : compte activé dont le jeton porte une revendication PÉRIMÉE → le serveur la retire', async () => {
  const h = firstLoginHarness({ 'partner_provisioning/s-new': { kind: 'seller', mustChangePassword: false } });
  const stale = h.req({ statusOnly: true }, { token: { partnerMustChangePassword: true } });
  assert.deepEqual(await h.run(stale), { required: false });
  assert.deepEqual(h.calls.filter(c => c[0] === 'claims'), [['claims', 's-new', null]]);
});

test('statut : compte historique (sans journal) → non obligatoire, aucune mutation', async () => {
  const h = firstLoginHarness();
  h.store.delete('partner_provisioning/s-new');
  assert.deepEqual(await h.run(h.req({ statusOnly: true })), { required: false });
  assert.equal(mutations(h).length, 0);
});

test('statut : un client ne peut pas se faire « activer » en changeant sa revendication locale', async () => {
  const h = firstLoginHarness();
  const forged = h.req({ statusOnly: true }, { token: { partnerMustChangePassword: false } });
  assert.deepEqual(await h.run(forged), { required: true });
});

test('le journal de première connexion est inaccessible aux clients : aucune règle d’accès (match) ne le déclare', () => {
  const rules = require('node:fs').readFileSync(require('node:path').join(__dirname, '../../firestore.rules'), 'utf8');
  // les règles le LISENT via get()/exists() (garde d'activation) mais n'accordent aucun accès client
  assert.equal(/match\s+\/partner_provisioning/.test(rules), false);
  assert.equal(/match \/\{document=\*\*\}/.test(rules), false, 'aucune règle générique ne l\'expose');
});

// ── B5 : projection restaurant_owners.mustChangePassword ───────────────────
const hashOfTemp = () => require('../passwordHash').hashSecret(TEMP);
const restaurantFirstLogin = (options = {}, seed = {}) => {
  const h = firstLoginHarness({
    'partner_provisioning/s-new': {
      kind: 'restaurant', mustChangePassword: true, tempPasswordHash: hashOfTemp(),
    },
    'restaurant_owners/s-new': { uid: 's-new', restaurantId: 'r1', mustChangePassword: true },
    ...seed,
  }, options);
  h.store.delete('sellers/s-new');
  return h;
};

test('B5 création restaurateur : projection true, dans le même lot que la clôture du journal', async () => {
  const h = harness(restaurantSub);
  const { uid } = await h.run(createRestaurant());
  assert.equal(h.store.get(`restaurant_owners/${uid}`).mustChangePassword, true);
  assert.equal(h.store.get(`partner_provisioning/${uid}`).mustChangePassword, true);
  const commit = h.calls.find(c => c[0] === 'commit');
  assert.ok(commit[1].includes(`restaurant_owners/${uid}`));
  assert.ok(commit[1].includes(`partner_provisioning/${uid}`), 'journal et projection : un seul lot');
});

test('B5 assignOwner : projection true aussi', async () => {
  const h = harness({ role: 'super', isActive: true }, { seed: seededRestaurant });
  const { uid } = await h.run(assignOwner());
  assert.equal(h.store.get(`restaurant_owners/${uid}`).mustChangePassword, true);
});

test('B5 vendeur et boulangerie : aucun restaurant_owners créé ni modifié', async () => {
  for (const kind of ['seller', 'boulangerie']) {
    const h = harness();
    await h.run(request({ action: 'create', kind, email: `${kind}@test.ci`, profile: sampleProfiles[kind] }));
    assert.equal([...h.store.keys()].some(k => k.startsWith('restaurant_owners/')), false);
    await h.run(request({ action: 'updatePassword', kind, uid: kind === 'seller' ? 's1' : 'b1' }));
    assert.equal([...h.store.keys()].some(k => k.startsWith('restaurant_owners/')), false);
  }
});

test("B5 échec du lot de création : ni projection ni profil, compte neuf supprimé", async () => {
  const h = harness(restaurantSub, { writeError: new Error('boom') });
  await assert.rejects(h.run(createRestaurant()), e => e.code === 'internal');
  assert.equal([...h.store.keys()].some(k => k.startsWith('restaurant_owners/')), false);
  assert.ok(h.calls.some(c => c[0] === 'deleteUser'));
});

test("B5 réinitialisation admin d'un restaurateur : action non exposée, aucune écriture restaurant_owners", async () => {
  const h = harness(restaurantSub, { seed: { 'restaurant_owners/r1': { restaurantId: 'x', mustChangePassword: false } } });
  await assert.rejects(h.run(request({ action: 'updatePassword', kind: 'restaurant', uid: 'r1' })), e => e.code === 'invalid-argument');
  assert.equal(h.store.get('restaurant_owners/r1').mustChangePassword, false);
  noAuthMutation(h);
});

test('B5 première connexion restaurateur : journal ET projection passent à false dans UN lot atomique', async () => {
  const h = restaurantFirstLogin();
  assert.deepEqual(await h.run(h.req({ newPassword: 'MonNouveau9' })), { success: true });
  const batch = h.calls.find(c => c[0] === 'batch');
  assert.deepEqual(batch[1], ['partner_provisioning/s-new', 'restaurant_owners/s-new']);
  assert.equal(h.store.get('partner_provisioning/s-new').mustChangePassword, false);
  assert.equal(h.store.get('restaurant_owners/s-new').mustChangePassword, false);
  assert.equal(h.store.get('restaurant_owners/s-new').restaurantId, 'r1', 'autres champs préservés');
  assert.deepEqual(h.calls.map(c => c[0]), ['lock', 'updateUser', 'batch', 'revoke', 'claims']);
});

test("B5 échec du lot : journal ET projection restent true (jamais l'un sans l'autre), verrou libéré", async () => {
  const h = restaurantFirstLogin({ batchError: new Error('firestore down') });
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'internal');
  assert.equal(h.store.get('partner_provisioning/s-new').mustChangePassword, true);
  assert.equal(h.store.get('restaurant_owners/s-new').mustChangePassword, true);
  assert.equal('changeLockUntilMs' in h.store.get('partner_provisioning/s-new'), false);
  assert.equal(h.calls.some(c => c[0] === 'revoke' || c[0] === 'claims'), false);
});

test("B5 restaurateur supprimé : changement refusé, projection intacte", async () => {
  const h = restaurantFirstLogin({}, { 'restaurant_owners/s-new': { restaurantId: 'r1', isDeleted: true, mustChangePassword: true } });
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'permission-denied');
  assert.equal(h.store.get('restaurant_owners/s-new').mustChangePassword, true);
  assert.equal(mutations(h).length, 0);
});

test('B5 restaurateur historique sans journal : aucune modification (ni journal ni projection)', async () => {
  const h = firstLoginHarness({ 'restaurant_owners/s-new': { restaurantId: 'r1' } });
  h.store.delete('partner_provisioning/s-new');
  await assert.rejects(h.run(h.req({ newPassword: 'MonNouveau9' })), e => e.code === 'failed-precondition');
  assert.equal('mustChangePassword' in h.store.get('restaurant_owners/s-new'), false);
  assert.equal(h.calls.length, 0);
});

test("B5 le rôle vient du journal, jamais du domaine e-mail : e-mail hors @az-restaurant.ci", async () => {
  const h = restaurantFirstLogin();
  const req = h.req({ newPassword: 'MonNouveau9' }, { token: { email: 'proprio@gmail.com' } });
  assert.deepEqual(await h.run(req), { success: true });
  assert.equal(h.store.get('restaurant_owners/s-new').mustChangePassword, false);
});

test('B5 vendeur/boulangerie première connexion : aucun lot, restaurant_owners intact', async () => {
  const h = firstLoginHarness({ 'restaurant_owners/s-new': { restaurantId: 'r1', mustChangePassword: true } });
  assert.deepEqual(await h.run(h.req({ newPassword: 'MonNouveau9' })), { success: true });
  assert.equal(h.calls.some(c => c[0] === 'batch'), false);
  assert.equal(h.store.get('restaurant_owners/s-new').mustChangePassword, true);
});

test('B5 deux changements simultanés restaurateur : un seul lot, une seule mise à jour Auth', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const h = restaurantFirstLogin({ slowAuth: () => gate });
  const first = h.run(h.req({ newPassword: 'PremierNouveau9' }));
  await new Promise(r => setImmediate(r));
  await assert.rejects(h.run(h.req({ newPassword: 'SecondNouveau9' })), e => e.code === 'aborted');
  release();
  await first;
  assert.equal(h.calls.filter(c => c[0] === 'updateUser').length, 1);
  assert.equal(h.calls.filter(c => c[0] === 'batch').length, 1);
});
