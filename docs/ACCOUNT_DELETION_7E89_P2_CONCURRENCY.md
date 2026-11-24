# Mission 7E-89 — Validation des 9 scénarios de concurrence du lot 2A

Date : 2026-11-09 · Strictement local. Aucun `git add`, commit, push, déploiement, commande distante, changement de secret ou de code/test, aucune activation de la passerelle. Production `az-express-b0469` non touchée. Rapport non suivi.

## 1. Audit initial
HEAD `294332e` · branche `finalisation/az-express` · index vide · `accountQuarantineConcurrency.emulator.test.js` présent (non suivi, 247 l.) avec les 9 scénarios attendus (A, A2, B, B2, E, C1, C2, C3, D) · Java OpenJDK 21.0.11 · émulateurs de l'utilisateur actifs sur 5001, 8080, 9099, 9199, 4000, 4400 (non touchés).

## 2. Configuration et preuve d'isolation
- Commande : `firebase emulators:exec --only firestore --project demo-7e89 --config fb89.json "bash run89.sh"` lancée depuis un dossier du scratchpad (hors du `firebase.json` du dépôt). Config : Firestore `127.0.0.1:18089`, hub `14400`, logging `14500`, UI désactivée, **aucune règle**. (Le websocket interne de l'UI Firestore s'est ouvert sur 9151, libre avant/après.)
- Ports vérifiés **libres avant** : 18089, 14400, 14500 (et 15001, 18080, 19099, 19199, 19299, 19499). Aucun de 5001/8080/9099 n'a été utilisé.
- Projet `demo-7e89` ; données synthétiques (`qz71_*`) ; le test se saute lui-même si `FIRESTORE_EMULATOR_HOST` est absent ou si le projet n'est pas `demo-*` ou contient `az-express`. Sortie constatée : `127.0.0.1:18089 demo-7e89`. Seul le service Firestore a été démarré (ni Auth, ni Functions) ; axios et Auth sont simulés dans le test : aucun appel réseau, aucun secret réel (valeurs `test-only-not-a-secret`).
- Exécuté avec Node v22.23.4. Seul le fichier ciblé a été lancé.

## 3. Résultats (9/9 PASS, 0 FAIL, 0 ignoré, 300,8 s au total, une seule exécution)
| # | Scénario | Résultat | Durée | Opérations concurrentes | Constat |
|---|---|---|---|---|---|
| 1 | A recharge vs quarantaine | PASS | 12,0 s | 25 rondes × (1 recharge + 1 quarantaine) | 4 créées avant le tombstone, 21 refusées (« Compte supprime ou en cours de suppression ») ; aucune demande validée après le tombstone ; refus ⇒ 0 demande |
| 2 | A2 retrait vs quarantaine | PASS | 36,3 s | 25 × (1 retrait + 1 quarantaine) | 11 retraits avant, 14 refusés ; solde débité seulement si le retrait précède le tombstone |
| 3 | B deux/trois confirmations AZ IA | PASS | 89,8 s | 25 × 3 confirmations simultanées | une seule réussit à chaque ronde ; effet validé exactement 1 fois (compteur transactionnel) |
| 4 | B2 confirmation AZ IA vs quarantaine | PASS | 2,5 s | 25 × (1 confirmation + 1 quarantaine) | 25 exécutées avant le tombstone, 0 bloquées : **aucune exécution après le tombstone**, mais la branche « refus » n'a pas été exercée dans cette exécution (voir §6) |
| 5 | E caractérisation de la primitive | PASS | 35,5 s | lecture tombstone absent vs profil existant | `absentOnly` et `withProfile` : conflit détecté et rejoué dans les deux cas dans cette exécution |
| 6 | C1 webhooks identiques | PASS | 25,8 s | 6 rondes × 3 webhooks identiques (+ nouvelle livraison) | 2 rejets de transaction par l'émulateur ; exactement un crédit, aucun double |
| 7 | C2 webhook vs quarantaine | PASS | 97,1 s | 25 rondes × (webhook + quarantaine), deux phases | 25 crédités (antérieurs au tombstone), 25 mis en attente `held_for_review` (postérieurs) ; aucun crédit perdu ni double |
| 8 | C3 profil anonymisé | PASS | 0,1 s | séquentiel | pas de crédit ; référence inconnue → 404 ; montant incorrect → 400 sans crédit |
| 9 | D quarantaine puis opération tardive | PASS | 0,8 s | séquentiel | suppression bloquée, aucun appel Auth (`disable/revoke/delete` vides), profil non anonymisé |

Erreurs Firestore : aucune remontée par les tests hors les 2 rejets de transaction rejoués en C1 (comportement attendu, sans effet financier). Aucun échec, donc aucune relance.

## 4. Contrôles financiers et tombstones
Assertions du test, toutes satisfaites : horodatage de **validation** (`createTime` serveur) de chaque demande/débit ≤ celui du tombstone ; refus ⇒ aucune écriture ; effet AZ IA exactement 1 ; crédit webhook exactement 1 par paiement, 0 pour paiement postérieur au tombstone ou profil anonymisé ; tombstone toujours créé ; Auth jamais touché. Pas de solde négatif ni de double débit/crédit constatés.

## 5. Nettoyage
`emulators:exec` a arrêté l'émulateur de la mission (SIGINT, hub et logging arrêtés). Après : 18089, 14400, 14500, 9151 libres ; 5001, 8080, 9099, 9199, 4000, 4400 **toujours en écoute** (émulateurs de l'utilisateur non perturbés). Fichiers de la mission (`fb89.json`, `run89.sh`, `out89.txt`, `firestore-debug.log`) conservés dans le scratchpad `e89/` (hors dépôt) ; aucune donnée utilisateur supprimée.

## 6. Limites et réserves
- B2 : dans cette exécution, la confirmation a toujours gagné face à la quarantaine (25/0) ; le chemin « refus par la garde » d'AZ IA n'a donc pas été observé en concurrence ici (il l'est par les tests unitaires du lot, 126/126 en 7E-88). L'invariant « jamais exécutée après le tombstone » est vérifié, pas la branche de refus.
- Le test prouve l'**absence de violation sur les entrelacements tirés** (délais aléatoires 0-80 ms) sur l'émulateur, pas la sécurité en production (charge, latence, multi-instances réelles).
- Durées longues (B, C2) : émulateur local seul ; pas de mesure de performance.
- Reste hors périmètre : lots 2B/2C/2D, commit 3, outil `held_for_review` (D4), quota **NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## 7. État Git avant / après
| | Avant | Après |
|---|---|---|
| HEAD | `294332e` | `294332e` |
| Index | vide | vide |
| `git status --short` | 89 entrées (hors ce rapport) | 90 (89 + rapport 7E88 déjà compté ; + ce rapport non encore compté au moment du contrôle) |
| `functions/index.js` | 8 hunks (7 P2 + 1 P3) | 8 hunks (inchangés ; P3 `setPharmaciePassword` distinct) |
`git diff --check` : seuls des avertissements LF/CRLF, aucune erreur. Aucun commit, aucun fichier de code ou de test modifié (le fichier de test n'est lu qu'en exécution).

## 8. Opérations distantes et émulateurs préexistants
Aucune opération distante (pas de push, fetch, déploiement, commande Firebase distante, accès prod/préprod). L'émulateur Firestore lancé est local, `demo-7e89`, 127.0.0.1. Les émulateurs préexistants (5001/8080/9099/9199/4000/4400) n'ont pas été arrêtés, redémarrés ni utilisés. `D:\h75.txt` non lu.

## Verdict
**9/9 CONCURRENCE VALIDÉE — LOT 2A PRÊT POUR REVUE**
(réserve consignée : branche de refus AZ IA de B2 non observée dans cette exécution ; preuve limitée à l'émulateur.) Aucun commit créé. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
