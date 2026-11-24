'use strict';

// Rapprochement MANUEL des commandes Restaurant / Boulangerie HISTORIQUES (avant commandes versionnées).
//
// Fonction PURE : elle classe des documents déjà lus. Elle n'écrit rien, ne touche aucun solde, ne crée aucun
// remboursement et ne propose aucune écriture automatique : chaque constat est une INFORMATION destinée à une décision
// humaine (une clé de décision stable par commande évite tout double traitement).
//
// Ce que les parcours actuels font réellement (audit Mission 7, lecture du code) :
//   Restaurant              : budget = total des plats ; wallet débité à la création (isPaid=true), journal client
//                             `purchase` ; à la livraison le restaurant reçoit `budget`, le livreur rien.
//   Boulangerie standard    : budget = frais de livraison, itemsAmount = articles, totalAmount = total ; isPaid=false
//                             à la création MÊME en wallet (aucun débit) ; seul `payOrderFromWalletCF` (après
//                             livraison) débite `budget` (frais) et le crédite au livreur ; articles jamais encaissés.
//   Boulangerie gâteau      : débit de totalAmount à la création (isPaid=true, aucun journal client) ; à la livraison
//                             la boulangerie reçoit `budget` (= frais), le livreur rien ; à l'annulation seul
//                             `budget` est remboursé.
//
// Entrées (montants positifs, tels que les journaux les stockent) :
//   clientLedger  : { orderId, type: 'purchase'|'payment'|'refund', amount }   clients/{uid}/wallet_transactions
//   partnerLedger : { orderId, type: 'earning', amount }                       {restaurants|boulangeries}/{id}/wallet_transactions
//   driverLedger  : { orderId, type: 'earning'|'commission'|'refund', amount } livreurs/{id}/wallet_transactions
// Les commandes versionnées (amountsVersion 2, partnerOrderAmounts.js) ont leur propre analyse (analyzeV2Order) : crédits
// uniques et exacts à la livraison, remboursements bornés, cash sans mouvement de wallet, reversement tracé.
// Une version 2 aux montants incohérents est SIGNALÉE (V2_AMOUNTS_INCONSISTENT), jamais traitée comme historique.

const crypto = require('crypto');
const { PARTNER_SELLER_TYPES, readPartnerAmounts } = require('./partnerOrderAmounts');

const SEVERITY_RANK = { critical: 0, high: 1, medium: 2, info: 3 };
const isInt = (n) => Number.isSafeInteger(n) && n >= 0;
const num = (n) => (Number.isFinite(Number(n)) ? Number(n) : 0);

function sumOf(lines, orderId, types) {
  return lines.filter((l) => l.orderId === orderId && types.includes(l.type)).reduce((s, l) => s + num(l.amount), 0);
}
function countOf(lines, orderId, types) {
  return lines.filter((l) => l.orderId === orderId && types.includes(l.type)).length;
}

const DAY_MS = 24 * 60 * 60 * 1000;
// Délai provisoire de reversement cash au partenaire (décision métier provisoire : 24 h après livraison, alerte seule).
const CASH_REMITTANCE_DELAY_MS = DAY_MS;

// ── Commandes versionnées (amountsVersion 2) ────────────────────────────────────────────────────────────────────
// Modèle attendu (partnerOrderAmounts.js, orderActions.js) :
//   wallet : le client est débité de `totalAmount` à la création (journal `payment`) ; le partenaire reçoit
//            `productAmount` UNE fois et le livreur `deliveryFee` UNE fois, tous deux à la LIVRAISON ; rien avant ;
//            annulation avant récupération = remboursement du total ; frais retenus (deliveryFeeHold) = exception.
//   cash   : aucun mouvement de wallet ; `cashRemittance` trace la remise des produits au partenaire.
// Une commande non livrée n'est JAMAIS signalée pour absence de crédit : ces crédits n'existent qu'après livraison.
// `reconciliationFlags` (optionnel) : signalements ouverts déjà posés par le serveur (ex. partner_credit_missing), qui
// transforment un crédit absent en régularisation connue plutôt qu'en anomalie inexpliquée.
function analyzeV2Order(o, amounts, { clientLedger, partnerLedger, driverLedger, reconciliationFlags, nowMs }) {
  const findings = [];
  const add = (code, severity, note, extra = {}) => findings.push({ code, severity, note, ...extra });
  const { productAmount, deliveryFee, totalAmount } = amounts;
  const wallet = o.paymentMethod === 'wallet';
  const delivered = o.status === 'delivered';
  const cancelled = o.status === 'cancelled';

  const clientPaid = sumOf(clientLedger, o.id, ['purchase', 'payment']);
  const refunded = sumOf(clientLedger, o.id, ['refund']);
  const partnerCredited = sumOf(partnerLedger, o.id, ['earning']);
  const partnerLines = countOf(partnerLedger, o.id, ['earning']);
  const driverEarning = sumOf(driverLedger, o.id, ['earning']);
  const driverLines = countOf(driverLedger, o.id, ['earning']);
  const commissionLines = countOf(driverLedger, o.id, ['commission']);
  const hasFlag = (type) => reconciliationFlags.some((f) => f.orderId === o.id && f.type === type && f.status !== 'resolved');

  const hold = o.deliveryFeeHold && Number.isSafeInteger(o.deliveryFeeHold.amount) ? o.deliveryFeeHold : null;
  const heldGain = o.settlementHold === true || o.heldDriverEarning != null;
  const partialRefundAuthorized = delivered && o.deliveryClosedBy === 'admin_dispute'
    && o.disputeDecision && o.disputeDecision.financialTreatment === 'partial_refund';

  if (wallet) {
    // ── Encaissement ──────────────────────────────────────────────────────────────────────────────────────────
    if (o.isPaid !== true) {
      add('V2_WALLET_NOT_MARKED_PAID', 'high', 'Commande wallet v2 non marquée payée (le débit est fait à la création).');
    }
    if (clientPaid === 0) {
      add('V2_CLIENT_DEBIT_MISSING', 'high', 'Aucun journal de débit client pour une commande wallet v2.',
        { expected: totalAmount, actual: 0, difference: totalAmount, owedBy: 'client' });
    } else if (clientPaid !== totalAmount) {
      add('V2_CLIENT_DEBIT_MISMATCH', 'critical', 'Le débit client journalisé ne correspond pas au total de la commande.',
        { expected: totalAmount, actual: clientPaid, difference: Math.abs(totalAmount - clientPaid) });
    }
    const paid = clientPaid > 0 ? clientPaid : totalAmount;

    // ── Remboursements : jamais plus que le payé, ni plus que la décision prise ───────────────────────────────
    if (refunded > paid) {
      add('V2_OVER_REFUNDED', 'critical', 'Remboursement supérieur au montant payé.',
        { expected: paid, actual: refunded, difference: refunded - paid });
    }
    if (cancelled) {
      // Exception autorisée : frais retenus par décision administrative (en attente ou conservés), jamais rendus.
      const heldFee = hold && hold.decision !== 'refundClient' ? hold.amount : 0;
      const expectedRefund = Math.max(0, paid - heldFee);
      if (refunded === 0 && expectedRefund > 0) {
        add('V2_CANCELLED_NOT_REFUNDED', 'critical', 'Commande annulée, montant payé non remboursé.',
          { expected: expectedRefund, actual: 0, difference: expectedRefund, owedTo: 'client' });
      } else if (refunded > 0 && refunded < expectedRefund) {
        add('V2_REFUND_INCOMPLETE', 'critical', 'Remboursement inférieur au montant dû au client.',
          { expected: expectedRefund, actual: refunded, difference: expectedRefund - refunded, owedTo: 'client' });
      } else if (refunded > expectedRefund && refunded <= paid) {
        add('V2_REFUND_ABOVE_DECISION', 'high', 'Remboursement supérieur à celui qu\'autorise la décision de retenue.',
          { expected: expectedRefund, actual: refunded, difference: refunded - expectedRefund });
      }
      if (hold && hold.status === 'pending_admin_review') {
        add('V2_FEE_HOLD_PENDING', 'medium', 'Frais de livraison retenus en attente de décision administrative.',
          { amountDueToPartner: 0, expected: hold.amount });
      }
      if (partnerCredited > 0) {
        add('V2_PARTNER_CREDITED_ON_CANCELLED', 'critical', 'Partenaire crédité sur une commande annulée.', { actual: partnerCredited });
      }
      const paidToDriver = hold && hold.decision === 'payDriver' ? hold.amount : 0;
      if (driverEarning > paidToDriver) {
        add('V2_DRIVER_CREDITED_ON_CANCELLED', 'critical', 'Livreur crédité sur une commande annulée.',
          { expected: paidToDriver, actual: driverEarning, difference: driverEarning - paidToDriver });
      }
    } else if (!delivered) {
      if (refunded > 0) add('V2_REFUND_ON_ACTIVE_ORDER', 'high', 'Remboursement enregistré sur une commande non annulée.', { actual: refunded });
      if (partnerCredited > 0 || driverEarning > 0) {
        add('V2_CREDIT_BEFORE_DELIVERY', 'critical', 'Crédit partenaire ou livreur avant la livraison.',
          { actual: partnerCredited + driverEarning, lines: partnerLines + driverLines });
      }
    } else if (partialRefundAuthorized) {
      // Remboursement partiel décidé par le super-administrateur : montant = décision, jamais le journal seul.
      if (refunded !== o.disputeDecision.clientRefund) {
        add('V2_PARTIAL_REFUND_MISMATCH', 'critical', 'Remboursement partiel différent de la décision administrative.',
          { expected: o.disputeDecision.clientRefund, actual: refunded, difference: Math.abs(refunded - o.disputeDecision.clientRefund) });
      } else {
        add('V2_PARTIAL_REFUND_AUTHORIZED', 'info', 'Remboursement partiel autorisé par décision administrative.', { actual: refunded });
      }
    } else {
      // ── Livrée : crédits uniques et exacts ──────────────────────────────────────────────────────────────────
      if (refunded > 0) {
        add('V2_REFUND_ON_DELIVERED', 'high', 'Remboursement enregistré sur une commande livrée sans décision administrative.', { actual: refunded });
      }
      if (partnerLines === 0) {
        if (hasFlag('partner_credit_missing')) {
          add('V2_PARTNER_CREDIT_FLAGGED', 'medium', 'Partenaire introuvable à la livraison : régularisation manuelle ouverte.',
            { expected: productAmount, actual: 0, difference: productAmount, owedTo: 'partner' });
        } else {
          add('V2_PARTNER_CREDIT_MISSING', 'critical', 'Livrée : les produits n\'ont pas été crédités au partenaire.',
            { expected: productAmount, actual: 0, difference: productAmount, owedTo: 'partner' });
        }
      } else {
        if (partnerLines > 1) add('V2_PARTNER_DOUBLE_CREDIT', 'critical', 'Plusieurs crédits partenaire pour une même commande.', { lines: partnerLines });
        if (partnerCredited > productAmount) {
          add('V2_PARTNER_OVERCREDITED', 'critical', 'Le partenaire a reçu plus que le montant des produits.',
            { expected: productAmount, actual: partnerCredited, difference: partnerCredited - productAmount });
        } else if (partnerCredited < productAmount) {
          add('V2_PARTNER_UNDERCREDITED', 'critical', 'Le partenaire a reçu moins que le montant des produits.',
            { expected: productAmount, actual: partnerCredited, difference: productAmount - partnerCredited, owedTo: 'partner' });
        }
      }
      if (heldGain && o.settlementStatus !== 'settled') {
        // Course transférée : le gain livreur est retenu pour validation administrative, rien n'est dû ici.
        add('V2_DRIVER_EARNING_HELD', 'medium', 'Gain livreur retenu (course transférée) en attente de validation administrative.',
          { expected: deliveryFee });
        if (driverEarning > 0) {
          add('V2_DRIVER_CREDITED_WHILE_HELD', 'critical', 'Livreur crédité alors que son gain est retenu.', { actual: driverEarning });
        }
      } else if (heldGain) {
        if (driverEarning > deliveryFee) {
          add('V2_DRIVER_OVERCREDITED', 'critical', 'Crédit livreur supérieur aux frais de livraison.',
            { expected: deliveryFee, actual: driverEarning, difference: driverEarning - deliveryFee });
        }
      } else if (driverLines === 0) {
        add('V2_DRIVER_FEE_MISSING', 'high', 'Livrée : les frais de livraison n\'ont pas été crédités au livreur.',
          { expected: deliveryFee, actual: 0, difference: deliveryFee, owedTo: 'driver' });
      } else {
        if (driverLines > 1) add('V2_DRIVER_DOUBLE_CREDIT', 'critical', 'Plusieurs crédits livreur pour une même commande.', { lines: driverLines });
        if (driverEarning > deliveryFee) {
          add('V2_DRIVER_OVERCREDITED', 'critical', 'Crédit livreur supérieur aux frais de livraison.',
            { expected: deliveryFee, actual: driverEarning, difference: driverEarning - deliveryFee });
        } else if (driverEarning < deliveryFee) {
          add('V2_DRIVER_UNDERCREDITED', 'high', 'Crédit livreur inférieur aux frais de livraison.',
            { expected: deliveryFee, actual: driverEarning, difference: deliveryFee - driverEarning, owedTo: 'driver' });
        }
      }
    }
  } else {
    // ── Cash : aucun mouvement de wallet, reversement tracé ───────────────────────────────────────────────────
    if (clientPaid > 0) add('V2_CASH_WALLET_DEBIT', 'critical', 'Commande cash avec un débit wallet client.', { actual: clientPaid });
    if (refunded > 0) add('V2_CASH_REFUND', 'critical', 'Commande cash avec un remboursement wallet.', { actual: refunded });
    if (partnerCredited > 0 || driverEarning > 0) {
      add('V2_CASH_WALLET_CREDIT', 'critical', 'Commande cash avec un crédit wallet partenaire ou livreur (argent déjà encaissé en espèces).',
        { actual: partnerCredited + driverEarning, lines: partnerLines + driverLines });
    }
    if (delivered) {
      const r = o.cashRemittance;
      if (!r || typeof r !== 'object') {
        add('V2_CASH_REMITTANCE_MISSING', 'high', 'Livrée en cash : aucune trace du reversement au partenaire.', { amountDueToPartner: productAmount, owedTo: 'partner' });
      } else {
        if (r.amountDue !== productAmount) {
          add('V2_CASH_AMOUNT_MISMATCH', 'critical', 'Montant dû au partenaire différent des produits de la commande.',
            { expected: productAmount, actual: r.amountDue ?? null });
        }
        const confirmed = r.status === 'confirmed' || r.status === 'resolved';
        if (o.merchantCashSettled === true && !confirmed) {
          // Une déclaration du livreur seule ne suffit JAMAIS à considérer le partenaire comme payé.
          add('V2_CASH_SETTLED_WITHOUT_CONFIRMATION', 'high', 'Reversement marqué réglé sans confirmation du partenaire.', { amountDueToPartner: productAmount });
        }
        if (r.status === 'resolved') {
          // Régularisation par le super-administrateur (Mission 7B-3B-C) : la trace est la décision, pas le partenaire.
          const res = r.resolution;
          if (!res || !isInt(res.finalAmount) || !res.byUid || !res.atMs) {
            add('V2_CASH_CONFIRMATION_UNTRACED', 'high', 'Reversement régularisé sans montant, date ou auteur de la décision.');
          } else if (res.finalAmount > productAmount) {
            add('V2_CASH_CONFIRMED_ABOVE_DUE', 'critical', 'Montant régularisé supérieur au montant dû.',
              { expected: productAmount, actual: res.finalAmount, difference: res.finalAmount - productAmount });
          } else if (res.finalAmount < productAmount) {
            add('V2_CASH_RESOLVED_SHORTFALL', 'medium', 'Reversement régularisé avec un reliquat arrêté par décision administrative (aucun débit automatique).',
              { expected: productAmount, actual: res.finalAmount, difference: productAmount - res.finalAmount, owedTo: 'partner' });
          }
        } else if (confirmed) {
          if (!isInt(r.amountConfirmed) || !r.partnerConfirmedAtMs || !r.confirmedBy) {
            add('V2_CASH_CONFIRMATION_UNTRACED', 'high', 'Reversement confirmé sans montant, date ou auteur.');
          } else if (r.amountConfirmed > productAmount) {
            add('V2_CASH_CONFIRMED_ABOVE_DUE', 'critical', 'Montant confirmé supérieur au montant dû.',
              { expected: productAmount, actual: r.amountConfirmed, difference: r.amountConfirmed - productAmount });
          } else if (r.amountConfirmed < productAmount && r.status === 'confirmed') {
            add('V2_CASH_SHORTFALL', 'medium', 'Montant confirmé inférieur au montant dû : reliquat à tracer.',
              { expected: productAmount, actual: r.amountConfirmed, difference: productAmount - r.amountConfirmed, owedTo: 'partner' });
            if (o.merchantCashSettled === true) {
              add('V2_CASH_SETTLED_WITH_OUTSTANDING', 'high', 'Reversement marqué réglé alors qu’un reliquat reste dû au partenaire.',
                { expected: productAmount, actual: r.amountConfirmed, difference: productAmount - r.amountConfirmed, owedTo: 'partner' });
            }
          }
        } else if (r.status === 'disputed') {
          add('V2_CASH_DISPUTED', 'medium', 'Reversement cash contesté : décision du super-administrateur attendue.', { amountDueToPartner: productAmount });
        } else {
          const since = Number.isFinite(Number(r.deliveredAtMs)) ? Number(r.deliveredAtMs) : null;
          const overdue = since !== null && nowMs - since > CASH_REMITTANCE_DELAY_MS;
          add(overdue ? 'V2_CASH_REMITTANCE_OVERDUE' : 'V2_CASH_REMITTANCE_PENDING', overdue ? 'medium' : 'info',
            overdue ? 'Reversement cash en retard (plus de 24 h après la livraison) : alerte administrative.'
              : 'Reversement cash au partenaire en attente de confirmation.', { amountDueToPartner: productAmount, owedTo: 'partner' });
        }
      }
      // État du paiement (7D-5) : une déclaration « Non payé » n'établit AUCUNE dette ; elle exige une vérification.
      const p = o.cashPayment;
      if (p && p.verification === 'pending_review') {
        add('V2_CASH_PAYMENT_UNVERIFIED', 'medium', 'Non-paiement déclaré par le livreur : vérification du super-administrateur en attente (le montant dû est conservé, aucune dette établie, aucun débit).',
          { amountDueToPartner: productAmount, owedTo: 'to_verify' });
      } else if (p && p.verification === 'confirmed_unpaid' && (!r || r.status !== 'resolved')) {
        add('V2_CASH_UNPAID_CONFIRMED_UNSETTLED', 'high', 'Non-paiement confirmé par l’administration mais reversement non régularisé : décision sur le montant final attendue.',
          { amountDueToPartner: productAmount, owedTo: 'to_decide' });
      }
    }
  }

  // ── Commission : sur les frais seuls, prélevée une seule fois ───────────────────────────────────────────────
  if (o.driverId && Number.isSafeInteger(o.commissionAmount) && o.commissionAmount > deliveryFee) {
    add('V2_COMMISSION_EXCEEDS_FEE', 'critical', 'Commission supérieure aux frais de livraison (elle ne porte jamais sur les produits).',
      { expected: deliveryFee, actual: o.commissionAmount, difference: o.commissionAmount - deliveryFee });
  }
  if (commissionLines > 1) {
    add('V2_COMMISSION_DOUBLE', 'high', 'Plusieurs prélèvements de commission pour une même commande.', { lines: commissionLines });
  }
  return { findings, collected: clientPaid, refunded, partnerCredited, driverEarning };
}

function analyzePartnerOrders({
  orders = [], clientLedger = [], partnerLedger = [], driverLedger = [], reconciliationFlags = [], nowMs = Date.now(),
} = {}) {
  const rows = [];
  let versionedAnalyzed = 0;
  let outOfScope = 0;

  for (const o of orders) {
    if (!PARTNER_SELLER_TYPES.includes(o.sellerType)) { outOfScope += 1; continue; }
    const v2Amounts = readPartnerAmounts(o);
    if (v2Amounts || o.amountsVersion === 2) {
      versionedAnalyzed += 1;
      const bakeryV2 = o.sellerType === 'boulangerie';
      let result;
      if (v2Amounts) {
        result = analyzeV2Order(o, v2Amounts, { clientLedger, partnerLedger, driverLedger, reconciliationFlags, nowMs });
      } else {
        // Version 2 déclarée mais montants incohérents : jamais traitée comme une commande historique.
        result = {
          findings: [{ code: 'V2_AMOUNTS_INCONSISTENT', severity: 'critical', note: 'amountsVersion 2 avec montants incohérents (produits + livraison ≠ total, ou budget ≠ livraison).' }],
          collected: sumOf(clientLedger, o.id, ['purchase', 'payment']), refunded: sumOf(clientLedger, o.id, ['refund']),
          partnerCredited: sumOf(partnerLedger, o.id, ['earning']), driverEarning: sumOf(driverLedger, o.id, ['earning']),
        };
      }
      if (result.findings.length) {
        result.findings.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
        rows.push({
          orderId: o.id, sellerType: o.sellerType, sellerId: o.sellerId ?? null, clientId: o.clientId ?? null,
          status: o.status ?? null, paymentMethod: o.paymentMethod ?? null, isPaid: o.isPaid === true,
          orderKind: bakeryV2 ? 'bakery_v2' : 'restaurant_v2',
          collectedFromClient: result.collected, refundedToClient: result.refunded,
          partnerCredited: result.partnerCredited, driverEarning: result.driverEarning,
          findings: result.findings, worstSeverity: result.findings[0].severity, decisionKey: `partner_reconcile_${o.id}`,
        });
      }
      continue;
    }

    const findings = [];
    const add = (code, severity, note, extra = {}) => findings.push({ code, severity, note, ...extra });

    const bakery = o.sellerType === 'boulangerie';
    const cake = bakery && o.orderSubType === 'custom_cake';
    const wallet = o.paymentMethod === 'wallet';
    const budget = o.budget;
    const shopping = o.shoppingBudget === undefined ? 0 : o.shoppingBudget;

    // ── 1. Cohérence produits / livraison / total ────────────────────────────────────────────────────────────
    let amountsOk = true;
    let expectedTotal;
    let partnerDue;
    let driverFeeDue;
    if (bakery) {
      if (!isInt(o.itemsAmount) || !isInt(budget) || !isInt(o.totalAmount) || o.itemsAmount + budget !== o.totalAmount) {
        amountsOk = false;
        add('AMOUNT_MISMATCH', 'high', 'itemsAmount + budget (livraison) ≠ totalAmount, ou montant absent/invalide.',
          { itemsAmount: o.itemsAmount ?? null, deliveryFee: budget ?? null, totalAmount: o.totalAmount ?? null });
      } else {
        expectedTotal = o.totalAmount;
        partnerDue = o.itemsAmount;
        driverFeeDue = budget;
      }
    } else if (!isInt(budget) || !isInt(shopping) || budget <= 0) {
      amountsOk = false;
      add('AMOUNT_MISMATCH', 'high', 'budget (total des plats) absent ou invalide.', { budget: budget ?? null });
    } else {
      expectedTotal = budget + shopping;
      partnerDue = expectedTotal; // restaurant : tout le budget revient au restaurant ; aucun frais séparé
      driverFeeDue = 0;
    }

    const driverId = o.driverId || null;
    const ledgerPaid = sumOf(clientLedger, o.id, ['purchase', 'payment']);
    const refunded = sumOf(clientLedger, o.id, ['refund']);
    const partnerCredited = sumOf(partnerLedger, o.id, ['earning']);
    const partnerCreditLines = countOf(partnerLedger, o.id, ['earning']);
    const driverEarning = sumOf(driverLedger, o.id, ['earning']);

    // Montant réellement encaissé auprès du client (wallet) :
    //  - restaurant et gâteau : débit au moment de la création, imposé par la règle Firestore
    //    walletDebitMatchesPaidOrder (isPaid=true ⇒ débit = total) ;
    //  - boulangerie standard : uniquement via payOrderFromWalletCF (journal `payment`).
    let collected = 0;
    if (wallet && amountsOk) {
      if (bakery && !cake) collected = ledgerPaid;
      else collected = o.isPaid === true ? expectedTotal : 0;
    } else if (wallet) {
      collected = ledgerPaid;
    }

    if (wallet && amountsOk && !(bakery && !cake) && o.isPaid === true && ledgerPaid > 0 && ledgerPaid !== collected) {
      add('LEDGER_AMOUNT_DIFFERS', 'medium', 'Le journal client ne correspond pas au débit imposé par la règle.',
        { expected: collected, actual: ledgerPaid, difference: Math.abs(collected - ledgerPaid) });
    }
    if (wallet && cake && o.isPaid === true && ledgerPaid === 0) {
      add('CLIENT_LEDGER_MISSING', 'info', 'Gâteau payé en wallet : le débit n\'a jamais été journalisé côté client.');
    }

    // ── 2. Wallet : encaissement, crédit partenaire, crédit livreur ──────────────────────────────────────────
    if (wallet && amountsOk && o.status === 'delivered') {
      if (bakery && !cake && collected < expectedTotal) {
        add('WALLET_NOT_FULLY_COLLECTED', 'critical',
          'Boulangerie wallet livrée : les articles n\'ont jamais été débités (seuls les frais éventuels l\'ont été).',
          { expected: expectedTotal, actual: collected, difference: expectedTotal - collected, owedBy: 'client' });
      }
      if (collected >= partnerDue && partnerCredited < partnerDue) {
        add('CLIENT_DEBIT_WITHOUT_PARTNER_CREDIT', 'critical',
          'Le client a payé les produits, le partenaire n\'a pas reçu leur montant.',
          { expected: partnerDue, actual: partnerCredited, difference: partnerDue - partnerCredited, owedTo: 'partner' });
      }
      if (partnerCredited > partnerDue) {
        add('PARTNER_OVERCREDITED', 'critical', 'Le partenaire a reçu plus que le montant de ses produits.',
          { expected: partnerDue, actual: partnerCredited, difference: partnerCredited - partnerDue });
      }
      if (partnerCreditLines > 1) {
        add('PARTNER_DOUBLE_CREDIT', 'critical', 'Plusieurs crédits partenaire pour une même commande.',
          { lines: partnerCreditLines });
      }
      if (bakery && collected > 0 && driverId && driverEarning < driverFeeDue) {
        add('DRIVER_FEE_UNPAID', 'high', 'Livraison payée par le client mais frais de livraison non crédités au livreur.',
          { expected: driverFeeDue, actual: driverEarning, difference: driverFeeDue - driverEarning, owedTo: 'driver' });
      }
      if (driverEarning > driverFeeDue) {
        add(partnerCredited > 0 && !bakery ? 'DRIVER_AND_PARTNER_BOTH_CREDITED' : 'DRIVER_OVERCREDITED', 'high',
          'Crédit livreur supérieur à ce que la commande prévoit.',
          { expected: driverFeeDue, actual: driverEarning, difference: driverEarning - driverFeeDue });
      }
    }

    // ── 3. Annulation et remboursement ───────────────────────────────────────────────────────────────────────
    if (o.status === 'cancelled' && wallet && collected > 0) {
      if (refunded === 0) {
        add('CANCELLED_NOT_REFUNDED', 'critical', 'Commande annulée, montant encaissé non remboursé.',
          { expected: collected, actual: 0, difference: collected, owedTo: 'client' });
      } else if (refunded < collected) {
        add('REFUND_INCOMPLETE', 'critical',
          cake ? 'Gâteau annulé : seuls les frais de livraison ont été remboursés, pas les articles.' : 'Remboursement inférieur au montant encaissé.',
          { expected: collected, actual: refunded, difference: collected - refunded, owedTo: 'client' });
      } else if (refunded > collected) {
        add('OVER_REFUNDED', 'critical', 'Remboursement supérieur au montant encaissé.',
          { expected: collected, actual: refunded, difference: refunded - collected });
      }
    }
    if (o.status !== 'cancelled' && refunded > 0 && o.status !== 'delivered') {
      add('REFUND_ON_ACTIVE_ORDER', 'high', 'Remboursement enregistré sur une commande non annulée.', { actual: refunded });
    }
    if (o.status === 'cancelled' && partnerCredited > 0) {
      add('PARTNER_CREDITED_ON_CANCELLED', 'critical', 'Partenaire crédité sur une commande annulée.',
        { actual: partnerCredited });
    }

    // ── 4. Cash : reversement au partenaire ──────────────────────────────────────────────────────────────────
    if (!wallet && o.status === 'delivered' && amountsOk) {
      if (o.merchantCashSettled !== true) {
        add('CASH_REMITTANCE_PENDING', 'medium', 'Produits encaissés en espèces par le livreur : reversement au partenaire non confirmé.',
          { amountDueToPartner: partnerDue, owedTo: 'partner' });
      } else if (!o.merchantCashSettledBy || !o.merchantCashSettledAt) {
        add('CASH_SETTLEMENT_UNTRACED', 'medium', 'Reversement marqué réglé sans auteur ni date, et sans montant remis.');
      }
    }

    // ── 5. Commission (information uniquement) ───────────────────────────────────────────────────────────────
    if (driverId && o.status === 'delivered') {
      const traced = o.commissionStatus === 'charged' && isInt(o.commissionAmount);
      const commissionLine = countOf(driverLedger, o.id, ['commission']) > 0;
      if (!traced && !commissionLine) {
        add('COMMISSION_UNTRACED', 'info', 'Aucune trace de la commission d\'acceptation (commande antérieure au suivi serveur).');
      }
      if (!bakery && traced && o.commissionAmount > 0) {
        add('COMMISSION_ON_PRODUCT_BASE', 'info', 'Restaurant : commission calculée sur le total des plats (budget), pas sur des frais de livraison.',
          { actual: o.commissionAmount, base: budget });
      }
    }

    if (findings.length) {
      findings.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
      rows.push({
        orderId: o.id, sellerType: o.sellerType, sellerId: o.sellerId ?? null, clientId: o.clientId ?? null,
        status: o.status ?? null, paymentMethod: o.paymentMethod ?? null, isPaid: o.isPaid === true,
        orderKind: cake ? 'custom_cake' : bakery ? 'bakery_standard' : 'restaurant',
        collectedFromClient: collected, refundedToClient: refunded, partnerCredited, driverEarning,
        findings,
        worstSeverity: findings[0].severity,
        // Une décision humaine par commande ; aucune écriture n'est proposée ici.
        decisionKey: `partner_reconcile_${o.id}`,
      });
    }
  }

  rows.sort((a, b) => SEVERITY_RANK[a.worstSeverity] - SEVERITY_RANK[b.worstSeverity]);
  const byCode = {};
  const bySeverity = { critical: 0, high: 0, medium: 0, info: 0 };
  for (const r of rows) {
    for (const f of r.findings) {
      byCode[f.code] = (byCode[f.code] || 0) + 1;
      bySeverity[f.severity] += 1;
    }
  }
  return {
    rows,
    summary: {
      ordersAnalyzed: orders.length - outOfScope,
      ordersWithFindings: rows.length,
      versionedAnalyzed,
      versionedSkipped: 0, // conservé pour compatibilité des lecteurs de rapport : les v2 sont désormais analysées
      outOfScope,
      bySeverity,
      byCode,
    },
  };
}

// Rapport ANONYMISÉ : aucun identifiant de commande, de client, de partenaire ni de livreur en clair, aucun nom,
// téléphone, adresse ni description. Les identifiants deviennent des empreintes salées et tronquées (non réversibles
// sans le sel). Le sel est choisi par l'opérateur (`--salt`) pour pouvoir retrouver une commande en recalculant son
// empreinte ; sans sel, un sel aléatoire est utilisé et le rapport n'est pas ré-identifiable. Les constats ne
// contiennent que des codes, des gravités et des montants.
function anonymizeReport(report, salt = crypto.randomBytes(16).toString('hex')) {
  const ref = (kind, value) => (value === null || value === undefined ? null
    : `${kind}_${crypto.createHash('sha256').update(`${salt}|${kind}|${value}`).digest('hex').slice(0, 12)}`);
  return {
    rows: report.rows.map((r) => ({
      orderRef: ref('order', r.orderId),
      partnerRef: ref('partner', r.sellerId),
      clientRef: ref('client', r.clientId),
      sellerType: r.sellerType, status: r.status, paymentMethod: r.paymentMethod, isPaid: r.isPaid,
      orderKind: r.orderKind, worstSeverity: r.worstSeverity,
      collectedFromClient: r.collectedFromClient, refundedToClient: r.refundedToClient,
      partnerCredited: r.partnerCredited, driverEarning: r.driverEarning,
      findings: r.findings.map((f) => {
        const { code, severity, expected, actual, difference, owedTo, owedBy, amountDueToPartner, lines } = f;
        return { code, severity, expected, actual, difference, owedTo, owedBy, amountDueToPartner, lines };
      }),
    })),
    summary: report.summary,
  };
}

module.exports = { analyzePartnerOrders, anonymizeReport };
