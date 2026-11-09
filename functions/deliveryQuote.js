'use strict';

// quoteDeliveryCF + createOrderFromQuoteCF — Phase 1, locale, NON déployées, NON branchées dans index.js.
//
// Devis : document `tariff_quotes/{quoteId}` écrit uniquement par le serveur (Admin SDK).
// Il lie : client authentifié, service, mode, départ, destination (arrondis à 5 décimales ≈ 1 m),
// montant, version du barème, expiration, identifiant aléatoire non réutilisable (statut open → used).
//
// Création de commande : UNE transaction relit le devis, vérifie propriétaire / expiration / usage /
// correspondance, recalcule le tarif courant, lit le wallet, puis débite et crée la commande.
// Règle de confirmation : si le tarif courant dépasse le montant devisé (changement de barème, passage
// à la nuit), RIEN n'est débité : PRICE_CHANGED + nouveau montant à reconfirmer. Si le tarif courant est
// inférieur, le client paie le moindre des deux.

const crypto = require('crypto');
const { DEFAULT_TARIFF_CONFIG } = require('./tariffConfig');
const { computeOfficialTariff, validPoint } = require('./officialTariff');
const { assertNewAccountActivity } = require('./accountAdmission');

const coord = (n) => Math.round(n * 1e5) / 1e5;
const canonicalPoint = (p) => ({ lat: coord(p.lat), lng: coord(p.lng) });
const samePoint = (a, b) => !!a && !!b && coord(a.lat) === coord(b.lat) && coord(a.lng) === coord(b.lng);

// Champs de commande que le CLIENT peut fournir (liste blanche), alignés sur DeliveryOrderService.buildOrder
// (voir docs/TARIFF_ENGINE_PHASE1A.md). Posés par le SERVEUR, jamais par le client : montants, statut, paiement,
// clientId, clientName/clientPhone (lus dans clients/{uid}), coordonnées (issues du devis), villes et zones
// (résolues par resolveDispatchGeography sur la collection `zones_livraison`), horodatage.
const ORDER_DRAFT_FIELDS = Object.freeze([
  'description', 'deliveryAddress', 'pickupAddress',
  'pickupContactName', 'pickupContactPhone', 'recipientName', 'recipientPhone',
  'gpsDetectedCityId', 'activeCityId', 'citySelectionSource',
]);
// La description d'une course contient la liste d'articles : aucune limite côté règles Firestore, 500 la tronquerait.
const MAX_DESCRIPTION = 4000;
const PAYMENT_METHODS = Object.freeze(['wallet', 'cash']);
const COORDINATE_SOURCES = Object.freeze(['gps', 'map_pin', 'local_place', 'nominatim', 'google']);
// Seuls services dont la commande est créée par ce flux (frais de livraison + budget d'achat libre).
const SUPPORTED_SERVICES = Object.freeze({ livraison: 'livraison', courses: 'shopping' });

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });

function pickDraft(order) {
  const out = {};
  for (const k of ORDER_DRAFT_FIELDS) {
    const v = order && order[k];
    if (v === undefined || v === null) continue;
    if (typeof v === 'string') out[k] = v.slice(0, k === 'description' ? MAX_DESCRIPTION : 500);
    else if (typeof v === 'boolean') out[k] = v;
  }
  for (const k of ['pickupCoordinateSource', 'deliveryCoordinateSource']) {
    if (COORDINATE_SOURCES.includes(order && order[k])) out[k] = order[k];
  }
  return out;
}

function parseRequest(data) {
  const d = data || {};
  const pickup = d.pickup ? { lat: Number(d.pickup.lat), lng: Number(d.pickup.lng) } : null;
  const destination = d.destination ? { lat: Number(d.destination.lat), lng: Number(d.destination.lng) } : null;
  return {
    serviceType: String(d.serviceType || ''),
    mode: d.mode === undefined ? 'standard' : String(d.mode),
    pickup, destination,
    declaredDistanceKm: d.routeDistanceKm === undefined ? undefined : Number(d.routeDistanceKm),
  };
}

// Crée un devis. Aucune écriture financière. Retourne l'enveloppe de réponse.
async function createQuote({ db, admin, uid, data, nowMs = Date.now(), config = DEFAULT_TARIFF_CONFIG, randomId = () => crypto.randomUUID() }) {
  const req = parseRequest(data);
  if (!req.pickup || !validPoint(req.pickup)) return envelope(false, 'INVALID_COORDINATES', 'Coordonnées de départ invalides');
  if (!SUPPORTED_SERVICES[req.serviceType]) return envelope(false, 'SERVICE_NOT_SUPPORTED', 'Service non pris en charge par les devis');
  const r = computeOfficialTariff({ ...req, nowMs, config });
  if (!r.ok) return envelope(false, r.code, r.message);

  const quoteId = randomId();
  const expiresAtMs = nowMs + config.quote.ttlSeconds * 1000;
  await db.collection('tariff_quotes').doc(quoteId).create({
    uid, status: 'open', serviceType: req.serviceType, mode: r.mode,
    pickup: canonicalPoint(req.pickup), destination: canonicalPoint(req.destination),
    amount: r.amount, cityId: r.cityId, distanceKm: r.distanceKm, tariffVersion: r.tariffVersion,
    createdAtMs: nowMs, expiresAtMs,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return envelope(true, null, 'Devis créé', {
    quoteId, amount: r.amount, currency: config.currency, mode: r.mode, expiresAtMs,
    tariffVersion: r.tariffVersion, isNight: r.isNight, itemsPolicy: r.itemsPolicy,
  });
}

function buildQuoteDeliveryCF({ db, admin, onCall, HttpsError, checkRateLimit, loadConfig = async () => DEFAULT_TARIFF_CONFIG, now = () => Date.now() }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    await checkRateLimit(uid, 'quote_delivery', 30, 60);
    try { assertActiveClient(await db.collection('clients').doc(uid).get()); } catch (err) {
      if (err instanceof QuoteRefusal) return envelope(false, err.code, err.message);
      throw err;
    }
    return createQuote({ db, admin, uid, data: request.data, nowMs: now(), config: await loadConfig() });
  });
}

function assertActiveClient(snap) {
  if (!snap.exists) throw new QuoteRefusal('CLIENT_NOT_FOUND', 'Compte client introuvable');
  const c = snap.data() || {};
  if (c.deletionRequested === true || c.isDeleted === true) throw new QuoteRefusal('ACCOUNT_UNAVAILABLE', 'Compte indisponible');
}

class QuoteRefusal extends Error {
  constructor(code, message, data = null) { super(message); this.code = code; this.data = data; }
}

// Création transactionnelle : vérifie le devis puis débite le wallet et crée la commande.
const defaultGeography = (db, args) => require('./dispatch').resolveDispatchGeography(db, args);

function buildCreateOrderFromQuoteCF({ db, admin, onCall, HttpsError, checkRateLimit, logAudit, loadConfig = async () => DEFAULT_TARIFF_CONFIG, now = () => Date.now(), newOrderId = () => crypto.randomUUID(), resolveGeography = defaultGeography }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    const uid = request.auth.uid;
    const d = request.data || {};
    if (typeof d.quoteId !== 'string' || !d.quoteId || d.quoteId.includes('/')) throw new HttpsError('invalid-argument', 'quoteId manquant');
    // Mobile money (orange_money, mtn_money, wave...) n'est PAS pris en charge ici : refus explicite plutôt que traité comme du cash.
    if (!PAYMENT_METHODS.includes(d.paymentMethod)) return envelope(false, 'PAYMENT_METHOD_UNSUPPORTED', 'Mode de paiement non pris en charge par les devis');
    const paymentMethod = d.paymentMethod;
    await checkRateLimit(uid, 'create_order_from_quote', 10, 60);

    const config = await loadConfig();
    const nowMs = now();
    const orderId = newOrderId();
    if (d.shoppingBudget !== undefined && !(Number.isSafeInteger(d.shoppingBudget) && d.shoppingBudget >= 0)) {
      throw new HttpsError('invalid-argument', "Budget d'achat invalide");
    }
    const shopping = d.shoppingBudget || 0;
    if (shopping > config.quote.maxShoppingBudgetFcfa) throw new HttpsError('invalid-argument', 'Budget d\'achat trop élevé');

    // Géographie de dispatch dérivée du SERVEUR à partir des coordonnées du devis (jamais des villes envoyées par le client).
    // Lecture hors transaction (collection de référence), avant tout débit : une zone non desservie ne coûte rien.
    const quoteRef = db.collection('tariff_quotes').doc(d.quoteId);
    const preQuote = await quoteRef.get();
    let geography = null;
    if (preQuote.exists && preQuote.data().uid === uid && preQuote.data().status === 'open') {
      const pq = preQuote.data();
      try {
        geography = await resolveGeography(db, {
          pickupLat: pq.pickup.lat, pickupLng: pq.pickup.lng, deliveryLat: pq.destination.lat, deliveryLng: pq.destination.lng,
          pickupCoordinateSource: pickDraft(d.order).pickupCoordinateSource, deliveryCoordinateSource: pickDraft(d.order).deliveryCoordinateSource,
        });
      } catch (err) {
        if (err && err.code === 'outside-service') return envelope(false, 'OUTSIDE_SERVICE', err.message);
        throw err;
      }
    }
    const orderRef = db.collection('orders').doc(orderId);
    const clientRef = db.collection('clients').doc(uid);
    let charged = 0;
    let replay = null;

    try {
      await db.runTransaction(async (tx) => {
        const quoteSnap = await tx.get(quoteRef);
        const clientSnap = await tx.get(clientRef);
        const orderSnap = await tx.get(orderRef);
        if (!quoteSnap.exists) throw new QuoteRefusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        const q = quoteSnap.data();
        // Même message qu'un devis absent : on ne révèle pas l'existence du devis d'un autre client.
        if (q.uid !== uid) throw new QuoteRefusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        // Rejeu après réponse perdue : le MÊME client retrouve SA commande, sans nouveau débit ni nouvelle commande.
        if (q.status === 'used' && q.orderId) replay = { orderId: q.orderId, charged: q.chargedTotal || 0 };
        if (replay) return;
        if (q.status !== 'open') throw new QuoteRefusal('QUOTE_ALREADY_USED', 'Devis déjà utilisé');
        if (!geography) throw new QuoteRefusal('GEOGRAPHY_UNAVAILABLE', 'Zone de livraison indisponible, réessayez');
        if (!(q.expiresAtMs > nowMs)) throw new QuoteRefusal('QUOTE_EXPIRED', 'Devis expiré');
        if (orderSnap.exists) throw new QuoteRefusal('ORDER_EXISTS', 'Commande déjà créée');

        // Le client doit redonner les paramètres qu'il a devisés : départ, destination, service, mode.
        const dest = d.destination, pick = d.pickup;
        if (!samePoint(dest, q.destination) || !samePoint(pick, q.pickup)
          || String(d.serviceType) !== q.serviceType || (d.mode || 'standard') !== q.mode) {
          throw new QuoteRefusal('QUOTE_MISMATCH', 'La commande ne correspond pas au devis');
        }

        // Tarif courant (heure serveur) : jamais plus que le devis sans reconfirmation.
        const current = computeOfficialTariff({ serviceType: q.serviceType, mode: q.mode, pickup: q.pickup, destination: q.destination, nowMs, declaredDistanceKm: q.distanceKm, config });
        if (!current.ok) throw new QuoteRefusal(current.code, current.message);
        if (current.amount > q.amount) {
          throw new QuoteRefusal('PRICE_CHANGED', 'Le tarif a changé : nouvelle confirmation requise', { quotedAmount: q.amount, currentAmount: current.amount });
        }
        const fee = Math.min(q.amount, current.amount);
        if (Number.isFinite(d.confirmedAmount) && d.confirmedAmount < fee) {
          throw new QuoteRefusal('AMOUNT_NOT_CONFIRMED', 'Montant non confirmé', { amount: fee });
        }

        if (!SUPPORTED_SERVICES[q.serviceType]) throw new QuoteRefusal('SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
        // Seul un compte CLIENT actif crée une commande (un livreur ou un partenaire n'a pas de document clients/{uid}).
        assertActiveClient(clientSnap);
        // Mission 7E-90 (lot 2B) : tombstone relu DANS cette transaction, avant tout débit ou création (wallet comme espèces :
        // c'est une NOUVELLE commande). Le rejeu d'un devis déjà utilisé est sorti plus haut : il ne crée ni ne débite rien.
        await assertNewAccountActivity(tx, db, HttpsError, uid);
        const total = fee + shopping;
        if (paymentMethod === 'wallet') {
          const wallet = Number(clientSnap.data().wallet);
          if (!Number.isSafeInteger(wallet) || wallet < total) {
            throw new QuoteRefusal('SOLDE_INSUFFISANT', `SOLDE_INSUFFISANT:${Number.isFinite(wallet) ? wallet : 0}:${total}`);
          }
          tx.update(clientRef, { wallet: wallet - total, lastPaidOrderId: orderId });
          tx.set(clientRef.collection('wallet_transactions').doc(`order_${orderId}`), {
            type: 'payment', amount: total, description: `Paiement commande — livraison ${fee} FCFA`,
            orderId, provider: 'wallet', txId: `order_${orderId}`, createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        tx.create(orderRef, {
          ...pickDraft(d.order),
          clientId: uid, status: 'pending', type: SUPPORTED_SERVICES[q.serviceType], forSelf: true,
          clientName: clientSnap.exists ? (clientSnap.data().name || null) : null,
          clientPhone: clientSnap.exists ? (clientSnap.data().phone || null) : null,
          pickupCityId: geography.pickupCityId, deliveryCityId: geography.deliveryCityId,
          pickupZoneId: geography.pickupZoneId || null, deliveryZoneId: geography.deliveryZoneId || null,
          cityResolutionStatus: geography.cityResolutionStatus,
          serviceType: q.serviceType, deliveryMode: q.mode,
          budget: fee, shoppingBudget: shopping,
          paymentMethod, isPaid: paymentMethod === 'wallet',
          latitude: q.pickup.lat, longitude: q.pickup.lng, deliveryLatitude: q.pickup.lat, deliveryLongitude: q.pickup.lng,
          destLat: q.destination.lat, destLng: q.destination.lng,
          tariffQuoteId: d.quoteId, quotedAmount: q.amount, tariffVersion: q.tariffVersion,
          tariffCityId: q.cityId, tariffDistanceKm: q.distanceKm,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(quoteRef, { status: 'used', usedAtMs: nowMs, orderId, chargedTotal: paymentMethod === 'wallet' ? total : 0 });
        charged = paymentMethod === 'wallet' ? total : 0;
      });
    } catch (err) {
      if (err instanceof QuoteRefusal) {
        await logAudit({ action: 'create_order_from_quote_refused', userId: uid, targetId: d.quoteId, status: 'refused', metadata: { code: err.code } });
        return envelope(false, err.code, err.message, err.data);
      }
      throw err;
    }

    if (replay) return envelope(true, null, 'Commande déjà créée', { ...replay, replayed: true });
    await logAudit({ action: 'create_order_from_quote', userId: uid, targetId: orderId, status: 'success', amount: charged, metadata: { quoteId: d.quoteId, paymentMethod } });
    return envelope(true, null, 'Commande créée', { orderId, charged });
  });
}

module.exports = { createQuote, buildQuoteDeliveryCF, buildCreateOrderFromQuoteCF, ORDER_DRAFT_FIELDS };
