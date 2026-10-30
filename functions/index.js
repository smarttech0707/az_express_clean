'use strict';

const { onCall: rawOnCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentUpdated, onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions } = require('firebase-functions/v2');
const { defineSecret } = require('firebase-functions/params');
const admin  = require('firebase-admin');
const axios  = require('axios');
const crypto = require('crypto');
const { expireOrderTx, rateLimitCancelTx } = require('./orderRefunds');
const { buildAdminBilling } = require('./adminBilling');
const { selectDepositAccount, isEligibleAgent } = require('./ekbineFlow');
const {
  isAuthorizedWebhookCall,
  processFeexPayWebhookEvent,
  resolvePayoutEndpoint,
  sanitizePayoutMotif,
  assertWithdrawalCanStart,
  classifyPayoutInitiation,
  compensateFailedWithdrawal,
  classifyCollectInitiationFailure,
  buildInitiationFailureLog,
  COLLECT_UNCERTAIN_STATUS,
  UNCERTAIN_RETRY_BLOCK_MS,
} = require('./feexpayPayments');
const {
  delayMsForCheck,
  verifyAndApplyWithdrawal,
  buildPendingWithdrawalChecker,
} = require('./feexpayPayoutScheduler');
const {
  createStatusVerifier,
  createPayoutStatusVerifier,
} = require('./feexpayVerification');
const { buildResetAccountPassword } = require('./passwordReset');
const { buildManageProfessionalSubscription } = require('./professionalSubscriptions');
const { buildManageAdminPartnerAccount } = require('./adminPartnerAccounts');
const { buildCompletePartnerFirstPasswordChange } = require('./partnerFirstLogin');
const { assertPartnerActivated } = require('./partnerActivationGuard');
const { requireAdminPermission, requireSuperAdmin } = require('./adminGuards');
const {
  buildPublishMarketplaceProduct,
  buildRepublishMarketplaceProduct,
  buildExpireMarketplaceProducts,
} = require('./marketplacePublishing');
const {
  DisabledExternalPharmacyGuardProvider,
  syncProvider: syncPharmacyGuardProvider,
} = require('./pharmacyGuards');

admin.initializeApp();
setGlobalOptions({ region: 'europe-west1' });

const db = admin.firestore();
const {buildPartnerQr,available:qrAvailable,COLLECTIONS:QR_COLLECTIONS}=require('./partnerQr');
const partnerQr=buildPartnerQr({db,auth:admin.auth(),HttpsError});
exports.getPartnerQr=rawOnCall({region:'europe-west1',maxInstances:2},partnerQr.manage);
exports.resolvePartnerQr=rawOnCall({region:'europe-west1',maxInstances:2},partnerQr.resolve);
exports.listPartnerQrEstablishments=rawOnCall({region:'europe-west1',maxInstances:2},partnerQr.list);
exports.setPartnerQrManager=onCall({region:'europe-west1',maxInstances:1},partnerQr.grant);
for(const [kind,collection] of Object.entries(QR_COLLECTIONS)){
  exports['syncPartnerQr_'+kind]=onDocumentWritten({document:collection+'/{id}',region:'europe-west1',maxInstances:1,retry:true},event=>{
    const before=event.data?.before.data(),after=event.data?.after.data();
    if(!qrAvailable(after)||qrAvailable(before))return;
    return partnerQr.sync(kind,event.params.id);
  });
}

// Refuse stale authenticated sessions once a verified deletion enters quarantine.
// Financial webhooks/schedulers are deliberately not wrapped.
const { buildAccountDeletion, assertAccountEnabled } = require('./accountDeletion');
function onCall(options, handler) {
  if(typeof options==='function'){handler=options;options={};}
  return rawOnCall(options,async(request,...rest)=>{
    await assertAccountEnabled(db,request.auth?.uid,HttpsError);
    return handler(request,...rest);
  });
}
const accountDeletion=buildAccountDeletion({db,auth:admin.auth(),admin,HttpsError,
  eraseAssets:async(uid,role)=>{
    await require('./accountPersonalAssets').erasePersonalAssets(admin.storage().bucket(),uid,role);
  }});
exports.requestAccountDeletionCF=rawOnCall({region:'europe-west1',maxInstances:1,cpu:0.5,concurrency:1,timeoutSeconds:120,memory:'256MiB'},accountDeletion.request);
exports.getAccountDeletionStatusCF=rawOnCall({region:'europe-west1',maxInstances:1,cpu:0.25,concurrency:1,timeoutSeconds:30,memory:'256MiB'},accountDeletion.status);
exports.retryAccountDeletions=onSchedule({schedule:'every 15 minutes',region:'europe-west1',maxInstances:1,cpu:0.25,concurrency:1,timeoutSeconds:120,memory:'256MiB'},accountDeletion.drain);
const {buildAccountDeletionSupport}=require('./accountDeletionSupport');
exports.manageAccountDeletionCF=onCall({region:'europe-west1',maxInstances:1,cpu:0.25,concurrency:1,timeoutSeconds:120,memory:'256MiB'},
  buildAccountDeletionSupport({db,admin,HttpsError,process:accountDeletion.process}));
const {buildPharmacyOwnerIdentity}=require('./pharmacyOwnerIdentity');
exports.managePharmacyOwnerIdentityCF=onCall({region:'europe-west1',maxInstances:1,timeoutSeconds:60,memory:'256MiB'},
  buildPharmacyOwnerIdentity({db,auth:admin.auth(),admin,HttpsError}));


const { settleTerminalOrder, diagnoseDriver, clearAcceptedOffers } = require('./driverLifecycle');
const { assertDriverRechargeAllowed } = require('./driverWalletPolicy');
const { buildAcceptOrder } = require('./driverAcceptance');
const { buildAdminDriverRecharge } = require('./adminDriverRecharge');
const { buildCreateFleetDriver } = require('./fleetDriverCreation');
const { buildManageArtisanPhotos } = require('./artisanPhotos');
const { buildManualAccountDeletion } = require('./manualAccountDeletion');
const { buildReleaseOrderBeforePickup } = require('./driverRelease');
const { buildDeclineLegacyOrder } = require('./driverDecline');
const { buildDeliveryTransfer, expireDueTransfers } = require('./driverTransfer');
const { buildSettleTransferEarnings } = require('./transferSettlement');

// Forward-only lifecycle repair: never handles deletions or scans old drivers.
exports.syncDriverOrderLifecycle = onDocumentUpdated({
  document: 'orders/{orderId}', maxInstances: 1, retry: true,
}, async event => {
  const before = event.data.before.data();
  const after = event.data.after.data();
  if (before.status === after.status) return;
  if (['cancelled', 'delivered'].includes(after.status)) {
    await settleTerminalOrder(db, admin, event.params.orderId, before);
  } else if (after.status === 'accepted') {
    await clearAcceptedOffers(db, admin, event.params.orderId, before);
  }
});

// Explicit Admin invocation only. No Firestore writes or corrective mode.
exports.diagnoseDriverOccupancy = onCall({ maxInstances: 1 }, async request => {
  await requireSuperAdmin({ request, db });
  const { driverId, mode } = request.data || {};
  if (typeof driverId !== 'string' || !driverId || driverId.includes('/') ||
      (mode != null && mode !== 'diagnostic')) {
    throw new HttpsError('invalid-argument', 'Driver ID required; diagnostic mode only.');
  }
  const result = await diagnoseDriver(db, driverId);
  console.info('[driverOccupancyDiagnostic]', result);
  return result;
});


exports.manageAdminPartnerAccount = onCall(
  { maxInstances: 2 },
  buildManageAdminPartnerAccount({
    db,
    auth: admin.auth(),
    fieldValue: admin.firestore.FieldValue,
    checkRateLimit,
    logAudit,
    logSecurityEvent,
  }),
);

// Première connexion des partenaires créés par l'administration (restaurant,
// vendeur, boulangerie) : changement OBLIGATOIRE du mot de passe temporaire,
// effectué par le serveur. maxInstances 1 (quota Cloud Run régional).
exports.completePartnerFirstPasswordChange = onCall(
  { maxInstances: 1, cpu: 0.5 },
  buildCompletePartnerFirstPasswordChange({
    db,
    auth: admin.auth(),
    fieldValue: admin.firestore.FieldValue,
    checkRateLimit,
    logAudit,
  }),
);

// maxInstances 5 → 2 (quota Cloud Run régional, voir la note plus bas sur les
// déclencheurs de notification) : avec une concurrence de 80, 2 instances
// servent déjà 160 publications simultanées.
exports.publishMarketplaceProduct = onCall(
  { maxInstances: 2 },
  buildPublishMarketplaceProduct({ db, admin }),
);
exports.republishMarketplaceProduct = onCall(
  { maxInstances: 2 },
  buildRepublishMarketplaceProduct({ db, admin }),
);
exports.expireMarketplaceProducts = onSchedule(
  { schedule: 'every day 02:15', timeZone: 'Africa/Abidjan', maxInstances: 1 },
  buildExpireMarketplaceProducts({ db, admin }),
);

// Architecture prête pour une API officielle future. Tant qu'aucune source
// autorisée n'est configurée, cette tâche ne modifie aucune donnée et conserve
// intégralement les gardes manuelles/déjà synchronisées dans Firestore.
exports.syncPharmacyGuards = onSchedule(
  { schedule: '0 5,17 * * *', timeZone: 'Africa/Abidjan', maxInstances: 1 },
  async () => {
    const now = new Date();
    const to = new Date(now.getTime() + 32 * 24 * 60 * 60 * 1000);
    return syncPharmacyGuardProvider({
      db,
      admin,
      provider: new DisabledExternalPharmacyGuardProvider(),
      city: 'Abengourou',
      from: now,
      to,
      logger: console,
    });
  },
);

// ── Environnement ───────────────────────────────────────────────────────────
// Configurer FEEXPAY_TOKEN et FEEXPAY_WEBHOOK_SECRET dans Secret Manager.
const FEEXPAY_TOKEN_SECRET = defineSecret('FEEXPAY_TOKEN');
const FEEXPAY_WEBHOOK_SECRET = defineSecret('FEEXPAY_WEBHOOK_SECRET');
const ANTHROPIC_API_KEY_SECRET = defineSecret('ANTHROPIC_API_KEY');
const DELIVERY_PROOF_PEPPER_SECRET = defineSecret('DELIVERY_PROOF_PEPPER');

// ── Clés des fournisseurs IA — Secret Manager, jamais functions/.env ────────
// Elles étaient jusqu'ici de simples variables d'environnement issues de
// `functions/.env`. Or le CLI Firebase applique ce fichier à TOUTES les
// fonctions du codebase, quel que soit le `--only` du déploiement : les clés
// se retrouvaient donc montées en clair jusque sur les fonctions de paiement
// FeexPay, les triggers de notification et `pharmacieLogin`, qui n'en ont
// aucun usage. Une variable d'environnement n'a ni versionnage, ni rotation,
// ni traçabilité d'accès, et reste lisible par quiconque obtient un droit de
// lecture sur le projet.
//
// Les providers lisent `process.env.<NOM>` : `defineSecret` monte la valeur
// sous ce même nom au runtime, donc AUCUN code de provider ne change — seule
// la déclaration `secrets:` par fonction détermine qui y a accès.
// Seuls les fournisseurs réellement en service sont déclarés : Claude
// (principal) et Gemini (repli). `defineSecret` crée une dépendance de
// DÉPLOIEMENT — déclarer un secret absent de Secret Manager ferait échouer le
// déploiement, or OPENAI/GROQ/MISTRAL/DEEPSEEK n'y existent pas.
//
// Pour activer un fournisseur optionnel plus tard, trois gestes :
//   1. `firebase functions:secrets:set <NOM>` (saisie masquée)
//   2. rétablir ici `const X_SECRET = defineSecret('<NOM>');`
//   3. l'ajouter à `azIaChatSecrets` ET à `fallbackProviders`
//      (`settings/ai` ou AI_FALLBACK_PROVIDERS)
// Sans ces gestes, le provider reste présent dans le code mais inerte :
// `isConfigured()` renvoie false et aucune requête ne part.
const GEMINI_API_KEY_SECRET = defineSecret('GEMINI_API_KEY');

const FEEXPAY_API_URL        = 'https://api.feexpay.me';
// Identifiant de boutique exige par l'API Payout V2 (champ `shop`). Ce n'est
// pas un secret : valeur de configuration lue depuis l'environnement des
// fonctions. Absente, les retraits echouent proprement AVANT tout debit.
const FEEXPAY_SHOP_ID        = () => String(process.env.FEEXPAY_SHOP_ID || '').trim();
// GCLOUD_PROJECT est défini par Cloud Functions : un projet de test ne doit jamais
// pointer le webhook de paiement vers la production.
const PROJECT_ID             = process.env.GCLOUD_PROJECT || 'az-express-b0469';

// Le secret est inclus dans l'URL du webhook → FeexPay le renvoie
// sans avoir à vérifier une signature HMAC (que FeexPay ne supporte pas)
function feexpayWebhookUrl() {
  const webhookSecret = FEEXPAY_WEBHOOK_SECRET.value();
  return webhookSecret
    ? `https://europe-west1-${PROJECT_ID}.cloudfunctions.net/feexPayWebhook?wh_secret=${webhookSecret}`
    : `https://europe-west1-${PROJECT_ID}.cloudfunctions.net/feexPayWebhook`;
}

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
      const adminsSnap = await db.collection('admins').where('isActive', '==', true).get();
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
exports.initiateFeexPayPayment = onCall({
  secrets: [FEEXPAY_TOKEN_SECRET, FEEXPAY_WEBHOOK_SECRET],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }

  const uid = request.auth.uid;
  // Partenaire créé par l'administration : aucune recharge avant le changement du
  // mot de passe temporaire. Contrôle placé AVANT toute validation, limitation
  // de débit ou création de transaction ; aucun effet pour les autres rôles.
  await assertPartnerActivated({ db, request });
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

  // Livreur : portefeuille initial 0 FCFA, première recharge d'au moins 1 000 FCFA
  // (solde utilisable, pas des frais). Contrôle serveur, avant toute transaction.
  if (userType === 'driver') {
    await assertDriverRechargeAllowed({ db, uid, amount, HttpsError });
  }

  // ── Vérifier qu'il n'y a pas déjà une transaction pending pour cet utilisateur ──
  const pendingSnap = await db.collection('wallet_transactions')
    .where('userId', '==', uid)
    .where('status', '==', 'pending')
    .limit(1)
    .get();
  if (!pendingSnap.empty) {
    throw new HttpsError('already-exists', 'Un paiement est déjà en cours. Attendez sa confirmation.');
  }

  // Un échec AMBIGU (502, timeout…) laisse la transaction en
  // `provider_uncertain` : FeexPay a peut-être créé la demande et sollicité le
  // téléphone. Relancer immédiatement risquerait un second débit réel pour une
  // seule intention d'achat. On bloque donc une nouvelle tentative pendant une
  // fenêtre bornée — jamais indéfiniment, sinon un utilisateur resterait
  // bloqué si aucun webhook n'arrive jamais. Requête à deux égalités, de même
  // forme que celle ci-dessus : aucun nouvel index composite nécessaire.
  const uncertainSnap = await db.collection('wallet_transactions')
    .where('userId', '==', uid)
    .where('status', '==', COLLECT_UNCERTAIN_STATUS)
    .limit(5)
    .get();
  const blockingUncertain = uncertainSnap.docs.find((doc) => {
    const createdAt = doc.data().createdAt?.toDate?.();
    return createdAt ? (Date.now() - createdAt.getTime()) < UNCERTAIN_RETRY_BLOCK_MS : true;
  });
  if (blockingUncertain) {
    throw new HttpsError(
      'already-exists',
      'Une demande de paiement précédente est encore en cours de vérification. '
      + 'Vérifiez votre téléphone, puis réessayez dans quelques minutes.',
    );
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
        callback:     feexpayWebhookUrl(),
        description:  'Recharge wallet AZ Express',
        currency:     'XOF',
        pay_in_phone: String(phone).trim(),
        type:         feexpayOperatorCode(operator),
      },
      {
        headers: {
          Authorization:  `Bearer ${FEEXPAY_TOKEN_SECRET.value()}`,
          'Content-Type': 'application/json',
        },
        timeout: 20000,
      }
    );
    feexpayData = response.data;
  } catch (err) {
    // Diagnostic structuré : l'ancien chemin ne retenait que
    // `data.message || err.message`, donc un 502 de passerelle ne laissait
    // qu'un message axios générique, remonté tel quel à l'application et
    // absent de Cloud Logging. Aucun corps brut, aucune URL complète, aucun
    // jeton, aucun téléphone ne sort d'ici.
    const verdict = classifyCollectInitiationFailure(err);
    console.error(buildInitiationFailureLog(verdict, txId));

    // Un échec AMBIGU n'est jamais marqué comme définitif : la transaction
    // reste rapprochable par `txId` (le même identifiant a été envoyé à
    // FeexPay dans le champ `id`), et un webhook tardif pourra toujours la
    // créditer après vérification serveur.
    await txRef.update({
      status: verdict.txStatus,
      errorReason: verdict.reason,
      providerHttpStatus: verdict.httpStatus,
      providerCode: verdict.providerCode,
      providerStatusRaw: verdict.providerStatus,
      providerReference: verdict.providerReference,
      errorMessage: verdict.providerMessage,
      ambiguous: verdict.ambiguous,
      ...(verdict.ambiguous ? { needsReview: true } : {}),
      failedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await logAudit({
      userId: uid, userType, action: 'payment_initiation_failed',
      targetId: txId, amount, status: verdict.txStatus,
    });

    if (verdict.ambiguous) {
      // Ne jamais annoncer un échec définitif sur un état incertain.
      throw new HttpsError(
        'unavailable',
        'Le service de paiement est momentanément indisponible. '
        + 'Vérifiez votre téléphone : si une demande de paiement y apparaît, elle reste valable.',
        { provider: 'FeexPay', httpStatus: verdict.httpStatus, retryable: true },
      );
    }
    throw new HttpsError(
      'failed-precondition',
      "La demande de paiement n'a pas pu être créée. Vérifiez le numéro et l'opérateur, puis réessayez.",
      { provider: 'FeexPay', httpStatus: verdict.httpStatus, retryable: false },
    );
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
//    https://europe-west1-az-express-b0469.cloudfunctions.net/feexPayWebhook
// ═══════════════════════════════════════════════════════════════════════════
exports.feexPayWebhook = onRequest({
  // FEEXPAY_TOKEN est requis pour la vérification serveur obligatoire du
  // paiement : sans cette déclaration, `token()` échouerait à l'exécution.
  secrets: [FEEXPAY_WEBHOOK_SECRET, FEEXPAY_TOKEN_SECRET],
}, async (req, res) => {
  // ── Vérification du token secret dans l'URL ──────────────────────────────
  // FeexPay renvoie l'URL telle quelle → le secret est dans ?wh_secret=
  const auth = isAuthorizedWebhookCall({
    method: req.method,
    receivedSecret: req.query.wh_secret,
    expectedSecret: FEEXPAY_WEBHOOK_SECRET.value(),
  });
  if (!auth.ok) {
    // Ne jamais journaliser le secret ni l'URL complète qui le contient.
    if (auth.reason === 'secret_not_configured') {
      console.error('FEEXPAY_WEBHOOK_SECRET manquant — webhook désactivé par sécurité');
      return res.status(503).json({ error: 'Service temporairement indisponible' });
    }
    if (auth.reason === 'invalid_secret') {
      console.error('Webhook : token secret invalide ou manquant');
      await logSecurityEvent('system', 'webhook_invalid_secret', 'high',
        `Tentative webhook avec secret invalide depuis ${req.ip}`);
      return res.status(401).json({ error: 'Non autorisé' });
    }
    return res.status(auth.httpStatus).json({ error: 'Method not allowed' });
  }

  // Le traitement de l'événement (référence, expiration, idempotence, montant,
  // statut inconnu, crédit atomique) vit dans functions/feexpayPayments.js,
  // testable hors ligne — voir functions/test/feexpayPayments.test.js.
  const result = await processFeexPayWebhookEvent({
    db,
    admin,
    body: req.body,
    collectionFor,
    logAudit,
    logSecurityEvent,
    // Vérification serveur OBLIGATOIRE auprès de FeexPay (endpoint officiel
    // /api/transactions/public/single/status/{reference}). Si ce vérificateur
    // venait à manquer, aucun crédit ne serait effectué : le traitement est
    // fail-closed, jamais permissif.
    verifier: createStatusVerifier({
      axios,
      token: () => FEEXPAY_TOKEN_SECRET.value(),
    }),
  });

  // Journalisation sans secret, sans URL complète, sans donnée personnelle.
  console.log(`Webhook FeexPay → outcome=${result.outcome}${result.reason ? ` reason=${result.reason}` : ''}`);
  return res.status(result.httpStatus).json(result.payload);
});


// ═══════════════════════════════════════════════════════════════════════════
// 3. INITIER UN RETRAIT FEEXPAY (Callable Flutter)
// ═══════════════════════════════════════════════════════════════════════════
exports.initiateWithdrawal = onCall({
  secrets: [FEEXPAY_TOKEN_SECRET],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }

  const uid = request.auth.uid;
  // Partenaire créé par l'administration : aucun retrait avant le changement du
  // mot de passe temporaire (contrôle serveur, indépendant de l'application).
  await assertPartnerActivated({ db, request });
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

  // ── Contrôles préalables AU DÉBIT ─────────────────────────────────────────
  // Tout ce qui peut empêcher l'initiation doit être vérifié avant de toucher
  // au solde : un débit suivi d'une initiation impossible laisserait l'argent
  // bloqué dans un état ambigu.
  const preconditions = assertWithdrawalCanStart({ operator, shopId: FEEXPAY_SHOP_ID() });
  if (!preconditions.ok) {
    // Allowlist stricte pour l'opérateur ; `shop` obligatoire côté FeexPay V2
    // et sans valeur par défaut légitime : on échoue proprement, avant tout
    // débit, plutôt que d'en inventer une. La valeur n'est jamais journalisée.
    throw new HttpsError(
      preconditions.code,
      preconditions.reason === 'unknown_operator'
        ? 'Opérateur de retrait non pris en charge'
        : 'Retraits momentanément indisponibles (configuration incomplète)',
    );
  }
  const endpoint = preconditions.endpoint;

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

  // ── Initiation Payout FeexPay V2 ──────────────────────────────────────────
  // Le solde est déjà débité. Une réponse "PENDING / Payout request accepted"
  // ne prouve PAS que l'argent est arrivé : elle ouvre seulement un suivi par
  // référence (checkWithdrawalStatus). Trois issues, jamais confondues :
  //   accepted             → référence obtenue, état NON final à vérifier.
  //   rejected_no_reference→ aucune référence créée : rien n'a pu partir,
  //                          compensation sûre et unique.
  //   ambiguous            → référence présente malgré l'erreur, réseau, 5xx
  //                          ou acceptation sans référence : NE JAMAIS
  //                          rembourser ni relancer, le transfert a pu partir.
  let response = null;
  let error = null;
  try {
    response = await axios.post(
      endpoint.url,
      {
        phoneNumber: phoneStr2,
        amount:      amount,
        shop:        FEEXPAY_SHOP_ID(),
        motif:       sanitizePayoutMotif(`Retrait AZ Express ${withdrawId}`),
      },
      {
        headers: {
          Authorization:  `Bearer ${FEEXPAY_TOKEN_SECRET.value()}`,
          'Content-Type': 'application/json',
        },
        timeout: 20000,
      }
    );
  } catch (err) {
    error = err;
  }

  const verdict = classifyPayoutInitiation({ response, error });
  const wdRef = db.collection('withdrawal_requests').doc(withdrawId);

  if (verdict.outcome === 'rejected_no_reference') {
    // Aucune référence n'existe : FeexPay a refusé avant de créer le payout,
    // donc aucun transfert ne peut aboutir — la compensation est sûre.
    const compensation = await compensateFailedWithdrawal({
      db, admin, withdrawId, collectionFor, logAudit, reason: verdict.reason,
    });
    console.warn(`Payout ${withdrawId} refusé sans référence — compensé=${compensation.compensated}`);
    return { withdrawId, status: 'failed_refunded', auto: false, refunded: compensation.compensated };
  }

  if (verdict.outcome === 'ambiguous') {
    await wdRef.update({
      status:              'pending_manual',
      provider:            'feexpay',
      providerReference:   verdict.reference || null,
      providerStatus:      verdict.providerStatus || null,
      settlementConfirmed: false,
      ambiguous:           true,
      autoRetryBlocked:    true,
      autoError:           verdict.reason,
    });
    await logAudit({
      userId: uid, userType: userType, action: 'withdrawal_ambiguous',
      targetId: withdrawId, amount: amount, status: 'pending_manual',
    });
    console.warn(`Payout ${withdrawId} ambigu (${verdict.reason}) — rapprochement manuel requis`);
    return { withdrawId, status: 'pending_manual', auto: false, ambiguous: true };
  }

  // accepted : référence obtenue, transfert EN COURS — surtout pas final.
  // `nextStatusCheckAt` arme la vérification automatique côté serveur : le
  // retrait se résout même si l'utilisateur ferme l'application.
  await wdRef.update({
    status:              'provider_pending',
    provider:            'feexpay',
    providerReference:   verdict.reference,
    providerStatus:      verdict.providerStatus || 'PENDING',
    settlementConfirmed: false,
    autoRetryBlocked:    true,
    statusCheckCount:    0,
    statusCheckStopped:  false,
    nextStatusCheckAt:   admin.firestore.Timestamp.fromMillis(Date.now() + delayMsForCheck(0)),
  });
  return {
    withdrawId, status: 'provider_pending', auto: true,
    settlementConfirmed: false, providerStatus: verdict.providerStatus || 'PENDING',
  };
});


// ═══════════════════════════════════════════════════════════════════════════
// 3 bis. VÉRIFIER LE STATUT D'UN RETRAIT (Callable — propriétaire ou admin)
//   GET /api/payouts/status/public/{reference} — vérification imposée par la
//   documentation FeexPay après une initiation PENDING. Toute mutation
//   financière reste ici, côté serveur.
// ═══════════════════════════════════════════════════════════════════════════
exports.checkWithdrawalStatus = onCall({
  secrets: [FEEXPAY_TOKEN_SECRET],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  }
  const uid = request.auth.uid;
  const withdrawId = String(request.data?.withdrawId || '').trim();
  if (!withdrawId || withdrawId.includes('/') || withdrawId.length > 200) {
    throw new HttpsError('invalid-argument', 'Identifiant de retrait invalide');
  }

  const wdSnap = await db.collection('withdrawal_requests').doc(withdrawId).get();
  if (!wdSnap.exists) throw new HttpsError('not-found', 'Retrait introuvable');
  const wd = wdSnap.data();

  // Autorisation : le propriétaire du retrait, ou un administrateur actif.
  // Un client ne peut jamais vérifier ni faire évoluer le retrait d'autrui.
  if (wd.userId !== uid) {
    const adminSnap = await db.collection('admins').doc(uid).get();
    if (!adminSnap.exists || adminSnap.data().isActive !== true) {
      throw new HttpsError('permission-denied', 'Accès refusé');
    }
  }
  await checkRateLimit(uid, 'withdrawal_status', 10, 60);

  if (!wd.providerReference) {
    return { withdrawId, status: wd.status, settlementConfirmed: wd.settlementConfirmed === true,
      checked: false, reason: 'no_provider_reference' };
  }

  // Exactement la même logique financière que la vérification automatique :
  // une seule machine d'états, jamais deux implémentations divergentes.
  const result = await verifyAndApplyWithdrawal({
    db, admin, withdrawId, data: wd, collectionFor, logAudit, logSecurityEvent,
    verifier: createPayoutStatusVerifier({
      axios, token: () => FEEXPAY_TOKEN_SECRET.value(),
    }),
  });

  // Jamais de référence, de jeton ni d'URL dans les journaux.
  console.log(`Statut retrait ${withdrawId} → ${result.outcome || result.reason} (${result.state || '—'})`);
  return {
    withdrawId,
    outcome: result.outcome || null,
    state: result.state || null,
    settled: result.state === 'settled',
    refunded: result.state === 'compensated',
    checked: result.checked,
    ...(result.checked ? {} : { reason: result.reason }),
  };
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
  const uniqueTokens = [...new Set(tokens.filter(Boolean))];
  const dataStr = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)]));
  for (let start = 0; start < uniqueTokens.length; start += 500) {
    const tokenBatch = uniqueTokens.slice(start, start + 500);
    try {
      const result = await admin.messaging().sendEachForMulticast({
        tokens: tokenBatch,
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
            console.log(`Token invalide détecté — marqué pour nettoyage: ${tokenBatch[i]?.slice(0, 20)}`);
            // Nettoyage asynchrone non-bloquant
            db.collection('invalid_fcm_tokens').add({
              token: tokenBatch[i], detectedAt: admin.firestore.FieldValue.serverTimestamp(),
            }).catch(() => {});
          }
        }
      });
    } catch (err) {
      console.warn('Multicast FCM error:', err.message);
    }
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
  if (t  === 'courses' || t === 'shopping') return 'courses';
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
//
// QUOTA CLOUD RUN (2026-10-02) : les déclencheurs Firestore de notification
// passent de maxInstances 2 à 1. Le quota régional « total allowable CPU »
// était saturé (178,5 unités pour 83 fonctions), ce qui empêchait TOUTE mise
// à jour : une mise à jour fait coexister l'ancienne et la nouvelle révision,
// et il ne restait plus la marge nécessaire. Sans incidence pratique ici :
// chaque instance sert jusqu'à 80 événements simultanés (concurrence = 80),
// très au-delà du volume réel. Les notifications de chat restent à 3
// (latence ressentie directement par l'utilisateur), et aucune fonction
// appelée par l'app (onCall) n'est réduite. La correction de fond reste une
// augmentation du quota côté console GCP.
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyClientOnOrderCreated = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyClientOnOrderUpdate = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
  try {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return;

    // Changement de livreur sans changement de statut (transfert après
    // récupération) ou remise en file après abandon : le client est prévenu,
    // le suivi pointe sur le nouveau livreur via order.driverId.
    const driverSwapped = before.status === after.status && after.status === 'picked_up' &&
      before.driverId && after.driverId && before.driverId !== after.driverId;
    const requeued = ['accepted', 'assigned'].includes(before.status) && after.status === 'pending' &&
      !!before.driverId && !after.driverId;
    if (driverSwapped || requeued) {
      const cDoc = await db.collection('clients').doc(after.clientId).get();
      const cToken = cDoc.data()?.fcmToken;
      if (!cToken) return;
      await sendToToken(cToken,
        driverSwapped ? '🔁 Nouveau livreur' : '🔎 Nouveau livreur en recherche',
        driverSwapped
          ? 'Votre colis a été confié à un autre livreur. Suivez-le en direct : un nouveau code de livraison sera demandé.'
          : 'Votre livreur ne peut pas poursuivre. Nous cherchons un autre livreur pour votre commande.',
        { type: driverSwapped ? 'driver_changed' : 'driver_reassigned', orderId: event.params.orderId, status: after.status });
      return;
    }
    if (before.status === after.status) return;

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
exports.notifyBroadcastDrivers = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyDriverOnAssigned = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyDriverLowBalance = onDocumentUpdated({ document: 'livreurs/{driverId}', maxInstances: 1 }, async (event) => {
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
exports.notifyDriverOnMissionEnd = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyDriverOnOrderCancelled = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyRestaurantOnOrder = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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

exports.notifyPharmacieOnOrder = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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

exports.notifyBoulangerieOnNewOrder = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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

// Client — suivi de préparation des commandes boulangerie. Ces transitions
// utilisent sellerStatus sans modifier le statut logistique de la commande.
exports.notifyClientOnBoulangeriePreparation = onDocumentUpdated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
  const before = event.data.before.data();
  const after = event.data.after.data();
  if (!before || !after || after.sellerType !== 'boulangerie') return;
  if (before.sellerStatus === after.sellerStatus) return;

  const notifications = {
    preparing: { title: '🥐 Préparation en cours', body: 'La boulangerie prépare votre commande.' },
    ready: { title: '✅ Commande prête', body: 'Votre commande est prête pour la livraison.' },
  };
  const notif = notifications[after.sellerStatus];
  if (!notif || !after.clientId) return;

  const clientDoc = await db.collection('clients').doc(after.clientId).get();
  const token = clientDoc.data()?.fcmToken;
  if (!token) return;

  await sendToToken(token, notif.title, notif.body, {
    type: 'order_update', orderId: event.params.orderId, status: after.sellerStatus,
  });
});

exports.notifySellerOnOrder = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyDriversOnNewOrder = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 1 }, async (event) => {
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
  deposit_proof_sent: { title: '📨 Preuve envoyée',        body: 'Votre preuve est en attente de validation par l’agent.' },
  deposit_confirmed: { title: '✅ Dépôt confirmé',         body: 'Votre agent peut maintenant commencer l’opération.' },
  deposit_rejected: { title: '⚠️ Preuve rejetée',          body: 'Votre agent a rejeté la preuve. Vous pouvez en envoyer une nouvelle.' },
  in_progress:      { title: '⏳ Traitement en cours',     body: 'Votre agent traite votre dossier.' },
  proof_sent:       { title: '📄 Justificatif envoyé',     body: 'Votre agent a envoyé le justificatif. Vérifiez.' },
  completed:        { title: '✅ Transaction terminée',    body: 'Votre demande E-Kbine a été complétée avec succès.' },
  cancelled:        { title: '❌ Demande annulée',         body: 'Votre demande E-Kbine a été annulée.' },
  disputed:         { title: '⚠️ Litige ouvert',           body: 'Un litige a été signalé sur votre dossier.' },
};

// ─── Client — Confirmation à la création ────────────────────────────────────
exports.notifyEkClientOnOrderCreated = onDocumentCreated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyEkClientOnStatusChange = onDocumentUpdated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyEkAgentsOnNewOrder = onDocumentCreated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
  const order = event.data.data();
  if (!order || order.status !== 'pending') return;

  // Chercher les agents en ligne — `isActive` n'a jamais existé dans le
  // schéma réel de ekbine_agents (seuls isOnline/isVerified/isSuspended/
  // subscriptionStatus existent), donc cette requête ne renvoyait jamais
  // aucun document depuis l'origine : aucun agent n'a jamais reçu cette
  // notification. `isOnline` est le champ réel déjà utilisé partout
  // ailleurs (toggleAgentOnline, streamPendingForAgent). L'éligibilité
  // complète (isVerified/isSuspended/subscriptionStatus) reste de toute
  // façon revérifiée par isEligibleAgent() au moment de l'acceptation
  // (ekbineAcceptOrder) — être notifié n'accorde aucun droit en soi.
  const agentsSnap = await db.collection('ekbine_agents')
    .where('isOnline', '==', true)
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
exports.notifyEkAgentOnAssigned = onDocumentUpdated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
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
exports.notifyEkAgentOnCompleted = onDocumentUpdated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
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
    { type: 'ek_mission_end', orderId: event.params.orderId }
  );
});


// ═══════════════════════════════════════════════════════════════════════════
// 4. RÉINITIALISATION MOT DE PASSE / PIN (Callable Flutter)
//    Appelé depuis GenericForgotPasswordPage après vérification OTP
// ═══════════════════════════════════════════════════════════════════════════
// Master Prompt 122 — quota CPU Cloud Run régional : fonction utilisateur
// secondaire (Groupe B), réduction légère de maxInstances uniquement (cpu
// inchangé, l'utilisateur attend une réponse en direct sur cet écran).
exports.resetAccountPassword = onCall({ maxInstances: 2 }, buildResetAccountPassword({
  db,
  auth: admin.auth(),
  fieldValue: admin.firestore.FieldValue,
  hashSecret,
  checkRateLimit,
}));
// maxInstances 5 → 2 : même raison de quota Cloud Run que ci-dessus.
exports.manageProfessionalSubscription = onCall({ maxInstances: 2 },
  buildManageProfessionalSubscription({
    db,
    auth: admin.auth(),
    timestamp: admin.firestore.Timestamp,
    fieldValue: admin.firestore.FieldValue,
  }));
/* Ancienne implementation desactivee: elle ne garantissait pas une resolution
 * unique du numero verifie vers l'UID Firebase Auth cible.
const resetAccountPasswordLegacy = async (request) => {
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
*/


// ═══════════════════════════════════════════════════════════════════════════
// LOOKUP TÉLÉPHONE CLIENT — remplace deux requêtes Firestore directes côté
// client (clients.where('phone', isEqualTo:...)) qui échouaient toujours avec
// permission-denied : la règle firestore.rules sur `clients` n'autorise que
// isOwner(clientId) (lecture d'un document par son propre propriétaire), donc
// structurellement incompatible avec une requête filtrée sur un autre champ que
// l'ID du document, quel que soit l'état d'authentification de l'appelant.
// Utilisé par : (1) client_auth_page.dart, vérification de doublon à
// l'inscription ; (2) auth_service.dart:getClientAuthEmail, résolution
// téléphone→email pour la connexion par numéro. Ne renvoie que le strict
// nécessaire (existence + email), jamais le document `clients` complet
// (wallet/nom/etc. restent privés) — pas d'assouplissement de firestore.rules.
// ═══════════════════════════════════════════════════════════════════════════
// Master Prompt 122 — quota CPU Cloud Run régional : Groupe B, réduction
// légère de maxInstances uniquement.
exports.checkClientPhone = onCall({ maxInstances: 2 }, async (request) => {
  const { phone } = request.data;
  if (!phone || typeof phone !== 'string') {
    throw new HttpsError('invalid-argument', 'Numéro de téléphone requis');
  }

  await checkRateLimit(`phone_check_${phone}`, 'client_phone_check', 10, 300);

  const snap = await db.collection('clients').where('phone', '==', phone).limit(1).get();
  if (snap.empty) return { exists: false, email: null };

  const data = snap.docs[0].data();
  const email = typeof data.email === 'string' ? data.email : null;
  const isRealEmail = email && !email.includes('@azexpress.app');
  return { exists: true, email: isRealEmail ? email : null };
});

// ═══════════════════════════════════════════════════════════════════════════
// PRESTATAIRES DE SERVICES (artisans) — inscription et connexion.
// `service_providers` a `allow write: if isAdmin();` (annuaire géré par
// l'admin), sans exception de création pour un prestataire s'inscrivant
// lui-même — service_provider_register_page.dart écrivait donc directement
// depuis le client et échouait à 100% en permission-denied. Le login a le
// même problème pour la liaison artisanUid : le commentaire déjà présent
// dans firestore.rules (« isRealUser() casserait le login » — artisan_login.dart
// utilise signInAnonymously() explicitement) documentait déjà ce gap sans le
// combler. Les deux write passent désormais par l'Admin SDK, sans aucun
// assouplissement de firestore.rules/storage.rules.
// ═══════════════════════════════════════════════════════════════════════════
// Master Prompt 122 — quota CPU Cloud Run régional : Groupe C, réduction
// modérée de maxInstances, cpu inchangé.
exports.submitServiceProviderApplication = onCall({ maxInstances: 2 }, async (request) => {
  // Forme et taille des champs validées avant toute écriture (module testé).
  const { name, phone, address, description, subcategory, category, photos, lat, lng, docId } =
    sanitizeApplication(request.data);

  await enforceApplicationLimits({ checkRateLimit, request, phone });

  // Réutilise l'ID généré côté client (avant l'appel, pour uploader les
  // photos au bon chemin Storage service_providers/{docId}/...) si fourni.
  const docRef = docId ? db.collection('service_providers').doc(String(docId))
                        : db.collection('service_providers').doc();

  // Une seule demande ou un seul compte par numéro (hors demande refusée) :
  // un réessai de la MÊME demande renvoie le même identifiant ; l'ancien
  // `set()` écrasait n'importe quel document dont l'identifiant était connu.
  const sameNumber = await db.collection('service_providers')
    .where('phone', '==', phone).limit(10).get();
  const blocking = sameNumber.docs.filter((d) => d.data().status !== 'rejected');
  if (blocking.some((d) => d.id === docRef.id)) return { docId: docRef.id };
  if (blocking.length > 0) {
    throw new HttpsError('already-exists', 'Une demande ou un compte existe déjà pour ce numéro');
  }

  await docRef.create({
    name, phone, address, description, subcategory, category, photos, lat, lng,
    isAvailable: false,
    isVerified:  false,
    status:      'pending',
    rating:      0,
    ratingCount: 0,
    // LOT 6.2 SECURITY : plus de placeholder artisanPin ici — le PIN n'est
    // désormais jamais présent en clair sur ce document, même vide ; il est
    // défini exclusivement par setArtisanPin (haché, artisan_credentials)
    // au moment de l'approbation.
    createdAt:   admin.firestore.FieldValue.serverTimestamp(),
  });

  return { docId: docRef.id };
});

// LOT 6 SECURITY (2026-09) — ne compare plus jamais le PIN en clair via une
// requête Firestore directe (`where('artisanPin','==',pin)`), qui exigeait
// structurellement que le PIN reste lisible en clair dans le document
// (et l'était : service_providers a `allow read: if isAuth()`, donc N'IMPORTE
// QUEL utilisateur authentifié pouvait lire le PIN de n'importe quel artisan
// simplement en lisant son document — confirmé exploitable, pas théorique).
// Recherche désormais par téléphone seul, puis vérifie le PIN contre
// artisan_credentials/{providerId} (haché, CF-only, jamais exposé par les
// Repli public uniquement en absence de credential prive.
// LOT 7.4 phase A : les comptes historiques restent acceptes sans creation
// de credential ni suppression du PIN public. Aucune migration au login.
// Master Prompt 122 — quota CPU Cloud Run régional : Groupe B, réduction
// légère de maxInstances uniquement.
const { buildArtisanLogin, buildSetArtisanPin } = require('./artisanAccounts');
const { sanitizeApplication, enforceApplicationLimits } = require('./serviceProviderApplication');
exports.artisanLogin = onCall({ maxInstances: 2 }, buildArtisanLogin({
  db, checkRateLimit,
}));
exports.setArtisanPin = onCall({ maxInstances: 2 }, buildSetArtisanPin({
  db, fieldValue: admin.firestore.FieldValue,
}));

// ═══════════════════════════════════════════════════════════════════════════
// AUTHENTIFICATION PHARMACIE — mot de passe haché (pharmacie_credentials)
// Remplace la comparaison en clair historique (voir commentaire dans
// firestore.rules match /pharmacies/{pharmacieId}, "Phase 5"). Migration
// paresseuse : au premier login réussi d'une pharmacie encore sur l'ancien
// champ password/accessCode en clair, on hache et on supprime le champ en clair.
// ═══════════════════════════════════════════════════════════════════════════
// Master Prompt 122 — quota CPU Cloud Run régional : Groupe B, réduction
// légère de maxInstances uniquement.
exports.pharmacieLogin = onCall({ maxInstances: 2 }, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Authentification requise');
  }
  const { pharmacieId, password } = request.data;
  if (!pharmacieId || !password) {
    throw new HttpsError('invalid-argument', 'Paramètres manquants');
  }

  await checkRateLimit(`pharmacie_${pharmacieId}`, 'pharmacie_login', 10, 300);

  const pharmacieRef  = db.collection('pharmacies').doc(String(pharmacieId));
  const pharmacieSnap = await pharmacieRef.get();
  if (!pharmacieSnap.exists) return { success: false };
  const data = pharmacieSnap.data();

  if (data.isDeleted === true) return { success: false };

  const credRef  = db.collection('pharmacie_credentials').doc(pharmacieId);
  const credSnap = await credRef.get();

  if (credSnap.exists) {
    const ok = verifySecret(password, credSnap.data().hash);
    if (!ok) return { success: false };
    // La liaison de session est créée uniquement après preuve du mot de passe.
    // Les règles Firestore peuvent ensuite autoriser ce seul propriétaire à
    // actualiser fcmToken sans permettre une auto-attribution cross-user.
    await pharmacieRef.update({ currentUid: request.auth.uid });
    return { success: true, mustChangePassword: data.mustChangePassword === true };
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
    currentUid: request.auth.uid,
  });

  return { success: true, mustChangePassword: data.mustChangePassword === true };
});

// Définit/réinitialise le mot de passe d'une pharmacie — appelable par un
// admin (n'importe quelle pharmacie) ou par la pharmacie elle-même (son
// propre mot de passe, session liée via `currentUid`, même mécanisme que la
// règle Firestore existante pour ce champ).
// Master Prompt 122 — quota CPU Cloud Run régional : Groupe B, réduction
// légère de maxInstances uniquement.
exports.setPharmaciePassword = onCall({ maxInstances: 2 }, async (request) => {
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

  const isCallerOwner  = pharmacieSnap.data().currentUid === uid;
  let isCallerAdmin = false;
  if (!isCallerOwner) {
    await requireAdminPermission({ request, db, permission: 'pharmacies' });
    isCallerAdmin = true;
  } else {
    try {
      await requireAdminPermission({ request, db, permission: 'pharmacies' });
      isCallerAdmin = true;
    } catch (_) {
      // The linked pharmacy owner retains the established self-service flow.
    }
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

// Master Prompt 122 — quota CPU Cloud Run régional : Groupe C, réduction
// modérée de maxInstances, cpu inchangé.
exports.createSubAdmin = onCall({ maxInstances: 2 }, async (request) => {
  await requireSuperAdmin({ request, db });

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

exports.deleteSubAdmin = onCall({ maxInstances: 2 }, async (request) => {
  await requireSuperAdmin({ request, db });

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
exports.notifyAdminsOnNewDriver = onDocumentCreated({ document: 'livreurs/{driverId}', maxInstances: 1 }, async (event) => {
  const driver = event.data.data();
  if (!driver) return;
  const snap = await db.collection('admins').where('isActive', '==', true).get();
  const tokens = snap.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
  if (!tokens.length) return;
  await sendToMultipleTokens(tokens,
    '🛵 Nouvelle demande livreur',
    `${driver.name ?? 'Nouveau livreur'} vient de s'inscrire. Vérifiez sa demande.`,
    { type: 'admin_new_driver', driverId: event.params.driverId }
  );
});

// ─── Notify admins on new service provider pending request ───────────────────
exports.notifyAdminsOnNewServiceProvider = onDocumentCreated({ document: 'service_providers/{id}', maxInstances: 1 }, async (event) => {
  const provider = event.data.data();
  if (!provider || provider.status !== 'pending') return;
  const snap = await db.collection('admins').where('isActive', '==', true).get();
  const tokens = snap.docs.map(d => d.data().fcmToken).filter(t => t?.length > 10);
  if (!tokens.length) return;
  await sendToMultipleTokens(tokens,
    '🏪 Nouveau prestataire en attente',
    `${provider.name ?? 'Un prestataire'} (${provider.subcategory ?? ''}) attend votre approbation.`,
    { type: 'admin_new_service_provider', providerId: event.params.id }
  );
});

// ═══════════════════════════════════════════════════════════════════════════

exports.notifyClientOnRecharge = onDocumentUpdated({ document: 'recharge_requests/{reqId}', maxInstances: 1 }, async (event) => {
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

exports.notifyEkAgentOnDepositProof = onDocumentUpdated({ document: 'ekbine_orders/{orderId}', maxInstances: 1 }, async (event) => {
  const before = event.data.before.data();
  const after = event.data.after.data();
  if (!before || !after || before.status === 'deposit_proof_sent' || after.status !== 'deposit_proof_sent') return;
  if (!after.agentId) return;
  const agent = await db.collection('ekbine_agents').doc(after.agentId).get();
  const token = agent.data()?.fcmToken;
  if (!token) return;
  await sendToToken(token, '📨 Preuve de dépôt reçue', 'Vérifiez la preuve avant de confirmer la réception.', {
    type: 'ek_deposit_proof', orderId: event.params.orderId,
  });
});

// E-Kbine deposit gate. These callables own every transition before service
// execution so a client cannot self-confirm and an agent cannot start early.
exports.ekbineAcceptOrder = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
  const orderId = request.data?.orderId;
  if (typeof orderId !== 'string') throw new HttpsError('invalid-argument', 'orderId manquant');
  const agentId = request.auth.uid;
  const orderRef = db.collection('ekbine_orders').doc(orderId);
  const agentRef = db.collection('ekbine_agents').doc(agentId);
  await db.runTransaction(async (tx) => {
    const [orderSnap, agentSnap] = await Promise.all([tx.get(orderRef), tx.get(agentRef)]);
    if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
    if (!agentSnap.exists) throw new HttpsError('permission-denied', 'Agent introuvable');
    const order = orderSnap.data();
    const agent = agentSnap.data();
    if (order.status !== 'pending') throw new HttpsError('failed-precondition', 'Commande non disponible');
    if (!isEligibleAgent(agent)) throw new HttpsError('permission-denied', 'Agent non éligible');
    const depositAccount = selectDepositAccount(agent, order.operator);
    if (!depositAccount) throw new HttpsError('failed-precondition', 'Aucun numéro valide pour cet opérateur');
    tx.update(orderRef, {
      agentId,
      agentName: String(agent.name || 'Agent E-Kbine'),
      agentPhone: String(agent.phone || ''),
      // Immutable snapshots: instructions cannot change when an agent edits profile.
      agentDepositAccountId: depositAccount.id,
      agentDepositNumber: depositAccount.phoneNumber,
      agentDepositOperator: order.operator,
      status: 'awaiting_deposit',
      assignedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { success: true };
});

// Only the authenticated agent can change deposit accounts. Historical
// operatorNumbers are retained; this callable migrates them on first save.
exports.ekbineUpdateDepositAccounts = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
  const incoming = request.data?.depositAccounts;
  if (!Array.isArray(incoming) || incoming.length > 20) {
    throw new HttpsError('invalid-argument', 'Liste de numéros invalide');
  }
  const validOperators = new Set(['orange', 'mtn', 'moov', 'wave']);
  const agentRef = db.collection('ekbine_agents').doc(request.auth.uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(agentRef);
    if (!snap.exists) throw new HttpsError('not-found', 'Agent introuvable');
    const seen = new Set();
    const primaryByOperator = new Set();
    const normalized = incoming.map((raw) => {
      const operator = String(raw?.operator || '').toLowerCase();
      const phoneNumber = String(raw?.phoneNumber || '').replace(/[^0-9]/g, '').replace(/^225/, '');
      if (!validOperators.has(operator) || phoneNumber.length < 8 || phoneNumber.length > 12) {
        throw new HttpsError('invalid-argument', 'Numéro ou opérateur invalide');
      }
      const key = `${operator}:${phoneNumber}`;
      if (seen.has(key)) throw new HttpsError('already-exists', 'Numéro de dépôt en double');
      seen.add(key);
      const isActive = raw?.isActive !== false;
      const isPrimary = raw?.isPrimary === true && isActive;
      if (isPrimary && primaryByOperator.has(operator)) {
        throw new HttpsError('failed-precondition', 'Un seul numéro principal actif par opérateur');
      }
      if (isPrimary) primaryByOperator.add(operator);
      return {
        id: typeof raw?.id === 'string' && raw.id.length <= 80 ? raw.id : crypto.randomUUID(),
        operator, phoneNumber, label: typeof raw?.label === 'string' ? raw.label.trim().slice(0, 60) : null,
        isPrimary, isActive, updatedAt: admin.firestore.Timestamp.now(),
      };
    });
    if (!normalized.some((account) => account.isActive)) {
      throw new HttpsError('failed-precondition', 'Au moins un numéro actif est requis');
    }
    const legacy = snap.data().operatorNumbers || {};
    for (const [operator, number] of Object.entries(legacy)) {
      if (!normalized.some((account) => account.operator === operator && account.phoneNumber === String(number).replace(/[^0-9]/g, '').replace(/^225/, ''))) {
        normalized.push({ id: `legacy_${operator}`, operator, phoneNumber: String(number).replace(/[^0-9]/g, '').replace(/^225/, ''), label: 'Historique', isPrimary: false, isActive: true, updatedAt: admin.firestore.Timestamp.now() });
      }
    }
    tx.update(agentRef, { depositAccounts: normalized, depositAccountsUpdatedAt: admin.firestore.FieldValue.serverTimestamp() });
  });
  return { success: true };
});

exports.ekbineSubmitDepositProof = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
  const { orderId, depositProofUrl, transactionReference } = request.data || {};
  if (typeof orderId !== 'string' || typeof depositProofUrl !== 'string' || depositProofUrl.length > 2048) {
    throw new HttpsError('invalid-argument', 'Preuve de dépôt invalide');
  }
  const ref = db.collection('ekbine_orders').doc(orderId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError('not-found', 'Commande introuvable');
    const order = snap.data();
    if (order.clientId !== request.auth.uid) throw new HttpsError('permission-denied', 'Non autorisé');
    if (!['awaiting_deposit', 'deposit_rejected'].includes(order.status)) {
      throw new HttpsError('failed-precondition', 'La preuve ne peut pas être envoyée maintenant');
    }
    tx.update(ref, {
      depositProofUrl,
      transactionReference: typeof transactionReference === 'string' ? transactionReference.trim().slice(0, 100) : null,
      depositRejectionReason: admin.firestore.FieldValue.delete(),
      status: 'deposit_proof_sent',
      depositProofSentAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { success: true };
});

exports.ekbineAgentDepositAction = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Authentification requise');
  const { orderId, action, rejectionReason } = request.data || {};
  if (typeof orderId !== 'string' || !['confirm', 'reject', 'start'].includes(action)) {
    throw new HttpsError('invalid-argument', 'Action de dépôt invalide');
  }
  const ref = db.collection('ekbine_orders').doc(orderId);
  const agentRef = db.collection('ekbine_agents').doc(request.auth.uid);
  let alreadyConfirmed = false;
  await db.runTransaction(async (tx) => {
    const [snap, agentSnap] = await Promise.all([tx.get(ref), tx.get(agentRef)]);
    if (!snap.exists || !agentSnap.exists) throw new HttpsError('not-found', 'Commande ou agent introuvable');
    const order = snap.data();
    if (order.agentId !== request.auth.uid || !isEligibleAgent(agentSnap.data())) {
      throw new HttpsError('permission-denied', 'Agent non autorisé');
    }
    if (action === 'confirm') {
      if (order.status === 'deposit_confirmed') { alreadyConfirmed = true; return; }
      if (order.status !== 'deposit_proof_sent' || !order.depositProofUrl) {
        throw new HttpsError('failed-precondition', 'Aucune preuve à confirmer');
      }
      tx.update(ref, { status: 'deposit_confirmed', depositConfirmedAt: admin.firestore.FieldValue.serverTimestamp() });
    } else if (action === 'reject') {
      if (order.status !== 'deposit_proof_sent') throw new HttpsError('failed-precondition', 'Preuve non rejetable');
      tx.update(ref, {
        status: 'deposit_rejected',
        depositRejectionReason: typeof rejectionReason === 'string' ? rejectionReason.trim().slice(0, 300) : 'Preuve non validée',
        depositRejectedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      if (order.status !== 'deposit_confirmed') throw new HttpsError('failed-precondition', 'Dépôt non confirmé');
      tx.update(ref, { status: 'in_progress', startedAt: admin.firestore.FieldValue.serverTimestamp() });
    }
  });
  return { success: true, alreadyConfirmed };
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
  // Master Prompt 122 — quota CPU Cloud Run régional : un seul déclenchement
  // cron à la fois, jamais de concurrence réelle nécessaire (et ça protège
  // contre un chevauchement si une exécution dépasse 1 minute). cpu laissé
  // à 1 (inchangé) — cette fonction touche des remboursements wallet et
  // tourne 1440 fois/jour, traitée avec plus de prudence que les autres
  // schedulers (Groupe D) qui, eux, passent aussi à cpu:0.5.
  maxInstances:   1,
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
      // Transaction atomique — protège contre la race condition avec acceptOrder().
      // Logique (annulation, remboursement client, reprise vendeur, métriques)
      // dans orderRefunds.js pour être testée.
      await db.runTransaction((tx) => expireOrderTx(tx, { db, admin, orderRef: doc.ref, orderId }));

      // Re-read terminal state and compare each reference transactionally.
      // If acceptance won the race, this does nothing.
      await settleTerminalOrder(db, admin, orderId, order);

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
exports.enforceOrderRateLimit = onDocumentCreated({ document: 'orders/{orderId}', maxInstances: 3 }, async (event) => {
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
    await db.runTransaction((tx) => rateLimitCancelTx(tx, { db, admin, orderRef, orderId, order, clientId }));

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
const {
  dispatchOrder,
  calculateCommission,
  DispatchError,
  assertValidDispatchPoint,
} = require('./dispatch');

exports.dispatchOrderToDriver = onCall({ maxInstances: 3 }, async (request) => {
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
    await requireAdminPermission({ request, db, permission: 'commandes' });
    isCallerAdmin = true;
  }
  if (!isOwner && !isCallerAdmin) {
    throw new HttpsError('permission-denied', 'Non autorisé');
  }

  const lat    = Number(order.latitude ?? order.deliveryLatitude ?? 0);
  const lng    = Number(order.longitude ?? order.deliveryLongitude ?? 0);
  const destLat = Number(order.destLat ?? 0);
  const destLng = Number(order.destLng ?? 0);
  const budget = Number(order.budget || 0);
  const pickupCityId = order.pickupCityId;
  const cityResolutionStatus = order.cityResolutionStatus;

  let result;
  try {
    assertValidDispatchPoint(lat, lng, 'collecte');
    assertValidDispatchPoint(destLat, destLng, 'livraison');
    result = await dispatchOrder(db, admin, {
      orderId: String(orderId),
      lat,
      lng,
      pickupCityId,
      cityResolutionStatus,
      budget,
      ...(typeof radiusKm === 'number' ? { radiusKm } : {}),
    });
  } catch (error) {
    if (error instanceof DispatchError) {
      throw new HttpsError('failed-precondition', error.message, {
        dispatchCode: error.code,
      });
    }
    throw error;
  }

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
const {
  buildPayOrderFromWallet,
  buildCancelOrder,
  buildDeliverOrder,
  buildDeliverOrderWithProof,
  buildPayBoutiqueOrder,
  buildPayBoutiqueOrderCash,
  buildRefundExpiredBoutiqueOrder,
} = require('./orderActions');
const {
  buildPrepareOrderProof,
  buildConfirmPickupWithProof,
} = require('./deliveryProofs');

exports.payOrderFromWalletCF = buildPayOrderFromWallet({ db, admin, onCall: (h) => onCall({ maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit });
exports.cancelOrderCF        = buildCancelOrder({ db, admin, onCall: (h) => onCall({ maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit, calculateCommission });
exports.deliverOrderCF       = buildDeliverOrder({ db, admin, onCall: (o, h) => onCall({ ...o, maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit });
exports.acceptOrderCF        = buildAcceptOrder({
  db, admin, onCall: (h) => onCall({ maxInstances: 5 }, h), HttpsError, checkRateLimit, logAudit, calculateCommission,
  selfieExists: async (path) => (await admin.storage().bucket().file(path).exists())[0],
});
exports.adminDriverRechargeCF = buildAdminDriverRecharge({
  db, admin, onCall: (h) => onCall({ maxInstances: 2 }, h), HttpsError, checkRateLimit, logAudit, requireAdminPermission,
});
exports.completeManualAccountDeletionCF = buildManualAccountDeletion({
  db, auth: admin.auth(), admin, bucket: { deleteFiles: (options) => admin.storage().bucket().deleteFiles(options) },
  onCall: (h) => onCall({ maxInstances: 1, cpu: 1, timeoutSeconds: 300, memory: '512MiB' }, h), HttpsError, checkRateLimit, logAudit, requireSuperAdmin,
});
exports.manageArtisanPhotosCF = buildManageArtisanPhotos({
  db, admin, bucket: { get name() { return admin.storage().bucket().name; }, file: (path) => admin.storage().bucket().file(path) }, onCall: (h) => onCall({ maxInstances: 2, cpu: 0.5, memory: '512MiB' }, h), HttpsError, checkRateLimit, logAudit,
});
exports.createFleetDriverCF = buildCreateFleetDriver({
  db, auth: admin.auth(), admin, onCall: (h) => onCall({ maxInstances: 2, cpu: 0.5 }, h), HttpsError, checkRateLimit, logAudit,
});
exports.declineLegacyOrderCF = buildDeclineLegacyOrder({
  db, admin, onCall: (h) => onCall({ maxInstances: 2 }, h), HttpsError, checkRateLimit, logAudit, dispatchOrder, DispatchError,
});
exports.deliveryTransferCF = buildDeliveryTransfer({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
  // Push FCM aux livreurs candidats ; le client est prévenu par notifyClientOnOrderUpdate.
  notify: async ({ collection, ids, event, orderId }) => {
    if (event !== 'transfer_requested' || !Array.isArray(ids)) return;
    for (const id of ids) {
      const token = (await db.collection(collection).doc(id).get()).data()?.fcmToken;
      if (token) await sendToToken(token, '🔁 Remplacement demandé',
        'Un livreur de votre ville cherche un remplaçant. Ouvrez l’application pour accepter.',
        { type: 'transfer_requested', orderId });
    }
  },
});
exports.settleTransferEarningsCF = buildSettleTransferEarnings({
  db, admin, onCall: (h) => onCall({ maxInstances: 2 }, h), HttpsError, checkRateLimit, logAudit, requireSuperAdmin,
});
// Examen administratif Marketplace / Boutique (livraison bloquée, frais retenus
// après récupération, remboursement boutique) — super-admin uniquement.
exports.adminBillingCF = buildAdminBilling({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, requireSuperAdmin, calculateCommission,
});
exports.releaseOrderBeforePickupCF = buildReleaseOrderBeforePickup({
  db, admin, onCall: (h) => onCall({ maxInstances: 2 }, h), HttpsError, checkRateLimit, logAudit,
  calculateCommission, dispatchOrder, DispatchError,
});
exports.prepareOrderProof    = buildPrepareOrderProof({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
});
exports.confirmOrderPickupWithProof = buildConfirmPickupWithProof({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
});
exports.confirmOrderDeliveryWithProof = buildDeliverOrderWithProof({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
});
const recipientProofAccess = require('./deliveryProofGuests').buildRecipientProofAccess({
  db, admin, onCall, HttpsError, checkRateLimit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
});
exports.createRecipientProofAccess = recipientProofAccess.create;
exports.redeemRecipientProofAccess = recipientProofAccess.redeem;
const deliveryProofSms = require('./deliveryProofSms').buildDeliveryProofSms({
  db, admin, onCall, HttpsError, checkRateLimit,
  deliveryProofPepper: DELIVERY_PROOF_PEPPER_SECRET,
});
exports.configureDeliverySms = deliveryProofSms.configure;
exports.markDeliverySmsArrival = deliveryProofSms.arrival;
exports.getDeliverySmsStatus = deliveryProofSms.status;
exports.retryDeliverySms = deliveryProofSms.retry;
exports.dispatchDeliverySms = onDocumentUpdated({
  document: 'delivery_proofs/{sessionId}', maxInstances: 1, retry: true,
  secrets: [DELIVERY_PROOF_PEPPER_SECRET],
}, async event => {
  if (process.env.DELIVERY_SMS_ENABLED !== 'true' || process.env.DELIVERY_PROOFS_ENABLED !== 'true') return;
  const state = event.data?.after.data();
  if (event.params.sessionId.startsWith('sms_') && state?.status === 'queued' && typeof state.orderId === 'string') {
    await deliveryProofSms.dispatch(state.orderId);
  }
});

exports.payBoutiqueOrderCF   = buildPayBoutiqueOrder({ db, admin, onCall: (h) => onCall({ maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit, dispatchOrder });
exports.payBoutiqueOrderCashCF = buildPayBoutiqueOrderCash({ db, admin, onCall: (h) => onCall({ maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit, dispatchOrder });
exports.refundExpiredBoutiqueOrderCF = buildRefundExpiredBoutiqueOrder({ db, admin, onCall: (h) => onCall({ maxInstances: 3 }, h), HttpsError, checkRateLimit, logAudit });

// LOT 6.3 SECURITY — voir functions/eventReservations.js : totalAmount
// désormais recalculé côté serveur à partir des vrais prix event_offers,
// jamais confiance au prix/quantité fournis par le client.
const { buildCreateEventReservation } = require('./eventReservations');
exports.createEventReservationCF = buildCreateEventReservation({ db, admin, onCall, HttpsError, checkRateLimit });


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
  // Master Prompt 122 — quota CPU Cloud Run régional : scheduler hebdomadaire,
  // une seule instance nécessaire, tâche de nettoyage légère.
  maxInstances:   1,
  cpu:            0.5,
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
// SCHEDULER — Correction des livreurs "en ligne" fantômes (audit dispatch,
// 2026-07-19). `dispatch.js` exclut déjà correctement du dispatch tout
// livreur dont le GPS est obsolète, mais rien ne corrigeait jamais le flag
// `isOnline` lui-même — un livreur dont l'app a disparu sans `goOffline()`
// restait visible "en ligne" indéfiniment (tableau de bord admin, carte
// client), invisible au dispatch réel, sans aucune alerte. Voir
// functions/staleDriverCleanup.js.
// ═══════════════════════════════════════════════════════════════════════════
const { buildStaleDriverCleanup } = require('./staleDriverCleanup');
exports.staleDriverCleanupCheck = buildStaleDriverCleanup({ db, admin, onSchedule });

// Libère le livreur remplaçant (et le verrou de la commande) quand une remise
// n'est pas confirmée à temps. Même discipline de quota que les autres crons.
exports.expireDeliveryTransfers = onSchedule({
  schedule: 'every 5 minutes', timeZone: 'Africa/Abidjan', region: 'europe-west1',
  timeoutSeconds: 120, memory: '256MiB', maxInstances: 1, cpu: 0.5,
}, async () => {
  try {
    const r = await expireDueTransfers(db, admin);
    if (r.expired > 0) console.log(`[expireDeliveryTransfers] ${r.expired} transfert(s) expiré(s)`);
  } catch (e) {
    console.error('[expireDeliveryTransfers]', e.message);
  }
});


// ═══════════════════════════════════════════════════════════════════════════
// SUPERVISION ADMIN DES EXÉCUTIONS D'OUTILS AZ IA — LECTURE SEULE
// `ai_tool_executions` reste fermée aux clients dans firestore.rules ; cet
// endpoint lit via l'Admin SDK après contrôle serveur de l'identité et de la
// permission admin. Aucune mutation n'est exposée (ni relance, ni suppression).
// ═══════════════════════════════════════════════════════════════════════════
const { buildListAiToolExecutions } = require('./aiToolExecutions');
exports.listAiToolExecutions = buildListAiToolExecutions({ db, onCall, HttpsError });


// ═══════════════════════════════════════════════════════════════════════════
// VÉRIFICATION AUTOMATIQUE DES RETRAITS FEEXPAY EN ATTENTE
// Consulte uniquement l'endpoint de STATUT avec une référence déjà obtenue —
// jamais une ré-initiation de payout. Ne dépend pas de l'application mobile.
// ═══════════════════════════════════════════════════════════════════════════
exports.checkPendingWithdrawals = buildPendingWithdrawalChecker({
  db, admin, onSchedule, collectionFor, logAudit, logSecurityEvent,
  secrets: [FEEXPAY_TOKEN_SECRET],
  createVerifier: () => createPayoutStatusVerifier({
    axios, token: () => FEEXPAY_TOKEN_SECRET.value(),
  }),
});


// ═══════════════════════════════════════════════════════════════════════════
// AZ IA — Assistant conversationnel (Claude)
// Configurer ANTHROPIC_API_KEY dans Secret Manager.
// ═══════════════════════════════════════════════════════════════════════════
const createAzIa = require('./azia');
const azIa       = createAzIa({
  db, admin, onCall, onSchedule, checkRateLimit, logAudit, HttpsError,
  axios, feexpayOperatorCode,
  FEEXPAY_TOKEN: FEEXPAY_TOKEN_SECRET,
  FEEXPAY_API_URL,
  WEBHOOK_URL: feexpayWebhookUrl,
  // Moindre privilège, vérifié par lecture des appelants réels :
  // `azIaChat` est la SEULE fonction qui appelle un modèle (aiGateway →
  // AIProviderService → providers), donc la seule à recevoir les clés IA.
  // Elle ne reçoit en revanche AUCUN secret FeexPay : dans `tools/wallet.js`,
  // `FEEXPAY_TOKEN.value()` et `WEBHOOK_URL()` sont appelés uniquement depuis
  // `afterConfirm`, exécuté par `aiConfirmAction` — jamais par le tour de
  // conversation. Le `handler` ne fait que créer une action en attente.
  // Cible actée : Claude principal + Gemini en repli. Les quatre autres
  // fournisseurs restent implémentés et sélectionnables par configuration,
  // mais leurs clés ne sont PAS montées ici : non requises au déploiement, et
  // un fournisseur sans clé est sauté sans aucun appel réseau
  // (`isConfigured()` → ProviderNotConfiguredError, jamais de requête).
  // Pour en activer un plus tard : créer son secret, l'ajouter à cette liste
  // ET l'ajouter à `fallbackProviders` (settings/ai ou AI_FALLBACK_PROVIDERS).
  azIaChatSecrets: [
    ANTHROPIC_API_KEY_SECRET,
    GEMINI_API_KEY_SECRET,
  ],
  // `aiConfirmAction` exécute les `afterConfirm` : elle a besoin de FeexPay
  // (recharge wallet) et d'aucune clé IA — elle n'appelle jamais de modèle.
  aiConfirmActionSecrets: [FEEXPAY_TOKEN_SECRET, FEEXPAY_WEBHOOK_SECRET],
  sendToToken,
});
exports.azIaChat                       = azIa.azIaChat;
exports.aiConfirmAction                = azIa.aiConfirmAction;
exports.aiCleanupExpiredPendingActions = azIa.aiCleanupExpiredPendingActions;
exports.clearAiHistory                 = azIa.clearAiHistory;
exports.aiSendDueReminders             = azIa.aiSendDueReminders;


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

// ÉVÉNEMENTIEL — réservations et messagerie
const { createEventNotificationFunctions } = require('./eventNotifications');
const eventNotifications = createEventNotificationFunctions({
  db, onDocumentCreated, onDocumentUpdated, sendToToken,
});
exports.notifyAdminsOnEventProviderApplication =
  eventNotifications.notifyAdminsOnEventProviderApplication;
exports.notifyProvidersOnEventReservation =
  eventNotifications.notifyProvidersOnEventReservation;
exports.notifyClientOnEventReservationUpdate =
  eventNotifications.notifyClientOnEventReservationUpdate;
exports.notifyEventChatRecipient =
  eventNotifications.notifyEventChatRecipient;
exports.updateEventProviderRating =
  eventNotifications.updateEventProviderRating;

// AUTO & MOTO — notification du destinataire d'un nouveau message.
const { createVehicleChatNotificationFunction } = require('./vehicleChatNotifications');
exports.notifyVehicleChatRecipient = createVehicleChatNotificationFunction({
  db, onDocumentCreated, sendToToken,
});
const { buildModerateVehicleEntity } = require('./vehicleModeration');
exports.moderateVehicleEntity = onCall(
  { maxInstances: 3 },
  buildModerateVehicleEntity({
    db, admin, requireAdminPermission, HttpsError,
  }),
);

// GPS privé/confidentialité réelle V2 — real_estate_private_locations,
// real_estate_location_access (voir functions/realEstateLocation.js).
const { createRealEstateLocationFunctions } = require('./realEstateLocation');
const realEstateLocation = createRealEstateLocationFunctions({
  db, admin, onCall, HttpsError, logAudit, checkRateLimit,
});
exports.upsertRealEstateLocation = realEstateLocation.upsertRealEstateLocation;


// ═══════════════════════════════════════════════════════════════════════════
// IDENTITÉ — journalisation des événements de connexion/rôle (Prompt 24)
// Fabriques définies dans authEvents.js (testables sans Firebase Admin, même
// pattern que orderActions.js/pendingActions.js).
// ═══════════════════════════════════════════════════════════════════════════
const { buildLogAuthEvent, buildLogAdminAuditEvent } = require('./authEvents');
exports.logAuthEvent      = buildLogAuthEvent({ onCall, HttpsError, checkRateLimit, logAudit });
exports.logAdminAuditEvent = buildLogAdminAuditEvent({ db, onCall, HttpsError, checkRateLimit, logAudit });
