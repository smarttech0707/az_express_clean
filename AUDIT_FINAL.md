# AZ Express — Audit final avant mise en production

**Date** : 2026-07-02 (Release Candidate Final Gate — Master Prompt 50, mise à jour depuis la version couvrant les Prompts 01→39)
**Périmètre** : synthèse des audits réalisés au fil des Master Prompts 01→50 (chacun grounded dans le code réel, jamais dans une supposition) + des jalons AZ IA M0→M7 livrés, plus une tranche ciblée de M8. Ce document ne réintroduit pas de nouvelles recherches à chaque section — il compile ce qui a déjà été vérifié et documenté dans `CLAUDE.md`, section par section, en un rapport priorisé. Les vérifications propres à ce Prompt 50 (règles Storage, sécurité au démarrage, suppression de compte avec solde actif) sont marquées explicitement.

**Ce que ce document n'est pas** : un audit de sécurité professionnel externe, un test de charge réel, ou une revue juridique/conformité. C'est une synthèse honnête de l'état du code tel qu'observé par un agent IA au cours de cette session — utile pour prioriser, pas pour remplacer une revue humaine avant un vrai lancement à grande échelle.

**Ce qui a changé depuis la version du 2026-07-02 (Prompts 01→39)** : cette mise à jour couvre 11 prompts supplémentaires (41→50, le 40 ayant produit la version précédente), avec un changement de nature — les prompts 41-45 ont audité des zones jusqu'ici jamais examinées (repositories morts, gestion mémoire, gestion d'état, doubles sources de vérité), mais **les prompts 46 à 49 ont trouvé et corrigé 6 bugs financiers réels et confirmés**, une découverte bien plus significative que tout ce qui avait été trouvé dans les Prompts 21-39 réunis. Le plus grave d'entre eux — **le remboursement automatique à 48h des commandes Boutique non livrées n'a jamais fonctionné en production, silencieusement, depuis la mise en service de cette fonctionnalité** — n'a été découvert qu'en traçant explicitement chaque chemin argent du module Boutique de bout en bout (Prompt 48 bis), après qu'un premier passage plus rapide (Prompt 47) avait laissé le sujet incomplet. La suite de tests est passée de 104 à **115 tests**.

---

## 1. Résumé exécutif

AZ Express est un super-app ivoirien fonctionnellement large (livraison, courses, marketplace, immobilier, restaurants, pharmacies, boulangeries, wallet, Ekbine, AZ IA) avec une base technique **plus mature que ce qu'un audit superficiel suggérerait** — mais cette session (Prompts 46-49 en particulier) a aussi confirmé que la classe de bug la plus dangereuse trouvée depuis le début de l'audit (« une transaction Firestore cross-user écrite depuis le client, bloquée par des règles de sécurité correctement strictes, échouant silencieusement en production ») n'était pas limitée aux trois cas déjà connus au 01/07 — six occurrences supplémentaires de cette même famille de bug existaient encore, réparties entre paiement Restaurant, double-crédit Marketplace/Boutique, remboursement manquant au vendeur lors d'une annulation, et surtout le remboursement automatique Boutique jamais fonctionnel.

**Nouveauté principale de cette mise à jour — 6 bugs financiers réels trouvés et corrigés (Prompts 46-49)** :
1. Paiement wallet Restaurant (`restaurant_menu.dart`) : 100 % cassé en production (même cause que les 3 bugs déjà connus).
2. Commandes Restaurant créées par AZ IA : double-crédit du restaurant (payé à la création ET à la livraison).
3. Commandes Marketplace/Boutique créées par AZ IA ou achetées directement : même double-crédit, corrigé avec une exemption explicite du modèle « commission à la livraison » pour ces deux types (0 % commission, payé intégralement à la création).
4. Annulation/expiration d'une commande Marketplace : le client était remboursé, le vendeur (déjà payé) jamais débité en retour — de l'argent créé à partir de rien à chaque annulation.
5. Solde négatif possible sur les deux débits ci-dessus si le vendeur avait déjà retiré une partie de son crédit — plafonné à 0.
6. **Le plus grave : le remboursement automatique 48h des commandes Boutique non livrées n'a jamais fonctionné** — bloqué par les mêmes règles de sécurité que les bugs déjà connus, l'échec avalé silencieusement. Aucun client n'a jamais été remboursé automatiquement pour une commande boutique non livrée, depuis que cette fonctionnalité existe.

**Deux bugs supplémentaires de double-tap trouvés et corrigés** (`boutique_page.dart` Prompt 48, `pharmacie_garde.dart` Prompt 49) — absence de protection anti-double-clic sur un bouton de paiement, permettant potentiellement une double commande + double débit.

**Une trouvaille de documentation corrigeant une erreur déjà présente dans ce document depuis le 01/07** : `lib/services/delivery_service.dart`, précédemment qualifié de « probablement mort », est en fait activement utilisé par `create_order.dart` — atteint depuis le bouton « Commander » du tableau de bord principal. Deux moteurs de tarification livraison réellement différents coexistent donc en production sur deux points d'entrée légitimes (Prompt 45), pas un seul actif et un mort comme supposé — non corrigé (nécessite un arbitrage produit, pas une simple suppression).

Le projet n'est **toujours pas prêt pour une mise en production à grande croissance non supervisée**, mais chaque bug financier confirmé et prouvé a été corrigé au fil de cette session — il n'existe, à la connaissance de cet audit, plus aucun chemin connu créant de l'argent à partir de rien ou perdant l'argent d'un utilisateur silencieusement. Les risques restants (tarification non validée serveur, App Check absent, deux systèmes Immobilier, deux back-offices) sont des risques de confiance/robustesse à moyen terme, pas des bugs actifs de perte d'argent.

---

## 2. État général du projet

| Dimension | État (2026-07-02, Prompt 50) | Évolution depuis Prompt 39 |
|---|---|---|
| Fonctionnalités métier | Larges et globalement fonctionnelles | Inchangé |
| Paiements wallet | **9 bugs réels au total trouvés et corrigés cette session** (3 avant Prompt 39, 6 aux Prompts 46-49) | **6 nouveaux bugs critiques corrigés** — le progrès le plus significatif de toute la session |
| Double-tap / idempotence UI | 2 bugs trouvés et corrigés (Boutique, Pharmacie) ; tous les autres boutons critiques déjà protégés | **Nouvel audit dédié** (Prompt 49), résultat majoritairement propre |
| Dispatch | Entièrement côté serveur, verrouillage transactionnel | Inchangé depuis Prompt 39 |
| Wallet — conciliation | Moteur de conciliation hebdomadaire actif | Inchangé, mais désormais plus fiable (6 bugs de moins) |
| Gestion mémoire Flutter | 1 fuite confirmée et corrigée (`agent_dashboard_screen.dart`), reste de l'app vérifié propre | **Nouvel audit** (Prompt 44) |
| Gestion d'état Flutter | Aucun Provider mort/géant/multi-domaine trouvé — zone la plus saine auditée | **Nouvel audit** (Prompt 43) |
| Tests | 104 → **115 tests** | +11, tous liés aux corrections financières |
| CI/CD | Toujours inactif (pas de remote GitHub), zéro commit git cette session | Inchangé |
| Documentation | `CLAUDE.md` étendu de ~10 sections supplémentaires (Prompts 41-50) | Étendu en continu |

---

## 3. Architecture

**Inchangé depuis Prompt 39** sur l'essentiel (voir version précédente) — séparation Flutter/Cloud Functions/Firestore respectée pour le code de cette session, pattern de fabrique testable généralisé, 52 Cloud Functions désormais déployées (était ~45-51).

**Nouveau (Prompt 41)** : `lib/repositories/` contenait 3 classes mortes et une (`WalletRepository`) activement dangereuse — un `credit()`/`debit()` générique qui aurait réintroduit la même classe de bug déjà corrigée si jamais câblé sans vérification. Supprimées entièrement plutôt que « corrigées mais laissées inutilisées » — le risque était qu'un futur développeur (humain ou IA) les découvre et les adopte en pensant bien faire.

**Nouveau (Prompt 42)** : troisième et quatrième occurrences du pattern déjà connu « deux implémentations parallèles construites indépendamment » — deux services de suivi de livraison temps réel (`TrackingService` vs `RealtimeTrackingService`), et (Prompt 45) deux moteurs de tarification livraison réellement actifs (voir résumé exécutif).

**Risque** : Moyen, inchangé dans sa nature.

---

## 4. Sécurité (classée par criticité)

### Critique — trouvées ET corrigées cette session (mise à jour Prompt 50)

**Déjà connues (Prompts 01-39)** :
- Mot de passe pharmacie en clair — corrigé (Prompt 12).
- Paiement wallet livraison cassé (`payOrderFromWallet`/`cancelOrder`/`deliverOrder`) — corrigé (Prompt 22 follow-up).
- Paiement wallet Boutique cassé (`creditSellerWallet`) — corrigé (Prompt 28).

**Nouvelles cette mise à jour (Prompts 46-49), même famille exacte — une transaction Firestore cross-user lancée par le client, bloquée par des règles de sécurité correctement strictes, échouant silencieusement en production, OU une Cloud Function server-side (légitimement capable de contourner les règles) qui elle-même n'a pas la bonne logique de non-duplication :**

1. **Paiement wallet Restaurant cassé** (`restaurant_menu.dart`) — tentait de créditer `restaurants/{id}.wallet` directement, rejeté par la règle (`isAdmin()` uniquement, aucune exception propriétaire), toute la transaction échouait donc y compris le débit client et la création de commande. Corrigé : délégué à `deliverOrderCF` (Prompt 46).
2. **Double-crédit Restaurant côté AZ IA** — `functions/azia/tools/restaurants.js` créditait le restaurant en entier à la création (Admin SDK, réussit) PUIS `deliverOrderCF` le créditait à nouveau à la livraison. Corrigé en retirant le crédit immédiat (Prompt 46).
3. **Double-crédit Marketplace/Boutique** — même mécanisme, mais la solution « retirer le crédit immédiat » aurait fait payer une commission de 100 FCFA à des types qui n'en doivent jamais (politique 0 % déjà documentée) ; corrigé en exemptant `seller`/`boutique` du crédit de `deliverOrderCF` (`PREPAID_PARTNER_TYPES`), décision validée explicitement par l'utilisateur (Prompt 46).
4. **Vendeur Marketplace jamais débité en retour lors d'une annulation/expiration** — `cancelOrderCF` et `autoExpireOrders` remboursaient le client sans jamais reprendre le crédit déjà versé au vendeur — argent créé à partir de rien à chaque annulation. Corrigé, validation utilisateur préalable obtenue (argent) (Prompt 47).
5. **Solde négatif possible** sur les débits vendeur ci-dessus si le vendeur avait déjà retiré une partie du crédit — plafonné à `Math.min(montant, solde actuel)` dans les deux fonctions, avec correction d'un problème d'ordre lecture/écriture Firestore découvert en implémentant le correctif (Prompt 48).
6. **Remboursement automatique Boutique 48h jamais fonctionnel** — `_processRefund()` créditait directement le wallet du client depuis une transaction Firestore côté client ; la règle `clients/{id}` n'autorise qu'une **diminution stricte** du solde propre (jamais une augmentation, même pour soi-même), et `boutique_orders/{id}` n'autorise que l'écriture admin — les deux écritures échouaient systématiquement, avalées silencieusement par un `try/catch`. **Aucun client n'a jamais été remboursé automatiquement pour une commande boutique non livrée**, découvert seulement en cartographiant le flux Boutique de bout en bout (Prompt 48 bis). Corrigé : nouvelle Cloud Function `refundExpiredBoutiqueOrderCF`, revalide le délai côté serveur, crédite le client, débite le vendeur (plafonné à 0).

**Interprétation, actualisée** : le constat déjà fait pour les 3 bugs de la version précédente se confirme et s'aggrave en fréquence — les règles de sécurité Firestore de ce projet sont systématiquement correctement strictes, et c'est le code applicatif (Flutter et, pour 2 des 6 nouveaux cas, les Cloud Functions elles-mêmes) qui ne les respecte pas. Neuf bugs de cette exacte nature trouvés en une seule session confirme que l'absence de tests d'intégration Flutter↔Firestore↔Cloud Functions (voir section Tests) est le facteur de risque numéro un du projet — pas la conception des règles elles-mêmes, qui s'est révélée être la ligne de défense qui a évité une perte financière réelle dans au moins 3 des 9 cas (les transactions cross-user rejetées plutôt que silencieusement réussies).

### Élevée — toujours ouvertes

- **App Check absent** — inchangé.
- **Tarification livraison non validée côté serveur** — inchangé, et **aggravé en substance** : ce n'est plus seulement « un moteur de tarification non validé », ce sont **deux moteurs différents non validés**, actifs simultanément sur deux points d'entrée légitimes (Prompt 45) — un client pourrait recevoir un prix différent pour un trajet identique selon l'écran utilisé, indépendamment de toute manipulation malveillante.
- **`livreurs/{id}.wallet` reste lisible par tout utilisateur authentifié** — inchangé, décision de report toujours valide.
- **Deux systèmes Immobilier parallèles** — inchangé.
- **Deux back-offices non unifiés** — inchangé.
- **🆕 (Prompt 50) Photos/selfies/pièces d'identité livreurs et flotte lisibles par tout utilisateur authentifié** (`storage.rules` : `driver_photos`, `driver_selfies`, `driver_id_photos`, `fleet_selfies`, `fleet_id_photos` ont toutes `allow read: if isAuth();`, sans restriction au propriétaire ou à l'admin) — même famille que le risque déjà connu sur `livreurs.wallet` (visibilité, pas vol de fonds), mais ici sur des données d'identité sensibles plutôt qu'un solde. Exploitable seulement par quelqu'un connaissant ou devinant l'UID exact du fichier (pas d'énumération triviale exposée), donc un risque réel mais pas immédiatement critique pour un pilote supervisé à petite échelle. Jamais audité avant ce Prompt 50.

### Moyenne

- Compte livreur de flotte : création probablement cassée (inchangé, non corrigé).
- Code mort 2FA admin (inchangé).
- `service_providers` (artisans) — faiblesse d'auth inchangée.
- Vocabulaire de statut transaction fragmenté (inchangé).
- Fichiers Cloud Storage jamais nettoyés (inchangé).
- **🆕 (Prompt 48 bis) Chemin de paiement cash Boutique cassé différemment** : décrémente le stock produit (écriture directe, non protégée) PUIS tente de créer `boutique_orders` avec un statut (`pending_payment`) qui viole la règle de création (`status == 'pending'` exact) — échoue systématiquement, mais après que le stock ait déjà été décrémenté. Pas une perte d'argent (paiement cash, rien n'est débité du wallet), mais un vrai problème d'inventaire à chaque tentative d'achat cash. Documenté, pas corrigé (nécessite une décision sur la sémantique de statut correcte, que l'écran admin ne connaît même pas).
- **🆕 (Prompt 50) Suppression de compte vendeur/livreur sans avertissement de solde actif** — `admin_sellers_page.dart`/`drivers_page.dart` suppriment le document sur simple confirmation, sans vérifier ni avertir si `wallet > 0`. Action admin-only, déclenchée délibérément (pas un risque automatique ou exploitable de l'extérieur), mais un vrai risque opérationnel/comptable si un admin supprime par erreur un compte avec un solde non nul.

### Faible

- Inchangé depuis Prompt 39 (sessions/appareils, MFA, CI inactive).

### Vérifications de sécurité ciblées Prompt 50, sans nouvelle trouvaille critique

- **Démarrage de l'app / initialisation Firebase** (`lib/main.dart`) : déjà bien protégé — `Firebase.initializeApp()` gère explicitement `duplicate-app`, la connexion anonyme a un timeout + `try/catch` avec remontée Crashlytics (pas de blocage du démarrage), `loadCommissionConfig()` a son propre `try/catch` interne, `NotificationService().init()` est intentionnellement non-awaité. Aucun chemin de crash au démarrage identifié.
- **`firestore.rules`/`storage.rules`** relus dans leur ensemble (pas seulement les collections déjà connues) — posture par défaut-refus confirmée (`storage.rules` se termine sans règle catch-all permissive), validation de type/taille systématique sur les uploads Storage. Aucune faille d'écriture ouverte trouvée au-delà des lectures déjà documentées ci-dessus (wallet livreur, photos d'identité).

---

## 5. Performances

**Inchangé depuis Prompt 39** — voir la version précédente pour le détail complet (GPS optimisé, `cached_network_image` adopté, `GoogleRoutesService` bien conçu, pagination incohérente, Firebase Analytics inutilisé). Aucune nouvelle trouvaille de performance dans les Prompts 41-50 — ces prompts se sont concentrés sur la correctness financière, pas la performance.

**Risque** : Moyen, inchangé.

---

## 6. Qualité du code

Le pattern déjà établi (chaque nouvelle Cloud Function critique reçoit son propre test) s'est maintenu strictement sur les 6 bugs financiers corrigés cette mise à jour — **11 nouveaux tests ajoutés** (`orderActions.test.js`), chacun couvrant précisément le comportement corrigé (non-double-crédit, plafond de solde négatif, remboursement 48h avec revalidation serveur du délai). Code mort supprimé dès identifié : 3 repositories dangereux (Prompt 41), `_processRefund()` remplacé plutôt que corrigé sur place (Prompt 48 bis).

**Nouveau constat (Prompt 44)** : la gestion mémoire Flutter (`dispose()` des contrôleurs/abonnements) est globalement saine dans ce projet — script exhaustif comparant créations et disposals sur tout `lib/`, un seul cas réel trouvé (`agent_dashboard_screen.dart`, module Immobilier), tous les autres candidats étaient des faux positifs (contrôleurs de dialogue ponctuels, correctement éphémères).

**Nouveau constat (Prompt 43)** : la gestion d'état (`Provider`/`ChangeNotifier`) est également saine — audit exhaustif des 4 `Provider` globaux, aucun mort, géant, ou multi-domaine trouvé, contrairement à la plupart des autres audits de cette session qui trouvaient systématiquement quelque chose à corriger.

---

## 7. Documentation

`CLAUDE.md` a gagné ~10 sections/sous-sections supplémentaires depuis Prompt 39 (Gestion d'état, corrections Prompts 41-49). Reste la documentation technique vivante de référence.

---

## 8. Audit par module (mise à jour des modules touchés par les Prompts 41-50 uniquement)

### Livraison
- **Nouveau (Prompt 45)** : deux moteurs de tarification actifs et différents (`TarifService`, 4 écrans, vs `DeliveryService`, 1 écran mais le point d'entrée le plus visible de l'app) — voir résumé exécutif. `TarifService` a le plus d'indices en sa faveur pour être la référence « officielle » (adoption plus large, seul mentionné dans la feuille de route multi-villes), mais aucune migration effectuée sans certitude business.
- **Nouveau (Prompt 42)** : deux services de tracking temps réel dupliqués (`TrackingService`/`RealtimeTrackingService`), documentés, non fusionnés.
- **Risque** : Élevé (tarification, aggravé), inchangé pour le reste.

### Wallet & Finance
- **9 bugs de paiement réels au total trouvés et corrigés sur toute la session** (3 avant Prompt 39, 6 aux Prompts 46-49) — voir section 4. C'est désormais la partie du projet la plus intensément vérifiée et corrigée, alors qu'elle était initialement perçue comme « transactionnellement propre » sur la seule base d'une lecture de code sans traçage complet des flux.
- **Risque** : passé de Moyen à **Faible pour les bugs déjà trouvés** (tous corrigés et testés) ; reste Moyen pour les risques structurels non résolus (vocabulaire de statut fragmenté, remboursement toujours total).

### Restaurant / Marketplace / Boutique
- **Nouveau** : les 6 bugs financiers de cette mise à jour concernent presque tous ces trois modules — voir section 4. Le module Boutique en particulier a fait l'objet d'une cartographie complète de bout en bout (Prompt 48 bis) : création, paiement wallet, paiement cash (cassé différemment, documenté), crédit vendeur, livraison, annulation client (le seul mécanisme existant touche le mauvais document), annulation vendeur (inexistante), expiration automatique (jamais fonctionnelle avant ce correctif).
- **Risque** : passé de non-évalué à Faible pour les 3 bugs corrigés, Moyen pour le chemin cash non corrigé.

### Architecture Flutter (gestion mémoire, gestion d'état)
- **Nouveau (Prompts 43-44)** : deux audits dédiés, résultats majoritairement propres (voir sections 4/6). Le seul correctif appliqué (fuite mémoire Immobilier) est mineur et sans risque.
- **Risque** : Faible.

### Autres modules (Courses, Immobilier hors tarification, Ekbine, AZ IA, Administration, Notifications, Maps/GPS, Identité)
- **Inchangés depuis Prompt 39** — aucun prompt de la tranche 41-50 n'a redemandé un audit direct de ces modules au-delà des vérifications transverses déjà notées (double-tap Ekbine vérifié protégé, Prompt 49 ; sécurité au démarrage AZ IA non spécifiquement re-testée). Leurs trouvailles de la version précédente restent valides.

---

## 9. Risques transverses (tableau mis à jour)

| Risque | Criticité | Statut |
|---|---|---|
| Mot de passe pharmacie en clair | Critique | **Corrigé** (Prompt 12) |
| Paiement wallet livraison cassé (×3 : payOrderFromWallet/cancelOrder/deliverOrder) | Critique | **Corrigé** (Prompt 22 follow-up) |
| Paiement wallet Boutique cassé (creditSellerWallet) | Critique | **Corrigé** (Prompt 28) |
| Paiement wallet Restaurant cassé | Critique | **Corrigé** (Prompt 46) |
| Double-crédit Restaurant (AZ IA) | Critique | **Corrigé** (Prompt 46) |
| Double-crédit Marketplace/Boutique (AZ IA + achat direct) | Critique | **Corrigé** (Prompt 46) |
| Vendeur Marketplace non débité lors d'une annulation | Critique | **Corrigé** (Prompt 47) |
| Solde négatif possible sur débit vendeur | Critique | **Corrigé** (Prompt 48) |
| Remboursement automatique Boutique 48h jamais fonctionnel | Critique | **Corrigé** (Prompt 48 bis) |
| Double-tap Boutique (double achat) | Élevée | **Corrigé** (Prompt 48) |
| Double-tap Pharmacie (double commande) | Élevée | **Corrigé** (Prompt 49) |
| Tarification livraison non validée serveur — **et désormais deux moteurs divergents** | Élevée | Ouvert, aggravé en substance (Prompt 45) |
| App Check absent | Élevée | Ouvert, inchangé |
| `livreurs.wallet` lisible par tout authentifié | Élevée | Ouvert, décision de report inchangée |
| Deux systèmes Immobilier parallèles | Élevée | Ouvert, inchangé |
| Deux back-offices non unifiés | Élevée | Ouvert, inchangé |
| Photos/pièces d'identité livreurs lisibles par tout authentifié | Élevée | **Nouvelle découverte** (Prompt 50), ouvert |
| ~90% du code sans test automatisé (hors chemins financiers désormais couverts) | Élevée | Ouvert, réduit (104→115 tests) |
| Repositories morts/dangereux (`WalletRepository` etc.) | Moyenne | **Corrigé — supprimés** (Prompt 41) |
| Fuite mémoire Immobilier (`agent_dashboard_screen.dart`) | Moyenne | **Corrigé** (Prompt 44) |
| Chemin cash Boutique cassé (stock décrémenté sans commande créée) | Moyenne | **Nouvelle découverte** (Prompt 48 bis), ouvert |
| Suppression compte vendeur/livreur sans avertissement de solde | Moyenne | **Nouvelle découverte** (Prompt 50), ouvert |
| Fichiers Storage jamais nettoyés | Moyenne | Ouvert, inchangé |
| Compte livreur de flotte probablement cassé | Moyenne | Ouvert, inchangé |
| `service_providers` faiblesse d'auth (artisans) | Moyenne | Ouvert, inchangé |
| Vocabulaire de statut transaction fragmenté | Moyenne | Ouvert, accepté comme dette |
| Pas de CI active, zéro commit git sur toute la session | Moyenne | Bloqué sur une action utilisateur |

---

## 10. Recommandations prioritaires (mises à jour)

**Critique** — aucune restante (les 9 bugs de paiement identifiés au total sont tous corrigés et testés).

**Élevée** :
1. Trancher entre `TarifService` et `DeliveryService` (ou instrumenter d'abord pour mesurer l'écart réel) — désormais le seul risque de tarification non résolu, mais concrètement double par rapport à la version précédente de ce document.
2. Activer App Check avec un rollout progressif.
3. Réconcilier ou séparer officiellement les deux systèmes Immobilier et les deux back-offices.
4. Restreindre la lecture de `livreurs.wallet` et des photos/pièces d'identité livreurs (`storage.rules`) — même famille de risque (visibilité, pas vol de fonds), à traiter ensemble si un chantier dédié est ouvert.
5. Étendre la couverture de tests aux flux Ekbine/Marketplace non financiers, et aux `confirmHandler` des outils AZ IA (`restaurants.js`, `marketplace.js`, `pharmacies.js`, `delivery.js`) — modifiés cette session (2 d'entre eux) mais toujours sans test unitaire direct, vérifiés seulement par relecture attentive et `node -c`/`require()`.

**Moyenne** :
6. Décider de la sémantique de statut correcte pour les commandes Boutique payées cash, puis corriger l'écriture qui viole aujourd'hui la règle Firestore.
7. Ajouter un avertissement de solde actif avant suppression d'un compte vendeur/livreur depuis l'admin.
8. Pousser le dépôt vers GitHub, committer le travail de cette session, activer la CI déjà écrite.
9. Configurer une sauvegarde Firestore planifiée.
10. Corriger le flux de création de compte livreur de flotte.
11. Nettoyer le code mort du mécanisme 2FA admin.
12. Concevoir une stratégie de nettoyage Storage.

**Faible** : inchangé (Analytics, préférences notification, suspension client, doc par endpoint).

---

## 11. Plan de lancement par phases (mis à jour)

### Phase 1 — Bêta privée (petit groupe contrôlé)
**Critères d'entrée** : déjà remplis, renforcés par cette mise à jour — les 9 bugs de paiement critiques connus sont désormais tous corrigés et testés (contre 3 à la version précédente), le dispatch est fiable, la conciliation wallet tourne en surveillance passive, les boutons de paiement critiques sont protégés contre le double-tap.
**Critères de sortie avant Phase 2** : App Check activé ; arbitrage sur les deux moteurs de tarification livraison ; décision prise sur les deux systèmes Immobilier et les deux back-offices ; restriction de la lecture `livreurs.wallet`/photos d'identité.

### Phase 2 — Bêta publique (Abengourou, trafic non contrôlé)
**Critères d'entrée** : tout ce qui précède + sauvegardes Firestore planifiées + CI réellement exécutée + travail committé et déployé.
**Critères de sortie** : deux semaines sans incident financier (conciliation wallet sans écart — désormais un test plus significatif qu'avant, puisque 6 sources d'écart connues ont été éliminées cette session).

### Phase 3 — Lancement officiel à Abengourou
**Inchangé** depuis la version précédente.

### Phase 4 — Extension aux autres villes / Phase 5 — Autres pays africains
**Inchangé** depuis la version précédente.

---

## 12. Indicateurs de succès proposés

**Inchangé** depuis la version précédente — voir section correspondante. Une addition : la conciliation wallet hebdomadaire (`walletReconciliationCheck`) est désormais un indicateur plus fiable qu'avant cette mise à jour, puisque les 6 sources d'écart structurel qu'elle aurait pu masquer ou confondre avec du bruit sont désormais éliminées.

---

## 13. Verdict final

### READY PILOT

AZ Express peut entrer en **phase pilote réelle, sous supervision humaine active** — c'est un cran plus solide qu'à la version précédente de ce document (Prompt 39), grâce à la correction de **6 bugs financiers critiques supplémentaires** trouvés cette mise à jour, dont un (le remboursement automatique Boutique 48h) était complètement silencieux et aurait pu passer inaperçu indéfiniment sans un audit dédié au flux de bout en bout. Il n'existe, à la connaissance de cette session d'audit, **plus aucun bug connu et non corrigé créant de l'argent à partir de rien ou perdant l'argent d'un utilisateur silencieusement**.

**Ce verdict est spécifiquement "pilote supervisé", pas "lancement public non supervisé"** — voir la liste des risques restants ci-dessous, dont deux au moins (tarification à deux moteurs divergents, App Check absent) représentent un risque de confiance/fraude qui devient significatif à mesure que le volume et l'exposition grandissent au-delà d'un groupe pilote surveillé.

### Liste exacte des risques restants (Élevée, tous non-bloquants pour un pilote supervisé mais à traiter avant un lancement public)

1. Tarification livraison non validée côté serveur, et désormais deux moteurs de calcul différents actifs simultanément (`TarifService` vs `DeliveryService`).
2. App Check non configuré.
3. `livreurs/{id}.wallet` et les photos/pièces d'identité livreurs (`storage.rules`) restent lisibles par tout utilisateur authentifié.
4. Deux systèmes Immobilier parallèles non réconciliés (`locations` vs `real_estate_listings`).
5. Deux back-offices web/mobile non unifiés.
6. Couverture de tests toujours partielle — en particulier les `confirmHandler` AZ IA de création de commande (restaurant/marketplace/pharmacie/livraison), certains modifiés cette session sans test unitaire dédié.
7. Chemin de paiement cash Boutique cassé (stock décrémenté sans commande créée) — pas une perte d'argent, mais un vrai problème d'inventaire.
8. Zéro commit git sur l'intégralité de cette session — le travail (y compris les 9 correctifs financiers) reste non versionné.

### Actions obligatoires avant lancement public (au-delà du pilote supervisé)

1. Trancher et unifier la tarification livraison (un seul moteur, validé côté serveur).
2. Activer App Check.
3. Restreindre `livreurs.wallet` et les documents d'identité livreurs à leur propriétaire + admin.
4. Décider explicitement du sort des deux systèmes Immobilier et des deux back-offices.
5. Committer et versionner le travail de cette session ; pousser vers un remote GitHub ; activer la CI déjà écrite.
6. Ajouter une couverture de test minimale sur les 4 `confirmHandler` AZ IA de création de commande.
7. Corriger le chemin de paiement cash Boutique.

**Point opérationnel indépendant, répété depuis la version précédente** : zéro commit git n'a été fait durant l'intégralité de cette session (50 prompts) — c'est toujours la première action concrète et à très faible risque avant toute suite.
