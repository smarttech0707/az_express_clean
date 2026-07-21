'use strict';

const { createPendingAction } = require('../pendingActions');

const VALID_OPERATORS = ['orange', 'mtn', 'moov', 'wave'];
const VALID_PAYMENT_METHODS = ['wallet', 'orange_money', 'mtn_momo', 'wave'];

function sanitizeEkOrder(id, data) {
  return {
    id,
    operator:     data.operator || null,
    serviceLabel: data.serviceLabel || null,
    amount:       data.amount ?? null,
    status:       data.status || null,
    agentId:      data.agentId || null,
    createdAt:    data.createdAt ? data.createdAt.toDate().toISOString() : null,
  };
}

// ── Suivi d'une commande E-Kbine (lecture seule, gap réel — Master Prompt
// 113 section 11 : « AZ IA doit pouvoir suivre la commande, contacter un
// agent »). Même contrat que track_order (delivery.js), scopé à
// ekbine_orders/agents.
function trackEkbineOrder({ db }) {
  return {
    name: 'track_ekbine_order',
    description: "Récupère le statut d'une commande E-Kbine (transfert Mobile Money via agent) du client, avec le contact de l'agent assigné si disponible. Si aucun orderId n'est fourni, retourne les commandes E-Kbine récentes du client.",
    input_schema: {
      type: 'object',
      properties: {
        orderId: { type: 'string', description: 'Identifiant de la commande E-Kbine (optionnel).' },
      },
    },
    handler: async (uid, input) => {
      if (input?.orderId) {
        const snap = await db.collection('ekbine_orders').doc(String(input.orderId)).get();
        if (!snap.exists || snap.data().clientId !== uid) {
          return { found: false, message: 'Commande E-Kbine introuvable.' };
        }
        const data = snap.data();
        let agentContact = null;
        if (data.agentId) {
          const agentSnap = await db.collection('ekbine_agents').doc(data.agentId).get();
          if (agentSnap.exists) {
            agentContact = { name: agentSnap.data().name || null, phone: agentSnap.data().phone || null };
          }
        }
        return { found: true, orders: [sanitizeEkOrder(snap.id, data)], agentContact };
      }

      const snap = await db.collection('ekbine_orders')
        .where('clientId', '==', uid)
        .orderBy('createdAt', 'desc')
        .limit(5)
        .get();
      return { found: !snap.empty, orders: snap.docs.map(d => sanitizeEkOrder(d.id, d.data())) };
    },
  };
}

// ── Création de commande E-Kbine — reprend le contrat exact de
// lib/ekbine/providers/ek_provider.dart:placeOrder() (fee=0, agentEarning=
// amount si wallet sinon 0, débit wallet AVANT création de la commande, même
// que le débit et la création se fassent dans la même transaction ici côté
// serveur plutôt qu'en deux étapes séparées côté client). Financier →
// confirmation explicite obligatoire, même mécanisme que
// initiate_wallet_recharge/create_delivery_order.
function createEkbineOrder({ db, admin, HttpsError }) {
  return {
    name: 'create_ekbine_order',
    description: "Prépare une commande E-Kbine (transfert Mobile Money via un agent AZ Express — crédit, transfert, dépôt/retrait Mobile Money). Nécessite une confirmation explicite avant toute création réelle.",
    input_schema: {
      type: 'object',
      properties: {
        operator:          { type: 'string', enum: VALID_OPERATORS, description: 'Opérateur Mobile Money concerné.' },
        serviceId:         { type: 'string', description: "Identifiant du service (ex: 'credit', 'transfer', 'momo_deposit', 'momo_withdrawal')." },
        serviceLabel:      { type: 'string', description: 'Libellé lisible du service (ex: "Dépôt Orange Money").' },
        beneficiaryNumber: { type: 'string', description: 'Numéro Mobile Money bénéficiaire de l\'opération.' },
        amount:            { type: 'number', description: 'Montant de l\'opération en FCFA.' },
        paymentMethod:     { type: 'string', enum: VALID_PAYMENT_METHODS, description: 'Moyen de paiement du client pour cette commande.' },
      },
      required: ['operator', 'serviceId', 'serviceLabel', 'beneficiaryNumber', 'amount', 'paymentMethod'],
    },
    handler: async (uid, input, ctx) => {
      const operator = VALID_OPERATORS.includes(String(input?.operator || '').toLowerCase())
        ? String(input.operator).toLowerCase() : null;
      if (!operator) throw new Error('Opérateur invalide (orange, mtn, moov ou wave)');

      const paymentMethod = VALID_PAYMENT_METHODS.includes(String(input?.paymentMethod || ''))
        ? String(input.paymentMethod) : null;
      if (!paymentMethod) throw new Error('Moyen de paiement invalide');

      const amount = Number(input?.amount);
      if (!amount || amount < 100) throw new Error('Montant minimum : 100 FCFA');

      const beneficiaryNumber = String(input?.beneficiaryNumber || '').trim();
      if (!beneficiaryNumber) throw new Error('Numéro bénéficiaire manquant');

      const serviceId = String(input?.serviceId || '').trim();
      const serviceLabel = String(input?.serviceLabel || '').trim();
      if (!serviceId || !serviceLabel) throw new Error('Service manquant');

      // Si paiement wallet, vérifie le solde en lecture seule ici (le vrai
      // débit a lieu dans confirmHandler, dans une transaction) — évite de
      // créer une action en attente qui échouerait de toute façon.
      if (paymentMethod === 'wallet') {
        const clientSnap = await db.collection('clients').doc(uid).get();
        const balance = clientSnap.exists ? (clientSnap.data().wallet || 0) : 0;
        if (balance < amount) throw new Error('Solde wallet insuffisant pour cette commande.');
      }

      const summaryFr = `${serviceLabel} de ${amount} FCFA (${operator.toUpperCase()}) vers ${beneficiaryNumber}, payé via ${paymentMethod === 'wallet' ? 'votre wallet AZ Express' : paymentMethod}.`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName:       'create_ekbine_order',
        toolInput:      { operator, serviceId, serviceLabel, beneficiaryNumber, amount, paymentMethod },
        summaryFr,
        amount,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    confirmHandler: async (tx, uid, toolInput) => {
      const { operator, serviceId, serviceLabel, beneficiaryNumber, amount, paymentMethod } = toolInput;
      const fee = 0; // Pas de frais sur les commandes E-Kbine (project_ekbine_no_fee) — l'agent gagne sur sa marge opérateur.
      const totalPaid = amount;
      const agentEarning = paymentMethod === 'wallet' ? amount : 0;

      // Toutes les lectures d'abord — Firestore exige qu'aucune écriture ne
      // précède une lecture dans une même transaction. Bug réel trouvé le
      // 2026-07-20 (audit module E-Kbine) : le second tx.get() (pour
      // clientName/clientPhone) était exécuté après tx.update()/tx.set() du
      // bloc wallet, levant "Firestore transactions require all reads to be
      // executed before all writes" — cassait à 100% toute commande E-Kbine
      // payée par wallet (même famille que le bug payOrderFromWalletCF,
      // Module Wallet). Un seul tx.get() désormais, réutilisé pour le solde
      // ET la dénormalisation nom/téléphone.
      const clientRef  = db.collection('clients').doc(uid);
      const clientSnap = await tx.get(clientRef);
      const clientData = clientSnap.exists ? clientSnap.data() : {};

      if (paymentMethod === 'wallet') {
        const balance = clientData.wallet || 0;
        if (balance < totalPaid) {
          throw new HttpsError('failed-precondition', 'Solde wallet insuffisant pour cette commande.');
        }
        tx.update(clientRef, { wallet: balance - totalPaid });
        const histRef = clientRef.collection('wallet_transactions').doc();
        tx.set(histRef, {
          type:        'payment',
          amount:      -totalPaid,
          description: `${serviceLabel} E-Kbine (AZ IA)`,
          createdAt:   admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const orderRef = db.collection('ekbine_orders').doc();
      tx.set(orderRef, {
        clientId:          uid,
        clientName:        clientData.name || null,
        clientPhone:       clientData.phone || null,
        operator,
        serviceId,
        serviceLabel,
        beneficiaryNumber,
        amount,
        fee,
        totalPaid,
        agentEarning,
        paymentMethod,
        status:            'pending',
        source:            'ai_chat',
        createdAt:         admin.firestore.FieldValue.serverTimestamp(),
      });

      return { orderId: orderRef.id, amount, operator, serviceLabel };
    },

    // Aucune étape post-transaction nécessaire — contrairement à la recharge
    // wallet (qui doit appeler FeexPay après coup), une commande E-Kbine est
    // simplement mise en attente d'un agent (déjà géré par l'écoute
    // streamPendingForAgent côté app agent, aucun appel externe requis ici).
    afterConfirm: async (uid, result) => {
      return {
        orderId: result.orderId,
        message: `Commande E-Kbine créée (${result.serviceLabel}, ${result.amount} FCFA). Un agent va la prendre en charge sous peu.`,
      };
    },
  };
}

module.exports = { trackEkbineOrder, createEkbineOrder };
