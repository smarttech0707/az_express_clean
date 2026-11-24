# SEC-01 / S6.17 — Préparation de la fermeture contrôlée des lectures `livreurs`

Date : 2026-11-22
Type : préparation uniquement — **aucune Rule de production modifiée, aucun déploiement effectué**
Fichiers de référence : `firestore.rules`, `rules-tests/candidates/livreurs_tightened.rules`, `rules-tests/livreurs-read-tightening.rules.test.js`
Historique : `docs/SEC01_S6_11_STREAMBUILDER_PHONE_AUDIT.md` → S6.14 (migrations Flutter, rapport en chat), S6.15 (audit de compatibilité, rapport en chat), S6.16 (validation Emulator, rapport en chat)

## Résumé exécutif

La règle candidate validée en S6.16 (41/41 tests) s'est révélée **incomplète** une fois confrontée à un inventaire frais et plus large du code (comme demandé explicitement par cette phase) : `admin_dashboard.dart`, l'écran d'accueil affiché à **tout** administrateur juste après connexion — super ou sous-admin, **sans aucune vérification de permission spécifique** — exécute des comptages non filtrés sur `livreurs`. Les 4 permissions ciblées en S6.15/S6.16 (`livreurs`, `carte`, `classement`, `gains`) ne couvrent pas ce cas : un sous-admin dont la seule permission est, par exemple, `tricycle`, atteint quand même ce tableau de bord et aurait vu ses requêtes échouer.

**Correction apportée dans cette phase** (au fichier candidat isolé uniquement, jamais à la production) : remplacement des 4 branches `hasAdminPermission(...)` par une condition unique `isActiveAdmin()` — vraie pour tout administrateur actif, super ou sous-admin, quelle que soit sa permission. Cette condition est strictement nécessaire pour couvrir une requête non filtrée atteignable par n'importe quel admin, et elle rend les 4 branches spécifiques redondantes pour la lecture (un sous-admin actif les satisfaisait déjà toutes via `isActiveAdmin()`).

La règle candidate corrigée a été re-validée par une exécution réelle sur l'émulateur : **38/38 tests passés** (3 nouveaux/modifiés par rapport aux 41 de S6.16, reflétant ce changement de politique).

## 1. Analyse de la candidate (Phase A)

### Fonctions Rules vérifiées dans le code réel

| Fonction | Définition (`firestore.rules`) | Usage dans la candidate |
|---|---|---|
| `isAuth()` | authentifié + compte non tombstoné | conservé pour les autres règles, plus utilisé seul sur `livreurs` |
| `isOwner(id)` | `uid() == id` | conservé — accès propriétaire |
| `isAdmin()` | `isActiveAdmin() && role=='super'` | **retiré** de la candidate (subsumé par `isActiveAdmin()`) |
| `isActiveAdmin()` | actif + rôle `super` ou `sub` (avec `permissions` liste pour `sub`) | **ajouté en S6.17** — condition correcte pour couvrir tout accès admin, y compris non filtré |
| `hasAdminPermission(x)` | `isActiveAdmin() && (super \|\| x in permissions)` | **retiré** de la candidate pour la lecture (redondant une fois `isActiveAdmin()` présent) |

### Vérification des 7 points demandés

- **Accès propriétaire** : préservé (`isOwner(livreurId)`), testé et validé (succès propre doc, refus doc d'un autre livreur).
- **Accès super-admin** : préservé (`isActiveAdmin()` inclut `role=='super'`), testé et validé.
- **Accès sous-admin avec permission réelle** : préservé — **et élargi à juste titre** à tout sous-admin actif (voir résumé exécutif), testé et validé pour les 4 permissions + le cas sans permission pertinente.
- **Accès flotte via `ownerId`** : préservé, avec la nuance « Rules ≠ filtres » correctement vérifiée (requête filtrée sur son propre `ownerId` → succès et ne retourne que ses livreurs ; requête non filtrée ou filtrée sur un autre `ownerId` → échec entier, pas un filtrage silencieux).
- **Pas de nouveaux privilèges injustifiés** : la candidate est **strictement plus restrictive** que la règle actuelle (`isAuth()` seul) sur tous les axes testés — clients, partenaires et anonymes perdent un accès qu'ils ont aujourd'hui ; aucun rôle n'en gagne un qu'il n'avait pas déjà via la règle actuelle.
- **Protection des données financières/téléphoniques/privées** : `wallet`, `isSuspended`, `ownerId`, `ownerName`, `deletionRequested` restent protégés en écriture par les branches `update` **inchangées** de ce même bloc (non touchées par cette phase) — 6 tests de non-régression le confirment.
- **Autres protections existantes** : `driver_public` (lecture anonyme toujours permise, testé) et `admins` (un sous-admin ne lit toujours que son propre profil, testé) ne sont affectés en rien — cohérent, aucune autre règle n'a été modifiée dans le fichier candidat (vérifié par `diff` ligne à ligne contre `firestore.rules` réel, un seul bloc modifié).

## 2. Inventaire d'impact (Phase B)

Inventaire refait intégralement dans cette phase par recherche exhaustive sur l'ensemble du dépôt (`lib/`, `functions/`, `web/`), pas une reprise supposée de S6.15/S6.16. Confirmé : **22 fichiers Flutter** accèdent directement à `livreurs` aujourd'hui (contre 23 avant S6.14 — `boulangerie_dashboard.dart` et `client_map.dart` ont bien disparu de la liste, confirmant que leur migration a tenu).

| Fichier | Fonction/emplacement | Type d'accès | Branche candidate qui l'autorise | Impact | Statut |
|---|---|---|---|---|---|
| `driver_dashboard.dart`, `driver_profil.dart`, `driver_map.dart`, `driver_login.dart`, `driver_wallet.dart`, `driver_rides_service.dart`, `driver_service.dart`, `driver_location_service.dart` | lecture/écriture du **propre** document du livreur | `doc(uid)` | `isOwner(livreurId)` | Aucun | **Compatible** |
| `auth_service.dart` | recherche du compte par `identifiant`/`email` à la connexion | requête par champ, un seul doc retourné (le sien) | `isOwner(livreurId)` (le doc retourné est le sien) | Aucun | **Compatible** |
| `admin_dashboard.dart` | `_load()` — comptages `count()` non filtrés | requête liste non filtrée | `isActiveAdmin()` **(ajout S6.17, sinon bloquant)** | Aucun après correction | **Compatible (après correction S6.17)** |
| `drivers_page.dart` (admin) | gestion des comptes livreurs | `collection()` | `isActiveAdmin()` | Aucun | **Compatible** |
| `admin_recharge_page.dart` | liste des livreurs à recharger | `collection()` | `isActiveAdmin()` | Aucun | **Compatible** |
| `driver_requests_page.dart` | vérification pré-approbation + création (`isAdmin()` déjà requis en écriture, inchangé) | `doc(uid).get()` + `batch.set()` | `isActiveAdmin()` pour la lecture ; écriture déjà `isAdmin()`-only, inchangée | Aucun | **Compatible** |
| `admin_map.dart`, `admin_live_tracking_page.dart` (via `live_marker_cache.onlineDriversFeed`) | carte/suivi admin, besoin réel de `phone` | `collection()` sans filtre / `.where(isOnline)` | `isActiveAdmin()` | Aucun | **Compatible** |
| `admin_drivers_ranking.dart` | classement | `collection()` | `isActiveAdmin()` | Aucun | **Compatible** |
| `admin_earnings.dart` | gains/commissions | `collection()` | `isActiveAdmin()` | Aucun | **Compatible** |
| `fleet_dashboard.dart` (×2) | tableau de bord du patron de flotte | `.where('ownerId', isEqualTo: ownerId)` | `(isRealUser() && resource.data.ownerId == uid())` | Aucun **si et seulement si** le compte utilisé est bien un compte authentifié réel (non anonyme) dont l'uid correspond à `ownerId` — déjà le cas en pratique (pas de connexion anonyme pour ce rôle) | **Compatible, vérifié par requête filtrée réelle en test** |
| `emulator_diagnostics.dart` | outil de développement | — | hors périmètre prod (dev uniquement) | Aucun | **Compatible** |
| `firestore_service.dart::assignDriverToFleet/makeDriverIndependent` | écriture `ownerId`/`ownerName` | `.update()` | Règle d'**écriture**, non touchée par cette phase (déjà `isAdmin()`-only côté admin, `unchanged()` côté livreur) | Aucun | **Compatible, hors périmètre lecture** |
| Tout `functions/*.js` référençant `livreurs` (`accountDeletion.js`, `dispatch.js`, `driverAcceptance.js`, `driverPublicSync.js`, `driverRatings.js`, etc.) | lecture/écriture serveur | Admin SDK | **Les Firestore Rules ne s'appliquent jamais à l'Admin SDK** — confirmé, aucune Cloud Function n'est affectée par un changement de Rules sur `livreurs` | Aucun | **Compatible par construction, non concerné** |
| Web Admin (`lib/web/`) | aucun accès direct trouvé | — | — | Aucun | **Compatible, confirmé par recherche fraîche** |
| Reste du dépôt (~90 fichiers mentionnant le mot « livreurs ») | texte d'interface/commentaires uniquement | — | — | Aucun | **Compatible, vérifié par échantillonnage** |

**Aucun accès légitime manquant trouvé** au-delà de celui corrigé ci-dessus (`admin_dashboard.dart`). **Aucun accès bloquant restant** après la correction S6.17.

## 3. Risques identifiés

- **Risque levé dans cette phase** : la candidate S6.15/S6.16, si déployée telle quelle, aurait cassé le tableau de bord admin pour tout sous-admin sans l'une des 4 permissions spécifiques — corrigé ici, jamais déployé sous sa forme initiale.
- **Risque résiduel accepté** : `isActiveAdmin()` donne à **tout** sous-admin actif, quelle que soit sa permission métier, un accès de lecture à `livreurs` (y compris `wallet`, `phone`, etc.) — plus large qu'un modèle « permission par permission » idéal, mais strictement nécessaire tant que `admin_dashboard.dart` n'est pas lui-même restreint par permission (hors périmètre : « ne migrer aucun lecteur supplémentaire, ne modifier aucun écran »). C'est un compromis déjà documenté, pas un oversight.
- **Risque non vérifiable depuis le dépôt seul** : la version des Rules **réellement déployée en production aujourd'hui** n'a pas été comparée ligne à ligne au fichier local dans cette phase (hors périmètre — lecture seule du dépôt demandée). À confirmer avant tout déploiement réel (`firebase deploy --only firestore:rules --dry-run` suffit, sans déployer).
- **Risque d'obsolescence rapide** : si un nouveau rôle ou une nouvelle permission admin accédant à `livreurs` est ajouté après cette phase sans repasser par un audit similaire, la même classe de problème peut réapparaître.

## 4. Conditions préalables au déploiement

1. Confirmation explicite de l'utilisateur (cette phase n'en est pas une).
2. `firebase deploy --only firestore:rules --dry-run` exécuté et sans erreur juste avant le déploiement réel.
3. Confirmation que le fichier `firestore.rules` réel du dépôt, avec la correction S6.17 appliquée **à ce seul bloc**, est bien celui qui sera déployé (pas le fichier candidat de test, qui reste un artefact isolé).
4. Confirmation qu'aucune autre modification non liée n'est mélangée dans le même déploiement (le dépôt porte 446 modifications locales préexistantes sans rapport — isoler précisément le diff `livreurs` avant déploiement).
5. Suite complète `npm run test:rules` (tous les fichiers existants + le nouveau) rejouée une dernière fois juste avant déploiement.

## 5. Plan de déploiement (séquencé)

1. **Sauvegarde** : conserver une copie horodatée de `firestore.rules` actuel (ex. `firestore.rules.backup-pre-s618-<date>`) avant toute modification — hors dépôt Git ou dans un emplacement clairement temporaire, jamais comme un fichier de règles actif.
2. **Vérification Emulator** : rejouer `npm run test:rules` + `rules-tests/livreurs-read-tightening.rules.test.js` contre le fichier réel une fois la modification appliquée localement (avant tout déploiement).
3. **Préparation de la version exacte** : appliquer à `firestore.rules` réel exactement le même remplacement de bloc que celui du fichier candidat (`allow read: if isOwner(livreurId) || isActiveAdmin() || (isRealUser() && resource.data.get('ownerId', null) == uid());`), rien d'autre.
4. **Projet cible** : `az-express-b0469` (confirmé actif via `.firebaserc`), jamais `az-express-preprod`.
5. **Préconditions** : §4 ci-dessus intégralement remplies.
6. **Déploiement minimal et contrôlé** : `firebase deploy --only firestore:rules --project az-express-b0469`, en dehors des heures de pointe de livraison si possible (minimise l'impact d'un éventuel imprévu).
7. **Tests immédiats après déploiement** : (a) un livreur réel peut toujours lire/mettre à jour son propre document ; (b) un admin réel (super et, si possible, un compte sous-admin de test) peut toujours ouvrir le tableau de bord et les écrans Livreurs/Carte/Classement/Gains ; (c) un patron de flotte réel voit toujours ses livreurs ; (d) un compte client ordinaire ne peut plus lire un document `livreurs` arbitraire (vérification de la fermeture elle-même) ; (e) surveillance des logs Firebase pendant 15-30 min pour tout pic de `permission-denied` inattendu.
8. **Critères GO/NO-GO** : voir checklist §7.
9. **Rollback** : voir §6.

## 6. Plan de rollback (préparé, non exécuté)

- **Fichier exact à restaurer** : la sauvegarde horodatée de `firestore.rules` créée à l'étape 1 du plan de déploiement (contenu identique à l'état actuel du dépôt avant cette phase, c'est-à-dire `allow read: if isAuth();` sur le bloc `livreurs`).
- **Commande exacte** : `firebase deploy --only firestore:rules --project az-express-b0469` après avoir remis le fichier `firestore.rules` à son contenu de sauvegarde.
- **Projet à vérifier** : `az-express-b0469` (jamais la préproduction).
- **Confirmation du retour** : relire le bloc `livreurs` déployé (`firebase.rules` tel que connu localement) et/ou exécuter à nouveau le test « trouvaille documentée » (`firestore.rules.test.js:372`, lecture anonyme réussie) contre l'émulateur chargé avec le fichier restauré — succès confirme le retour à l'état antérieur.
- **Tests immédiats après rollback** : vérifier qu'un admin, un livreur et un client ordinaire retrouvent exactement le comportement documenté avant cette phase (aucune régression supplémentaire introduite par le rollback lui-même).
- **Déclencheurs recommandés d'un rollback** : apparition de `permission-denied` inattendus sur un écran admin/flotte en production après déploiement, ou signalement utilisateur d'une fonctionnalité cassée liée à `livreurs`.

## 7. Checklist GO / NO-GO

- [x] Règle candidate relue et corrigée (gap `admin_dashboard.dart` levé).
- [x] 38/38 tests Emulator passés sur la version corrigée.
- [x] Inventaire d'impact refait intégralement dans cette phase, aucun accès bloquant restant identifié.
- [x] Non-régression des écritures financières/sensibles vérifiée par test.
- [ ] Comparaison avec les Rules réellement déployées en production (non faite dans cette phase — lecture seule du dépôt).
- [ ] `firebase deploy --only firestore:rules --dry-run` exécuté juste avant un déploiement réel.
- [ ] Autorisation explicite de déploiement donnée par l'utilisateur.
- [ ] Test manuel sur un compte sous-admin réel (pas seulement simulé sur l'émulateur) après déploiement.

## 8. Verdict final

## **GO PRÉPARATOIRE**

Le plan est prêt : la règle candidate est désormais complète (gap corrigé et re-validé par exécution réelle), l'inventaire d'impact est frais et exhaustif, le plan de déploiement et son rollback sont précis et immédiatement exploitables. Le déploiement reste conditionné à votre autorisation explicite et à la vérification finale `--dry-run` au moment voulu (non effectuée ici par choix, cette phase étant une préparation).

---

## Confirmation des limites respectées

Aucune modification de `firestore.rules` réel. Aucun déploiement de Rules ni de Cloud Function. Aucun changement de projet Firebase actif ni de configuration permanente (le fichier de configuration d'émulateur utilisé pour les tests reste temporaire, hors dépôt, dans le répertoire scratchpad de session). Aucune dépendance/lockfile modifié. Aucune migration Flutter supplémentaire, aucun écran modifié. Aucun fichier supprimé. Aucune opération Git destructive. Les 446 modifications locales préexistantes et les fichiers non suivis sont préservés. `operations_control/account_deletion` non activé. T7E non touché. Seuls fichiers créés/modifiés dans cette phase : ce rapport, `rules-tests/candidates/livreurs_tightened.rules` (corrigé), `rules-tests/livreurs-read-tightening.rules.test.js` (3 tests ajoutés/modifiés) — tous des artefacts de préparation, aucun fichier de production.

STOP après ce rapport. Aucune phase suivante commencée. En attente de votre autorisation explicite avant toute modification réelle des Rules ou tout déploiement.
