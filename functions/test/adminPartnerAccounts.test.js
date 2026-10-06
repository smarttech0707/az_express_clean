'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildManageAdminPartnerAccount } = require('../adminPartnerAccounts');
const { HttpsError } = require('firebase-functions/v2/https');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function harness(adminData = { role: 'super', isActive: true }, options = {}) {
  const calls = [];
  const audits = [], events = [], limits = [];
  const store = new Map(Object.entries({
    ...(adminData ? { 'admins/admin-1': adminData } : {}),
    'boulangeries/b1': { name: 'B' },
    'sellers/s1': { name: 'S' },
    ...options.seed,
  }));
  const auth = {
    createUser: async (data) => { calls.push(['createUser', data]); if (options.authError) throw options.authError; return { uid: 'partner-1' }; },
    updateUser: async (uid, data) => { calls.push(['updateUser', uid, data]); if (options.authError) throw options.authError; },
    deleteUser: async (uid) => { calls.push(['deleteUser', uid]); if (options.rollbackError) throw options.rollbackError; },
  };
  const db = {
    collection(name) {
      return {
        doc(uid) {
          return {
            get: async () => {
              if (options.readError && name !== 'admins') throw options.readError;
              return { exists: store.has(`${name}/${uid}`), data: () => store.get(`${name}/${uid}`) };
            },
            create: async (data) => {
              calls.push(['create', name, uid, data]);
              if (options.writeError) throw options.writeError;
              if (store.has(`${name}/${uid}`)) throw new Error('already exists');
              store.set(`${name}/${uid}`, data);
            },
          };
        },
      };
    },
  };
  const deps = {
    db, auth, fieldValue: { serverTimestamp: () => 'timestamp' },
    checkRateLimit: async (...args) => { limits.push(args); if (options.rateError) throw options.rateError; },
    logAudit: async (data) => { audits.push({ ...data, createdAt: 'timestamp' }); },
    logSecurityEvent: async (...args) => { events.push(args); },
  };
  return { calls, audits, events, limits, store, deps, run: buildManageAdminPartnerAccount(deps) };
}

const request = (data) => ({
  auth: { uid: 'admin-1', token: { firebase: { sign_in_provider: 'password' } } },
  data,
});

test('création vendeur utilise Admin SDK sans changer l’identité appelante', async () => {
  const h = harness();
  const result = await h.run(request({
    action: 'create', kind: 'seller', email: 'seller@test.ci', password: 'secret1', profile: { name: 'V' },
  }));
  assert.equal(result.uid, 'partner-1');
  assert.equal(h.calls[0][0], 'createUser');
  assert.equal(h.calls.some((call) => call[0] === 'signIn' || call[0] === 'signOut'), false);
});

test('création boulangerie utilise Admin SDK sans changer l’identité appelante', async () => {
  const h = harness();
  await h.run(request({
    action: 'create', kind: 'boulangerie', email: 'b@test.ci', password: 'secret1', profile: { name: 'B' },
  }));
  assert.equal(h.calls[0][0], 'createUser');
  assert.equal(h.calls.some((call) => call[0] === 'signIn' || call[0] === 'signOut'), false);
});

test('mot de passe boulangerie utilise updateUser sans changer la session', async () => {
  const h = harness();
  await h.run(request({ action: 'updatePassword', kind: 'boulangerie', uid: 'b1', password: 'secret2' }));
  assert.deepEqual(h.calls[0], ['updateUser', 'b1', { password: 'secret2' }]);
});

test('un sous-admin sans permission requise est refusé', async () => {
  const h = harness({ role: 'sub', isActive: true, permissions: [] });
  await assert.rejects(
    h.run(request({ action: 'create', kind: 'seller', email: 's@test.ci', password: 'secret1' })),
    (error) => error.code === 'permission-denied',
  );
});

const permissions = { seller: 'demandes_vendeurs', boulangerie: 'boulangeries' };
const collections = { seller: 'sellers', boulangerie: 'boulangeries' };
const sampleProfiles = {
  seller: { name: 'Commerce', phone: '0700000000', type: 'boutique', lat: 6.7, lng: -3.5 },
  boulangerie: { name: 'Pain', address: 'Rue test', phone: '0700000000', openTime: '06:00', closeTime: '20:00', lat: 6.7, lng: -3.5 },
};
const sub = kind => ({ role: 'sub', isActive: true, permissions: [permissions[kind]] });
const reset = (kind, uid = kind === 'seller' ? 's1' : 'b1') => request({
  action: 'updatePassword', kind, uid, password: 'DummyTest9!',
});
const create = (kind, profile = {}) => request({
  action: 'create', kind, profile, email: 'fixture@example.invalid', password: 'DummyTest9!',
});
const updates = h => h.calls.filter(c => c[0] === 'updateUser');
const creations = h => h.calls.filter(c => c[0] === 'createUser');

for (const kind of Object.keys(permissions)) {
  test(`${kind}: authorized sub resets exactly the validated UID once`, async () => {
    const h = harness(sub(kind));
    const req = reset(kind);
    assert.deepEqual(await h.run(req), { uid: req.data.uid });
    assert.deepEqual(updates(h), [['updateUser', req.data.uid, { password: req.data.password }]]);
    assert.deepEqual(h.limits, [['admin-1', 'admin_partner_password', 10, 3600]]);
    assert.equal(h.audits[0].status, 'success');
    assert.equal(h.audits[0].targetId, req.data.uid);
    assert.equal(h.audits[0].createdAt, 'timestamp');
  });

  for (const [label, uid, seed] of [
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
    assert.deepEqual(result, { uid: 'partner-1' });
    assert.deepEqual(h.store.get(`${collections[kind]}/partner-1`), {
      ...sampleProfiles[kind], wallet: 0, createdAt: 'timestamp',
    });
    assert.deepEqual(creations(h), [['createUser', { email: req.data.email, password: req.data.password }]]);
    assert.equal(h.store.has('admins/partner-1'), false);
    assert.deepEqual(h.limits, [['admin-1', 'admin_partner_create', 10, 3600]]);
    assert.equal(h.audits[0].status, 'success');
    assert.equal(h.audits[0].targetId, 'partner-1');
  });

  test(`${kind}: existing Flutter empty profile contract remains accepted`, async () => {
    const h = harness(sub(kind));
    assert.deepEqual(await h.run(create(kind)), { uid: 'partner-1' });
    assert.deepEqual(h.store.get(`${collections[kind]}/partner-1`), { wallet: 0, createdAt: 'timestamp' });
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
  await assert.rejects(h.run(create('boulangerie')), e => e.code === 'internal');
  assert.equal(h.audits[0].metadata.stage, 'creation_rollback_failed');
  assert.equal(h.events[0][1], 'admin_partner_creation_rollback_failed');
});

test('create refuses to overwrite an existing business document', async () => {
  const h = harness(undefined, { seed: { 'sellers/partner-1': { name: 'Original', wallet: 12 } } });
  await assert.rejects(h.run(create('seller')), e => e.code === 'internal');
  assert.deepEqual(h.store.get('sellers/partner-1'), { name: 'Original', wallet: 12 });
});

test('Auth failures and raw request secrets never enter audit or response', async () => {
  const marker = 'SensitiveFixture9!';
  for (const action of ['create', 'updatePassword']) {
    const h = harness(undefined, { authError: new Error(marker) });
    const req = action === 'create' ? create('seller') : reset('seller');
    Object.assign(req.data, { password: marker, newPassword: marker, hash: marker, PIN: marker, OTP: marker, token: marker });
    await assert.rejects(h.run(req), e => e.code === 'internal' && !e.message.includes(marker));
    assert.equal(JSON.stringify([h.audits, h.events]).includes(marker), false);
    assert.deepEqual(Object.keys(h.audits[0].metadata).sort(), ['kind', 'stage']);
  }
});

test('password minimum 6 remains unchanged and short input never reaches Auth', async () => {
  const h = harness();
  const req = reset('seller');
  req.data.password = '12345';
  await assert.rejects(h.run(req), e => e.code === 'invalid-argument');
  assert.equal(updates(h).length, 0);
  req.data.password = 'abcdef';
  await h.run(req);
  assert.equal(updates(h).length, 1);
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
  await handler(create('seller'));
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
  await run(create('seller'));
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
    assert.equal(JSON.stringify(row).includes('DummyTest9!'), false);
    assert.deepEqual(Object.keys(row.data.metadata).sort(), ['kind', 'stage']);
  }
});

test('successful create and reset never log raw profile or extra sensitive inputs', async () => {
  const marker = 'PrivateFixture9!';
  const h = harness();
  for (const req of [create('seller', { name: marker }), reset('seller')]) {
    Object.assign(req.data, { password: marker, newPassword: marker, hash: marker, OTP: marker, token: marker, PIN: marker });
    await h.run(req);
  }
  assert.equal(h.audits.length, 2);
  assert.equal(JSON.stringify(h.audits).includes(marker), false);
  assert.equal(h.events.length, 0);
});
