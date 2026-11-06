'use strict';

// Premier parcours Restaurant v2 (Mission 7E-38) : requêtes PRÉPARÉES, jamais exécutées par ce module.
// Chaque étape décrit : l'appelant, les paramètres exacts, les préconditions, les effets Firestore et financiers attendus,
// les risques et les critères PASS/FAIL. Les paramètres sont validés contre les VRAIS modules de functions/ par
// restaurantV2FirstRun.emulator.test.js (le même catalogue pilote tout le parcours sur l'émulateur).
// Aucun jeton ni mot de passe ici : `callableRequest` reçoit le jeton d'identification au moment de l'appel.

const lot = require('./lot');
const selfie = require('./selfie');

const { IDENTITIES } = lot;
const RESTO = IDENTITIES.restaurant.uid;
const DRIVER = IDENTITIES.driver.uid;
const FN = Object.freeze({
  quote: 'quotePartnerOrderCF', create: 'createPartnerOrderFromQuoteCF', partner: 'partnerOrderActionCF', dispatch: 'dispatchOrderToDriver',
  accept: 'acceptOrderCF', prepareProof: 'prepareOrderProof', pickup: 'confirmOrderPickupWithProof', deliver: 'confirmOrderDeliveryWithProof',
});

const choices = () => ({ sellerType: 'restaurant', sellerId: RESTO, items: lot.BASKET.map((i) => ({ ...i })), destination: { ...lot.DELIVERY_POINT } });

// ctx : { orderId, quoteId, total, pickup: { pin, token }, delivery: { pin, token }, selfieUrl }
const STEPS = Object.freeze([
  {
    id: 'S0', fn: FN.partner, caller: 'admin', title: 'Ouverture du pilote, restreinte au restaurant fictif',
    data: () => lot.pilotConfigPlan().request,
    preconditions: ['config/partnerOrdersV2 absent (version 0)', 'admins/t7e-admin : role super, isActive'],
    effects: ['crée config/partnerOrdersV2 {pilotPartnerIds:["t7e-resto"], creationOpen:true, managementFrozen:false, version:1, lastChange}', 'audit_logs : partner_orders_config_update', 'rate_limits/t7e-admin_partner_orders_config'],
    money: () => 'aucun mouvement',
    risks: ['seule étape qui ouvre le pilote : à refermer en fin d’essai (cleanup.js)'],
    pass: ['success=true', 'pilotPartnerIds = ["t7e-resto"] uniquement'], fail: ['tout autre partenaire listé', 'CONFIG_CONFLICT (document déjà présent)'],
  },
  {
    id: 'S1', fn: FN.quote, caller: 'client', title: 'Devis Restaurant v2',
    data: () => choices(),
    preconditions: ['S0 faite', 'tarif de jour ou de nuit connu (frais 500 ou 1 000)'],
    effects: ['crée tariff_quotes/<quoteId> {status:"open", uid:"t7e-client", kind:"partner", expiresAtMs}', 'rate_limits/t7e-client_quote_partner_order'],
    money: (a) => `aucun mouvement ; total attendu ${a.totalAmount} (produits ${a.productAmount} + frais ${a.deliveryFee})`,
    risks: ['devis périmé si trop d’attente avant S2', 'bascule jour/nuit entre S1 et S2 → PRICE_CHANGED'],
    pass: ['success=true', 'data.total = totalAmount attendu', 'data.productAmount = 6500'], fail: ['PARTNER_NOT_IN_PILOT', 'PARTNER_CLOSED', 'montant fourni par le client accepté'],
  },
  {
    id: 'S2', fn: FN.create, caller: 'client', title: 'Création de la commande (paiement wallet fictif)',
    data: (c) => ({ ...choices(), quoteId: c.quoteId, paymentMethod: 'wallet', confirmedAmount: c.total, deliveryAddress: 'Adresse fictive de test, Abengourou' }),
    preconditions: ['devis ouvert et non expiré', 'clients/t7e-client.wallet ≥ total'],
    effects: ['crée orders/<orderId> {status:"pending", amountsVersion:2, sellerId:"t7e-resto", clientId:"t7e-client", paymentMethod:"wallet", isPaid:true}', 'clients/t7e-client.wallet −= totalAmount', 'clients/t7e-client/wallet_transactions/order_<orderId>', 'tariff_quotes/<quoteId>.status = "used"'],
    money: (a) => `client −${a.totalAmount} ; restaurant et livreur inchangés`,
    risks: ['double appui : rejeu sûr (replayed:true, aucun second débit)'],
    pass: ['success=true', 'wallet client = départ − total', 'un seul document orders'], fail: ['second débit', 'SOLDE_INSUFFISANT'],
  },
  {
    id: 'S2b', fn: null, caller: 'script', title: 'Rafraîchissement du GPS du livreur (juste avant S3)',
    command: 'node scripts/restaurant-v2-pilot/prepare.js --project az-express-preprod --project-number 306761725053 --refresh-driver-gps --confirm "REFRESH t7e-lot-1 az-express-preprod 306761725053"',
    data: () => null,
    preconditions: ['livreurs/t7e-driver porte testLotId = t7e-lot-1', 'GPS valable moins de 3 minutes au dispatch'],
    effects: ['livreurs/t7e-driver : lat, lng, isOnline, updatedAt (seuls champs modifiés)'],
    money: () => 'aucun mouvement', risks: ['lancé trop tôt : GPS périmé, aucun livreur proposé (staleGps)'],
    pass: ['updatedAt < 60 s au moment de S3'], fail: ['NOT_IN_LOT'],
  },
  {
    id: 'S3', fn: FN.partner, caller: 'restaurant', title: 'Acceptation par le restaurant (lance le dispatch)',
    data: (c) => ({ orderId: c.orderId, action: 'acceptPartnerOrder' }),
    preconditions: ['orders/<orderId>.status = "pending"', 'appelant : uid = sellerId'],
    effects: ['orders/<orderId>.partnerAcceptedAtMs', 'dispatch serveur : un seul livreur éligible → status "assigned", driverId "t7e-driver"', 'livreurs/t7e-driver.pendingOrderId = orderId'],
    money: () => 'aucun mouvement',
    risks: ['GPS périmé → data.dispatch.dispatched=false (la reprise bornée se déclenche)'],
    pass: ['success=true', 'data.dispatch.dispatched=true', 'status "assigned"'], fail: ['status resté "pending" sans reprise'],
  },
  {
    id: 'S4', fn: FN.partner, caller: 'restaurant', title: 'Début de préparation',
    data: (c) => ({ orderId: c.orderId, action: 'startPreparation' }),
    preconditions: ['S3 faite'], effects: ['orders/<orderId>.sellerStatus = "preparing", preparationStartedAtMs'],
    money: () => 'aucun mouvement', risks: ['après ce point le restaurant ne peut plus refuser (PREPARATION_STARTED)'],
    pass: ['sellerStatus "preparing"'], fail: ['INVALID_TRANSITION'],
  },
  {
    id: 'S5', fn: FN.partner, caller: 'restaurant', title: 'Commande prête',
    data: (c) => ({ orderId: c.orderId, action: 'markReady' }),
    preconditions: ['sellerStatus = "preparing"'], effects: ['orders/<orderId>.sellerStatus = "ready", readyAtMs'],
    money: () => 'aucun mouvement', risks: ['sans « ready », la récupération est refusée'],
    pass: ['sellerStatus "ready"'], fail: ['INVALID_TRANSITION'],
  },
  {
    id: 'S6', fn: null, caller: 'driver', title: 'Dépôt du selfie synthétique (Storage), exigé par S7',
    data: (c) => selfie.buildSelfieUpload(c.orderId),
    preconditions: ['orderId connu', 'jeton d’identification du livreur', 'image JPEG < 5 Mo, nom = <uid>.jpg'],
    effects: ['crée l’objet acceptance_selfies/<orderId>/t7e-driver.jpg (≈ 2 Ko)'],
    money: () => 'aucun mouvement', risks: ['seule écriture Storage du parcours ; à supprimer au nettoyage (cleanup.js l’inventorie)'],
    pass: ['HTTP 200 avec downloadTokens', 'URL de téléchargement reconnue par acceptOrderCF'], fail: ['403 (règle Storage)', 'objet sous un autre nom'],
  },
  {
    id: 'S7', fn: FN.accept, caller: 'driver', title: 'Acceptation par le livreur',
    data: (c) => ({ orderId: c.orderId, acceptanceSelfieUrl: c.selfieUrl }),
    preconditions: ['status "assigned" (driverId = t7e-driver)', 'selfie déposé (S6)', 'livreur en ligne, libre, wallet ≥ commission'],
    effects: ['orders/<orderId> : status "accepted", driverId, commissionAmount, commissionPayerId, commissionTxId, commissionStatus "charged"', 'livreurs/t7e-driver.wallet −= commission ; isOnDelivery true', 'livreurs/t7e-driver/wallet_transactions/commission_<orderId>_t7e-driver', 'offres résiduelles nettoyées'],
    money: (a) => `livreur −${a.commission} (une seule fois, même en cas de rejeu)`,
    risks: ['SELFIE_REQUIRED si l’objet est absent ou l’URL étrangère'],
    pass: ['success=true', 'wallet livreur = départ − commission', 'rejeu : alreadyAccepted=true sans second prélèvement'], fail: ['CREDIT_INSUFFISANT', 'second prélèvement'],
  },
  {
    id: 'S8', fn: FN.prepareProof, caller: 'restaurant', title: 'Preuve de récupération émise par le restaurant',
    data: (c) => ({ orderId: c.orderId, type: 'pickup' }),
    preconditions: ['status "accepted"', 'restaurant_owners/t7e-resto.restaurantId = sellerId'],
    effects: ['crée delivery_proofs/<session> et versions/<proof> (hachages seulement)', 'orders/<orderId>.deliveryProofMode = "qr_v1"'],
    money: () => 'aucun mouvement',
    risks: ['la réponse contient le QR et le PIN en clair : ne jamais les journaliser ni les enregistrer', 'validité 15 min, 3 générations maximum'],
    pass: ['PIN à 6 chiffres', 'expiresAt ≈ +15 min'], fail: ['émission par le client ou le livreur acceptée'],
  },
  {
    id: 'S9', fn: FN.pickup, caller: 'driver', title: 'Confirmation de récupération (PIN)',
    data: (c) => ({ orderId: c.orderId, pin: c.pickup.pin }),
    preconditions: ['sellerStatus "ready"', 'preuve active, non expirée', 'moins de 5 PIN erronés'],
    effects: ['orders/<orderId>.status = "picked_up", pickedUpAt, pickupProofValidatedBy', 'preuve de récupération "used"'],
    money: () => 'aucun mouvement',
    risks: ['5 PIN erronés verrouillent la preuve (pinLocked)'], pass: ['status "picked_up"', 'rejeu → Code déjà utilisé'], fail: ['récupération avant "ready"'],
  },
  {
    id: 'S10', fn: FN.prepareProof, caller: 'client', title: 'Preuve de livraison émise par le client',
    data: (c) => ({ orderId: c.orderId, type: 'delivery' }),
    preconditions: ['status "picked_up"', 'deliveryProofMode "qr_v1"', 'preuve de récupération consommée'],
    effects: ['crée la session et la version de preuve "delivery"'], money: () => 'aucun mouvement',
    risks: ['QR et PIN en clair dans la réponse : ne pas les enregistrer'], pass: ['QR et PIN reçus par le client'], fail: ['émission par un autre compte'],
  },
  {
    id: 'S11', fn: FN.deliver, caller: 'driver', title: 'Confirmation de livraison (QR) : crédits en une transaction',
    data: (c) => ({ orderId: c.orderId, proofToken: c.delivery.token }),
    preconditions: ['status "picked_up"', 'preuve de livraison active', 'appelant = driverId'],
    effects: ['orders/<orderId>.status = "delivered"', 'restaurants/t7e-resto.wallet += productAmount (journal earning_<orderId>)', 'livreurs/t7e-driver.wallet += deliveryFee (journal earning_<orderId>)', 'commissions : une écriture', 'preuve "used"'],
    money: (a) => `restaurant +${a.productAmount} ; livreur +${a.deliveryFee} ; client inchangé ; seule la commission (${a.commission}) quitte les wallets`,
    risks: ['aucune annulation possible après livraison'],
    pass: ['status "delivered"', 'soldes = lot.expectedLedger().afterDelivery', 'rejeu → failed-precondition sans mouvement'], fail: ['crédit doublé', 'écart d’un FCFA'],
  },
]);

// Non appelée dans le premier parcours : pour une commande v2 le dispatch est piloté par le serveur (index.js).
const NOT_CALLED = Object.freeze({
  fn: FN.dispatch, caller: 'client (propriétaire de la commande) ou admin',
  data: (c) => ({ orderId: c.orderId }),
  reason: 'amountsVersion = 2 et appelant non administrateur → { dispatched:false, mode:"server_managed" } sans effet ; seul un administrateur peut forcer une proposition',
  effects: ['rate_limits/<uid>_dispatch_order uniquement'],
});

// Protocole des fonctions callable (HTTPS) : POST {"data": ...} avec `Authorization: Bearer <ID token>` ; réponse {"result": ...}
// ou {"error": {status, message}}. Le jeton est fourni à l'appel et n'est jamais écrit.
function callableRequest(url, idToken, data) {
  if (typeof idToken !== 'string' || idToken.split('.').length !== 3) throw new Error('jeton d’identification requis');
  return { url, init: { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` }, body: JSON.stringify({ data }) } };
}
function parseCallableResponse(status, body) {
  if (body && body.error) return { ok: false, status: body.error.status, message: body.error.message };
  return status >= 200 && status < 300 && body && 'result' in body ? { ok: true, result: body.result } : { ok: false, status: String(status) };
}

const stepsByFunction = (name) => STEPS.filter((s) => s.fn === name);

module.exports = { FN, STEPS, NOT_CALLED, callableRequest, parseCallableResponse, stepsByFunction, choices };
