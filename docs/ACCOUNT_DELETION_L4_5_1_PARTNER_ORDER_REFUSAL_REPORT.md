# Mission L4.5.1 — Protection du refus de commande par un partenaire

Statut : **terminée dans son périmètre**. Dans les cas testés (unitaire, mutation, émulateur), un refus de commande par un partenaire (`refusePartnerOrder`) ne peut plus créditer le client ni rendre une commission à un compte en quarantaine, scellé, anonymisé, absent ou illisible. Aucun commit, push, stash ni déploiement ; aucun accès production / préprod ; L4.6, L4.7, L5–L7 non lancées ; `feexpayPayments.js`, `orderRefunds.js`, règles Firebase, cinq fichiers sensibles non touchés.

## 1. État Git

Initial (vérifié avant toute modification) : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **34 suivis modifiés, 154 non suivis**, hashes (`git hash-object`) des cinq fichiers sensibles, de `feexpayPayments.js` (232dbcea) et `orderRefunds.js` (d985269a) conformes.
Final : HEAD `d65c8f0`, index vide, stash 0, **35 suivis modifiés** (+`partnerOrderActions.js`), **157 non suivis** (154 + 2 fichiers de test + ce rapport). Hashes inchangés : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. `orderActions.js` **strictement identique** à son état de fin de L4.5 (les protections L4.5 sont intactes). Aucune opération Git destructive.

## 2. Flux financier (audit avant modification)

- **Acteur** : le *partenaire* propriétaire de la commande (`order.sellerId === uid`, type restaurant / pharmacie / boulangerie, `amountsVersion` 2), avec un profil partenaire existant et actif. Ce n'est ni le client ni le livreur ; les contrôles d'acteur existants (commande introuvable pour un tiers, compte partenaire indisponible, gel de gestion, limite de débit) sont inchangés.
- **Chemin** : `applyAction` → `cancelOrderTx(…, uid: order.clientId, reason: 'partner_refused')`, **sans** `closure` (donc aucune garde), puis `tx.update(orderRef, { partnerRefusal })`, puis, hors transaction, `cancelOrderPostTx` (journaux) et audit.
- **Comptes réellement crédités / débités** : (1) **client** (`clients/<clientId>`) : remboursé du total payé par wallet (`isPaid`) ; (2) **payeur de la commission** (livreur ayant accepté — `commissionPayerId` tracé, sinon le livreur de la commande) : commission rendue si un livreur a accepté. (3) **Vendeur** : `needsSellerDebit` ne vaut que pour `sellerType: 'seller'` (Marketplace) ou Boutique ; ces types ne sont pas des types partenaires v2 (`PARTNER_SELLER_TYPES`), donc **le partenaire n'est jamais débité** sur ce chemin — vérifié par test. Le livreur de la commande est seulement libéré (aucun mouvement d'argent).
- **Avant** : aucune vérification d'état de fermeture ; client et payeur crédités même fermés (ou, si absents, ignorés en silence).
- **Idempotence** : une commande déjà `cancelled` avec `partnerRefusal` rend `replay` sans second mouvement ; journaux déterministes ; statut vérifié dans la transaction.
- **Effets secondaires** : journaux `cancelOrderPostTx` post-transaction (non atomiques, préexistants, inchangés) et audit.

## 3. Modification

`functions/partnerOrderActions.js` (seul fichier de production modifié) :
- l'appel à `cancelOrderTx` reçoit `closure: { admin: true, HttpsError }`, le mode « tous les bénéficiaires » de L4.5 (nom hérité : il n'est pas réservé aux administrateurs ; il évite le contrôle d'*acteur* de `closureGuard`, qui supposerait que l'acteur est le client). Réutilisation du helper existant, **aucun second système de garde** ;
- l'erreur `BENEFICIARY_ACCOUNT_CLOSED` est convertie en `Refusal` : le partenaire reçoit l'enveloppe habituelle `{ success: false, code: 'BENEFICIARY_ACCOUNT_CLOSED', message }` (« la commande reste en l'état ; contactez le support AZ Express ») et un audit `denied`, au lieu d'une erreur technique.

`orderActions.js` : **non modifié** (aucune adaptation nécessaire).

## 4. Bénéficiaires contrôlés

Dans la transaction, avant la première écriture, via `assertBeneficiariesCreditable` : le client (si un remboursement est dû) ; le payeur de la commission (si une commission est rendue) ; le vendeur (si un débit était dû — jamais le cas ici). Seuls actif et « suppression demandée » passent. Commande cash ou non payée (aucun remboursement dû) : aucun bénéficiaire, le refus reste possible même si le client est fermé — aucun crédit n'est de toute façon créé. Sous-cas **non tranché, refusé** : client fermé alors qu'un remboursement est dû → la commande reste ouverte (ni compensation inventée, ni détournement) ; le partenaire ne peut pas la refuser tant que le client est fermé. **Décision métier à prendre** si l'on veut une autre issue (par exemple annulation sans crédit avec dette tracée) : elle demanderait le règlement différé, non implémenté.

## 5. Résultats

Node 22.23.4 (`node.exe` explicite), garde de sortie réseau.
- **Unitaire** `partnerOrderRefusalL451.test.js` : **7/7** — tous actifs (client +4000, commission +100, une fois, rejeu sans doublon, partenaire non débité) ; client × payeur (= livreur) **36 combinaisons** ; client × payeur distinct **36 combinaisons** ; commande sans livreur (5 états de client refusés) ; commande cash avec client scellé (refus du partenaire possible, aucun crédit) ; erreur de lecture Firestore ; régularisation puis retry (un seul remboursement) ; permissions (autre partenaire, client, livreur, inconnu, anonyme : refusés sans écriture) ; câblage (le refus partenaire en mode complet, `cancelOrderCF` toujours en mode client). Pour chaque refus : magasin strictement identique, deux essais successifs identiques, aucun journal, `partnerRefusal` absent.
- **Mutations : 6/6 tuées**, fichiers restaurés (`diff` identique) : mode complet retiré ; conversion d'erreur désactivée ; payeur non vérifié ; client non vérifié ; état « scellé » autorisé ; liste de bénéficiaires vidée.
- **Émulateur `demo-l451-emu`** (port 28080, arrêté ensuite) `partnerOrderRefusalL451.emulator.test.js` **5/5, 3 exécutions** : 5 états × (client, payeur) refusés avec soldes et journaux intacts et retry sans effet ; actifs crédités une fois ; **course réelle refus / scellement** (client, payeur, les deux), scelleur transactionnel à marqueurs sérialisables : 225 rondes, crédité 11–18 / 25, refusé 7–14 / 25, `emulatorRejects: 0`, **jamais un crédit après un tombstone, jamais un crédit partiel**.
- **Autres appels à `cancelOrderTx`** : `orderActions.test.js`, `partnerOrderActions`, `partnerOrderFinancial`, `partnerOrderAdminPaths` (171 tests) verts ; régressions émulateur `partnerOrderConcurrency` 27/27 (une première exécution, tuée par mon délai de 200 s à 24/25, a été rejouée avec un délai suffisant), `adminFinancialPathsL45` 5/5, `orderActionsL4` 4/4. `partnerOrderClientAllowlist.emulator` : 7 tests ignorés (exigences d'environnement propres à cette suite, **non exécutée**).
- **Suite pure complète : 2858 tests, 2680 réussis, 0 échec, 178 ignorés** (référence L4.5 : 2850 / 2673 / 0 / 177).
- Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID) ; une suite à la fois.

## 6. Invariants vérifiés

Aucun remboursement ni crédit de commission sur un compte fermé, absent ou illisible ; aucun crédit partiel ; aucune écriture avant la vérification ; commande inchangée sur refus (statut, `partnerRefusal`, soldes, journaux) ; aucun débit vendeur non autorisé ; aucun journal fictif ; aucun détournement vers AZ ; idempotence ; compte jamais rouvert.

## 7. C2

Chemin de quarantaine (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js`) non modifié ⇒ L0-F non rejoué. C2 reste intermittent (17/20 sur émulateur) et **n'est pas déclaré corrigé**.

## 8. Risques résiduels

1. Un refus bloqué (client ou payeur fermé) laisse la commande ouverte ; sans règlement différé, elle reste à traiter par le support (décision métier ci-dessus).
2. Sur-refus fail-closed possible quand le payeur de commission distinct du livreur est fermé.
3. Journaux post-transaction (`cancelOrderPostTx`) toujours non atomiques (préexistant).
4. Autres appelants de `cancelOrderTx` hors périmètre : `orderRefunds.js` (expirations), writers L5.
5. Preuves sur faux Firestore et émulateur uniquement ; rien en production ni sur appareil.

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation.
