# Mission 7E-76 — Suite complète Functions après 7E-75

Date : 2026-11-07 · Node **v22.23.4** (binaire isolé), émulateurs Auth + Firestore locaux (projet `demo-full76n22`, ports dédiés `fb72.json`), `node --test --test-concurrency=1 test/*.test.js` depuis `functions/`, un seul processus d'émulateur de ma part (les émulateurs personnels de l'utilisateur sur 5001/8080/9099 n'ont pas été touchés). Aucune autre suite lancée en parallèle.

## Résultat
| | 7E-76 (après 7E-75) | 7E-74 (avant `details.reason`) |
|---|---|---|
| Tests | 2328 | 2328 |
| Réussis | **2280** | 2278 |
| Échecs | **1** | 3 |
| Annulés | 0 | 0 |
| Ignorés | 47 | 47 |
| Code de sortie | **1** (à cause de l'échec) | — |
| Durée | 5 640 s (≈ 94 min) | 915 s |

**La suite n'est pas verte : 1 échec.** Sortie : `full76_n22.txt` (scratchpad de session).

## Échec unique
`not ok 971 — émulateur 7C-2 : trois passes simultanées en phase 2 → un seul essai, élargissement sans rappel des premiers livreurs` (`test/dispatchRetry.emulator.test.js:204`). Assertion : « dP1 conservé, dP2 ajouté une seule fois » ; reçu `['dP1']`, attendu `['dP1','dP2']`. Échec **préexistant** (depuis 7E-69), même test qu'en 7E-74. `dispatchRetry.js` n'est pas modifié dans le dépôt.

## Comparaison avec 7E-74
- `accountQuarantineConcurrency` C2 : **passe** dans cette suite (il avait échoué en 7E-74 avec `Transaction is invalid or closed`, puis 9/9 isolé).
- `financialConcurrency` E-Kbine « 8 appels simultanés » : **passe** (3,5 s) (échec intermittent en 7E-74).
- `dispatchRetry` : échoue de nouveau.
- Les 2 tests qui passent maintenant sont ceux dont l'échec était qualifié d'intermittent d'émulateur : cela **confirme l'intermittence**, mais ne la **résout pas** (cause du déclenchement toujours non établie).
- Total identique (2328) et ignorés identiques (47) : le nombre de tests de la suite n'a pas changé ; les ajouts de 7E-75/76 sont dans Flutter ou déjà comptés.

## Durée anormale
5 640 s contre 915 s en 7E-74 (×6). Exemple : le test C2 a pris 121,7 s (contre quelques secondes). La cause n'a **pas été mesurée ni investiguée**. Hypothèses non vérifiées : machine chargée ou en veille partielle, autres processus ou émulateurs actifs. Une exécution lente rend les tests de concurrence moins représentatifs ; elle n'invalide pas les passages mais atténue la valeur de la comparaison d'intermittence.

## Tests ciblés P1 (Node 22.23.4, sans émulateur)
`accountDeletionHardening` + `accountDeletionSupport` + `manualAccountDeletion` + `accountQuarantineGuards` + `accountQuarantineIndex` + `accountAdmission` : **86/86**. Règles de suppression (4 fichiers, émulateurs, Node 22, après `details.reason`) : **69/69** (exécuté en 7E-75). Règles Firestore principales (470) et Storage (128) : non relancées en 7E-76 (aucun changement des règles) — derniers résultats 7E-74.

## Limites
Émulateurs seulement ; l'échec `dispatchRetry` reste non analysé quant à sa cause racine ; les passages de C2 et E-Kbine ne prouvent pas l'absence d'intermittence.
