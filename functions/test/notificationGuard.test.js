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

function run(env, calls, data = DATA, extra = {}) {
  const out = execFileSync(process.execPath, [path.join(__dirname, 'notificationHarness.js'), JSON.stringify({ env, calls, data, ...extra })], {
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
  assert.deepEqual(Object.keys(r.markers).sort(), ['notifyClientOnOrderUpdate_autre_client_c1', 'notifyClientOnOrderUpdate_same_client_c1']);
  assert.deepEqual(Object.values(r.markers).map((m) => m.state), ['sent', 'sent']);
  assert.ok(!JSON.stringify(r.markers).includes(T_CLIENT), 'jamais de token dans un marqueur');
});

test('commande hors périmètre (héritée, non v2) : aucun envoi, même pour un destinataire autorisé', () => {
  const env = preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fp(T_CLIENT)},restaurant:r1:${fp(T_REST)}` });
  const r = run(env, [update('e1', LEGACY), { fn: 'notifyRestaurantOnOrder', eventId: 'e2', order: LEGACY }]);
  assert.deepEqual(r.sends, []);
  assert.deepEqual(r.markers, {});
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
  assert.deepEqual(r.markers, {});
  assert.deepEqual(r.writes, []);
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

// ── Mission 7E-31 : réservation atomique, états, erreurs Firestore et FCM ─────────────────────────────────────────────────────────
const ON = (list) => preprod({ NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: list });
const CLIENT_OK = `client:c1:${fp(T_CLIENT)}`;
const markerStates = (r) => Object.values(r.markers).map((m) => m.state);

test('deux exécutions simultanées du même événement : une seule notification, un seul marqueur', () => {
  const r = run(ON(CLIENT_OK), [{ ...update('dup'), parallel: true }, { ...update('dup'), parallel: true }, { ...update('dup'), parallel: true }]);
  assert.equal(sentTokens(r).length, 1);
  assert.deepEqual(markerStates(r), ['sent']);
});

test('réservation Firestore impossible : aucun envoi en préproduction (jamais d’envoi sans marqueur)', () => {
  const r = run(ON(CLIENT_OK), [update('e1')].concat([{ fn: 'notifyDriversOnNewOrder', eventId: 'e2', order: { status: 'pending', budget: 500 } }]), DATA);
  assert.equal(sentTokens(r).length, 1); // contrôle : sans panne, l'envoi a lieu
  const down = run(ON(`${CLIENT_OK},driver:d1:${fp(T_DRIVER1)}`), [update('e1'), { fn: 'notifyDriversOnNewOrder', eventId: 'e2', order: { status: 'pending', budget: 500 } }], DATA, { failCreate: true });
  assert.deepEqual(down.sends, []);
  assert.deepEqual(down.markers, {});
  // Événement sans identifiant : réservation impossible, donc aucun envoi.
  assert.deepEqual(run(ON(CLIENT_OK), [update(undefined)]).sends, []);
});

test('refus définitif de FCM après réservation : marqueur « failed » avec le code, aucun renvoi automatique au rejeu', () => {
  const env = ON(CLIENT_OK);
  const r = run(env, [update('e1'), update('e1')], DATA, { sendError: 'messaging/registration-token-not-registered' });
  assert.equal(sentTokens(r).length, 1);
  assert.deepEqual(markerStates(r), ['failed']);
  assert.equal(Object.values(r.markers)[0].errorCode, 'messaging/registration-token-not-registered');
});

test('résultat FCM incertain (erreur serveur/réseau) : marqueur « uncertain », jamais renvoyé seul', () => {
  const r = run(ON(CLIENT_OK), [update('e1'), update('e1')], DATA, { sendError: 'messaging/internal-error' });
  assert.equal(sentTokens(r).length, 1);
  assert.deepEqual(markerStates(r), ['uncertain']);
  const unknown = run(ON(CLIENT_OK), [update('e2')], DATA, { sendError: 'ECONNRESET' });
  assert.deepEqual(markerStates(unknown), ['uncertain']);
});

test('redémarrage pendant l’envoi (marqueur resté « reserved ») ou événement rejoué : aucun nouvel envoi, état conservé pour diagnostic', () => {
  const seeded = { notifyClientOnOrderUpdate_e1_client_c1: { fn: 'notifyClientOnOrderUpdate', role: 'client', recipientId: 'c1', eventId: 'e1', state: 'reserved', reservedAt: 1 } };
  const r = run(ON(CLIENT_OK), [update('e1')], DATA, { markers: seeded });
  assert.deepEqual(r.sends, []);
  assert.deepEqual(r.markers, seeded);
});

test('multicast livreurs : l’issue de chaque livreur est enregistrée séparément', () => {
  const env = ON(`driver:d1:${fp(T_DRIVER1)},driver:d2:${fp(T_DRIVER2)}`);
  const r = run(env, [{ fn: 'notifyDriversOnNewOrder', eventId: 'e1', order: { status: 'pending', budget: 500 } }], DATA, { tokenErrors: { [T_DRIVER2]: 'messaging/invalid-registration-token' } });
  assert.deepEqual(sentTokens(r).sort(), [T_DRIVER1, T_DRIVER2].sort());
  assert.equal(r.markers.notifyDriversOnNewOrder_e1_driver_d1.state, 'sent');
  assert.equal(r.markers.notifyDriversOnNewOrder_e1_driver_d2.state, 'failed');
});

test('production : une panne de réservation ou de FCM ne change rien (aucun marqueur, mêmes envois)', () => {
  const r = run({ GCLOUD_PROJECT: PROD }, [update('e1', LEGACY)], DATA, { failCreate: true, sendError: 'messaging/internal-error' });
  assert.equal(sentTokens(r).length, 1);
  assert.deepEqual(r.markers, {});
  assert.deepEqual(r.writes, []);
});

// Expiration automatique avec notification bloquée : l'annulation et ses écritures ont lieu, seule l'alerte FCM est retenue.
const NOW = 1_800_000_000_000 - (1_800_000_000_000 % 300000); // minute multiple de 5 : les alertes « commandes bloquées » s'exécutent
const STALE = { status: 'pending', createdAtMs: NOW - 40 * 60 * 1000, clientId: 'c1', paymentMethod: 'cash', isPaid: false, budget: 500, description: 'Colis' };
const EXPIRY_DATA = { ...DATA, orders: { stale1: STALE, v2wait: { ...STALE, amountsVersion: 2, sellerType: 'restaurant', sellerId: 'r1', createdAtMs: NOW - 15 * 60 * 1000 } }, admins: { a1: { isActive: true, role: 'super', fcmToken: 'token-admin-0123456789-abcdefghij' } } };

test('expiration de commande : jamais empêchée par le blocage FCM (préproduction), alertes envoyées en production', () => {
  const pre = run(preprod({ NOTIFICATIONS_SEND: 'off' }), [], EXPIRY_DATA, { run: { fn: 'autoExpireOrders' }, now: NOW });
  const prod = run({ GCLOUD_PROJECT: PROD }, [], EXPIRY_DATA, { run: { fn: 'autoExpireOrders' }, now: NOW });
  // Même cheminement métier dans les deux projets : l'annulation (écriture sur la commande) a lieu quoi qu'il arrive.
  assert.ok(pre.writes.includes('orders/stale1'), 'préproduction : commande expirée');
  assert.deepEqual(pre.writes.filter((w) => w.startsWith('orders/')), prod.writes.filter((w) => w.startsWith('orders/')));
  assert.deepEqual(pre.sends, [], 'préproduction : aucune alerte FCM, y compris vers un administrateur');
  const allowed = run(ON(CLIENT_OK), [], EXPIRY_DATA, { run: { fn: 'autoExpireOrders' }, now: NOW });
  assert.deepEqual(allowed.sends, [], 'avec « on » et un client autorisé, l’administrateur n’est toujours pas notifié');
  assert.ok(allowed.writes.includes('orders/stale1'));
  assert.ok(prod.sends.length > 0, 'production : l’alerte « partenaire sans réponse » part vers l’administrateur');
});
