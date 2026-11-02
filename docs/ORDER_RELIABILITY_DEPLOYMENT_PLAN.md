# Plan de déploiement ciblé — fiabilité des commandes et litiges (2026-10-30)

**Statut : PRÉPARÉ, NON EXÉCUTÉ.** Aucun déploiement n'est autorisé à ce jour. Chaque étape ci-dessous exige une
demande explicite du propriétaire. Projet `az-express-b0469`, région `europe-west1`.

## Mise à jour du 2026-10-30 (isolation et mesures en production, lecture seule)

- **Arbre isolé** : `C:\Users\User\AppData\Local\Temp\az_isolated_reliability` (worktree détaché de `7a76f18` + uniquement ce chantier).
  C'est de cet arbre, et non du répertoire de travail mélangé, qu'il faudra déployer. Inventaire exact : voir le rapport.
- **Aucune variable d'environnement ni secret nouveau** : les modules du chantier ne lisent aucun `process.env`
  (`DELIVERY_PROOF_PEPPER` n'est lu que par le mode preuve QR, non utilisé ici).
- **Quota CPU mesuré (`firebase functions:list`, 95 fonctions)** : Σ(cpu × maxInstances) = **166,5** (cpu absent compté 1).
  Les deux nouvelles fonctions ajoutent +1,0 → 167,5. Le plafond réel n'est pas lisible depuis la CLI et la saturation avait été
  rencontrée vers ~168 : **marge inférieure à 1 point**. Prévoir de libérer de la marge avant la vague 1 (décision à prendre),
  ou accepter qu'un échec « total allowable CPU » arrête le déploiement sans effet (rien n'est partiellement modifié par fonction).
- **Règles** : déployées = règles de HEAD **moins** le bloc `ai_consents` ; l'arbre isolé = déployées + bloc `ai_consents` (déjà commité
  en HEAD) + 4 champs de litige. Aucun changement de règles n'est **indispensable** au fonctionnement des nouvelles fonctions
  (Admin SDK) : le lot B est une protection, pas un prérequis.
- **Index** : `orders status ASC + createdAt ASC` présent en production ; les 91 index locaux sont tous présents en production.
- **Fonctions HEAD non déployées** (QR de preuve, suppression de compte, SMS, QR partenaires — 25 fonctions) : un déploiement ciblé ne les touche pas.

## 0. Prérequis (avant toute commande)

1. Le répertoire de travail contient aussi des modifications **étrangères** à ce chantier (abonnements, événements,
   permissions admin : `professionalSubscriptions.js`, `eventNotifications.js`, `adminGuards.js`, nombreux écrans admin).
   Un déploiement ciblé `--only functions:x` téléverse **tout le code source** : les fonctions nommées s'exécuteront avec
   les modules partagés modifiés (`adminGuards.js` en particulier, utilisé par les deux nouvelles fonctions).
   → Décider : déployer depuis l'arbre actuel après revue de ces diffs, ou isoler ce chantier dans un commit dédié
   (commit à demander explicitement).
2. Relancer et conserver les preuves : `npm test` (functions), tests émulateur, `npm run test:rules`, `flutter analyze`, `flutter test`.
3. `firebase functions:list --json` : comparer à `docs/FUNCTIONS_DEPLOYED_2026-10-30.txt` (95 fonctions) ; sauvegarder l'état.
4. Vérifier le quota CPU Cloud Run régional (`Σ cpu × maxInstances`, ~119,5 au Prompt 122). Ajouts de ce lot :
   `adminOrderDisputeCF` 0,5 × 1 et `adminConfirmDeliveryCF` 0,5 × 1 = **+1,0**. Aucune augmentation de `cpu`/`maxInstances` ailleurs.
   Une erreur « total allowable CPU per project per region » = réduire ailleurs, pas insister.
5. Index : le rattrapage de diffusion lit `orders` par `status in [...]` + `createdAt <=`. L'index composite
   `status ASC, createdAt ASC` existe dans `firestore.indexes.json` ; **vérifier qu'il est actif en production** (console ou
   `firebase firestore:indexes`) — l'émulateur ne vérifie pas les index. Les autres requêtes (`cancelRequestAfterPickup.status ==`,
   `reconciliation_flags.status ==`, `stuck_order_alerts orderBy alertedAtMs`) n'utilisent que des index mono-champ automatiques.

## 1. Lot A — Cloud Functions (ordre recommandé)

| # | Fonction | Nature | Dépendances / remarque |
|---|---|---|---|
| 1 | `adminOrderDisputeCF` | **NOUVELLE** | `adminOrderDisputes.js`, `orderActions.js`, `driverLifecycle.js`, `adminGuards.js` ; sans effet tant qu'aucun écran ne l'appelle |
| 2 | `adminConfirmDeliveryCF` | **NOUVELLE** | cœur `buildDeliverOrder` (mode `adminConfirm`) ; super-admin seul |
| 3 | `cancelOrderCF` | modifiée | garde `ORDER_PICKED_UP` + demande `cancelRequestAfterPickup` (**change le comportement client** : plus d'annulation seule après récupération) |
| 4 | `deliverOrderCF` | modifiée (code partagé) | comportement livreur inchangé ; à déployer car `orderActions.js` change |
| 5 | `adminBillingCF` | code partagé | utilise `cancelOrderTx` (garde picked_up avec `adminDecision`) |
| 6 | `aiConfirmAction` (+ outil AZ IA `cancel_order`) | modifiée | refuse l'annulation d'une commande récupérée |
| 7 | `dispatchOrderToDriver` | modifiée | `expandBroadcast`, `lastDispatchAtMs`, observation tarifaire C2 (journal seul, jamais bloquant) |
| 8 | `notifyBroadcastDrivers` | modifiée | notifie seulement les **nouveaux** livreurs lors d'un élargissement |
| 9 | `enforceOrderRateLimit` | modifiée | `refundAmounts` inclut `shoppingBudget` (correctif C1) |
| 10 | `autoExpireOrders` | modifiée | reprise de diffusion (`dispatchRetry`) + alertes de commandes bloquées (`stuckOrderAlerts`) toutes les 5 min |

`confirmOrderDeliveryWithProof` (preuves QR/PIN) **n'est pas déployée** en production : ne pas l'inclure.

Commande (à exécuter UNIQUEMENT sur demande) :

```
firebase deploy --project az-express-b0469 --only functions:adminOrderDisputeCF,functions:adminConfirmDeliveryCF,functions:cancelOrderCF,functions:deliverOrderCF,functions:adminBillingCF,functions:aiConfirmAction,functions:dispatchOrderToDriver,functions:notifyBroadcastDrivers,functions:enforceOrderRateLimit,functions:autoExpireOrders
```

Déployer en deux vagues si possible : (1) fonctions 1-2 (nouvelles, inertes) ; (2) fonctions 3-10 après vérification.
Vérifier d'abord que `aiConfirmAction` est bien la seule fonction AZ IA à redéployer (les outils vivent dans le même module).

## 2. Lot B — Règles Firestore (séparé, après le Lot A)

Diff à déployer : `serverOwnedOrderFieldsUnchanged()` interdit désormais au client/livreur d'écrire `cancelRequestAfterPickup`,
`disputeDecision`, `adminDeliveryConfirmation`, `deliveryClosedBy`. `reconciliation_flags` reste en refus par défaut.
**Attention** : `firestore.rules` contient aussi d'autres modifications non liées (permissions admin S8, notes de livraison).
Les règles se déploient en bloc : valider tout le diff, puis `firebase deploy --only firestore:rules --dry-run`, puis le déploiement réel.
Aucune application cliente n'écrit ces champs aujourd'hui (à re-vérifier par recherche dans `lib/` avant le déploiement).

## 3. Lot C — Application admin (après A et B vérifiés)

Les écrans `admin_disputes_page.dart` et `admin_stuck_alerts_page.dart` existent mais ne sont **pas** dans `admin_menu.dart`. Les rattacher
(permission `commandes`, super-admin pour les décisions) seulement après la vérification du Lot A, puis publier une version admin.

## 4. Risques de régression

- **Annulation après récupération** : l'app cliente affiche le message d'erreur du serveur ; vérifier que le texte est lisible côté client.
- **Reprise de diffusion** : plus de lectures Firestore (≤ 50 commandes/minute) et d'écritures `order_dispatch_retries` ; surveiller la facturation.
- **Cadence du scheduler** : les paliers 30/90/150/300/480 s supposent un passage toutes les minutes (cadence mesurée, jitter ≤ 17 s). Les tentatives réelles ont lieu au premier passage après chaque palier.
- **Alertes** : `stuck_order` notifie les admins avec la permission `commandes` ; première exécution = alertes sur les commandes déjà bloquées (rafale unique, dédoublonnée ensuite).
- **Quota CPU** : +1,0 (voir §0.4).
- **Code partagé** : `orderActions.js` est utilisé par toutes les fonctions de commande ; surveiller `deliverOrderCF` / `acceptOrderCF` dans les 30 min suivantes.

## 5. Vérifications après déploiement (lecture seule d'abord)

1. `firebase functions:list` : les 2 nouvelles fonctions présentes (95 + 2 = 97 attendues), aucune autre disparue.
2. Journaux de `autoExpireOrders` pendant 10 min : exécutions chaque minute, pas d'erreur, `order_dispatch_retries` créés pour les commandes en attente seulement.
3. Appel `listAlerts` / `listDisputes` avec un compte admin de test (permission `commandes`), puis avec un compte sans permission (refus attendu).
4. Vérifier qu'un sous-admin reçoit `permission-denied` sur `decide` (remboursements) et sur `adminConfirmDeliveryCF`.
5. Test réel contrôlé sur **commande de test créée pour l'occasion** (aucune donnée de production existante modifiée) : annulation client après `picked_up` → demande tracée, aucun remboursement.
6. Surveiller `audit_logs` (`admin_order_dispute`, `admin_confirm_delivery`) et la facture Firestore pendant 24 h.

## 6. Retour arrière

- **Fonctions** : redéployer la révision précédente depuis le commit de référence (`7a76f18`) avec `firebase deploy --only functions:<nom>`
  depuis un arbre propre ; pour les deux nouvelles fonctions, `firebase functions:delete adminOrderDisputeCF adminConfirmDeliveryCF` (aucun état à restaurer).
  En urgence, Cloud Run conserve les révisions : rebasculer le trafic vers la révision précédente du service concerné.
- **Reprise de diffusion / alertes** : désactivables en retirant l'appel dans `autoExpireOrders` (déploiement d'une seule fonction) ; les documents `order_dispatch_retries`, `stuck_order_alerts` sont inertes.
- **Règles** : redéployer le fichier de règles précédent (sauvegarde : `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt`).
- **Données** : aucune migration, champs additifs seulement. Un remboursement exécuté est définitif (crédits wallet) : une erreur se corrige par une écriture compensatoire autorisée, jamais par retour arrière du code.
