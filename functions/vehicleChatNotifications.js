'use strict';

function createVehicleChatNotificationFunction({
  db,
  onDocumentCreated,
  sendToToken,
}) {
  return onDocumentCreated(
    {
      document: 'vehicle_conversations/{conversationId}/messages/{messageId}',
      maxInstances: 3,
    },
    async (event) => {
      const message = event.data?.data();
      if (!message || typeof message.senderId !== 'string') return;

      const conversationSnapshot = await db
        .collection('vehicle_conversations')
        .doc(event.params.conversationId)
        .get();
      const conversation = conversationSnapshot.data();
      if (!conversation) return;
      const participants = Array.isArray(conversation.participantIds)
        ? conversation.participantIds
        : [];
      if (!participants.includes(message.senderId)) return;
      const recipientId = participants.find((uid) => uid !== message.senderId);
      if (!recipientId) return;

      const [senderBlock, recipientBlock] = await Promise.all([
        db.collection('vehicle_user_blocks').doc(message.senderId)
          .collection('blocked').doc(recipientId).get(),
        db.collection('vehicle_user_blocks').doc(recipientId)
          .collection('blocked').doc(message.senderId).get(),
      ]);
      if (senderBlock.exists || recipientBlock.exists) return;

      let token;
      for (const collection of ['clients', 'vehicle_seller_profiles']) {
        const recipient = await db.collection(collection).doc(recipientId).get();
        const candidate = recipient.data()?.fcmToken;
        if (typeof candidate === 'string' && candidate.length > 10) {
          token = candidate;
          break;
        }
      }
      if (!token) return;

      await sendToToken(
        token,
        `Nouveau message • ${conversation.listingTitle || 'Auto & Moto'}`,
        'Un utilisateur vous a envoyé un message au sujet d’une annonce.',
        {
          type: 'vehicle_chat_message',
          conversationId: event.params.conversationId,
          listingId: String(conversation.listingId || ''),
        },
      );
    },
  );
}

module.exports = { createVehicleChatNotificationFunction };
