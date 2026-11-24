# SEC-01 — S6.9 : migration des lecteurs téléphone ponctuels (`get()`) vers `getDriverPhoneForOrderCF`

Date : 2026-11-22
Type : migration ciblée (3 lecteurs ponctuels), aucune callable modifiée, aucun lecteur `StreamBuilder` touché
Référence : `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md` (callable déjà implémentée et testée)

## 1. Résumé

Les 3 lecteurs ponctuels (`get()`/`FutureBuilder` ponctuel) identifiés par la mission ont été migrés vers `getDriverPhoneForOrderCF` : `web_client_dashboard.dart::_callDriver`, `suivi_commande.dart::_callDriver`, `customer_tracking_screen.dart::_loadDriverInfoById` (partie `phone` uniquement — la partie publique, déjà sur `driver_public` depuis S6.6, n'a pas été retouchée). Chacun transmet désormais exclusivement `orderId` à la callable ; aucun `driverId`/`phone` n'est plus jamais fourni par le client. Aucun repli vers la lecture directe de `livreurs.phone` n'a été conservé. Un quatrième lecteur ponctuel (`.get()`/`FutureBuilder`) a été découvert pendant la vérification du code réel de `suivi_commande.dart` et **n'a pas été migré** — voir §5 pour la justification. La callable S6.8 n'a pas été modifiée.

## 2. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `lib/web/pages/client/web_client_dashboard.dart` | `_callDriver` réécrit pour appeler la callable ; import `cloud_functions` ajouté ; appel mis à jour (`widget.id` au lieu de `driverId`) |
| `lib/screens/client/suivi_commande.dart` | `_callDriver` réécrit (signature `orderId` au lieu de `driverId`) ; import `cloud_functions` ajouté ; appel mis à jour (`order.id`) |
| `lib/screens/customer_tracking_screen.dart` | Dans `_loadDriverInfoById`, seul le second bloc (`phone`) remplacé par un appel à la callable ; import `cloud_functions` ajouté |
| `test/services/driver_phone_callable_response_test.dart` | **Nouveau** — test ciblé sur l'extraction de la réponse |
| `docs/SEC01_S6_9_PHONE_PUNCTUAL_READERS_MIGRATION.md` | **Nouveau** — ce rapport |

Aucune Rule, Cloud Function, dépendance, lockfile ou configuration Firebase modifiée.

## 3. Lecteurs migrés et méthode de remplacement

### 3.1 `web_client_dashboard.dart::_callDriver`

Avant : `.collection('livreurs').doc(driverId).get()`, lecture directe de `phone`.

Après :
```dart
Future<void> _callDriver(String orderId) async {
  try {
    final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('getDriverPhoneForOrderCF')
        .call({'orderId': orderId});
    final phone = ((result.data as Map?)?['data'] as Map?)?['phone'] as String?;
    if (phone == null || phone.isEmpty) return;
    await launchUrl(Uri(scheme: 'tel', path: phone));
  } on FirebaseFunctionsException catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.code == 'resource-exhausted'
            ? 'Trop de tentatives, réessayez plus tard.'
            : "Numéro du livreur indisponible pour l'instant."),
        backgroundColor: Colors.red));
  } catch (_) {}
}
```
Le site d'appel (`_OrderCardState`, qui dispose déjà de `widget.id`, l'identifiant de la commande affichée) a été mis à jour : `_callDriver(widget.id)` au lieu de `_callDriver(driverId)`. Le `driverId` local reste utilisé uniquement pour la condition d'affichage du bouton (`if (driverId != null)`), inchangée.

### 3.2 `suivi_commande.dart::_callDriver`

Même principe. Signature changée de `(BuildContext context, String driverId)` à `(BuildContext context, String orderId)`. Site d'appel mis à jour : `_callDriver(context, order.id)` au lieu de `_callDriver(context, order.driverId ?? '')` — `order` (un `OrderModel` complet, avec `.id`) était déjà dans le scope de ce bouton (`if (hasDriver) _actionButton(...)`).

### 3.3 `customer_tracking_screen.dart::_loadDriverInfoById` (partie `phone` uniquement)

```dart
Future<void> _loadDriverInfoById(String driverId) async {
  // (inchangé) : name/photoUrl/avgRating depuis `driver_public`
  try { ... } catch (_) {}
  // SEC-01 / S6.9 — remplace le second bloc (phone depuis `livreurs`) :
  try {
    final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('getDriverPhoneForOrderCF')
        .call({'orderId': widget.order.id});
    if (!mounted) return;
    final phone = ((result.data as Map?)?['data'] as Map?)?['phone'] as String?;
    setState(() => _driverPhone = phone);
  } catch (_) {
    if (mounted) setState(() => _driverPhone = null);
  }
}
```
Seul le second bloc (ajouté en S6.6 pour isoler `phone`) a été remplacé — le premier bloc (`driver_public`, inchangé depuis S6.6) n'a pas été touché. `widget.order.id` était déjà disponible dans cette classe (`widget.order.driverId` y est utilisé juste avant).

## 4. Gestion des erreurs et des refus d'accès

Dans les 3 cas, principe appliqué strictement : **aucun repli vers `livreurs.phone`**, et **aucune valeur obsolète ou fabriquée affichée**.

- **`FirebaseFunctionsException` avec `code == 'permission-denied'`** (refus d'autorisation, commande inexistante, statut non autorisé — tous indistinguables côté callable, cf. S6.8 §5) : traité comme un échec silencieux ou signalé selon le site — `web_client_dashboard.dart`/`suivi_commande.dart` affichent un message générique (« numéro indisponible ») ; `customer_tracking_screen.dart` remet simplement `_driverPhone` à `null` (l'écran masque déjà le bouton d'appel quand `driverPhone == null`, comportement préexistant inchangé).
- **`code == 'resource-exhausted'`** (limite de débit) : message spécifique (« trop de tentatives ») dans les deux sites avec bouton d'appel direct ; traité comme toute autre erreur dans `customer_tracking_screen.dart` (`_driverPhone = null`).
- **`code == 'failed-precondition'`** (aucun livreur assigné) / **`code == 'not-found'`** (numéro indisponible côté données) : capturés par le `catch` générique dans les 3 sites — comportement final identique à l'ancien « numéro absent » (bouton désactivé ou message « numéro indisponible »), sans jamais afficher un numéro.
- **Chargement** : les 3 sites restent asynchrones (`Future`), sans changement de la logique d'affichage pendant l'attente (déjà gérée par l'état existant de chaque écran — aucun nouvel indicateur de chargement introduit, ni requis par l'architecture actuelle de ces boutons/écrans).

Dans aucun des 3 sites un ancien numéro mis en cache n'est conservé en cas d'échec : `customer_tracking_screen.dart` écrase explicitement `_driverPhone` (succès → nouvelle valeur, échec → `null`) ; les deux autres sites n'ont jamais mis en cache de numéro entre deux appels (chaque tape sur « Appeler » déclenche un nouvel appel complet).

## 5. Lecteurs non migrés et raisons

- **`suivi_commande.dart` — carte livreur en `FutureBuilder`** (lignes ~316-390, découverte en vérifiant le code réel de ce fichier avant modification, conformément à la consigne) : lit `photoUrl`/`name`/**`phone`** dans un seul `.get()` sur `livreurs`, et **affiche** `phone` en texte brut (ligne 386, `Text(driver["phone"] ?? "")`), pas seulement via un bouton d'appel déclenché à la demande. **Non migré dans cette phase**, pour trois raisons :
  1. Ni ce site précis ni cette méthode n'étaient nommés dans le périmètre explicite de cette mission (qui cite `web_client_dashboard.dart`, `suivi_commande.dart`, `customer_tracking_screen.dart` comme candidats « notamment » — et le candidat déjà identifié et traité dans `suivi_commande.dart` à travers toutes les phases précédentes, S6.4/S6.6, a toujours été spécifiquement `_callDriver`, jamais cette carte).
  2. Architecturalement, ce site se comporte comme un `StreamBuilder`/`FutureBuilder` d'affichage continu plutôt qu'un appel ponctuel déclenché par une action utilisateur (bouton) — la consigne n°8 de cette mission (« ne pas modifier les lecteurs `StreamBuilder` ») vise explicitement à exclure ce type de pattern de cette phase, et ce site en partage l'esprit même s'il utilise techniquement `.get()` plutôt que `.snapshots()`.
  3. Migrer cet affichage textuel continu vers la callable nécessiterait une décision de conception supplémentaire (afficher un numéro en permanence via un appel serveur à chaque construction du widget a un profil d'usage différent d'un bouton d'appel ponctuel — risque de sur-sollicitation de la limitation de débit si le widget est reconstruit fréquemment) — hors périmètre d'une migration « sans risque » de cette phase.
  Ce site reste documenté ici pour une décision explicite future, conformément à l'esprit de l'engagement (signaler plutôt qu'improviser).
- **`admin_map.dart`** : non migré, conformément à l'interdiction explicite (consigne n°9).
- **`live_marker_cache.dart`** : non modifié, conformément à l'interdiction explicite (consigne n°10).
- **`pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`** : les 3 lecteurs `StreamBuilder` imbriqués créés en S6.6 — non touchés, conformément à la consigne n°8 (« ne pas modifier les lecteurs `StreamBuilder` dans cette phase »).

## 6. Tests exécutés et résultats

- **Tests existants pertinents** : recherche (`test/**/web_client_dashboard*`) — aucun fichier trouvé. `test/screens/client/suivi_commande_payment_message_test.dart` existe mais ne couvre que `paymentErrorMessage` (sans rapport avec cette migration) — non affecté, non modifié.
- **Test ciblé créé** : `test/services/driver_phone_callable_response_test.dart` (5 cas) — isole l'expression d'extraction `((data as Map?)?['data'] as Map?)?['phone'] as String?` partagée par les 3 sites migrés (réponse normale, `data` absent, `phone` absent, réponse `null`, type inattendu). Non exécuté par `flutter test` (voir §7) ; relu manuellement contre les 3 sites pour confirmer la correspondance exacte de l'expression.
- **Suite `functions/`** : non ré-exécutée dans cette phase (aucune Cloud Function modifiée — la callable S6.8 reste inchangée, déjà validée par ses propres 39 tests + la suite complète en S6.8).

## 7. Validations statiques

- **Lecture intégrale** de chaque bloc modifié après édition, pour confirmer l'équilibre des accolades/parenthèses (en particulier l'expression multi-lignes de `suivi_commande.dart::_callDriver`, relue ligne par ligne).
- **`grep` de contrôle** : confirmé qu'aucune lecture `collection('livreurs')` ne subsiste dans les 3 méthodes migrées (`_callDriver` ×2, le second bloc de `_loadDriverInfoById`) ; confirmé que les 2 lectures `livreurs` restantes dans `suivi_commande.dart` (la carte `FutureBuilder` §5, et `_listenDriver` qui ne lit que `lat`/`lng`, sans rapport avec `phone`) sont bien celles volontairement laissées intactes.
- **`git diff` ciblé** sur les 3 fichiers : chaque changement est isolé des très nombreuses modifications locales préexistantes et sans rapport déjà présentes dans ces fichiers (confirmé explicitement, notamment la découverte que `_statusLabel` dans `web_client_dashboard.dart` avait déjà été retiré par un refactor antérieur et sans rapport — vérifié comme préexistant à cette phase via `git show HEAD`, pas introduit par cette intervention).
- **Vérification des paramètres transmis à la callable** : confirmé par relecture que les 3 appels transmettent exclusivement `{'orderId': <valeur>}` — jamais `driverId` ni `phone`.
- **`flutter test`/`flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente de cet audit — aucun résultat n'est fabriqué). Non exécutés, honnêtement signalé.

## 8. Risques et réserves

- **Pas de validation de compilation réelle** : comme pour toutes les phases Flutter précédentes, l'absence de `flutter analyze` signifie que la correction syntaxique/typage repose sur une relecture manuelle attentive, pas sur une compilation réelle.
- **Site `FutureBuilder` non migré dans `suivi_commande.dart`** (§5) : continue de lire `phone` directement sur `livreurs` — aucune régression par rapport à l'état actuel, mais la réduction de l'exposition de `phone` reste partielle pour ce fichier tant qu'une décision explicite n'est pas prise sur ce site précis.
- **Messages d'erreur pour `permission-denied`** : volontairement génériques (« numéro indisponible »), cohérent avec l'anti-énumération de la callable (S6.8) — un utilisateur légitime dont la commande vient de changer de statut (ex. annulation pendant qu'il consulte l'écran) verra le même message qu'un cas d'erreur réseau, sans distinction — comportement voulu, pas un défaut.
- **Aucun indicateur de chargement nouveau** : les 3 sites n'affichaient déjà aucun indicateur de chargement dédié à l'appel/l'affichage du numéro (le `get()` direct précédent n'en avait pas non plus) — latence réseau légèrement différente (un aller-retour Cloud Function au lieu d'une lecture Firestore directe) mais comportement d'attente inchangé, pas une régression introduite par cette migration en elle-même.

## 9. Confirmation du respect du périmètre

- Aucun déploiement Firebase (`firebase deploy`) exécuté.
- Aucune Firestore Rule modifiée.
- Aucune configuration Firebase modifiée.
- Aucune Cloud Function modifiée (la callable S6.8 n'a pas été touchée — aucun blocage critique identifié ne l'a nécessité).
- `driver_public` : non modifié.
- `live_marker_cache.dart`, `admin_map.dart` : non modifiés.
- Les 3 lecteurs `StreamBuilder` de S6.6 (`pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`) : non modifiés.
- Aucune dépendance ni lockfile modifié (`package:cloud_functions` était déjà une dépendance existante du projet, utilisée dans de nombreux autres fichiers — seuls 3 nouveaux imports de ce paquet déjà présent ont été ajoutés).
- Aucun accès Firebase réel, aucun APK/AAB généré.
- Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.
- Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée.
- Les très nombreuses modifications locales préexistantes et sans rapport dans les 3 fichiers modifiés sont restées intactes (confirmé par `git diff` ciblé pour chacun).

## 10. Verdict

**MIGRATION VALIDÉE AVEC RÉSERVES**

Les 3 lecteurs ponctuels explicitement ciblés ont été migrés vers `getDriverPhoneForOrderCF`, transmettant exclusivement `orderId`, sans jamais faire confiance à un `driverId`/`phone` fourni par le client, sans repli vers la lecture directe, et sans jamais afficher de numéro obsolète en cas d'erreur. La callable S6.8 n'a pas eu besoin d'être modifiée. Un quatrième lecteur ponctuel (`FutureBuilder` dans `suivi_commande.dart`, affichage continu du numéro) a été découvert pendant la vérification du code réel et volontairement laissé intact, documenté pour une décision future plutôt que migré par extension non autorisée du périmètre. Les limites de validation (absence de `flutter analyze`/test d'intégration réel, par absence d'outillage dans cet environnement) sont documentées honnêtement.

STOP après ce rapport. Aucune phase suivante commencée sans autorisation explicite.
