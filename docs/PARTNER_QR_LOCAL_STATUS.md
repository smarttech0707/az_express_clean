# QR publics partenaires — état local, 24 octobre 2026

Complément de finalisation : voir `PARTNER_QR_FINAL_VALIDATION.md` pour les liens profonds préparés, les autorisations multi-établissements et les réapprobations transactionnelles. Le détail ci-dessous conserve l'état de la première reprise.

Verdict : PARTIEL. Aucun déploiement, aucune écriture de production, aucun commit.

## Implémentation

Réutilisation de qr_flutter, share_plus, path_provider, mobile_scanner et url_launcher déjà présents. Aucun ajout de dépendance. Les preuves QR/PIN/SMS restent distinctes.

Quatre collections prises en charge : restaurants, sellers, pharmacies, boulangeries. Leurs documents d'établissement sont créés par l'administration dans les parcours examinés. Les états pending/rejected/suspended/deleted, isActive=false, isSuspended/isDeleted/deletionRequested=true rendent la fiche indisponible. La présence d'un document historique sans ces indicateurs est traitée comme celle d'un établissement administrativement créé ; les données historiques devront être vérifiées avant activation.

Les quatre triggers syncPartnerQr_{restaurant,seller,pharmacie,boulangerie} créent le registre lors de la création d'un établissement disponible ou du passage indisponible → disponible. Ils relisent le document dans une transaction, sans faire confiance à l'ordre de livraison des événements. Les événements de wallet/statut de garde sans changement de disponibilité ne relisent pas le registre. Aucun déclenchement récursif sur le registre.

Registre serveur : partner_qr/{SHA256(type + séparateur + identifiant établissement)}, avec correspondance inverse partner_qr_tokens/{UUID}. Les deux documents sont créés atomiquement. Ils ne contiennent ni secret ni argent. Aucun champ ni QR n'est ajouté aux profils propriétaires ou aux transactions. Le téléphone n'intervient jamais dans l'identité du QR. Les clients ne peuvent lire, créer, modifier ou supprimer ces documents, même avec une session admin.

getPartnerQr vérifie le super-admin ou le lien de gestion existant. Restaurant : restaurant_owners ; pharmacie : liaison personnelle permanente ou currentUid déjà établi par le serveur ; boutique/boulangerie : UID égal au document, conformément au modèle existant. Les comptes marqués supprimés par tombstone sont refusés. Les anciens établissements sont initialisés au premier appel autorisé, sans scan global ni mutation financière.

resolvePartnerQr est public et ne retourne que disponibilité, catégorie et nom public, jamais le document complet, téléphone, GPS, wallet, identifiants de propriétaires ou secrets. La source est relue pour chaque résolution ; une suppression/suspension ne dépend pas d'une projection publique potentiellement obsolète.

Route créée : https://az-express-b0469.web.app/partenaire/{token}. Elle utilise la réécriture Hosting existante vers index.html. Cette route n'est pas encore publiée. Le routeur mobile comprend aussi /partenaire/{token}, mais les associations Android App Links/iOS Universal Links ne sont pas configurées par cette reprise.

Entrée « Mon QR code » dans la feuille de compte des quatre dashboards. PNG 1152 × 1152, fond blanc et marge ; partage natif, téléchargement navigateur ou sauvegarde dans les documents de l'application mobile. Sur mobile, Partager permet d'exporter vers les applications proposées par le système, éventuellement WhatsApp : aucune preuve d'envoi WhatsApp n'est annoncée.

Le super-admin peut retrouver un QR via « QR des etablissements », avec catégorie et identifiant. Le scanner de preuve reconnaît exclusivement les URLs publiques canoniques et ouvre la fiche sans retourner de credential de livraison. Au retour, il indique que le code de commande reste obligatoire. Les endpoints financiers et de confirmation ne sont pas modifiés.

## Fichiers

- functions/partnerQr.js ; functions/index.js.
- firestore.rules : registre serveur interdit aux SDK clients et indicateurs de suspension/activation protégés pour sellers/boulangeries.
- lib/partner_qr/{partner_qr_page,partner_qr_link,save_qr,save_qr_native,save_qr_web}.dart.
- lib/widgets/partner_account_sheet.dart ; quatre dashboards restaurant/seller/pharmacie/boulangerie ; admin_dashboard.dart.
- lib/main.dart ; lib/web/web_router.dart ; lib/delivery_proofs/proof_scanner_page.dart.
- functions/test/partnerQr.test.js ; rules-tests/partner-qr.test.js ; test/partner_qr/partner_qr_test.dart.

## Validation réellement exécutée

- Backend complet : 955 réussis, aucun échec, dont 7 QR ciblés.
- Firestore Emulator : 5 QR ciblés réussis, dont trois initialisations concurrentes et interdictions SDK client ; 235 tests généraux réussis.
- Flutter : 5 tests QR réussis (URL canonique, PNG réel/dimensions, fiche publique, suspension, erreur réseau) ; 19 tests de suppression de comptes réussis ; 12 tests QR/PIN/SMS existants réussis.
- Analyse des écrans modifiés sans anomalie après correction des avertissements ; analyse finale scanner/QR/tests sans anomalie.
- Aucun essai physique Android/iOS, aucune preuve de partage WhatsApp ou de téléchargement navigateur réel.
- Compilation `flutter build web --debug --no-pub` réussie. Le diagnostic WebAssembly signale des incompatibilités dans la dépendance existante flutter_tts ; le build Web JavaScript a abouti. Aucune publication du build.

## Limites et travail restant

1. Autres catégories de prestataires non activées : leurs preuves d'approbation et de gestion doivent être définies à partir de leurs modèles. Ne pas déduire une autorisation du téléphone ou d'un rôle déclaré.
2. Le registre distingue tous les documents d'établissements. En revanche, le modèle actuel seller/boulangerie utilise un document par UID, et restaurant_owners un seul restaurantId. La gestion de plusieurs établissements par un même UID n'est donc pas entièrement réalisable avec ces modèles. Une relation de gestion multiple côté serveur est nécessaire ; aucune migration implicite n'est faite.
3. Réapprobation : idempotence prouvée pour un même document d'établissement. Les formulaires historiques restaurant/pharmacie peuvent créer un nouvel auto-ID lorsqu'une demande est approuvée à nouveau ; cela constitue un autre établissement pour le registre. La déduplication de ces approbations historiques reste à sécuriser avant une garantie métier complète.
4. Fiche publique minimale nom/catégorie ; pas encore de lien vers un catalogue spécifique ni de commande depuis la fiche. Le lien /connexion existant donne accès au Web. Les liens stores trouvés dans le site sont génériques : ne pas prétendre qu'ils installent AZ Express.
5. App Links/Universal Links : domaines, certificats Android et Team ID iOS à vérifier avant d'ajouter assetlinks.json/apple-app-site-association. Aucune empreinte inventée. L'ouverture dans l'application installée n'est pas démontrée.
6. PNG/partage/impression : tester sauvegarde sur Android, export Fichiers et partage sur iPhone/iPad, WhatsApp installé/absent, navigateur sans support partage et lecture du QR imprimé. Le fichier PNG contient le QR ; le nom est affiché dans l'écran, pas composé dans une affiche d'impression.
7. Coûts : initialisation typique 2 lectures/2 créations hors contrôles d'autorisation ; résolution publique 2 lectures (1 pour token inexistant). Pas de listener, index composite ou scheduler nouveau. maxInstances limite la concurrence, pas le nombre total de requêtes : supervision/quotas des appels publics à valider.

## Préparation au déploiement — NON EXÉCUTÉE

Fermer les limites essentielles, comparer les options runtime avec la production, tester les anciennes mises à jour partenaires face aux indicateurs désormais protégés. Préserver les modifications de suppression des comptes et les autres travaux non déployés : ne pas déployer globalement ce workspace.

Après autorisation seulement : règles Firestore validées ; déploiement ciblé des six nouveaux exports getPartnerQr, resolvePartnerQr et syncPartnerQr_* ; publication Hosting du build Web configuré avec les paramètres Firebase validés ; nouvelles versions Android/iOS après essais internes et configuration des liens profonds. Aucun backfill destructif ; initialisation unitaire autorisée au premier affichage. Les registres doivent être préservés lors de tout retour arrière pour garder les QR imprimés stables.

La compilation locale ne prouve ni la disponibilité des routes en production, ni une configuration Firebase Web correcte, ni la compatibilité des anciens binaires.
