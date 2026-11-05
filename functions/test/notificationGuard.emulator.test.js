'use strict';

// Mission 7E-31 — réservation atomique des notifications contre l'émulateur Firestore (jamais la production) : N exécutions
// simultanées du même événement → une seule réservation. Aucun FCM. Données fictives.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-notif \
//     "node --test functions/test/notificationGuard.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

test('12 exécutions simultanées du même événement : une seule réservation, états reserved puis sent', options, async () => {
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  const db = admin.firestore();
  const { createNotificationGuard, fingerprint } = require('../notificationGuard');
  const token = 'token-client-emulateur-0123456789-abcdef';
  const env = { GCLOUD_PROJECT: 'az-express-preprod', NOTIFICATIONS_SEND: 'on', NOTIFICATIONS_ALLOWED_RECIPIENTS: `client:c1:${fingerprint(token).slice(0, 12)}` };
  const guard = createNotificationGuard({ db, env, logger: { log() {}, warn() {} } });
  const ctx = { fn: 'notifyClientOnOrderUpdate', eventId: 'evt-1', order: { amountsVersion: 2 } };
  const results = await Promise.all(Array.from({ length: 12 }, () => guard.authorize(ctx, [{ role: 'client', id: 'c1', token }])));
  const winners = results.filter((r) => r.tokens.length === 1);
  assert.equal(winners.length, 1);
  const id = 'notifyClientOnOrderUpdate_evt-1_client_c1';
  assert.equal((await db.doc(`notification_dedupe/${id}`).get()).data().state, 'reserved');
  await guard.settle(winners[0], [{ token, ok: true }]);
  const final = (await db.doc(`notification_dedupe/${id}`).get()).data();
  assert.equal(final.state, 'sent');
  assert.ok(!JSON.stringify(final).includes(token));
  // Rejeu après « sent » : rien n'est renvoyé.
  assert.deepEqual((await guard.authorize(ctx, [{ role: 'client', id: 'c1', token }])).tokens, []);
});
