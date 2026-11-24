# Mission 7E-67 — Périmètre de déploiement recommandé (suppression de compte)

Date : 2026-11-06 · Projet `az-express-b0469` · Document de **recommandation** : rien n'est déployé ni activé. Fondé sur `docs/ACCOUNT_DELETION_7E67_FUNCTION_RISK_MATRIX.md`. Tout déploiement exige une autorisation distincte et un lot ciblé (`--only functions:a,functions:b`), jamais global.

## Principe

Redéployer une fonction depuis le code local lui donne la garde en tête (wrapper `onCall`, `functions/index.js` l.79-85) mais embarque aussi les différences local/prod de ses modules (`index.js`, `ekbineFlow`, `eventReservations`, `professionalSubscriptions`, `adminPartnerAccounts`, `passwordReset`, `azia/index`, `azia/tools/*`). Chaque lot doit donc être précédé d'un diff prod↔local et suivi des tests.

## Priorité 0 — Les 4 fonctions de suppression (nouvelles, jamais déployées)

`requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`. Dépendances : `accountDeletion.js`, `accountDeletionSupport.js`, `accountCleanup.js`, `partnerAccountDeletion.js`, `accountAdmission.js`, `accountPersonalAssets`, `checkRateLimit`, `logAudit`. **Ne pas déployer avant la priorité 1.** Coût quota ≈ +1,25 Σ(cpu×maxInstances).

## Priorité 1 — Protection obligatoire (16 fonctions)

Paiements : `initiateFeexPayPayment`, `initiateWithdrawal`. AZ IA : `aiConfirmAction`, `azIaChat`. E-Kbine : `ekClientConfirmOrder`, `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`. Wallet/réservations : `createEventReservationCF`, `manageProfessionalSubscription`. Comptes : `resetAccountPassword`, `setArtisanPin`, `artisanLogin`, `pharmacieLogin`, `setPharmaciePassword`, `manageAdminPartnerAccount`.

Travaux locaux préalables (non faits dans 7E-67) : relecture du tombstone dans la transaction pour les 3 fonctions financières/IA (`index.js` l.373 et l.608, `azia/pendingActions.js`), garde sur le compte cible pour les changements de mot de passe, tests §7 de la matrice. Dépendance : `feexpayPayments.js` inchangé (identique prod/local).

## Priorité 2 — Fortement recommandée (14 fonctions)

`clearAiHistory`, `aiSendDueReminders`, `ekbineUpdateDepositAccounts`, `checkWithdrawalStatus`, `createSubAdmin`, `deleteSubAdmin`, `republishMarketplaceProduct`, `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `upsertRealEstateLocation`, `moderateVehicleEntity`, `syncPharmacyGuards`. Peut suivre dans un second lot, **avant** d'ouvrir la suppression aux rôles concernés (E-Kbine, immobilier, marketplace, pharmacies).

## À ne PAS déployer pour la garde (Liste 3, 44 fonctions)

Webhook `feexPayWebhook` et réconciliations (`checkPendingWithdrawals`, `walletReconciliationCheck`, `syncDriverOrderLifecycle`) : jamais de blocage ; seule une journalisation `creditedAfterDeletion` est envisagée (décision D1). Triggers de notification et tâches de maintenance : inchangés.

## Ordre proposé

1. Validation des rapports 7E-66 et 7E-67 ; décisions D1-D5.
2. Commit local (autorisation distincte) des fichiers 7E-64 et des corrections de la priorité 1.
3. Tests locaux et règles (`npm test`, `npm run test:rules`).
4. Clarification du quota Cloud Run (statut « non confirmé »).
5. Déploiement du lot priorité 1 (16 fonctions), vérification `firebase functions:list --project az-express-b0469`.
6. Déploiement des 4 fonctions de suppression ; Hosting des pages légales.
7. Test réel sur compte de test dédié ; seulement ensuite création de `operations_control/account_deletion` (autorisation distincte).
8. Lot priorité 2 avant l'ouverture aux rôles partenaires (`partnerInventoryVersion`).

## Estimation

Minimum sûr : **16 + 4 = 20 fonctions** ; recommandé : **30 + 4 = 34**. Quota : non confirmé (Σ actuel 166,5 ; chaque fonction redéployée garde ses valeurs cpu/maxInstances, donc aucun accroissement net hors les 4 nouvelles ≈ +1,25) — **[H]**, car le redéploiement crée de nouvelles révisions Cloud Run qui peuvent transitoirement doubler la consommation.

## Mise à jour Mission 7E-68 (corrections locales, rien déployé)

Le code modifié en 7E-68 change le périmètre ci-dessus ; détails et preuves dans `docs/ACCOUNT_DELETION_7E68_LOCAL_HARDENING_REPORT.md`.

- **Webhook `feexPayWebhook` entre dans le périmètre** : son code (module `feexpayPayments.js`) est désormais modifié (mise en attente tracée d'un paiement tardif, statut `held_for_review`). Il n'est toujours pas enveloppé par la garde callable.
- **Lot financier / IA** (à valider d'abord) : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `azIaChat`, `feexPayWebhook`. Prérequis : valider les ajouts métier locaux embarqués (`assertPartnerActivated`, `assertDriverRechargeAllowed`, outils AZ IA `delivery`/`marketplace`/`ekbine`).
- **Lot comptes** : `resetAccountPassword`, `setPharmaciePassword`, `pharmacieLogin`, `setArtisanPin`, `artisanLogin`, `manageProfessionalSubscription`, `createEventReservationCF`.
- **À isoler, revue métier obligatoire avant tout déploiement** : `ekClientConfirmOrder`, `ekbineAcceptOrder` (module `ekbineOrders.js` absent de la production, logique de crédit refondue), `manageAdminPartnerAccount` (module −46/+355 lignes), ainsi que `ekbineAgentDepositAction`/`ekbineSubmitDepositProof` si le lot E-Kbine est redéployé en bloc. Ces fonctions restent protégées côté local mais ne doivent pas être déployées « pour la garde » sans validation.
- **Moteur de suppression** : inchangé en périmètre (4 fonctions), avec la barrière D3 (aucun administrateur traité automatiquement). Configuration `operations_control/account_deletion` toujours à ne pas créer.
- **Manquant avant activation** : outil d'administration pour résoudre un paiement `held_for_review` (aucun remboursement réel n'a été implémenté).
- **Quota Cloud Run : toujours NON CONFIRMÉ** ; aucun déploiement n'est annoncé comme possible.
