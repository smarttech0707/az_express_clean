# SEC-01 — S6.0.1 : Audit read-only des 4 incertitudes (S6.0)

**Aucun code, test, Rule ou configuration n'a été modifié pour produire ce document.**
Suite directe de S6.0 (PLAN VALIDÉ AVEC RÉSERVES), qui avait laissé 4 points non
confirmés. Cette phase les clôt un par un, point financier en priorité, sans corriger
quoi que ce soit même si une anomalie est confirmée.

## Objet et périmètre

Vérifier exclusivement : (A) `deductCommission`, (B) `live_marker_cache.dart`,
(C) les 2 sites de lecture de `suivi_commande.dart`, (D) le champ `rating`. Aucune
extension à d'autres sujets.

## Fichiers inspectés

`lib/services/firestore_service.dart`, `functions/driverAcceptance.js`,
`lib/widgets/live_marker_cache.dart`, `lib/screens/admin/admin_live_tracking_page.dart`,
`lib/screens/client/client_map.dart`, `lib/screens/home/home_screen.dart`,
`lib/screens/client/suivi_commande.dart`, `lib/screens/driver/driver_profil.dart`,
`lib/screens/driver/driver_dashboard.dart` (comparaison), `firestore.rules` (règle
`livreurs`), ainsi qu'une recherche exhaustive (`grep`) sur `deductCommission`,
`onlineDriversFeed`/`LiveDriverFeed`, et `'rating':` dans `lib/` et `functions/`. Git log
consulté (lecture seule) pour dater l'introduction du code concerné.

---

## Point A — `firestore_service.dart::deductCommission`

### Reconstitution du chemin réel

- **Définition** : `lib/services/firestore_service.dart:400-418`. Transaction Firestore :
  lit `livreurs/{driverId}.wallet`, calcule `newWallet = (wallet - commission).clamp(0, ...)`,
  écrit `transaction.update(driverRef, {"wallet": newWallet})`, puis journalise via
  `_logTransaction(driverId, "commission", commission, ...)` dans
  `livreurs/{driverId}/wallet_transactions`.
- **Appelants** : recherche exhaustive (`grep -r "deductCommission"`) dans `lib/`,
  `functions/`, et `test/` (racine) : **zéro appelant trouvé, nulle part**. Seule la
  définition de la méthode existe.
- **Origine** : introduite dans le commit `a7f8423` (« feat: moteur notifications unifié +
  harmonisation UI premium », 2026-06-17) — le même commit que la création du fichier
  entier. Le mécanisme serveur actuel et documenté (`functions/driverAcceptance.js`,
  fonction `acceptOrder`) porte dans son propre commentaire la trace de ce qu'il a
  remplacé : *« Avant ce module, la commission AZ était prélevée par une transaction
  [cliente] (...) Ici : la commission est calculée par le serveur »*. `acceptOrder`
  utilise un identifiant de transaction idempotent (`commission_<orderId>_<uid>`), une
  vérification de solde suffisant, et `logAudit`. C'est le mécanisme actif et exclusif
  aujourd'hui.
- **Conclusion sur le chemin réel** : `deductCommission` est du code mort — écrit avant le
  passage au mécanisme serveur, jamais retiré, jamais appelé depuis.

### Réponses aux 12 questions

1. **Qui déclenche le débit ?** Personne — aucun appelant.
2. **Le débit est-il exécuté depuis Flutter ?** Non, car jamais exécuté (code mort).
3. **Le client peut-il choisir le montant ?** Si la méthode était appelée, oui — `price`
   est un paramètre arbitraire non revalidé contre `orders.budget`. Mais sans appelant,
   cette question est théorique.
4. **Le client peut-il choisir l'UID cible ?** `driverId` est un paramètre libre de la
   méthode, mais les Rules (`firestore.rules:418-425`) exigent `isOwner(livreurId)` pour
   la branche de diminution de solde : un appel avec un UID autre que celui de
   l'utilisateur connecté échouerait silencieusement (`permission-denied`). Le débit ne
   peut donc, par construction des Rules, jamais toucher le wallet d'un **autre**
   utilisateur, même si la méthode était un jour appelée.
5. **Le débit est-il protégé contre les modifications arbitraires ?** Oui, partiellement :
   les Rules bornent la casse possible à une diminution du **propre** wallet du livreur
   (`wallet >= 0 && wallet < resource.data.wallet`), jamais une augmentation ni un débit
   d'un tiers.
6. **Existe-t-il une validation serveur ?** Non pour cette méthode spécifique — c'est
   précisément ce qui en fait une violation de l'invariant si elle était appelée. La
   validation serveur existe dans le mécanisme parallèle et actif (`acceptOrder`).
7. **Le débit est-il transactionnel ?** Oui (`db.runTransaction`), mais seule la mise à
   jour du wallet l'est — le `_logTransaction` qui suit est un `.add()` séparé, hors
   transaction (incohérence mineure si jamais exécutée : la mise à jour du solde pourrait
   réussir sans que la ligne de journal soit créée, ou l'inverse en cas d'erreur réseau
   entre les deux appels).
8. **Peut-il être exécuté plusieurs fois ?** Oui — aucun identifiant idempotent (contraste
   avec `acceptOrder`, qui utilise `commission_<orderId>_<uid>` précisément pour empêcher
   un double prélèvement). Si un appelant était un jour ajouté sans réutiliser ce
   mécanisme, un double-appel (double-tap, retry réseau) causerait un double débit.
9. **Existe-t-il un risque de double débit ?** Uniquement si la méthode était un jour
   appelée sans protection anti-double-tap ou idempotence — risque latent, pas actif.
10. **Existe-t-il un risque de débit sur le mauvais wallet ?** Non — borné par
    `isOwner()` (voir Q4).
11. **Les Rules autorisent-elles réellement l'écriture ?** Oui, pour la branche
    « diminution de son propre solde » — c'est une permission intentionnelle et documentée
    des Rules (commentaire `firestore.rules:398-400` : *« OU en diminuant son wallet
    (déduction commission à l'acceptation) »*), pas une faille des Rules elles-mêmes.
    Le problème n'est donc pas une brèche de permission, mais l'existence d'un second
    chemin de code qui pourrait, en théorie, utiliser cette permission légitimement
    accordée pour un usage différent du flux serveur actuel.
12. **Le mécanisme est-il cohérent avec l'invariant financier du projet ?** Non, par la
    lettre : `.claude/rules/payments-wallet.md` énonce *« Aucun crédit/débit cross-user
    depuis Flutter »* et documente `acceptOrder` comme le point unique de prélèvement de
    commission. Un second code, non appelé, qui dupliquerait cette logique côté client
    est une incohérence architecturale même s'il est aujourd'hui inerte.

### Classification

**RISQUE POTENTIEL / PREUVES INSUFFISANTES — mais avec un chemin d'exploitation
actif confirmé absent.** Cette formulation volontairement nuancée reflète deux faits
distincts :
- **Côté exploitation actuelle : SÉCURISÉ.** Aucun appelant n'existe (preuve positive,
  pas une absence de recherche) ; même dans le pire cas théorique (code un jour relié), les
  Rules bornent tout débit frauduleux à de l'auto-préjudice (le livreur ne peut baisser que
  SON PROPRE solde, jamais celui d'un tiers) — aucune voie de vol cross-user n'existe.
- **Côté dette architecturale : RISQUE confirmé, de faible gravité mais réel.** Du code
  qui duplique une logique financière sensible (calcul + débit de commission) existe en
  dehors du chemin serveur documenté, sans idempotence, sans validation serveur, prêt à
  être réactivé par erreur (copier-coller, résurrection lors d'un refactor) — ce qui
  provoquerait alors soit un double prélèvement (la méthode + `acceptOrder`), soit une
  commission calculée sur un `price` non revalidé. C'est un risque de **régression
  future**, pas un risque d'exploitation présente.

**Recommandation (non exécutée ici)** : traiter dans une phase dédiée et explicitement
autorisée — soit la suppression de `deductCommission`/`calculateCommission` (si vraiment
mort et non référencé par un module de test ou de documentation qui en dépendrait), soit
sa mise en commentaire explicite "NE PAS UTILISER — remplacé par acceptOrder" si une
raison de la garder existe. Gravité : **faible à modérée** (pas d'exploitation possible
aujourd'hui, mais un risque de régression future bien réel et facile à corriger).

---

## Point B — `live_marker_cache.dart`

### Constat factuel

- Le cache (`onlineDriversFeed()`, ligne 99-105) exécute une requête Firestore
  **inchangée depuis sa conception** : `collection('livreurs').where('isOnline',
  isEqualTo: true).snapshots()` — donc `livreurs`, **pas** `driver_public` aujourd'hui
  (cohérent avec S6.0 : aucune migration n'a eu lieu).
- `liveDriverSnapshotFromQuery` (ligne 80-95) transmet le **document complet**
  (`d.data()`) à l'appelant, sans filtrage de champs — le cache lui-même ne retient rien
  en mémoire persistante au-delà des `Marker` reconstruits à chaque émission (pas de
  cache disque, pas de stockage local des champs bruts).
- **2 appelants identifiés par recherche exhaustive**, aucun autre :
  - `lib/screens/client/client_map.dart` — extrait seulement `lat`, `lng`, `name`
    (lignes 227-243) du document brut pour construire les marqueurs/info-windows. Aucune
    autre donnée n'est lue ni transmise plus loin.
  - `lib/screens/admin/admin_live_tracking_page.dart` — extrait `lat`, `lng`, `updatedAt`,
    `name`, **et `phone`** (lignes 78-89) pour l'info-window admin. `phone` est un champ
    privé, mais cet écran est réservé à l'admin, qui a de toute façon un accès complet et
    légitime à `livreurs` ailleurs (console admin, §3.2 de S6.0) — aucune élévation de
    privilège, juste un deuxième endroit où l'admin voit un champ qu'il voit déjà partout
    ailleurs.
- **Accès anonyme** : vérifié en remontant la chaîne de navigation de
  `client_map.dart`. Il n'est instancié que par `main_dashboard.dart` et
  `client_dashboard.dart`, tous deux atteints uniquement via `MainDashboard`, qui n'est
  lui-même poussé que depuis `home_screen.dart::_goToDashboard()` **après** un contrôle
  explicite : `final isAnon = user == null || user.isAnonymous; if (isAnon) { ... return
  à ClientAuthPage }` (lignes 213-219 et 250-258 de `home_screen.dart`). Un utilisateur
  anonyme ou non connecté est donc systématiquement redirigé vers la page de connexion
  **avant** de pouvoir atteindre `ClientMap`. L'unique appel `signInAnonymously()` présent
  dans ce fichier (ligne 236) est un cas de bord isolé (réinitialisation de session pour
  un compte vendeur dont le mot de passe temporaire n'a pas été activé) qui ne mène
  jamais à `MainDashboard` — il se contente de déconnecter puis retourner.
  **Conclusion : aucun chemin anonyme confirmé vers ce site de lecture.**
- `driver_public` répondrait déjà, sans aucune modification de ce fichier, au besoin de
  `client_map.dart` (3 champs, tous dans la whitelist) — confirmant la classification
  **A** de S6.0 pour ce chemin précis. Le besoin d'`admin_live_tracking_page.dart` (qui
  inclut `phone`) reste en **C** (admin, accès déjà légitime), comme déjà conclu en S6.0.

### Classification

Aucune anomalie trouvée. Les deux incertitudes de S6.0 (champs exacts, accès anonyme)
sont levées : champs confirmés ci-dessus, accès anonyme explicitement exclu par le code
de navigation. Pas de donnée sensible transmise à un utilisateur non autorisé.

---

## Point C — `suivi_commande.dart`, les 2 sites

### Site 1 — `FutureBuilder` ligne 302-317 (widget de carte « livreur assigné »)

- **Emplacement exact** : `lib/screens/client/suivi_commande.dart:302-317`.
- **Type de lecture** : `get()` (one-shot), reconstruit à chaque `build()` du widget
  parent — anti-pattern de requête réseau dans un `itemBuilder`/`build()` déjà documenté
  comme dette connue (`.claude/rules/flutter-ui.md`), **non corrigé ici** (hors périmètre
  explicite de cette phase).
- **Collection** : `livreurs/{order.driverId}`.
- **Champs lus** : `photoUrl` (ligne 313), `name` (ligne 368), `phone` (ligne 373).
- **Champs consommés/affichés** : les trois, dans une carte « livreur » avec photo,
  nom et numéro de téléphone affiché en texte (pas de bouton d'appel direct visible à cet
  emplacement précis, contrairement au site `_callDriver()` déjà inventorié en S6.0).
- **Dépendance au téléphone** : oui, directe (`driver["phone"]` affiché).
- **Dépendance GPS** : non.
- **Dépendance nom/photo** : oui, les deux.
- **Classification S6.0** : **B** (photoUrl/name migrables ; phone dépendant de **D**,
  le mécanisme `driverPhone` non construit).
- **Possibilité de migration future** : la partie photo/nom pourrait migrer vers
  `driver_public` indépendamment de la partie téléphone (qui resterait un `get()` sur
  `livreurs` jusqu'à la construction de `driverPhone`, ou serait retirée si ce numéro
  doit disparaître de cet écran au profit d'un bouton d'appel serveur-géré).

### Site 2 — `_listenDriver()` ligne 1328-1352 (`OrderMapPage`, carte de suivi)

- **Emplacement exact** : `lib/screens/client/suivi_commande.dart:1328-1352`
  (classe `_OrderMapPageState`).
- **Type de lecture** : `stream` (`.snapshots().listen`).
- **Collection** : `livreurs/{order.driverId}`.
- **Champs lus** : `lat`, `lng` uniquement (lignes 1336-1337).
- **Champs consommés/affichés** : position du marqueur « Livreur » sur une
  `GoogleMap`, rien d'autre.
- **Dépendance au téléphone** : non.
- **Dépendance GPS** : oui, exclusive.
- **Dépendance nom/photo** : non.
- **Classification S6.0** : **A** — correspondance exacte, aucun champ hors whitelist.
- **Possibilité de migration future** : migrable immédiatement, sans aucune dépendance,
  dès la phase S6.2 proposée dans le plan (services de suivi temps réel).

Les deux sites sont désormais entièrement confirmés ; l'inventaire S6.0 pour ce fichier
était incomplet mais pas erroné dans ses hypothèses (il supposait un alignement probable
avec les services de suivi pour le site 2 — confirmé exact).

---

## Point D — le champ `rating`

### Toutes les occurrences pertinentes de `rating` (hors `avgRating`/`ratingCount`)

Recherche exhaustive (`grep -rn "'rating':"` et équivalent guillemets doubles) dans
`lib/` et `functions/` :

| Occurrence | Collection cible | Nature |
|---|---|---|
| `driver_profil.dart:374` | **lecture** `livreurs/{driverId}` | **le site en question** |
| `event_service.dart:92,227,365` | `events`/sous-collections événementielles | note d'un événement, sans rapport avec les livreurs |
| `order_model.dart:235` | modèle `orders` | note d'une commande (client → partenaire), sans rapport |
| `web_artisans_page.dart:592,603` | artisans (page web) | note d'un artisan, sans rapport |
| `ek_service.dart:268`, `ek_agent_register.dart:491`, `ek_agent.dart:79` | module E-Kbine (`ekbine_agents`) | note d'un agent E-Kbine, module distinct des livreurs |
| `suivi_commande.dart:1445` | collection `reviews` (+ `avgRating`/`ratingCount` sur `sellers`/`restaurants`/`boulangeries`, lignes 1431-1438) | avis **vendeur/restaurant/boulangerie**, pas livreur |
| `service_providers_page.dart:557,572` | prestataires de services | note d'un prestataire, sans rapport |
| `firestore_service.dart:478` | `orders/{orderId}.rating` | note **de la commande elle-même** (différente du livreur) |

**Aucune de ces occurrences n'écrit jamais `rating` sur `livreurs/{driverId}`.**

### Comparaison avec le mécanisme réel de notation du livreur

`functions/driverRatings.js` (déjà audité en S5.3.4) lit et écrit exclusivement
`avgRating` et `ratingCount` sur `livreurs/{driverId}` — jamais `rating`.
`driver_dashboard.dart::_listenDriverDoc` (ligne 123-137, confirmé par l'inventaire S6.0)
lit correctement `avgRating` pour l'affichage de la note sur le tableau de bord principal
du livreur. Ces deux usages sont cohérents entre eux et avec la whitelist `driver_public`.

### Conclusion

`driver_profil.dart:374` (`final rating = data["rating"] ?? 0.0;`) lit un champ qui
**n'existe jamais** sur `livreurs/{driverId}` dans le code actuel (aucun écrivain
identifié, nulle part). Ce champ affiche donc **systématiquement 0.0** sur l'écran de
profil du livreur, quelle que soit sa vraie note (`avgRating`), qui existe bel et bien
mais n'est jamais lue à cet endroit précis. Origine : même commit fondateur (`a7f8423`)
que `deductCommission`, antérieur à la convention `avgRating`/`ratingCount` utilisée
partout ailleurs dans le projet — un reliquat d'un schéma de champ différent (ou jamais
implémenté), jamais corrigé depuis.

- **Signification exacte** : champ mort côté lecture, sans correspondance avec aucun
  champ réellement écrit sur `livreurs`.
- **Origine** : copiée depuis la création du fichier, sans lien avec le mécanisme de
  notation réellement construit plus tard.
- **Stockage** : aucun — le champ `rating` n'est stocké sur aucun document `livreurs`.
- **Destination/usage** : uniquement un bug d'affichage (« 0.0 » permanent) sur l'écran
  de profil du livreur — pas un risque de sécurité, un défaut fonctionnel mineur.
- **Correspondance avec `driver_public`** : aucune directe. Le champ **voulu** ici est
  presque certainement `avgRating`, qui lui est déjà dans la whitelist `driver_public` et
  déjà utilisé correctement par `driver_dashboard.dart`.
- **Migration possible ?** Une fois corrigé pour lire `avgRating` (correction hors
  périmètre de cette phase read-only), ce site rejoindrait naturellement la catégorie
  **A** de S6.0 — mais tant qu'il n'est pas corrigé, migrer ce site vers `driver_public`
  ne changerait rien : il continuerait à lire un champ `rating` absent de la whitelist et
  à afficher 0.0, juste depuis une autre collection.
- **Mapping nécessaire ?** Oui, si une correction est décidée : remplacer `data["rating"]`
  par `data["avgRating"]` — changement d'une ligne, mais c'est une **correction de bug**,
  pas une migration de lecteur, et donc hors du périmètre strictement read-only de cette
  phase (non effectuée ici).

---

## Tests exécutés

Aucun test automatisé n'a pu être exécuté pour les Points B, C, D : l'environnement de
cette session ne dispose pas de la commande `flutter` (`which flutter` → introuvable,
confirmé comme en S5.3.4 — signalé honnêtement, pas de résultat inventé). Des tests
existants et pertinents ont été repérés (`test/widgets/live_marker_cache_test.dart`,
`test/screens/client/client_map_live_markers_test.dart`,
`test/screens/admin/admin_live_tracking_live_markers_test.dart`,
`test/screens/client/suivi_commande_payment_message_test.dart`) et lus (pas exécutés) —
`live_marker_cache_test.dart` ne couvre que la fonction pure `applyLiveMarkerChanges`
(fusion incrémentale de marqueurs), pas l'exposition de champs, donc sans incidence sur
les conclusions ci-dessus. Le Point A (`deductCommission`) ne nécessitait aucune
exécution de test : la conclusion repose sur une recherche exhaustive de code (absence
d'appelant), vérifiable statiquement.

## Risques

- **A** : dette architecturale de code mort dupliquant une logique financière — risque de
  régression future si réactivé sans discipline (voir Point A). Pas de risque actif.
- **B** : aucun risque résiduel identifié après vérification complète.
- **C** : aucun risque résiduel — les 2 sites sont maintenant pleinement classifiés comme
  en S6.0 (B et A respectivement), sans surprise.
- **D** : bug fonctionnel mineur (affichage figé à 0.0), aucune implication de sécurité
  ou de confidentialité — ne bloque ni la migration ni la fermeture future des Rules
  `livreurs` (la whitelist `driver_public` reste correcte indépendamment de ce bug
  d'affichage côté lecteur).

## Recommandations (aucune exécutée)

1. Décider, dans une phase dédiée et explicitement autorisée, du sort de
   `deductCommission`/`calculateCommission` (suppression ou neutralisation documentée).
2. Corriger, dans une phase dédiée, `driver_profil.dart:374` pour lire `avgRating` au
   lieu de `rating` — bug mineur, correction triviale, sans rapport avec SEC-01 au-delà
   du fait qu'elle a été découverte pendant cet audit.
3. Aucune action requise pour les Points B et C : les classifications S6.0 (A pour le
   site GPS de `suivi_commande.dart`, B pour son site photo/nom/téléphone, A/C selon
   l'appelant pour `live_marker_cache.dart`) sont confirmées telles quelles.

## Verdict

**AUDIT VALIDÉ AVEC RÉSERVES.**

Les 4 incertitudes sont intégralement clarifiées avec preuves directes (recherche
exhaustive de code, lecture ligne à ligne, remontée de la chaîne de navigation,
historique Git). Deux anomalies non bloquantes pour S6.1 sont confirmées et documentées
(code mort financier au Point A, bug d'affichage au Point D) — toutes deux nécessitent
une phase de correction séparée et explicitement autorisée, ni l'une ni l'autre n'empêche
de poursuivre la planification de la migration des lecteurs. Points B et C : aucune
anomalie, incertitudes entièrement résolues.

Ce verdict n'autorise ni la correction du problème financier, ni celle du bug `rating`,
ni le commencement de S6.1.

**STOP après ce rapport. Pas d'enchaînement automatique sur S6.1.**
