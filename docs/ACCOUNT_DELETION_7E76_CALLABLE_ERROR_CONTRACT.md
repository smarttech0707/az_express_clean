# Mission 7E-76 — Contrat d'erreur callable backend → Flutter

Date : 2026-11-07 · Émulateurs locaux uniquement (projet `demo-contract76`, ports 18501/18597/18599). Aucune commande distante, aucune configuration `operations_control/account_deletion` créée hors de l'émulateur éphémère.

## 1. Construction de l'erreur (backend)
`functions/accountDeletion.js`, fonction `request`, après les contrôles d'authentification, de rôle/jeton et de présence du limiteur, **avant** `checkRateLimit` et toute écriture :
```js
const gate=(await db.collection('operations_control').doc('account_deletion').get()).data();
if(gate?.enabled!==true || gate.inventoryVersion!==1)throw new HttpsError('failed-precondition','ACCOUNT_DELETION_NOT_ENABLED',{reason:'ACCOUNT_DELETION_NOT_ENABLED'});
```
Une erreur de lecture Firestore n'est pas attrapée dans ce code : elle remonte donc comme erreur du handler, jamais comme autorisation. Le code client qu'elle produit (a priori `INTERNAL`) est une **inférence** : ce cas n'a pas été observé sur le transport réel (voir §4).

## 2. Preuve du transport réel (émulateur Functions)
Méthode : la vraie fonction `requestAccountDeletionCF` (arbre « commit 1 » reconstruit depuis HEAD, hors dépôt) est chargée par l'**émulateur Functions** ; un client Node 22 s'authentifie auprès de l'**émulateur Auth** (jeton d'identification réel de l'émulateur) et appelle l'endpoint callable en HTTP avec le protocole callable (`{"data":{…}}` + `Authorization: Bearer`). L'état Firestore (émulateur) est relu avant/après.

| Cas | HTTP | Corps reçu | Écritures |
|---|---|---|---|
| A. configuration absente | 400 | `{"error":{"details":{"reason":"ACCOUNT_DELETION_NOT_ENABLED"},"message":"ACCOUNT_DELETION_NOT_ENABLED","status":"FAILED_PRECONDITION"}}` | aucune : `account_deletions`, `account_tombstones`, `audit_logs`, `rate_limits` = 0 avant et après |
| B. `enabled:false, inventoryVersion:1` | 400 | identique | aucune (état identique) |
| C. `enabled:true, inventoryVersion:2` | 400 | identique | aucune (état identique) |
| D. rôle invalide (`admin`), passerelle ouverte | 400 | `{"error":{"message":"Demande invalide","status":"INVALID_ARGUMENT"}}` — pas de `details.reason` | — |
| E. sans jeton d'authentification | 401 | `{"error":{"message":"Connexion requise","status":"UNAUTHENTICATED"}}` | — |
| F. passerelle ouverte (`enabled:true, inventoryVersion:1`), demande valide | 200 | `{"result":{"status":"quarantined","reason":"waiting_for_inflight_operations","requestId":"…","authDeleted":false,"profileAnonymized":false,"reviewRequired":false}}` | dossier 1, tombstone 1, audit 1, `rate_limits` 1 (comportement normal) |

Conclusions : (1) `HttpsError('failed-precondition', …)` est émis comme `FAILED_PRECONDITION` ; (2) `details.reason` **est conservé par le transport callable** (il est dans le corps d'erreur du protocole) ; (3) aucune écriture quand la passerelle est fermée ; (4) le message textuel est inchangé.

## 3. Du corps d'erreur à Flutter (version réellement utilisée : `cloud_functions 6.3.2`, `cloud_functions_platform_interface 6.0.2`, `cloud_functions_web 5.1.8`, lues dans le cache pub)
- Android (`FlutterFirebaseFunctionsPlugin.kt` l. 113-143) : `additionalData = functionsException.details` placé dans `details["additionalData"]`.
- iOS (`FirebaseFunctionsPlugin.swift` l. 164) : `nsError.userInfo["details"]` placé dans `additionalDetails["additionalData"]`.
- Dart (`method_channel/utils/exception.dart` l. 37-50) : `FirebaseFunctionsException(details: details['additionalData'])`.
- Web (`cloud_functions_web/lib/utils.dart` l. 25) : `details: exception.getProperty('details').dartify()` (Map<Object?, Object?>).
Donc `e.details` est une `Map` portant `reason`, sur les trois plateformes. Le code Flutter teste `details is Map && details['reason'] == …`, compatible avec les deux types de Map.

## 4. Ce qui est prouvé et ce qui ne l'est pas
- **Prouvé** : sérialisation serveur réelle (émulateur) ; conversion plugin Dart réelle (convertisseur `platformExceptionToFirebaseFunctionsException` appelé dans un test Flutter avec une `PlatformException` au format natif) ; décision `isGateClosedRefusal`.
- **Non prouvé** : exécution du SDK natif Android/iOS/web sur appareil ou navigateur ; la forme exacte `PlatformException.details` est déduite de la lecture du code natif du plugin, pas observée.
- Le test F a nécessité, **dans la copie de test uniquement**, une cale (proxy sur `admin.firestore` fournissant `FieldValue`/`Timestamp`) car sous l'émulateur Functions de cet environnement `admin.firestore.FieldValue` est `undefined` (erreur observée sans la cale sur `checkRateLimit`, code de HEAD). Les cas A–E, qui lèvent le refus avant tout usage de `FieldValue`, ont été obtenus **sans** cale. Aucun fichier du dépôt n'a reçu cette cale. Cause de l'écart émulateur non investiguée. **L'absence d'impact sur le code déployé n'est pas démontrée** : aucune vérification n'a été faite en production ni sur un déploiement, et le chargement des 135 exports ne dit rien sur `FieldValue`. L'écart reste une réserve ouverte.
- Le cas « Firestore illisible » n'a pas été reproduit sur l'émulateur (non simulable sans modifier l'émulateur) ; il est couvert par un test unitaire à faux Firestore (la lecture lève, aucune écriture).
- L'émulateur a signalé la détection d'identifiants applicatifs par défaut ; le projet `demo-*` interdit l'accès aux services non émulés ; seuls Auth et Firestore émulés ont été sollicités.
