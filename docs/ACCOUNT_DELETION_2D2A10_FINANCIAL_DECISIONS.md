# 2D-2A.10 — Clôture des décisions financières (E-Kbine et obligations)

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document **documentaire** : aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, accès distant, opération Firebase, commit, push, déploiement ni nettoyage ; aucun document existant modifié ; aucun lot L0–L8 commencé. Analyse **statique**.

Sources : 2D-2A.3 à 2D-2A.9 (P3…P9), 7E-73, 7E-87, 7E-97 ; code relu en lecture seule : `accountObligations.js` (`RESOLUTIONS` l.225-235, `verifyDecision` l.507-560, `evaluateFlag` l.567-610), son test `test/accountObligations.test.js` (non exécuté), `accountDeletion.js` (l.62-96 : porte de déploiement, tombstone), `partnerAccountDeletion.js` (l.10-40), `accountDeletionSupport.js`, `adminGuards.js`, `firestore.rules` (l.54-78 : rôles admin), `ekbineOrders.js`, `index.js` (wrapper l.83-90, `ekbineAgentDepositAction` l.2130-2160).

## 0. Statuts : comment lire ce document

| Marqueur | Sens | Preuve exigée |
|---|---|---|
| **[RETENU-M]** | règle énoncée par le propriétaire dans le brief de la mission 2D-2A.10 (§1) ; reprise telle quelle | le brief lui-même |
| **[APPROUVÉ-ant.]** | décision approuvée dans une mission antérieure (X-1 : 2D-2A.7 ; X-2 : 2D-2A.8 ; règles N2/N3/super-admin/séquestre : 2D-2A.9) | ces briefs |
| **[PROPOSÉ]** | proposition de ce document (§2 Q1–Q4 et détails) | **aucune** : n'est **pas** une décision du propriétaire tant qu'elle n'est pas confirmée explicitement |
| **[FAIT]** | observé dans le code lu | référence de ligne |
| **[BLOQUANT]** | condition manquante avant L0 ou avant la fonctionnalité concernée | — |

Les quatre questions Q1–Q4 sont **résolues sous forme de propositions** : elles deviennent des décisions seulement après confirmation écrite du propriétaire.

---

## 1. Arbitrages financiers formalisés

Faits communs [FAIT] : il n'existe **pas de séquestre** (le client est débité, une écriture `ekorder_<id>` est créée, rien d'autre) ; `proof_sent` n'est pas annulable ; aucun writer d'administration Ekbine n'existe ; aucune fonction n'annule une demande de suppression ; N3 est indisponible dans le moteur (`flag_level3_unavailable`, `accountObligations.js:512`).

| # | Règle | Statut |
|---|---|---|
| F-1 | **S1** : rétablissement **prioritaire**, **avant `sealed`**, **après inspection complète**. Il ne déplace aucun argent ; le règlement reste celui de la confirmation normale. | [RETENU-M] ; modalités → Q1 [PROPOSÉ] |
| F-2 | **S2** : remboursement **distinct** (writer d'administration, jamais l'annulation client), avec **preuve du débit** (`provenDebit` + journal `ekorder_<id>` relu + absence de `ekrefund_<id>`) et **N2**. | [RETENU-M] ; writer et transition `proof_sent → cancelled` inexistants |
| F-3 | **S3** : substitution du bénéficiaire **refusée** tant que les règles métier ne sont pas définies. | [RETENU-M] : S3 est indisponible, aucun développement |
| F-4 | **S4** : règlement externe **en attente** d'un mécanisme vérifiable. | [RETENU-M] : indisponible |
| F-5 | **Client en quarantaine** : annulation de la demande (D-7) **prioritaire** ; toute autre solution doit respecter les contrôles financiers (transaction, lecture avant écriture, plafond, journal, audit strict, `epoch`). | [RETENU-M] |
| F-6 | **Client `sealed`** : **aucun crédit portefeuille automatique**. | [RETENU-M] ; cohérent avec P3 (aucune écriture après scellage) |
| F-7 | **Client anonymisé ou absent** : **aucun crédit portefeuille** (DR3 : absent ≡ anonymisé). | [RETENU-M] ; [APPROUVÉ-ant.] |
| F-8 | **`ekbineAgentDepositAction`** : contrôle transactionnel du tombstone **à prévoir** (`assertNewAccountActivity` au début de la transaction). | [RETENU-M] ; classification A/B des trois actions reste à confirmer (refus par défaut pour agent fermé) |
| F-9 | **Refus de confirmation** : audit serveur **idempotent** (création seule, identifiant déterministe, mode strict, sans donnée personnelle). | [RETENU-M] ; schéma de P9 §4.2 [PROPOSÉ] |
| F-10 | **`ekbine_order_blocked`** : type **distinct** de `beneficiary_account_closed`, **bloquant jusqu'à extension validée du moteur**. | [RETENU-M] ; schéma de P9 §5.1 [PROPOSÉ] |
| F-11 | Acquis antérieurs inchangés : 7E-73 prévaut sur 7E-87 D3 (X-1) ; `ekClientConfirmOrder` cinquième exception `onCallClosing` (X-2, C1–C13) ; S2–S4 en N2 ; N3 indisponible ; un seul super-admin ⇒ N2 en attente ; aucune suppression avec obligation non résolue ; aucune écriture manuelle directe ; aucun crédit forcé. | [APPROUVÉ-ant.] |

Statuts de disponibilité (rien n'est opérationnel) :

| Issue | Disponible aujourd'hui | Pourquoi |
|---|---|---|
| S1 | **non** | aucune fonction d'annulation de demande ; tombstone sans `phase`/`epoch` |
| S2 | **non** | writer, transition et registre de décisions/preuves inexistants |
| S3 | **non, par décision** | règles métier non définies |
| S4 | **non, par décision** | mécanisme vérifiable inexistant |
| X-2 | **non** | `onCallClosing`, `assertClosureActor` inexistants |

---

## 2. Les quatre questions ouvertes

### Q1 — Annulation de la demande de suppression d'un agent [PROPOSÉ]

**Faits** [FAIT] : aucun code n'annule ou n'« ouvre » une demande (aucune occurrence `cancel`/`reopen`/`restore` dans `accountDeletion*.js`, `partnerAccountDeletion.js`). Un tombstone est créé avec `{createdAt, state:'deleting'}` seulement. Le quarantaine pose sur le profil `deletionRequested`, `isOnline:false`, `isAvailable:false`, `isSuspended:true` (`partnerAccountDeletion.js:34`) **sans conserver les valeurs antérieures**. Le planificateur `retryAccountDeletions` (toutes les 15 minutes) reprend les dossiers `account_deletions`. La demande exige une authentification récente (≤ 300 s, `accountDeletion.js`, `request`).

**Rôles autorisés** (proposition) :

| Voie | Qui | Quand | Condition |
|---|---|---|---|
| **V1 — par le titulaire** | l'agent lui-même, identifié par `request.auth.uid` = l'identifiant du compte | avant `sealed` (phase absente ou `closing`) | authentification récente (≤ 300 s), non anonyme, rôle `ekbine_agent` vérifié dans `ekbine_agents/{uid}`, Auth non désactivé ni supprimé |
| **V2 — récupération administrative** | super-admin actif (`admins/{uid}.role='super'`, `isActive`), jamais le titulaire pour lui-même | `sealed` sans `authDeletedAtMs`, ou titulaire injoignable | motif codé ; second responsable (N2) si `deleting:true` (D5 D-2, **approuvé**) ; le scellé n'est jamais rouvert par un délai |
| **Aucune voie** | — | `isDeleted:true`, Auth supprimé (`authDeletedAtMs`), profil absent | l'opération est irréversible : S1 impossible → S2/S3/S4 |

Un administrateur **ne peut pas** annuler à la place du titulaire par une simple écriture ; il passe par V2 et ses preuves. Qui, du titulaire seul ou de l'administrateur, peut agir est **à confirmer** par le propriétaire.

**Contrôles d'identité** : jeton non anonyme ; `uid` du jeton = `uid` du dossier ; reconnexion récente ; correspondance rôle/collection ; aucun autre rôle actif (`multiple_roles_manual_review`) ; limitation de débit.

**Inspection complète exigée avant d'annuler** (F-1) : relecture **dans la transaction** de : tombstone (phase, `epoch`, `deleting`, `authDeletedAtMs`, jeton de scellé), profil (non `isDeleted`), dossier `account_deletions`, commandes Ekbine de l'agent (états), moteur d'obligations (évaluation `requiredQueries`, plafond 201). La présence de la commande bloquante ne s'oppose pas à l'annulation (c'est précisément son but) ; elle est **consignée**. Troncature ou résultat ambigu ⇒ refus.

**Effets à écrire dans la même transaction** (proposition) : tombstone supprimé ou marqué clos avec `epoch` incrémenté ; profil : `deletionRequested` retiré ; **restauration de `isSuspended`/`isOnline`/`isAvailable` seulement vers leurs valeurs antérieures** ; dossier `account_deletions` passé à un état terminal « annulé » **pour que `retryAccountDeletions` ne relance rien** ; audit strict.

**Limite essentielle [BLOQUANT pour Q1]** : le code ne conserve pas les valeurs antérieures de `isSuspended`, `isOnline`, `isAvailable`. Rétablir `isSuspended:false` sans cette information pourrait lever à tort une **suspension antérieure** (fraude, administration). Il faut enregistrer un instantané préalable au moment de la mise en quarantaine ; **à défaut, la restauration est refusée** et le dossier passe en revue administrative.

**Avant / après `sealed`** :

| Phase | Annulation | Remarque |
|---|---|---|
| absente ou `closing` | V1 ou V2 | inspection complète |
| `sealed` | V2 uniquement, retour à `closing` d'abord | `deleting:true` ⇒ N2 |
| `authDeletedAtMs` ou `isDeleted` | **impossible** | irréversible |

### Q2 — Remboursement externe [PROPOSÉ ; indisponible, voir F-4]

Aucun prestataire ni API n'est supposé. Un « remboursement externe » est un paiement fait **hors plateforme** que la plateforme **enregistre** ; elle ne l'exécute pas et ne le vérifie pas auprès d'un tiers.

| Élément | Exigence minimale |
|---|---|
| **Bénéficiaire** | identifiant technique du client de la commande (`clientId`) ; jamais un nom ni un numéro conservé dans la plateforme ; le lien entre le payeur externe et `clientId` est établi par **deux personnes** (N2) hors plateforme et attesté dans la preuve |
| **Devise** | `XOF` seulement ; montant entier strictement positif ; égal à `debitedAmount` |
| **Référence de transaction** | `paymentRef` externe, conforme au motif d'identifiant du moteur ; **unique** dans le registre des preuves |
| **Canal** | valeur d'une liste fermée définie par le propriétaire (la plateforme n'en nomme aucune ici) |
| **Date** | `paidAtMs` postérieure à la date de débit de la commande |
| **Preuve** | document immuable : montant, devise, `orderId`, `beneficiaryId`, `paymentRef`, `contentHash` (64 hex), `immutable:true`, `status:'verified'`, `verifiedBy`, `verifiedAtMs`, lié à la décision, au sujet et à la résolution (modèle de `verifyDecision`, `accountObligations.js:538-556`) |
| **Idempotence** | identifiant de preuve **déterministe** à partir de `paymentRef` (création seule : un second usage est refusé) ; identifiant de requête unique par décision ; une commande ne peut recevoir qu'une seule issue (aucun remboursement si `ekrefund_<id>` existe ou `refunded` vrai) |
| **Audit** | `audit_logs` strict dans la transaction qui clôt le dossier : décision, preuve, niveau, approbateurs, montant, commande ; identifiants techniques ; aucun nom, aucun numéro, aucune URL de preuve |
| **Niveau** | **N2** ; N3 indisponible |
| **Limite honnête** | le serveur contrôle la **cohérence** et l'**immuabilité** de la preuve et l'identité des vérificateurs ; il ne peut pas constater le paiement lui-même. La véracité repose sur les deux personnes de N2 |

Pour un client **anonymisé ou absent**, la preuve ne peut pas s'appuyer sur le profil (données effacées) ; la conservation légale d'éléments d'identification est une question **juridique non tranchée** [BLOQUANT pour ce cas].

### Q3 — `partnerInventoryVersion` [PROPOSÉ ; aucune commande distante]

**Où cela se joue** [FAIT] : document `operations_control/account_deletion`. Il y a **deux portes distinctes** :
1. Porte globale (`accountDeletion.js:68-71`) : `enabled === true` **et** `inventoryVersion === 1` ; sinon le dossier reste `pending` avec la raison `server_rollout_not_enabled` et **aucun tombstone n'est posé**.
2. Porte partenaires : `partnerInventoryVersion === 1` (`accountDeletion.js:78` ; `partnerAccountDeletion.js:16` exige aussi `enabled === true`) ; sinon un rôle autre que client/livreur est mis en `blocked` / `role_obligations_review_required`.

| Valeur observée | Conséquence pour les agents Ekbine | Conséquence pour X-2 / X-3 |
|---|---|---|
| `enabled ≠ true` ou `inventoryVersion ≠ 1` (porte 1 fermée) | aucune suppression automatique : ni quarantaine ni tombstone | X-2 et X-3 ne sont pas produits par ce flux ; seuls des états résiduels historiques peuvent exister |
| porte 1 ouverte, `partnerInventoryVersion = 1` et `enabled = true` | chemin partenaires actif ; profil `deletionRequested` posé même si l'inspection bloque ; tombstone après inspection propre | l'impasse « agent `deletionRequested` + commande `proof_sent` » est **réalisable** ; X-2/X-3/S1 deviennent pertinents |
| porte 1 ouverte, `partnerInventoryVersion` **absent** | rôle agent `blocked` (`role_obligations_review_required`) | pas d'impasse produite par ce flux |
| `partnerInventoryVersion` **différent de 1** (0, 2, chaîne, booléen…) | traité comme non égal à 1 : même effet que « absent » | idem ; **la comparaison est stricte** (`=== 1`) : `"1"` ou `true` ne conviennent pas |
| **inconnu** (cas actuel) | on ne sait pas laquelle des lignes précédentes s'applique | **concevoir et tester pour les deux situations** ; aucune décision ne doit supposer l'une d'elles |

**Production vs préproduction** : la valeur de `az-express-preprod` n'est pas celle de la production. Une lecture en préproduction **ne renseigne pas** sur la production. L'accès à la production est interdit par la règle de travail du projet ; il n'est donc pas demandé ici.

**Demande de lecture distincte (à soumettre au propriétaire, non exécutée)** — texte proposé :

> *Demande de lecture 2D-2A.R1.* Objet : connaître l'état du document `operations_control/account_deletion` sur le projet `<à préciser par le propriétaire>`. Lecture **seule**, un seul document, aucune écriture, aucun script déployé. Champs demandés : `enabled`, `inventoryVersion`, `partnerInventoryVersion` (valeur et type). Si le document est absent, le consigner. Méthode préférée : lecture manuelle dans la console par le propriétaire, qui transmet les trois valeurs et leur type ; à défaut, une lecture ponctuelle explicitement autorisée avec `--project` explicite. Pour la **production**, seul le propriétaire peut lire ou autoriser expressément cette lecture ; l'assistant n'y accède pas sans autorisation écrite spécifique. Rien d'autre ne doit être lu.

### Q4 — Deuxième approbateur N2 [PROPOSÉ]

**Faits** [FAIT] : le moteur impose `approvedBy ≠ requestedBy`, `approvedBy ≠ originBy` (décideur initial) quand il existe, `approvedAtMs ≥ requestedAtMs`, identifiants conformes, requête unique (`accountObligations.js:524-535`). Ces contrôles portent sur des **chaînes d'identifiants**, pas sur des personnes : deux comptes détenus par la même personne les passeraient. Rôles admin : `admins/{uid}` avec `role ∈ {super, sub}` et `isActive` ; les règles `isAdmin()` n'acceptent que `super` ; le second facteur est en mode `log` par défaut (`adminGuards.js`, `ADMIN_MFA_MODE`).

**Conditions d'indépendance proposées :**
1. Deux **personnes physiques distinctes**, désignées par écrit par le propriétaire (la distinction des identifiants ne suffit pas).
2. Chacune avec son propre compte administrateur actif, session et appareil propres.
3. L'approbateur n'est ni le demandeur, ni le décideur initial, ni le titulaire du compte concerné, ni le bénéficiaire, ni une personne ayant un intérêt dans le dossier.
4. L'approbateur a vu la preuve elle-même, pas un résumé du demandeur.
5. L'assistant n'est jamais un approbateur ni un demandeur de décision N2.

**Permissions** : compte administrateur actif ; permission d'approbation financière **dédiée** (la liste des permissions est fermée et testée en parité : en ajouter une est un changement à autoriser séparément) ; second facteur **imposé** (`ADMIN_MFA_MODE=enforce`) avant toute opération N2 [BLOQUANT pour N2 tant que le mode est `log`].

**Traçabilité** : décision au registre (demandeur, approbateur, niveaux, horodatages, identifiant de requête, résolution) ; preuve `verified` avec vérificateur ; ligne `audit_logs` stricte ; aucune donnée personnelle.

**Si aucune deuxième personne n'est désignée** [APPROUVÉ-ant.] : toute opération N2 reste `en attente de seconde approbation`, le dossier **reste bloquant**, il n'existe ni délai de péremption, ni délégation, ni contournement ; les comptes concernés ne sont pas supprimés.

---

## 3. Matrice financière finale

Colonnes : acteur ; état du compte ; statut de commande ; bénéficiaire ; preuve exigée ; écriture financière ; niveau ; effet sur la suppression. « Refusé » = aucune écriture. Les lignes marquées † dépendent d'éléments inexistants ou non décidés.

| # | Opération | Acteur | État du compte | Statut commande | Bénéficiaire | Preuve exigée | Écriture financière | Niveau | Effet sur la suppression |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Confirmation normale | client | actif ou suppression demandée (profil seul) | `proof_sent` | agent actif | débit prouvé ou non-wallet | **autorisée** : crédit agent = `debitedAmount` | aucun | la commande devient terminale |
| 2 | Confirmation, client en quarantaine † | client | tombstone `closing` | `proof_sent`, engagée avant (C1) | agent éligible (C7) | C1–C13 de P8 ; débit prouvé (C9) | **autorisée** (crédit agent) | aucun | idem ; quarantaine non levée |
| 3 | Confirmation, client `sealed`/anonymisé/absent | client | `sealed`/`isDeleted`/absent | `proof_sent` | — | — | **refusée** | — | dossier bloquant (S1/S2/…) |
| 4 | Confirmation, agent fermé ou absent | client | tout | `proof_sent` | agent en quarantaine/`deletionRequested`/`isDeleted`/absent | — | **refusée**, aucun crédit | — | dossier bloquant ; audit du refus (F-9) |
| 5 | Annulation avec remboursement par le client | client | actif / suppression demandée | `pending`, `awaiting_deposit` | client | débit prouvé | **autorisée** : remboursement `debitedAmount`, journal `ekrefund_<id>` | aucun | commande terminale |
| 6 | Annulation par le client | client | quarantaine | tout | — | — | **refusée** (wrapper) ; voie F-5 : D-7 | — | aucune levée automatique |
| 7 | **S1** annulation de la demande par le titulaire † | agent | avant `sealed` | `proof_sent` bloquée | — | inspection complète ; instantané antérieur des drapeaux de profil | aucune | aucun (aucun argent) | le compte redevient actif ; la confirmation suit le chemin normal |
| 8 | **S1** récupération administrative † | super-admin | `sealed` sans Auth supprimé | idem | — | motifs codés ; inspection ; `deleting:true` ⇒ second responsable | aucune | N2 si `deleting:true` | retour à `closing` ; pas de suppression |
| 9 | S1 impossible | — | `isDeleted`, Auth supprimé, profil absent | — | — | — | — | — | S2/S4 uniquement |
| 10 | **S2** remboursement portefeuille † | writer d'administration | client actif ou suppression demandée | `proof_sent` bloquée | client | débit prouvé (journal relu) ; absence de `ekrefund_<id>` ; élément établissant que le service n'est pas dû | **autorisée sous conditions** : crédit `debitedAmount` | **N2** | commande `cancelled` ; dossier résolu par décision vérifiée |
| 11 | S2, client en quarantaine † | idem | `closing` | idem | client (si profil existant, non anonymisé) | idem + `epoch` | **possible seulement après échec de D-7** ; crédit portefeuille ; crée un solde qui bloque ensuite la suppression (régularisation) | **N2** | suppression bloquée tant que le solde n'est pas régularisé ; circuit de régularisation d'un client en quarantaine non défini |
| 12 | S2, client `sealed` | idem | `sealed` | idem | — | — | **refusée** : aucun crédit portefeuille (F-6) | — | retour à `closing` par V2, ou externe (ligne 14) |
| 13 | S2, client anonymisé ou absent | idem | `isDeleted` / absent | idem | — | — | **refusée** : aucun crédit portefeuille (F-7) | — | externe ou revue |
| 14 | **S4 / remboursement externe** † | writer d'administration | tout | `proof_sent` bloquée | client (identifiant technique) | Q2 | aucune écriture de portefeuille ; enregistrement de la décision | **N2** + preuve | **indisponible** (F-4) ; dossier reste bloquant |
| 15 | **S3** substitution | — | — | — | tiers | — | **refusée** | — | **indisponible** (F-3) |
| 16 | Crédit à un agent anonymisé ou absent | tout | `isDeleted` / absent | tout | agent | — | **refusée** | — | dossier bloquant |
| 17 | Création de commande / nouveau débit | client | quarantaine ou plus | — | — | — | **refusée** (X-2 : C2) | — | — |
| 18 | `ekbineAgentDepositAction` (`confirm`/`reject`/`start`) | agent | fermé (tombstone, `deletionRequested`, `isDeleted`, absent) | `deposit_proof_sent` / `deposit_confirmed` | — | tombstone relu dans la transaction † | aucune | — | refus ; la commande bascule vers le dossier bloqué |
| 19 | Audit d'un refus de confirmation | serveur | — | `proof_sent` | — | l'appelant est le client de la commande | aucune (journal d'audit) | — | n'a aucun effet sur la suppression |
| 20 | Ouverture du dossier `ekbine_order_blocked` † | serveur | — | `proof_sent` bloquée | — | refus établi | aucune | — | **bloquant** jusqu'à extension validée du moteur |
| 21 | Débit non prouvé (flags `ekbine_*_unproven_debit`) | N1/N2 selon `RESOLUTIONS` | tout | tout | — | décision et preuve vérifiées | selon la résolution | N1 (`debit_proven_and_settled`) ; N2 (`debit_disproved`, `refunded_by_ledger`) | anciens flags sans origine : bloquants (D-6) |
| 22 | Abandon de créance | — | — | — | — | — | **refusée** | N3 : **indisponible** | — |
| 23 | Toute écriture manuelle directe en base | tout | tout | tout | — | — | **interdite** | — | — |

Règles transverses : transaction, lectures avant écritures, aucun solde négatif, plafond, journal, audit strict, `epoch` incrémentée sur compte en quarantaine, aucune levée automatique de quarantaine, aucune suppression avec obligation non résolue.

---

## 4. Contradictions et tensions subsistantes

| # | Constat | Traitement |
|---|---|---|
| T-1 | 7E-87 D3 (créditer l'agent) ↔ 7E-73 (refus) | levée pour Ekbine par X-1 [APPROUVÉ-ant.] |
| T-2 | 7E-97 : liste fermée de quatre fonctions ↔ X-2 : cinq | levée pour une fonction par X-2 ; les documents antérieurs restent inchangés |
| T-3 | 7E-73 : commandes engagées inchangées ↔ code : un client tombstoné ne peut pas confirmer | levée en principe par X-2, **non implémentée** |
| T-4 | D5 D-7 prévoit l'annulation d'une demande ; aucun code ne le fait et les valeurs antérieures du profil ne sont pas conservées | Q1, limite essentielle |
| T-5 | S2 sur client en quarantaine crée un solde non retirable par le client (wrapper) | ligne 11 ; D-7 d'abord |
| T-6 | Moteur : seuls les noms `clientId`, `driverId`, `partnerId`, `sellerId`, `pharmacieId` lient un dossier à un compte ; `agentId` non | dossier côté agent non vu par le moteur ; couvert par les inspecteurs via la commande |
| T-7 | Le test `accountObligations.test.js` est présent mais **non exécuté** par cette mission ; l'état « 169 tests ignorés par émulateur » reste celui des audits antérieurs | aucune preuve nouvelle |

---

## 5. Blocages avant L0

Aucun développement n'est autorisé tant que ces conditions ne sont pas remplies. Le **lot L0** (préparation) ne doit pas commencer avant leur traitement ou leur acceptation explicite.

| # | Blocage | Type |
|---|---|---|
| B-1 | Confirmation écrite du propriétaire pour les propositions Q1–Q4 (qui peut annuler une demande ; liste des canaux de remboursement externe ; conditions N2) | décision |
| B-2 | Désignation d'un **second responsable indépendant** (personne physique) ; sinon toutes les opérations N2 restent en attente | organisation |
| B-3 | `ADMIN_MFA_MODE=enforce` avant toute opération N2 (mode actuel par défaut `log`) | prérequis de sécurité |
| B-4 | Valeur réelle de `operations_control/account_deletion` (`enabled`, `inventoryVersion`, `partnerInventoryVersion`) : demande 2D-2A.R1, à autoriser séparément | information |
| B-5 | Conservation des valeurs antérieures du profil à la mise en quarantaine (instantané), sans quoi S1 ne peut pas restaurer sans risque | conception |
| B-6 | Question juridique de la preuve de remboursement externe pour un client anonymisé | juridique |
| B-7 | Règles métier de la substitution (S3) et mécanisme vérifiable du règlement externe (S4) : **volontairement non définis** | décision future |
| B-8 | Plan de migration de la transition `proof_sent → cancelled` (règle projet : pas d'extension d'une machine d'états sans plan) | conception |
| B-9 | Infrastructure de P3 : champs additifs du tombstone, `assertClosureActor`, `onCallClosing`, registre de décisions/preuves | développement futur |
| B-10 | Extension additive et testée de `accountObligations.js` (type, claim, résolutions, clé de lien de l'agent) | développement futur |
| B-11 | Indexation par hunks pour préserver les gardes Ekbine non commitées (présentes dans le worktree, absentes de HEAD) | pratique Git |
| B-12 | Plan de tests (émulateur et préproduction `az-express-preprod` avec `--project` explicite, après autorisation séparée) ; ces tests ne prouvent pas la production | validation |

---

Je m'arrête ici. Aucun code n'est écrit et aucune proposition n'est promue au rang de décision du propriétaire.
