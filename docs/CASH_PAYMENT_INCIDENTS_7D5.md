# Paiement cash v2 — états, incidents et politique (Mission 7D-5, locale, non déployée)

## Pourquoi
`orders.isPaid:false` ne prouve rien : « Non payé » déclaré, rien déclaré ou ancienne application donnent le même résultat.
`reportFakeOrder` (écriture client sur `clients/{id}`) échoue toujours pour un livreur (`permission-denied`, règles) : aucun
signalement n'a jamais été enregistré.

## Modèle (`orders.cashPayment`, écrit par le serveur seulement — `functions/cashPayment.js`)
- `status` : `confirmed` (le livreur déclare avoir encaissé — une déclaration, pas une preuve) | `non_payment_declared` | `unknown`.
- `verification` : `not_required` | `pending_review` | `confirmed_unpaid` | `refuted`.
- Conserve : `theoreticalTotal`, `declaredBy`, `declaredAtMs`, `reason`, `review{requestId,decision,byUid,atMs,justification}`, `history[]` (20 max).
- Posé à la livraison (`deliverOrderCF`, v2 cash uniquement) : booléen `markCashPaid` explicite true → `confirmed` ; false → `non_payment_declared` + `pending_review` + `reconciliation_flags/{id}_cash_payment_review` ; autre → `unknown`.
- Le dû (`cashRemittance.amountDue = productAmount`) n'est **jamais** modifié par une déclaration ni par un examen.

## Actions (dans `partnerOrderActionCF`, aucune nouvelle fonction)
- `declareCashNonPayment` {orderId, reason 10–300} : livreur final, commande livrée, cash v2, reversement non clos. Idempotent. Refusé si le livreur a déjà déclaré « payé ». Limite 10/h.
- `reviewCashNonPayment` {orderId, requestId, decision `confirm_unpaid`|`refute`, justification 10–500} : super-admin. Idempotent par `requestId`; une seconde décision différente est refusée.
- Le montant final se décide par `resolveCashRemittance` (inchangé). Aucun wallet n'est touché par ces actions.

## Politique proposée pour le seuil des 3 signalements (non appliquée)
Le compteur historique `fakeOrderCount`/`cashOnDeliveryEnabled` n'est PAS modifié par ce mécanisme. Proposition : compter les incidents
`cashPayment.verification == 'confirmed_unpaid'` par `clientId` (requête, pas de compteur modifiable) et laisser le super-admin décider la
suspension du cash (`admin_cod_page`) à partir de 3 incidents confirmés. Aucun blocage sur une déclaration non vérifiée.

## Décision métier ouverte
Qui supporte la perte quand le non-paiement est confirmé (restaurant, livreur, AZ) ? Le serveur ne tranche pas : l'administrateur arrête
le montant final via `resolveCashRemittance`, le reliquat est tracé (`reconciliation_flags/{id}_cash_shortfall`), jamais débité automatiquement.

## 7D-5-F — transitions, concurrence, compatibilité (vérifié localement)
Transitions de `cashPayment` (toutes dans une transaction sur `orders/{id}`, donc sérialisées) :
- livraison : `markCashPaid===true` → confirmed/not_required ; `false` → non_payment_declared/pending_review ; autre → unknown/not_required.
- `declareCashNonPayment` : unknown (ou absent) → non_payment_declared/pending_review ; déjà non_payment_declared → **rejeu** (même après examen ou clôture du reversement : la décision admin n'est jamais réécrite) ; confirmed → `PAYMENT_ALREADY_DECLARED_PAID`. Un signalement NEUF sur reversement clos (résolu/confirmé) → `CASH_ALREADY_FINAL`.
- `reviewCashNonPayment` : pending_review → confirmed_unpaid | refuted (une fois) ; même requestId → rejeu ; autre requestId → `PAYMENT_ALREADY_REVIEWED`.
- Correction 7D-5-F : le rejeu d'une déclaration après clôture du reversement renvoyait `CASH_ALREADY_FINAL` ; il renvoie désormais un rejeu.
- Course constatée sur émulateur : résolution puis déclaration simultanées → la déclaration est refusée (reversement clos) ; ordre inverse → les deux passent. Les deux issues sont cohérentes.

Compatibilité : Flutter envoie TOUJOURS un booléen `markCashPaid` (défaut `clientPaid=true`, `false` = choix explicite « Non payé ») → les applications actuelles produisent déjà `confirmed` ou `non_payment_declared`. `reportFakeOrder` (écriture sur `clients/{id}`, `fakeOrderCount` protégé par les règles) échoue toujours en `permission-denied` (déjà absorbé par un try/catch) : il n'est PAS fonctionnel ; la migration vers `declareCashNonPayment` demande une mise à jour Flutter.
