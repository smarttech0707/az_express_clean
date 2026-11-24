# SEC-01 — S6.4 : migration des lecteurs hybrides vers `driver_public`

Date : 2026-11-21
Type : migration ciblée (1 champ migré sur 1 lecteur, 6 lecteurs exclus avec justification)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` §4/B, §8 « Phase S6.4 », §13 ; `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md` ; `docs/SEC01_S6_3_1_VEHICLE_LIVE_MARKER_AUDIT.md`

## 1. Résumé exécutif

Des 7 lecteurs hybrides identifiés par le plan S6.0 (§4/B), **un seul champ, sur un seul lecteur**, a été migré : `avgRating` dans `driver_dashboard.dart::_listenDriverDoc`, désormais lu depuis `driver_public` via un second abonnement, tandis que `wallet` et `pendingOrderId` (privés) restent sur `livreurs` via l'abonnement existant, inchangé. Les 6 autres lecteurs hybrides n'ont pas été migrés : 5 nécessitent `phone` dans la même lecture (exclusion explicitement demandée) et 1 (`driver_profil.dart`) a été exclu après examen pour une raison nouvelle et spécifique, détaillée en §3.2 — un risque concret de régression visible (latence de synchronisation sur sa propre photo juste après l'avoir changée), distinct des raisons déjà connues. Aucune Rules, Cloud Function, configuration, ni `live_marker_cache.dart` n'a été touché.

## 2. Lecteurs examinés (les 7 candidats hybrides du plan S6.0 §4/B)

| Lecteur | Champs publics | Champ(s) privé(s) | Décision |
|---|---|---|---|
| `driver_dashboard.dart::_listenDriverDoc` | `avgRating` | `wallet`, `pendingOrderId` | **Migré** (champ public uniquement) |
| `driver_profil.dart` (StreamBuilder) | `photoUrl` | `wallet`, `deliveries` | **Exclu** — raison nouvelle (§3.2) |
| `admin_map.dart` | `lat`, `lng`, `name` | `phone` (même lecture) | **Exclu** — nécessite `phone` |
| `pharmacie_dashboard.dart::_DriverInfoCard` | `name`, `photoUrl` | `phone`, `motoModel` (même lecture) | **Exclu** — nécessite `phone` |
| `boulangerie_dashboard.dart` (inline builder) | `name`, `isOnline` | `phone` (même lecture) | **Exclu** — nécessite `phone` |
| `seller_dashboard.dart::_DriverSection` | `name`, `lat`, `lng`, `isOnline` | `phone` (même lecture) | **Exclu** — nécessite `phone` |
| `customer_tracking_screen.dart::_loadDriverInfoById` | `name`, `photoUrl`, `avgRating` | `phone` (même lecture) | **Exclu** — nécessite `phone` |

## 3. Examen détaillé

### 3.1 `driver_dashboard.dart::_listenDriverDoc` (migré)

Code avant migration (lignes 123-138) :

```dart
void _listenDriverDoc() {
  _driverSub = FirebaseFirestore.instance
      .collection('livreurs')
      .doc(widget.driverId)
      .snapshots()
      .listen((snap) {
    if (!mounted) return;
    final data = snap.data() ?? {};
    setState(() {
      _wallet = (data['wallet'] as num? ?? 0).toInt();
      _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
    });
    _handleBroadcastOrder(data['pendingOrderId'] as String?);
  });
}
```

- **Vérification des champs** : `wallet` (solde, privé, doit rester sur `livreurs`), `avgRating` (statistique publique, synchronisée par le serveur depuis S5.3.5, jamais écrite directement par le livreur — confirmé en S6.0 §5), `pendingOrderId` (détection de commande broadcast, logique de dispatch, privé — déclenche `_handleBroadcastOrder`, qui ouvre un second abonnement sur `orders`, non touché).
- **Aucune dépendance à `phone`** dans ce lecteur — seul candidat du lot sans ce blocage.
- **Pas de risque de latence d'auto-édition** : contrairement à `photoUrl` (voir §3.2), `avgRating` n'est jamais modifié par une action du livreur lui-même dans l'écran qui le lit — c'est une statistique calculée côté serveur à partir des notes clients, mise à jour de façon asynchrone de toute façon (avant comme après cette migration).
- **Modification appliquée** : ajout d'un second abonnement Firestore, dédié, sur `driver_public/{driverId}`, qui met à jour uniquement `_avgRating`. L'abonnement existant sur `livreurs` est conservé à l'identique pour `wallet`/`pendingOrderId`.

```diff
   void _listenDriverDoc() {
     _driverSub = FirebaseFirestore.instance
         .collection('livreurs')
         .doc(widget.driverId)
         .snapshots()
         .listen((snap) {
       if (!mounted) return;
       final data = snap.data() ?? {};
       setState(() {
         _wallet = (data['wallet'] as num? ?? 0).toInt();
-        _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
       });
       _handleBroadcastOrder(data['pendingOrderId'] as String?);
     });
+    // SEC-01 / S6.4 : `avgRating` est un champ public (synchronisé par le
+    // serveur depuis S5.3.5, jamais écrit par le livreur lui-même) → lu
+    // séparément depuis la projection `driver_public`, pendant que `wallet`
+    // et `pendingOrderId` (privés) restent sur `livreurs` ci-dessus.
+    _driverPublicSub = FirebaseFirestore.instance
+        .collection('driver_public')
+        .doc(widget.driverId)
+        .snapshots()
+        .listen((snap) {
+      if (!mounted) return;
+      final data = snap.data() ?? {};
+      setState(() {
+        _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
+      });
+    });
   }
```

Déclaration du nouveau champ (`StreamSubscription<DocumentSnapshot>? _driverPublicSub;`, juste après `_driverSub`) et annulation dans `dispose()` (`_driverPublicSub?.cancel();`, juste après `_driverSub?.cancel();`) — mécanisme de désabonnement strictement symétrique à l'existant, pas de nouveau pattern.

- **Pourquoi ce n'est pas une nouvelle architecture** : `driver_dashboard.dart` gère déjà, avant cette migration, 4 `StreamSubscription` indépendantes dans le même `State` (`_driverSub`, `_pendingSub`, `_deliverySub`, `_broadcastOrderSub`) ; en ajouter une cinquième suit exactement le pattern déjà établi, sans introduire de nouveau concept (pas de combinaison de flux, pas de nouvelle classe, pas de nouveau service).

### 3.2 `driver_profil.dart` — exclu pour une raison nouvelle et spécifique

Le plan S6.0 (§4/B) avait classé ce lecteur comme hybride migrable (`photoUrl` → `driver_public`, `wallet`/`deliveries`/`rating` restent sur `livreurs`), avec seulement une réserve générique de latence de synchronisation (§6, « un livreur qui vient de changer sa photo peut voir l'ancienne pendant quelques secondes »). Un examen plus précis, fait dans cette phase, révèle que ce risque n'est pas seulement générique mais **immédiat et concret** pour cet écran précis :

`driver_profil.dart` contient, dans le même écran que celui qui afficherait la photo migrée, l'action d'upload elle-même :

```dart
SinglePhotoEditor(
  photoUrl: photoUrl,
  storagePath: 'driver_photos/${widget.driverId}/profile.jpg',
  ...
  onUploaded: (url) async {
    await FirebaseFirestore.instance
        .collection('livreurs')
        .doc(widget.driverId)
        .update({'photoUrl': url});
  },
  ...
)
```

Le livreur écrit directement `livreurs.photoUrl` (son propre document, écriture autorisée par les Rules). Depuis S5.3.5, le livreur **ne peut plus** écrire directement `driver_public.photoUrl` (`unchanged('photoUrl')` dans la règle d'update, confirmé en S5.3.5) — seule la synchronisation serveur (`driverPublicSync.js`) le fait, de façon asynchrone. Si l'affichage de `photoUrl` dans cet écran était migré vers `driver_public`, le livreur qui vient de changer sa propre photo **ne la verrait pas changer immédiatement sur son propre écran** — une régression visible et immédiate de son propre point de vue, pas seulement une latence abstraite affectant un tiers (comme c'est le cas pour `name`/`photoUrl` vus par un client sur un autre écran, où la latence de quelques secondes est largement acceptable).

**Décision** : exclusion de `driver_profil.dart` de cette phase. Ce n'est ni un cas de `phone`, ni un champ absent de `driver_public` — c'est un risque de régression comportementale concret, découvert par l'examen détaillé demandé par cette mission (« ne pas élargir le périmètre sur la base de suppositions », appliqué ici dans l'autre sens : ne pas migrer sur la base d'une supposition d'innocuité qu'un examen plus poussé contredit). Une migration future de ce champ précis resterait possible, mais seulement après une décision explicite sur la façon de gérer l'affichage immédiat de la propre photo du livreur (ex. lecture optimiste locale après upload, hors périmètre de cette phase).

### 3.3 Les 5 lecteurs exclus pour dépendance à `phone`

Vérifiés individuellement par lecture du code (pas par présomption) :

- **`admin_map.dart:24,67,75`** : `.collection("livreurs").snapshots()` (tous les livreurs, sans filtre), `phone` lu dans le même document et affiché en snippet du marqueur (ligne 75). De plus, cet écran appartient à la console admin, déjà positionnée par S6.0 §6 comme ne devant jamais être migrée (accès légitime complet déjà garanti par `isAdmin()`, aucun gain de sécurité à migrer).
- **`pharmacie_dashboard.dart:962-973`** : un seul `get()`/stream sur `livreurs/{id}` lisant `phone` (ligne 971) **et** `motoModel` (ligne 973, absent de `driver_public`) dans le même bloc que `name`/`photoUrl`. Double motif d'exclusion (phone + champ absent), aucun à séparer dans cette phase.
- **`boulangerie_dashboard.dart:708-715`** : un seul `.collection('livreurs')...` lisant `dPhone` (ligne 715, `d['phone']`) avec `name`/`isOnline` dans le même bloc.
- **`seller_dashboard.dart:1421-1437`** : un seul `.collection('livreurs')...` lisant `phone` (ligne 1437) avec `name`/`lat`/`lng`/`isOnline` dans le même bloc, utilisé pour un bouton d'appel direct (ligne 1540, `tel:$phone`).
- **`customer_tracking_screen.dart:313-321`** : `_loadDriverInfoById`, un seul `get()` lisant `phone` (ligne 321) avec `name`/`photoUrl`/`avgRating` dans le même appel.

Dans les 5 cas, `phone` est lu **dans la même requête Firestore** que les champs publics — une migration du lecteur nécessiterait soit d'accepter de perdre `phone` (régression fonctionnelle refusée par les contraintes), soit d'ajouter une seconde lecture séparée sur `livreurs` pour `phone` seul. Cette dernière option n'a pas été mise en œuvre : elle s'apparente à une forme de séparation similaire à l'Option C de S6.3.1, que cette mission interdit explicitement d'appliquer à `live_marker_cache.dart` et, par cohérence avec l'esprit de cette interdiction et l'instruction explicite « ne pas migrer les lecteurs nécessitant `phone` », n'a pas été étendue à ces 5 lecteurs non plus sans autorisation explicite distincte.

## 4. Lecteurs migrés et leurs fichiers/lignes

- `lib/screens/driver/driver_dashboard.dart` — méthode `_listenDriverDoc()` (déclaration originale lignes 123-138) : champ `avgRating` migré vers un second abonnement sur `driver_public/{driverId}` ; `wallet`/`pendingOrderId` inchangés sur `livreurs`. Déclaration de `_driverPublicSub` (après `_driverSub`) et annulation dans `dispose()`.

## 5. Lecteurs exclus et justification

Voir tableau §2 et détail §3.2 (`driver_profil.dart`, risque de régression d'auto-édition) et §3.3 (5 lecteurs, dépendance directe à `phone` dans la même requête).

## 6. Modifications exactes

```diff
--- a/lib/screens/driver/driver_dashboard.dart
+++ b/lib/screens/driver/driver_dashboard.dart
@@ (déclaration des abonnements)
   StreamSubscription<DocumentSnapshot>? _driverSub;
+  StreamSubscription<DocumentSnapshot>? _driverPublicSub;
@@ _listenDriverDoc()
   void _listenDriverDoc() {
     _driverSub = FirebaseFirestore.instance
         .collection('livreurs')
         .doc(widget.driverId)
         .snapshots()
         .listen((snap) {
       if (!mounted) return;
       final data = snap.data() ?? {};
       setState(() {
         _wallet = (data['wallet'] as num? ?? 0).toInt();
-        _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
       });
       _handleBroadcastOrder(data['pendingOrderId'] as String?);
     });
+    _driverPublicSub = FirebaseFirestore.instance
+        .collection('driver_public')
+        .doc(widget.driverId)
+        .snapshots()
+        .listen((snap) {
+      if (!mounted) return;
+      final data = snap.data() ?? {};
+      setState(() {
+        _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
+      });
+    });
   }
@@ dispose()
     _driverSub?.cancel();
+    _driverPublicSub?.cancel();
     _pendingSub?.cancel();
```

Aucune autre ligne de `driver_dashboard.dart` n'a été touchée par cette migration (le fichier contenait, avant cette phase, de nombreuses modifications locales préexistantes et sans rapport — confirmées intactes par `git diff` ciblé, §9).

## 7. Tests exécutés et résultats

- **Recherche de tests existants** : `test/**/driver_dashboard*` — aucun fichier trouvé. Aucun test existant à adapter pour ce fichier.
- **Expression de repli déjà testée** : `(data['avgRating'] as num? ?? 0).toDouble()` est l'expression exacte déjà couverte par `test/screens/driver/driver_profil_rating_test.dart` (créé en S6.0.3, 6 cas : présent, absent, `null`, type inattendu, etc.) — **aucun nouveau test n'a été créé**, car il aurait été strictement redondant avec un test déjà existant sur la même expression de parsing. Conforme à la consigne « ajouter ou adapter des tests ciblés uniquement si cela est nécessaire ».
- **Validation statique** : lecture intégrale de la méthode modifiée et de `dispose()` pour confirmer la symétrie de création/annulation des abonnements ; `grep` confirmant qu'aucune autre référence à `_avgRating` dans le fichier n'est affectée (ligne 1106, affichage, inchangée) ; `git diff` ciblé confirmant que la modification est strictement limitée aux 3 points indiqués en §6.
- **`flutter test` / `flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente de cet audit — aucun résultat n'est fabriqué). Non exécuté, honnêtement signalé ; seule la validation statique ci-dessus a été effectuée.

## 8. Réserves éventuelles

- **`driver_profil.dart`** reste un candidat futur pour `photoUrl`, mais seulement après une décision explicite sur la gestion de l'auto-édition (§3.2) — non traité ici.
- **Les 5 lecteurs à `phone`** restent sur `livreurs` dans leur intégralité ; leur migration éventuelle dépendrait soit du mécanisme `driverPhone` serveur (catégorie D/S6.5), soit d'une décision explicite d'autoriser une séparation de lecture analogue à l'Option C de S6.3.1 — ni l'une ni l'autre n'est tranchée ici.
- **Fenêtre de synchronisation `driver_public`** (déjà documentée depuis S6.0) : `avgRating` sur le tableau de bord livreur peut être en retard de quelques secondes par rapport à une note tout juste enregistrée côté serveur — risque cosmétique déjà accepté pour les migrations précédentes (S6.1/S6.2/S6.3), sans particularité nouvelle ici (pas d'auto-édition de ce champ par le livreur).

## 9. Confirmation qu'aucun périmètre interdit n'a été touché

- `lib/widgets/live_marker_cache.dart` : **non modifié** (confirmé par `git status`/`git diff` scopés — absent de la liste des fichiers touchés par cette phase).
- Option C de S6.3.1 : **non implémentée** — aucune séparation de lecteur n'a été appliquée à `live_marker_cache.dart` ni à aucun des 5 lecteurs à `phone`.
- Aucun lecteur nécessitant `phone` n'a été migré.
- Aucun code supplémentaire supprimé ou neutralisé (contrairement à S6.0.3, cette phase n'a procédé à aucune suppression).
- `firestore.rules` : non modifié.
- Aucune Cloud Function modifiée.
- Aucune configuration Firebase modifiée.
- Aucune dépendance ni lockfile modifié.
- Aucun accès Firebase réel, aucun déploiement, aucun APK/AAB généré.
- Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.
- Aucune opération Git destructive, aucun commit, aucun push, aucun changement de branche.
- Les très nombreuses modifications locales préexistantes et sans rapport (dans `driver_dashboard.dart` notamment, et dans le reste du dépôt) sont restées intactes — confirmé par `git diff` ciblé, isolant strictement les 3 changements de cette phase (§6) du reste du diff préexistant du fichier.

## 10. Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

Le seul champ réellement migrable sans risque parmi les 7 lecteurs hybrides candidats l'a été (`avgRating` dans `driver_dashboard.dart`), avec un changement minimal suivant un pattern déjà établi dans le fichier (abonnements multiples). Les 6 autres lecteurs ont été examinés individuellement et exclus pour des raisons vérifiées et documentées : 5 pour une dépendance directe à `phone` dans la même requête (conformément à l'interdiction explicite), et 1 (`driver_profil.dart`) pour un risque de régression concret et nouvellement identifié (latence d'auto-édition de la photo de profil), plutôt que pour la seule réserve générique déjà connue. La réserve porte sur ces 6 lecteurs non migrés, volontairement laissés intacts plutôt que migrés par supposition.

STOP après ce rapport. Ne pas commencer S6.5 ni une autre phase sans autorisation explicite.
