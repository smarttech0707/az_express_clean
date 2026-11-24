## Évolutivité

Toute nouvelle fonctionnalité doit pouvoir être ajoutée sans casser les fonctionnalités existantes. Avant de modifier un modèle partagé (ex. `OrderModel`), vérifier tous les consommateurs existants (app livreur, admin, pricing, notifications) — préférer les extensions additives (nouveaux champs nullable) aux changements cassants.

