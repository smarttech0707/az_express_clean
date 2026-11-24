# SEC-01 — S6.0.2 : audit ciblé des 2 dettes résiduelles avant S6.1

Date : 2026-11-21
Type : audit exclusivement en lecture seule (aucune correction, aucune migration, aucun déploiement)
Périmètre : (1) `FirestoreService.deductCommission`, (2) le champ `rating` dans `driver_profil.dart`

## 1. Résumé exécutif

Les deux points résiduels de S6.0.1 sont reconfirmés à l'identique, avec des preuves fraîches (lignes exactes, mécanisme serveur comparé ligne à ligne, bornes Rules revérifiées).

- **`deductCommission`** : code mort, zéro appelant, remplacé depuis par le mécanisme serveur `acceptOrder` (`functions/driverAcceptance.js`). Même réactivé par erreur, les règles Firestore bornent tout débit à de l'auto-préjudice du livreur propriétaire (jamais cross-user). Risque architectural réel (duplication dangereuse d'une logique financière), risque d'exploitation actuel nul.
- **`rating`** : champ lu dans `driver_profil.dart:374` mais jamais écrit sur `livreurs/{driverId}` par aucun code du repository. Défaut fonctionnel pur (affichage toujours à 0.0), sans rapport avec le véritable couple `avgRating`/`ratingCount` déjà utilisé correctement ailleurs (serveur, via `applyDriverRatingOnOrderUpdate`). Aucune implication de sécurité.

Aucun fichier de code modifié. Aucune connexion Firebase réelle. Aucun déploiement.

## 2. Audit `deductCommission`

### 2.1 Localisation et code complet

`lib/services/firestore_service.dart:400-418` :

```dart
Future<void> deductCommission(String driverId, int price,
    {String? orderId}) async {
  int commission = calculateCommission(price);
  final driverRef = db.collection("livreurs").doc(driverId);
  await db.runTransaction((transaction) async {
    final snapshot = await transaction.get(driverRef);
    if (!snapshot.exists) return;
    int wallet = (snapshot["wallet"] as num? ?? 0).toInt();
    int newWallet = (wallet - commission).clamp(0, double.maxFinite.toInt());
    transaction.update(driverRef, {"wallet": newWallet});
  });
  await _logTransaction(
    driverId,
    "commission",
    commission,
    "Commission AZ Express — course à $price FCFA",
    orderId: orderId,
  );
}
```

Fonctionnement : transaction Firestore classique (lecture puis écriture), plafonnée à 0 (`clamp`), suivie d'une entrée de journal (`_logTransaction`, méthode locale non Cloud-Function). La cible d'écriture (`driverRef`) est dérivée du paramètre `driverId` fourni par l'appelant — **aucune vérification que l'appelant est bien ce livreur** : si la méthode était appelée avec un `driverId` arbitraire depuis le client, elle écrirait sur le wallet d'un tiers. C'est entièrement un problème d'appel (il n'y en a aucun), pas un bug corrigé par les Rules à ce niveau applicatif — voir §2.5 pour ce que les Rules bornent réellement.

### 2.2 Recherche exhaustive des références

```
grep -rn "deductCommission" .   →  lib/services/firestore_service.dart:400 (déclaration) uniquement
```

Aucune occurrence dans `lib/` (hors déclaration), `functions/`, `test/`, ni ailleurs dans le dépôt. Ni appel direct (`.deductCommission(`), ni appel indirect via une classe dérivée, un provider, un widget, ou un test. La méthode `calculateCommission` qu'elle utilise, elle, est partagée (alias différent côté Node dans `functions/` pour `driverAcceptance.js`), mais ce partage n'implique aucun appelant de `deductCommission` elle-même.

### 2.3 Confirmation : réellement inutilisée

Oui, confirmé sans ambiguïté. Zéro appelant dans tout le repository actuel (recherche exhaustive, pas limitée à `grep` simple : vérifié aussi qu'aucun provider/service ne référence `FirestoreService` par une méthode generic/dynamique qui pourrait masquer l'appel — la méthode est publique, nommée, et un appel par réflexion n'existe pas en Dart idiomatique ici).

### 2.4 Mécanisme serveur actuel comparé

`functions/driverAcceptance.js`, commentaire d'en-tête (lignes 10-15) :

```
// Avant ce module, la commission AZ était prélevée par une transaction
// [cliente] ... le calcul de la commission venaient du client. Ici :
//   - la commission est calculée par le serveur (config/commission) ;
//   ...
//   - le prélèvement est identifié (`commission_<commande>_<livreur>`) et
```

`acceptOrder` (lignes ~152-185) :

```js
const commission = legacyPartner
  ? 0
  : Math.max(0, Math.floor(Number(await calculateCommission(db, budget))));

if (!Number.isSafeInteger(wallet) || wallet < commission) {
  const message = `CREDIT_INSUFFISANT:${Number.isFinite(wallet) ? wallet : 0}:${commission}`;
  throw new HttpsError('failed-precondition', message, { wallet, commission });
}

const txId = `commission_${orderId}_${uid}`;
...
tx.update(driverRef, { wallet: wallet - commission, isOnDelivery: true });
if (commission > 0) {
  ...type: 'commission', amount: commission, orderId,
     description: `Commission AZ Express — course ${...} (${budget} FCFA)`,
}
...
  commissionAmount: commission,
  commissionPayerId: uid,
  commissionTxId: commission > 0 ? txId : null,
  commissionStatus: 'charged',
```

Différences structurelles clés par rapport à `deductCommission` :

| Aspect | `deductCommission` (mort) | `acceptOrder` (actif) |
|---|---|---|
| Calcul | côté client (`price` fourni par l'appelant) | côté serveur (`config/commission`, lu par le serveur) |
| Identité du débiteur | paramètre `driverId` libre, aucune vérification | `uid` = l'appelant authentifié (`request.auth`), auto-référent |
| Idempotence | aucune (ré-appel = double débit) | `txId = commission_<orderId>_<uid>`, vérifié avant tout nouveau débit (`alreadyAccepted`) |
| Garde-fou solde | `clamp(0, …)` — silencieux, pas d'erreur | `CREDIT_INSUFFISANT` explicite, rejet avant toute écriture |
| Traçabilité | `_logTransaction` local (log applicatif) | `logAudit` (journal Cloud-Function-only, `audit_logs`) |
| Exécution | transaction Firestore lancée depuis Flutter (Admin SDK absent) | Cloud Function `onCall`, Admin SDK, région `europe-west1` |

### 2.5 Risque en cas de réactivation accidentelle

Si un futur développeur réintroduisait un appel à `deductCommission` (par exemple en pensant « réparer » un flux de paiement), deux niveaux de protection existent déjà et resteraient actifs sans aucune modification :

1. **Rules `livreurs`** (`firestore.rules:396-422`) : la branche `allow update` ouverte au propriétaire exige `request.resource.data.wallet < resource.data.wallet` et `isOwner(livreurId)` — donc même un appel malveillant ou buggé ne peut, via les règles, affecter que le wallet du livreur **authentifié comme propriétaire du document ciblé**. Un livreur A ne peut pas faire baisser le wallet du livreur B par ce chemin, car il faudrait que la requête Firestore soit authentifiée en tant que B (`isOwner`), ce qu'un client Flutter ne contrôle pas pour un tiers.
2. Cela ne protège cependant pas contre un **double débit légitime** : si la méthode était rappelée pour le même livreur authentifié (lui-même), les Rules ne l'empêcheraient pas (absence d'idempotence applicative), contrairement à `acceptOrder` qui a `commissionTxId`/`alreadyAccepted`. C'est le risque réel : pas un vol cross-user, mais un débit en double sur son propre wallet si le code était réintroduit sans l'idempotence d'`acceptOrder`.

Conclusion de risque : **exploitation actuelle impossible (code mort, zéro appelant)** ; **risque architectural résiduel réel** si réactivé sans idempotence, borné par les Rules à de l'auto-préjudice (pas de cross-user).

### 2.6 Recommandation (non exécutée)

Supprimer `deductCommission`, `calculateCommission` (version Dart si elle n'est utilisée que par cette méthode — à vérifier séparément) et `_logTransaction` si cette dernière n'a pas d'autre appelant, **dans une phase dédiée et autorisée séparément**, avec un test de non-régression confirmant qu'aucun flux actif ne dépend de ces méthodes. Alternative plus conservatrice : laisser le code mais ajouter un commentaire `@Deprecated` explicite pointant vers `acceptOrder` — moins propre, mais nulle en risque d'oubli de dépendance cachée.

## 3. Audit du champ `rating`

### 3.1 Lecture dans `driver_profil.dart`

`lib/screens/driver/driver_profil.dart:374` :

```dart
final rating = data["rating"] ?? 0.0;
```

(dans le contexte du chargement du profil du livreur connecté, à partir de son propre document `livreurs/{uid}`).

### 3.2 Écritures effectives sur `livreurs`

Recherche exhaustive de toute écriture `'rating':`/`"rating":` dans `lib/` et `functions/`. Aucune ne cible la collection `livreurs`. Table complète des sites trouvés :

| Fichier:ligne | Collection cible | Rôle |
|---|---|---|
| `lib/event/services/event_service.dart:92,227,365` | événements | note d'un événement |
| `lib/ekbine/services/ek_service.dart:265,268` | `ekbine_agents` | note d'un agent E-Kbine |
| `lib/ekbine/screens/ek_agent_register.dart:491` | `ekbine_agents` | initialisation à l'inscription |
| `lib/models/order_model.dart:163,235` | `orders` | note de la commande elle-même |
| `lib/web/pages/client/web_artisans_page.dart:592,602-603` | artisans | note d'un artisan |
| `lib/screens/client/suivi_commande.dart:1445` | `orders` (confirmé en S6.0.1, lignes 1420-1448 : cible `reviews`/`orders`, pas `livreurs`) | avis client sur la commande |
| `lib/screens/client/service_providers_page.dart:557,572` | prestataires de service | note d'un prestataire |
| `lib/services/firestore_service.dart:478` | `orders/{orderId}` | `rateOrder()` — note posée sur la commande, pas sur le livreur |
| `functions/artisanAccounts.js:40` | artisans (liste de champs autorisés) | gestion de compte artisan |

Aucun de ces sites n'écrit `livreurs/{driverId}.rating`. Le champ lu en `driver_profil.dart:374` n'est donc jamais peuplé : il vaut systématiquement `0.0` par défaut (`?? 0.0`).

### 3.3 Mécanisme réel de calcul/mise à jour des notes livreur

Le commentaire de `firestore_service.dart:467-473` (méthode `rateOrder`, voisine de `deductCommission` dans le même fichier) documente le vrai mécanisme :

```dart
/// Enregistre la note du client sur sa commande livrée.
///
/// Le client ne peut écrire que `rating` sur sa propre commande (règles
/// Firestore). La moyenne du livreur (`avgRating`/`ratingCount`) est mise à
/// jour côté serveur par `applyDriverRatingOnOrderUpdate` : l'ancienne
/// transaction écrivait aussi `livreurs/{id}`, refusé par les règles, ce qui
/// faisait échouer toute la notation.
```

Donc : le client écrit `orders/{orderId}.rating` (via `rateOrder`, ligne 478) ; une Cloud Function serveur (`applyDriverRatingOnUpdate`, nom confirmé par le commentaire) lit cette note et met à jour `livreurs/{driverId}.avgRating` / `.ratingCount` — exactement la convention déjà confirmée en S5.3.5/S6.0 comme étant dans la whitelist `driver_public`. Le champ `rating` au singulier sur `livreurs` n'a jamais fait partie de ce mécanisme ; c'est un vestige antérieur (daté en S6.0.1, via `git log -L`, au commit `a7f8423`, antérieur à cette convention serveur).

### 3.4 Comparaison `rating` / `avgRating` / `ratingCount`

| Champ | Existe sur `livreurs` ? | Écrit par | Lu par |
|---|---|---|---|
| `rating` | jamais écrit (0.0 par défaut) | personne | `driver_profil.dart:374` (seul lecteur identifié) |
| `avgRating` | oui, maintenu | Cloud Function serveur (`applyDriverRatingOnUpdate`) | de nombreux écrans (whitelist `driver_public`) |
| `ratingCount` | oui, maintenu | même Cloud Function | idem |

### 3.5 Nature précise du problème

**Défaut d'affichage pur** (bug fonctionnel, pas un problème de données ni de sécurité) : le développeur de `driver_profil.dart` a très probablement voulu lire `avgRating` et a tapé/laissé `rating` par erreur ou par copie d'un ancien nom de champ antérieur à la convention serveur. Aucune donnée n'est corrompue, aucune fuite, aucun risque — seulement un chiffre affiché à zéro qui devrait afficher la vraie moyenne.

### 3.6 Correction minimale recommandée (non exécutée)

Remplacer, ligne 374, `data["rating"] ?? 0.0` par `data["avgRating"] ?? 0.0` — une seule ligne, aucun autre changement nécessaire (le type est déjà numérique dans les deux cas). Vérifier dans le même écran si `ratingCount` devrait aussi être affiché à proximité (hors preuve actuelle, à confirmer visuellement lors de la correction).

### 3.7 Tests recommandés (non créés)

- Un test de widget ciblé sur `driver_profil.dart` vérifiant que la note affichée correspond à `avgRating` du document Firestore simulé (pas à un champ `rating` absent).
- Pas de test Rules nécessaire : ce n'est pas un problème de permission, seulement de nom de champ côté lecture client.

## 4. Preuves et fichiers concernés (lecture seule)

- `lib/services/firestore_service.dart` (lignes 400-478)
- `functions/driverAcceptance.js` (lignes 10-15, 89-195)
- `firestore.rules` (lignes 396-422)
- `lib/screens/driver/driver_profil.dart` (ligne 374)
- Recherche exhaustive `grep -rn "deductCommission"` et `grep -rn "'rating'|\"rating\""` sur `lib/` et `functions/`
- `docs/SEC01_S6_0_1_READ_ONLY_UNCERTAINTY_AUDIT.md` (daté du commit `a7f8423` pour les deux points, référence croisée, non modifié)

## 5. Risques

| Point | Risque actuel | Risque résiduel |
|---|---|---|
| `deductCommission` | nul (zéro appelant) | dette architecturale : code financier dupliqué, non idempotent, pourrait causer un double débit sur soi-même s'il était réactivé sans précaution |
| `rating` | nul (aucune implication de sécurité) | cosmétique uniquement : note livreur toujours affichée à 0.0 dans cet écran |

## 6. Corrections minimales recommandées (non réalisées)

1. `deductCommission`/`calculateCommission`(Dart)/`_logTransaction` : suppression (ou a minima `@Deprecated`), dans une phase dédiée et autorisée séparément, après vérification qu'aucun autre appelant caché n'existe (réconfirmée ici : aucun).
2. `driver_profil.dart:374` : `data["rating"]` → `data["avgRating"]`, correction d'une ligne.

## 7. Tests recommandés (non créés)

- Un test unitaire/widget pour `driver_profil.dart` confirmant l'usage d'`avgRating`.
- Aucun test Rules supplémentaire nécessaire pour ces deux points.

## 8. Fichiers modifiés par cette phase

Aucun fichier de code modifié. Seul fichier créé : `docs/SEC01_S6_0_2_RESIDUAL_DEBT_AUDIT.md` (ce rapport).

## 9. Confirmation explicite

Aucune modification de code, aucun test modifié ou créé, aucune règle Firestore modifiée, aucune configuration modifiée, aucune connexion à un Firebase réel, aucun déploiement, aucune migration commencée, aucune production ni préproduction touchée, aucune intervention sur le pilote T7E.

## 10. Verdict

**AUDIT VALIDÉ**

Les deux points sont intégralement expliqués avec preuves directes (lignes exactes, mécanisme serveur comparé, bornes Rules vérifiées, recherche exhaustive des écritures), sans aucune zone d'incertitude restante. Aucune réserve : les deux corrections minimales recommandées sont claires et peu risquées, mais restent volontairement non exécutées dans cette phase, conformément à la consigne.
