# Distribution directe Android — AZ Express

**Mise à jour :** la publication Hosting a été autorisée et effectuée le 12 octobre 2026. Voir [le rapport de publication et les contrôles publics](DISTRIBUTION_PUBLICATION_REPORT.md). Les sections de préparation ci-dessous décrivent l'état avant autorisation ; la page publique est désormais active. La vérification de taille tient compte de la compression CDN via Content-Range, et les liens légaux utilisent les routes Flutter `/#/...`.

## État préparé — publication en attente de confirmation

La page publique et les codes QR pointent vers :

`https://az-express-b0469.web.app/telecharger`

Le manifeste local `web/distribution/latest.json` porte `published: true` pour la prochaine publication. Cela ne signifie pas que le site public a été déployé. L’APK original `build/app/outputs/flutter-apk/app-release.apk` est conservé et copié à l’identique dans `web/downloads/az-express-latest.apk`, puis dans `build/web/downloads/az-express-latest.apk` lors du build. Le bouton est activé uniquement après contrôle HTTP du fichier. La page précise que cet APK est réservé aux nouvelles installations et ne peut pas mettre à jour une installation Google Play.

L’AAB `1.0.10+11` reste réservé à Google Play et n’est pas inclus dans Hosting. Le code métier Flutter et les versions existantes ne sont pas modifiés par cette préparation.

Pour la version auditée : `1.0.9` (code 10), package `com.azexpress.app`, Android 7.0/API 24 minimum, 82 330 271 octets (environ 78,5 Mio). Le SHA-256 du fichier APK est distinct de celui du certificat signataire ; les deux empreintes sont consignées dans le manifeste.

## Publication initiale (après autorisation)

1. Distribuer cet APK aux nouveaux utilisateurs Android. Les installations Google Play doivent être mises à jour via Google Play, dont la signature est différente ; ne pas conseiller une désinstallation.
2. Vérifier le nouvel APK release : package, version, signature `apksigner verify`, SHA-256 du fichier, et installation/mise à niveau sur un téléphone de test. Garder Play Protect actif.
3. Créer `web/downloads/`, copier l’APK validé vers `web/downloads/az-express-latest.apk`, puis recalculer le hash et la taille du fichier copié. Les valeurs doivent être identiques à l’APK source.
4. Mettre à jour `web/distribution/latest.json` avec les métadonnées vérifiées et passer `published` à `true`. Conserver l’URL stable `https://az-express-b0469.web.app/downloads/az-express-latest.apk`.
5. Construire le site : `flutter build web --release --dart-define-from-file=.env`. Ce paramètre conserve la configuration Firebase nécessaire au fonctionnement du Web. Ne jamais copier `.env` dans Hosting. Après chaque build, exécuter `py scripts/verify_distribution.py` ; ce contrôle vérifie les copies et génère `docs/DISTRIBUTION_HOSTING_FILES.md`, l’inventaire exact avec tailles et SHA-256.
6. Tester localement `/telecharger`, le manifeste et les en-têtes du fichier, puis seulement après validation explicite déployer Hosting :

   `firebase deploy --only hosting --project az-express-b0469`

7. Après déploiement autorisé, vérifier depuis un réseau externe la page, le JSON, `HEAD` de l’APK (type MIME et taille), le téléchargement complet, le SHA-256 après téléchargement, l’installation et le lancement sur téléphone réel. Tant que ce test n’est pas passé, remettre `published` à `false`.

Le fichier porte des en-têtes `Content-Type: application/vnd.android.package-archive`, `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff` et un cache court (5 minutes). Le manifeste est non mis en cache. Le bouton n’est activé que si `published` est vrai, l’URL est HTTPS et de même origine, et une requête HEAD confirme le type et la taille annoncés.

## Mise à jour d’une version ultérieure

1. Générer et vérifier le nouvel APK, son certificat, son package ID, son `versionName`, son `versionCode`, son SHA-256 et sa taille.
2. Pour une mise à jour du canal direct, conserver sa signature et augmenter le `versionCode` par rapport aux versions directes déjà distribuées. Le canal Google Play reste distinct. Ne pas remplacer l’APK par une signature différente sans avoir vérifié le certificat d’application réellement utilisé sur les appareils existants.
3. Remplacer `web/downloads/az-express-latest.apk`, mettre à jour `web/distribution/latest.json` et ses notes de version vérifiées.
4. Garder le même QR, la même page et la même URL du fichier. Construire et tester le Web avant le déploiement Hosting autorisé.
5. Vérifier sur un appareil une mise à jour par-dessus l’application installée. Ne jamais demander de désinstallation automatique. Si Android indique un conflit de signature, arrêter la mise à jour et résoudre la provenance de la clé avant toute instruction aux utilisateurs.

## QR et affiche

Les SVG/PNG dans `web/distribution/qr/` encodent tous l’URL stable de la page, jamais une URL APK. Le QR sans logo est le choix recommandé pour les impressions. La variante avec logo utilise la correction d’erreur maximale et doit malgré tout être testée à l’impression réelle. L’affiche porte actuellement « Bientôt disponible sur Android » : ne la remplacer par « Disponible sur Android » et ne pas la distribuer avant le téléchargement public testé.

## Limites de signature et Android

Un APK installable par-dessus une installation existante doit conserver le même package et une signature compatible, et utiliser un `versionCode` supérieur. Dans Play App Signing, l’APK/AAB local est généralement signé par la clé d’importation, tandis que Google signe l’application distribuée avec la clé de signature de l’application. Si ces certificats diffèrent, l’APK direct signé avec la clé d’importation ne peut pas mettre à jour l’installation Play signée par Google. Une signature différente produit un conflit de mise à jour ; ne pas conseiller une désinstallation automatique, qui peut supprimer les données locales.

Android 8+ peut demander d’autoriser l’installation pour la source précise (navigateur ou gestionnaire de fichiers). Expliquer la procédure sans désactiver Play Protect ni contourner les avertissements. Les paramètres varient selon le fabricant.

## Choix d’hébergement et coûts indicatifs

Firebase Hosting est retenu : le fichier (82,3 MB décimaux / 78,5 Mio) reste très inférieur à la limite documentée de 2 GB par fichier, l’URL HTTPS est stable, et aucun bucket Storage ne doit être rendu public. L’APK est un seul objet statique et le CDN Hosting le distribue. Le projet doit disposer d’une facturation adaptée si le trafic dépasse le quota sans frais ; le quota Hosting est partagé par le projet avec le reste du site.

Estimation de bande passante par mois, basée sur 82 330 271 octets par téléchargement, quota sans frais de 10 GB/mois, puis tarif Hosting publié de 0,15 USD/GB ; trafic existant du site, taxes, éventuelles reprises de téléchargement et rétention des releases exclus :

| Téléchargements APK | Transfert brut estimé | Coût estimé après quota de 10 GB |
|---:|---:|---:|
| 100 | 8,23 GB | 0 USD |
| 1 000 | 82,33 GB | 10,85 USD |
| 10 000 | 823,30 GB | 122,00 USD |

Au plan sans frais, le service peut être suspendu après le quota mensuel. Sur Blaze, configurer des alertes de budget et surveiller le transfert Hosting dans la Console Firebase. Ces montants sont des estimations à partir du tarif publié, pas une garantie de facture.

Références tarifaires officielles consultées le 12 octobre 2026 :

- [Quotas et tarifs Firebase Hosting](https://firebase.google.com/docs/hosting/usage-quotas-pricing) — 2 GB maximum par fichier, 10 GB de stockage et 10 GB/mois de transfert sans frais, 0,15 USD/GB de transfert additionnel.
- [Tarifs Firebase](https://firebase.google.com/pricing).

## Contrôles de test après déploiement

- Ouvrir `/telecharger` sur mobile et ordinateur.
- Vérifier les liens `/confidentialite` et `/delete-account`.
- Vérifier que le QR scanne vers `/telecharger`, pas vers l’APK.
- Quand `published` est `false`, vérifier bouton inactif ; quand publié, le bouton doit rester inactif si HEAD, type MIME ou taille ne correspondent pas.
- Télécharger et recalculer le SHA-256 ; comparer au manifeste.
- Vérifier les anciennes routes Hosting et l’absence de secrets dans le contenu publié.
- Tester l’APK sur appareil Android API 24+ en conservant Play Protect actif.

Les réponses HTTP actuellement observées sur l’hébergement sont des réponses de la SPA Hosting avec repli vers `index.html` ; elles ne prouvent ni que cette nouvelle page statique est déployée ni qu’un APK est présent.

## Contrôles reproductibles avant déploiement

- `flutter test test/web --reporter expanded` : navigation, connexion, livraison et pages légales.
- `py scripts/verify_distribution.py` : intégrité et présence des fichiers finaux, manifeste, routes et recherche de secrets (fichiers sensibles et motifs de clés privées, y compris dans l’APK).
- `firebase serve --only hosting --project az-express-b0469 --host 127.0.0.1 --port 5008` : serveur local uniquement.
- `node scripts/test_distribution_browser.cjs` : QR PNG/SVG et scénarios du bouton sur le serveur local, avec `playwright-core`, `pngjs` et `jsqr` disponibles via `NODE_PATH`, et Microsoft Edge installé. Les requêtes navigateur vers l’origine publique sont interceptées et dirigées vers le serveur local ; aucun accès navigateur à la production.

La recherche de secrets ne considère pas les clés publiques Firebase/Maps intégrées au client comme des clés privées. Les essais sur téléphone réel et le téléchargement depuis le CDN public restent à effectuer après déploiement autorisé. Aucune publication n’est exécutée par les scripts de contrôle.

Résultats de préparation : build Web réussi, 40 tests Flutter Web réussis, 6 QR PNG/SVG décodés, 8 scénarios navigateur réussis (ordinateur, mobile et refus des téléchargements invalides). Le téléchargement HTTP local complet reproduit le SHA-256 de l’original. Aucun fichier du cache Hosting précédent ne manque dans le dossier final.

Limite locale : la bibliothèque `glob-slasher` de l’émulateur Hosting installé convertit les chemins en antislashs sous Windows ; les règles glob des en-têtes ne correspondent alors pas. Les motifs de `firebase.json` correspondent bien aux URL utilisant des slashs. Vérifier après publication les en-têtes Cache-Control, Content-Disposition et nosniff du CDN. Le build JavaScript réussit ; seul le contrôle préparatoire WebAssembly signale des incompatibilités existantes dans `flutter_tts`.
