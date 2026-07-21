'use strict';

const { createPendingAction } = require('../pendingActions');

const VALID_OPERATORS = ['mtn', 'orange', 'moov', 'wave'];

function getWalletBalance({ db }) {
  return {
    name: 'get_wallet_balance',
    description: 'Consulte le solde actuel du wallet AZ Express du client.',
    input_schema: {
      type: 'object',
      properties: {},
    },
    handler: async (uid) => {
      const snap = await db.collection('clients').doc(uid).get();
      const balanceFcfa = snap.exists ? (snap.data().wallet ?? 0) : 0;
      return { balanceFcfa };
    },
  };
}

// Lecture seule — comble un manque réel (Master Prompt 113, section 4) :
// AZ IA pouvait consulter le solde mais pas l'historique, ni donc expliquer
// pourquoi un paiement a été refusé ou vérifier qu'un remboursement a bien
// eu lieu. Sous-collection déjà utilisée par client_wallet_page.dart —
// mêmes 5 derniers mouvements, pas une nouvelle source de données.
function getWalletTransactions({ db }) {
  return {
    name: 'get_wallet_transactions',
    description: "Consulte les derniers mouvements du wallet du client (paiements, recharges, remboursements, débits) — utile pour expliquer un paiement refusé ou vérifier qu'un remboursement a bien été crédité.",
    input_schema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Nombre de mouvements à retourner (5 par défaut, 20 maximum).' },
      },
    },
    handler: async (uid, input) => {
      const limit = Math.min(Math.max(Number(input?.limit) || 5, 1), 20);
      const snap = await db.collection('clients').doc(uid)
        .collection('wallet_transactions')
        .orderBy('createdAt', 'desc')
        .limit(limit)
        .get();
      const transactions = snap.docs.map(d => {
        const t = d.data();
        return {
          type:        t.type || null,
          amount:      t.amount ?? null,
          description: t.description || null,
          orderId:     t.orderId || null,
          provider:    t.provider || null,
          createdAt:   t.createdAt ? t.createdAt.toDate().toISOString() : null,
        };
      });
      return { transactions };
    },
  };
}

// Réutilise exactement la validation (montant, téléphone, anti-doublon) et le
// flux Firestore/FeexPay de `initiateFeexPayPayment` (functions/index.js) —
// seule la couche « confirmation AZ IA » est nouvelle. Ce outil ne déclenche
// jamais le paiement directement : il crée une ai_pending_actions et attend
// une confirmation explicite, exécutée via aiConfirmAction.
function initiateWalletRecharge({ db, admin, checkRateLimit, axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL }) {
  return {
    name: 'initiate_wallet_recharge',
    description: "Prépare une recharge du wallet AZ Express via Mobile Money (MTN, Orange, Moov, Wave). Nécessite une confirmation explicite de l'utilisateur avant tout paiement réel.",
    input_schema: {
      type: 'object',
      properties: {
        amount:   { type: 'number', description: 'Montant à recharger en FCFA (entre 100 et 500 000).' },
        phone:    { type: 'string', description: 'Numéro de téléphone Mobile Money du client.' },
        operator: { type: 'string', enum: VALID_OPERATORS, description: 'Opérateur Mobile Money.' },
      },
      required: ['amount', 'phone', 'operator'],
    },
    handler: async (uid, input, ctx) => {
      const amount = Number(input?.amount);
      if (!amount || amount < 100) throw new Error('Montant minimum : 100 FCFA');
      if (amount > 500000) throw new Error('Montant maximum : 500 000 FCFA');

      const phone = String(input?.phone || '').trim();
      if (!phone || !/^\+?\d{8,15}$/.test(phone)) throw new Error('Numéro de téléphone invalide');

      const operator = VALID_OPERATORS.includes(String(input?.operator || '').toLowerCase())
        ? String(input.operator).toLowerCase()
        : null;
      if (!operator) throw new Error('Opérateur Mobile Money invalide (mtn, orange, moov ou wave)');

      // Même compteur que le flux de paiement classique (initiateFeexPayPayment)
      // — AZ IA ne doit pas offrir un moyen de contourner cette limite.
      await checkRateLimit(uid, 'payment', 5, 60);

      const pendingSnap = await db.collection('wallet_transactions')
        .where('userId', '==', uid)
        .where('status', '==', 'pending')
        .limit(1)
        .get();
      if (!pendingSnap.empty) {
        throw new Error('Un paiement est déjà en cours. Attendez sa confirmation.');
      }

      const summaryFr = `Recharger le wallet de ${amount} FCFA via ${operator.toUpperCase()} au ${phone}.`;
      const actionId = await createPendingAction(db, admin, {
        uid,
        conversationId: ctx?.conversationId,
        toolName:       'initiate_wallet_recharge',
        toolInput:      { amount, phone, operator },
        summaryFr,
        amount,
      });

      return { status: 'awaiting_confirmation', actionId, summaryFr };
    },

    // Exécuté dans la même transaction que la bascule de statut de l'action
    // en attente — se limite au travail Firestore (jamais d'appel réseau
    // externe dans une transaction, qui peut être retentée par le SDK).
    confirmHandler: async (tx, uid, toolInput) => {
      const { amount, phone, operator } = toolInput;
      const txRef = db.collection('wallet_transactions').doc();
      tx.set(txRef, {
        userId:        uid,
        userType:      'client',
        amount,
        status:        'pending',
        paymentMethod: operator,
        provider:      'FeexPay',
        phone,
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
        validatedAt:   null,
        credited:      false,
        source:        'ai_chat',
      });
      return { txId: txRef.id, amount, phone, operator };
    },

    // Étape post-transaction : l'appel FeexPay ne doit jamais s'exécuter à
    // l'intérieur d'une transaction Firestore — même découpage que
    // initiateFeexPayPayment (écriture Firestore d'abord, puis appel externe).
    afterConfirm: async (uid, result) => {
      const { txId, amount, phone, operator } = result;
      const txRef = db.collection('wallet_transactions').doc(txId);

      try {
        const response = await axios.post(
          `${FEEXPAY_API_URL}/api/v1/request/inline`,
          {
            amount,
            id:           txId,
            callback:     WEBHOOK_URL,
            description:  'Recharge wallet AZ Express (AZ IA)',
            currency:     'XOF',
            pay_in_phone: phone,
            type:         feexpayOperatorCode(operator),
          },
          {
            headers: { Authorization: `Bearer ${FEEXPAY_TOKEN}`, 'Content-Type': 'application/json' },
            timeout: 20000,
          }
        );
        const data = response.data;
        await txRef.update({
          feexpayToken: data.token || data.reference || null,
          feexpayUrl:   data.url || data.payment_url || null,
        });
        return {
          txId,
          paymentUrl: data.url || data.payment_url || null,
          message:    data.message || 'Paiement initié — vérifiez votre téléphone.',
        };
      } catch (err) {
        const msg = err.response?.data?.message || err.message;
        await txRef.update({ status: 'error', errorMessage: msg });
        return { txId, error: `Erreur FeexPay : ${msg}` };
      }
    },
  };
}

module.exports = { getWalletBalance, getWalletTransactions, initiateWalletRecharge };
