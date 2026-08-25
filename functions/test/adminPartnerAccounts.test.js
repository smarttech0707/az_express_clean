'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildManageAdminPartnerAccount } = require('../adminPartnerAccounts');

function harness(adminData = { role: 'super', isActive: true }) {
  const calls = [];
  const auth = {
    createUser: async (data) => { calls.push(['createUser', data]); return { uid: 'partner-1' }; },
    updateUser: async (uid, data) => { calls.push(['updateUser', uid, data]); },
    deleteUser: async () => {},
  };
  const db = {
    collection(name) {
      return {
        doc(uid) {
          return {
            get: async () => ({ exists: name === 'admins', data: () => adminData }),
            set: async (data) => { calls.push(['set', name, uid, data]); },
          };
        },
      };
    },
  };
  return {
    calls,
    run: buildManageAdminPartnerAccount({
      db, auth, fieldValue: { serverTimestamp: () => 'timestamp' },
    }),
  };
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
