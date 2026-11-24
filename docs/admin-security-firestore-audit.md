# Audit de l’écran Sécurité admin — 2026-10-06

Écran : `lib/screens/admin/admin_security_dashboard.dart`, ouvert depuis la carte
« Sécurité / Audit & monitoring » de `admin_dashboard.dart`.

## Cause reproduite localement

`_loadAuditStats()` lançait notamment :

```dart
db.collection('rate_limits')
  .where('updatedAt', isGreaterThan: since1h)
  .count().get();
```

Sans `orderBy` ni `limit`. `rate_limits` est couvert explicitement par
`allow read, write: if false`. Même un super-admin reçoit un refus ; `Future.wait`
fait alors échouer l’ensemble des statistiques. Le test émulateur reproduit ce
refus avec une authentification non anonyme et un document admin actif de rôle super.
Ce diagnostic concerne le code et les règles locaux. Les règles déployées et le
document du compte testé sur appareil n’ont pas été consultés.

Ce stockage est un état interne de limitation, pas un journal de refus :
`checkRateLimit` dans `functions/index.js` enregistre les requêtes acceptées et
`updatedAt`. Compter ces documents ne mesurait donc pas les appels bloqués.

## Correction

L’écran compte maintenant les événements existants `order_rate_limit_exceeded`
dans `security_events`, sur `createdAt > maintenant - 1 heure`. Ils sont déjà
émis par `enforceOrderRateLimit` dans `functions/index.js`. Le libellé devient
« Commandes limitées (1h) » : il ne prétend pas couvrir tous les types de quotas.
Aucune Function n’est modifiée, aucune collection ni API n’est créée.

`rate_limits` reste inaccessible aux clients, y compris admins. L’autorisation
client `update` sur `security_events` est supprimée : `allow write: if false`
ne neutralisait pas cet autre `allow update`. Le serveur conserve son accès via
l’Admin SDK. Aucune permission globale admin n’est modifiée.

Les erreurs de statistiques et des trois flux sont affichées sans diagnostic
technique. Un refus n’est plus présenté comme une liste vide ou saine. Le bouton
Actualiser permet de relancer les statistiques.

## Inventaire des requêtes après correction

Toutes les agrégations ci-dessous utilisent `count().get()`, sans `orderBy` ni
`limit`. Les périodes sont calculées une fois pour l’instance d’écran.

| Collection | Filtres | Période |
|---|---|---|
| audit_logs | action == payment_initiated, createdAt > seuil | 24h |
| audit_logs | action == wallet_credited, createdAt > seuil | 24h |
| audit_logs | action == withdrawal_initiated, createdAt > seuil | 24h |
| audit_logs | action == order_auto_cancelled_no_driver, createdAt > seuil | 24h, 7j, 30j (3 requêtes) |
| security_events | resolved == false | aucune |
| security_events | severity == critical, resolved == false | aucune |
| security_events | eventType == webhook_invalid_secret, createdAt > seuil | 24h |
| security_events | eventType == webhook_replay_attempt, createdAt > seuil | 24h |
| security_events | eventType == order_rate_limit_exceeded, createdAt > seuil | 1h |

Les trois flux utilisent `snapshots()`, sans filtre `where` :

| Collection | Tri décroissant | Limite |
|---|---|---|
| security_events | createdAt | 10 |
| audit_logs | createdAt | 15 |
| dispatch_metrics | noDriverFoundCount | 5 |

## Autorisations et index

Toutes ces collections ont un bloc de règles explicite. `audit_logs` utilise
`isSuperAdmin()`, `security_events` et `dispatch_metrics` utilisent `isAdmin()`.
Dans ce dépôt les deux fonctions réservent l’accès au rôle `super` actif :
authentification non anonyme, document `admins/{request.auth.uid}` existant,
`isActive == true`, `role == 'super'`. Les sous-admins restent exclus, même si
l’architecture générale possède `hasAdminPermission(permission)`.

Les index `audit_logs(action, createdAt)`, `security_events(eventType, createdAt)`
et `security_events(severity, resolved)` sont déjà déclarés dans
`firestore.indexes.json`. Aucun index n’est modifié. Leur présence en production
n’est pas vérifiée ; l’émulateur ne valide pas le provisionnement des index.
Le refus déterministe de `rate_limits` suffit à expliquer le `permission-denied`.

## Validation locale

- 11 tests de règles : agrégations et listes autorisées au super-admin ; refus
  sous-admin, admin inactif, client, livreur, vendeur, partenaire, anonyme et non
  authentifié ; ancienne requête toujours refusée ; create/update/delete interdits.
- 5 tests Flutter : collection privée jamais consultée, compteur corrigé, erreurs
  Firebase/PlatformException et autre erreur sans diagnostic technique, reprise
  après actualisation et erreurs des flux distinctes de l’état vide.
- Analyse Flutter ciblée sur l’écran et son test.

Aucun déploiement, AAB, commit ou push. Le durcissement des écritures dans les
règles locales n’est donc pas encore appliqué en production.
