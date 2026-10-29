# Nouvelle soumission iOS : opérations avant le build (29 octobre 2026)

Aucune de ces opérations n'a été exécutée en production. Branche : `apple-resubmission-azia-consent`. Chaque étape de déploiement exige une autorisation distincte.

## 1. Suppression de compte opérationnelle (priorité)
État en production : seule `completeManualAccountDeletionCF` est déployée. `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions` et `manageAccountDeletionCF` sont absentes ; `operations_control/account_deletion` n'existe pas.
- [ ] Déployer les 3 fonctions minimales `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions` (+ `manageAccountDeletionCF` pour le support) avec `--only functions:...`, sans `--force`, `cpu`/`maxInstances` explicites.
- [ ] Vérifier le quota Cloud Run CPU de `europe-west1` juste avant : somme actuelle `Σ(cpu×maxInstances)` = 166,5 pour 95 services ; les 4 fonctions ajoutent ≈ 0,7 (256 MiB, 1 instance).
- [ ] Décision juridique : durées de conservation des pièces financières, preuves de livraison, conversations (voir `ACCOUNT_DELETION_ROLE_POLICY.md`). Aucune durée n'est inventée.
- [ ] Créer `operations_control/account_deletion` avec `enabled:true, inventoryVersion:1` (sans `partnerInventoryVersion` : seuls client et livreur sont traités automatiquement, les partenaires restent en revue). Action de production à autoriser séparément.
- [ ] Essai réel avec un compte client fictif, puis surveillance 24 h. Retour arrière : `enabled:false`.
- [ ] Reformuler `web/legal/*.html` et `privacy_page.dart` pour annoncer la suppression dans l'application seulement une fois ces étapes validées.

## 2. Consentement AZ IA déployé
- [ ] Règles Firestore (seul `ai_consents` diffère du live).
- [ ] `firebase deploy --only functions:azIaChat`, sans `--force`, avec sauvegarde et vérification que `maxInstances`/`cpu` restent explicites.
- [ ] Les anciens clients Android perdent AZ IA jusqu'à mise à jour : publier d'abord l'APK/AAB corrigé.

## 3. Politique de confidentialité en ligne
- [ ] Publier le paquet Hosting préparé (copie des 68 fichiers publiés + pages légales + réécritures `/confidentialite` et `/delete-account`), après contrôle du canal de prévisualisation. Régénérer le paquet avec les derniers commits.
- [ ] Vérifier `/confidentialite`, `/delete-account`, `/telecharger/`, l'APK (sha256 = `latest.json`), `/distribution/*`.

## 4. Associated Domains
- [ ] Activer la capacité sur l'App ID `com.azexpress.app` (Apple Developer), régénérer le profil App Store.
- [ ] Entitlement `applinks:az-express-b0469.web.app` déjà dans `Runner.entitlements`.

## 5. AASA
- [ ] Fichier local `web/.well-known/apple-app-site-association` : `F6XWK2W7XG.com.azexpress.app`, chemin `/partenaire/*`. En production il est vide (`details:[]`).
- [ ] À publier avec le Hosting final, servi en JSON sans redirection ; vérifier avec le Team ID exact.
- [ ] Vérifier que le code mobile gère un lien `/partenaire/<jeton>` ouvert depuis l'extérieur (`FlutterDeepLinkingEnabled` est activé).

## 6. Configuration Codemagic
- [ ] `IOS_BUILD_NUMBER` : entier supérieur au dernier build d'App Store Connect (≥ 14).
- [ ] Groupe `firebase` : `FIREBASE_IOS_PLIST_B64`, `FIREBASE_DART_OPTIONS_B64`.
- [ ] Intégration App Store Connect et signature automatique actives. `submit_to_testflight` et `submit_to_app_store` restent à `false`.

## 7. Tests iPhone
- [ ] Appareil réel : connexion, commande, suivi, notifications, localisation, AZ IA avec refus puis acceptation du consentement, retrait, dictée vocale, suppression de compte.
- [ ] Aucun test sur appareil n'a été fait à ce jour.

## 8. Captures App Store (guideline 2.3.10)
- [ ] Prises sur iPhone ou simulateur iOS uniquement, sans clavier, barre d'état ni éléments Android, sans mention de Google Play.
- [ ] Tailles requises par App Store Connect (iPhone 6,9" / 6,5"). Ne pas utiliser `.scratch_shots`.

## Points ouverts hors checklist
- Clé Dart Maps : voir `MAPS_ROUTING_LIMITATION.md`.
- `onDevice` de la dictée vocale iOS : inchangé (décision utilisateur).
