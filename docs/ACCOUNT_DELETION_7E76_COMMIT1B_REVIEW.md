# Mission 7E-76 — Revue du commit 1b (Flutter, 4 fichiers)

Date : 2026-11-07 · Aucun `git add`/commit exécuté. Le nombre de fichiers reste 4 ; le contenu a évolué depuis 7E-75 (§2).

## 1. Fichiers exacts
`lib/services/account_deletion_service.dart` (+37/−4 vs HEAD) · `lib/widgets/account_deletion_dialog.dart` (+5/−2) · `test/services/account_deletion_service_test.dart` (+69) · `test/widgets/account_deletion_dialog_test.dart` (+25).

## 2. Évolution en 7E-76 (corrections locales, justifiées)
1. `resolveCallableFailure(e, lastRequest)` extrait du `catch` de `submitRequest` (comportement identique) afin de **tester** le cas « ancien reçu présent » (impossible tant que le `catch` appelait directement `checkLastRequest()`).
2. 6 tests de contrat ajoutés dans le fichier de test du service (conversion plugin réelle, Web, autres erreurs, ancien reçu, demande enregistrée).

## 3. Périmètre : ne contient que
- le refus de passerelle (`AccountDeletionUnavailableException`, `isGateClosedRefusal`, `resolveCallableFailure`) ;
- la distinction avec l'erreur réseau (repli `checkLastRequest` conservé) ;
- `unauthenticated` ajouté aux codes de réauthentification du dialogue ;
- les tests correspondants.
Aucune modification de thème, de mise en page, de navigation ni de la page web. Aucune autre fonction du service modifiée (`submitRequestUsing`, `checkLastRequest` intacts).

## 4. Points d'attention
- `unauthenticated` renvoyé par le **serveur** passe d'abord par le `catch FirebaseFunctionsException` (repli reçu) ; le libellé de réauthentification ne s'affiche que pour les exceptions Firebase Auth (`FirebaseException`) — comportement inchangé pour les erreurs serveur.
- Texte du message de refus : à la date de cette revue (7E-76/78) le code affichait une variante ASCII, distincte de la formulation retenue. **[Mise à jour 7E-80]** Depuis 7E-79, le code et les tests affichent exactement la formulation retenue (voir `ACCOUNT_DELETION_7E79_FLUTTER_MESSAGE.md`) ; le service, son test et le test du dialogue ont changé, le dialogue est inchangé. Les compteurs de lignes du §1 sont antérieurs à 7E-79.
- `visibleForTesting` importé depuis `flutter/foundation` (`show visibleForTesting`).
- Le fichier de test importe un chemin `src/` du plugin (`platformExceptionToFirebaseFunctionsException`) avec `ignore_for_file` : dépend de la structure interne de `cloud_functions_platform_interface 6.0.2` ; si le plugin est mis à jour, ce test pourrait devoir être adapté (aucun impact sur l'application).

## 5. Résultats
`flutter test` (service + dialogue) : 31/31 ; `flutter analyze` des 4 fichiers : aucune anomalie ; pas de test sur appareil ni de suite Flutter complète.

## 6. Dépendance de commit
Indépendant du code backend (fonctionne avec ou sans `details.reason` grâce au repli sur le message). À placer après le commit 1 et avant toute diffusion de l'application.
