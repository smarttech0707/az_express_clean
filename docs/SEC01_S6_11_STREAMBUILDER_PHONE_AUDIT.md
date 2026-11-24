# SEC-01 — S6.11 : audit READ-ONLY des 3 StreamBuilders téléphone restants

Date : 2026-11-22
Type : audit exclusivement en lecture seule — aucune modification de code, de Rules, de configuration ou de dépendance
Référence : `docs/SEC01_S6_6_PHONE_READERS_MIGRATION.md` (séparation public/privé déjà appliquée aux 3 lecteurs), `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md`, `docs/SEC01_S6_10_FUTUREBUILDER_PHONE_MIGRATION.md` (pattern de mémorisation déjà validé)

## 1. Résumé exécutif

Les 3 lecteurs sont retrouvés dans le code actuel, à l'identique de leur état post-S6.6 (aucune dérive constatée) : `pharmacie_dashboard.dart::_DriverInfoCard`, `boulangerie_dashboard.dart` (bloc inline de `_OrderCard`), `seller_dashboard.dart::_DriverSection`. Tous trois partagent la même structure : un `StreamBuilder` extérieur sur `driver_public/{driverId}` (champs publics), imbriquant un second `StreamBuilder` sur `livreurs/{driverId}` dont le seul rôle restant est de fournir `phone` (et `motoModel` pour la pharmacie).

**Découverte centrale de cet audit, non documentée dans les rapports précédents** : les 3 cartes rebuildent déjà, aujourd'hui, à haute fréquence pendant une livraison active — le `StreamBuilder` extérieur écoute le **document entier** `driver_public/{driverId}`, qui reçoit une écriture GPS toutes les ~5 secondes pendant qu'un livreur est en mouvement (`DriverLocationService`, throttle 5 s/15 m, `.claude/rules/dispatch-gps.md`), **même sur les cartes qui n'affichent ni `lat` ni `lng`** (pharmacie, boulangerie) — un listener Firestore se déclenche sur tout changement du document, pas seulement sur les champs lus. Le `StreamBuilder` intérieur (`livreurs`, pour `phone`) étant imbriqué dans le `builder` de l'extérieur, son expression `stream: ... .snapshots()` est **réévaluée et resouscrite à chaque reconstruction**, soit potentiellement toutes les ~5 secondes pendant une course active. Une migration naïve (remplacer cette lecture `phone` par un appel direct à la Callable dans ce même `builder`) appellerait donc `getDriverPhoneForOrderCF` au même rythme — une course de 10 minutes représenterait de l'ordre de 120 appels, dépassant largement la limite de 20 appels/60 s déjà configurée côté serveur (S6.8). C'est le risque technique dominant de cette migration, et il motive sans ambiguïté la stratégie recommandée (§5/§6) : mémoriser l'appel dans un `StatefulWidget`, exactement comme en S6.10.

Aucune Rule n'a besoin d'être modifiée pour cette migration (la Callable utilise l'Admin SDK, hors Rules, confirmé inchangé). Les 3 lecteurs transmettent déjà `driverId` en paramètre de widget, jamais `phone` — mais aucun n'utilise encore `orderId` nommément ; les 3 ont cependant un `orderId` disponible sans effort dans leur portée immédiate (§2).

## 2. Les 3 lecteurs identifiés (retrouvés dans le code actuel, lignes vérifiées)

### 2.1 `lib/screens/pharmacie/pharmacie_dashboard.dart::_DriverInfoCard`

1. **Fichier/méthode** : `_DriverInfoCard.build()`, lignes 958-991 (widget `StatelessWidget`, lignes 947-1133 avec `_buildCard`).
2. **Contexte d'utilisation** : carte « Livreur assigné — Vérification sécurité » affichée dans `_PharmacieOrderCard` (ligne 894, `_DriverInfoCard(driverId: driverId, status: status)`), elle-même construite par un `ListView.builder` (ligne ~772, `_PharmacieOrderCard(orderId: docs[i].id, data: data)`) alimenté par un `StreamBuilder<QuerySnapshot>` sur les commandes de la pharmacie.
3. **Origine actuelle du téléphone** : `livreurs/{driverId}.phone`, via le second `StreamBuilder` imbriqué (lignes 977-988).
4. **Type de widget/cycle de vie** : `StatelessWidget` (`_DriverInfoCard`), reconstruit entièrement à chaque fois que son parent (`_PharmacieOrderCard`, lui-même recréé par le `ListView.builder` à chaque émission du `StreamBuilder` de commandes) est reconstruit — aucun état propre, aucune mémorisation possible en l'état actuel.
5. **Ordre de grandeur des reconstructions** : élevé pendant une livraison active — le `StreamBuilder` extérieur écoute `driver_public/{driverId}` en entier, qui reçoit une écriture GPS toutes les ~5 s (throttle `DriverLocationService`) tant que le livreur est en mouvement ; chaque écriture déclenche une reconstruction complète de la carte, y compris son `StreamBuilder` intérieur sur `livreurs` (resouscription complète). Hors livraison active (livreur à l'arrêt), le rythme retombe au heartbeat GPS (90 s) ou aux rares changements de `name`/`photoUrl`/`isOnline`.
6. **Contexte de commande / disponibilité de `orderId`** : `_PharmacieOrderCard` possède déjà `final String orderId;` (ligne 783, confirmé) — `orderId` est donc disponible dans le même scope que l'instanciation de `_DriverInfoCard` (ligne 894), à une modification de signature près (non faite ici).
7. **Rôle de l'utilisateur / droits nécessaires** : pharmacie connectée, propriétaire de la commande. La Callable (S6.8) reconnaît ce rôle via `order.pharmacieId` existant et `pharmacies/{pharmacieId}.currentUid === uid` — mécanisme déjà implémenté et testé, compatible sans adaptation.
8. **Comportement actuel en cas d'erreur/numéro absent** : `privData?['phone'] as String? ?? ''` — si absent, chaîne vide, le bouton d'appel (`GestureDetector`, `onTap: () => _call(phone)`) reste affiché mais ne fait rien d'utile avec une chaîne vide (`Uri.parse('tel:')` — comportement déjà fragile, préexistant, non lié à cette migration).
9. **Comportement attendu après migration** : `phone` fourni par la Callable au lieu de `livreurs` ; en cas de refus/erreur, repli sur `null`/`''` (jamais un numéro fabriqué), cohérent avec le pattern déjà validé en S6.9/S6.10.
10. **Risque d'appels répétitifs** : **élevé en l'état actuel du code** — voir le constat central du §1. Sans mémorisation, le rythme GPS (~5 s) dépasserait la limite de 20/60 s en quelques dizaines de secondes.
11. **Implications d'une réponse ponctuelle plutôt qu'un flux** : la Callable ne notifie jamais spontanément d'un changement — contrairement au `StreamBuilder` actuel qui, bien qu'inefficace, mettait à jour le numéro affiché si le livreur modifiait son `phone` en cours de course (cas rarissime, aucun écran ne permet aujourd'hui à un livreur de changer son propre numéro, confirmé en S6.5). Perte fonctionnelle négligeable.
12. **Comportement en cas de réattribution du livreur** : la carte est reconstruite avec un nouveau `driverId` (prop du widget) dès que `_PharmacieOrderCard` reçoit le nouveau document de commande — un nouvel appel à la Callable avec le même `orderId` renverrait alors le nouveau livreur (la Callable relit `order.driverId` elle-même, jamais un paramètre fourni) — correct par construction, à condition que la mémorisation future réagisse bien au changement de `driverId` (pas seulement `orderId`), comme déjà fait en S6.10.

### 2.2 `lib/screens/boulangerie/boulangerie_dashboard.dart` (bloc inline dans `_OrderCard`)

1. **Fichier/méthode** : bloc inline (pas une méthode nommée séparée), lignes 705-786, à l'intérieur de `_OrderCard.build()` (classe débutant ligne 459).
2. **Contexte d'utilisation** : section « Livreur » d'une carte de commande boulangerie, affichée si `driverId != null` (ligne 705), à l'intérieur d'un `ListView`/`StreamBuilder` sur les commandes filtrées par `where('sellerId', isEqualTo: boulangerieId)` (ligne 396, confirmé).
3. **Origine actuelle du téléphone** : `livreurs/{driverId}.phone` (`dPhone`, ligne 729), via le `StreamBuilder` imbriqué (lignes 721-726).
4. **Type de widget/cycle de vie** : bloc inline dans `_OrderCard`, un `StatelessWidget` (ligne 459) — reconstruit à chaque reconstruction de la carte parente.
5. **Ordre de grandeur des reconstructions** : identique au raisonnement du §2.1 point 5 — le `StreamBuilder` extérieur écoute tout `driver_public/{driverId}`, donc reçoit aussi les écritures GPS toutes les ~5 s pendant une livraison active, même si cette carte n'affiche ni `lat` ni `lng`.
6. **Contexte de commande / disponibilité de `orderId`** : `_OrderCard` possède déjà `final String orderId;` (ligne 460, confirmé) — disponible dans le même `build()` qui contient ce bloc, sans paramètre supplémentaire à faire remonter.
7. **Rôle / droits** : boulangerie connectée, propriétaire de la commande via `sellerId == boulangerieId`. Confirmé que les comptes partenaires de ce type s'authentifient avec un uid Firebase correspondant à leur identifiant de document (`widget.boulangerieId` utilisé par ailleurs comme `uid` pour `userId`/tokens de notification, etc.) — compatible tel quel avec la vérification `order.sellerId === uid` déjà implémentée dans la Callable (rôle `'partner'`), sans adaptation nécessaire.
8. **Comportement actuel en cas d'erreur/numéro absent** : `privData?['phone'] ?? ''` — bouton d'appel toujours actif (`GestureDetector`, pas de garde `if (dPhone.isNotEmpty)`), `tel:` avec une chaîne vide en cas d'absence — défaut préexistant, non introduit par cette migration.
9. **Comportement attendu après migration** : identique au §2.1 point 9.
10. **Risque d'appels répétitifs** : élevé, identique au §2.1 point 10.
11. **Implications d'un flux vers une réponse ponctuelle** : identiques au §2.1 point 11.
12. **Réattribution du livreur** : identique au raisonnement du §2.1 point 12 — `driverId` provient de `data['driverId']` (ligne 487, re-lu à chaque nouveau snapshot de commande), donc à jour.

### 2.3 `lib/screens/seller/seller_dashboard.dart::_DriverSection`

1. **Fichier/méthode** : `_DriverSection.build()`, lignes 1417-1458 (widget `StatelessWidget`, classe lignes 1413-1572 avec `_buildCard`).
2. **Contexte d'utilisation** : section livreur d'une carte de commande marketplace/vendeur, instanciée ligne 1274 (`_DriverSection(driverId: order.driverId!)`), dans un contexte où `order` (un `OrderModel` complet) est déjà dans le scope (ligne 1260, utilisé pour `_InfoSection` juste avant).
3. **Origine actuelle du téléphone** : `livreurs/{driverId}.phone`, via le `StreamBuilder` imbriqué (lignes 1445-1455).
4. **Type de widget/cycle de vie** : `StatelessWidget`, mêmes caractéristiques que les deux précédents.
5. **Ordre de grandeur des reconstructions** : **le plus élevé des 3** — cette carte affiche en plus `lat`/`lng` (lien « Voir sur la carte », lignes 1518-1533), donc son `StreamBuilder` extérieur sur `driver_public` est, par conception, directement motivé par les mises à jour GPS en plus de les recevoir incidemment — confirmation supplémentaire que ce site rebuild au rythme GPS (~5 s) pendant une livraison active, de façon encore plus justifiée fonctionnellement que les deux précédents (l'affichage de la position est voulu, contrairement à pharmacie/boulangerie qui ne font que subir la fréquence du document).
6. **Contexte de commande / disponibilité de `orderId`** : `order.id` est disponible dans le même scope que l'instanciation (ligne 1274) — trivial à transmettre.
7. **Rôle / droits** : vendeur marketplace connecté, propriétaire via `order.sellerId === uid` — rôle `'partner'` de la Callable, déjà compatible.
8. **Comportement actuel en cas d'erreur/numéro absent** : `phone` est `String?` (ligne 1452, pas de valeur de repli `''`) — `if (phone != null) Text(phone, ...)` (ligne 1514) et `if (phone != null) IconButton(...)` (ligne 1537) : le bouton d'appel et le texte sont **correctement masqués** si `phone` est `null` (contrairement aux deux autres cartes) — le seul des 3 lecteurs déjà « propre » sur ce point.
9. **Comportement attendu après migration** : identique au §2.1 point 9 — la garde `if (phone != null)` déjà présente fonctionne sans changement avec une valeur `null` venant d'un échec de Callable.
10. **Risque d'appels répétitifs** : le plus élevé des 3 (point 5).
11. **Implications d'un flux vers une réponse ponctuelle** : identiques aux deux autres — perte négligeable, aucun mécanisme de changement spontané de `phone` par le livreur n'existe aujourd'hui (S6.5).
12. **Réattribution du livreur** : `order.driverId` relu à chaque nouveau document de commande (confirmé par la structure de l'écran, identique aux deux autres) — correct par construction, sous réserve que la future mémorisation écoute bien le changement de `driverId`.

## 3. Risques techniques (synthèse transversale)

- **Risque dominant : fréquence de reconstruction pilotée par le GPS, pas par le besoin réel d'affichage** (§1, détaillé par lecteur en §2 point 5). C'est un risque **déjà présent dans le code actuel** (le `StreamBuilder` imbriqué sur `livreurs` se resouscrit déjà à ce rythme pour obtenir `phone` en continu) ; il ne serait qu'aggravé — transformé en dépassement de rate-limit mesurable — par une migration naïve vers la Callable sans mémorisation.
- **Risque de perte du fil en cas de widget non-keyé recyclé par une liste** : comme en S6.10, aucun des 3 parents (`_PharmacieOrderCard`, `_OrderCard` boulangerie, la carte vendeur) n'utilise de `Key` explicite sur l'élément de liste — un `StatefulWidget` de remplacement devra donc, comme en S6.10, se fier à `didUpdateWidget` comparant `orderId`/`driverId` plutôt qu'à l'identité du widget seule.
- **Risque de double affichage incohérent pendant la transition** (nom/état en direct via `driver_public`, téléphone en différé via Callable) : déjà accepté et documenté comme acceptable depuis S6.6 (séparation des deux sources) — pas un risque nouveau introduit par cette migration du téléphone.
- **Aucun risque de sécurité nouveau identifié** : les 3 rôles (pharmacie/boulangerie/vendeur) sont déjà couverts par la matrice d'autorisation de la Callable (S6.8), sans qu'aucune extension de cette matrice ne soit nécessaire (vérifié en §7).

## 4. Stratégies de migration possibles (comparées, non implémentées)

### Option A — `Future` mémorisé dans un `StatefulWidget` (pattern S6.10)

- **Avantages** : élimine structurellement le risque de rate-limit (§3) — l'appel à la Callable n'est déclenché qu'à la création du widget ou à un changement réel de `driverId`/`orderId`, indépendamment du rythme des écritures GPS sur `driver_public`. Pattern déjà écrit, relu et documenté (S6.10) — aucune nouvelle idée à valider.
- **Inconvénients** : nécessite de convertir 3 `StatelessWidget` (ou sous-parties) en `StatefulWidget` — un changement structurel à chaque site, pas une simple substitution de ligne.
- **Risque de rate-limit** : **nul** — un seul appel par affectation de livreur, jamais par tick GPS.
- **Impact UX** : numéro affiché une fois résolu (délai d'un aller-retour réseau, comme en S6.10) puis stable jusqu'à une vraie réattribution — pas de clignotement ni de rafraîchissement visible à chaque tick GPS (amélioration involontaire par rapport à l'actuel, où le `StreamBuilder` imbriqué resouscrit déjà en continu sans bénéfice visible, puisque `phone` ne change jamais en pratique).
- **Complexité** : modérée — identique à ce qui a déjà été fait en S6.10 pour un cas structurellement très proche (carte avec nom public + téléphone privé).
- **Sécurité** : seul `orderId` transmis, jamais `driverId` ni `phone` — strictement conforme à la Callable.
- **Compatibilité avec la Callable S6.8** : totale, aucune adaptation de la Callable nécessaire.

### Option B — Chargement ponctuel au moment pertinent du cycle de vie (sans `StatefulWidget` dédié, ex. au niveau d'un ancêtre déjà `StatefulWidget`)

Les 3 cartes commandes parentes (`_PharmacieOrderCard`, `_OrderCard` boulangerie, la carte vendeur) sont elles-mêmes probablement des `StatelessWidget` ou des éléments d'un `ListView.builder` sans état propre — il faudrait vérifier/convertir l'ancêtre porteur de l'identité de la commande plutôt que la seule sous-carte livreur.

- **Avantages** : regrouperait la mémorisation à un seul niveau par commande, potentiellement réutile pour d'autres besoins futurs de cette carte.
- **Inconvénients** : périmètre plus large que nécessaire pour cette migration précise (toucherait la structure de la carte de commande entière, pas seulement la section livreur) — risque de sortir du périmètre strict « lecteur téléphone » fixé par cette mission.
- **Risque de rate-limit** : nul, si bien implémenté — mêmes garanties que l'option A.
- **Impact UX** : identique à l'option A.
- **Complexité** : plus élevée que l'option A (refactor d'un ancêtre partagé par plusieurs responsabilités, pas seulement le téléphone).
- **Sécurité** : identique à l'option A.
- **Compatibilité** : identique à l'option A.
- **Conclusion** : techniquement viable mais **non recommandée** — l'option A isole la migration exactement là où le problème se pose (la sous-carte livreur elle-même), sans toucher à la carte de commande parente ni à ses autres responsabilités (statut, articles, paiement…).

### Option C — Rafraîchissement contrôlé lors d'un changement d'état de commande (ex. recharger la Callable seulement sur un changement de `status`, pas sur `driverId` seul)

- **Avantages** : réduirait encore la fréquence d'appel si `driverId` changeait sans changement de `status` (cas rare).
- **Inconvénients** : **risque de numéro obsolète après une réattribution de livreur sans changement de statut visible** (un transfert en cours de route garde souvent le même `status` — `picked_up` avant et après, par exemple) — contredit directement la consigne « ne pas conserver un numéro obsolète » et le constat de S6.10 (la réattribution doit redéclencher l'appel, pas seulement un changement de statut). **Non recommandée**, pour une raison de sécurité/exactitude fonctionnelle, pas seulement de complexité.
- Les autres critères ne sont pas pertinents à détailler puisque cette option est écartée pour une raison de fond.

### Option D (écartées explicitement par la consigne, mentionnées pour mémoire)

Aucun cache global de numéros, aucun repli vers `livreurs.phone`, aucune pose du numéro dans un document de commande sans analyse de l'exposition — ces trois pistes ne sont pas évaluées comme des « options » de ce chantier, conformément à la consigne, et ne le seraient pas même sans cette consigne : un cache global violerait le principe de moindre privilège (un numéro resterait accessible en mémoire au-delà du besoin immédiat d'un widget précis), et poser `driverPhone` sur `orders` reproduirait le risque de sur-exposition au partenaire déjà identifié en S6.5/S6.7 (document `orders` lisible par plusieurs rôles à la fois).

## 5. Stratégie recommandée pour chaque lecteur

Pour les 3 lecteurs : **Option A** (Future mémorisé dans un `StatefulWidget` dédié à la section livreur, `didUpdateWidget` comparant `orderId`+`driverId`), strictement le même pattern que celui déjà implémenté et documenté en S6.10 pour `suivi_commande.dart`. Aucune raison technique ou de sécurité ne justifie une stratégie différente d'un lecteur à l'autre — les 3 partagent une structure identique (StreamBuilder extérieur `driver_public` imbriquant un StreamBuilder intérieur `livreurs` pour `phone`), issue de la même migration S6.6.

Différences mineures à prévoir lors d'une future implémentation (non faites ici) :
- **Pharmacie** : conserver aussi `motoModel` dans le même `StatefulWidget` (reste sur `livreurs`, hors périmètre Callable — pas une donnée de contact).
- **Vendeur** : la garde `if (phone != null)` déjà présente est directement compatible avec un `Future<String?>` — aucun ajustement de condition nécessaire au-delà du remplacement de la source.
- **Boulangerie** : absence actuelle de garde sur `phone` vide (défaut préexistant, §2.2 point 8) — à corriger ou non lors de l'implémentation future, question distincte de la migration elle-même.

## 6. Ordre recommandé de migration

1. **`seller_dashboard.dart::_DriverSection`** en premier : déjà le mieux préparé (garde `if (phone != null)` déjà correcte), et le cas où le risque de rate-limit actuel est le plus visible/mesurable (carte qui affiche aussi `lat`/`lng`, donc le rythme GPS y est le plus directement constatable) — le corriger en premier donne le signal le plus clair que la migration résout bien le problème.
2. **`pharmacie_dashboard.dart::_DriverInfoCard`** ensuite : structure très proche de `suivi_commande.dart` (S6.10), `orderId` déjà nommé dans le widget parent — migration directe par analogie.
3. **`boulangerie_dashboard.dart`** en dernier : seul des 3 sans garde sur `phone` vide — nécessite une décision supplémentaire (ajouter la garde en migrant, ou la laisser identique) avant de conclure cette dernière migration, d'où un ordre légèrement plus tardif.

Aucune dépendance croisée entre les 3 — l'ordre proposé est une préférence de clarté de démonstration, pas une contrainte technique.

## 7. Audit de sécurité

- **`orderId` correctement disponible et utilisable** pour les 3 lecteurs (§2, point 6 de chacun) — aucun des 3 n'a besoin d'une donnée supplémentaire pour fonctionner avec la Callable telle qu'elle existe.
- **La Callable ne recevrait, dans tous les cas, que `orderId`** — confirmé qu'aucun des 3 sites n'a de raison de transmettre `driverId` ou `phone` (la Callable les détermine elle-même, S6.8) ; aucun changement de ce principe n'est nécessaire ni envisagé.
- **Lecteurs directs restants dans le périmètre** : les 3 `StreamBuilder` intérieurs sur `livreurs` (lignes 977-988 pharmacie, 721-783 boulangerie, 1445-1455 vendeur) sont les seuls lecteurs directs de `phone` dans ces 3 fichiers — confirmé par recherche exhaustive (`grep` sur `['phone']`/`["phone"]` croisé avec `livreurs` dans chacun des 3 fichiers, aucune autre occurrence).
- **Migration réalisable sans modification des Rules** : confirmée — la Callable utilise l'Admin SDK (hors Rules) pour lire `orders`/`pharmacies`/`admins`/`livreurs` ; les Rules actuelles de `livreurs`/`driver_public` resteraient inchangées, et le retrait de ces 3 lectures côté client ne nécessite aucun ajustement des Rules existantes (elles continueraient de permettre la lecture, simplement plus personne ne l'exercerait depuis ces 3 sites après une future migration).
- **Rôles couverts par la matrice existante, sans extension** : `pharmacie` (déjà dans la matrice S6.8 via `pharmacieId`/`currentUid`), `partner` (déjà dans la matrice via `sellerId`, couvre à la fois boulangerie et vendeur marketplace puisque les deux filtrent leurs commandes par `sellerId == uid`, confirmé par lecture du code des deux dashboards).

## 8. Tests nécessaires lors de la future implémentation (non créés ici)

- Pour chacun des 3 `StatefulWidget` de remplacement : test confirmant qu'un `setState`/rebuild du parent **sans** changement de `driverId`/`orderId` ne déclenche pas un second appel à la Callable (équivalent du constat « pas d'appel répétitif », vérifié par relecture en S6.10 mais jamais par un test automatisé — recommandé de combler cette lacune à l'implémentation, si un harnais de test widget avec Callable simulée devient disponible).
- Test confirmant que `didUpdateWidget` relance bien l'appel quand `driverId` change (réattribution) et que l'ancien numéro n'est pas affiché entre-temps.
- Réutilisation du test déjà existant `test/services/driver_phone_callable_response_test.dart` (S6.9) pour l'expression de parsing de la réponse — strictement identique dans les 3 cas, aucun nouveau test de parsing nécessaire.
- Pour la pharmacie : test couvrant la coexistence de `motoModel` (resté sur `livreurs`) et `phone` (Callable) dans le même widget, sans confusion de source.
- Pour la boulangerie : si la garde sur `phone` vide est ajoutée à cette occasion (§5), un test de non-régression de ce changement de comportement précis.

## 9. Blocages identifiés

**Aucun blocage architectural.** Les 3 migrations sont réalisables avec le pattern déjà validé (Option A), sans extension de la matrice d'autorisation de la Callable, sans modification des Rules, et sans toucher à `driver_public` ou à la synchronisation serveur. Le seul point nécessitant une décision (pas un blocage) est le traitement de la garde manquante sur `phone` vide dans `boulangerie_dashboard.dart` (§5/§8) — une décision mineure, pas un obstacle à la migration elle-même.

## 10. Confirmation READ-ONLY

Aucun fichier n'a été modifié dans cette phase. Toutes les lectures effectuées (`Read`, `Grep`, `Bash` en mode lecture) ont servi exclusivement à retrouver et vérifier l'état réel du code pour cet audit. Aucune Rule, aucune Cloud Function, aucune configuration Firebase, aucune dépendance ni lockfile n'a été modifiée. Aucun accès Firebase réel, aucun déploiement, aucun APK/AAB. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée. Toutes les modifications locales préexistantes restent intactes.

## 11. Verdict

**AUDIT VALIDÉ**

Les 3 lecteurs sont retrouvés et documentés en détail (12 points demandés, pour chacun), avec une découverte architecturale significative et non triviale (le rythme de reconstruction piloté par les écritures GPS sur `driver_public`, indépendant de l'affichage réel du téléphone) qui explique précisément pourquoi une migration naïve présenterait un risque réel de dépassement du rate-limit de la Callable, et qui justifie sans ambiguïté la stratégie recommandée (mémorisation dans un `StatefulWidget`, pattern déjà validé en S6.10). Les options alternatives sont comparées avec leurs compromis réels, et deux d'entre elles sont explicitement écartées pour des raisons de fond (périmètre excessif pour l'option B, risque de numéro obsolète pour l'option C) plutôt que par simple préférence. Aucune des pistes interdites (cache global, repli direct, champ de commande non analysé) n'a été proposée. Aucun fichier n'a été modifié.

STOP après ce rapport. Pas d'enchaînement sur S6.12. En attente de votre autorisation.
