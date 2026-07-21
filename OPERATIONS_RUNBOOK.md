# AZ Express — Manuel d'exploitation (Abengourou)

**Créé** : 2026-07-09 (Master Prompt 84, « Operations Runbook & Post-Launch Monitoring »).
**Public visé** : l'admin/opérateur qui gère AZ Express au quotidien après le lancement pilote — pas un document technique pour développeurs (voir `CLAUDE.md` pour ça) ni un historique d'audit (voir `AUDIT_FINAL.md`).
**Portée** : documentation/process uniquement — aucun code n'a été modifié pour produire ce document. Chaque procédure ci-dessous s'appuie sur un écran ou un mécanisme **déjà construit et audité** cette session ; là où rien n'existe encore côté outillage, c'est dit explicitement plutôt que de décrire un outil imaginaire.
**Prérequis** : ce manuel suppose le plan d'activation de `AUDIT_FINAL.md` Section 38 exécuté (règles + 53/53 Cloud Functions déployées). Certaines procédures ci-dessous (ex. règlement cash marchand, `deliverOrderCF`) ne fonctionnent qu'une fois le blocage Cloud Build résolu et les Cloud Functions concernées réellement en production.

---

## 1. Journée type admin

### Matin — avant l'ouverture du service

| Vérification | Où | Ce qu'on regarde |
|---|---|---|
| Livreurs disponibles | `drivers_page.dart` (Livreurs) | Combien de comptes ont `isOnline:true` ; si un livreur attendu n'apparaît pas en ligne, contacter par téléphone (le numéro est affiché sur chaque carte livreur) |
| Comptes suspendus | `drivers_page.dart` | Vérifier qu'aucune suspension d'hier n'a été oubliée (badge "SUSPENDU" visible directement sur la carte, Prompt 77) — décider si elle doit être levée avant l'ouverture |
| Demandes livreur/partenaire en attente | `driver_requests_page.dart`, `admin_pharmacie_requests_page.dart`, `admin_restaurant_requests_page.dart`, `admin_seller_requests_page.dart`, `admin_boulangerie_requests_page.dart` | Traiter toute inscription arrivée pendant la nuit — chaque écran a un flux d'approbation déjà fonctionnel |
| Partenaires actifs | `admin_restaurants_page.dart` / `admin_pharmacies_page.dart` / `admin_boulangeries_page.dart` / `admin_boutique_page.dart` | Confirmer qu'au moins les partenaires prévus pour la journée ont `isOpen:true`/`isActive:true` — un restaurant resté fermé de la veille bloque silencieusement toutes ses commandes |
| Commandes en attente depuis la nuit | `admin_orders.dart` | Filtrer sur les statuts non terminaux (`pending`/`assigned`/`accepted`/`picked_up`) — toute commande visible ici depuis plus d'une heure est déjà signalée par une bordure rouge + avertissement "En cours depuis plus d'1h" (Prompt 77) |
| Cash marchand non réglé de la veille | `admin_cash_settlement_page.dart` (Cash à régler) | Si la liste n'est pas vide au matin, c'est un reliquat d'hier soir — à clôturer avant d'ouvrir la nouvelle journée, pas à laisser s'accumuler |
| Tickets support ouverts | `admin_support_page.dart` (onglet Tickets) | Répondre à tout ticket `open` arrivé pendant la nuit — le badge "Réponse du support disponible" côté client ne s'affiche qu'après une vraie réponse admin |
| État technique | Firebase Console (Crashlytics + Cloud Functions Logs) | Voir section 2 — un coup d'œil rapide avant l'ouverture, pas une revue complète |

### Pendant la journée

- **Suivi commandes en direct** : `admin_orders.dart` reste l'écran de référence — les commandes bloquées >1h y sont déjà signalées automatiquement (bordure rouge), pas besoin de les chercher manuellement dans une liste brute.
- **Carte livreurs en temps réel** : `admin_live_tracking_page.dart` — calcule déjà `gpsOk`/`secsSince` par livreur en ligne (position considérée périmée au-delà de 60 secondes sans mise à jour) ; utile pour repérer un livreur dont le téléphone a coupé le GPS ou dont la batterie est morte, avant qu'un client ne s'en plaigne.
- **Incidents** : voir section 3 (procédures par type d'incident).
- **Cash collecté en cours de journée** : `admin_cash_settlement_page.dart` se remplit au fil des livraisons cash de commandes avec un marchand (restaurant/pharmacie) — ce n'est pas une alerte à traiter dans l'instant, mais à garder à l'œil si la liste grossit vite (signe qu'un livreur accumule du cash sans jamais repasser à l'agence).
- **Signalements produits** : `admin_support_page.dart` (onglet Signalements) — à traiter dans la journée, pas nécessairement dans l'instant, sauf signalement grave (contenu illicite, arnaque).

### Soir — clôture de journée

1. **`admin_cash_settlement_page.dart`** doit revenir à zéro avant la clôture — chaque commande cash avec marchand y reste tant que l'admin n'a pas cliqué "Marquer réglé" (déclaratif : confirme que le livreur a bien remis les espèces au marchand, aucun mouvement de wallet). Une commande qui traîne plusieurs jours ici est un signal d'alerte (livreur qui garde le cash, voir section 5).
2. **Commissions du jour** : `admin_commissions_page.dart` / `admin_earnings.dart` — total des commissions perçues (100/200 FCFA par livraison selon le palier configuré dans `config/commission`), déjà prélevées automatiquement à l'acceptation de chaque course.
3. **`admin_boutique_page.dart`** : vérifier qu'aucune commande Boutique cash ne reste bloquée en statut "Cash à confirmer" (`pending_payment`) — bouton "Confirmer l'espèce reçue" à utiliser une fois le paiement réellement encaissé.
4. **Anomalies** : consulter `admin_security_dashboard.dart` (widget "zones/créneaux en échec de recherche de livreur", basé sur `dispatch_metrics.noDriverFoundCount`) — un pic sur une zone/tranche horaire précise indique soit trop peu de livreurs disponibles à ce moment, soit un rayon de dispatch trop court pour cette zone.
5. **Commandes annulées/expirées de la journée** : `admin_orders.dart` filtré sur `cancelled` — vérifier qu'aucune annulation n'a une cause anormale répétée (ex. toujours le même livreur qui annule).

---

## 2. Surveillance technique

Tous les outils ci-dessous vivent dans la **Console Firebase**/**Google Cloud Console** — pas dans l'app AZ Express elle-même. AZ Express n'a pas de tableau de bord technique interne unifié (déjà documenté comme gap non construit, `CLAUDE.md` section BI/Analytics) ; c'est un usage normal des consoles externes, pas un défaut du produit.

| Signal | Où le consulter | Fréquence recommandée | Ce qui est déjà instrumenté côté code |
|---|---|---|---|
| Erreurs Cloud Functions | Firebase Console → Functions → Logs | Quotidien | Chaque fonction financière (`orderActions.js`) journalise déjà les échecs de dispatch de livraison post-paiement dans `audit_logs` (Prompt 58) — consultable aussi depuis Firestore directement (super-admin uniquement, `admin_security_dashboard.dart` n'expose pas encore de recherche dans `audit_logs`, gap documenté) |
| Crashes app mobile | Firebase Console → Crashlytics | Quotidien la première semaine, puis hebdomadaire | Déjà câblé (`FlutterError.onError` + `PlatformDispatcher.instance.onError`, `main.dart`) — capture les crashs Flutter fatals et les erreurs async non interceptées |
| Consommation Firestore (lectures/écritures/coût) | Google Cloud Console → Firestore → Utilisation | Hebdomadaire au pilote, quotidien à grande échelle | Aucune alerte automatique configurée côté code — à surveiller manuellement ; voir section 6 pour les seuils qui rendront ça nécessaire |
| Storage (volume, coût) | Google Cloud Console → Storage → Bucket | Mensuel | Aucun nettoyage automatique des anciens fichiers n'existe (photos remplacées, KYC obsolète — gap déjà documenté, `CLAUDE.md` Prompt 37) — le volume ne fait que croître, à surveiller si le coût devient significatif |
| Auth (comptes créés, échecs) | Firebase Console → Authentication | Hebdomadaire | Pas d'alerte automatique sur un pic de créations de compte suspect (voir section 5) |
| Réconciliation wallet | `wallet_reconciliation_findings` (Firestore, super-admin) | Automatique chaque lundi 4h — juste consulter la collection le lundi matin | `walletReconciliationCheck` compare déjà le champ `wallet` réel de 6 collections (clients/livreurs/sellers/restaurants/pharmacies/boulangeries) à l'historique `wallet_transactions` — n'écrit une entrée que s'il y a un vrai écart |
| Nettoyage tokens FCM invalides | Automatique | Chaque lundi 5h, rien à faire manuellement | `fcmTokenCleanupCheck` |
| Rate limits expirés | Automatique | Chaque lundi 3h, rien à faire manuellement | `cleanupExpiredRateLimits` |
| Commandes jamais assignées | Automatique | Chaque minute, rien à faire manuellement | `autoExpireOrders` — annule et rembourse après 10 min sans livreur trouvé |

### Google Maps — quotas et coûts

- **Où** : Google Cloud Console → APIs & Services → Tableau de bord (filtrer sur Directions API / Places API / Maps SDK / Geocoding API).
- **Déjà maîtrisé côté code** (pas à reconstruire, juste à surveiller que ça reste vrai) : cache mémoire par grille 100 m/TTL 5 min sur `GoogleRoutesService`, throttle de recalcul d'itinéraire à 120 s pendant une livraison active, recherche d'adresse en priorité via Nominatim (gratuit) avant Google Places (voir mémoire `project_maps_cost_audit` — l'incident de facturation de juin 2026 est ce qui a motivé ces protections).
- **Fréquence recommandée** : hebdomadaire au pilote. Un pic soudain de coût malgré ces protections déjà en place est le signal le plus fiable d'un problème (bug de boucle, ou clé API utilisée en dehors de l'app — la clé n'est pas restreinte par empreinte d'app côté Console à ce jour, action externe déjà documentée comme non faite).

---

## 3. Procédures incidents

Chacune des procédures ci-dessous s'appuie sur un mécanisme réellement construit — quand rien n'existe encore pour un scénario, c'est indiqué comme "pas d'outil dédié, procédure manuelle" plutôt que de décrire un bouton qui n'existe pas.

### Côté client

| Incident | Procédure |
|---|---|
| **Commande bloquée** | `admin_orders.dart` — repérer la commande (bordure rouge si >1h en `accepted`/`picked_up`). Contacter le livreur assigné (téléphone visible sur la fiche commande). Si injoignable : pas d'outil de réassignation automatique (gap connu, `CLAUDE.md` section Livraison) — annulation manuelle + remboursement via le flux existant (`cancelOrderCF`), puis recréer la commande manuellement si le client le souhaite. |
| **Mauvais produit livré** | Créer/traiter comme un ticket support (`admin_support_page.dart`) — catégorie "Commande". Pas de remboursement partiel automatique (gap connu) : le remboursement existant est toujours intégral, décision manuelle au cas par cas. |
| **Demande de remboursement** | Via `admin_orders.dart` (annulation) si la commande n'est pas encore livrée, ou traitement manuel du wallet client si déjà livrée (aucun outil dédié "remboursement partiel post-livraison" — gap déjà documenté). |
| **Livreur absent/ne répond pas** | Vérifier `admin_live_tracking_page.dart` (position GPS, dernière mise à jour). Si GPS périmé (>60s, indicateur déjà calculé) et pas de réponse téléphone : traiter comme incident livreur (voir ci-dessous), réassigner ou annuler la commande manuellement. |

### Côté livreur

| Incident | Procédure |
|---|---|
| **Panne téléphone / batterie morte** | Le livreur disparaît de `admin_live_tracking_page.dart` (GPS périmé) et de la liste "en ligne" de `drivers_page.dart`. Contacter par un second moyen (WhatsApp si disponible). Réassigner ses commandes en cours manuellement si nécessaire. |
| **Accident** | Priorité sécurité humaine avant toute procédure logicielle. Une fois la situation stabilisée : suspendre temporairement le compte (`drivers_page.dart`, bouton pause déjà fonctionnel, Prompt 77) pour éviter qu'il ne reçoive de nouvelles courses, réassigner ses commandes en cours. |
| **GPS coupé volontairement (suspecté)** | `admin_live_tracking_page.dart` détecte déjà l'absence de mise à jour — mais rien ne distingue une coupure volontaire d'une vraie panne technique. Pas d'outil de détection automatique de fraude GPS (gap déjà documenté). Traiter au cas par cas : si récurrent chez le même livreur, voir section 5 (fraude). |
| **Problème de paiement de commission** | Vérifier le solde wallet du livreur (`drivers_page.dart` ou `admin_recharge_page.dart`) — la commission est déjà déduite automatiquement à l'acceptation (`acceptOrder()`), remboursable si la commande est annulée. Si le livreur conteste un montant, comparer avec `wallet_transactions` (sous-collection du livreur) pour l'historique réel. |

### Côté partenaire

| Incident | Procédure |
|---|---|
| **Produit indisponible** | Le partenaire doit désactiver le produit lui-même depuis son propre tableau de bord (`seller_dashboard.dart`/`restaurant_owner_dashboard.dart`/etc., déjà fonctionnel) — pas d'action admin nécessaire sauf si le partenaire ne peut pas se connecter. |
| **Retard de préparation** | Pas de mécanisme de pénalité/alerte automatique (gap non construit). Suivi manuel via `admin_orders.dart` — un retard récurrent chez le même partenaire est à traiter comme une conversation directe, pas un outil logiciel. |
| **Argent cash non remis** | `admin_cash_settlement_page.dart` — c'est exactement l'écran construit pour ce cas précis (Prompt 76). Une entrée qui reste plusieurs jours sans être marquée "réglée" est le signal à escalader vers le livreur concerné, voir section 5. |

---

## 4. Argent & fin de journée

Procédure de clôture quotidienne, à exécuter chaque soir (recoupe la section 1 « Soir », détaillée ici) :

1. **Paiements wallet du jour** : `admin_commissions_page.dart`/`admin_earnings.dart` pour la vue livreur ; pas de vue consolidée multi-vertical (Marketplace/Restaurant/Pharmacie) dans un seul écran — gap déjà documenté (`CLAUDE.md` section Administration).
2. **Cash collecté** : `admin_cash_settlement_page.dart` — liste des commandes cash avec marchand (`merchantCashSettled:false`). Objectif : liste vide en fin de journée.
3. **`merchantCashSettled` — contrôle précis** : ce champ n'existe QUE sur les commandes cash avec un `sellerId` restaurant/pharmacie (pas boutique — Boutique a son propre statut `pending_payment`→`paid`, pas marketplace/seller qui sont payés à 100% dès la création donc jamais concernés). Une commande absente de la liste `admin_cash_settlement_page.dart` alors qu'elle est cash avec marchand : vérifier qu'elle a bien atteint le statut `delivered` (le champ n'est écrit qu'à la livraison, pas avant).
4. **Commissions AZ** : déjà prélevées automatiquement à l'acceptation par chaque livreur (`acceptOrder()`, palier 100/200 FCFA selon `config/commission`) — rien à calculer manuellement, juste consulter le total du jour dans `admin_commissions_page.dart`.
5. **Écarts** : la vraie détection d'écart wallet↔historique est **automatique et hebdomadaire** (`walletReconciliationCheck`, chaque lundi 4h, écrit dans `wallet_reconciliation_findings`) — pas une vérification manuelle à refaire chaque soir. Le contrôle quotidien du soir porte sur la cohérence opérationnelle (cash effectivement remis, commandes bien closes), pas sur un recalcul comptable complet.

---

## 5. Sécurité après lancement

Aucun de ces signaux n'a d'alerte automatique poussée à l'admin (pas de notification push/email sur anomalie détectée — gap déjà documenté, `CLAUDE.md` section BI/Analytics « pas de détection d'anomalie business ») — chacun nécessite une vérification manuelle active, pas une passivité en attendant une alerte.

| Signal à surveiller | Où | Comment interpréter |
|---|---|---|
| **Tentative de fraude paiement** | `security_events` (Firestore, lecture admin) | Alimenté par `logSecurityEvent()` — déjà couvre les tentatives de webhook FeexPay invalides/rejouées. Rien de spécifique aux failles Firestore fermées au Prompt 80 (auto-assignation livreur, flip isPaid) puisque ces chemins sont désormais bloqués par les règles elles-mêmes — une tentative échouerait silencieusement côté client (permission-denied), sans forcément générer d'entrée `security_events` dédiée. |
| **Comptes suspects (multi-comptes)** | Pas d'outil dédié | Gap confirmé au Prompt 77 : aucune vérification d'unicité téléphone/pièce d'identité sur l'inscription livreur. Signal indirect possible : plusieurs comptes livreur avec le même numéro de téléphone dans les champs de contact — à repérer manuellement dans `drivers_page.dart`, pas automatisé. |
| **Livreurs problématiques** | `drivers_page.dart` + `admin_drivers_ranking.dart` + `admin_cash_settlement_page.dart` (entrées récurrentes) | Combiner : taux d'annulation élevé, cash jamais réglé à temps, position GPS souvent périmée — aucun score composite automatique, à croiser manuellement. Action disponible : suspension (`drivers_page.dart`, Prompt 77). |
| **Abus support** (signalements répétés sans fondement, spam de tickets) | `admin_support_page.dart` | Pas de limite de fréquence sur la création de `support_tickets` par un même utilisateur (gap non construit) — à traiter au cas par cas si observé. |
| **Commandes fictives ciblant un partenaire** | `admin_orders.dart` (commandes avec `sellerId` inhabituel, montant élevé, jamais réellement suivies d'une préparation réelle) | C'est exactement le scénario fermé côté serveur au Prompt 80 (`deliverOrderCF` exige désormais `isPaid===true` avant de créditer un partenaire) — une tentative de ce type échouerait à créditer, mais la COMMANDE elle-même pourrait quand même être créée et traîner en `pending`/`delivered`-sans-crédit. Une commande `delivered` dont le partenaire n'a manifestement pas été crédité (`walletTarget:'partner_unpaid'` dans les logs de `deliverOrderCF`) est le signal exact à chercher si ce type de fraude est suspecté. |

---

## 6. Croissance après pilote — seuils et prérequis

Ce qui suit sont des **limites déjà identifiées dans le code**, pas des estimations en l'air — chacune a été documentée lors d'un audit dédié cette session, avec le fichier exact concerné.

### 5 livreurs → 20 livreurs

- **Rien à changer techniquement** pour ce palier — `dispatch.js` scanne tous les livreurs en ligne sans `.limit()` (accepté explicitement comme sûr jusqu'à une flotte "significativement plus grande", Prompt 59) ; 20 reste dans cette zone de confort.
- Vérifier manuellement que la suspension/réactivation (`drivers_page.dart`) reste gérable à l'œil — au-delà d'une vingtaine de comptes, une recherche/filtre pourrait devenir utile (pas construit aujourd'hui).

### 50 commandes/jour → 500 commandes/jour

C'est le palier qui touche réellement des limites déjà documentées :

- **🔴 À corriger avant ce palier, pas après** : `admin_earnings.dart` et `admin_drivers_ranking.dart` agrègent les commissions/classements **côté client, sur une lecture Firestore non bornée** de toutes les commandes livrées (Prompt 79) — à 500 commandes/jour cumulées sur plusieurs semaines, ces écrans deviennent lents et coûteux en lectures Firestore à chaque ouverture. Nécessite soit un `.limit()` réfléchi (risque de sous-compter, déjà écarté comme "pas sûr sans jugement au cas par cas"), soit une vraie migration vers un compteur pré-agrégé (Cloud Function dédiée) — chantier de conception à part entière, pas une passe automatique.
- **~30 écrans admin sans `.limit()`** au total (Prompt 79) — la plupart sont des listes de travail (sûres à borner), mais nécessitent un tri fichier par fichier avant d'ajouter des limites en masse.
- **`functions/dispatch.js`** : passé un certain nombre de livreurs simultanément en ligne (pas seulement le volume de commandes), le scan complet sans filtre géographique préalable commence à coûter — à réévaluer si la flotte grandit en parallèle du volume de commandes, pas seulement le volume seul.
- **Aucune sauvegarde Firestore automatique configurée** (gap déjà documenté, Prompt 61/65) — à ce volume, la perte de données en cas d'incident devient un vrai risque business, pas juste théorique. Activer l'export planifié natif Firestore (action Console GCP) avant ce palier, pas après.
- **Pas de `minInstances` configuré sur les Cloud Functions** (Prompt 37) — les cold starts, négligeables à 50 commandes/jour, deviennent perceptibles pour les clients à 500/jour si le trafic est concentré sur des créneaux (heures de repas). À réévaluer avec des données réelles de latence, pas en anticipation aveugle.
- **Stockage jamais nettoyé** (photos KYC/preuves de livraison/produits, Prompt 37) — le coût croît avec le volume, sans jamais se stabiliser ; à surveiller en Console, un nettoyage devient plus urgent à ce palier qu'au pilote.
- **Un seul projet Firebase, pas d'environnement de staging** (Prompt 16/38) — à ce volume, tester un changement directement en production devient plus risqué ; envisager un second projet Firebase de test si le rythme de changements reste soutenu après le pilote.

### Ce qu'il NE faut PAS anticiper avant d'en avoir la preuve

Cohérent avec la discipline déjà appliquée toute cette session (« ne pas optimiser par théorie ») : ne pas construire de cache applicatif, ne pas ajouter `minInstances`, ne pas migrer vers une architecture multi-région, tant que des métriques réelles (Firebase Console) ne confirment pas que c'est nécessaire. Le tableau ci-dessus liste des points de vigilance à vérifier AVANT de grandir, pas une feuille de route à exécuter par anticipation.

---

## Indicateurs à suivre — synthèse

| Indicateur | Fréquence | Où |
|---|---|---|
| Commandes bloquées >1h | Continu (visuel, `admin_orders.dart`) | App |
| Cash marchand non réglé | Quotidien (soir) | `admin_cash_settlement_page.dart` |
| Écart wallet réel vs historique | Hebdomadaire (auto, lundi 4h) | `wallet_reconciliation_findings` |
| Zones/créneaux en échec de dispatch | Quotidien (soir) | `admin_security_dashboard.dart` |
| Tickets support ouverts | Continu | `admin_support_page.dart` |
| Crashs app | Quotidien (1ère semaine) | Firebase Crashlytics |
| Coût Google Maps | Hebdomadaire | Google Cloud Console |
| Consommation Firestore/Storage | Hebdomadaire (pilote) → quotidien (>500 cmd/j) | Google Cloud Console |
| Commissions AZ du jour | Quotidien (soir) | `admin_commissions_page.dart` |

---

**Document vivant** : ce manuel doit être mis à jour si un nouvel outil admin est construit ou si un gap listé ici est comblé — ne pas laisser ce fichier dériver du code réel comme cela a été corrigé pour `CLAUDE.md` à plusieurs reprises cette session (ex. le "500 dernières commandes" de `admin_drivers_ranking.dart`, corrigé au Prompt 79 après vérification directe).
