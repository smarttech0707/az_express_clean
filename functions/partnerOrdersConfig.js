'use strict';

// Activation progressive des commandes Restaurant/Boulangerie version 2 (Mission 7C-1).
//
// DEUX interrupteurs indépendants (variables d'environnement serveur) :
//   PARTNER_ORDERS_V2        = 'on'  → autorise la CRÉATION de nouvelles commandes v2 (devis + création).
//                                       Absent ou autre valeur : refus (FEATURE_DISABLED). Désactivé par défaut.
//   PARTNER_ORDERS_V2_MANAGE = 'off' → GÈLE la gestion des commandes v2 déjà créées (préparation, refus, cash, litiges).
//                                       Activée par défaut : arrêter les nouvelles créations ne doit jamais empêcher de
//                                       terminer ou de résoudre une commande existante (argent du client, du partenaire
//                                       et du livreur). 'off' est un gel d'urgence, à n'utiliser qu'en cas d'incident.
//
// Liste pilote (document Firestore `config/partnerOrdersV2`, écrit par un administrateur ou à la main — jamais par un
// client) : { pilotPartnerIds: ['<id partenaire>', ...] }.
//   - Document absent ou liste invalide : aucune restriction par partenaire (l'interrupteur de création décide seul).
//   - Liste présente : la création v2 n'est possible QUE pour ces partenaires (activation progressive), et les anciens
//     parcours de création (AZ IA) sont refusés pour ces mêmes partenaires tant que la création v2 est active.
//     Une liste vide (`[]`) bloque toute création v2 : c'est un arrêt par partenaire, pas une ouverture.

const CONFIG_COLLECTION = 'config';
const CONFIG_DOC = 'partnerOrdersV2';

const creationEnabled = () => process.env.PARTNER_ORDERS_V2 === 'on';
const managementEnabled = () => process.env.PARTNER_ORDERS_V2_MANAGE !== 'off';

function parsePilotConfig(data) {
  if (!data || !Array.isArray(data.pilotPartnerIds)) return { restricted: false, ids: new Set() };
  const ids = new Set(data.pilotPartnerIds.filter((id) => typeof id === 'string' && id && !id.includes('/')));
  return { restricted: true, ids };
}

async function loadPilotConfig(db) {
  const snap = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC).get();
  return parsePilotConfig(snap.exists ? snap.data() : null);
}

// Création v2 autorisée pour ce partenaire ? (hors interrupteur global, évalué séparément)
const v2CreationAllowed = (config, sellerId) => !config.restricted || config.ids.has(sellerId);

// Ancien parcours de création (sans devis serveur) refusé pour ce partenaire ? Seulement pour un partenaire pilote ET
// quand la création v2 est réellement active : sinon le partenaire n'aurait plus aucun moyen de recevoir une commande.
const legacyCreationBlocked = (config, sellerId, enabled = creationEnabled()) => enabled && config.restricted && config.ids.has(sellerId);

module.exports = {
  CONFIG_COLLECTION, CONFIG_DOC, creationEnabled, managementEnabled, parsePilotConfig, loadPilotConfig,
  v2CreationAllowed, legacyCreationBlocked,
};
