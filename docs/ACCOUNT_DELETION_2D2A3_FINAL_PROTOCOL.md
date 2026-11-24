# 2D-2A.3 — Protocole final de fermeture de compte et de verrouillage financier

Contrat de référence pour les lots de sécurisation. Spécification uniquement. Branche `finalisation/az-express`, HEAD `d65c8f0`, index vide. Aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, commande distante ni accès production (`az-express-b0469`). Seul fichier créé : celui-ci. Il remplace, pour la conception, les rapports 2D-2A.1 et 2D-2A.2 là où ils diffèrent (écarts listés au §0.3). Il ne les réécrit pas.

Légende : **[AP]** décision approuvée (citée) ; **[F]** fait vérifié (source) ; **[P]** proposition ; **[R]** risque non résolu ; **[A]** validation humaine encore requise.

---

## 0. Décisions de référence, faits et écarts

### 0.1 Décisions approuvées **[AP]**

| # | Décision | Origine |
|---|---|---|
| D-1 | Le tombstone existant (`account_tombstones/{uid}`) est le document faisant autorité | consigne 2D-2A.3 §1 |
| D-2 | Les champs `phase`, `epoch` et les informations de scellement sont **additifs** | idem |
| D-3 | Tous les writers concernés lisent **et modifient** ce même document dans leur transaction | idem |
| D-4 | Aucune nouvelle activité pendant la fermeture | idem |
| D-5 | Règlements engagés possibles sous contrôles D6 ; remboursements et compensations autorisés sous conditions | idem ; 7E-97 §1 (D6-a, D6-b, D6-c, DR1–DR3) |
| D-6 | N2 et N3 : deux responsables indépendants ; avec un seul super-admin, ils restent en attente ; aucune auto-validation | 7E-102, 7E-105 |
| D-7 | N3 bloquant tant que le consentement du créancier n'est pas vérifiable | 7E-107 (C1) |
| D-8 | Anciens flags Ekbine sans origine fiable : bloquants | 7E-107, `ORIGIN_DECIDER_REQUIRED` |
| D-9 | Délai de réflexion de 24 h exclu | consigne |
| D-10 | `held_for_review` obligatoire avant l'activation réelle de FeexPay | 7E-87 D4, 7E-97 R10 |
| D-11 | Aucun déverrouillage automatique fondé uniquement sur un délai | consigne 2D-2A.3 §2 |
| D-12 | Le moteur `accountObligations.js` s'ajoute aux contrôles existants, il ne les remplace pas ; `paid_by_client_out_of_system` indisponible ; production intouchable | 2D-2A.2, 7E-108 |
| D-13 | Un agent Ekbine en quarantaine ne valide pas une confirmation client ; un client en quarantaine ne crée pas de commande Ekbine ; commandes terminées ou engagées : comportement inchangé | 7E-73 `EKBINE_SCOPE_DECISION` §1 |

### 0.2 Faits vérifiés **[F]**

1. Wrapper d'appelant : l'`onCall` local de `index.js` appelle `assertAccountEnabled` (tombstone de l'appelant, **hors transaction**) pour toute Cloud Function sauf cinq `rawOnCall` ; webhooks et planificateurs non enveloppés (`index.js:76-90` ; 7E-97 §3).
2. Garde transactionnelle : `assertNewAccountActivity` relit `account_tombstones/{uid}` puis les profils dans la transaction du writer ; elle **ne fait que lire** (`accountAdmission.js:2-13`).
3. Création du tombstone : `tx.create(account_tombstones/{uid}, {createdAt, state:'deleting'})` dans T1 (`accountDeletion.js:88`). Règles : lecture et écriture client interdites (`firestore.rules:12`) ; `isAuth()` refuse tout client dont le tombstone existe (`firestore.rules:7-11`).
4. Séquence actuelle : `inspect()` avant le tombstone (`accountDeletion.js:85`), de nouveau au bail après `QUIET_MS` (même ligne, 2ᵉ passage), puis `inspectCleanup`, `auditStrict`, `updateUser(disabled)`, `revokeRefreshTokens`, `deleteUser`, contrôle d'absence (`accountDeletion.js:98-110`), enfin T3 après suppression Auth (`accountDeletion.js:124-133`).
5. Concurrence en émulateur (lot 2A, 7E-89) : 9 scénarios sur 9 réussis ; la lecture d'un tombstone absent par un writer entre en conflit avec sa création et est rejouée (scénario 5) ; aucun effet validé après le tombstone. Limites : émulateur, entrelacements tirés au hasard, pas de production.
6. Non implémentés : `onCallClosing`, `assertClosureActor`, `accountCreditState`, `assertBeneficiaryCreditable` (aucune occurrence dans `functions/*.js`). Le moteur `accountObligations.js` et son test sont **non suivis par Git** (hors HEAD).
7. Aucune suppression de tombstone n'existe dans le code (7E-87 D3).
8. Le déploiement progressif de la suppression est piloté par `operations_control/account_deletion` (`enabled`, `inventoryVersion`, `partnerInventoryVersion`) (`accountDeletion.js:68-71`).

### 0.3 Écarts avec 2D-2A.2 (corrigés ici)

1. **Pas de déverrouillage automatique par délai** (D-11). 2D-2A.2 prévoyait l'expiration du scellé à 60 s et son abandon implicite par le prochain writer : **abandonné**. Le temps ne sert plus qu'à l'alerte (§2.6).
2. **Ekbine, confirmation avec agent en quarantaine** : 2D-2A.2 écrivait « agent non `isDeleted` ». La décision 7E-73 (D-13) est plus stricte : **agent en quarantaine ⇒ refus**. Le registre 7E-87 D3 recommandait de créditer ; 7E-73 l'a remplacé.
3. **`manageProfessionalSubscription`** (abonnements professionnels, débit de portefeuille) n'était pas dans ma liste : ajouté, catégorie A (§4).
4. Les cinq fichiers non commités ont une origine connue (7E-68 et 7E-72), pas inconnue (§6).

---

## 1. Verrou financier

### 1.1 Schéma final du tombstone **[P]**

Document : `account_tombstones/{uid}`. Un document par UID dont le compte entre en fermeture.

| Champ | Type | Statut | Règle |
|---|---|---|---|
| `createdAt` | timestamp | existant | inchangé |
| `state` | `'deleting'` | existant | inchangé |
| `phase` | `'closing'` \| `'sealed'` | additif | absent ⇒ lu comme `closing` ; écrit explicitement par T1 dès le lot L2 |
| `epoch` | entier ≥ 0 | additif | absent ⇒ 0 ; voir §1.3 |
| `updatedAtMs` | entier | additif | horloge serveur de l'écriture |
| `sealToken` | chaîne aléatoire (UUID) | additif | présent seulement si `phase:'sealed'` |
| `sealEpoch` | entier | additif | valeur d'`epoch` au scellement |
| `sealedAtMs` | entier | additif | |
| `snapshotDigest` | SHA-256 hex 64 | additif | empreinte du snapshot financier validé à T2b |
| `deleting` | booléen | additif | vrai à partir du « fence » juste avant `deleteUser` |
| `deleteStartedAtMs` | entier | additif | |
| `authDeletedAtMs` | entier | additif | écrit après confirmation `auth/user-not-found` |
| `lastRecovery` | objet `{byUid, atMs, reasonCode, requestId}` | additif | dernier retour `sealed → closing` ; historique complet dans `audit_logs` |

Compatibilité : les gardes existantes testent seulement `exists` (`accountAdmission.js:6-7`) ; `isAuth()` aussi (`firestore.rules:10`). Les ajouts de champs ne les modifient pas **[F pour la lecture du code]**. Un tombstone existant sans `phase` reste valide.

Après suppression Auth confirmée, le tombstone n'est **jamais** supprimé : il reste `phase:'sealed'` avec `authDeletedAtMs`. Il n'existe donc pas de troisième phase `deleted`.

### 1.2 Phases et transitions

| De | Vers | Qui | Préconditions (toutes dans une transaction) |
|---|---|---|---|
| (absent) | `closing`, `epoch:0` | T1 (inspecteur) | inspection et moteur non bloquants ; lectures complètes ; `tx.create` |
| `closing` | `closing`, `epoch+1` | writer B/C/D (§4) | contrôles propres au writer |
| `closing` | `sealed` | T2b | `epoch` égal à celui de T2 ; bail détenu ; moteur non bloquant sur lectures complètes ; snapshot équivalent à T2 ; Auth désactivé |
| `sealed` | `sealed` + `deleting:true` | « fence » pré-suppression | `phase:'sealed'`, `sealToken` et `sealEpoch` égaux à ceux du dossier ; bail détenu |
| `sealed` | `sealed` + `authDeletedAtMs` | T3 | `auth/user-not-found` confirmé |
| `sealed` | `closing`, `epoch+1`, `lastRecovery` | **récupération administrative** (§1.6) | voir §1.6 |

Aucune autre transition n'existe. En particulier : pas de passage `sealed → closing` par un writer, par une expiration ou par le planificateur (D-11).

### 1.3 Gestion d'`epoch`

1. `epoch` est un compteur monotone : il ne diminue jamais.
2. Il est incrémenté, dans la même transaction, par : toute opération B/C/D qui écrit une obligation, un règlement, un journal de portefeuille ou un crédit concernant la partie ; toute récupération administrative ; tout abandon de scellé.
3. Il n'est pas incrémenté par un refus, ni par une lecture.
4. T2 enregistre l'`epoch` observé dans le dossier `account_deletions/{uid}` ; T2b exige l'égalité. Un écart signifie « une opération financière a eu lieu depuis la dernière inspection » ⇒ échec de T2b.

### 1.4 Protocole des writers (commun, une seule implémentation)

Pour chaque partie P du writer (appelant, client, livreur, vendeur, partenaire, agent, bénéficiaire), **avant toute écriture**, dans la transaction du writer :

1. lire `account_tombstones/{P}` et le profil de P ;
2. profil absent ou `isDeleted:true` ⇒ voir la ligne du writer (§4) : refus complet (D6-a, D2), crédit omis avec flag (DR1) ou mise en revue ;
3. tombstone absent ⇒ comportement actuel inchangé, **aucune écriture supplémentaire** (aucun coût pour les comptes actifs) ;
4. `phase:'sealed'` ⇒ **refus** `ACCOUNT_SEALED` pour toute catégorie A, B, C, D ;
5. `phase:'closing'` (ou absent) : catégorie A ⇒ refus ; B/C/D ⇒ autorisé si les conditions de la ligne du writer (§4) sont vérifiées ; le writer **écrit** alors le tombstone avec `epoch+1` dans la même transaction.

Un helper unique, `assertFinancialLock(tx, db, HttpsError, parties, opClass)`, applique 1 à 5 et retourne les écritures à ajouter **[P]**. Les writers ne réimplémentent rien.

### 1.5 Sérialisation et protection contre les doubles opérations

**Argument.** Chaque writer B/C/D lit puis écrit le tombstone de chaque partie ; T2b lit puis écrit le même document. Deux transactions Firestore qui lisent puis écrivent un même document ne peuvent pas toutes deux valider sur la même version : la seconde est rejouée et relit l'état à jour.

- Writer valide avant T2b ⇒ T2b est rejeté, rejoué, voit `epoch` modifié ⇒ **échec de T2b**.
- T2b valide avant le writer ⇒ le writer rejoué lit `sealed` ⇒ **refus**.
- Writer ayant commencé avant T2b mais validant après ⇒ même chose : sa lecture du tombstone est invalidée.

**Statut de la preuve.** **[F]** en émulateur pour la lecture d'un tombstone par un writer face à sa création (7E-89 #5, #1, #2, #7). **[R]** non démontré en production (hypothèses H1 à H3, §9). Le protocole ne s'appuie **pas** sur le comportement des *requêtes* de transaction face à une insertion de document (question Q11) : il utilise un document unique par compte.

**Doubles opérations.**

| Mécanisme | Portée |
|---|---|
| Identifiants déterministes (flags `<orderId>_…`, journaux `order_<id>`, `admin_refund_<orderId>`, `ekcancel_<orderId>`) | rejeu d'un même fait |
| Écriture `tx.create` au lieu de `tx.set` pour les flags et journaux nouveaux | refus si déjà existant ; le chemin `alreadyDone` reste inchangé |
| `sealToken` à usage unique | un seul processus de suppression peut franchir `sealed → deleting` |
| Bail du dossier `account_deletions/{uid}` (existant, 180 s) | un seul processus par dossier |
| `requestId` unique (registre de décisions) | une décision, un effet |
| Écritures hors transaction **interdites** pour les writers du registre | supprime les doubles/pertes lors d'un arrêt entre commit et écriture (`orderActions.js:142`, `ekbineOrders.js:264-268`) |

### 1.6 Récupération administrative (aucune réouverture sans nouvelle vérification)

**Cas.** Le processus s'arrête après le scellement et avant `deleteUser`, ou `deleteUser` échoue de façon répétée, ou un incident oblige à rouvrir les règlements.

**Principes [P].**
1. `sealed` reste `sealed` : aucune expiration, aucun writer, aucun planificateur ne le rouvre (D-11).
2. Tant que `phase:'sealed'`, aucun règlement ni remboursement n'est possible pour ce compte. C'est volontaire et temporaire.
3. Le seul moyen de rouvrir est une Cloud Function administrative dédiée `recoverSealedClosureCF` (catégorie D), appelée par un super-admin.

**Procédure [P]** (une seule transaction pour les contrôles Firestore, plus une lecture Auth préalable) :
1. Authentification super-admin (`requireSuperAdmin`), `checkRateLimit`, `requestId` obligatoire, motif obligatoire (code de motif d'une liste fermée).
2. **Aucun bail actif** sur `account_deletions/{uid}` ; sinon refus (un processus de suppression est en cours).
3. **Vérification de l'état Auth** (Admin SDK `getUser`) avant la transaction :
   - utilisateur **absent** ⇒ la suppression a eu lieu : la récupération est refusée ; le tombstone reste scellé et le dossier est complété par T3 (§3.7) ;
   - utilisateur **présent** ⇒ poursuite.
4. Si `deleting:true` (un appel `deleteUser` a pu partir) : la récupération exige une **seconde approbation** d'un responsable différent (N2). Avec un seul super-admin elle reste en attente [D-6].
5. Relecture complète à jour : `inspect()` + moteur sur lectures complètes. Le résultat est **enregistré** dans le journal d'audit ; il n'est pas exigé non bloquant (la réouverture sert justement à régler des obligations), mais il est **exigé complet et lisible** (lecture tronquée ou erreur ⇒ refus).
6. Si Auth est désactivé et que le dossier est abandonné : réactivation Auth **après** la transaction de réouverture, jamais avant.
7. Écriture : `phase:'closing'`, `epoch+1`, effacement de `sealToken`/`sealEpoch`/`deleting`, `lastRecovery`, `updatedAtMs` ; état du dossier `blocked` + `reviewRequired:true` ; ligne `audit_logs` (strict, la transaction échoue si l'audit échoue).
8. Après récupération : toute nouvelle tentative de suppression repasse par T2 et T2b complets (l'`epoch` a changé).

**Garantie.** La réouverture ne rend possibles que les catégories B/C/D (jamais A) et uniquement sous les contrôles D6 ; elle laisse une trace ; elle exige un état Auth vérifié et une inspection datée ; elle invalide tout scellé antérieur par l'`epoch`.

### 1.7 Erreurs

| Erreur | Effet | Reprise |
|---|---|---|
| Lecture du tombstone impossible (writer) | le writer échoue entièrement | retry client |
| Transaction rejouée par conflit | normal | automatique |
| Écriture de T2b impossible | dossier `blocked`, pas de `deleteUser` | reprise horaire (`RETRY_MS`) |
| Écart d'`epoch` ou de snapshot à T2b | dossier `blocked`, nouvelle inspection complète | idem |
| Processus arrêté en `sealed` | **le scellé reste** ; le prochain `drain` reprend (§3.6) ou alerte | reprise automatique sûre, sinon §1.6 |
| Document tombstone illisible | refus partout (fail-closed) | intervention technique |

---

## 2. Alerte, sans déverrouillage

Le temps ne rouvre rien. Il déclenche seulement une alerte de support **[P]** : dossier en `sealed` depuis plus de 1 heure (`sealedAtMs`), `deleting:true` sans `authDeletedAtMs` depuis plus de 15 minutes, `epoch` incrémenté après T2. Seuils à valider **[A]**. Le canal d'alerte (écran support existant `manageAccountDeletionCF`, notifications) reste à choisir.

---

## 3. Suppression Auth

Firestore et Auth ne forment pas une transaction distribuée **[F]** : l'appel Auth est un effet externe, atomique à lui seul, non rejouable de façon cohérente avec Firestore. Aucune étape ci-dessous ne suppose le contraire.

### 3.1 Séquence formelle **[P]**

| Étape | Opération | Réussite si | Échec si | Effet de l'échec |
|---|---|---|---|---|
| **T1** | transaction : identités, admin, rôles multiples, `inspect()` + moteur (lectures complètes), création du tombstone `closing`/`epoch:0`, `isSuspended:true` | tout non bloquant | obligation, `*_truncated`, lecture en erreur, admin | dossier `blocked`, **aucun tombstone** (le compte reste utilisable et peut régler) |
| **Q** | attente `QUIET_MS` (15 min) | — | — | — |
| **T2** | transaction de bail : `inspect()` + moteur ; enregistrement du snapshot, de `epoch` et du bail | non bloquant, bail acquis | obligation nouvelle, erreur | dossier `blocked`, tombstone `closing` conservé, Auth inchangé |
| **N** | contrôles non transactionnels (`inspectCleanup`, `auditStrict`) | passent | échec | dossier `blocked`/reprise ; Auth inchangé |
| **A1** | `updateUser(uid,{disabled:true})` + `revokeRefreshTokens` | succès | erreur Auth | retour à `closing`, retry ; aucune suppression |
| **T2b** | transaction : relecture complète + `epoch` égal + snapshot équivalent + bail ⇒ `phase:'sealed'`, `sealToken`, `sealEpoch`, `snapshotDigest` | toutes conditions vraies | n'importe laquelle | `phase` reste `closing` ; **réactivation Auth** (§3.5) ; dossier `blocked` |
| **F** | transaction « fence » : vérifie `sealed` + `sealToken` + bail ; écrit `deleting:true`, `deleteStartedAtMs` | vraie | jeton/phase différents | pas de `deleteUser` ; §1.6 |
| **D** | `deleteUser`, puis `getUser` doit répondre `auth/user-not-found` | absent confirmé | autre erreur | §3.4 |
| **T3** | `authDeletedAtMs`, nettoyage, anonymisation (code actuel) | cohérence | incohérence | `cleanup_pending`, **jamais** une protection |

Il n'y a pas de limite de temps entre T2b et F ou D : `sealed` interdit toute écriture financière protégée, quel que soit le délai. Le seul rôle du temps est l'alerte (§2).

### 3.2 Opérations déjà démarrées et transactions en conflit

- Transaction de writer qui a lu le tombstone avant T1 : son commit est invalidé par la création du tombstone, rejouée, puis traitée selon la phase **[F en émulateur ; H en production]**.
- Transaction de writer qui a lu `closing` avant T2b : invalidée par l'écriture de T2b, rejouée, refusée en `sealed`.
- Opération de catégorie B/C/D commise **avant** T2b : l'`epoch` change ⇒ T2b échoue ⇒ nouvelle inspection ⇒ l'obligation créée est visible au moteur.
- Opération **non** protégée par le protocole (script, console, writer non migré) : non couverte [R]. Mitigation : T3 et F rejouent une inspection en lecture seule et comparent l'empreinte du snapshot ; un écart bloque et alerte.

### 3.3 Jetons déjà émis

- **[F]** Dès T1, le tombstone empêche l'appelant par le wrapper (lu à chaque appel) et par les règles `isAuth()` pour tout accès Firestore client, quel que soit le jeton.
- **[F]** Les gardes transactionnelles ne dépendent pas du jeton.
- **[H]** Les callables ne vérifient pas la révocation des jetons ; un jeton déjà émis peut rester utilisable jusqu'à expiration pour les fonctions non gardées par tombstone. Conclusion : la désactivation Auth empêche les **nouvelles** sessions ; la protection des écritures repose sur le tombstone, pas sur Auth.

### 3.4 Échec de `deleteUser`

1. Erreur Auth avant effet certain (réseau, quota) : le dossier garde `sealed`, `deleting:true` ; aucune réouverture automatique.
2. Reprise : voir §3.6.
3. Résultat indéterminé (le processus s'arrête pendant l'appel) : `getUser` tranche. Absent ⇒ T3. Présent ⇒ nouvel essai de `deleteUser` si `sealed` est intact et si une relecture en lecture seule confirme que le snapshot est inchangé.
4. Échecs répétés (au-delà de `MAX_ATTEMPTS = 6`, `accountDeletion.js:139`) : dossier `blocked` + alerte ; sortie par §1.6 uniquement.

### 3.5 Restauration d'un compte désactivé

1. Réactiver Auth (`disabled:false`) ne touche **pas** au tombstone : le compte reste sous `closing`/`sealed` ; les gardes et les règles continuent de refuser tout sauf les clôtures D6 en `closing` **[F : le tombstone n'est jamais supprimé par le code]**.
2. Réactiver Auth est une décision **séparée** de la réouverture financière. Elle n'est autorisée que si le dossier est `closing` ou récupéré (§1.6), jamais en `sealed`.
3. Annuler la demande de suppression (lever le tombstone) n'existe pas et n'est pas conçu ici : ce serait un writer de catégorie D à part entière **[A]**.

### 3.6 Reprise après arrêt entre T2b et `deleteUser`

À l'expiration du bail, `drain` (toutes les 15 minutes) reprend le dossier. En présence de `sealed` :
1. vérifier `sealToken` et `sealEpoch` égaux à ceux du dossier ; sinon arrêt, alerte ;
2. relecture **en lecture seule** (`inspect()` + moteur) : si bloquant ou si l'empreinte diffère de `snapshotDigest` ⇒ arrêt, alerte, §1.6 ;
3. sinon réacquérir le bail, passer par F puis D.
Cette reprise n'est pas un déverrouillage : `sealed` n'a pas été rouvert.

### 3.7 Obligation découverte tardivement

| Moment | Conduite |
|---|---|
| T1 | dossier `blocked`, aucun tombstone, le compte règle lui-même |
| Entre T1 et T2b | dossier `blocked`, tombstone `closing`, Auth réactivé si A1 a eu lieu, règlement sous D6 |
| En `sealed` avant D | arrêt, alerte, §1.6 |
| Après D | flag `late_obligation_<uid>_<orderId>` (écriture serveur : `accountUid`, `epoch`, référence de l'événement) ; **aucun crédit automatique** vers un bénéficiaire anonymisé (D-12 de 2D-2A.2) ; résolution par décision administrative (N2) avec preuve |

---

## 4. Writers : classification A/B/C/D et règles par writer

Légende des colonnes : **Closing** = comportement quand le tombstone est `closing` ; **Sealed** = `ACCOUNT_SEALED` pour tous. « D6 » = D6-a (bénéficiaire fermé ⇒ rien d'écrit, motif tracé), D6-b, D6-c, DR1–DR3 (7E-97 §1). Les tests de concurrence C1 à C5 sont définis au §8.

| Writer | Cat. | Closing | Acteurs | Bénéficiaires | Contrôle transactionnel | Audit | Test de concurrence |
|---|---|---|---|---|---|---|---|
| `payOrderFromWalletCF` (`orderActions.js:48`) | B | autorisé (D6-b) | client propriétaire | vendeur/partenaire/livreur : présents, non `isDeleted` sinon refus entier (D6-a) | helper §1.4 ; statut payable ; journal `order_<id>` **dans** la transaction ; `epoch+1` | `logAudit` (existant) + `paidAt/paidBy` | C1 (vs T2b), C3 (double paiement) |
| `cancelOrderCF` (`orderActions.js:494`) | C | autorisé (D6-c) | client propriétaire (statut annulable) | client toujours remboursé ; livreur `isDeleted` : crédit omis + flag `beneficiary_account_closed` (DR1) | helper ; `assertClosureActor` ; `epoch+1` | existant | C1, C3 |
| `deliverOrderCF` (`orderActions.js:569`) | B | autorisé (D6-c) | livreur = `order.driverId`, statut `accepted`/`picked_up` | partenaire `isDeleted` ⇒ refus (DR2) ; livreur fermé ⇒ refus (L ✘ si anonymisé) | helper ; règlement et flags créés dans la même transaction ; `epoch+1` | existant | C1, C2 |
| `confirmOrderDeliveryWithProof` | B | autorisé (même exception) | idem | idem | idem + preuve QR/PIN conservée | existant | C1 |
| `adminConfirmDeliveryCF` | D (+B) | autorisé | super-admin uniquement | client, livreur, partenaire non `isDeleted` | helper pour **chaque** partie ; motif obligatoire | `audit_logs` obligatoire avec motif et preuve | C1 |
| `refundExpiredBoutiqueOrderCF` (`orderActions.js:1657`) | C | autorisé | client propriétaire | client non `isDeleted` sinon aucun crédit + `needsReview` | helper ; statut revérifié | existant | C1, C3 |
| `autoExpireOrders` (planificateur) | C | autorisé commande par commande | système | idem ; `sealed` ⇒ **reporter** la commande (aucune écriture, repasse au tour suivant) | helper dans la transaction de chaque commande ; une commande en erreur ne bloque pas les autres | `logAudit` | C4 |
| `releaseOrderBeforePickupCF` (`driverRelease.js`) | A | refusé (progression de mission) | — | — | refus par le wrapper (appelant) ; helper en transaction pour le cas d'un autre acteur | existant | C2 |
| `settleTransferEarningsCF` (`transferSettlement.js`) | D (+B) | autorisé | super-admin | **chaque** livreur de `driverIds` : présent et non `isDeleted` sinon refus de toute l'approbation (D2) | helper pour chaque livreur ; `epoch+1` pour chacun | `audit_logs` + décision du règlement | C1, C5 (multi-parties) |
| `adminBillingCF` (`adminBilling.js`) | D (+C) | autorisé | super-admin | cible non `isDeleted` sinon refus tracé (D2) | helper par cible | `audit_logs` obligatoire | C1 |
| `adminOrderDisputeCF` (`adminOrderDisputes.js`) | D (+C) | autorisé | super-admin | idem | helper par cible ; flags avec `decidedBy` | `audit_logs` obligatoire | C1 |
| `partnerOrderActionCF` : `acceptPartnerOrder`, `startPreparation`, `markReady`, `refusePartnerOrder` | A | refusé | partenaire | — | wrapper + helper | existant | C2 |
| `partnerOrderActionCF` : `declareCashNonPayment` | A | refusé si client ou partenaire fermé **[A]** | partenaire | — | helper | existant | C2 |
| `partnerOrderActionCF` : `declareCashHandover`, `confirmCashRemittance`, `disputeCashRemittance` | B | autorisé | livreur / partenaire concernés | non `isDeleted` | helper ; statut de remise | existant | C1 |
| `partnerOrderActionCF` : `resolveCashRemittance`, `reviewCashNonPayment` | D | autorisé | super-admin | — | helper ; `review.byUid` enregistré | `audit_logs` obligatoire | C1 |
| `ekCancelOrderCF` (`ekbineOrders.js:199`) | C | autorisé (client peut clôturer une commande engagée, D-13) | client propriétaire | client toujours remboursé | helper ; **flag Ekbine dans la transaction** (§5) ; `epoch+1` | audit dans la transaction | C1, C6 |
| `ekClientConfirmOrder` (`ekbineOrders.js:283`) | B | autorisé pour le **client** ; **agent en quarantaine ⇒ refus** (D-13) | client propriétaire | agent présent, non `isDeleted`, tombstone absent | helper pour client **et** agent ; aujourd'hui seul l'agent est relu | audit dans la transaction (existant) | C1, C6 |
| `ekCreateOrderCF`, `ekbineAcceptOrder` | A | refusé | — | — | gardes existantes (non commitées) | existant | C2 |
| `manageProfessionalSubscription` (`professionalSubscriptions.js`) | A (renouvellement, débit du portefeuille) | refusé ; `suspend` et `deactivateVip` restent permis (protection) | admin | — | tombstone relu dans la transaction (garde existante, non commitée) | existant | C2 |
| Créations de commande (devis, catalogue, partenaire, boutique, événements) | A | refusé | — | — | gardes existantes (HEAD) | existant | C2 |
| `initiateFeexPayPayment`, `initiateWithdrawal` | A | refusé | — | — | garde existante (HEAD) | existant | C2 |
| `feexPayWebhook` (crédit) | B | crédit si demande antérieure au tombstone, sinon `held_for_review` ; **en `sealed` : `held_for_review`** | système | profil anonymisé ⇒ aucun crédit | helper ; jamais d'échec silencieux | journal existant | C4 |
| Recharges administratives (`adminDriverRechargeCF`, `adminApproveRechargeCF`) | D | refusé pour une cible fermée (garde HEAD) | super-admin | cible | garde existante | existant | C1 |

Règles transversales **[P]** : aucun writer du tableau n'écrit un journal ou un flag hors de sa transaction ; aucun ne crédite un profil anonymisé ; une opération refusée laisse l'état strictement identique (aucune écriture partielle).

---

## 5. Ekbine : origine serveur et écriture atomique

### 5.1 Faits **[F]**

| Flag | Écrit par | Acteur réel | Écriture | Champs |
|---|---|---|---|---|
| `ekcancel_<orderId>` | `ekCancelOrderCF` | le client appelant | **après** la transaction (`ekbineOrders.js:264-268`) ; l'audit précédent avale ses erreurs (`index.js:300-312`) | `kind, orderId, clientId, status, createdAt` |
| `ekconfirm_<orderId>` | `ekClientConfirmOrder` | le client appelant | dans la transaction, avec une ligne d'audit (`ekbineOrders.js:318-326`) | `kind, orderId, clientId, agentId, amount, status, createdAt` |

La commande annulée porte `cancelledBy`, `cancelledAt` écrits dans la transaction d'annulation (`ekbineOrders.js:244-248`).

### 5.2 Contrat d'origine **[P]**

Champ ajouté par le serveur, jamais par le client :

```
origin: {
  uid        : request.auth.uid                      // identité réelle
  role       : 'client'                              // déduit de la collection du profil lu dans la transaction
  action     : 'ek_cancel_order' | 'ekbine_confirm_order'   // événement générateur
  eventRef   : 'ekbine_orders/<orderId>'             // annulation (cancelledBy/cancelledAt, même transaction)
               | 'audit_logs/<auditDocId>'           // confirmation (identifiant connu, tx.set dans la même transaction)
  atMs       : horloge serveur de la transaction     // date
  flagRef    : 'reconciliation_flags/ekcancel_<orderId>' | '.../ekconfirm_<orderId>'
  originProof: 'transactional'
}
decidedBy: origin.uid        // alias lu par le moteur (`originBy`, accountObligations.js:559)
```

### 5.3 Atomicité

1. Le flag est créé par `tx.create` dans la transaction de l'annulation ou de la confirmation. Un rejeu (`alreadyDone`) ne recrée rien.
2. Pour l'annulation, l'audit passe dans la transaction (`tx.set` avec identifiant connu), comme pour la confirmation.
3. Le protocole du §1.4 s'applique (lecture du tombstone du client et, pour la confirmation, de l'agent ; `epoch+1`).

### 5.4 Vérification au moment de la résolution (writer de décisions)

Le serveur recalcule `origin.uid` depuis l'objet source (`cancelledBy === clientId` et `cancelledAt` pour l'annulation ; ligne d'audit référencée pour la confirmation) et refuse la résolution si les valeurs diffèrent.

### 5.5 Anciens flags **[AP D-8]**

Les flags créés sans `origin`/`decidedBy` restent **bloquants** (`ORIGIN_DECIDER_REQUIRED`, `accountObligations.js:243`). Aucune reconstitution automatique. Sortie possible, à décider **[A]** : clôture hors système par décision N2 avec preuve, ou outil futur de reconstitution marqué `originProof:'reconstructed'` et validé par deux responsables.

### 5.6 Flags perdus

Les annulations passées dont le flag n'a pas été écrit (arrêt entre commit et écriture) ne sont pas détectables par le moteur, qui ne lit pas `ekbine_orders` **[R]**. Un contrôle de rapprochement en lecture seule (commandes `cancelled`, `paymentMethod:'wallet'`, `refunded:false`, sans flag) est proposé en L8 ; son intégration à la décision de suppression d'un client exige d'étendre le périmètre du moteur ou de l'inspecteur **[A]**. Les agents Ekbine conservent leurs protections actuelles (D-12).

---

## 6. Audit des cinq fichiers non commités

Méthode : `git diff` en lecture seule, comparaison avec les rapports 7E-68, 7E-72, 7E-73, 7E-93 à 7E-95. Aucun fichier modifié.

| Fichier | Changements (diff) | Origine | Lien avec les lots | Risque de chevauchement | Préservation |
|---|---|---|---|---|---|
| `functions/ekbineOrders.js` | +8 lignes : import de `assertNewAccountActivity` ; garde client dans `ekCreateOrderCF` (l.148) ; garde **agent** dans `ekClientConfirmOrder` (l.309) ; garde agent dans `ekbineAcceptOrder` (l.354) | **Connue** : mission 7E-72 (+8) et 7E-68, « commit 3 E-Kbine » (7E-95 §Commit 3) ; décision métier 7E-73 | **L6** réécrit la même fonction (flag dans la transaction, `origin`) ; **L4/L5** passent par `assertFinancialLock` | **élevé** : mêmes lignes et mêmes fonctions que L6 ; avertissement Git « LF remplacé par CRLF » à la prochaine écriture | commiter d'abord (autorisation requise) ou sauvegarder un patch hors dépôt avant L6 ; ne pas normaliser les fins de ligne dans le même commit |
| `functions/index.js` | +2 lignes dans `setPharmaciePassword` (l.~1880) : `assertTargetNotClosing(db, HttpsError, [pharmacieId, currentUid], profil)` | **Connue** : 7E-68 hunk 8 « P3 / commit 3b » ; les hunks 1 à 7 sont dans HEAD (7E-94, 7E-95 §20) | **L3** (`onCallClosing`) et **L5** modifient `index.js` | **moyen** : même fichier, régions distinctes (wrapper l.83-90, exports l.2435-2845, hunk P3 l.1880) | rattacher le hunk P3 au commit 3b avant L3 ; utiliser une indexation par hunks (`git apply --cached` d'un patch isolé) |
| `functions/professionalSubscriptions.js` | +3/−1 : relecture de `account_tombstones/{docId}` dans la transaction, condition `closing \|\| deletionRequested \|\| isDeleted` | **Connue** : 7E-68 ; classée « sans lien avec le moteur P1 », à rattacher au commit 3b (7E-95 §49) | catégorie A du §4 ; compatible avec le protocole (lecture seule) ; L1 pourrait remplacer la lecture par le helper | **faible** | commiter avec 3b ; ne pas toucher avant décision |
| `functions/adminPartnerAccounts.js` | +3 : import et `assertTargetNotClosing(db, HttpsError, [uid])` avant changement de mot de passe | **Connue** : 7E-68, P3 / commit 3b | aucun writer financier ; hors L1–L8 | **faible** | commiter avec 3b |
| `functions/passwordReset.js` | +3 : import et `assertTargetNotClosing(db, HttpsError, [accountDoc.id, currentUid])` | **Connue** : 7E-68, P3 / commit 3b | idem | **faible** | commiter avec 3b |

Éléments connexes non commités : `functions/test/passwordReset.test.js` (+2), `functions/test/restaurantV2Preprod.test.js` (+1/−1, rapporteur du processus fils, « commit 3 indépendant » selon 7E-72 §1), `functions/test/ekbineQuarantineGuards.test.js` (nouveau, 11 tests), et les non-suivis `functions/accountObligations.js` et `functions/test/accountObligations.test.js` (**le moteur n'est pas dans HEAD**).

Observations **[F]** :
1. `assertTargetNotClosing` lit hors transaction ; elle ne protège que des opérations d'accès (mot de passe), pas des écritures financières. Elle reste hors protocole du §1.
2. Les trois gardes de `ekbineOrders.js` sont des lectures seules : elles ne bumpent pas `epoch`. Le lot L6 devra les convertir au helper.
3. Divergence documentée : le registre 7E-87 D3 (recommandation de créditer) n'est pas suivi ; la décision 7E-73 fait foi (D-13).

Recommandations **[P, A]** : décider d'abord le sort de ces fichiers (commit 3 E-Kbine, commit 3b, commit indépendant du test) avant L3 et L6 ; préserver par patch local daté ; exclure les `.aab` et autres non-suivis de toute indexation ; ne jamais utiliser `git add .`, `stash`, `checkout --` ni `reset`.

---

## 7. Matrice finale des lots

Séparation : **W** protections des writers ; **R** writer du registre ; **I** intégration des inspecteurs ; **E** tests en émulateur ; **P** mesures en préproduction. Chaque lot = un commit local distinct après revue, avec indexation par chemins explicites. Aucun lot n'est commencé.

| Lot | Piste | Fichiers | Dépend de | Invariants financiers | Tests | Critères de validation | Autorisation nécessaire |
|---|---|---|---|---|---|---|---|
| **L0** | E | aucun fichier de code | — | aucun changement de comportement | suite sous Node 22.23.4 ; 169 tests ignorés (émulateurs isolés, projet `demo-*`) | 0 échec ; liste des ignorés exécutés et comptés | exécuter des émulateurs ; désigner la machine Node 22 |
| **L1** | W | helper dans `accountAdmission.js` (ou module neuf) ; test neuf ; registre `FINANCIAL_WRITERS` | L0 | aucune écriture pour un compte actif ; fail-closed | tests purs : absent/closing/sealed/profil absent/`isDeleted`/lecture en erreur | tests voisins inchangés ; aucun branchement | oui (nom, schéma) |
| **L2** | I | `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js` ; tests | L1 ; décision sur le moteur non commité ; pilotage par `operations_control` | jamais de `deleteUser` sans T2b réussi ; `epoch` inchangé ; scellé jamais rouvert par délai | séquence complète avec Auth simulé ; échecs A1/T2b/F/D | tests voisins verts ; cas §3.1 couverts | **oui** (modifie les inspecteurs ; moteur à intégrer dans HEAD) |
| **L2R** | W (D) | callable `recoverSealedClosureCF` (module neuf), `index.js` | L1, L2 | réouverture jamais sans état Auth vérifié, inspection complète et audit strict ; `deleting:true` ⇒ N2 | tests purs + règles de rôle | §1.6 vérifié point par point | oui (nouvelle fonction d'administration) |
| **L3** | W | `index.js` (`onCallClosing`, liste fermée de 4), `accountAdmission.js` (helpers 7E-97) | L1 ; sort de `index.js` non commité | acteur et bénéficiaires relus en transaction avant toute écriture | test de câblage : `onCallClosing` seulement pour la liste | idem | oui |
| **L4** | W | `orderActions.js`, `orderRefunds.js` : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof`, journaux dans la transaction | L1, L3 | pas de solde négatif ; une transaction ; crédit omis ⇒ flag ; rien d'écrit sur refus | 7E-97 §8 (#1–#16, #23, #24) + C1, C3 | rejeu idempotent ; collisions d'identifiants exclues | **oui** (code d'argent) |
| **L5** | W | `feexpayPayments.js`, `transferSettlement.js`, `adminBilling.js`, `adminOrderDisputes.js`, `partnerOrderActions.js`, `index.js` (`autoExpireOrders`, `refundExpiredBoutiqueOrderCF`) | L1, L3 | aucun crédit vers un profil `isDeleted` ; refus de toute l'approbation si un livreur est fermé ; `held_for_review` en scellé | 7E-97 #17–#20 + C1, C4, C5 | idem | **oui** ; **D-10** : outil `held_for_review` requis avant activation FeexPay |
| **L6** | W | `ekbineOrders.js` : flag et audit dans la transaction, `origin`/`decidedBy`, helper client + agent | L1 ; arbitrage du commit 3 E-Kbine | flag créé exactement une fois ; aucune perte | tests de rejeu, refus, cohérence `origin` ; C6 | 11 tests `ekbineQuarantineGuards` verts | **oui** |
| **L7** | R | module neuf (writer de décisions et de preuves), règles Firestore/Storage, mise à jour de la liste CLAUDE.md | L1, L2 ; schéma 2D-2A.1 Q4 | N2 : deux responsables ; N3 indisponible ; preuve relue par le serveur ; `requestId` unique | règles + unité + concurrence sur `requestId` | conformité au schéma | **oui** (règles et charte) |
| **L8** | W/I | contrôle de rapprochement des flags Ekbine perdus (lecture seule) | L6 | aucune écriture | tests purs | — | oui (extension de périmètre) |
| **E1** | E | aucun | L1–L6 | — | C1 à C6 (§8) ; échec Auth et reprise | zéro effet financier validé après `sealed` ; zéro `deleteUser` sans T2b | exécuter des émulateurs isolés |
| **P1** | P | aucun | E1 | — | données `synthetic-*` sur un environnement **distinct de la production** ; mesure du budget de lectures (2D-2A §5.4) ; concurrence réelle | lectures conformes à 2D-2A §5.1 (écart ≤ 5 %) | désigner l'environnement ; autorisation explicite |

Ordre : L0 → L1 → {L3, L2, L2R} → L4 → L5 → L6 → L7 → (L8) → E1 → P1. **L2 (intégration du moteur) ne doit pas être activé avant L4 et L5** : sans verrou ni gardes de bénéficiaires, la fenêtre reste ouverte (7E-97 §9 étape 2).

---

## 8. Tests de concurrence à prévoir (émulateurs isolés, aucun lancé ici)

| Id | Scénario | Résultat attendu |
|---|---|---|
| C1 | writer B/C/D vs T2b, 25 rondes minimum, délais aléatoires | soit le writer valide et T2b échoue (`epoch`), soit T2b valide et le writer est refusé ; jamais les deux |
| C2 | writer A vs T1 puis vs `closing` | aucune écriture après le tombstone |
| C3 | deux appels identiques du même writer (double paiement, double annulation) | un seul effet |
| C4 | webhook ou planificateur vs `sealed` | `held_for_review` ou report, aucun crédit perdu ni double |
| C5 | approbation multi-livreurs dont un livreur fermé | refus complet, aucun crédit partiel |
| C6 | annulation Ekbine : arrêt simulé entre les écritures | flag toujours présent (même transaction) |
| C7 | T2b concurrent avec lui-même (deux processus) | un seul passe en `sealed` |
| C8 | arrêt entre T2b et D, puis `drain` | reprise sans déverrouillage ; alerte seulement |
| C9 | échec de `deleteUser`, résultat indéterminé, `getUser` | décision selon §3.4 |
| C10 | récupération administrative avec bail actif, `deleting:true`, un seul super-admin | refus ou attente (N2) |

---

## 9. Hypothèses et risques non résolus

**Hypothèses [H]** (à vérifier par E1 puis P1) :
1. **H1** Le conflit entre transactions qui lisent puis écrivent un même document est appliqué en production comme en émulateur.
2. **H2** La contention sur un document tombstone par compte reste acceptable (écritures rares).
3. **H3** Un `deleteUser` interrompu laisse l'état Auth déterminable par `getUser`.
4. **H4** Les jetons déjà émis ne contournent aucun contrôle de tombstone des fonctions protégées.

**Risques [R]** :
1. Writers non migrés ou écritures hors protocole (scripts, console) : non couverts.
2. Un `sealed` bloqué suspend les règlements du compte jusqu'à reprise ou récupération administrative ; les alertes dépendent d'un support disponible.
3. Un crédit en quarantaine simple immobilise le compte (7E-97 R6).
4. Le moteur n'est pas dans HEAD ; l'intégration suppose de le commiter avant L2.
5. Les fichiers non commités se chevauchent avec L3 et L6 (§6).
6. Flags Ekbine d'annulation déjà perdus : indétectables par le moteur.
7. Récupération administrative à un seul super-admin : les cas `deleting:true` restent en attente (D-6).
8. 169 tests ignorés non exécutés ; Node 22.23.4 non validé ; aucune mesure de lectures.
9. `held_for_review` : outil de résolution absent ; FeexPay doit rester désactivé (D-10).

## 10. Décisions humaines requises **[A]**

1. Valider le schéma du tombstone (§1.1) et le helper unique (§1.4).
2. Valider la procédure de récupération administrative (§1.6), notamment N2 pour `deleting:true`, et la liste des motifs.
3. Valider la classification du §4, en particulier les lignes « par analogie » (boutique expirée, `autoExpireOrders`, remises d'espèces, `declareCashNonPayment`).
4. Valider les seuils d'alerte (§2).
5. Décider du sort des cinq fichiers non commités et du moteur (§6).
6. Décider de l'annulation d'une demande de suppression (levée de tombstone), hors périmètre actuel.
7. Décider du sort des anciens flags Ekbine et de l'extension du contrôle des flags perdus (§5.5, §5.6).
8. Désigner l'environnement de préproduction et autoriser les émulateurs isolés.
9. Confirmer que le délai de 24 h reste exclu.

Je m'arrête ici. Aucun lot (L0, L1 ou autre) n'est commencé sans nouvelle autorisation explicite.
