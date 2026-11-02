# Préproduction — analyse des appels callable et plan des prochains scénarios

Date : 2026-10-31. Analyse seulement : aucun changement IAM, aucun déploiement, aucune écriture, aucun code métier modifié. Sources : code de l'arbre isolé (`%TEMP%\az_isolated_reliability`), `firestore.rules`, résultats S1.

## 1. Accès aux callable depuis l'APK

### 1.1 Constat
- `dispatchordertodriver`, `acceptordercf`, `deliverordercf` (Cloud Run, europe-west1) : politique IAM **vide** — aucun `allUsers`. Ingress `all`. Pas d'organisation GCP sur le projet (donc aucune contrainte d'organisation n'empêche `allUsers`).
- Une requête sans identité Google reçoit **401 de Cloud Run** avant d'atteindre le code. Un jeton Firebase ne suffit pas : ce n'est pas un jeton IAM Google. L'APK ne peut donc pas appeler ces fonctions aujourd'hui.
- Cause probable (non prouvée) : l'invocateur public n'est posé par le CLI qu'à la création du service ; le premier déploiement a été partiel. En production ces fonctions sont publiques (comportement par défaut du CLI pour une `onCall`).
- `syncDriverOrderLifecycle` est un déclencheur Firestore : jamais à rendre public.

### 1.2 Contrôles dans le code (indépendants de l'IAM)
| Fonction | Authentification | Autorisation métier | Anonymes | Autre utilisateur |
|---|---|---|---|---|
| `dispatchOrderToDriver` | `request.auth` requis (anonyme **non** rejeté explicitement) | `order.clientId == uid`, sinon permission admin « commandes » | un anonyme ne peut pas posséder de commande (la création exige un vrai compte) → refusé | refusé (`permission-denied`) |
| `acceptOrderCF` | `request.auth.uid` requis, anonyme **rejeté** | doc `livreurs/<uid>` existant, en ligne, non suspendu, sans course active, commande `assigned`/`broadcast` proposée à lui, selfie existant dans Storage, crédit ≥ commission | rejeté | refusé (« Compte livreur introuvable », « ne vous est pas assignée ») — constaté en S1 |
| `deliverOrderCF` | `request.auth` requis | `order.driverId == uid`, statut `accepted`/`picked_up`, montants relus depuis la commande | un anonyme ne peut pas être `driverId` | refusé — constaté en S1 |
Toutes ont une limite de débit par utilisateur (20/60 s, 20/60 s, 30/60 s). Aucune ne fait confiance à un montant fourni par le client.

### 1.3 App Check
**Absent** : aucune option `enforceAppCheck`/`consumeAppCheckToken` dans le code ; les journaux indiquent `app: MISSING` et la requête passe. Conséquence : tout client possédant un jeton Firebase valide (par exemple un script) peut appeler les fonctions — c'est ainsi que S1 a été exécuté. Les contrôles métier ci-dessus sont donc la vraie défense.

### 1.4 Conséquences exactes de `allUsers` → `roles/run.invoker` (sur les 3 services)
- Ce que cela ouvre : la **joignabilité réseau** du point d'entrée HTTPS. Toute requête sans jeton Firebase valide est rejetée **par le code de la fonction** (`unauthenticated`), après démarrage éventuel d'une instance.
- Ce que cela n'ouvre pas : aucune donnée, aucun solde, aucun droit métier — les contrôles de 1.2 restent identiques. C'est le modèle de la production.
- Risques : (a) requêtes anonymes en masse facturées (invocations + CPU) — plafonné par `maxInstances` 3/5/3 et par l'alerte 5 USD (alerte seulement, **pas** de coupure automatique) ; (b) bruit dans les journaux ; (c) absence d'App Check (1.3).
- Réversible instantanément (`remove-iam-policy-binding`).

### 1.5 Options
| Option | Permission | Verdict |
|---|---|---|
| A. `allUsers` invocateur sur les 3 services seulement | `roles/run.invoker` pour `allUsers`, par service (le propriétaire a `run.services.setIamPolicy`) | **Recommandée** : identique à la production, test fidèle de l'APK |
| B. Rester privé, invocateur = compte précis | `roles/run.invoker` à un compte | inutilisable par l'APK (il faudrait embarquer une clé de compte de service) — à rejeter |
| C. Rester privé, tests par script uniquement | aucune | valable pour la logique financière (déjà fait), **ne teste pas l'APK** |
| D. App Check (Play Integrity) | enregistrement de l'app + `enforceAppCheck` dans le code + redéploiement | durcissement à planifier avant la production ; hors périmètre préprod |

### 1.6 Recommandation précise
Option A **au moment** des tests APK (pas avant) : trois commandes `gcloud run services add-iam-policy-binding <service> --member=allUsers --role=roles/run.invoker --region europe-west1 --project az-express-preprod` (`dispatchordertodriver`, `acceptordercf`, `deliverordercf`), puis vérification : sans jeton → 401 `UNAUTHENTICATED` rendu par la fonction ; avec jeton client → réponse métier. Retrait des liaisons à la fin des tests APK. Rien d'autre : pas sur `syncdriverorderlifecycle`, pas sur d'autres services. Prérequis hors callable : l'application appelle aussi `checkClientPhone` et `logAuthEvent` à la connexion (`client_auth_page.dart`, `admin_*`) — **non déployées** : la connexion APK échouera ou sera dégradée tant qu'on n'a pas décidé de les déployer ; à examiner séparément. L'APK utilise bien `europe-west1`.

## 2. Scénarios suivants

Comptes existants : `client1` (19 500), `driver1` (5 400). Un seul compte nouveau est nécessaire pour l'ensemble : `driverB` (livreur) — à autoriser. Chaque scénario utilise une **nouvelle commande de 500** (le client avance 500, restitués selon le cas). Contrôle commun : conservation = Σ wallets + commandes payées non terminales + commissions « en transit » + `az_wallet.totalCommissions`.

| # | Scénario | Comptes | Données | Fonctions | Soldes initiaux | Résultat financier attendu | Risques | À déployer |
|---|---|---|---|---|---|---|---|---|
| P | Livraison après `picked_up` | client1, driver1 | nouvelle commande, livreur en ligne, GPS frais | dispatch, accept, deliver (déjà là) ; `picked_up` = écriture client règles | c1 19 500, d1 5 400 | c1 19 000 ; d1 +500 −100 = 5 800 ; AZ +100 ; 1 commission, 1 `earning` | la règle permet aussi `picked_up→delivered` en écriture directe : à tester en négatif (le livreur se priverait de son crédit) | rien |
| A | Annulation avant récupération + remboursement client + libération livreur | client1, driver1 | commande acceptée (`accepted`), non récupérée | `cancelOrderCF` + sync | c1 19 000 (après P), 18 500 après création ; d1 5 800, 5 700 après acceptation | c1 revient à 19 000 (+500 remboursés) ; d1 revient à 5 800 (+100 commission rendue, `commissionStatus refunded`) ; `isOnDelivery false` ; AZ 0 ; 2ᵉ annulation refusée (`ORDER_NOT_CANCELLABLE`), 5 en parallèle → un seul remboursement | `cancelOrderPostTx` hors transaction ; sync sans réessai (préprod) | `cancelOrderCF` |
| A2 | Annulation après `picked_up` | idem | commande `picked_up` | `cancelOrderCF` | idem | refus + demande enregistrée (`cancelRequestAfterPickup`), aucun mouvement d'argent | — | `cancelOrderCF` |
| C | Crédit insuffisant | client1, driverB | commande `assigned` à driverB ; **fixture** : wallet driverB mis à 50 par l'Admin *avant* l'acceptation (le dispatch exclut les livreurs sous la commission) | accept | driverB 50 | `CREDIT_INSUFFISANT:50:100`, aucun débit, commande reste `assigned` | fixture = valeur posée par l'admin ; commande à annuler/expirer ensuite | rien |
| X | Deux acceptations réellement simultanées | client1, driver1, driverB | commande `broadcast` (2 livreurs éligibles, même ville, GPS frais) ; deux jetons lancés dans la même milliseconde, répété sur 3 commandes | accept | d1 ≥ 100, dB 5 000 | exactement un succès, l'autre `failed-precondition`/`permission-denied` ; une seule commission 100 ; perdant intact | dispatch peut choisir `assigned` si un seul éligible | rien |
| E | Expiration automatique | client1 | commande `pending`, aucun livreur éligible (driver1/B hors ligne ou GPS périmé), attendre > 10 min | `autoExpireOrders` (planifiée, 1/min) | c1 | `cancelled` / `no_driver_found`, client +500, `dispatch_metrics`, audit ; aucune commission ; sans exécution double | planificateur facturé (Cloud Scheduler + 1 440 exéc./jour) ; `retryPendingDispatch` peut attribuer la commande avant l'expiration si un livreur redevient éligible | `autoExpireOrders` (+ job Scheduler) |

Ordre recommandé : P → A/A2 → X → C → E (E en dernier car il faut déployer un planificateur permanent, qu'on met en pause/supprime après). Livrables par scénario : script de test avec assertions (comme S1), même contrôle de projet. Aucun scénario ne nécessite `enforceOrderRateLimit` ni les notifications.

## 3. Sécurité financière

1. **Fonds entre paiement et livraison** : le débit client (création) n'a pas de grand livre ni de séquestre dédié ; l'argent « en transit » n'existe que comme `orders` payées non terminales (`budget + shoppingBudget`). De plus, la commission prélevée à l'acceptation (100) n'est dans aucun portefeuille ni dans `az_wallet` avant la livraison : elle n'est tracée que sur la commande (`commission*`) et le journal du livreur. Une commande bloquée garde donc ces deux montants hors de tout total. Conservation vérifiable seulement par balayage des commandes. (Constaté en S1 : 24 500 + 500 + … = 25 000 à chaque étape.)
2. **Interruption après la transaction de livraison** : crédit livreur, statut et libération sont dans la transaction ; mais `deliveries`, `config/az_wallet`, le document `commissions` (id aléatoire, `.add`) et l'écriture `earning` sont faits **après**. Un arrêt entre les deux laisse le livreur crédité sans journal ni revenu AZ ; un nouvel appel est refusé (statut déjà `delivered`) donc **rien ne répare** et aucun réconciliateur n'existe (`scanStuckOrders` ne regarde que les commandes non terminales). Jamais de double crédit ; sous-comptabilisation possible. Le mode replay par clé d'opération n'existe que pour la confirmation administrative. Correction à envisager (plus tard, avec autorisation) : écrire commission/`earning` avec des identifiants déterministes dans la transaction ou via une intention + réparation idempotente.
3. **Double remboursement** : `expireOrderTx` ne rembourse que depuis `pending/broadcast/assigned` et passe à `cancelled` dans la même transaction ; `cancelOrderTx` refuse `delivered/cancelled`, marque la commission `refunded` dans la transaction ; le rate-limit et les décisions admin (`requestId`) suivent le même schéma. Les transactions Firestore sérialisent les chemins concurrents sur le document commande. Risque résiduel : post-traitements hors transaction (`settleTerminalOrder`, `cancelOrderPostTx`).
4. **Double crédit** : `deliverOrderCF` exige le bon livreur et le statut `accepted/picked_up` dans la transaction, relit le montant sur la commande ; confirmé en S1 (4 appels de livraison après coup : refusés, solde stable). Vigilance : la règle autorise un livreur à passer `picked_up→delivered` en écriture directe (hors QR) — sans crédit, mais à tester ; et le crédit de commission non journalisé du point 2.
5. **Commandes bloquées** : (a) `accepted`/`picked_up` sans livreur actif : aucune expiration, alertes seulement → fonds et commission immobilisés jusqu'à décision admin ; (b) tant que `autoExpireOrders` n'est pas déployée en préprod, toute commande `pending` reste payée indéfiniment ; (c) livreur laissé `isOnDelivery` si `syncDriverOrderLifecycle` échoue (sans réessai en préprod) ; (d) commandes avec avance d'achat non libérées automatiquement ; (e) l'arrêt du point 2.

## 4. À décider
1. Autoriser l'option A (ou l'option C) pour les callable ? 2. Autoriser le compte `driverB` ? 3. Autoriser le déploiement de `cancelOrderCF` puis de `autoExpireOrders` (liste blanche du script à étendre) ? 4. Déployer `checkClientPhone`/`logAuthEvent` pour la connexion APK ? 5. Planifier les corrections du point 3.2 et App Check avant la production.
