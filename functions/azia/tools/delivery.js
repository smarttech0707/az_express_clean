'use strict';

const { createPendingAction } = require('../pendingActions');
const { dispatchOrder, calculateCommission } = require('../../dispatch');

const MIN_DELIVERY_FEE = 500;
const MAX_DELIVERY_FEE = 10000;
const MIN_SHOPPING_BUDGET = 500;
const MAX_ITEMS = 20;
const CANCELLABLE_STATUSES = ['pending', 'broadcast', 'assigned', 'accepted', 'picked_up'];

function sanitizeOrder(id, data) {
  return {
    id,
    type:            data.type || null,
    status:          data.status || null,
    description:     data.description || null,
    budget:          data.budget ?? null,
    deliveryAddress: data.deliveryAddress || null,
    pickupAddress:   data.pickupAddress || null,
    driverId:        data.driverId || null,
    createdAt:       data.createdAt ? data.createdAt.toDate().toISOString() : null,
  };
}

function trackOrder({ db }) {
  return {
    name: 'track_order',
    description: "Récupère le statut d'une commande (livraison, courses, restaurant, pharmacie ou marketplace) du client. Si aucun orderId n'est fourni, retourne ses commandes les plus récentes.",
    input_schema: {
      type: 'object',
      properties: {
        orderId: {
          type: 'string',
          description: "Identifiant de la commande (optionnel — si absent, renvoie les commandes récentes du client).",
        },
      },
    },
    handler: async (uid, input) => {
      const orderId = input?.orderId;

      if (orderId) {
        const snap = await db.collection('orders').doc(String(orderId)).get();
        if (!snap.exists) {
          return { found: false, message: 'Commande introuvable.' };
        }
        const data = snap.data();
        if (data.clientId !== uid) {
          return { found: false, message: 'Commande introuvable.' };
        }
        return { found: true, orders: [sanitizeOrder(snap.id, data)] };
      }

      const snap = await db.collection('orders')
        .where('clientId', '==', uid)
        .orderBy('createdAt', 'desc')
        .limit(5)
        .get();

      const orders = snap.docs.map(d => sanitizeOrder(d.id, d.data()));
      return { found: orders.length > 0, orders };
    },
  };
}

// Débite le wallet (si paiement wallet) et crée la commande dans la même
// transaction — le dispatch (recherche de livreur) n'est PAS transactionnel
// (comme côté Dart) et se fait dans afterConfirm, après coup.
async function debitWalletIfNeeded(tx, db, admin, HttpsError, uid, amount, paymentMethod) {
  if (paymentMethod !== 'wallet') return;
  const clientRef = db.collection('clients').doc(uid);
  const snap = await tx.get(clientRef);
  const balance = (snap.exists ? snap.data().wallet : 0) || 0;
  if (balance < amount) {
    throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cette commande.');
  }
  tx.update(clientRef, { wallet: balance - amount });
  const histRef = clientRef.collection('wallet_transactions').doc();
  tx.set(histRef, {
    type:        'payment',
    amount,
    description: 'Frais de livraison (AZ IA)',
    createdAt:   admin.firestore.FieldValue.serverTimestamp(),
  });
}

// Créer une livraison de colis/document — reprend le contrat de données de
// lib/screens/client/create_order.dart (type='shopping', budget=frais de
// livraison, mêmes bornes 500-10000 FCFA, même logique de débit wallet).
function createDeliveryOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_delivery_order',
    description: "Crée une livraison de colis/document pour le client (ex. « envoie ce colis à Cafétou »). Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        description:     { type: 'string', description: 'Description du colis/document à livrer.' },
        budget:          { type: 'number', description: 'Frais de livraison en FCFA (entre 500 et 10000).' },
        deliveryLat:      { type: 'number', description: 'Latitude du point de livraison.' },
        deliveryLng:      { type: 'number', description: 'Longitude du point de livraison.' },
        deliveryAddress: { type: 'string', description: 'Adresse ou repère du point de livraison.' },
        pickupAddress:   { type: 'string', description: 'Adresse ou repère du point de collecte (optionnel).' },
        forSelf:         { type: 'boolean', description: 'true si la livraison est pour le client lui-même.' },
        recipientName:   { type: 'string', description: 'Nom du destinataire (si ce n\'est pas le client).' },
        recipientPhone:  { type: 'string', description: 'Téléphone du destinataire (si ce n\'est pas le client).' },
        deliveryMode:    { type: 'string', enum: ['standard', 'express'], description: 'Mode de livraison.' },
        paymentMethod:   { type: 'string', enum: ['cash', 'wallet'], description: 'Moyen de paiement des frais de livraison.' },
      },
      required: ['description', 'budget', 'deliveryLat', 'deliveryLng'],
    },
    handler: async (uid, input, ctx) => {
      const description = String(input?.description || '').trim();
      if (!description) throw new Error('La description du colis est requise.');

      const budget = Number(input?.budget);
      if (!budget || budget < MIN_DELIVERY_FEE) throw new Error(`Frais de livraison minimum : ${MIN_DELIVERY_FEE} FCFA`);
      if (budget > MAX_DELIVERY_FEE) throw new Error(`Frais de livraison maximum : ${MAX_DELIVERY_FEE} FCFA`);

      const deliveryLat = Number(input?.deliveryLat);
      const deliveryLng = Number(input?.deliveryLng);
      if (!deliveryLat || !deliveryLng) throw new Error('Coordonnées du point de livraison manquantes.');

      const paymentMethod = input?.paymentMethod === 'wallet' ? 'wallet' : 'cash';
      const deliveryMode  = input?.deliveryMode === 'express' ? 'express' : 'standard';
      const forSelf       = input?.forSelf !== false;

      if (paymentMethod === 'wallet') {
        const snap = await db.collection('clients').doc(uid).get();
        const balance = (snap.exists ? snap.data().wallet : 0) || 0;
        if (balance < budget) {
          return { error: `Solde wallet insuffisant (${balance} FCFA) pour des frais de ${budget} FCFA.` };
        }
      }

      const summaryFr = `Livraison "${description}" — ${budget} FCFA (${paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison'}, ${deliveryMode}).`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_delivery_order',
        toolInput: {
          description, budget, deliveryLat, deliveryLng,
          deliveryAddress: input?.deliveryAddress || null,
          pickupAddress:   input?.pickupAddress || null,
          forSelf,
          recipientName:  input?.recipientName || null,
          recipientPhone: input?.recipientPhone || null,
          deliveryMode,
          paymentMethod,
        },
        summaryFr,
        amount: paymentMethod === 'wallet' ? budget : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const {
        description, budget, deliveryLat, deliveryLng, deliveryAddress, pickupAddress,
        forSelf, recipientName, recipientPhone, deliveryMode, paymentMethod,
      } = toolInput;

      await debitWalletIfNeeded(tx, db, admin, HttpsError, uid, budget, paymentMethod);

      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description,
        budget,
        shoppingBudget: 0,
        status:         'pending',
        latitude:       deliveryLat,
        longitude:      deliveryLng,
        deliveryLatitude:  deliveryLat,
        deliveryLongitude: deliveryLng,
        type:           'shopping',
        clientId:       uid,
        paymentMethod,
        isPaid:         paymentMethod === 'wallet',
        forSelf,
        deliveryMode,
        source:         'ai_chat',
        createdAt:      admin.firestore.FieldValue.serverTimestamp(),
        ...(deliveryAddress  ? { deliveryAddress } : {}),
        ...(pickupAddress    ? { pickupAddress } : {}),
        ...(recipientName    ? { recipientName } : {}),
        ...(recipientPhone   ? { recipientPhone } : {}),
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
          ? 'Commande créée — un livreur a été notifié.'
          : 'Commande créée — recherche de livreur en cours.',
      };
    },
  };
}

// Créer une commande courses itemisée ("100f de tomates, 200f de piment...")
// — reprend le contrat de lib/screens/client/courses_libres.dart (type='shopping',
// budget = montant total incluant livraison) mais ajoute le champ additif
// `items[]` défini dans le plan AZ IA (budget = somme des items si fournis).
function createShoppingOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_shopping_order',
    description: "Crée une commande de courses itemisée pour le client (ex. « achète 100f de tomates, 200f de piment »). Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          description: 'Liste des articles à acheter, avec le budget alloué par article en FCFA.',
          items: {
            type: 'object',
            properties: {
              name:       { type: 'string', description: "Nom de l'article (ex. tomates)." },
              budgetFcfa: { type: 'number', description: 'Budget alloué pour cet article en FCFA.' },
            },
            required: ['name', 'budgetFcfa'],
          },
        },
        deliveryLat: { type: 'number', description: 'Latitude du point de livraison du client.' },
        deliveryLng: { type: 'number', description: 'Longitude du point de livraison du client.' },
        paymentMethod: { type: 'string', enum: ['cash', 'wallet'], description: 'Moyen de paiement.' },
      },
      required: ['items', 'deliveryLat', 'deliveryLng'],
    },
    handler: async (uid, input, ctx) => {
      const items = Array.isArray(input?.items) ? input.items : [];
      if (items.length === 0) throw new Error('La liste des articles est vide.');
      if (items.length > MAX_ITEMS) throw new Error(`Trop d'articles (maximum ${MAX_ITEMS}).`);

      const cleanItems = items.map(it => ({
        name: String(it?.name || '').trim(),
        budgetFcfa: Math.max(0, Math.round(Number(it?.budgetFcfa) || 0)),
      }));
      if (cleanItems.some(it => !it.name || it.budgetFcfa <= 0)) {
        throw new Error('Chaque article doit avoir un nom et un budget positif.');
      }

      const budget = cleanItems.reduce((sum, it) => sum + it.budgetFcfa, 0);
      if (budget < MIN_SHOPPING_BUDGET) {
        throw new Error(`Budget total minimum : ${MIN_SHOPPING_BUDGET} FCFA (frais de livraison inclus).`);
      }

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

      const itemsSummary = cleanItems.map(it => `${it.name} (${it.budgetFcfa} FCFA)`).join(', ');
      const summaryFr = `Courses : ${itemsSummary} — total ${budget} FCFA (${paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison'}).`;

      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_shopping_order',
        toolInput: { items: cleanItems, budget, deliveryLat, deliveryLng, paymentMethod },
        summaryFr,
        amount: paymentMethod === 'wallet' ? budget : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { items, budget, deliveryLat, deliveryLng, paymentMethod } = toolInput;

      await debitWalletIfNeeded(tx, db, admin, HttpsError, uid, budget, paymentMethod);

      const description = items.map(it => `${it.name} (${it.budgetFcfa} FCFA)`).join(', ');
      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description,
        budget,
        shoppingBudget: 0,
        items,
        status:      'pending',
        latitude:    deliveryLat,
        longitude:   deliveryLng,
        deliveryLatitude:  deliveryLat,
        deliveryLongitude: deliveryLng,
        type:        'shopping',
        clientId:    uid,
        paymentMethod,
        isPaid:      paymentMethod === 'wallet',
        forSelf:     true,
        deliveryMode: 'standard',
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
          ? 'Course créée — un livreur a été notifié.'
          : 'Course créée — recherche de livreur en cours.',
      };
    },
  };
}

// Annuler une commande — reprend exactement les règles de remboursement de
// FirestoreService.cancelOrder() (lib/services/firestore_service.dart) :
// remboursement wallet client si paiement wallet, remboursement commission
// livreur si déjà acceptée/récupérée. Tout se fait dans une seule transaction
// (plus strict que l'original, qui logge l'historique après coup).
function cancelOrder({ db, admin, HttpsError }) {
  return {
    name: 'cancel_order',
    description: "Annule une commande du client (livraison, courses, etc.). Nécessite une confirmation explicite.",
    input_schema: {
      type: 'object',
      properties: {
        orderId: { type: 'string', description: 'Identifiant de la commande à annuler.' },
      },
      required: ['orderId'],
    },
    handler: async (uid, input, ctx) => {
      const orderId = String(input?.orderId || '').trim();
      if (!orderId) throw new Error('orderId manquant.');

      const snap = await db.collection('orders').doc(orderId).get();
      if (!snap.exists) return { error: 'Commande introuvable.' };
      const data = snap.data();
      if (data.clientId !== uid) return { error: 'Commande introuvable.' };
      if (!CANCELLABLE_STATUSES.includes(data.status)) {
        return { error: `Cette commande ne peut plus être annulée (statut actuel : ${data.status}).` };
      }

      const summaryFr = `Annuler la commande "${data.description || orderId}" (${data.budget || 0} FCFA).`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'cancel_order',
        toolInput: { orderId },
        summaryFr,
        amount: null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const orderRef = db.collection('orders').doc(toolInput.orderId);
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable.');
      const data = orderSnap.data();
      if (data.clientId !== uid) throw new HttpsError('permission-denied', 'Non autorisé.');
      if (!CANCELLABLE_STATUSES.includes(data.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande ne peut plus être annulée.');
      }

      const originalStatus = data.status;
      const paymentMethod  = data.paymentMethod;
      const budget         = Number(data.budget || 0);
      const shoppingBudget = Number(data.shoppingBudget || 0);
      const clientId       = data.clientId;
      const driverId       = data.driverId;

      const needsClientRefund = paymentMethod === 'wallet' && !!clientId;
      const needsDriverRefund = ['accepted', 'picked_up'].includes(originalStatus) && !!driverId;

      let clientSnap = null;
      let driverSnap = null;
      if (needsClientRefund) clientSnap = await tx.get(db.collection('clients').doc(clientId));
      if (needsDriverRefund) driverSnap = await tx.get(db.collection('livreurs').doc(driverId));

      tx.update(orderRef, {
        status:      'cancelled',
        cancelReason: 'ai_client_cancel',
        cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      let refundAmount = 0;
      if (needsClientRefund) {
        refundAmount = budget + shoppingBudget;
        if (refundAmount > 0 && clientSnap && clientSnap.exists) {
          const w = Number(clientSnap.data().wallet || 0);
          tx.update(db.collection('clients').doc(clientId), { wallet: w + refundAmount });
          tx.set(db.collection('clients').doc(clientId).collection('wallet_transactions').doc(), {
            type:        'refund',
            amount:      refundAmount,
            description: 'Remboursement annulation commande (AZ IA)',
            orderId:     toolInput.orderId,
            createdAt:   admin.firestore.FieldValue.serverTimestamp(),
          });
        }
      }

      let commissionRefund = 0;
      if (needsDriverRefund && driverSnap && driverSnap.exists) {
        commissionRefund = await calculateCommission(db, budget);
        const w = Number(driverSnap.data().wallet || 0);
        tx.update(db.collection('livreurs').doc(driverId), { wallet: w + commissionRefund });
        tx.set(db.collection('livreurs').doc(driverId).collection('wallet_transactions').doc(), {
          type:        'refund',
          amount:      commissionRefund,
          description: 'Remboursement commission — commande annulée (AZ IA)',
          orderId:     toolInput.orderId,
          createdAt:   admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      return { orderId: toolInput.orderId, refundAmount, commissionRefund };
    },
  };
}

module.exports = { trackOrder, createDeliveryOrder, createShoppingOrder, cancelOrder };
