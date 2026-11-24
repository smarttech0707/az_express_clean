# Suppression partenaires — implémentation locale du 24 octobre 2026

## État courant

Le moteur `partnerAccountDeletion.js` est implémenté et les scénarios nominaux Auth/Firestore/Storage sont exécutés sur émulateurs pour les neuf rôles. Il remplace le refus inconditionnel des partenaires uniquement lorsque la configuration locale/test comprend `enabled:true`, `inventoryVersion:1`, `partnerInventoryVersion:1`. Aucune configuration de production n'a été écrite. Ces indicateurs ne doivent pas être activés en production sur la seule base de ces tests.

Le nouveau moteur exige un consentement explicite `allProfilesConsent:true` avec authentification récente. Le texte Flutter explique que tous les profils personnels liés à l'UID sont concernés. Les anciennes demandes sans ce consentement restent en attente. La liste des profils est figée au début de la quarantaine et comparée avant finalisation ; un changement bloque le traitement.

## Traitement réalisé

- Identité par UID pour client, livreur, vendeur, boulangerie, Ekbine, immobilier et flotte. Restaurant : lien administratif vers établissement. Pharmacie : liaison permanente par nomination super-admin puis consentement personnel, jamais currentUid seul.
- Inspection transactionnelle de tous les profils liés, des soldes connus, commandes, retraits, transactions, annonces et responsabilités. Statut inconnu, dette, solde non nul, référence de mission, historique dépassant la limite, annonce active ou flotte avec livreurs : blocage explicite, support et nouvelle tentative. Aucun calcul financier n'est changé.
- Flag serveur deletionRequested sur les profils en attente. Pour restaurant/pharmacie, fermeture des nouvelles activités de l'établissement seulement si aucun autre responsable actif ne subsiste. L'établissement lui-même n'est jamais supprimé ou anonymisé par ce moteur.
- Quarantaine, désactivation/révocation/suppression Auth et vérification user-not-found, nettoyage Storage UID, anonymisation des champs personnels connus, conservation des montants. Reprise après Auth/Storage indisponible ; aucun completed prématuré.
- Les producteurs boutique cash/wallet et AZ IA restaurant/pharmacie/marketplace/livraison/Ekbine contrôlent les demandes avant les mutations concernées. L'éligibilité Ekbine exclut les comptes en suppression. Les règles de création orders vérifient les contreparties ; les champs de suspension sont protégés dans les profils concernés. Publication/republication Marketplace refusée pour un vendeur en suppression.

Les logos et catalogues d'établissement, les preuves et données financières ne sont pas assimilés à des photos personnelles. Les préfixes supprimés sont explicités dans accountPersonalAssets.js. Il n'y a aucune purge globale ni suppression de commande.

## Validation exécutée

- 942/942 tests backend, zéro échec.
- 36/36 tests Firestore ciblés de suppression réussis, avec Auth/Storage simulés pour les injections de panne.
- 12/12 tests avec Auth/Firestore/Storage Emulator réels : deux suppressions historiques client/livreur, sept suppressions partenaires, consentement pharmacie et deux scénarios de mission/solde bloquants. Le cas Ekbine inclut un profil client sur le même UID ; restaurant/pharmacie incluent un autre responsable et vérifient l'établissement inchangé. Les photos des préfixes personnels partenaires connus sont effectivement créées puis supprimées dans Storage Emulator.
- 235/235 tests généraux Firestore réussis.
- 18/18 tests Flutter existants, analyse ciblée sans anomalie.
- Les pannes Auth/Storage et reprises sont injectées dans la suite Firestore ciblée : ce ne sont pas des pannes réelles des services Firebase.

## Limites bloquant encore l'activation générale

1. La migration des pharmacies historiques vers un compte Auth personnel et sa navigation mobile complète ne sont pas validées sur Android/iOS ; aucune liaison de production n'a été créée.
2. Le contrôle des producteurs couvre les chemins nommés ci-dessus, pas une preuve exhaustive de tous les producteurs Admin SDK et reprises historiques. Une version ancienne non mise à jour pourrait encore créer un engagement après le flag. Le délai de quarantaine ne remplace pas cette couverture.
3. La séparation physique des pièces comptables, la protection de tous les champs financiers conservés dans les anciens profils, les copies de messages/dossiers d'inscription et les durées de conservation ne sont pas entièrement implémentées. Les champs anonymisés et préfixes connus ne constituent pas une garantie d'effacement universel. Décisions de conservation légale encore nécessaires, sans délai inventé.
4. Les établissements partagés restent bloqués si le solde de l'établissement est non nul, même si un autre responsable subsiste : aucun transfert de dette ou de responsabilité n'est inféré. La reprise suit une régularisation métier existante ; aucun bouton support ne force la suppression.
5. Les stocks/annonces et affectations de flotte doivent être régularisés ou transférés par les parcours habilités avant suppression. L'escalade humaine reste à organiser ; la file support ne garantit pas à elle seule un délai de résolution.

Verdict : PARTIEL pour l'activation. Les neuf scénarios nominaux sont implémentés/testés localement ; cela n'équivaut pas à une validation de tous les comptes historiques ni à une autorisation de déploiement.

## Fichiers de cette reprise

Nouveaux : functions/accountDeletionScope.js, functions/partnerAccountDeletion.js, functions/accountAdmission.js, functions/accountPersonalAssets.js, functions/test/accountAdmission.test.js, ce rapport.

Adaptés : functions/accountDeletion.js, functions/index.js, functions/orderActions.js, functions/ekbineFlow.js, functions/marketplacePublishing.js, functions/azia/tools/{restaurants,pharmacies,marketplace,delivery,ekbine}.js, firestore.rules, lib/services/account_deletion_service.dart, lib/widgets/account_deletion_dialog.dart, rules-tests/account-deletion.test.js, rules-tests/account-deletion-real.test.js, les rapports de statut.

## Avant tests physiques et publication

Conserver les indicateurs désactivés. Finir les limites ci-dessus, établir le manifeste des fonctions embarquant les modules modifiés et préserver leurs configurations vérifiées. Tester sur un environnement dédié les anciennes applications, les comptes multirôles, la liaison pharmacie, les pertes réseau et les reprises après redémarrage. Ensuite seulement, demander l'autorisation distincte de déploiement ciblé et de publication Android/iOS. Ne jamais supprimer les reçus/tombstones ni recréer automatiquement un UID supprimé en guise de rollback.
