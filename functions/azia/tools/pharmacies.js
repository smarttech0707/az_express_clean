'use strict';

const { createPendingAction } = require('../pendingActions');
const { dispatchOrder } = require('../../dispatch');
const tarifService = require('../../tarifService');

const RESULT_LIMIT = 10;

// Reprend le filtrage de lib/screens/client/pharmacie_garde.dart (isOnDuty) —
// nécessaire pour qu'AZ IA puisse répondre à « trouve une pharmacie ouverte »
// sans connaître déjà un id de pharmacie.
function searchPharmacies({ db }) {
  return {
    name: 'search_pharmacies',
    description: "Recherche des pharmacies par nom ou par disponibilité (pharmacies de garde actuellement ouvertes).",
    input_schema: {
      type: 'object',
      properties: {
        query:    { type: 'string', description: 'Nom de la pharmacie (optionnel).' },
        openOnly: { type: 'boolean', description: 'Ne retourner que les pharmacies de garde actuellement ouvertes.' },
      },
    },
    handler: async (_uid, input) => {
      const snap = await db.collection('pharmacies').limit(200).get();
      let results = snap.docs.map(d => ({ id: d.id, ...d.data() }));

      if (input?.openOnly) {
        results = results.filter(p => p.isOnDuty === true);
      }
      if (input?.query) {
        const needle = String(input.query).toLowerCase();
        results = results.filter(p => String(p.name || '').toLowerCase().includes(needle));
      }

      const trimmed = results.slice(0, RESULT_LIMIT).map(p => ({
        id:       p.id,
        name:     p.name || null,
        address:  p.address || null,
        isOnDuty: p.isOnDuty === true,
      }));

      return { count: trimmed.length, results: trimmed };
    },
  };
}

// Reprend le contrat de lib/screens/client/pharmacie_garde.dart (type='pharmacie',
// pharmacieId/pharmacieName, budget=frais de livraison uniquement — pas de
// catalogue produit, demande en texte libre) et son comportement de paiement
// exact : au paiement wallet, seul le client est débité (la pharmacie n'est
// PAS créditée à la création, contrairement au restaurant — comportement
// existant reproduit tel quel, pas une omission de cet outil). Le prix n'est
// plus fourni par le modèle (Master Prompt 51) : calculé côté serveur via
// `tarifService.compute()` (source unique de vérité tarifaire), exactement
// comme le ferait pharmacie_garde.dart pour la même destination.
function createPharmacieOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_pharmacie_order',
    description: "Crée une demande de livraison de médicaments depuis une pharmacie pour le client. Le prix est calculé automatiquement selon la distance et l'heure — ne jamais demander ou proposer un montant. Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        pharmacieId: { type: 'string', description: 'Identifiant de la pharmacie.' },
        description: { type: 'string', description: 'Description des médicaments demandés.' },
        deliveryLat: { type: 'number', description: 'Latitude du point de livraison.' },
        deliveryLng: { type: 'number', description: 'Longitude du point de livraison.' },
        paymentMethod: { type: 'string', enum: ['cash', 'wallet'], description: 'Moyen de paiement des frais de livraison.' },
      },
      required: ['pharmacieId', 'description', 'deliveryLat', 'deliveryLng'],
    },
    handler: async (uid, input, ctx) => {
      const pharmacieId = String(input?.pharmacieId || '').trim();
      if (!pharmacieId) throw new Error('pharmacieId manquant.');

      const pharmacieSnap = await db.collection('pharmacies').doc(pharmacieId).get();
      if (!pharmacieSnap.exists) return { error: 'Pharmacie introuvable.' };
      const pharmacieName = pharmacieSnap.data().name || 'Pharmacie';

      const description = String(input?.description || '').trim();
      if (!description) throw new Error('La description des médicaments est requise.');

      const deliveryLat = Number(input?.deliveryLat);
      const deliveryLng = Number(input?.deliveryLng);
      if (!deliveryLat || !deliveryLng) throw new Error('Coordonnées de livraison manquantes.');

      const paymentMethod = input?.paymentMethod === 'wallet' ? 'wallet' : 'cash';

      const tarif = tarifService.compute({ clientLat: deliveryLat, clientLng: deliveryLng });
      if (!tarif.canOrder) {
        return { error: tarif.rejectionMessage || 'Livraison non disponible pour cette adresse à cette heure.' };
      }
      const budget = tarif.standardPrice;

      if (paymentMethod === 'wallet') {
        const snap = await db.collection('clients').doc(uid).get();
        const balance = (snap.exists ? snap.data().wallet : 0) || 0;
        if (balance < budget) {
          return { error: `Solde wallet insuffisant (${balance} FCFA) pour des frais de ${budget} FCFA.` };
        }
      }

      const summaryFr = `Livraison pharmacie ${pharmacieName} : "${description}" — ${budget} FCFA (${paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison'}).`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_pharmacie_order',
        toolInput: { pharmacieId, pharmacieName, description, budget, deliveryLat, deliveryLng, paymentMethod },
        summaryFr,
        amount: paymentMethod === 'wallet' ? budget : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { pharmacieId, pharmacieName, description, budget, deliveryLat, deliveryLng, paymentMethod } = toolInput;

      if (paymentMethod === 'wallet') {
        const clientRef  = db.collection('clients').doc(uid);
        const clientSnap = await tx.get(clientRef);
        const balance    = (clientSnap.exists ? clientSnap.data().wallet : 0) || 0;
        if (balance < budget) {
          throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cette livraison.');
        }
        tx.update(clientRef, { wallet: balance - budget });
        tx.set(clientRef.collection('wallet_transactions').doc(), {
          type: 'debit', amount: budget,
          description: `Livraison pharmacie : ${pharmacieName} (AZ IA)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description:    `Livraison pharmacie : ${description}`,
        budget,
        shoppingBudget: 0,
        status:         'pending',
        isPaid:         paymentMethod === 'wallet',
        type:           'pharmacie',
        pharmacieId,
        pharmacieName,
        latitude:       deliveryLat,
        longitude:      deliveryLng,
        deliveryLatitude:  deliveryLat,
        deliveryLongitude: deliveryLng,
        clientId:       uid,
        paymentMethod,
        source:         'ai_chat',
        createdAt:      admin.firestore.FieldValue.serverTimestamp(),
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
          ? 'Demande envoyée à la pharmacie — un livreur a été notifié.'
          : 'Demande envoyée à la pharmacie — recherche de livreur en cours.',
      };
    },
  };
}

module.exports = { searchPharmacies, createPharmacieOrder };
