// LOT 6.2 SECURITY — numéro de build compile-time, tenu manuellement en
// miroir du `+N` de pubspec.yaml (`version: 1.0.0+1` → kAppBuildNumber = 1).
// Utilisé uniquement pour comparer l'app installée à `config/app_version`
// (voir lib/services/wallet_payment_compatibility.dart) avant une tentative
// de paiement wallet — jamais pour autre chose. Choix délibéré de ne PAS
// ajouter `package_info_plus` pour cette seule vérification (aucune autre
// dépendance de ce type dans le projet à ce jour) : une constante manuelle,
// bumpée à chaque release aux côtés de pubspec.yaml, reste la solution la
// plus légère et la plus sûre pour ce besoin précis. Si un jour un usage
// plus large de la version installée est nécessaire ailleurs dans l'app,
// migrer vers `package_info_plus` (lecture dynamique, jamais désynchronisée)
// plutôt que multiplier les constantes manuelles.
const int kAppBuildNumber = 1;
