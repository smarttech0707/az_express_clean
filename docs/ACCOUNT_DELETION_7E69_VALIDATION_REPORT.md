# Mission 7E-69 — Validation finale locale et préparation à la préproduction

Date : 2026-11-06 · Branche `finalisation/az-express` (HEAD `aa3d1b0`, rien de commité) · Production `az-express-b0469` : **lecture seule, jamais ciblée**. Préproduction `az-express-preprod` (n° 306761725053) : existe, **non modifiée**.
Rien n'a été déployé, activé, commité, poussé ni modifié à distance. Aucune donnée réelle, aucun paiement réel.

## 1. Résumé exécutif

- Les corrections 7E-68 tiennent : 0 échec sur la suite fonctions, sur les 63 tests de règles de la famille suppression, 470 tests de règles principaux et 128 tests Storage.
- 9 tests de concurrence ont été ajoutés et exécutés sur un **vrai émulateur Firestore** (transactions réelles) : 9/9 réussis. Aucun double crédit, aucun solde négatif, aucune action exécutée après le tombstone.
- Un changement a été fait pendant 7E-69 : le webhook FeexPay lit désormais profil et tombstone **en parallèle** dans sa transaction (la lecture séquentielle provoquait des erreurs de contention dans l'émulateur : 2/12 contre 0/40 après).
- Un échec **préexistant, sans lien** : `test/dispatchRetry.emulator.test.js` (« trois passes simultanées en phase 2 »), fichier non touché.
- Écarts restants : outil de résolution des paiements `held_for_review` inexistant, revues métier E-Kbine / partenaires / AZ IA non signées, quota Cloud Run `NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ`, tests dépendant d'Auth/Storage non exécutés.
- **Verdict : PRÊT SOUS CONDITIONS** pour une phase de validation en préproduction (voir §14). Production : non couverte, non autorisée.

## 2. État Git initial

Branche `finalisation/az-express`, HEAD `aa3d1b0`. Fichiers modifiés et non suivis conformes à l'instantané de début de session (code 7E-64/68/69, docs 7E-66→69). Fichiers hors périmètre non touchés : `.aab`, `AZ_Express_Windows_to_Mac_Validated.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `qr-release/`, `scripts/maintenance/`, `test-env/.emulators.pid`, `web/downloads/`, `.firebase/hosting.*.cache`. Sauvegardes pré-7E-68 dans le dossier temporaire de session (hors dépôt). Projets Firebase : `az-express-b0469` est le projet « current » (`.firebaserc` par défaut) ; `az-express-preprod` présent. Aucune commande `firebase` n'a été lancée sans émulateur ou sans `--project demo-*`, hors `projects:list` / lectures.

## 3. Tests unitaires (sans émulateur)

| Commande | Tests | Réussis | Échecs | Ignorés |
|---|---|---|---|---|
| `npm test` (dans `functions/`) | 2300 | 2134 | 0 | 166 |
| Ciblée : feexpayPayments, accountAdmission, accountQuarantineIndex, accountQuarantineGuards, adminPartnerAccounts, passwordReset, accountDeletionHardening | 322 | 322 | 0 | 0 |

Les 166 ignorés exigent un émulateur (Firestore/Auth/Storage) ou `AZ_E2E_RULES=1` : **ils ne sont pas comptés comme réussis** ; la partie Firestore est couverte au §5.

Les quatre tests affectés par 7E-68 :
- `adminPartnerAccounts` (2) : message d'erreur changé par erreur → **code corrigé**, assertions inchangées.
- `passwordReset` (2) : le double de référence n'avait pas `get` → **double étendu**, assertions inchangées.
Couverture non réduite : aucune assertion supprimée ni affaiblie.

## 4. Tests des règles Firestore / Storage

| Suite | Résultat |
|---|---|
| `rules-tests/account-deletion*.test.js` (3 fichiers + lifecycle, émulateur dédié 8198/9198/9298, projet `demo-account-deletion`) | 63 réussis, 0 échec, 0 ignoré |
| Règles principales | 470 réussis, 0 échec, 0 ignoré |
| Storage | 128 réussis, 0 échec, 0 ignoré |

Les trois fichiers de suppression exigent `FIRESTORE_EMULATOR_HOST=127.0.0.1:8198` et refusent toute autre cible.

## 5. Tests d'émulateur

Suite fonctions complète sous émulateur Firestore + Auth : 2299 tests, 2251 réussis, **1 échec préexistant** (`dispatchRetry`, aussi en isolation), 47 ignorés (Storage absent, `AZ_E2E_RULES=1`). Isolation : projet `demo-*`, ports distincts de l'émulateur de l'utilisateur (8080/4400/4500/9099/9199/9299/9499/5001, non touché) ; le mode démo interdit tout accès à un service non émulé, donc impossible de basculer vers `az-express-b0469`.

## 6. Tests de concurrence (émulateur Firestore réel, 9/9)

Fichier : `functions/test/accountQuarantineConcurrency.emulator.test.js`. L'ordre est jugé par `createTime`/`updateTime` des documents (pas par `serverTimestamp`).

| Test | Scénario | Résultat |
|---|---|---|
| A | recharge vs quarantaine | aucune demande validée après le tombstone |
| A2 | retrait vs quarantaine | solde débité seulement si le retrait précède le tombstone, jamais négatif |
| B | double confirmation AZ IA | une seule exécution |
| B2 | confirmation AZ IA vs quarantaine | jamais exécutée après le tombstone |
| C1 | 3 webhooks identiques concurrents + rejeu | au plus un crédit, solde = 1000 |
| C2 | webhook avant/après quarantaine et anonymisation | crédité (paiement antérieur) ou `held_for_review` |
| C3 | référence inconnue, montant erroné | aucun crédit |
| D | inspection finale avec opérations non terminales | suppression bloquée, Auth intact |
| E | caractérisation de la détection de conflit | documentée |

Limites honnêtes : l'émulateur n'est pas Firestore de production. Sous forte contention il peut rejeter une transaction (`INVALID_ARGUMENT: Transaction is invalid or closed`) là où Firestore renvoie ABORTED et réessaie ; constaté aussi sur le code **pré-7E-68** (comparaison : 0/15 et 5/15 rondes avec erreur avant, 4/15 et 1/15 après), sans jamais de solde anormal. C1 vérifie donc l'invariant financier avec rejeu du webhook, pas l'absence d'erreur d'émulateur. Ce n'est **pas** une preuve de concurrence réelle de production.

## 7. Analyse `held_for_review`

Déclencheurs (webhook authentique, vérifié côté serveur, jamais bloqué) : profil `isDeleted`, paiement créé après le tombstone, date du tombstone illisible. Effet : transaction passée en `held_for_review`, `needsReview:true`, `credited:false`, solde inchangé, événement de sécurité `webhook_paid_account_in_deletion` + audit `payment_held_account_deletion`. Tout rejeu est traité comme déjà traité (pas de double effet).

États et résolution cible (non implémentée) :
| État | Qui | Preuve exigée | Action |
|---|---|---|---|
| En revue | Super-admin A | référence FeexPay, montant, horodatages | instruction |
| Confirmé | Super-admin B ≠ A (double validation) | vérification serveur du statut | crédit sur le portefeuille d'origine si compte actif, sinon remboursement |
| Rejeté | idem | motif | clôture, aucune écriture d'argent |
| Remboursement demandé / confirmé | idem | preuve opérateur | écriture ledger, hors API réelle ici |
| Litige | idem | pièces | suivi manuel |

Contrôles : transaction unique, lecture avant écriture, statut verrouillant tout double traitement, `audit_logs` et `support_events`, réconciliation comptable (somme des `held_for_review` = écart wallet/opérateur). Architecture proposée : callable `resolveHeldPayment` (super-admin, justification obligatoire, séparation des tâches), **non écrite, non déployée**. Aucun remboursement réel implémenté.

## 8. Revue E-Kbine

| Point | Classement |
|---|---|
| `ekClientConfirmOrder` : garde de quarantaine déjà dans la transaction ; crédit refondu (`creditFor`, `provenDebit`) | Compatible sous réserve (revue métier du crédit) |
| `ekbineAcceptOrder` : garde ajoutée en 7E-68 (`assertNewAccountActivity`) | Compatible |
| Module `ekbineOrders.js` absent de la production | Régression possible si déployé seul : doit l'être **en bloc** avec les règles locales E-Kbine (création serveur) et le Flutter |
| Absence de frais (`fee = 0`) | Compatible (inchangé) |

## 9. Revue des comptes partenaires

| Point | Classement |
|---|---|
| `manageAdminPartnerAccount` (−46/+355 lignes vs prod) : tombstone lu seulement pour conserver le message de refus existant | Compatible sous réserve |
| Fonctions de suppression partenaire | Non vérifié en préproduction (`partnerInventoryVersion` non activé : revue manuelle) |
| `artisanLogin` / `pharmacieLogin` inchangés (D4) | Compatible |
| `resetAccountPassword`, `setPharmaciePassword` : garde sur le compte **cible** (`assertTargetNotClosing`) | Compatible |
| Admins jamais supprimés automatiquement (D3) | Compatible |

## 10. Revue AZ IA

`aiConfirmAction` : garde dans la transaction de confirmation (avant `confirmHandler`, après le statut) — testé (B, B2). Outils `delivery`/`marketplace`/`ekbine` locaux absents de la prod : **Compatible sous réserve**. `assertPartnerActivated` et `assertDriverRechargeAllowed` embarqués avec FeexPay : **Non vérifié** métier. La règle « aucune action financière sans confirmation validée côté serveur » reste respectée. Aucun outil IA d'administration.

## 11. Opérations de support

Existant (`accountDeletionSupport.js`) : super-admin uniquement, actions `list` / `claim` / `retry`, `resolution` obligatoire, trace `support_events`, ne peut pas finaliser la suppression. Manques : consultation de dossier détaillé, examen d'un paiement en attente, vérification dette/solde, réconciliation d'un paiement antérieur, suspension/reprise, protection de double intervention (revendication exclusive à vérifier), séparation des tâches (double validation). **Non implémentés** : à construire avant production. Tests à préparer : refus d'un sous-admin, `claim` concurrent, `retry` sans motif, trace d'audit. Le support ordinaire ne peut pas finaliser une suppression (vérifié).

## 12. Quota Cloud Run

**NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ.** Distinctions : CPU maximum théorique Σ(cpu×maxInstances) ≈ 119,5 (mémoire du 15/07, à relever à nouveau ; l'ancienne estimation 166,5 figure dans la matrice 7E-67) ; CPU consommée en régime normal : inconnue ; quota de déploiement (nouvelles révisions simultanées) : inconnu ; quota de service et d'instances : non interrogés. Un redéploiement peut doubler transitoirement la consommation. Aucun chiffre n'a été vérifié dans la console GCP (non autorisé) ; la préproduction n'a pas été interrogée.

## 13. Risques ouverts

1. Pas d'outil de résolution `held_for_review` (bloquant avant production).
2. Revues métier E-Kbine / partenaires / AZ IA non signées.
3. Patchwork de déploiement en production (fonctions de générations différentes) : un lot redéployé embarque les différences local/prod.
4. Contention de l'émulateur : concurrence réelle non prouvée.
5. `dispatchRetry` en échec préexistant : à trier.
6. Tests Auth/Storage non exécutés (47 ignorés) ; 166 ignorés sans émulateur.
7. Quota Cloud Run non confirmé.
8. Durées de conservation / TTL à valider juridiquement.
9. Un compte avec un paiement antérieur crédité pendant la quarantaine est bloqué par `inspect` (régularisation manuelle).

## 14. Verdict de préparation à la préproduction

**PRÊT SOUS CONDITIONS.** Justification : toutes les vérifications locales sont vertes (0 échec attribuable à 7E-68/69), les cas d'argent critiques sont couverts par des transactions d'émulateur réelles, aucun défaut bloquant n'a été trouvé pour une phase de préproduction **synthétique et désactivée par défaut**.
Conditions avant le démarrage de la préproduction : (a) autorisation distincte et explicite ; (b) quota Cloud Run de la préproduction relevé ; (c) liste blanche de `deploy-preprod.ps1` étendue explicitement ; (d) déploiement en lots selon le runbook, config de suppression absente jusqu'à validation S1-S2.
Conditions avant toute décision production : outil `held_for_review`, outils de support complétés, revues métier signées, quota confirmé, `dispatchRetry` trié, validation juridique.
Procédure : `docs/ACCOUNT_DELETION_7E69_PREPROD_RUNBOOK.md`.

*Ne rien déployer, ne rien activer, ne rien commiter : attendre une autorisation distincte.*
