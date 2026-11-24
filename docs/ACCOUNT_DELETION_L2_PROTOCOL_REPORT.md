# ACCOUNT_DELETION — L2 : protocole de verrouillage et de suppression

Date : 2026-11-10. Node 22.23.4. Branche `finalisation/az-express`, HEAD `d65c8f0`. Aucun commit, push, déploiement ni accès à `az-express-b0469`.

## 1. Résumé

L2 implémente la séquence **T1 → T2 → T2b → F → suppression Auth → T3** pour les trois moteurs de suppression, avec tombstone à phases (`closing`/`sealed`), `epoch`, jeton de scellement, empreinte du snapshot financier et reprise après interruption. Le moteur `accountObligations.js` est intégré **en plus** des contrôles existants (D-12).

Ce qui n'est **pas** fait (hors périmètre de la mission) : branchement des 45 writers (L3 à L6), `onCallClosing`, récupération administrative N2/N3 (L2R/L7), `held_for_review`, aucun changement du webhook FeexPay.

**Conclusion** : fonctionnel et testé en mémoire et en émulateur local ; la garantie de sérialisation en production n'est **pas** démontrée (hypothèses H1–H3 inchangées). Tant que les writers financiers ne sont pas branchés sur le verrou commun (L4/L5), le scellement ne les arrête pas : il détecte seulement leurs effets via la relecture de T2b.

## 2. Fichiers

Nouveaux (non suivis) :

| Fichier | Rôle |
|---|---|
| `functions/accountClosureProtocol.js` | Planificateurs purs (`planEntry`, `planSeal`, `planFence`, `planResume`), transactions `sealTx` (T2b), `fenceTx` (F), `markAuthDeletedTx` (T3), pilote `sealAndDeleteAuth`, `blockedPatch` |
| `functions/accountObligationsInspector.js` | Lecture Firestore du moteur : requêtes exactes de `requiredQueries`, `limit(201)`, reçus de couverture, journaux `order_<id>`, empreinte canonique |
| `functions/test/accountClosureProtocol.test.js` (34), `accountObligationsInspector.test.js` (10), `accountClosureProtocol.emulator.test.js` (8, émulateur), `test/support/closureWorld.js` | Tests |

Modifiés (suivis) :

| Fichier | Changement |
|---|---|
| `functions/accountDeletion.js` | T1/T2/T2b/F/T3 ; `inspectAll` = `inspect()` puis moteur ; ordre de lecture tombstone d'abord |
| `functions/partnerAccountDeletion.js` | Même protocole ; un appel du moteur par identité (Q9) ; alerte si obligation découverte une fois scellé |
| `functions/manualAccountDeletion.js` | Tombstone créé seulement s'il n'existe pas (l'ancien `set` pouvait écraser un scellé), schéma additif, `authDeletedAtMs` ; moteur pour les pharmacies |
| `functions/test/accountDeletionHardening.test.js`, `manualAccountDeletion.test.js` | Un fixture de commande « livrée » reçoit `paymentMethod:'cash'` (sans moyen de paiement le moteur la juge ambiguë, fail-closed). Ce n'est pas un affaiblissement : la valeur manquait dans la donnée de test. |

Fichiers L1 ajustés (non suivis) : `accountClosureRegistry.js` (3 writers analysés), `test/accountClosureRegistry.test.js` (liste des 16 writers de règlement sans garde, allowlist), `test/accountObligations.test.js` (le test de périmètre affirmait « moteur branché nulle part », ce que L2 change ; réécrit pour n'autoriser que les inspecteurs de suppression).

Inchangés : `feexpayPayments.js`, `index.js`, `accountAdmission.js`, `accountDeletionScope.js`, `firestore.rules`.

## 3. Schéma du tombstone `account_tombstones/{uid}`

| Champ | Écrit par | Remarque |
|---|---|---|
| `createdAt`, `state:'deleting'` | T1 | ancien format conservé |
| `phase` `closing`/`sealed`, `epoch`, `updatedAtMs` | T1 (`closing`, 0) | absent ⇒ `closing` / 0 (anciens tombstones valides) |
| `sealToken`, `sealEpoch`, `sealedAtMs`, `snapshotDigest` | T2b | jeton UUID, `sealEpoch` = epoch observé |
| `deleting`, `deleteStartedAtMs` | F | posés avant tout `deleteUser`, date non réécrite aux reprises |
| `authDeletedAtMs` | T3 | après `auth/user-not-found` confirmé |
| `lastRecovery` | — | défini par le contrat, **jamais écrit** (récupération administrative non implémentée) |

Le tombstone n'est jamais supprimé ni rouvert par ce code ; aucune expiration ni horloge (un test interdit `Date.now`/`setTimeout`).

## 4. Fonctionnement

- **T1** (transaction de quarantaine) : lit tombstone, puis profil/collections, puis moteur ; tombstone existant ⇒ dossier bloqué `existing_tombstone_review` (jamais écrasé) ; inspection ou moteur bloquant ⇒ aucun tombstone.
- **T2** (bail, après `QUIET_MS`) : relit tout, enregistre sur le dossier `closureEpoch`, `snapshotDigest`, `financialSnapshot`. Tombstone absent/illisible ⇒ bloqué, jamais recréé. Tombstone déjà scellé ⇒ chemin de reprise.
- **Auth** : `disable` + `revoke` tolérant `user-not-found`.
- **T2b** : dans une transaction, exige bail détenu, même `epoch`, moteur non bloquant (seul `blocking === false` autorise), même empreinte ⇒ écrit `sealed`. Échec ⇒ Auth réactivé (si désactivé par ce passage), dossier bloqué, tentative comptée (plafond `MAX_ATTEMPTS`).
- **F** : exige scellé, jeton, epoch de scellement, bail ⇒ `deleting:true`.
- **Suppression** : `deleteUser`, puis `getUser` doit répondre `user-not-found` ; toute autre erreur = état incertain, aucune conclusion, reprise. Puis T3.
- **Epoch** : compteur monotone. Un writer B/C/D qui utilise `assertFinancialLock` (L1) l'incrémente dans sa transaction ; T2b exige l'égalité avec l'epoch de T2. **Aucun writer réel ne l'incrémente encore** (L4/L5).
- **Reprise d'un dossier scellé** (lecture seule) : jeton, epochs, absence d'obligation et empreinte doivent concorder ; sinon dossier bloqué sans reprise automatique, alerte `account_deletion_closure_alert`, tombstone reste scellé.

## 5. Inspecteurs financiers

Requêtes exactes du contrat : `orders`, `transfer_settlements` (`driverIds` en `array-contains`, `holderDriverId` en égalité), `reconciliation_flags`, chacune `limit(201)`, 201 résultats = troncature = blocage ; journaux `clients/{uid}/wallet_transactions/order_<id>` pour le client. Une exception de lecture fait échouer la transaction (rien n'est écrit, rien ne passe pour « vide »). Résultat illisible ou catégorie inconnue ⇒ bloquant.

Couverture : client, livreur, pharmacie, restaurant, boulangerie, vendeur. **Non couverts par le moteur** (contrôles historiques seuls, listés dans le snapshot) : agent Ekbine, agent immobilier, propriétaire de flotte (Q1). Les transactions Ekbine, boutique, blanchisserie, eau/boissons, `wallet_transactions` de niveau supérieur et `withdrawal_requests` restent contrôlées par l'inspecteur historique, pas par le moteur.

Registre de décisions : le writer de décisions est L7 ; les listes `decisions`/`evidence` sont vides, donc **tout signalement « résolu » ou « revu » reste bloquant** tant que L7 n'existe pas.

### Trois writers analysés (non modifiés)

| Writer | Constat | Classement proposé |
|---|---|---|
| `checkPendingWithdrawals` → `applyPayoutStatus` (`feexpayPayments.js`, réserve C2) | FAILED = crédit wallet de `wd.userId` sans tombstone, `isDeleted` ni epoch. Borné indirectement : un retrait non terminal bloque T1/T2/T2b ; `initiateWithdrawal` est refusé dès la quarantaine | C, à confirmer, sans garde |
| `adminApproveWithdrawalCF` | `pending_manual → processed`, portefeuille jamais touché ; inatteignable après T2b | D, à confirmer, sans garde |
| `ekbineAgentDepositAction` | transitions de statut par l'agent, sans argent ; seule garde `isEligibleAgent(profil)` ; le client n'est pas relu | B, à confirmer, sans garde |

Le registre compte maintenant **16** writers de règlement sans garde (13 + ces 3).

## 6. Scénarios d'interruption testés (faux Firestore, tous passent)

Arrêt après T1 ; arrêt après acquisition du bail (bail actif refusé, repris à l'expiration) ; arrêt après T2 ; arrêt après T2b avant `deleteUser` (reprise : même scellé, A1/T2b non rejoués, `deleteStartedAtMs` conservé) ; échec de `deleteUser` répété jusqu'au plafond (scellé conservé) ; état Auth incertain (`getUser` en erreur) ; utilisateur Auth déjà supprimé ; tombstone absent, illisible, ancien format ; jeton falsifié, obligation nouvelle, empreinte modifiée après scellement (arrêt + alerte, `deleteUser` jamais appelé) ; scellé intact 100 jours plus tard (le verrou L1 refuse A/B/C/D). Chemin partenaire : nominal, moteur bloquant, epoch bougé, reprise, obligation une fois scellé.

## 7. Résultats exacts

| Lot | Résultat |
|---|---|
| Nouveaux tests purs (protocole 34, inspecteur 10) | 44 / 44 |
| Suites L1 et concernées (accountObligations, accountClosure*, hardening, manual…) | passent (126 / 126 lors de la vérification ciblée) |
| **Suite pure complète** (Node 22.23.4, garde réseau) | **2492 tests, 2319 réussis, 0 échec, 0 annulé, 173 ignorés** (avant L2 : 2447 / 2275 / 0 / 172 ; +45 tests, +1 ignoré = le marqueur émulateur du nouveau fichier) |
| Émulateur local `demo-l2-b` (port 28080 dédié), `accountClosureProtocol.emulator.test.js` | **8 / 8** |
| Rejeux C2 isolés (`accountQuarantineConcurrency`, motif `^C2\.`, projet distinct par rejeu) | **17 réussis, 3 échecs sur 20** |

Détail de l'émulateur : L2-C1 (writer B/C/D contre T2b, 75 rondes) : 35 victoires du writer, 40 du scellement, **aucune violation** (jamais les deux, jamais aucun, epoch+1 écrit avec le writer). L2-C7/C7b (deux scellements concurrents) : **7 rejets d'émulateur** `3 INVALID_ARGUMENT: Transaction is invalid or closed` (6 + 1), comptés ; jamais deux scellements effectifs, jeton unique. L2-flow et L2-flow-epoch : séquence complète sur Firestore émulé, `deleteUser` observé avec un tombstone `sealed` + `deleting`. L2-C2real-T1 (25 rondes) et L2-C2real-T2b (25 rondes) : 0 rejet du webhook, crédit exactement une fois à chaque ronde.

**Première exécution émulateur : 6 / 8.** C7 et C7b avaient échoué avec l'erreur ci-dessus. J'ai modifié ces deux tests pour compter ce rejet (précédent : C1 de la suite existante) tout en gardant les invariants ; toute autre erreur échoue encore. Je signale que c'est un changement de test après échec, motivé par la limite d'émulateur démontrée en L0-F, non une preuve que la course est impossible en production.

Corrigé pendant L2 grâce aux tests : `planSeal` renvoyait un succès idempotent à un processus sans bail ; il exige désormais le bail.

## 8. Statut de C2

Aucun fichier de paiement ni le webhook n'est modifié (empreintes Git : `feexpayPayments.js` absent de la liste des modifiés). Le test C2 n'appelle pas le code modifié (il utilise sa propre quarantaine). Par prudence, L0-F a été rejoué : **3 échecs sur 20**, tous avec l'erreur d'émulateur `3 INVALID_ARGUMENT: Transaction is invalid or closed` (baseline L0-F : 5 sur 21). Aucune variation attribuable à L2. **C2 reste intermittent et n'est pas corrigé.** Les invariants financiers (crédit unique, rien de perdu) tiennent sur 50 rondes contre le T1 et le T2b réels. Collecte détaillée : journaux de rejeu hors dépôt.

## 9. Risques restants

1. **Sérialisation non démontrée en production** : preuve seulement en émulateur (H1–H3). Aucune conclusion de sécurité ne doit s'appuyer sur ces essais seuls.
2. **Writers non branchés** : 16 writers de règlement n'écrivent ni ne lisent le tombstone. Entre T2 et T2b ils sont détectés par la relecture (epoch non incrémenté, mais obligations visibles), pas empêchés.
3. **Inspecteur historique trop strict** (constat, non modifié) : `TERMINAL` ne contient pas `sent` ni `processed` ; un compte ayant déjà retiré de l'argent reste bloqué (fail-closed, mais refus de suppression à tort possible).
4. Registre de décisions absent : tout signalement résolu bloque tant que L7 n'existe pas.
5. Rôles hors moteur (agents Ekbine/immobilier, flotte) : contrôles historiques uniquement.
6. Lecture en erreur : la transaction échoue sans état « bloqué » visible côté dossier (le planificateur réessaie) ; le contrat prévoyait un dossier bloqué.
7. Auth réactivé après un échec de T2b : si cette réactivation échoue, l'information est dans l'audit (`authReactivated:false`), pas d'alerte dédiée.
8. Pas de récupération administrative d'un scellé : un dossier scellé bloqué reste à ce stade jusqu'à L2R.
9. Dossiers en cours lors d'un déploiement : un dossier sans `closureEpoch` échoue à T2b, est bloqué puis retraité par T2 (sûr, mais une tentative est consommée).
10. Mesures de lectures (budget ≈ 1 000) non faites ; Node 22 et émulateur locaux uniquement, aucun essai appareil.
11. Trois fichiers L1 et trois tests existants ont été ajustés (section 2).

## 10. Prérequis pour L3

- Décision sur la classification des 16 writers sans garde (D-3) et ordre de branchement.
- `onCallClosing` (liste fermée), puis `assertFinancialLock` dans chaque writer (L4/L5), jamais avant : le scellement n'a de sens complet qu'avec l'epoch incrémenté par les writers.
- Arbitrage du sort des cinq fichiers non commités (Ekbine, `index.js`) avant L3/L6.
- Outil `held_for_review` avant activation de FeexPay (D-10).
- Décision sur la correction de `TERMINAL` (`sent`, `processed`) et sur les rôles hors moteur.
- Plan d'essai préproduction pour valider H1–H3 et le budget de lectures.

## 11. Contrôle final

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, 0 stash. Cinq fichiers sensibles : empreintes `21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60` identiques. Suivis modifiés : 20 avant + 5 (`accountDeletion.js`, `partnerAccountDeletion.js`, `manualAccountDeletion.js` et deux tests existants) = 25. Non suivis : 117 avant + 5 fichiers de test/code + `test/support/` + ce rapport. Émulateur dédié arrêté ; ports 5001, 8080, 9099, 9199 et 4000 intacts. L3 non lancé.
