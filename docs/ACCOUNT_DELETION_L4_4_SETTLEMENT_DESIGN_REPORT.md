# Mission L4.4 — Étude du mécanisme de régularisation financière

Statut : **étude terminée, aucune implémentation.** Lecture seule du code et des documents ; seul ce rapport est créé. Aucun code, test, règle, secret ni configuration modifié ; aucune écriture Firebase ; aucun émulateur lancé ; aucun commit, push, stash ni déploiement ; production et préproduction non touchées ; `feexpayPayments.js` et `orderRefunds.js` non modifiés ; L5–L7 non lancées.

## 1. État Git

Initial : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **31 suivis modifiés, 150 non suivis** (identique à L4.3). Hashes : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a.
Final : mêmes HEAD, branche, index vide, stash 0, 31 suivis modifiés, **151 non suivis** (150 + ce rapport) ; hashes inchangés (vérifiés en fin de mission).

## 2. Fichiers examinés (lecture seule)

`functions/orderActions.js`, `adminBilling.js`, `accountClosureActor.js`, `transferSettlement.js`, `earningsSettlement.js`, `adminOrderDisputes.js`, `orderRefunds.js`, `walletReconciliation.js`, `accountObligations.js` (+ `accountObligationsInspector.js`), `firestore.rules`, `FIRESTORE_SCHEMA.md`, `docs/ACCOUNT_DELETION_7E102_BUSINESS_DECISIONS.md`, `…2D2A10_FINANCIAL_DECISIONS.md`, rapports L4 à L4.3.

## 3. Découverte majeure : une conception existe déjà

Le moteur d'obligations (`accountObligations.js`, 7E-98 à 7E-108, **non suivi**, jamais branché sur un exécutant) décrit déjà : des types de signalements dont `beneficiary_account_closed` et `partner_credit_missing` ; une table `RESOLUTIONS` par type avec niveaux de validation (N1 constat prouvé par un super-admin ; N2 deux super-admins distincts ; N3 accord du créancier, **indisponible** faute de contrat de consentement) ; un lecteur de **registre de décisions** (`status:'executed'`, `requestId`, `approvedBy ≠ requestedBy`, `remaining = 0`, `evidenceRef`) et de **documents de preuve** (`status:'verified'`, liés à la décision) ; et la décision M-3 de 7E-102 : *séparer « réautoriser une tentative » (`clearBeneficiaryReview`) et « fermer le signalement » (résolution N1/N2)*. **Ce qui n'existe pas** : la collection du registre, celle des preuves, l'exécutant, les règles — `resolved` n'a « aucun écrivain actuel ». La conception recommandée ci-dessous **prolonge** ce cadre au lieu d'en inventer un second.

## 4. Inventaire : ce qui est conservé, tracé ou dû

Principe vérifié : le modèle de solde est le champ `wallet` du document de rôle + sous-collection `wallet_transactions` (append-only, journaux à identifiants déterministes). **Il n'existe aucun portefeuille ni grand livre AZ** : `config/az_wallet` ne contient que des compteurs (`totalCommissions` incrémenté à la livraison ou par décision `retain`, `retainedDeliveryFees`). L'argent physique est sur les comptes de paiement AZ (hors système). « Conserver » une somme ne peut donc signifier que : (i) ne la créditer à personne, (ii) l'enregistrer de façon atomique, non écrasable et bloquante, (iii) ne la solder que par une décision vérifiée.

| Élément | Nature réelle | Retenue ? | Exécutant de règlement ? |
|---|---|---|---|
| `heldDriverEarning` + `settlementStatus` + `transfer_settlements` | gain livreur d'une course transférée, montant sur la commande, dossier à état | **tracé + exécutant existant** (`transferSettlement.js` : crédit atomique, journaux `transfer_settlement_<order>_<livreur>`, rejeu sans effet, super-admin) | oui |
| `deliveryFeeHold` + `resolveFeeHold` | frais de livraison retenus après récupération (Marketplace/Boutique) | **tracé + exécutant** (`adminBilling.resolveFeeHold`, journaux déterministes, décision unique) | oui |
| `reconciliation_flags` `partner_credit_missing` | dette envers un partenaire introuvable (legacy) | tracé seulement ; plus produit par la livraison (L4) | non |
| `reconciliation_flags/<o>_beneficiary_closed` (L4, annulation) | **commission non remboursée** à un livreur fermé, montant dans `parties[].amountWithheld` | **tracé seulement** : la commission a été débitée à l'acceptation (journal `commission_<o>_<d>` existant), jamais créditée ; **aucun mouvement, aucune réserve** | non |
| `reconciliation_flags/<o>_{pay,deliver,cancel}_beneficiary_refused` (L4) | trace d'une opération refusée | **aucune somme impliquée** (rien n'a bougé) ; statut de commande conservé | levée de verrou seulement |
| anciens `partner_credit_held` | produits par L4 puis supprimés en L4.1 | **jamais déployés** (L4 non déployée) : aucun en base | — |
| `commissionStatus:'charged'` sur commande annulée | état de la commission restée côté AZ | tracé ; **contredit la décision « non acquise à AZ »** : l'état dit « prélevée », la dette n'est pas exprimée | non |
| `config/az_wallet` | compteurs | ne retient rien | — |

**Conclusion §4 : aucune somme omise par L4 n'est retenue au sens financier ; elles sont tracées dans un signalement, et rien ne permet encore de les solder.** Seules `heldDriverEarning` et `deliveryFeeHold` disposent d'un exécutant.

Constats de compatibilité (à corriger lors de l'implémentation, non modifiés ici) :
1. **Les signalements L4 sont invisibles pour le moteur d'obligations.** L'inspecteur lit `reconciliation_flags` par `driverId` / `sellerId` / `pharmacieId` / `clientId` / `partnerId` de premier niveau ; nos signalements portent le bénéficiaire dans `parties[]` ou `beneficiary{}`, et leurs types (`beneficiary_closed`, `beneficiary_closed_refused`) sont étiquetés `other`. Ils ne seraient ni trouvés ni comptés.
2. `clearBeneficiaryReview` (L4/L4.1) passe les signalements de refus à `status:'cleared'`, valeur **inconnue** du moteur (`unknown_flag_status` ⇒ ambigu bloquant) ; et il fusionne levée de verrou et fermeture, contrairement à M-3.
3. Les chemins administratifs qui **créditent sans garde de fermeture** : `adminBilling.resolveFeeHold` (remboursement de commission au payeur, rémunération du livreur, remboursement du client), `adminBilling.closeStuckDelivery` (annulation sans `closure`), `refundBoutiqueOrder`, `adminOrderDisputes` (remboursements A/B/C/D), `transferSettlement` (vérifie seulement l'existence du livreur). `orderRefunds.js` : voir L5. Aucun n'est couvert par L4.1–L4.3.

## 5. Cas métier

**A. Quarantaine.** Le tombstone n'est jamais supprimé ; aujourd'hui aucune voie ne rétablit un compte (2D-2A.10 Q1 « annulation de la demande » est une proposition non implémentée). Règlement possible **si et seulement si** un rétablissement validé existe : crédit du **même compte**, journal `settle_due_<créance>` déterministe, état relu actif dans la transaction (N1, preuve : la créance existe et n'a jamais été soldée). Sans rétablissement, la quarantaine aboutit au scellé : cas B. Aucun double crédit : statut de la créance + journal déterministe lus et écrits dans la même transaction.

**B. Scellé.** Profil encore présent, Auth en cours de suppression ; aucun crédit, aucune réouverture. Règlement uniquement **hors portefeuille du compte scellé** : (i) paiement hors système au titulaire ou à l'ayant droit vérifié (référence mobile money, N2) ; ou (ii) **substitution** : crédit d'un autre compte **actif** désigné (`beneficiary_substituted`, N2) — exige un fondement juridique (procuration, succession) fourni hors système, jamais déduit.

**C. Anonymisé.** Les données personnelles sont effacées par conception : **aucune ré-identification ne doit être tentée ni proposée**. Une créance d'un compte anonymisé ne peut être traitée que **sur réclamation** d'une personne qui prouve hors système son droit (pièces, lien avec la commande par ses propres références de transaction) ; l'administration vérifie hors système et n'enregistre que des références techniques (identifiant de décision, de preuve, de paiement), jamais d'identité. Limites : durée de conservation de la créance, prescription, sort des sommes non réclamées (déshérence) et renonciation (N3, indisponible) sont des questions **juridiques** à trancher avec un conseil local avant toute implémentation ; aucune hypothèse légale n'est posée ici.

**D. Absent.** Même régime que C. Preuves disponibles : la commande (`driverId` / `sellerId`), le journal source `commission_<o>_<d>` (peut avoir disparu avec le profil : à vérifier), `commissions`. Si ni la commande ni le journal ne prouvent la dette, elle n'est **pas créée** (« aucune dette inventée » — principe 7E-102).

**E. Livraison administrative bloquée (`picked_up`).** Aujourd'hui (L4.3) : refus intégral, le client a pourtant payé. Trois voies :
- *E1 (recommandée, après registre)* : action administrative distincte « confirmer la livraison avec créances différées » (N2) : dans **une seule transaction**, crédite les seuls comptes créditables, marque `delivered`, et crée une créance typée pour chaque part non créditable. La livraison est ainsi séparée du règlement, sans qu'aucune somme ne puisse se perdre (créance atomique avec l'omission).
- *E2 (immédiate, déjà existante)* : annuler et rembourser le client par les litiges administratifs (`adminOrderDisputes`, `closeStuckDelivery` Marketplace/Boutique) — mais ces chemins ne sont pas gardés (§4.3) : à garder d'abord.
- *E3* : laisser bloqué (état actuel) — sûr, mais laisse le livreur et le client sans issue.

**F. Marketplace et Boutique — opérations financièrement différentes, règles distinctes :**

| Opération | Sens | Mécanisme existant | Traitement futur |
|---|---|---|---|
| Commission livreur (100/200) prélevée à l'acceptation, rendue à l'annulation | **dette envers le livreur** | journal `commission_<o>_<d>` ; remboursement dans `cancelOrderTx` | créance `commission_refund` (cas A–D) |
| Produits Marketplace/Boutique payés 100 % au vendeur à la création (0 % commission) | vendeur déjà crédité | — | à l'annulation, le vendeur est **débité** : c'est une **créance d'AZ/du client sur le vendeur**, de sens inverse ; vendeur fermé ⇒ décision E de L4.1 (non tranchée), **ne pas** réutiliser le flux « dette envers un bénéficiaire » |
| Frais de livraison retenus après récupération | à répartir (client / livreur / AZ) | `deliveryFeeHold` + `resolveFeeHold` (exécutant) | garder ce mécanisme ; ajouter seulement la garde de fermeture au crédit |
| Boutique : paiement sur `boutique_orders` | document séparé | remboursement dédié | hors flux de créances de livraison |
| Restaurant v2 : produits au partenaire, frais au livreur | deux crédits à la livraison | crédits dans `deliverOrderCF` | créances `partner_product_credit` et `driver_fee_credit` si E1 |
| E-Kbine | `fee = 0` | agent crédité du montant prouvé | hors périmètre (décisions X-1/X-2 distinctes) |

## 6. Architectures

### Option 1 (recommandée) — Créance = signalement typé strict + registre de décisions/preuves (extension du moteur existant)

- **Modèle de données.** Aucune collection de dettes nouvelle. La créance est un document `reconciliation_flags/<orderId>_due_<kind>_<beneficiaryId>` créé **dans la même transaction que l'omission** (création seule, jamais écrasé). Champs : `type:'beneficiary_account_closed'` (type du moteur), `kind` (`commission_refund` | `partner_product_credit` | `driver_fee_credit`), `orderId`, `amount` (entier), `currency:'XOF'`, identifiant du bénéficiaire en champ de premier niveau (`driverId` / `sellerId` / `pharmacieId`) pour être vu par l'inspecteur, `beneficiaryStateAtCreation`, `originFn`, `sourceJournalId`, `createdAtMs`, `status:'open'`. À la résolution seulement : `status:'resolved'` + les cinq champs de trace exigés par le moteur + `settlement{decisionId, resolution, method, journalId?, externalRef?, executedAtMs}`.
- **Registre.** Deux collections serveur seul (déjà prévues par M-1) : décisions append-only (`requested → approved → executed`, `tier`, `requestId`, `approvedBy`, `remaining`) et preuves vérifiées (liées à la décision, au sujet, à la résolution). Identifiant de décision = hash(`sujet|requestId`).
- **Exécutant.** Un module et une action `adminSettlementCF` (super-admin) : demander, approuver (second super-admin), exécuter. Règlements : `payment_completed` (N1, preuve calculée par le serveur), `paid_out_of_system` (N2, référence externe unique), `beneficiary_substituted` (N2, compte actif désigné, crédit avec journal `settle_due_<créance>`).
- **Prévention des doubles paiements.** (a) statut de la créance relu et écrit dans la transaction ; (b) journal de règlement à identifiant **par créance** (pas par `requestId`) : deux demandes distinctes ne peuvent pas payer deux fois ; (c) décision à identifiant déterministe ; (d) référence externe enregistrée en création seule (`external_refs/<hash>`) ; (e) `remaining` pour les règlements partiels.
- **Erreurs.** Tout état ambigu ou illisible refuse ; aucune écriture partielle ; compte substitut relu actif dans la transaction (comme L4.3).
- **Audit.** `audit_logs` (existants) + registre immuable ; aucune donnée personnelle ; pas de levée de signalement sans décision exécutée.
- **Compatibilité.** Transactions et `wallet_transactions` existants ; `walletReconciliation` : le crédit de substitution doit utiliser un type connu (`credit` ou `earning`) ; le moteur d'obligations lit déjà ces objets.
- **Coût / maintenance.** Un module + deux collections + règles + écran administrateur ; mais aucune nouvelle sémantique : la conception est déjà approuvée en principe (7E-102/107).
- **Risques.** Hétérogénéité de `reconciliation_flags` (limite de lecture 201 par requête ⇒ revue manuelle au-delà) ; dépendance à un second super-admin (voir §9) ; N3/abandon indisponibles.

### Option 2 — Collection dédiée `deferred_credits/{créance}` avec machine à états intégrée

- **Modèle.** Un document par créance (mêmes champs), état `due → verified → authorized → paid | paid_out_of_system | void`, sous-objets `verification`, `authorization` (deux approbateurs), `settlement` (journal, référence externe). Le journal de règlement et la décision sont embarqués dans le document.
- **Doubles paiements.** Transition d'état dans une transaction + journal déterministe par créance.
- **Pour.** Sémantique plus nette (une collection = une dette), requêtes simples par bénéficiaire, pas de pollution de `reconciliation_flags`.
- **Contre.** Duplique le registre de décisions du moteur approuvé ; exige d'enseigner à l'inspecteur une quatrième liste (lectures supplémentaires, nouvelle couverture) ; deux sources de vérité pour les signalements ; plus de code et de règles.

### Comparaison

| Critère | Option 1 | Option 2 |
|---|---|---|
| Réutilise le moteur et les décisions 7E-102 | oui | partiel |
| Nouvelles collections | 2 (registre, preuves) + 1 optionnelle (références externes) | 1 (+ registre si l'on garde la maker-checker) |
| Visibilité pour les contrôles de suppression de compte | immédiate | à développer |
| Séparation « dette » / « signalement » | moyenne (type strict) | nette |
| Coût d'implémentation | moyen | élevé |
| Maintenance | un seul modèle d'obligations | deux modèles à tenir cohérents |

Réponse à « une nouvelle collection ou un nouveau module est-il réellement nécessaire ? » : **un module oui** (l'exécutant), **des collections de registre/preuves oui** (aucun support actuel pour N2) ; **pas de collection de dettes** si l'Option 1 est retenue.

## 7. Procédure administrative proposée (valable pour l'Option 1)

1. **Identifier la somme due** : créance `open` liée à la commande, bénéficiaire, montant entier XOF.
2. **Vérifier la commande et le journal source** : le serveur relit la commande (statut, montants, `commissionAmount`) et le journal `commission_<o>_<d>` ; la créance doit correspondre exactement ; sinon elle est refusée (aucune dette inventée).
3. **Vérifier le bénéficiaire ou l'ayant droit** : hors système pour B–D ; l'administrateur dépose une **preuve** (document de preuve vérifié par un second acteur, références techniques seulement). Cette vérification **n'est pas** une autorisation.
4. **Vérifier que la somme n'a jamais été réglée** : statut `open`, absence du journal `settle_due_<créance>`, absence de décision exécutée, référence externe non utilisée.
5. **Autorisation** : N1 (A, `payment_completed`) ou N2 (B–D) ; demandeur ≠ approbateur ≠ décideur d'origine.
6. **Règlement** : crédit d'un compte actif désigné, ou paiement hors système enregistré ; jamais de crédit à un compte fermé, jamais de réouverture.
7. **Preuve du règlement** : décision `executed`, journal (ou référence externe), signalement `resolved` avec les champs de trace, audit.
8. **Anti-répétition** : voir §6 (statut + journal par créance + décision déterministe + référence unique).

**Distinction essentielle.** *Lever un verrou* (`clearBeneficiaryReview`) = autoriser une nouvelle tentative de l'opération (paiement / livraison) quand le bénéficiaire est redevenu créditable ; *résoudre un signalement* = changer son état après une décision exécutée ; *valider un règlement* = décision N1/N2 avec preuve **et** écriture du journal / de la référence. Aucune de ces trois actions n'implique les deux autres.

## 8. Risques et limites

Absence d'AZ ledger (la conservation reste comptable) ; dépendance à un second super-admin pour N2 (aujourd'hui un seul : « N2 en attente ») ; N3 et la renonciation indisponibles ; questions juridiques sur C/D ; flags L4 invisibles du moteur tant qu'ils ne sont pas réalignés ; chemins administratifs de crédit non gardés (§4.3) ; limite de lecture 201 ; données personnelles : le registre ne doit contenir que des références techniques.

## 9. Décisions métier et juridiques encore nécessaires

1. **Choix de l'architecture** (Option 1 recommandée, Option 2 alternative).
2. **Maker-checker** : existe-t-il ou existera-t-il un second super-admin ? Sinon quelle alternative (délai + justification renforcée) — 7E-102 pose déjà la question.
3. **Ayant droit** : définition et pièces acceptables (succession, procuration), qui les vérifie, et où elles sont conservées hors système.
4. **Anonymisé/absent** : durée de conservation de la créance, prescription, sort des sommes non réclamées, éventuelle renonciation (N3) — avis juridique requis.
5. **Substitution** : autorisée ou non (F-3 de 2D-2A.10 la refuse « tant que les règles métier ne sont pas définies »).
6. **Livraison bloquée** : E1, E2 ou E3 (et dans quel ordre).
7. **Commission d'une commande annulée** : confirmer que `commissionStatus:'charged'` doit devenir un état « due au livreur » (additif) afin de ne plus contredire la décision « non acquise à AZ ».
8. **M-3** : approuver la séparation `clearBeneficiaryReview` (nouvelle tentative) / fermeture du signalement, qui modifie 7E-97 §6.2.
9. **Gardes de fermeture** sur les chemins administratifs de crédit listés au §4.3 (mission préalable recommandée, car sans elles un règlement pourrait être contourné).
10. **Marketplace** : décision E de L4.1 (vendeur fermé à l'annulation), sens inverse de ce flux.

## 10. Fichiers qui seraient concernés par une implémentation (non modifiés ici)

Nouveaux : module exécutant (p. ex. `functions/obligationSettlement.js`) et ses tests ; tests de règles. Modifiés avec autorisation spécifique : `functions/index.js` (export — fichier sensible), `firestore.rules` (collections de registre/preuves/références, serveur seul) et `firestore.rules` tests, `functions/accountObligations.js` (types/résolutions, alignement), `functions/accountObligationsInspector.js` (si Option 2), `functions/orderActions.js` (forme des créances à la création, éventuelle action E1), `functions/accountClosureActor.js` (forme du signalement de refus), `functions/adminBilling.js` (`clearBeneficiaryReview` scindé ; garde de fermeture sur `resolveFeeHold` / `closeStuckDelivery` / `refundBoutiqueOrder`), `functions/adminOrderDisputes.js` et `functions/transferSettlement.js` (gardes), `OPERATIONS_RUNBOOK.md`, `FIRESTORE_SCHEMA.md`, `FIRESTORE_RULES.md`, écran administrateur Flutter (non existant pour ce flux). `orderRefunds.js` : L5.

## 11. Tests nécessaires (future implémentation)

Unitaires purs : machine à états de la créance, appariement créance ↔ commande ↔ journal, niveaux N1/N2 et identités distinctes, rejet N3, références externes uniques. Fonctions réelles : règlement unique malgré deux `requestId`, rejeu du même `requestId`, compte substitut fermé/absent/illisible refusé, aucun crédit à un compte scellé ou anonymisé, erreurs de lecture, permissions (sous-admin, client, anonyme), absence de journal positif sans crédit réel, `walletReconciliation` cohérente. Émulateur `demo-*` : concurrence règlement ↔ scellement du substitut (marqueurs sérialisables, comme L4.3), doubles demandes simultanées, atomicité création de créance + omission. Règles Firestore : collections de registre/preuves en `allow write: if false`. Mutations sur les gardes et sur l'identifiant de journal. Régression : suites L3–L4.3, moteur d'obligations, `clearBeneficiaryReview`.

## 12. Confirmations

Aucun code financier n'a été modifié ; aucun fichier de code, de test, de règles ou de configuration n'a été touché ; le seul fichier créé est ce rapport. **Aucun commit, push, stash ni déploiement ; aucun accès production ou préproduction ; aucune écriture Firebase.** Arrêt : en attente de votre examen et des décisions du §9.
