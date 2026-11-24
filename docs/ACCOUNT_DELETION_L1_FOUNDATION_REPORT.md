# ACCOUNT_DELETION — L1 : socle commun de protection de suppression des comptes

Date : 2026-11-10. Node 22.23.4. Branche `finalisation/az-express`, HEAD `d65c8f0`.

## 1. Résumé

L1 ajoute **trois modules purs/testables et trois fichiers de tests, sans modifier aucun fichier existant** :

| Fichier (nouveau) | Rôle |
|---|---|
| `functions/accountClosureState.js` | Interprétation unique de l'état de fermeture d'un compte (fonctions pures, sans lecture ni horloge) |
| `functions/accountClosureLock.js` | `assertFinancialLock` : verrou financier commun dans la transaction du writer (lectures seules, retourne les écritures `epoch+1`) |
| `functions/accountClosureRegistry.js` | Registre des writers sensibles : niveau attendu **et** garde réellement présente aujourd'hui |
| `functions/test/accountClosureState.test.js` (9 tests), `accountClosureLock.test.js` (12), `accountClosureRegistry.test.js` (8) | 29 tests au total |

Aucun module de production n'importe le socle (vérifié par un test) : **L1 ne change aucun comportement en production et ne touche pas C2**.

## 2. Analyse préalable et matrice avant/après

Lus : protocole 2D-2A.3 (§1 schéma/phases, §1.4 protocole des writers, §4 writers), décisions 2D-2A.5 (D-1 verrou commun et `epoch` approuvés ; noms de champs et du helper **recommandés** ; D-3 classification approuvée, chaque ligne à vérifier), `accountAdmission.js`, `accountDeletion.js` (création du tombstone `{createdAt, state:'deleting'}` en `:88`), `accountDeletionSupport.js`, `accountDeletionScope.js`, le moteur `accountObligations.js` (965 lignes, non intégré) et son test, les gardes de chaque writer par recherche dans le code. Le document `ACCOUNT_DELETION_L0D_PILOT_FIX_REPORT.md`, cité par la mission, n'existe pas dans le dépôt (L0-D n'a produit aucun rapport séparé) ; sans incidence.

| Responsabilité | Avant L1 | Après L1 |
|---|---|---|
| Lire « où en est le compte » | éparpillé : `exists` du tombstone (`accountAdmission`, wrapper `onCall`), `deletionRequested`/`isDeleted` lus à la main | `readClosureState` : 7 états, une seule définition |
| Distinguer quarantaine / scellé | impossible (le tombstone n'a que `state`) | `phase` absente = `closing`, `epoch` absent = 0, `sealed` reconnu ; écriture de ces champs **non faite** (T1 reste inchangé) |
| Autoriser A / B / C / D | A seulement (admission : refuse tout tombstone) ; aucune règle pour B/C/D | `closureRefusal(closure, opClass)` |
| Verrou dans la transaction du writer | `assertNewAccountActivity` (lecture seule, tombstone + profils) | `assertFinancialLock` (non branché) ; `accountAdmission` **inchangé** |
| Inventaire des writers | docs seulement | `accountClosureRegistry.js` vérifié contre le source |
| Moteur `accountObligations` | non intégré | **inchangé, non intégré** (hors périmètre L1) |

## 3. Architecture

### 3.1 États (`accountClosureState.js`)

| État | Condition | Protégé |
|---|---|---|
| `active` | profil présent, pas de tombstone, pas de demande | non |
| `deletion_requested` | profil `deletionRequested:true`, pas de tombstone | non (jamais assimilé à une anonymisation) |
| `closing` | tombstone sans `phase` (ancien format) ou `phase:'closing'` | oui |
| `sealed` | tombstone `phase:'sealed'` | oui |
| `anonymized` | profil `isDeleted:true` (prioritaire sur `closing`/`sealed`) | oui |
| `absent` | ni profil ni tombstone | non |
| `unreadable` | tombstone avec `phase` hors {closing, sealed} ou `epoch` invalide (négatif, non entier, texte, `NaN`), ou non-objet | oui, traité comme le plus strict |

Le temps n'entre nulle part : aucune horloge, aucun TTL (D-11). Un test fige `Date.now` en 2100 sur un tombstone de 1999 : il reste `sealed`/`closing`.

### 3.2 Règle de décision (`closureRefusal`)

| État | A | B / C / D |
|---|---|---|
| active | autorisé | autorisé |
| deletion_requested | `ACCOUNT_DELETION_REQUESTED` | autorisé |
| closing | `ACCOUNT_CLOSING` | autorisé (+ `epoch+1`) |
| sealed | `ACCOUNT_SEALED` | `ACCOUNT_SEALED` |
| unreadable | `ACCOUNT_TOMBSTONE_UNREADABLE` | idem |
| anonymized | `ACCOUNT_ANONYMIZED` | idem |
| absent | `ACCOUNT_ABSENT` | idem |

Erreurs : `HttpsError('failed-precondition', message, { code })`. Même code d'erreur que les gardes existantes ; messages **identiques** à `accountAdmission.js` pour les situations équivalentes (un test compare mot à mot sur 4 situations). `details.code` est stable et exploitable. Argument invalide (catégorie inconnue) : `TypeError`, jamais une autorisation silencieuse.

### 3.3 Verrou (`assertFinancialLock(tx, db, HttpsError, parties, opClass, { now })`)

- Dans la transaction du writer, **lectures seules** ; retourne `{ parties, skipped, writes, applyTo(tx) }`. Compte actif ou non protégé : aucune écriture (aucun coût).
- B/C/D en `closing` : une écriture par tombstone `{ epoch: epoch+1, updatedAtMs }` à appliquer par le writer dans la même transaction (invalide tout scellement précédent, protocole §1.3).
- Bénéficiaire `onClosed:'skip'` (DR1) : anonymisé/absent omis et retourné avec `beneficiary_account_closed`, uniquement B/C/D ; un bénéficiaire **scellé** est toujours refusé, la catégorie A ne l'omet jamais.
- Parties dédoublonnées, triées (identifiant puis collection), identifiants validés (message historique « Identite de commande invalide »).
- **Réserve C2 (L0-F) appliquée dans le design** : pour chaque partie, le tombstone est lu **avant** le profil, séquentiellement. L0-F a mesuré 0/200 échec avec cet ordre contre 16 % en profil-d'abord dans l'émulateur. Non validé contre Firestore réel, et non rejoué contre une quarantaine réelle dans L1 (le helper n'est branché nulle part).

### 3.4 Registre (`accountClosureRegistry.js`) : 45 entrées

Chaque entrée porte catégorie, comportement attendu (`closing`, `sealed`), statut de classification de D-3 (`anchored` / `to_confirm` / `recommended` / `unclassified`) et la **garde réelle** (`admission_helper`, `tombstone_read`, `target_guard`, `none`, `unexamined`) avec son suivi (`head` ou `working_copy`).

Répartition : A 21, B 6, C 4, D 7, non classés 7. Gardes : `admission_helper` 18, `tombstone_read` 5, `target_guard` 3, `none` 16, `unexamined` 3.

**Vérification par le test** : pour chaque entrée dont la garde est connue, le test relit le source du writer (de sa déclaration à la suivante) et exige la présence du jeton (`assertNewAccountActivity`, `account_tombstones`, `assertTargetNotClosing`), ou son **absence** pour `none`. Un test de complétude exige aussi que tout fichier de production qui lit le tombstone ou appelle les gardes apparaisse dans le registre (il a détecté `adminPartnerAccounts.js` au premier passage, ajouté). Les trois writers jamais lus (`checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction`) sont `unexamined` : aucune affirmation.

**Constat important** : 13 writers de règlement B/C/D n'ont **aucune** lecture du tombstone dans leur chemin d'écriture : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `adminConfirmDeliveryCF`, `confirmOrderDeliveryWithProof`, `refundExpiredBoutiqueOrderCF`, `autoExpireOrders`, `settleTransferEarningsCF`, `adminBillingCF`, `adminOrderDisputeCF`, `ekCancelOrderCF`, `partnerOrderActionCF` (cash : remise et décision administrative). Ils ne sont protégés que par le wrapper `onCall` (appelant en quarantaine refusé). C'est le périmètre des missions de branchement ; un test fige cette liste pour que tout changement soit visible.

## 4. Décisions appliquées

| Décision | Application dans L1 |
|---|---|
| Tombstone = autorité de protection (D-1, D-9) | seule source des états `closing`/`sealed` |
| Tombstone ancien sans nouveaux champs reste protégé | `phase` absente = `closing`, `epoch` absent = 0, document vide encore protecteur |
| Pas de déverrouillage par TTL (D-11) | aucune horloge dans l'interprétation ; `now` n'est utilisé que pour `updatedAtMs` des écritures |
| Aucun writer ne contourne un tombstone existant | scellé/illisible/anonymisé : refus pour toutes les catégories |
| Suppression demandée ≠ anonymisation | états distincts, protection distincte |
| Classification A/B/C/D avec vérification individuelle (D-3) | statut par ligne dans le registre, jamais promu au-delà de ce qui est approuvé |
| Noms `phase`, `epoch`, `assertFinancialLock` | **recommandés, pas approuvés** (D-1) : utilisés tels quels, faciles à renommer |

## 5. Tests exécutés (Node 22.23.4, sans émulateur, garde réseau chargée)

| Lot | Résultat |
|---|---|
| Nouveaux : `accountClosureState`, `accountClosureLock`, `accountClosureRegistry` | **29 / 29 pass** |
| Phases du tombstone (états, ancien format, illisible, aucune horloge) | couverts (9 tests) |
| Tombstones anciens | couvert (état, verrou, `epoch` 0 → 1) |
| Refus des writers non autorisés | catégories A/B/C/D × closing/sealed/illisible/anonymisé/absent ; multi-parties ; aucune écriture après refus |
| Compatibilité | message et code identiques à `assertNewAccountActivity` sur 4 situations ; aucun module de production n'importe le socle |
| Non-régression directe (accountAdmission, accountQuarantineGuards, accountDeletionHardening, accountDeletionSupport, manualAccountDeletion, accountObligations, ekbineQuarantineGuards, walletDebitQuarantineGuards, accountQuarantineIndex) | **185 / 185 pass** |
| Suite pure complète | **2447 tests, 2275 pass, 0 fail, 0 cancelled, 172 skipped** (L0-D.1 : 2418 / 2246 / 0 / 172 → +29 tests, +29 pass, mêmes 172 ignorés) |

**Non exécutés** : suites émulateur (non nécessaires : rien de branché, aucun fichier existant modifié) ; aucun test du helper contre une vraie transaction Firestore ; aucun test appareil.

## 6. Statut de C2 (webhook FeexPay)

- `feexpayPayments.js`, l'ordre de lecture du webhook, ses retries, `accountDeletion.js` et le test C2 : **non modifiés** (empreintes Git inchangées).
- L1 n'ajoute aucun import dans un chemin de production ; le protocole de rejeu de C2 prévu par la mission **n'a donc pas été déclenché**. Je **ne déclare pas C2 corrigé** : il reste intermittent (voir L0-F), classification D.
- Le webhook figure au registre comme `B / tombstone_read / sealed:'hold'` avec la réserve C2 en note.

## 7. Compatibilité avec l'existant

- Aucun fichier existant modifié par L1 (les 20 fichiers suivis modifiés sont ceux de L0-D/L0-D.1 et les 11 préexistants).
- `accountAdmission.js` reste la garde en vigueur ; ses appelants ne voient aucun changement.
- Les tombstones écrits aujourd'hui (`{createdAt, state:'deleting'}`, plus `source` pour le manuel) sont lus correctement (`closing`, epoch 0).
- Un tombstone sans profil est lu `closing` : B/C/D y sont autorisées par le helper (le writer gère l'absence du profil) — à confirmer au branchement.

## 8. Limites et risques

1. **Rien n'est protégé de plus qu'avant** : L1 fournit des outils, pas des protections. Les 13 writers de règlement restent sans garde de tombstone.
2. Registre : le test vérifie la présence/l'absence du jeton dans le corps du symbole (approximation textuelle) ; il ne prouve pas qu'une garde présente couvre toutes les parties du writer (ex. `ekClientConfirmOrder` ne relit que l'agent).
3. `phase`, `epoch`, `assertFinancialLock` : noms recommandés non approuvés ; T1 n'écrit pas encore `phase`/`epoch`.
4. Sérialisation prouvée en émulateur seulement (D-1, H1–H3) ; l'ordre de lecture choisi pour C2 vient de L0-F et reste à valider sur un branchement réel.
5. Le registre classe 7 entrées comme non classées et 3 jamais lues ; les lignes `to_confirm` ne sont pas approuvées.
6. Gardes présentes seulement dans la copie de travail non commitée : `ekCreateOrderCF`, `ekbineAcceptOrder`, `ekClientConfirmOrder`, `manageProfessionalSubscription`, `adminPartnerAccounts`, `resetAccountPassword`, `setPharmaciePassword` (cinq fichiers sensibles préservés, aucune modification).
7. Moteur `accountObligations.js` : non intégré (aucun inspecteur financier branché, aucun besoin dans L1).

## 9. Dépendances pour L2

- Décider si `phase`/`epoch`/noms sont approuvés (D-1) avant d'écrire `phase:'closing'`, `epoch:0` dans T1 (`accountDeletion.js:88`, aussi `manualAccountDeletion.js:144`).
- Choisir l'ordre de branchement des 13 writers sans garde (ordre de risque : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `autoExpireOrders` en premier) ; vérification individuelle de chaque ligne `to_confirm` (D-3).
- Inventaire des 3 writers non lus et des 7 non classés.
- Plan de test d'intégration en émulateur pour chaque writer branché, dont le cas « writer vs T2b » (protocole §8, C1–C6) et la comparaison C2 si le webhook est touché.
- Décisions Ekbine (`onCallClosing`, X-2) et moteur d'obligations restent des travaux distincts.

## 10. Contrôle final

- HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, 0 stash.
- 20 fichiers suivis modifiés inchangés ; cinq fichiers sensibles : empreintes `21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60` identiques.
- Non suivis : 110 avant L1 + 6 (3 modules, 3 tests) + ce rapport = 117.
- Aucun commit, push, stash, déploiement ; aucun accès à `az-express-b0469` ; aucun émulateur démarré pour L1 ; ceux des ports 5001, 8080, 9099, 9199 et 4000 intacts.
- L2 non lancé.
