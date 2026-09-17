'use strict';

// LOT 6.3 SECURITY — event_reservations : le client fournissait lui-même
// `totalAmount` et `items[].unitPrice`/`items[].lineTotal`, jamais validés
// contre les vrais prix des `event_offers`. Les règles Firestore ne peuvent
// PAS revalider ça de façon fiable : il faudrait boucler sur `items[]` (0-50
// éléments) et sommer un prix relu depuis un autre document par élément —
// confirmé infaisable en pratique lors de cet audit (un déroulement de ce
// type dépasse la limite Firestore Rules "maximum of 1000 expressions to
// evaluate", déjà rencontrée sur une règle sans rapport pendant les tests
// LOT 6.2). Seule une Cloud Function (Admin SDK, calcul serveur) peut
// garantir que `totalAmount` correspond réellement aux prestations et
// quantités réservées — même principe déjà établi pour `payBoutiqueOrderCF`
// (jamais confiance au prix du client, toujours relu depuis le catalogue
// serveur). Les tarifs eux-mêmes (`event_offers.unitPrice`) ne sont ni
// modifiés ni recalculés ici — seulement relus fidèlement.
//
// Remplace la création directe côté client (event_service.dart) — voir
// firestore.rules, event_reservations.allow create: if false (Cloud
// Function uniquement à partir de ce correctif).

const { createHash } = require('node:crypto');

const MAX_ITEMS = 50;
const MAX_QUANTITY_PER_ITEM = 1000;
const WALLET_MIN_AMOUNT = 500; // même plancher que orders.budget

function buildCreateEventReservation({ db, admin, onCall, HttpsError, checkRateLimit }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const {
      attemptId, items: rawItems, eventDateMs, eventTime, address, description,
      paymentMethod, delivery, installation, dismantling, latitude, longitude,
    } = request.data || {};

    if (typeof attemptId !== 'string' || !/^[a-zA-Z0-9_-]{16,128}$/.test(attemptId)) {
      throw new HttpsError('invalid-argument', 'Identifiant de tentative invalide');
    }

    if (!Array.isArray(rawItems) || rawItems.length === 0 || rawItems.length > MAX_ITEMS) {
      throw new HttpsError('invalid-argument', 'Liste de prestations invalide');
    }
    if (!['wallet', 'cash', 'future'].includes(paymentMethod)) {
      throw new HttpsError('invalid-argument', 'Moyen de paiement invalide');
    }

    const items = rawItems.map((raw) => {
      const offerId = String(raw && raw.offerId || '');
      const quantity = Number(raw && raw.quantity);
      if (!offerId || offerId.includes('/') || !Number.isInteger(quantity) ||
          quantity <= 0 || quantity > MAX_QUANTITY_PER_ITEM) {
        throw new HttpsError('invalid-argument', 'Article de réservation invalide');
      }
      return { offerId, quantity };
    }).sort((a, b) => a.offerId.localeCompare(b.offerId) || a.quantity - b.quantity);
    const payload = {
      items,
      eventDateMs: Number(eventDateMs) || null,
      eventTime: String(eventTime || '').slice(0, 20),
      address: String(address || '').slice(0, 500),
      description: String(description || '').slice(0, 2000),
      latitude: typeof latitude === 'number' ? latitude : null,
      longitude: typeof longitude === 'number' ? longitude : null,
      delivery: delivery === true,
      installation: installation === true,
      dismantling: dismantling === true,
      paymentMethod,
    };
    const fingerprint = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
    // Private, permanent receipt: client rules grant no access to this collection.
    const receiptId = createHash('sha256').update(JSON.stringify([uid, attemptId])).digest('hex');
    const receiptRef = db.collection('event_reservation_attempts').doc(receiptId);
    const previousResult = (snap) => {
      const receipt = snap.data();
      if (receipt.fingerprint !== fingerprint) {
        throw new HttpsError('already-exists',
          'Cette tentative correspond à une autre réservation');
      }
      return receipt.result;
    };
    // Replays still succeed after a catalogue change or rate-limit exhaustion.
    const previous = await receiptRef.get();
    if (previous.exists) return previousResult(previous);
    await checkRateLimit(uid, 'create_event_reservation', 20, 60);

    const reservationRef = db.collection('event_reservations').doc();
    const clientRef = db.collection('clients').doc(uid);
    return db.runTransaction(async (tx) => {
      // This read must precede every write. Concurrent first calls conflict here
      // and retry against the receipt committed by the winning transaction.
      const receipt = await tx.get(receiptRef);
      if (receipt.exists) return previousResult(receipt);

      // Relit chaque offre RÉELLE côté serveur — jamais le prix, le titre ou
      // la quantité fournis par le client. Seuls `offerId`/`quantity` sont
      // lus depuis l'entrée cliente ; tout le reste (unitPrice, providerId,
      // title, category...) vient exclusivement du document event_offers.
      const resolvedItems = [];
      const providerIdsSet = new Set();
      let totalAmount = 0;

      for (const { offerId, quantity } of items) {
        const offerSnap = await tx.get(db.collection('event_offers').doc(offerId));
        if (!offerSnap.exists) {
          throw new HttpsError('failed-precondition', `Prestation introuvable : ${offerId}`);
        }
        const offer = offerSnap.data();
        if (offer.isActive !== true) {
          throw new HttpsError('failed-precondition', `Prestation indisponible : ${offerId}`);
        }

        const providerSnap = await tx.get(db.collection('event_providers').doc(offer.providerId));
        if (!providerSnap.exists) {
          throw new HttpsError('failed-precondition', 'Prestataire introuvable');
        }
        const provider = providerSnap.data();
        if (provider.status !== 'approved' || provider.isSuspended === true) {
          throw new HttpsError('failed-precondition', 'Prestataire indisponible');
        }

        const unitPrice = Number(offer.unitPrice || 0);
        const lineTotal = unitPrice * quantity;
        totalAmount += lineTotal;
        providerIdsSet.add(offer.providerId);

        resolvedItems.push({
          offerId,
          providerId: offer.providerId,
          providerName: offer.providerName || provider.shopName || 'Prestataire',
          title: offer.title || '',
          category: offer.category || null,
          subcategory: offer.subcategory || '',
          unitPrice,
          quantity,
          lineTotal,
          photoUrl: Array.isArray(offer.photoUrls) && offer.photoUrls.length > 0
            ? offer.photoUrls[0] : null,
        });
      }

      if (totalAmount <= 0) {
        throw new HttpsError('failed-precondition', 'Montant total invalide');
      }
      if (paymentMethod === 'wallet' && totalAmount < WALLET_MIN_AMOUNT) {
        // Même plancher que orders.budget — empêche une réservation "payée"
        // à un montant dérisoire côté wallet (cohérent avec LOT 6.2).
        throw new HttpsError('invalid-argument',
          `Montant minimum pour un paiement wallet : ${WALLET_MIN_AMOUNT} FCFA`);
      }

      let isPaid = false;

      if (paymentMethod === 'wallet') {
        const clientSnap = await tx.get(clientRef);
        const wallet = Number(clientSnap.data() && clientSnap.data().wallet || 0);
        if (wallet < totalAmount) {
          throw new HttpsError('failed-precondition',
            `SOLDE_INSUFFISANT:${wallet}:${totalAmount}`);
        }
        tx.update(clientRef, { wallet: wallet - totalAmount });
        isPaid = true;
      }

      tx.set(reservationRef, {
        clientId: uid,
        providerIds: [...providerIdsSet],
        items: resolvedItems,
        eventDate: admin.firestore.Timestamp.fromMillis(
          Number(eventDateMs) || Date.now()),
        eventTime: String(eventTime || '').slice(0, 20),
        address: String(address || '').slice(0, 500),
        description: String(description || '').slice(0, 2000),
        latitude: typeof latitude === 'number' ? latitude : null,
        longitude: typeof longitude === 'number' ? longitude : null,
        delivery: delivery === true,
        installation: installation === true,
        dismantling: dismantling === true,
        totalAmount,
        paymentMethod,
        isPaid,
        status: 'pending',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (isPaid) {
        tx.set(clientRef.collection('wallet_transactions').doc(reservationRef.id), {
          type: 'debit',
          amount: -totalAmount,
          description: 'Réservation événementielle',
          orderId: reservationRef.id,
          provider: 'event',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const result = { reservationId: reservationRef.id, totalAmount };
      tx.set(receiptRef, {
        clientId: uid, fingerprint, result,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return result;
    });
  });
}

module.exports = { buildCreateEventReservation, MAX_ITEMS, MAX_QUANTITY_PER_ITEM, WALLET_MIN_AMOUNT };
