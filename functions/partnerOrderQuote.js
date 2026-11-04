'use strict';

// quotePartnerOrderCF + createPartnerOrderFromQuoteCF — Mission 7B-1, locales, NON utilisées en production.
//
// Commandes STANDARD Restaurant / Boulangerie (hors gâteau sur mesure). Même architecture que les devis de livraison
// (deliveryQuote.js, Mission 2) et les devis catalogue (catalogQuote.js, Mission 6) :
//   - le client envoie des CHOIX (partenaire, articles, quantités, point de livraison), jamais un montant ;
//   - le serveur relit les prix et la disponibilité dans Firestore, calcule les frais avec le barème officiel et pose
//     productAmount / deliveryFee / totalAmount ;
//   - le devis (`tariff_quotes`, Admin SDK uniquement) est lié au client, expire, ne sert qu'une fois ;
//   - la création relit TOUT dans une même transaction : jamais plus que le devis sans reconfirmation, wallet débité du
//     total exact, journal déterministe `order_<orderId>`, rejeu du même devis = même commande.
//
// Contrat de la commande créée (amountsVersion 2, voir partnerOrderAmounts.js) :
//   budget = deliveryFee (commission d'acceptation et dispatch inchangés) ; shoppingBudget = 0 ; productAmount revient
//   au partenaire ; totalAmount = ce que le client paie. AUCUN crédit partenaire ni livreur à la création.
//
// INTERRUPTEUR : sans PARTNER_ORDERS_V2=on, les deux fonctions refusent (FEATURE_DISABLED). Elles ne doivent pas servir
// avant l'adaptation de deliverOrderCF et cancelOrderTx aux commandes version 2 (Mission 7B-2) : aujourd'hui
// deliverOrderCF créditerait le partenaire de `budget` (= les frais) et cancelOrderTx ne rembourserait que `budget`.

const crypto = require('crypto');
const { DEFAULT_TARIFF_CONFIG } = require('./tariffConfig');
const { computeOfficialTariff, validPoint } = require('./officialTariff');
const { assertNewAccountActivity } = require('./accountAdmission');
const { buildPartnerAmounts } = require('./partnerOrderAmounts');
const { creationEnabled, loadPilotConfig, parsePilotConfig, v2CreationAllowed } = require('./partnerOrdersConfig');
const {
  PARTNER_KINDS, PartnerRefusal, parseItems, partnerRefusal, partnerPoint, priceItems, itemsFingerprint,
} = require('./partnerCatalog');

const PAYMENT_METHODS = Object.freeze(['wallet', 'cash']);
const COORDINATE_SOURCES = Object.freeze(['gps', 'map_pin', 'local_place', 'nominatim', 'google']);

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });
const coord = (n) => Math.round(n * 1e5) / 1e5;
const canonicalPoint = (p) => ({ lat: coord(p.lat), lng: coord(p.lng) });
const samePoint = (a, b) => !!a && !!b && coord(a.lat) === coord(b.lat) && coord(a.lng) === coord(b.lng);
// Interrupteur de CRÉATION (partnerOrdersConfig.js) : la gestion des commandes existantes est un autre interrupteur.
const defaultEnabled = creationEnabled;
const defaultGeography = (db, args) => require('./dispatch').resolveDispatchGeography(db, args);

function text(value, { max, required = false, field }) {
  if (value === undefined || value === null || value === '') {
    if (required) throw new PartnerRefusal('INVALID_FIELD', `Champ requis : ${field}`);
    return '';
  }
  if (typeof value !== 'string') throw new PartnerRefusal('INVALID_FIELD', `Champ invalide : ${field}`);
  const v = value.trim();
  if (required && !v) throw new PartnerRefusal('INVALID_FIELD', `Champ requis : ${field}`);
  return v.slice(0, max);
}

function requireClientAuth(request, HttpsError) {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  // Cohérent avec les règles de création de commande (isRealUser) : pas de compte anonyme.
  if (request.auth.token?.firebase?.sign_in_provider === 'anonymous') throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  return request.auth.uid;
}

function assertActiveClient(snap) {
  if (!snap.exists) throw new PartnerRefusal('CLIENT_NOT_FOUND', 'Compte client introuvable');
  const c = snap.data() || {};
  if (c.deletionRequested === true || c.isDeleted === true) throw new PartnerRefusal('ACCOUNT_UNAVAILABLE', 'Compte indisponible');
}

function parseChoices(d) {
  const sellerType = d.sellerType;
  if (typeof sellerType !== 'string' || !Object.prototype.hasOwnProperty.call(PARTNER_KINDS, sellerType)) {
    throw new PartnerRefusal('SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
  }
  const sellerId = d.sellerId;
  if (typeof sellerId !== 'string' || !sellerId || sellerId.length > 128 || sellerId.includes('/')) {
    throw new PartnerRefusal('INVALID_PARTNER', 'Partenaire invalide');
  }
  const items = parseItems(d.items);
  const destination = d.destination ? { lat: Number(d.destination.lat), lng: Number(d.destination.lng) } : null;
  if (!destination || !validPoint(destination)) throw new PartnerRefusal('INVALID_COORDINATES', 'Coordonnées de livraison invalides');
  // Les restaurants et boulangeries n'utilisent aujourd'hui que le tarif standard : aucun nouveau mode commercial.
  if (d.mode !== undefined && d.mode !== 'standard') throw new PartnerRefusal('INVALID_MODE', 'Mode de livraison invalide');
  const declared = d.routeDistanceKm === undefined ? undefined : Number(d.routeDistanceKm);
  return { sellerType, sellerId, items, destination, declaredDistanceKm: declared };
}

async function readPartnerAndMenu(read, kind, sellerId, items) {
  const cfg = PARTNER_KINDS[kind];
  const partnerSnap = await read(cfg.collection, sellerId);
  const menuSnaps = await Promise.all(items.map((it) => read(`${cfg.collection}/${sellerId}/${cfg.menu}`, it.itemId)));
  const menu = new Map(items.map((it, i) => [it.itemId, menuSnaps[i].exists ? menuSnaps[i].data() : null]));
  return { partnerSnap, partner: partnerSnap.exists ? partnerSnap.data() : null, menu };
}

// ── quotePartnerOrderCF ────────────────────────────────────────────────────
function buildQuotePartnerOrderCF({
  db, admin, onCall, HttpsError, checkRateLimit, loadConfig = async () => DEFAULT_TARIFF_CONFIG,
  now = () => Date.now(), randomId = () => crypto.randomUUID(), isEnabled = defaultEnabled, loadPilot = () => loadPilotConfig(db),
}) {
  return onCall(async (request) => {
    const uid = requireClientAuth(request, HttpsError);
    if (!isEnabled()) return envelope(false, 'FEATURE_DISABLED', 'Fonction non activée');
    const d = request.data || {};
    await checkRateLimit(uid, 'quote_partner_order', 30, 60);
    try {
      const c = parseChoices(d);
      assertActiveClient(await db.collection('clients').doc(uid).get());
      // Activation progressive : si une liste pilote existe, seuls ces partenaires acceptent des commandes v2.
      if (!v2CreationAllowed(await loadPilot(), c.sellerId)) throw new PartnerRefusal('PARTNER_NOT_IN_PILOT', 'Ce partenaire n’accepte pas encore ce type de commande');
      const read = (collection, id) => db.collection(collection).doc(id).get();
      const { partner, menu } = await readPartnerAndMenu(read, c.sellerType, c.sellerId, c.items);
      const nowMs = now();
      const refusal = partnerRefusal(c.sellerType, partner, nowMs);
      if (refusal) throw new PartnerRefusal(refusal.code, refusal.message);
      const pickup = partnerPoint(partner);
      if (!pickup) throw new PartnerRefusal('PARTNER_LOCATION_MISSING', 'Les coordonnées du partenaire ne sont pas renseignées');

      const { lines, productAmount } = priceItems(c.sellerType, c.items, menu);
      const config = await loadConfig();
      const tariff = computeOfficialTariff({
        serviceType: c.sellerType, mode: 'standard', pickup, destination: c.destination, nowMs,
        declaredDistanceKm: c.declaredDistanceKm, config,
      });
      if (!tariff.ok) throw new PartnerRefusal(tariff.code, tariff.message);
      const amounts = buildPartnerAmounts(productAmount, tariff.deliveryFee);

      const quoteId = randomId();
      const expiresAtMs = nowMs + config.quote.ttlSeconds * 1000;
      const sellerName = typeof partner.name === 'string' && partner.name.trim() ? partner.name.trim().slice(0, 120) : '';
      await db.collection('tariff_quotes').doc(quoteId).create({
        kind: 'partner', uid, status: 'open',
        sellerType: c.sellerType, sellerId: c.sellerId, sellerName,
        items: c.items, lines, fingerprint: itemsFingerprint(lines),
        productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee, amount: amounts.totalAmount,
        mode: 'standard', pickup: canonicalPoint(pickup), destination: canonicalPoint(c.destination),
        cityId: tariff.cityId, distanceKm: tariff.distanceKm, tariffVersion: tariff.tariffVersion,
        createdAtMs: nowMs, expiresAtMs,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return envelope(true, null, 'Devis créé', {
        quoteId, sellerType: c.sellerType, sellerId: c.sellerId, sellerName, lines,
        productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee, total: amounts.totalAmount,
        currency: config.currency, expiresAtMs, tariffVersion: tariff.tariffVersion, isNight: tariff.isNight,
      });
    } catch (err) {
      if (err instanceof PartnerRefusal) return envelope(false, err.code, err.message, err.data);
      throw err;
    }
  });
}

// ── createPartnerOrderFromQuoteCF ──────────────────────────────────────────
function buildCreatePartnerOrderFromQuoteCF({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, loadConfig = async () => DEFAULT_TARIFF_CONFIG,
  now = () => Date.now(), newOrderId = () => crypto.randomUUID(), resolveGeography = defaultGeography, isEnabled = defaultEnabled,
}) {
  return onCall(async (request) => {
    const uid = requireClientAuth(request, HttpsError);
    if (!isEnabled()) return envelope(false, 'FEATURE_DISABLED', 'Fonction non activée');
    const d = request.data || {};
    if (typeof d.quoteId !== 'string' || !d.quoteId || d.quoteId.includes('/')) throw new HttpsError('invalid-argument', 'quoteId manquant');
    // Mobile money n'est pas pris en charge : refus explicite plutôt que traité comme du cash.
    if (!PAYMENT_METHODS.includes(d.paymentMethod)) return envelope(false, 'PAYMENT_METHOD_UNSUPPORTED', 'Mode de paiement non pris en charge');
    const paymentMethod = d.paymentMethod;
    await checkRateLimit(uid, 'create_partner_order', 10, 60);

    let choices; let deliveryAddress; let notes; let requestedTime;
    try {
      choices = parseChoices(d);
      deliveryAddress = text(d.deliveryAddress, { max: 300, required: true, field: 'adresse de livraison' });
      notes = text(d.notes, { max: 500, field: 'notes' });
      requestedTime = text(d.requestedTime, { max: 30, field: 'heure souhaitée' });
    } catch (err) {
      if (err instanceof PartnerRefusal) return envelope(false, err.code, err.message, err.data);
      throw err;
    }
    const deliverySource = COORDINATE_SOURCES.includes(d.deliveryCoordinateSource) ? d.deliveryCoordinateSource : 'gps';

    const config = await loadConfig();
    const nowMs = now();
    const orderId = newOrderId();
    const quoteRef = db.collection('tariff_quotes').doc(d.quoteId);
    const orderRef = db.collection('orders').doc(orderId);
    const clientRef = db.collection('clients').doc(uid);

    // Géographie de dispatch dérivée du SERVEUR à partir des coordonnées du devis, avant tout débit.
    const preQuote = await quoteRef.get();
    let geography = null;
    if (preQuote.exists && preQuote.data().uid === uid && preQuote.data().kind === 'partner' && preQuote.data().status === 'open') {
      const pq = preQuote.data();
      try {
        geography = await resolveGeography(db, {
          pickupLat: pq.pickup.lat, pickupLng: pq.pickup.lng, deliveryLat: pq.destination.lat, deliveryLng: pq.destination.lng,
          pickupCoordinateSource: 'local_place', deliveryCoordinateSource: deliverySource,
        });
      } catch (err) {
        if (err && err.code === 'outside-service') return envelope(false, 'OUTSIDE_SERVICE', err.message);
        throw err;
      }
    }

    let replay = null;
    let charged = 0;
    let finalAmounts = null;
    try {
      await db.runTransaction(async (tx) => {
        // Toutes les lectures d'abord (Firestore interdit une lecture après une écriture).
        const quoteSnap = await tx.get(quoteRef);
        const clientSnap = await tx.get(clientRef);
        const orderSnap = await tx.get(orderRef);
        const pilotSnap = await tx.get(db.collection('config').doc('partnerOrdersV2'));
        if (!quoteSnap.exists) throw new PartnerRefusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        const q = quoteSnap.data();
        // Même réponse qu'un devis absent : on ne révèle ni le devis d'un autre client ni celui d'un autre type.
        if (q.uid !== uid || q.kind !== 'partner') throw new PartnerRefusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        // Rejeu après réponse perdue / double appui : le MÊME client retrouve SA commande, sans second débit.
        if (q.status === 'used' && q.orderId) { replay = { orderId: q.orderId, charged: q.chargedTotal || 0 }; return; }
        if (q.status !== 'open') throw new PartnerRefusal('QUOTE_ALREADY_USED', 'Devis déjà utilisé');
        if (!(q.expiresAtMs > nowMs)) throw new PartnerRefusal('QUOTE_EXPIRED', 'Devis expiré');
        if (orderSnap.exists) throw new PartnerRefusal('ORDER_EXISTS', 'Commande déjà créée');
        if (!v2CreationAllowed(parsePilotConfig(pilotSnap.exists ? pilotSnap.data() : null), q.sellerId)) {
          throw new PartnerRefusal('PARTNER_NOT_IN_PILOT', 'Ce partenaire n’accepte pas encore ce type de commande');
        }
        if (!geography) throw new PartnerRefusal('GEOGRAPHY_UNAVAILABLE', 'Zone de livraison indisponible, réessayez');
        // Le document de devis n'a pas été altéré (il n'est inscriptible que par le serveur ; défense en profondeur).
        if (!Array.isArray(q.lines) || itemsFingerprint(q.lines) !== q.fingerprint) throw new PartnerRefusal('QUOTE_CORRUPTED', 'Devis invalide');

        // La commande doit correspondre EXACTEMENT à ce qui a été devisé.
        if (q.sellerType !== choices.sellerType || q.sellerId !== choices.sellerId
          || JSON.stringify(q.items) !== JSON.stringify(choices.items)
          || !samePoint(choices.destination, q.destination)) {
          throw new PartnerRefusal('QUOTE_MISMATCH', 'La commande ne correspond pas au devis');
        }

        // Relecture des prix, de la disponibilité et du partenaire DANS la transaction.
        const read = (collection, id) => tx.get(db.collection(collection).doc(id));
        const { partner, menu } = await readPartnerAndMenu(read, q.sellerType, q.sellerId, q.items);
        const refusal = partnerRefusal(q.sellerType, partner, nowMs);
        if (refusal) throw new PartnerRefusal(refusal.code, refusal.message);
        await assertNewAccountActivity(tx, db, HttpsError, uid, [[PARTNER_KINDS[q.sellerType].collection, q.sellerId]]);
        assertActiveClient(clientSnap);

        const current = priceItems(q.sellerType, q.items, menu);
        const tariff = computeOfficialTariff({
          serviceType: q.sellerType, mode: q.mode, pickup: q.pickup, destination: q.destination, nowMs,
          declaredDistanceKm: q.distanceKm, config,
        });
        if (!tariff.ok) throw new PartnerRefusal(tariff.code, tariff.message);

        // Jamais plus que le devis sans reconfirmation (produits OU livraison) ; moins : nouvelle confirmation du montant exact.
        const quotedLines = new Map(q.lines.map((l) => [l.itemId, l.unitPrice]));
        const raisedItem = current.lines.find((l) => l.unitPrice > quotedLines.get(l.itemId));
        if (raisedItem || tariff.deliveryFee > q.deliveryFee) {
          throw new PartnerRefusal('PRICE_CHANGED', 'Le tarif a changé : nouvelle confirmation requise', {
            quotedAmount: q.amount, currentAmount: current.productAmount + tariff.deliveryFee,
            ...(raisedItem ? { itemId: raisedItem.itemId } : {}),
          });
        }
        const amounts = buildPartnerAmounts(current.productAmount, tariff.deliveryFee);
        // Le client confirme le montant EXACT qui sera débité. Prix en baisse depuis le devis : le nouveau montant
        // doit être présenté et reconfirmé (aucun débit d'un montant que le client n'a pas vu).
        if (!Number.isSafeInteger(d.confirmedAmount)) {
          throw new PartnerRefusal('AMOUNT_NOT_CONFIRMED', 'Montant non confirmé', { amount: amounts.totalAmount });
        }
        if (d.confirmedAmount !== amounts.totalAmount) {
          if (amounts.totalAmount < q.amount && d.confirmedAmount === q.amount) {
            throw new PartnerRefusal('PRICE_CHANGED', 'Le tarif a baissé : confirmez le nouveau montant', {
              quotedAmount: q.amount, currentAmount: amounts.totalAmount, decreased: true,
              productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee,
            });
          }
          throw new PartnerRefusal('AMOUNT_NOT_CONFIRMED', 'Montant non confirmé', { amount: amounts.totalAmount });
        }

        const total = amounts.totalAmount;
        if (paymentMethod === 'wallet') {
          const wallet = Number(clientSnap.data().wallet);
          if (!Number.isSafeInteger(wallet) || wallet < 0 || wallet < total) {
            throw new PartnerRefusal('SOLDE_INSUFFISANT', `SOLDE_INSUFFISANT:${Number.isFinite(wallet) ? wallet : 0}:${total}`);
          }
          tx.update(clientRef, { wallet: wallet - total, lastPaidOrderId: orderId });
          tx.set(clientRef.collection('wallet_transactions').doc(`order_${orderId}`), {
            type: 'payment', amount: total,
            description: `Commande ${q.sellerName || q.sellerType} — produits ${amounts.productAmount} FCFA + livraison ${amounts.deliveryFee} FCFA`,
            orderId, provider: 'wallet', txId: `order_${orderId}`, productAmount: amounts.productAmount, deliveryFee: amounts.deliveryFee,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }

        const bakery = q.sellerType === 'boulangerie';
        const itemLines = current.lines.map((l) => ({
          id: l.itemId, name: l.name, qty: l.qty, price: l.unitPrice, subtotal: l.subtotal, budgetFcfa: l.subtotal,
        }));
        const description = bakery
          ? deliveryAddress
          : `🍽️ ${q.sellerName || 'Restaurant'} : ${current.lines.map((l) => `${l.qty}x ${l.name} (${l.subtotal} FCFA)`).join(', ')}`;
        tx.create(orderRef, {
          id: orderId, type: q.sellerType, sellerType: q.sellerType, sellerId: q.sellerId, sellerName: q.sellerName || '',
          clientId: uid, clientName: clientSnap.data().name || null, clientPhone: clientSnap.data().phone || null,
          description, deliveryAddress, ...(notes ? { notes } : {}), items: itemLines,
          status: 'pending', shoppingBudget: 0,
          ...amounts, // amountsVersion 2, productAmount, deliveryFee, totalAmount, budget = deliveryFee
          ...(bakery ? { itemsAmount: amounts.productAmount, sellerStatus: null, requestedTime: requestedTime && requestedTime !== 'Maintenant' ? requestedTime : null } : {}),
          paymentMethod, isPaid: paymentMethod === 'wallet', forSelf: true, deliveryMode: 'standard',
          latitude: q.pickup.lat, longitude: q.pickup.lng, deliveryLatitude: q.pickup.lat, deliveryLongitude: q.pickup.lng,
          destLat: q.destination.lat, destLng: q.destination.lng,
          pickupCityId: geography.pickupCityId, deliveryCityId: geography.deliveryCityId,
          pickupZoneId: geography.pickupZoneId || null, deliveryZoneId: geography.deliveryZoneId || null,
          pickupCoordinateSource: 'local_place', deliveryCoordinateSource: deliverySource,
          cityResolutionStatus: geography.cityResolutionStatus,
          tariffQuoteId: d.quoteId, quotedAmount: q.amount, quotedProductAmount: q.productAmount, quotedDeliveryFee: q.deliveryFee,
          tariffVersion: q.tariffVersion, tariffCityId: q.cityId, tariffDistanceKm: q.distanceKm, source: 'partner_quote',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(quoteRef, { status: 'used', usedAtMs: nowMs, orderId, chargedTotal: paymentMethod === 'wallet' ? total : 0 });
        charged = paymentMethod === 'wallet' ? total : 0;
        finalAmounts = amounts;
      });
    } catch (err) {
      if (err instanceof PartnerRefusal) {
        await logAudit({ action: 'create_partner_order_refused', userId: uid, targetId: d.quoteId, status: 'refused', metadata: { code: err.code, sellerType: d.sellerType } });
        return envelope(false, err.code, err.message, err.data);
      }
      throw err;
    }

    if (replay) return envelope(true, null, 'Commande déjà créée', { ...replay, replayed: true });
    await logAudit({
      action: 'create_partner_order', userId: uid, targetId: orderId, status: 'success', amount: charged,
      metadata: { quoteId: d.quoteId, paymentMethod, sellerType: choices.sellerType, productAmount: finalAmounts.productAmount, deliveryFee: finalAmounts.deliveryFee },
    });
    return envelope(true, null, 'Commande créée', {
      orderId, charged, productAmount: finalAmounts.productAmount, deliveryFee: finalAmounts.deliveryFee, totalAmount: finalAmounts.totalAmount,
    });
  });
}

module.exports = { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF };
