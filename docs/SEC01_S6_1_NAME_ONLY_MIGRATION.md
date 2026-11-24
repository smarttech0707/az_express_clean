# SEC-01 — S6.1 : migration des lecteurs name-only vers `driver_public`

Date : 2026-11-21
Type : migration ciblée (3 lecteurs, champ `name` uniquement)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` §8 « Phase S6.1 — Lecteurs triviaux à champ unique public (`name` seul) »

## 1. Résumé exécutif

Les 3 lecteurs identifiés par le plan S6.0 comme « champ `name` seul, risque quasi nul » ont été migrés de `livreurs` vers `driver_public` : `conversations_page.dart`, `web_client_dashboard.dart::_rateDriver` et le flux de notation de `suivi_commande.dart`. Dans les 3 cas, seule la chaîne de collection a changé (`"livreurs"` → `"driver_public"`), avec un ajustement de sécurité mineur sur un site (`suivi_commande.dart`, accès nullable au lieu d'un accès par clé directe, pour tenir compte de la fenêtre de synchronisation serveur propre à `driver_public`). Aucun autre lecteur (`phone`, `wallet`, admin, GPS, dispatch) n'a été touché. Aucune Rules, Cloud Function, ni configuration modifiée.

## 2. Lecteurs identifiés (périmètre name-only du plan S6.0)

Re-vérifiés ligne par ligne dans le code actuel (pas seulement confirmés sur dossier) avant migration :

| Fichier:ligne (avant migration) | Champ lu | Traitement associé | Chemin anonyme ? |
|---|---|---|---|
| `lib/screens/chat/conversations_page.dart:120-123` (`_ConversationTileState._driverFuture`) | `name` seul | affichage d'un nom dans une tuile de conversation, repli `"Livreur"` | non — écran accessible seulement si `uid != null` (`ConversationsPage.build`, ligne 13) |
| `lib/web/pages/client/web_client_dashboard.dart:918-930` (`_rateDriver`) | `name` seul | nom injecté dans `RatingDialog`, repli `'le livreur'` | non — dashboard client authentifié |
| `lib/screens/client/suivi_commande.dart:540-558` (bouton de notation) | `name` seul | nom injecté dans `RatingDialog`, repli `"le livreur"` | non — écran de suivi d'une commande du client authentifié |

Vérification explicite effectuée (pas une présomption) pour chacun : lecture complète de la méthode englobante, confirmation qu'aucun autre champ (`phone`, `wallet`, `isSuspended`, etc.) n'est lu ni consommé dans le même bloc, et qu'aucun traitement en aval ne dépend d'un champ absent de `driver_public`.

## 3. Lecteurs migrés

Les 3 lecteurs ci-dessus, sans exception et sans ajout. Détail des changements :

### 3.1 `lib/screens/chat/conversations_page.dart`

```diff
+  // SEC-01 / S6.1 : nom seul, affiché quel que soit le rôle du lecteur
+  // (client authentifié) → projection publique `driver_public` au lieu de
+  // la collection privée `livreurs`.
   late final Future<DocumentSnapshot> _driverFuture = FirebaseFirestore.instance
-      .collection("livreurs")
+      .collection("driver_public")
       .doc(widget.driverId)
       .get();
```

Le code consommateur (`(driverSnap.data!.data() as Map)["name"] ?? "Livreur"`, ligne 157) était déjà un accès `Map` classique (pas l'opérateur `[]` de `DocumentSnapshot`, qui lève sur un champ absent) : aucun risque de régression, pas d'ajustement nécessaire.

### 3.2 `lib/web/pages/client/web_client_dashboard.dart::_rateDriver`

```diff
   void _rateDriver(String driverId) async {
     String driverName = 'le livreur';
     try {
-      final doc =
-          await FirebaseFirestore.instance.collection('livreurs').doc(driverId).get();
+      // SEC-01 / S6.1 : seul le nom est nécessaire pour le dialogue de
+      // notation → projection publique `driver_public`.
+      final doc = await FirebaseFirestore.instance
+          .collection('driver_public')
+          .doc(driverId)
+          .get();
       if (doc.exists) driverName = doc.data()?['name'] as String? ?? driverName;
     } catch (_) {}
```

Le site voisin `_callDriver` (lignes 906-916, lecture de `phone`) n'a **pas** été touché : catégorie D (bloquée par le mécanisme `driverPhone` absent), confirmé hors périmètre de cette phase.

### 3.3 `lib/screens/client/suivi_commande.dart` (bouton de notation)

```diff
                   String driverName = "le livreur";
                   if (order.driverId != null) {
+                    // SEC-01 / S6.1 : seul le nom est nécessaire pour le
+                    // dialogue de notation → projection publique
+                    // `driver_public`.
                     final doc = await FirebaseFirestore.instance
-                        .collection("livreurs")
+                        .collection("driver_public")
                         .doc(order.driverId)
                         .get();
-                    if (doc.exists) driverName = doc["name"] ?? driverName;
+                    // `driver_public.name` peut être en retard de quelques
+                    // secondes (synchronisation serveur) : accès par clé
+                    // directe (`doc["name"]`) lèverait si le champ n'est pas
+                    // encore présent, d'où l'accès nullable.
+                    if (doc.exists) {
+                      driverName =
+                          doc.data()?['name'] as String? ?? driverName;
+                    }
                   }
```

Ajustement de sécurité au-delà d'un simple changement de nom de collection : l'ancien code lisait `doc["name"]` (opérateur `[]` de `DocumentSnapshot`, qui **lève une exception** si le champ est absent du document). Sur `livreurs`, `name` est écrit dès la création du compte livreur (toujours présent). Sur `driver_public`, `name` est écrit par la synchronisation serveur (`driverPublicSync.js`) et peut légitimement être en retard de quelques secondes, ou absent pour un document tout juste créé (fenêtre déjà documentée en §5 de `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md`). Un accès par clé directe aurait introduit un risque de plantage inexistant avant la migration ; remplacé par `doc.data()?['name'] as String?`, qui retourne `null` proprement dans tous les cas (absent, `null`, type inattendu) et retombe sur le repli existant `"le livreur"`. Comportement UI strictement préservé dans le cas normal (nom présent), comportement de repli renforcé (pas de nouveau crash possible) dans les cas limites.

Le site `_listenDriver()` (ligne ~1341, GPS `lat`/`lng` seulement) et le site `itemBuilder` (ligne ~305, hybride `photoUrl`/`name`/`phone`) du même fichier n'ont **pas** été touchés : ils ne lisent pas exclusivement `name`, donc hors périmètre strict de cette phase (respectivement candidats de S6.2/S6.3 et S6.4 selon le plan de référence).

## 4. Lecteurs non migrés et justification

Aucun autre lecteur `name`-seul supplémentaire n'a été trouvé au-delà des 3 ci-dessus lors de la re-vérification (le plan S6.0 en avait identifié exactement 3 pour cette phase). Tous les autres lecteurs de `livreurs` inventoriés en S6.0 restent non migrés, pour les raisons déjà établies et reconfirmées ici sans ré-ouverture :

- **Catégorie B/D (téléphone)** : `web_client_dashboard.dart::_callDriver`, `suivi_commande.dart::_callDriver` (ligne 139), `suivi_commande.dart` `itemBuilder` (ligne 305, hybride), `suivi_commande.dart::_listenDriver` (ligne 1341, GPS pur — candidat A mais hors du périmètre « name seul » de cette phase précise) — nécessitent un champ absent de `driver_public` (`phone`) ou appartiennent à une autre étape du plan (GPS = S6.2/S6.3).
- **Catégorie C (admin/flotte/dispatch/financier/auth)** : console admin, roster/gains flotte, `auth_service.dart`, dispatch serveur, cycle de vie serveur, bookkeeping financier — données structurellement absentes de `driver_public`, jamais candidates.
- **Hybrides non encore séparés** : `driver_profil.dart` (StreamBuilder, `photoUrl`/`wallet`/`deliveries`/`avgRating`), `driver_dashboard.dart::_listenDriverDoc`, `admin_map.dart`, `pharmacie_dashboard.dart`, `boulangerie_dashboard.dart`, `seller_dashboard.dart`, `customer_tracking_screen.dart` — relèvent de S6.4 (séparation public/privé par écran), pas de S6.1.
- **Services de suivi temps réel** (`realtime_tracking_service.dart`, `tracking_service.dart`) — correspondance exacte à la projection mais pas « name seul » : relèvent explicitement de S6.2 selon l'ordre de migration recommandé par le plan.
- **`destination_picker.dart`, `live_marker_cache.dart`** — requêtes multi-livreurs : relèvent de S6.3, et la seconde reste conditionnée par la levée de l'incertitude anonyme déjà actée comme non bloquante en S6.0.1 mais toujours listée en S6.3 pour l'indexation.

## 5. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `lib/screens/chat/conversations_page.dart` | 1 site migré (changement de collection) |
| `lib/web/pages/client/web_client_dashboard.dart` | 1 site migré (changement de collection) ; `_callDriver` (phone) intact |
| `lib/screens/client/suivi_commande.dart` | 1 site migré (changement de collection + accès nullable) ; 3 autres sites `livreurs` intacts |
| `test/services/driver_public_name_fallback_test.dart` | **Nouveau fichier** : test ciblé |
| `docs/SEC01_S6_1_NAME_ONLY_MIGRATION.md` | **Nouveau fichier** : ce rapport |

## 6. Tests exécutés

- **Recherche exhaustive post-migration** `grep -n "collection('livreurs')|collection(\"livreurs\")"` sur les 3 fichiers : confirme que seuls les sites volontairement non migrés (`phone`, hybride, GPS) conservent une lecture `livreurs`, et que les 3 sites name-only lisent désormais `driver_public`.
- **Diff contrôlé** (`git diff`) sur les 3 fichiers : dans `conversations_page.dart`, le diff est intégralement celui de cette migration (aucune modification locale préexistante sur ce fichier) ; dans `web_client_dashboard.dart` et `suivi_commande.dart`, le changement est isolé au sein d'un diff plus large préexistant et sans rapport (travaux antérieurs non liés à SEC-01), confirmé ligne par ligne.

## 7. Tests non exécutés et raisons

- **`flutter test` / `flutter analyze`** : `flutter`/`dart` restent indisponibles dans cet environnement (confirmé comme à chaque phase précédente de cet audit — aucun résultat n'est fabriqué).
- **Test widget pilotant un vrai flux Firestore vers `driver_public`** : non réalisable sans ajouter une dépendance de simulation Firestore (`fake_cloud_firestore` ou équivalent, absente du dépôt), ce qui est explicitement interdit dans cette phase (aucune modification de dépendance). Remplacé par le test ciblé §6/§8 ci-dessous sur la logique de repli, seule logique non triviale introduite par la migration.
- **Test Rules** : non nécessaire — la lecture authentifiée de `driver_public` est déjà couverte par les 19 tests `rules-tests/driver-public.rules.test.js` (S5.3.5), non affectés par une migration de *lecteur* côté client.

## 8. Résultats

Test ajouté `test/services/driver_public_name_fallback_test.dart` (6 cas : nom présent, document absent, champ absent, champ `null`, type inattendu, repli spécifique à `conversations_page.dart`) — isole l'expression de repli `(data?['name'] as String?) ?? fallback` utilisée (directement ou via l'équivalent `Map`) dans les 3 sites migrés. Non exécuté par `flutter test` (indisponible), mais relu manuellement contre chaque site migré pour confirmer la correspondance exacte des expressions.

## 9. Diff et contrôle de périmètre

- Les 3 diffs ont été relus intégralement (reproduits en §3). Chacun ne contient que : (a) le changement de nom de collection, (b) dans un cas, un ajustement de robustesse directement motivé par la différence de garantie de présence du champ entre `livreurs` et `driver_public`, (c) un commentaire expliquant le changement.
- Confirmé qu'aucun site de catégorie B/C/D n'a été touché dans les 3 fichiers (vérification explicite des 3 autres sites `livreurs` restants dans `suivi_commande.dart`, et du site `_callDriver` dans `web_client_dashboard.dart`).
- Confirmé qu'aucun fichier Rules, Cloud Function, configuration, dépendance ou lockfile n'apparaît dans le diff de cette phase.
- Confirmé que les très nombreuses modifications locales préexistantes et sans rapport (travaux antérieurs visibles dans `git status`, hors du périmètre SEC-01) n'ont pas été altérées par cette intervention — seules les lignes identifiées en §3 ont été ajoutées/modifiées dans les fichiers concernés.

## 10. Risques résiduels

- **Fenêtre de synchronisation `driver_public`** : un nom de livreur tout juste créé peut rester bref instant sur son repli (`"le livreur"`/`"Livreur"`) avant que `driverPublicSync.js` ait propagé `name` — risque déjà documenté en S6.0 (§5/§6), cosmétique, atténué par les replis déjà existants dans les 3 sites.
- **Pas de compteur de repli observé** : comme noté dans la checklist de fermeture de S6.0 (§12), aucun mécanisme n'enregistre aujourd'hui si un repli ("Livreur"/"le livreur") se déclenche en production plus souvent qu'attendu — non implémenté ici (hors périmètre, serait un nouveau mécanisme).
- **Aucun risque de sécurité introduit** : les 3 sites migrés passaient déjà d'une collection lisible par tout utilisateur authentifié (`livreurs`, champ `wallet`/`phone` inclus) vers une collection strictement plus restreinte en champs (`driver_public`, 12 champs) avec la même condition d'authentification (`isAuth()`) — réduction de surface, pas d'élargissement.

## 11. Confirmation de préservation des modifications locales

Confirmé : les très nombreuses modifications locales préexistantes (listées par `git status` au démarrage de cette phase, aucune liée à SEC-01) sont restées intactes. Aucune opération Git destructive n'a été utilisée. Aucun fichier non suivi antérieur n'a été supprimé ou écrasé.

## 12. Confirmation Firebase / déploiement

Aucune connexion à un Firebase réel. Aucun déploiement. `firestore.rules` non modifié (confirmé par `git diff --stat` ciblé, aucune ligne touchée par cette phase). Aucune Cloud Function modifiée. Aucune dépendance ni lockfile modifié. Aucun APK/AAB généré. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.

## 13. Confirmation que S6.2 n'a pas commencé

Confirmé : aucun service de suivi temps réel (`realtime_tracking_service.dart`, `tracking_service.dart`), aucune requête multi-livreurs, aucun lecteur hybride, aucun mécanisme `driverPhone` n'a été touché dans cette phase. Le périmètre est resté strictement limité aux 3 lecteurs `name`-seul identifiés par le plan S6.0 pour S6.1.

## 14. Verdict

**MIGRATION VALIDÉE**

Les 3 lecteurs name-only identifiés par le plan de référence ont été migrés avec un changement minimal et vérifié, sans aucun élargissement de périmètre, sans toucher aux Rules/Functions/configuration, en préservant intégralement les comportements UI existants (y compris les replis en cas d'absence de données) et en renforçant un site contre un risque de plantage nouvellement introduit par la différence de garantie de présence du champ entre les deux collections. Les limites de test (infrastructure de simulation Firestore absente du dépôt, `flutter` indisponible) sont documentées honnêtement plutôt que contournées.

STOP après ce rapport. En attente d'autorisation avant S6.2 ou toute autre phase.
