'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  PERMISSION_KEYS, PROFILES, SUPER_ONLY_KEYS, NOTIFICATION_PERMISSION,
  validatePermissions, adminNotificationTokens,
} = require('../adminPermissions');

const root = path.join(__dirname, '..', '..');
const sorted = (list) => [...list].sort();

test('S8 : la liste officielle est identique côté Flutter, règles Firestore et serveur', () => {
  const dart = fs.readFileSync(path.join(root, 'lib/screens/admin/admin_mfa_security.dart'), 'utf8');
  const dartKeys = [...dart.slice(dart.indexOf('adminPermissionKeys'), dart.indexOf('};', dart.indexOf('adminPermissionKeys')))
    .matchAll(/^\s*'([a-z_]+)',/gm)].map((m) => m[1]);
  assert.deepEqual(sorted(dartKeys), sorted(PERMISSION_KEYS));

  const rules = fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8');
  const fn = rules.slice(rules.indexOf('hasOnly([', rules.indexOf('function adminPermissionsKnown')));
  const ruleKeys = [...fn.slice(0, fn.indexOf(']')).matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
  assert.deepEqual(sorted(ruleKeys), sorted(PERMISSION_KEYS));
});

test('S8 : toute clé exigée par une Cloud Function ou une règle est officielle', () => {
  const used = new Set();
  for (const file of fs.readdirSync(path.join(__dirname, '..')).filter((f) => f.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    for (const m of src.matchAll(/requireAdminPermission\(\{[^}]*permission:\s*'([a-z_]+)'/g)) used.add(m[1]);
  }
  const rules = fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8');
  for (const m of rules.matchAll(/hasAdminPermission\('([a-z_]+)'\)/g)) used.add(m[1]);
  assert.ok(used.size >= 8, 'le balayage doit trouver des clés');
  for (const key of used) assert.ok(PERMISSION_KEYS.includes(key), `clé non officielle utilisée : ${key}`);
});

test('S8 : les permissions inconnues ou mal formées sont refusées', () => {
  assert.deepEqual(validatePermissions(['livreurs', 'livreurs', 'support']), ['livreurs', 'support']);
  assert.deepEqual(validatePermissions(undefined), []);
  assert.deepEqual(validatePermissions([]), []);
  for (const bad of ['livreurs', {}, ['livreurs', 'root'], [1], [null], ['*'], ['LIVREURS'], ['auto-moto'],
    [{ $ne: 1 }], new Array(100).fill('livreurs')]) {
    assert.throws(() => validatePermissions(bad), (e) => e.code === 'invalid-argument');
  }
});

test('S8 : auto_moto est valide côté serveur mais n\'entre dans aucun profil', () => {
  assert.ok(PERMISSION_KEYS.includes('auto_moto'));
  for (const keys of Object.values(PROFILES)) assert.ok(!keys.includes('auto_moto'));
});

test('profils : clés officielles, sans doublon entre profils, aucune clé financière ou destructive', () => {
  const seen = new Map();
  for (const [name, keys] of Object.entries(PROFILES)) {
    assert.ok(keys.length > 0, name);
    assert.deepEqual(validatePermissions(keys), [...keys], name);
    for (const key of keys) {
      assert.ok(!SUPER_ONLY_KEYS.includes(key), `${name} contient une clé réservée : ${key}`);
      assert.ok(!seen.has(key), `${key} dans ${seen.get(key)} et ${name}`);
      seen.set(key, name);
    }
  }
  for (const key of ['gains', 'recharges', 'cash_marchand', 'purger']) {
    assert.ok(SUPER_ONLY_KEYS.includes(key));
  }
  assert.deepEqual(Object.keys(PROFILES).sort(), ['operations', 'partenaires', 'support']);
});

test('S5 : notifications — super-admin toujours, sous-admin selon sa permission', () => {
  const docs = [
    { role: 'super', isActive: true, fcmToken: 'super-token-0001' },
    { role: 'super', isActive: false, fcmToken: 'super-off-token-1' },
    { role: 'sub', isActive: true, permissions: ['demandes'], fcmToken: 'sub-demandes-001' },
    { role: 'sub', isActive: true, permissions: ['support'], fcmToken: 'sub-support-0001' },
    { role: 'sub', isActive: false, permissions: ['demandes'], fcmToken: 'sub-inactif-0001' },
    { role: 'sub', isActive: true, permissions: 'demandes', fcmToken: 'sub-malforme-001' },
    { role: 'other', isActive: true, permissions: ['demandes'], fcmToken: 'other-token-0001' },
    { role: 'sub', isActive: true, permissions: ['demandes'] },
    { role: 'sub', isActive: true, permissions: ['demandes'], fcmToken: 'court' },
  ];
  const asDocs = docs.map((d) => ({ data: () => d }));
  assert.deepEqual(adminNotificationTokens(asDocs, NOTIFICATION_PERMISSION.admin_new_driver).sort(),
    ['sub-demandes-001', 'super-token-0001']);
  assert.deepEqual(adminNotificationTokens(asDocs, NOTIFICATION_PERMISSION.admin_new_service_provider),
    ['super-token-0001']);
  // Alerte de sécurité : super-admin actif seulement.
  assert.equal(NOTIFICATION_PERMISSION.security_alert, null);
  assert.deepEqual(adminNotificationTokens(asDocs, NOTIFICATION_PERMISSION.security_alert), ['super-token-0001']);
  // Dédoublonnage des jetons.
  assert.deepEqual(adminNotificationTokens([docs[0], docs[0]], null), ['super-token-0001']);
});

test('S5 : toutes les notifications admin existantes passent par le routage par permission', () => {
  const index = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const events = fs.readFileSync(path.join(__dirname, '..', 'eventNotifications.js'), 'utf8');
  for (const src of [index, events]) {
    assert.ok(!/admins'\)\s*\.where\('isActive'[^;]*;\s*const tokens = [^;]*map\(\(?d/.test(src));
  }
  assert.ok(!/snap\.docs\.map\(d => d\.data\(\)\.fcmToken\)/.test(index), 'jetons admin bruts dans index.js');
  assert.ok(!/adminsSnap\.docs\.map/.test(index), 'jetons admin bruts (alerte sécurité)');
  assert.ok(!/doc\.data\(\)\?\.fcmToken/.test(events), 'jetons admin bruts (événementiel)');
});
