'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createVehicleChatNotificationFunction,
} = require('../vehicleChatNotifications');

function buildHarness({ conversation, client, sellerProfile, message, blocked = false }) {
  const sends = [];
  let handler;
  const functionUnderTest = createVehicleChatNotificationFunction({
    db: {
      collection(name) {
        return {
          doc() {
            return {
              collection() {
                return {
                  doc() {
                    return { get: async () => ({ exists: blocked }) };
                  },
                };
              },
              async get() {
                const data = name === 'vehicle_conversations'
                  ? conversation
                  : name === 'clients'
                    ? client
                    : sellerProfile;
                return { data: () => data };
              },
            };
          },
        };
      },
    },
    onDocumentCreated: (_options, callback) => {
      handler = callback;
      return callback;
    },
    sendToToken: async (...args) => sends.push(args),
  });
  return {
    sends,
    run: () => handler({
      data: { data: () => message },
      params: { conversationId: 'vc_listing_buyer', messageId: 'm1' },
    }),
    functionUnderTest,
  };
}

test('vendeur répond : le client reçoit un payload minimal sans donnée privée', async () => {
  const harness = buildHarness({
    conversation: {
      listingId: 'listing',
      listingTitle: 'Toyota Corolla',
      participantIds: ['buyer', 'seller'],
    },
    client: { fcmToken: 'client-token-12345' },
    message: { senderId: 'seller', text: 'contenu privé' },
  });
  await harness.run();
  assert.equal(harness.sends.length, 1);
  const [token, title, body, data] = harness.sends[0];
  assert.equal(token, 'client-token-12345');
  assert.match(title, /Toyota Corolla/);
  assert.doesNotMatch(body, /contenu privé/);
  assert.deepEqual(data, {
    type: 'vehicle_chat_message',
    conversationId: 'vc_listing_buyer',
    listingId: 'listing',
  });
  assert.equal('senderId' in data, false);
});

for (const sellerKind of ['particulier', 'professionnel', 'magasin']) {
  test(`client envoie : le vendeur ${sellerKind} reçoit via son profil`, async () => {
    const harness = buildHarness({
      conversation: {
        listingId: 'listing',
        participantIds: ['buyer', 'seller'],
      },
      client: {},
      sellerProfile: { fcmToken: `${sellerKind}-token-12345` },
      message: { senderId: 'buyer', text: 'message privé' },
    });
    await harness.run();
    assert.equal(harness.sends.length, 1);
    assert.equal(harness.sends[0][0], `${sellerKind}-token-12345`);
  });
}

test('ignore un expéditeur extérieur sans accepter de token expéditeur', async () => {
  const outsider = buildHarness({
    conversation: { participantIds: ['buyer', 'seller'] },
    client: { fcmToken: 'valid-token-12345' },
    message: { senderId: 'outsider', fcmToken: 'sender-token-12345' },
  });
  await outsider.run();
  assert.equal(outsider.sends.length, 0);
});

test('token absent ou invalide : aucune notification et aucune suppression', async () => {
  const missingToken = buildHarness({
    conversation: { participantIds: ['buyer', 'seller'] },
    client: { fcmToken: 'court' },
    sellerProfile: {},
    message: { senderId: 'buyer', text: 'message conservé' },
  });
  await missingToken.run();
  assert.equal(missingToken.sends.length, 0);
});

test('blocage dans un sens : aucune notification FCM', async () => {
  const harness = buildHarness({
    conversation: { participantIds: ['buyer', 'seller'] },
    sellerProfile: { fcmToken: 'seller-token-12345' },
    message: { senderId: 'buyer', text: 'message' },
    blocked: true,
  });
  await harness.run();
  assert.equal(harness.sends.length, 0);
});
