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
// Une commande déjà au format versionné (partnerOrderAmounts.js) est hors périmètre : sa conservation des montants
// est garantie par construction, elle sera contrôlée par son propre rapprochement.

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

function analyzePartnerOrders({ orders = [], clientLedger = [], partnerLedger = [], driverLedger = [] } = {}) {
  const rows = [];
  let versionedSkipped = 0;
  let outOfScope = 0;

  for (const o of orders) {
    if (!PARTNER_SELLER_TYPES.includes(o.sellerType)) { outOfScope += 1; continue; }
    if (readPartnerAmounts(o)) { versionedSkipped += 1; continue; }

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
      ordersAnalyzed: orders.length - outOfScope - versionedSkipped,
      ordersWithFindings: rows.length,
      versionedSkipped,
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
