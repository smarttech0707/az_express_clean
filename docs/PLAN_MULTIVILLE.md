# SECTION 1 — MODÈLE DE DONNÉES

## Principes de compatibilité

Le schéma cible reste dans les deux collections existantes `zones_livraison` et `places`. `zones_livraison` est déjà lisible par tout utilisateur authentifié et modifiable uniquement par un administrateur (`firestore.rules:586-590`). `places` est déjà lisible par tout utilisateur authentifié ; sa création par un utilisateur exige aujourd'hui seulement `name`, `latitude` et `longitude`, tandis que les mises à jour non admin sont limitées à `searchCount` et `updatedAt` (`firestore.rules:899-909`). Les règles devront donc être adaptées avant que les nouveaux champs obligatoires puissent être garantis ; cette adaptation appartient à un lot d'implémentation, pas au présent document.

Le modèle actuel de `LocalPlace` contient `name`, `category`, `district`, `address`, coordonnées, `keywords`, `searchCount`, `verified` et `source` (`lib/models/local_place.dart:6-31`). Sa sérialisation écrit `nameSearch`, `keywords` et `verified`, mais pas `cityId`, `normalizedName` ni `aliases` (`lib/models/local_place.dart:151-164`). L'auto-apprentissage crée actuellement un document avec `verified: false` et conserve la source externe (`lib/services/places_search_service.dart:315-358`). Cette valeur ne devra jamais être élevée automatiquement.

## Champs cibles de `zones_livraison`

| Champ | Type | Valeur par défaut à la création | Obligatoire cible | Besoin réel | Effet si absent sur un document existant |
|---|---|---:|---|---|---|
| `name` | `string` non vide | aucune | oui | Libellé administrable déjà utilisé par le seed et la liste (`lib/screens/admin/admin_zones_page.dart:187-199`, `lib/screens/client/create_order.dart:1597-1605`). | Le lecteur actuel force un cast en `String` ; le chargement de la liste peut échouer (`lib/screens/client/create_order.dart:1597-1604`). |
| `type` | enum `ville`, `quartier`, `village`, `secteur` | aucune ; choix admin explicite | oui | La collection et l'écran admin gèrent déjà ces quatre types (`lib/screens/admin/admin_zones_page.dart:17-18`, `lib/screens/admin/admin_zones_page.dart:261-273`). | Le lecteur actuel remplace l'absence par `''`, donc filtrage et hiérarchie deviennent indéterminés (`lib/screens/client/create_order.dart:1600-1604`). |
| `cityId` | `string` slug stable normalisé | pour la migration seulement : `abengourou` après preuve de rattachement ; sinon aucune | oui | Filtrer zones et lieux sans comparer `parentName` en texte et ajouter une ville sans modifier le code. | Le document reste lisible en transition, mais il est exclu des requêtes multi-ville ; aucun dispatch ou calcul de desserte ne doit déduire silencieusement une ville inconnue. Le schéma actuel ne contient que `parentName` textuel (`lib/screens/admin/admin_zones_page.dart:191-199`). |
| `parentZoneId` | `string` ID de document ou `null` | `null` pour une ville | oui pour `quartier`, `village`, `secteur`; nul pour `ville` | Remplacer le lien fragile par nom tout en conservant `parentName` pendant la compatibilité. | La zone peut encore être affichée via `parentName`, mais sa hiérarchie ne peut pas être jointe de façon sûre si une ville est renommée ; le formulaire actuel saisit le parent en texte libre (`lib/screens/admin/admin_zones_page.dart:277-283`). |
| `normalizedName` | `string` sans accents, en minuscules, espaces normalisés | dérivé de `name` | oui | Recherche déterministe et indépendante des accents/casses. Une normalisation existe déjà pour les lieux (`lib/models/local_place.dart:37-49`). | Le document ne ressort pas de la recherche préfixe cible ; le code de transition peut calculer la valeur en mémoire, mais cela empêche une requête Firestore indexée.
| `aliases` | `list<string>` normalisés et uniques | `[]` | oui, liste vide admise | Rechercher les variantes locales et usuelles sans appel externe. | La recherche par nom reste possible ; les variantes ne sont pas trouvées localement et peuvent provoquer un étage externe.
| `lat` | `number` ou `null` pendant migration | `null` tant qu'un admin n'a pas capturé/validé le point | oui pour une zone rendue desservable | Point central imposé par D3. Le formulaire sait déjà capturer une position GPS (`lib/screens/admin/admin_zones_page.dart:286-343`). | La zone peut rester administrative, mais ne peut ni détecter une ville ni participer à un calcul de distance.
| `lng` | `number` ou `null` pendant migration | même règle que `lat` | oui pour une zone rendue desservable | Paire indissociable de `lat`. | Même conséquence que `lat`; une paire partielle est invalide.
| `radiusKm` | `number > 0` ou `null` pendant migration | aucune valeur métier implicite ; saisie/validation admin | oui pour une zone rendue desservable | D3 exige un point plus un rayon ; sert à la détection GPS et aux frontières. | La zone est « géométrie incomplète » : affichable, mais non utilisable pour conclure qu'une position est couverte. Mettre `0` par défaut la rendrait faussement inutilisable et inventer un rayon risquerait de desservir une zone non validée.
| `coordinateSource` | enum `own`, `inherited`, `unknown` | `unknown` | oui | Distinguer une mesure propre d'une valeur de compatibilité héritée ; le code actuel écrase cette distinction en mémoire (`lib/screens/client/create_order.dart:1614-1628`). | Toute coordonnée héritée ou d'origine inconnue doit être traitée comme impropre aux distances ; sinon des quartiers différents paraissent coïncider.
| `isServiceable` | `bool` | `false` jusqu'à validation admin | oui | Séparer l'existence/visibilité d'une zone de son ouverture au service. `isActive` existe déjà et est le seul filtre du sélecteur actuel (`lib/screens/client/create_order.dart:1588-1594`). | En transition, le document ne doit pas être supposé desservable. Il peut rester visible en administration ; le flux client doit appliquer un comportement legacy explicitement borné seulement pendant la migration.
| `isActive` | `bool` | `true` à la création admin | oui | Champ existant de publication/archivage, écrit par le seed et lu par le sélecteur (`lib/screens/admin/admin_zones_page.dart:191-199`, `lib/screens/client/create_order.dart:1590-1594`). | Le document est absent de la requête actuelle `isActive == true`.
| `order` | `number` | prochaine position administrée | oui | Tri existant de l'interface (`lib/screens/client/create_order.dart:1590-1594`). | Le tri courant peut échouer ou placer le document de façon non maîtrisée.

`parentName` est conservé temporairement comme champ legacy lisible, car tous les enfants du seed l'utilisent (`lib/screens/admin/admin_zones_page.dart:47-155`) et le lecteur actuel s'en sert pour retrouver le parent (`lib/screens/client/create_order.dart:1604-1623`). Il ne doit plus être l'identifiant canonique après migration.

Deux options existent pour `isServiceable` sur les documents historiques. Option A : reprendre automatiquement `isActive`; coût faible, mais une zone sans géométrie pourrait être déclarée desservable. Option B : initialiser à `false`, puis faire valider point et rayon par un admin ; coût opérationnel supérieur, mais aucune couverture n'est inventée. Recommandation : option B, avec validation métier avant activation.

## Champs cibles de `places` (AZ Places)

| Champ | Type | Valeur par défaut à la création | Obligatoire cible | Besoin réel | Effet si absent sur un document existant |
|---|---|---:|---|---|---|
| `name` | `string` non vide | aucune | oui | Libellé existant, déjà requis par les règles de création (`firestore.rules:902-905`). | Le lieu est inutilisable et ne doit pas être retourné.
| `cityId` | `string` slug stable | ville active/détectée explicitement au moment de la proposition ; jamais une constante | oui | Cloisonner la recherche locale par ville et éviter qu'un « Gabriel » d'Abengourou masque celui d'Agnibilékrou. | Le lieu est exclu de la recherche multi-ville jusqu'à rattachement ; l'affecter automatiquement à Abengourou sans preuve est interdit.
| `normalizedName` | `string` normalisé | dérivé de `name` | oui | Clé canonique de recherche préfixe. Le champ actuel équivalent est `nameSearch`, écrit par le modèle et l'auto-apprentissage (`lib/models/local_place.dart:151-160`, `lib/services/places_search_service.dart:337-352`). | Le lieu ne ressort pas de la requête préfixe cible. En transition, `nameSearch` peut servir de repli, mais deux requêtes augmentent les lectures.
| `aliases` | `list<string>` normalisés et uniques | `[normalizedName]` ou `[]` si validation différée | oui, liste vide admise | Variantes exactes administrées : « Gabriel », « Pharmacie Gabriel », sigles et orthographes locales. | Le nom canonique reste trouvable ; les formulations alternatives passent éventuellement aux étages externes.
| `category` | `string` | `other` | oui | Classement déjà porté par `LocalPlace` et dérivé des résultats OSM (`lib/models/local_place.dart:8-18`, `lib/services/places_search_service.dart:192-208`). | Le modèle actuel remplace implicitement par `other` (`lib/models/local_place.dart:135-147`) ; seule la pertinence de classement baisse.
| `address` | `string` | `''` | non | Désambiguïsation d'un nom et affichage existant (`lib/models/local_place.dart:8-18`). | Le lieu reste sélectionnable si ses coordonnées sont valides, mais l'utilisateur dispose de moins de contexte.
| `latitude`, `longitude` | `number` | aucune | oui | Les règles les exigent déjà à la création utilisateur (`firestore.rules:902-905`) et l'auto-apprentissage refuse un lieu sans coordonnées (`lib/services/places_search_service.dart:317-318`). | Le lieu ne doit pas être servi comme destination résolue.
| `isVerified` | `bool` | `false` | oui | Appliquer D6 avec un nom explicite. | Une absence vaut `false`, jamais `true`; le lieu peut être proposé comme résultat communautaire distinct, mais pas comme résultat local validé bloquant les appels externes.
| `verified` | `bool` legacy | valeur existante conservée pendant transition | non à terme | Le modèle et le tri actuels lisent ce nom (`lib/models/local_place.dart:15-18`, `lib/services/places_search_service.dart:99-104`). | Le modèle actuel prend `false` (`lib/models/local_place.dart:135-147`). Pendant migration, la lecture cible doit interpréter `isVerified == true` seulement si un admin l'a écrit, ou reprendre un ancien `verified == true` après audit administratif.
| `source` | enum `admin`, `user`, `nominatim`, `google`, `legacy` | origine réelle | oui | Audit, modération et conformité ; l'auto-apprentissage conserve déjà `place.source` (`lib/services/places_search_service.dart:337-358`). | Origine « inconnue » ; aucune élévation de vérification et aucune décision de conservation externe ne peut être prise automatiquement.
| `keywords` | `list<string>` legacy | tokens normalisés | non à terme | Requête secondaire actuelle (`lib/services/places_search_service.dart:86-97`). | Tant que l'ancien moteur vit, les recherches par token perdent ce lieu ; après bascule, `aliases` prend le rôle des variantes explicites.
| `searchCount` | `number >= 0` | `0` ou `1` lors d'une première sélection externe | non | Classement local existant et incrément à la sélection (`lib/services/places_search_service.dart:99-104`, `lib/services/places_search_service.dart:304-312`). | Valeur actuelle par défaut `0`; aucune rupture fonctionnelle (`lib/models/local_place.dart:135-147`).

Pour la transition `verified` → `isVerified`, option A conserve définitivement `verified` et applique D6 à ce champ : aucune migration de nom, coût minimal. Option B adopte `isVerified`, fait une migration contrôlée et lit temporairement les deux champs : vocabulaire plus clair, mais index, règles et lecteurs doublés pendant la transition. Recommandation : option B si l'équipe accepte un lot de migration dédié ; sinon option A est fonctionnellement équivalente et moins risquée. Dans les deux options, seul un acte admin peut produire la valeur vraie.

# SECTION 2 — MIGRATION D'ABENGOUROU

## Choix du mécanisme

Le seed crée des identifiants Firestore automatiques (`lib/screens/admin/admin_zones_page.dart:187-200`) et rattache les enfants par la chaîne `parentName: Abengourou` (`lib/screens/admin/admin_zones_page.dart:47-155`). Une Cloud Function n'apporte aucun avantage à une opération ponctuelle et augmenterait la surface déployée. Recommandation : un script d'administration local, versionné et exécuté avec des droits contrôlés, avec modes `dry-run`, `apply` et `rollback`. Alternative : une Cloud Function admin temporaire ; elle est rejouable, mais exige déploiement, authentification, journalisation et suppression ultérieure. Le présent run n'écrit ni l'un ni l'autre.

## Procédure non destructive

1. **Prélecture et preuve.** Lire tous les documents `zones_livraison` une fois. Identifier la ville candidate par `type == ville` et nom normalisé `abengourou`, puis vérifier qu'elle est unique. Le seed attendu contient exactement une ville Abengourou avec un point (`lib/screens/admin/admin_zones_page.dart:37-46`), mais le contenu Firestore de production est **non trouvé** dans le dépôt : le script doit donc refuser d'écrire si zéro ou plusieurs villes correspondent.
2. **Rapport de dry-run.** Produire hors Firestore un fichier JSON daté contenant pour chaque document son ID, ses valeurs avant migration et les valeurs proposées. Le script classe : ville Abengourou, enfant dont `parentName` normalisé vaut `abengourou`, autre document, conflit de champ déjà présent. Aucun « autre document » n'est rattaché automatiquement.
3. **Identifiant stable.** Affecter `cityId: abengourou` à la ville et aux seuls enfants prouvés ci-dessus. Affecter `parentZoneId` aux enfants avec l'ID réel du document ville ; conserver `parentName` inchangé. Ajouter `normalizedName`, `aliases` vide, `coordinateSource`, et laisser `radiusKm` sans valeur métier tant qu'un admin ne l'a pas validé.
4. **Coordonnées.** Pour la ville seedée, proposer `coordinateSource: own` car son propre objet seed porte `lat` et `lng` (`lib/screens/admin/admin_zones_page.dart:39-45`). Pour les enfants sans point propre, écrire `coordinateSource: unknown`, pas `own` et pas des coordonnées copiées. Le seed écrit effectivement `lat: null` et `lng: null` pour les entrées qui n'en fournissent pas (`lib/screens/admin/admin_zones_page.dart:187-200`). Pour les données de production ayant des coordonnées, l'origine est **non trouvée** : elles restent `unknown` jusqu'à validation admin.
5. **Desserte.** Initialiser `isServiceable: false` pour toute géométrie non validée. La ville peut passer à `true` seulement après validation de son rayon ; aucun montant tarifaire n'est lu ou modifié.
6. **Écriture conditionnelle.** Utiliser des lots bornés et `set(..., merge: true)` ou des updates ciblés. Ne jamais remplacer un document entier. Refuser un document qui a déjà un `cityId` différent. Enregistrer dans le rapport local la précondition de version/horodatage utilisée.
7. **Contrôle après écriture.** Relire les documents touchés et comparer champ par champ au plan. Vérifier séparément les documents non touchés.

## Idempotence, rejeu et réversibilité

L'idempotence repose sur des valeurs déterministes et des préconditions : un document déjà égal à la cible est ignoré ; un document dont un champ cible diffère est signalé comme conflit et n'est pas écrasé. Rejouer le script après interruption ne fait donc qu'achever les documents manquants. Le seed actuel évite déjà les doublons par nom, mais sa lecture de toute la collection et sa comparaison seulement en minuscules ne suffit pas comme protocole de migration (`lib/screens/admin/admin_zones_page.dart:180-203`).

Le rollback consomme le JSON « avant » et ne retire/restaure un champ que si sa valeur courante est encore exactement celle écrite par cette exécution. Une modification admin postérieure est ainsi conservée et signalée. Le rollback retire uniquement les champs ajoutés par la migration ou restaure leur ancienne valeur ; il ne supprime aucun document et ne touche ni `name`, ni `parentName`, ni coordonnées, ni tarifs.

Option A stocke le journal uniquement dans un fichier local sécurisé : zéro collection, coût nul en lectures futures, mais conservation opérationnelle à organiser. Option B ajoute des métadonnées de migration dans chaque document : rollback plus autonome, mais pollution durable du modèle. Recommandation : option A, avec deux copies contrôlées du rapport et son hash ; validation finale à la charge du propriétaire.

# SECTION 3 — PROBLÈME DES COORDONNÉES HÉRITÉES

## Verdict

Le problème est **réel dans le seed**, et **non vérifiable sur les documents Firestore actuellement déployés**. Le seed contient une ville avec `lat: 6.7273` et `lng: -3.4961` (`lib/screens/admin/admin_zones_page.dart:37-46`). Les huit quartiers et dix villages qui suivent ne déclarent aucune coordonnée (`lib/screens/admin/admin_zones_page.dart:47-155`). Lors de l'écriture, le seed écrit tout de même les clés `lat` et `lng` depuis ces valeurs absentes, donc `null` pour ces enfants (`lib/screens/admin/admin_zones_page.dart:187-200`).

Le sélecteur charge toutes les zones actives, puis, pour chaque enfant sans coordonnées, cherche son parent par nom et copie le point du parent dans la structure en mémoire (`lib/screens/client/create_order.dart:1588-1605`, `lib/screens/client/create_order.dart:1614-1628`). Les 18 enfants seedés peuvent donc être présentés à la commande au point exact d'Abengourou. Ce n'est pas une simple hypothèse de modèle : c'est le chemin déterministe du seed et du lecteur. En revanche, savoir si un admin a depuis capturé des points propres dans Firestore est **non trouvé** ; le formulaire permet cette capture pour toute zone (`lib/screens/admin/admin_zones_page.dart:286-343`).

## Distinction proposée

`coordinateSource` porte l'origine métier :

- `own` : point capturé ou saisi pour cette zone et validé par un admin ; utilisable pour distance si `radiusKm` est également valide ;
- `inherited` : point copié temporairement d'un parent uniquement pour compatibilité d'affichage ; jamais utilisable pour distance ;
- `unknown` : point absent ou origine non prouvée ; jamais utilisable pour distance.

Option A conserve physiquement des coordonnées héritées accompagnées de `coordinateSource: inherited` : compatibilité d'affichage facile, mais risque qu'un ancien lecteur ignore le marqueur et les utilise. Option B ne stocke jamais la copie et calcule seulement un centre d'affichage explicitement étiqueté : moins de risque de contamination, mais adaptations UI nécessaires. Recommandation : option B. Le champ `coordinateSource` reste utile pour les données historiques et les contrôles admin.

## Règle bloquante pour la distance et le dispatch

Une zone ne fournit une géométrie de distance que si `coordinateSource == own`, si `lat/lng` sont valides, si `radiusKm > 0` et si `isServiceable == true`. Toute autre zone sert uniquement de libellé/hiérarchie. Le point effectif d'une commande doit être la coordonnée réellement choisie sur la carte, obtenue du GPS ou du lieu résolu ; le modèle de commande enregistre déjà des coordonnées de collecte et de livraison (`lib/models/order_model.dart:36-49`, `lib/models/order_model.dart:200-215`).

Si le client choisit un quartier sans point propre et sans destination résolue, le flux doit demander un pin GPS/carte avant de calculer la distance ou de dispatcher. Il ne doit ni reprendre le centre de la ville, ni estimer silencieusement. La fonction de dispatch actuelle utilise les coordonnées de commande, filtre par distance puis trie les livreurs par distance (`functions/index.js:2112-2120`, `functions/dispatch.js:69-86`) ; lui fournir le point hérité ferait donc réellement classer les livreurs autour d'un faux centre.

# SECTION 4 — RECHERCHE LOCAL FIRST

## Pile à conserver et pile à retirer

Recommandation : conserver `PlacesSearchService` comme façade unique de recherche/résolution pour la livraison, car elle retourne le modèle `LocalPlace`, interroge déjà `places`, classe les lieux vérifiés, incrémente leur popularité et auto-apprend les sélections externes (`lib/services/places_search_service.dart:35-60`, `lib/services/places_search_service.dart:67-106`, `lib/services/places_search_service.dart:304-358`). Retirer de `PlacesService` la partie autocomplete/recherche après migration ; conserver provisoirement son reverse geocoding hors de cette façade, car le reverse n'est pas une pile de recherche de destination.

Alternative : conserver `PlacesService`, qui a déjà deux écrans appelants et un cache autocomplete (`lib/widgets/destination_picker.dart:116-143`, `lib/screens/customer_tracking_screen.dart:338-354`, `lib/services/places_service.dart:52-61`). Son coût de migration d'appelants est plus faible, mais il faudrait lui greffer le modèle `LocalPlace`, la vérification, les compteurs et l'auto-apprentissage déjà présents dans l'autre service. Cette duplication de travail rend l'option moins recommandée.

Appelants exacts à migrer vers la façade conservée :

- `DestinationPicker` : `PlacesService.autocomplete` et `PlacesService.getCoordinates` (`lib/widgets/destination_picker.dart:116-143`) ;
- `CustomerTrackingScreen` : mêmes deux appels (`lib/screens/customer_tracking_screen.dart:338-354`). Cet écran est dans le flux de livraison/suivi, donc reste dans D7 ;
- `LivraisonScreen` utilise déjà `PlacesSearchService.search`, `resolve`, `incrementSearchCount` et `autoLearn` (`lib/screens/client/livraison_screen.dart:254-278`, `lib/screens/client/livraison_screen.dart:599-600`) : pas de migration de façade, mais ajout du contexte ville et des nouvelles règles de passage.

Les appels de reverse geocoding dans `LivraisonScreen` et `AddressPickerWidget` recensés dans l'audit restent hors de la fusion autocomplete ; ils ne doivent pas être supprimés par ce lot (`docs/AUDIT_GEO.md:21-23`). Tout autre appelant actuel de l'autocomplete est **non trouvé** après recherche du dépôt.

## Ordre de résolution et portes précises

La clé logique de toute recherche devient `cityId|requêteNormalisée`. Le seuil minimal reste trois caractères, déjà centralisé par `PlacesSearchService.minQueryLength` et appliqué dans l'UI livraison (`lib/services/places_search_service.dart:20-37`, `lib/screens/client/livraison_screen.dart:239-251`). La séquence cible est :

1. **Base locale filtrée par ville.** Après 300–400 ms sans saisie et seulement si la ville active est desservable, exécuter la requête préfixe locale, bornée à 8. Si elle retourne un match local administrativement vérifié dont `normalizedName == q` ou dont `aliases` contient exactement `q`, afficher les résultats et **arrêter** : ni cache externe, ni Nominatim, ni Google. Si elle retourne au moins 5 résultats vérifiés pertinents, arrêter également. Le moteur actuel interroge localement sans ville avec des limites 10 et 6 (`lib/services/places_search_service.dart:67-97`) ; le filtre ville est donc indispensable.
2. **Cache externe partagé.** Seulement si la base locale n'a fourni ni match exact/alias vérifié ni 5 résultats vérifiés, consulter le cache `cityId|q`. Un hit non expiré est affiché avec les résultats locaux et arrête le réseau. Les deux piles ont aujourd'hui des caches distincts : autocomplete 10 minutes dans `PlacesService` (`lib/services/places_service.dart:52-61`) et Nominatim 5 minutes dans `PlacesSearchService` (`lib/services/places_search_service.dart:24-29`). La façade unique doit conserver les TTL applicables à chaque source sans réintroduire deux caches de recherche.
3. **Nominatim.** Seulement sur cache miss, requête stable d'au moins 3 caractères, ville desservable connue, et absence de match local exact/alias vérifié. La requête doit être contextualisée avec le nom/centre/rayon de la ville active, jamais avec la constante Abengourou. Aujourd'hui Nominatim ajoute explicitement « Abengourou » et utilise une viewbox fixe (`lib/services/places_search_service.dart:126-143`). Les résultats sont fusionnés/dédupliqués, mais un résultat local vérifié garde la priorité.
4. **Google.** Ne plus déclencher Google parce que le total est inférieur à trois, règle actuelle des deux piles (`lib/services/places_service.dart:101-111`, `lib/services/places_search_service.dart:43-51`). Porte recommandée : Google n'est accessible qu'après zéro match local exact/alias, cache miss, zéro résultat Nominatim exploitable dans la ville, requête d'au moins 5 caractères, et action explicite de l'utilisateur « Élargir la recherche ». Une seule session autocomplete est ouverte pour la saisie/sélection. Alternative : déclenchement automatique après ces mêmes échecs et un délai supplémentaire ; friction moindre, mais toute ville peu couverte produit mécaniquement des appels payants. Recommandation : action explicite, à valider.

Un résultat local non vérifié peut être affiché sous un badge distinct, mais il ne doit ni bloquer seul la recherche externe ni devenir vérifié automatiquement. L'existant trie déjà les vérifiés devant les autres (`lib/services/places_search_service.dart:99-104`) et l'auto-apprentissage écrit `verified: false` (`lib/services/places_search_service.dart:337-358`).

# SECTION 5 — CAS GABRIEL

## Préconditions communes

Le GPS situe l'utilisateur dans le disque d'Agnibilékrou : document `zones_livraison` de type `ville`, `cityId == agnibilekrou`, point propre, rayon valide, `isActive == true` et `isServiceable == true`. Une surcharge manuelle persistée, si présente, devient la ville active conformément à D4 ; la ville GPS reste enregistrée comme contexte distinct. La détection ne peut pas reposer sur l'actuel filtre global `isActive` et tri `order`, qui lit toutes les zones actives (`lib/screens/client/create_order.dart:1588-1594`).

AZ Places contient un document vérifié pour le lieu concerné, avec `cityId: agnibilekrou`, coordonnées valides, `normalizedName` et aliases administrés. L'état réel d'un tel document dans Firestore est **non trouvé** ; le scénario décrit le comportement cible après son enregistrement et sa validation admin.

## « Gabriel »

1. À trois caractères, l'UI peut chercher ; après debounce, `q = gabriel`. Aucun réseau n'est lancé avant le seuil, comme le fait déjà l'écran livraison (`lib/screens/client/livraison_screen.dart:239-255`).
2. Requête P, préfixe canonique : `places.where(cityId == 'agnibilekrou').where(isVerified == true).orderBy(normalizedName).startAt(['gabriel']).endAt(['gabriel\uf8ff']).limit(8)`. Index composite requis : `cityId ASC, isVerified ASC, normalizedName ASC`.
3. Si le document s'appelle « Gabriel », P retourne un document. Le client constate `normalizedName == q`, l'affiche et s'arrête. Nombre de documents lus par P : 1 dans ce cas ; maximum 8.
4. Si P retourne zéro, requête A : `places.where(cityId == 'agnibilekrou').where(isVerified == true).where(aliases, arrayContains: 'gabriel').limit(8)`. Index composite requis : `cityId ASC, isVerified ASC, aliases ARRAY_CONTAINS`. Si « Gabriel » est un alias d'un nom plus long, A retourne le document et arrête la pile.
5. Parce qu'un match exact vérifié existe dans P ou A, le cache externe, Nominatim et Google ne sont pas consultés. Le zéro appel Google découle de la porte de décision, non d'un objectif de nombre minimal de suggestions.

## « pharmacie Gabriel »

1. `q = pharmacie gabriel`, même ville active.
2. P est identique avec les bornes `pharmacie gabriel` et `pharmacie gabriel\uf8ff`, limite 8. Si le nom canonique est « Pharmacie Gabriel », elle retourne un document et la pile s'arrête.
3. Si le nom canonique diffère, A cherche l'alias exact `pharmacie gabriel`, limite 8. L'alias doit avoir été validé/adminis­tré ; une concaténation supposée de catégorie et nom ne suffit pas.
4. Nombre de documents lus : 1 si P trouve le nom canonique ; sinon 0 à 8 pour P puis 0 à 8 pour A. Une fois le document correctement enregistré avec nom ou alias, aucun étage externe n'est appelé.

## « Lycée moderne »

1. `q = lycee moderne` après la même normalisation sans accents ; une normalisation sans accents existe déjà dans `LocalPlace` (`lib/models/local_place.dart:37-49`).
2. P utilise les bornes `lycee moderne` et `lycee moderne\uf8ff`, limite 8. Un document canonique « Lycée moderne » est retourné.
3. Sinon A utilise `aliases array-contains lycee moderne`, limite 8. Le même arrêt exact s'applique.
4. Nombre de documents lus : 1 au chemin canonique attendu ; au pire 16 documents retournés sur les deux requêtes bornées. Google reste à zéro si P ou A livre le match vérifié.

Le moteur actuel exécute systématiquement deux requêtes Firestore — préfixe limite 10 puis `keywords` limite 6 — même si la première a trouvé un résultat (`lib/services/places_search_service.dart:72-97`). Le plan rend A conditionnelle à l'absence de match exact dans P, ce qui réduit les lectures du cas nominal.

# SECTION 6 — DISPATCH MULTI-VILLE

## Champs de commande

Ajouter sans retirer les champs existants :

- `pickupCityId`, `deliveryCityId` : villes résolues géométriquement pour les deux points ;
- `pickupZoneId`, `deliveryZoneId` : IDs de zones, ou `null` si aucun disque enfant propre ne contient le point ;
- `pickupLatitude`, `pickupLongitude`, `deliveryLatitude`, `deliveryLongitude` : points effectifs, déjà partiellement écrits aujourd'hui (`lib/models/order_model.dart:200-215`) ;
- `pickupCoordinateSource`, `deliveryCoordinateSource` : `gps`, `map_pin`, `local_place`, `nominatim` ou `google`, jamais `inherited` ;
- `gpsDetectedCityId` : ville issue du GPS au moment de la commande ;
- `activeCityId` et `citySelectionSource` (`gps` ou `manual_override`) : contexte effectivement choisi selon D4 ;
- `cityResolutionStatus` (`resolved`, `border`, `outside_service`, `unknown`) : audit des frontières et des refus ;
- conserver `pickupZone` et `deliveryZone` textuels pendant compatibilité, car le modèle actuel les lit et les écrit (`lib/models/order_model.dart:48-49`, `lib/models/order_model.dart:150-151`, `lib/models/order_model.dart:214-215`).

Aucun champ de prix ou de tarif n'est ajouté ou modifié.

## Éligibilité et ordre des livreurs

Le dispatch actuel lit tous les livreurs `isOnline == true` sans limite (`functions/dispatch.js:40-45`), exclut livraison en cours, indisponibilité, suspension, notification déjà pendante, wallet insuffisant, GPS périmé de plus de trois minutes, absence de GPS et distance hors rayon (`functions/dispatch.js:52-75`). Il trie ensuite par distance et retient cinq IDs (`functions/dispatch.js:80-86`). Ces protections sont conservées.

Ordre cible recommandé :

1. filtres d'intégrité actuels ;
2. GPS livreur récent et point de collecte réel ;
3. distance au pickup dans le rayon de dispatch existant ;
4. présence géométrique actuelle dans la ville de pickup ou dans sa bande frontière ;
5. tri principal par distance croissante ;
6. à distance quasi égale, priorité au livreur dont `currentCityId` correspond à la ville du pickup ;
7. ensuite seulement, `registeredCityId` correspondant comme départage administratif ;
8. conserver le top 5 et le verrou transactionnel existants (`functions/dispatch.js:85-115`).

La ville d'inscription ne doit pas être un filtre dur. Si elle diffère de la position réelle, le GPS récent domine : un livreur inscrit à Abengourou mais physiquement à Agnibilékrou peut être candidat à Agnibilékrou s'il passe les contrôles de distance et de desserte. La divergence est journalisée pour contrôle, pas sanctionnée automatiquement. Les champs `registeredCityId` et `currentCityId` dans les documents livreurs sont **non trouvés** dans le chemin de dispatch actuel ; celui-ci ne lit que les statuts, wallet, horodatage et coordonnées cités (`functions/dispatch.js:52-75`).

## Frontières et trajets entre villes

La règle `pickupCityId != deliveryCityId ⇒ rejet` est exclue. Recommandation : combiner trois décisions indépendantes :

- le pickup doit être dans une zone de ville desservable, ou dans une tolérance frontière explicitement validée ;
- la destination doit être dans une zone desservable, ou être acceptée selon la politique hors-zone existante à définir, sans créer/modifier de tarif dans ce chantier ;
- l'éligibilité du livreur dépend de sa distance réelle au pickup, pas de l'égalité de chaînes `cityId`.

Si un point appartient à plusieurs disques de villes, marquer `cityResolutionStatus: border`. Option A choisit le centre dont la distance normalisée `distance/radiusKm` est la plus petite ; automatique et stable. Option B demande à l'utilisateur de choisir parmi les villes actives ; plus explicite, mais ajoute une étape. Recommandation : A pour proposer, avec possibilité de surcharge manuelle persistée conformément à D4. La commande conserve les deux traces GPS et choix actif pour audit.

## Ville détectée mais inactive

Si le GPS correspond à une ville `isActive == false` ou `isServiceable == false`, ne pas lancer la recherche externe ni le dispatch. Afficher « ville non desservie », permettre une surcharge manuelle vers une ville active seulement si l'utilisateur y commande réellement un point, et conserver le statut `outside_service`. Le système ne doit pas replier automatiquement vers Abengourou. Le filtre actuel ne connaît que `isActive == true` (`lib/screens/client/create_order.dart:1588-1594`) ; la distinction de desserte est donc un ajout requis.

# SECTION 7 — COÛT FIRESTORE

## Lectures des scénarios de la section 5

| Saisie | Requête | Documents lus/retournés | Index requis | Arrêt et pagination |
|---|---|---:|---|---|
| `Gabriel` | P : ville + vérifié + préfixe `normalizedName` | cas attendu : 1 ; borne : 8 | `cityId ASC, isVerified ASC, normalizedName ASC` | Arrêt immédiat sur exact. Page suivante seulement après action « plus », avec curseur sur `normalizedName` et ID ; 8 par page. |
| `Gabriel` si P sans exact | A : ville + vérifié + `aliases array-contains gabriel` | 0 à 8 supplémentaires | `cityId ASC, isVerified ASC, aliases ARRAY_CONTAINS` | Une seule page bornée à 8 ; pas de pagination automatique. |
| `pharmacie Gabriel` | P, mêmes filtres et préfixe | cas canonique : 1 ; borne : 8 | même index P | Même arrêt ; A seulement sans exact. |
| `pharmacie Gabriel` si nécessaire | A avec alias exact | 0 à 8 supplémentaires | même index A | Une seule page bornée. |
| `Lycée moderne` | P sur `lycee moderne` | cas canonique : 1 ; borne : 8 | même index P | Même arrêt ; A seulement sans exact. |
| `Lycée moderne` si nécessaire | A avec alias exact | 0 à 8 supplémentaires | même index A | Une seule page bornée. |

Les nombres ci-dessus sont des documents effectivement retournés par les limites ; la facturation minimale exacte d'une requête vide dépend des règles tarifaires Firestore en vigueur au moment de l'implémentation et doit être vérifiée alors. Le dépôt ne contient pas cette grille tarifaire : **non trouvé**.

Les index actuels de `zones_livraison` couvrent `order+name`, `type+order+name` et `isActive+order` (`firestore.indexes.json:188-211`). Aucun index composite `places` correspondant à P ou A n'est présent dans le fichier d'index consulté : **non trouvé**. Les deux index proposés doivent être ajoutés avant la bascule des requêtes ; leur création est un déploiement d'index ultérieur, pas une action de ce run.

## Bornes supplémentaires

- La détection de ville doit lire seulement `zones_livraison` avec `type == ville`, `isActive == true`, `isServiceable == true`, limite 50, une fois par session puis cache local. Index proposé : `type ASC, isActive ASC, isServiceable ASC, normalizedName ASC`. Avec plus de 50 villes actives, une pagination explicite ou une stratégie géographique supplémentaire deviendra nécessaire ; avant ce seuil, lire toutes les villes actives une fois est simple et borné.
- La recherche P est limitée à 8 ; A n'est lancée que si P n'a pas d'exact. Le cas nominal lit donc un document, pas les 16 maximum du moteur actuel, lequel lance limites 10 puis 6 sans court-circuit (`lib/services/places_search_service.dart:72-97`).
- Le compteur `searchCount` ajoute une écriture par sélection locale aujourd'hui (`lib/services/places_search_service.dart:304-312`). Option A le conserve en temps réel : classement frais, coût d'écriture inchangé. Option B l'agrège localement : moins d'écritures, mais perte potentielle et complexité. Recommandation : conserver dans ce chantier ; son optimisation est hors périmètre multi-ville.
- L'auto-apprentissage fait actuellement une requête `nameSearch == norm`, limite 1, sans ville, puis une mise à jour ou création (`lib/services/places_search_service.dart:320-358`). Elle doit devenir `cityId + normalizedName`, limite 1, sinon deux villes homonymes fusionnent. Index proposé : `cityId ASC, normalizedName ASC`. Cette requête reste bornée à une lecture retournée.
- Le dispatch actuel présente le risque majeur non borné : il lit tous les livreurs en ligne (`functions/dispatch.js:40-45`). Ajouter seulement `currentCityId` comme égalité dure serait incorrect aux frontières. Deux options : (A) requêtes bornées par villes candidates (ville principale plus villes dont les disques touchent la bande frontière), puis filtre distance ; (B) géohash sur les documents livreurs, plusieurs plages bornées puis filtre exact. A coûte moins de changements et suit D3, mais peut encore lire beaucoup de livreurs dans une grande ville ; B borne mieux à l'échelle, mais ajoute maintenance d'index et de géohash. Recommandation : A pour Agnibilékrou avec une limite opérationnelle et métriques, B seulement avant que le volume rende A insuffisante. La limite exacte et le comportement si elle est atteinte doivent être validés avant implémentation.

Tout écouteur temps réel sur P/A, toute requête sans `limit`, toute pagination automatique au scroll et toute double requête sur chaque caractère sont interdits. Le debounce actuel de l'écran livraison est de 300 ms (`lib/screens/client/livraison_screen.dart:239-255`) ; il doit être conservé. Le risque de lecture non bornée restant explicitement identifié est le dispatch des livreurs en ligne (`functions/dispatch.js:40-45`).

# SECTION 8 — DÉCOUPAGE EN LOTS D'IMPLÉMENTATION

Chaque lot tient dans une session de travail et doit livrer tests, formatage et analyse adaptés. Aucun lot ne change les tarifs. Immobilier, pharmacies en tant que vertical métier, marketplace, événements et Ekbine restent hors périmètre ; seule la chaîne livraison utilise les lieux décrits.

## Lot 1 — Contrat de données et compatibilité de lecture

Contenu : formaliser les champs des deux collections existantes, normalisation unique, lecture duale `nameSearch/normalizedName` et `verified/isVerified`, validation `coordinateSource`, et règles de sécurité empêchant un client de poser `isVerified: true`. L'existant autorise la création authentifiée avec seulement nom et coordonnées (`firestore.rules:899-909`), donc ce verrou doit précéder l'auto-apprentissage multi-ville.

Débloque : migration sûre et documents nouveaux cohérents. Si sauté : chaque écran interprète différemment les absences, et D6 n'est pas garanti.

## Lot 2 — Migration sèche puis appliquée d'Abengourou

Contenu : script local `dry-run/apply/rollback`, rapport JSON, préconditions, rattachement `cityId: abengourou`, `parentZoneId`, noms normalisés et états de coordonnées. Aucune Cloud Function. Le seed actuel utilise des IDs automatiques et des parents textuels (`lib/screens/admin/admin_zones_page.dart:187-200`).

Débloque : compatibilité de l'historique avec les filtres ville. Si sauté : les documents historiques disparaissent des requêtes multi-ville ou nécessitent un fallback global coûteux.

## Lot 3 — Administration point, rayon et desserte

Contenu : étendre l'écran admin existant pour `cityId`, parent par ID, aliases, point, rayon, origine et `isServiceable`; contrôles de paire lat/lng et rayon positif. L'écran sait déjà gérer types, parent textuel et capture GPS (`lib/screens/admin/admin_zones_page.dart:230-283`, `lib/screens/admin/admin_zones_page.dart:286-343`).

Débloque : création d'Agnibilékrou et validation terrain sans changement de code métier. Si sauté : les nouvelles villes exigent des écritures manuelles risquées et aucune géométrie n'est fiable.

## Lot 4 — Suppression fonctionnelle des coordonnées héritées

Contenu : empêcher les coordonnées `inherited/unknown` d'entrer dans distance, prix ou dispatch ; exiger un point effectif de commande ; tests sur quartier sans point. L'héritage se produit aujourd'hui dans le sélecteur (`lib/screens/client/create_order.dart:1614-1628`).

Débloque : toute logique de distance fiable. Si sauté : des quartiers distincts restent confondus avec le centre de leur ville ; les lots de détection et dispatch seraient invalides.

## Lot 5 — Détection GPS et surcharge persistée

Contenu : charger les villes actives/desservables de façon bornée, calcul point-dans-rayon, gérer chevauchement/frontière, persister la surcharge manuelle avec le stockage local déjà dépendant du projet (`pubspec.yaml:54-59`), traiter ville inactive sans repli Abengourou.

Débloque : contexte `activeCityId` stable dans la livraison. Si sauté : recherche et commandes ne peuvent pas être cloisonnées par ville.

## Lot 6 — Index et recherche locale ville-aware

Contenu : ajouter les index P/A et auto-apprentissage, étendre AZ Places, requêtes limites 8, aliases, court-circuit exact, tests de lectures logiques. Le dépôt n'a actuellement que les trois composites de zones cités (`firestore.indexes.json:188-211`).

Débloque : scénarios Gabriel à zéro Google. Si sauté : filtre ville impossible ou requêtes rejetées par Firestore, et homonymes mélangés.

## Lot 7 — Façade de recherche unique et portes externes

Contenu : conserver `PlacesSearchService`, migrer les quatre appels des deux écrans listés en section 4, partager les caches, contextualiser Nominatim/Google par ville, rendre Google explicite après échecs précis, préserver debounce/TTL/conformité. Les constantes actuelles ciblent Abengourou dans Nominatim et Google (`lib/services/places_search_service.dart:126-143`, `lib/services/places_search_service.dart:215-227`).

Débloque : ajout d'une ville par données admin, sans modification métier ni appels Google automatiques dus à une faible couverture. Si sauté : deux piles et deux caches continuent à diverger et le seuil « moins de 3 » continue à appeler Google.

## Lot 8 — Commande enrichie et compatibilité

Contenu : écrire les city IDs, zone IDs, sources et statut de résolution tout en conservant les champs textuels actuels ; règles et tests de sérialisation. Le modèle actuel ne porte que les zones textuelles et coordonnées (`lib/models/order_model.dart:36-49`, `lib/models/order_model.dart:200-215`).

Débloque : dispatch explicable, audit des frontières et historique stable. Si sauté : le serveur doit redéduire la ville à chaque dispatch et peut obtenir un résultat différent de celui vu par le client.

## Lot 9 — Dispatch multi-ville borné

Contenu : critères de section 6, ville actuelle dérivée du GPS récent, ville d'inscription comme départage seulement, requêtes bornées, frontière sans rejet par inégalité, conservation des filtres et transaction actuels (`functions/dispatch.js:52-75`, `functions/dispatch.js:85-128`).

Débloque : attribution Agnibilékrou et inter-ville contrôlée. Si sauté : lecture de tous les livreurs en ligne et aucune notion de ville (`functions/dispatch.js:40-45`). Ce lot implique une modification puis un déploiement ultérieur de la Cloud Function existante ; aucun déploiement n'est réalisé ici.

## Lot 10 — Validation terrain et observabilité coût

Contenu : tests Abengourou/Agnibilékrou/frontière/ville inactive, compteurs par étage de recherche, taux de hits locaux/cache/Nominatim/Google, nombre de documents lus par requête et alerte sur limite dispatch. Aucune adresse ni identifiant personnel dans les logs.

Débloque : décision factuelle avant généralisation à d'autres villes. Si sauté : impossible de prouver que le Local First réduit réellement Google sans déplacer le coût vers Firestore.

**DÉCISIONS QUI M'APPARTIENNENT**

- Valider l'initialisation prudente `isServiceable: false` pour toute géométrie historique non vérifiée, plutôt que la copie automatique de `isActive`.
- Valider le rayon de chaque ville et zone ; aucune valeur de rayon n'est déduite dans ce plan.
- Choisir la transition de vérification : adopter `isVerified` avec lecture duale/migration, ou conserver le nom historique `verified` en appliquant strictement D6.
- Valider le script local comme mécanisme de migration et l'organisation de conservation des rapports JSON de rollback.
- Valider la règle de frontière recommandée : plus petite distance normalisée, avec surcharge manuelle possible.
- Valider la porte Google recommandée : action explicite après échec local, cache et Nominatim, requête d'au moins cinq caractères ; ou accepter le coût du fallback automatique.
- Définir si un résultat AZ Places non vérifié est affiché avec badge ou masqué jusqu'à validation admin ; il ne sera jamais promu automatiquement.
- Valider les aliases administrés pour « Gabriel », « Pharmacie Gabriel » et les noms locaux ; le contenu réel de la collection de production est non trouvé.
- Définir la politique métier d'une destination hors zone ou entre deux villes actives, sans décider ni modifier aucun tarif dans ce chantier.
- Fixer la tolérance de frontière et la limite opérationnelle de livreurs candidats avant le lot dispatch.
- Valider si la surcharge manuelle reste seulement sur l'appareil ou doit aussi être synchronisée dans un document utilisateur existant ; aucune nouvelle collection n'est proposée.
- Autoriser ultérieurement les déploiements séparés nécessaires : règles Firestore, index composites et mise à jour de la Cloud Function de dispatch. Aucun n'est effectué dans ce run.
