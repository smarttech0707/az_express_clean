# Mission 7E-74 — Résultats des tests

Date : 2026-11-07 · Node 22.23.4 (binaire isolé) sauf mention ; machine par défaut Node 24.22.1. Émulateurs locaux uniquement (projets `demo-*`), aucune commande distante.

| Suite | Node | Résultat | Statut |
|---|---|---|---|
| `accountDeletionHardening.test.js` (ciblé) | 24 | 26/26 ; sur l'ancien code : 4 échecs (passerelle fermée), 22 réussis | PASS |
| Règles de suppression (4 fichiers, `--test-concurrency=1`) | 22 | 69/69 | PASS |
| Règles Firestore principales | 22 | 470/470, 0 ignoré | PASS |
| Règles Storage | 22 | 128/128, 0 ignoré | PASS |
| Suite complète Functions (Auth+Firestore, concurrence 1) | 22 | 2328 tests : 2278 réussis, 3 échecs, 47 ignorés, 0 annulé (915 s) | **FAIL (3 échecs, voir ci-dessous)** |
| `accountQuarantineConcurrency.emulator` relancé seul | 22 | 9/9 | PASS |
| Flutter : `account_deletion_dialog_test` + `account_deletion_service_test` | — | 25/25 | PASS |
| `flutter analyze` (4 fichiers touchés) | — | aucune anomalie | PASS |
| Suite Flutter complète | — | non lancée | NON VÉRIFIÉ |
| Test sur appareil / émulateur mobile | — | non fait | NON VÉRIFIÉ |
| Essai sur Firestore/Cloud Functions réels | — | non fait (interdit) | NON VÉRIFIÉ |

## Échecs de la suite complète (3)
1. `accountQuarantineConcurrency` C2 « webhook vs quarantaine » : `3 INVALID_ARGUMENT: Transaction is invalid or closed` (artefact d'émulateur documenté, non relancé par le SDK). Relancé seul : 9/9. Considéré comme **intermittent d'émulateur**, non lié à 7E-74 (fichier non modifié, chemin `request` non utilisé).
2. `dispatchRetry.emulator` « trois passes simultanées en phase 2 » : échec **préexistant** connu (depuis 7E-69).
3. `financialConcurrency.emulator` « E-Kbine création : 8 appels simultanés » : échec **intermittent connu** (voir 7E-73 EKBINE_SCOPE_DECISION), non résolu, test inchangé.

Aucun des trois n'implique `accountDeletion.js`. Aucun nouvel échec attribuable à la correction. Les 47 tests ignorés sont ceux de la suite habituelle ; leur liste n'a pas été comparée à une exécution de référence.

## Non annoncé comme vert
La suite complète n'est **pas** verte (3 échecs). Les échecs C2 et 8-appels sont des artefacts d'émulateur non prouvés autrement qu'en relance/analyses antérieures ; `passwordHash` (probabiliste) n'a pas échoué cette fois.

## Fichiers de sortie (scratchpad de session)
`r74_main_n22.txt`, `r74_storage_n22.txt`, `full74_n22.txt`, `c2_74_n22.txt`.
