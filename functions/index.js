'use strict';

const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin  = require('firebase-admin');
const axios  = require('axios');

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

// ── Rate Limiting ────────────────────────────────────────────────────────────
async function checkRateLimit(uid, action, maxRequests, windowSeconds) {
  const now         = Date.now();
  const windowStart = now - windowSeconds * 1000;
  const key         = `${uid}_${action}`;
  const ref         = db.collection('rate_limits').doc(key);

  await db.runTransaction(async (tx) => {
    const snap   = await tx.get(ref);
    const data   = snap.exists ? snap.data() : { requests: [] };
    const recent = (data.requests || []).filter(t => t > windowStart);
    if (recent.length >= maxRequests) {
      throw new HttpsError('resource-exhausted', 'Trop de tentatives. Veuillez réessayer plus tard.');
    }
    recent.push(now);
    // Safety cap: array is already bounded by maxRequests, but trim defensively
    const bounded = recent.length > 100 ? recent.slice(-100) : recent;
    tx.set(ref, {
      requests:   bounded,
      updatedAt:  admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

// ── Audit Logs ───────────────────────────────────────────────────────────────
async function logAudit(details) {
  try {
    await db.collection('audit_logs').add({
      userId:     details.userId   || null,
      userType:   details.userType || 'unknown',
      action:     details.action,
      targetId:   details.targetId || null,
      amount:     details.amount   || null,
      status:     details.status   || 'success',
      metadata:   details.metadata || {},
      createdAt:  admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (err) {
    console.error('Audit log error:', err.message);
  }
}

async function logSecurityEvent(userId, eventType, severity, description) {
  try {
    await db.collection('security_events').add({
      userId,
      eventType,
      severity,
      description,
      resolved:   false,
      createdAt:  admin.firestore.FieldValue.serverTimestamp(),
    });
    // Si critique : notifier les admins
    if (severity === 'critical' || severity === 'high') {
      const adminsSnap = await db.collection('admins').where('isActive', '!=', false).get();
      const tokens = adminsSnap.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
      if (tokens.length) {
        await sendToMultipleTokens(tokens,
          `🔴 Alerte sécurité — ${eventType}`,
          description,
          { type: 'security_alert', eventType }
        );
      }
    }
  } catch (err) {
    console.error('Security event log error:', err.message);
  }
}

// ── Hachage de mot de passe (comptes non-Firebase-Auth, ex. pharmacies) ─────
// Voir functions/passwordHash.js (module testable séparément, sans Firebase Admin).
const { hashSecret, verifySecret } = require('./passwordHash');

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
  const VALID_USER_TYPES = ['client', 'driver', 'seller', 'restaurant', 'boulangerie', 'pharmacie', 'fleet'];
  if (!VALID_USER_TYPES.includes(userType)) {
    throw new HttpsError('invalid-argument', 'Type utilisateur invalide');
  }
  if (!amount || typeof amount !== 'number' || amount < 100) {
    throw new HttpsError('invalid-argument', 'Montant minimum : 100 FCFA');
  }
  if (amount > 500000) {
    throw new HttpsError('invalid-argument', 'Montant maximum : 500 000 FCFA');
  }
  const phoneStr = String(phone || '').trim();
  if (!phoneStr || !/^\+?\d{8,15}$/.test(phoneStr)) {
    throw new HttpsError('invalid-argument', 'Numéro de téléphone invalide');
  }

  // ── Rate limiting ─────────────────────────────────────────────────────────
  await checkRateLimit(uid, 'payment', 5, 60);

  // ── Vérifier qu'il n'y a pas déjà une transaction pending pour cet utilisateur ──
  const pendingSnap = await db.collection('wallet_transactions')
    .where('userId', '==', uid)
    .where('status', '==', 'pending')
    .limit(1)
    .get();
  if (!pendingSnap.empty) {
    throw new HttpsError('already-exists', 'Un paiement est déjà en cours. Attendez sa confirmation.');
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
  await logAudit({ userId: uid, userType: userType, action: 'payment_initiated', targetId: txId, amount: amount, status: 'pending' });

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
  if (!FEEXPAY_WEBHOOK_SECRET) {
    console.error('FEEXPAY_WEBHOOK_SECRET manquant — webhook désactivé par sécurité');
    return res.status(503).json({ error: 'Service temporairement indisponible' });
  }
  const receivedSecret = req.query.wh_secret;
  if (!receivedSecret || receivedSecret !== FEEXPAY_WEBHOOK_SECRET) {
    console.error('Webhook : token secret invalide ou manquant');
    await logSecurityEvent('system', 'webhook_invalid_secret', 'high',
      `Tentative webhook avec secret invalide depuis ${req.ip}`);
    return res.status(401).json({ error: 'Non autorisé' });
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

  // Vérifier l'âge de la transaction (protection anti-replay)
  const txCreatedAt = tx.createdAt?.toDate ? tx.createdAt.toDate() : null;
  if (txCreatedAt) {
    const ageMs = Date.now() - txCreatedAt.getTime();
    if (ageMs > 24 * 60 * 60 * 1000) {
      console.warn(`Transaction ${txId} trop ancienne (${Math.floor(ageMs/3600000)}h) — possible replay`);
      await logSecurityEvent(tx.userId, 'webhook_replay_attempt', 'high',
        `Webhook pour transaction ${txId} vieille de ${Math.floor(ageMs/3600000)}h`);
      return res.status(400).json({ error: 'Transaction expirée' });
    }
  }

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
      await logAudit({ userId: tx.userId, userType: tx.userType, action: 'wallet_credited', targetId: txId, amount: tx.amount, status: 'success' });
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

  const VALID_USER_TYPES = ['client', 'driver', 'seller', 'restaurant', 'boulangerie', 'pharmacie', 'fleet'];
  if (!VALID_USER_TYPES.includes(userType)) {
    throw new HttpsError('invalid-argument', 'Type utilisateur invalide');
  }
  if (!amount || typeof amount !== 'number' || amount < 500) {
    throw new HttpsError('invalid-argument', 'Montant minimum de retrait : 500 FCFA');
  }
  if (amount > 500000) {
    throw new HttpsError('invalid-argument', 'Montant maximum de retrait : 500 000 FCFA');
  }
  const phoneStr2 = String(phone || '').trim();
  if (!phoneStr2 || !/^\+?\d{8,15}$/.test(phoneStr2)) {
    throw new HttpsError('invalid-argument', 'Numéro de téléphone invalide');
  }

  // ── Rate limiting ─────────────────────────────────────────────────────────
  await checkRateLimit(uid, 'withdrawal', 3, 60);

  const colName  = collectionFor(userType);
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
    await logAudit({ userId: uid, userType: userType, action: 'withdrawal_initiated', targetId: withdrawId, amount: amount, status: 'processing' });
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    console.error('Firestore transaction error:', err);
    throw new HttpsError('internal', 'Erreur interne. Veuillez réessayer.');
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
    // Même détection que sendToMultipleTokens (Prompt 30) — sans ça, les
    // tokens invalides des envois à un seul destinataire n'atteignaient
    // jamais invalid_fcm_tokens, donc jamais nettoyés.
    if (err.code === 'messaging/registration-token-not-registered' ||
        err.code === 'messaging/invalid-registration-token') {
      await db.collection('invalid_fcm_tokens').add({
        token, detectedAt: admin.firestore.FieldValue.serverTimestamp(),
      }).catch(() => {});
    }
  }
}

async function sendToMultipleTokens(tokens, title, body, data = {}, collectionHint = null) {
  if (!tokens?.length) return;
  const dataStr = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)]));
  try {
    const result = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      android: { priority: 'high', notification: { sound: 'default' } },
      apns:    { payload: { aps: { sound: 'default', badge: 1 } } },
      data:    dataStr,
    });
    // Nettoyer les tokens invalides
    result.responses.forEach((resp, i) => {
      if (!resp.success) {
        const code = resp.error?.code;
        if (code === 'messaging/registration-token-not-registered' ||
            code === 'messaging/invalid-registration-token') {
          console.log(`Token invalide détecté — marqué pour nettoyage: ${tokens[i]?.slice(0, 20)}`);
          // Nettoyage asynchrone non-bloquant
          db.collection('invalid_fcm_tokens').add({
            token: tokens[i], detectedAt: admin.firestore.FieldValue.serverTimestamp(),
          }).catch(() => {});
        }
      }
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
  try {
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
  } catch (err) {
    console.error('notifyClientOnOrderCreated error:', err.message);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// CLIENT — Suivi complet par statut, messages adaptés au service
// Couvre : assigned, broadcast, accepted, picked_up, delivered, cancelled
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyClientOnOrderUpdate = onDocumentUpdated('orders/{orderId}', async (event) => {
  try {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after || before.status === after.status) return;

    const clientDoc = await db.collection('clients').doc(after.clientId).get();
    const token     = clientDoc.data()?.fcmToken;
    if (!token) return;

    // Annulation automatique "aucun livreur" — message spécifique
    if (after.status === 'cancelled' && after.cancelReason === 'no_driver_found') {
      await sendToToken(token,
        '😔 Aucun livreur disponible',
        'Nous n\'avons trouvé aucun livreur disponible pour le moment. Vous pouvez réessayer dans quelques minutes.',
        { type: 'no_driver_found', orderId: event.params.orderId, status: 'cancelled' }
      );
      return;
    }

    const svcType  = getServiceType(after);
    const messages = CLIENT_STATUS_MESSAGES[svcType] || CLIENT_STATUS_MESSAGES.livraison;
    const notif    = messages[after.status];
    if (!notif) return;

    const notifType = ['assigned', 'broadcast'].includes(after.status)
      ? 'driver_found'
      : after.status === 'cancelled' ? 'order_cancelled' : 'order_update';

    await sendToToken(token, notif.title, notif.body, {
      type:    notifType,
      orderId: event.params.orderId,
      status:  after.status,
    });
  } catch (err) {
    console.error('notifyClientOnOrderUpdate error:', err.message);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREURS (broadcast) — FCM push à tous les livreurs ciblés simultanément
// Déclenché quand status → 'broadcast' (transition uniquement)
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyBroadcastDrivers = onDocumentUpdated('orders/{orderId}', async (event) => {
  try {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return;
    if (before.status === 'broadcast' || after.status !== 'broadcast') return;

    const driverIds = after.notifiedDriverIds;
    if (!Array.isArray(driverIds) || driverIds.length === 0) return;

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
  } catch (err) {
    console.error('notifyBroadcastDrivers error:', err.message);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// LIVREUR (assignation directe) — FCM push quand un seul livreur est désigné
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyDriverOnAssigned = onDocumentUpdated('orders/{orderId}', async (event) => {
  try {
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
  } catch (err) {
    console.error('notifyDriverOnAssigned error:', err.message);
  }
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

  const snapshot = await db.collection('livreurs').where('isOnline', '==', true).limit(50).get();
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

  await checkRateLimit(request.auth.uid, 'reset_password', 5, 3600);

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

  // ── Pharmacie → mot de passe haché dans pharmacie_credentials ────────────
  if (userType === 'pharmacie') {
    let snap = await db.collection('pharmacies').where('phone', '==', phone).limit(1).get();
    if (snap.empty) {
      snap = await db.collection('pharmacies').where('phone', '==', normalizedInput).limit(1).get();
    }
    if (snap.empty) throw new HttpsError('not-found', 'Pharmacie introuvable');
    const pharmacieRef = snap.docs[0].reference;
    await db.collection('pharmacie_credentials').doc(pharmacieRef.id).set({
      hash:      hashSecret(String(newValue)),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await pharmacieRef.update({
      password:           admin.firestore.FieldValue.delete(),
      accessCode:          admin.firestore.FieldValue.delete(),
      mustChangePassword: false,
    });
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
// AUTHENTIFICATION PHARMACIE — mot de passe haché (pharmacie_credentials)
// Remplace la comparaison en clair historique (voir commentaire dans
// firestore.rules match /pharmacies/{pharmacieId}, "Phase 5"). Migration
// paresseuse : au premier login réussi d'une pharmacie encore sur l'ancien
// champ password/accessCode en clair, on hache et on supprime le champ en clair.
// ═══════════════════════════════════════════════════════════════════════════
exports.pharmacieLogin = onCall(async (request) => {
  const { pharmacieId, password } = request.data;
  if (!pharmacieId || !password) {
    throw new HttpsError('invalid-argument', 'Paramètres manquants');
  }

  await checkRateLimit(`pharmacie_${pharmacieId}`, 'pharmacie_login', 10, 300);

  const pharmacieRef  = db.collection('pharmacies').doc(String(pharmacieId));
  const pharmacieSnap = await pharmacieRef.get();
  if (!pharmacieSnap.exists) return { success: false };
  const data = pharmacieSnap.data();

  const credRef  = db.collection('pharmacie_credentials').doc(pharmacieId);
  const credSnap = await credRef.get();

  if (credSnap.exists) {
    const ok = verifySecret(password, credSnap.data().hash);
    return ok
      ? { success: true, mustChangePassword: data.mustChangePassword === true }
      : { success: false };
  }

  // Pas encore migrée — comparer avec l'ancien champ en clair, puis migrer.
  const legacy = (data.password || data.accessCode || '').toString();
  if (!legacy || legacy !== password) {
    return { success: false };
  }

  await credRef.set({
    hash:      hashSecret(password),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await pharmacieRef.update({
    password:   admin.firestore.FieldValue.delete(),
    accessCode: admin.firestore.FieldValue.delete(),
  });

  return { success: true, mustChangePassword: data.mustChangePassword === true };
});

// Définit/réinitialise le mot de passe d'une pharmacie — appelable par un
// admin (n'importe quelle pharmacie) ou par la pharmacie elle-même (son
// propre mot de passe, session liée via `currentUid`, même mécanisme que la
// règle Firestore existante pour ce champ).
exports.setPharmaciePassword = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentification requise');
  }
  const uid = request.auth.uid;
  const { pharmacieId, newPassword } = request.data;
  if (!pharmacieId || !newPassword) {
    throw new HttpsError('invalid-argument', 'Paramètres manquants');
  }
  if (String(newPassword).length < 6) {
    throw new HttpsError('invalid-argument', 'Mot de passe trop court (minimum 6 caractères)');
  }

  const pharmacieRef  = db.collection('pharmacies').doc(String(pharmacieId));
  const pharmacieSnap = await pharmacieRef.get();
  if (!pharmacieSnap.exists) {
    throw new HttpsError('not-found', 'Pharmacie introuvable');
  }

  const adminSnap      = await db.collection('admins').doc(uid).get();
  const isCallerAdmin  = adminSnap.exists && adminSnap.data().isActive !== false;
  const isCallerOwner  = pharmacieSnap.data().currentUid === uid;

  if (!isCallerAdmin && !isCallerOwner) {
    throw new HttpsError('permission-denied', 'Non autorisé');
  }
  if (!isCallerAdmin) {
    await checkRateLimit(uid, 'set_pharmacie_password', 5, 3600);
  }

  await db.collection('pharmacie_credentials').doc(pharmacieId).set({
    hash:      hashSecret(newPassword),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await pharmacieRef.update({
    password:            admin.firestore.FieldValue.delete(),
    accessCode:          admin.firestore.FieldValue.delete(),
    // L'admin force un changement au prochain login ; la pharmacie qui
    // change son propre mot de passe n'a pas besoin de le refaire.
    mustChangePassword:  isCallerAdmin,
  });

  await logAudit({
    userId:   uid,
    userType: isCallerAdmin ? 'admin' : 'pharmacie',
    action:   'set_pharmacie_password',
    targetId: pharmacieId,
    status:   'success',
  });

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

  await checkRateLimit(request.auth.uid, 'create_admin', 10, 3600);

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
  await logAudit({ userId: request.auth.uid, userType: 'admin', action: 'create_sub_admin', targetId: userRecord.uid, metadata: { name, email } });

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
  await logAudit({ userId: request.auth.uid, userType: 'admin', action: 'delete_sub_admin', targetId: uid });

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

// ─── E-KBINE — Confirmation commande client (remplace l'écriture Firestore directe) ──
exports.ekClientConfirmOrder = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentification requise');
  }
  const uid     = request.auth.uid;
  const orderId = request.data.orderId;
  if (!orderId || typeof orderId !== 'string') {
    throw new HttpsError('invalid-argument', 'orderId manquant');
  }

  const orderRef = db.collection('ekbine_orders').doc(orderId);
  await db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
    const order = orderSnap.data();
    // Vérifier que c'est bien le client propriétaire
    if (order.clientId !== uid) throw new HttpsError('permission-denied', 'Non autorisé');
    // Vérifier le statut
    if (order.status !== 'proof_sent') throw new HttpsError('failed-precondition', 'Statut invalide');
    const agentId  = order.agentId;
    const earning  = order.agentEarning;
    if (!agentId || typeof earning !== 'number' || earning <= 0) {
      throw new HttpsError('invalid-argument', 'Données commande invalides');
    }
    const agRef = db.collection('ekbine_agents').doc(agentId);
    const agentSnap = await tx.get(agRef);
    if (!agentSnap.exists) throw new HttpsError('not-found', 'Agent introuvable');

    tx.update(orderRef, {
      status:      'completed',
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(agRef, {
      walletBalance:  admin.firestore.FieldValue.increment(earning),
      totalCompleted: admin.firestore.FieldValue.increment(1),
      lastOrderId:    orderId,
    });

    // Audit log
    const auditRef = db.collection('audit_logs').doc();
    tx.set(auditRef, {
      userId:    uid,
      userType:  'client',
      action:    'ekbine_confirm_order',
      targetId:  orderId,
      amount:    earning,
      agentId:   agentId,
      status:    'success',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { success: true };
});


// ═══════════════════════════════════════════════════════════════════════════
// SCHEDULER — Annulation automatique des commandes sans livreur
// Toutes les minutes : annule les commandes pending/broadcast/assigned
// créées il y a plus de 10 minutes. Transaction atomique + remboursement
// wallet + nettoyage livreurs + audit log + métriques dispatching.
// ═══════════════════════════════════════════════════════════════════════════
exports.autoExpireOrders = onSchedule({
  schedule:       'every 1 minutes',
  timeoutSeconds: 120,
  memory:         '256MiB',
}, async () => {
  const now       = admin.firestore.Timestamp.now();
  const tenMinAgo = new admin.firestore.Timestamp(now.seconds - 600, now.nanoseconds);

  const snap = await db.collection('orders')
    .where('status', 'in', ['pending', 'broadcast', 'assigned'])
    .where('createdAt', '<=', tenMinAgo)
    .get();

  if (snap.empty) return;

  console.log(`autoExpireOrders : ${snap.docs.length} commande(s) à expirer`);

  for (const doc of snap.docs) {
    const orderId = doc.id;
    const order   = doc.data();

    try {
      // Transaction atomique — protège contre la race condition avec acceptOrder()
      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(doc.ref);
        if (!fresh.exists) return;
        const freshData = fresh.data();

        // Vérifier que le statut est encore annulable (un livreur a peut-être accepté)
        if (!['pending', 'broadcast', 'assigned'].includes(freshData.status)) return;

        const willRefund = freshData.paymentMethod === 'wallet' && freshData.isPaid === true;
        // Marketplace ('seller') est crédité en entier à la création de la
        // commande (voir PREPAID_PARTNER_TYPES, Master Prompt 46) — sans ce
        // débit en retour, l'expiration automatique créerait de l'argent à
        // partir de rien (client remboursé + vendeur déjà payé), exactement
        // comme pour cancelOrderCF (Master Prompt 47). Même limitation
        // volontaire qu'orderActions.js:buildCancelOrder — n'inclut pas
        // 'boutique', dont le document `orders` ici ne représente que le
        // trajet de livraison (montant différent du paiement réel, qui vit
        // sur `boutique_orders` séparément) : débiter `budget` ici serait
        // incorrect pour ce type, documenté comme trouvaille distincte.
        const needsSellerDebit = willRefund && freshData.sellerId && freshData.sellerType === 'seller';
        // Toutes les lectures doivent précéder toute écriture dans une
        // transaction Firestore — lire le vendeur ici, avant tx.update(doc.ref)
        // ci-dessous, pour pouvoir plafonner le débit à 0 (pas de solde négatif).
        const sellerRef  = needsSellerDebit ? db.collection('sellers').doc(freshData.sellerId) : null;
        const sellerSnap = needsSellerDebit ? await tx.get(sellerRef) : null;

        // Annuler la commande
        tx.update(doc.ref, {
          status:       'cancelled',
          cancelReason: 'no_driver_found',
          cancelledAt:  admin.firestore.FieldValue.serverTimestamp(),
        });

        // Remboursement wallet si paiement par wallet
        if (willRefund) {
          const amount    = freshData.budget || 0;
          const clientRef = db.collection('clients').doc(freshData.clientId);
          tx.update(clientRef, {
            wallet: admin.firestore.FieldValue.increment(amount),
          });
          const histRef = clientRef.collection('wallet_transactions').doc();
          tx.set(histRef, {
            type:        'refund',
            amount:      amount,
            description: 'Remboursement — aucun livreur disponible',
            orderId:     orderId,
            createdAt:   admin.firestore.FieldValue.serverTimestamp(),
          });

          if (needsSellerDebit && sellerSnap.exists) {
            const w = Number(sellerSnap.data().wallet || 0);
            // Plafonné à 0 : si le vendeur a déjà retiré une partie de ce
            // crédit avant l'expiration, on reprend ce qu'il reste plutôt que
            // de créer un solde négatif (même logique que cancelOrderCF).
            const sellerDebit = Math.min(amount, w);
            if (sellerDebit > 0) {
              tx.update(sellerRef, {
                wallet: w - sellerDebit,
              });
              const sellerHistRef = sellerRef.collection('wallet_transactions').doc();
              tx.set(sellerHistRef, {
                type:        'debit',
                amount:      sellerDebit,
                description: 'Commande expirée (aucun livreur) — reprise du paiement',
                orderId:     orderId,
                createdAt:   admin.firestore.FieldValue.serverTimestamp(),
              });
            }
          }
        }

        // Métriques dispatching — incrémente le compteur de la tranche horaire/zone
        const today  = new Date().toISOString().split('T')[0];
        const hour   = new Date().getHours();
        const slot   = Math.floor(hour / 3) * 3; // tranches de 3h
        const zone   = freshData.pickupZone || freshData.deliveryZone || 'unknown';
        const svc    = freshData.type || 'livraison';
        const metricRef = db.collection('dispatch_metrics')
          .doc(`${today}_${zone}_${slot}h`);
        tx.set(metricRef, {
          date:               today,
          zone,
          serviceType:        svc,
          hourSlot:           slot,
          noDriverFoundCount: admin.firestore.FieldValue.increment(1),
          lastUpdated:        admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      });

      // Nettoyage pendingOrderId chez les livreurs notifiés (hors transaction)
      const notifiedIds = order.notifiedDriverIds;
      if (Array.isArray(notifiedIds) && notifiedIds.length > 0) {
        const batch = db.batch();
        notifiedIds.forEach(driverId => {
          batch.update(db.collection('livreurs').doc(driverId), {
            pendingOrderId: admin.firestore.FieldValue.delete(),
          });
        });
        await batch.commit().catch(err =>
          console.warn(`Cleanup pendingOrderId batch (${orderId}):`, err.message));
      }
      if (order.driverId) {
        await db.collection('livreurs').doc(order.driverId)
          .update({ pendingOrderId: admin.firestore.FieldValue.delete() })
          .catch(() => {});
      }

      // Audit log
      const searchSecs = order.createdAt
        ? Math.round((Date.now() - order.createdAt.toMillis()) / 1000) : 0;
      await logAudit({
        userId:   order.clientId || 'unknown',
        userType: 'system',
        action:   'order_auto_cancelled_no_driver',
        targetId: orderId,
        metadata: {
          serviceType:           order.type || 'livraison',
          previousStatus:        order.status,
          zone:                  order.pickupZone || order.deliveryZone || 'unknown',
          searchDurationSeconds: String(searchSecs),
          notifiedDriversCount:  String(
            Array.isArray(order.notifiedDriverIds) ? order.notifiedDriverIds.length : 0
          ),
          walletRefunded: String(order.paymentMethod === 'wallet' && order.isPaid === true),
        },
      });

      console.log(`✅ Commande ${orderId} expirée automatiquement (était ${order.status}, ${searchSecs}s)`);
    } catch (err) {
      console.error(`❌ Erreur expiration commande ${orderId}:`, err.message);
    }
  }
});


// ═══════════════════════════════════════════════════════════════════════════
// RATE LIMITING RÉACTIF — Création de commandes
// Trigger sur orders/{orderId} : annule automatiquement si le client dépasse
// 10 commandes en 1 heure. Aucune modification Flutter nécessaire.
// Le remboursement wallet est automatique si la commande était payée.
// ═══════════════════════════════════════════════════════════════════════════
exports.enforceOrderRateLimit = onDocumentCreated('orders/{orderId}', async (event) => {
  try {
    const order   = event.data.data();
    const orderId = event.params.orderId;
    if (!order || !order.clientId) return;

    const clientId    = order.clientId;
    const now         = Date.now();
    const oneHourAgo  = now - 3600 * 1000;
    const key         = `${clientId}_order_creation`;
    const ref         = db.collection('rate_limits').doc(key);

    let exceeded = false;
    await db.runTransaction(async (tx) => {
      const snap   = await tx.get(ref);
      const data   = snap.exists ? snap.data() : { requests: [] };
      const recent = (data.requests || []).filter(t => t > oneHourAgo);

      if (recent.length >= 10) {
        exceeded = true;
        return;
      }
      recent.push(now);
      const bounded = recent.length > 100 ? recent.slice(-100) : recent;
      tx.set(ref, { requests: bounded, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    });

    if (!exceeded) return;

    // Trop de commandes — annuler immédiatement
    const orderRef = db.collection('orders').doc(orderId);
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(orderRef);
      if (!fresh.exists || fresh.data().status !== 'pending') return;

      tx.update(orderRef, {
        status:       'cancelled',
        cancelReason: 'rate_limit_exceeded',
        cancelledAt:  admin.firestore.FieldValue.serverTimestamp(),
      });

      // Remboursement automatique si payé par wallet
      if (order.paymentMethod === 'wallet' && order.isPaid === true) {
        const amount    = order.budget || 0;
        const clientRef = db.collection('clients').doc(clientId);
        tx.update(clientRef, { wallet: admin.firestore.FieldValue.increment(amount) });
        const histRef = clientRef.collection('wallet_transactions').doc();
        tx.set(histRef, {
          type:        'refund',
          amount,
          description: 'Remboursement — limite de commandes dépassée',
          orderId,
          createdAt:   admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    });

    await logSecurityEvent(clientId, 'order_rate_limit_exceeded', 'medium',
      `Client ${clientId} a dépassé la limite de 10 commandes/heure`);
    console.warn(`⚠️ Rate limit commandes: client=${clientId} orderId=${orderId}`);
  } catch (err) {
    console.error('enforceOrderRateLimit error:', err.message);
  }
});


// ═══════════════════════════════════════════════════════════════════════════
// DISPATCH GÉNÉRIQUE — attribution d'un livreur à une commande
// Remplace l'ancien findNearestDriver() côté client (lib/services/
// firestore_service.dart), qui lisait le champ `wallet` de TOUS les livreurs
// directement depuis le client — c'est ce qui empêchait de restreindre la
// lecture de ce champ sensible (voir FIRESTORE_RULES.md, section 5). Le
// dispatch tourne désormais uniquement côté serveur (Admin SDK, ignore les
// règles). Réutilise la même logique que les outils AZ IA (functions/dispatch.js).
// ═══════════════════════════════════════════════════════════════════════════
const { dispatchOrder, calculateCommission } = require('./dispatch');

exports.dispatchOrderToDriver = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }
  const uid = request.auth.uid;
  const { orderId, radiusKm } = request.data || {};
  if (!orderId) {
    throw new HttpsError('invalid-argument', 'orderId manquant');
  }

  await checkRateLimit(uid, 'dispatch_order', 20, 60);

  const orderRef  = db.collection('orders').doc(String(orderId));
  const orderSnap = await orderRef.get();
  if (!orderSnap.exists) {
    throw new HttpsError('not-found', 'Commande introuvable');
  }
  const order = orderSnap.data();

  // Seul le client propriétaire de la commande (ou un admin) peut déclencher
  // son dispatch — même contrat que la lecture directe de orders/{id}.
  const isOwner = order.clientId === uid;
  let isCallerAdmin = false;
  if (!isOwner) {
    const adminSnap = await db.collection('admins').doc(uid).get();
    isCallerAdmin = adminSnap.exists && adminSnap.data().isActive !== false;
  }
  if (!isOwner && !isCallerAdmin) {
    throw new HttpsError('permission-denied', 'Non autorisé');
  }

  const lat    = Number(order.latitude ?? order.deliveryLatitude ?? 0);
  const lng    = Number(order.longitude ?? order.deliveryLongitude ?? 0);
  const budget = Number(order.budget || 0);

  const result = await dispatchOrder(db, admin, {
    orderId:  String(orderId),
    lat, lng, budget,
    ...(typeof radiusKm === 'number' ? { radiusKm } : {}),
  });

  return result; // { dispatched: boolean, mode: 'assigned'|'broadcast'|'none' }
});


// ═══════════════════════════════════════════════════════════════════════════
// PAIEMENT WALLET / ANNULATION / LIVRAISON — portage côté serveur
// Ces trois actions déduisaient/créditaient le wallet d'UN AUTRE utilisateur
// (client → livreur, ou livreur → lui-même en augmentant son solde) depuis des
// transactions Firestore lancées directement par le client Flutter
// (lib/services/firestore_service.dart : payOrderFromWallet/cancelOrder/
// deliverOrder). La règle `livreurs/{id}` n'autorise que isAdmin() ou le
// propriétaire DIMINUANT son propre wallet (voir firestore.rules) — ces
// écritures cross-user étaient donc déjà rejetées par les règles en
// production (bug préexistant, indépendant de ce chantier). Portage fidèle de
// la même logique métier côté Admin SDK, qui ignore les règles et peut donc
// exécuter légitimement ces crédits — et permet en prime de restreindre la
// lecture du champ wallet côté client (voir plus bas). Fabriques définies
// dans orderActions.js (testables sans Firebase Admin, même pattern que
// azia/pendingActions.js:buildConfirmAction).
// ═══════════════════════════════════════════════════════════════════════════
const { buildPayOrderFromWallet, buildCancelOrder, buildDeliverOrder, buildPayBoutiqueOrder, buildPayBoutiqueOrderCash, buildRefundExpiredBoutiqueOrder } = require('./orderActions');

exports.payOrderFromWalletCF = buildPayOrderFromWallet({ db, admin, onCall, HttpsError, checkRateLimit, logAudit });
exports.cancelOrderCF        = buildCancelOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission });
exports.deliverOrderCF       = buildDeliverOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit });
exports.payBoutiqueOrderCF   = buildPayBoutiqueOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, dispatchOrder });
exports.payBoutiqueOrderCashCF = buildPayBoutiqueOrderCash({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, dispatchOrder });
exports.refundExpiredBoutiqueOrderCF = buildRefundExpiredBoutiqueOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit });


// ═══════════════════════════════════════════════════════════════════════════
// SCHEDULER — Nettoyage hebdomadaire des rate_limits expirés
// Supprime les documents rate_limits dont toutes les entrées ont expiré.
// Réduit les coûts de lecture Firestore et évite l'accumulation de docs.
// ═══════════════════════════════════════════════════════════════════════════
exports.cleanupExpiredRateLimits = onSchedule({
  schedule:       'every monday 03:00',
  timeZone:       'Africa/Abidjan',
  timeoutSeconds: 300,
  memory:         '256MiB',
}, async () => {
  try {
    const now          = Date.now();
    const maxWindowMs  = 3600 * 1000; // fenêtre max = 1h
    const cutoff       = now - maxWindowMs;
    const snap         = await db.collection('rate_limits').get();
    if (snap.empty) return;

    const batch = db.batch();
    let   count = 0;

    snap.docs.forEach(doc => {
      const requests = doc.data().requests || [];
      const active   = requests.filter(t => t > cutoff);
      if (active.length === 0) {
        batch.delete(doc.ref);
        count++;
      }
    });

    if (count > 0) {
      await batch.commit();
      console.log(`🧹 Rate limits nettoyés : ${count} documents supprimés`);
    }
  } catch (err) {
    console.error('cleanupExpiredRateLimits error:', err.message);
  }
});


// ═══════════════════════════════════════════════════════════════════════════
// SCHEDULER — Conciliation wallet hebdomadaire (Prompt 28)
// Diagnostic en lecture seule : signale les écarts entre le champ `wallet`
// et l'historique wallet_transactions, ne modifie jamais un solde.
// Voir functions/walletReconciliation.js pour le détail.
// ═══════════════════════════════════════════════════════════════════════════
const { buildWalletReconciliationCheck } = require('./walletReconciliation');
exports.walletReconciliationCheck = buildWalletReconciliationCheck({ db, admin, onSchedule, logAudit });


// ═══════════════════════════════════════════════════════════════════════════
// SCHEDULER — Nettoyage hebdomadaire des tokens FCM invalides (Prompt 30)
// Ferme la boucle : invalid_fcm_tokens est déjà alimenté par sendToToken/
// sendToMultipleTokens, mais rien ne le consommait avant ce jour.
// Voir functions/fcmTokenCleanup.js.
// ═══════════════════════════════════════════════════════════════════════════
const { buildFcmTokenCleanup } = require('./fcmTokenCleanup');
exports.fcmTokenCleanupCheck = buildFcmTokenCleanup({ db, admin, onSchedule });


// ═══════════════════════════════════════════════════════════════════════════
// AZ IA — Assistant conversationnel (Claude)
// Créez functions/.env avec :
//   ANTHROPIC_API_KEY=votre_clé_anthropic
// ═══════════════════════════════════════════════════════════════════════════
const createAzIa = require('./azia');
const azIa       = createAzIa({
  db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError,
  axios, feexpayOperatorCode, FEEXPAY_TOKEN, FEEXPAY_API_URL, WEBHOOK_URL,
});
exports.azIaChat                       = azIa.azIaChat;
exports.aiConfirmAction                = azIa.aiConfirmAction;
exports.aiCleanupExpiredPendingActions = azIa.aiCleanupExpiredPendingActions;
exports.clearAiHistory                 = azIa.clearAiHistory;


// ═══════════════════════════════════════════════════════════════════════════
// IMMOBILIER (jalon M6) — real_estate_agents/listings/visit_requests
// ═══════════════════════════════════════════════════════════════════════════
const { createRealEstateFunctions } = require('./realestate');
const realEstate = createRealEstateFunctions({
  db, admin, onCall, onDocumentCreated, onDocumentUpdated,
  checkRateLimit, logAudit, HttpsError, sendToToken,
});
exports.submitRealEstateAgentRequest  = realEstate.submitRealEstateAgentRequest;
exports.approveRealEstateAgentRequest = realEstate.approveRealEstateAgentRequest;
exports.requestPropertyVisit          = realEstate.requestPropertyVisit;
exports.respondToVisitRequest         = realEstate.respondToVisitRequest;
exports.notifyAgentOnVisitRequest     = realEstate.notifyAgentOnVisitRequest;
exports.notifyClientOnVisitUpdate     = realEstate.notifyClientOnVisitUpdate;


// ═══════════════════════════════════════════════════════════════════════════
// IDENTITÉ — journalisation des événements de connexion/rôle (Prompt 24)
// Fabriques définies dans authEvents.js (testables sans Firebase Admin, même
// pattern que orderActions.js/pendingActions.js).
// ═══════════════════════════════════════════════════════════════════════════
const { buildLogAuthEvent, buildLogAdminAuditEvent } = require('./authEvents');
exports.logAuthEvent      = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit, logAudit });
exports.logAdminAuditEvent = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit, logAudit });
