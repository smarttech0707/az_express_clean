# Mission 7E-71 — Plafonds des fonctions en préproduction (suppression de compte)

Date : 2026-11-06 · Projet cible `az-express-preprod` (n° 306761725053) · **Modifications locales uniquement, rien d'appliqué à distance.** Production `az-express-b0469` : aucune option modifiée (prouvé par test, §6).
Constats distants de référence (lectures du 2026-11-06, mission 7E-70) : quota `CpuAllocPerProjectRegion` `europe-west1` = **20 vCPU**, usage réel **illisible**, Σ(cpu×maxInstances) des 20 fonctions déployées = **17,5 vCPU**, marge théorique 2,5 vCPU. **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE.**

## 1. Configuration actuelle des quatre fonctions de garde (analyse locale du code)

Obtenue en chargeant `functions/index.js` avec `GCLOUD_PROJECT` = projet visé, comme le CLI Firebase (aucun réseau).

| Fonction | Type | CPU | Mémoire | `maxInstances` | Concurrence | Délai | Secrets |
|---|---|---|---|---|---|---|---|
| `initiateFeexPayPayment` | callable | défaut plateforme | défaut (256 MiB) | **aucun** (défaut plateforme) | défaut | défaut (60 s) | `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET` |
| `initiateWithdrawal` | callable | défaut | défaut | **aucun** | défaut | défaut | `FEEXPAY_TOKEN` |
| `aiConfirmAction` | callable | défaut | 256 MiB | **aucun** | défaut | 60 s | `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET` |
| `feexPayWebhook` | HTTPS | défaut | défaut | **aucun** | défaut | défaut | `FEEXPAY_WEBHOOK_SECRET`, `FEEXPAY_TOKEN` |

Faits sur les valeurs « défaut » :
- **CPU = 1 vCPU** : preuve empirique dans ce projet — les fonctions préproduction sans `cpu` explicite (ex. `acceptOrderCF`, `deliverOrderCF`) sont listées à `cpu 1` / 256 Mi par `firebase functions:list` et par Cloud Run.
- **`maxInstances` non posé = défaut plateforme (100 d'après la documentation des fonctions de 2ᵉ génération ; non vérifié ici faute de déploiement)**. Le code le dit lui-même : « un `maxInstances` par défaut ferait exploser le quota CPU Cloud Run » (`azia/index.js`). Empreinte théorique par fonction : 1 vCPU × 100 = **100 vCPU**, soit 400 pour les quatre, face à un quota de 20.
- Les appels sortants (FeexPay, vérification de statut) ont un délai de **20 s** (`index.js` l.492 et 750, `feexpayVerification.js`) ; le délai de la fonction est de 60 s.

## 2. Configuration préparée pour la préproduction (locale, non appliquée)

`pilotLightOptions()` (`functions/pilotCap.js`) renvoie, **seulement si `GCLOUD_PROJECT === 'az-express-preprod'`**, `{ maxInstances: 1, cpu: 0.25, concurrency: 1 }` ; sinon `{}`.

| Fonction | CPU | `maxInstances` | Concurrence | Mémoire / délai / secrets / région | Empreinte |
|---|---|---|---|---|---|
| `initiateFeexPayPayment` | **0,25** | **1** | **1** | inchangés | 0,25 |
| `initiateWithdrawal` | 0,25 | 1 | 1 | inchangés | 0,25 |
| `aiConfirmAction` | 0,25 | 1 | 1 | inchangés (256 MiB, 60 s) | 0,25 |
| `feexPayWebhook` | 0,25 | 1 | 1 | inchangés | 0,25 |
| **Total** | | | | | **1,0 vCPU** |

Câblage : `index.js` (3 fonctions, `...pilotLightOptions()`), `azia/pendingActions.js` (nouveau paramètre `options` de `buildConfirmAction`, vide par défaut) et `azia/index.js` (`options: pilotLightOptions()`). Aucune autre fonction ne change : le manifeste complet (135 points d'entrée) a été comparé avant/après — **seules ces quatre diffèrent**.

### Justification des valeurs (aucune n'est arbitraire)

| Valeur | Raison | Contrainte vérifiée |
|---|---|---|
| `maxInstances: 1` | Sans maximum, la plateforme réserve jusqu'à 100 instances ; en préproduction `PILOT_MAX_INSTANCES=1` est déjà la politique du pilote (`pilotCap.js`). Les essais portent sur des comptes synthétiques, un seul acteur à la fois. | quota 20 vCPU |
| `cpu: 0.25` | Valeur la plus faible qui garde la totalité du lot P1+P2 sous la limite : 17,5 + 1,25 + 1,0 = **19,75 ≤ 20**. Avec 0,5 : 20,75 ✗ ; avec 1 : 22,75 ✗. Les 4 fonctions de suppression utilisent déjà 0,25 à 0,5. | arithmétique ci-dessous |
| `concurrency: 1` | Une fraction de vCPU impose la concurrence 1 en 2ᵉ génération ; elle est aussi **explicite** pour que la CLI n'ait pas à la deviner. | règle de la plateforme (Firebase CLI) |
| Mémoire, délai, secrets, région | Non modifiés : aucune raison de toucher à ce qui conditionne la correction fonctionnelle. | — |

Arithmétique (préproduction) : 17,5 (existant) + 1,25 (P1, 4 fonctions de suppression) + 1,0 (P2, ces 4 gardes) = **19,75 vCPU**, **marge théorique 0,25 vCPU (1,25 %)**. Elle ne répond **pas** à l'exigence « marge de capacité suffisante » ; voir §4 (décision humaine).

## 3. Impact sur les traitements financiers et les webhooks

- **Exactitude financière : inchangée.** Aucun garde-fou d'argent ne dépend du nombre d'instances : tout passe par des transactions Firestore (lecture avant écriture, plafonnement du solde, idempotence du webhook, quarantaine relue dans la transaction). Les tests de concurrence 7E-69 (A, A2, B, B2, C1-C3, D, E) s'exécutent contre Firestore, pas contre Cloud Run.
- **Débit : volontairement limité.** Une instance, une requête à la fois : les appels sont **sérialisés**. Un appel FeexPay lent (jusqu'à 20 s) retarde les suivants ; au-delà de la file d'attente de la plateforme, un appel peut recevoir un refus de capacité (429/503). Comportement de la file **à observer au premier essai** (non vérifiable sans déploiement).
- **Webhooks FeexPay** : en préproduction FeexPay reste `DISABLED` — **aucun webhook réel n'arrive** ; les appels sont des essais manuels. Si un fournisseur réel réessayait un webhook refusé pour capacité, l'idempotence (statuts `completed` / `held_for_review` traités comme « déjà traité ») empêche tout double effet.
- **Conséquence de test (limite honnête)** : avec `concurrency: 1` et `maxInstances: 1`, le scénario 17 « deux webhooks concurrents » de la matrice 7E-70 est **sérialisé par la plateforme** : il ne démontre pas une exécution réellement simultanée. La concurrence réelle est couverte seulement par les tests d'émulateur (qui eux-mêmes ne prouvent pas Firestore de production).
- **Démarrage à froid** : 0,25 vCPU pour charger un `index.js` de 135 fonctions (SDK Anthropic, OpenAI, firebase-admin) peut allonger le premier appel de plusieurs secondes. Le délai de 60 s est conservé ; **risque à observer**, pas à supposer.
- **Valeur 0,25 non encore éprouvée dans ce projet** : seules 0,5 et 1 sont observées sur les 20 fonctions préproduction ; 0,25 est utilisée par le code des fonctions de suppression mais jamais déployée à ce jour.

## 4. Choix qui relèvent d'une décision humaine (options présentées, aucune appliquée)

| Option | Effet | Coût |
|---|---|---|
| **A — retenue en local** : 4 gardes à 0,25 / max 1 / concurrence 1 | tient dans 19,75 sur 20 | marge 0,25 vCPU seulement ; concurrence du webhook non testable |
| B — webhook à 1 vCPU, concurrence par défaut ; 3 autres à 0,25 | concurrence réelle du webhook | 20,5 > 20 ✗ sans libération de capacité |
| C — A, mais seulement après libération de capacité (ex. retirer les 3 `notify*` du pilote, **désactivés** : `NOTIFICATIONS_SEND=off`) | marge portée à ≈ 3,25 vCPU | opération **distante** sur le pilote fermé : décision séparée |
| D — A, après hausse de quota demandée par un humain | marge confortable | demande à l'équipe GCP, hors périmètre |
| E — déployer P2 en deux temps (`aiConfirmAction` + `initiateWithdrawal`, puis `initiateFeexPayPayment` + `feexPayWebhook`) | lissage du risque | plus d'étapes |

**Recommandation** : A pour l'état local (déjà préparé), **et** décision humaine sur C ou D avant d'autoriser P2. Le script de déploiement exige `-MinMarginVcpu` explicite pour accepter une marge inférieure à 0,5 vCPU : P2 sera refusé par défaut tant qu'une décision n'est pas prise.

## 5. Compatibilité avec les limites du projet préproduction

| Limite | Valeur lue | Vérification |
|---|---|---|
| CPU Cloud Run `europe-west1` | 20 vCPU | 19,75 théorique (marge 0,25) — usage réel non lisible |
| Mémoire Cloud Run `europe-west1` | 40 GiB | 8 fonctions × 256 MiB = 2 GiB, très sous la limite |
| Révisions actives | 4 000 | 28 services au total, sans objet |
| Services | 1 000 | sans objet |
| Nouvelles fonctions (pas de révision antérieure) | — | pas de doublement transitoire |

## 6. Production inchangée — preuves

- `pilotLightOptions({ GCLOUD_PROJECT: 'az-express-b0469' })` renvoie `{}` (test unitaire), de même pour variable absente, `az-express-clean`, `az-express-preprod-1`, `demo-*`.
- Analyse de `index.js` avec `GCLOUD_PROJECT=az-express-b0469` : `cpu`, `maxInstances`, `concurrency` **absents** pour les 4 fonctions ; `aiConfirmAction` garde 256 MiB / 60 s ; région `europe-west1` partout (test `gardes financières — production`).
- Analyse avec l'identifiant préproduction : 1 / 0,25 / 1, mémoire, délai, secrets et région identiques à la production (test `gardes financières — préproduction`).
- Remarque : en production, ces quatre fonctions restent **sans plafond dans le code** ; un redéploiement de production ne les plafonne pas (état préexistant, hors périmètre).

## 7. Réversibilité

Supprimer le spread `...pilotLightOptions()` (3 endroits) et le paramètre `options` rétablit exactement l'état précédent ; `pilotLightOptions` peut rester inutilisé. Rien n'est déployé.
