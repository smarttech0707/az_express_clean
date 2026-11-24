# SEC-01 — S6.3 : migration des lecteurs publics multi-livreurs vers `driver_public`

Date : 2026-11-21
Type : migration ciblée (1 lecteur migré, 1 lecteur bloqué et documenté)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` §8 « Phase S6.3 — Requêtes multi-livreurs à champs publics », §13

## 1. Résumé exécutif

Des deux lecteurs multi-livreurs visés par cette phase, un seul a pu être migré : `destination_picker.dart::_loadNearestDriver` (filtre `isOnline`, champs `lat`/`lng`/`name`, tous dans `driver_public`). Le second, `live_marker_cache.dart::onlineDriversFeed()`, **n'a pas été migré** : l'examen de ses deux usages réels a révélé **deux raisons de blocage indépendantes**, dont une nouvelle, non identifiée dans les phases précédentes (S6.0/S6.0.1) : son consommateur client (`client_map.dart`) lit un champ `vehicle` absent de la liste blanche `driver_public`, en plus de son consommateur admin (`admin_live_tracking_page.dart`) qui lit `phone`, un champ privé. Les deux consommateurs partagent la même fonction de lecture : migrer casserait l'un des deux usages, et créer deux fonctions séparées aurait introduit une nouvelle architecture, explicitement interdite dans cette phase. Aucune Rules, Cloud Function, ni mécanisme GPS/synchronisation modifié.

## 2. Lecteurs identifiés

Chemins réels confirmés :

- `lib/widgets/destination_picker.dart` (`_DestinationPickerScreenState._loadNearestDriver`)
- `lib/widgets/live_marker_cache.dart` (`onlineDriversFeed()`), avec ses deux appelants réels confirmés par recherche exhaustive : `lib/screens/client/client_map.dart` et `lib/screens/admin/admin_live_tracking_page.dart`.

## 3. Examen détaillé de chaque lecteur

### 3.1 `destination_picker.dart::_loadNearestDriver` (lignes 71-113 avant migration)

- **Source Firestore** : `.collection('livreurs').where('isOnline', isEqualTo: true).limit(20).get()` — requête ponctuelle (`get()`, pas de `Stream`).
- **Champs réellement consommés** (lecture intégrale de la méthode) : `isOnline` (filtre de requête), `lat`, `lng` (sélection du plus proche par distance, et placeholder `(0,0)` filtré via `if (lat == 0 || lng == 0) continue;`), `name` (avec repli `'Livreur'`). Aucun autre champ lu dans cette méthode ni ailleurs dans le fichier (fichier lu en intégralité, 606 lignes).
- **Usages indirects** : le résultat (`_driverPos`, `_driverName`) alimente uniquement un marqueur de carte et un libellé d'info-bulle (`_setDestination`, lignes 161-274) — aucun traitement financier, administratif ou de contact.
- **Dépendance à un champ privé** : aucune.
- **Conclusion** : migration sans régression possible — **catégorie A confirmée**.

### 3.2 `live_marker_cache.dart::onlineDriversFeed()` (lignes 99-105 avant intervention)

- **Source Firestore** : `.collection('livreurs').where('isOnline', isEqualTo: true).snapshots()` — flux continu, adapté en `LiveDriverSnapshot` par `liveDriverSnapshotFromQuery` (lignes 80-95), qui transmet le **document complet** (`d.data()`) à chaque appelant, sans filtrage de champs à ce niveau.
- **Usages indirects — les deux seuls appelants réels, confirmés par recherche exhaustive** (`grep -rn "onlineDriversFeed"`) :
  - `client_map.dart::_onDriversSnapshot` (lignes 218-251) : lit `lat`, `lng`, `name` (repli `'Livreur'`) **et `data['vehicle']` (repli `''`)**, affiché en snippet du marqueur (ligne 244).
  - `admin_live_tracking_page.dart::_onDriversUpdate` (lignes 73-100) : lit `lat`, `lng`, `heading`, `speed`, `updatedAt`, `name` **et `phone`** (ligne 89, `_DriverStatus.phone`), ce dernier non affiché dans l'extrait lu mais stocké dans l'état de l'écran.
- **Vérification du champ `vehicle`** (nouvelle vérification, absente des rapports S6.0/S6.0.1, qui n'avaient listé que `lat`/`lng`/`name` pour `client_map.dart`) : `vehicle` est un champ réel et activement écrit sur `livreurs` — confirmé par `lib/models/driver_model.dart:20,30` (`"vehicle": vehicle` / `data["vehicle"]`) et `lib/web/pages/drivers_page.dart:242` (`'vehicle': _vehicle`, écriture admin). Il **n'apparaît pas** dans `driverPublicKeysValid()` (`firestore.rules:91-95` : `name, photoUrl, lat, lng, heading, speed, updatedAt, isOnline, isAvailable, isOnDelivery, avgRating, ratingCount` — 12 champs exactement, `vehicle` absent).
- **Vérification du champ `phone`** (déjà identifié en S6.0.1) : confirmé absent de la même liste blanche — champ privé par nature (contact direct), catégorie D du plan de référence.
- **Index Firestore** : vérifié dans `firestore.indexes.json` (823 lignes) — aucune entrée ni `fieldOverrides` pour `livreurs` ou `driver_public` ; une égalité simple sur `isOnline` sans `orderBy` combiné utilise l'indexation automatique par champ unique, activée par défaut. **Pas un blocage** (contrairement à ce que le plan S6.0 avait laissé en suspens, §8/S6.3).
- **Conclusion** : **non migrable dans cette phase**, pour deux raisons indépendantes et chacune suffisante à elle seule :
  1. `client_map.dart` dépend de `vehicle`, absent de `driver_public` — migrer sans ce champ changerait silencieusement le comportement de l'info-bulle (snippet vide au lieu du modèle de véhicule), une régression fonctionnelle.
  2. `admin_live_tracking_page.dart` dépend de `phone`, donnée privée absente de `driver_public` par conception (catégorie D du plan).
  Les deux appelants partagent une unique fonction (`onlineDriversFeed`) et un unique point de lecture Firestore : migrer cette fonction casserait nécessairement l'un des deux usages, sauf à construire deux fonctions de lecture séparées (une par type de consommateur) — ce qui constituerait une nouvelle architecture, explicitement interdite par cette phase (« Ne pas introduire une nouvelle architecture »). Étendre la liste blanche pour inclure `vehicle` et/ou `phone` est également explicitement interdit (« Ne pas ajouter de champs à la projection »).

## 4. Lecteurs migrés

Un seul : `destination_picker.dart::_loadNearestDriver` (détail en §3.1 et §6).

## 5. Lecteurs non migrés et justification

- **`live_marker_cache.dart::onlineDriversFeed()`** (et donc, par construction, ses deux appelants `client_map.dart` et `admin_live_tracking_page.dart`) : conservé intact. Raison documentée en détail en §3.2 — dépendance croisée à deux champs absents de `driver_public` (`vehicle` côté client, `phone` côté admin) portée par une fonction de lecture unique et partagée, dont la séparation en deux sources distinctes constituerait une nouvelle architecture hors du périmètre de cette phase. Aucune ligne de ce fichier ni de ses deux appelants n'a été modifiée.

## 6. Champs consommés

| Lecteur | Champs lus | Tous dans `driver_public` ? | Décision |
|---|---|---|---|
| `destination_picker.dart::_loadNearestDriver` | `isOnline` (filtre), `lat`, `lng`, `name` | Oui — 4/4 | **Migré** |
| `live_marker_cache.dart` → `client_map.dart` | `isOnline` (filtre), `lat`, `lng`, `name`, **`vehicle`** | Non — `vehicle` absent | **Non migré** |
| `live_marker_cache.dart` → `admin_live_tracking_page.dart` | `isOnline` (filtre), `lat`, `lng`, `heading`, `speed`, `updatedAt`, `name`, **`phone`** | Non — `phone` absent | **Non migré** |

## 7. Usages indirects vérifiés

- `destination_picker.dart` : aucun usage indirect au-delà de l'affichage carte/info-bulle dans le même fichier — confirmé par lecture intégrale (606 lignes).
- `live_marker_cache.dart::onlineDriversFeed` : recherche exhaustive (`grep -rn "onlineDriversFeed"`) confirmant exactement 2 appelants dans tout `lib/` — `client_map.dart` et `admin_live_tracking_page.dart` — tous deux lus en détail (respectivement lignes 218-251 et 64-134) pour établir la liste exacte des champs consommés par chacun, au-delà de la simple apparence à l'écran.

## 8. Fichiers modifiés

| Fichier | Nature du changement |
|---|---|
| `lib/widgets/destination_picker.dart` | 1 ligne (collection) + commentaire, dans `_loadNearestDriver()` |
| `test/widgets/destination_picker_nearest_driver_test.dart` | **Nouveau fichier** : test ciblé (4 cas) |
| `docs/SEC01_S6_3_MULTI_DRIVER_READERS_MIGRATION.md` | **Nouveau fichier** : ce rapport |

`lib/widgets/live_marker_cache.dart`, `lib/screens/client/client_map.dart` et `lib/screens/admin/admin_live_tracking_page.dart` : **non modifiés**, confirmé par `git status`/`git diff` scopés (§10).

## 9. Tests exécutés

- **Lecture intégrale** de `destination_picker.dart` (606 lignes) et de `live_marker_cache.dart` (106 lignes), ainsi que des deux appelants de ce dernier, pour établir les listes de champs exactes des §3/§6 — pas une présomption fondée sur un résumé antérieur.
- **Recherche exhaustive** `grep -rn "onlineDriversFeed"` et `grep -n "'vehicle'|\"vehicle\""`/`grep -n "'phone'|\"phone\""` dans les fichiers concernés, pour confirmer la portée réelle des deux blocages.
- **Vérification de `firestore.indexes.json`** (823 lignes) : absence de `fieldOverrides` désactivant l'indexation automatique pour `livreurs`/`driver_public`, confirmant qu'aucun index composite n'est requis pour la requête migrée (égalité simple sur `isOnline`, pas de `orderBy` combiné).
- **Diff contrôlé** (`git diff`) sur `destination_picker.dart` : changement strictement limité à la ligne de collection et son commentaire.

## 10. Tests non exécutés et raisons

- **`flutter test`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente). Non exécuté, honnêtement signalé.
- **Test widget/intégration pilotant un vrai flux/requête Firestore `driver_public`** : non réalisable sans simulateur Firestore absent du dépôt, et l'ajout d'une dépendance pour y remédier est explicitement interdit dans cette phase. Remplacé par un test ciblé (§11) isolant l'algorithme de sélection du livreur le plus proche (logique pure, sans Firestore), reproduisant exactement les expressions de `_loadNearestDriver`.
- **Test Rules** : non nécessaire — la lecture authentifiée de `driver_public` est déjà couverte par les 19 tests `rules-tests/driver-public.rules.test.js` (S5.3.5), non affectés par une migration de *lecteur* côté client.

## 11. Résultats

Test ajouté `test/widgets/destination_picker_nearest_driver_test.dart` (4 cas : aucun document en ligne, document avec placeholder `(0,0)` ignoré, nom absent → repli `'Livreur'`, sélection du livreur le plus proche parmi plusieurs) — reproduit fidèlement l'algorithme de `_loadNearestDriver` (filtrage du placeholder, distance minimale via `Geolocator.distanceBetween`, repli de nom). Non exécuté par `flutter test` (indisponible), relu manuellement contre le code migré pour confirmer la correspondance exacte.

## 12. Diff vérifié

- `destination_picker.dart` : diff limité à 2 lignes ajoutées (commentaire) + 1 ligne modifiée (`'livreurs'` → `'driver_public'`), confirmé par `git diff` ciblé — aucune autre ligne touchée, aucune modification locale préexistante sur ce fichier à préserver (le diff observé est entièrement celui de cette migration).
- `live_marker_cache.dart`, `client_map.dart`, `admin_live_tracking_page.dart` : confirmés absents de `git status --porcelain` pour cette phase — aucune ligne touchée.
- Confirmé qu'aucun fichier Rules, Cloud Function, configuration, dépendance, lockfile, mécanisme GPS ou de synchronisation `driver_public` n'apparaît dans le diff de cette phase.

## 13. Risques résiduels

- **`live_marker_cache.dart` reste sur `livreurs`** : aucun changement de surface d'exposition par rapport à l'état actuel (déjà en production) — ni amélioration ni dégradation. Reste un candidat futur, mais seulement après une décision explicite du porteur du projet sur l'une des deux options suivantes (non tranchées ici, hors périmètre) : (a) séparer `onlineDriversFeed` en deux fonctions distinctes selon le consommateur (client public vs admin), ou (b) accepter que `client_map.dart` perde l'affichage du modèle de véhicule dans son info-bulle si une migration partielle était un jour décidée. Aucune de ces deux options n'a été mise en œuvre ici.
- **Fenêtre de synchronisation `driver_public`** (déjà documentée en S6.0/S6.1/S6.2) : un livreur tout juste passé en ligne peut apparaître avec un nom en retard de quelques secondes sur `destination_picker.dart` — cosmétique, déjà couvert par le repli `'Livreur'` existant.
- **Aucun risque de sécurité introduit** : le seul lecteur migré passe d'une collection lisible par tout utilisateur authentifié avec champs privés inclus (`livreurs`) vers une collection strictement plus restreinte en champs (`driver_public`) avec la même condition d'authentification (`isAuth()`) — réduction de surface, pas d'élargissement. Le lecteur non migré reste inchangé, donc sans risque nouveau.

## 14. Confirmation de préservation des modifications locales

Confirmé : aucune des nombreuses modifications locales préexistantes et sans rapport (listées par `git status` au démarrage de cette phase) n'a été touchée. Aucune opération Git destructive n'a été utilisée. Aucun fichier non suivi antérieur n'a été supprimé ou écrasé.

## 15. Confirmation Firebase / déploiement

Aucune connexion à un Firebase réel. Aucun déploiement. `firestore.rules` non modifié. Aucune Cloud Function modifiée. Aucun mécanisme GPS (`driver_location_service.dart`) ni de synchronisation `driver_public` (`functions/driverPublicSync.js`) modifié. Aucune dépendance ni lockfile modifié. Aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.

## 16. Confirmation que S6.4 n'a pas commencé

Confirmé : aucun lecteur hybride (`driver_profil.dart`, `driver_dashboard.dart::_listenDriverDoc`, `admin_map.dart`, `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`, `customer_tracking_screen.dart`) n'a été touché. Le périmètre est resté strictement limité aux deux lecteurs multi-livreurs de S6.3, avec un seul effectivement migré.

## 17. Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

Le lecteur réellement migrable (`destination_picker.dart`) l'a été, avec un changement minimal et vérifié. Le second lecteur visé par le plan de référence (`live_marker_cache.dart`) n'a pas pu être migré : son examen approfondi (usages indirects des deux appelants, pas seulement leur apparence à l'écran) a révélé une dépendance bloquante supplémentaire, non identifiée dans les phases précédentes (`vehicle`, en plus de `phone` déjà connu), confirmant qu'une migration aurait exigé soit d'étendre la liste blanche, soit d'introduire une nouvelle architecture de lecture à deux sources — les deux explicitement interdites dans cette phase. La réserve porte donc sur ce second lecteur, volontairement laissé intact et documenté plutôt que migré par improvisation, conformément à la consigne.

STOP après ce rapport. En attente d'autorisation avant S6.4 ou toute autre phase.
