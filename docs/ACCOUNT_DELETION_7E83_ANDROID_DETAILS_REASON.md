# Mission 7E-83 — Diagnostic natif du transport `details.reason` sur Android

Date : 2026-11-08 · Strictement local. Aucun `git add`, commit, push, déploiement ni commande distante. Backend, règles et secrets inchangés. Production `az-express-b0469` non utilisée. `operations_control/account_deletion` jamais créé (porte absente, scénario A1). Rapport non suivi.

## 1. Audit initial
HEAD `65e738b`, branche `finalisation/az-express`, index vide, 4 fichiers du commit 1B modifiés non committés, aucun fichier du commit 1 modifié, `google-services.json` intact (SHA-256 identique avant/après), Samsung SM-A115F connecté (Android 12), `cloud_functions` 6.3.2 (`pubspec.lock`). Un second téléphone (Infinix) était branché : jamais ciblé (`-s R9PN9018DDJ`).

## 2. Méthode
Instrumentation **temporaire** (une ligne `print`, marquée `7E83-TEMP`) dans le `catch FirebaseFunctionsException` de `submitRequest`, ne journalisant que : `e.code`, type Dart de `details`, `details is Map`, type de `details['reason']`, égalité exacte avec `ACCOUNT_DELETION_NOT_ENABLED`, résultat « structuré seul » (code + Map + raison, sans regarder le message), présence du code dans le message, résultat de `isGateClosedRefusal`. Aucun UID, e-mail, téléphone, jeton, reçu ni contenu de `details`. APK debug `com.azexpress.app.test` reconstruit avec les mêmes garde-fous que 7E-82 (applicationId vérifié, scan d'identifiants de production passé), backend = copie de staging du commit 65e738b sur mes émulateurs (ports 15001/18080/19099), tunnels `adb reverse`.

## 3. Résultat réel sur appareil (scénario A1 : compte synthétique, porte absente)
Ligne unique relevée dans logcat :

`[7E83_DIAG] code=failed-precondition detailsType=_Map<Object?, Object?> detailsIsMap=true reasonType=String reasonExact=true structuredOnly=true messageHasCode=true isGateClosedRefusal=true`

| Élément | Valeur réelle observée |
|---|---|
| Code d'erreur | `failed-precondition` |
| Type de `e.details` | `_Map<Object?, Object?>` (est une Map) |
| `details['reason']` | `String`, exactement `ACCOUNT_DELETION_NOT_ENABLED` |
| Reconnaissance par la raison structurée seule | **oui** (`structuredOnly=true`, calculé sans le message) |
| Message serveur | contient aussi le code (`messageHasCode=true`) : le message seul aurait donc suffi pour le repli ; la preuve de la voie structurée vient de `structuredOnly=true` |
| Affichage | message exact « Le service de suppression de compte n’est pas disponible… » (égalité caractère pour caractère, capture `A1_diag.png` dans le scratchpad) |

Le transport natif Android du plugin 6.3.2 restitue donc bien `details` comme Map avec `reason` : la forme jusque-là seulement déduite du code du plugin est **observée**.

## 4. Tests de discrimination (unitaires — pas natifs)
Ajoutés dans `test/services/account_deletion_service_test.dart` (fichier du commit 1B ; 3 tests) :
1. raison structurée correcte + message sans aucun rapport avec le code → refus reconnu, `resolveCallableFailure` lève `AccountDeletionUnavailableException`, ancien reçu jamais lu ;
2. message contenant le code mais **sans** `details` structurés (trois variantes) → reconnu uniquement par le **repli textuel**, explicitement nommé comme tel (version de fonction antérieure) ;
3. ni raison structurée ni code dans le texte → jamais un refus.
Exécution du fichier : **27/27 PASS**. Ces tests ne sont **pas** des tests natifs ; le cas « repli textuel seul » n'a **pas** été testé sur appareil (le backend n'a pas été modifié pour fabriquer une erreur artificielle). Le repli textuel est conservé et documenté dans le code.

## 5. Restauration et contrôles
| Contrôle | Résultat |
|---|---|
| Instrumentation | retirée ; `account_deletion_service.dart` restauré, SHA-256 identique à l'original (`1EE6EBBB…`), 0 marque `7E83` dans `lib/` |
| Fichiers non concernés | dialogue, test du dialogue, `google-services.json`, `functions/accountDeletion.js` : SHA-256 identiques avant/après |
| Fichier modifié légitimement | `test/services/account_deletion_service_test.dart` (3 tests ajoutés, périmètre du commit 1B) |
| Journal complet logcat | supprimé ; seule la ligne de diagnostic ci-dessus est conservée (aucune donnée personnelle) |
| HEAD / index / commits | `65e738b`, index vide, 0 commit en plus, aucun push, aucun déploiement |
| Tunnels ADB | retirés (`reverse --list` vide) |
| Émulateurs | les miens arrêtés ; ceux de l'utilisateur (5001/8080/9099) toujours actifs |
| APK instrumenté | supprimé de `build/` ; **la copie installée sur le Samsung contient encore le diagnostic** (paquet de test `com.azexpress.app.test`, non désinstallé) — à désinstaller ou réinstaller si souhaité |
| `git status` | seul changement : ce rapport (et le test ajouté, déjà suivi comme modifié) |

## 6. Réserves restantes
- Exécution combinée service + dialogue et `flutter analyze` relancés en fin de mission : **résultat non confirmé au moment de la rédaction** (le service seul : 27/27). À relancer.
- Repli textuel non testé nativement ; scénario D (autres codes) toujours non testé sur appareil ; iOS non testé ; un seul appareil Android 12.
- `dispatchRetry.emulator` en échec historique ; couverture financière incomplète avant le commit 2 ; `admin.firestore.FieldValue` sous l'émulateur ; **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## Verdict
**DETAILS.REASON VALIDÉ NATIVEMENT — COMMIT 1B PRÊT POUR AUTORISATION**
(sous réserve de relancer service + dialogue + analyse, et des réserves ci-dessus). Aucun commit créé ; en attente d'une nouvelle autorisation humaine.
