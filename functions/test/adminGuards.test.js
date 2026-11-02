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

// S2 : vérifier un retrait peut le régler ou le rembourser.
test('S2 : requireWithdrawalAccess — propriétaire et super-admin seulement', async () => {
  const { requireWithdrawalAccess } = require('../adminGuards');
  const withdrawal = { userId: 'owner' };
  // Propriétaire : aucune lecture de la collection admins.
  await requireWithdrawalAccess({ request: request('owner'), db: dbWith(undefined), withdrawal });
  // Super-admin actif.
  await requireWithdrawalAccess({
    request: request('boss'), db: dbWith({ role: 'super', isActive: true }), withdrawal,
  });
  // Tout le reste est refusé : sous-admin (même avec permissions financières), désactivé, inconnu, anonyme.
  for (const [admin, req] of [
    [{ role: 'sub', isActive: true, permissions: ['recharges', 'commandes', 'demandes_vendeurs'] }, request('sub')],
    [{ role: 'super', isActive: false }, request('boss')],
    [{ role: 'other', isActive: true }, request('x')],
    [undefined, request('stranger')],
    [{ role: 'super', isActive: true }, request('boss', 'anonymous')],
  ]) {
    await assert.rejects(
      requireWithdrawalAccess({ request: req, db: dbWith(admin), withdrawal }),
      (error) => error.code === 'permission-denied' || error.code === 'unauthenticated',
    );
  }
  // Retrait sans propriétaire connu : ne s'ouvre jamais par égalité undefined.
  await assert.rejects(
    requireWithdrawalAccess({ request: request('sub'), db: dbWith({ role: 'sub', isActive: true, permissions: [] }), withdrawal: {} }),
    (error) => error.code === 'permission-denied',
  );
});

// S7 : le second facteur (MFA Firebase) est vérifié aussi côté serveur.
test('S7 : enforceAdminSecondFactor — modes off / log / enforce', () => {
  const { enforceAdminSecondFactor } = require('../adminGuards');
  const withFactor = { auth: { uid: 'a1', token: { firebase: { sign_in_provider: 'password', sign_in_second_factor: 'totp' } } } };
  const without = { auth: { uid: 'a2', token: { firebase: { sign_in_provider: 'password' } } } };
  const logs = [];
  const warn = (...args) => logs.push(args.join(' '));
  enforceAdminSecondFactor({ request: without, role: 'sub', mode: 'off', warn });
  enforceAdminSecondFactor({ request: withFactor, role: 'sub', mode: 'enforce', warn });
  assert.equal(logs.length, 0);
  enforceAdminSecondFactor({ request: without, role: 'sub', mode: 'log', warn });
  enforceAdminSecondFactor({ request: without, role: 'sub', mode: 'log', warn });
  assert.equal(logs.length, 1, 'une seule trace par compte');
  assert.match(logs[0], /admin_without_second_factor/);
  assert.doesNotMatch(logs[0], /token|password|otp/i);
  assert.throws(
    () => enforceAdminSecondFactor({ request: without, role: 'super', mode: 'enforce', warn }),
    (error) => error.code === 'permission-denied',
  );
});

test('S7 : en mode enforce, requireSuperAdmin et requireAdminPermission exigent le second facteur', async () => {
  const { requireSuperAdmin: superGuard, requireAdminPermission: permGuard } = require('../adminGuards');
  const previous = process.env.ADMIN_MFA_MODE;
  process.env.ADMIN_MFA_MODE = 'enforce';
  try {
    const plain = request('boss');
    const mfa = { auth: { uid: 'boss', token: { firebase: { sign_in_provider: 'password', sign_in_second_factor: 'phone' } } } };
    const db = dbWith({ role: 'super', isActive: true });
    await assert.rejects(superGuard({ request: plain, db }), (e) => e.code === 'permission-denied');
    await assert.rejects(permGuard({ request: plain, db, permission: 'commandes' }), (e) => e.code === 'permission-denied');
    await superGuard({ request: mfa, db });
    await permGuard({ request: mfa, db, permission: 'commandes' });
  } finally {
    if (previous === undefined) delete process.env.ADMIN_MFA_MODE; else process.env.ADMIN_MFA_MODE = previous;
  }
});
