# Suppression de compte — état local, activation interdite sans validation

Mise à jour du 24 octobre : voir ACCOUNT_DELETION_PARTNER_IMPLEMENTATION.md. Le moteur multirôle et les neuf suppressions nominales sont maintenant implémentés et testés sur émulateurs, sous un indicateur partenaire désactivé par défaut. Les anciennes mentions « destruction partenaire non implémentée » sont historiques. L'activation reste PARTIELLE pour les limites précisément listées dans le nouveau rapport.

Dernière reprise partenaires : liaison permanente pharmacie par nomination admin et acceptation personnelle ajoutée ; voir le complément en tête de ACCOUNT_DELETION_ROLE_POLICY.md. Résultats : 937 backend, 28 Firestore ciblés, 5 tests avec trois émulateurs réels, 18 Flutter réussis ; analyse ciblée sans anomalie. Seules les suppressions client/livreur sont validées sur émulateurs. Destruction des sept partenaires encore bloquée par le code, pas finalisée. Politique métier acceptée ; il reste des implémentations et validations techniques.

## Dernière reprise : identité et support

Voir `ACCOUNT_DELETION_ROLE_POLICY.md` pour l'état courant par rôle, l'inventaire de conservation, les protections Admin SDK ciblées et les résultats. Une page super-admin et manageAccountDeletionCF permettent désormais la prise en charge et le réexamen audités sans forcer les obligations. Six rôles partenaires supplémentaires déposent une demande authentifiée mais restent bloqués avant destruction ; pharmacie conserve la vérification manuelle. Verdict toujours PARTIEL, neuf suppressions définitives non validées. Les mentions historiques « aucun outil support » ci-dessous ne décrivent plus le code courant.

## Complément du 23 octobre 2026 — dernière reprise

Verdict : PARTIEL, pas terminé pour les neuf rôles, activation toujours bloquée.

Corrections supplémentaires : `deletionRequested` est écrit côté serveur pour une demande livreur avec consentement vérifié, protégé contre les écritures du livreur, et exclu de la sélection. `dispatch.js` relit les reçus dans la transaction d'attribution. Les règles refusent une nouvelle acceptation mais permettent encore accepted → picked_up → delivered. Le suivi est désormais accessible depuis l'accueil après redémarrage via le reçu conservé sur l'appareil.

Tests supplémentaires exécutés : 920/920 backend ; 18/18 Flutter ; analyse des cinq fichiers Flutter concernés sans anomalie ; 4/4 tests avec Auth, Firestore et Storage Emulator réels (deux suppressions, reconnexion refusée, fichiers supprimés, ancienne session refusée, deux scénarios de blocage avec poursuite de mission). La suite Firestore générale a passé ses 235 tests. La suite Storage a initialement échoué sur 2 tests à cause d'un projet de test différent du projet de l'émulateur ; après configuration du même projet fictif, 11/11 passent. Aucune permission n'a été élargie. Les erreurs transitoires Auth/Storage restent couvertes par injection de panne, pas par panne réelle de ces émulateurs.

Fichiers supplémentaires de cette reprise : functions/accountDeletion.js, functions/dispatch.js, functions/test/dispatch.test.js, firestore.rules, lib/screens/home/home_screen.dart, rules-tests/account-deletion.test.js, rules-tests/storage.rules.test.js, rules-tests/account-deletion-real.test.js, firebase.account-deletion-emulators.json et ce rapport. Les journaux des émulateurs ont été générés localement par Firebase CLI.

Les anciennes limitations ci-dessous sont conservées comme historique : le suivi accueil, l'exclusion dispatch et les tests Auth/Storage nominaux sont maintenant réalisés. Restent bloquants : sept rôles non automatisés, couverture des autres producteurs Admin SDK, inventaire exhaustif des données personnelles, interface et escalade support, régularisation validée des soldes/dettes et politique légale de conservation. Le parcours pharmacie utilise notamment currentUid ; le parcours restaurant relie restaurant_owners/{uid} à restaurantId. Ces liens nécessitent une validation des responsabilités, pas une simple substitution du nom de collection.

### Commandes futures uniquement, après levée des blocages

Ne pas exécuter de déploiement maintenant. Préparer une liste des fonctions existantes embarquant le garde ou dispatch.js avant de construire les commandes ciblées ; les trois nouveaux exports seuls ne suffisent pas. Sauvegarder les règles et configurations réellement actives. Conserver le traitement désactivé jusqu'à validation du déploiement coordonné. Ne jamais supprimer un tombstone pour revenir en arrière.

Android : après validation Flutter et essais sur appareil, `flutter build appbundle --release` avec la configuration de signature existante et un numéro de build nouveau. iOS : sur le Mac autorisé, après tests et validation des signatures, `flutter build ipa --release`. Ces commandes ne sont pas exécutées et ne publient pas à elles seules les applications. Aucune preuve d'exécution sur un ancien binaire Android/iOS n'est revendiquée.

Aucune opération de production exécutée. Ce document ne constitue pas une autorisation de déploiement.

## Implémentation présente

`accountDeletion.js` traite les clients et livreurs dont le document a pour identifiant l'UID Auth. Les autres rôles restent sur une demande manuelle, explicitement non terminée. Ne jamais utiliser un téléphone ou un identifiant de document fourni par le client comme preuve d'identité.

La configuration `operations_control/account_deletion` est fermée par défaut. Le traitement exige `enabled: true` et `inventoryVersion: 1`. Ces champs sont des garde-fous opérationnels, pas une preuve automatique que l'inventaire a été validé. Ne pas les activer maintenant.

États : pending, blocked, quarantined, cleanup_pending, completed. Une authentification récente est obligatoire pour autoriser la destruction. Une capacité aléatoire conservée localement permet uniquement de lire un état minimal après déconnexion. Une confirmation completed exige l'absence Auth vérifiée et la transaction d'anonymisation terminée.

Une mission, une référence active, un solde non nul ou ambigu, une opération non terminale, plusieurs rôles ou un historique trop volumineux imposent une revue. Aucun solde, remboursement ou montant n'est corrigé par cette fonctionnalité. Les demandes vérifiées sont réexaminées périodiquement ; reviewAfter indique une échéance opérationnelle de revue à 72 heures, pas un délai légal garanti. Aucun outil support dédié ni alerte d'escalade n'est encore implémenté.

## Limites empêchant une activation

- Les sept autres rôles nécessitent une correspondance serveur fiable entre UID, établissements, flotte et responsabilités. Par exemple createFleetOwner utilise add(), pas doc(uid).
- Une demande bloquée par une mission n'empêche pas encore de nouvelles missions : ajouter un garde distinct de la suspension générale dans tous les chemins de sélection et d'affectation, sans bloquer collecte, livraison ou règlement.
- La quarantaine de 15 minutes n'est pas à elle seule une preuve que tous les producteurs Admin SDK ou webhooks en vol ont terminé. Vérifier chacun et les durées maximales avant activation.
- Le garde commun aux callables ne couvre pas nécessairement les exports construits ailleurs, les triggers ni les accès directs non fondés sur isAuth. Inventaire de couverture à terminer.
- Firestore et Storage n'offrent pas une transaction atomique avec Auth. Les échecs restent en attente, sans confirmation de suppression complète.
- L'anonymisation utilise une liste explicite de champs et préfixes ; elle ne prouve pas l'effacement de toutes les copies personnelles, messages, preuves ou sauvegardes.
- Les données financières sont conservées sans recalcul. Durées, bases légales, purge différée, accès aux archives et traitement des preuves doivent être validés par le responsable compétent. Aucune durée légale n'est inventée ici.
- Les tests Auth et Storage utilisent des mocks. Reconnexion réelle sur Auth Emulator, règles Storage et parcours Android/iOS non validés.
- Le suivi après redémarrage de l'application nécessite encore un point d'entrée accessible sans session ; le reçu local existe mais l'écran de suivi est actuellement ouvert après la demande.
- Le blocage UID empêche la réutilisation de cet UID, pas une nouvelle inscription légitime avec un nouvel UID. Définir séparément les obligations applicables sans conserver arbitrairement des identifiants personnels.

## Tests réellement exécutés pendant cette intervention

- 17 tests dédiés avec Firestore Emulator et Auth/Storage simulés : réussis.
- 18 tests Flutter service/dialogue : réussis.
- 917 tests backend existants avec garde hors ligne : réussis.
- Analyse Flutter des quatre fichiers service/dialogue/tests : aucune anomalie avant la dernière modification d'affichage des détails.
- Suite générale Firestore supplémentaire : non exécutée, le contrôle automatique d'autorisation a échoué sur sa limite d'utilisation. Ne pas compter les résultats historiques comme validation de ces modifications.

## Procédure future, NON EXÉCUTÉE

1. Compléter les limites ci-dessus et valider l'inventaire par rôle, la procédure de régularisation et la conservation. Prévoir un support responsable des demandes en retard.
2. Exécuter les suites générales Rules/Storage/Auth sur émulateurs avec comptes fictifs et scénarios d'échec Firestore, Auth, Storage et redémarrage mobile.
3. Établir le manifeste ciblé à partir des dépendances réelles : requestAccountDeletionCF, getAccountDeletionStatusCF, retryAccountDeletions et tous les producteurs nécessitant un garde. Vérifier régions, runtime, comptes de service et droits minimaux ; ne pas faire de déploiement global implicite.
4. Après autorisation distincte, installer les protections et fonctions avec traitement désactivé ; valider les missions et paiements existants avant toute activation.
5. Publier les nouvelles applications Android/iOS après tests sur appareils. Les anciens binaires ne reçoivent pas ces corrections par simple déploiement backend.
6. Activer seulement après validation complète et autorisation explicite ; surveiller les états et demandes en retard. En cas d'incident, fermer le traitement sans supprimer les reçus ou tombstones. Une suppression Auth est irréversible : ne pas réactiver automatiquement un compte ni recréer son profil.
