# SEC-01 — S6.13 : migration du lecteur téléphone — `pharmacie_dashboard.dart::_DriverInfoCard`

Date : 2026-11-22
Type : migration ciblée (1 lecteur), aucune autre fonctionnalité touchée
Référence : `docs/SEC01_S6_11_STREAMBUILDER_PHONE_AUDIT.md`, `docs/SEC01_S6_12_SELLER_DRIVER_SECTION_MIGRATION.md` (pattern réutilisé), `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md` (callable, non modifiée)

## Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

## 1. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `lib/screens/pharmacie/pharmacie_dashboard.dart` | `_DriverInfoCard` converti en `StatefulWidget` (`_DriverInfoCardState`) ; import `cloud_functions` ajouté ; site d'appel mis à jour (`orderId: orderId` ajouté) |
| `docs/SEC01_S6_13_PHARMACIE_DRIVER_CARD_MIGRATION.md` | **Nouveau** — ce rapport |

Aucun autre fichier touché (confirmé par `git status` scopé). Aucune Rule, Cloud Function, configuration Firebase, dépendance ou lockfile modifiée.

## 2. Lecteur migré

Chemin exact retrouvé et vérifié avant modification : `lib/screens/pharmacie/pharmacie_dashboard.dart::_DriverInfoCard` (lignes 947-1133 avant migration), instanciée dans `_PharmacieOrderCard.build()`, qui possède déjà `final String orderId;` (confirmé en S6.11, re-vérifié ici).

Seule la lecture de `phone` est concernée. `name`/`photoUrl` continuent d'être lus en continu depuis `driver_public` (inchangé). `motoModel` continue d'être lu en continu depuis `livreurs` (inchangé — ce n'est pas une donnée de contact, sa migration vers `driver_public` n'était pas demandée et n'a pas été faite).

## 3. Architecture mise en place

`_DriverInfoCard` (`StatelessWidget`) → `_DriverInfoCard` (`StatefulWidget`) + `_DriverInfoCardState` :

```dart
class _DriverInfoCard extends StatefulWidget {
  final String orderId;
  final String driverId;
  final String status;
  const _DriverInfoCard({required this.orderId, required this.driverId, required this.status});
  @override
  State<_DriverInfoCard> createState() => _DriverInfoCardState();
}

class _DriverInfoCardState extends State<_DriverInfoCard> {
  late Future<String?> _phoneFuture;

  @override
  void initState() {
    super.initState();
    _phoneFuture = _fetchPhone();            // créé UNE SEULE FOIS
  }

  @override
  void didUpdateWidget(_DriverInfoCard oldWidget) {
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

  Future<void> _call(String phone) async { ... }       // inchangé

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(             // inchangé : driver_public, name/photoUrl
      stream: FirebaseFirestore.instance.collection('driver_public').doc(widget.driverId).snapshots(),
      builder: (context, snap) {
        ...
        return StreamBuilder<DocumentSnapshot>(          // inchangé : livreurs, motoModel SEUL désormais
          stream: FirebaseFirestore.instance.collection('livreurs').doc(widget.driverId).snapshots(),
          builder: (context, privSnap) {
            final moto = (privSnap.data?.data() as Map?)?['motoModel'] as String? ?? '';
            return FutureBuilder<String?>(                // nouveau : phone via la Callable
              future: _phoneFuture,                       // référence le Future mémorisé, jamais recréé ici
              builder: (context, phoneSnap) {
                final phone = phoneSnap.data ?? '';
                return _buildCard(context, name, phone, photo, moto);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCard(...) { ... }   // contenu visuel et _showPhoto inchangés
}
```

Le site d'appel dans `_PharmacieOrderCard.build()` est devenu :
```dart
_DriverInfoCard(orderId: orderId, driverId: driverId, status: status)
```

## 4. Mécanisme anti-appels répétitifs

- `_phoneFuture` est un champ de `_DriverInfoCardState`, assigné uniquement dans `initState()`/`didUpdateWidget()` — jamais dans `build()`.
- Le `StreamBuilder` extérieur sur `driver_public` continue de se reconstruire au rythme des écritures GPS (~5 s pendant une livraison active, confirmé en S6.11), et le `StreamBuilder` intérieur sur `livreurs` (`motoModel`) se resouscrit à chaque reconstruction de l'extérieur — mais ni l'un ni l'autre ne touche plus `_phoneFuture` : `build()` le référence simplement, sans jamais le recréer. Aucun appel supplémentaire à la Callable n'est donc déclenché par ces reconstructions.
- Aucun `Timer`, aucune boucle, aucun polling introduit.
- Aucun cache global : `_phoneFuture` est un champ d'instance propre à cette carte précise.

## 5. Gestion de `didUpdateWidget`

Identique au pattern S6.10/S6.12 : comparaison de `orderId` **et** `driverId` entre l'ancien et le nouveau widget.
- **Changement de commande affichée** ou **réattribution du livreur** (transfert via `driverTransfer.js`) : le Future est relancé via `setState`, pour que le nouveau `FutureBuilder` observe la nouvelle instance — la Callable relit elle-même `order.driverId` à jour côté serveur, jamais un ancien numéro.
- **Reconstruction sans changement pertinent** (y compris celles dues au GPS sur `driver_public`, ou à `motoModel` sur `livreurs`) : le Future n'est **pas** relancé.

## 6. Traitement séparé de `phone` et `motoModel`

- `motoModel` reste lu exactement comme avant S6.13 : le même `StreamBuilder` sur `livreurs/{driverId}`, en continu — seule différence, il n'extrait plus `phone` du même document (`privData?['motoModel'] as String? ?? ''` uniquement). Son comportement, sa fraîcheur et sa fréquence de mise à jour sont **inchangés**.
- `phone` est désormais entièrement indépendant de ce flux : son `Future` est mémorisé dans l'État du widget, insensible aux reconstructions dues à `motoModel`/`driver_public`.
- Aucun ajustement du schéma de données : `motoModel` reste sur `livreurs`, non migré vers `driver_public`, conformément à la consigne. Aucune nouvelle exposition de donnée n'est introduite — `motoModel` était et reste lisible exactement par les mêmes règles qu'avant (Rules `livreurs`, non modifiées).
- Les deux sources (Callable pour `phone`, Stream pour `motoModel`) sont combinées uniquement au moment de l'affichage (`_buildCard`), sans qu'aucune ne dépende de l'état de l'autre pour se rafraîchir.

## 7. Gestion des erreurs

`_fetchPhone()` capture toute exception (`permission-denied`, `resource-exhausted`, `failed-precondition`, `not-found`, erreur réseau) et retourne `null` — **aucun repli vers une lecture directe de `livreurs.phone`**. `phoneSnap.data ?? ''` fournit une chaîne vide à `_buildCard` pendant le chargement et en cas d'échec — comportement identique à l'ancien code (`privData?['phone'] as String? ?? ''`), donc aucun numéro incorrect ni obsolète, et aucune régression visible du comportement du bouton d'appel existant (même limite préexistante déjà signalée en S6.11 : le bouton reste actif même avec une chaîne vide — défaut antérieur à cette migration, non introduit ni aggravé ici).

## 8. Tests exécutés et résultats

- **Recherche de tests existants** : aucun fichier de test ne cible `pharmacie_dashboard.dart`/`_DriverInfoCard` (confirmé, comme pour les lecteurs migrés en S6.9/S6.10/S6.12).
- **Test déjà existant réutilisable, non dupliqué** : `test/services/driver_phone_callable_response_test.dart` (S6.9) couvre déjà l'expression d'extraction `((data as Map?)?['data'] as Map?)?['phone'] as String?`, strictement identique à celle utilisée ici — aucun nouveau test créé.
- **`flutter test`/`flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente). **Non exécutés, honnêtement signalé** — l'absence d'appel répété et le bon fonctionnement de `motoModel` en parallèle du téléphone ne sont validés que par relecture du mécanisme, pas par une exécution observée.

## 9. Validations statiques

- **Équilibre global des accolades/parenthèses** vérifié par comptage automatisé sur l'ensemble du fichier modifié : profondeur de 0 dans les deux cas.
- **`grep` de contrôle** : confirmé qu'aucune extraction `['phone']`/`["phone"]` ne subsiste à partir de `livreurs` dans ce fichier — les deux seules occurrences restantes de `'phone'` concernent le numéro de la pharmacie elle-même (`pharmacieData['phone']`), sans rapport avec le livreur, non touchées.
- **Vérification du paramètre transmis à la Callable** : confirmé par relecture que `_fetchPhone()` transmet exclusivement `{'orderId': widget.orderId}`.
- **`git diff` ciblé** : la modification est strictement isolée dans la zone de `_PharmacieOrderCard` (site d'appel) et `_DriverInfoCard`/`_DriverInfoCardState` ; les hunks pré-existants et sans rapport du fichier (import `min_version_dialog`, bloc `showMinVersionDialogIfNeeded`) sont restés intacts, confirmés par lecture complète du diff.
- **Vérification de `motoModel`** : confirmé par relecture que le `StreamBuilder` sur `livreurs` et son extraction `motoModel` sont fonctionnellement identiques à avant la migration, seule la coextraction de `phone` ayant été retirée de ce flux.

## 10. Réserves

- **Aucune validation par exécution réelle** (§8/§9) : la garantie « pas d'appel répété » et « `motoModel` fonctionnel en parallèle » repose sur une application rigoureuse et relue du pattern déjà validé en S6.10/S6.12, pas sur un test automatisé exécuté.
- **Défaut préexistant non corrigé** : le bouton d'appel reste actif même quand `phone` est une chaîne vide (`tel:` sans numéro) — comportement identique à avant cette migration (§7), non dans le périmètre de cette mission (qui porte sur la source de la donnée, pas sur la robustesse du bouton).
- **Portée strictement limitée à `pharmacie_dashboard.dart`** : `boulangerie_dashboard.dart`, identifié dans le même audit S6.11, reste avec son `StreamBuilder` imbriqué sur `livreurs` pour `phone` — non touché, conformément au périmètre strict de cette mission.

## 11. Confirmation

Aucune Firestore Rule modifiée. Aucune configuration Firebase modifiée. Aucun déploiement (Cloud Function ou Rules) exécuté. Aucune dépendance ni lockfile modifié (`package:cloud_functions` était déjà une dépendance existante du projet — seul un import de ce paquet déjà présent a été ajouté). La Callable `getDriverPhoneForOrderCF` n'a pas été modifiée, aucun contrôle serveur contourné. `boulangerie_dashboard.dart`, `seller_dashboard.dart`, `admin_map.dart`, `live_marker_cache.dart`, `suivi_commande.dart`, `customer_tracking_screen.dart`, `web_client_dashboard.dart`, `driver_public` : non touchés. Aucun accès Firebase réel, aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée. Les modifications locales préexistantes et sans rapport dans ce fichier restent intactes.

STOP après ce rapport. Aucune autre phase (S6.14) commencée sans autorisation explicite.
