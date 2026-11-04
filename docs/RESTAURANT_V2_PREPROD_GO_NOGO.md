# Pilote Restaurant v2 — checklist GO / NO-GO de préproduction (Mission 7E-4)

Document de décision, **rien n'est exécuté**. Production : `az-express-b0469` — **interdite** pour tout essai. Complète `docs/RESTAURANT_V2_PREPROD_PROCEDURE.md` (déroulé) ; ici : critères d'arrêt.

Légende : GO = prêt localement · À VÉRIFIER = ne se prouve qu'en préproduction · NO-GO = bloque tant que non levé.

## Politique provisoire — non-paiement confirmé (décision du 2026-11-04)

- AZ Express assume le risque financier du pilote, **sous réserve de validation du super-admin**.
- Aucune compensation automatique, aucune pénalité automatique, aucun débit wallet supplémentaire. Le moteur financier n'est pas modifié.
- Chaque incident (commande, livreur, restaurant, montant, motif, décision d'examen) et toute indemnisation sont **documentés** : l'incident reste visible dans « Incidents paiement cash » jusqu'à son examen ; la décision et le montant retenu sont consignés dans `audit_logs` et dans un registre tenu par le super-admin.

## Checklist

| # | Contrôle | Statut | Critère de passage |
|---|---|---|---|
| 1 | Identité du projet Firebase | **NO-GO** tant que non confirmé | Projet cible = `az-express-preprod` (n° 306761725053, app Android `1:306761725053:android:51262de719c16f85fd2d14`, d'après `test-env/dart-defines.test.json`). Existence **non confirmée** aujourd'hui (voir étapes console ci-dessous). Jamais `az-express-b0469`. `.firebaserc` n'est pas modifié ; toute commande porte `--project az-express-preprod`. |
| 2 | Quotas Cloud Run | **À VÉRIFIER** | Σ(cpu × maxInstances) du projet **plus** +3 CPU pour les 3 fonctions v2 (`quotePartnerOrderCF`, `createPartnerOrderFromQuoteCF`, `partnerOrderActionCF` : 0,5 × 2 chacune) ≤ quota régional `europe-west1`. |
| 3 | Variables d'environnement | **À VÉRIFIER** | `PARTNER_ORDERS_V2` **absent** à l'installation (création fermée). `=on` seulement au moment d'ouvrir. `PARTNER_ORDERS_V2_MANAGE` absent ou `on`. `FEEXPAY_SHOP_ID=DISABLED`, SMS coupés (`DELIVERY_SMS_ENABLED=false`, `DELIVERY_SMS_PROVIDER=none`). `DELIVERY_PROOF_PEPPER` défini si `DELIVERY_PROOFS_ENABLED=true`. Valeurs jamais de production, secrets jamais committés. |
| 4 | Index Firestore | **À VÉRIFIER** | `orders(amountsVersion, status, partnerAcceptedAtMs)` et les 12 autres index `orders` à l'état READY. Aucun index nouveau pour 7E-2/7E-4. |
| 5 | Règles Firestore | **GO** local / **À VÉRIFIER** réel | 454/454 à l'émulateur. En réel : règle `orders` update proche de 1000 expressions (refus par plafond = échec fermé) ; tester accepter livreur, annuler client, noter, actions partenaire, écritures admin. |
| 6 | Fonctions à déployer | **À VÉRIFIER** | Déploiement complet d'un seul arbre cohérent (pas l'arbre isolé du 10-31, qui n'avait que 4 fonctions). `europe-west1`. Nécessaires : `quotePartnerOrderCF`, `createPartnerOrderFromQuoteCF`, `partnerOrderActionCF`, `deliverOrderCF`, `cancelOrderCF`, `payOrderFromWalletCF`, `acceptOrderCF`, dispatch associé. Aucune nouvelle fonction. |
| 7 | Versions compatibles | **À VÉRIFIER** | Restaurateur, client, livreur : build ≥ 11 (1.0.10+11 non encore publiée ; les `.aab` locaux 1.0.6→1.0.9 n'ont pas les écrans v2). Contrôle de version minimale disponible pour `driver`, `restaurant`, `client` dans `config/app_versions` — **désactivé par défaut** (voir ci-dessous). iOS cible 13.0. |
| 8 | Tests cash | **À VÉRIFIER** | Cash `isPaid:false`, aucune écriture wallet ; livraison payée → reversement déclaré/confirmé ; contestation → décision ; livraison non payée → incident visible, examiné, montants inchangés. |
| 9 | Tests wallet | **À VÉRIFIER** | Un seul débit client, `productAmount` → restaurant, `deliveryFee` → livreur ; double appui sans double débit ; annulation/remboursement/litige v2. Recharge de test sans FeexPay réel. |
| 10 | Fermeture d'urgence | **GO** local | Outil « Pilote restaurants v2 » : Fermer la création (immédiat) ; gel d'urgence ; ultime recours `PARTNER_ORDERS_V2=off` + redéploiement des fonctions. À essayer en préproduction avant toute ouverture. |
| 11 | Retour arrière | **GO** (procédure) | Création fermée, pilote vidé, gel levé après analyse ; règles/fonctions précédentes redéployables depuis le commit antérieur (pas d'outil). Aucune commande n'est supprimée à la main. |
| 12 | Politique non-paiement | **GO** | Voir ci-dessus. |

## Version minimale — restaurateur et client

- Document `config/app_versions` (lisible de tous, écriture admin, règles inchangées) : `{ restaurant: {minBuild, enforce, message}, client: {...}, driver: {...} }`.
- **Sans entrée pour le rôle : aucun effet.** Avec `minBuild` seul : simple rappel (« Plus tard »). **Blocage uniquement avec `enforce: true`.**
- Build inconnu (0) ou lecture impossible : jamais de blocage. Les versions déjà installées sans ce contrôle l'ignorent (elles ne lisent pas le document).
- Pour le pilote : écrire `restaurant.minBuild = 11` **sans** `enforce` d'abord ; n'activer `enforce` qu'après vérification que l'app du restaurant pilote est à jour. L'écriture se fait par la console/admin, pas par l'application.

## Confirmer l'existence du projet — Firebase Console (à faire par toi)

1. Ouvrir <https://console.firebase.google.com> avec le compte propriétaire et regarder la liste des projets : chercher **az-express-preprod** (n° 306761725053).
2. S'il est listé : Paramètres du projet → Général : vérifier l'ID `az-express-preprod` et le numéro de projet 306761725053.
3. Vérifier la facturation (plan Blaze) : Utilisation et facturation. Sans Blaze, pas de Cloud Functions.
4. Authentication : initialisée ? (le 10-31 elle ne l'était pas : `CONFIGURATION_NOT_FOUND`.)
5. Firestore : base créée, région cohérente. Functions : lister ce qui est déployé (le 10-31 : 4 fonctions de l'arbre isolé).
6. Console GCP → Cloud Run → Quotas (`europe-west1`, CPU) : noter quota et usage.
7. Si le projet n'apparaît pas : il n'existe pas (ou autre compte) → décision de création à prendre séparément ; ne rien faire sur `az-express-b0469`.

## Risques restants

- Existence, facturation et état du projet de préproduction inconnus.
- Plafond de 1000 expressions de la règle `orders` : comportement réel à observer.
- Application du restaurateur pilote à publier et à installer ; versions antérieures non bloquées sans configuration explicite.
- Le registre des incidents/indemnisations est manuel (hors application).
- Aucune de ces vérifications n'a été exécutée sur Firebase réel.
