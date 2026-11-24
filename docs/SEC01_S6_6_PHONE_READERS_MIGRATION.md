# SEC-01 — S6.6 : migration des 6 lecteurs non-admin dépendants de `phone`

Date : 2026-11-21
Type : migration ciblée, Option D (séparation locale des lecteurs) exclusivement
Référence : `docs/SEC01_S6_5_PHONE_DEPENDENCY_AUDIT.md` §7-D, §9 ; pattern déjà validé en `docs/SEC01_S6_4_HYBRID_READERS_MIGRATION.md`

## 1. Résumé exécutif

Des 6 lecteurs autorisés, **4 ont été migrés** par séparation locale (un second flux/appel Firestore distinct pour `phone`, conservé sur `livreurs`, tandis que les champs publics basculent sur `driver_public`) : `customer_tracking_screen.dart`, `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`. **2 n'ont nécessité aucune modification** : `web_client_dashboard.dart::_callDriver` et `suivi_commande.dart::_callDriver` ne lisent déjà **que** `phone` (aucun champ public dans la même requête) — il n'y a rien à séparer, et forcer un changement aurait été un refactoring inutile. Aucune Rule, Cloud Function, configuration, `driver_public`, `live_marker_cache.dart`, `admin_map.dart` ni `driver_profil.dart` n'a été touché. `phone` n'a jamais été exposé dans `driver_public`.

## 2. Les 6 lecteurs examinés

| # | Fichier | Requête actuelle confirmée | Champs mixés avec `phone` ? |
|---|---|---|---|
| 1 | `lib/web/pages/client/web_client_dashboard.dart::_callDriver` | `.collection('livreurs').doc(driverId).get()`, ligne 909 | Non — `phone` seul |
| 2 | `lib/screens/client/suivi_commande.dart::_callDriver` | `.collection("livreurs").doc(driverId).get()`, ligne 139 | Non — `phone` seul |
| 3 | `lib/screens/customer_tracking_screen.dart::_loadDriverInfoById` | `.collection('livreurs').doc(driverId).get()`, ligne 313 (avant migration) | Oui — `name`/`photoUrl`/`avgRating` |
| 4 | `lib/screens/pharmacie/pharmacie_dashboard.dart::_DriverInfoCard` | `.collection('livreurs').doc(driverId).snapshots()`, ligne 962 (avant migration) | Oui — `name`/`photoUrl` (+ `motoModel`, également privé) |
| 5 | `lib/screens/boulangerie/boulangerie_dashboard.dart` (inline builder) | `.collection('livreurs').doc(driverId).snapshots()`, ligne 708 (avant migration) | Oui — `name`/`isOnline` |
| 6 | `lib/screens/seller/seller_dashboard.dart::_DriverSection` | `.collection('livreurs').doc(driverId).snapshots()`, ligne 1421 (avant migration) | Oui — `name`/`lat`/`lng`/`isOnline` |

Chaque requête a été re-vérifiée dans le fichier réel avant toute modification (pas sur la seule base du rapport S6.5) — confirmée identique à l'audit.

## 3. Lecteurs migrés

### 3.1 `customer_tracking_screen.dart::_loadDriverInfoById`

Avant :
```dart
final doc = await FirebaseFirestore.instance.collection('livreurs').doc(driverId).get();
...
_driverName = d['name'] as String?;
_driverPhoto = d['photoUrl'] as String?;
_driverPhone = d['phone'] as String?;
_driverRating = (d['avgRating'] as num?)?.toDouble();
```

Après : un premier `get()` sur `driver_public` alimente `_driverName`/`_driverPhoto`/`_driverRating` ; un second `get()`, inchangé, sur `livreurs`, alimente uniquement `_driverPhone`. Les deux appels sont indépendants (chacun dans son propre `try/catch`), donc un échec de l'un n'empêche pas l'autre de réussir — comportement au moins aussi robuste qu'avant (un seul `catch` englobant masquait auparavant un échec partiel).

### 3.2 `pharmacie_dashboard.dart::_DriverInfoCard`

`StreamBuilder` unique → `StreamBuilder` imbriqué : extérieur sur `driver_public` (`name`/`photoUrl`), intérieur sur `livreurs` (`phone`/`motoModel`, les deux absents de la projection publique). Le contenu visuel (`Container` et tout son arbre de widgets) a été extrait dans une méthode `_buildCard(context, name, phone, photo, moto)`, appelée depuis le `builder` du flux intérieur — aucune ligne de présentation modifiée, seulement son point d'appel.

### 3.3 `boulangerie_dashboard.dart` (inline builder)

Même principe, sans extraction de méthode (le bloc reste inline, imbriqué directement) : `StreamBuilder` extérieur sur `driver_public` (`name`/`isOnline`), `StreamBuilder` intérieur sur `livreurs` (`phone` seul). Le `Container` existant est désormais retourné depuis le `builder` du flux intérieur.

### 3.4 `seller_dashboard.dart::_DriverSection`

Même principe que 3.2 : extérieur sur `driver_public` (`name`/`lat`/`lng`/`isOnline`), intérieur sur `livreurs` (`phone` seul), contenu visuel extrait dans `_buildCard(name, phone, lat, lng, isOnline)`.

Dans les 4 cas, le pattern est strictement identique à celui déjà validé en S6.4 pour `driver_dashboard.dart::_listenDriverDoc` (un second flux Firestore indépendant pour le champ privé, sans fusion de flux ni nouvelle classe) — adapté ici à des `StatelessWidget` via un `StreamBuilder` imbriqué plutôt qu'une seconde `StreamSubscription` de `State`, l'équivalent exact du même principe pour ce type de widget.

## 4. Lecteurs non migrés et justification

- **`web_client_dashboard.dart::_callDriver`** et **`suivi_commande.dart::_callDriver`** : aucune modification. Les deux lisent déjà **exclusivement** `phone` — aucun champ public n'est lu dans la même requête, donc il n'y a rien à séparer. Appliquer malgré tout un changement de collection aurait été soit incorrect (migrer `phone` vers `driver_public`, interdit), soit un changement cosmétique sans aucun effet réel (passer sur `driver_public` puis immédiatement rebasculer sur `livreurs` pour le seul champ lu) — un refactoring inutile, explicitement à éviter.
- **`admin_map.dart`** : non touché, conformément à l'exclusion explicite (accès admin déjà légitime et complet).
- **`live_marker_cache.dart`** : non touché, conformément à l'exclusion explicite (dépendances non résolues, `vehicle` + `phone`, cf. S6.3.1).
- **`driver_profil.dart`** : non touché, conformément à l'exclusion explicite (risque de régression de synchronisation de la propre photo, identifié en S6.4).
- **`suivi_commande.dart::itemBuilder`** (ligne 305) et **`suivi_commande.dart::_listenDriver`** (ligne 1341) : non touchés — ni l'un ni l'autre ne fait partie des 6 lecteurs explicitement autorisés par cette mission (le premier est un lecteur hybride non examiné dans ce périmètre précis, le second ne lit que des champs GPS, sans `phone`) ; les toucher aurait élargi le périmètre sans autorisation.

## 5. Séparation des champs publics et privés (récapitulatif)

| Lecteur migré | Champs → `driver_public` | Champs restant sur `livreurs` |
|---|---|---|
| `customer_tracking_screen.dart` | `name`, `photoUrl`, `avgRating` | `phone` |
| `pharmacie_dashboard.dart` | `name`, `photoUrl` | `phone`, `motoModel` |
| `boulangerie_dashboard.dart` | `name`, `isOnline` | `phone` |
| `seller_dashboard.dart` | `name`, `lat`, `lng`, `isOnline` | `phone` |

Aucun champ n'a été ajouté à la liste blanche `driver_public` (12 champs inchangés). `motoModel` reste sur `livreurs` avec `phone`, exactement comme documenté en S6.5 (absent de la projection, aucune décision d'extension prise).

## 6. Fichiers modifiés

| Fichier | Nature du changement |
|---|---|
| `lib/screens/customer_tracking_screen.dart` | `_loadDriverInfoById` : 1 appel séparé en 2, 1 ligne déplacée |
| `lib/screens/pharmacie/pharmacie_dashboard.dart` | `_DriverInfoCard.build()` : `StreamBuilder` imbriqué, extraction de `_buildCard()` |
| `lib/screens/boulangerie/boulangerie_dashboard.dart` | Bloc inline livreur : `StreamBuilder` imbriqué |
| `lib/screens/seller/seller_dashboard.dart` | `_DriverSection.build()` : `StreamBuilder` imbriqué, extraction de `_buildCard()` |
| `docs/SEC01_S6_6_PHONE_READERS_MIGRATION.md` | **Nouveau fichier** : ce rapport |

Aucun autre fichier touché. Aucun fichier de test créé (justifié en §7).

## 7. Tests et validation

- **Tests existants pertinents** : recherche (`test/**/pharmacie_dashboard*`, `test/**/boulangerie_dashboard*`, `test/**/seller_dashboard*`, `test/**/customer_tracking_screen*`) — **aucun fichier trouvé** pour les 4 écrans modifiés. Rien à adapter.
- **Pas de nouveau test créé** : les changements sont structurels (déplacement de la source de lecture, imbrication d'un second flux déjà équivalent au pattern S6.4) et n'introduisent aucune nouvelle logique de calcul ou de parsing au-delà de ce qui est déjà couvert par les tests existants (`test/screens/driver/driver_profil_rating_test.dart`, `test/services/driver_public_name_fallback_test.dart` pour les expressions de repli `?? 'Livreur'`/`?? ''`/`as String?`, de forme identique à celles utilisées ici). Créer un nouveau test aurait été redondant, et dupliquer un `StreamBuilder` imbriqué sans simulateur Firestore (absent du dépôt, et son ajout est interdit) ne peut pas être testé dynamiquement de façon plus utile que les tests déjà existants sur les mêmes expressions.
- **Validation statique effectuée** :
  - Lecture intégrale de chaque bloc modifié après édition, pour confirmer l'équilibre des accolades/parenthèses des `StreamBuilder` imbriqués (vérifié précisément pour les 3 fichiers avec imbrication : `boulangerie_dashboard.dart`, `pharmacie_dashboard.dart`, `seller_dashboard.dart`).
  - `grep` confirmant qu'aucune occurrence de `collection('livreurs')`/`collection("livreurs")` ne subsiste à l'intérieur des 4 blocs migrés, sauf dans le flux intérieur dédié à `phone`/`motoModel`.
  - `git diff` ciblé sur chacun des 4 fichiers, confirmant que le changement est strictement isolé des modifications locales préexistantes et sans rapport (ex. ajout de `showMinVersionDialogIfNeeded` dans les trois dashboards partenaires, confirmé intact et non mélangé avec cette migration).
- **`flutter test` / `flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente de cet audit — aucun résultat n'est fabriqué). Non exécuté, honnêtement signalé.
- **Limite de la validation statique** : l'imbrication de `StreamBuilder` dans `pharmacie_dashboard.dart` et `seller_dashboard.dart` a nécessité d'extraire le contenu visuel existant dans une méthode `_buildCard()` — la cohérence exacte des types de paramètres (`dynamic` pour `name`/`isOnline` dans `seller_dashboard.dart`, reproduisant le typage dynamique déjà implicite dans le code original) a été vérifiée par relecture, mais seule une compilation réelle (`flutter analyze`, indisponible) confirmerait l'absence d'erreur de type — signalé comme limite, pas comme un résultat positif fabriqué.

## 8. Réserves

- **Formatage** : l'indentation du bloc `boulangerie_dashboard.dart` (lignes ~730-780) est restée à son niveau d'origine après l'imbrication du second `StreamBuilder`, sans être ré-indentée au niveau attendu par un formateur automatique (`dartfmt`/`flutter format`, indisponible dans cet environnement) — cosmétique uniquement, sans impact sur le comportement.
- **Validation de compilation non effectuée** : comme pour toutes les phases précédentes de cet audit, `flutter analyze`/`flutter test` n'ont pas pu être exécutés. La correction des 4 migrations repose sur une relecture manuelle attentive (équilibre des blocs, types), pas sur une compilation réelle.
- **`phone` reste pleinement lisible sur `livreurs` par tout utilisateur authentifié** : cette migration réduit l'exposition des champs publics (`name`/`photoUrl`/`avgRating`/`lat`/`lng`/`isOnline`) sur ces 4 écrans, mais ne réduit en rien l'exposition de `phone` lui-même (toujours sur `livreurs`, toujours lisible par tout authentifié) — conformément à l'objectif de cette phase (Option D uniquement), la réduction complète de l'exposition de `phone` reste dépendante d'une décision future sur l'Option B/C (S6.5 §7-8), non prise ici.
- **`web_client_dashboard.dart::_callDriver`/`suivi_commande.dart::_callDriver`** : aucune réduction d'exposition pour ces deux lecteurs, puisqu'ils ne lisaient déjà que `phone` — leur dépendance à `livreurs` reste entière, sans changement possible dans le cadre de l'Option D seule.

## 9. Confirmation du respect du périmètre

- `phone`/`driverPhone` **non ajoutés** à `driver_public` (12 champs inchangés, confirmé par absence de modification de `firestore.rules`/`functions/driverPublicSync.js`).
- Option C **non implémentée** (aucune Cloud Function créée ou modifiée).
- `driverPhone` **non ajouté** à `orders` (aucune modification de `order_model.dart`, `orderActions.js`, `driverAcceptance.js`, `dispatch.js`, `driverTransfer.js`).
- `firestore.rules` : **non modifié**.
- Aucune Cloud Function modifiée.
- Aucune configuration Firebase modifiée.
- Aucune dépendance ni lockfile modifié.
- Aucun accès Firebase réel, aucun déploiement, aucun APK/AAB généré.
- Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.
- Aucune opération Git destructive, aucun commit, aucun push, aucun changement de branche.
- `admin_map.dart`, `live_marker_cache.dart`, `driver_profil.dart` : confirmés absents de `git status`/`git diff` pour cette phase — non touchés.
- Les très nombreuses modifications locales préexistantes et sans rapport (confirmées par `git status` en début de phase, notamment l'ajout de `showMinVersionDialogIfNeeded` dans les 3 dashboards partenaires) sont restées intactes — isolées des 4 migrations par relecture `git diff` ciblée (§7).
- Aucune logique de paiement, de commande, d'annulation ou d'attribution de livreur n'a été touchée — seules les lectures d'affichage de la fiche livreur ont été modifiées.

## 10. Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

Les 4 lecteurs réellement hybrides parmi les 6 autorisés ont été migrés selon l'Option D exclusivement, en réutilisant strictement le pattern déjà validé en S6.4 (second flux Firestore indépendant pour le champ privé), sans nouvelle architecture, sans toucher aux Rules/Functions/`driver_public`/`orders`, et sans exposer `phone` dans la projection publique. Les 2 lecteurs ne consommant déjà que `phone` ont été laissés intacts par choix délibéré, pour éviter un refactoring sans effet réel. La réserve porte sur l'absence de validation par compilation réelle (`flutter analyze`/`flutter test` indisponibles, comme à chaque phase de cet audit) et sur le fait que `phone` lui-même reste pleinement exposé sur `livreurs`, cette phase ne visant que la séparation des champs publics, pas la résolution complète de la dépendance à `phone`.

STOP après ce rapport. Aucune phase suivante sans autorisation explicite.
