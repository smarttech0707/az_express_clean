# Mission 7E-78 — Correction documentaire et consolidation finale

> **[Mise à jour 7E-80]** Rapport historique : les passages « formulation non implémentée / écart ouvert » (tableau §1 lignes 1 et 6, §2, verdict) décrivent l'état avant 7E-79. L'écart est levé depuis 7E-79 (`ACCOUNT_DELETION_7E79_FLUTTER_MESSAGE.md`) ; les réserves du §5 autres que le message restent ouvertes.

Date : 2026-11-07 · Strictement local. Aucun `git add`, `git apply --cached`, commit, push, déploiement, commande distante, modification Firebase. Aucun code backend ou Flutter modifié. `operations_control/account_deletion` non créé. `D:\h75.txt` non supprimé (présent). Rapport 7E-77 conservé tel quel (c'est lui qui documente les écarts).

## 1. Les six écarts (7E-77 §3) et leur correction
| # | Document | Écart | Correction apportée |
|---|---|---|---|
| 1 | `7E76_FLUTTER_CONTRACT_TESTS` §3 | « Reessayer plus tard » au lieu de « Reessayez » ; message de refus | §3 réécrit : formulation retenue (ci-dessous), texte réellement présent dans le code (variante ASCII, « Reessayez »), écart ouvert signalé ; note de correction |
| 2 | `7E76_CALLABLE_ERROR_CONTRACT` §4 | affirmation non étayée sur le code déployé et `FieldValue` | remplacée par : l'absence d'impact sur le code déployé **n'est pas démontrée** (réserve ouverte) |
| 3 | `7E76_CALLABLE_ERROR_CONTRACT` §1 | « remonte (INTERNAL côté client) » présenté comme un fait | reformulé en **inférence**, non observée sur le transport réel |
| 4 | `7E76_FUNCTIONS_FULL_SUITE` | cause de la durée (×6) affirmée | reformulé : cause non mesurée ni investiguée ; hypothèses non vérifiées |
| 5 | `7E76_COMMIT1_REVIEW` §1 | renvoi à un « §2 » qui ne contient pas la comparaison | renvoi corrigé vers `7E76_FINAL_DECISION` §1 (comparaison octet à octet des 5 fichiers `functions/`) ; précision : les 3 `rules-tests` ne sont contrôlés que par horodatage |
| 6 | `7E76_FINAL_DECISION` | formulation du message tronquée (« … ») | texte complet dans §7(a) ; mention du statut « non implémentée » |

Autres harmonisations : `7E76_FINAL_DECISION` §6.4 (même correction que l'écart 2) ; `7E76_COMMIT1B_REVIEW` §4 (le message retenu n'est pas encore celui du code) ; ajout dans `7E76_FINAL_DECISION` d'un §3 bis « Provenance des résultats » distinguant exécutés en 7E-76, issus de missions précédentes, non exécutés, réserves ouvertes.

## 2. Message de refus — formulation retenue et écart avec le code (état à la date de 7E-78)
> **[Mise à jour 7E-80]** L'écart décrit ici a été **levé par 7E-79** : le code et les tests affichent et vérifient la formulation retenue (voir `ACCOUNT_DELETION_7E79_FLUTTER_MESSAGE.md`). Les phrases ci-dessous décrivent l'état avant 7E-79 et sont conservées comme historique.
Formulation retenue (demandée en 7E-78) :
« Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. »

**Les rapports 7E-76 présentent cette formulation comme la formulation retenue, pas comme implémentée.** Le code (`lib/services/account_deletion_service.dart`, inchangé) affiche la variante ASCII : « Le service de suppression de compte n est pas disponible pour le moment. Votre demande n a pas ete enregistree et votre compte reste inchange. Reessayez plus tard ou contactez le support. » Les tests widget cherchent des fragments de cette variante. Aligner le code modifie le commit 1B (service + assertions du test de dialogue) : **non fait, à autoriser séparément**. C'est une réserve ouverte, pas une validation.

## 3. Distinction des résultats dans les rapports
- `7E76_FINAL_DECISION` §3 bis : tableau exécuté 7E-76 / missions précédentes / non exécutés / réserves.
- `7E76_FUNCTIONS_FULL_SUITE` : sépare déjà les ciblés exécutés, les règles 69/69 (7E-75) et Firestore/Storage (7E-74).
- `7E77_FINAL_REVIEW` §6 : exécutés en 7E-77 vs non exécutés (inchangé).
- Réserves : listes `FINAL_DECISION` §6, `7E77_FINAL_REVIEW` §8 ; aucune réserve n'a été transformée en validation dans cette mission.

## 4. Contrôles finaux
| Contrôle | Résultat |
|---|---|
| 9 fichiers du commit 1 identiques (SHA-256 avant/après) | oui, 9/9 |
| 4 fichiers Flutter du commit 1B identiques | oui, 4/4 |
| Manifestes inchangés (`7E75_FINAL_P1_MANIFEST`, `7E75_COMMIT_COMMANDS`, SHA-256) ; manifestes de `7E77_FINAL_REVIEW` §4–5 non modifiés | oui, 2/2 + 7E-77 non touché |
| `git diff --check` sur les 13 fichiers suivis du périmètre | aucune erreur d'espaces (avertissements LF/CRLF attendus) |
| HEAD | `aa3d1b0`, branche `finalisation/az-express` |
| Index | vide (0 fichier) |
| Opération distante | aucune |
| Fichiers modifiés par 7E-78 | 6 documents `7E76_*` (CALLABLE_ERROR_CONTRACT, FLUTTER_CONTRACT_TESTS, FUNCTIONS_FULL_SUITE, COMMIT1_REVIEW, COMMIT1B_REVIEW, FINAL_DECISION) + ce rapport |
| `D:\h75.txt` | présent, non lu, non supprimé |
Aucun test applicatif n'a été (re)lancé dans cette mission : elle est documentaire ; les résultats cités restent ceux des missions antérieures.

## 5. Réserves encore ouvertes (inchangées)
SDK natif non testé sur appareil ; `dispatchRetry.emulator` en échec, à traiter séparément ; couverture financière incomplète jusqu'au commit 2 ; `admin.firestore.FieldValue` sous l'émulateur (impact sur le code déployé non démontré) ; « Firestore illisible » non validé sur le transport réel ; message de refus non aligné sur la formulation retenue ; quota **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## Verdict
**DOCUMENTATION CONSOLIDÉE — COMMITS INCHANGÉS**
(les documents sont corrigés et cohérents ; les commits 1 et 1B sont strictement inchangés ; l'écart de formulation entre le code et le message retenu est signalé comme réserve ouverte, non résolu). Aucun commit n'est créé ; toute opération Git exige une autorisation humaine distincte.
