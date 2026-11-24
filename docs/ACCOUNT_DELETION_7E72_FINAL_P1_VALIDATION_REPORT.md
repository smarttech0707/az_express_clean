# Mission 7E-72 — Validation finale du périmètre P1 avant commit

Date : 2026-11-07 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · Préproduction `az-express-preprod` (306761725053) · Production `az-express-b0469` : jamais touchée.
**Aucune commande distante, aucun déploiement, aucune activation de `operations_control/account_deletion`, aucun commit/push/reset, aucun secret modifié.** Validations locales et émulateurs `demo-*` uniquement. Documents liés : `…EKBINE_CONCURRENCY_ANALYSIS`, `…NODE22_FINAL_TESTS`, `…EKCLIENTCONFIRMORDER_AUDIT`, `…COMMIT_FINAL_MANIFEST`, `…P1_CAPACITY_REVIEW`.

## 1. Verdict

# PRÊT SOUS CONDITIONS

Le périmètre P1 (4 fonctions de suppression) est techniquement cohérent, validé sous Node 22 et sous Node 24, et le code est prêt à être soumis à revue de commit. Quatre conditions restent ouvertes :

| # | Condition | Nature |
|---|---|---|
| 1 | **Quota Cloud Run non confirmé** — relevé humain en console (document de capacité §5) | bloque l'autorisation de déploiement |
| 2 | **Test d'émulateur E-Kbine « 8 appels »** en échec dans 2 suites complètes sur 4 ; cause du déclenchement **non établie** (code de création non fautif : même erreur sur `HEAD`) | bloque la déclaration « suite verte » ; **n'est pas un bloquant de sécurité P1** |
| 3 | `dispatchRetry.emulator` (« trois passes simultanées en phase 2 ») échoue dans toutes les suites complètes depuis 7E-69 | préexistant, hors périmètre |
| 4 | Aucun commit : le script de déploiement refuse un arbre sale | décision humaine (manifeste final) |

## 2. Résumé des résultats

| Domaine | Résultat |
|---|---|
| Investigation E-Kbine | Mécanisme identifié (erreur de l'émulateur `INVALID_ARGUMENT / Transaction is invalid or closed`, non relancée par le SDK, reproduite aussi sur le code de `HEAD`) ; aucun écart financier dans aucune ronde ; déclencheur en suite complète **non établi**. Aucune assertion assouplie, aucun retry ajouté. |
| Node 22.23.4 | `npm ci` PASS (0 différence de versions avec le dépôt) ; manifeste de 135 points d'entrée identique à Node 24 ; règles suppression **63/63**, principales **470/470**, Storage **128/128** ; suite complète émulateurs **2274/2323**, 47 ignorés, 2 échecs (ceux de la ligne ci-dessus). |
| Node 24.22.1 | 2 suites complètes : **2275/2323**, 47 ignorés, 1 échec (`dispatchRetry`). |
| Défaut `restaurantV2Preprod.test.js:121` | cause confirmée (rapporteur) ; correctif d'une ligne appliqué et testé : 12/12 sous Node 22 et Node 24. |
| `ekClientConfirmOrder` | défaut réel : agent bénéficiaire non relu contre le tombstone → **corrigé** localement ; 11 tests (6 échouent sur `HEAD`). Inatteignable en P1 (agents hors périmètre partenaires). |
| `ekCreateOrderCF` | défaut réel découvert : aucune garde de quarantaine pour un client (création hors wallet possible) → **corrigé** (1 ligne) et testé. |
| Capacité P1 | plafonds raisonnables pour un pilote synthétique ; marge recommandée 1,0 vCPU ; **quota non confirmé**. |
| Commits | 5 commits proposés, séparabilité vérifiée par reconstitution (sans toucher Git) ; commandes exactes fournies. |
| Script de déploiement | simulations : production, ancien identifiant et numéro de production **refusés** ; pas de Hosting, pas de « toutes les fonctions ». |

## 3. Statut de chaque test (PASS / FAIL / SKIP / NON VÉRIFIÉ)

| Test / suite | Node | Résultat | Statut |
|---|---|---|---|
| E-Kbine : 54 tests (`ekbineQuarantineGuards` 11, `ekbineOrders`, `ekbineDepositFlow`, `ekbineReconciliation`), faux Firestore | 24 | 54/54 | PASS |
| `ekbineQuarantineGuards` sur `ekbineOrders.js` de `HEAD` | 24 | 5/11 | FAIL attendu (preuve du défaut) |
| `restaurantV2Preprod.test.js` | 22 / 24 | 12/12 / 12/12 | PASS |
| Règles de suppression (4 fichiers) | 22 | 63/63 | PASS (24 : 63/63 en 7E-71) |
| Règles Firestore principales | 22 | 470/470 | PASS |
| Règles Storage | 22 | 128/128 | PASS |
| Suite complète émulateurs | 22 | 2274/2323 ; 2 FAIL ; 47 SKIP | **FAIL (2)** |
| Suite complète émulateurs, exécution 1 / exécution 2 | 24 | 2275/2323 ; 1 FAIL ; 47 SKIP (×2) | **FAIL (1, préexistant)** |
| `financialConcurrency` seul | 24 | 12/12 ×3 (7E-71) | PASS |
| Sonde E-Kbine 40 rondes × 8 appels (code actuel) | 24 | 37/40 | FAIL (3 rondes ; wallet 4000 et 1 commande à chaque fois) |
| Même sonde sur `HEAD:ekbineOrders.js` | 24 | 38/40 | FAIL (2 rondes) |
| `passwordHash.test.js` « tampered hash » | 24 | échec 1× dans une reconstitution de test (probabiliste, ~1/256) ; 6/6 en exécution isolée | PASS (test intermittent préexistant) |
| 47 tests (Storage, `AZ_E2E_RULES`) | 22 / 24 | non exécutés | SKIP |
| Build `nodejs22` réel (Cloud Build), `npm ci` avec le npm de Cloud Build | — | non exécutés | NON VÉRIFIÉ |
| Tests d'appareil / émulateur mobile, Firestore de production | — | non exécutés | NON VÉRIFIÉ |
| Exécution réelle du script de déploiement | — | interdite | NON VÉRIFIÉ |

## 4. Corrections locales réalisées (non commitées)

| Fichier | Modification | Pourquoi |
|---|---|---|
| `functions/ekbineOrders.js` | +2 appels `assertNewAccountActivity` (confirmation : agent ; création : client) | défaut « action après quarantaine » démontré par test sur `HEAD` |
| `functions/test/ekbineQuarantineGuards.test.js` | **nouveau**, 11 tests | agent normal / en quarantaine / tombstone absent / lecture en erreur / course / double confirmation / commande terminée |
| `functions/test/restaurantV2Preprod.test.js` | rapporteur du fils forcé (`spec`) | défaut de test Node 22 (aucune assertion métier changée) |
| `test-env/deploy-account-deletion-preprod.ps1` | marge de quota par défaut 0,5 → 1,0 | alignement sur la recommandation de capacité |
| `docs/ACCOUNT_DELETION_7E72_*.md` | 6 documents | livrables |

Rien d'autre n'a été modifié : plafonds de production inchangés, versions de dépendances inchangées, règles Firestore/Storage inchangées.

**Incident d'outillage, corrigé** : une copie `robocopy` mal paramétrée (PowerShell traite `$D` et `$d` comme une seule variable) a créé des copies parasites dans le dépôt (`functions/functions`, `docs/docs`, `rules-tests/rules-tests`, `test-env/test-env`, `lib/lib`, `scripts/scripts`, 12 fichiers à la racine de `scripts/`). Vérifié non suivi par Git et identique aux originaux (`cmp`), puis supprimé ; `git status` confirmé conforme. Les résultats obtenus pendant sa présence ont été écartés et les suites rejouées. Les dossiers `.scratch_shots`, comptes partenaires, `.aab`, patch, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `web/downloads/` et l'émulateur personnel (ports 8080, etc.) n'ont pas été touchés.

## 5. Contrôle de sécurité P1 (étape 7)

Constat par lecture du code (`accountDeletion.js`, `accountDeletionSupport.js`, `accountCleanup.js`, `accountAdmission.js`, `index.js:90-100`) et des règles ; **aucun de ces points n'est prouvé par un test unitaire seul** : les preuves sont des tests d'émulateur (Firestore, Auth, Storage réels émulés) **et** la lecture du code ; rien n'a été testé contre un Firebase réel.

| Contrôle | Constat | Preuve / limite |
|---|---|---|
| Réauthentification | `auth_time` ≤ 300 s exigé pour valider le consentement ; sinon le dossier reste `reauthentication_required` sans traitement | tests `accountDeletionHardening` ; `auth_time` d'un jeton réel non rejoué hors émulateur |
| Contrôle de rôle | rôles admis dans le moteur P1 : `client`, `livreur` seulement ; tout autre rôle (partenaire) → bloqué `role_obligations_review_required` tant que `partnerInventoryVersion !== 1` ; identité du profil établie par `readDeletionIdentity` | tests + règles ; périmètre partenaires **fermé** en pilote |
| Rate limiting | 5 demandes/h/compte, 10 par dossier, 60 s d'absorption, suivi 30/10 min après vérification du jeton ; refus (`RATE_LIMITER_REQUIRED`) si aucun limiteur n'est injecté | tests ; limiteur Firestore réel non rejoué |
| Idempotence | un dossier par UID (`account_deletions/{uid}`) ; rejeu absorbé ; bail 180 s ; suppression Auth idempotente (`user-not-found` attendu) | tests de concurrence C1-C3 (émulateur) |
| Audit | `auditStrict` (propage l'échec) **avant** l'étape irréversible ; `auditInfo` pour le reste ; support : `support_events` | tests ; audit réel non vérifié en préproduction |
| Quarantaine | tombstone + `isSuspended` ; 15 min de calme ; `assertNewAccountActivity` relu dans chaque transaction financière ; règles Firestore : `isAuth()` refuse tout compte avec tombstone ; storage : mention du tombstone | tests A/A2/B/B2/C (émulateur) ; **lacunes comblées en 7E-72 : E-Kbine création et confirmation** |
| Solde / retraits | `wallet` entier et nul ; `debt`, `pendingBalance`, `reservedBalance`, `pendingWithdrawal`, `commissionDebt` nuls ; requêtes `wallet_transactions`, `withdrawal_requests` : statut non terminal ou `needsReview`/`refundPending` → bloqué (`financial_regularization_required`) | tests ; seuls les 200 premiers documents liés sont examinés (au-delà : revue manuelle) |
| Commandes | `orders`, `boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`, `ekbine_orders` : statut non terminal → bloqué | tests |
| Administrateurs | un UID présent dans `admins` n'est jamais traité (`admin_account_manual_process`), dès la demande **et** dans `process` ; `manageAccountDeletionCF` réservé aux super-administrateurs, jamais à un sous-administrateur ni à un compte inactif | tests ; Auth réel non rejoué |
| Erreurs Firestore | toute exception de `process` → `failurePatch` (6 échecs puis arrêt), jamais de fin de dossier ; lecture de tombstone en échec → transaction en échec | tests dont fail-closed |
| Avant suppression Auth | `inspectCleanup` (élément inconnu → revue manuelle, compte intact) puis audit strict, puis `disabled`, révocation, suppression, **relecture** (`AUTH_DELETION_NOT_CONFIRMED`) | tests |
| Avant anonymisation | nouvelle `inspect` dans la transaction finale ; champs financiers conservés ; seuls les champs personnels listés sont effacés | tests |
| Nettoyage AZ IA | effacement par UID (`eraseAiData`) ; consentement, actions confirmées et exécutions d'outils **conservés** | tests ; **conservations non validées juridiquement** |
| Passerelle de configuration | `operations_control/account_deletion` doit avoir `enabled === true` **et** `inventoryVersion === 1`, sinon aucune quarantaine ni suppression (fail-closed) ; aucune règle Firestore pour `operations_control` → inaccessible aux clients (défaut refus) | tests ; **le document n'existe pas et n'a pas été créé** |

Écart à signaler (non bloquant P1 synthétique, à trancher avant toute activation) : pour le rôle **livreur**, `requestAccountDeletionCF` pose `deletionRequested: true` sur le profil dès une demande réauthentifiée, **même quand la passerelle est fermée** ; le livreur est alors refusé par les gardes de nouvelles activités alors que son dossier attend `server_rollout_not_enabled`. Sans effet pour un pilote de comptes `t7e-del-*` ; à décider (poser le marqueur seulement quand la passerelle est ouverte) avant tout usage avec de vrais comptes.

## 6. Risques

### Bloquants pour P1
Aucun bloquant technique de sécurité connu après 7E-72 (suppression prématurée, perte de données, suppression d'un administrateur, corruption financière, action après quarantaine sur les fonctions P1 : couverts et testés). Restent des **préconditions d'autorisation** :
- **Quota non confirmé** → *déploiement non autorisé sur cette base*.
- **Déploiement sur la mauvaise cible / surcharge** : couvert par le script (refus de la production, liste blanche) mais **chemin réel jamais exécuté**.
- **Arbre non commité** : le script refuse l'exécution réelle.

### Bloquants pour l'activation complète
- Outil de résolution `held_for_review` absent (un paiement réel tardif serait retenu sans issue).
- Revue métier E-Kbine, partenaires et AZ IA non signée.
- Durées légales de conservation non validées (consentement IA, actions confirmées, pièces financières, pages légales).
- Marqueur `deletionRequested` posé avec la passerelle fermée (§5).
- Test d'émulateur E-Kbine non fiabilisé ; test `dispatchRetry` en échec.

### Reportables (justifiés)
| Point | Justification |
|---|---|
| Échec E-Kbine en suite complète | n'affecte ni le code P1 ni l'argent (aucune écriture incorrecte observée) ; fonction hors P1 |
| `dispatchRetry` | préexistant, module de dispatch sans lien avec la suppression |
| `passwordHash` probabiliste (1/256) | préexistant, test seulement |
| CI en Node 20 | pas de déploiement par la CI ; aligner avant release |
| Latence/démarrage à froid à 0,25 vCPU | non mesurable localement ; à observer lors du premier essai préproduction |
| `ekCancelOrderCF` non modifié | pas d'activité nouvelle ; commande non terminale refusée par le moteur ; non testé sur émulateur |

## 7. Capacité et quota (rappel)

> **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**

Quota annoncé 20 vCPU ; usage réel non confirmé ; P1 théorique 18,75 ; P1 + P2 théorique 19,75 (marge 0,25, insuffisante). **Marge recommandée : 1,0 vCPU.** Informations à relever manuellement : voir `…P1_CAPACITY_REVIEW.md` §5. Aucune augmentation de quota demandée.

## 8. Décisions qui nécessitent votre autorisation

1. **Valider (ou refuser) les corrections locales E-Kbine** (`ekbineOrders.js` + `ekbineQuarantineGuards.test.js`) : y compris le choix métier « agent fermé ⇒ la confirmation du client est refusée » ou « terminée sans crédit avec signalement ».
2. **Valider le manifeste des 5 commits** (ou en retirer le commit 2 pour le différer). Aucun commit n'est fait.
3. **Quota** : faire relever l'usage réel par un humain, puis décider du lot P1 seul ou de P1 + P2 (options A à E de 7E-71).
4. **Test E-Kbine « 8 appels »** : accepter son intermittence documentée, ou autoriser son aménagement (rafales de 2-4 appels, ou comptage explicite du rejet d'émulateur) — change l'assertion.
5. **Marqueur `deletionRequested` du livreur** avec passerelle fermée : le poser seulement passerelle ouverte (modification de `accountDeletion.js`) ?
6. Avant toute activation : outil `held_for_review`, revue métier, durées de conservation.

## 9. Proposition de prochaine étape

1. Autorisation distincte de **commits 1 → 5** (aucun fait).
2. Relevé humain du quota ; mise à jour du statut de quota.
3. Autorisation distincte de la **simulation** du script, puis de l'exécution de P1 seul (`-Stage functions-deletion`).
4. P2 et la création de `operations_control/account_deletion` : autorisations distinctes ultérieures.

*Aucun commit. Aucun push. Aucun déploiement. Aucune activation. Aucune modification distante. En attente d'une autorisation distincte.*
