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
// client) : { pilotPartnerIds: ['<id partenaire>', ...] }. SÉCURITÉ PAR DÉFAUT (Mission 7C-1-S) :
//   - Document absent, liste absente, invalide ou vide : AUCUNE création v2 (aucun partenaire pilote).
//   - Seuls les partenaires explicitement listés créent en v2.
//   - Cette MÊME liste est lue par firestore.rules (fonction legacyPartnerCreationBlocked) : un partenaire listé ne reçoit
//     plus de commande au format historique (création directe Flutter ni AZ IA). Les règles ne voient pas les variables
//     d'environnement : pour rouvrir l'ancien parcours d'un partenaire, le RETIRER de la liste (arrêt immédiat des deux
//     côtés). Vider la liste est l'arrêt d'urgence complet de la création v2 ; couper seulement PARTNER_ORDERS_V2 laisse
//     les partenaires listés sans parcours de création.

const CONFIG_COLLECTION = 'config';
const CONFIG_DOC = 'partnerOrdersV2';

const creationEnabled = () => process.env.PARTNER_ORDERS_V2 === 'on';
const managementEnabled = () => process.env.PARTNER_ORDERS_V2_MANAGE !== 'off';

function parsePilotConfig(data) {
  if (!data || !Array.isArray(data.pilotPartnerIds)) return { ids: new Set() };
  return { ids: new Set(data.pilotPartnerIds.filter((id) => typeof id === 'string' && id && !id.includes('/'))) };
}

async function loadPilotConfig(db) {
  const snap = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC).get();
  return parsePilotConfig(snap.exists ? snap.data() : null);
}

// Création v2 autorisée pour ce partenaire ? (hors interrupteur global, évalué séparément)
const v2CreationAllowed = (config, sellerId) => config.ids.has(sellerId);

// Ancien parcours de création (sans devis serveur) refusé pour ce partenaire ? Exactement les partenaires pilotes : même
// définition que les règles Firestore, qui ne peuvent pas lire l'interrupteur d'environnement.
const legacyCreationBlocked = (config, sellerId) => config.ids.has(sellerId);

module.exports = {
  CONFIG_COLLECTION, CONFIG_DOC, creationEnabled, managementEnabled, parsePilotConfig, loadPilotConfig,
  v2CreationAllowed, legacyCreationBlocked,
};
