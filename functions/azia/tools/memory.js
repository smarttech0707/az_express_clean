'use strict';

// ═══════════════════════════════════════════════════════════════════════════
// MÉMOIRE UTILISATEUR AZ IA (Master Prompt 113, jalon M8 scopé) — quand un
// utilisateur communique une information personnelle dans la conversation
// (nom, adresse, quartier, ville, moyen de paiement préféré, pharmacie/
// restaurant/boutique/livreur préféré), AZ IA appelle cet outil pour la
// mémoriser durablement dans ai_user_memory/{uid} plutôt que de devoir la
// redemander à chaque nouvelle conversation. Écriture non sensible (aucune
// donnée financière, aucune action) — pas de confirmation requise, cohérent
// avec les autres outils en lecture/écriture de préférence déjà existants
// (ex. aucun outil actuel ne demande confirmation pour une simple recherche).
// ═══════════════════════════════════════════════════════════════════════════

const ALLOWED_FIELDS = [
  'name', 'phone', 'address', 'quartier', 'ville',
  'preferredPaymentMethod', 'favoritePharmacyId', 'favoriteRestaurantId',
  'favoriteSellerId', 'favoriteDriverId',
  // Master Prompt 118 — profil enrichi (prénom/surnom/langue/préférences),
  // additif pur : les champs déjà existants ci-dessus ne changent pas de
  // sens, ceux-ci s'ajoutent simplement à la liste déjà autorisée.
  'firstName', 'nickname', 'language', 'foodPreferences', 'voicePreference',
];

function rememberUserInfo({ db, admin }) {
  return {
    name: 'remember_user_info',
    description: "Mémorise une information personnelle communiquée par l'utilisateur (nom, prénom, surnom, adresse, quartier, ville, langue, moyen de paiement préféré, préférences alimentaires/vocales, pharmacie/restaurant/boutique/livreur préféré) pour ne plus jamais la redemander dans une future conversation. À appeler dès que l'utilisateur fournit une de ces informations, même en passant — jamais pour des données financières ou sensibles. Pour une adresse NOMMÉE (« chez moi », « au bureau », « chez maman »...), utilise plutôt l'outil remember_named_address.",
    input_schema: {
      type: 'object',
      properties: {
        name:                    { type: 'string', description: 'Nom complet.' },
        firstName:               { type: 'string', description: 'Prénom.' },
        nickname:                { type: 'string', description: "Surnom que l'utilisateur préfère qu'on utilise." },
        phone:                   { type: 'string', description: 'Numéro de téléphone.' },
        address:                 { type: 'string', description: 'Adresse ou repère principal (ex: "près du marché de Cafétou").' },
        quartier:                { type: 'string', description: "Quartier de résidence." },
        ville:                   { type: 'string', description: 'Ville.' },
        language:                { type: 'string', description: 'Langue préférée mentionnée par l\'utilisateur (ex: "français", "dioula").' },
        preferredPaymentMethod:  { type: 'string', enum: ['wallet', 'cash'], description: 'Moyen de paiement préféré.' },
        foodPreferences:         { type: 'string', description: 'Préférences alimentaires (ex: "pas de piment", "végétarien").' },
        voicePreference:         { type: 'string', description: "Préférence sur les réponses vocales (ex: \"préfère les réponses courtes à l'oral\")." },
        favoritePharmacyId:      { type: 'string', description: 'ID de la pharmacie préférée (déjà connu via search_pharmacies).' },
        favoriteRestaurantId:    { type: 'string', description: 'ID du restaurant préféré (déjà connu via search_restaurants).' },
        favoriteSellerId:        { type: 'string', description: 'ID du vendeur/boutique préféré.' },
        favoriteDriverId:        { type: 'string', description: 'ID du livreur préféré, si mentionné.' },
      },
    },
    handler: async (uid, input) => {
      const updates = {};
      for (const field of ALLOWED_FIELDS) {
        if (input && input[field] !== undefined && input[field] !== null && String(input[field]).trim() !== '') {
          updates[field] = String(input[field]).trim();
        }
      }
      if (Object.keys(updates).length === 0) {
        return { saved: false, message: 'Aucune information exploitable à mémoriser.' };
      }
      updates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      await db.collection('ai_user_memory').doc(uid).set(updates, { merge: true });
      return { saved: true, fields: Object.keys(updates).filter(k => k !== 'updatedAt') };
    },
  };
}

const MAX_NAMED_ADDRESSES = 10;

// Carnet d'adresses nommées (Master Prompt 118) — distinct de `address`
// (l'adresse principale, un seul champ scalaire) : permet de résoudre
// « chez moi »/« au bureau »/« chez maman » sans jamais redemander,
// nécessite une logique de fusion par étiquette (tableau), incompatible
// avec la boucle générique de rememberUserInfo ci-dessus — d'où un outil
// séparé plutôt qu'un cas particulier ajouté à ALLOWED_FIELDS.
function rememberNamedAddress({ db, admin }) {
  return {
    name: 'remember_named_address',
    description: "Mémorise une adresse NOMMÉE (ex: « chez moi », « au bureau », « chez maman », « chez ma sœur ») pour que l'utilisateur puisse ensuite dire « livre chez maman » ou « au bureau » sans jamais redonner l'adresse complète. À appeler dès qu'un nom/label d'adresse est mentionné avec une adresse ou un repère.",
    input_schema: {
      type: 'object',
      properties: {
        label:   { type: 'string', description: 'Nom donné à cette adresse (ex: "maison", "bureau", "chez maman").' },
        address: { type: 'string', description: 'Adresse ou repère correspondant (ex: "Cafétou, près du grand marché").' },
      },
      required: ['label', 'address'],
    },
    handler: async (uid, input) => {
      const label = String(input?.label || '').trim().toLowerCase();
      const address = String(input?.address || '').trim();
      if (!label || !address) {
        return { saved: false, message: 'Label et adresse requis.' };
      }

      const ref = db.collection('ai_user_memory').doc(uid);
      const snap = await ref.get();
      const existing = Array.isArray(snap.data()?.addresses) ? snap.data().addresses : [];

      const next = existing.filter(a => String(a?.label || '').toLowerCase() !== label);
      next.push({ label, address });
      if (next.length > MAX_NAMED_ADDRESSES) next.shift(); // borne simple, la plus ancienne cède la place

      await ref.set({
        addresses: next,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { saved: true, label, address };
    },
  };
}

// Lit tout ce qu'AZ IA sait déjà de l'utilisateur — utilisé par
// contextBuilder.js (injection automatique en début de conversation), pas
// exposé comme outil séparé pour ne pas gaspiller un tour de modèle sur une
// donnée qui doit déjà être dans le contexte avant même le premier message.
async function getUserMemory(db, uid) {
  try {
    const snap = await db.collection('ai_user_memory').doc(uid).get();
    return snap.exists ? snap.data() : null;
  } catch (_) {
    return null;
  }
}

module.exports = { rememberUserInfo, rememberNamedAddress, getUserMemory, ALLOWED_FIELDS };
