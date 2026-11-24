'use strict';

// Socle L1 : registre des writers sensibles face à la fermeture d'un compte (protocole 2D-2A.3 §4, décision D-3).
// Ce registre DÉCRIT ; il ne protège rien et n'est lu par aucun writer. Chaque entrée sépare :
//   - le niveau attendu (category, closing, sealed) : classification du protocole, avec son statut de décision ;
//   - la garde RÉELLEMENT présente aujourd'hui (guard) : relevée dans le code, et vérifiée par test (voir
//     test/accountClosureRegistry.test.js, qui relit le source de chaque writer pour confirmer la présence ou l'absence du jeton).
// Ne jamais déclarer une garde sans l'avoir lue dans le chemin d'écriture : le test échoue sinon.
//
// category : A nouvelle activité · B progression/règlement · C annulation/remboursement · D décision administrative · null = non classé.
// closing  : comportement attendu en quarantaine ; sealed : comportement attendu une fois scellé (voir accountClosureLock.js).
// guard.type : 'admission_helper'  accountAdmission.assertNewAccountActivity dans la transaction (refuse tout tombstone et les
//                                   profils deletionRequested/isDeleted, sans distinguer les phases)
//              'tombstone_read'    lecture directe du tombstone dans la transaction
//              'target_guard'      accountAdmission.assertTargetNotClosing (cible d'une opération d'administration, hors transaction)
//              'closure_exception' L3 : exception contrôlée onCallClosing (accountClosureActor.js) ; le jeton est celui du garde réellement appelé
//              'unexamined'        chemin d'écriture non lu pour L1 : AUCUNE affirmation sur la garde
//              'none'              aucune lecture du tombstone dans ce chemin ; seul le wrapper onCall (appelant) s'applique, et
//                                   rien pour les schedulers et webhooks (« deliberately not wrapped », index.js)
// classification : 'anchored' (ancrée par une décision approuvée) · 'to_confirm' (analogie, à confirmer, D-3) ·
//                  'recommended' · 'unclassified' (jamais lu entièrement : inventaire requis, D-3).
// tracking : 'head' si la garde est dans HEAD, 'working_copy' si elle n'existe que dans une modification locale non commitée.

const CATEGORIES = Object.freeze(['A', 'B', 'C', 'D']);
const GUARD_TYPES = Object.freeze(['admission_helper', 'tombstone_read', 'target_guard', 'closure_exception', 'none', 'unexamined']);
const GUARD_TOKEN = Object.freeze({
  admission_helper: 'assertNewAccountActivity',
  tombstone_read: 'account_tombstones',
  target_guard: 'assertTargetNotClosing',
});
const CLASSIFICATIONS = Object.freeze(['anchored', 'to_confirm', 'recommended', 'unclassified']);

const guard = (type, tracking = 'head', token = null) => Object.freeze({ type, tracking, token: token || GUARD_TOKEN[type] || null });
const writer = (id, def) => Object.freeze({
  id,
  kind: 'onCall',
  actions: null,
  closing: def.category === 'A' ? 'refuse' : 'allow',
  sealed: 'refuse',
  notes: '',
  ...def,
  guard: def.guard || guard('none'),
});

const WRITERS = Object.freeze([
  // ── Orders (orderActions.js) ──────────────────────────────────────────────────────────────────────────────────────
  writer('payOrderFromWalletCF', { file: 'orderActions.js', symbol: 'function buildPayOrderFromWallet', category: 'B', classification: 'anchored',
    guard: guard('closure_exception', 'working_copy', 'closureGuard'), notes: 'D6-a/D6-b ; L3 : client en quarantaine, commande engagée avant ; bénéficiaire fermé => refus' }),
  writer('cancelOrderCF', { file: 'orderActions.js', symbol: 'function buildCancelOrder', category: 'C', classification: 'anchored',
    guard: guard('closure_exception', 'working_copy', 'assertClosureActor'), notes: 'D6-c ; DR1 ; L3 : bénéficiaire fermé omis + signalement' }),
  writer('deliverOrderCF', { file: 'orderActions.js', symbol: 'function buildDeliverOrder', category: 'B', classification: 'anchored',
    guard: guard('closure_exception', 'working_copy', 'closureGuard'), notes: 'D6-c ; DR2 ; L3 : livreur lié à la commande ; partenaire fermé => refus' }),
  writer('adminConfirmDeliveryCF', { file: 'orderActions.js', symbol: 'function buildDeliverOrder', category: 'D', classification: 'to_confirm',
    notes: 'même constructeur que deliverOrderCF (chemin administrateur) ; cibles à confirmer (D2)' }),
  writer('confirmOrderDeliveryWithProof', { file: 'orderActions.js', symbol: 'function buildDeliverOrder', category: 'B', classification: 'anchored',
    guard: guard('closure_exception', 'working_copy', 'closureGuard'), notes: 'L3 : même corps que deliverOrderCF (requireProof)' }),
  writer('refundExpiredBoutiqueOrderCF', { file: 'orderActions.js', symbol: 'function buildRefundExpiredBoutiqueOrder', category: 'C', classification: 'to_confirm' }),
  writer('autoExpireOrders', { kind: 'schedule', file: 'index.js', symbol: 'exports.autoExpireOrders', category: 'C', classification: 'to_confirm',
    sealed: 'defer', notes: 'sealed : reporter la commande au tour suivant, aucune écriture' }),
  writer('payBoutiqueOrderCF', { file: 'orderActions.js', symbol: 'function buildPayBoutiqueOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('payBoutiqueOrderCashCF', { file: 'orderActions.js', symbol: 'function buildPayBoutiqueOrderCash', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('releaseOrderBeforePickupCF', { file: 'driverRelease.js', symbol: 'function buildReleaseOrderBeforePickup', category: 'A', classification: 'anchored',
    notes: 'progression de mission ; vérification individuelle à faire' }),

  // ── Admin : règlements, facturation, litiges ──────────────────────────────────────────────────────────────────────
  writer('settleTransferEarningsCF', { file: 'transferSettlement.js', symbol: 'function buildSettleTransferEarnings', category: 'D', classification: 'to_confirm',
    notes: 'chaque livreur de driverIds doit être contrôlé (D2)' }),
  writer('adminBillingCF', { file: 'adminBilling.js', symbol: 'function buildAdminBilling', category: 'D', classification: 'to_confirm' }),
  writer('adminOrderDisputeCF', { file: 'adminOrderDisputes.js', symbol: 'function buildAdminOrderDispute', category: 'D', classification: 'to_confirm' }),
  writer('adminDriverRechargeCF', { file: 'adminDriverRecharge.js', symbol: 'function buildAdminDriverRecharge', category: 'D', classification: 'anchored',
    guard: guard('admission_helper') }),
  writer('adminApproveRechargeCF', { file: 'adminWalletRequests.js', symbol: 'function buildAdminApproveRecharge', category: 'D', classification: 'anchored',
    guard: guard('admission_helper') }),

  // ── Commandes partenaires (une même fonction, plusieurs actions de catégories différentes) ──────────────────────
  writer('partnerOrderActionCF#preparation', { file: 'partnerOrderActions.js', symbol: 'function buildPartnerOrderAction', category: 'A', classification: 'to_confirm',
    actions: ['acceptPartnerOrder', 'startPreparation', 'acceptAndPrepare', 'markReady', 'refusePartnerOrder'],
    notes: 'acceptAndPrepare absente du tableau §4 : classée A par cohérence avec acceptPartnerOrder, à confirmer' }),
  writer('partnerOrderActionCF#cashNonPayment', { file: 'partnerOrderActions.js', symbol: 'function buildPartnerOrderAction', category: 'A', classification: 'to_confirm',
    actions: ['declareCashNonPayment'] }),
  writer('partnerOrderActionCF#cashRemittance', { file: 'partnerOrderActions.js', symbol: 'function buildPartnerOrderAction', category: 'B', classification: 'to_confirm',
    actions: ['declareCashHandover', 'confirmCashRemittance', 'disputeCashRemittance'] }),
  writer('partnerOrderActionCF#adminDecision', { file: 'partnerOrderActions.js', symbol: 'function buildPartnerOrderAction', category: 'D', classification: 'anchored',
    actions: ['resolveCashRemittance', 'reviewCashNonPayment'], notes: 'ancré dans le code (requireSuperAdmin) ; contrôles de cible à confirmer' }),

  // ── Creations de commande et paiements entrants (catégorie A) ───────────────────────────────────────────────────
  writer('createOrderFromQuoteCF', { file: 'deliveryQuote.js', symbol: 'function buildCreateOrderFromQuoteCF', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('createCatalogOrderFromQuoteCF', { file: 'catalogQuote.js', symbol: 'function buildCreateCatalogOrderFromQuoteCF', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('createPartnerOrderFromQuoteCF', { file: 'partnerOrderQuote.js', symbol: 'function buildCreatePartnerOrderFromQuoteCF', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('createEventReservation', { file: 'eventReservations.js', symbol: 'function buildCreateEventReservation', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('initiateFeexPayPayment', { file: 'index.js', symbol: 'exports.initiateFeexPayPayment', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('initiateWithdrawal', { file: 'index.js', symbol: 'exports.initiateWithdrawal', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('aziaConfirmAction', { file: 'azia/pendingActions.js', symbol: 'function buildConfirmAction', category: 'A', classification: 'anchored', guard: guard('admission_helper'),
    notes: 'confirmation serveur des actions AZ IA' }),

  // ── Webhook ─────────────────────────────────────────────────────────────────────────────────────────────────────────
  writer('feexPayWebhook', { kind: 'http', file: 'feexpayPayments.js', symbol: 'async function processFeexPayWebhookEvent', category: 'B', classification: 'anchored',
    sealed: 'hold', guard: guard('tombstone_read'),
    notes: 'held_for_review si la demande est postérieure au tombstone ; comportement en sealed recommandé. RÉSERVE C2 (L0-F) : ne pas modifier sans rejouer C2' }),

  // ── E-Kbine (gardes présentes seulement dans la copie de travail, non commitées) ─────────────────────────────────
  writer('ekCreateOrderCF', { file: 'ekbineOrders.js', symbol: 'function buildEkCreateOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper', 'working_copy') }),
  writer('ekbineAcceptOrder', { file: 'ekbineOrders.js', symbol: 'function buildEkbineAcceptOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper', 'working_copy') }),
  writer('ekClientConfirmOrder', { file: 'ekbineOrders.js', symbol: 'function buildEkClientConfirmOrder', category: 'B', classification: 'anchored',
    guard: guard('admission_helper', 'working_copy'),
    notes: 'L3 : exception onCallClosing (X-2, C1-C13) implémentée via assertClosureActor ; agent relu par assertNewAccountActivity' }),
  writer('ekCancelOrderCF', { file: 'ekbineOrders.js', symbol: 'function buildEkCancelOrder', category: 'C', classification: 'anchored', notes: 'flag atomique recommandé' }),
  writer('manageProfessionalSubscription', { file: 'professionalSubscriptions.js', symbol: 'function buildManageProfessionalSubscription', category: 'A', classification: 'to_confirm',
    guard: guard('tombstone_read', 'working_copy'), notes: 'suspend et deactivateVip restent permis (protection)' }),

  // ── Outils AZ IA (exécutés par aziaConfirmAction, après confirmation serveur) ─────────────────────────────────────
  writer('aziaTool:createMarketplaceOrder', { file: 'azia/tools/marketplace.js', symbol: 'function createMarketplaceOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('aziaTool:createPharmacieOrder', { file: 'azia/tools/pharmacies.js', symbol: 'function createPharmacieOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('aziaTool:createRestaurantOrder', { file: 'azia/tools/restaurants.js', symbol: 'function createRestaurantOrder', category: 'A', classification: 'anchored', guard: guard('admission_helper') }),
  writer('aziaTool:debitWalletIfNeeded', { file: 'azia/tools/delivery.js', symbol: 'async function debitWalletIfNeeded', category: 'A', classification: 'anchored', guard: guard('admission_helper'),
    notes: 'débit du portefeuille pour une livraison AZ IA' }),

  // ── Opérations d'identité sur un compte cible (non financières) ────────────────────────────────────────────────────
  writer('resetAccountPassword', { file: 'passwordReset.js', symbol: 'function buildResetAccountPassword', category: 'A', classification: 'anchored', guard: guard('target_guard', 'working_copy') }),
  writer('adminPartnerAccounts', { file: 'adminPartnerAccounts.js', symbol: 'async function assertTargetBelongsToKind', category: null, classification: 'unclassified', closing: 'unknown', sealed: 'unknown',
    guard: guard('target_guard', 'working_copy'), notes: 'administration des comptes partenaires ; garde de cible constatée, catégorie non analysée' }),
  writer('setPharmaciePassword', { file: 'index.js', symbol: 'exports.setPharmaciePassword', category: 'A', classification: 'anchored', guard: guard('target_guard', 'working_copy') }),

  // ── Lecture du tombstone constatée, catégorie non analysée pour L1 ─────────────────────────────────────────────────
  writer('createFleetDriver', { file: 'fleetDriverCreation.js', symbol: 'function buildCreateFleetDriver', category: null, classification: 'unclassified', closing: 'unknown', sealed: 'unknown',
    guard: guard('tombstone_read'), notes: 'lit le tombstone du propriétaire de flotte ; sémantique non analysée' }),
  writer('partnerQr', { file: 'partnerQr.js', symbol: 'function buildPartnerQr', category: null, classification: 'unclassified', closing: 'unknown', sealed: 'unknown',
    guard: guard('tombstone_read'), notes: 'paquet QR isolé (ne pas modifier sans demande) ; lit le tombstone' }),
  writer('pharmacyOwnerIdentity', { file: 'pharmacyOwnerIdentity.js', symbol: 'function buildPharmacyOwnerIdentity', category: null, classification: 'unclassified', closing: 'unknown', sealed: 'unknown',
    guard: guard('tombstone_read'), notes: 'lie un propriétaire de pharmacie ; lit le tombstone ; sémantique non analysée' }),

  // ── Analysés en L2 (lecture seule, aucun de ces trois writers n'est modifié) ─────────────────────────────────────────
  // Classification « à confirmer » (D-3) : la garde réelle a été lue de bout en bout, la catégorie reste une proposition.
  writer('checkPendingWithdrawals', { kind: 'schedule', file: 'index.js', symbol: 'exports.checkPendingWithdrawals', category: 'C', classification: 'to_confirm', closing: 'allow', sealed: 'refuse', guard: guard('none'),
    actions: ['verify_payout_status', 'refund_failed_payout'],
    notes: 'L2 : délègue à applyPayoutStatus (feexpayPayments.js, réserve C2 : NON modifiable ici). FAILED = crédit wallet de wd.userId (« userSnap.exists » seulement : ni tombstone, ni isDeleted, ni epoch). Indirectement borné : un retrait non terminal bloque T1/T2/T2b via inspect(), et initiateWithdrawal est refusé dès la quarantaine (catégorie A).' }),
  writer('adminApproveWithdrawalCF', { file: 'index.js', symbol: 'exports.adminApproveWithdrawalCF', category: 'D', classification: 'to_confirm', closing: 'allow', sealed: 'refuse', guard: guard('none'),
    actions: ['mark_withdrawal_processed'],
    notes: 'L2 : adminWalletRequests.js, super-admin ; pending_manual -> processed, wallet jamais touché (walletUntouched). Aucune lecture du compte. Après T2b aucun retrait ne peut être pending_manual (inspect bloque), donc inatteignable en pratique ; sans garde ni epoch.' }),
  writer('ekbineAgentDepositAction', { file: 'index.js', symbol: 'exports.ekbineAgentDepositAction', category: 'B', classification: 'to_confirm', closing: 'allow', sealed: 'refuse', guard: guard('none'),
    actions: ['confirm_deposit', 'reject_deposit', 'start_order'],
    notes: 'L2 : transitions de statut de la commande Ekbine par son agent, aucun mouvement argent. Seule garde : isEligibleAgent(profil) (deletionRequested, isDeleted, isSuspended), pas le tombstone ; le wrapper onCall refuse un agent en quarantaine hors transaction. Le client de la commande est relu nulle part.' }),
]);

const byId = new Map(WRITERS.map((w) => [w.id, w]));
const getWriter = (id) => byId.get(id) || null;
const listWriters = ({ category, guardType, classification } = {}) => WRITERS.filter((w) => (category === undefined || w.category === category)
  && (guardType === undefined || w.guard.type === guardType) && (classification === undefined || w.classification === classification));
// Writers de catégorie B/C/D sans aucune lecture du tombstone dans leur chemin d'écriture : le périmètre des missions de branchement.
const unguardedSettlementWriters = () => WRITERS.filter((w) => ['B', 'C', 'D'].includes(w.category) && w.guard.type === 'none');

// Contrôle structurel (le test vérifie en plus le source de chaque writer).
function validateRegistry(list = WRITERS) {
  const problems = [];
  const seen = new Set();
  for (const w of list) {
    if (seen.has(w.id)) problems.push(`${w.id}: identifiant dupliqué`);
    seen.add(w.id);
    if (w.category !== null && !CATEGORIES.includes(w.category)) problems.push(`${w.id}: catégorie invalide`);
    if (!GUARD_TYPES.includes(w.guard.type)) problems.push(`${w.id}: type de garde invalide`);
    if (!CLASSIFICATIONS.includes(w.classification)) problems.push(`${w.id}: classification invalide`);
    if (w.category === null && w.classification !== 'unclassified') problems.push(`${w.id}: non classé mais classification déclarée`);
    if (w.category !== null && w.classification === 'unclassified') problems.push(`${w.id}: classé sans classification`);
    if (!w.file || !w.symbol) problems.push(`${w.id}: fichier ou symbole manquant`);
    if (w.guard.type !== 'none' && !['head', 'working_copy'].includes(w.guard.tracking)) problems.push(`${w.id}: suivi de garde invalide`);
    if (w.category === 'A' && w.closing !== 'refuse') problems.push(`${w.id}: catégorie A doit refuser en quarantaine`);
    if (['B', 'C', 'D'].includes(w.category) && w.closing !== 'allow') problems.push(`${w.id}: catégorie ${w.category} doit être autorisée en quarantaine`);
    if (w.category !== null && w.sealed === 'allow') problems.push(`${w.id}: aucun writer ne peut être autorisé une fois scellé`);
  }
  return problems;
}

module.exports = { WRITERS, CATEGORIES, GUARD_TYPES, GUARD_TOKEN, getWriter, listWriters, unguardedSettlementWriters, validateRegistry };
