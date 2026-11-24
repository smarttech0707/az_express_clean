# Mission 7E-72 — Revue de capacité du périmètre P1 (préproduction)

Date : 2026-11-07 · **Aucune commande distante exécutée.** Sources : seules les preuves recueillies en 7E-70 et 7E-71 (`ACCOUNT_DELETION_7E70_PREPROD_PREPARATION_REPORT.md`, `ACCOUNT_DELETION_7E71_PREPROD_FUNCTION_LIMITS.md`) et le code du dépôt.

## 1. Statut du quota

> **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**

| Donnée | Valeur | Provenance / fiabilité |
|---|---|---|
| Quota `CpuAllocPerProjectRegion`, `europe-west1` | 20 vCPU | relevé en 7E-70 ; fiable pour la limite |
| Usage réel actuel | **inconnu** | non lisible par API ; modèle de travail Σ(cpu × maxInstances) = 17,5 — **non prouvé** |
| Coût P1 théorique | 1,25 vCPU (0,5 + 3 × 0,25) | calculé d'après le code |
| P1 total théorique | 18,75 vCPU | **théorique, pas une capacité disponible** |
| P1 + P2 total théorique | 19,75 vCPU | marge 0,25 |

Ces chiffres sont des **projections d'un modèle non démontré**, pas de la capacité libre.

## 2. Plafonds P1 (vérifiés dans `functions/index.js:94-98`)

| Fonction | Type | cpu | maxInstances | concurrency | mémoire | timeout |
|---|---|---|---|---|---|---|
| `requestAccountDeletionCF` | callable | 0,5 | 1 | 1 | 256 MiB | 120 s |
| `getAccountDeletionStatusCF` | callable | 0,25 | 1 | 1 | 256 MiB | 30 s |
| `retryAccountDeletions` | planifiée (15 min) | 0,25 | 1 | 1 | 256 MiB | 120 s |
| `manageAccountDeletionCF` | callable (super-admin) | 0,25 | 1 | 1 | 256 MiB | 120 s |

(Plafonds identiques en production : ils sont fixés dans le code, pas conditionnés au projet.)

## 3. Le plafond est-il raisonnable pour un pilote synthétique ?

**Oui pour P1, sous les hypothèses ci-dessous.** Un pilote de préproduction n'a que des comptes `t7e-del-*` : quelques demandes par heure (le limiteur autorise 5 demandes/heure/utilisateur, 10 par dossier).

| Critère | Évaluation |
|---|---|
| `maxInstances 1` | Une seule instance par fonction : débit serialisé, aucune amplification de charge. Au pire, les requêtes simultanées attendent ou reçoivent un 429. Acceptable pour un test à débit faible. |
| CPU 0,25 / 0,5 | Les traitements sont des E/S Firestore et Auth, peu de calcul. 0,25 vCPU ralentit l'initialisation Node et les appels gRPC ; `requestAccountDeletionCF` à 0,5 porte le traitement le plus long (transaction + Auth + effacement). **Latence réelle non mesurée.** |
| `concurrency 1` | Requis par Cloud Run Gen2 pour cpu < 1 ; un appel à la fois par instance. Un dossier lent bloque les suivants jusqu'à son terme (≤ 120 s). |
| Mémoire 256 MiB | Charge faible (pages de 20 dossiers max). Pas de signal de risque, **non mesuré en conditions réelles**. |
| Timeout | `status` 30 s (lecture d'un document + limiteur) correct. `request` / `manage` 120 s : traitement d'un dossier + effacements Storage ; reprise possible (bail 180 s, idempotent). `retryAccountDeletions` : 20 dossiers max par passage ; à 0,25 vCPU un passage plein peut dépasser 120 s → le reste est repris au tour suivant (15 min). Acceptable pour un pilote, pas pour une activation de masse. |
| Démarrage à froid | Probablement de plusieurs secondes à 0,25 vCPU (chargement de `index.js`, 131 modules, SDK Admin). Premier appel plus lent ; aucune alerte attendue puisque le client attend la réponse. **Non mesuré.** À observer lors du premier essai. |
| Saturation | Les 4 fonctions sont indépendantes et plafonnées ; aucun risque de saturer le quota *par elles-mêmes* (1,25 vCPU). Le risque vient de la **somme** avec les 57 autres fonctions et de la marge, pas du comportement de ces fonctions. |
| Traitements simultanés | Plusieurs suppressions simultanées : sérialisées par `maxInstances 1`. Le planificateur et un appel manuel peuvent se chevaucher : géré par le bail du dossier (`leaseUntil`). |

## 4. Marge de sécurité recommandée

- **Marge minimale recommandée : 1,0 vCPU** (5 % du quota) *après* le coût du lot. Elle absorbe : l'imprécision du modèle (cpu par défaut supposé 1, absence de `maxInstances` interprétée comme 100), une révision de fonction pendant le déploiement (Cloud Run garde l'ancienne révision jusqu'à la bascule), et l'écart entre calcul et facturation de quota.
- **P1** : exige un usage relevé ≤ **17,75 vCPU** (20 − 1,25 − 1,0). Modèle de travail : 17,5 → marge 1,25 : **compatible, sans confirmation**.
- **P1 + P2** : 19,75 → marge 0,25 < 1,0 : **non recommandé**. Le script refuse ce cas par défaut.
- Le défaut du script (`MinMarginVcpu` 0,5) a été relevé à **1,0** en 7E-72 pour s'aligner sur cette recommandation (modification locale, script jamais exécuté en réel).

## 5. Ce qu'un opérateur doit relever à la main dans la console GCP

À faire par un humain, **sur le projet `az-express-preprod` (n° 306761725053)**, en lecture seule, avant toute autorisation de déploiement :

1. Console GCP → *IAM et administration* → *Quotas et limites système* → filtrer sur le service **Cloud Run Admin API**, région **europe-west1**, métrique **« Total CPU allocation, per project per region »** (`CpuAllocPerProjectRegion`). Relever **la limite** et **l'usage actuel (graphique « usage maximal sur 7 jours » et valeur instantanée)**.
2. Noter la date et l'heure du relevé et si l'usage inclut des révisions en cours de bascule.
3. Console Cloud Run (europe-west1) : liste des services `az-express-preprod` avec **CPU** et **instances maximum** par service ; vérifier que la somme Σ(cpu × instances max) est cohérente avec l'usage du point 1 (valide ou invalide le modèle de travail).
4. Relever le **nombre de services** et s'il existe d'autres charges Cloud Run non-Functions dans le projet (consommatrices du même quota).
5. Vérifier qu'aucune demande d'augmentation de quota n'est en cours (cette mission **n'en demande aucune**).

Décision : P1 est acceptable si `(usage relevé) + 1,25 ≤ 20 − 1,0`. Sinon, ne pas déployer et choisir parmi les options A à E du document 7E-71.

## 6. Conclusion

- Les plafonds P1 sont **raisonnables** pour un pilote synthétique à faible volume.
- Le déploiement reste **non autorisé sur cette base** : l'usage réel n'est pas confirmé.
- Limites connues : démarrage à froid, latence et saturation réelles non mesurées ; le modèle Σ(cpu × maxInstances) n'est pas démontré.
