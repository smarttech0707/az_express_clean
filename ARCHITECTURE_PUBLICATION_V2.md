# Architecture Publication V2

## Objectif et principes

Publication V2 est un contrat de données et d'actions commun, pas une nouvelle
collection obligatoire. Chaque module conserve ses champs métier et adopte le
contrat progressivement, sans migration automatique ni changement des flux
Wallet, paiement, livraison ou authentification.

Une publication possède un propriétaire immuable, des statuts séparés entre
visibilité technique et métier, des médias ordonnés et des statistiques
uniquement lorsqu'elles sont effectivement produites.

## Contrat de données commun

```text
id: string
ownerId: string                    // immuable
ownerType: string                  // seller, agent, restaurant, pharmacy, admin...
createdAt: server timestamp
updatedAt: server timestamp

isActive: bool
isDeleted: bool
visibility: public | private | hidden | suspended
publicationStatus: draft | active | inactive | archived | deleted
businessStatus: string             // propre au module

title: string
description: string?
category: string

images: [{url, storagePath, order, mimeType?, sizeBytes?}]
mainImage: string?
videos: [{url, storagePath, mimeType, sizeBytes}]? // seulement si supporté

latitude: number?
longitude: number?
address: string?
city: string?

views: number?                     // serveur ou incrément strictement borné
contacts: number?
favorites: number?
```

Les modules ajoutent leurs données métier dans un sous-ensemble propre : prix,
stock, disponibilité, réservation, ordonnance, préparation, etc. Ces données
ne sont jamais remplacées par le contrat commun.

## Actions et droits

| Action | Propriétaire | Admin | Préconditions |
|---|---|---|---|
| Créer | Oui | Oui | propriétaire défini, données métier valides |
| Modifier | Oui, hors ownerId et données financières | Oui | non supprimée |
| Désactiver / activer | Oui | Oui | transition autorisée |
| Archiver | Oui | Oui | non livrée / non engagée selon métier |
| Supprimer | Oui selon module | Oui | confirmation et nettoyage médias |
| Restaurer | Non | Oui | archivage/suppression logique |
| Partager / voir | selon visibilité | Oui | lecture autorisée |
| Statistiques | propriétaire | Oui | données réellement collectées |
| Signaler | utilisateur autorisé | modère | publication visible |

Transitions génériques : `draft -> active -> inactive -> active`,
`active|inactive -> archived`, `archived -> active` seulement par admin si la
politique métier le permet, puis `* -> deleted` comme suppression logique.
`businessStatus` reste indépendant : Immobilier (`available`, `reserved`,
`rented`, `sold`), Boutique (`in_stock`, `out_of_stock`), Boulangerie
(`available`, `preparing`, `ready`, `out_of_stock`) et Services (`available`,
`busy`, `unavailable`).

## Médias

Les images sont un tableau ordonné ; `mainImage` référence l'élément principal.
Chaque upload stocke chemin, MIME et taille afin de permettre suppression et
remplacement sûrs. Les règles Storage doivent vérifier propriétaire/admin,
MIME image, taille maximale et chemin lié à l'ID de publication. Les vidéos ne
sont activées que pour les modules qui disposent de validation MIME, limite de
taille et stratégie de compression.

## Localisation GPS obligatoire

Les publications Immobilier (maisons, résidences, terrains, locaux
commerciaux), les services avec adresse physique, pharmacies, boulangeries,
boutiques physiques, restaurants et tout service nécessitant le déplacement du
client adoptent le sous-contrat suivant :

```text
latitude: number
longitude: number
address: string
city: string
quartier: string?
locationLabel: string?
geohash: string?
locationVerified: bool
locationUpdatedAt: server timestamp
locationPrecision: exact | approximate | hidden
```

`latitude` est comprise entre -90 et 90 et `longitude` entre -180 et 180.
Une localisation obligatoire refuse les valeurs nulles et le couple `0,0`.
Toute modification par un propriétaire autorisé, un agent vérifié ou un admin
met simultanément à jour `updatedAt` et `locationUpdatedAt`.

Le propriétaire peut utiliser le GPS, chercher une adresse, choisir ou déplacer
un repère sur la carte, confirmer sa position puis la modifier. Le client peut
consulter l'adresse et le quartier autorisés, la carte, la distance si elle est
réellement calculée, un itinéraire, l'ouverture Maps externe et le partage de
localisation.

Pour l'Immobilier, `locationPrecision` est obligatoire :

- `exact` : coordonnées exactes publiques ;
- `approximate` : position décalée/publique avant accord de visite ;
- `hidden` : aucune coordonnée publique.

Les coordonnées exactes ne sont alors révélées qu'après accord de l'agent ou
confirmation de visite. Les terrains exigent GPS et carte, mais n'affichent
jamais de mesure cadastrale inventée et précisent que le GPS ne remplace pas
les documents fonciers. Les résidences exigent le bâtiment et l'itinéraire ;
les lieux utiles et distances ne sont affichés que si leurs données existent.

Les Rules doivent interdire au client la modification de localisation, vérifier
les bornes, le droit du propriétaire/agent/admin, l'immuabilité du propriétaire
et la confidentialité selon `locationPrecision`. Les tests de migration devront
couvrir coordonnées valides, refus de `0,0`, refus d'un tiers, autorisation
d'un agent vérifié et d'un admin, protection de position exacte, itinéraire,
petit écran et non-chevauchement avec AZ IA.

## Sécurité Firestore

Les règles communes doivent :

- exiger `ownerId == request.auth.uid` à la création ;
- interdire tout changement de `ownerId`, `sellerId`, `agentId`, `partnerId` ;
- interdire les écritures directes sur solde, commission, paiement et statut
  terminal métier ;
- limiter l'admin à un document `admins/{uid}` actif ;
- limiter les incréments publics de statistiques à une opération bornée ;
- réserver les transitions de réservation, commande, remboursement et paiement
  aux Cloud Functions ou aux règles métier déjà existantes.

## Inventaire et migration progressive

| Module | Collection/modèle actuel | Compatible | Évolution requise |
|---|---|---|---|
| Immobilier | `real_estate_listings`, `RealEstateListing` | propriétaire, images, ville, vues, statuts | séparer statut générique/métier, ajouter updatedAt et médias structurés |
| Maisons / Résidences | `locations`, `residences` | catalogue et médias administrés | migration ultérieure vers Immobilier, pas de réservation avant backend |
| Marketplace/Boutique | `marketplace_products`, `MpProduct` | vendeur, prix, images, stock | adapter statuts et actions sans toucher paiement/stock serveur |
| Pharmacie | `pharmacies` et commandes | administration/propriétaire selon flux | définir publication catalogue distincte des commandes |
| Boulangerie | `boulangeries`, `menu_items` | propriétaire, menu, disponibilité | normaliser médias/statuts sans toucher préparation/paiements |
| Services locaux | `service_providers`, `services` | annuaire, prestataire | rester annuaire jusqu'au backend rendez-vous |
| Blanchisserie / Eau / Cave / Colis | configuration et/ou `orders` | faible | définir d'abord un catalogue et un propriétaire serveur |
| Futur véhicule/location/événement | nouvelle collection | oui par contrat | créer avec ce schéma dès l'origine |

Ordre recommandé : 1) Immobilier, 2) Marketplace/Boutique, 3) Boulangerie,
4) Pharmacie, 5) annuaires Services, 6) catalogues non finalisés. Les données
`locations`, `residences`, `simple_services` et `service_providers` ne doivent
pas être migrées avant validation métier.

## Widgets à préparer lors des migrations

`PublicationCard`, `PublicationGrid`, `PublicationEditor`,
`PublicationImages`, `PublicationGallery`, `PublicationStatusChip`,
`PublicationActionsMenu`, `PublicationDeleteDialog`, `PublicationStatsCard`,
`PublicationOwnerHeader`, `PublicationLocationCard` et `PublicationMediaPicker`.
Ils seront créés seulement lorsqu'un premier module fournit le contrat complet,
afin d'éviter des composants branchés sur des champs inexistants.

## Bonnes pratiques

- horodatages serveur exclusivement ;
- suppression logique avant suppression physique ;
- pagination par curseur, jamais lecture complète ;
- tests Rules pour chaque droit et transition ;
- toute statistique affichée provient d'une donnée réellement maintenue ;
- aucune migration automatique sans sauvegarde, script idempotent et validation
  préalable sur environnement de test.
