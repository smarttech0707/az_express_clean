# ACCOUNT_DELETION — L0-F : investigation de `accountQuarantineConcurrency` C2

Date : 2026-11-10. Mission d'investigation : aucun code, test, règle ni configuration du dépôt modifié ; seul fichier créé : ce rapport. Node 22.23.4, émulateur Firestore local `demo-*` uniquement.

## 1. Résumé exécutif

- **Classification : D — interaction entre le code et l'environnement** (cause du déclenchement démontrée expérimentalement ; part « émulateur » vs « production » non démontrable localement). Confiance : **élevée** sur le mécanisme (ordre de lecture), **moyenne** sur l'équivalence avec la production.
- **Reproduction :** 5 échecs sur 21 exécutions isolées de C2 (1 sonde + 20 rejeux), soit ≈ 24 %. Les 5 échecs sont **la même transaction** : celle du webhook (`feexpayPayments.js:621`), en phase 1 (webhook contre quarantaine), après une attente de 8,4 à 9,7 s, avec `3 INVALID_ARGUMENT: Transaction is invalid or closed.` La transaction de quarantaine n'échoue jamais ; la phase 2 (deux webhooks simultanés) n'échoue jamais.
- **Mécanisme :** la quarantaine lit le profil puis écrit tombstone + profil ; le webhook lit le profil puis le tombstone (absent). Ces ordres de verrouillage se croisent dans l'émulateur : l'une des transactions est sacrifiée (la quarantaine est rejouée par le SDK sur `ABORTED`, ≈ 2,6 s), mais le webhook, dont une lecture reste bloquée, finit par recevoir `INVALID_ARGUMENT`, **code non rejoué par le SDK**.
- **Preuve d'ordre de lecture (expérience hors dépôt, 100 tours par ligne) :** tombstone d'abord → 0/200 échec ; `getAll` → 0/200 ; profil d'abord (séquentiel) → 32/200 (16 %) ; lectures parallèles (forme du code actuel) → 4/280 (≈ 1,4 % par tour, ce qui correspond à ≈ 30 % pour les 25 tours de la phase 1 de C2).
- **Aucun risque financier démontré :** 900 tours avec le VRAI `processFeexPayWebhookEvent` contre la quarantaine, invariants contrôlés après chaque tour : **0 violation**. Les 6 erreurs de transaction du webhook n'ont laissé **aucune écriture partielle** (solde 0, statut `pending`, journal vide) et le rejeu du webhook a crédité **exactement une fois** (6/6).
- Le test C2 n'est donc pas un révélateur d'un double crédit ou d'un crédit perdu ; il est **fragile** parce qu'il exige que la transaction du webhook ne subisse aucune erreur du moteur, alors que C1 (même fichier) documente et tolère précisément cette erreur.
- **Décision proposée pour L1 : autorisable avec réserve** (voir §9).

## 2. Analyse statique du test C2 (`accountQuarantineConcurrency.emulator.test.js:180`)

Préconditions : `FIRESTORE_EMULATOR_HOST`, projet `demo-*`, axios remplacé, 25 rondes (`ROUNDS`).

- **Phase 1 (25 rondes)** : `seedPay(Q_i)` crée `clients/{uid}` (wallet 0) et `wallet_transactions/Q_i` (pending, créé il y a 60 s) ; puis `await Promise.all([hook(webhook SUCCESSFUL, 1000), quarantine(uid)])`. Attendu : transaction `completed`, solde 1000 (paiement antérieur au tombstone ⇒ toujours crédité).
- **Phase 2 (25 rondes)** : tombstone posé avant, paiement créé 1 s avant l'appel ⇒ deux webhooks simultanés, exactement un `held_for_review`, solde 0.
- `Promise.all` (et non `allSettled`) : toute exception d'une des deux fonctions fait échouer le test immédiatement. C1 utilise `allSettled` et rejoue le webhook, avec le commentaire suivant : l'émulateur peut rejeter une transaction en interblocage par `INVALID_ARGUMENT "Transaction is invalid or closed"` là où Firestore renvoie `ABORTED` (SDK réessaie) ; constaté aussi avant la mission 7E-68.

## 3. Fonctions et transactions impliquées

| Transaction | Source | Lectures | Écritures |
|---|---|---|---|
| Webhook | `processFeexPayWebhookEvent`, `feexpayPayments.js:621` | `wallet_transactions/{id}`, puis **en parallèle** `Promise.all([get(clients/{uid}), get(account_tombstones/{uid})])` | `clients/{uid}.wallet`, `wallet_transactions/{id}` (completed), `clients/{uid}/wallet_transactions/*` ; ou, si « hold » : statut `held_for_review` seul |
| Quarantaine (helper du test, même forme que `accountDeletion.js`) | test:55 | `clients/{uid}` | `account_tombstones/{uid}` (create), `clients/{uid}` (isSuspended) |

Contrôle du cycle de vie transactionnel : le callback du webhook n'utilise que l'objet `firestoreTx` reçu, toutes les lectures sont `await`ées avant la première écriture, aucun appel asynchrone ne survit au callback, aucun objet transactionnel n'est réutilisé, les effets externes (`logSecurityEvent`, `logAudit`) sont hors transaction, après son `commit`. Le code **respecte** le protocole Firestore (lectures avant écritures, callback idempotent : le `heldReason` est réinitialisé à chaque tentative). Pas de timeout ni de retry propres : le SDK rejoue sur `ABORTED` (jusqu'à 5 tentatives) mais pas sur `INVALID_ARGUMENT`.

Effets financiers possibles si l'opération échoue : la transaction est tout-ou-rien ; le webhook renvoie une erreur (le fournisseur rejouera la livraison) ; `already_processed` empêche le double crédit (`credited`/`status`).

## 4. Protocole des rejeux

- Émulateur Firestore seul, ports 28080/24400/24500 (libres vérifiés), projet par défaut `demo-l0f` ; un projet **distinct par rejeu** (`demo-l0f-iso1`…`iso20`) = état indépendant ; un seul processus de test à la fois ; garde de sortie réseau chargée ; variables `GOOGLE_APPLICATION_CREDENTIALS`, `FIREBASE_CONFIG`, `AZ_PILOT_DRIVER_IDS` retirées.
- Commande : `node --test --test-name-pattern='^C2\.' test/accountQuarantineConcurrency.emulator.test.js`.
- Observation seule : un préchargement hors dépôt (`scratchpad\l0f\tracer.js`) journalise chaque `runTransaction`, chaque tentative et chaque opération (chemin) avec horodatage. **Limite** : ce traceur peut modifier légèrement le timing ; il n'a pas été comparé à une série non tracée (les 3 rejeux isolés de L0-E, non tracés, étaient passés, 1 échec sur 4 au total hors trace).
- Pas de redémarrage de l'émulateur entre rejeux (l'isolation vient du projet distinct) ; non nécessaire.

## 5. Résultats détaillés

| Rejeu | Résultat | Durée | Transactions | Tentatives rejouées par le SDK |
|---|---|---|---|---|
| probe | **FAIL** (webhook, ronde 0) | 35 s | 17 évts | — |
| iso1 | PASS | 120 s | 100 | 59 |
| iso2 | PASS | 122 s | 100 | 64 |
| iso3 | PASS | 99 s | 100 | 47 |
| iso4 | PASS | 131 s | 100 | 63 |
| iso5 | **FAIL** (webhook, phase 1 ronde 24, 8 940 ms) | 41 s | 50 | 14 |
| iso6 | PASS | 116 s | 100 | 58 |
| iso7 | PASS | 119 s | 100 | 51 |
| iso8 | PASS | 112 s | 100 | 49 |
| iso9 | **FAIL** (webhook, ronde 8, 9 668 ms) | 26 s | 18 | 6 |
| iso10 | **FAIL** (webhook, ronde 13, 8 384 ms) | 31 s | 28 | 6 |
| iso11–14 | PASS ×4 | 104–129 s | 100 | 49–61 |
| iso15 | **FAIL** (webhook, ronde 1, 9 321 ms) | 12 s | 4 | 1 |
| iso16–20 | PASS ×5 | 104–126 s | 100 | 47–60 |

Total : **16 PASS / 5 FAIL sur 21** (rejeux 1–20 : 16 PASS / 4 FAIL). Message identique dans les 5 cas : `3 INVALID_ARGUMENT: Transaction is invalid or closed.` (`code: 3`, pile gRPC sans ligne du dépôt, `testCodeFailure`). Journaux : `scratchpad\l0f\logs\iso_N.tap|.trace`.

Les rejeux réussis ne sont pas « calmes » : 47 à 64 des 100 transactions de C2 sont rejouées par le SDK après un `ABORTED` (contention normale, ≈ 100 s par test au lieu de quelques secondes).

## 6. Trace type d'un échec (iso15, ronde 1)

```
t=2079  tx3 (webhook)    attempt 1, get wallet_transactions/Q1
t=2080  tx4 (quarantine) attempt 1, get clients/cq1
t=2084  tx3              get clients/cq1
t=2085  tx3              get account_tombstones/cq1        <- envoyées en parallèle
t=2088  tx4              create account_tombstones/cq1 ; update clients/cq1
t=4689  tx4              attempt 2 (rejouée par le SDK après ABORTED, ≈ 2,6 s)
t=4713  tx4              tx_ok (attempts=2)                 <- la quarantaine est terminée
t=11396 tx3              cb_error code 3 INVALID_ARGUMENT "Transaction is invalid or closed"   (9 321 ms)
```
La transaction du webhook reste bloquée sur ses lectures bien après la fin de la quarantaine, puis reçoit l'erreur : ce n'est pas une exception levée par le code métier.

## 7. Expérience de discrimination (hors dépôt, `scratchpad\l0f\exp.js`)

Même motif que C2 (quarantaine identique, gigue 0–80 ms), webhook réduit à ses lectures/écritures, 100 tours par ligne, projets neufs :

| Forme de lecture côté webhook | Échecs `INVALID_ARGUMENT` |
|---|---|
| tombstone puis profil (séquentiel) | 0 / 200 |
| `tx.getAll(profil, tombstone)` | 0 / 200 |
| profil puis tombstone (séquentiel) | 32 / 200 (16 %) |
| `Promise.all([get(profil), get(tombstone)])` (forme du code) | 4 / 280 (≈ 1,4 %) — une première série de 100 tours a été **écartée** (état laissé par un essai précédent : `ALREADY_EXISTS`, artefact de ma procédure) |

Conclusion : l'échec dépend de l'**ordre d'acquisition des verrous** (le profil, lu par la quarantaine avant d'être écrit, puis le tombstone créé). L'ordre d'arrivée des deux lectures parallèles est aléatoire, d'où l'intermittence. Ceci contredit en partie le commentaire du code (« une seule fenêtre de verrouillage ») : la lecture parallèle réduit le risque mais ne l'élimine pas dans l'émulateur.

## 8. Invariants financiers (vrai code, 3 × 300 tours, `scratchpad\l0f\exp3.js`)

Chaque tour : seed (solde 0, paiement antérieur de 60 s), `hook` ∥ `quarantine`, puis contrôle ; si le webhook a échoué : aucune écriture partielle attendue, puis rejeu du webhook.

| Invariant | Résultat |
|---|---|
| Aucun double crédit (solde = 1000 exactement ou 0 cohérent avec `credited`) | OK, 900/900 |
| Aucun crédit perdu (paiement antérieur au tombstone ⇒ crédité à la fin) | OK, 900/900 (après rejeu si erreur) |
| Aucune écriture partielle après erreur du webhook | OK, 6/6 (solde 0, statut `pending`, journal 0) |
| Cohérence journal ↔ solde (1 entrée d'historique par crédit) | OK, 900/900 |
| Tombstone toujours posé (aucun contournement de la quarantaine) | OK, 900/900 |
| Retry / idempotence : rejeu après erreur crédite exactement une fois | OK, 6/6 (`credited`) |
| Erreurs de transaction du webhook | 6 / 900 (0,7 %) ; quarantaine : 0 |

Aucun vrai paiement, aucun projet réel, vérificateur factice (`createFakeVerifier`).

## 9. Cause retenue, incertitudes, recommandations

**Catégorie D.** Preuves : (1) échec toujours sur la même transaction, même phase, même erreur ; (2) taux dépendant de l'ordre de lecture (0 % / 16 %) ; (3) aucune violation financière. Le code métier ne présente pas de défaut transactionnel démontré (A écarté : pas d'effet financier erroné) ; le test n'est pas seul en cause (B partiel : il ne tolère pas l'erreur qu'accepte C1) ; l'émulateur seul n'explique pas pourquoi le même schéma est à 0 % avec un autre ordre de lecture (C écarté comme cause exclusive).

**Incertitudes :** (a) l'émulateur produit `INVALID_ARGUMENT` là où Firestore renvoie `ABORTED` d'après le commentaire du code : non vérifiable sans Firestore réel ; si la production produisait aussi une erreur non rejouable, le webhook répondrait en erreur et le fournisseur rejouerait la livraison (idempotent, §8) ; (b) le traceur peut influencer le timing ; (c) les autres chemins qui lisent profil puis tombstone (initiation de paiement, retrait : tests A/A2 passés ici) n'ont pas été éprouvés avec 100+ tours ; (d) la cause interne de l'attente de 9 s dans l'émulateur n'a pas été élucidée.

**Recommandations (non appliquées) :**
1. Test : traiter C2 comme C1 (`allSettled`, rejeu du webhook, invariants) ou le marquer comme sensible à l'émulateur — décision du propriétaire du test.
2. Code (à étudier séparément, chemin financier sensible) : aligner l'ordre de lecture du webhook avec celui de la quarantaine (tombstone avant profil, ou `tx.getAll`) ; vérifier d'abord les autres appelants du même motif. Ne rien changer sans tests dédiés.
3. Option : boucle de rejeux de C2 sur une version modifiée **en copie** avant toute décision.

**Décision proposée pour L1 : autorisable avec réserve.** Les invariants financiers tiennent sur 900 tours et 21 exécutions ; l'échec n'est pas un blocage de sécurité. Réserves : C2 reste intermittent (≈ 24 % par exécution isolée) tant que le test ou l'ordre de lecture n'est pas traité ; tout lot L1 touchant au moteur de suppression/quarantaine ou au webhook doit relancer ce test avec rejeux et ne pas interpréter un échec isolé sans lire le message complet.

## 10. Limites

Émulateur uniquement (aucun Firestore réel), traceur susceptible de perturber le timing, procédures expérimentales hors dépôt réalisées sur des copies de motif (pas sur le code modifié), un essai comparatif écarté (état résiduel), deux premières exécutions parasites écartées (identifiant de projet invalide). Les 5 échecs pourraient avoir une fréquence différente en environnement non tracé.

## 11. Contrôle final

- HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, 0 stash.
- 20 fichiers suivis modifiés (11 préexistants + 9 de L0-D / L0-D.1), cinq fichiers sensibles inchangés (`21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60`) ; `feexpayPayments.js`, `accountDeletion.js` et le test C2 non modifiés.
- Non suivis : 109 avant la mission + ce rapport = 110.
- Aucun commit, push, stash ou déploiement ; aucun accès à `az-express-b0469` ; mes émulateurs arrêtés (28080, 24400, 24500 libres) ; ceux des ports 5001, 8080, 9099, 9199, 4000 intacts.
- Scripts et journaux : `…\scratchpad\l0f\` (hors dépôt).
