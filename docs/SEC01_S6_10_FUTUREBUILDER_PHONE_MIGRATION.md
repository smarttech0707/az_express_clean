# SEC-01 — S6.10 : migration du lecteur téléphone `FutureBuilder` dans `suivi_commande.dart`

Date : 2026-11-22
Type : migration ciblée (1 lecteur, découvert et documenté en S6.9), aucune autre fonctionnalité touchée
Référence : `docs/SEC01_S6_9_PHONE_PUNCTUAL_READERS_MIGRATION.md` §5 (découverte du lecteur), `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md` (callable réutilisée, non modifiée)

## 1. Résumé

Le dernier lecteur direct de `livreurs.phone` dans `suivi_commande.dart` — une carte affichée via `FutureBuilder` dans `_OrderCard` (`StatelessWidget`), qui recréait son `Future` à chaque reconstruction — a été extrait dans un nouveau `StatefulWidget` dédié, `_DriverContactCard`. Celui-ci mémorise deux `Future` (fiche livreur publique sur `livreurs` pour `name`/`photoUrl`, et téléphone via `getDriverPhoneForOrderCF`) dans son état, créés une seule fois par `initState()` et réinitialisés uniquement par `didUpdateWidget()` quand `orderId` ou `driverId` change réellement. Aucune lecture directe de `phone` ne subsiste dans ce composant. La callable S6.8 n'a pas été modifiée — seul son usage a été déplacé d'un site à la mémorisation correcte dans un widget avec état.

## 2. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `lib/screens/client/suivi_commande.dart` | Extraction de la carte livreur (`_OrderCard`) dans un nouveau widget `_DriverContactCard`/`_DriverContactCardState` ; déplacement de `_showPhotoDialog` en fonction top-level `_showDriverPhotoDialog` (seule chose qui l'utilisait) |
| `docs/SEC01_S6_10_FUTUREBUILDER_PHONE_MIGRATION.md` | **Nouveau** — ce rapport |

Aucun autre fichier touché. Aucune Rule, Cloud Function, configuration Firebase, dépendance ou lockfile modifié.

## 3. Le lecteur migré

### État avant migration (vérifié dans le code réel, pas supposé d'après S6.9)

```dart
class _OrderCard extends StatelessWidget {        // StatelessWidget
  ...
  Widget build(BuildContext context) {
    ...
    if (hasDriver)
      FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance
            .collection("livreurs").doc(order.driverId).get(),   // recréé à CHAQUE build()
        builder: (context, snap) {
          final driver = snap.data!.data() as Map<String, dynamic>;
          ...
          Text(driver["phone"] ?? "", ...),        // lecture directe affichée en permanence
          ...
        },
      ),
  }
}
```

`_OrderCard` est un `StatelessWidget` instancié sans `Key` explicite depuis une `ListView` d'`_OrderCard` (une par commande). Le `future:` étant une expression évaluée **dans `build()`**, chaque reconstruction de `_OrderCard` (déclenchée par le `StreamBuilder` parent sur `orders`, par exemple à chaque mise à jour de statut ou de position GPS d'une autre commande de la liste) créait un **nouvel appel Firestore**, et aurait créé un **nouvel appel à la Callable** après une migration naïve du seul contenu du `builder`.

### Solution retenue : extraction en `StatefulWidget` avec mémorisation dans l'état

```dart
class _DriverContactCard extends StatefulWidget {
  final String orderId;
  final String driverId;
  final String? acceptanceSelfie;
  const _DriverContactCard({required this.orderId, required this.driverId, this.acceptanceSelfie});
  @override
  State<_DriverContactCard> createState() => _DriverContactCardState();
}

class _DriverContactCardState extends State<_DriverContactCard> {
  late Future<DocumentSnapshot> _driverFuture;
  late Future<String?> _phoneFuture;

  @override
  void initState() {
    super.initState();
    _startFutures();                 // ← créés UNE SEULE FOIS à la création du widget
  }

  @override
  void didUpdateWidget(_DriverContactCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orderId != widget.orderId || oldWidget.driverId != widget.driverId) {
      _startFutures();               // ← relancés UNIQUEMENT si la commande ou le livreur change
    }
  }

  void _startFutures() {
    _driverFuture = FirebaseFirestore.instance.collection('livreurs').doc(widget.driverId).get();
    _phoneFuture = _fetchPhone();
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
    return FutureBuilder<DocumentSnapshot>(
      future: _driverFuture,          // ← référence au Future mémorisé, jamais recréé ici
      builder: (context, snap) {
        ...
        FutureBuilder<String?>(
          future: _phoneFuture,       // ← idem pour le téléphone
          builder: (context, phoneSnap) => Text(phoneSnap.data ?? "", ...),
        ),
        ...
      },
    );
  }
}
```

`name`/`photoUrl` restent lus sur `livreurs` (hors périmètre de cette mission, qui cible exclusivement `phone`) — seul `phone` provient désormais de la Callable, dans un second `FutureBuilder` imbriqué (même principe d'imbrication qu'en S6.6, mais source = Callable au lieu de `driver_public`, puisque `phone` ne peut par construction jamais être dans cette projection).

Le site d'appel dans `_OrderCard.build()` est devenu :
```dart
if (hasDriver)
  _DriverContactCard(
    orderId: order.id,
    driverId: order.driverId!,          // sûr : hasDriver implique order.driverId != null
    acceptanceSelfie: order.driverAcceptanceSelfie,
  ),
```

`_showPhotoDialog` (utilisée uniquement par cette carte — vérifié par recherche exhaustive, 3 occurrences, toutes dans ce bloc) a été déplacée en fonction top-level `_showDriverPhotoDialog`, réutilisée telle quelle par `_DriverContactCard` — aucun changement de comportement, seulement un déplacement.

## 4. Mécanisme empêchant les appels répétitifs

- **Mémorisation dans l'État, pas dans `build()`** : `_driverFuture`/`_phoneFuture` sont des champs de `_DriverContactCardState`, assignés uniquement dans `_startFutures()` (appelée depuis `initState()` et, conditionnellement, `didUpdateWidget()`). `build()` ne fait que **référencer** ces champs déjà créés — aucune nouvelle requête Firestore ni aucun nouvel appel à la Callable n'est déclenché par une reconstruction normale du widget (ex. `setState` d'un parent, nouveau snapshot `orders` sans changement de commande affichée).
- **Pas de polling** : aucun `Timer`, aucune boucle, aucun `Stream` périodique introduit — un seul appel par Future, exactement comme l'ancien code (qui, lui, en revanche, en relançait un à chaque `build()` — c'est la régression de fond que cette extraction corrige).
- **Pas de cache global** : `_driverFuture`/`_phoneFuture` sont des champs d'instance de `_DriverContactCardState`, propres à cette carte précise — aucune structure statique, aucun `Map` partagé entre cartes, aucune persistance au-delà du cycle de vie de ce widget. Deux commandes différentes affichées simultanément dans la liste ont chacune leur propre instance de `_DriverContactCardState` et leurs propres Futures, sans partage.

## 5. Comportement lors d'un changement d'identifiant de commande

`didUpdateWidget` compare explicitement `orderId` **et** `driverId` entre l'ancien et le nouveau widget :
```dart
if (oldWidget.orderId != widget.orderId || oldWidget.driverId != widget.driverId) {
  _startFutures();
}
```
- **Changement de commande affichée** (`orderId` différent — ex. recyclage d'un emplacement de liste par Flutter) : les deux Futures sont relancés, aucune donnée de l'ancienne commande n'est conservée.
- **Réattribution du livreur en cours de route** (`orderId` identique, `driverId` différent — transfert via `driverTransfer.js`) : les deux Futures sont relancés ; en particulier, la Callable étant rappelée avec le même `orderId`, elle relit elle-même le `driverId` à jour côté serveur (comportement déjà garanti par la Callable S6.8, non modifié ici) — le numéro affiché devient celui du **nouveau** livreur, jamais l'ancien.
- **Aucun changement** (ni `orderId` ni `driverId` différents, seule une reconstruction normale) : `_startFutures()` n'est **pas** rappelée — c'est précisément le mécanisme qui élimine les appels répétitifs (§4).

## 6. Gestion des erreurs

- **Fiche livreur publique (`livreurs`, `name`/`photoUrl`)** : comportement inchangé par rapport à l'ancien code — `snap.hasData`/`snap.data!.exists` gèrent l'absence de données ; en cas d'échec, la carte entière reste masquée (`SizedBox.shrink()`), comme avant.
- **Téléphone (Callable)** : `_fetchPhone()` capture toute exception (`permission-denied`, `resource-exhausted`, `failed-precondition`, `not-found`, erreur réseau) et retourne `null` — jamais de propagation d'exception non gérée, jamais de repli vers une lecture directe de `livreurs.phone`. Le `FutureBuilder<String?>` interne affiche `phoneSnap.data ?? ""` : pendant le chargement (`phoneSnap.data == null`) et en cas d'échec (même résultat, `null`), le texte est simplement vide — jamais un numéro obsolète, fabriqué, ou celui d'un autre livreur.
- **Pas de message d'erreur visible dédié** pour l'échec du téléphone dans cette carte précise : comportement délibérément aligné sur l'ancien (qui, lui non plus, n'affichait jamais de message d'erreur pour cette carte — seule une absence de texte) ; un échec se traduit donc par une ligne vide sous le nom du livreur, cohérent avec « respecter les interfaces et comportements existants autant que possible ».

## 7. Tests réellement exécutés

- **Recherche de tests existants** : aucun fichier de test ne cible `_OrderCard`/`_DriverContactCard`/la carte livreur de `suivi_commande.dart` (confirmé, comme en S6.9).
- **Test déjà existant réutilisable** : `test/services/driver_phone_callable_response_test.dart` (créé en S6.9) couvre déjà exhaustivement l'expression d'extraction `((data as Map?)?['data'] as Map?)?['phone'] as String?`, strictement identique à celle utilisée dans `_fetchPhone()` ici — **aucun nouveau test n'a donc été créé**, pour éviter une duplication stricte d'un test déjà existant sur la même logique.
- **`npx mocha` / suite `functions/`** : non ré-exécutée — aucune Cloud Function modifiée dans cette phase.
- **`flutter test`/`flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente de cet audit). **Non exécutés, honnêtement signalé** — en particulier, le comportement de mémorisation du `Future` à travers les reconstructions (`initState`/`didUpdateWidget`) et l'absence d'appel répété ne sont **pas vérifiés par un test automatisé réel** dans cette phase ; la correction repose sur l'application rigoureuse du pattern standard Flutter (mémorisation dans l'État), pas sur une exécution observée.

## 8. Validations statiques

- **Lecture intégrale** du nouveau widget après édition, pour confirmer l'équilibre des accolades/parenthèses (vérifié aussi par un comptage automatisé global du fichier : profondeur d'accolades et de parenthèses revenant exactement à 0 sur l'ensemble du fichier).
- **`grep` de contrôle** : confirmé qu'aucune lecture `driver["phone"]`/`d['phone']` ne subsiste dans `_DriverContactCard` — seule la lecture `livreurs` pour `photoUrl`/`name` demeure (hors périmètre de cette phase). Confirmé que `_showPhotoDialog` n'a pas de second appelant oublié (recherche exhaustive, 3 occurrences, toutes migrées vers `_showDriverPhotoDialog`).
- **Vérification du paramètre transmis à la Callable** : confirmé par relecture que `_fetchPhone()` transmet exclusivement `{'orderId': widget.orderId}` — jamais `driverId` ni aucun numéro.
- **`git diff` ciblé** : la modification est contenue dans `lib/screens/client/suivi_commande.dart` ; aucune autre fonctionnalité du fichier (paiement wallet, annulation, chat, notation, GPS `_listenDriver`, bannière pharmacie) n'a été touchée — confirmé par relecture du diff complet.
- **Pas de blocage architectural rencontré** : l'extraction en `StatefulWidget` a suffi — aucun changement hors périmètre (Rules, `driver_public`, Callable S6.8, autres écrans) n'a été nécessaire.

## 9. Réserves

- **Aucun test automatisé du cycle de vie Flutter** (§7) : la garantie « pas d'appel répété » et « réinitialisation correcte au changement de commande/livreur » repose sur l'application du pattern standard, pas sur une exécution vérifiée (`flutter test` indisponible).
- **Pas d'indicateur de chargement dédié au téléphone** : le texte reste vide pendant la résolution du `Future` (comme avant la migration, où le chargement du livreur entier masquait toute la carte) — léger changement de granularité (le nom peut apparaître avant le numéro) mais pas une régression fonctionnelle perçue comme problématique au vu du comportement préexistant déjà asynchrone.
- **`name`/`photoUrl` restent sur `livreurs`** (non migrés vers `driver_public`) : décision délibérée pour rester strictement dans le périmètre de cette mission (uniquement `phone`) — une migration future de ces champs publics resterait possible dans une phase séparée et explicitement autorisée.
- **Pas de `Key` explicite sur `_DriverContactCard`** : le widget s'appuie sur `didUpdateWidget` pour détecter tout changement de commande/livreur à la même position d'arbre, ce qui est correct et suffisant tant que `_OrderCard` lui-même garde une position stable dans la liste (comportement Flutter standard sans clé explicite, inchangé par rapport à l'architecture préexistante de cet écran).

## 10. Confirmation

Aucune Firestore Rule modifiée. Aucune configuration Firebase modifiée. Aucun déploiement (Cloud Function ou Rules) exécuté. `driver_public` non modifié. La Callable `getDriverPhoneForOrderCF` (S6.8) n'a pas été modifiée — aucun blocage critique ne l'a exigé. `admin_map.dart`, `live_marker_cache.dart`, et les 3 `StreamBuilder` de téléphone de S6.6 (`pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`) n'ont pas été touchés. Aucune dépendance ni lockfile modifié. Aucun accès Firebase réel, aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié. Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée. Les modifications locales préexistantes et sans rapport dans ce fichier (confirmées en S6.9) restent intactes.

## 11. Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

Le dernier lecteur direct de `livreurs.phone` identifié dans `suivi_commande.dart` est migré vers `getDriverPhoneForOrderCF`, avec une solution adaptée au cycle de vie Flutter (mémorisation du `Future` dans un `StatefulWidget` dédié, réinitialisation ciblée uniquement sur changement réel de commande ou de livreur) — sans polling, sans cache global, sans repli vers la lecture directe, et sans jamais afficher un numéro obsolète. La callable S6.8 et toutes les autres fonctionnalités du fichier restent inchangées. La réserve porte sur l'absence de validation par exécution réelle (`flutter test`/`flutter analyze` indisponibles dans cet environnement, comme à chaque phase précédente) — la correction du mécanisme anti-répétition repose sur une application rigoureuse et relue du pattern standard, pas sur une observation d'exécution.

STOP après ce rapport. Aucune autre phase commencée sans autorisation explicite.
