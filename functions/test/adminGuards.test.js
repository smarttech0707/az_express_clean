'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');

function dbWith(admin) {
  return {
    collection: () => ({
      doc: () => ({
        get: async () => ({ exists: admin != null, data: () => admin }),
      }),
    }),
  };
}

function request(uid = 'admin', provider = 'password') {
  return { auth: { uid, token: { firebase: { sign_in_provider: provider } } } };
}

test('requireAdminPermission authorizes an active super and an authorized sub', async () => {
  await requireAdminPermission({ request: request(), db: dbWith({ role: 'super', isActive: true }), permission: 'commandes' });
  await requireAdminPermission({ request: request(), db: dbWith({ role: 'sub', isActive: true, permissions: ['commandes'] }), permission: 'commandes' });
});

test('requireAdminPermission rejects inactive, unknown, anonymous, and unauthorized sub admins', async () => {
  const denied = async (admin, req = request()) => assert.rejects(
    requireAdminPermission({ request: req, db: dbWith(admin), permission: 'commandes' }),
    (error) => error.code === 'permission-denied' || error.code === 'unauthenticated',
  );
  await denied({ role: 'super', isActive: false });
  await denied({ role: 'other', isActive: true });
  await denied({ role: 'sub', isActive: true, permissions: ['livreurs'] });
  await denied({ role: 'super', isActive: true }, request('admin', 'anonymous'));
});

test('requireSuperAdmin rejects every sub admin and a disabled super admin', async () => {
  await requireSuperAdmin({ request: request(), db: dbWith({ role: 'super', isActive: true }) });
  for (const admin of [
    { role: 'super', isActive: false },
    { role: 'sub', isActive: true, permissions: ['commandes'] },
  ]) {
    await assert.rejects(
      requireSuperAdmin({ request: request(), db: dbWith(admin) }),
      (error) => error.code === 'permission-denied',
    );
  }
});
