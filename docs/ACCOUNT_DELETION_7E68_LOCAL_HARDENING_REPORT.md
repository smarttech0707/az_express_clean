# Mission 7E-68 — Corrections locales et sécurisation de la suppression de compte

Date : 2026-11-06 · Branche `finalisation/az-express` (HEAD `aa3d1b0`, inchangé) · Projet de référence `az-express-b0469`.
**Modifications locales uniquement.** Aucun déploiement, aucune écriture distante, aucune activation, aucun commit, aucun push. `operations_control/account_deletion` reste absent en production (vérifié en 7E-62/66, non modifié ici).

Légende : **[V]** vérifié par test ou lecture de code · **[H]** hypothèse · **NON CONFIRMÉ**.

## 1. État initial et sauvegardes

- Branche `finalisation/az-express`, 12 fichiers déjà modifiés par 7E-64 (moteur de suppression, pages légales, tests de règles), plus les fichiers non suivis listés dans le brief initial. Rien n'a été écrasé ni supprimé ; les fichiers `.aab`, patch, logs, `qr-release/`, `scripts/maintenance/`, `web/downloads/`, `.firebase/…cache` n'ont pas été touchés.
- Rapports 7E-66 et 7E-67 présents dans `docs/`.
- **Sauvegardes locales (avant modification)** : `C:\Users\User\AppData\Local\Temp\claude\d--az-express-clean\c579b050-5748-4442-a523-d168d26fdffb\scratchpad\backup68\functions\` — `index.js`, `accountDeletion.js` (+ `accountDeletion.before68d.js`), `accountAdmission.js`, `feexpayPayments.js`, `azia\index.js`, `azia\pendingActions.js`, `ekbineFlow.js`, `eventReservations.js`, `passwordReset.js`, `adminPartnerAccounts.js`, `ekbineOrders.js`, `professionalSubscriptions.js`. Les copies de `index.js`/`accountDeletion.js` correspondent à l'état de fin de 7E-64 (le HEAD Git ne contient pas ces modifications 7E-64).

## 2. Fichiers modifiés par 7E-68

| Fichier | Nature |
|---|---|
| `functions/index.js` | import `assertNewAccountActivity`/`assertTargetNotClosing` ; garde transactionnelle dans `initiateFeexPayPayment` (création du paiement pending dans une transaction) et `initiateWithdrawal` (avant lecture/débit) ; contrôle de la pharmacie cible dans `setPharmaciePassword` |
| `functions/azia/pendingActions.js` | `aiConfirmAction` : tombstone/suppression relus dans la transaction de confirmation, avant tout `confirmHandler` |
| `functions/feexpayPayments.js` | webhook : statut `held_for_review`, `shouldHoldPayment`, aucun crédit silencieux sur profil supprimé |
| `functions/accountAdmission.js` | nouveau `assertTargetNotClosing` |
| `functions/passwordReset.js`, `functions/adminPartnerAccounts.js` | refus si le compte CIBLE a un tombstone |
| `functions/ekbineOrders.js` | `ekbineAcceptOrder` : garde dans la transaction |
| `functions/professionalSubscriptions.js` | tombstone lu dans la transaction de débit/activation |
| `functions/accountDeletion.js` | décision D3 : barrière « compte administrateur » |
| `functions/test/passwordReset.test.js` | le double de test gagne une lecture `get` de document (requise par la garde réelle) — extension, aucune assertion modifiée |
| `functions/test/accountQuarantineIndex.test.js` (nouveau) | 11 tests de bout en bout sur `index.js` |
| `functions/test/accountQuarantineGuards.test.js` (nouveau) | 16 tests AZ IA / webhook / D3 / cibles |

## 3. Comparaison production / local des 16 fonctions de la Liste 1

Méthode **[V]** : corps de fonction extrait de `index.js` déployé (instantanés g0/g8) et du local, lignes vides et commentaires ignorés ; modules comparés à `git show HEAD:` (état local avant 7E-68). Le local n'est **pas** tenu pour supérieur : les écarts ci-dessous sont des fonctionnalités d'autres missions déjà présentes dans la branche.

| Fonction | Code local | Code production | Différences | Risque de régression | Action |
|---|---|---|---|---|---|
| `initiateFeexPayPayment` | `index.js` l.≈373 | g0 `index.js` l.251 | local : `assertPartnerActivated` (partenaire non activé) et `assertDriverRechargeAllowed` (politique de recharge livreur, module `driverWalletPolicy`) ; aucune ligne prod absente du local | MOYEN : règles métier livreur/partenaire embarquées | Garde transactionnelle ajoutée ; validation métier des 2 ajouts avant déploiement |
| `initiateWithdrawal` | `index.js` l.≈608 | g0 l.476 | local : `assertPartnerActivated` seulement | FAIBLE | Garde ajoutée |
| `feexPayWebhook` | `index.js` l.≈560 + `feexpayPayments.js` | g0 l.420 | corps identique ; module `feexpayPayments` identique avant 7E-68 | FAIBLE | Traitement spécial (§5) |
| `checkWithdrawalStatus` (Liste 2) | l.≈803 | g0 l.668 | local : `requireWithdrawalAccess` (remplace un contrôle admin inline), `notificationGuard` pour les FCM | MOYEN : autre chemin d'autorisation | Non modifié (wrapper d'entrée seulement) |
| `ekClientConfirmOrder` | `ekbineOrders.js` `buildEkClientConfirmOrder` | g0 l.1814 (inline) | refonte complète : preuve de débit (`creditFor`), `agentCredited`, drapeaux de réconciliation, idempotence | **ÉLEVÉ** : logique de crédit différente | Non modifié ; entrée gardée par le wrapper ; revue métier requise avant déploiement |
| `ekbineAcceptOrder` | `ekbineOrders.js` | g0 l.1883 (inline) | local : acceptation directe `deposit_confirmed` si débit wallet prouvé, snapshots de compte de dépôt | **ÉLEVÉ** | Garde transactionnelle ajoutée ; revue métier requise |
| `ekbineAgentDepositAction`, `ekbineSubmitDepositProof` | `index.js` | g0 l.1991 / 1965 | corps identiques ; `ekbineFlow` : 1 ligne | FAIBLE | Non modifiés (wrapper d'entrée) |
| `createEventReservationCF` | `eventReservations.js` | g0 | corps identique ; module : +7 lignes (garde `assertNewAccountActivity` déjà présente) | FAIBLE | Déjà protégé localement |
| `manageProfessionalSubscription` | `professionalSubscriptions.js` | g0 l.1391 | corps identique ; module : −13/+33 lignes (refus des comptes en suppression, opérations de protection autorisées) | MOYEN | Tombstone ajouté dans la transaction |
| `resetAccountPassword` | `passwordReset.js` | g0 l.1383 | module : +3 lignes (refus `isDeleted`) | FAIBLE | Refus des cibles en suppression ajouté |
| `setArtisanPin`, `artisanLogin` | `artisanAccounts.js` | g0 | identiques (prod = local) | NUL | Non modifiés (voir D4) |
| `pharmacieLogin` | `index.js` | g0 | local : +1 ligne (`isDeleted` → `success:false`) | FAIBLE | Non modifié |
| `setPharmaciePassword` | `index.js` | g0 | corps identique ; `adminGuards` : +32 lignes | FAIBLE | Contrôle de la pharmacie cible ajouté |
| `manageAdminPartnerAccount` | `adminPartnerAccounts.js` | g0 l.54 | module **−46/+355 lignes** (refonte de la gestion des comptes partenaires) | **ÉLEVÉ** | Garde « cible » ajoutée ; **ne pas redéployer sans validation métier dédiée** |
| `azIaChat` | `azia/index.js` | g0 | corps identique ; `azia/index` −4/+38, outils `delivery` +25, `marketplace` −17/+83, `ekbine` +9 | MOYEN (outils de commande modifiés) | Non modifié (garde d'entrée du wrapper) |
| `aiConfirmAction` | `azia/pendingActions.js` | g8 | local = prod sauf 1 ligne ; mêmes outils que `azIaChat` | MOYEN (via outils) | Garde transactionnelle ajoutée |

Aucune différence de validation ou de sécurité de la production n'a été supprimée : dans les 16 corps comparés, la production ne contient **aucune ligne absente** du local (hors refactorisations E-Kbine et du contrôle d'accès de `checkWithdrawalStatus`, qui déplacent la logique).

## 4. Garde centrale de quarantaine (wrapper `onCall`)

Examen de `functions/index.js` l.79-88 et `accountDeletion.assertAccountEnabled` :

- Identité = `request.auth.uid` fournie par Firebase ; jamais une donnée du corps de requête **[V]**.
- Tombstone cherché à `account_tombstones/{uid}` avec ce même UID ; exécuté **avant** le traitement métier **[V]**.
- Une erreur de lecture Firestore fait échouer l'appel (la promesse est rejetée, pas avalée) → fail-closed **[V : test « erreur de lecture »]**.
- Appels internes : les callables ne s'appellent pas entre eux ; les outils AZ IA appellent leurs `confirmHandler` en direct, donc uniquement via `aiConfirmAction`/`azIaChat` (protégés) **[V par lecture]**.
- **Insuffisante seule** pour les écritures financières (fenêtre entre contrôle et écriture) → relecture dans la transaction ajoutée pour recharge, retrait, confirmation AZ IA, acceptation E-Kbine, abonnements. Les 2 tests « quarantaine posée après la garde d'entrée » le démontrent **[V]**.
- Triggers, planifiées et webhooks HTTP ne sont **pas** enveloppés (voulu) **[V : test de source]**.
- `uid` absent (appel non authentifié) : le wrapper n'ajoute pas de refus ; la fonction refuse elle-même (`unauthenticated`) **[V par lecture]**.
- Limite : le wrapper ne vérifie que le tombstone, pas `isDeleted` du profil ; les fonctions financières ajoutent ce contrôle dans leur transaction.

## 5. Corrections prioritaires

### A. `aiConfirmAction`
`buildConfirmAction` appelle `assertNewAccountActivity(tx, db, HttpsError, uid)` dans la transaction de confirmation, **avant** toute exécution de `confirmHandler` (livraison, restaurant, pharmacie, marketplace, E-Kbine, recharge). Il relit le tombstone et refuse un client `deletionRequested`/`isDeleted`. Une action préparée avant la quarantaine reste `pending` et n'est jamais exécutée. Tests : quarantaine, profil en suppression, profil anonymisé, erreur de lecture, double confirmation séquentielle, compte non concerné. **Limite honnête** : la recharge FeexPay est lancée en `afterConfirm`, après la transaction ; si la quarantaine apparaît dans cet intervalle, la demande `pending` existe déjà et c'est le webhook (traitement §5.D) qui la traite. **NON TESTÉ** : deux confirmations réellement concurrentes (le faux Firestore ne sérialise pas ; Firestore verrouille le document d'action, mais ce n'est pas prouvé ici).

### B. `initiateFeexPayPayment`
La création du `wallet_transactions` pending se fait dans une transaction qui relit le tombstone et le profil. Identifiants, `pending`/`uncertain`, rate limit, appel FeexPay et traitements d'erreur inchangés. Toute erreur de lecture : aucune demande créée, aucun appel opérateur (**[V]**).

### C. `initiateWithdrawal`
Contrôle en tête de la transaction existante, avant la lecture du solde : aucun débit ni `withdrawal_requests` ni payout en cas de quarantaine, profil anonymisé ou erreur de lecture (**[V]**). Solde, limites, rate limit, statuts et audit inchangés. Les compensations d'un retrait déjà engagé (`compensateFailedWithdrawal`, scheduler `checkPendingWithdrawals`) ne sont pas modifiées.

### D. `feexPayWebhook` — traitement spécial (décision D1)
Authenticité du webhook inchangée (secret d'URL + `createStatusVerifier` auprès de FeexPay, fail-closed), vérification du montant inchangée, idempotence inchangée. Nouveau, dans la transaction de crédit :

| Situation | Résultat |
|---|---|
| Profil actif, pas de tombstone | crédit normal |
| Tombstone **plus récent** que la demande de paiement (paiement antérieur à la quarantaine) et profil non anonymisé | crédit normal : l'argent est dû à l'utilisateur ; le solde non nul bloquera ensuite la suppression (inspection du moteur) |
| Demande de paiement créée **après** le tombstone, tombstone sans date lisible, ou profil `isDeleted` | **pas de crédit** : transaction `status:'held_for_review'`, `needsReview:true`, `reviewReason`, `credited:false`, `heldAt` ; `logSecurityEvent('webhook_paid_account_in_deletion')` + `logAudit('payment_held_account_deletion')` ; réponse HTTP 200 |
| Rejeu d'un webhook (crédité ou en attente) | `already_processed`, aucun effet |

La somme reste tracée sur la transaction (référence opérateur, montant vérifié) : réconciliation ou remboursement par intervention administrative. **Il n'existe pas encore de fonction d'administration pour résoudre un paiement `held_for_review`** : c'est un point ouvert (§9), à traiter par une mission dédiée (remboursement FeexPay = opération financière réelle, non réalisée ici). Aucune API FeexPay ni statut opérateur n'a été inventé.

## 6. Autres fonctions de la Liste 1

| Fonction | Traitement | Raison |
|---|---|---|
| `azIaChat`, `ekClientConfirmOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `createEventReservationCF` | garde d'entrée du wrapper (local) ; `createEventReservationCF` a déjà la relecture transactionnelle | le client en quarantaine n'a pas d'opération E-Kbine non terminale (inspection) ; le crédit agent d'une commande déjà terminée ne dépend pas de lui |
| `ekbineAcceptOrder` | + garde transactionnelle | un agent supprimé ne prend plus de course |
| `manageProfessionalSubscription` | + tombstone dans la transaction | débit wallet |
| `resetAccountPassword`, `manageAdminPartnerAccount`, `setPharmaciePassword` | + refus si la **cible** est en suppression | l'appelant peut être un administrateur sain |
| `setArtisanPin`, `pharmacieLogin` | non modifiés | `pharmacieLogin` refuse déjà `isDeleted` ; `setArtisanPin` identique prod/local |
| `artisanLogin` | non modifié (D4) | renvoie `success`, `docId` et les données de profil sans secret ; aucun jeton créé ; la suppression artisan est manuelle et anonymise le profil ; bloquer une connexion normale sans risque démontré est exclu |

## 7. Liste 2 (14 fonctions)

Callables (`clearAiHistory`, `ekbineUpdateDepositAccounts`, `checkWithdrawalStatus`, `createSubAdmin`, `deleteSubAdmin`, `republishMarketplaceProduct`, `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `upsertRealEstateLocation`, `moderateVehicleEntity`) : couvertes par la garde d'entrée du wrapper dans le local — **aucune modification de code**. Planifiées `aiSendDueReminders` et `syncPharmacyGuards` : non enveloppées, **non modifiées** ; le risque résiduel est un rappel FCM ou une garde rétablie pendant la quarantaine (FAIBLE) ; `eraseAiData` supprime les rappels à la fin du dossier.

## 8. Comptes administrateurs (D3) et jetons (D2)

- **D3 [V par test]** : un UID présent dans `admins` est refusé dès la demande (`ADMIN_ACCOUNT_MANUAL_PROCESS`, aucun dossier créé) ; un dossier existant dont le compte devient administrateur est bloqué (`admin_account_manual_process`, sans tombstone ni suppression Auth) avant tout traitement. Conséquence : **aucun administrateur, donc jamais le dernier super-administrateur, n'est supprimé automatiquement**. Pas de contrôle « dernier super-admin » séparé : il serait redondant. Intervention distincte et tracée = procédure manuelle hors moteur (`manageAccountDeletionCF`/support), non créée ici. Effet sur les autres rôles : un administrateur titulaire d'un profil client ne peut plus supprimer ce profil en libre-service (à documenter côté support).
- **D2** : la protection principale est le contrôle serveur du tombstone. Le moteur appelle déjà `revokeRefreshTokens` avant `deleteUser` ; aucune vérification de révocation (`checkRevoked`) n'est ajoutée aux callables (coût en latence, risque de régression de connexion non testé). Aucune session réelle n'est révoquée.

## 9. Scénarios de concurrence

| Scénario | Résultat |
|---|---|
| Compte actif au début, quarantaine avant l'écriture (recharge, retrait) | refus par la relecture transactionnelle **[V : tests]** |
| Deux confirmations simultanées d'une action AZ IA | une seule peut passer `pending → completed` (Firestore) ; **NON TESTÉ** avec un vrai Firestore |
| Retrait et demande de suppression simultanés | le moteur inspecte (retrait `processing` non terminal ⇒ dossier bloqué) puis réinspecte après 15 min ; un retrait posé juste avant le tombstone est vu à la 2ᵉ inspection **[lecture]** ; **NON CONFIRMÉ** : isolation exacte des requêtes de plage entre la 1ʳᵉ transaction du moteur et un retrait concurrent |
| Paiement initié juste avant la quarantaine | webhook : crédit (paiement antérieur) ; solde non nul ⇒ suppression bloquée jusqu'à régularisation **[V]** |
| Webhook après quarantaine / après anonymisation | crédit si antérieur et non anonymisé ; mise en attente tracée sinon **[V]** |
| Action AZ IA confirmée pendant la création du tombstone | si la lecture transactionnelle précède le tombstone, l'action s'exécute (état cohérent : commande + dossier ensuite bloqué par l'inspection) ; sinon refus **[lecture]** |
| Anonymisation après crédit tardif | l'inspection de la transaction finale du moteur refuse si `wallet ≠ 0` ; dossier `cleanup_pending`, profil non anonymisé **[lecture + test existant 7E-64]** |

Aucune de ces corrections ne retire, double ou déplace un solde.

## 10. Fonctions de suppression (relecture)

`requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF` : comportements 7E-64 inchangés (limiteur, plafond de demandes, demandes répétées, jeton de reprise, tentatives, audit strict avant Auth, inventaire avant Auth, 2ᵉ inspection après 15 min, blocages manuels). Compatibilité avec les protections : le moteur n'appelle aucune fonction gardée ; la barrière D3 s'ajoute. Configuration de production : absente ⇒ fermé (test « fermé par défaut » vert).

## 11. Tests

**Ajoutés (27)** : `accountQuarantineIndex.test.js` (11) — recharge/retrait actifs, en quarantaine, quarantaine tardive, profil anonymisé, erreur de lecture, autre compte, non-enveloppement du webhook/scheduler ; `accountQuarantineGuards.test.js` (16) — AZ IA (6), webhook (6), D3 (3), cible (1).

Correspondance avec les 14 exigences : 1 (compte actif) ; 2 (nouvelle commande via AZ IA refusée — les commandes SDK sont couvertes par les règles, non retestées) ; 3 retrait ; 4 recharge ; 5 action préparée avant ; 6 double confirmation (séquentielle) ; 7 webhook antérieur ; 8 webhook dupliqué ; 9 paiement tardif ; 10 jeton valide/Auth supprimé simulé par `isDeleted`/tombstone (le serveur ne dépend pas du jeton) ; 11 erreur de lecture ; 12 administrateur ; 13 compte non concerné ; 14 **non couverte** : aucune opération de support autorisée sur un compte en quarantaine n'a été ajoutée (la traçabilité de `manageAccountDeletionCF` est couverte par les tests 7E-64).

**Exécutés** (`D:\az_express_clean\functions`, hors réseau, faux Firestore) :
- Fichiers ciblés avant ajout de tests : 485 tests ; 4 échecs initiaux dus à mes modifications (2 : message de refus d'un partenaire supprimé dans `adminPartnerAccounts` ; 2 : double de test de `passwordReset` sans lecture de document). Correction du code pour le premier (refus conservé sur l'ancien message, seul le tombstone est ajouté) et extension du double pour le second ; **aucune assertion existante affaiblie**.
- `npm test` complet : **2299 tests, 2133 réussis, 0 échec, 166 ignorés** (tests d'émulateur ignorés sans émulateur). `node -c` OK sur les 9 fichiers de production modifiés.
- **Non exécutés** : `npm run test:rules` et les tests d'émulateur (Java/émulateur ; l'émulateur existant de l'utilisateur n'a pas été touché) ; ils n'ont donc **pas** confirmé les 3 fichiers `rules-tests/account-deletion*.test.js` après la barrière D3. `flutter analyze/test` non lancés (aucun fichier Dart modifié dans cette mission).

## 12. Risques encore ouverts

| Risque | Gravité |
|---|---|
| Aucun outil d'administration pour résoudre un paiement `held_for_review` (remboursement/crédit manuel) | ÉLEVÉ |
| Écarts métier embarqués au redéploiement (E-Kbine, `adminPartnerAccounts` −46/+355, outils AZ IA, politique de recharge livreur) | ÉLEVÉ |
| Concurrence réelle (double confirmation, retrait/suppression simultanés) non testée sur Firestore | MOYEN |
| Fenêtre d'environ 1 h de jeton valide pour les fonctions de la Liste 3 (webhook, planifiées) | FAIBLE |
| Recharge AZ IA lancée en `afterConfirm` après la transaction | MOYEN |
| `rules-tests` et émulateur non rejoués après D3 | MOYEN |
| Quota Cloud Run | **NON CONFIRMÉ** |
| Durées de conservation à valider juridiquement, TTL absent | MOYEN |

## 13. Décisions D1 à D5

- **D1** : mise en attente tracée (pas de crédit silencieux, pas de rejet) — **implémentée localement**, résolution administrative à construire.
- **D2** : contrôle serveur du tombstone comme protection principale ; pas de `checkRevoked` global — **retenue**.
- **D3** : aucun administrateur supprimé automatiquement — **implémentée**.
- **D4** : `artisanLogin`/`pharmacieLogin` examinées, aucune modification (aucun risque démontré) — **retenue**.
- **D5** : redéploiement des modules divergents — **non décidée** : à trancher par fonction (voir §3 et le périmètre).

## 14. Quota Cloud Run — estimation seulement

Les 16 fonctions de la Liste 1 sont déjà déployées : Σ(cpu×maxInstances) actuelle = 8 × 3 + 8 × 2 = **40** (sur 166,5 au total) ; un redéploiement reprend les `cpu`/`maxInstances` du code local, qui peuvent différer (ex. `ekClientConfirmOrder` : `maxInstances:2, cpu:0.5` dans le local contre 1 × 3 en production). Les 4 fonctions de suppression ajoutent ≈ +1,25. Révisions Cloud Run transitoires pendant un déploiement : **NON CONFIRMÉ**. **Le quota n'est pas confirmé ; aucun déploiement n'est annoncé comme possible.**

## 15. Périmètre pouvant être soumis à validation avant déploiement

À valider, par priorité (voir `docs/ACCOUNT_DELETION_7E67_RECOMMENDED_DEPLOYMENT_SCOPE.md`, mis à jour) :
1. Lot financier/IA : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `azIaChat` + `feexPayWebhook` (code modifié) — après validation des ajouts partenaire/livreur et des outils AZ IA.
2. Lot comptes : `resetAccountPassword`, `setPharmaciePassword`, `pharmacieLogin`, `setArtisanPin`, `artisanLogin`, `manageProfessionalSubscription`, `createEventReservationCF`.
3. À part, après revue métier : `ekClientConfirmOrder`, `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `manageAdminPartnerAccount`.
4. Les 4 fonctions de suppression en dernier, config toujours absente.

Rien n'a été commité, déployé ni activé. Autorisation distincte requise pour chacune de ces étapes.
