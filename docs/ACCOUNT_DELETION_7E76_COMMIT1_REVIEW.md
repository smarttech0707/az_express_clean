# Mission 7E-76 — Revue du commit 1 (moteur backend P1, 9 fichiers)

Date : 2026-11-07 · Aucun `git add`/commit exécuté. Remplace les listes de 7E-75 sur un point : le test Hardening a changé d'une ligne (voir §3).

## 1. Fichiers exacts
`functions/accountDeletion.js` · `functions/accountCleanup.js` (nouveau) · `functions/partnerAccountDeletion.js` · `functions/accountDeletionSupport.js` · `functions/index.js` (**hunk 3 seulement**, 1 ligne) · `functions/test/accountDeletionHardening.test.js` (nouveau) · `rules-tests/account-deletion.test.js` · `rules-tests/account-deletion-lifecycle.test.js` · `rules-tests/account-deletion-real.test.js`.

Aucun fichier modifié depuis 7E-75 dans ce lot : comparaison octet à octet des 5 fichiers `functions/` avec la copie reconstruite (résultat consigné dans `ACCOUNT_DELETION_7E76_FINAL_DECISION.md` §1) ; les 3 `rules-tests` ne sont pas plus récents que le rapport 7E-75 (contrôle par horodatage seulement).

## 2. Dépendances (vérifiées)
`accountDeletion` → `accountCleanup` (inclus), `accountDeletionIdentity`, `partnerAccountDeletion` (inclus), `node:crypto` ; `partnerAccountDeletion` → `accountCleanup`, `accountDeletionScope`, `accountRelatedPersonalData` ; `accountDeletionSupport` → `adminGuards` ; hors `accountCleanup`, tous présents à HEAD. Aucun import de `accountAdmission`, `pilotCap`, `feexpayPayments`, `azia/*`, `ekbineOrders`, `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`. L'arbre reconstruit « HEAD + 9 fichiers (index = hunk 3) » a servi de **source de l'émulateur Functions** pour la preuve de transport (cas A–F de `…CALLABLE_ERROR_CONTRACT.md`) : la fonction du commit 1 fonctionne sans P2/P3 (avec la réserve de la cale d'émulateur pour le cas F, hors dépôt).

## 3. Contenu métier vérifié
- Refus avant écriture si passerelle absente/désactivée/`inventoryVersion` ≠ 1 (A–C sur transport réel, état Firestore identique) ; erreur de lecture : test unitaire.
- `details.reason` ajouté à l'erreur (message et code inchangés).
- Test Hardening : le prédicat `GATE_ERROR` exige désormais `details.reason` en plus du code et du message (assertion renforcée, rien d'affaibli).
- Comportement passerelle ouverte conservé (F sur transport réel : 200, dossier + tombstone + audit + limiteur ; tests unitaires : idempotence, plafond).
- Aucun fichier de configuration, secret, `.env` ou activation inclus.

## 4. Résultats de tests (voir `…FUNCTIONS_FULL_SUITE.md` pour la suite complète)
Hardening 26 tests, règles de suppression 69 (4 fichiers), `accountDeletionSupport` + `manualAccountDeletion`, chargement de `index.js` (135 exports) : résultats consignés dans le rapport de décision.

## 5. Limites
Validation locale (faux Firestore, émulateurs). Quarantaine : gardes financières P2 non incluses (écart connu). Aucune opération réelle d'Auth/Storage.
