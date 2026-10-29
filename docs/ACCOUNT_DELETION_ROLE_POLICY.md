# Suppression : identités, support et conservation — proposition locale

État du 24 octobre : le moteur partenaires/multirôles est désormais implémenté et ses neuf scénarios nominaux vérifiés sur émulateurs. Voir ACCOUNT_DELETION_PARTNER_IMPLEMENTATION.md pour les résultats courants et les limites restantes ; les refus inconditionnels décrits ci-dessous correspondent aux reprises antérieures. Aucune activation de production effectuée.

## Reprise : politique partenaires validée, liaison pharmacie implémentée

La politique métier de l'utilisateur est désormais validée. Les limites ci-dessous sont du travail technique restant, pas une demande de nouvelle autorisation métier.

La liaison permanente pharmacie est maintenant implémentée dans pharmacyOwnerIdentity.js : nomination super-admin avec authentification récente, vérification du compte Auth personnel, invitation limitée à 24 heures (durée technique, pas durée de conservation légale), inspection puis acceptation par le destinataire récemment authentifié. pharmacy_owners/{uid} est immuable par les clients et ne dépend pas de currentUid. Les comptes en suppression ne peuvent pas être liés. Plusieurs responsables peuvent avoir des liens distincts vers le même établissement. Aucun wallet, credential métier ou établissement n'est supprimé par cette opération.

managePharmacyOwnerIdentityCF est un nouvel export local. La nomination est accessible dans la page super-admin de suppression. Le dialogue pharmacie propose l'inspection et l'acceptation de l'invitation ; une session personnelle non anonyme est nécessaire. Le parcours historique pharmacie utilisant une session anonyme doit encore permettre de se connecter à ce compte personnel : cette migration mobile n'est pas finalisée.

Les demandes pharmacie dont la liaison est établie utilisent désormais requestAccountDeletionCF. Elles restent bloquées par role_obligations_review_required : la destruction partenaire n'a PAS été implémentée dans cette reprise. Les passages historiques de ce document affirmant qu'aucune liaison permanente n'existe sont remplacés par ce complément.

Tests exécutés : 937/937 backend ; 28/28 Firestore Emulator dont quatre scénarios de liaison pharmacie ; 5/5 avec Auth/Firestore/Storage Emulator réels, incluant nomination et consentement pharmacie (pas destruction pharmacie) et les suppressions client/livreur ; 18/18 Flutter existants ; analyse ciblée de trois fichiers Flutter sans anomalie. Les nouvelles interactions de nomination/acceptation n'ont pas été testées sur appareils physiques.

Fichiers de cette reprise : functions/pharmacyOwnerIdentity.js (nouveau), functions/accountDeletionIdentity.js, functions/index.js, firestore.rules, lib/services/account_deletion_service.dart, lib/screens/admin/account_deletion_support_page.dart, lib/widgets/account_deletion_dialog.dart, rules-tests/account-deletion.test.js, rules-tests/account-deletion-real.test.js et les deux rapports.

Restent non réalisés : admission bloquée dans tous les producteurs partenaires, résolution des obligations de chaque rôle, destruction/anonymisation multirôle, retrait d'un responsable sans suppression de l'établissement et tests de suppression réelle des sept rôles partenaires. Le refus conservateur actuel évite la destruction erronée ; il ne satisfait pas la finalisation demandée. Verdict PARTIEL, activation toujours interdite sans validation ultérieure.

Statut : PARTIEL. Aucun déploiement autorisé par ce document. Ne pas activer le traitement global en l'état.

## Correspondances et obligations

| Rôle | Preuve d'identité locale utilisée | Ce qui manque avant destruction |
|---|---|---|
| Client | clients/{UID}, session non anonyme et récente | Inventaire complet des copies personnelles et producteurs en vol |
| Livreur | livreurs/{UID}, session non anonyme et récente | Même inventaire, couverture de tous les producteurs d'affectation |
| Vendeur | sellers/{UID} | Commandes boutique, stocks détenus, crédits vendeur, remboursements et abonnements |
| Restaurant | restaurant_owners/{UID}, lien restaurantId écrit par administrateur, restaurant existant | Commandes/préparation, obligations de l'établissement et autres exploitants |
| Pharmacie | Aucune identité permanente démontrée par currentUid | currentUid est une session remplaçable ; ne jamais supprimer son Auth sur ce seul indice. Définir une liaison de propriétaire durable et traiter les credentials privés |
| Boulangerie | boulangeries/{UID} | Commandes programmées/personnalisées, acomptes, stocks, remboursements |
| Agent Ekbine | ekbine_agents/{UID} | walletBalance, dépôts, retraits et profil client partageant l'UID |
| Agent immobilier | real_estate_agents/{UID} | Mandats, annonces, engagements contractuels et éventuels collaborateurs |
| Flotte | fleet_owners/{UID} uniquement | Responsabilités des livreurs ownerId, dettes, abonnements. Les anciens documents à ID aléatoire ne sont pas associés par téléphone |

La correspondance d'identité ne prouve pas l'absence d'obligations. Les six nouveaux parcours authentifiés enregistrent le profil exact et le lien restaurant éventuel, puis restent bloqués avec role_obligations_review_required. Ils ne suppriment pas Auth. Les demandes anonymes/pharmacies restent dans account_deletion_requests et ne constituent jamais un consentement de destruction.

## Support disponible

Entrée super-admin : « Suppressions de comptes » dans admin_dashboard. Endpoint manageAccountDeletionCF, contrôle serveur super-admin actif. Files authentifiée/manuelle distinctes, pages de 25, prise en charge, échéance de revue et réexamen. Les actions sont enregistrées sous support_events. Le service n'expose pas les capacités recoveryHash dans la liste.

« Réexaminer » relance les contrôles existants après régularisation via les procédures métier ordinaires. Aucun bouton ne force completed, ne change l'identité, le consentement, un wallet ou une dette. Une demande manuelle ne peut pas être convertie automatiquement en destruction. Un résultat d'appel sans erreur ne signifie pas que le compte est supprimé : la page recharge l'état serveur.

La revue suivante à 24 heures est une échéance interne de suivi, pas un délai légal. L'interface indique le retard ; aucune notification externe ou garantie de prise en charge humaine n'est implémentée. Un responsable opérationnel doit être désigné. L'escalade au-delà de cette file reste à organiser.

## Inventaire actuellement implémenté (client/livreur seulement)

| Données | Action actuelle | Motif technique / décision restante |
|---|---|---|
| Utilisateur Firebase Authentication | Désactivation, révocation, suppression, vérification user-not-found | Retirer l'accès ; reprise idempotente |
| Photos client, photos livreur, pièces et selfies d'inscription dans les préfixes UID connus | Suppression Storage | Données personnelles sans réutilisation opérationnelle prévue ; inventaire des autres chemins à compléter |
| Notifications sous profil et driver_requests/{UID} | Suppression | Messages et dossier d'inscription du profil traité |
| Nom, téléphone, email, adresse, position, tokens, identifiants personnels listés dans accountDeletion.js | Suppression des champs ; profil conservé inactif | Ne pas supprimer les soldes et références financières |
| Contacts et coordonnées de commandes dans les champs explicitement listés | Suppression des champs | Réduire les données personnelles ; vérifier les copies non couvertes avant activation |
| Wallets, montants, commissions, transactions, références comptables | Conservation sans recalcul | Réconciliation, obligations et litiges potentiels ; base et durée légales à valider, non présumées |
| Preuves de livraison, messages, documents non inventoriés, sauvegardes | Pas de suppression globale | Éviter perte de preuve ou de données tierces ; classification et décision de conservation nécessaires |
| Tombstones UID, reçus, journal support | Conservation technique actuelle | Éviter réactivation et permettre reprise/audit ; durée et accès à valider |

Cette liste n'est pas une attestation de conformité légale. Aucun délai légal n'est codé. La limitation de conservation exige encore une politique approuvée, une purge différée vérifiable et une procédure pour les litiges. Ne pas déclarer que toutes les données personnelles sont effacées.

## Producteurs Admin SDK

Le garde existant des callables vérifie le tombstone de l'appelant ; il ne suffit pas pour un administrateur agissant sur un autre UID. Des protections ciblées ont été ajoutées au reset par téléphone, au reset administrateur vendeur/boulangerie et au login pharmacie pour refuser les profils isDeleted.

La création administrateur vendeur/boulangerie utilise un nouvel UID Auth et create() sur le profil, sans écrasement. Cela ne constitue pas une restauration du même UID. Une interdiction de réinscription de la même personne nécessiterait une autre politique et ne doit pas être déduite ici.

Il reste à prouver la couverture de tous les producteurs Admin SDK, des réinitialisations historiques et des écritures financières tardives. Les garde-fous ciblés ajoutés ne constituent pas une garantie globale de non-réactivation.

## Validation de cette reprise

- Backend complet : 937 réussis, zéro échec ; inclut 14 tests identité/support et 3 tests supplémentaires de refus de récupération d'un profil supprimé.
- Firestore Emulator : 24 réussis, zéro échec ; six demandes partenaires bloquées sans mutation Auth/finance, pagination/prise en charge/réexamen support et audit protégé.
- Analyse Flutter : aucune anomalie sur page support, dashboard admin et service.
- Les tests Auth/Storage réels de la reprise précédente ne sont pas une validation de suppression des sept rôles restants.

Fichiers de cette reprise : functions/accountDeletionIdentity.js, functions/accountDeletionSupport.js, functions/accountDeletion.js, functions/index.js, functions/passwordReset.js, functions/adminPartnerAccounts.js, functions/test/accountDeletionSupport.test.js, functions/test/passwordReset.test.js, functions/test/adminPartnerAccounts.test.js, rules-tests/account-deletion.test.js, lib/screens/admin/account_deletion_support_page.dart, lib/screens/admin/admin_dashboard.dart, lib/services/account_deletion_service.dart, ce document et ACCOUNT_DELETION_LOCAL_STATUS.md.
