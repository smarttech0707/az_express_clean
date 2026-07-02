'use strict';

const { createPendingAction } = require('../pendingActions');
const { dispatchOrder } = require('../../dispatch');

const MAX_ITEMS = 30;
const RESULT_LIMIT = 10;

// Reprend le filtrage de lib/screens/restaurant/restaurant_list.dart :
// subscriptionStatus != 'suspended' exclut les restaurants suspendus, VIP
// (vipStatus === 'active') affichés en premier — nécessaire pour qu'AZ IA
// puisse répondre à « trouve-moi un restaurant » sans connaître déjà un id.
function searchRestaurants({ db }) {
  return {
    name: 'search_restaurants',
    description: "Recherche des restaurants par nom, catégorie de cuisine ou disponibilité (ouvert maintenant).",
    input_schema: {
      type: 'object',
      properties: {
        query:    { type: 'string', description: 'Nom ou mot-clé de cuisine (ex. "poulet", "pizza").' },
        category: { type: 'string', description: 'Catégorie de cuisine (optionnel, ex. "Ivoirien", "Fast food").' },
        openOnly: { type: 'boolean', description: 'Ne retourner que les restaurants actuellement ouverts.' },
      },
    },
    handler: async (_uid, input) => {
      const snap = await db.collection('restaurants').limit(200).get();
      let results = snap.docs
        .map(d => ({ id: d.id, ...d.data() }))
        .filter(r => r.subscriptionStatus !== 'suspended');

      if (input?.openOnly) {
        results = results.filter(r => r.isOpen !== false);
      }
      if (input?.category) {
        const needle = String(input.category).toLowerCase();
        results = results.filter(r => String(r.category || '').toLowerCase().includes(needle));
      }
      if (input?.query) {
        const needle = String(input.query).toLowerCase();
        results = results.filter(r =>
          String(r.name || '').toLowerCase().includes(needle) ||
          String(r.category || '').toLowerCase().includes(needle)
        );
      }

      results.sort((a, b) => (b.vipStatus === 'active' ? 1 : 0) - (a.vipStatus === 'active' ? 1 : 0));

      const trimmed = results.slice(0, RESULT_LIMIT).map(r => ({
        id:       r.id,
        name:     r.name || null,
        category: r.category || null,
        address:  r.address || null,
        isOpen:   r.isOpen !== false,
        isVip:    r.vipStatus === 'active',
      }));

      return { count: trimmed.length, results: trimmed };
    },
  };
}

// Reprend le contrat de lib/screens/restaurant/restaurant_menu.dart
// (type='restaurant', sellerType='restaurant', sellerId=restaurantId,
// description préfixée "🍽️") — avec deux corrections volontaires par
// rapport à l'écran existant : (1) l'écran fixe latitude/longitude à 0 pour
// toutes les commandes restaurant (jamais la vraie position de livraison),
// ce qui casserait le dispatch ; (2) le chemin paiement wallet de l'écran
// n'appelle jamais findNearestDriver() (oubli apparent). Cet outil utilise
// de vraies coordonnées et dispatche systématiquement, quel que soit le
// moyen de paiement.
function createRestaurantOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_restaurant_order',
    description: "Crée une commande dans un restaurant pour le client. Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        restaurantId: { type: 'string', description: 'Identifiant du restaurant.' },
        items: {
          type: 'array',
          description: 'Articles commandés.',
          items: {
            type: 'object',
            properties: {
              name:     { type: 'string', description: "Nom du plat/article." },
              price:    { type: 'number', description: 'Prix unitaire en FCFA.' },
              quantity: { type: 'number', description: 'Quantité (défaut 1).' },
            },
            required: ['name', 'price'],
          },
        },
        deliveryLat: { type: 'number', description: 'Latitude du point de livraison.' },
        deliveryLng: { type: 'number', description: 'Longitude du point de livraison.' },
        paymentMethod: { type: 'string', enum: ['cash', 'wallet'], description: 'Moyen de paiement.' },
      },
      required: ['restaurantId', 'items', 'deliveryLat', 'deliveryLng'],
    },
    handler: async (uid, input, ctx) => {
      const restaurantId = String(input?.restaurantId || '').trim();
      if (!restaurantId) throw new Error('restaurantId manquant.');

      const restaurantSnap = await db.collection('restaurants').doc(restaurantId).get();
      if (!restaurantSnap.exists) return { error: 'Restaurant introuvable.' };
      const restaurantName = restaurantSnap.data().name || restaurantSnap.data().restaurantName || 'Restaurant';

      const rawItems = Array.isArray(input?.items) ? input.items : [];
      if (rawItems.length === 0) throw new Error('La liste des articles est vide.');
      if (rawItems.length > MAX_ITEMS) throw new Error(`Trop d'articles (maximum ${MAX_ITEMS}).`);

      const cleanItems = rawItems.map(it => ({
        name:     String(it?.name || '').trim(),
        price:    Math.max(0, Math.round(Number(it?.price) || 0)),
        quantity: Math.max(1, Math.round(Number(it?.quantity) || 1)),
      }));
      if (cleanItems.some(it => !it.name || it.price <= 0)) {
        throw new Error('Chaque article doit avoir un nom et un prix positif.');
      }

      const budget = cleanItems.reduce((sum, it) => sum + it.price * it.quantity, 0);
      if (budget <= 0) throw new Error('Le total de la commande doit être positif.');

      const deliveryLat = Number(input?.deliveryLat);
      const deliveryLng = Number(input?.deliveryLng);
      if (!deliveryLat || !deliveryLng) throw new Error('Coordonnées de livraison manquantes.');

      const paymentMethod = input?.paymentMethod === 'wallet' ? 'wallet' : 'cash';

      if (paymentMethod === 'wallet') {
        const snap = await db.collection('clients').doc(uid).get();
        const balance = (snap.exists ? snap.data().wallet : 0) || 0;
        if (balance < budget) {
          return { error: `Solde wallet insuffisant (${balance} FCFA) pour un total de ${budget} FCFA.` };
        }
      }

      const itemsDesc = cleanItems.map(it => `${it.quantity}x ${it.name} (${it.price * it.quantity} FCFA)`).join(', ');
      const summaryFr = `Commande chez ${restaurantName} : ${itemsDesc} — total ${budget} FCFA (${paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison'}).`;

      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_restaurant_order',
        toolInput: {
          restaurantId, restaurantName, items: cleanItems, budget,
          deliveryLat, deliveryLng, paymentMethod,
        },
        summaryFr,
        amount: paymentMethod === 'wallet' ? budget : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { restaurantId, restaurantName, items, budget, deliveryLat, deliveryLng, paymentMethod } = toolInput;

      if (paymentMethod === 'wallet') {
        const clientRef     = db.collection('clients').doc(uid);
        const restaurantRef = db.collection('restaurants').doc(restaurantId);
        const clientSnap    = await tx.get(clientRef);
        const balance       = (clientSnap.exists ? clientSnap.data().wallet : 0) || 0;
        if (balance < budget) {
          throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cette commande.');
        }
        tx.update(clientRef, { wallet: balance - budget });
        tx.update(restaurantRef, { wallet: admin.firestore.FieldValue.increment(budget) });
        tx.set(clientRef.collection('wallet_transactions').doc(), {
          type: 'purchase', amount: budget,
          description: `Commande ${restaurantName} (AZ IA, wallet)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(restaurantRef.collection('wallet_transactions').doc(), {
          type: 'sale', amount: budget,
          description: `Commande client (AZ IA, wallet) — ${budget} FCFA`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const description = `🍽️ ${restaurantName} : ${items.map(it => `${it.quantity}x ${it.name} (${it.price * it.quantity} FCFA)`).join(', ')}`;
      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description,
        budget,
        shoppingBudget: 0,
        items: items.map(it => ({ name: `${it.quantity}x ${it.name}`, budgetFcfa: it.price * it.quantity })),
        status:      'pending',
        latitude:    deliveryLat,
        longitude:   deliveryLng,
        deliveryLatitude:  deliveryLat,
        deliveryLongitude: deliveryLng,
        type:        'restaurant',
        clientId:    uid,
        sellerId:    restaurantId,
        sellerName:  restaurantName,
        sellerType:  'restaurant',
        paymentMethod,
        isPaid:      paymentMethod === 'wallet',
        source:      'ai_chat',
        createdAt:   admin.firestore.FieldValue.serverTimestamp(),
      });

      return { orderId: orderRef.id, lat: deliveryLat, lng: deliveryLng, budget };
    },

    afterConfirm: async (uid, result) => {
      const dispatch = await dispatchOrder(db, admin, {
        orderId: result.orderId, lat: result.lat, lng: result.lng, budget: result.budget,
      });
      return {
        orderId: result.orderId,
        dispatched: dispatch.dispatched,
        message: dispatch.dispatched
          ? 'Commande envoyée au restaurant — un livreur a été notifié.'
          : 'Commande envoyée au restaurant — recherche de livreur en cours.',
      };
    },
  };
}

module.exports = { searchRestaurants, createRestaurantOrder };
