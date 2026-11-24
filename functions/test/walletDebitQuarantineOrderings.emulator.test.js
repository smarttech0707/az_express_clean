'use strict';

// Mission 7E-91 : ORDONNANCEMENTS contrôlés quarantaine ↔ création de commande payée (lot 2B), contre l'émulateur Firestore.
// Complète walletDebitQuarantine.emulator.test.js (dont la quarantaine précédait presque toujours la transaction pour la boutique).
// Quatre ordonnancements par fonction :
//   quarantine_first : la quarantaine est validée AVANT l'appel                       → refus attendu
//   call_first       : l'appel est validé AVANT la quarantaine                        → accepté attendu
//   during           : la quarantaine démarre PENDANT la transaction de l'appel, juste après la dernière lecture de la garde
//                      (profil/tombstone déjà lus), puis la transaction reste ouverte 0-120 ms                → accepté OU refusé
//   jitter           : décalage aléatoire de la quarantaine sur 0-1,6 × la durée d'un appel (mesurée)        → accepté OU refusé
// Exige FIRESTORE_EMULATOR_HOST et un projet « demo-* » : ignoré sinon. Données synthétiques, aucun appel réseau.
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

  const CENTER = { lat: 6.7273, lng: -3.4961 };
  const DEST = { lat: 6.7453, lng: -3.4961 };
  const NOON = Date.UTC(2026, 5, 1, 12, 0);
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const committed = (snap) => BigInt(snap.createTime.seconds) * 1000000000n + BigInt(snap.createTime.nanoseconds);
  const origRun = db.runTransaction.bind(db);

  // Crochet « pendant » : dans la transaction de l'APPEL (jamais celle de la quarantaine, qui passe par origRun), une fois le
  // tombstone lu puis le dernier document de la garde lu, on lance la quarantaine sans l'attendre et on garde la transaction ouverte.
  let hook = null;
  db.runTransaction = (cb, opts) => origRun(async (tx) => {
    const h = hook;
    if (!h) return cb(tx);
    let seenTombstone = false;
    return cb({
      get: async (r) => {
        const out = await tx.get(r);
        if (r.path === `account_tombstones/${h.uid}`) seenTombstone = true;
        else if (seenTombstone && r.path === h.afterPath && !h.fired) {
          h.fired = true;
          h.quarantine = quarantineNow(h.uid);
          await sleep(h.wait);
        }
        return out;
      },
      create: (...a) => tx.create(...a), update: (...a) => tx.update(...a), set: (...a) => tx.set(...a),
    });
  }, opts);

  // Même forme que le moteur (accountDeletion.js) : lecture du profil, création du tombstone ET mise à jour du profil dans la
  // même transaction. Réessayée si l'émulateur rejette la transaction de quarantaine elle-même (défaut du harnais, pas du test).
  const quarantineNow = async (uid) => {
    for (let i = 0; i < 4; i++) {
      try {
        return await origRun(async (tx) => {
          await tx.get(db.collection('clients').doc(uid));
          tx.create(db.collection('account_tombstones').doc(uid), { createdAt: FieldValue.serverTimestamp(), state: 'deleting' });
          tx.update(db.collection('clients').doc(uid), { isSuspended: true, isOnline: false });
        });
      } catch (err) {
        if ((await db.doc(`account_tombstones/${uid}`).get()).exists) return undefined;
        if (i === 3) throw err;
        await sleep(20);
      }
    }
    return undefined;
  };

  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const dispatchOrder = async () => ({ dispatched: true });
  let oid = 0;
  const quoteFn = buildCreateOrderFromQuoteCF({
    ...common, onCall: (h) => h, now: () => NOON, newOrderId: () => `qz91_o${Date.now()}_${oid++}`,
    resolveGeography: async () => ({ pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' }),
  });
  const walletFn = buildPayBoutiqueOrder({ ...common, onCall: (h) => h, dispatchOrder });
  const cashFn = buildPayBoutiqueOrderCash({ ...common, onCall: (h) => h, dispatchOrder });

  const SCN = {
    quote: { debit: 500, wallet: 10000, cols: ['orders'] },
    wallet: { debit: 5500, wallet: 10000, cols: ['boutique_orders', 'orders'] },
    cash: { debit: 0, wallet: 10000, cols: ['boutique_orders', 'orders'] },
  };

  async function seedShop(name) {
    await db.doc('config/billing').set({ separateDeliveryFee: 'accepted_only' });
    for (const [id, type] of [['abengourou', 'ville'], ['centre', 'quartier']]) {
      await db.doc(`zones_livraison/${id}`).set({ type, cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7, lng: -3.5, radiusKm: 100 });
    }
    await db.doc(`sellers/qz91_${name}_s`).set({ wallet: 0, name: 'Vendeur', type: 'boutique', lat: 6.7, lng: -3.5 });
    await db.doc(`boutique_products/qz91_${name}_p`).set({ sellerId: `qz91_${name}_s`, name: 'Riz', category: 'A', price: 5000, stock: 100000 });
  }

  // Prépare un client (et un devis pour « quote »), renvoie le lanceur de l'appel et le dernier chemin lu par la garde.
  async function prepare(name, uid) {
    await db.doc(`clients/${uid}`).set({ wallet: SCN[name].wallet, name: 'T', phone: '+2250000000001' });
    if (name === 'quote') {
      const q = await createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST }, nowMs: NOON });
      const data = { quoteId: q.data.quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'c' } };
      return { run: () => quoteFn({ auth: { uid }, data }), afterPath: `clients/${uid}`, data };
    }
    const data = { productId: `qz91_${name}_p`, qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 };
    const fn = name === 'wallet' ? walletFn : cashFn;
    return { run: () => fn({ auth: { uid }, data }), afterPath: name === 'wallet' ? `sellers/qz91_${name}_s` : `clients/${uid}`, data };
  }

  const stats = {};
  const tally = (name, mode, key) => { const k = `${name}/${mode}`; stats[k] = stats[k] || { accepted: 0, guard: 0, contention: 0 }; stats[k][key] += 1; };
  const totals = {};

  // Vérifie les invariants d'une ronde et renvoie 'accepted' | 'guard' | 'contention'.
  async function check(name, mode, uid, r, walletBefore) {
    const spec = SCN[name];
    const tomb = await db.doc(`account_tombstones/${uid}`).get();
    assert.ok(tomb.exists, `${uid}: le tombstone est toujours créé`);
    let docs = [];
    for (const c of spec.cols) docs = docs.concat((await db.collection(c).where('clientId', '==', uid).get()).docs);
    for (const d of docs) assert.ok(committed(d) <= committed(tomb), `${name}/${mode}/${uid}: document validé APRÈS la quarantaine`);
    const wallet = (await db.doc(`clients/${uid}`).get()).data().wallet;
    const refused = r.status === 'rejected' || (r.value && r.value.success === false);
    if (refused) {
      const msg = r.status === 'rejected' ? String(r.reason && r.reason.message) : JSON.stringify(r.value);
      let kind;
      if (/suppression/.test(msg)) kind = 'guard';
      else if (/Transaction is invalid or closed/.test(msg)) kind = 'contention'; // échec SANS effet (vérifié ci-dessous), jamais compté comme refus de la garde
      else assert.fail(`${name}/${mode}/${uid}: refus pour un autre motif : ${msg}`);
      assert.equal(docs.length, 0, `${name}/${mode}/${uid}: refus ⇒ aucune commande`);
      assert.equal(wallet, walletBefore, `${name}/${mode}/${uid}: refus ⇒ solde intact`);
      tally(name, mode, kind);
      return kind;
    }
    assert.equal(wallet, walletBefore - spec.debit, `${name}/${mode}/${uid}: accepté ⇒ exactement un débit`);
    assert.equal(docs.length, name === 'quote' ? 1 : 2, `${name}/${mode}/${uid}: accepté ⇒ exactement une commande (boutique : achat + course)`);
    tally(name, mode, 'accepted');
    return 'accepted';
  }

  async function tracker(name) {
    if (name === 'quote') return { read: async () => ({}) };
    return { read: async () => ({ stock: (await db.doc(`boutique_products/qz91_${name}_p`).get()).data().stock, seller: (await db.doc(`sellers/qz91_${name}_s`).get()).data().wallet }) };
  }

  // Cohérence globale d'un scénario : stock retiré, crédit vendeur et commandes = nombre d'acceptations (aucun double retrait).
  async function globalCheck(name, before, accepted) {
    if (name === 'quote') return;
    const after = await (await tracker(name)).read();
    assert.equal(before.stock - after.stock, accepted, `${name}: stock retiré = nombre d'acceptations (aucun double retrait)`);
    assert.equal(after.seller - before.seller, name === 'wallet' ? accepted * 5000 : 0, `${name}: crédit vendeur cohérent avec les débits clients`);
  }

  async function measure(name) {
    const times = [];
    for (let i = 0; i < 3; i++) {
      const uid = `qz91_cal_${name}_${Date.now()}_${i}`;
      const p = await prepare(name, uid);
      const t0 = Date.now();
      await p.run();
      times.push(Date.now() - t0);
    }
    return times.sort((a, b) => a - b)[1];
  }

  for (const name of ['quote', 'wallet', 'cash']) {
    const N = { quarantine_first: 12, call_first: 12, during: 25, jitter: 25 };
    test(`O-${name}. ordonnancements contrôlés quarantaine/paiement (${Object.values(N).reduce((a, b) => a + b, 0)} rondes)`, { skip, timeout: 540000 }, async () => {
      if (name !== 'quote') await seedShop(name);
      const before = await (await tracker(name)).read();
      const T = await measure(name);
      let accepted = 0; // hors calibration
      const calibrationAccepted = 3;
      const calBefore = { ...before };
      if (name !== 'quote') { calBefore.stock = before.stock; }
      for (const mode of Object.keys(N)) {
        for (let i = 0; i < N[mode]; i++) {
          const uid = `qz91_${name}_${mode}_${Date.now()}_${i}`;
          const p = await prepare(name, uid);
          const walletBefore = SCN[name].wallet;
          let r;
          if (mode === 'quarantine_first') {
            await quarantineNow(uid);
            [r] = await Promise.allSettled([p.run()]);
          } else if (mode === 'call_first') {
            [r] = await Promise.allSettled([p.run()]);
            await quarantineNow(uid);
          } else if (mode === 'during') {
            hook = { uid, afterPath: p.afterPath, wait: Math.floor(Math.random() * 120), fired: false, quarantine: null };
            [r] = await Promise.allSettled([p.run()]);
            const h = hook; hook = null;
            if (h.fired) await h.quarantine; else await quarantineNow(uid); // crochet non atteint (refus avant la garde) : quarantaine après
            assert.ok(h.fired || r.status === 'rejected' || r.value, 'crochet');
          } else {
            const delay = Math.floor(Math.random() * T * 1.6);
            const q = (async () => { await sleep(delay); return quarantineNow(uid); })();
            [r] = await Promise.allSettled([p.run()]);
            await q;
          }
          const kind = await check(name, mode, uid, r, walletBefore);
          if (mode === 'quarantine_first') assert.equal(kind, 'guard', `${name}: quarantaine validée avant l'appel ⇒ refus par la garde`);
          if (mode === 'call_first') assert.equal(kind, 'accepted', `${name}: appel validé avant la quarantaine ⇒ accepté`);
          if (kind === 'accepted') accepted += 1;

          // Nouvelle tentative après la quarantaine : jamais d'effet supplémentaire ; devis déjà utilisé ⇒ même commande, même solde.
          const walletAfter = (await db.doc(`clients/${uid}`).get()).data().wallet;
          if (name === 'quote' && kind === 'accepted') {
            const again = await p.run();
            assert.equal(again.success, true);
            assert.equal(again.data.replayed, true, 'rejeu d\'un devis utilisé : même commande');
            assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, walletAfter, 'rejeu : aucun nouveau débit');
          } else if (kind !== 'accepted') {
            const [again] = await Promise.allSettled([p.run()]);
            assert.ok(again.status === 'rejected' || again.value.success === false, 'nouvelle tentative après refus : toujours refusée');
            assert.equal((await db.doc(`clients/${uid}`).get()).data().wallet, walletAfter, 'nouvelle tentative : solde intact');
          }
        }
      }
      // La calibration (3 appels sans quarantaine) retire aussi du stock : on l'ajoute au compte attendu.
      await globalCheck(name, before, accepted + calibrationAccepted * (name === 'quote' ? 0 : 1));
      totals[name] = stats;
      const lines = Object.keys(N).map((m) => `${m}: ${JSON.stringify(stats[`${name}/${m}`] || {})}`);
      console.log(`  O-${name} (durée d'un appel ≈ ${T} ms) → ${lines.join(' | ')}`);
      // Les deux côtés de la course doivent avoir été exercés.
      const during = stats[`${name}/during`] || {}; const jit = stats[`${name}/jitter`] || {};
      assert.ok((during.accepted || 0) + (jit.accepted || 0) > 0, `${name}: aucun ordonnancement « accepté » dans during/jitter`);
      assert.ok((during.guard || 0) + (jit.guard || 0) + (during.contention || 0) + (jit.contention || 0) > 0, `${name}: aucun ordonnancement « refusé » dans during/jitter`);
    });
  }
} else {
  // Sans émulateur, aucun scénario n'est enregistré : on le DIT (ignoré) plutôt que de compter un faux « réussi ».
  test('ordonnancements quarantaine/paiement (lot 2B) — émulateur Firestore requis', { skip }, () => {});
}
