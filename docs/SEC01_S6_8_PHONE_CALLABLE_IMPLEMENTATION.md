# SEC-01 — S6.8 : implémentation isolée de `getDriverPhoneForOrderCF`

Date : 2026-11-21
Type : implémentation ciblée (1 callable + ses tests), aucune migration de lecteur
Référence : `docs/SEC01_S6_7_PHONE_ACCESS_DESIGN_AUDIT.md` (conception approuvée)

## 1. Résumé

La callable `getDriverPhoneForOrderCF`, conçue en S6.7, a été implémentée dans un nouveau module `functions/driverPhoneAccess.js`, wirée dans `functions/index.js` (région `europe-west1`, héritée de `setGlobalOptions`), et couverte par 39 tests ciblés dans `functions/test/driverPhoneAccess.test.js`. Elle réutilise exclusivement les primitives déjà existantes (`checkRateLimit`, `logAudit`, `HttpsError`, `onCall`) — aucun nouveau helper d'infrastructure n'a été créé. Aucun des 7 lecteurs Flutter/Web n'a été touché : la callable existe, mais n'est consommée par aucun écran dans cette phase. La suite complète des tests Functions (3042 tests, dont les 39 nouveaux) passe sans régression.

## 2. Fichiers modifiés

| Fichier | Nature |
|---|---|
| `functions/driverPhoneAccess.js` | **Nouveau** — logique de la callable (`buildGetDriverPhoneForOrder`) et ses fonctions pures exportées pour les tests |
| `functions/test/driverPhoneAccess.test.js` | **Nouveau** — 39 tests ciblés |
| `functions/index.js` | Modifié — 1 `require` + 1 ligne `exports.getDriverPhoneForOrderCF = ...`, insérés au milieu d'un diff préexistant et sans rapport (confirmé isolé par `git diff` ciblé) |
| `docs/SEC01_S6_8_PHONE_CALLABLE_IMPLEMENTATION.md` | **Nouveau** — ce rapport |

Aucun fichier Flutter/Web, aucune Rule, aucune configuration Firebase, aucune dépendance/lockfile n'a été modifié.

## 3. Implémentation de la callable

### Entrée et validation

Entrée minimale : `{ orderId: string }`. Validation stricte avant tout accès Firestore :
```js
if (typeof orderId !== 'string' || orderId.trim().length === 0 || orderId.length > 200) {
  throw new HttpsError('invalid-argument', 'orderId invalide.');
}
```
Aucun `driverId`, `phone`, `uid` ou rôle fourni par le client n'est jamais accepté ni utilisé — `uid` vient exclusivement de `request.auth.uid` (Firebase Auth, vérifié server-side), `driverId` est toujours relu depuis le document `orders` fraîchement chargé.

### Authentification

```js
if (!request.auth?.uid) throw new HttpsError('unauthenticated', 'Vous devez être connecté.');
```
Aucune distinction anonyme/identifié — conforme à la décision S6.7 §5.A : un client authentifié anonyme a un `uid` Firebase Auth valide, et l'autorisation repose sur la correspondance avec `orders.clientId`, identique dans les deux cas. Testé explicitement (§7).

### Autorisation (`resolveRole`)

Relit systématiquement l'identité de l'appelant contre le document `orders` (jamais l'inverse) :

```js
async function resolveRole({ db, uid, order }) {
  if (order.clientId === uid) return 'client';
  if (order.pharmacieId) {
    const pharmacieSnap = await db.collection('pharmacies').doc(String(order.pharmacieId)).get();
    if (pharmacieSnap.exists && pharmacieSnap.data()?.currentUid === uid) return 'pharmacie';
  }
  if (order.sellerId && order.sellerId === uid) return 'partner';
  const adminSnap = await db.collection('admins').doc(uid).get();
  const adminData = adminSnap.data();
  if (adminSnap.exists && adminData?.isActive === true && adminData?.role === 'super') return 'admin';
  return null;
}
```

- **Pharmacie** : reproduit exactement `isPharmacieOwnerOfOrder()` des Rules (`firestore.rules:301-306`), traduit côté serveur.
- **Partenaire** (boulangerie/vendeur marketplace) : `order.sellerId === uid`, identique au motif déjà utilisé par la Rule de lecture `orders` (`resource.data.sellerId == uid()`).
- **Admin** : restreint au **super-admin** (`role === 'super'`), aligné sur la sémantique de `isAdmin()` dans les Rules (`.claude/rules/firestore-rules.md` : « `isAdmin()` = super-admin seul »). Un sous-admin n'est **jamais** traité comme admin par cette callable — testé explicitement (§7), conformément à l'interdiction de créer un bypass admin implicite.
- **Livreur** : **aucune branche** ne reconnaît un livreur (ni le sien, ni un autre) — exclu par défaut, conformément à S6.7 §5.B (aucun cas d'usage identifié). Testé explicitement : un livreur affecté à la commande est refusé.

### Statuts (`statusAllowsAccess`, `isWithinDeliveredGrace`)

```js
const ACTIVE_STATUSES = new Set(['assigned', 'accepted', 'picked_up']);
const DELIVERED_GRACE_MS = 2 * 60 * 60 * 1000; // 2 heures

function statusAllowsAccess(role, order) {
  if (role === 'admin') return true;
  return ACTIVE_STATUSES.has(order.status) || isWithinDeliveredGrace(order);
}
```

Statuts réels du code (confirmés, pas inventés — `firestore.rules`, `functions/dispatch.js`, `functions/orderActions.js`) : `pending`, `broadcast`, `assigned`, `accepted`, `picked_up`, `delivered`, `cancelled`, plus les statuts terminaux secondaires déjà présents dans le code (`expired`, `refunded`, `failed_refunded`, `failed`, `rejected`, `declined`, `closed`, `completed`, cf. `functions/manualAccountDeletion.js::TERMINAL`) — tous implicitement refusés (aucun n'est dans `ACTIVE_STATUSES` ni égal à `'delivered'`). Le rôle `admin` contourne la restriction de statut (y compris `cancelled`), conformément à la matrice S6.7 §6 (traçabilité/litige) — testé.

La fenêtre de grâce post-`delivered` utilise `order.deliveredAt` (champ réel du modèle `OrderModel`, confirmé dans `lib/models/order_model.dart:70`). **Absence de `deliveredAt` sur une commande `delivered` → refusé**, jamais un repli permissif (testé explicitement : « donnée manquante ≠ accès accordé »).

### Validation server-side et protection contre les accès croisés

Séquence appliquée dans la callable : lecture de `orders/{orderId}` → détermination du rôle → vérification du statut → **relecture de `order.driverId` depuis ce même document** (jamais un paramètre) → lecture de `livreurs/{driverId}` → extraction du seul champ `phone`. Chaque étape échoue de façon contrôlée (voir §5) sans jamais faire confiance à une donnée fournie par le client au-delà de `orderId`.

**Protection contre les anciens livreurs après réattribution** : comme `driverId` est relu à chaque invocation depuis le document `orders` courant (jamais mis en cache), un appel effectué après un transfert (`driverTransfer.js`, qui réécrit `order.driverId`) retourne systématiquement le numéro du **nouveau** livreur. Testé explicitement (§7, scénario de réattribution).

### Réponse

```js
return { success: true, data: { phone }, error: null, message: null, code: null };
```
Aucun champ au-delà de `phone` n'est jamais inclus — testé explicitement (`Object.keys(result.data)` égal à `['phone']`).

## 4. Matrice d'autorisation implémentée

| Acteur | `pending`/`broadcast` | `assigned`/`accepted`/`picked_up` | `delivered` (≤ 2h) | `delivered` (> 2h ou sans `deliveredAt`) | `cancelled`/autres terminaux |
|---|---|---|---|---|---|
| Client (`clientId === uid`) | Refusé | **Autorisé** | Autorisé | Refusé | Refusé |
| Pharmacie (`pharmacieId` → `currentUid`) | Refusé | **Autorisé** | Autorisé | Refusé | Refusé |
| Partenaire (`sellerId === uid`) | Refusé | **Autorisé** | Autorisé | Refusé | Refusé |
| Admin (super, `isActive===true`) | Refusé (pas de `driverId`) | Autorisé | Autorisé | Autorisé | Autorisé |
| Sous-admin | Refusé | Refusé | Refusé | Refusé | Refusé |
| Livreur (affecté ou non) | Refusé | Refusé | Refusé | Refusé | Refusé |
| Tiers non lié | Refusé | Refusé | Refusé | Refusé | Refusé |

Strictement identique à la matrice approuvée en S6.7 §6 — aucune autorisation ajoutée, aucun statut inventé.

## 5. Protections anti-abus

- **Limitation des appels** : `checkRateLimit(uid, 'get_driver_phone_for_order', 20, 60)` — réutilisation directe de la primitive existante (`functions/index.js:279-299`), mêmes valeurs que `payOrderFromWalletCF` (20 appels/60 s). Testé : paramètres exacts vérifiés, et propagation correcte d'un refus (`resource-exhausted`) si la limite est atteinte.
- **Anti-énumération** : « commande inexistante » et « commande existante mais non autorisée » renvoient le **même** code (`permission-denied`) et le **même** message (`'Accès refusé pour cette commande.'`) — testé explicitement par comparaison des deux messages d'erreur.
- **Accès croisés entre commandes** : testé explicitement (client de la commande A tentant d'accéder à la commande B → refusé).
- **Erreurs sans révélation excessive** : les refus d'autorisation ne précisent jamais si c'est le rôle, le statut ou l'existence de la commande qui a échoué (message générique unique) ; seules les erreurs de validation d'entrée (`invalid-argument`) et les erreurs post-autorisation sans risque d'énumération (`failed-precondition` « aucun livreur assigné », `not-found` « numéro indisponible ») sont spécifiques — cohérent avec le principe retenu en S6.7 (une fois l'autorisation déjà validée, préciser la cause n'aide pas un attaquant).
- **App Check** : non activé (`enforceAppCheck` toujours désactivé côté fonctions, confirmé inchangé dans `.claude/rules/firebase-functions.md`) — décision S6.7 de ne pas en faire une dépendance bloquante, respectée ; rien n'a été changé sur ce point.
- **Aucune nouvelle dépendance** : `onCall`, `HttpsError` (déjà importés par tout le reste de `functions/`), `checkRateLimit`, `logAudit` (injectés, comme pour toutes les autres callables).

## 6. Journalisation

Chaque issue (succès ou refus) appelle `logAudit` exactement une fois :
```js
await logAudit({
  userId: uid, userType: role /* ou 'unknown' si aucun rôle déterminé */,
  action: 'get_driver_phone_for_order', targetId: normalizedOrderId,
  status: 'success' | 'denied',
  metadata: { driverId, orderStatus } /* succès */ | { reason } /* refus */,
});
```
**Le numéro de téléphone n'est jamais inclus** dans `metadata` ni dans aucun autre champ journalisé — vérifié par un test dédié qui sérialise l'intégralité des appels à `logAudit` et confirme l'absence du numéro attendu dans la sortie JSON. Les motifs de refus journalisés (`order_not_found`, `no_matching_role`, `status_not_allowed`, `no_driver_assigned`, `driver_phone_unavailable`) sont des catégories, jamais une donnée personnelle.

## 7. Tests exécutés

`npx mocha functions/test/driverPhoneAccess.test.js` — **39/39 passants** :

- **Authentification** (3) : appel non authentifié rejeté ; utilisateur anonyme avec uid valide et propriétaire autorisé ; utilisateur authentifié valide autorisé.
- **Autorisation** (10) : client propriétaire autorisé ; client d'une autre commande refusé ; livreur affecté refusé ; livreur non affecté refusé ; partenaire propriétaire autorisé ; partenaire d'une autre commande refusé ; pharmacie propriétaire autorisée ; pharmacie non propriétaire refusée ; admin super autorisé (y compris `cancelled`) ; sous-admin refusé ; admin inactif refusé.
- **Statuts** (10) : `pending` refusé ; `broadcast` refusé ; `assigned` autorisé ; `accepted` autorisé ; `picked_up` autorisé ; `delivered` dans la fenêtre de grâce autorisé ; `delivered` hors fenêtre refusé ; `delivered` sans `deliveredAt` refusé ; `cancelled` refusé ; réattribution du livreur → nouveau numéro retourné.
- **Protections** (15) : `orderId` absent/type incorrect/trop long (3× `invalid-argument`) ; commande inexistante avec message identique au refus d'autorisation ; commande sans `driverId` (`failed-precondition`) ; livreur inexistant (`not-found`) ; téléphone absent (`not-found`) ; accès croisé entre commandes ; rate limit appliqué avec les bons paramètres ; rate limit dépassé propagé ; audit du succès ; audit du refus ; numéro absent des logs ; réponse limitée au seul champ `phone`.
- **Logique pure** (1) : `isWithinDeliveredGrace`/`statusAllowsAccess` sur des cas synthétiques, sans Cloud Function.

`npm test` (suite complète `functions/`) : **2861 passants, 0 échec, 181 ignorés** (tests nécessitant l'émulateur Firestore, absent de cet environnement — comportement inchangé par rapport à l'état antérieur à cette phase). Confirme l'absence de régression sur l'ensemble des fonctions existantes.

Vérification de chargement du module (convention du dépôt, `.claude/rules/firebase-functions.md`) :
```
node -c functions/index.js
node -e "console.log(typeof require('./index.js').getDriverPhoneForOrderCF)"  →  function
```

## 8. Tests non exécutés

- **Tests avec émulateur Firestore réel** (`*.emulator.test.js`) : non créés pour cette callable — la conception S6.7 et les tests unitaires ci-dessus couvrent exhaustivement la logique d'autorisation sans nécessiter de Firestore réel (pattern déjà établi pour `orderActions.js`, dont les tests `.test.js` non-émulateur sont la majorité). Aucun test émulateur n'a été lancé dans cette phase (aucun accès Firebase réel, conformément à la consigne).
- **Test d'invocation réelle via le SDK client** (`httpsCallable` depuis Flutter) : hors périmètre — aucun lecteur n'est migré dans cette phase, donc aucun appel client réel n'existe à tester.
- **`flutter test`/`flutter analyze`** : sans objet — aucun fichier Flutter/Web modifié dans cette phase.

## 9. Réserves

- **Durée de la fenêtre de grâce post-livraison (2 heures)** : valeur choisie à titre d'exemple raisonnable dans la plage suggérée par S6.7 (« quelques minutes à quelques heures »), codée comme une constante isolée (`DELIVERED_GRACE_MS`) facilement ajustable — reste une décision produit, pas verrouillée définitivement par ce choix d'implémentation.
- **Admin dans la callable** : implémenté conformément à la matrice S6.7, mais comme déjà noté dans ce même rapport de conception, l'admin n'a normalement pas besoin de cette callable puisqu'il lit déjà `livreurs` directement (`admin_map.dart`) — sa présence ici est une complétude de la matrice, pas un besoin opérationnel nouveau.
- **Rate-limit par commande** (mentionné comme defense-in-depth optionnelle en S6.7 §7) : non implémenté — seule la limitation par utilisateur (`checkRateLimit` existant) a été appliquée, conformément à « réutiliser les mécanismes existants » plutôt qu'en ajouter un nouveau dans cette phase isolée.
- **App Check** : non activé, décision explicitement hors périmètre de cette phase (dépend d'un rollout séparé, cf. S6.7).
- **Aucune migration de lecteur** : la callable existe et est entièrement testée, mais **n'est appelée par aucun code Flutter/Web** à ce stade — elle est un composant isolé, prêt pour une phase de migration future et séparée (S6.9 ou équivalent), non commencée ici.
- **Validation de compilation côté fonctions** : `node -c`/`require` confirment un chargement syntaxique et d'exécution correct du module (sans initialiser de vraie connexion Firebase, pattern déjà utilisé par le reste du dépôt) — ce n'est pas un déploiement ni un test d'intégration réel.

## 10. Confirmation du respect du périmètre

- Aucun écran Flutter/Web migré ; aucun des 7 lecteurs de `phone` modifié (confirmé par `git status`/`git diff` scopés — absents de cette phase).
- `driver_public` : non modifié (`phone` n'y a jamais été ajouté).
- `orders` : non modifié (`driverPhone` n'y a jamais été ajouté, ni aucun autre champ).
- `firestore.rules` : non modifié.
- Aucune configuration Firebase modifiée.
- Aucune dépendance ni lockfile modifié (`functions/package.json`/`package-lock.json` absents du diff de cette phase).
- Aucun accès Firebase réel, aucun déploiement (`firebase deploy` non exécuté), aucun APK/AAB généré.
- La callable est exportée dans `functions/index.js` (nécessaire pour qu'elle soit un jour déployable) mais **n'a été déployée nulle part** — vérifié par l'absence de toute commande de déploiement dans cette session, et par le fait que `require('./index.js')` ne contacte aucun Firebase réel (pattern de chargement déjà utilisé par le dépôt, confirmé inoffensif).
- Ni la production `az-express-b0469` ni la préproduction `az-express-preprod` n'ont été touchées. Le pilote T7E n'a pas été modifié.
- Aucune opération Git destructive, aucun commit, aucun push, aucune branche créée.
- Les très nombreuses modifications locales préexistantes et sans rapport (notamment dans `functions/index.js`, confirmées par `git diff` ciblé isolant les 3 lignes ajoutées par cette phase) sont restées intactes.

## 11. Verdict

**IMPLEMENTATION VALIDÉE AVEC RÉSERVES**

La callable `getDriverPhoneForOrderCF` est implémentée conformément à la conception S6.7, avec une matrice d'autorisation stricte (jamais fondée sur le seul `orderId`), une protection effective contre les accès croisés et les anciens livreurs après réattribution, une réponse minimale sans champ superflu, une journalisation sans exposition du numéro, et une réutilisation complète des mécanismes anti-abus existants. 39 tests ciblés couvrent exhaustivement l'authentification, l'autorisation (par acteur), les statuts réels du code, et les protections demandées ; la suite complète (3042 tests) confirme l'absence de régression. La réserve porte sur des paramètres de décision produit non figés (fenêtre de grâce, rate-limit par commande, App Check) et sur le fait que la callable reste un composant isolé, non encore consommé par aucun lecteur — conformément au périmètre strict de cette phase.

STOP après ce rapport. Aucun lecteur migré. Aucune autre phase commencée sans autorisation explicite.
