# SEC-01 — S5.1 : consolidation de l'écriture `isOnline`

**Statut : correction ciblée appliquée et testée. Aucun trigger, aucune règle, aucune Cloud Function touchée.** Suite de S5 (`docs/SEC01_S5_SERVER_PROJECTION_AUDIT.md`, §1 « Statut »), qui recensait 6 sites d'écriture de `isOnline` et signalait une duplication à l'événement de déconnexion.

## 1. Rappel des 6 sites audités en S5

| # | Fichier / fonction | Acteur | Déclencheur | Valeur |
|---|---|---|---|---|
| 1 | `driver_location_service.dart::_saveToFirestore` | Flutter (livreur) | Écriture GPS throttlée | `true` |
| 2 | `driver_location_service.dart::goOffline` | Flutter (livreur) | Arrêt explicite du suivi | `false` |
| 3 | `driver_profil.dart::_showSignOutDialog` | Flutter (livreur) | Déconnexion depuis l'écran de profil | `false` **(écriture directe, sans arrêt préalable du flux GPS)** |
| 4 | `drivers_page.dart::_toggleSuspend` | Flutter (admin) | Suspension d'un livreur | `false` (groupé avec `isSuspended:true`) |
| 5 | `functions/accountDeletion.js:108,165` | Cloud Function | Mise en quarantaine / clôture de compte | `false` (groupé avec `isAvailable:false,isSuspended:true`) |
| 6 | `functions/staleDriverCleanup.js:48` | Cloud Function (cron, 5 min) | Péremption GPS (`STALE_MINUTES`) | `false` |

## 2. Duplication confirmée (pas seulement supposée)

Seuls les sites **2 et 3** correspondent au **même événement métier** (le livreur se déconnecte volontairement) — les sites 4, 5 et 6 répondent chacun à un déclencheur distinct (suspension admin, clôture de compte, péremption GPS) et n'ont donc **pas** été touchés, conformément à la consigne « uniquement si duplication réelle ».

La duplication entre les sites 2 et 3 n'est pas seulement redondante : c'est un **bug réel, déjà rencontré et corrigé une fois dans ce projet pour un cas identique**. `lib/screens/driver/driver_dashboard.dart::_setOnline` porte ce commentaire explicite (ligne 441-443) :

> « stopTracking seul n'écrit pas isOnline:false. Sans cet appel, le stream GPS continuait et sa prochaine position remettait le livreur en ligne automatiquement. »

C'est exactement pour cette raison que `goOffline()` existe : il **arrête le flux GPS avant** d'écrire `isOnline:false`, fermant la fenêtre de course. Or `driver_profil.dart::_showSignOutDialog` faisait l'inverse : écriture directe de `isOnline:false`, puis `FirebaseAuth.instance.signOut()` (un appel réseau), puis seulement à la fin, indirectement, l'arrêt réel du flux GPS — via `DriverDashboard.dispose()` (qui appelle `DriverLocationService.instance.stopTracking()` sans condition), déclenché par le `Navigator.popUntil` qui démonte l'écran de tableau de bord sous-jacent. Entre l'écriture directe et ce démontage, le flux GPS restait actif : une position reçue pendant ce court intervalle (mouvement réel ou battement de cœur) aurait réécrit `isOnline:true`, annulant silencieusement la déconnexion.

## 3. Correction apportée

`lib/screens/driver/driver_profil.dart::_showSignOutDialog` : remplacement de l'écriture directe (`FirebaseFirestore.instance.collection("livreurs").doc(widget.driverId).update({"isOnline": false})`) par un appel à la source unique déjà existante, `DriverLocationService.instance.goOffline(widget.driverId)`. Le reste de la séquence (journalisation de l'événement d'authentification, `FirebaseAuth.instance.signOut()`, retour à l'écran racine) est inchangé.

Aucun nouveau timer, aucune nouvelle Cloud Function, aucun nouveau mécanisme de statut : réutilisation stricte de l'existant.

## 4. Fichiers modifiés

- `lib/screens/driver/driver_profil.dart` — 1 import ajouté, 1 bloc remplacé (6 lignes → 7 lignes avec commentaire).
- `test/services/driver_location_service_test.dart` — 2 nouveaux groupes, 5 tests.

## 5. Tests ajoutés et résultats

**Groupe « consolidation de la déconnexion (gardes de source) »** (3 tests) :
- confirme que `_showSignOutDialog` ne contient plus aucune écriture directe de `isOnline` ;
- confirme l'appel à `DriverLocationService.instance.goOffline(widget.driverId)` et l'import correspondant ;
- confirme qu'aucun autre champ serveur protégé (`isAvailable`, `isOnDelivery`, `isSuspended`, `avgRating`, `ratingCount`) n'est touché par ce bloc — verrouille le périmètre strict de la correction.

**Groupe « `goOffline()` : comportement réel »** (2 tests, sur le harnais de test déjà existant du service) :
- un flux GPS actif (`debugAttach`) est bien fermé par `goOffline()` (`active` passe de 1 à 0) et l'appel se termine sans jamais lever, même sans Firebase initialisé (l'écriture Firestore, déjà protégée par son propre `try/catch` interne, échoue silencieusement comme en production face à une erreur réseau) ;
- appel idempotent sans flux actif (cas où le livreur n'était pas en train de suivre sa position).

**Résultat** : **64/64 tests passés** (`flutter test test/services/driver_location_service_test.dart test/services/driver_public_projection_test.dart test/screens/driver_map_update_throttle_test.dart`) — les 5 nouveaux tests, plus l'intégralité de la suite GPS/tracking déjà existante (y compris S4/S4.1), sans aucune régression.

## 6. Analyse statique

`flutter analyze` propre (0 issue) sur `lib/screens/driver/driver_profil.dart` et sur `test/services/driver_location_service_test.dart`.

## 7. Confirmations

- `isAvailable`, `isOnDelivery`, `avgRating`, `ratingCount` : non modifiés — seul `isOnline` a été touché, uniquement sur le site dupliqué.
- Les 4 autres sites d'écriture de `isOnline` (GPS, suspension admin, clôture de compte, cron de péremption) : non modifiés, aucune duplication réelle démontrée entre eux.
- Aucune règle Firestore modifiée.
- Aucune Cloud Function modifiée.
- Aucun trigger `driver_public` introduit (hors périmètre de cette mission, prévu en S5.2/S5.3).
- Aucun lecteur migré.
- Aucun accès Firebase réel, aucun déploiement, aucun APK/AAB.
- Pilote T7E et `account_deletion` non touchés.

## 8. Risques résiduels

- **Changement de comportement mineur, délibéré et bénéfique** : l'ancienne écriture directe n'avait aucun `try/catch` — un échec de l'écriture Firestore aurait laissé l'exception se propager dans le gestionnaire `onPressed` (comportement non maîtrisé). `goOffline()` encapsule cette écriture dans son propre `try/catch` interne (déjà existant, pas ajouté ici) : un échec est désormais absorbé silencieusement et la déconnexion se poursuit normalement (journalisation puis `signOut()`). C'est un alignement sur le comportement déjà établi et testé pour le bouton « Hors ligne » du tableau de bord, pas une régression.
- La correction ne couvre que l'événement de déconnexion volontaire depuis l'écran de profil ; les 4 autres sites restent par conception des mécanismes distincts, à ne pas fusionner sans justification propre (confirmé en S5 et réaffirmé ici).

## 9. Limites

Cette mission ne implémente pas le trigger de synchronisation serveur `driver_public` (S5.2/S5.3, hors périmètre explicite). La consolidation réalisée ici réduit de 6 à 5 le nombre de sites qu'un futur trigger devra couvrir (ou, plus précisément, élimine un site qui dupliquait un autre sans ajouter de nouvelle sémantique), simplifiant d'autant l'implémentation à venir.
