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

// Fonctions de garde financières (Mission 7E-71 : initiateFeexPayPayment, initiateWithdrawal, aiConfirmAction, feexPayWebhook) :
// sans maximum explicite la plateforme en réserve 100 et le quota CPU régional de la préproduction (20 vCPU) serait dépassé.
// Préproduction seulement : 1 instance, 0,25 vCPU (empreinte 0,25 par fonction) et 1 requête par instance — une fraction de vCPU
// impose concurrency 1 en 2e génération. L'exactitude financière ne dépend pas de ces valeurs (transactions Firestore) ; elles ne
// limitent que le débit, négligeable pour des comptes synthétiques. Ailleurs : options vides, donc production inchangée.
const PILOT_LIGHT_OPTIONS = Object.freeze({ maxInstances: 1, cpu: 0.25, concurrency: 1 });
function pilotLightOptions(env = process.env) {
  return pilotInstanceLimit(env) === null ? {} : { ...PILOT_LIGHT_OPTIONS };
}

// Réessai automatique d'un déclencheur : la préproduction garde la politique sans réessai déjà déployée (Mission 7E-25) ; tout autre
// projet conserve la valeur d'origine du code. Un réessai relancerait aussi sans fin un échec permanent, facturé à chaque tentative.
function pilotRetry(original, env = process.env) {
  return env.GCLOUD_PROJECT === PREPROD_PROJECT ? false : original;
}

module.exports = { PREPROD_PROJECT, PILOT_LIGHT_OPTIONS, pilotInstanceLimit, capInstances, pilotOnlyInstanceOptions, pilotLightOptions, pilotRetry };
