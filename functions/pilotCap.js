// Plafond d'instances propre à la PRÉPRODUCTION (Mission 7E-9). Le Firebase CLI exécute index.js à l'analyse avec
// GCLOUD_PROJECT = identifiant du projet visé (vérifié dans firebase-tools/lib/functions/env.js : loadFirebaseEnvs), puis charge
// `.env` et `.env.<projectId>`. Le plafond ne s'applique donc QUE si le projet est exactement `az-express-preprod` ; pour tout
// autre projet (production comprise), les valeurs d'origine sont renvoyées telles quelles.
const PREPROD_PROJECT = 'az-express-preprod';
const DEFAULT_PILOT_MAX_INSTANCES = 1;

// null = aucun plafond (tout projet autre que la préproduction).
function pilotInstanceLimit(env = process.env) {
  if (env.GCLOUD_PROJECT !== PREPROD_PROJECT) return null;
  const n = Number(env.PILOT_MAX_INSTANCES);
  return Number.isInteger(n) && n >= 1 && n <= 100 ? n : DEFAULT_PILOT_MAX_INSTANCES;
}

// Valeur d'origine en dehors de la préproduction ; jamais plus que la valeur d'origine.
function capInstances(original, env = process.env) {
  const limit = pilotInstanceLimit(env);
  return limit === null ? original : Math.min(original, limit);
}

// Fonctions qui n'ont AUCUN maxInstances dans le code (valeur par défaut de la plateforme) : un maximum explicite n'est posé qu'en
// préproduction ; ailleurs les options restent vides, donc inchangées.
function pilotOnlyInstanceOptions(env = process.env) {
  const limit = pilotInstanceLimit(env);
  return limit === null ? {} : { maxInstances: limit };
}

module.exports = { PREPROD_PROJECT, pilotInstanceLimit, capInstances, pilotOnlyInstanceOptions };
