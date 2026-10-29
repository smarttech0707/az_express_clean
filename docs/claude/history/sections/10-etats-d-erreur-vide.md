## États d'erreur & vide

Il n'existe **pas** de widgets d'erreur réutilisables aujourd'hui (pas de "pas de connexion", "404", "permission refusée", "localisation désactivée" génériques) — chaque écran gère ça au cas par cas (SnackBar, Dialog, Center+Text inline). Avant d'ajouter un nouvel écran d'erreur ad-hoc, vérifier si un widget partagé (`lib/widgets/`) devrait être créé à la place — mais ne pas lancer une refonte globale des erreurs sans que ce soit la tâche demandée.

