'use strict';

// Garde des notifications push de la PRÉPRODUCTION (Mission 7E-30).
//
// Les tokens FCM présents dans az-express-preprod appartiennent à de vrais appareils dont le propriétaire n'est pas établi :
// aucune notification ne doit partir sans autorisation explicite. Hors préproduction (production comprise) le garde est
// transparent : mêmes envois, mêmes destinataires, aucune écriture supplémentaire.
//
// Préproduction, un envoi n'est possible que si TOUT est vrai :
//   1. NOTIFICATIONS_SEND vaut exactement « on » (absent, « off », « DISABLED », valeur inconnue = bloqué) ;
//   2. le destinataire figure dans NOTIFICATIONS_ALLOWED_RECIPIENTS, au format  <rôle>:<identifiant>:<empreinte du token>
//      (rôle = client | driver | restaurant ; empreinte = 8 à 64 premiers caractères hexadécimaux du SHA-256 du token, jamais le
//      token) ; une entrée mal formée est ignorée ;
//   3. le token lu sur le document du destinataire a cette empreinte (un token renouvelé exige une nouvelle autorisation) ;
//   4. la fonction appelante est dans la liste des fonctions autorisées pour ce rôle, et la commande est dans son périmètre ;
//   5. l'événement n'a pas déjà notifié ce destinataire (livraison répétée d'un événement Firestore).
// La couche basse (sendToToken / sendToMultipleTokens) refuse en plus tout envoi qui n'a pas été autorisé ici : une autre
// fonction qui appellerait FCM directement est bloquée par défaut en préproduction.
const crypto = require('node:crypto');

const PREPROD_PROJECT = 'az-express-preprod';
const DEDUPE_COLLECTION = 'notification_dedupe';
const MIN_FINGERPRINT = 8;

// fonction -> rôle de destinataire qu'elle peut joindre. Toute autre combinaison est refusée.
const FUNCTION_ROLES = Object.freeze({
  notifyRestaurantOnOrder: 'restaurant',
  notifyClientOnOrderUpdate: 'client',
  notifyDriversOnNewOrder: 'driver',
});

// Périmètre de commande par fonction en préproduction : le pilote ne concerne que les commandes Restaurant v2.
// notifyDriversOnNewOrder ne vise que les commandes non partenaires (livraison historique) : pas de restriction supplémentaire.
const ORDER_SCOPE = Object.freeze({
  notifyRestaurantOnOrder: (order) => order && order.sellerType === 'restaurant' && Number(order.amountsVersion) === 2,
  notifyClientOnOrderUpdate: (order) => order && Number(order.amountsVersion) === 2,
  notifyDriversOnNewOrder: (order) => !!order,
});

const fingerprint = (token) => crypto.createHash('sha256').update(String(token)).digest('hex');

function isPreprod(env = process.env) { return env.GCLOUD_PROJECT === PREPROD_PROJECT; }

// 'unrestricted' hors préproduction ; 'allowlist' seulement avec NOTIFICATIONS_SEND exactement « on » ; sinon 'blocked'.
function sendMode(env = process.env) {
  if (!isPreprod(env)) return 'unrestricted';
  return typeof env.NOTIFICATIONS_SEND === 'string' && env.NOTIFICATIONS_SEND.trim().toLowerCase() === 'on' ? 'allowlist' : 'blocked';
}

function parseAllowlist(raw) {
  const entries = [];
  if (typeof raw !== 'string') return entries;
  for (const part of raw.split(',')) {
    const [role, id, fp, ...extra] = part.trim().split(':');
    if (extra.length || !Object.values(FUNCTION_ROLES).includes(role)) continue;
    if (!id || id.includes('/') || !/^[0-9a-f]+$/i.test(fp || '') || fp.length < MIN_FINGERPRINT || fp.length > 64) continue;
    entries.push({ role, id, fp: fp.toLowerCase() });
  }
  return entries;
}

function createNotificationGuard({ db, env = process.env, logger = console } = {}) {
  const mode = sendMode(env);
  const allowlist = mode === 'allowlist' ? parseAllowlist(env.NOTIFICATIONS_ALLOWED_RECIPIENTS) : [];
  const granted = new WeakSet(); // autorisations émises par CE garde (non falsifiables par un appelant)
  const UNRESTRICTED = Object.freeze({ unrestricted: true });

  const log = (fn, reason) => logger.log(`[notificationGuard] envoi bloqué (${reason}) fn=${fn}`);

  function allowedFor(fn, role, id, token) {
    if (FUNCTION_ROLES[fn] !== role) return 'fonction/rôle non autorisés';
    const fp = fingerprint(token);
    const entry = allowlist.find((e) => e.role === role && e.id === id);
    if (!entry) return 'destinataire non autorisé';
    if (!fp.startsWith(entry.fp)) return 'token différent de celui autorisé';
    return null;
  }

  // Marque l'événement pour ce destinataire : false si déjà traité (livraison répétée). Panne du magasin = on envoie
  // (une notification légitime ne doit pas être perdue ; seuls les destinataires déjà autorisés arrivent ici).
  async function claim(fn, eventId, role, id) {
    if (!eventId || !db) return true;
    try {
      await db.collection(DEDUPE_COLLECTION).doc(`${fn}_${eventId}_${role}_${id}`.slice(0, 500)).create({ fn, role, at: Date.now() });
      return true;
    } catch (err) {
      if (err && (err.code === 6 || /ALREADY_EXISTS/.test(String(err.message)))) return false;
      logger.warn(`[notificationGuard] déduplication indisponible : ${err && err.message}`);
      return true;
    }
  }

  // ctx : { fn, eventId, order }. recipients : [{ role, id, token }]. Renvoie { tokens, authorization } : seuls les tokens autorisés
  // ; authorization est exigée par la couche basse. Hors préproduction : tous les tokens, sans écriture.
  async function authorize(ctx, recipients) {
    const all = recipients.filter((r) => r && r.token);
    if (mode === 'unrestricted') return { tokens: all.map((r) => r.token), authorization: UNRESTRICTED };
    if (mode === 'blocked') { if (all.length) log(ctx.fn, 'NOTIFICATIONS_SEND non activé'); return { tokens: [], authorization: null }; }
    const scope = ORDER_SCOPE[ctx.fn];
    if (!scope || !scope(ctx.order)) { if (all.length) log(ctx.fn, 'commande hors périmètre'); return { tokens: [], authorization: null }; }
    const tokens = [];
    for (const r of all) {
      const why = allowedFor(ctx.fn, r.role, r.id, r.token);
      if (why) { log(ctx.fn, why); continue; }
      if (!(await claim(ctx.fn, ctx.eventId, r.role, r.id))) { log(ctx.fn, 'événement déjà notifié'); continue; }
      tokens.push(r.token);
    }
    if (!tokens.length) return { tokens, authorization: null };
    const authorization = Object.freeze({ tokens: new Set(tokens) });
    granted.add(authorization);
    return { tokens, authorization };
  }

  // Couche basse : ce token peut-il partir avec cette autorisation ?
  function permits(token, authorization) {
    if (mode === 'unrestricted') return true;
    return !!authorization && granted.has(authorization) && authorization.tokens.has(token);
  }

  return { mode, authorize, permits };
}

module.exports = { createNotificationGuard, sendMode, parseAllowlist, fingerprint, FUNCTION_ROLES, DEDUPE_COLLECTION, PREPROD_PROJECT };
