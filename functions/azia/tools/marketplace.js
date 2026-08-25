'use strict';

const { createPendingAction } = require('../pendingActions');
const { dispatchOrder, resolveDispatchGeography } = require('../../dispatch');

const RESULT_LIMIT = 10;

// Reprend la logique de filtrage de lib/marketplace/services/mp_service.dart
// (MpService.search) — filtrage texte/prix côté serveur car Firestore ne
// supporte pas la recherche plein texte.
function searchMarketplace({ db }) {
  return {
    name: 'search_marketplace',
    description: 'Recherche des produits sur le Marketplace (Djassa) AZ Express par mot-clé, catégorie et/ou prix maximum.',
    input_schema: {
      type: 'object',
      properties: {
        query:    { type: 'string', description: 'Mot-clé de recherche (titre, marque ou description).' },
        category: { type: 'string', description: 'Catégorie du produit (optionnel).' },
        maxPrice: { type: 'number', description: 'Prix maximum en FCFA (optionnel).' },
      },
    },
    handler: async (_uid, input) => {
      let q = db.collection('marketplace_products').where('status', '==', 'active');
      if (input?.category) {
        q = q.where('category', '==', String(input.category));
      }

      const snap = await q.orderBy('createdAt', 'desc').limit(80).get();
      let results = snap.docs.map(d => ({ id: d.id, ...d.data() }));

      if (input?.query) {
        const needle = String(input.query).toLowerCase().trim();
        results = results.filter(p =>
          String(p.title || '').toLowerCase().includes(needle) ||
          String(p.brand || '').toLowerCase().includes(needle) ||
          String(p.description || '').toLowerCase().includes(needle)
        );
      }
      if (typeof input?.maxPrice === 'number') {
        results = results.filter(p => (p.price ?? Infinity) <= input.maxPrice);
      }

      const trimmed = results.slice(0, RESULT_LIMIT).map(p => ({
        id:        p.id,
        title:     p.title || null,
        price:     p.price ?? null,
        category:  p.category || null,
        condition: p.condition || null,
        city:      p.city || null,
      }));

      return { count: trimmed.length, results: trimmed };
    },
  };
}

// Aucun parcours de commande Marketplace n'existe aujourd'hui côté client
// (audit confirmé : la fiche produit va directement à l'appel/message/WhatsApp,
// pas de panier — voir CLAUDE.md section Marketplace). Ce outil est donc conçu
// à partir du contrat déjà attendu par le trigger `notifySellerOnOrder`
// (functions/index.js) : sellerType='seller', sellerId, un tableau `items`
// (dont seule la longueur est lue par ce trigger) et `budget` comme montant.
function createMarketplaceOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_marketplace_order',
    description: "Achète un produit du Marketplace (Djassa) pour le client. Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        productId:   { type: 'string', description: 'Identifiant du produit Marketplace.' },
        quantity:    { type: 'number', description: 'Quantité souhaitée (défaut 1).' },
        deliveryLat: { type: 'number', description: 'Latitude du point de livraison.' },
        deliveryLng: { type: 'number', description: 'Longitude du point de livraison.' },
        paymentMethod: { type: 'string', enum: ['cash', 'wallet'], description: 'Moyen de paiement.' },
      },
      required: ['productId', 'deliveryLat', 'deliveryLng'],
    },
    handler: async (uid, input, ctx) => {
      const productId = String(input?.productId || '').trim();
      if (!productId) throw new Error('productId manquant.');

      const productSnap = await db.collection('marketplace_products').doc(productId).get();
      if (!productSnap.exists) return { error: 'Produit introuvable.' };
      const product = productSnap.data();
      if (product.status !== 'active') return { error: "Ce produit n'est plus disponible." };

      const quantity = Math.max(1, Math.round(Number(input?.quantity) || 1));
      const budget   = Number(product.price || 0) * quantity;
      if (budget <= 0) return { error: 'Prix du produit invalide.' };

      const deliveryLat = Number(input?.deliveryLat);
      const deliveryLng = Number(input?.deliveryLng);
      const sellerId = String(product.sellerId || '');
      const sellerSnap = sellerId
        ? await db.collection('sellers').doc(sellerId).get()
        : null;
      const pickupLat = Number(sellerSnap?.data()?.lat);
      const pickupLng = Number(sellerSnap?.data()?.lng);
      const geography = await resolveDispatchGeography(db, {
        pickupLat,
        pickupLng,
        deliveryLat,
        deliveryLng,
        pickupCoordinateSource: 'local_place',
        deliveryCoordinateSource: 'gps',
      });

      const paymentMethod = input?.paymentMethod === 'wallet' ? 'wallet' : 'cash';

      if (paymentMethod === 'wallet') {
        const snap = await db.collection('clients').doc(uid).get();
        const balance = (snap.exists ? snap.data().wallet : 0) || 0;
        if (balance < budget) {
          return { error: `Solde wallet insuffisant (${balance} FCFA) pour un total de ${budget} FCFA.` };
        }
      }

      const summaryFr = `Achat : ${quantity}x ${product.title} — ${budget} FCFA (${paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison'}).`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_marketplace_order',
        toolInput: {
          productId, quantity, budget,
          title:      product.title || 'Produit',
          sellerId:   product.sellerId,
          sellerName: product.sellerName || 'Vendeur',
          pickupLat, pickupLng, deliveryLat, deliveryLng, paymentMethod,
          ...geography,
        },
        summaryFr,
        amount: paymentMethod === 'wallet' ? budget : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { productId, quantity, budget, title, sellerId, sellerName,
        pickupLat, pickupLng, deliveryLat, deliveryLng, paymentMethod } = toolInput;

      const productRef  = db.collection('marketplace_products').doc(productId);
      const productSnap = await tx.get(productRef);
      if (!productSnap.exists || productSnap.data().status !== 'active') {
        throw new HttpsError('failed-precondition', "Ce produit n'est plus disponible.");
      }

      if (paymentMethod === 'wallet') {
        const clientRef  = db.collection('clients').doc(uid);
        const sellerRef  = db.collection('sellers').doc(sellerId);
        const clientSnap = await tx.get(clientRef);
        const balance    = (clientSnap.exists ? clientSnap.data().wallet : 0) || 0;
        if (balance < budget) {
          throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cet achat.');
        }
        tx.update(clientRef, { wallet: balance - budget });
        tx.update(sellerRef, { wallet: admin.firestore.FieldValue.increment(budget) });
        tx.set(clientRef.collection('wallet_transactions').doc(), {
          type: 'purchase', amount: budget,
          description: `Achat Marketplace : ${title} (AZ IA, wallet)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(sellerRef.collection('wallet_transactions').doc(), {
          type: 'sale', amount: budget,
          description: `Vente Marketplace : ${title} (AZ IA, wallet)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description: `🛒 ${quantity}x ${title}`,
        budget,
        shoppingBudget: 0,
        items: [{ name: `${quantity}x ${title}`, budgetFcfa: budget }],
        status:      'pending',
        latitude:    pickupLat,
        longitude:   pickupLng,
        destLat:     deliveryLat,
        destLng:     deliveryLng,
        type:        'marketplace',
        clientId:    uid,
        sellerId,
        sellerName,
        sellerType:  'seller',
        paymentMethod,
        isPaid:      paymentMethod === 'wallet',
        source:      'ai_chat',
        pickupCityId: toolInput.pickupCityId,
        pickupZoneId: toolInput.pickupZoneId,
        deliveryCityId: toolInput.deliveryCityId,
        deliveryZoneId: toolInput.deliveryZoneId,
        pickupCoordinateSource: toolInput.pickupCoordinateSource,
        deliveryCoordinateSource: toolInput.deliveryCoordinateSource,
        cityResolutionStatus: toolInput.cityResolutionStatus,
        createdAt:   admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        orderId: orderRef.id,
        lat: pickupLat,
        lng: pickupLng,
        pickupCityId: toolInput.pickupCityId,
        cityResolutionStatus: toolInput.cityResolutionStatus,
        budget,
      };
    },

    afterConfirm: async (uid, result) => {
      const dispatch = await dispatchOrder(db, admin, {
        orderId: result.orderId, lat: result.lat, lng: result.lng,
        pickupCityId: result.pickupCityId,
        cityResolutionStatus: result.cityResolutionStatus,
        budget: result.budget,
      });
      return {
        orderId: result.orderId,
        dispatched: dispatch.dispatched,
        message: dispatch.dispatched
          ? 'Achat confirmé — un livreur a été notifié.'
          : 'Achat confirmé — recherche de livreur en cours.',
      };
    },
  };
}

module.exports = { searchMarketplace, createMarketplaceOrder };
