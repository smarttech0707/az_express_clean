# 2D-2A.7 — Arbitrage final E-Kbine (X-1, X-2, X-3 et points associés)

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document d'arbitrage uniquement : aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, accès distant, opération Firebase, commit, push, déploiement ni nettoyage du worktree ; aucun document existant modifié ; aucun lot L0–L8 commencé. Analyse **statique** : aucune fonction exécutée.

Sources : 2D-2A.6 (**P6**), 2D-2A.5 (**D5**), 7E-73, 7E-87, 7E-97 ; code lu en lecture seule : `functions/index.js` (wrapper `onCall` l.83-90, exports Ekbine), `ekbineOrders.js`, `ekbineFlow.js`, `accountAdmission.js`, `accountDeletion.js`, `partnerAccountDeletion.js`, `accountObligations.js` (types de flags, `RESOLUTIONS`), `ekbineReconciliation.js`.

## 0. Statuts et corrections

| Marqueur | Sens |
|---|---|
| **[ARBITRÉ]** | formulé par la mission 2D-2A.7 comme arbitrage ; à reporter tel quel dans le registre des décisions |
| **[RETENU]** | proposition de ce document, conforme aux conditions minimales de la mission, **à valider formellement par le propriétaire avant toute implémentation** (aucune recommandation n'est ici une décision approuvée) |
| **[CODE]** | comportement observé dans le code lu |
| **[OUVERT]** | décision manquante ; le cas reste **bloqué** ou **en revue** en attendant |

**Corrections de P6, constatées en relisant le code :**
1. P6 §4 affirmait que `ekbineAgentDepositAction` n'a « aucune garde en transaction ». **Inexact** : la transaction relit le profil agent et applique `isEligibleAgent` (`index.js:2130-2150`), qui teste `deletionRequested`, `isDeleted`, `isSuspended`. Ce qui manque est la **relecture du tombstone** (`assertNewAccountActivity`). La protection effective dépend donc des drapeaux de profil posés par le traitement de suppression (voir §6).
2. P6 §7.3 (X-3) ne précisait pas que la suppression d'un agent Ekbine n'est traitée que par le chemin partenaires, actif seulement si `operations_control/account_deletion.partnerInventoryVersion === 1` (voir §7).

---

## 1. X-1 — Confirmation client et crédit agent **[ARBITRÉ]**

| # | Règle | Fondement |
|---|---|---|
| X1-a | **7E-73 prévaut sur 7E-87 D3.** D3 (créditer l'agent en quarantaine sauf `isDeleted`) n'est pas retenue pour Ekbine. | mission 2D-2A.7 |
| X1-b | Un agent en quarantaine **ne peut pas valider** (faire aboutir) une confirmation client : la confirmation est refusée tant que le bénéficiaire est fermé. | 7E-73 §1 ; [CODE] `ekbineOrders.js:309` |
| X1-c | **Aucun crédit automatique** vers un profil anonymisé (`isDeleted`) ou absent. | consigne ; [CODE] `not-found` (profil absent) et garde (anonymisé) |
| X1-d | **Confirmation client ≠ règlement d'une obligation.** La confirmation est une déclaration du client ; le règlement est un mouvement d'argent sur un portefeuille. Leur couplage dans une seule transaction est un état du code, pas un principe : toute évolution qui les séparerait (terminer sans crédit) exige une décision distincte. | P6 §2 ; 7E-72 §5 (alternative non retenue) |

Conséquences :
- La confirmation reste **atomique** : si le règlement n'est pas permis, rien n'est écrit et la commande reste `proof_sent`.
- D5 D-8 (« D3 à confirmer, arbitrage D3 / 7E-73 ») est **levée pour Ekbine** par X1-a. D1, D2, DR1–DR3 ne sont pas concernées.
- D3 reste historiquement valable pour ce qu'elle traitait hors Ekbine (aucune autre fonction ne la reprend).

---

## 2. X-2 — Client en quarantaine : terminer une commande déjà engagée

### 2.1 Situation actuelle [CODE]

Chemin d'une confirmation par un client sous tombstone :
1. `ekClientConfirmOrder` est construit avec `onCall: (h) => onCall({ maxInstances: 2, cpu: 0.5 }, h)` (`index.js:2032-2034`) → le wrapper local appelle `assertAccountEnabled` **avant** le gestionnaire (`index.js:85-90`) → `permission-denied ACCOUNT_DELETION_IN_PROGRESS`. Le gestionnaire n'est jamais atteint.
2. Même chose pour `ekCancelOrderCF` et `ekbineSubmitDepositProof`.
3. Un client avec **`deletionRequested` seul** (sans tombstone) **n'est pas bloqué** : le wrapper ne lit pas le profil, et le gestionnaire de confirmation ne lit pas le profil client. Il peut aujourd'hui confirmer.

### 2.2 Pourquoi « ajouter à `onCallClosing` » ne suffit pas

`onCallClosing` n'existe pas dans le code (aucune occurrence). Sa spécification (7E-97 §5, §6) n'est valable que **avec** `assertClosureActor` et les contrôles de bénéficiaires dans la transaction. Dans `buildEkClientConfirmOrder`, **si on retirait seulement le contrôle du wrapper**, le gestionnaire exécuterait ceci :

| Contrôle | Présent dans le gestionnaire ? | Effet si le wrapper est levé |
|---|---|---|
| Appelant = `order.clientId` | oui (l.298) | suffisant pour le propriétaire, **pas** pour l'état du compte |
| Profil client existe, non `isDeleted` | **non** (le profil client n'est pas lu) | un client **anonymisé** dont le jeton est encore valide (désactivation Auth réversible, jeton non expiré) confirmerait |
| Tombstone du client : phase `closing` seulement | **non** | un client **scellé** (`sealed`) ou en suppression (`deleting`) confirmerait ; le protocole P3 interdit toute écriture après scellage |
| Époque (`epoch`) du tombstone incrémentée | **non** (champ non encore créé) | le snapshot d'inspection serait périmé sans le savoir (P3 §3) |
| Engagement **avant** la quarantaine | **non** | une commande engagée après la quarantaine serait terminable |
| Agent bénéficiaire fermé/absent | **oui** (l.304, l.309) | conservé |
| Statut `proof_sent` | oui (l.300) | conservé |
| Preuve de débit | oui, via `creditFor` ; le cas « débit non prouvé » **crée un flag** et termine la commande | pour un client fermé, crée une nouvelle créance : à refuser (§2.4) |
| Limite de débit `checkRateLimit` | oui, hors transaction | sans effet sur la sécurité |
| Écritures du gestionnaire | commande, **portefeuille de l'agent**, `audit_logs`, éventuel flag | aucune écriture sur le client lui-même |

Donc la levée du wrapper seule ouvrirait trois chemins interdits : client anonymisé, client scellé, et commande engagée après la quarantaine. Il faut, **dans la transaction, avant toute écriture**, un contrôle d'acteur de type `assertClosureActor` (non implémenté) en plus de la garde existante sur le bénéficiaire.

### 2.3 Fenêtre réelle de ce cas

Le client est inspecté avant le tombstone : la présence d'une commande Ekbine non terminale bloque la quarantaine (`accountDeletion.js:46-51`, relecture dans la transaction de pose). Le cas « quarantaine + commande engagée » ne se produit donc que par :
- une commande engagée **après** l'inspection mais avant la pose du tombstone (course) ; ou
- une commande créée par l'écriture directe client autorisée par les règles (P6 §8 #2) ; ou
- un état résiduel historique.

Il n'existe pas d'acceptation d'une commande par un agent qui relise l'état du client (`ekbineAcceptOrder` ne garde que l'agent) : une commande `pending` d'un client fermé reste acceptable. Cette population est **petite**, ce qui limite le bénéfice de l'exception. Ordre de préférence **[RETENU]** :

1. **D-7 (D5)** : annulation de la demande de suppression avant `sealed`, sous nouvelle inspection ; le client redevient actif et confirme normalement. Aucune exception de wrapper.
2. **Exception X-2** (ci-dessous), uniquement si le propriétaire veut que la quarantaine soit conservée pendant la clôture.
3. À défaut : X-3 (revue administrative).

### 2.4 Exception X-2 : conditions **[RETENU]**

Portée : **une seule fonction**, `ekClientConfirmOrder`. L'extension de la « liste fermée de 4 » de 7E-97 §5 à une 5ᵉ fonction est une modification d'une décision déclarée définitive (D6) : **elle exige la décision explicite du propriétaire** **[OUVERT]**. `ekCancelOrderCF` et `ekbineSubmitDepositProof` ne sont pas incluses (§2.5).

Conditions minimales de la mission, plus les compléments déduits du code (marqués +) :

| # | Condition | Où | Détail |
|---|---|---|---|
| C1 | Commande engagée **avant** la quarantaine | transaction | `order.assignedAt` (horodatage serveur posé par `ekbineAcceptOrder`) strictement antérieur à `tombstone.createdAt` ; absence ou valeur non-Timestamp ⇒ refus. + Limite : si l'agent a écrit `proof_sent` par règles, `assignedAt` reste celui de l'acceptation ; une commande créée directement par le client sans acceptation serveur n'a pas `assignedAt` ⇒ refus. |
| C2 | **Aucune nouvelle commande** | structurel | l'exception ne couvre pas `ekCreateOrderCF` ni l'écriture directe (bloquée par `isAuth()` sous tombstone) ; +  test de câblage |
| C3 | **Rôle** | transaction | l'identité est dans `clients/{uid}`, et dans aucune autre collection de rôle (cohérent avec `multiple_roles_manual_review`) |
| C4 | **Identité** | transaction | `order.clientId === uid` (existant) ; `uid` du jeton = id du tombstone relu |
| C5 | **Statut du client** | transaction | tombstone **existe**, `phase` ∈ {absent (état actuel `deleting` à 2D), `closing`} ; **refus** si `sealed`, si `deleting:true` côté P3, ou si `isDeleted` ; profil client existant ; + vérifie que le Auth n'est pas déjà supprimé (`authDeletedAtMs` absent) |
| C6 | **Statut de la commande** | transaction | `proof_sent` uniquement (existant) |
| C7 | **Bénéficiaire** | transaction | agent existant, non anonymisé, **sans** tombstone, **sans** `deletionRequested` : c'est la garde actuelle `assertNewAccountActivity(agent)` **conservée à l'identique** ; aucune exception pour un agent anonymisé ou absent |
| C8 | **Aucune confirmation interdite à l'agent** | transaction | si l'agent ne peut pas être crédité, la confirmation est refusée en entier (X1-b) ; aucune terminaison « sans crédit » |
| C9 | + **Preuve financière** | transaction | exception limitée à `provenDebit(order)` (débit AZ prouvé) ou `paymentMethod !== 'wallet'` ; **débit non prouvé ⇒ refus** (créerait un flag, c'est-à-dire une nouvelle créance dans un compte fermé) ; en outre relecture du journal `ekorder_<orderId>` conforme au montant [OUVERT : contrôle supplémentaire] |
| C10 | + **Époque** | transaction | incrémentation de `tombstone.epoch` dans la même transaction (writer de catégorie B, P3) ; lecture `epoch` avant écriture |
| C11 | + **Audit** | transaction | ligne `audit_logs` dans la transaction avec indicateur `closureDuringQuarantine:true`, sans donnée personnelle |
| C12 | + **Pas d'effet de bord sur le client** | transaction | aucune écriture sur `clients/{uid}` (profil/portefeuille) ; seul le portefeuille de l'agent change |
| C13 | + **Liste fermée testée** | test | test de câblage : `onCallClosing` n'est utilisé que pour les fonctions de la liste approuvée |

Refus attendus (tous sans écriture) : client anonymisé, scellé, ou sans profil ; commande postérieure à la quarantaine ; agent fermé ou absent ; débit non prouvé ; statut ≠ `proof_sent`.

### 2.5 Fonctions écartées

| Fonction | Décision | Motif |
|---|---|---|
| `ekCancelOrderCF` | **non incluse** [RETENU] | catégorie C (remboursement) vers le portefeuille d'un compte en fermeture ; un solde non nul bloque ensuite la suppression (`inspect`, `balance_regularization_required`) ; relève de D1/D2 (refus pour `isDeleted`, permis pour tombstone seul) : décision séparée [OUVERT] |
| `ekbineSubmitDepositProof` | **non incluse** | ne termine pas la commande ; ne réduit pas l'engagement |
| `ekbineAgentDepositAction` | **hors périmètre client** | action d'agent ; voir §6 |

---

## 3. X-3 — Commande `proof_sent` bloquée : revue administrative distincte

### 3.1 Constat [CODE]

- Aucun writer d'administration ne règle une commande Ekbine : `ekbineReconciliation.js` n'exporte que `analyzeLegacyEkOrders` et `isServerProcessed` (analyse, pas de correction). Seule l'écriture directe d'un administrateur (`firestore.rules:909`, `isAdmin()`) existe, hors protocole financier.
- Les types de flags Ekbine existants (`ekbine_cancel_unproven_debit`, `ekbine_confirm_unproven_debit`) ne couvrent que le **débit non prouvé**. Une commande à débit **prouvé** bloquée par un agent fermé n'a **aucun type de dossier**.
- `beneficiary_account_closed` existe (résolutions `payment_completed` N1, `beneficiary_substituted` N2) mais son **claim est `client_payment`** (`accountObligations.js:217`), pas `ekbine_debit`. Le réutiliser pour Ekbine fausserait le sens du dossier **[OUVERT]**.
- L'engin bloque la suppression tant qu'une commande Ekbine du compte est non terminale (inspecteurs).

### 3.2 Procédure proposée **[RETENU — conception, aucun code]**

**Principes** : aucune libération automatique ; aucun crédit forcé ; aucune quarantaine levée ; le dossier reste **bloquant** tant qu'une sortie n'est pas atteinte ; la décision est tracée.

**Étape 0 — Ouverture du dossier** (serveur, jamais par le client) : après un refus de confirmation pour bénéficiaire fermé (voir §5), création idempotente d'un dossier de revue `ekbine_order_blocked` (nouveau type additif **proposé**, claim `ekbine_debit`), identifié par `ekbeneficiary_<orderId>`, contenant uniquement des identifiants techniques et le montant prouvé.

**Étape 1 — Instruction** (lecture seule, tout administrateur autorisé) : constitution des preuves **vérifiables côté serveur** :
- journal de débit client `ekorder_<orderId>` lu et conforme au montant (`provenDebit`) ;
- absence de remboursement (`ekrefund_<orderId>` inexistant, `refunded` non vrai) ;
- état de l'agent (existe, anonymisé, tombstone, `deletionRequested`) ;
- preuve d'exécution du service : `proof_sent` + éléments d'exécution de la commande. Une simple référence textuelle n'est **jamais** une preuve (règle du moteur, `OUT_OF_SYSTEM_RESOLUTIONS`).

**Étape 2 — Sorties possibles** (aucune n'est automatique) :

| Sortie | Condition | Niveau | Effet |
|---|---|---|---|
| **S1** Rétablissement de l'agent puis confirmation normale | l'agent annule sa demande avant `sealed` (D-7) et est de nouveau éligible ; le client confirme lui-même | aucune décision financière | la commande se termine par le chemin normal ; le dossier est clos par vérification du résultat |
| **S2** Annulation avec remboursement du client | service non rendu (preuve d'exécution absente ou contestée) ; client non anonymisé et existant | **N2** (deux responsables indépendants) | remboursement d'exactement `debitedAmount` via journal `ekrefund_<orderId>`, une fois ; si le client est anonymisé ou absent : **aucun crédit portefeuille** |
| **S3** Substitution du bénéficiaire | service rendu, agent fermé ; bénéficiaire de substitution vérifié | **N2** | équivalent de `beneficiary_substituted` ; jamais un crédit vers le profil anonymisé |
| **S4** Règlement hors système | preuve de paiement vérifiée côté serveur, montant et bénéficiaire concordants | **N2** + preuve | équivalent des règlements `*_out_of_system` |
| Abandon de créance | — | **N3 : indisponible** | `flag_level3_unavailable` (7E-107) |

Aucune sortie ne crédite un compte `isDeleted` ou absent (X1-c) ; DR3 : profil absent traité comme anonymisé.

**Étape 3 — Clôture** : le dossier ne passe à « résolu » que si l'inspecteur constate, après la sortie, que la commande est terminale **et** que le dossier est résolu par une décision vérifiée (`verifyDecision`). Sinon il reste bloquant.

### 3.3 Ce qui est possible avec **un seul super-admin**

Décision de référence : un seul super-admin ; N2 exige **deux** responsables indépendants (7E-102 → 7E-107).

| Action | Faisable seul ? |
|---|---|
| Lire, instruire, rassembler les preuves (étape 1) | **oui** |
| Ouvrir/commenter le dossier de revue | oui (trace) |
| **S1** (rétablissement + confirmation par le client) | **oui** pour la part administrative (information de l'agent) ; l'annulation de la demande est un acte du titulaire du compte, non de l'admin **[OUVERT : qui peut annuler une demande d'un agent]** |
| **S2, S3, S4** (N2) | **non** : aucun second responsable indépendant ; le dossier reste **bloqué** |
| N3 | non (indisponible) |
| Écriture Firestore directe pour « débloquer » | **à proscrire** : hors protocole, sans preuve, sans second responsable ; elle contournerait les contrôles de sécurité |

Conséquence : **tant qu'un second responsable indépendant n'existe pas**, tout dossier X-3 nécessitant N2 reste bloqué, et la suppression des comptes concernés reste refusée. C'est le comportement voulu (« aucune suppression si une obligation reste non résolue »).

### 3.4 Garantie « aucune suppression avec obligation non résolue »

- Tant que la commande est non terminale, l'inspecteur client (`accountDeletion.js:46-51`) et l'inspecteur partenaire (`accountDeletionScope.js:42-44`) refusent la suppression : **[CODE]** déjà vrai.
- Le futur dossier `ekbine_order_blocked` doit être ajouté à la liste des types bloquants du moteur (additif) et à `ORIGIN_DECIDER_REQUIRED` s'il enregistre un décideur initial humain.

---

## 4. Séparation des niveaux : règle, code, proposition

| Sujet | Règle métier (décidée) | Code actuel | Proposition |
|---|---|---|---|
| Confirmation vs règlement | X1-d | couplés en transaction | inchangé |
| Agent fermé ne reçoit rien | 7E-73, X1-b | refus (garde non commitée) | conserver la garde |
| Crédit vers anonymisé/absent | interdit (consigne) | refus | idem |
| Client fermé confirme | **aucune** règle commune ; 7E-72/73 la supposent | **refusé** par le wrapper | exception X-2 (§2.4) ou D-7 |
| Liste `onCallClosing` | 4 fonctions (7E-97) | n'existe pas | extension à 5 = décision [OUVERT] |
| Dossier de commande bloquée | aucune | aucun type, aucun writer | type additif + N2 (§3) |
| Trace d'un refus | aucune | aucune | §5 |
| Tombstone en transaction (`ekbineAgentDepositAction`) | aucune | profil seulement | §6 |

---

## 5. Trace des confirmations refusées **[RETENU, à valider]**

- **Aujourd'hui** : le refus lève une erreur avant toute écriture ; **rien n'est tracé** (`ekbineOrders.js:304-309`).
- La trace ne peut pas être écrite dans la transaction qui échoue (annulation). Elle doit l'être **après** l'échec, hors transaction, de façon **idempotente**, comme D6-a.
- Conditions : (1) **uniquement** si le refus provient de l'état du bénéficiaire, après avoir établi que l'appelant est le client de la commande et que la commande est `proof_sent` (sinon un tiers pourrait créer des dossiers) ; (2) identifiant déterministe (`ekbeneficiary_<orderId>`) et écriture en création seule (jamais d'écrasement d'un dossier déjà décidé) ; (3) limitation de débit existante conservée ; (4) échec d'écriture de la trace : le refus reste, l'erreur n'est pas masquée en succès ; (5) aucun nom, numéro ni jeton.
- Contenu : `orderId`, `clientId`, `agentId`, montant prouvé, état constaté du bénéficiaire (`closing|sealed|deleted|absent|deletionRequested`), horodatage serveur.
- Réutilisation de `beneficiary_account_closed` : **déconseillée** (claim `client_payment`) ; type additif `ekbine_order_blocked` préféré **[OUVERT]**.

---

## 6. Protection transactionnelle de `ekbineAgentDepositAction`

**[CODE]** Transaction avec relecture du profil agent et `isEligibleAgent` ; **pas** de relecture du tombstone ; protection du wrapper hors transaction (`index.js:83-90`).

Lecture du risque : une quarantaine posée entre le contrôle du wrapper et l'écriture n'est vue **que si** les drapeaux de profil (`deletionRequested`, `isSuspended`) sont posés dans la même transaction de quarantaine. C'est le cas dans le chemin partenaires (`partnerAccountDeletion.js:34`) et dans le chemin client/livreur pour `isSuspended` (`accountDeletion.js:88`) ; mais le chemin agent Ekbine n'existe que si `partnerInventoryVersion === 1` (§7).

**Proposition [RETENU]** : ajouter `assertNewAccountActivity(tx, db, HttpsError, agentId, [['ekbine_agents', agentId]])` **au début** de la transaction, avant les lectures, pour les trois actions (`confirm`, `reject`, `start`), de la même manière que `ekbineAcceptOrder` (`ekbineOrders.js:354`). Classification : action d'agent sur une commande **déjà engagée**, donc catégorie B ou A **[OUVERT]** ; défaut **conservateur** : refus pour agent fermé (cohérent avec `isEligibleAgent` actuel). Conséquence assumée : un agent fermé ne fait plus avancer ses commandes, qui basculent vers X-3.

Aucune modification n'est faite ici.

---

## 7. Préservation des gardes Ekbine non commitées

**[CODE]** Les gardes de 7E-68/7E-72 (acceptation l.354, confirmation l.309, création l.148) sont dans `functions/ekbineOrders.js`, **modifié non commité** (+8 lignes d'après le diff global ; avertissement CRLF). Elles ne sont pas dans HEAD `d65c8f0`.

Règles **[RETENU]** :
1. Toute implémentation part de l'état actuel du worktree ; **ne jamais** restaurer le fichier depuis HEAD (les gardes seraient perdues).
2. Un déploiement construit depuis HEAD n'inclurait **pas** ces gardes : à signaler dans toute décision de déploiement.
3. L'indexation se fait par **hunks** (`git apply --cached` d'un patch isolé), comme déjà décidé en P3 pour `index.js`, afin de séparer les gardes existantes des futures modifications.
4. Les tests existants qui couvrent ces gardes (`ekbineOrders` tests) sont conservés ; la future exception X-2 s'ajoute sans les modifier.

---

## 8. `partnerInventoryVersion` inconnu

**[CODE]** Deux effets (`accountDeletion.js:78`, `partnerAccountDeletion.js:16`) :
- Si `partnerInventoryVersion === 1` (et `enabled === true`) : les agents Ekbine peuvent entrer dans le chemin partenaires (profil `deletionRequested` posé même si l'inspection bloque ; tombstone posé après inspection propre).
- Sinon : le chemin générique ne connaît que `client` et `livreur` (`ROLES`, `accountDeletion.js:3`) ; un rôle agent est mis en `blocked` / `role_obligations_review_required`. **Aucun agent Ekbine n'est mis en quarantaine ni marqué `deletionRequested` par ce flux.**

Conséquences :

| Hypothèse | Effet sur X-2 / X-3 |
|---|---|
| ≠ 1 ou désactivé | l'impasse « agent `deletionRequested` + commande engagée » n'est **pas produite par le flux automatique** ; X-3 ne concerne alors que des états résiduels ; la garde sur agent fermé reste valable mais rarement déclenchée |
| = 1 | l'impasse X-3 est **réalisable** (profil `deletionRequested` sans tombstone, commande bloquée) ; la décision sur la distinction `deletionRequested` / quarantaine devient prioritaire |
| **inconnu** (cas actuel) | **les deux hypothèses doivent être traitées comme possibles** ; aucune décision ne doit supposer l'une d'elles. **Prérequis** : constater la valeur réelle, par une **demande de lecture explicite et séparément autorisée** (aucun accès distant n'a été fait ici) |

Distinction à trancher **[OUVERT]** : la garde de confirmation refuse l'agent dès `deletionRequested`, alors que le commentaire du code dit que cette demande « ne suspend pas le travail existant ». Deux voies : (a) garder le refus et traiter via X-3 (S1 : rétablissement) ; (b) distinguer `deletionRequested` seul (le règlement d'une commande engagée reste permis) de tombstone/anonymisé (refus). La voie (b) reviendrait à la recommandation D3 pour cet état précis et contredit l'esprit de 7E-73 ; **non retenue ici**, par prudence.

---

## 9. Synthèse

### 9.1 Décisions retenues

| # | Décision | Statut |
|---|---|---|
| 1 | 7E-73 prévaut sur 7E-87 D3 ; agent fermé : confirmation refusée ; aucun crédit vers anonymisé/absent | **[ARBITRÉ]** |
| 2 | Confirmation client et règlement sont deux notions ; leur couplage atomique est conservé | **[ARBITRÉ]** |
| 3 | Préférence D-7 (annulation de demande avant `sealed`) à toute exception de wrapper | [RETENU] |
| 4 | Exception X-2 : une seule fonction, `ekClientConfirmOrder`, avec contrôle d'acteur transactionnel et conditions C1–C13 ; ne suffit pas d'ajouter `onCallClosing` | [RETENU] |
| 5 | `ekCancelOrderCF` et `ekbineSubmitDepositProof` hors exception | [RETENU] |
| 6 | X-3 : dossier distinct `ekbine_order_blocked`, sorties S1–S4, N2 pour S2–S4, N3 indisponible, aucune écriture manuelle directe | [RETENU] |
| 7 | Avec un seul super-admin : instruction possible, sorties N2 bloquées | [RETENU] (déduit de la décision N2) |
| 8 | Trace des refus hors transaction, idempotente, conditionnée | [RETENU] |
| 9 | Garde de tombstone en transaction pour `ekbineAgentDepositAction` | [RETENU] |
| 10 | Gardes non commitées préservées ; indexation par hunks | [RETENU] |

### 9.2 Points encore ouverts

1. Validation formelle par le propriétaire de X-2 (extension de la liste fermée 7E-97 à une 5ᵉ fonction).
2. Qui peut annuler la demande de suppression d'un agent (titulaire seulement ou administrateur) ; modalités D-7.
3. Type de dossier : `ekbine_order_blocked` additif contre réutilisation de `beneficiary_account_closed` (claim différent) ; ajout aux listes du moteur.
4. Remboursement d'un client fermé (`ekCancelOrderCF`) : D1/D2 pour Ekbine.
5. Contrôle supplémentaire C9 (relecture du journal `ekorder_<id>`).
6. Classification de `ekbineAgentDepositAction` (A ou B).
7. Distinction `deletionRequested` seul / quarantaine (voie (a) ou (b), §8).
8. **Valeur réelle de `partnerInventoryVersion`** (lecture à autoriser séparément).
9. Existence d'un second responsable indépendant pour N2.
10. Écriture directe client des commandes (règles) et acceptation d'une commande sans relire l'état du client.

### 9.3 Risques financiers

| Risque | Gravité |
|---|---|
| Fonds client débités et retenus par AZ (aucun compte séquestre explicite) tant qu'une commande `proof_sent` est bloquée | élevée |
| Agent non payé pour un service rendu (agent fermé) ; impasse si `partnerInventoryVersion = 1` | élevée |
| Résolution manuelle par écriture directe, hors preuve et hors double validation | élevée si tolérée |
| Exception X-2 mal câblée : confirmation par un client scellé/anonymisé, ou crédit d'un agent fermé | élevée |
| Création d'une créance dans un compte fermé (flag de débit non prouvé) | moyenne ; évitée par C9 |
| Aucune trace des refus : commandes immobilisées invisibles du support | moyenne |
| Gardes Ekbine absentes de HEAD : déploiement depuis HEAD sans protection | moyenne |
| Écriture directe de commandes par le client tant que les règles l'autorisent | moyenne |
| Un seul super-admin : dossiers N2 durablement bloqués | opérationnelle |

### 9.4 Prérequis avant toute implémentation

1. Décision formelle du propriétaire sur X-2 (extension de la liste fermée) et sur les points §9.2 1, 3, 4, 7.
2. Détermination, par lecture autorisée séparément, de la valeur de `partnerInventoryVersion` ; sinon, concevoir pour les deux hypothèses.
3. Lots d'infrastructure de P3 d'abord : `assertClosureActor`, `onCallClosing` limité, tombstone `phase`/`epoch` (aucun n'existe).
4. Rattachement des gardes Ekbine non commitées par hunks avant de modifier `ekbineOrders.js`.
5. Définition du type de dossier et des résolutions dans le moteur (additif), avec son test.
6. Plan de tests : refus pour client anonymisé/scellé/absent, commande postérieure à la quarantaine, agent fermé/absent/anonymisé, débit non prouvé, statut ≠ `proof_sent`, idempotence de la trace, test de câblage de la liste fermée. Les tests d'émulateur ne valent pas preuve de production.
7. Autorisation séparée pour tout accès préproduction (`az-express-preprod` uniquement, avec `--project` explicite) ; production strictement exclue.

Je m'arrête ici. Aucun lot n'est commencé.
