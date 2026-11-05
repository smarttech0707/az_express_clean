'use strict';

// Mission 7E-30 — notifications push de la préproduction : bloquées par défaut, autorisation explicite par destinataire et par token,
// périmètre Restaurant v2, déduplication des événements répétés, production inchangée. Aucun envoi FCM réel : le Firebase Messaging
// et Firestore sont factices (test/notificationHarness.js, processus enfant avec le vrai index.js).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { sendMode, parseAllowlist, fingerprint, createNotificationGuard } = require('../notificationGuard');

const PRE = 'az-express-preprod';
const PROD = 'az-express-b0469';
const T_CLIENT = 'token-client-0123456789-abcdefghij';
const T_DRIVER1 = 'token-driver1-0123456789-abcdefghij';
const T_DRIVER2 = 'token-driver2-0123456789-abcdefghij';
const T_REST = 'token-restaurant-0123456789-abcdef';
const fp = (t) => fingerprint(t).slice(0, 12);

const DATA = {
  clients: { c1: { fcmToken: T_CLIENT }, cNoToken: {} },
  livreurs: { d1: { isOnline: true, fcmToken: T_DRIVER1 }, d2: { isOnline: true, fcmToken: T_DRIVER2 }, d3: { isOnline: false, fcmToken: 'token-offline-0123456789' } },
  restaurants: { r1: { fcmToken: T_REST } },
  restaurant_owners: {},
};
const V2 = { clientId: 'c1', sellerType: 'restaurant', sellerId: 'r1', amountsVersion: 2, status: 'pending', description: 'Menu', budget: 1500 };
const LEGACY = { clientId: 'c1', sellerType: 'restaurant', sellerId: 'r1', status: 'pending', description: 'Menu', budget: 1500 };
const update = (eventId, order = V2, status = 'accepted') => ({ fn: 'notifyClientOnOrderUpdate', eventId, update: true, before: { ...order, status: 'assigned' }, after: { ...order, status } });

function run(env, calls, data = DATA) {
  const out = execFileSync(process.execPath, [path.join(__dirname, 'notificationHarness.js'), JSON.stringify({ env, calls, data })], {
    env: { ...process.env, FIREBASE_CONFIG: JSON.stringify({ projectId: env.GCLOUD_PROJECT }), ...env }, encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  return JSON.parse(out.slice(out.lastIndexOf('@@') + 2));
}
const preprod = (extra = {}) => ({ GCLOUD_PROJECT: PRE, ...extra });
const sentTokens = (r) => r.sends.flatMap((s) => (s.kind === 'send' ? [s.token] : s.tokens));
const allow = (...e) => e.join(',');

test('sendMode : seule la valeur exacte « on » ouvre la préproduction ; production et autres projets non concernés', () => {
  for (const v of [undefined, '', 'off', 'OFF', 'DISABLED', 'true', '1', 'yes', 'onn', ' o n ']) {
    assert.equal(sendMode({ GCLOUD_PROJECT: PRE, NOTIFICATIONS_SEND: v }), 'blocked', String(v));
  }
  assert.equal(sendMode({ GCLOUD_PROJECT: PRE, NOTIFICATIONS_SEND: 'on' }), 'allowlist');
  assert.equal(sendMode({ GCLOUD_PROJECT: PRE, NOTIFICATIONS_SEND: ' ON ' }), 'allowlist');
  for (const project of [PROD, 'demo-test', undefined, 'az-express-preprod-1']) {
    assert.equal(sendMode({ GCLOUD_PROJECT: project }), 'unrestricted', String(project));
    assert.equal(sendMode({ GCLOUD_PROJECT: project, NOTIFICATIONS_SEND: 'off' }), 'unrestricted', 'la variable est sans effet hors préproduction');
  }
});

test('liste d\'autorisation : entrées mal formées ignorées, jamais de token en clair', () => {
  const ok = `client:c1:${fp(T_CLIENT)}`;
  const parsed = parseAllowlist(`${ok}, driver:d1:abcd, restaurant:r1, admin:a1:${fp('x')}, client:c1/x:${fp('x')}, client:c1:zzzzzzzz, client:c1:${fp('x')}:extra,`);
  assert.deepEqual(parsed, [{ role: 'client', id: 'c1', fp: fp(T_CLIENT) }]);
  assert.deepEqual(parseAllowlist(undefined), []);
  assert.deepEqual(parseAllowlist(''), []);
});

test('interrupteur absent, off ou invalide : aucun envoi, quel que soit le destinataire', () => {
  const calls = [update('e1'), { fn: 'notifyDriversOnNewOrder', eventId: 'e2', order: { status: 'pending', budget: 500 } },
    { fn: 'notifyRestaurantOnOrder', eventId: 'e3', order: V2 }];
  const list = allow(`client:c1:${fp(T_CLIENT)}`, `driver:d1:${fp(T_DRIVER1)}`, `restaurant:r1:${fp(T_REST)}`);
  for (const send of [undefined, 'off', 'DISABLED', 'maybe', '']) {
    const env = preprod({ NOTIFICATIONS_ALLOWED_RECIPIENTS: list, ...(send === undefined ? {} : { NOTIFICATIONS_SEND: send }) });
    assert.deepEqual(run(env, calls).sends, [], String(send));
  }
});

test('on + liste vide ou destinataire non listé : aucun envoi ; seul le destinataire autorisé reçoit', () => {
  const calls = [update('e1')];
  assert.deepEqual(run(preprod({ NOTIFICATIONS_SEND: 'on' }), calls).sends, []);
  assert.deepEqual(run(preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: '' }), calls).sends, []);
  assert.deepEqual(run(preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:autre:${fp(T_CLIENT)}` }), calls).sends, []);
  const r = run(preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fp(T_CLIENT)}` }), calls);
  assert.deepEqual(sentTokens(r), [T_CLIENT]);
});

test('destinataire autorisé sans token, ou token renouvelé / différent : aucun envoi', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:cNoToken:${fp(T_CLIENT)},client:c1:${fp('ancien-token-autre-appareil')}` });
  assert.deepEqual(run(env, [{ ...update('e1'), after: { ...V2, clientId: 'cNoToken', status: 'accepted' } }]).sends, []);
  assert.deepEqual(run(env, [update('e2')]).sends, []); // l'empreinte autorisée n'est plus celle du token actuel
});

test('événement Firestore livré deux fois : une seule notification ; un autre événement notifie normalement', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fp(T_CLIENT)}` });
  const r = run(env, [update('same'), update('same'), update('autre', V2, 'picked_up')]);
  assert.equal(sentTokens(r).length, 2);
  assert.deepEqual(r.dedupe.sort(), ['notification_dedupe/notifyClientOnOrderUpdate_autre_client_c1', 'notification_dedupe/notifyClientOnOrderUpdate_same_client_c1']);
});

test('commande hors périmètre (héritée, non v2) : aucun envoi, même pour un destinataire autorisé', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fp(T_CLIENT)},restaurant:r1:${fp(T_REST)}` });
  const r = run(env, [update('e1', LEGACY), { fn: 'notifyRestaurantOnOrder', eventId: 'e2', order: LEGACY }]);
  assert.deepEqual(r.sends, []);
  assert.deepEqual(r.dedupe, []);
  const ok = run(env, [{ fn: 'notifyRestaurantOnOrder', eventId: 'e3', order: V2 }]);
  assert.deepEqual(sentTokens(ok), [T_REST]);
});

test('livreurs : seul le livreur autorisé (avec son token) reçoit parmi les livreurs en ligne', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `driver:d2:${fp(T_DRIVER2)}` });
  const r = run(env, [{ fn: 'notifyDriversOnNewOrder', eventId: 'e1', order: { status: 'pending', budget: 500, description: 'Colis' } }]);
  assert.deepEqual(sentTokens(r), [T_DRIVER2]);
});

test('séparation des rôles : une autorisation « driver » ne sert pas à notifier un client, ni l\'inverse', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `driver:c1:${fp(T_CLIENT)},client:d1:${fp(T_DRIVER1)}` });
  assert.deepEqual(run(env, [update('e1')]).sends, []);
  assert.deepEqual(run(env, [{ fn: 'notifyDriversOnNewOrder', eventId: 'e2', order: { status: 'pending', budget: 500 } }]).sends, []);
});

test('une autre fonction qui appelle FCM directement reste bloquée en préproduction, même avec « on » et une liste', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fp(T_CLIENT)}` });
  const r = run(env, [{ fn: 'notifyClientOnOrderCreated', eventId: 'e1', order: V2 }]);
  assert.deepEqual(r.sends, []);
});

test('production : comportement inchangé (mêmes envois, aucune liste, aucune écriture de déduplication)', () => {
  const env = { GCLOUD_PROJECT: PROD };
  const r = run(env, [update('e1', LEGACY), update('e1', LEGACY), { fn: 'notifyRestaurantOnOrder', eventId: 'e2', order: LEGACY },
    { fn: 'notifyDriversOnNewOrder', eventId: 'e3', order: { status: 'pending', budget: 500 } }, { fn: 'notifyClientOnOrderCreated', eventId: 'e4', order: LEGACY }]);
  assert.deepEqual(r.sends, [
    { kind: 'send', token: T_CLIENT }, { kind: 'send', token: T_CLIENT }, { kind: 'send', token: T_REST },
    { kind: 'multi', tokens: [T_DRIVER1, T_DRIVER2] }, { kind: 'send', token: T_CLIENT },
  ]);
  assert.deepEqual(r.dedupe, []);
  // Les variables de préproduction n'ont aucun effet en production.
  assert.equal(run({ ...env, NOTIFICATIONS_SEND: 'off' }, [update('e9', LEGACY)]).sends.length, 1);
});

test('le garde n\'accepte pas une autorisation fabriquée par un appelant', async () => {
  const guard = createNotificationGuard({ db: null, env: { GCLOUD_PROJECT: PRE, NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: '' }, logger: { log() {}, warn() {} } });
  assert.equal(guard.permits('tok', { tokens: new Set(['tok']) }), false);
  assert.equal(guard.permits('tok', null), false);
  const { tokens, authorization } = await guard.authorize({ fn: 'notifyClientOnOrderUpdate', eventId: 'e', order: V2 }, [{ role: 'client', id: 'c1', token: 'tok' }]);
  assert.deepEqual(tokens, []);
  assert.equal(authorization, null);
});
