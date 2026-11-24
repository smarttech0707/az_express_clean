# SEC-01 — S6.2 : migration des services de tracking temps réel vers `driver_public`

Date : 2026-11-21
Type : migration ciblée (2 services, lecture de la projection publique uniquement)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` §8 « Phase S6.2 — Services de suivi temps réel (meilleur candidat global) », §4/A, §5

## 1. Résumé exécutif

`realtime_tracking_service.dart` et `tracking_service.dart` ont été migrés de `livreurs` vers `driver_public`. Les deux étaient déjà identifiés en S6.0 comme correspondance exacte à la projection (catégorie A) : vérification faite dans le code actuel, les champs réellement consommés (`lat`/`lng`/`heading`/`speed`/`updatedAt`/`isOnline`/`name`/`photoUrl` pour l'un, `lat`/`lng` seulement pour l'autre) sont tous les 8 dans la liste blanche de `driver_public`. Seul le nom de la collection source a changé dans chaque service, à l'intérieur de sa méthode d'écoute Firestore. Aucun mécanisme d'écriture GPS, de synchronisation, Rule ou Cloud Function n'a été touché. Les tests existants (interpolation visuelle pure) ne dépendent pas de la collection lue et restent valides sans modification.

## 2. Services identifiés

Chemins réels confirmés avant intervention :

- `lib/services/realtime_tracking_service.dart` (classe `RealtimeTrackingService`)
- `lib/services/tracking_service.dart` (classe `TrackingService`, + `TrackingState`)

### 2.1 `RealtimeTrackingService`

- **Lecture Firestore unique** : `_startFirestoreListener()` (lignes 113-121 avant migration) — un seul `.collection('livreurs').doc(_driverId).snapshots()`, aucune autre lecture Firestore dans tout le fichier (vérifié par lecture intégrale).
- **Champs réellement consommés** : via `DriverLocationModel.fromMap()` (`lib/models/driver_location_model.dart:31-45`) — `lat`, `lng`, `heading`, `speed`, `updatedAt`, `isOnline`, `name`, `photoUrl`. Exactement les 8 champs attendus par le plan S6.0 (§8, Phase S6.2).
- **Abonnement Stream** : `StreamSubscription<DocumentSnapshot>? _firestoreSub`, créé dans `_startFirestoreListener()`, annulé dans `dispose()` (ligne 292 : `_firestoreSub?.cancel()`). Mécanisme inchangé.
- **États absence/erreur** : `if (!snap.exists) return;` et `if (data == null) return;` (lignes 124-126) — pas de propagation d'erreur visible à l'UI au-delà de `onError: (_) {}` (déjà le comportement avant migration, non modifié). `DriverLocationModel.isValid` (`latitude != 0 || longitude != 0`) filtre le placeholder `(0,0)`, inchangé.
- **Dépendance à un champ hors `driver_public`** : aucune.

### 2.2 `TrackingService`

- **Lecture Firestore unique** : `_start()` (lignes 114-121 avant migration) — un seul `.collection('livreurs').doc(_driverId).snapshots()`.
- **Champs réellement consommés** : `_onDriverSnapshot()` (lignes 123-144) lit uniquement `data['lat']` et `data['lng']` ; `if (lat == 0 || lng == 0) return;` filtre le placeholder. Aucun autre champ lu dans tout le fichier (vérifié par lecture intégrale, y compris `TrackingState`, qui ne contient que des données calculées, pas de champs Firestore bruts).
- **Abonnement Stream** : `StreamSubscription<DocumentSnapshot>? _driverSub`, créé dans `_start()`, annulé dans `dispose()` (ligne 298 : `_driverSub?.cancel()`). Mécanisme inchangé.
- **États absence/erreur** : `if (!doc.exists) return;`, `if (data == null) return;`, filtre `lat == 0 || lng == 0`, `onError: (_) {}` — identiques à avant migration.
- **Dépendance à un champ hors `driver_public`** : aucune.

## 3. Services migrés

Les deux, sans exception.

### 3.1 `realtime_tracking_service.dart`

```diff
   void _startFirestoreListener() {
     // Ne rien écouter si pas encore de livreur assigné (évite doc path vide)
     if (_driverId.isEmpty) return;
+    // SEC-01 / S6.2 : tous les champs consommés par `DriverLocationModel.fromMap`
+    // (lat/lng/heading/speed/updatedAt/isOnline/name/photoUrl) sont dans la
+    // projection publique `driver_public` → plus besoin de la collection
+    // privée `livreurs` pour ce suivi.
     _firestoreSub = FirebaseFirestore.instance
-        .collection('livreurs')
+        .collection('driver_public')
         .doc(_driverId)
         .snapshots()
         .listen(_onFirestoreUpdate, onError: (_) {});
   }
```

Aucune autre ligne du fichier modifiée. La logique d'animation, de recalcul d'itinéraire, les getters publics et `dispose()` sont strictement identiques.

### 3.2 `tracking_service.dart`

```diff
   void _start() {
     if (_driverId.isEmpty) return;
+    // SEC-01 / S6.2 : seuls `lat`/`lng` sont consommés (`_onDriverSnapshot`),
+    // tous deux dans la projection publique `driver_public`.
     _driverSub = FirebaseFirestore.instance
-        .collection('livreurs')
+        .collection('driver_public')
         .doc(_driverId)
         .snapshots()
         .listen(_onDriverSnapshot, onError: (_) {});
   }
```

Aucune autre ligne liée à cette migration. Le fichier contenait déjà, avant cette phase, une modification locale préexistante et sans rapport (ajout de `routeIsEstimate` à `TrackingState` et `_calculateRoutes`) — confirmée intacte, non touchée par cette intervention (diff isolé vérifié en §9).

## 4. Services non migrés et justification

Aucun autre service de tracking temps réel n'était dans le périmètre de cette phase. Les deux services ciblés par le plan S6.0 pour S6.2 (`realtime_tracking_service.dart`, `tracking_service.dart`) sont les seuls candidats de cette étape ; aucun cas bloquant (téléphone, wallet, administratif, champ absent, séparation public/privé non établie) n'a été rencontré sur l'un ou l'autre — tous deux étaient déjà classés catégorie A sans réserve.

Pour mémoire (hors périmètre, non touchés) : les lecteurs de suivi restant sur `livreurs` — `customer_tracking_screen.dart::_loadDriverInfoById` (hybride `name`/`photoUrl`/`phone`/`avgRating`, catégorie B/D, relève de S6.4), `suivi_commande.dart::_listenDriver` et `itemBuilder` (respectivement catégorie A isolée et catégorie B, non inclus dans le périmètre explicite de S6.1/S6.2), `destination_picker.dart` et `live_marker_cache.dart` (requêtes multi-livreurs, relèvent de S6.3) — restent inchangés, conformément au plan et à l'interdiction d'élargir le périmètre.

## 5. Champs consommés (récapitulatif)

| Service | Champs lus | Tous dans `driver_public` ? |
|---|---|---|
| `RealtimeTrackingService` (via `DriverLocationModel.fromMap`) | `lat`, `lng`, `heading`, `speed`, `updatedAt`, `isOnline`, `name`, `photoUrl` | Oui — 8/8 |
| `TrackingService` (`_onDriverSnapshot`) | `lat`, `lng` | Oui — 2/2 |

Aucun champ supplémentaire n'a été inventé ni ajouté à la projection ; la liste blanche de 12 champs (`firestore.rules::driverPublicKeysValid()` / `functions/driverPublicSync.js::DRIVER_PUBLIC_FIELDS`/`GPS_PROJECTION_FIELDS`) n'a pas été consultée pour être modifiée, seulement pour confirmer la couverture.

## 6. Fichiers modifiés

| Fichier | Nature du changement |
|---|---|
| `lib/services/realtime_tracking_service.dart` | 1 ligne (collection) + commentaire, dans `_startFirestoreListener()` |
| `lib/services/tracking_service.dart` | 1 ligne (collection) + commentaire, dans `_start()` |
| `docs/SEC01_S6_2_REALTIME_TRACKING_MIGRATION.md` | **Nouveau fichier** : ce rapport |

Aucun nouveau fichier de test créé dans cette phase (justifié en §7/§8).

## 7. Tests exécutés

- **Lecture intégrale des deux services** et de `DriverLocationModel` pour confirmer exhaustivement les champs consommés (§2) — pas une présomption fondée sur le nom des champs affichés à l'écran, mais sur le code de parsing réel.
- **Recherche exhaustive** `grep -n "livreurs|driver_public"` sur les deux fichiers : confirme qu'aucune lecture `livreurs` ne subsiste et qu'une seule lecture `driver_public` existe par fichier.
- **Identification des appelants** (`grep -rn "RealtimeTrackingService(|TrackingService("`) : `customer_tracking_screen.dart` (×2) et `order_tracking_map.dart` (×2) — aucun des deux n'instancie ces services avec des attentes sur la collection source (le constructeur ne prend que `driverId`/`clientPosition`/`destination`), donc aucun impact d'appelant à vérifier davantage dans ce périmètre.
- **Tests existants relus** : `test/services/realtime_tracking_service_animation_test.dart` et `test/services/tracking_service_animation_test.dart` instancient les deux services avec `driverId: ''` — la condition `if (_driverId.isEmpty) return;` empêche toute connexion Firestore dans ces tests (confirmé en lisant `_startFirestoreListener()`/`_start()`) : ils exercent uniquement la logique pure d'animation (`debugStartVisualTransition`), jamais la lecture Firestore. **Aucune adaptation n'était donc nécessaire** : ces tests restent valides à l'identique, qu'ils lisent `livreurs` ou `driver_public`, puisqu'ils ne lisent ni l'un ni l'autre.
- **Diff contrôlé** (`git diff`) sur les deux fichiers : chaque changement correspond strictement à la migration ; les modifications locales préexistantes et sans rapport (ex. `routeIsEstimate` dans `tracking_service.dart`) ont été identifiées et confirmées intactes.

## 8. Tests non exécutés et raisons

- **`flutter test`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente — `which`/`--version` sans résultat). Non exécuté, honnêtement signalé ; aucun résultat n'est fabriqué.
- **Test dynamique vérifiant que le Stream lit effectivement `driver_public` en conditions réelles** : non réalisable sans simulateur Firestore (`fake_cloud_firestore` ou équivalent), absent du dépôt — et la consigne de cette phase interdit explicitement d'ajouter une dépendance pour rendre un test exécutable. Remplacé par la vérification statique exhaustive (§7) : lecture complète du code de parsing, confirmation que 100 % des champs consommés appartiennent à la liste blanche déjà testée par `rules-tests/driver-public.rules.test.js` (S5.3.5, lecture authentifiée) et par `functions/test/driverPublicSync.test.js` (S2, fiabilité de la projection).
- **Test manuel sur appareil réel pendant une livraison simulée** (mentionné par le plan S6.0 comme exigence standard avant observation en production) : hors périmètre technique de cette session (pas d'accès à un appareil physique ni à un Firebase réel, interdit par les contraintes absolues).

## 9. Résultats et vérification du diff

- `git diff` sur les deux fichiers : dans chaque cas, la modification de cette phase est limitée à la ligne de collection et à son commentaire explicatif, à l'intérieur de la méthode d'écoute Firestore. Aucune ligne relative à l'animation, au recalcul d'itinéraire, aux getters publics ou à `dispose()` n'a été touchée.
- Confirmé qu'aucune autre lecture `livreurs` ne subsiste dans l'un ou l'autre fichier (`grep`, §7).
- Confirmé qu'aucun fichier d'écriture GPS (`driver_location_service.dart`), de synchronisation (`functions/driverPublicSync.js`), de Rules (`firestore.rules`) ou de Cloud Function n'apparaît dans le diff de cette phase.
- Confirmé que les modifications locales préexistantes et sans rapport dans `tracking_service.dart` (`routeIsEstimate`) sont restées intactes — isolées du changement de cette phase.
- Confirmé qu'aucun lecteur hybride ou de catégorie B/C/D n'a été touché (aucun fichier autre que les deux services ciblés n'apparaît dans le diff de cette phase).

## 10. Risques résiduels

- **Fenêtre de latence de synchronisation** (déjà documentée en S6.0 §5/§6) : `driver_public.name`/`.photoUrl` peuvent être en retard de quelques secondes par rapport à `livreurs` ; sans impact fonctionnel critique ici, car `RealtimeTrackingService` ne les utilise que pour un affichage secondaire (le modèle les porte mais ni l'un ni l'autre service ne les utilise pour une décision logique — vérifié : aucune branche conditionnelle du code de ces deux services ne teste `name`/`photoUrl`).
- **Péremption GPS côté lecteur public** : comme déjà signalé en S6.0 §13, aucun des deux services n'implémente une logique de péremption équivalente au seuil serveur du dispatch (`STALE_MINUTES`) — risque préexistant, non introduit ni aggravé par cette migration (le comportement est identique à avant, seule la collection source change).
- **Aucun risque de sécurité introduit** : les deux services passent d'une collection lisible par tout utilisateur authentifié avec champs privés inclus (`livreurs`) vers une collection strictement plus restreinte en champs (`driver_public`, 12 champs) avec la même condition d'authentification (`isAuth()`) — réduction de surface, pas d'élargissement.
- **Absence de repli automatique vers `livreurs`** en cas d'échec de lecture `driver_public` (ex. document non encore créé pour un livreur qui n'a jamais émis sa position) : comportement identique à avant (`if (!snap.exists) return;` / `if (!doc.exists) return;`), pas une régression, mais le plan pré-existant (`docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`) recommandait un repli explicite comme filet de sécurité — non implémenté ici (introduirait une nouvelle logique de repli, hors périmètre strict de cette phase, qui demande de préserver les mécanismes existants sans en ajouter).

## 11. Confirmation de préservation des modifications locales

Confirmé : les modifications locales préexistantes et sans rapport (dans `tracking_service.dart` notamment, et les très nombreuses autres listées par `git status` au démarrage de cette phase) sont restées intactes. Aucune opération Git destructive n'a été utilisée. Aucun fichier non suivi antérieur n'a été supprimé ou écrasé.

## 12. Confirmation Firebase / déploiement

Aucune connexion à un Firebase réel. Aucun déploiement. `firestore.rules` non modifié. Aucune Cloud Function modifiée (`functions/` intact, confirmé par absence dans le diff de cette phase). Aucun mécanisme d'écriture GPS ni de synchronisation `driver_public` modifié (`driver_location_service.dart`, `functions/driverPublicSync.js` non touchés). Aucune dépendance ni lockfile modifié. Aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.

## 13. Confirmation que S6.3 n'a pas commencé

Confirmé : aucune requête multi-livreurs (`destination_picker.dart`, `live_marker_cache.dart`), aucun lecteur hybride, aucun mécanisme `driverPhone` n'a été touché. Le périmètre est resté strictement limité aux deux services de tracking temps réel identifiés par le plan S6.0 pour S6.2.

## 14. Verdict

**MIGRATION VALIDÉE**

Les deux services identifiés comme meilleur candidat global (correspondance exacte de champs, aucun prérequis manquant) ont été migrés avec un changement strictement minimal (une ligne par fichier), sans toucher à l'écriture GPS, à la synchronisation, aux Rules ni aux Cloud Functions, et sans introduire de nouveau mécanisme de cache ou de repli. Les tests existants restent valides sans modification car ils n'exercent pas le chemin Firestore ; les limites de vérification dynamique (absence de simulateur Firestore dans le dépôt, `flutter` indisponible) sont documentées honnêtement plutôt que contournées, conformément à l'interdiction explicite d'ajouter une dépendance pour les rendre exécutables.

STOP après ce rapport. En attente d'autorisation avant S6.3 ou toute autre phase.
