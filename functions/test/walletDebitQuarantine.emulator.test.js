'use strict';

// Mission 7E-90 (lot 2B) : CONCURRENCE quarantaine ↔ création de commande payée, contre l'émulateur Firestore (vraies transactions
// de l'Admin SDK). Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Données synthétiques, aucun appel réseau.
//
// Limite assumée : l'émulateur reproduit la sérialisation transactionnelle de Firestore mais pas sa charge ni sa latence réelles ;
// ces tests prouvent l'ABSENCE de violation sur N entrelacements tirés, pas l'absence de toute course possible en production.
const test = require('node:test');
const assert = require('node:assert/strict');

const HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT = process.env.GCLOUD_PROJECT || '';
const skip = !HOST ? 'FIRESTORE_EMULATOR_HOST absent (émulateur Firestore requis)'
  : (!/^demo-/.test(PROJECT) || /az-express/.test(PROJECT) ? 'projet non « demo-* » : refus de tourner' : false);

if (!skip) {
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  const { HttpsError } = require('firebase-functions/v2/https');
  const db = admin.firestore();
  const { FieldValue } = admin.firestore;
  const { buildCreateOrderFromQuoteCF, createQuote } = require('../deliveryQuote');
  const { buildPayBoutiqueOrder, buildPayBoutiqueOrderCash } = require('../orderActions');

  const ROUNDS = 25;
  const outcomes = { guard: 0, contention: 0 };
  const CENTER = { lat: 6.7273, lng: -3.4961 };
  const DEST = { lat: 6.7453, lng: -3.4961 };
  const NOON = Date.UTC(2026, 5, 1, 12, 0);
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const committed = (snap) => BigInt(snap.createTime.seconds) * 1000000000n + BigInt(snap.createTime.nanoseconds);
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const dispatchOrder = async () => ({ dispatched: true });
  const create = buildCreateOrderFromQuoteCF({
    ...common, onCall: (h) => h.bind(null), now: () => NOON, newOrderId: (() => { let n = 0; return () => `qz90_o${Date.now()}_${n++}`; })(),
    resolveGeography: async () => ({ pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' }),
  });
  const payWallet = buildPayBoutiqueOrder({ ...common, onCall: (h) => h, dispatchOrder });
  const payCash = buildPayBoutiqueOrderCash({ ...common, onCall: (h) => h, dispatchOrder });
  const PAY = { productId: 'qz90_b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 };

  // Même forme que le moteur (accountDeletion.js) : lecture du profil, création du tombstone ET mise à jour du profil dans la
  // même transaction. Décalage aléatoire 0-80 ms pour couvrir des entrelacements différents.
  const quarantine = async (uid) => {
    await sleep(Math.floor(Math.random() * 80));
    return db.runTransaction(async (tx) => {
      await tx.get(db.collection('clients').doc(uid));
      tx.create(db.collection('account_tombstones').doc(uid), { createdAt: FieldValue.serverTimestamp(), state: 'deleting' });
      tx.update(db.collection('clients').doc(uid), { isSuspended: true, isOnline: false });
    });
  };
  const byClient = async (col, uid) => (await db.collection(col).where('clientId', '==', uid).get()).docs;
  const seedShop = async () => {
    await db.doc('config/billing').set({ separateDeliveryFee: 'accepted_only' });
    await db.doc('zones_livraison/abengourou').set({ type: 'ville', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7, lng: -3.5, radiusKm: 100 });
    await db.doc('zones_livraison/centre').set({ type: 'quartier', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7, lng: -3.5, radiusKm: 100 });
    await db.doc('sellers/qz90_s1').set({ wallet: 0, name: 'Vendeur', type: 'boutique', lat: 6.7, lng: -3.5 });
    await db.doc('boutique_products/qz90_b1').set({ sellerId: 'qz90_s1', name: 'Riz', category: 'A', price: 5000, stock: 1000 });
  };

  // Vérifie, pour une ronde, que rien n'est validé après le tombstone et que refus ⇒ aucun effet.
  async function checkRound({ uid, result, cols, walletBefore, debit }) {
    const tomb = await db.doc(`account_tombstones/${uid}`).get();
    assert.ok(tomb.exists, 'le tombstone est toujours créé');
    let docs = [];
    for (const c of cols) docs = docs.concat(await byClient(c, uid));
    for (const d of docs) assert.ok(committed(d) <= committed(tomb), `${uid}: commande validée après la quarantaine`);
    const wallet = (await db.doc(`clients/${uid}`).get()).data().wallet;
    if (result.status === 'rejected' || (result.value && result.value.success === false)) {
      // Le refus doit venir de la GARDE (motif de suppression), pas d'une autre cause (zone, stock, solde…).
      const msg = result.status === 'rejected' ? String(result.reason && result.reason.message) : JSON.stringify(result.value);
      if (/suppression/.test(msg)) outcomes.guard += 1;
      else if (/Transaction is invalid or closed|ABORTED|too much contention/.test(msg)) outcomes.contention += 1; // erreur de transaction de l'émulateur : échec sans effet (vérifié ci-dessous), JAMAIS compté comme refus de la garde
      else assert.fail(`refus pour un autre motif : ${msg}`);
      assert.equal(docs.length, 0, 'refus ⇒ aucune commande');
      assert.equal(wallet, walletBefore, 'refus ⇒ solde intact');
      return false;
    }
    assert.equal(wallet, walletBefore - debit, 'accepté ⇒ exactement un débit');
    return true;
  }

  test('Q1. createOrderFromQuote (wallet) contre quarantaine : aucune commande/débit validé APRÈS le tombstone', { skip }, async () => {
    let accepted = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz90_q1_${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 5000, name: 'T', phone: '+2250000000001' });
      const q = await createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST }, nowMs: NOON });
      const [r] = await Promise.allSettled([
        create({ auth: { uid }, data: { quoteId: q.data.quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'c' } } }),
        quarantine(uid),
      ]);
      if (await checkRound({ uid, result: r, cols: ['orders'], walletBefore: 5000, debit: 500 })) accepted += 1;
    }
    console.log(`  Q1: ${accepted} acceptées avant le tombstone, ${ROUNDS - accepted} refusées (garde : ${outcomes.guard}, erreur de contention émulateur : ${outcomes.contention})`); outcomes.guard = 0; outcomes.contention = 0;
  });

  test('Q2. payBoutiqueOrder (wallet) contre quarantaine : ni débit, ni stock, ni crédit vendeur après le tombstone', { skip }, async () => {
    await seedShop();
    let accepted = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz90_q2_${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 10000 });
      const stock0 = (await db.doc('boutique_products/qz90_b1').get()).data().stock;
      const sellerBefore = (await db.doc('sellers/qz90_s1').get()).data().wallet;
      const [r] = await Promise.allSettled([payWallet({ auth: { uid }, data: PAY }), quarantine(uid)]);
      const ok = await checkRound({ uid, result: r, cols: ['boutique_orders', 'orders'], walletBefore: 10000, debit: 5500 });
      const stock1 = (await db.doc('boutique_products/qz90_b1').get()).data().stock;
      const sellerAfter = (await db.doc('sellers/qz90_s1').get()).data().wallet;
      assert.equal(stock1, ok ? stock0 - 1 : stock0, 'stock cohérent avec le résultat');
      assert.equal(sellerAfter, ok ? sellerBefore + 5000 : sellerBefore, 'crédit vendeur cohérent avec le débit client');
      if (ok) accepted += 1;
    }
    console.log(`  Q2: ${accepted} acceptées avant le tombstone, ${ROUNDS - accepted} refusées (garde : ${outcomes.guard}, erreur de contention émulateur : ${outcomes.contention})`); outcomes.guard = 0; outcomes.contention = 0;
  });

  test('Q3. payBoutiqueOrderCash (espèces) contre quarantaine : aucune nouvelle commande ni stock retiré après le tombstone', { skip }, async () => {
    await seedShop();
    let accepted = 0;
    for (let i = 0; i < ROUNDS; i++) {
      const uid = `qz90_q3_${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 10000 });
      const stock0 = (await db.doc('boutique_products/qz90_b1').get()).data().stock;
      const [r] = await Promise.allSettled([payCash({ auth: { uid }, data: PAY }), quarantine(uid)]);
      const ok = await checkRound({ uid, result: r, cols: ['boutique_orders', 'orders'], walletBefore: 10000, debit: 0 });
      const stock1 = (await db.doc('boutique_products/qz90_b1').get()).data().stock;
      assert.equal(stock1, ok ? stock0 - 1 : stock0, 'stock cohérent avec le résultat');
      if (ok) accepted += 1;
    }
    console.log(`  Q3: ${accepted} acceptées avant le tombstone, ${ROUNDS - accepted} refusées (garde : ${outcomes.guard}, erreur de contention émulateur : ${outcomes.contention})`); outcomes.guard = 0; outcomes.contention = 0;
  });

  test('Q0. témoins SANS quarantaine : les trois flux aboutissent (un refus ultérieur vient donc bien de la garde)', { skip }, async () => {
    await seedShop();
    const uid = 'qz90_q0';
    await db.doc(`clients/${uid}`).set({ wallet: 20000, name: 'T', phone: '+2250000000001' });
    const q = await createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST }, nowMs: NOON });
    const a = await create({ auth: { uid }, data: { quoteId: q.data.quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'c' } } });
    assert.equal(a.success, true, JSON.stringify(a));
    assert.ok((await payWallet({ auth: { uid }, data: PAY })).orderId);
    assert.ok((await payCash({ auth: { uid }, data: PAY })).orderId);
    assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 20000 - 500 - 5500);
  });

  test('Q4. createOrderFromQuote : trois appels concurrents sur le MÊME devis → un seul débit, une seule commande', { skip }, async () => {
    for (let i = 0; i < 10; i++) {
      const uid = `qz90_q4_${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 5000, name: 'T', phone: '+2250000000001' });
      const q = await createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST }, nowMs: NOON });
      const body = { quoteId: q.data.quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'c' } };
      const res = await Promise.allSettled([1, 2, 3].map(() => create({ auth: { uid }, data: body })));
      const fresh = res.filter((x) => x.status === 'fulfilled' && x.value.success && !x.value.data.replayed);
      assert.equal(fresh.length, 1, 'une seule création effective');
      assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 4500, 'un seul débit');
      assert.equal((await byClient('orders', uid)).length, 1, 'une seule commande');
    }
  });

  test('Q5. payBoutiqueOrder : deux achats concurrents avec un solde pour un seul → un seul débit, jamais de solde négatif', { skip }, async () => {
    await seedShop();
    for (let i = 0; i < 10; i++) {
      const uid = `qz90_q5_${i}`;
      await db.doc(`clients/${uid}`).set({ wallet: 5500 });
      const res = await Promise.allSettled([payWallet({ auth: { uid }, data: PAY }), payWallet({ auth: { uid }, data: PAY })]);
      assert.equal(res.filter((x) => x.status === 'fulfilled').length, 1, 'un seul achat réussit');
      assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, 0);
      assert.equal((await byClient('boutique_orders', uid)).length, 1);
    }
  });
} else {
  // Sans émulateur, aucun scénario n'est enregistré : on le DIT (ignoré) plutôt que de compter un faux « réussi ».
  test('concurrence quarantaine/paiement (lot 2B) — émulateur Firestore requis', { skip }, () => {});
}
