# Protocole de test Samsung — fiabilité des commandes (2026-10-30)

**Statut : PRÉPARÉ, NON EXÉCUTÉ.** Aucun test sur appareil n'a été fait. Aucun paiement réel, aucun remboursement réel,
aucune donnée de production. Appareil : Samsung Galaxy A11 (`R9PN9018DDJ`, voir `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md`).
Un second appareil (ou un second compte sur l'émulateur Android) est nécessaire pour jouer le client ET le livreur.

## 0. Règles d'or

1. **Jamais le projet de production** (`az-express-b0469`). Toute commande `firebase` porte `--project <id-test>` ; `test-env/verify-isolation.js` doit renvoyer 0 avant de commencer.
2. Comptes fictifs uniquement (`test-env/seed-test-data.js` : 1 client, 2 livreurs, 1 admin, 1 vendeur, soldes fictifs). Mot de passe de test hors du dépôt.
3. Paiement : **wallet fictif ou cash**. Aucun FeexPay réel (`FEEXPAY_*` = `DISABLED` dans le projet de test). Aucun SMS réel.
4. Fonctions déployées dans le projet de test = **l'arbre isolé** (`az_isolated_reliability`), pas l'arbre de travail mélangé.
5. Arrêt immédiat si un identifiant de production apparaît dans un écran, un journal ou une URL.

## 1. Deux environnements, deux niveaux de preuve

| Élément à prouver | Émulateurs locaux (`test-env/emulators-start.ps1`) | Projet Firebase de test (à créer par vous) |
|---|---|---|
| Création, dispatch (callable), acceptation, annulation, refus après récupération, remboursements, wallets | **Oui** | Oui |
| Reprise automatique du dispatch, expiration à 10 min (scheduler `autoExpireOrders` chaque minute) | Non (pas de scheduler) — on appelle la logique par test unitaire/émulateur, déjà couverte | **Oui, obligatoire** |
| Notifications push (FCM) | Non (pas de FCM réel) | **Oui, obligatoire** |
| Suivi GPS en tâche de fond, application fermée | Position simulée seulement | **Oui, obligatoire** |

Conclusion : les tests de reprise du dispatch, d'expiration, de notifications et de GPS réel exigent un projet de test dédié
(étapes 1 à 8 de `test-env/README.md`, à votre charge). Sans lui, ils ne peuvent PAS être déclarés faits.

## 2. Préparation (une fois)

1. Projet de test créé, secrets factices posés, `verify-isolation.js` = 0.
2. Déployer **dans le projet de test seulement** : `firebase deploy --project <id-test> --only firestore:rules,firestore:indexes,functions` depuis l'arbre isolé.
3. `seed-test-data.js` ; vérifier les soldes de départ (seed) : client 20 000 FCFA, livreur A 5 000 FCFA, livreur B 5 000 FCFA.
4. Installer l'APK de test (`build-test-apk.ps1` / `install-test-apk.ps1`, `applicationId` suffixé `.test`) ; production non remplacée.
5. Ouvrir la console Firestore du projet de test : surveiller `orders`, `order_dispatch_retries`, `audit_logs`, `stuck_order_alerts`, wallets.
6. Autorisations Android : localisation « toujours », notifications, optimisation batterie désactivée pour l'app (Samsung met les apps en veille).

Relevé de départ à noter pour chaque scénario : soldes client / livreur A / livreur B, heure, `orderId`.

## 3. Scénarios

Légende : C = client (téléphone 1), L1/L2 = livreurs (téléphone 2 ou second compte).

### S1 — Création d'une commande
1. C crée une livraison wallet (frais 500 FCFA) dans la zone de test.
2. **Attendu** : `orders/<id>` `status` `pending` → `assigned` (1 livreur éligible) ou `broadcast` (≥ 2) ; client débité de 500 une seule fois ; `orderRateLimit`/`audit_logs` cohérents ; aucune commission encore prélevée.
3. Preuve : captures de la commande et du solde client.

### S2 — Fermeture de l'application, reprise du dispatch
1. Tous les livreurs **hors ligne** ou hors rayon ; C crée une commande puis **ferme l'application** (balayage + arrêt forcé).
2. Mettre L1 en ligne (position dans 2 km) **après** 40 s.
3. **Attendu** : au passage du scheduler suivant (≈ 60-90 s après création, paliers minimaux 30/90/150/300/480 s ; rayons 2/5/30/30/30 km) la commande passe `assigned`/`broadcast` et L1 reçoit la notification, sans aucune action de C. `order_dispatch_retries/<id>` montre ≤ 5 tentatives, écart ≥ 45 s.
4. Noter l'heure exacte de chaque tentative (preuve que la cadence réelle est celle du scheduler, pas « à 30 s »).
5. Variante : L1 hors rayon initial mais dans 5 km → la commande n'est prise qu'à partir du palier 5 km.

### S3 — Acceptation par un livreur, premier arrivé
1. Commande en `broadcast` notifiant L1 et L2.
2. L1 et L2 touchent « Accepter » **en même temps** (compte à rebours à deux).
3. **Attendu** : un seul accepte (`driverId`), l'autre reçoit un refus clair ; commission prélevée **une seule fois** sur le gagnant (100 FCFA si frais < 1000, sinon 200) ; l'autre livreur sans prélèvement ; pas de double attribution.

### S4 — Annulation avant récupération
1. Après acceptation (statut `accepted`), C annule.
2. **Attendu** : `cancelled` ; client remboursé de **tout** (frais + budget d'achat éventuel) ; commission rendue **au payeur d'origine** ; livreur libéré (`isOnDelivery:false`) ; `audit_logs` présent ; rien en double si C retouche « Annuler ».

### S5 — Refus d'annulation après récupération
1. L1 marque « colis récupéré » (`picked_up`).
2. C tente d'annuler.
3. **Attendu** : message « Le colis a déjà été récupéré… » ; statut inchangé ; **aucun** mouvement de wallet ; `orders.cancelRequestAfterPickup.status = pending_admin_review`.
4. Côté admin (écran Litiges, une fois rattaché) : la demande apparaît ; décider sur ce dossier de test : « Résoudre » (sans argent) ; refaire sur un second dossier : option B ou D et contrôler les soldes (jamais sur des données réelles).

### S6 — Expiration
1. Tous les livreurs hors ligne ; C crée une commande ; ne rien faire 10-11 minutes.
2. **Attendu** : plus aucune reprise après ~9 min ; `cancelled` (raison `no_driver_found`) entre 10 et 11 min ; client remboursé de l'intégralité (frais + budget d'achat) **une seule fois** ; notification d'expiration reçue.

### S7 — Remboursement des courses (contrôle de conservation)
Pour S4, S6 et un litige S5 : `soldeClient + soldeLivreurs` avant/après ; l'écart doit être exactement la commission AZ conservée (ou 0 si rendue). Tout autre écart = anomalie à signaler, arrêt des tests.

### S8 — Notifications
Pour S2, S3, S4, S5, S6 : application au premier plan, en arrière-plan, **fermée**, écran verrouillé. Noter le délai entre l'événement et l'affichage, le son, l'ouverture sur le bon écran. Livreur : une seule notification par commande et par élargissement (pas de doublon aux nouveaux livreurs seulement).

### S9 — Suivi GPS
1. L1 accepte, démarre la course, **verrouille l'écran, change d'application** pendant 5 minutes en se déplaçant.
2. **Attendu** : la position de L1 avance côté C ; trace sans trou > 1 min ; un livreur dont la position date de > 3 min n'est plus proposé aux nouvelles commandes.
3. Couper la localisation 4 minutes puis la rétablir : l'app l'indique, la position reprend ; relever la consommation batterie sur 30 min.

### S10 — Alertes de commandes bloquées
Laisser une commande `accepted` > 30 min puis `picked_up` > 90 min dans le projet de test : alerte unique (pas de répétition) reçue par un admin porteur de `commandes`, visible dans « Commandes bloquées » ; **aucune annulation ni remboursement automatique**.

### S11 — Livraison terminée (wallet puis cash)
1. Commande wallet (frais 500 + achat 3 000, **commande de test**) : L1 accepte, récupère, livre (`deliverOrderCF`).
2. **Attendu** : `delivered` ; livreur crédité de frais + achat (3 500) **une seule fois** ; commission 100 prélevée une seule fois à l'acceptation, enregistrée dans `commissions` / `config/az_wallet.totalCommissions` à la livraison ; double appui sur « Livrer » sans effet.
3. Répéter en cash : aucun mouvement de wallet client ; livreur garde l'argent.

### S12 — Litige après récupération (super-admin, commandes de test)
Une commande par option : A, B, C, D, puis « Résoudre sans clôturer ». Pour chacune : relever les soldes avant/après et comparer à `docs/ORDER_DISPUTES_SPEC.md` §11 (frais 500, achat 3 000, commission 100).
Vérifier : sous-admin refusé ; rejeu du même `requestId` sans second mouvement ; commande sans trace de commission : aucune commission rendue + signalement visible.

## 3bis. Couverture des 10 vérifications demandées

| # | Vérification | Scénario |
|---|---|---|
| 1 | Création de commande | S1 |
| 2 | Fermeture de l'application client | S2 |
| 3 | Reprise automatique du dispatch | S2 (scheduler : projet de test obligatoire) |
| 4 | Acceptation par un livreur | S3 |
| 5 | Suivi GPS | S9 |
| 6 | Annulation avant récupération | S4 |
| 7 | Refus d'annulation après récupération | S5 |
| 8 | Livraison terminée | S11 |
| 9 | Remboursement | S4, S6, S7, S12 |
| 10 | Notifications et alertes | S8, S10 |

## 4. Critères de réussite / d'arrêt

- Réussite : tous les « Attendu » vérifiés, S7 sans écart inexpliqué, aucun solde négatif, aucun double crédit.
- Arrêt et rapport : un identifiant de production visible, un solde incohérent, une double commission, un remboursement après `picked_up` sans décision admin.
- Chaque scénario : capture d'écran + extrait Firestore (`orders`, `audit_logs`) + heure. Rien n'est « validé » sans cette preuve.

## 5. Ce qui reste hors périmètre de ce protocole
Paiements FeexPay réels, SMS réels, iPhone (voir `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md`), QR partenaires (paquet isolé).
