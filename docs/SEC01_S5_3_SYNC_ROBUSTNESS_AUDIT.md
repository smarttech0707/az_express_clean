# SEC-01 — S5.3 : audit de robustesse de la synchronisation `driver_public`

**Statut : audit terminé, aucune correction de code nécessaire — deux constats réels documentés, pas corrigés (question architecturale, conformément à la consigne « stopper et documenter »).** Suite de S5.2 (`docs/SEC01_S5_2_SERVER_SYNC_IMPLEMENTATION.md`).

## 1. Résumé exécutif

L'implémentation S5.2 a été réinspectée intégralement, pas supposée conforme à son propre rapport. Elle est globalement robuste : whitelist stricte vérifiée, champs GPS structurellement protégés, idempotence démontrée, aucune fuite de champ sensible. **Deux constats réels ont été identifiés et documentés, sans correction** (questions architecturales, hors périmètre d'une correction ponctuelle) :

1. **Aucune synchronisation à la création** : il n'existe aucun déclencheur `onDocumentCreated` couvrant `driver_public`. Un livreur fraîchement créé n'aura `name`/`photoUrl`/`avgRating`/`ratingCount` dans `driver_public` qu'une fois que l'un de ces champs change pour la première fois après la création (un `onDocumentCreated` sur `livreurs` existe déjà — `notifyAdminsOnNewDriver` — mais c'est une notification admin, confirmée sans rapport avec `driver_public`).
2. **Absence de garantie d'ordre stricte entre écritures concurrentes** : les triggers Firestore sur un même document ne garantissent pas un ordre d'exécution strict en cas d'écritures rapprochées ou de nouvelle tentative (`retry`). Un scénario rare (ex. une note de livreur et un battement GPS dans la même fenêtre très courte) pourrait voir une exécution tardive écraser `driver_public` avec une valeur plus ancienne pour un seul champ. Évalué comme faible probabilité, impact limité et largement auto-corrigé (`isOnline` est réécrit à chaque battement GPS, 30-90 s).

Aucun de ces deux constats ne remet en cause la validité de S5.2 — ce sont des limites documentées, pas des défauts démontrés nécessitant une correction immédiate.

## 2. Baseline S5.2 (rappel, revérifié)

2 984 tests, 2 803 passés, 0 échec, 181 ignorés.

## 3. État Git initial et final

**Initial** : identique à la fin de S5.2 (`functions/driverPublicSync.js`, `functions/test/driverPublicSync.test.js`, `functions/index.js` modifié). **Final** : seul `functions/test/driverPublicSync.test.js` complété (6 tests ajoutés) ; aucun fichier source modifié ; ce rapport est le seul nouveau fichier. `firestore.rules`, `.firebaserc`, `firebase.json` : inchangés depuis avant S5.3.

## 4. Fichiers inspectés

`functions/driverPublicSync.js` (relu intégralement), `functions/index.js` (les deux triggers S5.2, plus `notifyDriverLowBalance` et `notifyAdminsOnNewDriver` — les deux autres triggers existants sur `livreurs/{driverId}`), `functions/test/driverPublicSync.test.js` (relu avant complément), `functions/accountDeletion.js` (logique d'anonymisation reconfirmée), `lib/screens/admin/drivers_page.dart` (bouton de suppression reconfirmé).

## 5. Architecture vérifiée

Les deux triggers (`syncDriverPublicOnLivreurUpdate`, `syncDriverPublicOnLivreurDelete`) sont correctement enregistrés et exportés (confirmé par test 19 : `require('../index.js')` expose bien les deux comme fonctions appelables), sur le chemin exact `livreurs/{driverId}`. Aucun risque de boucle : les écritures ciblent `driver_public`, jamais `livreurs`. Conventions de région/exécution alignées sur `driverRatings.js`/`applyDriverRatingOnOrderUpdate`, déjà en production.

## 6. Résultats de l'audit de robustesse (15 points)

| # | Point | Verdict |
|---|---|---|
| 1 | Trigger correctement enregistré/exporté | **OK** — confirmé par relecture et test 19 |
| 2 | Chemin source exact | **OK** — `livreurs/{driverId}` sur les deux triggers |
| 3 | Événements traités pertinents | **Constat documenté** — `onCreate` non couvert (voir §1, point 1) |
| 4 | Pas de boucle de déclenchement | **OK** — écriture vers une collection distincte, jamais vers `livreurs` |
| 5 | Idempotence démontrable | **OK** — tests 12-13, 18/18b ; un rejeu du même événement produit le même état final |
| 6 | Écritures inutiles évitées | **OK** — `hasChanges` conditionne toute écriture, testé (13b) |
| 7 | Whitelist strictement respectée | **OK** — `DRIVER_PUBLIC_FIELDS` figé, seule source de clés possibles |
| 8 | Champs sensibles jamais projetés | **OK** — testé explicitement (test 9), y compris présents des deux côtés |
| 9 | Champs GPS jamais écrasés | **OK** — structurellement impossible, testé (10, 10b, 18b) |
| 10 | Champs absents/null/invalides/changements de type | **Constat mineur documenté** — `null` traité comme type invalide (ignoré, jamais effacé), nouveau test 16 ; oscillation de type testée sans corruption (test 17) |
| 11 | Pas de régression `isOnline` | **OK** — motifs exacts de S5.1 (`goOffline`) et S4 (`_saveToFirestore`) rejoués et validés (tests 18, 18b) |
| 12 | Suppressions correctement traitées ou identifiées | **OK** — couvert pour la suppression réelle (admin), explicitement non applicable à l'anonymisation (qui ne supprime pas le document) |
| 13 | Interactions avec les autres writers | **Constat documenté** — voir point 2 du résumé (ordre d'exécution) |
| 14 | Risques d'événements concurrents/ordre d'exécution | **Constat documenté** — idem, limitation native de Cloud Firestore, pas un bug de ce module |
| 15 | Limites de synchronisation Firestore documentées | **OK, documenté ici** — livraison « au moins une fois » (pas exactement une fois), cohérence éventuelle (pas transactionnelle avec l'écriture `livreurs` d'origine) |

## 7. Tests exécutés et résultats

**6 nouveaux tests** ajoutés à `functions/test/driverPublicSync.test.js` (16 à 20, dont 18/18b) :
- **16** : valeur `null` explicite — confirmé traitée comme type invalide (ignorée, jamais effacée, jamais écrite).
- **17** : oscillation valide→invalide→valide — confirmé qu'une valeur invalide intercalée ne corrompt jamais la dernière valeur valide.
- **18/18b** : rejeu exact des motifs d'écriture réels de S5.1 (`goOffline`, isOnline seul) et S4 (`_saveToFirestore`, GPS + isOnline dans la même écriture) — confirmé qu'aucune régression n'affecte `isOnline` et que les champs GPS restent exclus même quand ils changent dans le même événement.
- **19** : vérification d'intégration réelle (`require('../index.js')`), pas seulement de code source — les deux exports existent et sont appelables.
- **20** : documentation active du constat n°1 — confirme qu'un `onDocumentCreated` existe bien sur `livreurs` (`notifyAdminsOnNewDriver`) mais qu'aucun ne touche `driver_public`, et qu'aucun export `syncDriverPublicOnLivreurCreate` n'existe.

**Résultat** : `node --test functions/test/driverPublicSync.test.js` → **19/19 passés** (13 de S5.2 + 6 nouveaux). Suite complète `npm test` → **2990 tests, 2809 passés, 0 échec, 181 ignorés** (exactement +6/+6 par rapport à la baseline S5.2, confirmant l'absence de toute régression ailleurs).

## 8. Corrections apportées

**Aucune.** Aucun défaut de code n'a été démontré — uniquement deux limitations architecturales réelles, documentées par de nouveaux tests plutôt que corrigées, conformément à la consigne explicite de cette mission (« si le défaut nécessite une décision architecturale, STOPPER et documenter »).

## 9. Risques résiduels

Les deux constats du résumé exécutif, tous deux déjà qualifiés (faible probabilité, impact limité, largement auto-correcteur pour `isOnline`) — aucun des deux n'est un risque critique non résolu au sens du critère de validation de cette mission.

## 10. Impact éventuel sur S5.2

Aucun. L'implémentation livrée en S5.2 est confirmée robuste telle quelle ; aucune ligne de `driverPublicSync.js` ni de `index.js` n'a dû être modifiée.

## 11. Confirmation absence de Firebase réel et de déploiement

Confirmée : tous les tests sont exécutés localement (`node --test`), aucune commande `firebase deploy`, aucun accès réseau à un projet Firebase.

## 12. Recommandation pour la prochaine étape

Deux décisions restent à votre arbitrage, non entreprises ici :
- Faut-il ajouter un déclencheur `onDocumentCreated` dédié à la synchronisation `driver_public` (séparé de `notifyAdminsOnNewDriver`, pour ne pas mélanger notification et synchronisation), ou accepter que le backfill (S3, non exécuté) et les mises à jour ultérieures suffisent à peupler `driver_public` progressivement ?
- Le risque d'ordre d'exécution (point 2) justifie-t-il un mécanisme de garde par version/horodatage avant une éventuelle fermeture de `livreurs` (S8), ou reste-t-il acceptable au vu de sa faible probabilité et de son caractère auto-correcteur ?

## 13. Verdict

**S5.3 VALIDÉ AVEC RÉSERVES.**

S5.2 reste robuste et n'a nécessité aucune correction. La réserve porte sur les deux constats documentés (§1) : réels, mais non bloquants et non corrigés dans cette phase, conformément à son périmètre strictement limité à l'audit.

STOP — fin de mission S5.3. Je n'entame ni S5.4, ni S6, ni la fermeture de `livreurs`. J'attends vos instructions.
