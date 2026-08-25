# Standard unifié des publications — V1

## Contrat commun cible

Chaque publication doit disposer d'un propriétaire immuable (`ownerId` ou
`sellerId`/`agentId`), d'un statut générique (`draft`, `active`, `inactive`,
`paused`, `archived`, `deleted`), d'un statut métier séparé, de
`createdAt`/`updatedAt`, et de médias ordonnés avec une image principale.

Les actions communes sont : créer, modifier, supprimer avec confirmation,
apercevoir, partager, activer/désactiver et consulter les statistiques qui
existent réellement. Les règles doivent protéger le propriétaire, les prix,
les identifiants partenaires et les données financières.

## Migration progressive

1. Immobilier : adopter le statut générique séparé de `available/reserved/...`
   et compléter les statistiques/partage sans modifier les visites existantes.
2. Boutique, Pharmacie et Boulangerie : adapter leurs écrans propriétaires au
   contrat commun, en conservant leurs stock et paiements serveur.
3. Annuaire : `service_providers` et `simple_services` restent des fiches,
   sans actions de commande tant que le backend n'existe pas.
4. Catalogues historiques : migrer `locations` et `residences` vers
   `real_estate_listings` seulement après validation métier et données.

## Composants à créer lors de la migration

`PublicationCard`, `PublicationStatus`, `PublicationActions`,
`PublicationStats`, `PublicationImages` et les dialogues communs de
suppression/activation/désactivation. Ils ne doivent être branchés qu'après
compatibilité de chaque schéma et de ses règles.
