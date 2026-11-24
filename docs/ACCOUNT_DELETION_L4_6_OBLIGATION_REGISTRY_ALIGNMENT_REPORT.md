# Mission L4.6 — Harmonisation des signalements et du moteur d'obligations

Statut : **terminée dans son périmètre**. Le moteur `accountObligations.js` reconnaît désormais les signalements écrits par L4 (`beneficiary_closed`, `beneficiary_closed_refused`), identifie le bénéficiaire réel sans ambiguïté, et la levée d'un verrou (`clearBeneficiaryReview`) ne ferme plus aucune créance. Aucune somme n'est déclarée payée : aucun mécanisme de preuve de règlement n'existe encore. Règlement différé, collections de décisions / preuves, module exécutant, portefeuille et grand livre : **non créés**. Aucun commit, push, stash ni déploiement ; aucun accès production / préprod ; L4.7 et L5–L7 non lancées.

## 1. État Git

Initial (vérifié avant toute modification) : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **35 suivis modifiés, 157 non suivis**, hashes (`git hash-object`) des cinq fichiers sensibles, de `feexpayPayments.js` (232dbcea) et `orderRefunds.js` (d985269a) conformes.
Final : HEAD `d65c8f0`, index vide, stash 0, **35 suivis modifiés** (aucun nouveau : les fichiers touchés étaient déjà modifiés ou non suivis), **159 non suivis** (157 + `test/obligationRegistryL46.test.js` + ce rapport). Hashes des sept fichiers protégés inchangés. Aucune opération Git destructive.

## 2. Fichiers

Production : `functions/accountObligations.js` (non suivi, moteur pur — reste sans `require`, horloge ni Firestore, vérifié par son test de pureté) ; `functions/accountClosureActor.js` (helper `flagPartyFields`, champs plats dans le signalement de refus) ; `functions/orderActions.js` (champs plats dans le signalement de crédit omis, 1 ligne + import) ; `functions/adminBilling.js` (sémantique de `clearBeneficiaryReview`). Jamais touchés : `feexpayPayments.js`, `orderRefunds.js`, règles Firebase, `accountObligationsInspector.js`, cinq fichiers sensibles.
Tests : créé `test/obligationRegistryL46.test.js` (17 tests) ; adaptés légitimement `test/beneficiaryReviewL4.test.js` (le signalement reste `open` + traces de levée, au lieu de `cleared`) et `test/accountClosureExceptions.test.js` (assertions additionnelles : champ plat et lecture du signalement réel par le moteur).

## 3. Compatibilité avant / après

**Avant** : le moteur ne connaissait pas les types `beneficiary_closed` / `beneficiary_closed_refused` (type « other »), cherchait le compte dans des champs plats absents (`flag_without_party`, ambigu) et traitait le statut `cleared` comme `unknown_flag_status` ; l'inspecteur, qui interroge `reconciliation_flags` par champ propriétaire (`driverId`, `clientId`, `sellerId`, `pharmacieId`, `partnerId`), ne retrouvait **jamais** ces signalements — une dette envers un compte fermé était invisible.

**Après** :
- **Identification du bénéficiaire** : la source de vérité est la structure imbriquée (`parties[]` ou `beneficiary` : collection + identifiant, collections connues seulement : clients, livreurs, sellers, pharmacies, restaurants, boulangeries). Les champs plats **additifs** (écrits maintenant par les deux écrivains L4 via `flagPartyFields`, pour la requête de l'inspecteur) doivent la **confirmer** ; une contradiction ou un doublon sur un même champ (champ alors omis) est ambigu. Aucune donnée personnelle n'est lue : seuls identifiants techniques et libellés de listes blanches atteignent le résultat (testé avec un faux nom et un faux numéro).
- **Plusieurs bénéficiaires** : chaque compte voit **sa** part (livreur 100, vendeur 400 dans le test), jamais celle de l'autre ; un compte tiers voit « document non lié ».
- **Montant, devise, origine, journal source** : exigés pour `beneficiary_closed` (montant entier > 0 du bénéficiaire, devise XOF, `kind: commission_refund_omitted`, `sourceJournalId`) ; le manque de l'un d'eux rend le signalement **ambigu et bloquant** (`flag_amount_invalid`, `flag_currency_invalid`, `flag_kind_unknown`, `flag_source_journal_missing`, `flag_parties_unreadable`, `flag_order_missing`, `flag_party_contradiction`), jamais réglable. Créance rattachée à la créance économique « commission » (clé commande|créance, sans double comptage avec la revue de la commande). La trace de refus (`beneficiary_closed_refused`) est une trace d'opération non faite : aucun montant inventé, `completed: true` est contradictoire.
- **Revue de commande** : les motifs `beneficiary_closed` et `beneficiary_credit_omitted` sont nommés (liste blanche) ; tout autre motif reste « needs_review » générique.
- **Données historiques** : conservées intactes, aucune migration. Un signalement L4 sans champ plat reste **évalué correctement** s'il est fourni au moteur (testé) ; en revanche l'inspecteur ne peut pas le retrouver par requête (voir risques, nombre réel en base : L4 n'a **jamais été déployée**, donc aucun). `partner_credit_held` n'existe plus (supprimé en L4.1, jamais déployé).

## 4. États des signalements (moteur)

| Statut du signalement L4 | Lecture par le moteur |
|---|---|
| `open` | **revue, bloquant** (`flag_open:<type>`) |
| `cleared` (historique : verrou levé) | **revue, bloquant** (`flag_lock_lifted_debt_maintained`) — jamais conservé / réglé |
| `contested` | revue, bloquant |
| `recorded` / `reviewed` / `resolved` | **ambigu, bloquant** (`flag_closure_unproven`) : aucune décision ni preuve de règlement ne peut exister aujourd'hui |
| statut inconnu / illisible | ambigu, bloquant |

Rien n'est jamais « conservé » (non bloquant) pour ces types.

## 5. Séparation levée de verrou / créance (M-3)

`clearBeneficiaryReview` ne fait plus qu'**une levée de verrou opérationnel** : `orders.needsReview:false` (inchangé) et, sur le signalement, **seulement** `lockLifted:true`, `lockLiftedAtMs`, `lockLiftedBy`, `lockLiftJustification` — le statut reste `open`, `completed` reste `false`, aucun solde, journal, montant ni statut de règlement n'est touché, aucun crédit rétroactif (testé : soldes identiques, zéro journal). Les cinq notions sont désormais distinctes : (1) levée du verrou = traces `lockLifted*` ; (2) créance maintenue = statut `open` bloquant côté moteur ; (3) décision administrative = **non implémentée** (aucune écriture de décision) ; (4) preuve de règlement = **non implémentée** ; (5) clôture définitive = **impossible** aujourd'hui (tout statut de clôture est lu comme non prouvé). Le rejeu de la levée est idempotent (aucune écriture). Une levée reste refusée tant que le bénéficiaire est fermé et pour tout appelant non super-admin (testé).

## 6. Tests

Node 22.23.4 (`node.exe` explicite), garde de sortie réseau.
- **Ciblés** : `obligationRegistryL46.test.js` 17/17 ; moteur `accountObligations*` 82/82 (dont pureté) ; `accountClosureExceptions` 109/109 ; `beneficiaryReviewL4`, `financialIntegrityL41`, `accountClosureRegistry` verts.
- Couverture demandée : parties[] ; historique sans champ plat ; bénéficiaire absent / contradictoire ; anonymisé (aucune donnée personnelle) ; plusieurs bénéficiaires ; montant ou devise manquants ; journal source manquant ; levée sans paiement ; clôture sans preuve (3 statuts × 2 types) ; décision sans règlement ; rejeu idempotent ; erreur de lecture (listes non fournies) ; permissions.
- **Mutations : 15/15 tuées**, fichiers restaurés (`diff` identique) : types non reconnus ; `cleared` ignoré ou classé « conservé » ; montant / devise / journal non vérifiés ; clôture non prouvée acceptée ; contradiction ignorée ; bénéficiaire par défaut ; `completed` accepté ; levée écrivant `cleared` ou sans trace ; champs plats multiples ; écrivains sans champ plat (refus et annulation).
- **Émulateur `demo-l46-emu`** (port 28080, arrêté ensuite) : `orderActionsL4` 4/4, `accountClosureExceptions` 5/5 (le signalement est écrit par la vraie transaction ; une première exécution avait atteint mon délai de 150 s, rejouée avec un délai suffisant). Ports 5001, 8080, 9099, 9199, 4000 intacts. Pas de nouveau test de concurrence : aucun chemin transactionnel de garde modifié.
- **Suite pure complète : 2875 tests, 2697 réussis, 0 échec, 178 ignorés** (référence L4.5.1 : 2858 / 2680 / 0 / 178).

## 7. C2

Chemin de quarantaine (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js`) **non modifié** ⇒ L0-F non rejoué. C2 reste intermittent (17/20 sur émulateur) et **n'est pas déclaré corrigé**.

## 8. Risques résiduels

1. **Signalements historiques sans champ plat** : l'inspecteur (requêtes par champ plat) ne peut pas les retrouver ; aucun n'existe puisque L4 n'est pas déployée. Si un tel signalement apparaît, un rattrapage ciblé serait nécessaire (non fait : pas de migration).
2. Le signalement **ne retient pas** la somme (tracing seul) : tant que le règlement différé n'existe pas, la dette est visible et bloquante mais pas exécutable ; la clôture est volontairement impossible.
3. Identifiant de signalement déterministe (`<commande>_beneficiary_closed`, point 3 de M-3) : un second événement sur la même commande n'écrirait pas de nouveau signalement ; non traité ici (aucune clôture ne peut survenir, donc rien n'est écrasé aujourd'hui).
4. Un seul bénéficiaire par champ plat ; les cas à plusieurs bénéficiaires du même rôle ne portent pas de champ plat (lecture imbriquée seulement, non retrouvable par l'inspecteur).
5. La levée de verrou ne rattache pas le signalement à une nouvelle tentative réussie : un signalement `open` dont l'opération a ensuite abouti reste bloquant jusqu'à une clôture, impossible aujourd'hui. À régler avec le règlement différé (preuve vérifiable `isPaid` + journal, niveaux N1/N2 de M-3).
6. Preuves sur faux Firestore et émulateur uniquement ; rien en production.

## 9. Décisions encore nécessaires

(a) Faut-il un rattrapage des signalements sans champ plat en cas d'apparition ? (b) Création du registre de décisions / preuves et du module de clôture (mission séparée, N2 = deux super-admins distincts) pour fermer les signalements sur preuve vérifiable. (c) Politique d'identifiant de signalement pour les événements répétés sur une même commande (M-3 point 3).

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation.
