# LOT 7.4 — phase A locale

Base vérifiée : `sync-windows-20260825`, `d99137f`, arbre initial propre.

## Périmètre implémenté

`buildArtisanLogin` reste le point d'entrée utilisé par `artisanLogin`, mais
devient un lecteur compatible sans migration au login. Le credential privé
est prioritaire, même invalide : aucun repli public dans ce cas. Le compte
historique est accepté sans créer de credential ni supprimer le PIN public.
La transaction relit le prestataire et le credential ; elle peut seulement
mettre à jour `artisanUid`. Authentification et limitation de fréquence restent
actives. La réponse utilise une liste explicite de champs de profil ; les
champs inconnus, documents d'identité et tokens ne sont pas renvoyés.

La phase B n'est pas activée. La finalisation a remplacé les deux lectures du
login par `tx.getAll`, sans intercepter ni réessayer artificiellement les erreurs.
Deux modifications concurrentes ont été constatées en fin de travail dans
`artisanCredentials.js` et `test/migrateArtisanPins.test.js` (lecture groupée
également). Elles ont été préservées, mais leur état final n'est pas certifié
par la campagne lancée avant leur constatation.

## Règles intermédiaires

Le ruleset de référence est
`9b96657d-bc14-4dc0-bc25-4e52671b6178` (release lue au LOT 7.2,
publication du 6 septembre 2026 à 13:59:42 UTC).
La copie et sa provenance sont désormais disponibles dans `docs/firestore-production`.
SHA-256 vérifié : `30f9e39e175d82c63becd0ed148a6930e1582ba0db0412a7b3f359467a02ae6a`.
`firestore.intermediate.rules` conserve tout sauf les deux autorisations update :
suspension personnelle du livreur et champs financiers du livreur assigné.
Le contrôle commun couvre aussi les rôles vendeur/client cumulés ; l'exception
administrateur autorisé reste explicite. Le test compare le reste du fichier
exactement à la référence. `firestore.rules` reste intact.

## Tests locaux

Dans une console, démarrer le JAR Firestore déjà installé sur un port local :

```powershell
java '-Duser.language=en' '-Duser.country=US' -jar "$env:USERPROFILE\.cache\firebase\emulators\cloud-firestore-emulator-v1.21.0.jar" --host 127.0.0.1 --port 8187 --project_id demo-lot74
```

Dans une seconde console, à la racine du dépôt :

```powershell
$env:FIRESTORE_EMULATOR_HOST = '127.0.0.1:8187'
node --test rules-tests/firestore.intermediate.test.js
node --test functions/test-emulator/artisanLoginPhaseA.test.js
node --test functions/test/passwordHash.test.js functions/test/passwordReset.test.js
node --test --test-name-pattern='legacy login|two simultaneous resets|approval|approvals' functions/test-emulator/artisanAccounts.test.js
flutter test --no-pub test/services/artisan_event_region_test.dart
git diff --check
```

La nouvelle suite impose localhost/127.0.0.1 et le projet `demo-lot74`.
La suite existante utilise `demo-lot71`. Les resets/approbations de fixtures
restent exclusivement dans l'émulateur. Aucun CLI de migration n'est exécuté.
Ne jamais supprimer la vérification d'hôte pour faire passer ces tests.

## Limites de transition

Les PIN historiques restent exposés aux lecteurs autorisés des documents
publics tant qu'une transition ultérieure n'a pas été approuvée. Les anciens
écrivains publics restent un risque distinct ; cette phase ne prétend pas les
neutraliser. Les binaires distribués et la compatibilité de consommateurs
inconnus avec la réponse filtrée ne sont pas vérifiés. Le tableau de bord
Flutter local consomme des champs conservés par le nouveau contrat.

## Résultats de finalisation

- Compilation et règles intermédiaires : 33/33, contrats historiques compris.
- Login phase A après lecture groupée : cinq passages de 10/10.
- Suite artisan ciblée : cinq passages, respectivement 5/6, 6/6, 5/6, 5/6, 6/6.
  Les trois échecs concernent les approbations simultanées et ne sont pas masqués.
- Hachage/reset : 12/12 ; syntaxe JavaScript et `git diff --check` réussis.
- Flutter régional : 5/5 lors de la passe précédente, non réexécuté ici.

Avant adaptation, deux passages complets de la suite artisan avaient échoué
sur la course login/rotation ; une troisième répétition artisan a été interrompue
pour redémarrer l'émulateur (elle n'est pas comptée comme réussite).
Le premier essai de règles a également été interrompu : la locale fr_FR de
l'émulateur provoquait une MissingResourceException. Le démarrage en anglais
a permis la réussite des 33 tests sans changer les permissions.

Les logs montrent des timeouts de verrou suivis de transactions invalides ou
fermées. Le SDK installé ne retente INVALID_ARGUMENT que si le message contient
`transaction has expired`, pas `Transaction is invalid or closed`. La lecture
groupée réduit les RPC du login, mais ne résout pas toute l'instabilité : la
cause interne complète et son éventuelle portée hors émulateur restent non établies.

Verdict : BLOCKED pour la revue globale tant que l'instabilité et les modifications
concurrentes ne sont pas validées. Aucun déploiement, migration, commit ou push.
