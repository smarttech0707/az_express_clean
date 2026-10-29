'use strict';
const {assertNewAccountActivity}=require('../../accountAdmission');

const { createPendingAction } = require('../pendingActions');
const { dispatchOrder, resolveDispatchGeography } = require('../../dispatch');
const tarifService = require('../../tarifService');
const { buildAmounts } = require('../../orderAmounts');
const { getBillingMode } = require('../../billingPolicy');
const { getLegacyPartnerPolicy } = require('../../legacyPartnerPolicy');

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
      const productAmount = Number(product.price || 0) * quantity;
      if (!Number.isSafeInteger(productAmount) || productAmount <= 0) {
        return { error: 'Prix du produit invalide.' };
      }

      const deliveryLat = Number(input?.deliveryLat);
      const deliveryLng = Number(input?.deliveryLng);
      if (!Number.isFinite(deliveryLat) || !Number.isFinite(deliveryLng)) {
        return { error: 'Coordonnées du point de livraison manquantes.' };
      }

      // Coupe-circuit config/billing = 'legacy' : facturation historique (produits
      // seuls). Sinon le texte de confirmation (summaryFr, produit par le serveur
      // et affiché par toutes les versions de l'application) présente le total
      // exact qui sera débité.
      const explicit = (await getBillingMode(db)) !== 'legacy';
      // Mode historique : course sans frais encaissés, donc sans rémunération
      // possible du livreur — refusée tant que la politique n'est pas 'no_commission'.
      if (!explicit && (await getLegacyPartnerPolicy(db)) === 'block') {
        return { error: 'Les commandes Marketplace sont momentanément indisponibles.' };
      }
      let amounts = null;
      if (explicit) {
        // Frais de livraison : barème unique (standard), jamais fourni par le modèle.
        const tarif = tarifService.compute({ clientLat: deliveryLat, clientLng: deliveryLng });
        if (!tarif.canOrder) {
          return { error: tarif.rejectionMessage || 'Livraison non disponible pour cette adresse à cette heure.' };
        }
        amounts = buildAmounts(productAmount, tarif.standardPrice);
      }
      const totalToPay = amounts ? amounts.totalAmount : productAmount;
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
        if (balance < totalToPay) {
          return { error: `Solde wallet insuffisant (${balance} FCFA) pour un total de ${totalToPay} FCFA.` };
        }
      }

      const payLabel = paymentMethod === 'wallet' ? 'wallet' : 'cash à la livraison';
      const summaryFr = amounts
        ? `Achat : ${quantity}x ${product.title} — produits ${amounts.productAmount} FCFA + livraison ${amounts.deliveryFee} FCFA = total ${amounts.totalAmount} FCFA (${payLabel}).`
        : `Achat : ${quantity}x ${product.title} — ${productAmount} FCFA (${payLabel}).`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName: 'create_marketplace_order',
        toolInput: {
          productId, quantity, ...(amounts || { budget: productAmount }),
          title:      product.title || 'Produit',
          sellerId:   product.sellerId,
          sellerName: product.sellerName || 'Vendeur',
          pickupLat, pickupLng, deliveryLat, deliveryLng, paymentMethod,
          ...geography,
        },
        summaryFr,
        amount: paymentMethod === 'wallet' ? totalToPay : null,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { productId, quantity, title, sellerId, sellerName,
        pickupLat, pickupLng, deliveryLat, deliveryLng, paymentMethod } = toolInput;
      // Montants relus de l'action confirmée et revalidés : jamais d'incohérence
      // possible entre ce qui a été affiché et ce qui est débité. Une action en
      // attente créée avant l'introduction des frais (ou en mode 'legacy') ne
      // porte que `budget` : facturation historique, produits seuls.
      const isLegacy = toolInput.productAmount == null && toolInput.deliveryFee == null;
      let amounts = null;
      let budget;
      if (isLegacy) {
        budget = toolInput.budget;
        if (!Number.isSafeInteger(budget) || budget <= 0) {
          throw new HttpsError('failed-precondition', 'Montant de la commande invalide.');
        }
      } else {
        try {
          amounts = buildAmounts(toolInput.productAmount, toolInput.deliveryFee);
        } catch (_) {
          throw new HttpsError('failed-precondition', 'Montants de la commande incohérents.');
        }
        if (amounts.totalAmount !== toolInput.totalAmount) {
          throw new HttpsError('failed-precondition', 'Montants de la commande incohérents.');
        }
      }
      const chargeTotal = amounts ? amounts.totalAmount : budget;
      const sellerCredit = amounts ? amounts.productAmount : budget;
      await assertNewAccountActivity(tx,db,HttpsError,uid,[['sellers',sellerId]]);

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
        if (balance < chargeTotal) {
          throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cet achat.');
        }
        // Le client règle produits + livraison ; le vendeur reçoit les produits
        // seuls, les frais restent en attente pour le livreur (crédités à la
        // livraison par deliverOrderCF).
        tx.update(clientRef, { wallet: balance - chargeTotal });
        tx.update(sellerRef, { wallet: admin.firestore.FieldValue.increment(sellerCredit) });
        tx.set(clientRef.collection('wallet_transactions').doc(), {
          type: 'purchase', amount: chargeTotal,
          description: amounts
            ? `Achat Marketplace : ${title} — produits ${amounts.productAmount} + livraison ${amounts.deliveryFee} (AZ IA, wallet)`
            : `Achat Marketplace : ${title} (AZ IA, wallet)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(sellerRef.collection('wallet_transactions').doc(), {
          type: 'sale', amount: sellerCredit,
          description: `Vente Marketplace : ${title} (AZ IA, wallet)`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const orderRef = db.collection('orders').doc();
      tx.set(orderRef, {
        description: `🛒 ${quantity}x ${title}`,
        ...(amounts
          ? { ...amounts, itemsAmount: amounts.productAmount, deliveryFeePaid: paymentMethod === 'wallet' }
          : { budget }),
        shoppingBudget: 0,
        items: [{ name: `${quantity}x ${title}`, budgetFcfa: sellerCredit }],
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
        budget: amounts ? amounts.budget : budget,
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
