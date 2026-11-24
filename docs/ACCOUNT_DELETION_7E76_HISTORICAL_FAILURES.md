# Mission 7E-76 — Les trois échecs historiques de la suite Functions

Date : 2026-11-07 · Node 22.23.4, émulateurs locaux. Aucune assertion modifiée ; aucun test affaibli.

| Test | 7E-69 | 7E-71 | 7E-72 | 7E-74 | 7E-76 |
|---|---|---|---|---|---|
| `dispatchRetry.emulator` « trois passes simultanées en phase 2 » | échec | échec | échec | échec | **échec** |
| `financialConcurrency.emulator` E-Kbine « 8 appels » | PASS | FAIL 7/8 | FAIL N22 / PASS N24 ×2 | FAIL | **PASS** |
| `accountQuarantineConcurrency` C2 | non relevé | non relevé | non relevé | FAIL (`Transaction is invalid or closed`), 9/9 isolé | **PASS** |

## A. C2 (webhook vs quarantaine)
Aucun nouvel échec : passe (en 121,7 s, machine chargée). Fichier du commit 2 (P2), absent du commit 1. Bloque P1 : non. Preuve : succès en isolé (7E-74) et en suite (7E-76). Limite : l'échec de 7E-74 était un `INVALID_ARGUMENT` d'émulateur non relancé par l'Admin SDK ; sa survenue dépend de la contention de l'émulateur, pas du code ; **aucune preuve** que Firestore réel se comporte de même ni qu'il en soit indemne.

## B. `dispatchRetry.emulator`
Échoue de nouveau, même assertion (`['dP1']` au lieu de `['dP1','dP2']`). `functions/dispatchRetry.js` n'est modifié ni par 7E-74/75/76 ni dans l'arbre de travail ; le moteur de suppression n'importe pas ce module. Indépendant du périmètre P1 : oui, d'après les imports et l'état Git ; cause racine non analysée. Bloque P1 : non. Reportable : oui, mais l'échec reste à traiter avant d'annoncer une suite verte.

## C. E-Kbine, 8 appels simultanés
Passe cette fois (3,5 s). Le comportement a changé (PASS au lieu de FAIL) sans modification de `ekbineOrders.js` ni du test (test et fichier identiques à 7E-74). C'est cohérent avec l'intermittence documentée (7E-73 : sonde 40 rondes, 2-3 rondes en échec, solde final toujours 4000, une seule commande). Bloque P1 : non (commit 3 distinct). Le test reste actif et inchangé.

## Réserves
- Aucune de ces trois conclusions n'est une preuve de bon fonctionnement en production : ce sont des comportements d'émulateur.
- Un passage ne prouve pas que l'intermittence est résolue ; deux des trois tests ont changé de résultat sans changement de code.
- La suite a duré 94 min (×6 vs 7E-74) : environnement chargé, ce qui peut influencer les tests de concurrence dans les deux sens.
