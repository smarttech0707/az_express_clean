'use strict';

const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin  = require('firebase-admin');
const axios  = require('axios');
const crypto = require('crypto');

admin.initializeApp();
setGlobalOptions({ region: 'europe-west1' });

const db = admin.firestore();

// ── Environnement ───────────────────────────────────────────────────────────
// Créez functions/.env avec :
//   FEEXPAY_TOKEN=votre_token_feexpay
//   FEEXPAY_WEBHOOK_SECRET=votre_secret_webhook
const FEEXPAY_TOKEN          = process.env.FEEXPAY_TOKEN;
const FEEXPAY_WEBHOOK_SECRET = process.env.FEEXPAY_WEBHOOK_SECRET;
const FEEXPAY_API_URL        = 'https://api.feexpay.me';
const PROJECT_ID             = 'az-express-clean';

// Le secret est inclus dans l'URL du webhook → FeexPay le renvoie
// sans avoir à vérifier une signature HMAC (que FeexPay ne supporte pas)
const WEBHOOK_URL = FEEXPAY_WEBHOOK_SECRET
  ? `https://europe-west1-${PROJECT_ID}.cloudfunctions.net/feexPayWebhook?wh_secret=${FEEXPAY_WEBHOOK_SECRET}`
  : `https://europe-west1-${PROJECT_ID}.cloudfunctions.net/feexPayWebhook`;

// ── Collection selon le type d'utilisateur ──────────────────────────────────
function collectionFor(userType) {
  const map = {
    driver:      'livreurs',
    seller:      'sellers',
    restaurant:  'restaurants',
    boulangerie: 'boulangeries',
    pharmacie:   'pharmacies',
  };
  return map[userType] || 'clients';
}

// ── Code opérateur FeexPay ───────────────────────────────────────────────────
function feexpayOperatorCode(operator) {
  const map = {
    mtn:    'MTN_MOMO_CI',
    orange: 'ORANGE_MONEY_CI',
    moov:   'MOOV_MONEY_CI',
    wave:   'WAVE_CI',
  };
  return map[(operator || '').toLowerCase()] || 'MTN_MOMO_CI';
}


// ═══════════════════════════════════════════════════════════════════════════
// 1. INITIER UN PAIEMENT FEEXPAY (Callable Flutter)
// ═══════════════════════════════════════════════════════════════════════════
exports.initiateFeexPayPayment = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }

  const uid = request.auth.uid;
  const { amount, phone, operator, userType } = request.data;

  // ── Validation ────────────────────────────────────────────────────────────
  if (!amount || typeof amount !== 'number' || amount < 100) {
    throw new HttpsError('invalid-argument', 'Montant minimum : 100 FCFA');
  }
  if (!phone || String(phone).trim().length < 8) {
    throw new HttpsError('invalid-argument', 'Numéro de téléphone invalide');
  }

  // ── Créer la transaction pending ─────────────────────────────────────────
  const txRef = db.collection('wallet_transactions').doc();
  const txId  = txRef.id;

  await txRef.set({
    userId:        uid,
    userType:      userType || 'client',
    amount:        amount,
    status:        'pending',
    paymentMethod: operator || 'mtn',
    provider:      'FeexPay',
    phone:         String(phone).trim(),
    createdAt:     admin.firestore.FieldValue.serverTimestamp(),
    validatedAt:   null,
    credited:      false,
  });

  // ── Appel API FeexPay ─────────────────────────────────────────────────────
  let feexpayData;
  try {
    const response = await axios.post(
      `${FEEXPAY_API_URL}/api/v1/request/inline`,
      {
        amount:       amount,
        id:           txId,
        callback:     WEBHOOK_URL,
        description:  'Recharge wallet AZ Express',
        currency:     'XOF',
        pay_in_phone: String(phone).trim(),
        type:         feexpayOperatorCode(operator),
      },
      {
        headers: {
          Authorization:  `Bearer ${FEEXPAY_TOKEN}`,
          'Content-Type': 'application/json',
        },
        timeout: 20000,
      }
    );
    feexpayData = response.data;
  } catch (err) {
    const msg = err.response?.data?.message || err.message;
    await txRef.update({ status: 'error', errorMessage: msg });
    throw new HttpsError('internal', `Erreur FeexPay : ${msg}`);
  }

  await txRef.update({
    feexpayToken: feexpayData.token       || feexpayData.reference  || null,
    feexpayUrl:   feexpayData.url         || feexpayData.payment_url || null,
  });

  return {
    txId:       txId,
    paymentUrl: feexpayData.url || feexpayData.payment_url || null,
    token:      feexpayData.token || null,
    message:    feexpayData.message || 'Paiement initié — vérifiez votre téléphone',
  };
});


// ═══════════════════════════════════════════════════════════════════════════
// 2. WEBHOOK FEEXPAY (HTTP — appelé par FeexPay après paiement)
//    URL à configurer dans le dashboard FeexPay :
//    https://europe-west1-az-express-clean.cloudfunctions.net/feexPayWebhook
// ═══════════════════════════════════════════════════════════════════════════
exports.feexPayWebhook = onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // ── Vérification du token secret dans l'URL ──────────────────────────────
  // FeexPay renvoie l'URL telle quelle → le secret est dans ?wh_secret=
  if (FEEXPAY_WEBHOOK_SECRET) {
    const receivedSecret = req.query.wh_secret;
    if (!receivedSecret || receivedSecret !== FEEXPAY_WEBHOOK_SECRET) {
      console.error('Webhook : token secret invalide ou manquant');
      return res.status(401).json({ error: 'Non autorisé' });
    }
  } else {
    console.warn('⚠️ FEEXPAY_WEBHOOK_SECRET non configuré — webhook non sécurisé');
  }

  const body   = req.body;
  // FeexPay envoie le txId dans "order_id" (= le champ "id" qu'on a passé à l'API)
  const txId   = body.order_id || body.id || body.custom_id || body.reference;
  const status = (body.status || '').toUpperCase();
  const reseau = body.reseau || body.phoneNumber || '';

  console.log(`Webhook FeexPay → txId=${txId} status=${status} reseau=${reseau}`);

  if (!txId) {
    return res.status(400).json({ error: 'ID transaction manquant' });
  }

  const txRef  = db.collection('wallet_transactions').doc(txId);
  const txSnap = await txRef.get();

  if (!txSnap.exists) {
    console.error(`Transaction ${txId} introuvable`);
    return res.status(404).json({ error: 'Transaction introuvable' });
  }

  const tx = txSnap.data();

  // ── Idempotence ───────────────────────────────────────────────────────────
  if (tx.credited === true || tx.status === 'completed') {
    console.log(`Transaction ${txId} déjà traitée — ignorée`);
    return res.status(200).json({ message: 'Déjà traité' });
  }

  // ── Paiement réussi → crédit atomique du wallet ───────────────────────────
  if (['SUCCESSFUL', 'SUCCESS', 'COMPLETED', 'PAID'].includes(status)) {
    try {
      await db.runTransaction(async (firestoreTx) => {
        const colName    = collectionFor(tx.userType);
        const clientRef  = db.collection(colName).doc(tx.userId);
        const clientSnap = await firestoreTx.get(clientRef);

        if (!clientSnap.exists) {
          throw new Error(`Utilisateur ${tx.userId} introuvable`);
        }

        const currentWallet = clientSnap.data().wallet || 0;

        // Crédit wallet
        firestoreTx.update(clientRef, {
          wallet:         currentWallet + tx.amount,
          lastRechargeAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        // Transaction complétée
        firestoreTx.update(txRef, {
          status:            'completed',
          credited:          true,
          validatedAt:       admin.firestore.FieldValue.serverTimestamp(),
          feexpayOperator:   body.reseau          || body.operator || null,
          feexpayPhone:      body.phoneNumber     || null,
          feexpayRef:        body.ref_operator    || body.reference || null,
        });

        // Historique wallet (sous-collection existante)
        const histRef = db.collection(colName).doc(tx.userId)
          .collection('wallet_transactions').doc();
        firestoreTx.set(histRef, {
          type:        'recharge',
          amount:      tx.amount,
          description: `Recharge FeexPay ${(tx.paymentMethod || '').toUpperCase()} — ${tx.amount} FCFA`,
          provider:    'FeexPay',
          txId:        txId,
          createdAt:   admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      console.log(`✅ Wallet crédité : user=${tx.userId} +${tx.amount} FCFA`);
    } catch (err) {
      console.error('Erreur crédit wallet :', err);
      await txRef.update({ status: 'error', errorMessage: err.message });
      return res.status(500).json({ error: 'Erreur crédit wallet' });
    }

  // ── Paiement échoué ou annulé ─────────────────────────────────────────────
  } else if (['FAILED', 'CANCELLED', 'CANCELED', 'REJECTED'].includes(status)) {
    const finalStatus = ['CANCELLED', 'CANCELED'].includes(status) ? 'cancelled' : 'failed';
    await txRef.update({
      status:        finalStatus,
      validatedAt:   admin.firestore.FieldValue.serverTimestamp(),
      failureReason: body.reason     || null,
      feexpayPhone:  body.phoneNumber || null,
    });
    console.log(`Transaction ${txId} → ${finalStatus} (reason: ${body.reason})`);
  }

  return res.status(200).json({ message: 'OK' });
});


// ═══════════════════════════════════════════════════════════════════════════
// 3. INITIER UN RETRAIT FEEXPAY (Callable Flutter)
// ═══════════════════════════════════════════════════════════════════════════
exports.initiateWithdrawal = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }

  const uid = request.auth.uid;
  const { amount, phone, operator, userType, userName } = request.data;

  if (!amount || typeof amount !== 'number' || amount < 500) {
    throw new HttpsError('invalid-argument', 'Montant minimum de retrait : 500 FCFA');
  }
  if (!phone || String(phone).trim().length < 8) {
    throw new HttpsError('invalid-argument', 'Numéro de téléphone invalide');
  }

  const colName  = collectionFor(userType || 'client');
  const withdrawId = `WD_${Date.now()}_${uid.substring(0, 8)}`;

  // ── Déduire le solde atomiquement ──────────────────────────────────────────
  try {
    await db.runTransaction(async (firestoreTx) => {
      const userRef  = db.collection(colName).doc(uid);
      const userSnap = await firestoreTx.get(userRef);

      if (!userSnap.exists) {
        throw new HttpsError('not-found', 'Utilisateur introuvable');
      }

      const balance = userSnap.data().wallet || 0;
      if (balance < amount) {
        throw new HttpsError(
          'failed-precondition',
          `Solde insuffisant. Disponible : ${balance} FCFA`
        );
      }

      firestoreTx.update(userRef, { wallet: balance - amount });

      const wdRef = db.collection('withdrawal_requests').doc(withdrawId);
      firestoreTx.set(wdRef, {
        userId:    uid,
        userType:  userType || 'client',
        userName:  userName || '—',
        amount:    amount,
        phone:     String(phone).trim(),
        operator:  operator || 'mtn',
        status:    'processing',
        provider:  'FeexPay',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const histRef = db.collection(colName).doc(uid)
        .collection('wallet_transactions').doc();
      firestoreTx.set(histRef, {
        type:        'withdrawal',
        amount:      amount,
        description: `Retrait ${(operator || 'MTN').toUpperCase()} → ${String(phone).trim()} — ${amount} FCFA`,
        withdrawId:  withdrawId,
        status:      'processing',
        createdAt:   admin.firestore.FieldValue.serverTimestamp(),
      });
    });
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    throw new HttpsError('internal', `Erreur Firestore : ${err.message}`);
  }

  // ── Appel API FeexPay Payout ───────────────────────────────────────────────
  try {
    const response = await axios.post(
      `${FEEXPAY_API_URL}/api/v1/payout`,
      {
        amount:      amount,
        phone:       String(phone).trim(),
        type:        feexpayOperatorCode(operator),
        id:          withdrawId,
        description: `Retrait AZ Express ${withdrawId}`,
        currency:    'XOF',
      },
      {
        headers: {
          Authorization:  `Bearer ${FEEXPAY_TOKEN}`,
          'Content-Type': 'application/json',
        },
        timeout: 20000,
      }
    );

    const newStatus = response.data?.status === 'SUCCESS' ? 'sent' : 'pending_manual';
    await db.collection('withdrawal_requests').doc(withdrawId).update({
      status:          newStatus,
      feexpayResponse: response.data?.status || null,
    });

    return { withdrawId, status: newStatus, auto: true };
  } catch (err) {
    // Auto échoué → traitement manuel (solde déjà déduit)
    console.warn('FeexPay payout failed, traitement manuel :', err.message);
    await db.collection('withdrawal_requests').doc(withdrawId).update({
      status:    'pending_manual',
      autoError: err.message,
    });
    return { withdrawId, status: 'pending_manual', auto: false };
  }
});


// ═══════════════════════════════════════════════════════════════════════════
// MOTEUR UNIFIÉ DE NOTIFICATIONS AZ EXPRESS
// ═══════════════════════════════════════════════════════════════════════════

// ── Helpers FCM ─────────────────────────────────────────────────────────────

async function sendToToken(token, title, body, data = {}) {
  if (!token) return;
  try {
    await admin.messaging().send({
      token,
      notification: { title, body },
      android: { priority: 'high', notification: { sound: 'default' } },
      apns:    { payload: { aps: { sound: 'default', badge: 1 } } },
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
    });
  } catch (err) {
    console.warn(`FCM failed token ${token?.slice(0, 20)} : ${err.message}`);
  }
}

async function sendToMultipleTokens(tokens, title, body, data = {}) {
  if (!tokens?.length) return;
  const dataStr = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)]));
  try {
    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      android: { priority: 'high', notification: { sound: 'default' } },
      apns:    { payload: { aps: { sound: 'default', badge: 1 } } },
      data:    dataStr,
    });
  } catch (err) {
    console.warn('Multicast FCM error:', err.message);
  }
}

// ── Détection du type de service ─────────────────────────────────────────────
function getServiceType(order) {
  const st = order.sellerType;
  const t  = order.type;
  if (st === 'restaurant')  return 'restaurant';
  if (st === 'boulangerie') return 'boulangerie';
  if (st === 'seller')      return 'marketplace';
  if (t  === 'pharmacie')   return 'pharmacie';
  if (t  === 'courses')     return 'courses';
  return 'livraison';
}

// ── Messages client à la création de commande ─────────────────────────────────
const CLIENT_CREATION_MESSAGES = {
  livraison:   { title: '✅ Commande enregistrée',  body: 'Recherche du meilleur livreur disponible...' },
  courses:     { title: '✅ Demande enregistrée',   body: 'Recherche d\'un coursier disponible...' },
  restaurant:  { title: '✅ Commande reçue',        body: 'Le restaurant a bien reçu votre commande.' },
  pharmacie:   { title: '✅ Ordonnance reçue',      body: 'La pharmacie de garde prépare votre commande.' },
  boulangerie: { title: '✅ Commande reçue',        body: 'La boulangerie a bien reçu votre commande.' },
  marketplace: { title: '✅ Commande envoyée',      body: 'Votre commande a été envoyée au vendeur.' },
};

// ── Messages client par statut et par service ─────────────────────────────────
const CLIENT_STATUS_MESSAGES = {
  livraison: {
    assigned:  { title: '🛵 Livreur trouvé !',                body: 'Un livreur a accepté votre commande et est en route.' },
    broadcast: { title: '📡 Plusieurs livreurs contactés',    body: 'Nous avons contacté plusieurs livreurs disponibles.' },
    accepted:  { title: '🛵 Livreur en route',                body: 'Votre livreur se dirige vers le point de récupération.' },
    picked_up: { title: '📦 Colis récupéré',                  body: 'Votre colis est pris en charge. En route vers vous !' },
    delivered: { title: '✅ Livraison terminée !',            body: 'Votre colis a bien été livré. Merci !' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre commande a été annulée.' },
  },
  courses: {
    assigned:  { title: '🛵 Coursier trouvé !',               body: 'Un coursier a accepté et effectue vos achats.' },
    broadcast: { title: '📡 Plusieurs coursiers contactés',   body: 'Nous avons contacté plusieurs coursiers disponibles.' },
    accepted:  { title: '🛒 Courses en cours',                body: 'Votre coursier effectue vos achats.' },
    picked_up: { title: '🛵 En route vers vous',              body: 'Les achats sont terminés, votre coursier arrive !' },
    delivered: { title: '✅ Courses livrées !',               body: 'Vos courses ont bien été livrées. Merci !' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre demande a été annulée.' },
  },
  restaurant: {
    assigned:  { title: '🛵 Livreur trouvé !',                body: 'Un livreur récupère votre repas au restaurant.' },
    broadcast: { title: '📡 Recherche d\'un livreur',         body: 'Plusieurs livreurs disponibles ont été contactés.' },
    accepted:  { title: '🛵 Livreur en route',                body: 'Votre livreur se dirige vers le restaurant.' },
    picked_up: { title: '🍔 Repas récupéré',                  body: 'Votre repas est en route vers vous !' },
    delivered: { title: '✅ Livraison terminée !',            body: 'Votre repas est arrivé. Bon appétit !' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre commande a été annulée.' },
  },
  pharmacie: {
    assigned:  { title: '🛵 Livreur trouvé !',                body: 'Un livreur récupère vos médicaments.' },
    broadcast: { title: '📡 Recherche d\'un livreur',         body: 'Plusieurs livreurs disponibles ont été contactés.' },
    accepted:  { title: '🛵 Livreur en route',                body: 'Votre livreur se dirige vers la pharmacie.' },
    picked_up: { title: '💊 Médicaments récupérés',           body: 'Vos médicaments sont en route vers vous !' },
    delivered: { title: '✅ Livraison terminée !',            body: 'Vos médicaments sont arrivés. Bonne santé !' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre commande a été annulée.' },
  },
  boulangerie: {
    assigned:  { title: '🛵 Livreur trouvé !',                body: 'Un livreur récupère votre commande à la boulangerie.' },
    broadcast: { title: '📡 Recherche d\'un livreur',         body: 'Plusieurs livreurs disponibles ont été contactés.' },
    accepted:  { title: '🛵 Livreur en route',                body: 'Votre livreur se dirige vers la boulangerie.' },
    picked_up: { title: '🥖 Commande récupérée',              body: 'Votre commande est en route vers vous !' },
    delivered: { title: '✅ Livraison terminée !',            body: 'Votre commande de boulangerie est arrivée.' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre commande a été annulée.' },
  },
  marketplace: {
    assigned:  { title: '🛵 Livreur trouvé !',                body: 'Un livreur récupère votre colis chez le vendeur.' },
    broadcast: { title: '📡 Recherche d\'un livreur',         body: 'Plusieurs livreurs disponibles ont été contactés.' },
    accepted:  { title: '🛵 Livreur en route',                body: 'Votre livreur se dirige vers le vendeur.' },
    picked_up: { title: '📦 Colis récupéré',                  body: 'Votre colis est en route vers vous !' },
    delivered: { title: '✅ Livraison terminée !',            body: 'Votre colis est arrivé. Merci !' },
    cancelled: { title: '❌ Commande annulée',                body: 'Votre commande a été annulée.' },
  },
};

// ─────────────────────────────────────────────────────────────────────────────
// CLIENT — Confirmation immédiate à la création de commande
// Tous services confondus (livraison, courses, restaurant, pharmacie…)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyClientOnOrderCreated = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || !order.clientId) return;

  const clientDoc = await db.collection('clients').doc(order.clientId).get();
  const token     = clientDoc.data()?.fcmToken;
  if (!token) return;

  const svcType = getServiceType(order);
  const notif   = CLIENT_CREATION_MESSAGES[svcType] || CLIENT_CREATION_MESSAGES.livraison;

  await sendToToken(token, notif.title, notif.body, {
    type:    'order_confirmed',
    orderId: event.params.orderId,
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// CLIENT — Suivi complet par statut, messages adaptés au service
// Couvre : assigned, broadcast, accepted, picked_up, delivered, cancelled
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyClientOnOrderUpdate = onDocumentUpdated('orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after || before.status === after.status) return;

  const clientDoc = await db.collection('clients').doc(after.clientId).get();
  const token     = clientDoc.data()?.fcmToken;
  if (!token) return;

  const svcType  = getServiceType(after);
  const messages = CLIENT_STATUS_MESSAGES[svcType] || CLIENT_STATUS_MESSAGES.livraison;
  const notif    = messages[after.status];
  if (!notif) return;

  // Type de notification côté Flutter selon le statut
  const notifType = ['assigned', 'broadcast'].includes(after.status)
    ? 'driver_found'
    : after.status === 'cancelled' ? 'order_cancelled' : 'order_update';

  await sendToToken(token, notif.title, notif.body, {
    type:    notifType,
    orderId: event.params.orderId,
    status:  after.status,
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREURS (broadcast) — FCM push à tous les livreurs ciblés simultanément
// Déclenché quand status → 'broadcast' (transition uniquement)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyBroadcastDrivers = onDocumentUpdated('orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === 'broadcast' || after.status !== 'broadcast') return;

  const driverIds = after.notifiedDriverIds;
  if (!Array.isArray(driverIds) || driverIds.length === 0) return;

  // Récupérer les tokens FCM des livreurs ciblés
  const driverDocs = await Promise.all(
    driverIds.map(id => db.collection('livreurs').doc(id).get())
  );
  const tokens = driverDocs
    .map(d => d.data()?.fcmToken)
    .filter(t => t?.length > 10);
  if (!tokens.length) return;

  const budget  = after.budget ?? 0;
  const desc    = (after.description ?? 'Course').split('\n')[0].substring(0, 40);
  const gain    = Math.max(0, budget - (budget >= 1000 ? 200 : 100));
  const pickup  = after.pickupAddress ? ` · 📍 ${String(after.pickupAddress).substring(0, 30)}` : '';
  const mode    = after.deliveryMode === 'express' ? ' 🚀 EXPRESS' : '';

  await sendToMultipleTokens(tokens,
    `📦 Nouvelle course${mode} !`,
    `${desc}${pickup} · ${budget} FCFA · Gain ${gain} FCFA`,
    { type: 'new_order', orderId: event.params.orderId, budget: String(budget) }
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREUR (assignation directe) — FCM push quand un seul livreur est désigné
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriverOnAssigned = onDocumentUpdated('orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === 'assigned' || after.status !== 'assigned') return;

  const driverId = after.driverId;
  if (!driverId) return;

  const driverDoc = await db.collection('livreurs').doc(driverId).get();
  const token     = driverDoc.data()?.fcmToken;
  if (!token) return;

  const budget  = after.budget ?? 0;
  const desc    = (after.description ?? 'Course').split('\n')[0].substring(0, 40);
  const gain    = Math.max(0, budget - (budget >= 1000 ? 200 : 100));
  const pickup  = after.pickupAddress ? ` · 📍 ${String(after.pickupAddress).substring(0, 30)}` : '';
  const mode    = after.deliveryMode === 'express' ? ' 🚀 EXPRESS' : '';

  await sendToToken(token,
    `📦 Nouvelle course${mode} pour vous !`,
    `${desc}${pickup} · ${budget} FCFA · Gain ${gain} FCFA`,
    { type: 'new_order', orderId: event.params.orderId, budget: String(budget) }
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREUR — Alerte solde bas (< 500 FCFA)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriverLowBalance = onDocumentUpdated('livreurs/{driverId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;

  if ((before.wallet ?? 0) >= 500 && (after.wallet ?? 0) < 500 && after.fcmToken) {
    await sendToToken(after.fcmToken,
      '⚠️ Crédit bas',
      `Votre solde est de ${after.wallet ?? 0} FCFA. Rechargez pour continuer.`,
      { type: 'low_balance', balance: String(after.wallet ?? 0) }
    );
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREUR — Mission terminée (livraison confirmée)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriverOnMissionEnd = onDocumentUpdated('orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === 'delivered' || after.status !== 'delivered') return;

  const driverId = after.driverId;
  if (!driverId) return;

  const driverDoc = await db.collection('livreurs').doc(driverId).get();
  const token     = driverDoc.data()?.fcmToken;
  if (!token) return;

  const budget     = after.budget ?? 0;
  const commission = budget >= 1000 ? 200 : 100;
  const gain       = Math.max(0, budget - commission);

  await sendToToken(token,
    '✅ Mission accomplie !',
    `Livraison confirmée. Gain : +${gain} FCFA crédité sur votre wallet.`,
    { type: 'mission_end', orderId: event.params.orderId }
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREUR — Annulation d'une commande (broadcast, assigné ou accepté)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriverOnOrderCancelled = onDocumentUpdated('orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (after.status !== 'cancelled') return;
  if (!['broadcast', 'assigned', 'accepted', 'picked_up'].includes(before.status)) return;

  const orderId = event.params.orderId;

  // Cas broadcast : notifier tous les livreurs encore dans notifiedDriverIds
  if (before.status === 'broadcast') {
    const driverIds = before.notifiedDriverIds;
    if (Array.isArray(driverIds) && driverIds.length > 0) {
      const driverDocs = await Promise.all(
        driverIds.map(id => db.collection('livreurs').doc(id).get())
      );
      const tokens = driverDocs
        .map(d => d.data()?.fcmToken)
        .filter(t => t?.length > 10);
      if (tokens.length) {
        await sendToMultipleTokens(tokens,
          '❌ Course annulée',
          'La commande que vous étiez en attente d\'accepter a été annulée.',
          { type: 'order_cancelled', orderId }
        );
      }
    }
    return;
  }

  // Cas assigné ou accepté : notifier le livreur désigné
  const driverId = after.driverId || before.driverId;
  if (!driverId) return;
  const driverDoc = await db.collection('livreurs').doc(driverId).get();
  const token     = driverDoc.data()?.fcmToken;
  if (!token) return;

  const msg = ['accepted', 'picked_up'].includes(before.status)
    ? 'La commande que vous aviez acceptée a été annulée.'
    : 'La commande qui vous avait été assignée a été annulée.';

  await sendToToken(token, '❌ Course annulée', msg,
    { type: 'order_cancelled', orderId }
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// PARTENAIRES — Notification à la création de commande
// Restaurant, pharmacie, boulangerie, marketplace — inchangés
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyRestaurantOnOrder = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || order.sellerType !== 'restaurant' || !order.sellerId) return;

  const ownerSnap = await db.collection('restaurant_owners')
    .where('restaurantId', '==', order.sellerId)
    .limit(1).get();

  let token = null;
  if (!ownerSnap.empty) {
    token = ownerSnap.docs[0].data()?.fcmToken;
  }
  if (!token) {
    const restDoc = await db.collection('restaurants').doc(order.sellerId).get();
    token = restDoc.data()?.fcmToken;
  }
  if (!token) return;

  const desc = (order.description ?? 'Commande').substring(0, 60);
  await sendToToken(token,
    '🍽️ Nouvelle commande !',
    `${desc} — ${order.budget ?? 0} FCFA`,
    { type: 'new_seller_order', orderId: event.params.orderId, sellerType: 'restaurant' }
  );
});

exports.notifyPharmacieOnOrder = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || order.type !== 'pharmacie' || !order.pharmacieId) return;

  const pharmDoc = await db.collection('pharmacies').doc(order.pharmacieId).get();
  const token    = pharmDoc.data()?.fcmToken;
  if (!token) return;

  await sendToToken(token,
    '💊 Nouvelle demande de médicaments',
    `Client : ${order.clientName ?? '—'} — ${order.description ?? ''}`.substring(0, 80),
    { type: 'new_pharmacie_order', orderId: event.params.orderId }
  );
});

exports.notifyBoulangerieOnNewOrder = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || order.sellerType !== 'boulangerie' || !order.sellerId) return;

  const doc   = await db.collection('boulangeries').doc(order.sellerId).get();
  const token = doc.data()?.fcmToken;
  if (!token) return;

  const count  = (order.items ?? []).length;
  const amount = order.itemsAmount ?? 0;
  const time   = order.requestedTime ? `pour ${order.requestedTime}` : 'maintenant';
  await sendToToken(token,
    '🥐 Nouvelle commande !',
    `${count} article(s) — ${amount} FCFA — Livraison ${time}`,
    { type: 'new_boulangerie_order', orderId: event.params.orderId }
  );
});

exports.notifySellerOnOrder = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || order.sellerType !== 'seller' || !order.sellerId) return;

  const sellerDoc = await db.collection('sellers').doc(order.sellerId).get();
  const token     = sellerDoc.data()?.fcmToken;
  if (!token) return;

  const count  = (order.items ?? []).length;
  const amount = order.itemsAmount ?? order.budget ?? 0;
  const desc   = count > 0
    ? `${count} article(s) — ${amount} FCFA`
    : `${(order.description ?? 'Commande').substring(0, 50)} — ${amount} FCFA`;

  await sendToToken(token,
    '🛍️ Nouvelle commande !',
    `${desc}. Préparez le colis avant l\'arrivée du livreur.`,
    { type: 'new_seller_order', orderId: event.params.orderId, sellerType: 'seller' }
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREURS GÉNÉRAUX — Alerte sur nouvelles courses de livraison directe
// Exclut les commandes partenaires (restaurant/boulangerie/pharmacie/marketplace)
// car celles-ci passent par notifyDriverOnAssigned / notifyBroadcastDrivers
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriversOnNewOrder = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || (order.status && order.status !== 'pending')) return;

  // Ignorer les commandes qui vont à un partenaire spécifique
  const partnerOrder =
    order.sellerType === 'restaurant'  ||
    order.sellerType === 'boulangerie' ||
    order.sellerType === 'seller'      ||
    order.type       === 'pharmacie';
  if (partnerOrder) return;

  const snapshot = await db.collection('livreurs').where('isOnline', '==', true).get();
  const tokens   = snapshot.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
  if (!tokens.length) return;

  const budget = order.budget ?? 0;
  const desc   = (order.description ?? 'Livraison').substring(0, 60);
  await sendToMultipleTokens(tokens,
    '🛵 Nouvelle course disponible !',
    `${desc} — ${budget} FCFA`,
    { type: 'new_order', orderId: event.params.orderId, budget: String(budget) }
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// E-KBINE — Moteur de notifications dédié
// Collections : ekbine_orders (clientId, agentId), ekbine_agents (fcmToken)
// ═══════════════════════════════════════════════════════════════════════════

// Messages client Ekbine par statut
const EK_CLIENT_MESSAGES = {
  assigned:         { title: '👤 Agent trouvé !',          body: 'Un agent a pris en charge votre demande.' },
  awaiting_deposit: { title: '💰 Dépôt requis',            body: 'Votre agent attend votre dépôt pour démarrer.' },
  in_progress:      { title: '⏳ Traitement en cours',     body: 'Votre agent traite votre dossier.' },
  proof_sent:       { title: '📄 Justificatif envoyé',     body: 'Votre agent a envoyé le justificatif. Vérifiez.' },
  completed:        { title: '✅ Transaction terminée',    body: 'Votre demande E-Kbine a été complétée avec succès.' },
  cancelled:        { title: '❌ Demande annulée',         body: 'Votre demande E-Kbine a été annulée.' },
  disputed:         { title: '⚠️ Litige ouvert',           body: 'Un litige a été signalé sur votre dossier.' },
};

// ─── Client — Confirmation à la création ────────────────────────────────────
exports.notifyEkClientOnOrderCreated = onDocumentCreated('ekbine_orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || !order.clientId) return;

  const clientDoc = await db.collection('clients').doc(order.clientId).get();
  const token     = clientDoc.data()?.fcmToken;
  if (!token) return;

  const service = order.serviceName ?? order.serviceType ?? 'E-Kbine';
  await sendToToken(token,
    '✅ Demande enregistrée',
    `Votre demande ${service} a bien été reçue. Recherche d\'un agent disponible...`,
    { type: 'ek_update', orderId: event.params.orderId, status: 'pending' }
  );
});

// ─── Client — Suivi par statut ───────────────────────────────────────────────
exports.notifyEkClientOnStatusChange = onDocumentUpdated('ekbine_orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after || before.status === after.status) return;
  if (!after.clientId) return;

  const notif = EK_CLIENT_MESSAGES[after.status];
  if (!notif) return;

  const clientDoc = await db.collection('clients').doc(after.clientId).get();
  const token     = clientDoc.data()?.fcmToken;
  if (!token) return;

  await sendToToken(token, notif.title, notif.body, {
    type:    'ek_update',
    orderId: event.params.orderId,
    status:  after.status,
  });
});

// ─── Agents disponibles — Nouvelle demande E-Kbine ──────────────────────────
exports.notifyEkAgentsOnNewOrder = onDocumentCreated('ekbine_orders/{orderId}', async (event) => {
  const order = event.data.data();
  if (!order || order.status !== 'pending') return;

  // Chercher les agents actifs (subscriptionActive ou trialActive)
  const agentsSnap = await db.collection('ekbine_agents')
    .where('isActive', '==', true)
    .get();

  const tokens = agentsSnap.docs
    .map(d => d.data().fcmToken)
    .filter(t => t?.length > 10);
  if (!tokens.length) return;

  const service = order.serviceName ?? order.serviceType ?? 'transaction';
  const amount  = order.amount ?? order.totalPaid ?? 0;

  await sendToMultipleTokens(tokens,
    '📋 Nouvelle demande E-Kbine',
    `${service}${amount ? ` — ${amount} FCFA` : ''}. Acceptez pour prendre en charge.`,
    { type: 'ek_new_order', orderId: event.params.orderId }
  );
});

// ─── Agent — Confirmation d'assignation ─────────────────────────────────────
exports.notifyEkAgentOnAssigned = onDocumentUpdated('ekbine_orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === 'assigned' || !['assigned', 'awaiting_deposit'].includes(after.status)) return;

  const agentId = after.agentId;
  if (!agentId) return;

  const agentDoc = await db.collection('ekbine_agents').doc(agentId).get();
  const token    = agentDoc.data()?.fcmToken;
  if (!token) return;

  const service = after.serviceName ?? after.serviceType ?? 'E-Kbine';
  await sendToToken(token,
    '✅ Demande acceptée',
    `Vous avez pris en charge la demande ${service}. Commencez le traitement.`,
    { type: 'ek_new_order', orderId: event.params.orderId }
  );
});

// ─── Agent — Mission Ekbine terminée ────────────────────────────────────────
exports.notifyEkAgentOnCompleted = onDocumentUpdated('ekbine_orders/{orderId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after) return;
  if (before.status === 'completed' || after.status !== 'completed') return;

  const agentId = after.agentId;
  if (!agentId) return;

  const agentDoc = await db.collection('ekbine_agents').doc(agentId).get();
  const token    = agentDoc.data()?.fcmToken;
  if (!token) return;

  const earning = after.agentEarning ?? 0;
  await sendToToken(token,
    '✅ Mission accomplie !',
    `Transaction E-Kbine complétée.${earning ? ` Gain : +${earning} FCFA.` : ''}`,
    { type: 'mission_end', orderId: event.params.orderId }
  );
});


// ═══════════════════════════════════════════════════════════════════════════
// 4. RÉINITIALISATION MOT DE PASSE / PIN (Callable Flutter)
//    Appelé depuis GenericForgotPasswordPage après vérification OTP
// ═══════════════════════════════════════════════════════════════════════════
exports.resetAccountPassword = onCall(async (request) => {
  // Le caller doit être authentifié via vérification téléphonique (OTP)
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentification requise');
  }
  const callerPhone = request.auth.token.phone_number;
  if (!callerPhone) {
    throw new HttpsError('unauthenticated', 'Vérification téléphonique requise');
  }

  const { userType, phone, newValue } = request.data;
  if (!userType || !phone || !newValue) {
    throw new HttpsError('invalid-argument', 'Paramètres manquants');
  }
  if (String(newValue).length < 4) {
    throw new HttpsError('invalid-argument', 'Valeur trop courte (minimum 4 caractères)');
  }

  // Normaliser le numéro ivoirien vers E.164 pour comparer avec le token
  const normalizeCI = (p) => {
    const digits = String(p).replace(/\D/g, '');
    if (digits.startsWith('225') && digits.length >= 11) return `+${digits}`;
    if (digits.length === 10 && digits.startsWith('0')) return `+225${digits.slice(1)}`;
    if (digits.length === 10) return `+225${digits}`;
    if (digits.length === 8) return `+225${digits}`;
    return `+${digits}`;
  };

  const normalizedInput  = normalizeCI(phone);
  // callerPhone est déjà en E.164 depuis Firebase Auth (OTP vérifié)
  if (normalizedInput !== callerPhone) {
    throw new HttpsError('permission-denied', 'Numéro de téléphone non vérifié');
  }

  // ── Pharmacie → mise à jour champ password en Firestore ─────────────────
  if (userType === 'pharmacie') {
    let snap = await db.collection('pharmacies').where('phone', '==', phone).limit(1).get();
    if (snap.empty) {
      snap = await db.collection('pharmacies').where('phone', '==', normalizedInput).limit(1).get();
    }
    if (snap.empty) throw new HttpsError('not-found', 'Pharmacie introuvable');
    await snap.docs[0].reference.update({ password: String(newValue), mustChangePassword: false });
    return { success: true };
  }

  // ── Artisan → mise à jour artisanPin en Firestore ────────────────────────
  if (userType === 'artisan') {
    let snap = await db.collection('service_providers').where('phone', '==', phone).limit(1).get();
    if (snap.empty) {
      snap = await db.collection('service_providers').where('phone', '==', normalizedInput).limit(1).get();
    }
    if (snap.empty) throw new HttpsError('not-found', 'Compte artisan introuvable');
    await snap.docs[0].reference.update({ artisanPin: String(newValue) });
    return { success: true };
  }

  // ── Firebase Auth types : UID = document ID dans Firestore ───────────────
  // Chercher par téléphone → obtenir l'UID → Admin SDK updateUser
  const colMap = {
    fleet:       'fleet_owners',
    seller:      'sellers',
    restaurant:  'restaurant_owners',
    boulangerie: 'boulangeries',
  };
  const colName = colMap[userType];
  if (!colName) throw new HttpsError('invalid-argument', `Type invalide : ${userType}`);

  let snap = await db.collection(colName).where('phone', '==', phone).limit(1).get();
  if (snap.empty) {
    snap = await db.collection(colName).where('phone', '==', normalizedInput).limit(1).get();
  }
  if (snap.empty) throw new HttpsError('not-found', 'Compte introuvable');

  const uid = snap.docs[0].id; // document ID = Firebase Auth UID
  await admin.auth().updateUser(uid, { password: String(newValue) });
  return { success: true };
});


// ═══════════════════════════════════════════════════════════════════════════
// 5. GESTION DES SOUS-ADMINS (super admin seulement)
// ═══════════════════════════════════════════════════════════════════════════

exports.createSubAdmin = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Non authentifié');

  const callerDoc = await db.collection('admins').doc(request.auth.uid).get();
  if (!callerDoc.exists || callerDoc.data().role !== 'super') {
    throw new HttpsError('permission-denied', 'Réservé à l\'admin principal');
  }

  const { name, email, password, phone, permissions } = request.data;
  if (!name || !email || !password) {
    throw new HttpsError('invalid-argument', 'Champs name, email, password requis');
  }

  const userRecord = await admin.auth().createUser({ email, password });

  await db.collection('admins').doc(userRecord.uid).set({
    name,
    email,
    phone:       phone || '',
    role:        'sub',
    permissions: permissions || [],
    isActive:    true,
    createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    createdBy:   request.auth.uid,
  });

  return { uid: userRecord.uid };
});

exports.deleteSubAdmin = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Non authentifié');

  const callerDoc = await db.collection('admins').doc(request.auth.uid).get();
  if (!callerDoc.exists || callerDoc.data().role !== 'super') {
    throw new HttpsError('permission-denied', 'Réservé à l\'admin principal');
  }

  const { uid } = request.data;
  if (!uid) throw new HttpsError('invalid-argument', 'uid manquant');
  if (uid === request.auth.uid) {
    throw new HttpsError('invalid-argument', 'Impossible de supprimer son propre compte');
  }

  await admin.auth().deleteUser(uid);
  await db.collection('admins').doc(uid).delete();

  return { success: true };
});

// ─── Notify admins on new driver registration ────────────────────────────────
exports.notifyAdminsOnNewDriver = onDocumentCreated('livreurs/{driverId}', async (event) => {
  const driver = event.data.data();
  if (!driver) return;
  const snap = await db.collection('admins').where('isActive', '!=', false).get();
  const tokens = snap.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
  if (!tokens.length) return;
  await sendToMultipleTokens(tokens,
    '🛵 Nouvelle demande livreur',
    `${driver.name ?? 'Nouveau livreur'} vient de s'inscrire. Vérifiez sa demande.`,
    { type: 'admin_new_driver', driverId: event.params.driverId }
  );
});

// ─── Notify admins on new service provider pending request ───────────────────
exports.notifyAdminsOnNewServiceProvider = onDocumentCreated('service_providers/{id}', async (event) => {
  const provider = event.data.data();
  if (!provider || provider.status !== 'pending') return;
  const snap = await db.collection('admins').where('isActive', '!=', false).get();
  const tokens = snap.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
  if (!tokens.length) return;
  await sendToMultipleTokens(tokens,
    '🏪 Nouveau prestataire en attente',
    `${provider.name ?? 'Un prestataire'} (${provider.subcategory ?? ''}) attend votre approbation.`,
    { type: 'admin_new_service_provider', providerId: event.params.id }
  );
});

// ═══════════════════════════════════════════════════════════════════════════

exports.notifyClientOnRecharge = onDocumentUpdated('recharge_requests/{reqId}', async (event) => {
  const before = event.data.before.data();
  const after  = event.data.after.data();
  if (!before || !after || before.status === after.status || after.status !== 'approved') return;

  const clientDoc = await db.collection('clients').doc(after.userId).get();
  const token     = clientDoc.data()?.fcmToken;
  if (!token) return;

  await sendToToken(token,
    '💰 Recharge confirmée',
    `${after.amount ?? 0} FCFA ont été crédités sur votre wallet AZ Express.`,
    { type: 'recharge', amount: String(after.amount ?? 0) }
  );
});
