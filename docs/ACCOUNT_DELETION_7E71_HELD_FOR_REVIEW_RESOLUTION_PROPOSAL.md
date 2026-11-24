# Mission 7E-71 — `held_for_review` : analyse et proposition d'outil de résolution

Date : 2026-11-06 · **Analyse et proposition seulement.** Aucun code d'outil n'a été écrit, aucun remboursement ni crédit créé, aucune API de paiement appelée. (Le titre de ce document est une hypothèse : la liste des livrables de la mission 7E-71 est tronquée après le 5ᵉ document.)

## 1. Où et quand un paiement est mis en attente

Fichier `functions/feexpayPayments.js`, fonction `processFeexPayWebhookEvent`, **dans la transaction de crédit** (l. 626-695). Le webhook est d'abord authentifié (secret dans l'URL) et le paiement **vérifié côté serveur** auprès de l'opérateur (`createStatusVerifier`) ; seulement si ces contrôles passent, `shouldHoldPayment` est évaluée. Trois motifs (`reviewReason`) :

| Motif | Condition |
|---|---|
| `profile_anonymized` | le profil du compte est `isDeleted` |
| `payment_created_after_quarantine` | la demande de paiement a été créée après la date du tombstone |
| `tombstone_date_unreadable` | un tombstone existe mais sa date est illisible → décision prudente |

Un paiement antérieur à la quarantaine sur un profil intact est **crédité normalement** (un solde non nul bloque ensuite la suppression via `inspect`).

## 2. Ce qui est conservé et écrit

Sur le document **de premier niveau** `wallet_transactions/{txId}` (celui créé par `initiateFeexPayPayment`) : `status: 'held_for_review'`, `needsReview: true`, `reviewReason`, `credited: false`, `heldAt`, `feexpayOperator`, `feexpayRef`, `amountVerified`, `independentlyVerified`, plus les champs d'origine (`userId`, `userType`, `amount`, `paymentMethod`…). **Le solde n'est pas modifié.** Réponse HTTP 200 (pour éviter des rejeux sans issue).

Journaux (après la transaction) : événement de sécurité `webhook_paid_account_in_deletion` (gravité `high`) ; audit `payment_held_account_deletion` (`status: 'held'`, montant). Les deux sont écrits par le serveur uniquement.

## 3. Idempotence et double traitement

- Un rejeu du même webhook : la lecture initiale et la lecture dans la transaction traitent `held_for_review` comme **déjà traité** (comme `completed`) → aucune deuxième écriture, aucun crédit.
- Tests : `feexpayPayments.test.js`, `accountQuarantineGuards.test.js` et la concurrence C1-C3 (émulateur).
- **Risque résiduel** : l'événement de sécurité et l'audit sont écrits *après* la transaction ; un arrêt entre les deux perd la trace secondaire (le statut `held_for_review` reste la source de vérité).

## 4. Moyens de consultation aujourd'hui

| Moyen | État |
|---|---|
| Console Firebase / requête sur `needsReview == true` | **seul moyen** ; aucun écran d'administration, aucune fonction de liste |
| `security_events` / `audit_logs` | lisibles par les administrateurs selon les règles existantes ; non agrégés |
| Client | la règle de lecture de `wallet_transactions` autorise le propriétaire (`userId == uid`) : il voit le document ; l'application classe tout statut inconnu en **`pending`** (`feexpay_transaction.dart`, `_parseStatus`) → affichage « en attente » sans explication (compte déjà suspendu en pratique) |
| Moteur de suppression | `needsReview == true` est lu comme blocage (`financial_regularization_required`) pour les comptes **non encore** anonymisés |

## 5. Absence d'outil de résolution — risques

1. **Aucun chemin sûr** pour rendre l'argent : ni crédit, ni remboursement, ni rejet n'existent côté serveur.
2. **Crédit manuel dans la console** : écrit hors transaction, sans audit, sans garde de double crédit ; sur un profil anonymisé, crédit sans propriétaire.
3. **Remboursement manuel côté opérateur** : aucune trace croisée avec le document ; risque de remboursement **et** de crédit ultérieur (double paiement au client).
4. **Argent immobilisé** : le montant est prélevé chez l'opérateur, retenu dans le document, non rendu.
5. **Écart comptable** : la somme des `held_for_review` doit être rapprochée du relevé opérateur ; aucun état « résolu » n'existe pour clore l'écart.

## 6. Proposition d'outil sécurisé (non développée)

**Nom proposé** : `resolveHeldPayment` (callable, région `europe-west1`, enveloppe `{success, error, message, data, code}`, `checkRateLimit`, `logAudit`), plus `listHeldPayments` en lecture. Hors périmètre de cette mission : aucune ligne n'est écrite.

### 6.1 Accès
Super-administrateurs actifs seulement (comme `manageAccountDeletionCF`) ; **séparation des tâches** : l'administrateur qui propose une résolution ne peut pas la valider (double validation). Aucun accès pour le support ordinaire.

### 6.2 Machine d'états (sur `wallet_transactions/{txId}`, extension additive)
`held_for_review` → `resolution_proposed` → (`credited_after_review` | `rejected_after_review` | `refund_requested` → `refund_confirmed`). Un seul passage possible par état ; toute autre transition est refusée. Champs : `resolution: {kind, proposedBy, proposedAt, approvedBy, approvedAt, justification, operatorRef, idempotencyKey}`.

### 6.3 Contrôles avant toute action financière
1. **Référence de paiement** : `txId` et `feexpayRef` correspondent au document ; revérification serveur auprès de l'opérateur (vérificateur existant) ; refus si le statut n'est plus « payé ».
2. **Montant et devise** : montant entier en FCFA égal au montant demandé et au montant vérifié par l'opérateur ; devise XOF (aucune conversion) ; refus à la moindre différence.
3. **Compte** : pour `credit`, le profil doit exister, ne pas être `isDeleted`, ne pas avoir de tombstone ; sinon seule la voie `refund` ou `reject` est possible.
4. **Idempotence** : clé `txId` + type d'action ; transaction Firestore (lecture avant écriture) qui vérifie `status == 'held_for_review'` ou l'état attendu ; un rejeu renvoie le résultat déjà obtenu sans rien réécrire.
5. **Séparation crédit / remboursement / rejet** : trois actions distinctes, mutuellement exclusives, une seule par paiement.
6. **Confirmation humaine** : l'action n'est exécutée qu'après la validation du second administrateur ; justification obligatoire ; aucune action déclenchée par AZ IA.
7. **Audit** : `audit_logs` (`held_payment_resolution_proposed|approved|executed`), `support_events`, événement de sécurité en cas de refus ; jamais de secret ni de donnée personnelle brute.
8. **Plafond** : un crédit ne dépasse jamais le montant vérifié ; solde jamais négatif.

### 6.4 Ce que l'outil ne ferait pas
Aucun remboursement automatique ; **aucun appel à une API de remboursement** (le remboursement est effectué hors système puis *enregistré* avec la référence opérateur) ; aucune modification du portefeuille sans validation ; aucun effet sur d'autres comptes.

### 6.5 Tests à écrire avec l'outil
Double crédit refusé ; montant différent refusé ; profil anonymisé → crédit refusé ; double validation par le même administrateur refusée ; rejeu idempotent ; concurrence de deux administrateurs ; absence d'effet pour un sous-administrateur ; audit présent.

## 7. Bloque-t-il le déploiement ?

| Étape | Bloquant ? | Raison |
|---|---|---|
| Déploiement en préproduction des fonctions de suppression et de garde | **Non** | FeexPay est `DISABLED` : aucun paiement réel ne peut arriver ; le statut n'est atteignable que par essai simulé, document à nettoyer manuellement |
| Validation en préproduction (scénarios 14-17) | **Non**, avec la limite déclarée | seul le refus sûr et la rétention sont vérifiés ; la résolution n'est pas testable |
| Activation de la suppression en **production**, ou toute ouverture au public avec FeexPay actif | **Oui** | un paiement réel arrivé après la quarantaine serait retenu sans issue pour le client ; aucun outil ne permet de le rendre |

Conclusion : `held_for_review` bloque **l'activation complète**, pas le pilote préproduction.

*Aucun remboursement ni crédit n'a été créé ; aucun développement d'action financière n'a été fait.*
