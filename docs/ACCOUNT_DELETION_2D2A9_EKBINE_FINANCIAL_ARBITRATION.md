# 2D-2A.9 — Arbitrage des points ouverts E-Kbine (X-3, remboursements, traçabilité, type de dossier)

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document d'arbitrage **documentaire** : aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, accès distant, opération Firebase, commit, push, déploiement ni nettoyage ; aucun document existant modifié ; aucun lot L0–L8 commencé. Analyse **statique** : aucune fonction exécutée.

Sources : P6 (2D-2A.6), P7 (2D-2A.7), P8 (2D-2A.8), D5 (2D-2A.5), 7E-73, 7E-87, 7E-97 ; code relu en lecture seule : `functions/ekbineOrders.js`, `index.js` (wrapper l.83-90, `ekbineAgentDepositAction` l.2130-2160), `ekbineFlow.js`, `accountAdmission.js`, `accountDeletion.js`, `accountObligations.js` (`evaluateFlag` l.567-610, `RESOLUTIONS` l.225-235, `verifyDecision` l.507-560, `flagTypeLabel` l.174), `firestore.rules` (`audit_logs` l.1553).

## 0. Statuts, faits et limites

| Marqueur | Sens |
|---|---|
| **[APPROUVÉ]** | décision explicite du propriétaire (X-1 par 2D-2A.7 ; X-2 par 2D-2A.8 ; règles de la présente mission : « aucun crédit forcé, aucun paiement vers anonymisé/absent, aucune écriture manuelle directe, S2–S4 en N2, N3 indisponible, un seul super-admin ⇒ N2 en attente, aucune suppression avec obligation non résolue, pas de séquestre inventé ») |
| **[RECOMMANDÉ]** | proposition de ce document, cohérente avec les règles approuvées ; **n'est pas une décision** |
| **[À CONFIRMER]** | proposition qui demande une décision humaine ou une vérification |
| **[BLOQUANT]** | élément sans lequel aucune implémentation ne doit commencer |
| **[FAIT]** | observé dans le code lu |
| **[HYPOTHÈSE]** | non vérifié |

**Aucun mécanisme n'est inventé.** En particulier, il **n'existe pas de compte séquestre** : le code débite le portefeuille du client (`wallet`), écrit un journal `ekorder_<orderId>` et ne crédite ensuite personne tant que la commande n'est pas confirmée. Il n'y a pas de ligne comptable représentant la somme « en attente » en dehors de la commande elle-même (`debitedAmount`, `debitLedgerId`). Ce document ne suppose aucun séquestre, aucun portefeuille technique AZ, aucun mécanisme de virement externe.

**Faits de départ vérifiés dans le code :**
1. `proof_sent` n'est pas annulable : `CANCELLABLE = ['pending','awaiting_deposit']` (`ekbineOrders.js:30`) ; `deposit_confirmed` seulement avec `EK_CANCEL_FROM_DEPOSIT_CONFIRMED=true` (désactivé).
2. Aucun writer d'administration ne règle une commande Ekbine ; `ekbineReconciliation.js` n'analyse que (`analyzeLegacyEkOrders`).
3. Les inspecteurs refusent la suppression tant qu'une commande Ekbine du compte est non terminale (`accountDeletion.js:46-51`, `accountDeletionScope.js:42-44`).
4. Un flag de `reconciliation_flags` est lié à un compte par les clés `clientId`, `driverId`, `partnerId`, `sellerId`, `pharmacieId` (`accountObligations.js:572`) : **`agentId` n'en fait pas partie**.
5. Un type de flag inconnu est lu comme `other` (`flagTypeLabel`) ; `RESOLUTIONS` n'a aucune entrée pour `other` ⇒ `flag_resolution_not_allowed` ⇒ dossier bloquant. Un flag `open` est toujours en revue (bloquant).
6. `audit_logs` : `allow write: if false` (Cloud Functions seulement).

---

## 1. X-3 — Commandes E-Kbine `proof_sent` bloquées

### 1.1 Qualification du dossier

Une commande est « bloquée » **[RECOMMANDÉ]** lorsque : statut `proof_sent` ; le client ne peut pas la confirmer (agent fermé/absent, ou client fermé hors exception X-2) ; aucune sortie normale n'existe. Le montant en jeu est `debitedAmount` (XOF), seulement si `provenDebit(order)`.

Rappel : la commande à **débit non prouvé** relève des types existants `ekbine_*_unproven_debit` et n'est pas traitée ici.

### 1.2 Règles communes à S1–S4 [APPROUVÉ]

- Aucun crédit forcé ni automatique ; aucun paiement vers un profil anonymisé ou absent (DR3 : absent ≡ anonymisé).
- Aucune écriture manuelle directe de Firestore pour débloquer.
- S2, S3, S4 : **deux validations indépendantes (N2)**. N3 indisponible (`flag_level3_unavailable`). Avec un seul super-admin : opération N2 **en attente**, dossier **bloquant**.
- Aucune suppression de compte tant que l'obligation est non résolue.
- Une preuve est toujours **lue et vérifiée côté serveur** ; une référence textuelle fournie par une personne n'est jamais une preuve (règle du moteur, `verifyDecision`).

### 1.3 S1 — Rétablissement de l'agent après vérification

| Rubrique | Contenu |
|---|---|
| **Principe** | l'agent redevient éligible ; le **client confirme lui-même** par le chemin normal (`ekClientConfirmOrder`) ; le règlement est celui du code actuel (crédit de `debitedAmount`) |
| **Possible si** | agent non `isDeleted`, non `sealed`, profil existant, tombstone absent ou en phase non scellée ; sinon S1 est **impossible** (→ S2/S3/S4) |
| **Preuves** | état de l'agent relu côté serveur après rétablissement (`isEligibleAgent` vrai, aucun tombstone) ; commande toujours `proof_sent` ; débit prouvé (`provenDebit`) ; journal `ekorder_<id>` conforme |
| **Contrôles financiers** | aucune écriture financière dans S1 lui-même ; le crédit se fait dans la confirmation ordinaire, avec ses gardes ; aucun doublon possible (idempotence `alreadyDone`) |
| **Approbation** | aucune décision financière N1/N2 : aucun argent ne bouge par S1. L'acte de rétablissement est une **annulation de demande de suppression (D-7)**, sous nouvelle inspection, avant `sealed` |
| **Qui annule la demande** | **[À CONFIRMER]** : le titulaire seulement, ou un administrateur après vérification. Aucun texte approuvé ne le fixe |
| **Effet sur la suppression** | la demande est annulée ; le compte n'est plus en cours de suppression. Si l'agent redemande plus tard, une nouvelle inspection relit les commandes |
| **Limite** | inutilisable après `sealed` ou anonymisation |

Statut : **[RECOMMANDÉ]** comme voie prioritaire (cohérent avec la priorité D-7 de 2D-2A.8).

### 1.4 S2 — Remboursement du client

| Rubrique | Contenu |
|---|---|
| **Principe** | la prestation n'est pas due ; le client récupère exactement `debitedAmount`, une seule fois |
| **Cas typique** | agent fermé/absent et service non rendu, ou service contesté |
| **Preuves** | (a) journal de débit `ekorder_<id>` lu et conforme (`provenDebit`) ; (b) **absence** de remboursement antérieur (`ekrefund_<id>` inexistant, `refunded` non vrai) ; (c) élément établissant que le service n'a pas été rendu ou n'est plus exigible, **vérifié côté serveur** (document de preuve immuable lié à la décision, au sujet, à la résolution) ; (d) état du client relu |
| **Contrôles financiers** | transaction, lectures avant écritures ; remboursement plafonné à `debitedAmount` ; solde client valide (`wallet` entier ≥ 0, comme `ekCancelOrderCF`) ; journal `ekrefund_<id>` créé une fois ; commande → `cancelled` avec `refunded:true` ; `audit_logs` strict |
| **Approbation** | **N2** (deux responsables indépendants, approbateur ≠ demandeur ≠ décideur initial s'il existe) |
| **Destination** | selon l'état du client, §2 ; **jamais** vers un profil anonymisé/absent |
| **Nouvelle transition** | `proof_sent → cancelled` n'existe pas aujourd'hui. Elle ne peut être faite que par un writer d'administration **à créer** (non autorisé ici) ; aucun nom de statut nouveau ; transition additive restreinte à ce writer. **[À CONFIRMER]** : le modèle `ekbine_orders` n'est pas migré, mais un plan est requis (règle projet : pas d'extension de la machine d'états sans plan) |
| **Effet sur la suppression** | une fois la commande `cancelled` et le dossier résolu (décision vérifiée), les inspecteurs ne voient plus d'obligation ; si le remboursement a créé un solde non nul sur un client fermé, la suppression reste bloquée par la régularisation de solde (`balance_regularization_required`) |

### 1.5 S3 — Substitution du bénéficiaire

| Rubrique | Contenu |
|---|---|
| **Principe** | le service a été rendu ; l'agent ne peut pas être payé ; la somme due est attribuée à un autre bénéficiaire vérifié |
| **Réserve forte** | le code ne contient **aucun** mécanisme de substitution Ekbine. La résolution `beneficiary_substituted` (N2) existe pour `beneficiary_account_closed` (claim `client_payment`), non pour Ekbine. Aucun bénéficiaire de substitution n'est défini par les règles. Rien n'est inventé ici |
| **Preuves** | commande `proof_sent` + preuve d'exécution vérifiée ; débit prouvé ; **identité du bénéficiaire de substitution établie** et vérifiée côté serveur (profil existant, non anonymisé, sans tombstone, éligible) ; concordance montant/commande ; accord de l'agent d'origine ou décision démontrant sa renonciation **[À CONFIRMER : aucune règle ne la définit]** |
| **Contrôles financiers** | crédit unique de `debitedAmount` vers le **seul** bénéficiaire de substitution validé ; journal dédié ; commande → `completed` avec `creditReason` explicite ; jamais le profil anonymisé/absent |
| **Approbation** | **N2** |
| **Effet sur la suppression** | dossier résolu seulement si l'inspecteur voit la commande terminale et la décision vérifiée |

Statut : **[À CONFIRMER]** et **[BLOQUANT]** : la définition du bénéficiaire de substitution et de la renonciation de l'agent est un choix métier non fait. Tant que ce choix manque, S3 reste indisponible (le dossier reste bloqué).

### 1.6 S4 — Règlement hors système

| Rubrique | Contenu |
|---|---|
| **Principe** | un paiement a été fait **en dehors** de la plateforme ; la plateforme l'enregistre sans bouger de portefeuille |
| **Preuves** | document de preuve **vérifié par le serveur, immuable**, avec : montant en XOF concordant avec la créance, identifiant de commande, identifiant du bénéficiaire, référence de paiement conforme (`ID_PATTERN`), empreinte `contentHash` (64 hex), `immutable:true` (modèle de `OUT_OF_SYSTEM_RESOLUTIONS`, `accountObligations.js:538-556`) ; une simple référence textuelle est insuffisante |
| **Contrôles financiers** | aucune écriture de portefeuille ; la commande passe à un statut terminal par un writer d'administration ; la preuve est comparée à la créance **calculée par le serveur**, pas à la décision |
| **Approbation** | **N2** + preuve vérifiée |
| **Réserve** | le moteur ne définit pas de résolution hors système pour Ekbine ; `RESOLUTIONS` ne contient que `debit_proven_and_settled`, `debit_disproved`, `refunded_by_ledger` pour les types Ekbine existants. Le calcul `matches` de `verifyDecision` exige un `beneficiaryId` dans la créance, aujourd'hui fourni seulement pour trois types. S4 Ekbine suppose donc une **extension du moteur** (non faite ici) |
| **Effet sur la suppression** | idem S3 |

Statut : **[À CONFIRMER]**, indisponible tant que le moteur et le registre de preuves ne le prévoient pas.

### 1.7 Synthèse X-3

| Issue | Argent déplacé | Niveau | Disponible aujourd'hui | Statut |
|---|---|---|---|---|
| S1 | non (le règlement est celui du chemin normal) | aucune décision financière | non (D-7 non implémenté) | RECOMMANDÉ, prioritaire |
| S2 | oui, vers le client | N2 | non (writer inexistant) | RECOMMANDÉ, à confirmer |
| S3 | oui, vers un tiers | N2 | non | À CONFIRMER, BLOQUANT |
| S4 | non | N2 + preuve | non | À CONFIRMER |
| N3 | — | — | **indisponible** | APPROUVÉ |

**Un seul super-admin** [APPROUVÉ] : il peut lire, instruire et rassembler les preuves ; il ne peut finaliser aucune opération N2 ; le dossier reste en attente et bloquant ; les comptes concernés ne sont pas supprimés. L'écriture directe en base pour contourner cette attente est interdite.

---

## 2. Remboursement d'un client fermé

Aucun crédit automatique vers un compte anonymisé ou absent [APPROUVÉ].

Définitions : **portefeuille** = crédit de `clients/{uid}.wallet` + journal ; **externe** = paiement hors plateforme, simplement **enregistré** avec preuve vérifiée (le système ne le fait pas) ; **revue manuelle** = dossier bloquant instruit par des humains.

| État du client | Portefeuille | Externe | Revue manuelle | Règle proposée [RECOMMANDÉ] |
|---|---|---|---|---|
| **Suppression demandée** (profil seul) | possible | — | — | traité comme un client actif : `ekCancelOrderCF` si la commande est annulable ; sinon S2 par writer d'administration |
| **Quarantaine** (tombstone `closing`) | **possible** par un writer serveur de catégorie C, **seulement** si le profil existe, non `isDeleted`, tombstone non `sealed` ; incrémentation de `epoch` dans la transaction ; D2 : le tombstone seul n'interdit pas le crédit | possible, N2 + preuve | oui | **voie préférée : D-7** (le client redevient actif). Sinon crédit portefeuille N2, suivi de la régularisation du solde avant toute suppression. **Constat** : `ekCancelOrderCF` est refusée par le wrapper pour un client tombstoné ; aucun écrivain administratif ne le remplace |
| **`sealed`** | **non** (aucune écriture après scellage, P3) | possible, N2 + preuve | oui | refus du crédit portefeuille ; retour à `closing` par la **récupération administrative** de P3 (N2 si `deleting:true`), puis traitement comme quarantaine ; à défaut, externe ou revue |
| **Anonymisé** (`isDeleted`) | **non, jamais** (D2, DR3) | possible, N2 + preuve vérifiée | oui | aucun crédit portefeuille ; règlement externe enregistré ou revue ; la preuve ne peut pas s'appuyer sur le profil anonymisé (données effacées) |
| **Absent** | **non, jamais** (≡ anonymisé, DR3) | idem | oui | idem |

Points communs : le remboursement ne dépasse jamais `debitedAmount` ; jamais deux fois ; en transaction ; journal `ekrefund_<orderId>` ; audit strict ; solde non valide ⇒ refus (`WALLET_INVALID`) et revue.

**Points ouverts [À CONFIRMER]** :
1. Un crédit sur le portefeuille d'un client en quarantaine crée un solde non nul qui bloque ensuite sa suppression (`inspect`, `balance_regularization_required`) et que le client ne peut pas retirer lui-même sous quarantaine (le wrapper refuse ses appels) : le circuit de régularisation d'un client en quarantaine n'est pas défini dans les sources lues. Voie D-7 d'abord.
2. Règlement externe vers un client anonymisé : comment établir qu'un tiers est le bon bénéficiaire sans données personnelles conservées, et quel organisme exécute le paiement externe, ne sont pas définis ; aucune règle ne l'autorise aujourd'hui.
3. Compatibilité avec D1/D2 de 7E-87 : D2 vise les crédits administratifs vers `isDeleted` (refus) et les autorise « pour tombstone seul » ; cette proposition est cohérente avec D2 mais **D2 n'a pas été confirmée pour Ekbine** (D5 D-8 : D1–D3 à confirmer par règle).

---

## 3. `ekbineAgentDepositAction`

### 3.1 Fonctionnement réel [FAIT]

Fichier `index.js:2130-2160`, enveloppé par `onCall` (donc `assertAccountEnabled`, tombstone de l'appelant lu **hors** transaction). Paramètres : `orderId`, `action` ∈ {`confirm`,`reject`,`start`}, `rejectionReason`.

Transaction : lecture de la commande et de `ekbine_agents/{uid}` en parallèle ; refus si l'un manque (`not-found`) ; refus si `order.agentId !== uid` ou `!isEligibleAgent(profil)` ; puis :
- `confirm` : si déjà `deposit_confirmed` → succès idempotent ; sinon exige `deposit_proof_sent` et `depositProofUrl` ;
- `reject` : exige `deposit_proof_sent` ;
- `start` : exige `deposit_confirmed` → `in_progress`.

Aucune écriture financière. Pas de relecture du tombstone dans la transaction. `isEligibleAgent` teste `deletionRequested`, `isDeleted`, `isVerified`, `isSuspended`, `subscriptionStatus`. Pas de limitation de débit. Pas d'audit.

### 3.2 Propositions [RECOMMANDÉ, À CONFIRMER]

| Contrôle | Proposition | Observation |
|---|---|---|
| **Tombstone dans la transaction** | `assertNewAccountActivity(tx, db, HttpsError, uid, [['ekbine_agents', uid]])` **au début** de la transaction, avant les lectures, comme `ekbineAcceptOrder` (`ekbineOrders.js:354`) | ferme la course entre la garde du wrapper et la pose du tombstone ; ce helper teste aussi `deletionRequested`/`isDeleted` du profil |
| **Identité** | `request.auth.uid` = `order.agentId` (existant) ; l'identifiant doit être sûr (`typeof` string, sans `/`) | `orderId` n'est validé que par `typeof string` : durcissement par `validOrderId` (déjà utilisé ailleurs) à proposer |
| **Rôle** | le profil est dans `ekbine_agents`, et dans aucune autre collection de rôle | non fait aujourd'hui par aucun chemin Ekbine ; cohérent avec `multiple_roles_manual_review` ; **à confirmer** |
| **Agent bénéficiaire** | `isEligibleAgent` conservé ; refus si `isDeleted` ou profil absent (`not-found`) | déjà le cas |
| **Anonymisation / absent** | refus explicite sans écriture | déjà le cas pour absent et pour `isDeleted` (via `isEligibleAgent`) |
| **Client de la commande fermé** | **proposition à confirmer** : lire l'état du client (tombstone, `isDeleted`) et refuser `start` si le client est `sealed` ou anonymisé (on ne démarre pas l'exécution d'une prestation dont la confirmation ne peut plus être faite) | non demandé explicitement ; élargit le contrôle ; aucune règle approuvée |
| **Doubles opérations** | transaction Firestore (relecture à chaque tentative) + vérification de statut : `confirm` déjà fait ⇒ succès sans réécriture ; `reject` et `start` répétés ⇒ `failed-precondition` | **suffisant** pour l'atomicité ; la limitation de débit (`checkRateLimit`) peut être ajoutée pour l'abus, hors sécurité financière |
| **Audit** | ligne d'audit **dans** la transaction pour `confirm`/`reject`/`start` (identifiants techniques seulement) | aucune trace aujourd'hui |

**Classification** (catégorie A ou B) [À CONFIRMER] : défaut conservateur **refus pour un agent fermé** pour les trois actions (cohérent avec `isEligibleAgent` actuel et 7E-73). Conséquence assumée : un agent fermé ne fait plus avancer ses commandes, qui basculent vers X-3.

Aucune fonction n'est modifiée par la présente mission.

---

## 4. Traçabilité des confirmations refusées

### 4.1 Situation [FAIT]

Quand `ekClientConfirmOrder` refuse (bénéficiaire fermé ou absent), l'erreur est levée à l'intérieur de la transaction (`ekbineOrders.js:304, 309`) ; la transaction est annulée ; **aucune trace** n'est écrite.

### 4.2 Journal proposé [RECOMMANDÉ, À CONFIRMER]

**Journal d'audit, distinct de toute écriture financière et distinct du dossier bloquant (§5).** Il ne bloque pas la suppression par lui-même.

| Élément | Proposition |
|---|---|
| Support | `audit_logs` (écriture réservée aux Cloud Functions : `allow write: if false`, **aucune modification de règle**) |
| Identifiant | déterministe : `ekconfirm_refused_<orderId>_<codeRaison>` ; écriture en **création seule** (`create`) ; un second refus identique est absorbé sans erreur visible au client |
| Contenu | `action: 'ekbine_confirm_refused'`, `targetId: orderId`, `userId` = id technique du client, `userType: 'client'`, `status: 'refused'`, `metadata: { reason, agentId, agentState, amount (XOF), currency: 'XOF' }`, `createdAt` horodatage serveur |
| Raison (énumération fermée) | `beneficiary_absent`, `beneficiary_anonymized`, `beneficiary_closing`, `beneficiary_deletion_requested`, `actor_closed` (si X-2 refuse l'acteur) |
| Données personnelles | aucune : ni nom, ni téléphone, ni jeton, ni URL de preuve ; identifiants techniques et codes seulement |
| Mode d'écriture | **strict** (variante qui propage l'erreur, comme `auditStrict` de `accountDeletion.js`), pas `logAudit` qui avale les erreurs (`index.js:300-312`) |
| Condition d'émission | seulement **après** avoir établi, par une lecture séparée, que l'appelant est le client de la commande et que son statut est `proof_sent` ; sinon n'importe quel appelant pourrait remplir le journal |
| Limitation | `checkRateLimit` existant conservé ; un seul document par couple (commande, raison) borne le volume |

Séparation : le refus (aucun mouvement d'argent) **ne partage aucune transaction** avec une écriture financière ; la trace d'un refus ne peut pas annuler ni valider un règlement.

### 4.3 Risques d'une écriture hors transaction

| Risque | Conséquence | Atténuation |
|---|---|---|
| Interruption de l'instance après le refus et avant la trace | trace perdue | l'état durable (`proof_sent` + agent fermé) subsiste ; le client peut réessayer ; une analyse périodique des commandes `proof_sent` avec agent fermé constituerait le filet de sécurité (**nouveau mécanisme non proposé ici, à décider**) |
| Échec de l'écriture de la trace | refus sans trace | l'erreur d'origine est renvoyée au client ; l'échec de la trace est signalé (journal technique) ; **jamais** transformé en succès |
| Trace écrite sans que le refus soit définitif (course : l'agent redevient éligible entre-temps) | trace inutile mais inoffensive | la trace est informative ; elle ne bloque rien |
| Attaque par répétition | spam d'écritures | identifiant déterministe en création seule + limitation de débit |
| Perte de traçabilité si le client n'essaie jamais | aucune trace | c'est une limite assumée de ce journal ; le dossier de §5 est la protection de fond |

---

## 5. Type de dossier `ekbine_order_blocked`

Distinct de `beneficiary_account_closed` [FAIT : ce type a le claim `client_payment` et des résolutions `payment_completed` N1 / `beneficiary_substituted` N2, inadaptées à Ekbine]. **`accountObligations.js` n'est pas modifié par cette mission.**

### 5.1 Schéma proposé [RECOMMANDÉ, À CONFIRMER]

Support : `reconciliation_flags/ekblocked_<orderId>` (un dossier par commande, création seule).

| Champ | Contenu | Remarque |
|---|---|---|
| `kind` | `'ekbine_order_blocked'` | lu par `flagTypeLabel` ; **inconnu aujourd'hui ⇒ `other`** |
| `status` | `'open'` ; ultérieurement `contested`/`resolved` | `open` = bloquant (revue) |
| **origine** | `origin: 'ekClientConfirmOrder_refusal'`, `originSource: 'server'`, `originAtMs` | origine **serveur** ; aucun décideur humain initial ⇒ pas de `decidedBy` ; **à confirmer** si le type doit entrer dans la liste de décideur initial |
| **référence de commande** | `orderId` | |
| **montant et devise** | `amount` (entier XOF, = `debitedAmount`), `currency: 'XOF'` | `amount` est lu par `evaluateFlag` |
| **bénéficiaire** | `beneficiaryId` = `agentId`, `beneficiaryRole: 'ekbine_agent'`, `beneficiaryState` (`absent`/`anonymized`/`closing`/`deletionRequested`) | |
| **parties** | `clientId` (clé reconnue par le moteur pour lier le dossier au compte du client) ; l'agent (`agentId`) n'est **pas** une clé de lien du moteur | l'agent reste couvert par le blocage de la commande non terminale (inspecteurs) ; ajouter une clé de lien serait une modification du moteur **[À CONFIRMER]** |
| **motif** | `reason` (énumération fermée, §4.2) | |
| **preuves** | `evidence`: références (`ekorder_<id>`, présence/absence de `ekrefund_<id>`, état de l'agent relu, `debitedAmount`), immuables, jamais une URL fournie par un client | |
| **approbations** | portées par le **registre de décisions** (`resolutionDecisionId`, `resolutionRequestId`, `resolvedBy`, niveau, approbateur), pas par le dossier lui-même | |
| **résolution** | `resolution` ∈ {`s1_agent_reinstated_and_confirmed`, `s2_refunded_client`, `s3_substituted_beneficiary`, `s4_paid_out_of_system`} (noms proposés), `resolvedAtMs` | non reconnues aujourd'hui |

### 5.2 Fail-closed

Règles de lecture proposées, dont deux sont **déjà vraies** avec le moteur actuel [FAIT] :
- statut absent ou illisible ⇒ ambigu, bloquant (déjà) ;
- aucune clé de partie ⇒ ambigu, bloquant (déjà) ;
- `kind` inconnu ⇒ `other`, aucune résolution autorisée, dossier bloquant (déjà) ;
- statut `open` ⇒ revue, bloquant (déjà) ;
- `resolved` sans champs de trace complets ⇒ ambigu (déjà) ;
- **à ajouter** (proposition) : champ obligatoire manquant (`orderId`, `amount` entier > 0, `currency` ≠ `'XOF'`, `beneficiaryId`, `reason` hors énumération, preuve absente ou non immuable, montant incohérent avec la commande) ⇒ **bloquant** ;
- une résolution n'est acceptée que si la décision est `executed`, du niveau requis (N2), `remaining` = 0, approbateur ≠ demandeur, et preuve `verified` liée (mécanisme de `verifyDecision`).

Conséquence : tant que le moteur n'est pas étendu, un tel dossier **ne peut jamais être résolu**, donc **bloque** sa partie : c'est le comportement voulu avant implémentation.

### 5.3 Ce qu'il faudra changer plus tard (non fait ici)

Extension de `FLAG_TYPES`, `FLAG_CLAIM` (claim `ekbine_debit`), `RESOLUTIONS` (niveaux), éventuellement `partyKeys` (agent), `OUT_OF_SYSTEM_RESOLUTIONS` ; tests du moteur ; écrivain serveur du dossier ; registre de décisions/preuves en collections Cloud-Function-only. Tout cela exige une autorisation d'implémentation.

---

## 6. Synthèse

### 6.1 Classement des décisions

| # | Décision | Classement |
|---|---|---|
| 1 | 7E-73 prévaut sur 7E-87 D3 ; agent fermé ne valide pas | APPROUVÉ (2D-2A.7) |
| 2 | Exception X-2 : `ekClientConfirmOrder` en 5ᵉ exception, C1–C13 | APPROUVÉ (2D-2A.8) ; **non implémentée** |
| 3 | Règles de X-3 (aucun crédit forcé, N2 pour S2–S4, N3 indisponible, super-admin seul ⇒ attente, pas de suppression avec obligation, pas d'écriture directe, pas de séquestre inventé) | APPROUVÉ (présente mission) |
| 4 | S1 comme voie prioritaire (D-7) | RECOMMANDÉ |
| 5 | S2 (remboursement) | RECOMMANDÉ, à confirmer (writer et transition à créer) |
| 6 | S3 (substitution) | À CONFIRMER, **BLOQUANT** (bénéficiaire de substitution non défini) |
| 7 | S4 (hors système) | À CONFIRMER (extension du moteur) |
| 8 | Qui peut annuler la demande de suppression d'un agent | À CONFIRMER, **BLOQUANT** pour S1 |
| 9 | Règles de remboursement par état du client (§2) | RECOMMANDÉ ; circuit de régularisation d'un client en quarantaine : À CONFIRMER |
| 10 | Règlement externe vers un client anonymisé/absent | À CONFIRMER, **BLOQUANT** |
| 11 | Garde de tombstone en transaction pour `ekbineAgentDepositAction` | RECOMMANDÉ |
| 12 | Contrôle de l'état du client dans `start` ; contrôle multi-rôles | À CONFIRMER |
| 13 | Journal d'audit des refus (`audit_logs`, création seule, strict) | RECOMMANDÉ |
| 14 | Filet de sécurité périodique contre la perte de trace | À CONFIRMER (nouveau mécanisme) |
| 15 | Type `ekbine_order_blocked` (schéma, fail-closed) | RECOMMANDÉ ; extension du moteur BLOQUANTE avant résolution |
| 16 | Clé de lien du dossier pour l'agent | À CONFIRMER |
| 17 | Valeur de `partnerInventoryVersion` | **BLOQUANT** pour dimensionner X-3 (lecture à autoriser séparément) |
| 18 | Second responsable indépendant pour N2 | **BLOQUANT** pour toute résolution N2 |

### 6.2 Faits, propositions, hypothèses

- **Faits** vérifiés : §0 (6 faits), §3.1 (fonctionnement), §4.1 (aucune trace), §5.2 (comportement fail-closed existant).
- **Propositions** : S1–S4 détaillées, règles §2, contrôles §3.2, journal §4.2, schéma §5.1.
- **Hypothèses** non vérifiées : valeur de `partnerInventoryVersion` ; existence d'agents Ekbine dans un état `deletionRequested` avec commande `proof_sent` en production ; comportement de l'application client sur un refus ; absence d'un circuit de retrait pour un client en quarantaine (non trouvé dans les sources lues, non exhaustivement recherché).

### 6.3 Contradictions et tensions

| # | Constat | Avec |
|---|---|---|
| K-1 | Aucune contradiction avec X-1 (agent fermé refusé) ni X-2 (exception limitée à la confirmation) : S1–S4 n'ouvrent aucun crédit automatique vers un agent fermé | 7E-73 ; 2D-2A.7/.8 |
| K-2 | S3 (substitution) revient à payer un autre bénéficiaire que l'agent de la commande ; 7E-87 D3 recommandait de créditer l'agent lui-même ; D3 est écartée pour Ekbine mais **aucune source n'autorise un tiers** | 7E-87 D3 ; à confirmer |
| K-3 | 7E-73 écrit que les commandes engagées restent inchangées ; or le code les rend aujourd'hui impossibles à terminer par un client tombstoné (wrapper) | 7E-73 ↔ code ; levé en principe par X-2 (non implémenté) |
| K-4 | 7E-97 D6 « définitives » avec liste de quatre fonctions ; X-2 la porte à cinq : modification approuvée mais non répercutée dans les documents antérieurs, inchangés par règle | 7E-97 ↔ 2D-2A.8 |
| K-5 | D2 (7E-87) autorise un crédit vers un tombstone seul ; or l'impossibilité de retrait d'un client en quarantaine rend ce crédit potentiellement bloquant | 7E-87 D2 ↔ §2 point 1 |
| K-6 | `agentId` n'est pas une clé de lien du moteur : un dossier côté agent n'est pas vu par le moteur (il l'est par les inspecteurs via la commande) | `accountObligations.js` ↔ §5.1 |
| K-7 | La transition `proof_sent → cancelled` n'existe pas ; la règle projet interdit d'étendre une machine d'états sans plan | CLAUDE.md ↔ S2 |

### 6.4 Risques financiers

1. Fonds client débités et non attribués tant qu'une commande `proof_sent` reste bloquée, **sans compte séquestre** ni écriture comptable dédiée : visibilité uniquement par la commande.
2. Agent non payé pour un service rendu (S3/S4 indisponibles).
3. Remboursement sur le portefeuille d'un client en quarantaine : solde non retirable (point 1 du §2).
4. Résolution par écriture directe si les voies N2 restent indisponibles : interdite, mais tentante.
5. Perte de trace d'un refus (§4.3).
6. Dossier non résoluble tant que le moteur n'est pas étendu : blocage durable des comptes concernés (conséquence voulue).
7. Un seul super-admin : dossiers N2 durablement en attente.
8. Gardes Ekbine non commitées (absentes de HEAD) : à préserver par indexation par hunks.

### 6.5 Prérequis avant toute implémentation

1. Décisions humaines sur les points `À CONFIRMER`/`BLOQUANT` du §6.1 (8, 10, 6, 17, 18 en priorité).
2. Lecture de `partnerInventoryVersion`, par autorisation séparée (aucun accès distant ici).
3. Lots d'infrastructure de P3 (champs de tombstone, `assertClosureActor`, `onCallClosing` limité à cinq).
4. Extension additive du moteur et son test, après autorisation.
5. Writer d'administration Ekbine (S2–S4) avec registre de décisions/preuves.
6. Plan de tests complet ; les résultats d'émulateur ne sont pas une preuve de production.
7. Aucun déploiement ; préproduction seulement sur `az-express-preprod` après autorisation séparée ; production exclue.

Je m'arrête ici. Aucun code n'est écrit, aucune décision n'est transformée en approbation au-delà de ce qui est marqué.
