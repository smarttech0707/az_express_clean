'use strict';

// Harnais partagé des tests de facturation Marketplace / Boutique : vraies
// fonctions (création, acceptation, livraison, annulation, remboursement,
// examen administratif) sur un faux Firestore.
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildAcceptOrder } = require('../driverAcceptance');
const { withSelfie } = require('./selfieHelper');
const {
  buildDeliverOrder, buildCancelOrder, buildPayBoutiqueOrder,
  buildPayBoutiqueOrderCash, buildRefundExpiredBoutiqueOrder,
} = require('../orderActions');
const { calculateCommission } = require('../dispatch');
const { buildAdminBilling } = require('../adminBilling');
const { createMarketplaceOrder } = require('../azia/tools/marketplace');
const tarifService = require('../tarifService');
const { buildAmounts, readAmounts } = require('../orderAmounts');

const ts = (ms) => ({ toMillis: () => ms });
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: {
      serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion,
      increment: (n) => ({ __increment: n }),
    },
  },
};
const oc = (...a) => ({ run: a[a.length - 1] });
const fresh = () => ({ toMillis: () => Date.now() - 1000 });
const driver = (extra = {}) => ({
  wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou',
  lat: 6.74, lng: -3.49, updatedAt: fresh(), ...extra,
});
const zones = {
  'zones_livraison/abengourou': {
    type: 'ville', cityId: 'abengourou', isActive: true, isServiceable: true,
    coordinateSource: 'own', lat: 6.7, lng: -3.5, radiusKm: 100,
  },
  'zones_livraison/centre': {
    type: 'quartier', cityId: 'abengourou', isActive: true, isServiceable: true,
    coordinateSource: 'own', lat: 6.7, lng: -3.5, radiusKm: 100,
  },
};

// fakeDb sans identifiant automatique pour doc() : on en génère un.
function world(seed = {}) {
  const db = fakeDb({
    ...zones,
    'clients/c1': { wallet: 10000 },
    'admins/root': { role: 'super', isActive: true },
    'sellers/s1': { wallet: 0, name: 'Vendeur', type: 'boutique', lat: 6.7, lng: -3.5 },
    'livreurs/dA': driver(),
    'marketplace_products/p1': { status: 'active', title: 'Téléviseur', price: 5000, sellerId: 's1', sellerName: 'Vendeur' },
    'boutique_products/b1': { sellerId: 's1', name: 'Riz', category: 'A', price: 5000, stock: 10 },
    ...seed,
  });
  let n = 0;
  const original = db.collection;
  db.collection = (name) => {
    const c = original(name);
    const doc = c.doc;
    c.doc = (id) => doc(id ?? `gen${n++}`);
    return c;
  };
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const dispatchOrder = async () => ({ dispatched: true });
  const fns = {
    accept: withSelfie(buildAcceptOrder({ ...common, onCall: oc, calculateCommission }).run),
    deliver: buildDeliverOrder({ ...common, onCall: oc }).run,
    cancel: buildCancelOrder({ ...common, onCall: oc, calculateCommission }).run,
    payBoutique: buildPayBoutiqueOrder({ ...common, onCall: oc, dispatchOrder }).run,
    payBoutiqueCash: buildPayBoutiqueOrderCash({ ...common, onCall: oc, dispatchOrder }).run,
    refund: buildRefundExpiredBoutiqueOrder({ ...common, onCall: oc }).run,
    adminBilling: buildAdminBilling({
      ...common, onCall: oc, calculateCommission,
      requireSuperAdmin: async ({ request }) => {
        if (request.auth.uid !== 'root') throw new HttpsError('permission-denied', 'non');
      },
    }).run,
  };
  const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const h = {
    db,
    get: (p) => db.store.get(p),
    set: (p, v) => db.store.set(p, v),
    w: (p) => db.store.get(p).wallet,
    call: (name, uid, data) => fns[name](req(uid, data)),
    keys: (prefix) => [...db.store.keys()].filter((k) => k.startsWith(prefix)),
    commissionsLogged: () => [...db.store.entries()]
      .filter(([k]) => k.startsWith('commissions/')).reduce((s, [, v]) => s + v.amount, 0),
    mode: (m) => db.store.set('config/billing', { ...(db.store.get('config/billing') || {}), separateDeliveryFee: m }),
    // Politique des commandes historiques (legacyPartnerPolicy.js) : 'block' (défaut) | 'no_commission'.
    legacyPolicy: (p) => db.store.set('config/billing', { ...(db.store.get('config/billing') || {}), legacyPartnerAcceptance: p }),
    totalMoney: () => ['clients/c1', 'sellers/s1', 'livreurs/dA']
      .reduce((s, p) => s + db.store.get(p).wallet, 0),
    // Marketplace : crée la commande avec les vrais confirmHandler / afterConfirm.
    async marketplace({ productAmount = 5000, deliveryFee = 500, paymentMethod = 'wallet' } = {}) {
      const tool = createMarketplaceOrder({ db, admin, HttpsError });
      const amounts = buildAmounts(productAmount, deliveryFee);
      const result = await db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
        productId: 'p1', quantity: 1, ...amounts, title: 'Téléviseur',
        sellerId: 's1', sellerName: 'Vendeur', pickupLat: 6.7, pickupLng: -3.5,
        deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod,
      }));
      return result.orderId;
    },
    // Le dispatch attribue la course à dA (état 'assigned', comme en production).
    assign(orderId) {
      h.set(`orders/${orderId}`, { ...h.get(`orders/${orderId}`), status: 'assigned', driverId: 'dA', pickupCityId: 'abengourou' });
    },
    pickUp(orderId) {
      h.set(`orders/${orderId}`, { ...h.get(`orders/${orderId}`), status: 'picked_up' });
    },
  };
  return h;
}

const photo = 'https://x/p.jpg';


module.exports = { world, photo, ts, admin, HttpsError };
