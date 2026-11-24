# Mission 7E-73 — Revue du commit 1 (moteur de suppression P1)

Date : 2026-11-07 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · **Aucun `git add`, commit, push, merge, reset ; aucune commande distante.** Constat : l'ancien « commit 1 » de 7E-72 mélangeait P1, P2 et P3 parce que `functions/index.js` porte les trois ; il est **scindé ici en commit 1 (P1) et commit 2 (gardes P2)**. La scission de `index.js` se fait par hunks (patchs fournis, §6).

## 1. Contenu exact du commit 1

| Fichier | État | Rôle P1 |
|---|---|---|
| `functions/accountDeletion.js` | modifié | moteur : demande, quarantaine, tombstone, `process`, `drain`, `status` ; limites 5/h, 10/dossier, 60 s, 6 échecs ; audit strict avant Auth ; blocage administrateurs |
| `functions/accountCleanup.js` | **nouveau** | inventaire/effacement notifications et données AZ IA ; `failurePatch` ; **importé par `accountDeletion.js` et `partnerAccountDeletion.js` (sans lui `index.js` ne se charge pas)** |
| `functions/partnerAccountDeletion.js` | modifié | importé par le moteur (périmètre partenaires, fermé tant que `partnerInventoryVersion` ≠ 1) ; mêmes plafonds/nettoyage |
| `functions/accountDeletionSupport.js` | modifié | `manageAccountDeletionCF` : la reprise motivée remet `attempts` à 0 |
| `functions/index.js` | **hunk n° 3 seulement** (`index_p1.patch`, 13 lignes) | injecte `checkRateLimit` et `logAudit` dans `buildAccountDeletion` — **indispensable : sans limiteur le moteur refuse de traiter (`RATE_LIMITER_REQUIRED`)** |
| `functions/test/accountDeletionHardening.test.js` | nouveau | 21 tests du moteur |
| `rules-tests/account-deletion.test.js`, `-lifecycle.test.js`, `-real.test.js` | modifiés (1 ligne chacun) | injectent `checkRateLimit` (sinon ces suites échouent) |

Les 4 fonctions P1 sont déjà câblées dans `index.js` à HEAD (`requestAccountDeletionCF` 0,5 vCPU ; `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF` 0,25 vCPU ; 1 instance ; concurrence 1). Le commit 1 n'en change pas les plafonds.

## 2. Ce qui est EXCLU de P1

| Élément | Commit | Raison |
|---|---|---|
| `accountAdmission.js` (ajout de `assertTargetNotClosing`) | 2 | le moteur P1 n'importe pas ce module ; `assertNewAccountActivity` existe déjà à HEAD |
| `feexpayPayments.js` (`held_for_review`), hunks `index.js` n° 1, 2, 4-8 (`pilotLightOptions`, création de paiement, retrait) | 2 | gardes P2 : `initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook` |
| `azia/pendingActions.js`, `azia/index.js` | 2 | garde P2 : `aiConfirmAction` |
| `pilotCap.js` + `pilotCap.test.js` | 2 | uniquement `pilotLightOptions` (P2) |
| tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator` | 2 | tests des gardes P2 (`accountQuarantineIndex` charge `index.js` et vérifie le câblage P2) |
| `passwordReset.js`, `adminPartnerAccounts.js`, `professionalSubscriptions.js`, `ekbineOrders.js`, hunk n° 9 (`setPharmaciePassword`) | 3 | gardes P3 / E-Kbine |
| `restaurantV2Preprod.test.js` | 4 | indépendant |

## 3. Protections déjà présentes à HEAD (non modifiées par les commits 1 et 2)

`assertNewAccountActivity` (tombstone relu en transaction) existe à HEAD dans `adminDriverRecharge`, `adminWalletRequests`, `catalogQuote`, `eventReservations`, `partnerOrderQuote` et les outils AZ IA `delivery`, `marketplace`, `pharmacies`, `restaurants`. Règles Firestore : `isAuth()` refuse tout compte ayant un tombstone ; Storage : 3 références au tombstone.

**Écart connu si seul le commit 1 est déployé** : `initiateFeexPayPayment`, `initiateWithdrawal`, le crédit du webhook et la confirmation AZ IA ne relisent pas le tombstone. Compensations : (a) le moteur refuse la quarantaine si `wallet ≠ 0`, retrait en cours ou paiement `pending`, et **réinspecte à chaque passage et dans la transaction finale** ; (b) FeexPay est `DISABLED` en préproduction ; (c) pilote sur comptes synthétiques `t7e-del-*`. Cet écart disparaît avec le commit 2 ; il n'est acceptable pour P1 seul que dans ces conditions.

## 4. Les quatre fonctions P1

| Fonction | Contrôles confirmés (code + tests) |
|---|---|
| `requestAccountDeletionCF` | non anonyme ; rôle autorisé ; jeton de suivi 64 hex ; **limiteur obligatoire** puis 5/h ; réauthentification ≤ 300 s ; administrateur refusé ; identité du profil établie ; 10 demandes/dossier ; absorption 60 s ; un dossier par UID |
| `getAccountDeletionStatusCF` | jeton comparé à temps constant ; limite 30/10 min **après** vérification du jeton ; état minimal |
| `retryAccountDeletions` | 20 dossiers max par passage ; chaque `process` isolé ; ne termine jamais faussement |
| `manageAccountDeletionCF` | super-administrateur seulement ; `list`, `claim`, `retry` motivée ; ne change ni consentement, ni solde, ni identité, ni achèvement ; trace `support_events` |

| Protection demandée | Où | Preuve |
|---|---|---|
| Suppression prématurée | passerelle `operations_control/account_deletion` (`enabled === true` et `inventoryVersion === 1`) ; consentement réauthentifié ; 15 min de calme ; réinspection avant Auth et avant anonymisation | tests moteur + 63 règles |
| Administrateur | refusé à la demande **et** dans `process` (`admin_account_manual_process`) | tests |
| Opérations financières en attente | `wallet` entier = 0, dettes/réservations nulles, `withdrawal_requests`/`wallet_transactions` non terminaux, `needsReview`, `refundPending`, `paymentStatus pending` → `blocked` | tests |
| Commandes non terminées | `orders`, `boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`, `ekbine_orders` non terminales → `blocked` | tests |
| Actions AZ IA après quarantaine | garde de `aiConfirmAction` en **commit 2** ; outils AZ IA déjà gardés à HEAD ; nettoyage des données AZ IA dans le commit 1 | §3 |
| Erreurs Firestore | exception de `process` → `failurePatch`, 6 essais puis arrêt ; lecture de tombstone en échec → échec de transaction | tests |
| Doubles traitements | bail 180 s ; dossier unique ; suppression Auth idempotente | tests C1-C3 (émulateur) |
| Demandes répétées | 5/h, 10/dossier, absorption 60 s | tests |

## 5. Vérifications effectuées (reconstitution hors dépôt)

`git archive HEAD` + fichiers du commit 1 + `index_p1.patch`, dossier temporaire ; dépendances par jonction ; aucun état Git modifié.

| Contrôle | Résultat |
|---|---|
| `require('./index.js')` | se charge |
| Tests sans émulateur (Node 24) | 2272 tests · 2097 réussis · 8 échecs · 167 ignorés. Les 8 échecs sont **identiques** dans les reconstitutions « 1 », « 1+2 », « 1+2+3 » : tests qui lisent `web/`, `lib/`, `.git`, absents d'une extraction partielle (association Android/iOS, hébergement, simulation de script, inventaires Flutter). Ils passent dans le dépôt réel. |
| Règles de suppression (Auth + Firestore + Storage, `--test-concurrency=1`, 4 fichiers) | **63 / 63** |
| Cohérence des patchs | `index_p1` + `index_p2` + `index_p3` appliqués à HEAD redonnent **exactement** l'`index.js` de l'arbre de travail |

## 6. Scission de `index.js` (à exécuter par un humain ; NON exécutée)

Patchs dans `test-env/runtime/7e73-patches/` (dossier ignoré par Git) : `index_p1.patch`, `index_p2.patch`, `index_p3.patch`. `git apply --cached --check` : OK pour les trois (lecture seule, vérifié). `git apply --cached <patch>` n'ajoute à l'index que les hunks du patch, sans toucher à l'arbre de travail.

## 7. Écart avec la règle « passerelle fermée » — décision requise AVANT le commit 1

L'arbre de travail actuel **ne respecte pas** la règle retenue (passerelle absente ou désactivée ⇒ refus net, `deletionRequested` inchangé, aucun état créé). Correctif proposé, **non appliqué**, vérifié en reconstitution (22/22 unitaires, 63/63 règles) : voir `ACCOUNT_DELETION_7E73_FINAL_DECISION_REPORT.md` §4. Recommandation : l'inclure dans le commit 1 (il touche `accountDeletion.js` et deux fichiers de test du même commit).

## 8. Conclusion

Commit 1 cohérent, minimal, séparable, sans code P2. Soumissible à autorisation humaine **sous réserve de la décision du §7** et de l'écart du §3.
