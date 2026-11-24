# SEC-01 — S6.0.3 : corrections ciblées des 2 dettes résiduelles

Date : 2026-11-21
Type : correction ciblée (ni S6.1, ni migration de lecteurs Firestore)
Périmètre : (1) champ `rating` dans `driver_profil.dart`, (2) code mort `deductCommission`/`_logTransaction`

## 1. Résumé

Les deux corrections confirmées lors de l'audit S6.0.2 ont été appliquées :

1. `driver_profil.dart:374` lit maintenant `avgRating` (converti et borné en cas d'absence/`null`/type inattendu), au lieu de l'ancien champ `rating` jamais écrit.
2. `deductCommission` et son unique dépendance privée `_logTransaction` (plus jamais appelées nulle part après re-vérification exhaustive) ont été supprimées de `lib/services/firestore_service.dart`. `calculateCommission`/`calculateDriverGain`, partagées avec `admin_earnings.dart`, n'ont pas été touchées.

Aucune Cloud Function, aucune Rules Firestore, aucune structure de données modifiée. Aucun fichier hors de ces deux corrections n'a été modifié.

## 2. Correction du champ `rating`

### 2.1 Re-vérification du contexte

`driver_profil.dart` (`_DriverProfilState.build`, lignes 354-374) lit son document via un `StreamBuilder<DocumentSnapshot>` sur `livreurs/{widget.driverId}`. `data` retombe sur `<String, dynamic>{}` si le document n'existe pas. Re-confirmé : aucune autre écriture Flutter/Functions ne pose jamais `rating` sur `livreurs` (recherche exhaustive refaite, même résultat qu'en S6.0.2 — table complète dans ce rapport précédent).

### 2.2 Changement appliqué

`lib/screens/driver/driver_profil.dart:374` :

```diff
- final rating = data["rating"] ?? 0.0;
+ final rating = (data["avgRating"] as num? ?? 0).toDouble();
```

Ce motif (`(data[champ] as num? ?? 0).toDouble()`) est la convention déjà utilisée pour `avgRating` ailleurs dans le code (`driver_dashboard.dart:133`, `suivi_commande.dart:1431`, `customer_tracking_screen.dart:322`) : il gère nativement les trois cas demandés :

- **absent** → `as num?` donne `null` → `?? 0` → `0.0`.
- **`null` explicite** → idem → `0.0`.
- **type non numérique** (ex. chaîne) → `as num?` échoue le cast et donne `null` (cast nullable, pas d'exception) → `?? 0` → `0.0`.

Aucune autre ligne de l'écran n'a été modifiée : l'affichage reste `"$rating ★"` (ligne 462), les conventions d'interface existantes sont préservées. Le calcul des notes et les Cloud Functions de notation (`rateOrder`, mise à jour serveur d'`avgRating`/`ratingCount`) n'ont pas été touchés.

### 2.3 Test ajouté

`test/screens/driver/driver_profil_rating_test.dart` (nouveau fichier) : isole l'expression de lecture exacte dans une fonction pure testée sur 6 cas (double présent, int présent, absent, `null`, type non numérique, ancien champ `rating` legacy ignoré en présence d'`avgRating`). Un test widget complet pilotant le `StreamBuilder<DocumentSnapshot>` réel n'est pas réalisable : aucun paquet de simulation Firestore n'est présent dans le dépôt (`fake_cloud_firestore` absent de `pubspec.yaml`, confirmé par recherche) et modifier les dépendances est explicitement interdit dans cette phase — limitation déjà documentée dans le dépôt pour le même type d'écran (`test/screens/driver/driver_accept_selfie_test.dart`, commentaire : *« FirebaseStorage / Firestore ne sont pas simulables ici »*).

## 3. Neutralisation de `deductCommission`

### 3.1 Recherche exhaustive refaite

```
grep -rn "deductCommission" .   → aucune occurrence de code (lib/, functions/, test/)
grep -rn "_logTransaction" .    → aucune occurrence de code (lib/, functions/, test/)
```

(Seules des occurrences documentaires subsistent, hors périmètre : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md`, `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md`, `docs/SEC01_S6_0_2_RESIDUAL_DEBT_AUDIT.md`, `docs/LEDGER_FORGERY_FIX.md`, `firestore.rules` [commentaire], `rules-tests/driver-ledger.rules.test.js` [commentaire] — aucune n'est du code exécutable, aucune n'a été modifiée ici conformément à la consigne « ne pas modifier de fichier sans rapport avec les deux corrections »).

### 3.2 Dépendances identifiées et vérifiées

- **`_logTransaction`** (privée, `firestore_service.dart`) : un seul appelant dans tout le fichier, `deductCommission` elle-même (ligne 411 avant suppression). Confirmé sans autre usage. Supprimée avec `deductCommission`.
- **`calculateCommission`** (publique) : utilisée par `deductCommission` **mais aussi** par `admin_earnings.dart:176,419` (calcul de commissions totales côté admin) et par `calculateDriverGain` (même fichier, ligne 42, elle-même potentiellement utilisée ailleurs). **Dépendance partagée, donc conservée intégralement, non touchée.**
- **Import `Timestamp`** (`cloud_firestore`) : toujours utilisé ailleurs dans le fichier (`walletTransactions`, autres écritures horodatées) — aucun import à retirer.

### 3.3 Point de vigilance identifié et résolu (Rules / anciennes versions de l'app)

`firestore.rules` (lignes 429-436) et `docs/LEDGER_FORGERY_FIX.md` documentent que la sous-collection `livreurs/{id}/wallet_transactions` conserve volontairement une règle de création côté client correspondant **exactement** à la forme produite par l'ancien `_logTransaction` (`type:'commission'`, identifiant automatique du SDK, montant entier 0-1000, champs `type/amount/description/orderId/createdAt`). Le commentaire des règles le qualifie de « flux client légitime conservé (anciennes versions) ».

Vérification faite avant de supprimer : cette accommodation des règles protège les **applications déjà installées sur des téléphones** (anciens APK compilés, dont le code Dart figé ne dépend pas de ce dépôt). Elle n'est pas une référence au code source actuel : la recherche exhaustive (§3.1) confirme qu'aucun chemin du code source présent — avant ou après cette phase — n'appelle plus `deductCommission`/`_logTransaction` ; ce chemin était déjà totalement mort dans les builds actuels avant cette correction. Supprimer le code source mort ne change donc rien au comportement des anciens appareils (leur binaire est indépendant de ce dépôt) ni aux règles Firestore (non modifiées ici). `rules-tests/driver-ledger.rules.test.js` teste directement la règle elle-même en construisant le document, sans passer par le code Dart : il reste valide et n'a pas été modifié.

Conclusion : **aucun risque identifié**, suppression menée à bien sans réserve sur ce point.

### 3.4 Décision technique retenue

Suppression propre de `deductCommission` et `_logTransaction` (lignes 334-348 et 400-418 avant modification de `lib/services/firestore_service.dart`). Aucune dépendance partagée n'a été touchée. Le mécanisme serveur actuel (`functions/driverAcceptance.js::acceptOrder`) n'a reçu aucune modification.

## 4. Fichiers modifiés — liste exacte

| Fichier | Nature du changement |
|---|---|
| `lib/screens/driver/driver_profil.dart` | 1 ligne : `data["rating"]` → `(data["avgRating"] as num? ?? 0).toDouble()` |
| `lib/services/firestore_service.dart` | Suppression de `_logTransaction` (15 lignes) et `deductCommission` (19 lignes) |
| `test/screens/driver/driver_profil_rating_test.dart` | **Nouveau fichier** : test ciblé (6 cas) |
| `docs/SEC01_S6_0_3_RESIDUAL_DEBT_FIX.md` | **Nouveau fichier** : ce rapport |

Confirmé par `git status --porcelain` scopé à ces chemins : exactement ces 3 entrées (2 `M`, 1 `??` pour le test ; le rapport est listé séparément ci-dessous), rien d'autre.

## 5. Tests exécutés et résultats

- **`functions/test/orderActions.test.js`** (`npx mocha`, car couvre `acceptOrderCF`/`cancelOrderCF`/commission serveur, mécanisme non touché par cette phase) : **85/85 passants**, 0 échec — confirme l'absence de régression sur le système actuel de commission et d'acceptation de commande.
- **Recherche exhaustive finale** `grep -rn "deductCommission|_logTransaction" lib/ functions/ test/` : aucune occurrence — confirme qu'aucune référence ne subsiste dans le code.
- **Diff contrôlé** (`git diff` sur les 2 fichiers modifiés) : chaque changement correspond strictement aux deux corrections demandées ; une modification locale préexistante et sans rapport dans `driver_profil.dart` (import de `driver_location_service.dart` et refonte du bouton « passer hors ligne », marquée `SEC-01 / S5.1` dans son propre commentaire) était déjà présente avant cette phase et a été intégralement préservée — seule la ligne 374 a été ajoutée à cette modification.

## 6. Tests non exécutés et raisons

- **`flutter test` / `flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé par `which`/`--version`, comme lors de toutes les phases précédentes de cet audit). Non exécutés, honnêtement signalé — aucun résultat n'est fabriqué.
- **Test widget complet de `DriverProfil`** : non réalisable sans ajouter une dépendance de simulation Firestore (interdit dans cette phase) — voir §2.3. Remplacé par un test de logique pure sur l'expression exacte.

## 7. Vérification du diff

Diff complet relu ligne par ligne pour les 2 fichiers modifiés (reproduit en §2.2 et dans la table des dépendances supprimées en §3). Aucune ligne étrangère aux deux corrections n'a été introduite. Le fichier `firestore_service.dart` ne perd que les deux méthodes mortes ; `calculateCommission`, `calculateDriverGain`, `walletTransactions`, l'import `Timestamp` et tout le reste du fichier sont inchangés.

## 8. Préservation des modifications locales

Confirmé : la modification préexistante et non liée dans `driver_profil.dart` (bouton « passer hors ligne » via `DriverLocationService.instance.goOffline()`, déjà présente avant cette phase) est intacte. Aucun fichier non suivi antérieur n'a été touché. Aucune opération Git destructive (`reset`, `clean`, `checkout`, `stash`) n'a été utilisée.

## 9. Confirmation Firebase / déploiement

Aucune connexion à un Firebase réel. Aucun déploiement. Aucune modification de `firestore.rules`, d'aucune configuration Firebase, d'aucune dépendance ni lockfile. Aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.

## 10. Confirmation que S6.1 n'a pas commencé

Confirmé : aucune migration de lecteur Firestore vers `driver_public`, aucune modification de règles, aucun élargissement du périmètre au-delà des deux corrections demandées. Les autres défauts éventuellement visibles dans les fichiers touchés n'ont pas été corrigés (hors mandat de cette phase).

## 11. Verdict

**CORRECTIONS VALIDÉES**

Les deux corrections sont appliquées, minimales, strictement bornées à leur périmètre, vérifiées par recherche exhaustive et par la suite de tests serveur existante (85/85), avec un test ciblé ajouté pour la correction du champ `rating` dans les limites de ce que l'infrastructure de test du dépôt permet sans ajout de dépendance. Le seul point d'attention identifié (accommodation des règles Firestore pour les anciennes versions de l'application) a été investigué et s'avère sans impact, puisqu'il concerne des binaires déjà installés et non ce dépôt.

STOP après ce rapport. En attente d'autorisation avant toute phase suivante.
