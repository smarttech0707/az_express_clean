# SEC-01 — S5.3.3 : sécurisation de la synchronisation concurrente `driver_public`

**Statut : implémenté et testé localement. Aucun Firebase réel, aucun déploiement, aucune règle modifiée.** Traite les deux risques démontrés en S5.3.2 (`docs/SEC01_S5_3_2_CONCURRENCY_AUDIT.md`).

## 1. Résumé exécutif

`functions/driverPublicSync.js` ne fait plus jamais confiance aux données `before`/`after` portées par l'événement Cloud Functions. Les trois triggers (`create`/`update`/`delete`) partagent désormais une seule fonction de reconciliation, `reconcileDriverPublicFromSource`, qui **relit l'état courant** de `livreurs/{driverId}` et de `driver_public/{driverId}` dans une **transaction Firestore** avant d'écrire, et déduit le correctif de cette lecture fraîche plutôt que de l'historique figé de l'événement.

- **RISK A (événement obsolète)** : résolu pour la classe de risque démontrée en S5.3.2 (scénarios 1, 2, 3, 4, 8, 9, 12 — écrasement par un événement ancien retardé/retry). Un événement n'est plus un porteur de données périmées : c'est un simple signal de réveil. N'importe quelle exécution, quel que soit l'événement qui l'a déclenchée ou son retard, écrit toujours le reflet de l'état **réellement courant** de `livreurs` au moment où elle s'exécute.
- **RISK B (projection fantôme)** : résolu par deux mécanismes complémentaires : (1) `syncDriverPublicOnDelete` relit `livreurs` avant de supprimer et **annule la suppression si le document a été recréé** entre-temps (scénario 12 de S5.3.2, « suppression répétée ») ; (2) `syncDriverPublicOnCreate`/`...OnUpdate`, en trouvant la source absente, **n'écrivent jamais** de nouvelle valeur — ils invalident au plus les champs non-GPS déjà présents, sans jamais recréer de contenu (scénario 11 de S5.3.2).
- **Limite honnêtement documentée (exigence critique de la mission)** : la transaction utilisée garantit une lecture cohérente et la détection d'un conflit de lecture **au sein d'une même transaction**, mais ne garantit pas un ordre d'exécution entre deux invocations Cloud Functions séparées. La correction n'élimine pas la possibilité d'une **fenêtre transitoire** de quelques centaines de millisecondes à quelques secondes entre le moment où `livreurs` change et le moment où la reconciliation suivante s'exécute — elle élimine l'obsolescence **persistante** (le risque réellement démontré en S5.3.2), pas la latence intrinsèque d'un mécanisme asynchrone. Voir §7 pour l'analyse précise de ce que la transaction garantit et ne garantit pas.

**Verdict de cette mission : VALIDÉ.** Les deux risques ciblés sont traités selon une architecture conforme aux limites réelles de Firestore, pas selon une garantie supposée ; la limite résiduelle honnête est documentée plutôt que masquée.

## 2. Baseline

3 001 tests, 2 820 passés, 0 échec, 181 ignorés (état de fin de S5.3.2, inchangé puisque S5.3.2 n'a modifié aucun code).

## 3. État Git initial et final

**Initial** : `functions/driverPublicSync.js`, `functions/test/driverPublicSync.test.js` (non suivis), `functions/index.js` (modifié) — état de fin de S5.3.1/S5.3.2. `firestore.rules` et `functions/package-lock.json` apparaissaient déjà modifiés **avant le début de cette mission** (état préexistant du dépôt, sans rapport avec SEC-01, non touché ici — confirmé par `git status` avant toute modification).

**Final** : `functions/driverPublicSync.js` réécrit (reconciliation transactionnelle), `functions/index.js` modifié (les trois triggers n'extraient plus `event.data`, seulement `event.params.driverId`), `functions/test/driverPublicSync.test.js` réécrit (32 tests). `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md` est le seul fichier nouveau. `firestore.rules`, `.firebaserc`, `firebase.json`, `functions/package.json` : **non touchés** par cette mission (le `M` sur `firestore.rules`/`package-lock.json` reste celui, préexistant, d'avant S5.3.3).

## 4. Fichiers inspectés

`functions/driverPublicSync.js` (intégral, avant et après réécriture), `functions/index.js` (les trois triggers `livreurs` et les deux triggers préexistants sans rapport `notifyDriverLowBalance`/`notifyAdminsOnNewDriver`), `functions/test/driverPublicSync.test.js` (intégral, avant réécriture), `docs/SEC01_S5_3_2_CONCURRENCY_AUDIT.md` (les 12 scénarios et les 5 options de correction), `docs/SEC01_S5_3_1_CREATE_PROJECTION.md`, `docs/SEC01_S5_3_SYNC_ROBUSTNESS_AUDIT.md`, `docs/SEC01_S5_SERVER_PROJECTION_AUDIT.md` (constats et conventions déjà établis), `functions/driverRatings.js` (pattern transactionnel existant, comparé), `functions/test/lifecycleFake.js` (fausse base transactionnelle existante, pattern réutilisé pour la conception du nouveau faux `db`).

## 5. Fichiers créés et modifiés

**Créé** : `docs/SEC01_S5_3_3_CONCURRENCY_FIX.md` (ce rapport) — seul fichier nouveau.

**Modifiés** :
- `functions/driverPublicSync.js` : `computeDriverPublicPatch`/`buildFirestorePatch` inchangées (logique pure réutilisée telle quelle, seule la sémantique de leur paramètre `before` change — voir §6) ; ajout de `GPS_PROJECTION_FIELDS`, `invalidateIfOrphaned`, `reconcileDriverPublicFromSource` ; `syncDriverPublicOnCreate`/`...OnUpdate` délèguent désormais toutes deux à `reconcileDriverPublicFromSource` (signature réduite à `{db, admin, driverId}`, sans `before`/`after`) ; `syncDriverPublicOnDelete` relit `livreurs` dans une transaction avant de supprimer.
- `functions/index.js` : les trois triggers n'extraient plus `event.data.before.data()`/`event.data.after.data()`/`event.data.data()` — seul `event.params.driverId` est transmis, commentaires mis à jour pour expliquer le changement d'architecture.
- `functions/test/driverPublicSync.test.js` : réécrit (32 tests, contre 30 avant) — les 11 tests de la fonction pure `computeDriverPublicPatch` sont conservés à l'identique (logique inchangée), tous les tests de bout en bout sont réécrits autour d'un nouveau faux `db` supportant `runTransaction`, couvrant les 20 points de concurrence/suppression/sécurité-régression de la Phase 4 de la mission, plus les tests d'export et de reproduction des documents réels de création (S5.3.1, non régressés).

## 6. Architecture retenue

`reconcileDriverPublicFromSource({db, admin, driverId})` : ouvre une transaction (`db.runTransaction`), lit `livreurs/{driverId}` et `driver_public/{driverId}` (en parallèle, `Promise.all` à l'intérieur de la transaction), puis :

- si `livreurs` **existe** : calcule le correctif via `computeDriverPublicPatch({before, after})`, où **`after` est la lecture fraîche de `livreurs`** et **`before` est la lecture fraîche de `driver_public`** (et non plus l'historique de l'événement) — la fonction pure reste inchangée, seule la provenance de ses arguments change. N'écrit que si `hasChanges` (idempotence, pas d'écriture inutile).
- si `livreurs` **n'existe pas** : délègue à `invalidateIfOrphaned`, qui n'écrit jamais de nouvelle valeur — au plus, elle nettoie ce qui existe déjà (voir §9).

`syncDriverPublicOnCreate`/`syncDriverPublicOnUpdate` sont désormais **strictement identiques** : les deux délèguent mot pour mot à `reconcileDriverPublicFromSource` (vérifié par le test 33, par lecture de code). Un seul chemin de calcul pour les trois signaux (création, mise à jour, et indirectement la non-recréation côté suppression) — conforme à la préférence du projet pour la réutilisation plutôt que la duplication, déjà appliquée en S5.3.1.

`syncDriverPublicOnDelete({db, driverId})` : ouvre sa propre transaction, relit `livreurs` ; si le document existe (recréation entre-temps), annule la suppression (`{deleted: false, reason: 'source-recreated'}`) ; sinon, supprime `driver_public`.

Aucun nouveau champ n'est introduit dans `livreurs` (aucun champ de version — conforme à l'interdiction explicite de la mission). Les conventions `region: 'europe-west1'` (implicite via `setGlobalOptions`), `maxInstances: 1, cpu: 0.5/0.25, concurrency: 1, memory: '256MiB', retry: true` sur les trois triggers sont **inchangées** dans `functions/index.js`.

## 7. Garanties transactionnelles démontrées

**Ce que `db.runTransaction` garantit réellement (Firestore, documenté par la plateforme)** : toutes les lectures effectuées dans la transaction forment un instantané cohérent ; si un document lu dans la transaction est modifié par une écriture externe avant que la transaction ne se valide, le SDK Admin **avorte et rejoue automatiquement** toute la fonction de mise à jour (nouvelle lecture, nouveau calcul, nouvelle tentative de validation), de façon transparente pour l'appelant. Concrètement pour ce module : si `livreurs/{driverId}` change pendant qu'une exécution de `reconcileDriverPublicFromSource` est en cours (entre sa lecture et sa validation), cette exécution est automatiquement rejouée avec la valeur la plus récente — elle ne peut **pas** valider une écriture basée sur une lecture devenue périmée pendant sa propre exécution.

**Ce que cette garantie NE couvre PAS, documenté explicitement (exigence critique de la mission)** : elle ne garantit **aucun ordre d'exécution entre deux invocations Cloud Functions distinctes** déclenchées par deux écritures différentes sur `livreurs`. Si l'écriture A (ancienne) déclenche une exécution qui démarre et se termine **après** que l'écriture B (récente) a déjà été entièrement appliquée à `livreurs`, l'exécution déclenchée par A lira — comme n'importe quelle lecture faite à cet instant — l'état **de B**, pas celui d'A : c'est exactement le mécanisme qui élimine le RISK A, mais ce n'est pas la transaction elle-même qui l'empêche de « s'exécuter en premier » — c'est le fait qu'elle ne lit plus jamais sa propre donnée historique. La transaction protège contre un cas plus étroit : qu'une écriture concurrente invalide une lecture **pendant** l'exécution en cours, pas qu'une exécution se termine « trop tard » par rapport à une autre en valeur absolue. **La correction du RISK A vient du changement de source de vérité (relecture au lieu de confiance dans l'événement), pas de l'atomicité de la transaction en elle-même** — la transaction ajoute une garantie de cohérence utile et correcte à utiliser ici, mais ce n'est pas elle qui résout le problème central ; ce point est signalé pour ne pas sur-vendre la portée de la transaction, conformément à l'exigence critique de la mission (« ne pas considérer une simple relecture suivie d'une écriture non atomique comme une garantie contre la concurrence » — la relecture seule suffit déjà à éliminer l'obsolescence persistante ; la transaction ajoute, en plus, la protection contre une modification survenant **pendant** l'exécution elle-même, qu'une relecture simple sans transaction n'offrirait pas).

**Limite résiduelle honnête** : une fenêtre transitoire reste possible entre le moment où `livreurs` change et le moment où une exécution de reconciliation s'exécute enfin (latence Cloud Functions). Pendant cette fenêtre, `driver_public` peut afficher une valeur momentanément différente de `livreurs`. Ce n'est pas un défaut de cette correction : c'est une propriété inhérente à toute projection asynchrone basée sur des triggers, et ne peut être éliminée sans faire écrire `driver_public` de façon synchrone par les writers métier eux-mêmes — explicitement hors périmètre (« ne pas modifier les writers métier »).

**Ce qui N'A PAS pu être vérifié par les tests de cette mission, documenté sans prétendre le contraire** : les tests ajoutés (fichier `functions/test/driverPublicSync.test.js`) utilisent un faux `db` dont `runTransaction` exécute simplement la fonction fournie sans simuler l'abandon/rejeu réel de Firestore en cas de conflit de lecture pendant l'exécution. Ces tests démontrent correctement la propriété centrale de la correction (toute exécution lit l'état courant, jamais un historique figé) ; ils ne démontrent PAS, et ne peuvent pas démontrer sans l'émulateur Firestore réel (hors périmètre de cette mission), le comportement précis d'abandon/rejeu décrit au paragraphe précédent. Ce point est documenté ici plutôt que présenté comme prouvé — voir aussi l'avertissement en tête de `functions/test/driverPublicSync.test.js`.

## 8. Traitement des événements obsolètes (RISK A)

Les tests 12, 13, 15, 16, 17, 18 (tous dans `functions/test/driverPublicSync.test.js`) démontrent, en mutant directement l'état simulé de `livreurs` entre deux appels (représentant « d'autres écritures ont déjà eu lieu avant que cette exécution ne démarre enfin »), que le résultat final écrit dans `driver_public` correspond systématiquement à l'état le plus récent de `livreurs` au moment de l'exécution — jamais à une valeur plus ancienne. Le test 12 reproduit explicitement l'exemple de la mission S5.3.2 (`isOnline=true` puis `isOnline=false`, l'événement du `true` s'exécutant en dernier) et confirme que `driver_public` se retrouve avec `isOnline:false`, pas `true`.

## 9. Traitement des suppressions (RISK B)

Stratégie retenue (conforme à la Phase 3 de la mission) :

- **`syncDriverPublicOnDelete`** : relit `livreurs` avant de supprimer. Si le document existe à nouveau (recréation avant l'exécution d'un événement de suppression en retard), la suppression est annulée (`source-recreated`, test 23) — ne supprime jamais la projection d'un livreur qui existe à nouveau.
- **`syncDriverPublicOnCreate`/`...OnUpdate`** rencontrant une source absente (`invalidateIfOrphaned`) : ne recréent jamais de contenu. Si `driver_public` ne contient aucun champ GPS, le document entier est supprimé (test 20, test 21 pour le cas limite d'une création sans source ni projection préexistantes). Si des champs GPS existent encore (projection S4 toujours active), seuls les 7 champs non-GPS sont effacés, le document et ses champs GPS étant préservés (test 22) — conforme à l'instruction explicite de la Phase 3 (« préserver les champs GPS si la stratégie ne nécessite pas la suppression du document »).
- **Interaction vérifiée avec le trigger create** (test 21), **avec le trigger update** (test 20, 22), **avec une suppression répétée** (test 23, 23b), **avec une projection déjà absente** (test 24). **Interaction avec les suppressions de compte existantes** : `accountDeletion.js` n'efface jamais `livreurs` (anonymisation en place, confirmé en S5/S5.3) — ce chemin de suppression de `driver_public` ne s'active donc jamais via la clôture de compte normale, uniquement via la suppression admin directe (`drivers_page.dart`), exactement comme avant S5.3.3. `operations_control/account_deletion` et le pilote T7E ne sont ni lus ni modifiés par cette mission.

## 10. Protection GPS

Structurellement inchangée : `GPS_PROJECTION_FIELDS` n'est jamais lu pour sa valeur (seulement pour détecter sa présence lors d'une invalidation, test 22) ; `DRIVER_PUBLIC_FIELDS` ne contient toujours aucun champ GPS ; toute écriture passe par `.set(merge:true)`, qui ne touche jamais une clé absente du correctif. Testé de bout en bout pour la création (test 27, complète le test 19) et pour la reconciliation après suppression (test 22).

## 11. Whitelist

Inchangée, revérifiée de bout en bout via le nouveau mécanisme de lecture live (tests 25, 26) — les mêmes 7 champs, la même fonction pure `computeDriverPublicPatch`.

## 12. Tests exécutés et résultats

`functions/test/driverPublicSync.test.js` : **32/32 passés** localement (`node --test test/driverPublicSync.test.js`), couvrant les 20 points de concurrence/suppression/sécurité-régression de la Phase 4 (tests 12 à 31), plus les 11 tests inchangés de la fonction pure (1 à 11b), plus l'export/intégration (32), la non-duplication de logique (33), et la reproduction des deux formes de document de création réelles (34, 35).

Suite complète (`npm test` dans `functions/`) : **3 003 tests, 2 822 passés, 0 échec, 181 ignorés** — soit +2/+2 par rapport à la baseline de fin de S5.3.2 (3 001/2 820), cohérent avec le passage de 30 à 32 tests dans le fichier modifié (aucune régression ailleurs dans le dépôt).

`node -c functions/driverPublicSync.js`, `node -c functions/index.js`, `node -e "require('./index.js')"` : chargement confirmé sans erreur.

Analyse statique ciblée : relecture complète des deux fichiers modifiés après écriture (pas seulement avant), confirmant l'absence de référence résiduelle à `event.data`/`before`/`after` dans les triggers, l'absence de tout champ de version introduit dans le schéma `livreurs`, et l'absence de toute modification des writers métier (`driverLifecycle.js`, `driverAcceptance.js`, `accountDeletion.js`, etc. — non touchés, non relus pour modification).

## 13. Risques résiduels

- **Fenêtre transitoire inhérente** (voir §7) : entre une écriture `livreurs` et l'exécution effective du trigger correspondant, `driver_public` peut refléter brièvement un état dépassé. Non éliminable sans toucher aux writers métier (hors périmètre) ; nature différente et bornée, contrairement à l'obsolescence **persistante** que cette mission corrige.
- **Garantie transactionnelle non vérifiée empiriquement** (voir §7, dernier paragraphe) : les tests unitaires locaux ne peuvent pas démontrer le comportement réel d'abandon/rejeu de Firestore sous conflit de lecture pendant l'exécution — seul l'émulateur Firestore ou un déploiement réel le pourraient, tous deux hors périmètre de cette mission.
- **Coût Cloud Run légèrement accru** : chaque exécution effectue désormais deux lectures (`livreurs` + `driver_public`) au lieu de zéro (les données venaient auparavant de l'événement lui-même, sans lecture Firestore). Impact jugé mineur au vu de la fréquence des écritures `livreurs` et des quotas déjà respectés (`maxInstances`/`cpu` inchangés).
- Les deux constats restants de S5.3 (limite de livraison « au moins une fois », absence de garantie d'ordre absolue au niveau de la plateforme elle-même) demeurent des propriétés documentées de Cloud Firestore, pas des défauts de ce module — inchangés par cette mission, désormais sans conséquence persistante grâce à la relecture live.

## 14. Confirmation absence de Firebase réel et de déploiement

Confirmée : tous les tests exécutés localement (`node --test`), aucune commande `firebase deploy`, aucun accès réseau à un projet Firebase réel, aucune règle Firestore modifiée, aucun changement de dépendance/lockfile causé par cette mission (le `M` préexistant sur `functions/package-lock.json` date d'avant S5.3.3, confirmé en §3).

## 15. Verdict

**S5.3.3 : VALIDÉ.**

Les deux risques ciblés par la mission sont traités par une architecture qui correspond aux garanties réelles de Firestore, pas à une garantie supposée : RISK A est résolu par le changement de source de vérité (relecture live au lieu de confiance dans l'événement) combiné à l'usage correct d'une transaction pour la cohérence intra-exécution ; RISK B est résolu par une garde de recréation côté suppression et une invalidation contrôlée (jamais une recréation) côté création/mise à jour. La limite réelle de la transaction (elle ne garantit pas un ordre entre exécutions séparées) est documentée explicitement plutôt que masquée, conformément à l'exigence critique de la mission. Whitelist et protection GPS intactes, 32/32 tests locaux, 3 003/2 822 sur la suite complète, aucune régression, aucun Firebase réel, aucun déploiement.

STOP — fin de mission S5.3.3. Je n'entame ni S5.3.4, ni S5.4, ni S6. J'attends vos instructions.
