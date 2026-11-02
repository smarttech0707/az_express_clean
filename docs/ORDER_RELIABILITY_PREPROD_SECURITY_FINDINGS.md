# Fiabilité des commandes — constat règles Firestore, journal financier, scénarios P/X/C

Date : 2026-10-31. Analyse et préparation : aucun correctif déployé, aucun code métier ni règle modifiés. Seul ajout au dépôt : `rules-tests/driver-delivered-direct.rules.test.js` (non branché dans `npm run test:rules`).

## 1. `picked_up → delivered` écrit directement par le livreur — CONFIRMÉ

**Règle concernée** : `firestore.rules`, `match /orders/{orderId}`, `allow update`, branche livreur assigné (`resource.data.driverId == uid()`), alternative :
```
|| (resource.data.status == 'picked_up'
    && resource.data.get('deliveryProofMode', '') != 'qr_v1'
    && request.resource.data.status == 'delivered')
```
Les règles déployées en préproduction sont identiques sur ce point.

**Reproduction (émulateur local uniquement, aucune commande cloud)** : commande wallet payée (`isPaid: true`, budget 500, commission 100 prélevée), statut `picked_up`, livreur assigné `d1` : `update({status:'delivered'})` **réussit** ; clients, wallet livreur (4 900), compteur de livraisons (0) et collection `commissions` restent inchangés. Modifier en même temps `commissionStatus`, `isPaid` ou `budget` est refusé. Fichier : `rules-tests/driver-delivered-direct.rules.test.js` (4 tests, 4 réussis). Les deux premiers documentent l'état actuel, les deux suivants valident la règle cible.

**Conséquences financières** : la commande devient `delivered` sans passer par `deliverOrderCF`. Le crédit du livreur, `commissions`, `config/az_wallet` et le compteur ne sont produits que par `deliverOrderCF`, qui refuse ensuite la commande (statut déjà `delivered`, constaté en S1). Résultat : le client a payé 500, la commission de 100 a été prélevée au livreur, personne n'est crédité, le revenu AZ n'est pas journalisé ; aucun mécanisme automatique ne répare. Pas de création d'argent ni de double crédit : de l'argent est **immobilisé/perdu** (500 + 100) et la comptabilité diverge. Abus : un livreur peut clore sans livrer (sabotage) ; en cas de collusion, aucun gain direct (le crédit exige `deliverOrderCF`). L'application actuelle n'écrit plus `delivered` (`firestore_service.dart` appelle `deliverOrderCF`) : seules de très anciennes versions l'utilisent.

**Faille voisine déjà documentée** : la branche `assigned → accepted` (acceptation sans commission), `rules-tests/driver-accept-closed.rules.test.js` et `docs/DRIVER_ACCEPT_RULE_MIGRATION.md`. Combinée à une livraison par `deliverOrderCF`, elle permet de livrer sans commission prélevée.

**Correctif minimal** : supprimer la branche ci-dessus (la remplacer par rien). Les autres transitions restent : `assigned→accepted` (traitée par le plan de migration existant), `accepted→picked_up`, mises à jour sans changement de statut, administrateur, QR par fonction. Effets de bord : (a) une version de l'app qui écrirait encore `delivered` serait refusée — vérifier l'usage avant déploiement (audit en lecture seule de la production sur les commandes `delivered` sans document `commissions` ; **non fait**, demande une autorisation) ; (b) la règle `orders update` est proche de la limite des 1 000 expressions (le test d'émulateur affiche « maximum of 1000 expressions » sur plusieurs refus) : retirer une branche réduit ce risque.
**Tests de non-régression** : `driver-delivered-direct.rules.test.js` (refus livreur/autre livreur/client ; transitions `picked_up`, même statut, QR, admin conservées) + à ajouter à `package.json` (`test:rules`) et au test `driver-accept-closed.rules.test.js` qui affirme encore `picked1 → delivered` réussi (ligne « transitions légitimes inchangées ») : à mettre à jour au moment du correctif.

## 2. Journal financier de `deliverOrderCF`

**Séquence actuelle** — dans la transaction : crédit livreur (ou partenaire), statut `delivered`, libération du livreur, règlement. **Hors transaction, séquentiel** : `deliveries +1`, `config/az_wallet` (+commission, +1 livraison), `commissions.add` (identifiant aléatoire), journaux `wallet_transactions` (`earning`/`refund`), audit. Un arrêt entre la transaction et ces écritures laisse un journal partiel ; l'appel suivant est refusé (statut `delivered`) donc aucune réparation. En mode administrateur, `order_dispute_decisions/<hash>` fait déjà office de clé d'opération ; pas en mode normal.

**Solution A — tout dans la transaction.** `commissions/<orderId>` en `tx.create` (identifiant déterministe : un second essai échoue au lieu de dupliquer), `wallet_transactions` `earning_<orderId>_<livreur>` / `refund_…` en `tx.create`, `deliveries` fusionné dans l'`update` du livreur, `az_wallet` incrémenté dans la transaction. Garanties : un seul crédit (garde de statut), une seule commission (id déterministe + `commissionStatus`), journal complet ou rien, pas de réparation à écrire pour le futur. Coûts : plafond ≈ 1 écriture/s sur `config/az_wallet` (document chaud) → fragmenter (`az_wallet_shards`) si le volume l'exige ; taille de transaction accrue (largement sous 500 écritures) ; modification du cœur argent → tests unitaires et émulateur obligatoires.

**Solution B — réconciliation idempotente.** Un balayage périodique compare les commandes `delivered` aux enregistrements et complète. Exige quand même des identifiants déterministes, une planification (coût), une fenêtre d'incohérence, un recalcul d'agrégat, et le risque de double comptage si le balayage et l'appel original se croisent. Plus complexe à prouver.

**Recommandation** : **A pour les enregistrements par commande**, avec `az_wallet` dans la transaction tant que le volume reste faible (fragmentation prévue ensuite), **plus** un contrôleur de réconciliation en lecture seule (écrit seulement des constats dans `wallet_reconciliation_findings`, jamais d'argent) pour détecter les écarts historiques et les futurs. Réparation de l'existant : un outil ponctuel, idempotent, à identifiants déterministes (`set` sans fusion si absent), qui reconstruit `commissions` et `az_wallet` à partir des commandes `delivered`, après audit en lecture seule. Pas de B comme mécanisme principal.
Tests à écrire : unitaire (ordre des écritures, échec de `tx.create` ⇒ aucun crédit), concurrence (2 appels), chemins partenaire/cash/transfert/administrateur, commande sans trace de commission (legacy), invariant de conservation sur l'émulateur.

## 3. Scénarios prêts (non exécutés) — scripts : `scratchpad/s2.js P|X|C`

Garde : refuse de tourner sans `S2_AUTHORIZED=1` ; projet imposé `az-express-preprod` ; arrêt à la première assertion fausse ; aucun nouveau compte ; tests par script uniquement (pas d'invocateur public). Montant total de référence : 30 000 fictifs (client1 19 500, driver1 5 400, driverB 5 000, AZ 100).

| | P — livraison après `picked_up` | X — acceptations simultanées | C — crédit insuffisant |
|---|---|---|---|
| Données | 1 commande 500 payée wallet ; driver1 en ligne (GPS frais), driverB hors ligne | 3 manches ; chaque manche : 1 commande ; driver1 et driverB en ligne, GPS frais | 1 commande ; driver1 hors ligne, driverB en ligne |
| Soldes initiaux | c 19 500, d1 5 400, dB 5 000, AZ 100 | selon l'état courant (après P : c 19 000, d1 5 800, AZ 200) | idem |
| Statuts | pending → assigned → accepted → picked_up (écriture livreur, règles) → delivered | pending → broadcast (2 notifiés) → accepted (1 seul) → delivered (gagnant) | pending → assigned (driverB) → reste assigned |
| Écritures attendues | accept : d1 5 300, commission 100 tracée ; delivery : d1 5 800, `earning 500`, 1 doc `commissions` (100, `traced`, gain 400), `az_wallet` 200 / 2 livraisons ; client 19 000 | par manche : 1 gagnant, 1 seule `commission`, perdant sans écriture, client −500, gagnant +400, AZ +100 | fixture déclarée : wallet driverB 5 000 → 50 après dispatch (restauré à la fin) ; `CREDIT_INSUFFISANT:50:100` ; aucun débit, statut `assigned`, 500 restent immobilisés (annulation = `cancelOrderCF` non déployée) |
| Anti-doublon | rejeu de `deliverOrderCF` refusé ; soldes stables ; conservation 30 000 | deux requêtes lancées dans le même tick ; exactement un succès ; total constant par manche | aucune commission ; aucune écriture livreur |
| Arrêt | toute assertion fausse ; dispatch ≠ `assigned` ; erreur 5xx ; écriture `picked_up` refusée | dispatch ≠ `broadcast` ; 0 ou 2 gagnants ; commission ≠ 1 | dispatch ≠ `assigned` ; message ≠ `CREDIT_INSUFFISANT:50:100` ; solde modifié |
Hors périmètre volontaire : le test d'écriture directe `delivered` n'est **pas** exécuté sur la préproduction (émulateur seulement). Ordre : P → X → C. Coût estimé : quelques centimes.
