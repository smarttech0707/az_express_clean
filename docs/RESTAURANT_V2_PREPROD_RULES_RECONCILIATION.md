# Réconciliation des règles Firestore — préproduction (Mission 7E-17, 2026-11-05)

Ruleset publié en préproduction : `5236f3d7-5c4f-4dce-82d6-c22eee79e269` (2026-11-01), copie exacte dans
`test-env/runtime/backup-preprod-20261105/firestore.rules.deployed` (dossier ignoré par Git).

Le ruleset publié ne correspond à aucun commit : base plus ancienne + fermeture de deux transitions d'argent.

| Sujet | Publié (préprod) | Local avant 7E-17 | Retenu |
|---|---|---|---|
| `assigned → accepted` écrit par le livreur | interdit | autorisé | **interdit** (acceptOrderCF) |
| `picked_up → delivered` écrit par le livreur | interdit | autorisé | **interdit** (deliverOrderCF) |
| `deliveryPhoto`, `driverAcceptanceSelfie` | non protégés | protégés (7E-11-T) | protégés |
| `cashPayment` | non verrouillé | verrouillé (7E-2-S) | verrouillé |
| Champs v2 (montants, préparation, annulation) | non verrouillés | verrouillés (7B-3B-S) | verrouillés |
| Création legacy d'un partenaire pilote | libre | bloquée (`legacyPartnerCreationBlocked`) | bloquée |
| Notes `rating`/`sellerRating` | libres | posées une fois, 1..5 | posées une fois |
| Champs financiers E-Kbine | partiels | `ekFinancialUnchanged` | complet |
| `admins` : champs OTP, clés de permissions | OTP écrivables, clés libres | retirés, liste officielle | liste officielle |
| Sous-admin `sellers` | création/suppression libres | super-admin ; fiche limitée à 6 champs | local |
| `wallet_transactions` client/vendeur | champs `provider`/`txId` permis | forme stricte, montant borné | local |
| `config/*` lecture | publique | liste d'autorisation | local |

Contrainte production : les anciennes versions de l'application livreur utilisent les deux écritures directes
(`docs/DRIVER_ACCEPT_RULE_MIGRATION.md`). Publier ce fichier en production exige leur retrait préalable.
