# Fiabilité des commandes — préparation avant essais réels (2026-10-30)

**Statut : PRÉPARATION LOCALE ET LECTURE SEULE.** Aucun déploiement, aucun commit, aucun quota ni paramètre modifié, aucune donnée de
production touchée, aucun projet cloud créé. Projet de production : `az-express-b0469`, région `europe-west1`.

## 1. Quota Cloud Run CPU (mesuré, lecture seule)

| Mesure | Valeur | Source |
|---|---|---|
| Quota « Total CPU allocation per project per region » appliqué à `europe-west1` | **20 vCPU (20 000 milli-vCPU)** | `serviceusage` (consumerQuotaMetrics), valeur effective |
| Σ(cpu × maxInstances) des 95 fonctions déployées | 166,5 (call 119 · event 38 · http 3 · scheduler 6,5) | `firebase functions:list --json` |
| Instances minimales (`minInstances`) | **0 partout** | idem |
| Consommation réelle (instances actives simultanées) | ≈ 4 vCPU en régime courant ; **un pic à 20 instances le 2026-10-29 vers 20:01 UTC** | Cloud Monitoring `container/instance_count` |
| Refus « quota exceeded » dans les journaux | aucun trouvé | Cloud Logging |

Lecture : la somme `Σ(cpu×max)` est un **maximum théorique**, pas la consommation. Le quota se mesure sur les instances **actives en même
temps**. La marge réelle en régime courant est large (≈ 16 vCPU), mais un pic à 20 instances montre que le plafond peut être atteint par une
rafale (planificateur + notifications + appels simultanés). Les deux nouvelles fonctions (0,5 × 1 chacune) ajoutent **au plus 1 vCPU actif**.

Pistes d'optimisation (aucune appliquée) :
1. Toutes les fonctions sont à `cpu: 1` par défaut. Les callables rares (administration, Ekbine dépôts, listes AZ IA) pourraient passer à `cpu: 0.5`
   (à vérifier : Cloud Run impose `concurrency: 1` sous 1 vCPU — évaluer l'effet sur la latence avant tout changement).
2. `maxInstances` : les triggers d'événements (`notify*`, 38 points) peuvent rester bas (≤ 2) ; les fonctions critiques (`acceptOrderCF` 5, paiement,
   wallet, dispatch, AZ IA) ne doivent pas être réduites.
3. Étaler les planificateurs (`autoExpireOrders` chaque minute + autres) pour éviter l'empilement à la même seconde.
4. Demande d'augmentation de quota (console Cloud Run > Quotas) : option à décider par le propriétaire, **non faite**.

Plan de déploiement avec marge : (a) vérifier juste avant que `instance_count` total < 10 (hors pic) ; (b) vague 1 = 2 fonctions neuves (+≤ 1 vCPU actif) ;
(c) vague 2 = fonctions modifiées une à une, hors heures de pointe, en lisant les journaux entre chaque ; (d) à la moindre erreur « total allowable CPU »,
arrêt (rien n'est modifié côté service en échec) et réduction ailleurs, jamais d'insistance.

## 2. Lot minimal de règles Firestore (non déployé)

Fichier : `functions/` n'est pas concerné ; copie de travail hors dépôt (scratchpad) = **règles réellement déployées**
(`docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt`) **+ une seule modification** dans `serverOwnedOrderFieldsUnchanged()` :
`'cancelRequestAfterPickup', 'disputeDecision', 'adminDeliveryConfirmation', 'deliveryClosedBy'` (écriture client/livreur interdite).
`adminReview` était déjà protégé.

Preuve (règles chargées dans l'émulateur à partir d'une copie, le test lit son fichier de règles à côté de lui) :

| Règles | `order-reliability-server-only` (falsification des 4 champs par client et livreur) | Autres tests de règles commandes |
|---|---|---|
| Déployées (actuelles) | **ÉCHEC** : un client/livreur peut forger ces champs | 37 réussis |
| Lot minimal | **RÉUSSI** (client et livreur refusés, y compris combiné à `accepted → picked_up`) | 38 réussis |

Les 5 échecs de `order-rating.rules.test.js` sont **identiques avant/après** : ils testent des règles de notation d'un autre chantier,
absentes du lot minimal. Ce lot n'embarque donc **aucune** autre modification de `firestore.rules` (permissions admin S8, notation, `ai_consents`).
Les sous-admins n'ont aucun droit d'écriture sur `orders` : leurs décisions passent par `adminOrderDisputeCF` (Admin SDK).

Bloc `ai_consents` (présent en HEAD, absent du déployé) : `allow read: isOwner || isAdmin ; allow write: false`. Aucun code Flutter ne le lit
(`grep lib/` : aucun résultat) ; l'écriture reste réservée à `azIaChat`. Sans ce bloc, l'accès est refusé par défaut — **aucun effet fonctionnel**
sur l'application actuelle. Il n'est donc pas indispensable au lot de litiges et reste hors du lot minimal.

Le lot minimal n'est **pas** indispensable au fonctionnement des nouvelles fonctions (Admin SDK) : c'est une protection contre la falsification.

## 3. Test en échec `partnerQrCache.test.js`

- **Assertion** : *Hosting revalidates unversioned paths…* lit `firebase.json` **relativement au dossier courant** (`fs.readFileSync('firebase.json')`).
- **Cause exacte** : `npm test` s'exécute dans `functions/`, où `firebase.json` n'existe pas → `ENOENT`. Aucune assertion sur le contenu n'est atteinte.
- **Reproduction sur copie propre de `7a76f18`** (worktree sans aucune modification) : échec `ENOENT` lancé depuis `functions/` ; **réussite** lancée depuis la racine
  (`node --test functions/test/partnerQrCache.test.js`). Le contenu de `firebase.json` (inchangé depuis HEAD) satisfait bien les assertions.
- **Dans l'arbre de travail**, le test réussit parce qu'un autre chantier a modifié ce test (chemin résolu depuis `__dirname`).
- **Non introduit par ce chantier** : l'arbre isolé de fiabilité n'a modifié ni ce test ni `firebase.json` ; l'échec existe à l'identique à HEAD.
- Correction non appliquée (appartient à l'autre chantier) : remplacer le chemin relatif par `path.join(__dirname,'..','..','firebase.json')`.

## 4. Projet Firebase de test (préparation — rien de créé)

L'infrastructure existe déjà : `test-env/` (README, `verify-isolation.js`, `seed-test-data.js`, `build-test-apk.ps1`, émulateurs, `env/*.example`).
Étapes à votre charge : voir `test-env/README.md` (création du projet, Authentication / Firestore / Storage / Messaging, empreinte SHA-1, secrets factices).

| Sujet | Décision |
|---|---|
| Configuration | `--project <id-test>` obligatoire ; `.firebaserc` par défaut = production **jamais modifié** ; `functions/.env.<id-test>` surcharge avec `DISABLED` |
| Services | Auth (e-mail/mot de passe + numéros de test fictifs), Firestore (même région), Storage, Cloud Messaging, Functions, Scheduler (automatique) |
| Émulateurs | Firestore/Auth/Storage/Functions pour tout sauf : planificateur `autoExpireOrders`, FCM réel, GPS réel (→ projet de test obligatoire) |
| Comptes | 1 client, 2 livreurs, 1 admin super, 1 sous-admin `commandes`, 1 vendeur — mot de passe de test hors dépôt |
| Données fictives | `seed-test-data.js` : soldes client 10 000 / livreurs 1 000 FCFA, zones, produits ; **aucune donnée de production copiée** |
| Règles | celles de l'arbre isolé (`firestore.rules` + index) déployées **dans le projet de test seulement** |
| Fonctions à tester | `adminOrderDisputeCF`, `adminConfirmDeliveryCF`, `cancelOrderCF`, `acceptOrderCF`, `deliverOrderCF`, `dispatchOrderToDriver`, `notifyBroadcastDrivers`, `enforceOrderRateLimit`, `autoExpireOrders` |
| Protections | `verify-isolation.js` (code retour 1 si un id/clef de production apparaît dans `.env`, dart-defines ou google-services), `--confirm-project` du seed, `applicationId` suffixé `.test`, FeexPay/SMS = `DISABLED` |
| Scénarios | `docs/ORDER_RELIABILITY_SAMSUNG_TEST_PROTOCOL.md` |
| Coût (estimation, non mesurée) | Plan Blaze obligatoire pour les fonctions. Volume de test faible : Functions/Firestore/Scheduler restent dans les quotas gratuits ; coûts résiduels attendus = Artifact Registry + Cloud Build (quelques centimes à ~1-2 USD/mois). Recommandé : alerte de budget à 5 USD, suppression du projet après la campagne |

Rien n'est créé ni facturé sans votre autorisation explicite.

## 5. Autres risques traités localement

- `reconciliation_flags` : id dérivé de la décision (`{orderId}_seller_{16}` / `{orderId}_driver_advance_{16}`) → deux décisions successives ne s'écrasent plus,
  le rejeu d'une même décision retombe sur le même document (idempotent). Test dédié.
- Tout mouvement financier de litige reste tracé : `disputeDecision` (parts), `wallet_transactions` séparées (`refund`, `earning`, `reimbursement`), `audit_logs`, `commissions`.
- Commission non tracée : corrigé (voir ORDER_DISPUTES_SPEC §11) — plus aucun crédit sans preuve de prélèvement.

## 6. Écarts entre le code déployé et le local

Voir le rapport de session (comparaison par fonction des sources déployées à `7a76f18` et à l'arbre isolé). Principe : redéployer une fonction
embarque **tout le module source** de HEAD ; la liste exacte des fichiers qui changent par rapport au déployé est dans `drift.json` (scratchpad).
