'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createEventNotificationFunctions,
} = require('../eventNotifications');

function trigger(_options, handler) {
  return handler;
}

test('event notification: notifie chaque prestataire unique', async () => {
  const sent = [];
  const providers = {
    p1: { fcmToken: 'token-1' },
    p2: { fcmToken: 'token-2' },
  };
  const db = {
    collection(name) {
      assert.equal(name, 'event_providers');
      return {
        doc(id) {
          return {
            async get() {
              return { data: () => providers[id] };
            },
          };
        },
      };
    },
  };
  const functions = createEventNotificationFunctions({
    db,
    onDocumentCreated: trigger,
    onDocumentUpdated: trigger,
    sendToToken: async (...args) => sent.push(args),
  });
  await functions.notifyProvidersOnEventReservation({
    data: {
      data: () => ({
        providerIds: ['p1', 'p1', 'p2'],
        items: [{}, {}],
        address: 'Abengourou',
      }),
    },
    params: { reservationId: 'r1' },
  });
  assert.equal(sent.length, 2);
  assert.deepEqual(sent.map((entry) => entry[0]).sort(), ['token-1', 'token-2']);
  assert.equal(sent[0][3].reservationId, 'r1');
});

test('event notification: ignore une mise à jour sans changement de statut', async () => {
  const sent = [];
  const functions = createEventNotificationFunctions({
    db: {},
    onDocumentCreated: trigger,
    onDocumentUpdated: trigger,
    sendToToken: async (...args) => sent.push(args),
  });
  await functions.notifyClientOnEventReservationUpdate({
    data: {
      before: { data: () => ({ status: 'pending' }) },
      after: { data: () => ({ status: 'pending' }) },
    },
    params: { reservationId: 'r1' },
  });
  assert.equal(sent.length, 0);
});

test('event notification: notifie les administrateurs lors d’une inscription', async () => {
  const sent = [];
  const db = {
    collection(name) {
      assert.equal(name, 'admins');
      return {
        where() {
          return {
            async get() {
              return {
                docs: [
                  { data: () => ({ fcmToken: 'admin-token-12345' }) },
                  { data: () => ({ fcmToken: 'admin-token-12345' }) },
                ],
              };
            },
          };
        },
      };
    },
  };
  const functions = createEventNotificationFunctions({
    db,
    onDocumentCreated: trigger,
    onDocumentUpdated: trigger,
    sendToToken: async (...args) => sent.push(args),
  });
  await functions.notifyAdminsOnEventProviderApplication({
    data: { data: () => ({ status: 'pending', shopName: 'Events AZ' }) },
    params: { providerId: 'provider-1' },
  });
  assert.equal(sent.length, 1);
  assert.equal(sent[0][3].providerId, 'provider-1');
});
