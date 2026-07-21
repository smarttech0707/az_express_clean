'use strict';

const { getUserMemory } = require('./tools/memory');

// ═══════════════════════════════════════════════════════════════════════════
// ContextManager (Master Prompt 113, enrichi Master Prompt 118) — assemble,
// avant le premier appel Claude d'un tour de conversation, tout ce qui est
// DÉJÀ connu de l'utilisateur (profil clients/{uid}, mémoire
// ai_user_memory/{uid}, localisation transmise par le client Flutter si le
// GPS est déjà autorisé, ET DÉSORMAIS des insights dérivés de données
// RÉELLES — dernière commande, vendeur fréquent, solde wallet faible) en un
// court bloc de contexte textuel injecté dans le system prompt.
//
// Objectif direct : que le modèle n'ait jamais à demander une information
// déjà disponible (section 15 du prompt) — sans appel LLM supplémentaire ni
// aller-retour d'outil, cette lecture Firestore ciblée remplace ce qui
// aurait autrement nécessité que Claude appelle explicitement un outil de
// lecture puis reformule la question (section 18 : privilégier Firestore/
// mémoire avant d'interroger le LLM).
//
// Les insights "proactifs" (Master Prompt 118 : "tu commandes souvent ici",
// "ton portefeuille est faible") sont calculés ICI à partir de données
// réellement lues (dernières commandes, solde wallet réel) — jamais
// inventés. Volontairement PAS un système de notification push séparé :
// l'information est simplement mise à disposition du modèle, qui décide
// (via le SYSTEM_PROMPT) s'il est pertinent de la mentionner naturellement.
// ═══════════════════════════════════════════════════════════════════════════

const LOW_WALLET_THRESHOLD_FCFA = 500;
const FREQUENT_SELLER_MIN_COUNT = 3;
const RECENT_ORDERS_SAMPLE_SIZE = 10;

async function getLastOrderAndFrequentSeller(db, uid) {
  try {
    const snap = await db.collection('orders')
      .where('clientId', '==', uid)
      .orderBy('createdAt', 'desc')
      .limit(RECENT_ORDERS_SAMPLE_SIZE)
      .get();
    if (snap.empty) return { lastOrder: null, frequentSeller: null };

    const docs = snap.docs.map(d => d.data());
    const lastOrder = docs[0];

    // Vendeur/restaurant/pharmacie fréquent — compte par sellerName (ou
    // description à défaut, pour les livraisons/courses sans vendeur
    // identifié) sur l'échantillon récent, réellement lu, jamais deviné.
    const counts = new Map();
    for (const o of docs) {
      const key = o.sellerName || o.description;
      if (!key) continue;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    let frequentSeller = null;
    for (const [key, count] of counts.entries()) {
      if (count >= FREQUENT_SELLER_MIN_COUNT && (!frequentSeller || count > frequentSeller.count)) {
        frequentSeller = { name: key, count };
      }
    }

    return { lastOrder, frequentSeller };
  } catch (_) {
    return { lastOrder: null, frequentSeller: null };
  }
}

async function buildUserContext(db, uid, location) {
  const lines = [];
  let wallet = null;

  try {
    const clientSnap = await db.collection('clients').doc(uid).get();
    if (clientSnap.exists) {
      const c = clientSnap.data();
      if (c.name)  lines.push(`Nom du client : ${c.name}`);
      if (c.phone) lines.push(`Téléphone du client : ${c.phone}`);
      if (typeof c.wallet === 'number') wallet = c.wallet;
    }
  } catch (_) {
    // best-effort — l'absence de profil ne doit jamais bloquer la conversation
  }

  const memory = await getUserMemory(db, uid);
  if (memory) {
    if (memory.firstName)              lines.push(`Prénom : ${memory.firstName}`);
    if (memory.nickname)               lines.push(`Surnom préféré : ${memory.nickname}`);
    if (memory.address)                lines.push(`Adresse connue : ${memory.address}`);
    if (memory.quartier)               lines.push(`Quartier connu : ${memory.quartier}`);
    if (memory.ville)                  lines.push(`Ville connue : ${memory.ville}`);
    if (memory.language)               lines.push(`Langue préférée mentionnée : ${memory.language}`);
    if (memory.preferredPaymentMethod) lines.push(`Moyen de paiement préféré : ${memory.preferredPaymentMethod}`);
    if (memory.foodPreferences)        lines.push(`Préférences alimentaires : ${memory.foodPreferences}`);
    if (memory.voicePreference)        lines.push(`Préférence vocale : ${memory.voicePreference}`);
    if (memory.favoritePharmacyId)     lines.push(`Pharmacie préférée (ID) : ${memory.favoritePharmacyId}`);
    if (memory.favoriteRestaurantId)   lines.push(`Restaurant préféré (ID) : ${memory.favoriteRestaurantId}`);
    if (memory.favoriteSellerId)       lines.push(`Boutique/vendeur préféré (ID) : ${memory.favoriteSellerId}`);
    if (memory.favoriteDriverId) {
      lines.push(`Livreur préféré (ID) : ${memory.favoriteDriverId} — mentionne-le si pertinent, mais rappelle que l'attribution du livreur reste automatique (aucun outil ne permet de forcer un livreur précis).`);
    }
    if (Array.isArray(memory.addresses) && memory.addresses.length > 0) {
      const list = memory.addresses.map(a => `${a.label} → ${a.address}`).join(' ; ');
      lines.push(`Adresses nommées connues (utilise-les pour "chez moi"/"au bureau"/"chez maman" sans jamais redemander) : ${list}`);
    }
  }

  if (location && typeof location.latitude === 'number' && typeof location.longitude === 'number') {
    lines.push(`Position GPS actuelle du client (déjà autorisée, ne jamais la redemander) : latitude=${location.latitude}, longitude=${location.longitude}`);
    if (location.address) lines.push(`Adresse déduite de la position GPS : ${location.address}`);
  }

  // Insights réels (Master Prompt 118) — dérivés de commandes/solde
  // effectivement lus, jamais inventés.
  const { lastOrder, frequentSeller } = await getLastOrderAndFrequentSeller(db, uid);
  if (lastOrder) {
    const label = lastOrder.sellerName || lastOrder.description || 'une commande précédente';
    lines.push(`Dernière commande connue : ${label}${lastOrder.budget ? ` (${lastOrder.budget} FCFA)` : ''} — utile pour "comme hier"/"encore la même chose", mais confirme toujours les détails avant de recréer une commande.`);
  }
  if (frequentSeller) {
    lines.push(`Vendeur/restaurant fréquent récemment : ${frequentSeller.name} (${frequentSeller.count} commandes récentes) — tu peux le mentionner naturellement si pertinent ("tu commandes souvent ici, tu veux recommander ?"), sans insister.`);
  }
  if (wallet !== null) {
    if (wallet < LOW_WALLET_THRESHOLD_FCFA) {
      lines.push(`Solde wallet actuel : ${wallet} FCFA (faible) — tu peux le mentionner une seule fois si pertinent dans la conversation, sans insister ni le répéter à chaque message.`);
    }
  }

  if (lines.length === 0) return null;

  return 'Informations déjà connues sur ce client — ne jamais les redemander :\n' + lines.map(l => `- ${l}`).join('\n');
}

module.exports = { buildUserContext };
