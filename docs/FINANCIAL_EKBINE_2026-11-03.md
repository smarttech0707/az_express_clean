# Sécurité financière E-Kbine — Mission 5 (local, NON déployé, NON commité)

Branche `finalisation/az-express`. Rien n'est déployé : fonctions, règles et application restent à décider.

## Ce qui change

| Élément | Avant | Maintenant |
|---|---|---|
| Création | Flutter débite le wallet (transaction client), puis écrit la commande séparément. Aucune preuve serveur du débit ; `agentEarning` fourni par le client. | `ekCreateOrderCF` : une transaction (débit + `tx.create` commande + ligne de journal `ekorder_<id>`), montants/frais/gain recalculés, clé d'idempotence → identifiant de commande déterministe. |
| Annulation | Écriture directe `status: cancelled`, aucun remboursement. | `ekCancelOrderCF` : propriétaire, statuts `pending`/`awaiting_deposit` seulement, remboursement de `debitedAmount` prouvé, une fois, journal `ekrefund_<id>`, même transaction. |
| Confirmation | Crédit agent = `order.agentEarning` (champ client). Refuse `agentEarning == 0`. | Crédit = `debitedAmount` prouvé (= `amount`, non remboursé). Sans preuve : commande terminée, **aucun crédit**, `reconciliation_flags` ouvert. Hors wallet : terminée, aucun crédit. Une seule fois (`agentCredited`). |
| AZ IA `create_ekbine_order` | Débit sans preuve. | Écrit la même preuve (`walletDebited`, `debitedAmount`, journal `ekorder_<id>`). |
| Règles (locales) | `agentEarning` et montants modifiables dans plusieurs branches ; création libre. | `ekFinancialUnchanged()` sur toutes les branches de mise à jour ; création refusée si elle porte une preuve (`walletDebited`, `debitedAmount`, …). |

Règles métier conservées : frais 0, le client paie le montant exact, l'agent gagne `amount` (wallet). Aucun tarif ni commission ajouté.
Plafond de sécurité ajouté : 1 000 000 FCFA par commande (aucun plafond n'existait). Barème minimal par service recopié de `ekServices`.

## Paiements hors wallet (Orange Money, MTN MoMo, Wave, cash)

Comportement réel : le client paie l'agent **hors application** ; AZ ne reçoit rien. Le formulaire pose `agentEarning = 0`, donc `ekClientConfirmOrder` refusait toute commande hors wallet (« Données commande invalides ») : elles ne pouvaient jamais se terminer (blocage existant, pas une protection).
Aucune API ne permet à AZ de vérifier ces paiements (FeexPay n'est pas branché sur E-Kbine ; la « preuve de dépôt » est une image que l'agent juge lui-même).
Décision locale : on ne crédite **aucun** wallet pour ces commandes (aucun argent AZ à créer ni à rendre) ; la commande peut être terminée après confirmation du client, sans mouvement financier. Si un crédit AZ pour ces commandes est voulu un jour, il exige une confirmation fournisseur (FeexPay) : **non inventée, non faite**.

## Dépendances / ordre de déploiement

1. Fonctions `ekCreateOrderCF`, `ekCancelOrderCF` (0,5 CPU × 2 chacune, soit +2 au quota Cloud Run) et `ekClientConfirmOrder` durcie.
2. **Attention** : dès que `ekClientConfirmOrder` durcie est en production, les commandes wallet créées par l'ANCIENNE application (sans preuve de débit) terminent sans crédit pour l'agent (+ signalement admin). Livrer la nouvelle application avant ou en même temps que cette fonction, ou accepter un traitement manuel pour les commandes de la période.
3. Règles locales : seul le durcissement additif est dans `firestore.rules` (compatible avec l'ancienne application). La fermeture complète ci-dessous n'est PAS appliquée.

## Fermeture des anciens chemins (préparée, non appliquée)

À appliquer après la version minimale de l'application :

```
// ekbine_orders
allow create: if false;                       // création uniquement par ekCreateOrderCF / AZ IA (Admin SDK)
// branche client « cancelled » : supprimer (annulation uniquement par ekCancelOrderCF)
```
Et retirer côté règles top-level `wallet_transactions` le type `ekbine_payment` (plus d'écrivain).
Reste ouvert (à traiter en phase suivante) : l'agent écrit encore `proof_sent` directement ; le litige client (`disputed`) est direct ; les commandes historiques n'ont pas de preuve de débit.

## Risques restants

- Commandes wallet historiques (avant ce lot) : aucune preuve ; confirmation sans crédit, annulation sans remboursement automatique → `reconciliation_flags` (`ekconfirm_*`, `ekcancel_*`) pour décision admin. Pas de rattrapage automatique (le journal de premier niveau `ekbine_payment` est forgeable).
- Commandes annulées directement par l'ancienne application : jamais remboursées (état antérieur, non rétroactif).
- Le déblocage `awaiting_deposit` reste identique pour toutes les commandes (le texte de l'interface dit que le wallet n'a pas d'étape de dépôt) : comportement existant, non modifié, à clarifier.
- Collusion client/agent sur l'étape « preuve » : le crédit est plafonné au montant réellement débité (aucune création d'argent), mais la qualité de l'exécution reste déclarative.

## Tests

`functions/test/ekbineOrders.test.js` (17), `financialConcurrency.emulator.test.js` (+5, concurrence réelle sur l'émulateur), `rules-tests/ekbine-orders.rules.test.js` (4).

---

## Validation finale (compatibilité)

### Plafond technique — valeur PROVISOIRE
1 000 000 FCFA par commande (`MAX_EK_AMOUNT`, `functions/ekbineOrders.js`). Aucun plafond n'existait avant ; la valeur n'a pas été fixée par une règle métier : **à valider avant la production**. Aucun tarif ni commission modifié.

### Paiements hors wallet : déclaratif ≠ vérifié
- `ekClientConfirmOrder` répond `settlement` : `wallet_credit` (débit AZ prouvé, agent crédité), `declarative_no_credit` (paiement hors wallet : le client déclare la commande exécutée), `withheld_unproven` (commande historique sans preuve).
- Pour `declarative_no_credit` : aucun wallet client ni agent n'est touché, aucune ligne de journal créée (testé). La commande est « déclarée exécutée », jamais « paiement vérifié » : aucun fournisseur n'a confirmé quoi que ce soit.

### Parcours `awaiting_deposit` pour les commandes wallet — INCOHÉRENCE CONSTATÉE, NON CORRIGÉE
Constat : `ekbineAcceptOrder` place toute commande acceptée en `awaiting_deposit`. L'écran de suivi affiche alors « Preuve de paiement requise » et le numéro Mobile Money de l'agent, y compris pour une commande wallet **déjà débitée** ; l'agent ne peut démarrer qu'après `deposit_confirmed`. Le suivi de statut côté client attend pourtant, pour le wallet, `pending → assigned → in_progress` (aucun dépôt) : `assigned` n'est plus produit. Risque : le client wallet paie deux fois (wallet AZ, puis dépôt à l'agent).
Correction minimale proposée (statuts existants uniquement) : dans `ekbineAcceptOrder`, si `order.paymentMethod === 'wallet' && order.walletDebited === true`, écrire directement `status: 'deposit_confirmed'` (mêmes champs d'agent) au lieu de `awaiting_deposit`. Le bouton « démarrer » de l'agent existe déjà pour `deposit_confirmed`, aucun statut nouveau, le dépôt reste exigé pour les paiements hors wallet.
Conséquences : (1) le client wallet ne peut plus annuler après l'acceptation par un agent (annulation limitée à `pending`, déjà le comportement serveur) ; (2) l'écran de suivi wallet devrait afficher `deposit_confirmed` comme étape « Agent » ; (3) les commandes déjà en `awaiting_deposit` ne sont pas migrées. **Non appliquée : décision requise.**

### Procédure de rapprochement manuel des commandes historiques (aucun solde modifié)
Outils (lecture seule) : `functions/ekbineReconciliation.js` (analyse pure, 9 tests) et `functions/scripts/ekbineReconciliationReport.js` (`--project` obligatoire, aucune écriture).
1. **Périmètre** : commandes `ekbine_orders` payées par wallet sans `walletDebited`/`debitedAmount`/`refunded`/`agentCredited` (jamais traitées par le serveur : exclues = aucun double traitement).
2. **Débits réels** : le seul indice est `wallet_transactions` (niveau supérieur) `type: ekbine_payment` du même client, même montant, dans les 15 minutes avant la création. Appariement un-pour-un (un débit ne justifie qu'une commande). C'est un INDICE falsifiable : confirmer sur le solde réel et l'historique du client.
3. **Clients à rembourser** : commandes `cancelled` sans remboursement tracé et débit probable → `client_refund_to_decide`.
4. **Agents à rémunérer** : commandes `completed` avec débit probable et aucun audit `ekbine_confirm_order` → `agent_pay_to_decide` ; commandes en cours → `pending_order_follow_up`.
5. **Alertes** : agent crédité sans débit retrouvé → `agent_paid_without_debit_review` ; débit ambigu → revue.
6. **Anti-doublon** : une décision par commande (`decisionKey = ek_reconcile_<orderId>`) ; avant toute correction, relire la commande (une commande devenue `walletDebited`/`refunded`/`agentCredited` est hors périmètre). Les `reconciliation_flags` `ekcancel_*` / `ekconfirm_*` ouverts par les fonctions suivent le même principe.
7. **Exécution d'une correction** : hors de ce lot. Elle nécessitera une fonction d'administration dédiée (transaction, identifiant de journal déterministe lié à `decisionKey`, super-admin, audit) ; aucun remboursement ni crédit automatique pour l'historique.

### Tests ajoutés
Flutter : `test/ekbine/ek_order_server_flow_test.dart` (15) ; fonctions : `ekbineReconciliation.test.js` (9) et assertions `settlement` dans `ekbineOrders.test.js`.

---

## Correction du parcours wallet (décision 2, local, non commité)

**`ekbineAcceptOrder`** (désormais `buildEkbineAcceptOrder`, `functions/ekbineOrders.js`) : dans la transaction, si la commande est `pending`, payée par wallet et à débit PROUVÉ (`walletDebited === true`, `debitedAmount === amount`, non remboursée), elle passe directement à `deposit_confirmed` (agent, nom, téléphone, `assignedAt`). Aucun débit, aucun crédit agent, aucune consigne de dépôt. Tous les autres cas (hors wallet, commande historique sans preuve, preuve incohérente) gardent `awaiting_deposit` et le numéro de dépôt de l'agent.

**Annulation avant exécution** (`ekCancelOrderCF`) : depuis `deposit_confirmed` UNIQUEMENT si le débit est prouvé, `startedAt`/`proofUrl`/`completedAt`/`agentCredited` sont absents et aucun remboursement n'a eu lieu ; vérifié dans la transaction (remboursement du seul `debitedAmount`, une fois). Dès que l'agent démarre (`in_progress` + `startedAt`, transaction de `ekbineAgentDepositAction`), l'annulation est refusée. Course annulation/démarrage prouvée sur l'émulateur : un seul des deux aboutit. Interrupteur : **désactivé par défaut au lancement** (voir ci-dessous).
Limite assumée : « commencé » = l'agent a appuyé sur « Commencer » dans l'application. Une exécution hors application avant cet appui n'est pas détectable ; le risque porte sur l'agent (service rendu puis commande annulée), jamais sur une création d'argent. À encadrer par la consigne donnée aux agents (appuyer sur « Commencer » avant d'exécuter).

**Interface** (`lib/ekbine/ek_tracking.dart`, `ek_order_tracking.dart`) : plus de dépôt demandé aux clients wallet prépayés, frise sans étape de paiement (`Attente → Agent → En cours → Preuve → Terminé`), statut réel (« Agent affecté — paiement déjà effectué »), bouton d'annulation proposé selon la même règle que le serveur (qui reste seul juge). Parcours hors wallet et commandes historiques inchangés (frise enrichie de l'étape « Confirmé », jusque-là absente).

**Règles** : inchangées (l'annulation depuis `deposit_confirmed` n'est possible que par la fonction ; testé).

**Tests** : `ekbineOrders.test.js` (29), émulateur (12, dont acceptation simultanée et course annulation/démarrage), Flutter `ek_tracking_test.dart` (12).

### Interrupteur d'annulation depuis deposit_confirmed — DÉSACTIVÉ au lancement
- **Serveur** : `EK_CANCEL_FROM_DEPOSIT_CONFIRMED` (variable d'environnement, `functions/.env`). Seule la valeur exacte `true` l'active ; absente ou toute autre valeur = désactivé. Lue à chaque appel de `ekCancelOrderCF`. Le code de remboursement sécurisé est conservé intact.
- **Flutter** : `kEkCancelFromDepositConfirmed` (`lib/ekbine/ek_tracking.dart`, `false`) masque le bouton. Les deux doivent rester alignés ; le serveur reste seul juge.
- **Effet actuel** : l'annulation avec remboursement fonctionne tant que la commande est `pending` (avant acceptation) ou `awaiting_deposit` sans preuve ; une commande wallet acceptée (`deposit_confirmed`) ne peut plus être annulée par le client (refus `ORDER_NOT_CANCELLABLE`, aucun remboursement).
- **Activation ultérieure** : (1) ajouter `EK_CANCEL_FROM_DEPOSIT_CONFIRMED=true` dans `functions/.env`, puis redéployer `ekCancelOrderCF` ; (2) passer `kEkCancelFromDepositConfirmed` à `true` dans la prochaine version de l'application ; (3) donner aux agents la consigne d'appuyer sur « Commencer » avant d'exécuter le service ; (4) rejouer les tests (`ekbineOrders.test.js`, émulateur, `ek_tracking_test.dart`).
- **Tests** : désactivé par défaut (refus, aucun remboursement) ; annulation avant acceptation conservée ; valeurs d'environnement autres que `true` refusées ; activation lue à chaque appel ; chemin sécurisé testé avec l'interrupteur forcé (unitaires, émulateur, Flutter).
