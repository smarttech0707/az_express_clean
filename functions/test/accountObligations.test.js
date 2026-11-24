'use strict';

// Mission 7E-98 (lot 2D-1), durci par 7E-100 (C1 à C6) : prédicat pur des obligations financières. Aucun Firestore, aucun réseau, aucune horloge.
// Les structures de test reprennent les champs réellement écrits par deliverOrderCF, cancelOrderTx, driverTransfer,
// transferSettlement, partnerOrderActions, cashPayment et adminOrderDisputes (voir le rapport 7E-98 §1).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const obligations = require('../accountObligations');
const {
  evaluateAccountObligations: strict, buildFinancialSnapshot, normalizeRole, TYPES, STATE, CODE, MAX_SNAPSHOT_ITEMS,
  INSPECTOR_TERMINAL_STATUSES, KNOWN_TERMINAL_STATUSES, READ_LIMIT, requiredQueries, requiredWalletDebitIds, RESOLUTIONS,
} = obligations;

// Les tests historiques (24) évaluent des listes sans répéter `terminalStatuses` ni `reads` : cet adaptateur les ajoute
// SEULEMENT quand ils sont absents. Les tests 7E-100 (C1/C6) appellent `strict` directement pour prouver le refus.
const TERMINAL = INSPECTOR_TERMINAL_STATUSES.accountDeletionScope;
const withReads = (o) => {
  const req = requiredQueries(o.role, o.ids);
  const reads = {};
  if (!req) return reads;
  for (const n of ['orders', 'settlements', 'flags']) {
    if (Array.isArray(o[n])) reads[n] = { queries: req[n].map((q, i) => ({ ...q, limit: 201, size: i === 0 ? o[n].length : 0 })) };
  }
  return reads;
};
// Journaux de débit conformes (fournis automatiquement aux seuls tests historiques ; les tests 7E-103 appellent `strict`).
const withDebits = (o) => requiredWalletDebitIds(o.role, o.orders).map((id) => {
  const order = o.orders.find((d) => `order_${d.id}` === id).data;
  return { id, exists: true, data: { type: 'payment', amount: order.totalAmount, orderId: id.slice('order_'.length) } };
});
const evaluate = (inp) => {
  if (inp === null || typeof inp !== 'object' || Array.isArray(inp)) return strict(inp);
  const o = { ...inp };
  if (o.terminalStatuses === undefined) o.terminalStatuses = TERMINAL;
  if (o.reads === undefined) o.reads = withReads(o);
  if (o.walletDebits === undefined && Array.isArray(o.orders)) o.walletDebits = withDebits(o);
  return strict(o);
};

const deepFreeze = (v) => {
  if (v && typeof v === 'object' && !Object.isFrozen(v)) { Object.freeze(v); Object.values(v).forEach(deepFreeze); }
  return v;
};
const order = (id, over = {}) => ({
  id,
  data: {
    status: 'delivered', clientId: 'c1', driverId: 'd1', pharmacieId: 'p1', sellerId: 's1', type: 'pharmacie',
    paymentMethod: 'wallet', isPaid: true, budget: 1000, ...over,
  },
});
const input = (role, over = {}) => ({
  role, ids: [{ client: 'c1', livreur: 'd1', pharmacie: 'p1', seller: 's1' }[role] || role],
  orders: [], settlements: [], flags: [], ...over,
});
const types = (r) => r.obligations.map((o) => o.type);
const reasons = (r) => r.obligations.map((o) => o.reason);

test('1. aucune obligation : résultat non bloquant, structure complète', () => {
  for (const role of ['client', 'livreur', 'pharmacie', 'seller']) {
    const r = evaluate(input(role));
    assert.equal(r.blocking, false);
    assert.equal(r.code, CODE.NONE);
    assert.deepEqual(r.obligations, []);
    assert.deepEqual(r.retained, []);
    assert.deepEqual(r.summary, { open: 0, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 0, flags: 0, byType: {} });
  }
});

test('2. commande livrée non payée (wallet, isPaid false) : bloquante pour client, livreur et pharmacie, avec montant', () => {
  const o = order('o1', { isPaid: false, budget: 1500 });
  for (const role of ['client', 'livreur', 'pharmacie']) {
    const r = evaluate(input(role, { orders: [o] }));
    assert.equal(r.blocking, true, role);
    assert.equal(r.code, CODE.PENDING);
    const hit = r.obligations.find((x) => x.type === TYPES.UNPAID_DELIVERED_WALLET);
    assert.ok(hit, role);
    assert.equal(hit.state, STATE.OPEN);
    assert.equal(hit.amount, 1500);
    assert.equal(hit.currency, 'XOF');
    assert.equal(hit.orderId, 'o1');
  }
});

test('3. commande payée (wallet ou espèces) : non bloquante ; exclusion certaine : boutique', () => {
  assert.equal(evaluate(input('client', { orders: [order('o1')] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [order('o2', { paymentMethod: 'cash', isPaid: false, sellerId: undefined })] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [order('o3', { type: 'boutique', isPaid: false })] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [order('o4', { amountsVersion: 2, isPaid: true, productAmount: 900, deliveryFee: 1000, totalAmount: 1900, budget: 1000 })] })).blocking, false, 'v2 payée');
  assert.equal(evaluate(input('client', { orders: [order('o4b', { amountsVersion: 2, isPaid: false })] })).blocking, true, '7E-100 C2 : v2 wallet non payée bloque');
  assert.equal(evaluate(input('client', { orders: [order('o5', { status: 'cancelled', isPaid: false })] })).blocking, false);
});

test('4. settlementHold ouvert / settlementStatus en attente : bloquant (client et livreur), pas pour le partenaire', () => {
  const held = order('o1', { settlementHold: true, settlementStatus: 'pending_admin_review' });
  for (const role of ['client', 'livreur']) {
    const r = evaluate(input(role, { orders: [held] }));
    assert.ok(types(r).includes(TYPES.SETTLEMENT_HELD), role);
  }
  assert.equal(evaluate(input('pharmacie', { orders: [held] })).blocking, false);
  const cash = evaluate(input('livreur', { orders: [order('o2', { settlementStatus: 'cash_pending' })] }));
  assert.deepEqual(reasons(cash), ['settlement_status_cash_pending']);
});

test('5. heldDriverEarning non réglé : bloquant avec montant ; réglé (settled) ou nul : non bloquant', () => {
  const r = evaluate(input('livreur', { orders: [order('o1', { heldDriverEarning: 800, settlementStatus: 'pending_admin_review' })] }));
  const hit = r.obligations.find((x) => x.type === TYPES.HELD_DRIVER_EARNING);
  assert.ok(hit);
  assert.equal(hit.amount, 800);
  assert.equal(evaluate(input('livreur', { orders: [order('o2', { heldDriverEarning: 800, settlementStatus: 'settled', settlementHold: false })] })).blocking, false);
  assert.equal(evaluate(input('livreur', { orders: [order('o3', { heldDriverEarning: 0 })] })).blocking, false);
});

test('5b. frais de livraison retenus et demande d\'annulation après récupération', () => {
  const fee = evaluate(input('client', { orders: [order('o1', { deliveryFeeHold: { amount: 500, status: 'pending_admin_review' } })] }));
  assert.deepEqual(types(fee), [TYPES.DELIVERY_FEE_HELD]);
  assert.equal(fee.obligations[0].amount, 500);
  assert.equal(evaluate(input('client', { orders: [order('o2', { deliveryFeeHold: { amount: 500, status: 'resolved', decision: 'x' } })] })).blocking, false);
  const cancel = evaluate(input('client', { orders: [order('o3', { cancelRequestAfterPickup: { status: 'pending_admin_review' } })] }));
  assert.equal(cancel.obligations[0].state, STATE.REVIEW);
  for (const closed of ['resolved_delivery_confirmed', 'resolved_without_closure', 'resolved_cancelled', 'resolved_partial_refund']) {
    assert.equal(evaluate(input('client', { orders: [order('o4', { cancelRequestAfterPickup: { status: closed } })] })).blocking, false, closed);
  }
});

test('6. remise de fonds non finalisée (cashRemittance) : bloquante ; confirmée en totalité ou résolue : non bloquante', () => {
  const base = { paymentMethod: 'cash', isPaid: true, amountsVersion: 2, sellerId: 's1', productAmount: 4000 };
  const remit = (cashRemittance, extra = {}) => order('o1', { ...base, cashRemittance, ...extra });
  for (const status of ['pending', 'declared']) {
    const r = evaluate(input('livreur', { orders: [remit({ status, amountDue: 4000 })] }));
    assert.deepEqual(types(r), [TYPES.CASH_REMITTANCE_OPEN], status);
    assert.equal(r.obligations[0].amount, 4000);
  }
  const partial = evaluate(input('seller', { orders: [remit({ status: 'confirmed', amountDue: 4000, amountConfirmed: 1500 })] }));
  assert.equal(partial.obligations[0].amount, 2500);
  assert.equal(evaluate(input('seller', { orders: [remit({ status: 'disputed', amountDue: 4000 })] })).obligations[0].state, STATE.REVIEW);
  assert.equal(evaluate(input('livreur', { orders: [remit({ status: 'confirmed', amountDue: 4000, amountConfirmed: 4000 }, { merchantCashSettled: true })] })).blocking, false);
  assert.equal(evaluate(input('livreur', { orders: [remit({ status: 'resolved', amountDue: 4000, resolution: { finalAmount: 3000 } })] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [remit({ status: 'pending', amountDue: 4000 })] })).blocking, false, 'le client n\'est pas partie au reversement');
});

test('6b. espèces avec marchand sans cashRemittance (ancien format) : merchantCashSettled false => bloquant', () => {
  const legacy = order('o1', { paymentMethod: 'cash', isPaid: false, sellerId: 's1', merchantCashSettled: false, type: 'restaurant', pharmacieId: undefined });
  assert.deepEqual(types(evaluate(input('livreur', { orders: [legacy] }))), [TYPES.MERCHANT_CASH_UNSETTLED]);
  assert.equal(evaluate(input('seller', { orders: [{ ...legacy, data: { ...legacy.data, merchantCashSettled: true } }] })).blocking, false);
  const v2missing = evaluate(input('livreur', { orders: [order('o2', { paymentMethod: 'cash', amountsVersion: 2, sellerId: 's1' })] }));
  assert.equal(v2missing.code, CODE.AMBIGUOUS, 'v2 cash livrée sans cashRemittance = incohérent');
});

test('6c. non-paiement espèces déclaré : revue en attente bloquante ; examiné : non bloquant', () => {
  const declared = (verification) => order('o1', { paymentMethod: 'cash', isPaid: false, sellerId: undefined, cashPayment: { status: 'non_payment_declared', verification } });
  assert.equal(evaluate(input('client', { orders: [declared('pending_review')] })).obligations[0].type, TYPES.CASH_PAYMENT_REVIEW);
  // 7E-103 : le client est traité au cas par cas (revue bloquante, aucun montant inventé) ; le livreur n'est pas concerné.
  const clientCase = evaluate(input('client', { orders: [declared('confirmed_unpaid')] }));
  assert.deepEqual(reasons(clientCase), ['cash_nonpayment_case_review']);
  assert.equal(clientCase.obligations[0].amount, null);
  assert.equal(evaluate(input('livreur', { orders: [declared('confirmed_unpaid')] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [declared('refuted')] })).blocking, false);
  assert.equal(evaluate(input('client', { orders: [declared('not_required')] })).code, CODE.AMBIGUOUS);
});

test('7. transfer_settlements ouvert : bloquant pour les livreurs de la chaîne et le client ; settled : non bloquant', () => {
  const s = (status, over = {}) => ({ id: 'o1', data: { orderId: 'o1', status, driverIds: ['d1', 'd2'], holderDriverId: 'd2', clientId: 'c1', totalPaid: 2000, method: 'wallet', ...over } });
  for (const role of ['livreur', 'client']) {
    const r = evaluate(input(role, { settlements: [s('pending_review')] }));
    assert.deepEqual(types(r), [TYPES.TRANSFER_SETTLEMENT_OPEN], role);
    assert.equal(r.obligations[0].amount, 2000);
  }
  assert.equal(evaluate(input('livreur', { settlements: [s('cash_pending')] })).obligations[0].state, STATE.OPEN);
  assert.equal(evaluate(input('livreur', { settlements: [s('settled')] })).blocking, false);
  assert.equal(evaluate({ ...input('livreur', { settlements: [s('pending_review')] }), ids: ['d2'] }).blocking, true, 'livreur détenteur');
  // Un partenaire n'est jamais partie à un transfert : lui fournir des règlements est un défaut d'appel => ambigu, bloquant.
  const misuse = evaluate(input('pharmacie', { settlements: [s('pending_review')] }));
  assert.equal(misuse.code, CODE.AMBIGUOUS);
  assert.ok(reasons(misuse).includes('settlement_not_linked_to_account'));
  assert.equal(evaluate({ role: 'pharmacie', ids: ['p1'], orders: [], flags: [] }).blocking, false, 'liste omise pour un partenaire : non bloquant');
});

test('7b. signalements de rapprochement : open bloquant, recorded conservé non bloquant (avec trace), reviewed/resolved clos (avec trace)', () => {
  const f = (status, over = {}) => ({ id: `o1_flag_${status}`, data: { orderId: 'o1', type: 'cash_shortfall', status, driverId: 'd1', amount: 700, ...over } });
  const open = evaluate(input('livreur', { flags: [f('open')] }));
  assert.equal(open.obligations[0].type, TYPES.RECONCILIATION_FLAG_OPEN);
  assert.equal(open.obligations[0].amount, 700);
  // 7E-103 : `recorded` n'est PAS une dette abandonnée : bloquant (revue) tant qu'aucune décision de clôture n'existe.
  const recorded = evaluate(input('livreur', { flags: [f('recorded', { decidedBy: 'adm1', requestId: 'req-1' })] }));
  assert.equal(recorded.blocking, true);
  assert.equal(recorded.retained.length, 0);
  assert.deepEqual(reasons(recorded), ['flag_recorded_open']);
  assert.equal(recorded.obligations[0].state, STATE.REVIEW);
  assert.equal(recorded.obligations[0].amount, 700);
  const reviewed = f('reviewed', { type: 'cash_payment_review', reviewedBy: 'adm1', reviewedAtMs: 5, requestId: 'r2', decision: 'confirm_unpaid', verification: 'confirmed_unpaid' });
  const resolved = f('resolved', { decidedBy: 'adm0', resolvedBy: 'adm1', resolvedAtMs: 6, resolutionRequestId: 'request-resolution-0003', resolutionDecisionId: 'dec1', resolution: 'recovered_in_full' });
  const decision = { id: 'dec1', data: { status: 'executed', subjectKind: 'flag', subjectId: resolved.id, subjectType: 'cash_shortfall', resolution: 'recovered_in_full', requestId: 'request-resolution-0003', requestedBy: 'adm1', requestedAtMs: 6, approvedBy: 'adm2', approvedAtMs: 7, tier: 2, remaining: 0 } };
  const closed = evaluate(input('livreur', { flags: [resolved, reviewed], decisions: [decision] }));
  assert.equal(closed.blocking, false);
  assert.equal(closed.retained.length, 2, 'décisions conservées pour la traçabilité');
  assert.equal(evaluate(input('livreur', { flags: [resolved] })).blocking, true, 'sans registre de décisions : non vérifié => bloquant');
});

test('8. plusieurs obligations : toutes identifiées, comptées par type, ordre stable', () => {
  const r = evaluate(input('livreur', {
    orders: [
      order('o2', { isPaid: false }),
      order('o1', { settlementHold: true, settlementStatus: 'pending_admin_review', heldDriverEarning: 500 }),
    ],
    settlements: [{ id: 'o1', data: { orderId: 'o1', status: 'pending_review', driverIds: ['d1'], holderDriverId: 'd1', clientId: 'c1', totalPaid: 900 } }],
    flags: [{ id: 'f1', data: { orderId: 'o2', type: 'partner_credit_missing', status: 'open', driverId: 'd1', sellerId: 's1' } }],
  }));
  assert.deepEqual(types(r), [
    TYPES.HELD_DRIVER_EARNING, TYPES.RECONCILIATION_FLAG_OPEN, TYPES.SETTLEMENT_HELD, TYPES.TRANSFER_SETTLEMENT_OPEN, TYPES.UNPAID_DELIVERED_WALLET,
  ]);
  assert.equal(r.summary.open + r.summary.review, 5);
  assert.deepEqual(r.summary.byType, {
    held_driver_earning: 1, reconciliation_flag_open: 1, settlement_held: 1, transfer_settlement_open: 1, unpaid_delivered_wallet: 1,
  });
});

test('9. statut inconnu : fail-closed, jamais réglé', () => {
  const cases = [
    order('a', { status: 'mystery' }),
    order('b', { status: undefined }),
    order('c', { settlementStatus: 'archived' }),
    order('d', { deliveryFeeHold: { amount: 5, status: 'weird' } }),
    order('e', { cancelRequestAfterPickup: { status: 'weird' } }),
    order('f', { paymentMethod: 'cash', amountsVersion: 2, cashRemittance: { status: 'weird', amountDue: 1 } }),
    order('g', { cashPayment: { status: 'weird', verification: 'not_required' } }),
    order('h', { paymentMethod: 'barter', isPaid: false }),
  ];
  for (const o of cases) {
    const r = evaluate(input('livreur', { orders: [o] }));
    assert.equal(r.blocking, true, o.id);
    assert.equal(r.code, CODE.AMBIGUOUS, o.id);
  }
  const s = evaluate(input('livreur', { settlements: [{ id: 'x', data: { status: 'archived', driverIds: ['d1'] } }] }));
  assert.equal(s.code, CODE.AMBIGUOUS);
  const fl = evaluate(input('livreur', { flags: [{ id: 'x', data: { status: 'archived', driverId: 'd1' } }] }));
  assert.equal(fl.code, CODE.AMBIGUOUS);
});

test('10. données incohérentes ou de type inattendu : fail-closed', () => {
  const bad = [
    order('a', { refundPending: 'yes' }),
    order('b', { needsReview: 1 }),
    order('c', { paymentStatus: 3 }),
    order('d', { isPaid: 'false' }),
    order('e', { settlementHold: 'true' }),
    order('f', { settlementStatus: 'settled', settlementHold: true }),
    order('g', { heldDriverEarning: 'lots' }),
    order('h', { heldDriverEarning: -5 }),
    order('i', { paymentMethod: 'cash', amountsVersion: 2, cashRemittance: { status: 'confirmed', amountDue: 100, amountConfirmed: 500 } }),
    order('j', { paymentMethod: 'cash', amountsVersion: 2, cashRemittance: { status: 'resolved', amountDue: 100, resolution: {} } }),
    order('k', { paymentMethod: 'cash', merchantCashSettled: true, cashRemittance: { status: 'declared', amountDue: 100 } }),
    { id: 'l', data: 'not an object' },
    order('m', { clientId: 'other', driverId: 'other', pharmacieId: 'other', sellerId: 'other' }),
  ];
  for (const o of bad) {
    const r = evaluate(input('livreur', { orders: [o] }));
    assert.equal(r.blocking, true, o.id);
    assert.ok(r.obligations.some((x) => x.state === STATE.AMBIGUOUS), o.id);
  }
  assert.equal(evaluate(input('livreur', { orders: [{ data: {} }] })).code, CODE.AMBIGUOUS);
  assert.equal(evaluate(input('livreur', { orders: 'oops' })).code, CODE.AMBIGUOUS);
});

test('10b. entrée invalide : rôle inconnu, identifiants absents, entrée non objet, listes manquantes ou tronquées', () => {
  for (const bad of [null, undefined, 3, [], { role: 'admin', ids: ['x'], orders: [] }, { role: 'client', ids: [], orders: [] }, { role: 'client', orders: [] }]) {
    const r = evaluate(bad);
    assert.equal(r.blocking, true);
    assert.equal(r.code, CODE.AMBIGUOUS);
  }
  const missing = evaluate({ role: 'client', ids: ['c1'] });
  assert.deepEqual(reasons(missing).sort(), ['flags_not_provided', 'orders_not_provided', 'settlements_not_provided']);
  const noSettlementNeeded = evaluate({ role: 'pharmacie', ids: ['p1'], orders: [], flags: [] });
  assert.equal(noSettlementNeeded.blocking, false, 'liste settlements non requise pour un partenaire');
  const truncated = evaluate(input('client', { orders: Array.from({ length: 201 }, (_, i) => order(`t${i}`)) }));
  assert.deepEqual(reasons(truncated), ['orders_truncated']);
});

test('11. obligation résolue : non bloquante, y compris après transition (replay du même compte)', () => {
  const before = input('livreur', { orders: [order('o1', { isPaid: false })] });
  assert.equal(evaluate(before).blocking, true);
  const after = input('livreur', { orders: [order('o1', { isPaid: true })] });
  assert.equal(evaluate(after).blocking, false);
  const settledAfter = input('livreur', { orders: [order('o2', { settlementHold: false, settlementStatus: 'settled', heldDriverEarning: 300 })] });
  assert.equal(evaluate(settledAfter).blocking, false);
});

test('12. profil sans données financières : non bloquant seulement si les listes sont fournies (absence certaine)', () => {
  assert.equal(evaluate(input('client')).blocking, false);
  assert.equal(evaluate({ role: 'client', ids: ['c1'], orders: [], settlements: [], flags: [] }).blocking, false);
  assert.equal(evaluate({ role: 'client', ids: ['c1'] }).blocking, true, 'listes non fournies = absence non certaine');
});

test('12b. opération non terminée et drapeaux existants des inspecteurs sont repris', () => {
  const active = evaluate(input('client', { orders: [order('o1', { status: 'accepted' })] }));
  assert.deepEqual(reasons(active), ['active_or_unresolved_operation']);
  assert.deepEqual(types(evaluate(input('client', { orders: [order('o2', { refundPending: true })] }))), [TYPES.REFUND_PENDING]);
  assert.equal(evaluate(input('client', { orders: [order('o3', { needsReview: true, reviewReason: 'beneficiary_account_closed' })] })).obligations[0].reason, 'needs_review:beneficiary_account_closed');
  assert.deepEqual(types(evaluate(input('client', { orders: [order('o4', { paymentStatus: 'pending' })] }))), [TYPES.PAYMENT_PENDING]);
});

test('12c. commande wallet livrée sans champ isPaid : toujours bloquante ; l\'option de dérogation n\'existe plus (7E-100)', () => {
  const legacy = order('o1', { isPaid: undefined });
  const blocked = evaluate(input('client', { orders: [legacy] }));
  assert.equal(blocked.code, CODE.AMBIGUOUS);
  assert.deepEqual(reasons(blocked), ['delivered_wallet_order_is_paid_absent']);
  const ignored = evaluate(input('client', { orders: [legacy], legacyAbsentIsPaid: 'ignore' }));
  assert.equal(ignored.blocking, true);
  assert.ok(reasons(ignored).includes('legacy_option_unsupported'));
  assert.ok(reasons(ignored).includes('delivered_wallet_order_is_paid_absent'));
});

test('déterminisme : même résultat à chaque appel, quel que soit l\'ordre des documents ; entrées jamais modifiées', () => {
  const orders = [
    order('o3', { isPaid: false }),
    order('o1', { settlementStatus: 'cash_pending' }),
    order('o2', { deliveryFeeHold: { amount: 100, status: 'pending_admin_review' } }),
  ];
  const flags = [{ id: 'f2', data: { status: 'recorded', type: 'cash_shortfall', driverId: 'd1', amount: 5, decidedBy: 'adm1', requestId: 'r1' } }, { id: 'f1', data: { status: 'open', driverId: 'd1' } }];
  const a = deepFreeze(input('livreur', { orders, flags }));
  const r1 = evaluate(a);
  const r2 = evaluate(a);
  assert.deepEqual(r1, r2);
  assert.equal(JSON.stringify(r1), JSON.stringify(r2));
  const shuffled = input('livreur', { orders: [...orders].reverse(), flags: [...flags].reverse() });
  assert.equal(JSON.stringify(evaluate(shuffled)), JSON.stringify(r1));
  assert.equal(JSON.stringify(a), JSON.stringify(deepFreeze(JSON.parse(JSON.stringify(a)))), 'aucune mutation de l\'entrée (gelée : une écriture lèverait)');
});

test('alias de rôle et normalisation', () => {
  assert.equal(normalizeRole('livreur'), 'driver');
  assert.equal(normalizeRole('Driver'), 'driver');
  assert.equal(normalizeRole('pharmacie'), 'partner');
  assert.equal(normalizeRole('boulangerie'), 'partner');
  assert.equal(normalizeRole('admin'), null);
  assert.equal(normalizeRole(undefined), null);
});

test('snapshot financier : structure minimale sans donnée personnelle, bornée, déterministe, sans horloge', () => {
  const r = evaluate(input('livreur', {
    orders: [order('o1', { isPaid: false, budget: 1500, clientName: 'Awa Koné', clientPhone: '+2250700000000', deliveryAddress: 'Rue 12' })],
    flags: [{ id: 'f2', data: { status: 'reviewed', type: 'cash_payment_review', driverId: 'd1', reviewedBy: 'adm1', reviewedAtMs: 5, requestId: 'r1', decision: 'refute', verification: 'refuted' } }],
  }));
  const snap = buildFinancialSnapshot(r, { atMs: 1700000000000 });
  assert.deepEqual(Object.keys(snap).sort(), ['atMs', 'blocking', 'code', 'counts', 'currency', 'items', 'manualReviewRequired', 'omitted', 'truncated', 'version']);
  assert.equal(snap.version, 1);
  assert.equal(snap.atMs, 1700000000000);
  assert.equal(snap.blocking, true);
  assert.equal(snap.currency, 'XOF');
  assert.deepEqual(snap.counts, { open: 1, review: 0, ambiguous: 0, retained: 1, manualReview: 0, orders: 1, economic: 1, flags: 0 });
  assert.deepEqual(Object.keys(snap.items[0]).sort(), ['amount', 'claim', 'currency', 'economicKey', 'orderId', 'party', 'reason', 'refId', 'source', 'state', 'status', 'type']);
  const text = JSON.stringify(snap);
  for (const secret of ['Awa', '0700000000000', 'Rue 12', 'clientName', 'clientPhone']) assert.equal(text.includes(secret), false, secret);
  assert.equal(JSON.stringify(buildFinancialSnapshot(r, { atMs: 1700000000000 })), text);
  assert.equal(buildFinancialSnapshot(r).atMs, null, 'aucune horloge interne');
  const many = evaluate(input('client', { orders: Array.from({ length: MAX_SNAPSHOT_ITEMS + 7 }, (_, i) => order(`o${String(i).padStart(3, '0')}`, { isPaid: false })) }));
  const big = buildFinancialSnapshot(many, { atMs: 1 });
  assert.equal(big.items.length, MAX_SNAPSHOT_ITEMS);
  assert.equal(big.truncated, true);
  assert.equal(big.omitted, 7);
  assert.equal(buildFinancialSnapshot(null).blocking, true, 'résultat illisible => bloquant');
});

test('pureté : le module n\'importe rien, n\'utilise ni horloge, ni Firestore, ni réseau, ni process', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'accountObligations.js'), 'utf8');
  const code = src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
  assert.equal(/require\(/.test(code), false, 'aucun require');
  for (const forbidden of ['Date.now', 'new Date', 'Math.random', 'firebase', 'firestore', 'fetch(', 'axios', 'process.', '.set(', '.update(', '.get(', 'tx.']) {
    assert.equal(code.includes(forbidden), false, forbidden);
  }
});

test('périmètre (L2) : le moteur est utilisé uniquement par les inspecteurs de suppression, jamais par index.js ni par un writer', () => {
  const dir = path.join(__dirname, '..');
  // Intégré en L2 (D-12 : en plus des contrôles existants) par l'inspecteur de lecture et les deux moteurs de suppression.
  for (const f of ['accountObligationsInspector.js', 'accountDeletion.js', 'partnerAccountDeletion.js']) {
    assert.equal(fs.readFileSync(path.join(dir, f), 'utf8').includes('accountObligations'), true, f);
  }
  // Toujours hors du chemin des writers financiers, des gardes d'admission et de la couche d'exports.
  // L2.2 : le périmètre partenaires n'appelle que l'inspecteur de retraits (accountObligationsInspector), jamais le moteur directement.
  assert.equal(fs.readFileSync(path.join(dir, 'accountDeletionScope.js'), 'utf8').includes("require('./accountObligations')"), false, 'accountDeletionScope.js');
  assert.equal(fs.readFileSync(path.join(dir, 'accountDeletionScope.js'), 'utf8').includes("require('./accountObligationsInspector')"), true, 'accountDeletionScope.js');
  for (const f of ['index.js', 'orderActions.js', 'accountAdmission.js', 'feexpayPayments.js']) {
    assert.equal(fs.readFileSync(path.join(dir, f), 'utf8').includes('accountObligations'), false, f);
  }
});


// ═══════════════ Missions 7E-100 et 7E-103 : durcissement (C1 à C6, D-1, D-2, D-6, décisions 7E-102) ═══════════════
const base = (role, over = {}) => ({ ...input(role, over), terminalStatuses: TERMINAL });
const covered = (o) => ({ ...o, reads: withReads(o) });
const noUnrecognized = (r) => assert.equal(JSON.stringify(r).includes('unrecognized_reason'), false);
const queryOf = (key, id, size = 0, limit = 201) => ({ key, id, limit, size });
// Contrat attendu, écrit indépendamment du module (miroir des requêtes des inspecteurs).
const EXPECTED_KEYS = {
  client: { orders: ['clientId'], settlements: ['clientId'], flags: ['clientId'] },
  livreur: { orders: ['driverId'], settlements: ['driverIds', 'holderDriverId'], flags: ['driverId'] },
  pharmacie: { orders: ['sellerId', 'pharmacieId'], settlements: [], flags: ['partnerId', 'sellerId', 'pharmacieId'] },
  restaurant: { orders: ['sellerId', 'restaurantId'], settlements: [], flags: ['partnerId', 'sellerId', 'pharmacieId'] },
  boulangerie: { orders: ['sellerId', 'boulangerieId'], settlements: [], flags: ['partnerId', 'sellerId', 'pharmacieId'] },
  seller: { orders: ['sellerId'], settlements: [], flags: ['partnerId', 'sellerId', 'pharmacieId'] },
};

test('D-1/D-2. contrat de requêtes : requêtes exigées par rôle (table indépendante), cross-produit avec les identifiants', () => {
  for (const [role, lists] of Object.entries(EXPECTED_KEYS)) {
    const req = requiredQueries(role, ['id1', 'id2']);
    for (const [name, keys] of Object.entries(lists)) {
      const expected = keys.flatMap((key) => ['id1', 'id2'].map((id) => `${key}|${id}`)).sort();
      assert.deepEqual(req[name].map((x) => `${x.key}|${x.id}`).sort(), expected, `${role}.${name}`);
    }
  }
  assert.equal(requiredQueries('admin', ['x']), null);
  assert.equal(requiredQueries('client', []), null);
  assert.equal(READ_LIMIT, 201);
});

test('D-2b. le contrat reprend les champs réellement interrogés par les inspecteurs (lecture des sources)', () => {
  const dir = path.join(__dirname, '..');
  const scope = fs.readFileSync(path.join(dir, 'accountDeletionScope.js'), 'utf8');
  const deletion = fs.readFileSync(path.join(dir, 'accountDeletion.js'), 'utf8');
  for (const field of ['restaurantId', 'pharmacieId', 'boulangerieId', 'sellerId', 'clientId', 'driverId']) assert.ok(scope.includes(field), `scope:${field}`);
  assert.ok(deletion.includes("'clientId'") && deletion.includes("'driverId'"));
  assert.ok(/limit\(201\)/.test(scope) && /LIMIT=201/.test(deletion), 'limite 201 des inspecteurs');
});

test('D-2c. requête exigée manquante, inconnue, dupliquée ou mal formée : bloquant (chaque requête omise une à une)', () => {
  const cases = [['client', 'c1'], ['livreur', 'd1'], ['pharmacie', 'p1'], ['restaurant', 'r1'], ['boulangerie', 'b1'], ['seller', 's1']];
  for (const [role, id] of cases) {
    const o = { role, ids: [id], terminalStatuses: TERMINAL, orders: [], settlements: role === 'client' || role === 'livreur' ? [] : undefined, flags: [] };
    assert.equal(strict({ ...o, reads: withReads(o) }).blocking, false, role);
    for (const name of ['orders', 'settlements', 'flags']) {
      const reads = withReads(o);
      if (!reads[name]) continue;
      reads[name].queries.forEach((_, drop) => {
        const partial = { ...reads, [name]: { queries: reads[name].queries.filter((__, i) => i !== drop) } };
        const r = strict({ ...o, reads: partial });
        assert.ok(reasons(r).includes(`${name}_queries_incomplete`), `${role}.${name} sans requête n°${drop}`);
        assert.equal(r.blocking, true);
      });
    }
  }
  const o = base('client', {});
  const ok = withReads(o);
  const variant = (orders) => strict({ ...o, reads: { ...ok, orders } });
  const good = queryOf('clientId', 'c1');
  assert.equal(variant({ queries: [good] }).blocking, false);
  const bad = [
    [{ queries: [good, good] }, 'orders_query_duplicate'],
    [{ queries: [good, queryOf('driverId', 'c1')] }, 'orders_query_invalid'],
    [{ queries: [good, queryOf('clientId', 'zz')] }, 'orders_query_invalid'],
    [{ queries: [{ key: 'clientId', id: 'c1', limit: 201 }] }, 'orders_query_invalid'],
    [{ queries: [{ key: 'clientId', id: 'c1', size: 0 }] }, 'orders_query_invalid'],
    [{ queries: [{ ...good, extra: 1 }] }, 'orders_query_invalid'],
    [{ queries: [null] }, 'orders_query_invalid'],
    [{ queries: ['clientId'] }, 'orders_query_invalid'],
    [{ queries: [] }, 'orders_queries_incomplete'],
    [{ queries: [good], limit: 201 }, 'orders_coverage_unproven'],
    [{ limit: 201, size: 0 }, 'orders_coverage_unproven'],
    [{ queries: 'x' }, 'orders_coverage_unproven'],
    [undefined, 'orders_coverage_unproven'],
    [null, 'orders_coverage_unproven'],
    [[good], 'orders_coverage_unproven'],
  ];
  for (const [orders, reason] of bad) assert.ok(reasons(variant(orders)).includes(reason), `${reason} <- ${JSON.stringify(orders)}`);
  // identifiants multiples : chaque couple (clé, id) est exigé
  const two = strict({ role: 'client', ids: ['c1', 'c2'], terminalStatuses: TERMINAL, orders: [], settlements: [], flags: [], reads: withReads({ role: 'client', ids: ['c1'], orders: [], settlements: [], flags: [] }) });
  assert.ok(reasons(two).includes('orders_queries_incomplete'));
});

test('D-1/R5. limite de lecture : exactement 201 ; plafond atteint => lecture potentiellement tronquée => revue manuelle', () => {
  const o = base('client', {});
  const run = (limit, size, listSize = size) => {
    const orders = Array.from({ length: listSize }, (_, i) => order(`d${i}`));
    const reads = { ...withReads({ ...o, orders: [] }), orders: { queries: [{ key: 'clientId', id: 'c1', limit, size }] } };
    return strict({ ...o, orders, reads });
  };
  assert.equal(run(201, 200).blocking, false, '200 documents pour la limite 201 = complet');
  for (const limit of [1, 2, 100, 200, 202, 1000, 1e15, Number.MAX_SAFE_INTEGER, 0, -1, 1.5, NaN, Infinity, '201', null, undefined, true]) {
    const r = run(limit, 0);
    assert.equal(r.blocking, true, String(limit));
    assert.ok(reasons(r).includes('orders_query_invalid'), String(limit));
  }
  // 5 000 commandes dont la moitié impayées avec une limite artificielle : jamais « sans obligation »
  const big = Array.from({ length: 5000 }, (_, i) => order(`b${i}`, { isPaid: i % 2 === 0 }));
  const forged = strict({ ...o, orders: big, reads: { ...withReads({ ...o, orders: [] }), orders: { queries: [queryOf('clientId', 'c1', 5000, 1e15)] } } });
  assert.equal(forged.blocking, true);
  // plafond atteint
  const full = run(201, 201);
  assert.deepEqual(reasons(full), ['orders_truncated']);
  assert.equal(full.manualReviewRequired, true);
  assert.equal(full.code, CODE.AMBIGUOUS);
  assert.ok(reasons(run(100, 100)).includes('orders_query_invalid'), 'limite plus basse que 201 : refusée (R5)');
  assert.ok(reasons(run(200, 200)).includes('orders_query_invalid'));
  assert.equal(run(201, 200).manualReviewRequired, false);
  // taille déclarée supérieure à la limite / incohérente avec la liste
  assert.ok(reasons(run(201, 202, 3)).includes('orders_query_invalid'));
  assert.ok(reasons(run(201, 5, 3)).includes('orders_read_size_mismatch'), 'moins de documents que la taille déclarée');
  assert.ok(reasons(run(201, 2, 3)).includes('orders_read_size_mismatch'), 'plus de documents que la somme des requêtes');
  // plusieurs requêtes : chacune est jugée, la somme ne tronque pas à tort
  const p = { role: 'pharmacie', ids: ['p1'], terminalStatuses: TERMINAL, orders: [], flags: [] };
  const reads = withReads(p);
  reads.orders = { queries: [queryOf('sellerId', 'p1', 150), queryOf('pharmacieId', 'p1', 150)] };
  const docs = Array.from({ length: 150 }, (_, i) => order(`m${i}`));
  assert.equal(strict({ ...p, orders: docs, reads }).blocking, false, 'deux requêtes de 150 : aucune ne touche la limite');
  reads.orders = { queries: [queryOf('sellerId', 'p1', 150), queryOf('pharmacieId', 'p1', 201)] };
  assert.ok(reasons(strict({ ...p, orders: docs, reads })).includes('orders_truncated'), 'une seule requête tronquée suffit');
  assert.ok(reasons(strict({ ...p, orders: docs.slice(0, 100), reads: { ...reads, orders: { queries: [queryOf('sellerId', 'p1', 150), queryOf('pharmacieId', 'p1', 20)] } } })).includes('orders_read_size_mismatch'), 'moins de documents que la plus grande requête');
});

test('D-1b. chaque liste est jugée séparément ; clé de lecture inconnue ; liste non fournie', () => {
  for (const name of ['settlements', 'flags']) {
    const o = base('client', { [name]: Array.from({ length: 201 }, (_, i) => ({ id: `x${i}`, data: {} })) });
    const reads = withReads(o);
    reads[name] = { queries: [queryOf('clientId', 'c1', 201)] };
    assert.ok(reasons(strict({ ...o, reads })).includes(`${name}_truncated`), name);
  }
  const unk = strict({ ...covered(base('client')), reads: { ...withReads(base('client')), ordres: { queries: [] } } });
  assert.ok(reasons(unk).includes('reads_unknown_key'));
  assert.ok(reasons(strict({ role: 'client', ids: ['c1'], terminalStatuses: TERMINAL, reads: {} })).includes('orders_not_provided'));
  for (const reads of [undefined, null, true, 'true', 1, []]) {
    const r = strict({ ...base('client'), reads });
    assert.equal(r.blocking, true, JSON.stringify(reads));
  }
  // les documents d'une lecture tronquée restent évalués
  const full = Array.from({ length: 200 }, (_, i) => order(`p${i}`));
  const mixed = strict({ ...base('client', { orders: [...full, order('late', { isPaid: false })] }), reads: { ...withReads(base('client')), orders: { queries: [queryOf('clientId', 'c1', 201)] } } });
  assert.ok(reasons(mixed).includes('orders_truncated'));
  assert.ok(types(mixed).includes(TYPES.UNPAID_DELIVERED_WALLET));
});

test('C1b. ancien indicateur `truncated` : toute valeur ambiguë bloque, seul un objet entièrement à false est toléré', () => {
  for (const truncated of [true, 'true', 1, { orders: true }, { orders: 1 }, { orders: 'true' }, { ordres: true }, { orders: false, flags: 'false' }, [], 'false', 0, null, false]) {
    const r = strict({ ...covered(base('client')), truncated });
    assert.equal(r.blocking, true, JSON.stringify(truncated));
    assert.ok(reasons(r).includes('truncated_flag_invalid_or_set'), JSON.stringify(truncated));
  }
  assert.equal(strict({ ...covered(base('client')), truncated: { orders: false, settlements: false, flags: false } }).blocking, false);
});

test('C1c. documents en double : évalués une seule fois, défaut d\'appel bloquant', () => {
  const r = strict(covered(base('client', { orders: [order('o1', { isPaid: false }), order('o1', { isPaid: false })] })));
  assert.equal(r.obligations.filter((x) => x.type === TYPES.UNPAID_DELIVERED_WALLET).length, 1);
  assert.ok(reasons(r).includes('orders_duplicate_document_id'));
});

const v2w = (id, over = {}) => order(id, { amountsVersion: 2, paymentMethod: 'wallet', isPaid: true, productAmount: 900, deliveryFee: 1000, totalAmount: 1900, budget: 1000, ...over });
const debit = (id, over = {}) => ({ id: `order_${id}`, exists: true, data: { type: 'payment', amount: 1900, orderId: id, ...over } });
const v2client = (orders, walletDebits, extra = {}) => strict({ ...covered(base('client', { orders })), walletDebits, ...extra });

test('C2. wallet v2 livrée non payée : bloquante ; variantes et contradictions', () => {
  const run = (o, role = 'client') => evaluate(input(role, { orders: [o] }));
  for (const role of ['client', 'livreur', 'pharmacie']) {
    const r = run(v2w('a', { isPaid: false }), role);
    assert.deepEqual(types(r), [TYPES.UNPAID_DELIVERED_WALLET], role);
    assert.equal(r.obligations[0].state, STATE.OPEN);
    assert.equal(r.obligations[0].amount, 1000);
  }
  assert.equal(run(v2w('c', { isPaid: undefined })).code, CODE.AMBIGUOUS, 'v2 sans isPaid : jamais réglée implicitement');
  assert.equal(run(v2w('d', { isPaid: 'true' })).code, CODE.AMBIGUOUS);
  assert.equal(run(v2w('e', { isPaid: 1 })).code, CODE.AMBIGUOUS);
  assert.equal(run(v2w('f', { isPaid: false, status: 'cancelled' })).blocking, false, 'annulée : pas une dette de livraison');
  assert.equal(run(v2w('g', { isPaid: false, status: 'accepted' })).obligations[0].type, TYPES.OPERATION_OPEN);
  assert.equal(run(v2w('h', { isPaid: false, status: 'mystery' })).code, CODE.AMBIGUOUS);
  assert.equal(run(v2w('i', { isPaid: false, paymentMethod: 'barter' })).code, CODE.AMBIGUOUS);
  assert.ok(types(run(v2w('j', { refundPending: true }))).includes(TYPES.REFUND_PENDING));
  assert.ok(types(run(v2w('k', { needsReview: true }))).includes(TYPES.REVIEW_OPEN));
  const cash = run(v2w('l', { paymentMethod: 'cash', isPaid: false, cashRemittance: { status: 'confirmed', amountDue: 900, amountConfirmed: 900 }, sellerId: 's1' }), 'livreur');
  assert.equal(cash.blocking, false);
  assert.equal(run(v2w('m', { type: 'boutique', isPaid: false })).blocking, false, 'boutique : traitement distinct conservé');
  assert.equal(run(v2w('n', { isPaid: true }), 'livreur').blocking, false, 'le débit wallet est une preuve côté client seulement');
});

test('décision 10. wallet v2 payée : `isPaid:true` ET débit wallet rapproché (journal order_<id>) pour le client', () => {
  const o = [v2w('a')];
  assert.equal(v2client(o, [debit('a')]).blocking, false, 'débit conforme');
  assert.deepEqual(requiredWalletDebitIds('client', [v2w('a'), v2w('b', { status: 'cancelled' }), order('z'), v2w('t', { type: 'boutique' })]), ['order_a']);
  assert.deepEqual(requiredWalletDebitIds('livreur', o), []);
  // journal non fourni : jamais « conforme »
  for (const walletDebits of [undefined, [], [debit('zzz')]]) assert.deepEqual(reasons(v2client(o, walletDebits)), ['v2_wallet_debit_unverified']);
  // journal absent (lecture faite, document inexistant) : revue, montant = total
  const missing = v2client(o, [{ id: 'order_a', exists: false }]);
  assert.deepEqual(reasons(missing), ['v2_wallet_debit_missing']);
  assert.equal(missing.obligations[0].state, STATE.REVIEW);
  assert.equal(missing.obligations[0].amount, 1900);
  // incohérences du journal
  for (const over of [{ amount: 1000 }, { amount: '1900' }, { amount: 0 }, { type: 'refund' }, { type: undefined }, { orderId: 'other' }]) {
    assert.deepEqual(reasons(v2client(o, [debit('a', over)])), ['v2_wallet_debit_mismatch'], JSON.stringify(over));
  }
  assert.ok(reasons(v2client(o, [{ id: 'order_a', exists: true, data: 'x' }])).includes('wallet_debits_invalid'));
  // montants de la commande incohérents
  for (const over of [{ totalAmount: 1800 }, { productAmount: 0 }, { deliveryFee: -1 }, { totalAmount: undefined }, { productAmount: '900' }]) {
    assert.deepEqual(reasons(v2client([v2w('a', over)], [debit('a')])), ['v2_amounts_inconsistent'], JSON.stringify(over));
  }
  // entrées invalides ou dupliquées
  assert.ok(reasons(v2client(o, [debit('a'), debit('a')])).includes('wallet_debits_invalid'));
  assert.ok(reasons(v2client(o, 'x')).includes('wallet_debits_invalid'));
  assert.ok(reasons(v2client(o, [null, { id: 'order_a' }])).includes('wallet_debits_invalid'));
  // la preuve de débit n'efface pas `isPaid:false` : l'obligation de paiement reste
  assert.deepEqual(types(v2client([v2w('a', { isPaid: false })], [debit('a')])), [TYPES.UNPAID_DELIVERED_WALLET]);
  // conflit : débit absent + revue administrative + signalement bénéficiaire : trois symptômes, une seule créance client_payment
  const flags = [{ id: 'f1', data: { orderId: 'a', type: 'beneficiary_account_closed', status: 'open', clientId: 'c1' } }];
  const conflict = strict({ ...covered(base('client', { orders: [v2w('a', { needsReview: true, reviewReason: 'beneficiary_account_closed' })], flags })), walletDebits: [{ id: 'order_a', exists: false }] });
  assert.equal(conflict.blocking, true);
  assert.equal(conflict.summary.orders, 1);
  assert.equal(conflict.summary.flags, 1);
  assert.equal(conflict.summary.economic, 2, 'client_payment (débit absent + signalement) et order_state (revue) : deux créances, pas trois');
});

test('D-6. clé économique orderId + créance ; comptes distincts commandes / créances / signalements', () => {
  const r = evaluate(input('client', {
    orders: [order('o1', { isPaid: false, needsReview: true, reviewReason: 'beneficiary_account_closed' })],
    flags: [{ id: 'f1', data: { orderId: 'o1', type: 'beneficiary_account_closed', status: 'open', clientId: 'c1' } }],
  }));
  const keys = r.obligations.map((x) => x.economicKey).sort();
  assert.deepEqual(keys, ['o1|client_payment', 'o1|client_payment', 'o1|order_state']);
  assert.deepEqual([r.summary.orders, r.summary.economic, r.summary.flags], [1, 2, 1]);
  // chaîne espèces : remise ouverte et reliquat enregistré = même créance (cash_remittance)
  const chain = evaluate(input('livreur', {
    orders: [order('o2', { paymentMethod: 'cash', amountsVersion: 2, sellerId: 's1', cashRemittance: { status: 'declared', amountDue: 500 } })],
    flags: [{ id: 'f2', data: { orderId: 'o2', type: 'cash_shortfall', status: 'recorded', driverId: 'd1', amount: 500, decidedBy: 'a', requestId: 'r' } }],
  }));
  assert.deepEqual([chain.summary.orders, chain.summary.economic, chain.summary.flags], [1, 1, 1]);
  // signalement sans orderId fiable : aucune clé, compté séparément et bloquant
  const unkeyed = evaluate(input('client', { flags: [{ id: 'f3', data: { type: 'seller_review', status: 'open', clientId: 'c1' } }, { id: 'f4', data: { type: 'seller_review', status: 'open', clientId: 'c1' } }] }));
  assert.ok(unkeyed.obligations.every((x) => x.economicKey === null));
  assert.deepEqual([unkeyed.summary.orders, unkeyed.summary.economic, unkeyed.summary.flags], [0, 2, 2]);
  // type de signalement inconnu : pas de créance reconnue
  const other = evaluate(input('client', { flags: [{ id: 'f5', data: { orderId: 'o1', type: 'mystery', status: 'open', clientId: 'c1' } }] }));
  assert.equal(other.obligations[0].economicKey, null);
  assert.equal(other.blocking, true);
});

test('D-6b. identifiants invalides : jamais fusionnés, empreinte stable, résultat bloquant, snapshot sans sous-comptage', () => {
  const orders = Array.from({ length: 120 }, (_, i) => order(`id invalide ${i} +225070000${i}`, { isPaid: false }));
  const r = evaluate(input('client', { orders }));
  assert.equal(r.blocking, true);
  assert.equal(r.summary.open, 120);
  assert.equal(r.summary.ambiguous, 120, 'un défaut d\'identifiant par document');
  assert.ok(r.obligations.every((x) => x.economicKey === null), 'aucune clé économique sans identifiant fiable');
  assert.equal(new Set(r.obligations.map((x) => x.refId)).size, 120, 'identifiants invalides distincts');
  assert.ok(r.obligations.every((x) => /^invalid:[0-9a-f]{8}$/.test(x.refId)));
  const snap = buildFinancialSnapshot(r, { atMs: 1 });
  assert.equal(snap.counts.open, 120);
  assert.equal(snap.counts.ambiguous, 120);
  assert.equal(snap.counts.economic, r.summary.economic);
  assert.equal(snap.items.length, MAX_SNAPSHOT_ITEMS);
  assert.equal(snap.omitted, 240 - MAX_SNAPSHOT_ITEMS);
  for (const leak of ['invalide', '225070000', 'id ']) assert.equal(JSON.stringify(snap).includes(leak), false, leak);
  assert.equal(JSON.stringify(buildFinancialSnapshot(evaluate(input('client', { orders: [...orders].reverse() })), { atMs: 1 })), JSON.stringify(snap), 'déterminisme');
  // un document propre à identifiant invalide bloque quand même (aucune clé fiable)
  const clean = evaluate(input('client', { orders: [order('bad id', {})] }));
  assert.equal(clean.blocking, true);
  assert.ok(reasons(clean).includes('orders_invalid_document_id'));
});

test('C3. libellés : aucune donnée personnelle, aucun texte libre, aucune chaîne longue (résultat, snapshot, décisions, journaux)', () => {
  const long = 'x'.repeat(3000);
  const phone = '+225 07 00 00 00 00';
  const evil = [
    order('a', { status: `Awa Koné ${phone}` }),
    order('b', { needsReview: true, reviewReason: `${phone} ${long}` }),
    order('c', { settlementStatus: long }),
    order('d', { settlementStatus: phone }),
    order('e', { deliveryFeeHold: { amount: 5, status: `Rue ${long}` } }),
    order('f', { cancelRequestAfterPickup: { status: phone } }),
    order('g', { paymentMethod: 'cash', amountsVersion: 2, cashRemittance: { status: long, amountDue: 1 } }),
    order('h', { cashPayment: { status: phone, verification: long } }),
    order('i', { paymentStatus: 'pending', clientName: 'Awa', clientPhone: phone }),
    { id: long, data: { status: 'delivered', clientId: 'c1', isPaid: false, paymentMethod: 'wallet' } },
    { id: `Awa ${phone}`, data: { status: 'delivered', clientId: 'c1', isPaid: false, paymentMethod: 'wallet' } },
  ];
  const settlements = [
    { id: 's1', data: { orderId: long, status: long, clientId: 'c1', driverIds: ['d1'] } },
    { id: 's2', data: { orderId: phone, status: phone, clientId: 'c1' } },
  ];
  const flags = [
    { id: 'f1', data: { status: 'open', type: `${phone} ${long}`, clientId: 'c1' } },
    { id: 'f2', data: { status: phone, type: 'cash_shortfall', clientId: 'c1' } },
    { id: 'f3', data: { status: 'open', kind: 'ekbine_confirm_unproven_debit', clientId: 'c1', orderId: phone } },
    { id: 'f4', data: { status: 'resolved', type: long, clientId: 'c1', resolvedBy: phone, resolvedAtMs: 1, resolutionRequestId: long, resolutionDecisionId: 'D', resolution: phone } },
  ];
  const decisions = [{ id: 'D', data: { status: 'executed', subjectKind: 'flag', subjectId: 'f4', subjectType: long, resolution: phone, justification: `Awa ${phone}`, requestedBy: phone } }];
  const r = evaluate(input('client', { orders: evil, settlements, flags, decisions }));
  const snap = buildFinancialSnapshot(r, { atMs: 1 });
  for (const text of [JSON.stringify(r), JSON.stringify(snap)]) {
    for (const leak of ['Awa', 'Koné', '0700000000', '07 00', 'Rue', 'xxxxxxxx', 'clientName', 'clientPhone', 'justification']) assert.equal(text.includes(leak), false, leak);
  }
  for (const i of [...r.obligations, ...r.retained]) {
    for (const k of ['type', 'state', 'source', 'refId', 'orderId', 'party', 'status', 'reason', 'claim', 'economicKey']) assert.ok(i[k] === null || String(i[k]).length <= 160, `${k} borné`);
    assert.match(i.reason, /^[a-z0-9_:]{1,64}$/);
  }
  assert.ok(reasons(r).includes('flag_open:other'));
  assert.ok(reasons(r).includes('flag_open:ekbine_confirm_unproven_debit'));
  assert.ok(r.obligations.some((i) => /^invalid:/.test(i.refId)));
  assert.ok(r.obligations.some((i) => i.status === 'unrecognized'));
  assert.ok(r.obligations.some((i) => i.reason === 'needs_review'), 'raison libre non recopiée');
  assert.equal(evaluate(input('client', { orders: [order('o3', { needsReview: true, reviewReason: 'beneficiary_account_closed' })] })).obligations[0].reason, 'needs_review:beneficiary_account_closed');
  const ordinary = [order('a', { status: 'accepted' }), order('b', { isPaid: false }), order('c', { settlementHold: true, settlementStatus: 'cash_pending', heldDriverEarning: 5 }),
    order('d', { deliveryFeeHold: { amount: 1, status: 'pending_admin_review' } }), order('e', { cancelRequestAfterPickup: { status: 'pending_admin_review' } }),
    order('f', { paymentMethod: 'cash', amountsVersion: 2, sellerId: 's1', cashRemittance: { status: 'declared', amountDue: 5 } }),
    order('g', { paymentMethod: 'cash', amountsVersion: 2, sellerId: 's1', cashRemittance: { status: 'disputed', amountDue: 5 } }),
    order('h', { paymentMethod: 'cash', isPaid: false, cashPayment: { status: 'non_payment_declared', verification: 'pending_review' } }), order('i', { isPaid: undefined })];
  noUnrecognized(evaluate(input('livreur', { orders: ordinary })));
  noUnrecognized(evaluate(input('livreur', { orders: ordinary, settlements: [{ id: 'z', data: { status: 'cash_pending', driverIds: ['d1'] } }, { id: 'y', data: { status: 'pending_review', driverIds: ['d1'] } }] })));
});

test('C4. snapshot : ne lève jamais, recalcule blocking, signale tout résultat altéré', () => {
  const good = evaluate(input('livreur', { orders: [order('o1', { isPaid: false })] }));
  const clone = () => JSON.parse(JSON.stringify(good));
  const noSummary = clone(); delete noSummary.summary;
  let snap = buildFinancialSnapshot(noSummary, { atMs: 1 });
  assert.equal(snap.blocking, true);
  assert.ok(snap.items.some((i) => i.reason === 'result_inconsistent'));
  for (const blocking of [false, undefined, null, 'false', 0]) {
    snap = buildFinancialSnapshot({ ...clone(), blocking });
    assert.equal(snap.blocking, true, String(blocking));
    assert.ok(snap.items.some((i) => i.reason === 'result_inconsistent'));
  }
  assert.equal(buildFinancialSnapshot({ ...clone(), code: 'none' }).code, CODE.AMBIGUOUS);
  assert.equal(buildFinancialSnapshot({ ...clone(), summary: { open: 0, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 0, flags: 0, byType: {} } }).blocking, true);
  snap = buildFinancialSnapshot({ ...clone(), obligations: [] });
  assert.equal(snap.blocking, true);
  assert.equal(snap.code, CODE.AMBIGUOUS);
  const grown = clone(); grown.obligations.push({ ...grown.obligations[0], refId: 'extra', reason: 'delivered_wallet_order_unpaid' });
  snap = buildFinancialSnapshot(grown);
  assert.equal(snap.counts.open, 2);
  assert.ok(snap.items.some((i) => i.reason === 'result_inconsistent'));
  const empty = buildFinancialSnapshot(evaluate(input('client')), { atMs: 7 });
  assert.equal(empty.blocking, false);
  assert.equal(empty.code, CODE.NONE);
  assert.deepEqual(empty.items, []);
  assert.deepEqual(empty.counts, { open: 0, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 0, flags: 0 });
  assert.equal(empty.truncated, false);
  assert.equal(empty.manualReviewRequired, false);
  const many = evaluate(input('client', { orders: Array.from({ length: 120 }, (_, i) => order(`o${String(i).padStart(3, '0')}`, { isPaid: false })) }));
  const big = buildFinancialSnapshot(many);
  assert.equal(big.items.length, MAX_SNAPSHOT_ITEMS);
  assert.equal(big.omitted, 70);
  assert.equal(big.truncated, true);
  assert.equal(big.counts.open, 120);
  assert.equal(big.counts.orders, 120);
  assert.equal(big.counts.economic, 120);
  assert.deepEqual(big.items.map((i) => i.refId), [...big.items.map((i) => i.refId)].sort());
  const dupResult = clone(); dupResult.obligations.push({ ...dupResult.obligations[0] });
  snap = buildFinancialSnapshot(dupResult);
  assert.equal(snap.items.filter((i) => i.reason === 'delivered_wallet_order_unpaid').length, 1, 'doublon strict affiché une fois');
  assert.equal(snap.counts.open, 2, 'les comptes ne passent pas par la déduplication');
  const secret = 'Awa Koné +2250700000000';
  const malformed = [
    null, undefined, 3, 'x', [], {}, { obligations: 'x', retained: [] }, { obligations: [], retained: null },
    { obligations: [null, 5, 'x', [], { type: secret, state: secret, reason: secret, status: secret, refId: secret, orderId: secret, party: secret, source: secret, amount: secret, claim: secret, economicKey: secret }], retained: [] },
    { obligations: [], retained: [{ type: 'reconciliation_recorded', state: 'open', reason: secret }] },
    { obligations: [{ type: 'payment_pending', state: 'retained', reason: 'payment_status_pending' }], retained: [] },
    { obligations: [], retained: [{ type: 'unpaid_delivered_wallet', state: 'retained', reason: secret }] },
    new Proxy({}, { get() { throw new Error('boom'); } }),
    { get obligations() { throw new Error('boom'); }, retained: [] },
  ];
  for (const [idx, m] of malformed.entries()) {
    let out;
    assert.doesNotThrow(() => { out = buildFinancialSnapshot(m, { atMs: 'bad' }); });
    assert.equal(out.blocking, true, `cas malformé n°${idx}`);
    assert.equal(out.atMs, null);
    for (const leak of ['Awa', 'Koné', '0700000000']) assert.equal(JSON.stringify(out).includes(leak), false, leak);
  }
  for (const o of [undefined, null, 5, 'x', { atMs: 2.5 }]) assert.doesNotThrow(() => buildFinancialSnapshot(good, o));
  const forgedRetained = buildFinancialSnapshot({ ...clone(), retained: [{ ...good.obligations[0], state: 'open' }] });
  assert.equal(forgedRetained.counts.retained, 0);
  // la clé économique et l'indicateur de revue manuelle sont recalculés, jamais repris
  const truncResult = evaluate(input('client', { orders: Array.from({ length: 201 }, (_, i) => order(`t${i}`)) }));
  assert.equal(truncResult.manualReviewRequired, true);
  assert.equal(buildFinancialSnapshot({ ...truncResult, manualReviewRequired: false }).manualReviewRequired, true);
  const forgedKey = clone(); forgedKey.obligations[0].economicKey = 'zzz|client_payment'; forgedKey.obligations[0].claim = 'client_payment';
  assert.equal(buildFinancialSnapshot(forgedKey).items[0].economicKey, 'o1|client_payment');
});

test('C4b. snapshot : éléments forgés de type/état valides mais au contenu libre, ou conservés à tort', () => {
  const secret = 'Awa Koné +2250700000000';
  const valid = { type: 'payment_pending', state: 'open', source: 'order', refId: secret, orderId: 'x'.repeat(3000), party: 'client', amount: 5, currency: 'EUR', status: secret, reason: secret };
  const forged = buildFinancialSnapshot({ version: 1, blocking: true, code: 'financial_obligation_pending', obligations: [valid], retained: [], summary: { open: 1, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 1, flags: 0, byType: {} } });
  const text = JSON.stringify(forged);
  for (const leak of ['Awa', 'Koné', '0700000000', 'xxxxxxxx']) assert.equal(text.includes(leak), false, leak);
  assert.ok(/^invalid:/.test(forged.items[0].refId) && /^invalid:/.test(forged.items[0].orderId));
  assert.deepEqual([forged.items[0].reason, forged.items[0].status, forged.items[0].currency], ['unrecognized_reason', 'unrecognized', 'XOF']);
  const disguised = { version: 1, blocking: false, code: 'none', obligations: [], retained: [{ ...valid, type: 'unpaid_delivered_wallet', state: 'retained', reason: 'delivered_wallet_order_unpaid' }], summary: { open: 0, review: 0, ambiguous: 0, retained: 1, manualReview: 0, orders: 0, economic: 0, flags: 0, byType: {} } };
  const snap = buildFinancialSnapshot(disguised);
  assert.equal(snap.blocking, true);
  assert.equal(snap.counts.retained, 0);
  assert.ok(snap.counts.ambiguous >= 1);
  // retained invalide, résumé cohérent avec « aucun retained » : l'élément ne disparaît pas
  const silent = { version: 1, blocking: false, code: 'none', obligations: [], retained: [{ ...valid, type: 'unpaid_delivered_wallet', state: 'retained', reason: 'delivered_wallet_order_unpaid', refId: 'o9', orderId: 'o9', amount: 9 }], summary: { open: 0, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 0, flags: 0, byType: {} } };
  const s2 = buildFinancialSnapshot(silent);
  assert.equal(s2.blocking, true);
  assert.ok(s2.items.some((i) => i.refId === 'o9' && i.state === 'ambiguous'), 'élément invalide conservé comme obligation ambiguë');
});

test('C5. signalements : open/contested/recorded bloquants ; reviewed avec trace ; états ambigus', () => {
  const f = (status, over = {}) => ({ id: `f_${status}`, data: { orderId: 'o1', status, driverId: 'd1', type: 'cash_shortfall', amount: 500, ...over } });
  const run = (flag, role = 'livreur') => evaluate(input(role, { flags: [flag] }));
  for (const type of ['cash_payment_review', 'cash_shortfall', 'commission_untraced', 'partner_credit_missing', 'seller_review', 'driver_advance_unreimbursed', 'beneficiary_account_closed']) {
    const r = run(f('open', { type }));
    assert.deepEqual([r.blocking, r.obligations[0].state, r.obligations[0].reason], [true, STATE.REVIEW, `flag_open:${type}`], type);
  }
  assert.deepEqual(reasons(run(f('open', { type: undefined, kind: 'ekbine_cancel_unproven_debit' }))), ['flag_open:ekbine_cancel_unproven_debit']);
  assert.deepEqual(reasons(run(f('contested'))), ['flag_contested']);
  // recorded : jamais une dette abandonnée
  const trace = { decidedBy: 'adm1', requestId: 'req-1' };
  const rec = run(f('recorded', trace));
  assert.deepEqual([rec.blocking, rec.retained.length, reasons(rec)], [true, 0, ['flag_recorded_open']]);
  assert.equal(rec.obligations[0].amount, 500);
  assert.equal(run(f('recorded', { ...trace, remaining: 120 })).obligations[0].amount, 120, 'paiement partiel : le reliquat reste dû');
  assert.equal(run(f('recorded', { ...trace, remaining: 0 })).blocking, true, 'remaining 0 déclaré sur le signalement ne ferme rien');
  assert.equal(run(f('recorded', { ...trace, remaining: -5 })).obligations[0].amount, 500, 'reliquat négatif ignoré');
  for (const over of [{}, { decidedBy: 'a' }, { requestId: 'r' }, { ...trace, amount: -1 }, { ...trace, amount: '5' }, { ...trace, amount: undefined }, { ...trace, type: 'commission_untraced' }, { ...trace, type: undefined }, { decidedBy: '', requestId: 'r' }]) {
    assert.deepEqual(reasons(run(f('recorded', over))), ['flag_recorded_unproven'], JSON.stringify(over));
  }
  // reviewed
  const ok = { type: 'cash_payment_review', reviewedBy: 'adm1', reviewedAtMs: 10, requestId: 'r', decision: 'x', verification: 'refuted' };
  assert.equal(run(f('reviewed', ok)).blocking, false);
  assert.equal(run(f('reviewed', { ...ok, verification: 'confirmed_unpaid' })).retained.length, 1);
  for (const over of [{ type: 'commission_untraced' }, { type: 'cash_shortfall' }, { verification: 'pending_review' }, { verification: 'not_required' }, { verification: undefined }, { reviewedBy: undefined }, { reviewedAtMs: 0 }, { requestId: undefined }, { decision: '' }]) {
    assert.deepEqual(reasons(run(f('reviewed', { ...ok, ...over }))), ['flag_reviewed_unproven'], JSON.stringify(over));
  }
  assert.deepEqual(reasons(run(f('reviewed'))), ['flag_reviewed_unproven']);
  for (const status of ['Open', 'OPEN', 'closed', 'done', '', 'archived']) assert.equal(run(f(status)).code, CODE.AMBIGUOUS, status);
  assert.equal(run(f(undefined)).code, CODE.AMBIGUOUS);
  assert.equal(run(f('open', { driverId: undefined })).code, CODE.AMBIGUOUS, 'sans partie');
  assert.equal(run(f('open', { driverId: 'other' })).code, CODE.AMBIGUOUS, 'autre compte');
  assert.equal(run(f('reviewed', { ...ok, driverId: 'other' })).code, CODE.AMBIGUOUS);
});

// ═══════════════ Mission 7E-105 : réserves R1 à R4 de 7E-104 (décisions, preuves, deux personnes) ═══════════════
const RID = 'request-resolution-0001';
const EXPECTED_RESOLUTIONS = {
  commission_untraced: { verified_no_debit: 1, refunded_by_ledger: 1, waived_platform_claim: 3 },
  partner_credit_missing: { paid_to_partner_ledger: 1, paid_out_of_system: 2 },
  seller_review: { reviewed_no_action: 2, adjusted_by_ledger: 2 },
  driver_advance_unreimbursed: { reimbursed_by_ledger: 1, reimbursed_out_of_system: 2 },
  ekbine_cancel_unproven_debit: { debit_proven_and_settled: 1, debit_disproved: 2, refunded_by_ledger: 2 },
  ekbine_confirm_unproven_debit: { debit_proven_and_settled: 1, debit_disproved: 2, refunded_by_ledger: 2 },
  cash_shortfall: { recovered_in_full: 2, absorbed_by_platform: 2 },
  beneficiary_account_closed: { payment_completed: 1, beneficiary_substituted: 2 },
  client_cash_nonpayment: { refuted_after_contest: 2, paid_by_client_out_of_system: 2 },
};
// Jeu complet et valide pour fermer UN signalement résolu (livreur) : signalement, décision, preuve.
const closing = (label, resolution, over = {}) => {
  const tierMin = EXPECTED_RESOLUTIONS[label][resolution];
  const decisionId = 'D1';
  const flag = {
    id: 'F', data: {
      orderId: 'o1', [label.startsWith('ekbine') ? 'kind' : 'type']: label, status: 'resolved', driverId: 'd1', sellerId: 's1', amount: 500, decidedBy: 'adm0',
      resolvedBy: 'adm1', resolvedAtMs: 12, resolutionRequestId: RID, resolutionDecisionId: decisionId, resolution, ...(over.flag || {}),
    },
  };
  const data = {
    status: 'executed', subjectKind: 'flag', subjectId: 'F', subjectType: label, resolution, requestId: RID, requestedBy: 'adm1', requestedAtMs: 10,
    tier: tierMin, remaining: 0,
    ...(tierMin >= 2 ? { approvedBy: 'adm2', approvedAtMs: 11 } : {}),
    ...(tierMin === 3 ? { creditorConsentRef: 'doc-1' } : {}),
    ...(resolution === 'waived_platform_claim' ? { creditor: 'az_express' } : {}),
    ...(tierMin === 1 || obligations.OUT_OF_SYSTEM_RESOLUTIONS.includes(resolution) ? { evidenceRef: 'ev1' } : {}),
    ...(over.decision || {}),
  };
  const payment = obligations.OUT_OF_SYSTEM_RESOLUTIONS.includes(resolution)
    ? { amount: 500, currency: 'XOF', beneficiaryId: label === 'driver_advance_unreimbursed' ? 'd1' : 's1', orderId: 'o1', paymentRef: 'pay-ref-1', contentHash: 'a'.repeat(64), immutable: true }
    : {};
  const evidence = tierMin === 1 || data.evidenceRef !== undefined
    ? [{ id: 'ev1', exists: true, data: { status: 'verified', decisionId, subjectKind: 'flag', subjectId: 'F', resolution, verifiedBy: 'srv1', verifiedAtMs: 9, ...payment, ...(over.evidence || {}) } }]
    : [];
  return { flag, decisions: [{ id: decisionId, data }], evidence };
};
const runClosing = (c, extra = {}) => strict({
  ...covered(base('livreur', { flags: [c.flag] })), decisions: c.decisions, evidence: c.evidence, ...extra,
});

test('R2. matrice des résolutions : égale à 7E-102 (table indépendante) ; valeurs non autorisées absentes', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(RESOLUTIONS)), EXPECTED_RESOLUTIONS);
  for (const bad of ['closed_by_contract', 'no_claim_established', 'waived_by_partner', 'waived_by_driver', 'written_off_by_platform']) {
    assert.ok(obligations.UNAUTHORIZED_RESOLUTIONS.includes(bad), bad);
    for (const [label, table] of Object.entries(RESOLUTIONS)) assert.equal(Object.prototype.hasOwnProperty.call(table, bad), false, `${label}/${bad}`);
  }
  assert.equal(RESOLUTIONS.client_cash_nonpayment.refuted_after_contest, 2, 'refuted_after_contest = N2');
  assert.equal(Object.prototype.hasOwnProperty.call(RESOLUTIONS.client_cash_nonpayment, 'paid_out_of_system'), false, 'ancien nom retiré');
});

test('R2/décisions 1-9. chaque résolution autorisée ferme avec un jeu valide, jamais avec un niveau, une preuve ou un approbateur en moins', () => {
  for (const [label, table] of Object.entries(EXPECTED_RESOLUTIONS)) {
    if (label === 'client_cash_nonpayment') continue;
    for (const [resolution, tierMin] of Object.entries(table)) {
      if (tierMin === 3) {
        // C1 : le niveau 3 est INDISPONIBLE, quels que soient le consentement, les approbateurs et le registre.
        for (const decision of [{}, { creditorConsentRef: undefined }, { creditorConsentRef: 'doc-verifie-1234' }, { approvedBy: 'adm3' }, { tier: 2 }]) {
          const r = runClosing(closing(label, resolution, { decision }));
          assert.equal(r.blocking, true, `${label}/${resolution} ${JSON.stringify(decision)}`);
          assert.equal(r.retained.length, 0);
        }
        continue;
      }
      const ok = runClosing(closing(label, resolution));
      assert.equal(ok.blocking, false, `${label}/${resolution}`);
      assert.equal(ok.retained.length, 1);
      if (tierMin > 1) {
        assert.equal(runClosing(closing(label, resolution, { decision: { tier: tierMin - 1 } })).blocking, true, `${label}/${resolution} niveau insuffisant`);
        assert.equal(runClosing(closing(label, resolution, { decision: { approvedBy: undefined } })).blocking, true, `${label}/${resolution} sans second responsable : en attente`);
        assert.equal(runClosing(closing(label, resolution, { decision: { approvedBy: 'adm1' } })).blocking, true, `${label}/${resolution} même personne`);
      }
    }
  }
});

test('R1. requestId réel, non vide et vérifié : signalements et dossiers client', () => {
  const run = (requestId, flagRequestId = requestId) => runClosing(closing('cash_shortfall', 'recovered_in_full', { decision: { requestId }, flag: { resolutionRequestId: flagRequestId } }));
  assert.equal(run(RID).blocking, false);
  for (const bad of [undefined, null, '', ' ', 'court', 'x'.repeat(129), `${RID} `, 12345678901234567890, {}, [], true, 'a b c d e f g h i j k l m n']) {
    const r = run(bad);
    assert.equal(r.blocking, true, JSON.stringify(bad));
    assert.ok(reasons(r).some((x) => x === 'flag_decision_unverified' || x === 'flag_resolved_unproven'), JSON.stringify(bad));
  }
  assert.equal(run(RID, 'request-resolution-OTHER').blocking, true, 'requestId du signalement différent de celui de la décision');
  // requestId partagé par deux décisions différentes : ambigu => refusé
  const c = closing('cash_shortfall', 'recovered_in_full');
  const dup = [...c.decisions, { id: 'D9', data: { ...c.decisions[0].data, subjectId: 'Z' } }];
  assert.equal(runClosing({ ...c, decisions: dup }).blocking, true);
  // dossier client : mêmes refus, notamment décision sans requestId (trou constaté par 7E-104)
  for (const bad of [undefined, null, '', 'court', 'x'.repeat(129), 7]) {
    const r = runClient(clientCase(), [clientDecision({ requestId: bad })]);
    assert.equal(r.blocking, true, `client ${JSON.stringify(bad)}`);
    assert.deepEqual(reasons(r), ['cash_nonpayment_case_review']);
  }
  const noKey = clientDecision(); delete noKey.data.requestId;
  assert.equal(runClient(clientCase(), [noKey]).blocking, true, 'clé requestId absente');
  assert.equal(runClient(clientCase(), [clientDecision()]).blocking, false, 'témoin : jeu valide');
});

test('R3. approbateur N2 : différent du demandeur ET du décideur initial ; identités manquantes ou non conformes en attente', () => {
  const ok = (over) => runClosing(closing('cash_shortfall', 'recovered_in_full', over));
  assert.equal(ok({}).blocking, false, 'trois personnes distinctes');
  assert.equal(ok({ decision: { approvedBy: 'adm1' } }).blocking, true, 'approbateur = demandeur');
  assert.equal(ok({ decision: { approvedBy: 'adm0' } }).blocking, true, 'approbateur = décideur initial');
  assert.equal(ok({ decision: { approvedBy: 'adm0' }, flag: { resolvedBy: 'adm1' } }).blocking, true);
  assert.equal(ok({ flag: { decidedBy: undefined } }).blocking, true, 'décideur initial inconnu pour un type qui en a un');
  assert.equal(ok({ flag: { decidedBy: '' } }).blocking, true);
  assert.equal(ok({ flag: { decidedBy: 42 } }).blocking, true);
  for (const approvedBy of [undefined, null, '', ' ', 'adm2 ', ' adm2', 'adm 2', 7, {}]) {
    assert.equal(ok({ decision: { approvedBy } }).blocking, true, JSON.stringify(approvedBy));
  }
  for (const requestedBy of ['adm1 ', ' adm1', '', undefined]) {
    assert.equal(ok({ decision: { requestedBy }, flag: { resolvedBy: requestedBy } }).blocking, true, JSON.stringify(requestedBy));
  }
  assert.equal(ok({ decision: { approvedBy: 'adm1 ' } }).blocking, true, 'variante avec espace du demandeur : refusée, non tolérée comme « distincte »');
  assert.equal(ok({ decision: { approvedAtMs: 5 } }).blocking, true, 'approbation antérieure à la demande');
  assert.equal(ok({ decision: { requestedAtMs: undefined } }).blocking, true);
  assert.equal(ok({ decision: { approvedAtMs: undefined } }).blocking, true);
  // type sans décideur initial humain (signalement créé par le système) : la règle demandeur ≠ approbateur suffit
  assert.equal(runClosing(closing('partner_credit_missing', 'paid_out_of_system', { flag: { decidedBy: undefined } })).blocking, false);
  assert.equal(runClosing(closing('partner_credit_missing', 'paid_out_of_system', { flag: { decidedBy: 'adm2' } })).blocking, true, 'décideur présent = approbateur');
  // dossier client : décideur initial = cashPayment.review.byUid
  assert.equal(runClient(clientCase(), [clientDecision({ approvedBy: 'adm0' })]).blocking, true, 'approbateur = auteur de la revue');
  assert.equal(runClient(clientCase({ review: undefined }), [clientDecision()]).blocking, true, 'auteur de la revue inconnu');
  assert.equal(runClient(clientCase({ review: { byUid: '' } }), [clientDecision()]).blocking, true);
  assert.equal(runClient(clientCase(), [clientDecision({ approvedBy: 'adm1' })]).blocking, true, 'approbateur = demandeur');
  assert.equal(runClient(clientCase(), [clientDecision({ approvedBy: undefined })]).blocking, true, 'un seul responsable : en attente');
});

test('R4. résolution N1 : preuve lue côté serveur, vérifiée et liée à la décision ; une chaîne seule ne suffit jamais', () => {
  const N1 = [['commission_untraced', 'verified_no_debit'], ['commission_untraced', 'refunded_by_ledger'], ['partner_credit_missing', 'paid_to_partner_ledger'],
    ['driver_advance_unreimbursed', 'reimbursed_by_ledger'], ['ekbine_cancel_unproven_debit', 'debit_proven_and_settled'], ['beneficiary_account_closed', 'payment_completed']];
  for (const [label, resolution] of N1) {
    const good = closing(label, resolution);
    assert.equal(runClosing(good).blocking, false, `${label}/${resolution}`);
    assert.equal(runClosing({ ...good, evidence: [] }).blocking, true, 'preuve non lue');
    assert.equal(runClosing({ ...good, evidence: undefined }).blocking, true, 'registre de preuves non fourni');
    assert.equal(runClosing(closing(label, resolution, { decision: { evidenceRef: undefined } })).blocking, true, 'sans référence');
    assert.equal(runClosing({ ...good, decisions: [{ id: 'D1', data: { ...good.decisions[0].data, evidenceRef: 'forged-by-client' } }] }).blocking, true, 'chaîne inventée');
    for (const evidenceRef of ['', ' ', 7, null, {}, 'a b', 'x'.repeat(200)]) {
      assert.equal(runClosing(closing(label, resolution, { decision: { evidenceRef } })).blocking, true, JSON.stringify(evidenceRef));
    }
    for (const over of [{ status: 'pending' }, { status: undefined }, { decisionId: 'D2' }, { subjectId: 'Z' }, { subjectKind: 'order' }, { resolution: 'other_resolution' },
      { verifiedBy: undefined }, { verifiedBy: '' }, { verifiedBy: 'a b' }, { verifiedAtMs: 0 }, { verifiedAtMs: '9' }, { verifiedAtMs: undefined }]) {
      assert.equal(runClosing(closing(label, resolution, { evidence: over })).blocking, true, `${label} ${JSON.stringify(over)}`);
    }
    assert.equal(runClosing({ ...good, evidence: [{ id: 'ev1', exists: false }] }).blocking, true, 'document absent');
    assert.equal(runClosing({ ...good, evidence: [{ ...good.evidence[0], exists: true, data: 'x' }] }).blocking, true);
    // preuve valable pour une autre décision : refus
    const reused = { ...good, decisions: [{ id: 'D5', data: { ...good.decisions[0].data } }], flag: { ...good.flag, data: { ...good.flag.data, resolutionDecisionId: 'D5' } } };
    assert.equal(runClosing(reused).blocking, true, 'preuve liée à D1 réutilisée par D5');
    // sur-validation (niveau 2) : la preuve reste exigée
    assert.equal(runClosing({ ...closing(label, resolution, { decision: { tier: 2, approvedBy: 'adm2', approvedAtMs: 11 } }), evidence: [] }).blocking, true);
  }
  assert.ok(reasons(runClosing({ ...closing('commission_untraced', 'verified_no_debit'), evidence: 'x' })).includes('evidence_invalid'));
  for (const evidence of [[null], [{ id: 'ev1' }], [{ id: 'ev1', exists: true }], [{ id: 'ev1', exists: false }, { id: 'ev1', exists: false }]]) {
    const r = runClosing({ ...closing('commission_untraced', 'verified_no_debit'), evidence });
    assert.equal(r.blocking, true, JSON.stringify(evidence));
  }
  // la preuve n'est pas exigée pour N2 (deux personnes) : ne pas élargir le périmètre
  assert.equal(runClosing({ ...closing('cash_shortfall', 'recovered_in_full'), evidence: undefined }).blocking, false);
});

test('R2/décision 5-6. valeurs non autorisées ou inconnues : refusées et bloquantes quel que soit le niveau de validation', () => {
  const all = [...obligations.UNAUTHORIZED_RESOLUTIONS, 'inconnue', '', '__proto__', 'constructor', 'toString', 'hasOwnProperty', undefined, null, 5];
  for (const label of Object.keys(EXPECTED_RESOLUTIONS)) {
    if (label === 'client_cash_nonpayment') continue;
    for (const resolution of all) {
      const good = closing(label, Object.keys(EXPECTED_RESOLUTIONS[label])[0]);
      const flag = { ...good.flag, data: { ...good.flag.data, resolution } };
      const decisions = [{ id: 'D1', data: { ...good.decisions[0].data, resolution, tier: 3, approvedBy: 'adm2', approvedAtMs: 11, creditorConsentRef: 'doc', creditor: 'az_express', contractRef: 'c' } }];
      const r = runClosing({ flag, decisions, evidence: good.evidence });
      assert.equal(r.blocking, true, `${label}/${String(resolution)}`);
      assert.ok(reasons(r).includes('flag_resolution_not_allowed') || reasons(r).includes('flag_resolved_unproven'), `${label}/${String(resolution)}`);
    }
  }
  // type de signalement sans matrice (cash_payment_review, inconnu) : aucune fermeture
  assert.equal(runClosing(closing('cash_shortfall', 'recovered_in_full', { flag: { type: 'mystery' } })).blocking, true);
  // renonciation (niveau 3) : indisponible (C1) ; la règle « créances d'AZ seulement » est donc sans objet pour l'instant
  const w = closing('commission_untraced', 'waived_platform_claim');
  assert.equal(runClosing(w).blocking, true);
  assert.deepEqual(reasons(runClosing(w)), ['flag_level3_unavailable']);
  for (const decision of [{ creditor: 'partner' }, { creditor: undefined }, { tier: 2 }, { creditorConsentRef: undefined }, { approvedBy: 'adm1' }, { creditorConsentRef: 'x', approvedBy: 'adm3', approvedAtMs: 12 }]) {
    assert.equal(runClosing(closing('commission_untraced', 'waived_platform_claim', { decision })).blocking, true, JSON.stringify(decision));
  }
});

test('décisions de base. contrôles conservés : statut, sujet, type, reste dû, registre absent ou illisible', () => {
  const c = closing('cash_shortfall', 'recovered_in_full');
  for (const decision of [{ status: 'pending' }, { status: undefined }, { subjectId: 'other' }, { subjectKind: 'order' }, { subjectType: 'seller_review' },
    { resolution: 'absorbed_by_platform' }, { requestedBy: 'adm9' }, { tier: 4 }, { tier: '2' }, { tier: 0 }, { remaining: 1 }, { remaining: undefined }, { remaining: '0' }]) {
    assert.equal(runClosing(closing('cash_shortfall', 'recovered_in_full', { decision })).blocking, true, JSON.stringify(decision));
  }
  for (const flag of [{ resolvedBy: undefined }, { resolvedAtMs: 0 }, { resolvedAtMs: '12' }, { resolutionRequestId: undefined }, { resolutionDecisionId: undefined }, { resolution: undefined }]) {
    assert.equal(runClosing(closing('cash_shortfall', 'recovered_in_full', { flag })).blocking, true, JSON.stringify(flag));
  }
  assert.deepEqual(reasons(runClosing({ ...c, decisions: undefined })), ['flag_decision_unverified'], 'registre non fourni');
  assert.deepEqual(reasons(runClosing({ ...c, decisions: [] })), ['flag_decision_unverified']);
  assert.deepEqual(reasons(runClosing({ ...c, flag: { ...c.flag, data: { ...c.flag.data, resolutionDecisionId: 'D9' } } })), ['flag_decision_unverified']);
  for (const bad of ['x', [null], [{ id: 'D1' }], [{ id: 'D1', data: 'x' }], [{ id: 'D1', data: {} }, { id: 'D1', data: {} }]]) assert.equal(runClosing({ ...c, decisions: bad }).blocking, true);
  assert.ok(reasons(runClosing({ ...c, decisions: 'x' })).includes('decisions_invalid'));
  // le signalement fermé ne ferme pas la créance de paiement de la commande
  const b = closing('beneficiary_account_closed', 'payment_completed', { flag: { driverId: undefined, clientId: 'c1' } });
  const still = strict({ ...covered(base('client', { orders: [order('o1', { isPaid: false })], flags: [b.flag] })), decisions: b.decisions, evidence: b.evidence });
  assert.deepEqual(types(still), [TYPES.UNPAID_DELIVERED_WALLET]);
});

// Dossier espèces client (décision 8) : commande espèces `confirmed_unpaid`, revue enregistrée par `adm0`.
const clientCase = (over = {}) => order('o1', {
  paymentMethod: 'cash', isPaid: false, sellerId: undefined,
  cashPayment: { status: 'non_payment_declared', verification: 'confirmed_unpaid', ...('review' in over ? (over.review ? { review: over.review } : {}) : { review: { requestId: 'review-request-00001', decision: 'confirm_unpaid', byUid: 'adm0', atMs: 1 } }) },
});
const clientDecision = (over = {}) => ({
  id: 'DC1', data: {
    status: 'executed', subjectKind: 'order', subjectId: 'o1', subjectType: 'client_cash_nonpayment', resolution: 'refuted_after_contest', requestId: 'client-request-000001',
    requestedBy: 'adm1', requestedAtMs: 10, approvedBy: 'adm2', approvedAtMs: 11, tier: 2, remaining: 0, ...over,
  },
});
const runClient = (order1, decisions, evidence) => strict({ ...covered(base('client', { orders: [order1] })), ...(decisions ? { decisions } : {}), ...(evidence ? { evidence } : {}) });

test('décision 8/R2. dossier espèces client : revue, jamais de dette inventée, fermeture par N2 uniquement', () => {
  const open = runClient(clientCase());
  assert.deepEqual([reasons(open), open.obligations[0].amount, open.obligations[0].state], [['cash_nonpayment_case_review'], null, STATE.REVIEW]);
  for (const resolution of ['refuted_after_contest']) {
    const closed = runClient(clientCase(), [clientDecision({ resolution })]);
    assert.equal(closed.blocking, false, resolution);
    assert.deepEqual(closed.retained.map((x) => x.reason), ['cash_nonpayment_case_closed']);
    assert.equal(runClient(clientCase(), [clientDecision({ resolution, tier: 1, approvedBy: undefined, approvedAtMs: undefined })]).blocking, true, `${resolution} niveau 1 refusé`);
    assert.equal(runClient(clientCase(), [clientDecision({ resolution, approvedBy: undefined })]).blocking, true, `${resolution} un seul responsable`);
  }
  // paid_by_client_out_of_system : le titulaire de la créance client et le montant de référence ne sont pas définis (7E-102 §M-5) ;
  // aucune concordance montant/bénéficiaire n'est possible : indisponible, même avec deux approbateurs et une preuve plausible.
  const proofOf = { id: 'ev1', exists: true, data: { status: 'verified', decisionId: 'DC1', subjectKind: 'order', subjectId: 'o1', resolution: 'paid_by_client_out_of_system', verifiedBy: 'srv1', verifiedAtMs: 9, amount: 500, currency: 'XOF', beneficiaryId: 'd1', orderId: 'o1', paymentRef: 'pay-ref-1', contentHash: 'b'.repeat(64), immutable: true } };
  assert.equal(runClient(clientCase(), [clientDecision({ resolution: 'paid_by_client_out_of_system', evidenceRef: 'ev1' })], [proofOf]).blocking, true);
  for (const resolution of ['no_claim_established', 'paid_out_of_system', 'written_off_by_platform', 'waived_by_partner', 'closed_by_contract', 'inconnue']) {
    assert.equal(runClient(clientCase(), [clientDecision({ resolution, tier: 3, creditorConsentRef: 'x' })]).blocking, true, resolution);
  }
  assert.equal(runClient(clientCase(), [clientDecision({ subjectId: 'o2' })]).blocking, true, 'décision d\'une autre commande');
  assert.equal(runClient(clientCase(), [clientDecision({ status: 'pending' })]).blocking, true);
  assert.equal(runClient(clientCase(), [clientDecision({ remaining: 3 })]).blocking, true);
  assert.equal(runClient(clientCase(), [clientDecision({ requestedBy: undefined })]).blocking, true, 'sans demandeur');
  assert.equal(runClient(clientCase(), [clientDecision({ requestedBy: '' })]).blocking, true);
  assert.equal(runClient(clientCase(), [clientDecision({ requestedBy: 'adm1 ' })]).blocking, true);
  const refuted = order('o2', { paymentMethod: 'cash', isPaid: false, sellerId: undefined, cashPayment: { status: 'non_payment_declared', verification: 'refuted' } });
  assert.equal(runClient(refuted).blocking, false, 'non-paiement infirmé : aucune obligation');
  assert.equal(evaluate(input('livreur', { orders: [clientCase()] })).blocking, false, 'seul le client est concerné');
});

test('commande wallet v2 non payée sans journal : bloquante, la preuve de débit absente ne la rend jamais conforme', () => {
  const unpaid = v2w('a', { isPaid: false });
  for (const walletDebits of [undefined, [], [{ id: 'order_a', exists: false }], [debit('a')]]) {
    const r = v2client([unpaid], walletDebits);
    assert.equal(r.blocking, true);
    assert.deepEqual(types(r), [TYPES.UNPAID_DELIVERED_WALLET], JSON.stringify(walletDebits));
  }
  assert.deepEqual(requiredWalletDebitIds('client', [unpaid]), [], 'aucun journal exigé pour une commande non payée');
});

test('R6/R7. identifiants du compte dédoublonnés ; identifiants neutralisés identiques dans le résultat et le snapshot', () => {
  const q = requiredQueries('client', ['c1', 'c1', 'c1']);
  assert.deepEqual(q.orders, [{ key: 'clientId', id: 'c1' }]);
  assert.equal(requiredQueries('livreur', ['d1', 'd1']).settlements.length, 2);
  const o = { role: 'client', ids: ['c1', 'c1'], terminalStatuses: TERMINAL, orders: [], settlements: [], flags: [] };
  assert.equal(strict({ ...o, reads: withReads(o) }).blocking, false, 'identifiants répétés : même contrat que sans doublon');
  const r = evaluate(input('client', { orders: [order('id invalide 1', { isPaid: false }), order('id invalide 2', { isPaid: false })] }));
  const snap = buildFinancialSnapshot(r, { atMs: 1 });
  assert.deepEqual(snap.items.map((i) => i.refId).sort(), r.obligations.map((i) => i.refId).sort(), 'mêmes identifiants dans le snapshot');
  assert.deepEqual(buildFinancialSnapshot(r, { atMs: 1 }).items, snap.items, 'idempotent');
  assert.match(snap.items[0].refId, /^invalid:[0-9a-f]{8}$/);
});

test('M-2/E7. conflits et trous de couverture de 7E-101 : relations partenaires, montants négatifs, retained forgé', () => {
  // E3 : relation propriétaire des partenaires
  const o = (id, field) => ({ id, data: { status: 'delivered', paymentMethod: 'cash', isPaid: false, [field]: 'x1' } });
  for (const [role, field] of [['boulangerie', 'boulangerieId'], ['restaurant', 'restaurantId'], ['pharmacie', 'pharmacieId'], ['seller', 'sellerId']]) {
    const r = strict(covered({ role, ids: ['x1'], terminalStatuses: TERMINAL, orders: [o('a', field)], settlements: undefined, flags: [] }));
    assert.equal(r.blocking, false, role);
  }
  const foreign = { id: 'z', data: { status: 'delivered', paymentMethod: 'cash', isPaid: false, boulangerieId: 'autre' } };
  const rf = strict(covered({ role: 'boulangerie', ids: ['x1'], terminalStatuses: TERMINAL, orders: [foreign], flags: [] }));
  assert.equal(rf.blocking, true, 'commande d une autre boulangerie : defaut d appel bloquant');
  assert.deepEqual(reasons(rf), ['order_not_linked_to_account']);
  // E5 : montants négatifs ou non entiers
  const neg = evaluate(input('client', { orders: [order('a', { refundPending: true, budget: -5 }), order('b', { isPaid: false, budget: 12.5 })], flags: [{ id: 'f', data: { status: 'open', clientId: 'c1', type: 'seller_review', amount: -3 } }] }));
  assert.ok(neg.obligations.every((x) => x.amount === null));
  assert.equal(evaluate(input('client', { orders: [order('a', { refundPending: true, budget: 0 })] })).obligations[0].amount, 0);
});

test('C6. terminalStatuses : obligatoire, valide, égal aux ensembles des inspecteurs', () => {
  const base0 = { role: 'client', ids: ['c1'], orders: [], settlements: [], flags: [] };
  const withR = (o) => ({ ...o, reads: withReads(o) });
  for (const ts of [undefined, null, [], 'delivered', ['delivered', 3], [''], { a: 1 }, ['delivered', 'delivered']]) {
    const r = strict(withR({ ...base0, terminalStatuses: ts }));
    assert.equal(r.blocking, true, JSON.stringify(ts));
  }
  assert.equal(strict(withR({ ...base0, terminalStatuses: TERMINAL })).blocking, false);
  const src = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  for (const [file, set] of [['accountDeletion.js', INSPECTOR_TERMINAL_STATUSES.accountDeletion], ['accountDeletionScope.js', INSPECTOR_TERMINAL_STATUSES.accountDeletionScope], ['manualAccountDeletion.js', INSPECTOR_TERMINAL_STATUSES.manualAccountDeletion]]) {
    if (!set) continue;
    const text = src(file);
    for (const s of set) assert.ok(text.includes(`'${s}'`), `${file}:${s}`);
  }
});

test('R3/R4 compléments : horodatage de demande nul, preuve déclarée absente, identifiant de preuve non conforme, preuves en double', () => {
  assert.equal(runClosing(closing('cash_shortfall', 'recovered_in_full', { decision: { requestedAtMs: 0, approvedAtMs: 0 } })).blocking, true, 'requestedAtMs 0');
  const good = closing('commission_untraced', 'verified_no_debit');
  const ev = good.evidence[0];
  assert.equal(runClosing({ ...good, evidence: [{ ...ev, exists: false }] }).blocking, true, 'exists:false avec des données plausibles');
  const weird = closing('commission_untraced', 'verified_no_debit', { decision: { evidenceRef: 'ev 1' } });
  assert.equal(runClosing({ ...weird, evidence: [{ ...ev, id: 'ev 1' }] }).blocking, true, 'identifiant de preuve non conforme');
  assert.ok(reasons(runClosing({ ...good, evidence: [ev, { ...ev }] })).includes('evidence_invalid'), 'même preuve fournie deux fois');
  assert.equal(runClosing({ ...good, evidence: [ev, { ...ev }] }).blocking, true);
});

// ═══════════════ Mission 7E-107 : conditions finales (C1, R10, Ekbine, origine, paiement hors système) ═══════════════
test('C1. niveau 3 : indisponible dans le moteur, aucun contournement par consentement, registre ou approbateurs', () => {
  const N3 = [['commission_untraced', 'waived_platform_claim']];
  assert.deepEqual(Object.entries(RESOLUTIONS).flatMap(([t, m]) => Object.entries(m).filter(([, tier]) => tier === 3).map(([r]) => [t, r])), N3, 'seule résolution de niveau 3 connue');
  for (const [label, resolution] of N3) {
    const base3 = closing(label, resolution);
    assert.equal(runClosing(base3).blocking, true, 'consentement présent mais non vérifié');
    assert.deepEqual(reasons(runClosing(base3)), ['flag_level3_unavailable']);
    // consentement absent
    assert.equal(runClosing(closing(label, resolution, { decision: { creditorConsentRef: undefined } })).blocking, true);
    // deux approbateurs, créancier AZ déclaré, accord « vérifié » fourni comme preuve
    const rich = closing(label, resolution, { decision: { approvedBy: 'adm2', coApprovedBy: 'adm3', creditor: 'az_express', creditorConsentRef: 'consent-0001', evidenceRef: 'ev1' } });
    const withConsentDoc = [{ id: 'consent-0001', exists: true, data: { status: 'verified', decisionId: 'D1', subjectKind: 'flag', subjectId: 'F', resolution, verifiedBy: 'srv1', verifiedAtMs: 9, creditor: 'az_express', consent: 'granted' } }];
    const r = runClosing({ ...rich, evidence: [...rich.evidence, ...withConsentDoc] });
    assert.equal(r.blocking, true);
    assert.equal(r.retained.length, 0);
    for (const tier of [1, 2, 3, 4]) assert.equal(runClosing(closing(label, resolution, { decision: { tier } })).blocking, true, `tier ${tier}`);
  }
  // niveau 3 déclaré sur une résolution de niveau inférieur : refusé aussi (le niveau est calculé par le serveur)
  const over3 = runClosing(closing('cash_shortfall', 'recovered_in_full', { decision: { tier: 3, creditorConsentRef: 'doc' } }));
  assert.equal(over3.blocking, true);
  assert.equal(over3.retained.length, 0);
});

test('Ekbine. debit_disproved exige N2 : deux validations, approbateur différent du demandeur ET du décideur initial, décideur initial obligatoire', () => {
  for (const label of ['ekbine_cancel_unproven_debit', 'ekbine_confirm_unproven_debit']) {
    const ok = (over) => runClosing(closing(label, 'debit_disproved', over));
    assert.equal(RESOLUTIONS[label].debit_disproved, 2);
    assert.equal(ok({}).blocking, false, `${label} positif`);
    assert.equal(ok({ decision: { tier: 1, approvedBy: undefined, approvedAtMs: undefined } }).blocking, true, 'un seul responsable');
    assert.equal(ok({ decision: { approvedBy: undefined } }).blocking, true, 'second responsable absent : en attente');
    assert.equal(ok({ decision: { approvedBy: 'adm1' } }).blocking, true, 'approbateur = demandeur');
    assert.equal(ok({ decision: { approvedBy: 'adm0' } }).blocking, true, 'approbateur = décideur initial');
    assert.equal(ok({ flag: { decidedBy: undefined } }).blocking, true, 'décideur initial absent : bloquant');
    assert.equal(ok({ flag: { decidedBy: '' } }).blocking, true);
    assert.equal(ok({ flag: { decidedBy: 'adm1' } }).blocking, false, 'demandeur = décideur initial : autorisé');
    assert.equal(ok({ decision: { approvedBy: 'adm1 ' } }).blocking, true, 'variante avec espace');
    assert.equal(RESOLUTIONS[label].debit_proven_and_settled, 1);
    assert.equal(RESOLUTIONS[label].refunded_by_ledger, 2);
    assert.equal(runClosing(closing(label, 'refunded_by_ledger', { flag: { decidedBy: undefined } })).blocking, true, 'refunded_by_ledger : décideur initial aussi obligatoire');
    assert.equal(runClosing(closing(label, 'debit_proven_and_settled')).blocking, false, 'N1 avec preuve');
  }
  // signalement Ekbine par `agentId` seul : jamais fermé, même avec une décision complète
  const c = closing('ekbine_cancel_unproven_debit', 'debit_disproved', { flag: { driverId: undefined, sellerId: undefined, agentId: 'a1' } });
  assert.deepEqual(reasons(runClosing(c)), ['flag_without_party']);
});

test('origine : le demandeur peut être le décideur initial ; l\'approbateur N2 ne le peut jamais (tous les types concernés)', () => {
  const N2 = [['cash_shortfall', 'recovered_in_full'], ['cash_shortfall', 'absorbed_by_platform'], ['seller_review', 'reviewed_no_action'],
    ['seller_review', 'adjusted_by_ledger'], ['driver_advance_unreimbursed', 'reimbursed_out_of_system'],
    ['ekbine_cancel_unproven_debit', 'debit_disproved'], ['ekbine_confirm_unproven_debit', 'refunded_by_ledger']];
  for (const [label, resolution] of N2) {
    const run = (over) => runClosing(closing(label, resolution, over));
    const tag = `${label}/${resolution}`;
    assert.equal(run({}).blocking, false, `${tag} décideur initial présent, approbateur indépendant`);
    assert.equal(run({ flag: { decidedBy: undefined } }).blocking, true, `${tag} décideur initial absent`);
    assert.equal(run({ flag: { decidedBy: null } }).blocking, true, `${tag} décideur initial nul`);
    assert.equal(run({ decision: { approvedBy: 'adm0' } }).blocking, true, `${tag} approbateur = décideur initial`);
    assert.equal(run({ decision: { approvedBy: 'adm1' } }).blocking, true, `${tag} approbateur = demandeur`);
    assert.equal(run({ flag: { decidedBy: 'adm1' } }).blocking, false, `${tag} demandeur = décideur initial : autorisé`);
    assert.equal(run({ flag: { decidedBy: 'adm1' }, decision: { approvedBy: 'adm1' } }).blocking, true, `${tag} les trois identiques`);
  }
  // N1 : aucune approbation ni origine exigée (la preuve l'est)
  assert.equal(runClosing(closing('driver_advance_unreimbursed', 'reimbursed_by_ledger', { flag: { decidedBy: undefined } })).blocking, false, 'N1 sans décideur initial');
  // dossier client : décideur initial = auteur de la revue
  const cc = (review, over) => runClient(clientCase({ review }), [clientDecision(over)]);
  const rv = (byUid) => ({ requestId: 'review-request-00001', decision: 'confirm_unpaid', byUid, atMs: 1 });
  assert.equal(cc(rv('adm0'), {}).blocking, false);
  assert.equal(cc(rv('adm1'), {}).blocking, false, 'demandeur = auteur de la revue : autorisé');
  assert.equal(cc(rv('adm2'), {}).blocking, true, 'approbateur = auteur de la revue');
  assert.equal(cc(undefined, {}).blocking, true);
});

test('paiement hors système : N2 + preuve de paiement serveur concordante (montant, bénéficiaire, commande) et immuable', () => {
  const CASES = [['partner_credit_missing', 'paid_out_of_system'], ['driver_advance_unreimbursed', 'reimbursed_out_of_system']];
  for (const [label, resolution] of CASES) {
    const run = (over) => runClosing(closing(label, resolution, over));
    const tag = `${label}/${resolution}`;
    assert.equal(run({}).blocking, false, `${tag} positif`);
    assert.equal(RESOLUTIONS[label][resolution], 2);
    assert.equal(run({ decision: { tier: 1, approvedBy: undefined, approvedAtMs: undefined } }).blocking, true, `${tag} un seul responsable`);
    assert.equal(run({ decision: { approvedBy: 'adm1' } }).blocking, true, `${tag} même personne`);
    assert.equal(runClosing({ ...closing(label, resolution), evidence: [] }).blocking, true, `${tag} preuve non lue`);
    assert.equal(runClosing({ ...closing(label, resolution), evidence: undefined }).blocking, true);
    assert.equal(run({ decision: { evidenceRef: undefined } }).blocking, true, `${tag} sans référence`);
    assert.equal(run({ decision: { evidenceRef: 'virement-orange-12345' } }).blocking, true, `${tag} référence textuelle seule`);
    const beneficiary = label === 'driver_advance_unreimbursed' ? 'd1' : 's1';
    for (const evidence of [{ amount: 499 }, { amount: 501 }, { amount: '500' }, { amount: 0 }, { amount: -500 }, { amount: undefined }, { currency: 'EUR' }, { currency: undefined },
      { beneficiaryId: 'autre' }, { beneficiaryId: undefined }, { beneficiaryId: beneficiary === 'd1' ? 's1' : 'd1' }, { orderId: 'o2' }, { orderId: undefined },
      { paymentRef: undefined }, { paymentRef: '' }, { paymentRef: 'a b' }, { paymentRef: 12 },
      { contentHash: undefined }, { contentHash: 'abc' }, { contentHash: 'A'.repeat(64) }, { contentHash: 'g'.repeat(64) }, { contentHash: 'a'.repeat(65) },
      { immutable: false }, { immutable: undefined }, { immutable: 'true' }, { status: 'pending' }, { decisionId: 'D2' }, { verifiedBy: undefined }]) {
      assert.equal(run({ evidence }).blocking, true, `${tag} ${JSON.stringify(evidence)}`);
    }
    for (const flag of [{ amount: undefined }, { amount: 0 }, { amount: -5 }, { amount: '500' }, { orderId: undefined }, { sellerId: undefined, driverId: undefined }]) {
      assert.equal(run({ flag }).blocking, true, `${tag} flag ${JSON.stringify(flag)}`);
    }
    assert.equal(run({ flag: { amount: 600 } }).blocking, true);
    // créance et preuve « vides » qui se ressemblent : aucune concordance n'est possible, donc jamais fermé
    assert.equal(run({ flag: { amount: 0 }, evidence: { amount: 0 } }).blocking, true, `${tag} montant nul des deux côtés`);
    assert.equal(run({ flag: { sellerId: undefined, driverId: undefined }, evidence: { beneficiaryId: undefined } }).blocking, true, `${tag} bénéficiaire inconnu des deux côtés`);
    assert.equal(run({ flag: { orderId: undefined }, evidence: { orderId: undefined } }).blocking, true, `${tag} commande inconnue des deux côtés`);
    const good = closing(label, resolution);
    const reused = { ...good, decisions: [{ id: 'D5', data: { ...good.decisions[0].data } }], flag: { ...good.flag, data: { ...good.flag.data, resolutionDecisionId: 'D5' } } };
    assert.equal(runClosing(reused).blocking, true);
  }
  assert.deepEqual([...obligations.OUT_OF_SYSTEM_RESOLUTIONS].sort(), ['paid_by_client_out_of_system', 'paid_out_of_system', 'reimbursed_out_of_system']);
});

// ── Générations d'écrivain wallet (R10) ─────────────────────────────────────────────────────────────────────────
const quoteOrder = (id, over = {}) => order(id, {
  type: 'livraison', sellerId: undefined, pharmacieId: undefined, paymentMethod: 'wallet', isPaid: true, budget: 1000, shoppingBudget: 500,
  tariffQuoteId: 'quote-0001', quotedAmount: 1500, ...over,
});
const qDebit = (id, over = {}) => ({ id: `order_${id}`, exists: true, data: { type: 'payment', amount: 1500, orderId: id, provider: 'wallet', txId: `order_${id}`, ...over } });
const runGen = (orders, walletDebits, extra = {}) => strict({ ...covered(base('client', { orders })), ...(walletDebits !== undefined ? { walletDebits } : {}), ...extra });
const legacyOrder = (id, over = {}) => order(id, { type: 'livraison', sellerId: undefined, pharmacieId: undefined, paymentMethod: 'wallet', isPaid: true, budget: 1000, ...over });

test('R10. génération « devis serveur » (tariffQuoteId) : journal order_<id> exigé ; absent ou divergent => revue', () => {
  const o = [quoteOrder('q1')];
  assert.equal(obligations.walletGeneration(o[0].data), 'quote');
  const ok = runGen(o, [qDebit('q1')]);
  assert.deepEqual([ok.blocking, ok.obligations.length, ok.manualReview.length, ok.retained.length], [false, 0, 0, 0]);
  assert.deepEqual(requiredWalletDebitIds('client', o), ['order_q1']);
  const missing = runGen(o, [{ id: 'order_q1', exists: false }]);
  assert.deepEqual([reasons(missing), missing.obligations[0].state, missing.obligations[0].amount], [['quote_wallet_debit_missing'], STATE.REVIEW, 1500]);
  assert.equal(missing.blocking, true);
  for (const over of [{ amount: 1000 }, { amount: 1501 }, { amount: '1500' }, { amount: 0 }, { type: 'refund' }, { type: undefined }, { orderId: 'autre' }]) {
    const r = runGen(o, [qDebit('q1', over)]);
    assert.deepEqual([reasons(r), r.obligations[0].state, r.blocking], [['quote_wallet_debit_mismatch'], STATE.REVIEW, true], JSON.stringify(over));
  }
  for (const walletDebits of [undefined, [], [qDebit('zz')]]) {
    const r = runGen(o, walletDebits);
    assert.deepEqual([reasons(r), r.obligations[0].state], [['quote_wallet_debit_unverified'], STATE.AMBIGUOUS]);
  }
  for (const over of [{ budget: 0 }, { budget: '1000' }, { budget: -5 }, { shoppingBudget: undefined }, { shoppingBudget: -1 }, { shoppingBudget: '5' }, { budget: undefined }]) {
    assert.deepEqual(reasons(runGen([quoteOrder('q1', over)], [qDebit('q1')])), ['quote_amounts_inconsistent'], JSON.stringify(over));
  }
  assert.equal(runGen([quoteOrder('q2', { shoppingBudget: 0 })], [qDebit('q2', { amount: 1000 })]).blocking, false);
  assert.deepEqual(types(runGen([quoteOrder('q1', { isPaid: false })], [qDebit('q1')])), [TYPES.UNPAID_DELIVERED_WALLET]);
  assert.equal(evaluate(input('livreur', { orders: [quoteOrder('q1')] })).blocking, false);
  for (const over of [{ status: 'cancelled' }, { paymentMethod: 'cash', isPaid: false }, { type: 'boutique', isPaid: false }]) {
    assert.deepEqual(requiredWalletDebitIds('client', [quoteOrder('q1', over)]), [], JSON.stringify(over));
  }
});

test('R10. génération historique (sans journal garanti) : revue manuelle NON bloquante, ni dette inventée ni règlement déclaré', () => {
  const o = legacyOrder('l1');
  assert.equal(obligations.walletGeneration(o.data), 'legacy');
  const r = evaluate(input('client', { orders: [o] }));
  assert.equal(r.blocking, false, 'jamais de blocage indistinct des clients historiques');
  assert.equal(r.code, CODE.NONE);
  assert.deepEqual(r.obligations, []);
  assert.deepEqual(r.retained, [], 'jamais déclarée réglée');
  assert.equal(r.manualReview.length, 1);
  assert.deepEqual([r.manualReview[0].type, r.manualReview[0].state, r.manualReview[0].reason, r.manualReview[0].amount, r.manualReview[0].blocking],
    [TYPES.LEGACY_WALLET_UNPROVEN, STATE.MANUAL_REVIEW, 'legacy_wallet_payment_unproven', null, false]);
  assert.equal(r.summary.manualReview, 1);
  assert.equal(r.manualReviewRequired, false, 'réservé aux lectures tronquées');
  assert.deepEqual(requiredWalletDebitIds('client', [o]), [], 'aucun journal exigé : le writer ne le garantit pas');
  assert.equal(evaluate(input('livreur', { orders: [o] })).manualReview.length, 0);
  assert.equal(evaluate(input('pharmacie', { orders: [o] })).manualReview.length, 0);
  for (const over of [{ status: 'cancelled' }, { paymentMethod: 'cash', isPaid: false }, { type: 'boutique', isPaid: false }, { status: 'accepted' }, { isPaid: false }]) {
    assert.equal(evaluate(input('client', { orders: [legacyOrder('l2', over)] })).manualReview.length, 0, JSON.stringify(over));
  }
  assert.deepEqual(types(evaluate(input('client', { orders: [legacyOrder('l3', { isPaid: false })] }))), [TYPES.UNPAID_DELIVERED_WALLET]);
  assert.equal(evaluate(input('client', { orders: [order('l4')] })).manualReview.length, 1);
  const mixed = runGen([quoteOrder('q1'), legacyOrder('l1'), legacyOrder('l2'), v2w('v1')], [qDebit('q1'), debit('v1')]);
  assert.equal(mixed.blocking, false);
  assert.deepEqual(mixed.manualReview.map((x) => x.refId), ['l1', 'l2']);
  assert.equal(mixed.summary.manualReview, 2);
  const both = evaluate(input('client', { orders: [legacyOrder('l1'), legacyOrder('l9', { isPaid: false })] }));
  assert.equal(both.blocking, true);
  assert.deepEqual([both.summary.open, both.summary.manualReview, both.obligations.length], [1, 1, 1]);
});

test('v2 : débit divergent ou absent => REVUE (bloquante), journal non fourni => ambigu', () => {
  const o = [v2w('a')];
  assert.equal(v2client(o, [{ id: 'order_a', exists: false }]).obligations[0].state, STATE.REVIEW);
  assert.equal(v2client(o, [debit('a', { amount: 1000 })]).obligations[0].state, STATE.REVIEW);
  assert.equal(v2client(o, [debit('a', { type: 'refund' })]).obligations[0].state, STATE.REVIEW);
  assert.equal(v2client(o, undefined).obligations[0].state, STATE.AMBIGUOUS);
  assert.equal(v2client(o, [debit('a', { amount: 1000 })]).blocking, true);
});

test('snapshot : revue manuelle conservée sans devenir bloquante, jamais falsifiable en règlement', () => {
  const r = evaluate(input('client', { orders: [legacyOrder('l1'), legacyOrder('l2')] }));
  const snap = buildFinancialSnapshot(r, { atMs: 5 });
  assert.equal(snap.blocking, false);
  assert.equal(snap.code, CODE.NONE);
  assert.equal(snap.counts.manualReview, 2);
  assert.equal(snap.counts.retained, 0);
  assert.deepEqual(snap.items.map((i) => [i.type, i.state, i.refId]), [['legacy_wallet_payment_unproven', 'manual_review', 'l1'], ['legacy_wallet_payment_unproven', 'manual_review', 'l2']]);
  assert.deepEqual(buildFinancialSnapshot(r, { atMs: 5 }), snap, 'déterministe');
  const clone = () => JSON.parse(JSON.stringify(r));
  const dropped = clone(); delete dropped.manualReview;
  assert.equal(buildFinancialSnapshot(dropped).blocking, true);
  const emptied = clone(); emptied.manualReview = [];
  assert.equal(buildFinancialSnapshot(emptied).blocking, true);
  for (const bad of ['x', 5, {}, true]) assert.equal(buildFinancialSnapshot({ ...clone(), manualReview: bad }).blocking, true, JSON.stringify(bad));
  const inObl = clone(); inObl.obligations = [r.manualReview[0]]; inObl.manualReview = [];
  assert.equal(buildFinancialSnapshot(inObl).blocking, true);
  assert.ok(buildFinancialSnapshot(inObl).items.some((i) => i.reason === 'item_invalid'), 'élément déplacé neutralisé');
  const real = evaluate(input('client', { orders: [legacyOrder('l9', { isPaid: false })] }));
  const smuggled = { ...real, obligations: [], manualReview: real.obligations, blocking: false, code: 'none', summary: { ...real.summary, open: 0, manualReview: 1, byType: {} } };
  const s2 = buildFinancialSnapshot(smuggled);
  assert.equal(s2.blocking, true);
  assert.equal(s2.counts.manualReview, 0);
  const wrongType = clone(); wrongType.manualReview[0] = { ...wrongType.manualReview[0], type: 'unpaid_delivered_wallet' };
  assert.equal(buildFinancialSnapshot(wrongType).blocking, true);
  const empty = buildFinancialSnapshot(evaluate(input('client')));
  assert.deepEqual(empty.counts, { open: 0, review: 0, ambiguous: 0, retained: 0, manualReview: 0, orders: 0, economic: 0, flags: 0 });
});
