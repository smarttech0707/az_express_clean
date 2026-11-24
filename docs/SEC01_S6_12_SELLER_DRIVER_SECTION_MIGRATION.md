# SEC-01 — S6.12 : migration du lecteur téléphone — `seller_dashboard.dart::_DriverSection`

Date : 2026-11-22
Type : migration ciblée (1 lecteur), aucune autre fonctionnalité touchée
Référence : `docs/SEC01_S6_11_STREAMBUILDER_PHONE_AUDIT.md` (stratégie recommandée), `docs/SEC01_S6_10_FUTUREBUILDER_PHONE_MIGRATION.md` (pattern réutilisé), `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md` (callable, non modifiée)

## Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

## 1. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `lib/screens/seller/seller_dashboard.dart` | `_DriverSection` converti en `StatefulWidget` (`_DriverSectionState`) ; import `cloud_functions` ajouté ; site d'appel mis à jour (`orderId: order.id` ajouté) |
| `docs/SEC01_S6_12_SELLER_DRIVER_SECTION_MIGRATION.md` | **Nouveau** — ce rapport |

Aucun autre fichier touché (confirmé par `git status` scopé). Aucune Rule, Cloud Function, configuration Firebase, dépendance ou lockfile modifiée.

## 2. Lecteur migré

Chemin exact retrouvé et vérifié avant modification : `lib/screens/seller/seller_dashboard.dart::_DriverSection` (anciennement `StatelessWidget`, lignes 1413-1571 avant migration), instanciée ligne 1274 dans `_OrderCard.build()` (`order` — un `OrderModel` complet — déjà dans le scope).

Seule la lecture de `phone` est concernée. `name`/`lat`/`lng`/`isOnline` continuent d'être lus en continu depuis `driver_public` via le même `StreamBuilder` qu'avant (S6.6, inchangé par cette phase).

## 3. Architecture mise en place

`_DriverSection` (`StatelessWidget`) → `_DriverSection` (`StatefulWidget`) + `_DriverSectionState` :

```dart
class _DriverSection extends StatefulWidget {
  final String orderId;
  final String driverId;
  const _DriverSection({required this.orderId, required this.driverId});
  @override
  State<_DriverSection> createState() => _DriverSectionState();
}

class _DriverSectionState extends State<_DriverSection> {
  late Future<String?> _phoneFuture;

  @override
  void initState() {
    super.initState();
    _phoneFuture = _fetchPhone();          // créé UNE SEULE FOIS
  }

  @override
  void didUpdateWidget(_DriverSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orderId != widget.orderId || oldWidget.driverId != widget.driverId) {
      setState(() { _phoneFuture = _fetchPhone(); });   // relancé SEULEMENT si pertinent
    }
  }

  Future<String?> _fetchPhone() async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('getDriverPhoneForOrderCF')
          .call({'orderId': widget.orderId});
      return ((result.data as Map?)?['data'] as Map?)?['phone'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(          // inchangé : driver_public, name/lat/lng/isOnline
      stream: FirebaseFirestore.instance.collection('driver_public').doc(widget.driverId).snapshots(),
      builder: (context, snap) {
        ...
        return FutureBuilder<String?>(               // nouveau : phone via la Callable
          future: _phoneFuture,                      // référence le Future mémorisé, jamais recréé ici
          builder: (context, phoneSnap) => _buildCard(name, phoneSnap.data, lat, lng, isOnline),
        );
      },
    );
  }

  Widget _buildCard(...) { ... }   // contenu visuel inchangé
}
```

Le site d'appel dans `_OrderCard.build()` est devenu :
```dart
_DriverSection(orderId: order.id, driverId: order.driverId!)
```

L'affichage (`_buildCard`), le bouton d'appel, le lien « Voir sur la carte », les gardes `if (phone != null)` déjà présentes, et toute la logique de livraison/paiement/statut de `_OrderCard` restent **inchangés**.

## 4. Mécanisme anti-appels répétitifs

- `_phoneFuture` est un champ de `_DriverSectionState`, assigné uniquement dans `initState()`/`didUpdateWidget()` — jamais dans `build()`.
- Le `StreamBuilder` extérieur sur `driver_public` continue de se reconstruire au rythme des écritures GPS (~5 s pendant une livraison active, confirmé en S6.11) ; `build()` **référence** `_phoneFuture` à chaque reconstruction, sans jamais le recréer — donc sans jamais rappeler la Callable à ce rythme. C'est précisément le risque identifié en S6.11 (une migration naïve dans le `builder` aurait rappelé la Callable toutes les ~5 s), ici évité par construction.
- Aucun `Timer`, aucune boucle, aucun polling introduit.
- Aucun cache global : `_phoneFuture` est un champ d'instance propre à cette carte précise — aucune structure statique ni partagée entre plusieurs `_DriverSection`.

## 5. Gestion de `didUpdateWidget`

```dart
if (oldWidget.orderId != widget.orderId || oldWidget.driverId != widget.driverId) {
  setState(() { _phoneFuture = _fetchPhone(); });
}
```
- **Changement de commande affichée** (`orderId` différent) : le Future est relancé.
- **Réattribution du livreur** (`orderId` identique, `driverId` différent — transfert via `driverTransfer.js`) : le Future est relancé ; la Callable relit elle-même `order.driverId` à jour côté serveur (comportement garanti par la Callable S6.8, non modifiée) — le numéro affiché devient celui du **nouveau** livreur.
- **Aucun changement pertinent** (reconstruction normale, y compris celles pilotées par le GPS sur `driver_public`) : le Future n'est **pas** relancé — c'est le mécanisme du §4.
- L'appel à `_fetchPhone()` est entouré de `setState(...)` dans `didUpdateWidget`, pour que le nouveau `FutureBuilder` observe bien la nouvelle instance de Future (nécessaire car `didUpdateWidget` seul ne déclenche pas de reconstruction).

## 6. Gestion des erreurs

`_fetchPhone()` capture toute exception (`permission-denied`, `resource-exhausted`, `failed-precondition`, `not-found`, erreur réseau) et retourne `null` — **aucun repli vers une lecture directe de `livreurs.phone`**. Le `FutureBuilder<String?>` intérieur transmet `phoneSnap.data` (donc `null` pendant le chargement et en cas d'échec) à `_buildCard`, qui applique déjà les gardes préexistantes `if (phone != null)` (texte et bouton d'appel) — ni numéro incorrect, ni numéro obsolète, ni bouton actif sur une valeur vide, exactement comme demandé.

## 7. Tests exécutés et résultats

- **Recherche de tests existants** : aucun fichier de test ne cible `seller_dashboard.dart`/`_DriverSection` (confirmé, comme pour les lecteurs migrés en S6.9/S6.10).
- **Test déjà existant réutilisable, non dupliqué** : `test/services/driver_phone_callable_response_test.dart` (créé en S6.9) couvre déjà exhaustivement l'expression d'extraction `((data as Map?)?['data'] as Map?)?['phone'] as String?`, strictement identique à celle utilisée dans `_fetchPhone()` ici — aucun nouveau test créé, pour éviter une duplication stricte.
- **`flutter test`/`flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente). **Non exécutés, honnêtement signalé** — en particulier, l'absence d'appel répété lors des reconstructions pilotées par le GPS n'est validée que par relecture du mécanisme (§4), pas par une exécution observée.

## 8. Validations statiques

- **Équilibre global des accolades/parenthèses** vérifié par comptage automatisé sur l'ensemble du fichier modifié : profondeur de 0 dans les deux cas (confirmé après édition).
- **`grep` de contrôle** : confirmé qu'**aucune** occurrence de `collection('livreurs')`/`collection("livreurs")` ne subsiste dans `seller_dashboard.dart` — le lecteur ciblé était le seul de ce fichier.
- **Vérification du paramètre transmis à la Callable** : confirmé par relecture que `_fetchPhone()` transmet exclusivement `{'orderId': widget.orderId}` — jamais `driverId` ni aucun numéro.
- **`git diff` ciblé** : la modification est strictement isolée dans la zone de `_DriverSection`/`_OrderCard` (site d'appel) ; les hunks pré-existants et sans rapport du fichier (import `min_version_dialog`, bloc `showMinVersionDialogIfNeeded` dans `initState` du dashboard) sont restés intacts, confirmés par lecture complète du diff.
- **Relecture de la carte vendeur (`_InfoSection`, boutons, logique de commande)** : confirmée inchangée au-delà de l'unique ligne du site d'appel.

## 9. Réserves

- **Aucune validation par exécution réelle** (§7/§8) : la garantie « pas d'appel répété » et « relance correcte sur changement » repose sur une application rigoureuse et relue du pattern déjà validé en S6.10, pas sur un test automatisé exécuté — `flutter`/`dart` indisponibles dans cet environnement, comme à chaque phase Flutter de cet audit.
- **Pas de `Key` explicite** sur `_DriverSection`/`_OrderCard` dans la liste des commandes : comportement Flutter standard déjà présent avant cette migration (inchangé) — `didUpdateWidget` reste le mécanisme de détection de changement, suffisant tant que la position du widget dans l'arbre reste stable, cohérent avec le choix déjà fait et documenté en S6.10.
- **Portée strictement limitée à `seller_dashboard.dart`** : `pharmacie_dashboard.dart` et `boulangerie_dashboard.dart`, identifiés dans le même audit S6.11, restent avec leur `StreamBuilder` imbriqué sur `livreurs` — non touchés, conformément au périmètre strict de cette mission.

## 10. Confirmation

Aucune Firestore Rule modifiée. Aucune configuration Firebase modifiée. Aucun déploiement (Cloud Function ou Rules) exécuté. Aucune dépendance ni lockfile modifié (`package:cloud_functions` était déjà une dépendance existante, utilisée ailleurs dans le dépôt — seul un import de ce paquet déjà présent a été ajouté). La Callable `getDriverPhoneForOrderCF` n'a pas été modifiée, aucun contrôle serveur contourné. `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `admin_map.dart`, `live_marker_cache.dart`, `suivi_commande.dart`, `customer_tracking_screen.dart`, `web_client_dashboard.dart`, `driver_public` : non touchés. Aucun accès Firebase réel, aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée. Les modifications locales préexistantes et sans rapport dans ce fichier restent intactes.

STOP après ce rapport. Aucune autre phase (S6.13) commencée sans autorisation explicite.
