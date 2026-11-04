'use strict';

// Activation et arrêt d'urgence des commandes Restaurant/Boulangerie version 2 (Missions 7C-1, 7C-1-S, 7C-2).
//
// Document Firestore `config/partnerOrdersV2` — TROIS notions séparées, toutes à « fermé » par défaut :
//   pilotPartnerIds  : IDENTITÉ des partenaires pilotes (liste). Lue aussi par firestore.rules : un partenaire listé ne reçoit
//                      plus de commande créée directement au format historique (Flutter, AZ IA). Elle ne sert JAMAIS à
//                      arrêter les commandes : on ne la vide pas pour cela.
//   creationOpen     : AUTORISATION de créer de nouvelles commandes v2 (devis + création). false/absent = fermé. Passer à
//                      false arrête immédiatement les créations v2 SANS rouvrir l'ancien parcours (les règles ne lisent pas ce
//                      champ) et sans toucher aux commandes existantes.
//   managementFrozen : GEL EXCEPTIONNEL de la gestion des commandes v2 existantes (voir MANAGEMENT_FREEZE_POLICY).
//
// Variables d'environnement (niveau déploiement, dernier recours) :
//   PARTNER_ORDERS_V2        = 'on'  → rend la création possible (avec creationOpen et la liste). Absent : jamais de création.
//   PARTNER_ORDERS_V2_MANAGE = 'off' → même gel que managementFrozen.
//
// Création v2 = variable 'on' ET creationOpen === true ET partenaire dans pilotPartnerIds.
// Modification du document : uniquement par l'opération super-administrateur `setPartnerOrdersConfig`
// (partnerOrderActionCF) : validation stricte, version (contrôle de concurrence), journal d'audit avant/après.

const CONFIG_COLLECTION = 'config';
const CONFIG_DOC = 'partnerOrdersV2';

// Politique du gel (managementFrozen = true ou PARTNER_ORDERS_V2_MANAGE = 'off'). Les 9 actions de gestion de
// partnerOrderActionCF sont refusées (code MANAGEMENT_FROZEN) : accepter/préparer/prêt/refuser et les quatre actions de
// reversement cash. Seule l'opération de configuration super-administrateur reste possible (sinon on ne pourrait plus dégeler).
// Les voies INDÉPENDANTES restent actives, donc aucun argent n'est bloqué définitivement : annulation par le client, expiration
// automatique (10 min après acceptation sans préparation, 60 min sans acceptation) avec remboursement, livraison par le livreur,
// annulation exceptionnelle et litiges administratifs (adminOrderDisputeCF, adminBillingCF), alertes administratives.
// Effets pendant un gel : une commande non encore préparée n'avance plus côté partenaire ; une commande préparée ne peut plus être
// déclarée prête (le livreur ne peut pas la récupérer) ; un reversement cash reste en l'état (alerte à 24 h, aucun débit).
const MANAGEMENT_FREEZE_POLICY = 'all_partner_order_actions_except_config';

const creationEnabled = () => process.env.PARTNER_ORDERS_V2 === 'on';
const managementEnabled = () => process.env.PARTNER_ORDERS_V2_MANAGE !== 'off';

function parsePilotConfig(data) {
  const d = data && typeof data === 'object' ? data : {};
  return {
    ids: new Set(Array.isArray(d.pilotPartnerIds)
      ? d.pilotPartnerIds.filter((id) => typeof id === 'string' && id && !id.includes('/')) : []),
    creationOpen: d.creationOpen === true,
    managementFrozen: d.managementFrozen === true,
    version: Number.isSafeInteger(d.version) && d.version >= 0 ? d.version : 0,
  };
}

async function loadPilotConfig(db) {
  const snap = await db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC).get();
  return parsePilotConfig(snap.exists ? snap.data() : null);
}

// Création v2 autorisée pour ce partenaire ? (hors variable d'environnement, évaluée séparément)
const v2CreationAllowed = (config, sellerId) => config.creationOpen === true && config.ids.has(sellerId);

// Motif de refus lisible : distingue l'arrêt global (creationOpen) de l'absence du partenaire dans la liste.
function creationRefusal(config, sellerId) {
  if (config.creationOpen !== true) return { code: 'CREATION_CLOSED', message: 'Ces commandes sont momentanément indisponibles' };
  if (!config.ids.has(sellerId)) return { code: 'PARTNER_NOT_IN_PILOT', message: 'Ce partenaire n’accepte pas encore ce type de commande' };
  return null;
}

// Ancien parcours de création (sans devis serveur) refusé pour ce partenaire ? Exactement les partenaires pilotes : même
// définition que les règles Firestore, qui ne lisent ni creationOpen ni les variables d'environnement.
const legacyCreationBlocked = (config, sellerId) => config.ids.has(sellerId);

// ── Modification administrative ───────────────────────────────────────────────────────────────────────

class ConfigRefusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const PATCH_KEYS = Object.freeze(['pilotPartnerIds', 'creationOpen', 'managementFrozen']);
const PARTNER_ID = /^[A-Za-z0-9_-]{1,128}$/;
const MAX_PILOTS = 50;

function validateConfigChange(input) {
  const i = input && typeof input === 'object' ? input : {};
  const patch = i.patch && typeof i.patch === 'object' && !Array.isArray(i.patch) ? i.patch : null;
  if (!patch) throw new ConfigRefusal('INVALID_CONFIG', 'Modification manquante');
  const keys = Object.keys(patch);
  if (!keys.length || keys.some((k) => !PATCH_KEYS.includes(k))) throw new ConfigRefusal('INVALID_CONFIG', 'Champs de configuration invalides');
  const clean = {};
  for (const k of ['creationOpen', 'managementFrozen']) {
    if (k in patch) {
      if (typeof patch[k] !== 'boolean') throw new ConfigRefusal('INVALID_CONFIG', `${k} doit être un booléen`);
      clean[k] = patch[k];
    }
  }
  if ('pilotPartnerIds' in patch) {
    const list = patch.pilotPartnerIds;
    if (!Array.isArray(list) || list.length > MAX_PILOTS || list.some((id) => typeof id !== 'string' || !PARTNER_ID.test(id))
      || new Set(list).size !== list.length) {
      throw new ConfigRefusal('INVALID_CONFIG', 'Liste de partenaires pilotes invalide');
    }
    clean.pilotPartnerIds = [...list].sort();
  }
  if (!Number.isSafeInteger(i.expectedVersion) || i.expectedVersion < 0) throw new ConfigRefusal('INVALID_CONFIG', 'Version attendue invalide');
  const reason = typeof i.reason === 'string' ? i.reason.trim() : '';
  if (reason.length < 10 || reason.length > 300) throw new ConfigRefusal('INVALID_CONFIG', 'Justification de 10 à 300 caractères obligatoire');
  return { patch: clean, expectedVersion: i.expectedVersion, reason };
}

const view = (c) => ({ pilotPartnerIds: [...c.ids].sort(), creationOpen: c.creationOpen, managementFrozen: c.managementFrozen, version: c.version });

// Écrit la configuration dans UNE transaction : lecture, contrôle de version (modifications concurrentes), écriture et trace
// `lastChange` dans le document lui-même (le journal d'audit est écrit ensuite par l'appelant ; cette trace subsiste même si
// l'écriture du journal échoue). Retourne { before, after, reason }.
async function applyConfigChange({ db, uid, input, nowMs = Date.now() }) {
  const { patch, expectedVersion, reason } = validateConfigChange(input);
  const ref = db.collection(CONFIG_COLLECTION).doc(CONFIG_DOC);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const before = view(parsePilotConfig(snap.exists ? snap.data() : null));
    if (before.version !== expectedVersion) {
      throw new ConfigRefusal('CONFIG_CONFLICT', 'La configuration a changé entre-temps : rechargez-la avant de modifier');
    }
    const after = { ...before, ...patch, version: before.version + 1 };
    tx.set(ref, {
      pilotPartnerIds: after.pilotPartnerIds, creationOpen: after.creationOpen, managementFrozen: after.managementFrozen,
      version: after.version, updatedAtMs: nowMs, updatedBy: uid,
      lastChange: { by: uid, atMs: nowMs, reason, before, after },
    });
    return { before, after, reason };
  });
}

module.exports = {
  CONFIG_COLLECTION, CONFIG_DOC, MANAGEMENT_FREEZE_POLICY, creationEnabled, managementEnabled, parsePilotConfig, loadPilotConfig,
  v2CreationAllowed, creationRefusal, legacyCreationBlocked, ConfigRefusal, validateConfigChange, applyConfigChange,
};
