'use strict';

// L3 : exceptions contrôlées de la suppression de compte pour cinq fonctions (payOrderFromWalletCF, cancelOrderCF, deliverOrderCF,
// confirmOrderDeliveryWithProof, ekClientConfirmOrder). Faux Firestore en mémoire (écritures différées, annulées en cas d'échec) :
// chaque refus est prouvé par l'égalité STRICTE de tout le magasin avant/après (aucune écriture, aucun epoch, aucun tombstone levé).
// La concurrence réelle avec le scellement est dans accountClosureExceptions.emulator.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE } = require('./fakeFirestore');
const { buildPayOrderFromWallet, buildCancelOrder, buildDeliverOrder, buildDeliverOrderWithProof } = require('../orderActions');
const { buildEkClientConfirmOrder } = require('../ekbineOrders');
const { hashPin, hashToken, sessionId } = require('../deliveryProofs');
const { CLOSURE_EXCEPTIONS, assertClosureActor, buildOnCallClosing } = require('../accountClosureActor');

const PEPPER = 'unit-test-only-delivery-proof-pepper';
const ts = (ms) => ({ toMillis: () => ms });
const T_ORDER = 1000, T_TOMB = 2000, T_LATE = 3000;
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: { serverTimestamp: () => 'ts', increment: (n) => ({ __increment: n }), delete: () => DELETE },
  },
};
const tomb = (over = {}) => ({ createdAt: ts(T_TOMB), state: 'deleting', ...over });
const SEALED = { phase: 'sealed', sealToken: 'tok', sealEpoch: 0 };
const snapshot = (h) => JSON.stringify([...h.db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
const get = (h, p) => h.db.store.get(p);

const base = { checkRateLimit: async () => {}, logAudit: async () => {}, HttpsError, admin };
function build(db) {
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  process.env.DELIVERY_PROOF_PEPPER = PEPPER;
  return {
    pay: buildPayOrderFromWallet({ db, onCall, ...base }),
    cancel: buildCancelOrder({ db, onCall, ...base, calculateCommission: async () => 100 }),
    deliver: buildDeliverOrder({ db, onCall, ...base }),
    proof: buildDeliverOrderWithProof({ db, onCall, ...base, calculateCommission: async () => 100, deliveryProofPepper: { name: 'p' } }),
    ek: buildEkClientConfirmOrder({ db, onCall: (handler) => ({ run: handler }), ...base }),
  };
}

// Jeu de données par fonction. `actor` = identité qui appelle ; `actorProfile` = document du rôle ; `money` = soldes à protéger.
const TOKEN = crypto.randomBytes(32).toString('base64url');
const SPECS = {
  payOrderFromWalletCF: {
    key: 'pay', actor: 'c1', actorProfile: 'clients/c1', other: 'c2', beneficiary: 'livreurs/d1',
    seed: (o = {}) => ({
      'orders/o1': { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false, status: 'accepted', createdAt: ts(T_ORDER), ...o },
      'clients/c1': { wallet: 1000 }, 'livreurs/d1': { wallet: 200 },
    }),
    call: (h, uid = 'c1') => h.fns.pay.run({ auth: { uid }, data: { orderId: 'o1' } }),
    wrongStatus: { status: 'cancelled' }, notEngaged: { createdAt: ts(T_LATE) }, noStamp: { createdAt: undefined },
    done: (h) => get(h, 'orders/o1').isPaid === true,
    money: (h) => [get(h, 'clients/c1').wallet, get(h, 'livreurs/d1').wallet],
    afterOk: (h) => { assert.equal(get(h, 'clients/c1').wallet, 500); assert.equal(get(h, 'livreurs/d1').wallet, 700); },
  },
  cancelOrderCF: {
    key: 'cancel', actor: 'c1', actorProfile: 'clients/c1', other: 'c2', beneficiary: 'livreurs/d1',
    seed: (o = {}) => ({
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', isPaid: true, budget: 1000, createdAt: ts(T_ORDER),
        commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100, ...o,
      },
      'clients/c1': { wallet: 0 }, 'livreurs/d1': { wallet: 500 },
    }),
    call: (h, uid = 'c1') => h.fns.cancel.run({ auth: { uid }, data: { orderId: 'o1' } }),
    wrongStatus: { status: 'delivered' }, notEngaged: { createdAt: ts(T_LATE) }, noStamp: { createdAt: undefined },
    done: (h) => get(h, 'orders/o1').status === 'cancelled',
    money: (h) => [get(h, 'clients/c1').wallet, get(h, 'livreurs/d1').wallet],
    afterOk: (h) => { assert.equal(get(h, 'clients/c1').wallet, 1000); assert.equal(get(h, 'livreurs/d1').wallet, 600); assert.equal(get(h, 'orders/o1').commissionStatus, 'refunded'); },
  },
  deliverOrderCF: {
    key: 'deliver', actor: 'd1', actorProfile: 'livreurs/d1', other: 'd2', beneficiary: 'restaurants/r1',
    seed: (o = {}) => ({
      'orders/o1': {
        clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', budget: 1000, isPaid: true, sellerId: 'r1',
        sellerType: 'restaurant', acceptedAt: ts(T_ORDER), ...o,
      },
      'livreurs/d1': { wallet: 0 }, 'livreurs/d2': { wallet: 0 }, 'restaurants/r1': { wallet: 100 },
    }),
    call: (h, uid = 'd1') => h.fns.deliver.run({ auth: { uid }, data: { orderId: 'o1' } }),
    wrongStatus: { status: 'pending' }, notEngaged: { acceptedAt: ts(T_LATE) }, noStamp: { acceptedAt: undefined },
    done: (h) => get(h, 'orders/o1').status === 'delivered',
    money: (h) => [get(h, 'livreurs/d1').wallet, get(h, 'restaurants/r1').wallet],
    afterOk: (h) => assert.equal(get(h, 'orders/o1').status, 'delivered'),
  },
  confirmOrderDeliveryWithProof: {
    key: 'proof', actor: 'd1', actorProfile: 'livreurs/d1', other: 'd2', beneficiary: 'restaurants/r1',
    seed: (o = {}) => {
      const id = 'proof-v1';
      const session = `delivery_proofs/${sessionId('o1', 'delivery')}`;
      return {
        'orders/o1': {
          clientId: 'c1', driverId: 'd1', status: 'picked_up', paymentMethod: 'wallet', budget: 1000, isPaid: true, sellerId: 'r1',
          sellerType: 'restaurant', acceptedAt: ts(T_ORDER), deliveryProofMode: 'qr_v1', driverAssignmentVersion: 1, ...o,
        },
        [session]: { orderId: 'o1', type: 'delivery', currentProofId: id, driverId: 'd1', assignmentVersion: 1 },
        [`${session}/versions/${id}`]: {
          orderId: 'o1', type: 'delivery', tokenHash: hashToken(TOKEN), pinHash: hashPin('987654', PEPPER, 'o1', 'delivery'),
          status: 'active', expiresAt: ts(Date.now() + 600_000), driverId: 'd1', assignmentVersion: 1, pinAttempts: 0,
        },
        'livreurs/d1': { wallet: 0 }, 'livreurs/d2': { wallet: 0 }, 'restaurants/r1': { wallet: 100 },
      };
    },
    call: (h, uid = 'd1') => h.fns.proof.run({ auth: { uid }, data: { orderId: 'o1', proofToken: TOKEN } }),
    wrongStatus: { status: 'accepted' }, notEngaged: { acceptedAt: ts(T_LATE) }, noStamp: { acceptedAt: undefined },
    done: (h) => get(h, 'orders/o1').status === 'delivered',
    money: (h) => [get(h, 'livreurs/d1').wallet, get(h, 'restaurants/r1').wallet],
    afterOk: (h) => assert.equal(get(h, 'orders/o1').status, 'delivered'),
  },
  ekClientConfirmOrder: {
    key: 'ek', actor: 'c1', actorProfile: 'clients/c1', other: 'c2', beneficiary: 'ekbine_agents/a1',
    seed: (o = {}) => ({
      'ekbine_orders/o1': {
        clientId: 'c1', agentId: 'a1', status: 'proof_sent', paymentMethod: 'wallet', amount: 1000, walletDebited: true, debitedAmount: 1000,
        debitLedgerId: 'ekorder_o1', assignedAt: ts(T_ORDER), ...o,
      },
      'clients/c1': { wallet: 4000 }, 'clients/c2': { wallet: 0 },
      'clients/c1/wallet_transactions/ekorder_o1': { type: 'payment', amount: -1000, orderId: 'o1', source: 'ekbine_order' },
      'ekbine_agents/a1': { walletBalance: 0, totalCompleted: 0 },
    }),
    call: (h, uid = 'c1') => h.fns.ek.run({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId: 'o1' } }),
    wrongStatus: { status: 'pending' }, notEngaged: { assignedAt: ts(T_LATE) }, noStamp: { assignedAt: undefined },
    ordersPath: 'ekbine_orders/o1',
    done: (h) => get(h, 'ekbine_orders/o1').status === 'completed',
    money: (h) => [get(h, 'clients/c1').wallet, get(h, 'ekbine_agents/a1').walletBalance],
    afterOk: (h) => { assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 1000); assert.equal(get(h, 'clients/c1').wallet, 4000); },
  },
};

function harness(spec, { seed = {}, orderOver = {}, actorOver, tombstone, drop = [] } = {}) {
  const data = { ...spec.seed(orderOver), ...seed };
  if (actorOver) data[spec.actorProfile] = { ...(data[spec.actorProfile] || {}), ...actorOver };
  if (tombstone) data[`account_tombstones/${spec.actor}`] = tombstone;
  for (const p of drop) delete data[p];
  const db = fakeDb(data);
  return { db, fns: build(db) };
}
const orderPath = (spec) => spec.ordersPath || 'orders/o1';
const refused = async (h, spec, expectCode, uid) => {
  const before = snapshot(h);
  await assert.rejects(() => spec.call(h, uid), (e) => (expectCode ? (e.details && e.details.code === expectCode) || e.code === expectCode : true));
  assert.equal(snapshot(h), before, 'aucune écriture : magasin strictement identique');
};
const IN_PROGRESS = 'ACCOUNT_DELETION_IN_PROGRESS';
// L3.1 : refus pour bénéficiaire fermé = aucune écriture FINANCIÈRE, mais une trace idempotente (reconciliation_flags/<id>_<op>_beneficiary_refused).
const TRACE = /^reconciliation_flags\/[^/]+_(pay|deliver)_beneficiary_refused$/;
// L4 : la trace met aussi la commande en revue (needsReview / reviewReason / reviewFlagId) ; ces trois champs sont ignorés ici.
const stripReview = ([k, v]) => {
  if (!/^orders\//.test(k) || !v) return [k, v];
  const { needsReview, reviewReason, reviewFlagId, ...rest } = v;
  return [k, rest];
};
const withoutTrace = (h) => JSON.stringify([...h.db.store.entries()].filter(([k]) => !TRACE.test(k)).map(stripReview).sort(([a], [b]) => (a < b ? -1 : 1)));
const traces = (h) => [...h.db.store.entries()].filter(([k]) => TRACE.test(k));
async function refusedWithTrace(h, spec, cause, { uid, party } = {}) {
  const before = withoutTrace(h);
  await assert.rejects(() => spec.call(h, uid), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED' && e.details.cause === cause);
  assert.equal(withoutTrace(h), before, 'aucune écriture financière ni autre que la trace');
  const t = traces(h);
  assert.equal(t.length, 1, 'une seule trace');
  const first = JSON.stringify(t[0]);
  assert.equal(t[0][1].type, 'beneficiary_closed_refused');
  assert.equal(t[0][1].completed, false, 'jamais un paiement réussi');
  assert.equal(t[0][1].beneficiary.state, cause);
  if (party) assert.equal(`${t[0][1].beneficiary.collection}/${t[0][1].beneficiary.id}`, party);
  assert.ok(!JSON.stringify(t[0][1]).match(/phone|email|"name"|address|"balance"/i), 'aucune donnée personnelle ni solde');
  // Retry : la commande est désormais verrouillée (ORDER_UNDER_REVIEW) jusqu'à clearBeneficiaryReview ; trace et données inchangées.
  await assert.rejects(() => spec.call(h, uid), (e) => ['BENEFICIARY_ACCOUNT_CLOSED', 'ORDER_UNDER_REVIEW'].includes(e.details.code));
  assert.equal(withoutTrace(h), before);
  assert.equal(JSON.stringify(traces(h)[0]), first, 'trace inchangée au retry');
}

for (const [fn, spec] of Object.entries(SPECS)) {
  const tombPath = `account_tombstones/${spec.actor}`;
  const epochOf = (h) => (get(h, tombPath) || {}).epoch;

  test(`${fn} : compte actif -> opération normale, aucun tombstone créé, aucun epoch`, async () => {
    const h = harness(spec);
    await spec.call(h);
    assert.ok(spec.done(h)); spec.afterOk(h);
    assert.equal(get(h, tombPath), undefined);
  });

  test(`${fn} : suppression demandée (deletionRequested, sans tombstone) -> autorisé`, async () => {
    const h = harness(spec, { actorOver: { deletionRequested: true } });
    await spec.call(h);
    assert.ok(spec.done(h));
  });

  test(`${fn} : quarantaine autorisée -> termine l’opération engagée, epoch+1, tombstone intact`, async () => {
    const h = harness(spec, { tombstone: tomb() });
    const before = get(h, tombPath);
    await spec.call(h);
    assert.ok(spec.done(h)); spec.afterOk(h);
    const after = get(h, tombPath);
    assert.equal(after.epoch, 1);
    assert.equal(after.phase, undefined);
    assert.equal(after.createdAt, before.createdAt);
    assert.equal(after.state, 'deleting');
  });

  test(`${fn} : quarantaine explicite (phase closing, epoch 4) -> epoch 5, jamais scellé ni levé`, async () => {
    const h = harness(spec, { tombstone: tomb({ phase: 'closing', epoch: 4 }) });
    await spec.call(h);
    assert.equal(epochOf(h), 5);
    assert.equal(get(h, tombPath).phase, 'closing');
  });

  test(`${fn} : compte scellé -> refus, aucune écriture`, async () => {
    const h = harness(spec, { tombstone: tomb(SEALED) });
    await refused(h, spec, IN_PROGRESS);
  });

  test(`${fn} : suppression Auth commencée (deleting / authDeletedAtMs) -> refus, aucune écriture`, async () => {
    for (const extra of [{ deleting: true }, { authDeletedAtMs: 5 }]) {
      const h = harness(spec, { tombstone: tomb(extra) });
      await refused(h, spec, IN_PROGRESS);
    }
  });

  test(`${fn} : compte anonymisé (avec ou sans tombstone) -> refus, aucune écriture`, async () => {
    for (const tombstone of [tomb(SEALED), tomb(), undefined]) {
      const h = harness(spec, { tombstone, actorOver: { isDeleted: true } });
      await refused(h, spec, IN_PROGRESS);
    }
  });

  test(`${fn} : tombstone sans profil acteur (profil supprimé) -> refus, aucune écriture`, async () => {
    const h = harness(spec, { tombstone: tomb(), drop: [spec.actorProfile] });
    await refused(h, spec, IN_PROGRESS);
  });

  test(`${fn} : tombstone illisible -> refus (échec sûr)`, async () => {
    const h = harness(spec, { tombstone: tomb({ epoch: -3 }) });
    await refused(h, spec, IN_PROGRESS);
  });

  test(`${fn} : mauvais acteur (autre compte en quarantaine) -> refus, aucun epoch`, async () => {
    const h = harness(spec, { tombstone: tomb(), seed: { [`account_tombstones/${spec.other}`]: tomb(), [spec.actorProfile.replace(spec.actor, spec.other)]: { wallet: 0 } } });
    await refused(h, spec, null, spec.other);
    assert.equal(epochOf(h), undefined);
  });

  test(`${fn} : mauvais propriétaire (commande d’un autre) -> refus même pour un compte actif`, async () => {
    const owner = spec.key === 'deliver' || spec.key === 'proof' ? { driverId: 'd2' } : { clientId: 'c2' };
    const h = harness(spec, { orderOver: owner, tombstone: tomb() });
    await refused(h, spec);
    assert.equal(epochOf(h), undefined);
  });

  test(`${fn} : mauvais statut -> refus, aucune écriture, aucun epoch`, async () => {
    for (const tombstone of [undefined, tomb()]) {
      const h = harness(spec, { orderOver: spec.wrongStatus, tombstone });
      await refused(h, spec);
    }
  });

  test(`${fn} : opération non engagée avant la quarantaine (horodatage postérieur ou absent) -> refus, aucune écriture`, async () => {
    for (const over of [spec.notEngaged, spec.noStamp, { [Object.keys(spec.notEngaged)[0]]: 'ts' }]) {
      const h = harness(spec, { orderOver: over, tombstone: tomb() });
      await refused(h, spec, 'ACCOUNT_CLOSING_OPERATION_NOT_ENGAGED');
    }
    // Hors quarantaine l’horodatage n’est pas exigé : un compte actif n’est pas concerné par l’exception.
    const active = harness(spec, { orderOver: spec.notEngaged });
    await spec.call(active);
    assert.ok(spec.done(active));
  });

  test(`${fn} : répétition -> aucun second débit ni second crédit, aucun epoch supplémentaire`, async () => {
    const h = harness(spec, { tombstone: tomb() });
    await spec.call(h);
    const moneyAfter = spec.money(h);
    const epoch = epochOf(h);
    let second = null;
    try { second = await spec.call(h); } catch (e) { second = e; }
    assert.deepEqual(spec.money(h), moneyAfter, 'soldes inchangés');
    assert.equal(epochOf(h), epoch, 'pas de second epoch');
    if (fn === 'ekClientConfirmOrder') assert.equal(second.alreadyDone, true);
    else assert.ok(second instanceof Error, 'la seconde exécution est refusée');
  });

  test(`${fn} : aucun nouveau document de commande n’est créé, le tombstone n’est jamais supprimé`, async () => {
    const h = harness(spec, { tombstone: tomb() });
    const before = [...h.db.store.keys()].filter((k) => /^(orders|ekbine_orders)\//.test(k)).sort();
    await spec.call(h);
    assert.deepEqual([...h.db.store.keys()].filter((k) => /^(orders|ekbine_orders)\//.test(k)).sort(), before);
    assert.ok(get(h, tombPath));
  });
}

// ── Bénéficiaires fermés ─────────────────────────────────────────────────────────────────────────────────────────────────
test('payOrderFromWalletCF : livreur ou pharmacie bénéficiaire anonymisé / scellé / absent -> paiement refusé en entier', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  for (const tombstone of [undefined, tomb()]) {
    const anonymized = harness(spec, { seed: { 'livreurs/d1': { isDeleted: true, wallet: 200 } }, tombstone });
    await refusedWithTrace(anonymized, spec, 'anonymized', { party: 'livreurs/d1' });
    const absent = harness(spec, { tombstone, drop: ['livreurs/d1'] });
    await refusedWithTrace(absent, spec, 'absent', { party: 'livreurs/d1' });
    const sealedDriver = harness(spec, { tombstone, seed: { 'account_tombstones/d1': tomb(SEALED) } });
    await refusedWithTrace(sealedDriver, spec, 'sealed', { party: 'livreurs/d1' });
  }
  const pharm = harness(spec, { orderOver: { pharmacieId: 'p1' }, seed: { 'pharmacies/p1': { isDeleted: true, wallet: 0 } } });
  const callPharm = { call: (h) => h.fns.pay.run({ auth: { uid: 'c1' }, data: { orderId: 'o1', medicineAmount: 300 } }) };
  await refusedWithTrace(pharm, callPharm, 'anonymized', { party: 'pharmacies/p1' });
});

test('payOrderFromWalletCF : pharmacie absente -> refus tracé, la partie fermée est nommée même avec deux bénéficiaires', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  const h = harness(spec, { orderOver: { pharmacieId: 'p9' } });
  const callPharm = { call: (hh) => hh.fns.pay.run({ auth: { uid: 'c1' }, data: { orderId: 'o1', medicineAmount: 300 } }) };
  await refusedWithTrace(h, callPharm, 'absent', { party: 'pharmacies/p9' });
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(get(h, 'livreurs/d1').wallet, 200);
});

test('refus d’un acteur (scellé) : aucune trace de bénéficiaire (ce n’est pas un refus de bénéficiaire)', async () => {
  for (const fn of ['payOrderFromWalletCF', 'deliverOrderCF', 'confirmOrderDeliveryWithProof']) {
    const spec = SPECS[fn];
    const h = harness(spec, { tombstone: tomb(SEALED) });
    await refused(h, spec, IN_PROGRESS);
    assert.equal(traces(h).length, 0);
  }
});

test('payOrderFromWalletCF : livreur en quarantaine -> paiement refusé en entier (aucun nouveau crédit avant résolution, aucune retenue sûre possible)', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  const h = harness(spec, { seed: { 'account_tombstones/d1': tomb() } });
  await refusedWithTrace(h, spec, 'closing', { party: 'livreurs/d1' });
  assert.equal(get(h, 'clients/c1').wallet, 1000, 'rien débité');
  assert.equal(get(h, 'livreurs/d1').wallet, 200, 'rien crédité');
  assert.equal(get(h, 'account_tombstones/d1').epoch, undefined, 'tombstone du bénéficiaire inchangé');
  assert.equal(get(h, 'orders/o1').isPaid, false);
  assert.equal(get(h, 'orders/o1').needsReview, true);
  assert.equal(get(h, 'orders/o1').reviewReason, 'beneficiary_closed');
  // le verrou de revue interdit tout nouveau règlement tant que clearBeneficiaryReview n'a pas levé le refus
  await assert.rejects(() => spec.call(h), (e) => e.details && e.details.code === 'ORDER_UNDER_REVIEW');
  assert.equal(get(h, 'clients/c1').wallet, 1000);
});

test('payOrderFromWalletCF : journaux dans la transaction, identifiants déterministes, un seul débit et un seul crédit même après retry', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  const h = harness(spec);
  await spec.call(h);
  assert.equal(get(h, 'clients/c1').wallet, 500);
  assert.equal(get(h, 'livreurs/d1').wallet, 700);
  assert.equal(get(h, 'clients/c1/wallet_transactions/pay_order_o1').amount, 500);
  assert.equal(get(h, 'livreurs/d1/wallet_transactions/earning_pay_order_o1').amount, 500);
  assert.equal(get(h, 'orders/o1').paidBy, 'c1');
  const journals = [...h.db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));
  await assert.rejects(() => spec.call(h));
  assert.equal(get(h, 'clients/c1').wallet, 500);
  assert.equal(get(h, 'livreurs/d1').wallet, 700);
  assert.deepEqual([...h.db.store.keys()].filter((k) => k.includes('/wallet_transactions/')), journals, 'aucun journal supplémentaire');
});

test('payOrderFromWalletCF : échec de la transaction (solde insuffisant) -> aucun journal ni débit ni crédit', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  const h = harness(spec, { seed: { 'clients/c1': { wallet: 100 } } });
  await assert.rejects(() => spec.call(h), (e) => /SOLDE_INSUFFISANT/.test(e.message));
  assert.equal([...h.db.store.keys()].filter((k) => k.includes('/wallet_transactions/')).length, 0);
  assert.equal(get(h, 'livreurs/d1').wallet, 200);
});

test('payOrderFromWalletCF : statuts non payables refusés (annulée, expirée, remboursée, échouée, rejetée)', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  for (const status of ['cancelled', 'expired', 'refunded', 'failed', 'rejected']) {
    const h = harness(spec, { orderOver: { status }, tombstone: tomb() });
    await refused(h, spec, 'PAYMENT_ORDER_NOT_PAYABLE');
  }
});

test('cancelOrderCF : commission d’un livreur anonymisé / absent -> client remboursé, crédit omis, commissionStatus inchangé, signalement', async () => {
  const spec = SPECS.cancelOrderCF;
  for (const closed of [{ wallet: 500, isDeleted: true }, null]) {
    for (const tombstone of [undefined, tomb()]) {
      const h = harness(spec, { seed: closed ? { 'livreurs/d1': closed } : {}, drop: closed ? [] : ['livreurs/d1'], tombstone });
      await spec.call(h);
      assert.equal(get(h, 'clients/c1').wallet, 1000, 'le client est toujours remboursé');
      assert.equal((get(h, 'livreurs/d1') || { wallet: 500 }).wallet, 500, 'aucun crédit au bénéficiaire fermé');
      assert.equal(get(h, 'orders/o1').commissionStatus, 'charged');
      assert.equal(get(h, 'orders/o1').status, 'cancelled');
      const flag = get(h, 'reconciliation_flags/o1_beneficiary_closed');
      assert.equal(flag.type, 'beneficiary_closed'); assert.equal(flag.needsReview, true);
      assert.equal(flag.parties[0].amountWithheld, 100, 'montant dû tracé');
      assert.equal(get(h, 'orders/o1').needsReview, true);
      assert.equal(get(h, 'orders/o1').reviewReason, 'beneficiary_credit_omitted');
      if (tombstone) assert.equal(get(h, 'account_tombstones/c1').epoch, 1);
    }
  }
});

test('cancelOrderCF : livreur bénéficiaire scellé -> client remboursé, aucun crédit au scellé, signalement idempotent, compte scellé non rouvert', async () => {
  const spec = SPECS.cancelOrderCF;
  const h = harness(spec, { tombstone: tomb(), seed: { 'account_tombstones/d1': tomb(SEALED) } });
  const sealedBefore = JSON.stringify(get(h, 'account_tombstones/d1'));
  await spec.call(h);
  assert.equal(get(h, 'orders/o1').status, 'cancelled');
  assert.equal(get(h, 'clients/c1').wallet, 1000, 'client remboursé selon les règles normales');
  assert.equal(get(h, 'livreurs/d1').wallet, 500, 'aucun crédit au bénéficiaire scellé');
  assert.equal(JSON.stringify(get(h, 'account_tombstones/d1')), sealedBefore, 'tombstone scellé inchangé (jamais rouvert)');
  const flag = get(h, 'reconciliation_flags/o1_beneficiary_closed');
  assert.equal(flag.parties[0].state, 'sealed');
  // L4.6 : champ plat additif + le moteur d'obligations lit CE signalement réel (bénéficiaire, 100 XOF, bloquant, créance maintenue).
  assert.equal(flag.driverId, 'd1');
  {
    const engine = require('../accountObligations');
    const req = engine.requiredQueries('livreur', ['d1']);
    const reads = {};
    for (const n of ['orders', 'settlements', 'flags']) reads[n] = { queries: req[n].map((q, i) => ({ ...q, limit: 201, size: i === 0 && n === 'flags' ? 1 : 0 })) };
    const res = engine.evaluateAccountObligations({
      role: 'livreur', ids: ['d1'], orders: [], settlements: [], flags: [{ id: 'o1_beneficiary_closed', data: flag }],
      terminalStatuses: engine.INSPECTOR_TERMINAL_STATUSES.accountDeletionScope, walletDebits: [], reads,
    });
    const item = res.obligations.find((i) => i.source === 'reconciliation_flag');
    assert.equal(res.blocking, true);
    assert.equal(item.reason, 'flag_open:beneficiary_closed');
    assert.equal(item.amount, 100);
  }
  assert.equal(get(h, 'orders/o1').reviewReason, 'beneficiary_credit_omitted');
  // rejeu : refusé (déjà annulée), aucun second remboursement ni second signalement
  await assert.rejects(() => spec.call(h));
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.deepEqual(get(h, 'reconciliation_flags/o1_beneficiary_closed'), flag);
});

test('cancelOrderCF : bénéficiaire en quarantaine simple -> client remboursé, aucun NOUVEAU crédit, montant tracé, tombstone du bénéficiaire inchangé', async () => {
  const spec = SPECS.cancelOrderCF;
  const h = harness(spec, { tombstone: tomb(), seed: { 'account_tombstones/d1': tomb() } });
  await spec.call(h);
  assert.equal(get(h, 'clients/c1').wallet, 1000);
  assert.equal(get(h, 'livreurs/d1').wallet, 500, 'pas de crédit pendant la quarantaine');
  assert.equal(get(h, 'account_tombstones/d1').epoch, undefined);
  assert.equal(get(h, 'account_tombstones/c1').epoch, 1);
  const flag = get(h, 'reconciliation_flags/o1_beneficiary_closed');
  assert.equal(flag.parties[0].reason, 'beneficiary_in_quarantine');
  assert.equal(flag.parties[0].amountWithheld, 100);
  assert.equal(get(h, 'orders/o1').reviewReason, 'beneficiary_credit_omitted');
});

test('cancelOrderCF : après récupération le client en quarantaine ne peut ni annuler ni écrire une demande (acteur contrôlé d’abord)', async () => {
  const spec = SPECS.cancelOrderCF;
  for (const tombstone of [tomb(SEALED), tomb({ deleting: true })]) {
    const h = harness(spec, { orderOver: { status: 'picked_up' }, tombstone });
    await refused(h, spec, IN_PROGRESS);
  }
});

test('deliverOrderCF / confirmOrderDeliveryWithProof : partenaire à créditer anonymisé ou scellé -> livraison refusée sans écriture (DR2)', async () => {
  for (const fn of ['deliverOrderCF', 'confirmOrderDeliveryWithProof']) {
    const spec = SPECS[fn];
    for (const tombstone of [undefined, tomb()]) {
      const anonymized = harness(spec, { tombstone, seed: { 'restaurants/r1': { wallet: 100, isDeleted: true } } });
      await refusedWithTrace(anonymized, spec, 'anonymized', { party: 'restaurants/r1' });
      const sealed = harness(spec, { tombstone, seed: { 'account_tombstones/r1': tomb(SEALED) } });
      await refusedWithTrace(sealed, spec, 'sealed', { party: 'restaurants/r1' });
      // DR2 §6.4 : partenaire ABSENT = anonymisé -> livraison refusée, livreur non crédité, commande non livrée.
      const absent = harness(spec, { tombstone, drop: ['restaurants/r1'] });
      await refusedWithTrace(absent, spec, 'absent', { party: 'restaurants/r1' });
      assert.notEqual(get(absent, 'orders/o1').status, 'delivered');
      assert.equal(get(absent, 'livreurs/d1').wallet, 0);
      assert.equal(get(absent, 'reconciliation_flags/o1_partner_credit_missing'), undefined, 'pas de faux signalement de crédit manquant');
    }
  }
});

test('deliverOrderCF / confirmOrderDeliveryWithProof : partenaire en quarantaine -> livraison REFUSÉE (aucune retenue financière sûre), rien débité ni crédité, tombstone inchangé', async () => {
  for (const fn of ['deliverOrderCF', 'confirmOrderDeliveryWithProof']) {
    const spec = SPECS[fn];
    const h = harness(spec, { tombstone: tomb(), seed: { 'account_tombstones/r1': tomb() } });
    await refusedWithTrace(h, spec, 'closing', { party: 'restaurants/r1' });
    assert.notEqual(get(h, 'orders/o1').status, 'delivered');
    assert.equal(get(h, 'restaurants/r1').wallet, 100);
    assert.equal(get(h, 'livreurs/d1').wallet, 0, 'livreur non crédité non plus');
    assert.equal(get(h, 'account_tombstones/r1').epoch, undefined);
    assert.equal(get(h, 'reconciliation_flags/o1_partner_credit_held'), undefined, 'aucune fausse « réserve » par simple signalement');
  }
});

test('deliverOrderCF : commande en revue pour bénéficiaire fermé -> livraison refusée (ORDER_UNDER_REVIEW) tant que la revue n’est pas levée', async () => {
  const spec = SPECS.deliverOrderCF;
  const h = harness(spec, { orderOver: { needsReview: true, reviewReason: 'beneficiary_closed' } });
  await refused(h, spec, 'ORDER_UNDER_REVIEW');
});

test('livraison : un partenaire qui n’est PAS crédité (paiement espèces) n’est pas contrôlé -> aucun refus à tort', async () => {
  const spec = SPECS.deliverOrderCF;
  const h = harness(spec, { orderOver: { paymentMethod: 'cash', isPaid: false }, drop: ['restaurants/r1'], tombstone: tomb() });
  await spec.call(h);
  assert.equal(get(h, 'orders/o1').status, 'delivered');
  assert.equal(traces(h).length, 0);
});

test('une transaction qui échoue pour une autre raison n’écrit aucune trace de bénéficiaire', async () => {
  const spec = SPECS.deliverOrderCF;
  const h = harness(spec, { orderOver: spec.wrongStatus, drop: ['restaurants/r1'] });
  await refused(h, spec);
  assert.equal(traces(h).length, 0);
});

test('trace de refus : si l’écriture de la trace échoue, le refus métier d’origine est quand même renvoyé', async () => {
  const spec = SPECS.payOrderFromWalletCF;
  const h = harness(spec, { drop: ['livreurs/d1'] });
  const coll = h.db.collection;
  h.db.collection = (name) => {
    const c = coll(name);
    if (name !== 'reconciliation_flags') return c;
    return { ...c, doc: (id) => ({ ...c.doc(id), get: async () => { throw new Error('trace down'); } }) };
  };
  await assert.rejects(() => spec.call(h), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED');
});

test('adminConfirmDeliveryCF : la confirmation administrative ne passe pas par la garde de fermeture', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'orderActions.js'), 'utf8');
  // L4.2 : la confirmation administrative a sa propre garde de BÉNÉFICIAIRE (jamais la garde d'acteur de fermeture).
  assert.match(src, /if \(adminInfo\) \{[\s\S]*?await assertBeneficiariesCreditable\(tx, db, HttpsError, adminBeneficiaries\)/);
  assert.match(src, /\} else \{\s*assertNotUnderReview\(HttpsError, order\);\s*closure = await closureGuard/);
  const index = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const start = index.indexOf('exports.adminConfirmDeliveryCF');
  assert.ok(start > 0);
  assert.ok(!index.slice(start, start + 600).includes('onCallClosing'));
});

// ── E-Kbine (conditions C1 à C13) ────────────────────────────────────────────────────────────────────────────────────────
test('ekClientConfirmOrder : T1 succès en quarantaine -> agent crédité du montant débité, epoch+1, audit sans donnée personnelle', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const h = harness(spec, { tombstone: tomb() });
  const clientBefore = JSON.stringify(get(h, 'clients/c1'));
  const res = await spec.call(h);
  assert.equal(res.credited, 1000);
  assert.equal(get(h, 'account_tombstones/c1').epoch, 1);
  assert.equal(JSON.stringify(get(h, 'clients/c1')), clientBefore, 'C12 : aucune écriture sur clients/{uid}');
  const audit = [...h.db.store.entries()].find(([k]) => k.startsWith('audit_logs/'))[1];
  assert.equal(audit.closureDuringQuarantine, true);
  assert.equal(audit.action, 'ekbine_confirm_order');
  assert.ok(!JSON.stringify(audit).match(/phone|name|email/i));
});

test('ekClientConfirmOrder : C3 identité client uniquement (autre rôle existant) -> refus, aucune écriture', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  for (const col of ['livreurs', 'sellers', 'restaurants', 'pharmacies', 'boulangeries', 'ekbine_agents', 'real_estate_agents', 'fleet_owners', 'admins']) {
    const h = harness(spec, { tombstone: tomb(), seed: { [`${col}/c1`]: { wallet: 0 } } });
    await refused(h, spec, IN_PROGRESS);
  }
});

test('ekClientConfirmOrder : C7/C8 agent anonymisé, en quarantaine, supprimé ou absent -> toute la confirmation refusée', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const agents = [
    { seed: { 'ekbine_agents/a1': { walletBalance: 0, isDeleted: true } } },
    { seed: { 'ekbine_agents/a1': { walletBalance: 0, deletionRequested: true } } },
    { seed: { 'account_tombstones/a1': tomb() } },
    { seed: { 'account_tombstones/a1': tomb(SEALED) } },
    { drop: ['ekbine_agents/a1'] },
  ];
  for (const a of agents) {
    const h = harness(spec, { tombstone: tomb(), ...a });
    await refused(h, spec);
    assert.equal(get(h, 'reconciliation_flags/ekconfirm_o1'), undefined);
  }
});

test('ekClientConfirmOrder : C9 débit non prouvé en quarantaine -> refus, aucun signalement créé ; journal incohérent -> refus', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const unproven = [
    { walletDebited: false }, { debitedAmount: undefined }, { debitedAmount: 999 }, { refunded: true }, { debitLedgerId: 'ekorder_other' },
  ];
  for (const over of unproven) {
    const h = harness(spec, { tombstone: tomb(), orderOver: over });
    await refused(h, spec, 'EK_DEBIT_UNPROVEN_DURING_CLOSURE');
    assert.equal(get(h, 'reconciliation_flags/ekconfirm_o1'), undefined, 'aucun flag');
  }
  const ledgers = [
    { type: 'payment', amount: -999, orderId: 'o1' }, { type: 'payment', amount: -1000, orderId: 'other' },
    { type: 'refund', amount: -1000, orderId: 'o1' }, { type: 'payment', amount: 1000, orderId: 'o1' },
  ];
  for (const ledger of ledgers) {
    const h = harness(spec, { tombstone: tomb(), seed: { 'clients/c1/wallet_transactions/ekorder_o1': ledger } });
    await refused(h, spec, 'EK_DEBIT_UNPROVEN_DURING_CLOSURE');
  }
  const noLedger = harness(spec, { tombstone: tomb(), drop: ['clients/c1/wallet_transactions/ekorder_o1'] });
  await refused(noLedger, spec, 'EK_DEBIT_UNPROVEN_DURING_CLOSURE');
});

test('ekClientConfirmOrder : paiement hors wallet en quarantaine -> succès sans crédit (T16)', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const h = harness(spec, { tombstone: tomb(), orderOver: { paymentMethod: 'orange_money', walletDebited: false, debitedAmount: 0, debitLedgerId: null } });
  const res = await spec.call(h);
  assert.equal(res.credited, 0);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal(get(h, 'account_tombstones/c1').epoch, 1);
});

test('ekClientConfirmOrder : compte actif avec débit non prouvé -> comportement historique (pas de crédit, signalement)', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const h = harness(spec, { orderOver: { walletDebited: false } });
  const res = await spec.call(h);
  assert.equal(res.credited, 0);
  assert.ok(get(h, 'reconciliation_flags/ekconfirm_o1'));
});

test('ekClientConfirmOrder : C1 assignedAt doit être un Timestamp serveur (nombre ou texte refusé en quarantaine)', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  for (const assignedAt of [500, '2020-01-01', { seconds: 1 }, null]) {
    const h = harness(spec, { tombstone: tomb(), orderOver: { assignedAt } });
    await refused(h, spec, 'ACCOUNT_CLOSING_OPERATION_NOT_ENGAGED');
  }
});

test('ekClientConfirmOrder : C5 egalité des horodatages (assignedAt == createdAt) -> refus (strictement antérieur)', async () => {
  const spec = SPECS.ekClientConfirmOrder;
  const h = harness(spec, { tombstone: tomb(), orderOver: { assignedAt: ts(T_TOMB) } });
  await refused(h, spec, 'ACCOUNT_CLOSING_OPERATION_NOT_ENGAGED');
});

// ── Socle : fonctions autorisées, enveloppe, câblage ─────────────────────────────────────────────────────────────────────
test('la liste des exceptions est fermée : exactement cinq fonctions, gelée', () => {
  assert.deepEqual(Object.keys(CLOSURE_EXCEPTIONS).sort(),
    ['cancelOrderCF', 'confirmOrderDeliveryWithProof', 'deliverOrderCF', 'ekClientConfirmOrder', 'payOrderFromWalletCF']);
  assert.ok(Object.isFrozen(CLOSURE_EXCEPTIONS));
  assert.throws(() => { 'use strict'; CLOSURE_EXCEPTIONS.adminConfirmDeliveryCF = 'livreurs'; }, TypeError);
});

test('assertClosureActor : une fonction hors liste est rejetée (aucune exception globale)', async () => {
  const db = fakeDb({ 'clients/c1': { wallet: 0 } });
  await assert.rejects(() => db.runTransaction((tx) => assertClosureActor(tx, db, HttpsError, { fn: 'initiateWithdrawal', uid: 'c1' })), TypeError);
  await assert.rejects(() => db.runTransaction((tx) => assertClosureActor(tx, db, HttpsError, { fn: 'createOrderCF', uid: 'c1' })), TypeError);
});

test('assertClosureActor : identifiants invalides refusés', async () => {
  const db = fakeDb({});
  for (const uid of [undefined, '', 'a/b', 12]) {
    await assert.rejects(() => db.runTransaction((tx) => assertClosureActor(tx, db, HttpsError, { fn: 'payOrderFromWalletCF', uid })), (e) => e.code === 'permission-denied');
  }
});

test('onCallClosing : contrôle préalable (tombstone absent ou quarantaine simple passe ; scellé, suppression Auth, illisible refusés)', async () => {
  const cases = [
    [undefined, true], [tomb(), true], [tomb({ phase: 'closing', epoch: 2 }), true],
    [tomb(SEALED), false], [tomb({ deleting: true }), false], [tomb({ authDeletedAtMs: 3 }), false], [tomb({ phase: 'weird' }), false],
  ];
  for (const [tombstone, ok] of cases) {
    const db = fakeDb(tombstone ? { 'account_tombstones/u1': tombstone } : {});
    const onCallClosing = buildOnCallClosing({ rawOnCall: (options, handler) => ({ run: handler, options }), db, HttpsError });
    const wrapped = onCallClosing('payOrderFromWalletCF', { maxInstances: 3 }, async () => 'handled');
    assert.deepEqual(wrapped.options, { maxInstances: 3 }, 'options conservées');
    if (ok) assert.equal(await wrapped.run({ auth: { uid: 'u1' } }), 'handled');
    else await assert.rejects(() => wrapped.run({ auth: { uid: 'u1' } }), (e) => e.code === 'permission-denied' && e.details.code === IN_PROGRESS);
  }
});

test('onCallClosing : refuse de créer l’enveloppe pour une fonction hors liste', () => {
  const db = fakeDb({});
  const onCallClosing = buildOnCallClosing({ rawOnCall: (o, h) => ({ run: h }), db, HttpsError });
  assert.throws(() => onCallClosing('adminConfirmDeliveryCF', {}, async () => {}), TypeError);
  assert.throws(() => onCallClosing('getPartnerQr', {}, async () => {}), TypeError);
});

test('câblage de index.js : exactement les cinq exports utilisent onCallClosing, chacun avec son propre nom ; aucun autre', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const uses = [...src.matchAll(/onCallClosing\('([A-Za-z]+)'/g)].map((m) => m[1]).sort();
  assert.deepEqual(uses, Object.keys(CLOSURE_EXCEPTIONS).sort());
  for (const fn of Object.keys(CLOSURE_EXCEPTIONS)) {
    const start = src.indexOf(`exports.${fn} `);
    assert.ok(start > 0, fn);
    const stmt = src.slice(start, src.indexOf(';', src.indexOf('onCallClosing', start)) + 1);
    assert.ok(stmt.includes(`onCallClosing('${fn}'`), `${fn} utilise son enveloppe`);
  }
  // Aucune autre déclaration de l’enveloppe, et le wrapper général n’a pas été assoupli.
  assert.equal(src.split('buildOnCallClosing').length - 1, 1);
  assert.match(src, /await assertAccountEnabled\(db,request\.auth\?\.uid,HttpsError\);/);
});

test('options de capacité conservées pour les cinq exports (maxInstances / capInstances / pilotOnlyInstanceOptions)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(src, /onCallClosing\('ekClientConfirmOrder', \{ maxInstances: 2, cpu: 0\.5 \}, h\)/);
  assert.match(src, /onCallClosing\('payOrderFromWalletCF', \{ maxInstances: 3 \}, h\)/);
  assert.match(src, /onCallClosing\('cancelOrderCF', \{ maxInstances: capInstances\(3\) \}, h\)/);
  assert.match(src, /onCallClosing\('deliverOrderCF', \{ \.\.\.o, maxInstances: capInstances\(3\) \}, h\)/);
  assert.match(src, /onCallClosing\('confirmOrderDeliveryWithProof', \{ \.\.\.o, \.\.\.pilotOnlyInstanceOptions\(\) \}, h\)/);
});

test('aucune des cinq fonctions ne crée de commande (C2 structurel) ni ne supprime / réécrit le tombstone', () => {
  const orderSrc = fs.readFileSync(path.join(__dirname, '..', 'orderActions.js'), 'utf8');
  const ekSrc = fs.readFileSync(path.join(__dirname, '..', 'ekbineOrders.js'), 'utf8');
  const slice = (src, from, to) => src.slice(src.indexOf(from), src.indexOf(to, src.indexOf(from)));
  const bodies = [
    slice(orderSrc, 'function buildPayOrderFromWallet', '// Cœur transactionnel'),
    slice(orderSrc, 'function buildCancelOrder', '// Remplace FirestoreService.deliverOrder'),
    slice(ekSrc, 'function buildEkClientConfirmOrder', '// ── ekbineAcceptOrder'),
  ];
  for (const body of bodies) {
    assert.ok(!/tx\.create\(/.test(body), 'pas de création');
    assert.ok(!/collection\('(orders|ekbine_orders)'\)\.add\(/.test(body), 'pas d’ajout de commande');
    assert.ok(!/account_tombstones'\)\.doc\([^)]*\)\.(delete|set)\(/.test(body), 'tombstone jamais supprimé ni réécrit');
  }
  const actorSrc = fs.readFileSync(path.join(__dirname, '..', 'accountClosureActor.js'), 'utf8');
  assert.ok(!/\.delete\(|phase:\s*'closing'|FieldValue\.delete/.test(actorSrc), 'le socle ne lève ni ne rouvre le tombstone');
});
