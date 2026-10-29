# Publication Firebase Hosting — 12 octobre 2026

Statut : PASS pour la distribution APK ; réserve sur les liens directs Flutter sans fragment.

- Projet : az-express-b0469 ; dernière version Hosting : `75df260b86ade3af`.
- Commande exécutée après autorisation : `firebase deploy --only hosting --project az-express-b0469`.
- 68 fichiers publiés depuis build/web. Aucun déploiement Functions, rules, Authentication ou Google Play. Aucun commit/push.
- Page : https://az-express-b0469.web.app/telecharger
- APK : https://az-express-b0469.web.app/downloads/az-express-latest.apk
- APK téléchargé par clic navigateur : 1.0.9+10, com.azexpress.app, 82 330 271 octets ; signature v2 vérifiée.
- SHA-256 : `9457E91D3B6511C56074006583F36114F1D6E5A36B8007C65DABB37820BB3616`.
- Manifeste public : published=true, version 1.0.9, code 10 ; Cache-Control no-store et nosniff.
- APK : Content-Type application/vnd.android.package-archive ; Content-Disposition attachment ; Cache-Control public, max-age=300 ; nosniff.
- Page : Cache-Control no-cache.

## Contrôles réalisés

Bouton Android actif sur ordinateur et viewport mobile ; clic et téléchargement public complet vérifiés. Empreinte et signature conformes à l'original. Manifeste, en-têtes et 14 routes HTTP contrôlés ; fichiers main.dart.js et flutter_bootstrap.js identiques au build validé. Liens légaux cliqués dans la dernière page publique et contenu attendu vérifié. Connexion client et Admin rendues ; /#/app redirige vers /#/connexion sans session. Aucun test de paiement, création de compte, commande ou suppression de données en production.

## Problèmes rencontrés et corrections

1. Le CDN compresse l'APK : Content-Length représente alors 39 075 766 octets transférés et non les 82 330 271 octets du fichier. La vérification initiale bloquait le bouton. Correction limitée à la page statique : si Content-Encoding est présent, une requête Range bytes=0-0 vérifie la taille réelle via Content-Range. Six scénarios testés avant republication. L'APK est inchangé.
2. Le routeur Flutter existant utilise les fragments /#/... : /confidentialite et /delete-account répondent 200 mais affichent l'accueil. Les deux liens de la page statique ont été corrigés vers /#/confidentialite et /#/delete-account. Le routage métier Flutter n'a pas été modifié. Les anciennes URL sans fragment restent une réserve connue.
3. Avertissement non bloquant du CLI sur la propriété flutter dans firebase.json ; déploiements terminés avec code 0.

Installation et lancement sur téléphone Android réel non testés dans cet environnement. L'APK direct ne constitue pas une mise à jour compatible avec une installation Google Play ; cette distinction est affichée sur la page.

Les journaux et preuves locaux se trouvent dans `.scratch_shots/distribution-public/` (hors Hosting).
