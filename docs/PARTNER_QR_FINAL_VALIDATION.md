# Finalisation QR partenaires — rapport clôturé le 25 octobre 2026

Verdict : PARTIEL pour la mise en service. Implémentation locale préparée ; aucun déploiement, publication, commit ou changement de production.

## Corrections de cette reprise

- Android : intent filter HTTPS autoVerify limité à az-express-b0469.web.app/partenaire/ ; traitement Flutter natif des liens activé.
- iOS : Associated Domains et FlutterDeepLinkingEnabled ; AASA avec App ID provenant du projet Xcode local (F6XWK2W7XG.com.azexpress.app). Le profil de provisioning et l'App ID Prefix réellement signés restent à vérifier sur Mac.
- Hosting : fichiers .well-known inclus, type application/json et cache 5 minutes. Les autres routes sont conservées. La configuration d'exclusion continue à exclure .env et .git.
- assetlinks.json utilise le certificat SHA-256 de l'APK local web/downloads/az-express-latest.apk, vérifié avec apksigner : 950EF85E42C78E1C37E39390F4D0F78DBB97D2CF60124C7D20A85101419F1AC9. Ce certificat n'est PAS présenté comme le certificat App signing Google Play.
- Multi-établissements : collection technique partner_qr_managers/{UID}/establishments/{clé}, interdite aux SDK clients. Le super-admin peut attribuer/révoquer une permission QR depuis son écran QR ; les droits existants restent compatibles. Cette permission ne donne aucun accès aux commandes, profils privés ou wallets.
- Nouveau callable listPartnerQrEstablishments : retourne uniquement les établissements autorisés, nom, catégorie, ID et disponibilité. Sélection explicite avant téléchargement/partage. Nouveau callable setPartnerQrManager : super-admin uniquement. getPartnerQr relit les autorisations dans sa transaction ; une sélection passée ne suffit pas après révocation.
- Liste bornée : au-delà de 100 liaisons explicites ou 100 sessions pharmacie, erreur explicite, pas de liste silencieusement tronquée. Pas d'index composite ajouté.
- Réapprobations restaurant/pharmacie/boulangerie : transaction commune approvePartnerOnce. Un document existant n'est jamais réécrit ; liens, argent, statut et QR restent inchangés. Une demande historique approuvée sans liaison vérifiable, ou avec liaisons contradictoires, est bloquée plutôt que dupliquée. Le parcours vendeur possédait déjà son garde transactionnel et reste inchangé.
- Téléchargement Web : utilise la page /telecharger/ réellement présente dans web. L'interface précise qu'iPhone est en validation Apple. URL Apple communiquée par l'utilisateur : https://apps.apple.com/app/id6822464604 ; non proposée comme téléchargement confirmé tant que sa disponibilité n'est pas validée.

## Tests

- 958 tests backend réussis (dont 3 contrôles supplémentaires des fichiers de liens et configuration locale).
- 8 tests QR Firestore Emulator réussis : concurrence, registre fermé, multi-établissements, révocation, refus d'auto-attribution, compte supprimé et cibles Auth invalides (Auth simulé dans cette suite). 235 tests généraux Firestore réussis.
- Première tentative émulateur échouée au hook de connexion avant disponibilité du service ; relance après démarrage complet réussie.
- 67 tests Flutter ciblés réussis : QR, sélection, choix d'identité lors de réapprobation, approbations historiques vendeur/pharmacie, preuves et suppression des comptes.
- Analyse ciblée finale sans anomalie, y compris après ajout du texte informatif Apple.
- Une ultime relance Flutter après ce texte informatif n'a pas été exécutée : le contrôle automatique d'approbation a échoué à cause d'une limite d'utilisation. Les 67 succès précédents ne sont pas présentés comme une nouvelle exécution. Aucun contournement effectué.
- Compilation Flutter Web réussie ; les deux fichiers .well-known sont présents dans build/web. Avertissements WebAssembly préexistants dans flutter_tts, sans échec du build JavaScript. Ce build précède la dernière modification du texte informatif Apple.
- Une relance QR avec des données émulateur résiduelles avait compté 3 registres au lieu de 1. Le hook initialise désormais le projet fictif dédié par clearFirestore ; la relance finale réussit les 8 tests. Aucune base réelle n'est concernée.
- Les tests de décision de réapprobation Flutter ne sont pas une exécution du formulaire sur téléphone avec Firestore : ce parcours reste dans la matrice physique.

## Fichiers de la reprise

functions/partnerQr.js ; functions/index.js ; firestore.rules ; firebase.json ; android/app/src/main/AndroidManifest.xml ; ios/Runner/Info.plist ; ios/Runner/Runner.entitlements ; web/.well-known/assetlinks.json ; web/.well-known/apple-app-site-association ; lib/partner_qr/partner_qr_page.dart ; lib/widgets/partner_account_sheet.dart ; lib/services/partner_approval_service.dart ; lib/screens/admin/admin_{restaurant,pharmacie,boulangerie}_requests_page.dart ; functions/test/partnerQr.test.js ; functions/test/partnerQrLinks.test.js ; rules-tests/partner-qr.test.js ; test/services/partner_approval_service_test.dart ; test/partner_qr/partner_qr_test.dart ; rapports.

## Prérequis non prouvés localement

1. Fournir l'empreinte App signing Play Console ; l'ajouter sans supprimer celle de l'APK distribué si les deux canaux sont utilisés. Ne jamais substituer une empreinte d'upload à celle de signature distribuée.
2. Vérifier les droits Associated Domains, Team/App ID Prefix et profil de provisioning sur le Mac de signature. Aucun build iOS n'est prétendu réalisé sur Windows.
3. Tester les anciennes demandes approuvées ambiguës sans créer de nouvel établissement : rapprochement administratif explicite si lien absent. Aucune recherche par téléphone ni correction de production automatique.
4. Les anciennes applications admin peuvent encore contenir l'ancien formulaire non idempotent. Utiliser la nouvelle version pour les approbations ; aucune règle n'empêche globalement un administrateur habilité de créer un autre document.
5. La relation ajoutée gère plusieurs QR, pas plusieurs comptes financiers. L'extension éventuelle de gestion des commandes multi-établissements est hors de ce périmètre.
6. Aucun essai réel de liens OS, WhatsApp, export Fichiers, impression ou ancienne application n'a été effectué.

## Procédure Android — NON EXÉCUTÉE

Dans un environnement de validation dédié et avec comptes fictifs :

1. Installer un APK signé avec le certificat déclaré. Tester aussi la version distribuée par Play avec son certificat lorsqu'il est connu.
2. Après publication autorisée des associations, consulter `adb shell pm get-app-links com.azexpress.app` ; exiger le domaine vérifié. Pour relancer la vérification sur un appareil de test : `adb shell pm verify-app-links --re-verify com.azexpress.app`.
3. Depuis une application externe, ouvrir une vraie URL QR par `adb shell am start -W -a android.intent.action.VIEW -d "https://az-express-b0469.web.app/partenaire/TOKEN_DE_TEST"`. Ne pas forcer le package : cela masquerait un défaut d'association.
4. Vérifier application arrêtée, déjà ouverte, déconnectée, réseau coupé ; seule la fiche publique doit apparaître, jamais une confirmation de commande.
5. Désinstaller l'application sur l'appareil fictif, ouvrir le lien : fiche Web puis page de téléchargement Android. Vérifier les données publiques et le message d'indisponibilité.

## Procédure iPhone/iPad — NON EXÉCUTÉE

1. Sur Mac, vérifier le profil signé et les Associated Domains ; produire une version de test après autorisation, sans toucher aux comptes existants.
2. Installer sur appareil physique, ouvrir le lien depuis Notes/Messages ou un QR imprimé (pas uniquement en le tapant dans Safari). Vérifier démarrage à froid et à chaud.
3. Sans application installée : fiche Web ; afficher l'attente Apple tant que l'URL id6822464604 n'est pas publiquement disponible. L'ouverture universelle dépend du cache Apple/AASA : réinstaller uniquement la version de test si nécessaire.
4. Vérifier export PNG, marge lisible à l'impression, partage natif, WhatsApp présent/absent et partage iPad. Aucun message ne doit annoncer un envoi réussi sans confirmation du système.

## Matrice métier commune

- Deux établissements autorisés et un établissement tiers : liste correcte, QR distincts, refus de la demande directe pour le tiers.
- Révocation après ouverture de la liste : getPartnerQr doit refuser. Suspension/suppression : résolution publique indisponible.
- Revalidation du même dossier : même ID et même QR, aucun nouveau document ni changement de stock/wallet. Double clic depuis deux appareils : transaction sans doublon.
- Téléphone du partenaire modifié : QR inchangé. Ancien établissement sans registre : initialisation autorisée sans mutation du profil.
- Scanner le QR public pendant une livraison : fiche d'identification seulement ; le PIN/QR de commande reste obligatoire et les montants restent inchangés.

## Ordre recommandé — aucune commande exécutée

1. Valider signatures et identités ci-dessus ; préparer une source de release isolée pour éviter d'embarquer les développements non validés de suppression des comptes et autres modules partagés.
2. Autorisation distincte avant toute opération réelle. Déployer les règles validées, puis les 8 fonctions QR seulement : getPartnerQr, resolvePartnerQr, listPartnerQrEstablishments, setPartnerQrManager, syncPartnerQr_restaurant, syncPartnerQr_seller, syncPartnerQr_pharmacie, syncPartnerQr_boulangerie. Préserver les options runtime approuvées ; ne pas déployer toutes les fonctions du projet.
3. Publier le Web et .well-known après compilation et configuration Firebase validées. Vérifier HTTPS 200 sans redirection, JSON (pas index.html), Content-Type application/json, certificat et contenu exacts des deux fichiers publics.
4. Installer les nouvelles versions de validation Android/iOS et exécuter la matrice. Mettre à jour les applications admin avant les réapprobations.
5. Publication publique et activation des permissions QR seulement après résultats réels et nouvelle autorisation. Initialisation des établissements existants au premier accès ; pas de migration globale.
6. En cas d'anomalie : suspendre la distribution de la nouvelle version ou révoquer uniquement les nouvelles permissions QR après autorisation. Ne supprimer ni registres ni établissements : cela casserait les QR imprimés. Ne toucher ni aux paiements ni aux preuves de livraison.
