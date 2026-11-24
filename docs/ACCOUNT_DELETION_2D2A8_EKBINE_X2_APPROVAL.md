# 2D-2A.8 — Formalisation de l'exception E-Kbine X-2

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document de formalisation uniquement : aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, accès distant, opération Firebase, commit, push, déploiement ni nettoyage ; aucun document existant modifié ; modifications locales préservées ; aucun lot L0–L8 commencé.

Sources : mission 2D-2A.8 (décision du propriétaire), `ACCOUNT_DELETION_2D2A7_EKBINE_DECISIONS.md` (**P7**, §2), 7E-97 §5-§6, `ACCOUNT_DELETION_2D2A5_APPROVED_DECISIONS.md`, code relu en lecture seule (`functions/index.js` l.83-90 et 2032-2034, `ekbineOrders.js` l.283-340, `accountAdmission.js`, `accountDeletion.js` l.16-19 et l.88).

---

## 1. Les quatre niveaux (à ne pas confondre)

| Niveau | Contenu | Statut |
|---|---|---|
| **A. Décision métier approuvée** | §2 | **APPROUVÉE par le propriétaire** (mission 2D-2A.8) |
| **B. Conditions techniques à implémenter** | §3 (C1–C13) et §4 | **Contrat d'implémentation**, non implémenté |
| **C. Contrôles restant à tester** | §5 | **Aucun test écrit ni exécuté** |
| **D. Preuves de fonctionnement absentes** | §6 | **Aucune** |

> **L'exception n'est pas opérationnelle.** Elle est approuvée comme décision ; elle n'existe ni dans le code, ni dans les tests, ni en préproduction, ni en production. Elle ne doit pas être déclarée opérationnelle avant l'exécution des tests du §5 et les autorisations séparées du §7.

---

## 2. A — Décision métier approuvée

**Le propriétaire approuve l'ajout de `ekClientConfirmOrder` comme cinquième exception au contrôle `onCallClosing` prévu par 7E-97.**

Précisions de portée, issues de la mission :
1. L'exception est **strictement limitée** au client qui **confirme une commande déjà engagée avant sa mise en quarantaine**.
2. Elle étend la liste fermée de 7E-97 §5 (quatre fonctions : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof`) à **cinq**. Ce changement de la liste fermée est donc **approuvé pour cette seule fonction** ; la liste reste fermée (aucune sixième sans nouvelle décision).
3. Ne sont **pas** approuvées par cette décision : `ekCancelOrderCF`, `ekbineSubmitDepositProof`, `ekbineAgentDepositAction`, toute autre fonction Ekbine, toute fonction hors Ekbine.
4. L'annulation de la demande de suppression avant `sealed` (D-7) **reste prioritaire** lorsqu'elle est possible (§4.3).

Effet sur les documents antérieurs : lève, pour cette seule fonction, l'ouvert « extension de la liste fermée » de P7 §2.4 et §9.2 point 1. Cela ne modifie pas rétroactivement les documents existants.

---

## 3. B — Conditions techniques : C1–C13 (reprises intégralement de P7 §2.4)

Contexte de portée repris de P7 §2.4 : une seule fonction, `ekClientConfirmOrder`, avec contrôle d'acteur de type `assertClosureActor` dans la transaction, avant toute écriture. Ajouter seulement `onCallClosing` **ne suffit pas** (P7 §2.2).

| # | Condition | Où | Détail |
|---|---|---|---|
| **C1** | Commande engagée **avant** la quarantaine | transaction | `order.assignedAt` (horodatage serveur posé par `ekbineAcceptOrder`) strictement antérieur à `tombstone.createdAt` ; absence ou valeur non-Timestamp ⇒ refus. Limite : si l'agent a écrit `proof_sent` par les règles, `assignedAt` reste celui de l'acceptation ; une commande créée directement par le client sans acceptation serveur n'a pas `assignedAt` ⇒ refus. |
| **C2** | **Aucune nouvelle commande** | structurel | l'exception ne couvre pas `ekCreateOrderCF` ni l'écriture directe (bloquée par `isAuth()` sous tombstone) ; test de câblage |
| **C3** | **Rôle** | transaction | l'identité est dans `clients/{uid}`, et dans aucune autre collection de rôle (cohérent avec `multiple_roles_manual_review`) |
| **C4** | **Identité** | transaction | `order.clientId === uid` (existant) ; `uid` du jeton = id du tombstone relu |
| **C5** | **Statut du client** | transaction | tombstone **existe**, `phase` ∈ {absent (état actuel `deleting` à 2D), `closing`} ; **refus** si `sealed`, si `deleting:true` côté P3, ou si `isDeleted` ; profil client existant ; vérifie que le Auth n'est pas déjà supprimé (`authDeletedAtMs` absent) |
| **C6** | **Statut de la commande** | transaction | `proof_sent` uniquement (existant) |
| **C7** | **Bénéficiaire** | transaction | agent existant, non anonymisé, **sans** tombstone, **sans** `deletionRequested` : garde actuelle `assertNewAccountActivity(agent)` **conservée à l'identique** ; aucune exception pour un agent anonymisé ou absent |
| **C8** | **Aucune confirmation interdite à l'agent** | transaction | si l'agent ne peut pas être crédité, la confirmation est refusée en entier (X1-b) ; aucune terminaison « sans crédit » |
| **C9** | **Preuve financière** | transaction | exception limitée à `provenDebit(order)` (débit AZ prouvé) ou `paymentMethod !== 'wallet'` ; **débit non prouvé ⇒ refus** (créerait un flag, c'est-à-dire une nouvelle créance dans un compte fermé) ; en outre relecture du journal `ekorder_<orderId>` conforme au montant |
| **C10** | **Époque** | transaction | incrémentation de `tombstone.epoch` dans la même transaction (writer de catégorie B, P3) ; lecture `epoch` avant écriture |
| **C11** | **Audit** | transaction | ligne `audit_logs` dans la transaction avec indicateur `closureDuringQuarantine:true`, sans donnée personnelle |
| **C12** | **Pas d'effet de bord sur le client** | transaction | aucune écriture sur `clients/{uid}` (profil/portefeuille) ; seul le portefeuille de l'agent change |
| **C13** | **Liste fermée testée** | test | test de câblage : `onCallClosing` n'est utilisé que pour les fonctions de la liste approuvée |

**Remarque de statut sur C9.** P7 marquait la relecture du journal `ekorder_<orderId>` comme `[OUVERT : contrôle supplémentaire]`. La mission exige la reprise **sans simplification** des 13 conditions : elle est donc ici **reprise comme condition** ; la forme exacte de la comparaison (montant, identifiant de commande, absence de remboursement `ekrefund_<orderId>`) reste à préciser à l'implémentation.

**Remarque de statut sur C5.** Le tombstone actuel est créé avec `{createdAt, state:'deleting'}` (`accountDeletion.js:88`) : il n'a **ni** `phase`, **ni** `epoch`, **ni** `authDeletedAtMs`. Aujourd'hui, un tombstone « en cours de quarantaine » et un tombstone « en cours de suppression » ne sont pas distinguables. C5, C10 et C1 (pour `createdAt` : disponible) ne sont donc **pleinement implémentables qu'après** introduction des champs additifs de P3. Tant que ce n'est pas fait, la seule lecture sûre est : **tout doute sur la phase ⇒ refus**.

---

## 4. B — Exigences de la mission, rattachées aux conditions

Les dix conditions obligatoires de la mission ne remplacent pas C1–C13 ; elles s'y ajoutent et s'y rattachent.

| # mission | Exigence | Condition(s) |
|---|---|---|
| 1 | Reprendre C1–C13 sans les simplifier | §3 |
| 2 | Vérifier le tombstone du client dans la transaction | C5, C10 : lecture `account_tombstones/{uid}` via la transaction (jamais seulement par le wrapper, qui lit hors transaction) |
| 3 | Vérifier rôle et identité de l'acteur | C3, C4 |
| 4 | Vérifier l'état de la commande et son antériorité | C6, C1 |
| 5 | Vérifier l'état du bénéficiaire | C7 |
| 6 | Aucun crédit vers un bénéficiaire anonymisé ou absent | C7, C8 : profil absent ⇒ refus `not-found` (existant, relu avant la garde) ; `isDeleted` ⇒ refus ; DR3 (profil absent traité comme anonymisé) |
| 7 | Aucune nouvelle commande ni nouveau débit | C2, C9, C12 : l'exception ne contient aucun chemin de création ni de débit client ; `clients/{uid}` n'est pas écrit |
| 8 | Un agent en quarantaine ne valide jamais une confirmation client | C7, C8 : le refus tient à l'état du bénéficiaire ; il ne peut être levé ni par l'exception, ni par l'état du client |
| 9 | Toute incohérence ⇒ refus sans écriture financière partielle | toutes : tous les contrôles sont faits **avant** la première écriture dans la même transaction ; l'échec annule l'ensemble (commande, portefeuille agent, flag, audit) |
| 10 | L'annulation avant `sealed` reste prioritaire | §4.3 |

### 4.1 Séquence d'exécution requise

Dans l'ordre, tout refus étant sans écriture :
1. wrapper `onCallClosing` : ne vérifie **pas** l'état du compte (aucun `assertAccountEnabled`) ; limitation de débit existante ;
2. dans la transaction, **lectures d'abord** : commande, tombstone du client, profil client, absence d'autres profils de rôle, profil agent, tombstone agent, journal de débit (C9) ;
3. contrôles C1, C3–C9 ;
4. seulement alors : écritures de la commande, du portefeuille de l'agent, de `tombstone.epoch` (C10), de l'audit (C11).

### 4.2 Ce que l'exception ne fait jamais

- Lever, raccourcir ou annuler une quarantaine.
- Créditer un agent fermé, anonymisé ou absent.
- Créer ou débiter une commande ; écrire sur le portefeuille ou le profil du client.
- Terminer une commande sans règlement en cas de refus du bénéficiaire.
- Créer un flag de débit non prouvé pour un client fermé.
- S'appliquer à un client `sealed`, anonymisé ou dont l'Auth est supprimé.

### 4.3 Priorité à l'annulation de la demande de suppression (D-7)

Ordre de traitement **[approuvé comme priorité par la mission]** :
1. Si la demande peut être annulée avant `sealed`, sous nouvelle inspection (D5 D-7), c'est la voie à privilégier : le client redevient actif et confirme par le chemin normal, sans exception de wrapper.
2. L'exception X-2 n'est utilisée que si la quarantaine doit être conservée.
3. Si aucune des deux n'est possible, le dossier reste bloqué (voir §8, X-3).

Les modalités de D-7 (qui peut annuler, quelle inspection) restent **ouvertes** (§8).

---

## 5. C — Contrôles restant à tester (aucun n'existe)

Aucun test n'a été écrit, modifié ni exécuté pour cette mission. Plan minimal, à produire seulement après autorisation d'implémentation :

| # | Cas | Résultat attendu | Condition |
|---|---|---|---|
| T1 | client sous tombstone `closing`, commande `proof_sent` engagée avant, agent actif, débit prouvé | confirmation réussie ; agent crédité de `debitedAmount` ; `epoch` +1 ; audit `closureDuringQuarantine` | C1, C5, C10, C11 |
| T2 | client `sealed` | refus, aucune écriture | C5 |
| T3 | client `isDeleted` avec jeton valide | refus | C5 |
| T4 | profil client absent | refus | C5 |
| T5 | Auth du client déjà supprimé (`authDeletedAtMs`) | refus | C5 |
| T6 | `assignedAt` postérieur au tombstone | refus | C1 |
| T7 | `assignedAt` absent ou non-Timestamp | refus | C1 |
| T8 | commande hors `proof_sent` | refus | C6 |
| T9 | `order.clientId` ≠ appelant | refus | C4 |
| T10 | appelant présent dans une autre collection de rôle | refus | C3 |
| T11 | agent en quarantaine / `deletionRequested` / tombstone | refus, commande reste `proof_sent`, aucun crédit | C7, C8 |
| T12 | agent `isDeleted` | refus, aucun crédit | C7 |
| T13 | profil agent absent | refus `not-found`, aucun crédit | C7 |
| T14 | débit non prouvé | refus, aucun flag créé | C9 |
| T15 | journal `ekorder_<id>` absent ou de montant différent | refus | C9 |
| T16 | paiement hors wallet | réussite ; crédit 0 ; aucune écriture de portefeuille | C9 |
| T17 | tentative de création de commande par un client en quarantaine | refus | C2 |
| T18 | `clients/{uid}` inchangé après réussite | vérifié | C12 |
| T19 | rejeu de la même confirmation | `alreadyDone`, aucune double écriture | idempotence |
| T20 | course : tombstone devenant `sealed` entre la lecture et l'écriture | transaction échoue ou refuse | C5, C10 |
| T21 | faute simulée après la première écriture | aucune écriture partielle | mission #9 |
| T22 | câblage : `onCallClosing` n'est utilisé que pour les cinq fonctions approuvées ; chaque fonction exécutée avec un acteur anonymisé refuse | échec si une sixième apparaît | C13 |
| T23 | les autres fonctions Ekbine (`ekCancelOrderCF`, `ekbineSubmitDepositProof`, `ekbineAgentDepositAction`) restent sous le wrapper standard | vérifié | portée |
| T24 | les gardes Ekbine existantes (création, acceptation, confirmation agent) restent actives | tests existants inchangés | préservation |

T20 et T21 supposent un contrôle de concurrence ; la validation en émulateur (7E-89, 9/9) **n'est pas une preuve de production**.

---

## 6. D — Preuves de fonctionnement encore absentes

| Élément | État |
|---|---|
| `onCallClosing` | **n'existe pas** dans `functions/*.js` (aucune occurrence) |
| `assertClosureActor` | **n'existe pas** |
| Champs de tombstone `phase`, `epoch`, `authDeletedAtMs` | **n'existent pas** (tombstone actuel : `createdAt`, `state:'deleting'`) |
| Câblage de `ekClientConfirmOrder` | inchangé : toujours sous le wrapper `onCall` qui refuse tout appelant tombstoné (`index.js:83-90`, `2032-2034`) |
| Tests de l'exception | **aucun** |
| Test de câblage de la liste fermée | **aucun** |
| Validation en émulateur, préproduction, production | **aucune** |
| Version de Node 22.23.4 | jamais validée (seule v24.22.1 disponible) |
| Gardes Ekbine existantes | présentes seulement dans le worktree non commité (`ekbineOrders.js`, +8 lignes), absentes de HEAD |
| Valeur de `partnerInventoryVersion` | inconnue |

**Comportement réel aujourd'hui** : un client sous tombstone **ne peut pas** confirmer une commande Ekbine. Cette décision ne change rien à ce comportement tant qu'elle n'est pas implémentée et testée.

---

## 7. Prérequis avant toute implémentation

1. Autorisation explicite d'implémentation (aucune n'est donnée par la présente mission).
2. Infrastructure de P3 : champs additifs du tombstone (`phase`, `epoch`, `authDeletedAtMs`), `assertClosureActor`, `onCallClosing` créé **avec** ses gardes (7E-97 : l'exception de wrapper n'est introduite qu'avec ses gardes), et ordre des lots déjà fixé en P3.
3. Rattachement des gardes Ekbine non commitées par hunks avant de modifier `ekbineOrders.js` ; ne jamais restaurer le fichier depuis HEAD.
4. Écriture des tests T1–T24 **avant ou avec** le code ; aucune déclaration « opérationnelle » avant leur passage.
5. Aucun déploiement ; préproduction seulement après autorisation séparée, sur `az-express-preprod` avec `--project` explicite ; production strictement exclue.
6. Conséquence sur 7E-97 : son test de câblage « quatre fonctions » doit être remplacé par « cinq fonctions » ; ceci n'est pas fait ici.

---

## 8. Sujets qui restent **à confirmer** (non approuvés par le propriétaire)

Les propositions suivantes de P7 **ne sont pas** approuvées par la mission 2D-2A.8. Elles restent des propositions ou des points ouverts :

| Sujet | État |
|---|---|
| **X-3** : dossier `ekbine_order_blocked`, sorties S1–S4, N2, traitement avec un seul super-admin | proposé, **à confirmer** |
| Remboursement d'un client fermé (`ekCancelOrderCF`), D1/D2 pour Ekbine | **ouvert** |
| `ekbineAgentDepositAction` : garde de tombstone en transaction, classification A ou B | proposé, **à confirmer** |
| `partnerInventoryVersion` : valeur réelle et distinction `deletionRequested` seul / quarantaine | **ouvert** ; lecture à autoriser séparément |
| Trace des confirmations refusées (hors transaction, idempotente) | proposé, **à confirmer** |
| Type de dossier (`ekbine_order_blocked` contre réutilisation de `beneficiary_account_closed`, claim `client_payment`) | **ouvert** |
| Qui peut annuler la demande de suppression d'un agent ; modalités de D-7 | **ouvert** |
| Existence d'un second responsable indépendant pour N2 | **ouvert** |
| Écriture directe des commandes par le client (règles) et acceptation sans relecture de l'état du client | **ouvert** |
| Préservation des gardes non commitées ; indexation par hunks | pratique recommandée (P7 §7), non soumise à décision |

Des décisions antérieures restent inchangées : 7E-73 prévaut sur 7E-87 D3 pour l'agent en quarantaine (X-1, arbitré par la mission 2D-2A.7) ; aucune levée automatique de quarantaine ; aucun crédit automatique vers un compte anonymisé ou absent.

---

## 9. Risques résiduels de l'exception

| Risque | Gravité | Atténuation |
|---|---|---|
| Câblage incomplet : retrait du wrapper sans `assertClosureActor` (confirmation par un client scellé ou anonymisé) | élevée | `onCallClosing` introduit seulement avec ses gardes ; T2–T5, T22 |
| Distinction `closing` / `deleting` impossible avec le tombstone actuel | élevée | tout doute ⇒ refus ; champs P3 d'abord |
| Antériorité de l'engagement établie sur un horodatage d'acceptation ; si l'agent écrit `proof_sent` par règles, la preuve reste celle de l'acceptation | moyenne | C1 refuse l'absence de `assignedAt` ; durcissement des règles hors périmètre |
| Débit prouvé établi par des champs de la commande (`provenDebit`) | moyenne | C9 : relecture du journal `ekorder_<id>` |
| Commande bloquée par un agent fermé : l'exception ne la résout pas | élevée | X-3 (à confirmer) ; D-7 prioritaire |
| Gardes Ekbine absentes de HEAD | moyenne | §7 point 3 |

---

Je m'arrête ici. Aucun code, test ni lot n'est commencé ; l'exception n'est pas opérationnelle.
