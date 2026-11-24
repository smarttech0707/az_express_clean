# Mission 7E-75 — Rapport final de décision : commit P1

Date : 2026-11-07 · Local uniquement. Aucun `git add`, `git apply --cached`, commit, push, merge, reset, déploiement, activation, commande distante. Production `az-express-b0469` non touchée. Rapports antérieurs non remplacés.

## 1. État Git
- **Avant** : HEAD `aa3d1b0`, branche `finalisation/az-express`, index vide, 77 entrées `git status --short`.
- **Après** : HEAD `aa3d1b0`, index vide (0 fichier), 82 entrées (= +4 documents 7E-74 non comptés avant + 5 documents 7E-75 − 4 déjà comptés ; aucun autre fichier nouveau dans le dépôt).
- Modifications de code en 7E-75 (en plus de 7E-74) : `functions/accountDeletion.js` (`details.reason`), `functions/test/accountDeletionHardening.test.js` (assertion renforcée, sans affaiblissement), `lib/services/account_deletion_service.dart` (helper `isGateClosedRefusal`), `test/services/account_deletion_service_test.dart` (+1 test, import).

## 2. Fichiers P1
- **Commit 1** (9 fichiers) : `functions/accountDeletion.js`, `accountCleanup.js` (nouveau), `partnerAccountDeletion.js`, `accountDeletionSupport.js`, `functions/test/accountDeletionHardening.test.js` (nouveau), `rules-tests/account-deletion.test.js`, `account-deletion-lifecycle.test.js`, `account-deletion-real.test.js`, + `functions/index.js` **hunk 3 seulement** (`checkRateLimit,logAudit`, via `index_p1.patch`).
- **Commit 1b** (Flutter, 4 fichiers) : `account_deletion_service.dart`, `account_deletion_dialog.dart` et leurs deux tests.
- Détail et justifications : `…FINAL_P1_MANIFEST.md`, `…FLUTTER_COMMIT_SCOPE.md`.

## 3. Flutter : intégré, avec justification
Indispensable pour qu'un refus de passerelle ne soit jamais présenté comme une demande enregistrée (le repli `checkLastRequest` pourrait montrer un ancien reçu). Fragilité du texte de message traitée par un code machine additif `details.reason` (message inchangé) lu en priorité, texte en repli, `failed-precondition` exigé. Non vérifié : transmission réelle de `details` par un callable déployé ; aucun test appareil.

## 4. Exclus (P2 / P3 / autres)
P2 : `accountAdmission`, `feexpayPayments`, `azia/*`, `pilotCap`, hunks 1, 2, 4–8 d'`index.js`, tests de quarantaine/plafonds. E-Kbine (commit 3 séparé, dépend de HEAD seulement). P3 : `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`, hunk 9. Hors P1 : `restaurantV2Preprod.test` (4), script de déploiement (5), docs (6), pages légales web, `.aab`, patchs, journaux, `qr-release/`, `scripts/*`, `web/downloads/`, caches Hosting, `.env`.

## 5. Dépendances entre commits
1 ← HEAD seul (reconstruit hors dépôt, vérifié). 1b ← aucun (indépendant du code backend). 2 ← 1 (hunks d'`index.js` empilés). 3 ← HEAD seul. 3b ← 2. 4, 5, 6 libres. Ordre : 1 → 1b → 2 → 3 → 3b → 4 → 5 → 6.

## 6. Résultats de tests disponibles
| Suite | Résultat |
|---|---|
| Reconstruction commit 1 depuis HEAD (Hardening + Support + manualAccountDeletion), Node 22.23.4 et 24.22.1 | 51/51 ; `index.js` se charge, 135 exports |
| Hardening (arbre de travail, Node 24) | 26/26 (après `details.reason`) |
| Règles de suppression, 4 fichiers, Node 22 | 69/69 (après `details.reason`) |
| Règles Firestore principales / Storage, Node 22 (7E-74, avant `details.reason`) | 470/470 ; 128/128 — non relancées : le changement ne touche pas les règles |
| Flutter : service + dialogue | 26/26 ; analyse des fichiers : aucune anomalie |
| Suite Functions complète, Node 22 (7E-74, avant `details.reason`) | 2278/2328, 47 ignorés, 3 échecs — non relancée en 7E-75 |
| Suite Flutter complète ; appareil ; Firestore/Auth réels | NON VÉRIFIÉ |

## 7. Les trois échecs Functions
C2 (artefact d'émulateur, 9/9 isolé, fichier du commit 2), `dispatchRetry` phase 2 (préexistant, sans lien démontré avec P1), E-Kbine 8 appels (intermittent d'émulateur, aucun double débit observé, commit 3). **Aucun ne bloque le commit 1** ; tous reportables, avec les limites de preuve détaillées dans `…P1_DEPENDENCY_AUDIT.md` §4. Aucune assertion modifiée.

## 8. Commandes Git proposées
Voir `…COMMIT_COMMANDS.md` : `git add --` avec chemins explicites, `git apply --cached --check` puis `git apply --cached` sur `index_p1.patch` (hunk 3), contrôles (`--check`, fichiers sensibles, fichiers P2/P3), message de commit avec la ligne de co-auteur. **Non exécutées.** Procédure après commit : `…POST_COMMIT_CHECKLIST.md` (arrêt immédiat sur échec critique).

## 9. Risques ouverts
1. Validation locale seulement (faux Firestore, émulateurs) ; rien sur Firestore/Auth/Functions réels ni appareil.
2. Quarantaine non appliquée aux chemins financiers/AZ IA tant que le commit 2 n'est pas livré (écart connu) ; P1+P2 théorique 19,75 vCPU.
3. Suite complète non verte (3 échecs documentés) et non relancée après `details.reason` (changement minimal, additif, testé ciblé).
4. Les patchs `index_p*.patch` sont hors Git (dossier ignoré) : à conserver ou régénérer ; `git apply --cached --check` n'a **pas** été exécuté (interdit) — seule l'application sur une copie hors dépôt est vérifiée.
5. Fins de ligne mixtes CRLF/LF (`autocrlf`) : avertissements attendus ; aucune erreur `--check` à ce stade.
6. Transmission de `details` par le callable déployé non vérifiée (repli sur le message).
7. Pas de test réel de « suppression Auth » ni d'anonymisation en environnement réel.
8. Fichier parasite hors dépôt : `D:\h75.txt` (sortie de test créée par erreur à la racine du disque D, suppression refusée par la protection de sécurité — à supprimer par vous ; aucun secret).
9. Quota : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (18,75 vCPU théoriques ≠ capacité disponible ; à vérifier humainement dans `az-express-preprod`, `europe-west1`).

## Verdict
**PRÊT SOUS CONDITIONS** — le périmètre P1 est cohérent, reconstructible depuis HEAD sans P2/P3, et testé localement ; conditions avant autorisation : (a) décision humaine sur 1 + 1b séparés ou fusionnés ; (b) relecture humaine des 3 échecs Functions ; (c) accord sur l'écart de quarantaine tant que P2 n'est pas livré ; (d) conscience que le quota n'est pas confirmé et que toute validation réelle reste à faire.

Aucune opération Git ou distante sans autorisation distincte.
