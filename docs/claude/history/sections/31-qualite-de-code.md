## Qualité de code

Code lisible, modulaire, réutilisable, testé, sécurisé. Éviter la duplication — avant d'écrire une nouvelle fonction, vérifier si un service/helper existant peut être réutilisé (`lib/services/`, `lib/ekbine/services/ek_service.dart` est un bon exemple de service layer propre à imiter). Documenter le POURQUOI quand il n'est pas évident (contrainte cachée, contournement, invariant) plutôt que reformuler ce que le code montre déjà — la lisibilité du code et des noms doit porter l'essentiel de la documentation.

