'use strict';

// Rapport financier LOCAL et réconciliation des commandes du lot (Mission 7E-47). Lecture seule : aucune écriture cloud, aucun wallet
// modifié. Aucun PIN, jeton de preuve, empreinte de preuve ni mot de passe : seuls des champs blancs (identifiants, montants, statuts,
// dates) sont retenus. La réconciliation sert aussi de garde-fou au nettoyage : un écart bloque toute suppression.

const lot = require('./lot');
const intruder = require('./intruder');

const { IDENTITIES } = lot;
const WALLET_OWNERS = Object.freeze({
  client: `clients/${IDENTITIES.client.uid}`, driver: `livreurs/${IDENTITIES.driver.uid}`,
  restaurant: `restaurants/${IDENTITIES.restaurant.uid}`, intruder: `clients/${intruder.INTRUDER.uid}`,
});
const SIGN = Object.freeze({ payment: -1, commission: -1, earning: 1, refund: 1 });
const ms = (v) => (v && typeof v.toMillis === 'function' ? v.toMillis() : (typeof v === 'number' ? v : null));
const iso = (v) => (ms(v) === null ? null : new Date(ms(v)).toISOString());

// ── Lecture ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
// includeIntruder : seulement si le manifeste étendu (7E-43) a créé le compte intrus ; sinon un document t7e-intrus éventuel n'est pas du lot.
async function gather({ db, orderIds, includeIntruder = false }) {
  const data = { orders: {}, quotes: [], commissions: [], txs: {}, wallets: {}, walletDocs: {}, proofs: [], audit: [] };
  for (const id of orderIds) { const s = await db.doc(`orders/${id}`).get(); if (s.exists) data.orders[id] = s.data(); }
  for (const d of (await db.collection('tariff_quotes').where('uid', '==', IDENTITIES.client.uid).get()).docs) data.quotes.push({ id: d.id, ...d.data() });
  for (const id of orderIds) for (const d of (await db.collection('commissions').where('orderId', '==', id).get()).docs) data.commissions.push({ id: d.id, ...d.data() });
  for (const [k, p] of Object.entries(WALLET_OWNERS)) {
    if (k === 'intruder' && !includeIntruder) { data.walletDocs[k] = false; data.wallets[k] = null; data.txs[k] = []; continue; }
    const s = await db.doc(p).get();
    data.walletDocs[k] = s.exists;
    data.wallets[k] = s.exists ? s.data().wallet : null;
    data.txs[k] = (await db.collection(`${p}/wallet_transactions`).get()).docs.map((d) => ({ id: d.id, ...d.data() }));
  }
  for (const id of orderIds) {
    for (const d of (await db.collection('delivery_proofs').where('orderId', '==', id).get()).docs) {
      const versions = (await d.ref.collection('versions').get()).docs.map((v) => v.data());
      data.proofs.push({ id: d.id, session: d.data(), versions });
    }
  }
  const uids = new Set([...lot.UIDS, intruder.INTRUDER.uid]);
  const audit = await db.collection('audit_logs').orderBy('createdAt', 'desc').limit(300).get();
  data.audit = audit.docs.map((d) => d.data()).filter((a) => uids.has(a.userId || a.uid) || orderIds.includes((a.metadata || {}).orderId) || orderIds.includes(a.targetId));
  return data;
}

// ── Réconciliation (pure) ────────────────────────────────────────────────────────────────────────────────────────────────────────
function reconcile(data, start = lot.WALLETS) {
  const problems = [];
  const bad = (why) => problems.push(why);
  const orderIds = Object.keys(data.orders);
  const expected = { client: start.client, driver: start.driver, restaurant: start.restaurant, intruder: 0 };

  for (const id of orderIds) {
    const o = data.orders[id];
    const label = `commande ${id.slice(0, 8)}`;
    // Annulée : le contrôle porte sur la somme des écritures (remboursements compris), pas sur le détail livré.
    if (o.status === 'cancelled') continue;
    if (o.status !== 'delivered') { bad(`${label} : statut ${o.status} (livrée ou annulée attendue)`); continue; }
    if (o.clientId !== IDENTITIES.client.uid || o.sellerId !== IDENTITIES.restaurant.uid || o.driverId !== IDENTITIES.driver.uid) bad(`${label} : acteurs hors lot`);
    if (o.paymentMethod !== 'wallet' || o.isPaid !== true) bad(`${label} : paiement wallet non confirmé`);
    if (!(Number.isInteger(o.productAmount) && Number.isInteger(o.deliveryFee) && o.totalAmount === o.productAmount + o.deliveryFee)) bad(`${label} : total ≠ produits + livraison`);
    if (o.commissionAmount !== lot.commissionFor(o.deliveryFee)) bad(`${label} : commission ${o.commissionAmount} ≠ barème ${lot.commissionFor(o.deliveryFee)}`);
    const mine = (k) => data.txs[k].filter((t) => t.orderId === id);
    const one = (k, type, amount) => {
      const list = mine(k).filter((t) => t.type === type);
      if (list.length !== 1) bad(`${label} : ${list.length} écriture(s) « ${type} » pour ${k} (1 attendue)`);
      else if (list[0].amount !== amount) bad(`${label} : écriture « ${type} » ${list[0].amount} ≠ ${amount}`);
    };
    one('client', 'payment', o.totalAmount);
    one('driver', 'commission', o.commissionAmount);
    one('driver', 'earning', o.deliveryFee);
    one('restaurant', 'earning', o.productAmount);
    const commissions = data.commissions.filter((c) => c.orderId === id);
    if (commissions.length !== 1) bad(`${label} : ${commissions.length} commission(s) (1 attendue)`);
    else if (commissions[0].amount !== o.commissionAmount) bad(`${label} : commission enregistrée ${commissions[0].amount} ≠ ${o.commissionAmount}`);
    const used = data.quotes.filter((q) => q.status === 'used' && q.orderId === id);
    if (used.length !== 1) bad(`${label} : ${used.length} devis utilisé(s) (1 attendu)`);
    else if (used[0].amount !== o.totalAmount) bad(`${label} : devis ${used[0].amount} ≠ total ${o.totalAmount}`);
    const proofs = data.proofs.filter((p) => p.session.orderId === id);
    for (const type of ['pickup', 'delivery']) {
      const p = proofs.find((x) => x.session.type === type);
      if (!p) bad(`${label} : preuve ${type} absente`);
      else if (!p.versions.some((v) => ms(v.validatedAt) !== null || v.status === 'validated')) bad(`${label} : preuve ${type} non validée`);
    }
  }
  // Soldes : départ + écritures signées. Toute écriture de type inconnu ou sans commande du lot est un écart.
  for (const k of Object.keys(expected)) {
    // Le compte intrus n'existe que si le manifeste étendu l'a créé ; tout autre portefeuille absent reste un écart.
    if (!data.walletDocs[k] && k === 'intruder') continue;
    for (const t of data.txs[k]) {
      if (!(t.type in SIGN)) { bad(`écriture inconnue « ${t.type} » sur ${k}`); continue; }
      if (!orderIds.includes(t.orderId)) { bad(`écriture sans commande du lot sur ${k}`); continue; }
      expected[k] += SIGN[t.type] * t.amount;
    }
    if (data.wallets[k] !== expected[k]) bad(`solde ${k} ${data.wallets[k]} ≠ attendu ${expected[k]}`);
  }
  if (data.txs.intruder.length || orderIds.some((id) => data.orders[id].clientId === intruder.INTRUDER.uid)) bad('activité de l’intrus');
  return { coherent: problems.length === 0, problems, expectedWallets: expected };
}

// ── Rapport (champs blancs uniquement) ───────────────────────────────────────────────────────────────────────────────────────────
function buildReport(data, { project, generatedAtMs = Date.now() } = {}) {
  const verdict = reconcile(data);
  const orders = Object.entries(data.orders).map(([id, o]) => ({
    orderId: id, status: o.status, type: o.type, paymentMethod: o.paymentMethod, isPaid: o.isPaid, amounts: { productAmount: o.productAmount, deliveryFee: o.deliveryFee, totalAmount: o.totalAmount, commissionAmount: o.commissionAmount },
    clientId: o.clientId, sellerId: o.sellerId, driverId: o.driverId, tariffQuoteId: o.tariffQuoteId || null, createdAt: iso(o.createdAt), deliveredAt: iso(o.deliveredAt),
  }));
  const ledger = (k) => data.txs[k].map((t) => ({ txId: t.id, type: t.type, amount: t.amount, orderId: t.orderId || null, createdAt: iso(t.createdAt) })).sort((a, b) => (a.txId < b.txId ? -1 : 1));
  return {
    kind: 'restaurant-v2-first-run-financial-report', lot: lot.LOT_ID, project, generatedAt: new Date(generatedAtMs).toISOString(), coherent: verdict.coherent, problems: verdict.problems,
    orders,
    quotes: data.quotes.map((q) => ({ quoteId: q.id, status: q.status, orderId: q.orderId || null, amount: q.amount, deliveryFee: q.deliveryFee, productAmount: q.productAmount, expired: typeof q.expiresAtMs === 'number' ? q.expiresAtMs < generatedAtMs : null })),
    commissions: data.commissions.map((c) => ({ id: c.id, orderId: c.orderId, amount: c.amount, driverId: c.driverId, deliveryFee: c.deliveryFee, driverGain: c.driverGain })),
    wallets: { before: { ...lot.WALLETS, intruder: 0 }, after: { ...data.wallets }, expected: verdict.expectedWallets },
    walletTransactions: { client: ledger('client'), driver: ledger('driver'), restaurant: ledger('restaurant'), intruder: ledger('intruder') },
    // Aucune empreinte (pinHash/tokenHash), aucun PIN ni jeton : type, statut et dates seulement.
    deliveryProofs: data.proofs.map((p) => ({ type: p.session.type, orderId: p.session.orderId, generationCount: p.session.generationCount || null, versions: p.versions.map((v) => ({ status: v.status, validationMethod: v.validationMethod || null, pinAttempts: v.pinAttempts ?? null, validated: ms(v.validatedAt) !== null, createdAt: iso(v.createdAt) })) })),
    idempotence: {
      cloud: 'unicité constatée : une écriture par type et par commande, une commission, un devis utilisé (identifiants déterministes order_/commission_/earning_)',
      replaysNotRunInCloud: true,
      replaysCoveredByEmulator: ['création rejouée → replayed, aucun second débit', 'acceptation rejouée → alreadyAccepted, aucune seconde commission', 'preuves QR/PIN réutilisées → refusées', 'double livraison → refusée'],
    },
    audit: data.audit.map((a) => ({ action: a.action, userId: a.userId || a.uid || null, orderId: (a.metadata || {}).orderId || (data.orders[a.targetId] ? a.targetId : null), code: (a.metadata || {}).code || null, at: iso(a.createdAt) })).reverse(),
  };
}

module.exports = { gather, reconcile, buildReport, WALLET_OWNERS };
