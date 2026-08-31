'use strict';

function createEventNotificationFunctions({
  db,
  onDocumentCreated,
  onDocumentUpdated,
  sendToToken,
}) {
  const notifyAdminsOnEventProviderApplication = onDocumentCreated(
    { document: 'event_providers/{providerId}', maxInstances: 2 },
    async (event) => {
      const provider = event.data?.data();
      if (!provider || provider.status !== 'pending') return;
      const admins = await db.collection('admins')
        .where('isActive', '==', true).get();
      const tokens = [...new Set(admins.docs
        .map((doc) => doc.data()?.fcmToken)
        .filter((token) => typeof token === 'string' && token.length > 10))];
      await Promise.all(tokens.map((token) => sendToToken(
        token,
        'Nouveau prestataire événementiel',
        `${provider.shopName || 'Une boutique'} attend votre validation.`,
        {
          type: 'event_provider_application',
          providerId: event.params.providerId,
        },
      )));
    },
  );

  const notifyProvidersOnEventReservation = onDocumentCreated(
    { document: 'event_reservations/{reservationId}', maxInstances: 2 },
    async (event) => {
      const reservation = event.data?.data();
      const providerIds = [...new Set(reservation?.providerIds || [])];
      if (!providerIds.length) return;
      await Promise.all(providerIds.map(async (providerId) => {
        const provider = await db.collection('event_providers').doc(providerId).get();
        const token = provider.data()?.fcmToken;
        if (!token) return;
        await sendToToken(
          token,
          'Nouvelle réservation événementielle',
          `${reservation.items?.length || 0} prestation(s) pour ${reservation.address || 'un événement'}.`,
          {
            type: 'event_reservation',
            reservationId: event.params.reservationId,
          },
        );
      }));
    },
  );

  const notifyClientOnEventReservationUpdate = onDocumentUpdated(
    { document: 'event_reservations/{reservationId}', maxInstances: 2 },
    async (event) => {
      const before = event.data?.before.data();
      const after = event.data?.after.data();
      if (!after || before?.status === after.status) return;
      const client = await db.collection('clients').doc(after.clientId).get();
      const token = client.data()?.fcmToken;
      if (!token) return;
      const labels = {
        confirmed: 'Votre réservation a été confirmée.',
        completed: 'Votre événement est marqué comme terminé.',
        cancelled: 'Votre réservation a été annulée.',
      };
      const body = labels[after.status];
      if (!body) return;
      await sendToToken(token, 'Réservation événementielle', body, {
        type: 'event_reservation_update',
        reservationId: event.params.reservationId,
        status: after.status,
      });
    },
  );

  const notifyEventChatRecipient = onDocumentCreated(
    {
      document: 'event_chats/{chatId}/messages/{messageId}',
      maxInstances: 3,
    },
    async (event) => {
      const message = event.data?.data();
      const chat = await db.collection('event_chats').doc(event.params.chatId).get();
      const data = chat.data();
      if (!data || !message?.senderId) return;
      const recipientId = (data.participantIds || [])
        .find((id) => id !== message.senderId);
      if (!recipientId) return;
      const [client, provider] = await Promise.all([
        db.collection('clients').doc(recipientId).get(),
        db.collection('event_providers').where('ownerId', '==', recipientId)
          .limit(1).get(),
      ]);
      const token = client.data()?.fcmToken
        || provider.docs[0]?.data()?.fcmToken;
      if (!token) return;
      await sendToToken(
        token,
        `Message • ${data.providerName || 'Événementiel'}`,
        String(message.text || '').slice(0, 120),
        { type: 'event_chat', chatId: event.params.chatId },
      );
    },
  );

  const updateEventProviderRating = onDocumentCreated(
    { document: 'event_reviews/{reviewId}', maxInstances: 2 },
    async (event) => {
      const review = event.data?.data();
      if (!review?.providerId || !Number.isFinite(review.rating)) return;
      const ref = db.collection('event_providers').doc(review.providerId);
      await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists) return;
        const provider = snapshot.data() || {};
        const count = Number(provider.reviewCount || 0);
        const average = Number(provider.rating || 0);
        transaction.update(ref, {
          rating: ((average * count) + review.rating) / (count + 1),
          reviewCount: count + 1,
        });
      });
    },
  );

  return {
    notifyAdminsOnEventProviderApplication,
    notifyProvidersOnEventReservation,
    notifyClientOnEventReservationUpdate,
    notifyEventChatRecipient,
    updateEventProviderRating,
  };
}

module.exports = { createEventNotificationFunctions };
