# SEC-01 — S6.3.1 : audit ciblé — `vehicle` et `live_marker_cache.dart`

Date : 2026-11-21
Type : audit exclusivement en lecture seule (aucune correction, aucune migration, aucun test créé)
Objet : comprendre précisément le blocage constaté en S6.3 pour `live_marker_cache.dart::onlineDriversFeed()`

## 1. Résumé exécutif

L'audit révèle une asymétrie importante entre les deux champs bloquants identifiés en S6.3 :

- **`phone`** (consommateur `admin_live_tracking_page.dart`) est un **blocage réel et actif** : le champ est écrit à l'approbation du livreur (`driver_requests_page.dart::_approve`) et **affiché à l'écran** (ligne 361-362 de l'écran admin). Aucune alternative publique n'existe.
- **`vehicle`** (consommateur `client_map.dart`) est, après recherche exhaustive, un **champ mort sur `livreurs`** : aucun code actuellement exécutable ne l'écrit sur ce document. La seule méthode qui l'écrirait (`DriverService.registerDriver`) a **zéro appelant** dans tout le dépôt — la classe `DriverService` elle-même n'est instanciée nulle part. Le flux d'inscription réel (`driver_requests_page.dart::_approve`) ne pose jamais `vehicle` sur `livreurs`. En conséquence, `client_map.dart:244` (`data['vehicle'] as String? ?? ''`) retombe systématiquement sur la chaîne vide dans l'état actuel du code — **ce blocage n'a, en pratique, aucun effet fonctionnel observable aujourd'hui**, même s'il reste vrai, au sens strict du code source, que le champ est lu et absent de `driver_public`.

Cette asymétrie change la portée du blocage : `phone` reste un obstacle réel et durable (catégorie D, déjà connu) ; `vehicle` est un obstacle **au niveau du code source** (le champ n'existe pas dans la liste blanche) mais **sans impact utilisateur actuel**, puisque la donnée qu'il référence n'est jamais produite par le flux réel. La séparation des deux consommateurs (Option C) reste la voie la plus prometteuse, mais elle doit être tranchée par une décision explicite et n'est pas mise en œuvre ici.

## 2. Documents examinés (contenu réel, pas seulement le résumé)

- `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md` — confirme que le principe de projection publique n'a jamais prévu `vehicle` ni `phone` dans sa liste de champs.
- `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` — §3.3/§4/§13 : avait identifié `live_marker_cache.dart` comme « probablement A » avec champs non confirmés, et listé `driver_service.dart::getDriverStatus` comme incertitude d'appelant non tracé (voir §5 ci-dessous, cette incertitude est maintenant levée).
- `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md` — Point B : confirme l'absence d'accès anonyme à `live_marker_cache.dart`, sans avoir examiné `vehicle`.
- `docs/SEC01_S6_3_MULTI_DRIVER_READERS_MIGRATION.md` — rapport à l'origine de cette mission : avait correctement identifié que `vehicle` est absent de la liste blanche et actif dans le code source de `client_map.dart`, mais n'avait pas vérifié si ce champ est réellement peuplé sur `livreurs` en pratique. C'est la vérification complémentaire apportée par cet audit.
- Rapports S5.3.3 à S5.3.5, S6.0.2, S6.0.3 — consultés pour le contexte de méthode (aucune mention de `vehicle`).

## 3. Audit de `vehicle`

### 3.1 Structure réelle

`vehicle` est un champ **chaîne simple** (`String`), sans sous-champs, utilisé comme type d'engin de livraison (valeurs observées dans l'UI : `'Moto'`, `'Vélo'`, `'Voiture'`, `'Tricycle'`, cf. `lib/web/pages/drivers_page.dart:218`). Aucune structure (map/objet imbriqué) n'a été trouvée — confirmé par lecture de tous les sites qui le manipulent.

### 3.2 Sources d'écriture — recherche exhaustive

Recherche par motif exact de clé (`'vehicle':`/`"vehicle":`) dans `lib/` et `functions/` (pas seulement le mot « vehicle », pour exclure le module sans rapport `auto_moto`/marché de véhicules d'occasion, qui utilise `vehicleType`, `vehicle_listings`, etc. — un espace de noms totalement distinct, confirmé par la lecture de `firestore.rules` lignes 1959-2510, aucun rapport avec le profil livreur) :

| Site | Écrit sur | Statut |
|---|---|---|
| `lib/web/pages/drivers_page.dart:242` (`'vehicle': _vehicle`) | `driver_applications` (formulaire public du site vitrine, `_submit()`, lignes 234-247) | **Actif**, mais pas sur `livreurs` |
| `lib/models/driver_model.dart:20` (`DriverModel.toMap()`) | utilisé uniquement par `DriverService.registerDriver()` (`lib/services/driver_service.dart:7-8`, `db.collection("livreurs").doc(driver.id).set(driver.toMap())`) | **Code mort** — voir §3.2.1 |

Aucune Cloud Function n'écrit jamais `vehicle` (recherche exhaustive dans `functions/`, zéro résultat sur la clé exacte).

### 3.2.1 `DriverService.registerDriver` — confirmation du statut de code mort

- `grep -rn "DriverService"` dans tout le dépôt : **une seule occurrence**, la déclaration de la classe elle-même (`lib/services/driver_service.dart:4`). Aucune instanciation (`DriverService()`), nulle part.
- Le flux d'inscription réel d'un livreur est `driver_requests_page.dart::_approve` (admin approuve une candidature) : il crée le document `livreurs/{uid}` via un `batch.set(...)` **explicite**, listant précisément `name`, `phone`, `email`, `identifiant`, `photoUrl`, `idPhotoUrl`, `selfieUrl`, `wallet`, `isOnline`, `lat`, `lng`, `deliveries`, `avgRating`, `ratingCount`, `createdAt` — **`vehicle` n'y figure pas** (lignes 30-48 du fichier, reproduites intégralement ici par souci de preuve : aucune ligne `"vehicle"` dans ce bloc).
- Conclusion : **aucun chemin de code actuellement exécutable ne pose jamais `vehicle` sur un document `livreurs`.** `DriverModel`/`DriverService` forment une paire de code mort, du même type que `FirestoreService.deductCommission` déjà neutralisé en S6.0.3 — non traitée ici (hors périmètre strict de cet audit, qui est en lecture seule).
- Ceci lève également, par la même recherche, l'incertitude non résolue de S6.0 §13 sur `driver_service.dart::getDriverStatus` : son appelant n'est pas seulement « non tracé », il **n'existe pas** — toute la classe `DriverService` est inutilisée.

### 3.3 Sources de lecture — recherche exhaustive

| Site | Lit depuis | Usage |
|---|---|---|
| `lib/models/driver_model.dart:30` (`DriverModel.fromMap`) | n'importe quelle collection passée en paramètre (générique) | Code mort — aucun appelant de `DriverModel.fromMap` identifié non plus (vérifié par `grep -rn "DriverModel.fromMap"`, résultat unique = la déclaration) |
| `lib/web/pages/admin/web_admin_dashboard.dart:715` (`data['vehicle']`) | **`driver_applications`** (et d'autres types de « demandes » génériques : `type == 'driver'`/`'partner'`/autre, pas spécifiquement `livreurs`) — confirmé par le contexte (`_detailRows`, lignes 706-725, qui affiche aussi `city`/`businessType`/`activity`/`subject`/`message`, des champs typiques d'une candidature, pas d'un profil livreur actif) | Affichage admin d'une candidature en attente, **pas de `livreurs`** |
| `lib/screens/client/client_map.dart:244` (`data['vehicle']`) | `livreurs` (via `onlineDriversFeed()`) | Snippet de l'info-bulle du marqueur livreur — **seul site qui lit réellement `vehicle` depuis `livreurs`**, et qui retombe systématiquement sur `''` (cf. §3.2) |

### 3.4 Origine des valeurs

Quand il est renseigné (sur `driver_applications`, pas sur `livreurs`), `vehicle` provient d'un choix du candidat livreur lui-même, dans un menu déroulant à 4 valeurs fixes (`drivers_page.dart:218`) — ni une saisie libre, ni une donnée administrative. Mais cette valeur n'est **jamais reportée** sur `livreurs` au moment de l'approbation (§3.2.1) : elle est donc perdue après l'approbation, dans l'état actuel du code.

### 3.5 Modifiable par le propriétaire (le livreur) ?

Non observé. Aucun écran livreur (`driver_profil.dart`, `driver_dashboard.dart`, etc.) ne propose de modifier un champ `vehicle` sur son propre document `livreurs` (recherche exhaustive du mot « vehicle » dans tous les écrans livreur : zéro résultat).

### 3.6 Encadrement par les Firestore Rules

Le bloc `match /livreurs/{livreurId}` (`firestore.rules` lignes ~396-500) ne mentionne `vehicle` à aucun endroit — ni autorisé, ni interdit, ni validé par type. Les occurrences de « vehicle » ailleurs dans `firestore.rules` (lignes 1959-2510) appartiennent toutes au module `auto_moto` (marché de véhicules d'occasion : `vehicle_listings`, `vehicle_seller_profiles`, `vehicle_conversations`, etc.) — un espace de données **entièrement distinct**, sans rapport avec le profil livreur. Conclusion : `vehicle` sur `livreurs` n'est régi par aucune règle spécifique ; seule la règle générale `allow update: if isAdmin() || (isOwner(...) && ...)` s'applique, et comme vu en §3.5, aucun chemin client ne l'écrit en pratique.

### 3.7 Donnée privée ou sensible ?

Non. Un type d'engin de livraison (moto/vélo/voiture/tricycle) n'est pas une donnée personnelle sensible au sens des autres champs exclus de `driver_public` (téléphone, solde, identité administrative). Si le champ était un jour réellement peuplé sur `livreurs`, rien dans sa nature n'empêcherait de l'ajouter à la liste blanche — **mais cette décision n'est pas prise ici** (l'extension de la liste blanche est explicitement hors périmètre de cette mission, et de toute façon pas nécessaire tant que le champ n'est jamais écrit sur `livreurs`).

### 3.8 Nécessaire à `client_map.dart` / à l'info-bulle ?

Fonctionnellement non-impactant aujourd'hui : puisque la valeur est toujours absente (§3.2), le repli `''` (chaîne vide) produit déjà, dans la pratique actuelle, exactement le même rendu visuel qu'une migration qui omettrait purement et simplement ce champ. Le snippet de l'info-bulle (`InfoWindow.snippet`) affiche une ligne vide sous le nom du livreur, que la lecture de `vehicle` échoue (migration) ou retombe sur son repli (code actuel) — **aucune différence visible pour l'utilisateur dans l'état actuel du code**.

### 3.9 Donnée équivalente ailleurs ?

Non trouvée dans `driver_public` ni dans `livreurs`. Si l'information « type d'engin » devait un jour être affichée de façon fiable, elle nécessiterait soit (a) de corriger le flux d'approbation pour reporter la valeur de `driver_applications.vehicle` vers `livreurs.vehicle` au moment de la création (un correctif fonctionnel distinct, hors périmètre de cet audit en lecture seule), soit (b) de l'ajouter à la liste blanche `driver_public` une fois peuplé de façon fiable. Aucune des deux n'est tranchée ni mise en œuvre ici.

## 4. Audit de `live_marker_cache.dart`

### 4.1 `onlineDriversFeed()` (lignes 99-105)

```dart
Stream<LiveDriverSnapshot> onlineDriversFeed() {
  return FirebaseFirestore.instance
      .collection('livreurs')
      .where('isOnline', isEqualTo: true)
      .snapshots()
      .map(liveDriverSnapshotFromQuery);
}
```

- **Source Firestore** : requête continue (`snapshots()`), filtre unique `isOnline == true`, aucune limite (`limit`) — contrairement à `destination_picker.dart` (migré en S6.3) qui limitait à 20.
- **Mapping** (`liveDriverSnapshotFromQuery`, lignes 80-95) : transforme chaque document en `LiveDriverDoc(id, data())` — **le document complet est transmis tel quel**, aucun filtrage de champ à ce niveau. C'est une couche d'adaptation de *type* (pour permettre l'injection d'un faux flux en test), pas de *contenu*.
- **Cache** : aucun cache au sens strict dans ce fichier. `applyLiveMarkerChanges` (lignes 13-26) est une fonction pure de fusion incrémentale (`added`/`modified`/`removed`) sur une `Map<String, Marker>` fournie par l'appelant — c'est l'appelant qui détient l'état (`_driverMarkers` dans `client_map.dart` et `admin_live_tracking_page.dart`), pas `live_marker_cache.dart` lui-même.
- **Effets secondaires** : aucun. Fonction pure de lecture, aucune écriture.

### 4.2 Les deux appelants et leurs besoins respectifs (confirmés par `grep -rn "onlineDriversFeed"`, exactement 2 résultats hors déclaration)

| Appelant | Champs consommés | Besoin réel |
|---|---|---|
| `client_map.dart::_onDriversSnapshot` (lignes 218-251) | `lat`, `lng`, `name`, `vehicle` | 3/4 publics ; `vehicle` techniquement absent de la liste blanche mais **jamais peuplé en pratique** (§3) |
| `admin_live_tracking_page.dart::_onDriversUpdate` (lignes 73-100) | `lat`, `lng`, `heading`, `speed`, `updatedAt`, `name`, `phone` | 6/7 publics ; `phone` **réellement peuplé et affiché** à l'écran (lignes 361-362), blocage réel |

### 4.3 Séparation minimale sans nouvelle architecture — analyse, sans réalisation

La fonction `onlineDriversFeed()` est une fonction de niveau module de 7 lignes, sans état partagé, sans classe, sans dépendance croisée avec le reste du fichier au-delà des types `LiveDriverSnapshot`/`LiveDriverDoc` (déjà génériques et indépendants de la collection source). Dupliquer cette fonction en deux variantes — l'une pointant vers `driver_public` (pour `client_map.dart`), l'autre inchangée sur `livreurs` (pour `admin_live_tracking_page.dart`) — ne nécessiterait :

- aucune nouvelle classe, aucun nouveau service, aucun nouvel état partagé ;
- aucun changement des types `LiveDriverSnapshot`/`LiveDriverDoc`/`LiveMarkerChange` (déjà agnostiques de la collection) ;
- aucun changement de `applyLiveMarkerChanges` (fonction pure, déjà indépendante de la source) ;
- un changement d'un seul paramètre (`widget.driversFeed ?? onlineDriversFeed`) dans chacun des deux appelants, pour pointer vers sa propre fonction.

**Verdict de cette analyse** : il s'agit d'une **duplication locale d'une fonction déjà conçue pour être substituée** (le type `LiveDriverFeed = Stream<LiveDriverSnapshot> Function()` existe déjà précisément dans ce but, à l'origine pour les tests). Ce n'est pas, à proprement parler, une « nouvelle architecture » au sens d'une nouvelle couche, d'un nouveau mécanisme de cache ou d'un nouveau concept — c'est l'application du mécanisme d'injection déjà présent dans le fichier, à un deuxième cas d'usage (la source de données) plutôt qu'au seul cas d'usage actuel (les tests). Cette qualification reste cependant un jugement d'architecture, pas un fait vérifiable mécaniquement ; une personne plus conservatrice pourrait légitimement considérer qu'introduire une deuxième fonction de flux constitue déjà un changement structurel suffisant pour mériter une décision explicite plutôt qu'une migration silencieuse — ce qui est précisément la position prise lors de S6.3, par prudence, en l'absence à ce moment d'une analyse aussi détaillée que celle-ci.

## 5. Évaluation des 4 options (sans implémentation)

### Option A — Maintenir le lecteur partagé sur `livreurs`

- **Risques** : aucun nouveau — c'est l'état actuel, déjà en production. Les deux consommateurs continuent de lire une collection avec des champs privés (`phone`, `wallet`, etc.) non filtrés au niveau de la requête, bien qu'aucun des deux ne les affiche au-delà de ce qui est listé en §4.2.
- **Limites** : aucune réduction de la surface d'exposition de `livreurs` pour ces deux écrans ; la fermeture future des Rules `livreurs` (checklist S6.0 §12) resterait bloquée par ces deux lecteurs tant qu'ils n'ont pas de chemin alternatif.
- **Conséquences pour SEC-01** : neutre à court terme (pas de régression), mais empêche la clôture complète de l'objectif SEC-01 (fermeture de `livreurs` aux lecteurs non essentiels) pour ces deux écrans précis.

### Option B — Migrer seulement le client (`client_map.dart`)

- **Compatibilité avec `driver_public`** : 3 champs sur 4 (`lat`, `lng`, `name`) sont déjà couverts. Le 4ᵉ (`vehicle`) n'est, d'après §3, **jamais peuplé en pratique** sur `livreurs` — migrer `client_map.dart` seul vers `driver_public` ne changerait donc rien d'observable pour l'utilisateur final (le snippet reste vide avant et après).
- **Dépendance au champ `vehicle`** : techniquement réelle au niveau du code source (la ligne existe et référence une clé absente de la liste blanche), mais **sans conséquence fonctionnelle actuelle**, car la donnée n'existe jamais à cet endroit.
- **Faisabilité** : **élevée**, à condition de séparer ce lecteur de celui de `admin_live_tracking_page.dart` (cf. Option C) — faire pointer uniquement `client_map.dart` vers `driver_public` sans toucher `admin_live_tracking_page.dart` impose nécessairement une forme de séparation, même minimale (ne serait-ce qu'un second appel à `onlineDriversFeed` avec un paramètre, ou une seconde fonction). Migrer la fonction partagée telle quelle casserait `phone` côté admin (blocage réel, §4.2).

### Option C — Séparer les besoins des deux appelants

- **Modification minimale envisageable** : décrite en détail en §4.3 — une duplication de la fonction de 7 lignes, avec un changement d'une ligne dans chacun des deux appelants (pointer vers la bonne fonction).
- **Risques de régression** : faibles, à condition de vérifier (lors d'une éventuelle mise en œuvre future, non faite ici) que les deux flux restent fonctionnellement équivalents à l'identique pour chaque appelant (mêmes champs, même filtre `isOnline`, même absence de `limit`).
- **Coût de migration** : faible — pas de nouvelle dépendance, pas de nouveau fichier nécessairement (les deux fonctions peuvent coexister dans le même fichier `live_marker_cache.dart`), pas de changement des types existants.
- **Utiliser `driver_public` pour le client et conserver une lecture privée pour l'admin** : **oui, c'est exactement le mécanisme envisagé** — l'admin garde son accès légitime à `livreurs` (déjà justifié par `isAdmin()` dans les Rules, cohérent avec la position déjà prise en S6.0 §6 pour toute la console admin), le client bascule vers la projection publique.
- **Séparation locale ou nouvelle architecture ?** : analysé en détail en §4.3 — argument favorable à une « séparation locale », mais la question reste en partie un jugement, pas un fait purement mécanique. **Recommandation de cet audit** : une décision explicite du porteur du projet reste appropriée avant toute mise en œuvre, mais les éléments rassemblés ici indiquent que le risque et le coût réels d'une telle séparation sont faibles.

### Option D — Exclure `vehicle` de l'affichage

- **Impact fonctionnel** : **nul**, d'après §3 — le champ n'affiche déjà jamais rien (toujours vide) dans l'état actuel du code, puisqu'il n'est jamais peuplé sur `livreurs`.
- **Conséquences sur l'expérience client** : aucune, pour la même raison.
- **Faisabilité** : triviale sur le principe (retirer une ligne de code), mais cette option seule **ne suffit pas** à débloquer la migration de `client_map.dart`, car le véritable blocage partagé avec l'admin reste `phone` (Option C reste nécessaire pour migrer quoi que ce soit, indépendamment du sort de `vehicle`).

## 6. Impact sur S6.4

- **`vehicle` ne bloque aucun lecteur hybride prévu en S6.4** : les lecteurs hybrides identifiés par le plan S6.0 pour S6.4 (`driver_profil.dart`, `driver_dashboard.dart::_listenDriverDoc`, `admin_map.dart`, `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`, `customer_tracking_screen.dart`) ne lisent `vehicle` nulle part (vérifié par recherche exhaustive du mot dans chacun de ces fichiers lors de cet audit et des audits précédents — zéro occurrence).
- **Lecteurs réellement concernés par `vehicle`/`live_marker_cache.dart`** : uniquement `client_map.dart` et `admin_live_tracking_page.dart`, aucun autre.
- **S6.4 peut être exécuté indépendamment** : oui — aucune dépendance croisée identifiée entre la question `live_marker_cache.dart` et les lecteurs hybrides prévus pour S6.4. Les deux chantiers sont strictement indépendants.
- **Dépendances croisées** : aucune au-delà de celles déjà connues (le mécanisme `driverPhone` serveur, catégorie D/S6.5, reste la seule dépendance structurante partagée par plusieurs phases — `phone` sur `admin_live_tracking_page.dart` n'en fait cependant pas partie, puisque l'admin garde de toute façon un accès légitime à `livreurs`, indépendamment de ce mécanisme).

## 7. Recommandation argumentée

Sur la base des preuves ci-dessus, la recommandation de cet audit — **non mise en œuvre ici** — est la suivante, par ordre de préférence :

1. **Option C, dans une phase dédiée et explicitement autorisée** : dupliquer `onlineDriversFeed()` en une fonction orientée `driver_public` pour `client_map.dart` (champs `lat`/`lng`/`name`, en retirant `vehicle` puisqu'il n'a jamais d'effet observable) et conserver la fonction actuelle, inchangée, sur `livreurs` pour `admin_live_tracking_page.dart` (qui a un besoin réel et légitime de `phone`). C'est l'option qui réduit effectivement la surface d'exposition de `livreurs` pour le consommateur client, sans aucune perte fonctionnelle, à un coût et un risque faibles d'après l'analyse de §4.3.
2. **Si l'option C n'est pas retenue à ce stade** : l'option A (statu quo) reste préférable à toute solution improvisée — ne jamais migrer la fonction partagée telle quelle, ce qui casserait `phone` côté admin.
3. **Indépendamment de la décision sur `live_marker_cache.dart`** : il serait pertinent, dans une phase séparée et dédiée (hors SEC-01 à proprement parler, plutôt une correction fonctionnelle), de clarifier si `driver_applications.vehicle` doit un jour être reporté sur `livreurs` à l'approbation — mais cela n'est ni urgent ni bloquant pour SEC-01, puisque son absence actuelle n'a aucune conséquence de sécurité (ce n'est pas une donnée privée) ni fonctionnelle observable.

Cette recommandation n'autorise aucune mise en œuvre ; elle attend une décision explicite du porteur du projet.

## 8. Fichiers consultés

- `lib/widgets/live_marker_cache.dart` (lecture intégrale)
- `lib/screens/client/client_map.dart` (lignes 1-260)
- `lib/screens/admin/admin_live_tracking_page.dart` (lignes 1-100, 290-365)
- `lib/models/driver_model.dart` (lecture intégrale)
- `lib/services/driver_service.dart` (lecture intégrale)
- `lib/web/pages/drivers_page.dart` (lignes 205-345)
- `lib/web/pages/admin/web_admin_dashboard.dart` (lignes 680-725)
- `lib/screens/driver/driver_register.dart` (lignes 1-135)
- `lib/screens/admin/driver_requests_page.dart` (lecture intégrale)
- `firestore.rules` (bloc `livreurs` lignes 396-500 ; occurrences « vehicle » lignes 88, 148-150, 1959-2510)
- `firestore.indexes.json` (consulté en S6.3, non re-consulté ici — hors périmètre de cet audit)
- `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`, `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md`, `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md`, `docs/SEC01_S6_3_MULTI_DRIVER_READERS_MIGRATION.md`
- Recherches exhaustives (`grep -rn`) : `DriverService`, `DriverModel.fromMap`, `registerDriver`, `'vehicle':`/`"vehicle":`, `onlineDriversFeed`, `.phone\b` dans `admin_live_tracking_page.dart`

## 9. Confirmation qu'aucun code n'a été modifié

Confirmé : aucun fichier de code, de test, de Rules, de configuration, de dépendance ou de lockfile n'a été modifié, créé ou supprimé dans cette phase. Seul le présent rapport Markdown a été créé, dans `docs/`.

## 10. Confirmation Firebase / déploiement

Aucune connexion à un Firebase réel. Aucun déploiement. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.

## 11. Confirmation que S6.4 n'a pas commencé

Confirmé : aucun lecteur hybride prévu pour S6.4 n'a été touché ni même modifié par cet audit — seule une analyse (§6) a établi leur indépendance par rapport au sujet de cette mission.

## 12. Verdict

**AUDIT VALIDÉ**

L'audit répond intégralement aux questions posées, avec des preuves directes (lignes exactes, recherche exhaustive des écritures, confirmation du statut de code mort de `DriverService`/`DriverModel`, lecture complète des deux appelants de `live_marker_cache.dart`). Le blocage `phone` est confirmé réel ; le blocage `vehicle` est requalifié — toujours présent au niveau du code source, mais sans effet fonctionnel actuel, une nuance absente du rapport S6.3 d'origine et apportée ici. Les 4 options sont analysées avec leurs preuves à l'appui, sans qu'aucune ne soit choisie ni mise en œuvre, conformément au périmètre strictement read-only de cette mission.

STOP après ce rapport. En attente d'autorisation avant toute mise en œuvre ou avant S6.4.
