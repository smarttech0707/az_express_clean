'use strict';

const crypto = require('crypto');
const { assertNewAccountActivity } = require('./accountAdmission');
const {
  CATALOG_VERSION, CatalogRefusal, resolveBlanchisserieConfig, priceCatalogRequest, canonicalParams,
} = require('./catalogTariff');

// quoteCatalogCF + createCatalogOrderFromQuoteCF — Colis, Blanchisserie, Eau & Boissons.
//
// Même architecture que le devis de livraison (deliveryQuote.js) : devis `tariff_quotes` écrit par le serveur
// seulement (Admin SDK), lié au client, au service et aux paramètres choisis, à durée limitée, à usage unique ;
// création de commande en UNE transaction (relecture du devis, nouveau calcul, débit wallet, `tx.create` de la
// commande, devis marqué utilisé). Un rejeu avec le même devis retrouve la même commande : jamais de second débit.
// Le client ne fournit que des CHOIX (type, kilos, produits, quantités) et des textes ; tous les montants sont posés
// par le serveur. La commande garde exactement la forme des écrans actuels (acceptation, livraison, annulation et
// commission fonctionnent sans changement ; annulation = cancelOrderCF).
// Nouveaux points d'entrée uniquement : aucun écran actuel ne les appelle, aucun parcours existant n'est modifié.

const SERVICES = Object.freeze(['colis', 'blanchisserie', 'eau_boissons']);
const PAYMENT_METHODS = Object.freeze(['wallet', 'cash']);
const QUOTE_TTL_MS = 10 * 60 * 1000;

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });

class Refusal extends Error {
  constructor(code, message, data = null) { super(message); this.code = code; this.data = data; }
}

// Texte libre : jamais un montant, simplement borné et nettoyé.
function text(value, { max = 300, required = false, field }) {
  if (value === undefined || value === null || value === '') {
    if (required) throw new CatalogRefusal('INVALID_FIELD', `Champ requis : ${field}`);
    return '';
  }
  if (typeof value !== 'string') throw new CatalogRefusal('INVALID_FIELD', `Champ invalide : ${field}`);
  const v = value.trim();
  if (required && !v) throw new CatalogRefusal('INVALID_FIELD', `Champ requis : ${field}`);
  return v.slice(0, max);
}

// Description et champs texte identiques à ceux des écrans actuels.
function buildOrderTexts(service, d, priced) {
  if (service === 'colis') {
    const f = {
      senderName: text(d.senderName, { field: 'expéditeur' }), senderPhone: text(d.senderPhone, { max: 30, field: 'téléphone expéditeur' }),
      recipientName: text(d.recipientName, { required: true, field: 'destinataire' }),
      recipientPhone: text(d.recipientPhone, { max: 30, field: 'téléphone destinataire' }),
      recipientAddress: text(d.recipientAddress, { required: true, field: 'adresse destinataire' }),
      contentDescription: text(d.contentDescription, { max: 500, field: 'contenu' }),
    };
    let desc = `Colis : ${priced.orderFields.colisType}`;
    if (priced.orderFields.fragile) desc += ' (Fragile)';
    if (f.senderName) desc += `\nExpéditeur : ${f.senderName}`;
    if (f.senderPhone) desc += ` — ${f.senderPhone}`;
    desc += `\nDestinataire : ${f.recipientName} — ${f.recipientPhone}`;
    desc += `\nAdresse : ${f.recipientAddress}`;
    if (f.contentDescription) desc += `\nContenu : ${f.contentDescription}`;
    return { description: desc, fields: f };
  }
  if (service === 'blanchisserie') {
    const address = text(d.address, { required: true, field: 'adresse' });
    const notes = text(d.notes, { max: 500, field: 'notes' });
    const desc = `Blanchisserie : ${priced.orderFields.serviceType} — ${priced.orderFields.quantity} kg\nAdresse : ${address}${notes ? `\nNotes : ${notes}` : ''}`;
    return { description: desc, fields: { address, notes } };
  }
  const address = text(d.address, { required: true, field: 'adresse' });
  const parts = priced.orderFields.items.map((it) => `${it.name} ×${it.qty}`);
  return { description: `Eau & Boissons :\n${parts.join('\n')}\nAdresse : ${address}`, fields: { address } };
}

function ledgerDescription(service, priced) {
  if (service === 'colis') return `Colis — ${priced.orderFields.colisType}${priced.orderFields.fragile ? ' (Fragile)' : ''}`;
  if (service === 'blanchisserie') return `Blanchisserie — ${priced.orderFields.serviceType} × ${priced.orderFields.quantity} kg`;
  return `Eau & Boissons (${priced.orderFields.items.map((it) => `${it.name} ×${it.qty}`).join(', ')}) + livraison`;
}

function requireClientAuth(request, HttpsError) {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  // Cohérent avec les règles actuelles de création de commande (isRealUser) : pas de compte anonyme.
  if (request.auth.token?.firebase?.sign_in_provider === 'anonymous') throw new HttpsError('unauthenticated', 'Vous devez être connecté');
  return request.auth.uid;
}

function assertActiveClient(snap) {
  if (!snap.exists) throw new Refusal('CLIENT_NOT_FOUND', 'Compte client introuvable');
  const c = snap.data() || {};
  if (c.deletionRequested === true || c.isDeleted === true) throw new Refusal('ACCOUNT_UNAVAILABLE', 'Compte indisponible');
}

// Configuration administrable de la blanchisserie : relue ET validée par le serveur à chaque calcul.
async function loadBlanchisserieConfig(db) {
  const snap = await db.collection('app_config').doc('blanchisserie').get();
  return resolveBlanchisserieConfig(snap.exists ? snap.data() : null);
}

// ── quoteCatalogCF ─────────────────────────────────────────────────────────
function buildQuoteCatalogCF({ db, admin, onCall, HttpsError, checkRateLimit, now = () => Date.now(), randomId = () => crypto.randomUUID() }) {
  return onCall(async (request) => {
    const uid = requireClientAuth(request, HttpsError);
    const d = request.data || {};
    if (!SERVICES.includes(d.service)) return envelope(false, 'SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
    await checkRateLimit(uid, 'quote_catalog', 30, 60);
    try {
      assertActiveClient(await db.collection('clients').doc(uid).get());
      const cfg = d.service === 'blanchisserie' ? await loadBlanchisserieConfig(db) : undefined;
      const priced = priceCatalogRequest(d.service, d, { blanchisserieConfig: cfg });
      const nowMs = now();
      const quoteId = randomId();
      const expiresAtMs = nowMs + QUOTE_TTL_MS;
      await db.collection('tariff_quotes').doc(quoteId).create({
        kind: 'catalog', uid, status: 'open', serviceType: d.service, params: priced.params,
        budget: priced.budget, shoppingBudget: priced.shoppingBudget, amount: priced.total,
        catalogVersion: CATALOG_VERSION, createdAtMs: nowMs, expiresAtMs,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return envelope(true, null, 'Devis créé', {
        quoteId, service: d.service, budget: priced.budget, shoppingBudget: priced.shoppingBudget, total: priced.total,
        lines: priced.lines, currency: 'XOF', expiresAtMs, catalogVersion: CATALOG_VERSION,
        ...(priced.pricePerKg ? { pricePerKg: priced.pricePerKg } : {}),
      });
    } catch (err) {
      if (err instanceof CatalogRefusal || err instanceof Refusal) return envelope(false, err.code, err.message, err.data);
      throw err;
    }
  });
}

// ── createCatalogOrderFromQuoteCF ──────────────────────────────────────────
function buildCreateCatalogOrderFromQuoteCF({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, now = () => Date.now(), newOrderId = () => crypto.randomUUID(),
}) {
  return onCall(async (request) => {
    const uid = requireClientAuth(request, HttpsError);
    const d = request.data || {};
    if (typeof d.quoteId !== 'string' || !d.quoteId || d.quoteId.length > 128 || d.quoteId.includes('/')) {
      throw new HttpsError('invalid-argument', 'quoteId manquant');
    }
    if (!SERVICES.includes(d.service)) return envelope(false, 'SERVICE_NOT_SUPPORTED', 'Service non pris en charge');
    // Mobile money non pris en charge ici : refus explicite (jamais traité comme du cash).
    if (!PAYMENT_METHODS.includes(d.paymentMethod)) return envelope(false, 'PAYMENT_METHOD_UNSUPPORTED', 'Mode de paiement non pris en charge');
    await checkRateLimit(uid, 'create_catalog_order', 10, 60);
    const paymentMethod = d.paymentMethod;
    const quoteRef = db.collection('tariff_quotes').doc(d.quoteId);
    const clientRef = db.collection('clients').doc(uid);
    const orderId = newOrderId();
    const orderRef = db.collection('orders').doc(orderId);

    let priced; let texts;
    let cfg;
    try {
      // Lectures hors transaction (configuration de référence) : avant tout débit.
      if (d.service === 'blanchisserie') cfg = await loadBlanchisserieConfig(db);
      priced = priceCatalogRequest(d.service, d, { blanchisserieConfig: cfg });
      texts = buildOrderTexts(d.service, d, priced);
    } catch (err) {
      if (err instanceof CatalogRefusal) return envelope(false, err.code, err.message, err.data);
      throw err;
    }

    let replay = null;
    let charged = 0;
    let finalOrderId = orderId;
    const nowMs = now();
    try {
      await db.runTransaction(async (tx) => {
        const quoteSnap = await tx.get(quoteRef);
        const clientSnap = await tx.get(clientRef);
        if (!quoteSnap.exists) throw new Refusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        const q = quoteSnap.data();
        // Même réponse qu'un devis absent : on ne révèle pas le devis d'un autre client ni d'un autre type.
        if (q.uid !== uid || q.kind !== 'catalog') throw new Refusal('QUOTE_NOT_FOUND', 'Devis introuvable');
        // Rejeu après réponse perdue / double appui : le MÊME client retrouve SA commande, sans second débit.
        if (q.status === 'used' && q.orderId) { replay = { orderId: q.orderId, charged: q.chargedTotal || 0 }; return; }
        if (q.status !== 'open') throw new Refusal('QUOTE_ALREADY_USED', 'Devis déjà utilisé');
        if (!(q.expiresAtMs > nowMs)) throw new Refusal('QUOTE_EXPIRED', 'Devis expiré');
        // La commande doit correspondre EXACTEMENT à ce qui a été devisé (service et choix).
        if (q.serviceType !== d.service || canonicalParams(q.params) !== canonicalParams(priced.params)) {
          throw new Refusal('QUOTE_MISMATCH', 'La commande ne correspond pas au devis');
        }
        // Tarif courant : jamais plus que le devis sans reconfirmation ; moins → le client paie le moindre.
        if (priced.total > q.amount) {
          throw new Refusal('PRICE_CHANGED', 'Le tarif a changé : nouvelle confirmation requise', { quotedAmount: q.amount, currentAmount: priced.total });
        }
        if (Number.isFinite(d.confirmedAmount) && d.confirmedAmount < priced.total) {
          throw new Refusal('AMOUNT_NOT_CONFIRMED', 'Montant non confirmé', { amount: priced.total });
        }
        assertActiveClient(clientSnap);
        await assertNewAccountActivity(tx, db, HttpsError, uid, []);

        const total = priced.total;
        if (paymentMethod === 'wallet') {
          const wallet = Number(clientSnap.data().wallet);
          if (!Number.isSafeInteger(wallet) || wallet < 0 || wallet < total) {
            throw new Refusal('SOLDE_INSUFFISANT', `SOLDE_INSUFFISANT:${Number.isFinite(wallet) ? wallet : 0}:${total}`);
          }
          tx.update(clientRef, { wallet: wallet - total, lastPaidOrderId: orderId });
          tx.set(clientRef.collection('wallet_transactions').doc(`order_${orderId}`), {
            type: 'payment', amount: total, description: ledgerDescription(d.service, priced),
            orderId, provider: 'wallet', txId: `order_${orderId}`, createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        tx.create(orderRef, {
          id: orderId, description: texts.description,
          budget: priced.budget, shoppingBudget: priced.shoppingBudget,
          status: 'pending', type: d.service,
          ...priced.orderFields, ...texts.fields,
          latitude: 0, longitude: 0,
          clientId: uid, paymentMethod, isPaid: paymentMethod === 'wallet',
          tariffQuoteId: d.quoteId, quotedAmount: q.amount, catalogVersion: CATALOG_VERSION, source: 'catalog_quote',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(quoteRef, { status: 'used', usedAtMs: nowMs, orderId, chargedTotal: paymentMethod === 'wallet' ? total : 0 });
        charged = paymentMethod === 'wallet' ? total : 0;
      });
    } catch (err) {
      if (err instanceof Refusal) {
        await logAudit({ action: 'create_catalog_order_refused', userId: uid, targetId: d.quoteId, status: 'refused', metadata: { code: err.code, service: d.service } });
        return envelope(false, err.code, err.message, err.data);
      }
      throw err;
    }
    if (replay) return envelope(true, null, 'Commande déjà créée', { ...replay, replayed: true });
    await logAudit({ action: 'create_catalog_order', userId: uid, targetId: finalOrderId, status: 'success', amount: charged, metadata: { quoteId: d.quoteId, paymentMethod, service: d.service } });
    return envelope(true, null, 'Commande créée', { orderId: finalOrderId, charged });
  });
}

module.exports = { buildQuoteCatalogCF, buildCreateCatalogOrderFromQuoteCF, SERVICES, QUOTE_TTL_MS };
