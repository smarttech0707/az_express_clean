# SEC-01 — S6.5 : audit préalable des dépendances `phone`

Date : 2026-11-21
Type : audit exclusivement en lecture seule (aucune migration, aucune correction, aucun test créé)
Référence : `docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md` (catégorie D), `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md`, `docs/SEC01_S6_0_2/S6_0_3`, `docs/SEC01_S6_3_MULTI_DRIVER_READERS_MIGRATION.md`, `docs/SEC01_S6_3_1_VEHICLE_LIVE_MARKER_AUDIT.md`, `docs/SEC01_S6_4_HYBRID_READERS_MIGRATION.md`, `docs/DRIVER_PUBLIC_MIGRATION_PLAN.md`

## 1. Résumé exécutif

Les 7 lecteurs `phone` identifiés depuis S6.0 sont reconfirmés à l'identique — **aucun lecteur supplémentaire n'est apparu** depuis S6.0 (recherche exhaustive refaite). Le cycle de vie de `phone` sur `livreurs` est désormais cartographié précisément : un seul chemin de création **réellement actif** (`driver_requests_page.dart::_approve`, flux admin d'approbation), deux chemins de code mort qui l'écriraient aussi (`DriverService.addDriverToFleet`, `DriverService.registerDriver`, zéro appelant chacun — même anomalie que `deductCommission`, S6.0.3), aucune modification en cours de vie (aucun écran livreur ne permet de changer son propre numéro), et une suppression confirmée à la suppression de compte (`accountDeletion.js`, redaction générique).

Le mécanisme `driverPhone` sur `orders`, envisagé par le plan pré-existant comme solution de déblocage, **n'existe toujours pas en tant que donnée réellement écrite** — mais l'audit révèle une nuance nouvelle : le champ est déjà **anticipé par deux endroits du code de suppression de compte** (`functions/accountRelatedPersonalData.js`, `functions/accountDeletion.js`), qui le traiteraient correctement s'il était un jour ajouté (ils filtrent par présence réelle du champ, `Object.hasOwn`). Un examen des Rules `orders` révèle aussi un risque de conception important pour l'Option B, non mentionné dans les rapports précédents : `orders` est lisible non seulement par le client, mais aussi par le vendeur/restaurant/pharmacie de la même commande (`sellerId`) — poser `driverPhone` directement sur le document `orders` l'exposerait donc **aussi au partenaire**, pas seulement au client, sauf conception plus fine (sous-collection privée ou mécanisme dédié).

Recommandation : **Option D (séparation locale des lecteurs) en complément d'une Option B revue**, détaillées en §7/§8 — aucune des deux n'est mise en œuvre ici.

## 2. Liste exhaustive des lecteurs `phone` (recherche exhaustive refaite)

Recherche par `grep -rn "collection('livreurs')\|collection(\"livreurs\")"` dans tout `lib/`, suivie d'un examen de chaque occurrence sur ±10 lignes pour détecter un usage de `phone`, plus une recherche complémentaire ciblée `grep -rn "'phone'|\"phone\""` croisée avec le contexte `livreurs`/`driverId`. **Résultat : exactement les 7 lecteurs déjà connus, aucun nouveau.**

| # | Fichier:méthode | Contexte d'accès | Requête exacte |
|---|---|---|---|
| 1 | `lib/web/pages/client/web_client_dashboard.dart::_callDriver` (lignes 906-916) | Client (web) | `.collection('livreurs').doc(driverId).get()` |
| 2 | `lib/screens/client/suivi_commande.dart::_callDriver` (lignes 136-154) | Client (mobile) | `.collection("livreurs").doc(driverId).get()` |
| 3 | `lib/screens/customer_tracking_screen.dart::_loadDriverInfoById` (lignes 310-324) | Client (mobile, flux `livraison_screen.dart`, actif) | `.collection('livreurs').doc(driverId).get()` |
| 4 | `lib/screens/admin/admin_map.dart` (lignes 24, 67, 75) | Admin | `.collection("livreurs").snapshots()` (tous, sans filtre) |
| 5 | `lib/screens/pharmacie/pharmacie_dashboard.dart::_call`/builder (lignes 953-973, 1062-1064) | Partenaire (pharmacie) | `.collection('livreurs').doc(driverId).get()`/stream |
| 6 | `lib/screens/boulangerie/boulangerie_dashboard.dart` (lignes 705-767, inline builder) | Partenaire (boulangerie) | `.collection('livreurs').doc(driverId).snapshots()` |
| 7 | `lib/screens/seller/seller_dashboard.dart::_DriverSection` (lignes 1421-1437, 1537-1543) | Partenaire (vendeur marketplace) | `.collection('livreurs').doc(driverId).snapshots()` |

## 3. Analyse détaillée de chaque lecteur

### 3.1 `web_client_dashboard.dart::_callDriver`

```dart
Future<void> _callDriver(String driverId) async {
  try {
    final doc = await FirebaseFirestore.instance.collection('livreurs').doc(driverId).get();
    final phone = doc.data()?['phone'] as String?;
    if (phone == null || phone.isEmpty) return;
    await launchUrl(Uri(scheme: 'tel', path: phone));
  } catch (_) {}
}
```
- **Champs lus** : `phone` uniquement.
- **Usage** : bouton d'appel direct (`tel:`), déclenché à la demande du client sur sa propre commande en cours.
- **Dépendance indirecte** : aucune — fonction autonome, pas de cache.
- **Risque fonctionnel en cas de migration** : la fonctionnalité d'appel disparaîtrait entièrement si migrée vers `driver_public` sans alternative (le champ n'existe pas dans la projection).
- **Risque de confidentialité actuel** : le client a déjà accès à ce numéro via cette fonctionnalité volontaire (contact nécessaire à la livraison) — pas une fuite, une fonctionnalité voulue.
- **Séparation publique/privée** : triviale par nature — ce lecteur ne lit *que* `phone`, il n'y a rien à séparer (il ne lit déjà aucun champ public). La question n'est pas de séparer une requête mixte ici, mais de trouver une source alternative pour `phone` seul.

### 3.2 `suivi_commande.dart::_callDriver`

Identique en substance à 3.1 (même pattern `get()` + `tel:`), avec une validation supplémentaire (`phone.isEmpty`, message d'erreur si absent). Même conclusion.

### 3.3 `customer_tracking_screen.dart::_loadDriverInfoById`

```dart
final doc = await FirebaseFirestore.instance.collection('livreurs').doc(driverId).get();
...
_driverName = d['name'] as String?;
_driverPhoto = d['photoUrl'] as String?;
_driverPhone = d['phone'] as String?;
_driverRating = (d['avgRating'] as num?)?.toDouble();
```
- **Champs lus** : `name`, `photoUrl`, `phone`, `avgRating` — **lecteur hybride** (3 champs publics + 1 privé), déjà classé B en S6.0 et laissé intact en S6.4 pour cette raison (phone dans la même requête).
- **Usage** : `_driverPhone` est transmis à `EtaCard` (`lib/widgets/eta_card.dart`), qui affiche un bouton d'appel (`driverPhone != null` active le bouton, ligne 276 ; `tel:$driverPhone`, ligne 68).
- **Risque fonctionnel en cas de migration partielle** (migrer `name`/`photoUrl`/`avgRating` seuls, laisser `phone` sur une requête séparée) : faible, techniquement proche de ce qui a déjà été fait pour `driver_dashboard.dart::_listenDriverDoc` en S6.4 (ajout d'un second abonnement) — mais ici ce serait un second **get()** plutôt qu'un second stream, donc encore plus simple. Non réalisé dans cette phase, car hors périmètre strict (READ-ONLY).

### 3.4 `admin_map.dart`

```dart
stream: FirebaseFirestore.instance.collection("livreurs").snapshots(),
...
String phone = data["phone"] ?? "";
... snippet: phone,
```
- **Champs lus** : tout le document livré au builder, mais seuls `lat`/`lng` (marqueur) et `phone` (snippet) sont effectivement consommés (confirmé par lecture complète du fichier en S6.4).
- **Usage** : affichage passif dans l'info-bulle du marqueur (pas de bouton d'appel actif dans cet extrait).
- **Contexte d'accès** : admin — accès déjà légitime et complet à `livreurs`, indépendamment de cette fonctionnalité précise. **Recommandation constante depuis S6.0 §6 : ne jamais migrer la console admin**, ce lecteur y compris.
- **Risque de confidentialité** : nul — l'admin a déjà un accès complet et légitime.

### 3.5 `pharmacie_dashboard.dart` (`_DriverInfoCard`, `_call`)

```dart
Future<void> _call(String phone) async { ... launchUrl(Uri.parse('tel:$phone')); }
...
final phone = d['phone'] as String? ?? '';
final moto = d['motoModel'] as String? ?? '';
```
- **Champs lus** : `name`, `photoUrl`, `phone`, `motoModel` — hybride, **avec un second champ absent de `driver_public`** (`motoModel`, déjà noté en S6.0 §4/D comme nécessitant une décision d'extension de la liste blanche, jamais prise).
- **Usage** : carte d'info sur le livreur assigné + bouton d'appel actif (ligne 1064, `onTap: () => _call(phone)`).
- **Risque fonctionnel en cas de migration** : élevé si fait sans séparation — double motif de blocage (`phone` + `motoModel`), aucun des deux disponible dans `driver_public`.

### 3.6 `boulangerie_dashboard.dart`

Reproduit intégralement en §4 de cette analyse de code (lignes 705-767) : `StreamBuilder` unique sur `livreurs/{driverId}`, consommant `name`, `phone`, `isOnline` dans le même `builder`, avec un bouton d'appel direct (`GestureDetector` → `launchUrl('tel:$dPhone')`, ligne 756). Risque identique aux précédents : un seul flux mixte, sans séparation établie.

### 3.7 `seller_dashboard.dart::_DriverSection`

```dart
.collection('livreurs')...
final phone = data['phone'] as String?;
...
if (phone != null) IconButton(onPressed: () { launchUrl(Uri.parse('tel:$phone')); }, icon: Icon(Icons.phone_rounded, ...))
```
- **Champs lus** : `name`, `phone`, `lat`, `lng`, `isOnline` — hybride, bouton d'appel actif à deux endroits du widget (lignes ~1399 et ~1540, l'un pour le numéro du client de la commande — `order.clientPhone`, sans rapport — l'autre pour le livreur).
- Même conclusion que les sites 5/6 : requête mixte, aucune séparation existante.

## 4. Lecteurs supplémentaires introduits depuis S6.0 ?

**Aucun.** Recherche exhaustive refaite (grep sur toutes les occurrences de `collection('livreurs')`/`collection("livreurs")` dans `lib/`, croisée avec toute occurrence du mot `phone` à proximité) : les 7 sites listés en §2 sont exactement ceux déjà identifiés en S6.0, sans ajout ni suppression depuis. Les migrations S6.1/S6.2/S6.3 ont porté sur des lecteurs entièrement distincts (`name` seul, services de tracking, `destination_picker.dart`) ; S6.4 a migré un champ (`avgRating`) sur un lecteur (`driver_dashboard.dart`) qui ne lit jamais `phone`. Aucun de ces changements n'a affecté la liste des 7.

## 5. Cartographie du cycle de vie de `phone`

### 5.1 Création

| Chemin | Collection | Statut |
|---|---|---|
| `driver_register.dart` (lignes 190-205) → `driver_requests/{uid}` avec `"phone": phone` | `driver_requests` | **Actif** — auto-inscription in-app du candidat livreur |
| `driver_requests_page.dart::_approve` (lignes 28-48) → `livreurs/{uid}` avec `"phone": data["phone"] ?? ""` | `livreurs` | **Actif** — seul chemin qui pose réellement `phone` sur `livreurs`, copié depuis `driver_requests` au moment de l'approbation admin |
| `lib/web/pages/drivers_page.dart` (lignes 234-247) → `driver_applications` avec `'phone': _phoneCtrl.text` | `driver_applications` | **Actif, mais collection distincte** — formulaire public du site vitrine, candidature traitée séparément (pas de lien direct confirmé vers `driver_requests_page.dart::_approve`, qui ne lit que `driver_requests`) |
| `DriverService.registerDriver` (`driver_service.dart:7-8`) → `livreurs` via `DriverModel.toMap()` | `livreurs` | **Code mort** — `DriverService` n'est instanciée nulle part (`grep -rn "DriverService"` : une seule occurrence, la déclaration) |
| `FirestoreService.addDriverToFleet` (`firestore_service.dart:538-550`) → `livreurs` (ajout direct) | `livreurs` | **Code mort** — zéro appelant (`grep -rn "addDriverToFleet"` : une seule occurrence, la déclaration) |

### 5.2 Modification

Aucun écran livreur ne permet de modifier son propre `phone` après approbation (recherche exhaustive dans `lib/screens/driver/` : aucune occurrence d'écriture de `phone`). La seule voie de modification possible serait une intervention admin directe sur `livreurs` (non observée dans le code — aucun champ de saisie `phone` trouvé dans les écrans admin de gestion de livreur) ou, en théorie, une écriture cliente directe : les Rules `livreurs` (`firestore.rules` lignes 396-500) **ne restreignent `phone` d'aucune façon** — contrairement à `wallet`/`isSuspended`/`deletionRequested`/`ownerId`/`ownerName` (explicitement `unchanged()` dans la branche propriétaire) et contrairement à `name`/`photoUrl`/`isOnline` sur `driver_public` (verrouillés depuis S5.3.5). **Un livreur pourrait donc, en théorie, modifier son propre `phone` sur `livreurs` par une écriture directe**, même en l'absence d'un écran prévu à cet effet — incohérence de moindre privilège déjà notée pour `name`/`photoUrl`/`isOnline` sur `livreurs` lui-même dans le rapport S5.3.5 (« résidu non corrigé »), et qui s'étend donc aussi à `phone`.

### 5.3 Suppression

Confirmée dans `functions/accountDeletion.js` (lignes 161-167, pipeline de suppression/quarantaine) :

```js
const personal=['name','fullName','firstName','lastName','phone','email','identifiant','address','photoUrl','fcmToken','token','lat','lng','latitude','longitude', ...];
const patch={isDeleted:true,isOnline:false,isAvailable:false,isSuspended:true,deletedAt:stamp()};
for(const k of personal)if(Object.hasOwn(check.profile,k))patch[k]=admin.firestore.FieldValue.delete();
```

`phone` fait partie des champs personnels explicitement supprimés (`FieldValue.delete()`) lors d'une suppression de compte livreur, dans la même transaction que les autres marquages (`isDeleted`, `isSuspended`), en préservant tous les champs financiers. Comportement conforme au principe déjà établi ailleurs (`accountDeletionScope.js`, `.claude/rules/auth-identity.md`).

### 5.4 `driver_requests` (candidature)

`phone` y est créé par `driver_register.dart`, lu par `driver_requests_page.dart` (admin) pour approbation ou rejet, puis le document entier est supprimé (`batch.delete(doc.reference)`, ligne 50) après copie vers `livreurs` — `phone` ne survit donc pas sur `driver_requests` après approbation (transfert, pas duplication permanente).

### 5.5 `orders` — `driverPhone`

**N'existe pas comme donnée réellement écrite.** Deux mentions trouvées, toutes deux défensives/anticipatoires, pas des preuves d'usage réel :

- `functions/accountRelatedPersonalData.js:14` (`relatedPersonalPatch`) : liste `driverPhone` parmi les champs à effacer d'une commande si le livreur supprime son compte — mais la fonction filtre par présence réelle (`Object.hasOwn(data, field)`), donc elle ne fait rien si le champ n'existe pas. Code prêt à accueillir le champ, pas une preuve qu'il existe.
- `functions/accountDeletion.js:168` : même liste, même logique défensive, dans un contexte legacy (`j.role==='client'?[...]:['driverName','driverPhone',...]`).
- `rules-tests/account-deletion.test.js:31` : un test construit une commande simulée avec `driverPhone:'PHONE'` pour vérifier que la redaction fonctionnerait *si* le champ existait — un test de robustesse anticipatoire, pas une preuve de production.
- Aucune Cloud Function (`driverAcceptance.js`, `dispatch.js`, `orderActions.js`, `driverTransfer.js`) n'écrit jamais `driverPhone` sur un document `orders` (recherche exhaustive, zéro résultat).
- Côté Flutter, `driverPhone` n'existe que comme paramètre de widget (`eta_card.dart`, `customer_tracking_screen.dart`), alimenté directement par la lecture `livreurs.phone` (§3.3), jamais par un champ `orders.driverPhone` lui-même absent.

**Conclusion** : le code de suppression de compte est déjà « prêt » pour ce champ (il ne casserait rien s'il apparaissait), mais rien ne l'écrit — confirmation précise et à jour de ce qu'affirmaient déjà S6.0/S6.0.1, avec la nuance nouvelle de cette anticipation défensive côté suppression de compte.

## 6. Analyse des Rules et de la confidentialité

- **`livreurs` (lignes 396-500)** : lecture ouverte à tout utilisateur authentifié, anonymes compris (`allow read: if isAuth();`) — **`phone` est donc déjà lisible aujourd'hui par n'importe quel compte authentifié**, pas seulement par les 7 lecteurs ci-dessus ; ces 7 lecteurs sont simplement les endroits du code qui *affichent* ou *utilisent* ce numéro, pas les seuls qui pourraient techniquement le lire. C'est précisément la justification de fond de SEC-01 (fermer `livreurs`).
- **`driver_requests` (lignes 502-507)** : lecture limitée à l'admin ou au propriétaire de la demande (`resource.data.uid == uid()`) — correctement restreint, pas un problème de confidentialité en soi (c'est une candidature, pas encore un compte actif).
- **`orders` (lignes 767-774)** : lecture ouverte à `clientId`, `driverId`, `sellerId`, le propriétaire pharmacie, et l'admin. **Risque de conception pour l'Option B** : si `driverPhone` était simplement ajouté comme champ du document `orders`, il serait automatiquement lisible par le **vendeur/restaurant/pharmacie** de cette commande (`sellerId`), pas seulement par le client — Firestore Rules ne permettent pas de restriction par champ à l'intérieur d'un même document, seulement par document entier. Ce risque n'était pas mentionné explicitement dans les rapports précédents (S6.0 le supposait implicitement sûr car « lisible par le client propriétaire de la commande », sans vérifier que d'autres rôles partagent aussi l'accès en lecture au même document).
- **Accès non authentifiés** : aucun — `isAuth()` est requis pour `livreurs` comme pour `orders`, et les 7 lecteurs identifiés sont tous atteints depuis des écrans authentifiés (confirmé pour les contextes client en S6.0.1 ; pour les contextes partenaire/admin, l'authentification de rôle est intrinsèque à l'accès à ces tableaux de bord).
- **Accès authentifiés mais non autorisés** : le principal est déjà documenté — n'importe quel compte authentifié (client, livreur d'un autre compte, etc.) peut lire `livreurs.phone` de n'importe quel livreur via une simple requête directe, même sans passer par un des 7 écrans. C'est l'exposition structurelle que SEC-01 cherche à réduire.
- **Contrôle server-side existant** : aucun mécanisme de masquage ou de relais d'appel (proxy téléphonique) n'a été trouvé dans le dépôt (recherche de motifs usuels — aucun résultat pertinent). Le seul contrôle server-side pertinent est la suppression du champ à la suppression de compte (§5.3).
- **Risque d'accès indirect** : la requête `admin_map.dart` (`.collection("livreurs").snapshots()`, sans filtre) récupère déjà tous les documents, y compris `phone`, côté client — ce n'est un risque nouveau pour personne d'autre que l'admin lui-même (déjà autorisé), mais cela illustre que toute requête non filtrée sur `livreurs` ramène `phone` par défaut, qu'il soit utilisé ou non par l'écran.
- **Principe du moindre privilège** : non respecté aujourd'hui pour `phone` (lisible par tout authentifié, alors que seuls 7 écrans + l'admin en ont un besoin réel identifié) — c'est exactement la motivation initiale de SEC-01, pas une découverte nouvelle, mais reconfirmée précisément ici.

## 7. Comparaison des options

### Option A — Maintenir les lecteurs `phone` dans `livreurs`

- **Avantages** : aucun développement, aucun risque de régression, comportement actuel déjà fonctionnel pour les 7 écrans.
- **Inconvénients** : aucune réduction de la surface d'exposition de `phone` (lisible par tout authentifié) ; bloque la fermeture complète de `livreurs` tant que ces 7 lecteurs existent.
- **Impact sur SEC-01** : neutre à court terme, mais empêche l'objectif final (fermeture des Rules `livreurs` aux rôles non essentiels, §12 de S6.0) tant qu'aucune alternative n'existe pour `phone`.

### Option B — Stocker `driverPhone` dans `orders`

- **Existe déjà ?** Non — confirmé en détail §5.5.
- **Mécanismes de commande à adapter** : `driverPhone` devrait être posé à l'**assignation** (`dispatch.js`/`driverAcceptance.js::acceptOrder`), et **mis à jour à chaque transfert** (`driverTransfer.js`, confirmé que `order.driverId` change bien de valeur lors d'un transfert accepté, ligne 501 : `newDriverId: t.toDriverId`) — sans quoi le client appellerait l'ancien livreur après un transfert. C'est un point que les rapports précédents n'avaient pas détaillé : **le champ ne peut pas être posé une seule fois à la création**, il doit suivre tout changement de `driverId` sur la durée de vie de la commande (acceptation initiale, re-dispatch après expiration via `dispatchRetry.js`, transfert en cours de route).
- **Risque d'accès aux commandes** : voir §6 — `orders` est lisible par `clientId`, `driverId`, `sellerId`, pharmacie propriétaire, admin. Poser `driverPhone` en champ racine l'expose à **tous** ces rôles pour cette commande, pas seulement au client. Pour les commandes marketplace/boutique/restaurant/pharmacie (qui ont un `sellerId`), le partenaire verrait aussi le numéro du livreur — probablement sans besoin réel (aucun des 7 lecteurs côté partenaire n'a besoin du numéro du livreur *via* la commande du client ; `pharmacie_dashboard.dart`/`boulangerie_dashboard.dart`/`seller_dashboard.dart` le lisent déjà directement sur `livreurs`, pour une raison différente — contacter le livreur qui leur est assigné en tant que partenaire, pas en tant que tiers sur la commande d'un client).
- **Risques d'exposition** : élevé pour les clients/vendeurs/partenaires simultanément si fait naïvement (champ racine) ; maîtrisable avec une sous-collection dédiée scoper au client uniquement (ex. `orders/{id}/driver_contact/{doc}` avec une règle de lecture restreinte à `clientId` seul) — option non explorée par le plan pré-existant, qui supposait (sans le vérifier) que le champ racine suffirait.
- **Règles et mécanismes server-side** : aucune règle n'existe aujourd'hui pour un tel champ ou une telle sous-collection (confirmé §6) — à concevoir entièrement.
- **Conclusion** : techniquement faisable, mais plus coûteux que ce que les rapports précédents laissaient supposer — nécessite (a) une sous-collection ou un mécanisme de lecture plus fin que le champ racine, (b) une mise à jour à chaque changement de `driverId` (3 points d'écriture serveur distincts au minimum), (c) de nouvelles Rules dédiées et testées.

### Option C — Service privé dédié au téléphone

- **Architecture minimale envisageable** : une Cloud Function callable (`getDriverContactForOrder({orderId})`) qui vérifie côté serveur que l'appelant est bien `clientId` (ou le partenaire légitime) de la commande, lit `livreurs.phone` via l'Admin SDK (donc hors Rules), et retourne uniquement le numéro, à la demande (pas en continu, pas en `Stream`).
- **Autorisations** : contrôle précis possible côté serveur (vérifier le rôle exact de l'appelant par rapport à la commande ou au livreur, logguer l'accès via `logAudit` si souhaité) — plus fin que ce que les Rules Firestore permettent nativement sur un document partagé.
- **Risques de sécurité** : plus faibles qu'Option B en théorie (le numéro ne transite jamais par une lecture Firestore directe, donc jamais par un document lisible par un tiers non prévu) ; nécessite cependant de bien définir qui peut appeler cette fonction pour quelle commande/quel livreur, avec le même soin que `driverAcceptance.js` ou `orderActions.js`.
- **Coût de migration** : plus élevé qu'Option D à court terme (nouvelle Cloud Function, nouveaux tests dédiés, changement des 7 appels `get()`/`stream` existants en appel `httpsCallable`) mais résout le problème de façon durable et generalisable (pas seulement pour la livraison en cours, potentiellement réutilisable pour d'autres rôles).
- **Compatibilité avec les lecteurs existants** : les 7 lecteurs devraient tous changer de mécanisme (passer d'une lecture Firestore à un appel de fonction) — changement plus profond qu'un simple changement de nom de collection, mais chaque site reste individuellement simple à adapter (remplacer `get()` par `httpsCallable(...).call(...)`).

### Option D — Séparation locale des lecteurs

- **Principe** : pour chacun des 7 lecteurs, séparer la requête mixte (si elle l'est) en deux lectures distinctes — une vers `driver_public` pour les champs publics, une vers `livreurs` conservée telle quelle pour `phone` seul (et `motoModel` pour le cas n°5).
- **Coût par lecteur** : faible et déjà démontré — c'est exactement le pattern appliqué en S6.4 à `driver_dashboard.dart::_listenDriverDoc` (un second abonnement/appel, sans nouvelle architecture). Pour les lecteurs `get()` ponctuels (n°1, 2, 3, 5), ce serait même plus simple qu'un `Stream` : un second `.get()` sur `livreurs` pour `phone` seul, à côté d'un premier sur `driver_public` pour le reste.
- **Risque de régression** : faible, à condition de garder le comportement de repli existant (numéro absent/vide → bouton désactivé ou message, déjà en place dans tous les sites examinés).
- **Admin (n°4)** : à exclure de toute séparation — accès déjà légitime et complet, aucun bénéfice à migrer (cohérent avec S6.0 §6).
- **Avantage par rapport à l'Option B/C** : ne nécessite **aucun** changement de Cloud Function, de Rules, ni de structure de commande — seulement des lectures côté client, strictement dans l'esprit déjà autorisé par SEC-01 jusqu'ici (S6.1-S6.4). C'est la voie la moins coûteuse pour réduire immédiatement la dépendance à `livreurs` sur les champs publics de ces 6 lecteurs (hors admin), même si `phone` lui-même continue d'y être lu.
- **Limite** : ne réduit pas l'exposition de `phone` lui-même (toujours lisible par tout authentifié sur `livreurs`) — seulement l'exposition des 6 autres champs. La fermeture complète des Rules `livreurs` resterait bloquée tant que `phone` lui-même n'a pas une alternative (Option B ou C).

### Option E — Autre solution

Aucune autre solution n'est apparue justifiée par l'architecture réelle du dépôt au-delà des 4 ci-dessus. Une variante hybride B+C (poser `driverPhone` sur une sous-collection privée de la commande, mais via une Cloud Function de lecture plutôt qu'une lecture Firestore directe) combinerait les avantages des deux, mais ce n'est qu'une nuance d'implémentation de B/C, pas une option fondamentalement distincte — mentionnée ici par transparence, non développée comme option séparée.

## 8. Recommandation argumentée

1. **Court terme, sans risque, dans une phase dédiée et autorisée séparément** : appliquer l'Option D aux 6 lecteurs non-admin (n°1, 2, 3, 5, 6, 7) — séparer leur partie publique (`name`/`photoUrl`/`lat`/`lng`/`isOnline`/`avgRating` selon le site) vers `driver_public`, en conservant une lecture dédiée et inchangée vers `livreurs` pour `phone` (et `motoModel` au n°5, qui resterait bloqué de toute façon tant que ce champ n'est pas ajouté à la liste blanche — décision distincte, non prise ici). Risque et coût faibles, pattern déjà validé en S6.4.
2. **Moyen terme, décision à part, hors SEC-01-lecteurs stricto sensu** : si l'objectif final est de pouvoir un jour fermer complètement les Rules `livreurs`, `phone` lui-même doit obtenir une alternative. Entre B et C, **l'Option C (fonction callable dédiée) est recommandée** plutôt que l'Option B simple (champ racine sur `orders`), en raison du risque de sur-exposition identifié en §6/§7-B (le partenaire de la commande verrait aussi le numéro du livreur). Si l'Option B est malgré tout préférée pour sa simplicité perçue, elle devrait être conçue avec une sous-collection dédiée et scoper en lecture au seul `clientId`, jamais en champ racine du document `orders`.
3. Ni B ni C ne sont à entreprendre sans une décision explicite et séparée du porteur du projet — ce sont des développements fonctionnels non triviaux (nouvelle Cloud Function et/ou nouvelles Rules), au-delà du périmètre d'une « migration de lecteur ».

## 9. Liste des migrations potentielles, ordonnées par risque

1. **Risque quasi nul** : séparer la partie publique de `customer_tracking_screen.dart::_loadDriverInfoById` (n°3) — déjà un simple `get()`, pattern déjà validé.
2. **Risque faible** : séparer la partie publique de `boulangerie_dashboard.dart` (n°6) et `seller_dashboard.dart` (n°7) — streams simples, un seul champ de filtre (`isOnline` pour seller_dashboard).
3. **Risque faible à modéré** : séparer la partie publique de `pharmacie_dashboard.dart` (n°5) — bloqué en partie par `motoModel`, qui resterait sur `livreurs` de toute façon (pas un nouveau risque, juste un gain partiel).
4. **Hors périmètre de toute séparation locale, nécessite une décision structurelle** : `phone` lui-même, sur les 6 lecteurs non-admin — Option B ou C, à trancher séparément.
5. **Ne jamais migrer** : `admin_map.dart` (n°4) — accès admin déjà légitime et complet, aucun bénéfice.

## 10. Réserves, inconnues et éléments non vérifiables

- **`driver_applications` vs `driver_requests`** : les deux collections existent et portent chacune un champ `phone` écrit à la candidature, mais aucun lien direct n'a été trouvé entre elles dans le code examiné (le formulaire public `drivers_page.dart` écrit sur `driver_applications`, jamais lu par `driver_requests_page.dart::_approve`, qui ne lit que `driver_requests`) — il est possible qu'un processus manuel ou un outil non examiné dans cette phase transfère les candidatures de l'un vers l'autre ; non vérifié ici (hors périmètre strict de cette mission, qui porte sur `livreurs`/`orders`, pas sur la réconciliation entre les deux collections de candidature).
- **Admin, modification manuelle de `phone`** : aucun écran de modification trouvé, mais l'absence d'un écran n'exclut pas formellement une correction ponctuelle via un autre outil (console Firebase manuelle, script) — hors périmètre de vérification de cette phase (lecture de code uniquement, pas d'accès Firebase réel).
- **Coût exact d'une Option C** : l'estimation de coût (§7-C) est qualitative, fondée sur la taille des 7 sites et le pattern déjà connu des Cloud Functions callable du dépôt (`adminDriverRechargeCF`, etc.) — un chiffrage précis nécessiterait une phase de conception dédiée, non faite ici.
- **Impact de `dispatchRetry.js`** sur un éventuel `driverPhone` : confirmé que `driverId` peut changer via plusieurs mécanismes (assignation initiale, retry après expiration, transfert) mais le détail exact de `dispatchRetry.js` n'a pas été relu intégralement dans cette phase (uniquement cité par le fichier `.claude/rules/dispatch-gps.md`) — à vérifier plus précisément si l'Option B est un jour engagée.

## 11. Confirmation du respect du périmètre READ-ONLY

Aucun fichier de code, de test, de Rules, de configuration, de dépendance ou de lockfile n'a été modifié, créé ou supprimé dans cette phase. Seul le présent rapport Markdown a été créé, dans `docs/`. Aucune migration n'a été réalisée. Aucune connexion à un Firebase réel. Aucun déploiement. Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié. Aucune opération Git destructive, aucun commit, aucun push, aucun changement de branche. Toutes les modifications locales préexistantes (confirmées par `git status` en début de phase, aucune touchée) sont restées intactes.

## 12. Verdict

**AUDIT VALIDÉ**

L'audit répond intégralement aux questions posées : les 7 lecteurs sont confirmés exhaustifs et inchangés depuis S6.0, le cycle de vie complet de `phone` (création, absence de modification, suppression) est cartographié avec preuves directes, le statut réel de `driverPhone` sur `orders` est confirmé (toujours inexistant, mais anticipé côté suppression de compte), et un risque de conception nouveau et significatif pour l'Option B (exposition au partenaire via les Rules `orders` partagées) a été identifié et documenté. Les 4 options sont comparées avec preuves à l'appui et une recommandation argumentée est fournie, sans qu'aucune ne soit mise en œuvre, conformément au périmètre strictement READ-ONLY de cette mission.

STOP après ce rapport. En attente d'une autorisation explicite avant toute migration ou modification.
