# Mission 7E-66 — Sûreté de la suppression de compte en production

Date : 2026-11-06 · Projet : `az-express-b0469` (n° 697217052961), région `europe-west1` · Mode : **lecture seule** (aucun déploiement, aucune écriture distante, aucun commit, aucune activation).

Légende : **[V]** fait vérifié · **[H]** hypothèse · **[N]** information non disponible. Gravité : CRITIQUE / ÉLEVÉ / MOYEN / FAIBLE / NON CONFIRMÉ.

## 1. Résumé exécutif

1. **[V]** Production = 95 fonctions (52 callables, 11 HTTP/planifiées, 32 triggers Firestore). Leur code est un patchwork de 9 instantanés : **74 fonctions (instantanés du 6 oct. et 17-18 oct.) ne contiennent ni module de suppression, ni vérification de tombstone, ni le wrapper `assertAccountEnabled`** ; 21 fonctions (28-30 oct.) les contiennent.
2. **[V]** Les quatre fonctions de suppression (`requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`) sont **absentes** de la production ; `operations_control/account_deletion` est absent (constaté en 7E-62 ; non relu ici) → le système est **fermé** : rien ne peut être mis en quarantaine aujourd'hui.
3. **[V]** Les règles Firestore et Storage déployées (28/10/2026) contiennent déjà `isAuth()` avec refus si `account_tombstones/{uid}` existe, `account_tombstones` fermé, `account_deletions` en lecture admin seule. **Les écritures directes du SDK client d'un compte en quarantaine sont donc bloquées en production** (pour les chemins protégés par `isAuth()`).
4. **[V]** Les règles **ne lient pas l'Admin SDK**. Un compte en quarantaine peut encore agir via les **~74 fonctions sans garde** (retraits, paiement FeexPay, E-Kbine, AZ IA, mots de passe, immobilier, etc.).
5. **[V/H]** Un jeton ID reste valide ~1 h après `deleteUser` : un callable sans garde ne vérifie pas la révocation (aucun `checkRevoked` dans `index.js`). La fenêtre de risque dépasse donc la quarantaine de 15 min.
6. **Recommandation** : **ne pas déployer les 4 fonctions seules**. Déployer d'abord (Option A+) un petit lot de fonctions financières/commande déjà sensibles, ou activer le moteur sans les fonctions B. Voir §6–§9. Activation de la config : **NON** tant que le lot de protection n'est pas déployé et testé.

## 2. Cartographie des fonctions de production

Source : `gcloud functions list --v2` (95), comparée aux instantanés de code déployés (`gs://gcf-v2-sources-…`) et au code local. Aucune fonction de production n'est absente du code local ; 40 fonctions locales n'existent pas en production. **[V]**

| Groupe | Date | Nb | Garde quarantaine | Fonctions |
|---|---|---|---|---|
| g0 | 6 oct. | 71 | **Non** | azIaChat, clearAiHistory, listAiToolExecutions, initiateWithdrawal, checkWithdrawalStatus, initiateFeexPayPayment, feexPayWebhook, ek* (5), notify* (≈27), createSubAdmin/deleteSubAdmin, manageAdminPartnerAccount, resetAccountPassword, setArtisanPin, setPharmaciePassword, artisanLogin, pharmacieLogin, checkClientPhone, createEventReservationCF, requestPropertyVisit/respondToVisitRequest, real estate (4), republishMarketplaceProduct, manageProfessionalSubscription, moderateVehicleEntity, logAuthEvent/logAdminAuditEvent, planifiées (aiCleanup…, aiSendDueReminders, checkPendingWithdrawals, cleanupExpiredRateLimits, expireMarketplaceProducts, fcmTokenCleanupCheck, staleDriverCleanupCheck, syncPharmacyGuards, walletReconciliationCheck) |
| g8 | 17-18 oct. | 3 | **Non** | aiConfirmAction, diagnoseDriverOccupancy, syncDriverOrderLifecycle |
| g1 | 28-30 oct. | 4 | Oui | cancelOrderCF, dispatchOrderToDriver, enforceOrderRateLimit, autoExpireOrders |
| g2 | 28-30 oct. | 5 | Oui | acceptOrderCF, declineLegacyOrderCF, releaseOrderBeforePickupCF, adminDriverRechargeCF, settleTransferEarningsCF |
| g3 | 28-30 oct. | 4 | Oui | manageArtisanPhotosCF, completePartnerFirstPasswordChange, completeManualAccountDeletionCF, createFleetDriverCF |
| g4 | 28-30 oct. | 4 | Oui | payBoutiqueOrderCF, payBoutiqueOrderCashCF, payOrderFromWalletCF, refundExpiredBoutiqueOrderCF |
| g5/g6/g7 | 28-30 oct. | 4 | Oui | deliverOrderCF, adminBillingCF, publishMarketplaceProduct, submitServiceProviderApplication |

Types par fonction (callable / HTTP-planifiée / trigger), CPU, maxInstances et concurrence : voir le tableau §3 ; la matrice brute est reproductible depuis `gcloud functions list --v2`.

Note : la création de commande « livraison/course/restaurant » part du **client Flutter vers Firestore** (règles), pas d'une fonction ; elle est donc couverte par `isAuth()` (règles). Les commandes E-Kbine passent par `ekCreateOrderCF`, **absente de production** (non listée) : seule la voie `ekbine*`/`ekClientConfirmOrder` (g0) existe. **[V]**

## 3. Fonctions et risque de quarantaine

| Fonction(s) | Type | Peut agir après demande de suppression ? | Gravité |
|---|---|---|---|
| initiateWithdrawal, checkWithdrawalStatus, checkPendingWithdrawals | callable / planif. | Oui (g0, sans garde). Le moteur exige solde = 0 et aucun retrait en attente à l'inspection, mais un retrait ou un suivi peut démarrer **après** la quarantaine ; le retrait d'un solde nul est rejeté, risque résiduel de retrait sur crédit tardif | ÉLEVÉ |
| initiateFeexPayPayment, feexPayWebhook | callable / HTTP | Oui : une recharge initiée peut créditer le wallet d'un profil en cours d'anonymisation (webhook volontairement non gardé) → solde non nul sur compte supprimé | ÉLEVÉ |
| ekClientConfirmOrder, ekbineAcceptOrder, ekbineAgentDepositAction, ekbineSubmitDepositProof, ekbineUpdateDepositAccounts | callable | Oui (g0) : écritures E-Kbine / crédits agent sur compte en quarantaine | ÉLEVÉ |
| azIaChat, clearAiHistory, listAiToolExecutions, aiConfirmAction (g8) | callable | Oui : une conversation AZ IA peut recréer `ai_conversations/{uid}` après l'effacement ; confirmation d'action possible | MOYEN (ÉLEVÉ pour aiConfirmAction financier) |
| resetAccountPassword, setArtisanPin, setPharmaciePassword, artisan/pharmacieLogin, manageAdminPartnerAccount, createSubAdmin/deleteSubAdmin | callable | Oui : modification d'identifiants / emission de jetons personnalisés pour un compte en suppression | ÉLEVÉ (jetons) / MOYEN |
| createEventReservationCF, requestPropertyVisit, respondToVisitRequest, immobilier (4), republishMarketplaceProduct, manageProfessionalSubscription, moderateVehicleEntity | callable | Oui : création de documents liés à l'UID (données personnelles recréées) | MOYEN |
| notify* (≈27), updateEventProviderRating | triggers | Envoient des FCM / lisent des profils ; pas de création de commande ni de mouvement d'argent | FAIBLE |
| planifiées (walletReconciliationCheck, cleanup…) | planif. | Traitent tous les comptes ; sans effet sur la quarantaine | FAIBLE |
| acceptOrderCF, cancelOrderCF, dispatchOrderToDriver, payOrderFromWalletCF, payBoutique*, refundExpiredBoutiqueOrderCF, deliverOrderCF, settleTransferEarningsCF, adminDriverRechargeCF, adminBillingCF | callable | **Non** : wrapper `assertAccountEnabled` + `assertNewAccountActivity` dans les transactions | FAIBLE |
| Écritures SDK client (profil, commandes, wallet par règles) | règles | **Non** : `isAuth()` + tombstone (règles déployées) | FAIBLE |

Statut CPU : la plupart des callables critiques ont 1 vCPU, maxInstances 1-5, concurrence 80 ; schedulers 0,5 vCPU × 1. **[V]**

## 4. Protection centrale indépendante des anciennes fonctions

- **Règles Firestore/Storage (déjà en production) [V]** : bloquent le SDK client, mais pas l'Admin SDK. Aucune modification de règles n'apporte de protection aux callables g0.
- **Auth** : `disabled:true` + `revokeRefreshTokens` n'invalide pas les jetons ID déjà émis (≈1 h). **[V — comportement documenté Firebase ; absence de `checkRevoked` vérifiée dans `index.js`]**
- **Wrapper `onCall` global** : n'existe que dans les instantanés ≥ 28 oct. ; redéployer une fonction g0 avec le code local le lui donne automatiquement (mais redéploie aussi tout son code actuel — voir risque de régression).
- **Protection centrale sans toucher aux anciennes fonctions** : impossible côté serveur seul pour g0/g8. Pistes **[H]** : (a) redéployer les fonctions g0 sensibles ; (b) retirer temporairement le droit d'invocation (`run.invoker`) — modification de production, hors périmètre ; (c) accepter la fenêtre résiduelle en exigeant en amont solde = 0, aucun retrait/paiement en cours (déjà dans l'inspection) et en documentant le risque.
- **Aucun changement de règles requis** pour la quarantaine ; le changement nécessaire est dans les fonctions (déploiement).

Risques financiers/commandes résiduels : recharge FeexPay tardive (solde non nul sur profil anonymisé, ÉLEVÉ), retrait tardif (ÉLEVÉ), action AZ IA confirmée tardive (ÉLEVÉ), commande créée par SDK client (bloqué par les règles, FAIBLE).

## 5. Comparaison des options

| | A — 4 fonctions seulement + fonctions critiques | B — Protection centrale compatible avec l'existant | C — Redéploiement large |
|---|---|---|---|
| Fonctions | 4 + ≈12 critiques g0/g8 (initiateWithdrawal, checkWithdrawalStatus, initiateFeexPayPayment, ekClientConfirmOrder, ekbine* (4), azIaChat, clearAiHistory, aiConfirmAction, resetAccountPassword, setArtisanPin/setPharmaciePassword, artisan/pharmacieLogin) ≈ 20 | Aucune protection centrale serveur n'existe pour g0 : se réduit aux règles (déjà en place) + inspection préalable | 4 + 74 non gardées ≈ 78 |
| Fichiers | functions/ (index.js, accountDeletion*.js, accountCleanup.js, partnerAccountDeletion.js…) | aucun nouveau | idem + tout le code local |
| Avantages | Couvre argent et jetons ; périmètre maîtrisé | Pas de déploiement | Cohérence totale du code |
| Limites / risques | Redéploiement de code local plus récent (régression possible, tests à rejouer) ; quota | Fenêtre résiduelle ouverte (§3) | Quota Cloud Run (Σ ≈167,5/20 000 m-vCPU non rapprochés), régression large |
| Estimation | ≈ 20 | 4 (non recommandé seul) | ≈ 78 |

**Aucune option n'est appliquée.**

## 6. Quota Cloud Run (europe-west1)

- **[V]** `CpuAllocPerProjectRegion` rapporté par l'API = 20 000 milli-vCPU ; Σ(cpu × maxInstances) des 95 services = **166,5** (+1,25 avec les 4 nouvelles = 167,75).
- **[V]** Série d'usage vide ; aucune série `quota/exceeded` ; refus d'augmentation `NOT_ENOUGH_USAGE_HISTORY` ; `functions_after_failed_deploy.txt` est un instantané du 6 oct. sans erreur de quota exploitable.
- **[V — mémoire projet]** Un déploiement de juillet a été bloqué vers ≈168 en Σ(cpu × maxInstances).
- **Conclusion : quota non confirmé.** Le lien entre 20 000 m-vCPU et Σ ≈ 166-168 n'est pas réconcilié. Les 4 fonctions seules (+1,25) ne changent presque rien ; un déploiement large est plus risqué.

## 7. Règles et configuration

- Firestore : ruleset `28112bcd…` (28/10/2026). Contient `isAuth()` + tombstone, `account_tombstones`, `account_deletions` (admin lecture seule), `account_deletion_requests` (création publique, `hasAll` sans `hasOnly`). Le local diffère (≈187 lignes locales en plus : 7E-11-S, pilote partenaires, E-Kbine, etc. — non déployées) ; aucune ligne locale de suppression de compte ne manque en prod. **[V]**
- Storage : ruleset `0aa439e0…` ; protection tombstone présente ; le local ajoute la restriction des preuves de livraison (7E-11-S) **non déployée**. **[V]**
- `operations_control` : aucune règle → refus client par défaut ; accès Admin SDK uniquement. Document `account_deletion` absent (7E-62). **[V]**
- Système fermé tant que `enabled !== true` ou `inventoryVersion !== 1` (fail-closed testé localement). **[V]**

## 8. Risques ouverts

| Risque | Gravité |
|---|---|
| 74 fonctions sans garde, jeton ID valide ~1 h après Auth delete | ÉLEVÉ |
| Recharge FeexPay / retrait tardif après quarantaine | ÉLEVÉ |
| Recréation de données AZ IA après effacement | MOYEN |
| Redéploiement de code local plus récent que la prod (régression) | MOYEN |
| Quota Cloud Run non réconcilié | NON CONFIRMÉ |
| Pas de PITR ni de sauvegarde planifiée Firestore | MOYEN |
| TTL absent (`ai_tool_executions`, durées de conservation à valider juridiquement) | MOYEN |
| `account_deletion_requests` sans `hasOnly` (spam) | FAIBLE |

## 9. Recommandation technique finale

1. **Ne pas déployer les 4 fonctions de suppression seules ni activer la config** : une fois la quarantaine possible, ~74 fonctions peuvent encore agir.
2. Préparer un lot ciblé (≈20 fonctions critiques g0/g8 + 4) avec revue de diff prod↔local, tests `npm test` et `npm run test:rules`, puis demander une autorisation distincte.
3. Réconcilier le quota (Cloud Console > Quotas ; vérifier à la source) avant tout déploiement.
4. Ne pas activer `operations_control/account_deletion` avant : lot déployé, test réel sur compte de test dédié, validation juridique des durées.

## 10. Prochaines actions (ordre)

1. Validation de ce rapport.
2. Commit des 14 fichiers de 7E-64 (autorisation distincte).
3. Diff prod↔local des ≈20 fonctions candidates ; plan de rollback.
4. Clarifier le quota.
5. Déploiement ciblé (autorisation distincte), vérification `functions:list`.
6. Déploiement Hosting des pages légales.
7. Test réel sur compte de test, puis création de la config (autorisation distincte).
8. Validation juridique des durées, TTL / purge.

*Limites : liste exhaustive des collections lues/écrites par fonction non reconstruite ligne à ligne ; la gravité des fonctions g0 est inférée de leur rôle et de l'absence de garde dans l'instantané déployé.*
