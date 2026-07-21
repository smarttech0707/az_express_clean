# AZ EXPRESS TECHNICAL BIBLE
### Version 1.0 — 2026-07-16

**Méthode de production de ce document** : chaque affirmation ci-dessous est déduite du code réel du dépôt (`d:\az_express_clean`), de son historique documenté dans `CLAUDE.md` (journal technique vivant tenu à jour prompt par prompt depuis le début du projet, lui-même vérifié contre le code à chaque entrée), et de requêtes fraîches contre le projet Firebase de production `az-express-b0469` (`firebase functions:list`, `firestore.rules`, `pubspec.yaml`, `functions/package.json`). Aucune section n'a été devinée. Là où une information n'est pas démontrable dans le code, c'est écrit explicitement (« NON VÉRIFIABLE DANS CET ENVIRONNEMENT » ou « NON IMPLÉMENTÉ »). Ce document ne modifie rien — audit et synthèse uniquement.

**Légende de statut utilisée dans tout le document** :
- **OPÉRATIONNEL** — construit, testé au moins partiellement, utilisé en production.
- **PARTIELLEMENT IMPLÉMENTÉ** — construit mais avec un gap réel et documenté (fonctionnalité manquante, non testé, ou connu pour avoir un bug/une limite).
- **NON IMPLÉMENTÉ** — n'existe pas dans le code, quel que soit ce qu'un document marketing pourrait laisser supposer.

---

# CHAPITRE 1 — Présentation générale

**Nom** : AZ Express.

**Objectif** : super-application ivoirienne unique couvrant livraison à la demande, courses, marketplace d'occasion, commerce de proximité (boutique/restaurant/pharmacie/boulangerie), immobilier, moto-taxi/services (E-Kbine), wallet mobile money, et un assistant conversationnel (AZ IA) qui vise à devenir le point d'entrée principal de la plateforme. Signature produit répétée dans le code et la documentation : « Parlez. AZ s'occupe du reste. »

**Vision** : remplacer la navigation manuelle entre écrans/modules par une conversation unique avec AZ IA capable de consulter et déclencher des actions dans tous les modules, avec une garantie de sécurité non négociable — AZ IA ne touche jamais Firestore directement, uniquement via des Cloud Functions, et toute action financière ou destructrice exige une confirmation utilisateur validée côté serveur (`ai_pending_actions`/`aiConfirmAction`).

**Marché** : Côte d'Ivoire. Les constantes de tarification (`lib/services/tarif_service.dart`) sont centrées sur des coordonnées GPS fixes d'Abengourou (6.7273°N, -3.4961°E) — **le produit est aujourd'hui codé pour une seule ville**, pas une architecture multi-pays/multi-devises (FCFA codé en dur partout, `AppConfig.currency` jamais utilisé). L'app référence aussi Abidjan/Bouaké/Yamoussoukro/San Pedro/Daloa/Korhogo/Man/Gagnoa/Divo comme villes de sélection dans certains formulaires (Marketplace), mais le moteur de tarification/dispatch lui-même reste mono-ville.

**Public visé** : clients (grand public), livreurs indépendants et flottes, vendeurs Marketplace, restaurants/pharmacies/boulangeries/boutiques, agents E-Kbine, agents immobiliers, artisans/prestataires de services, administrateurs et sous-administrateurs de la plateforme.

**Pays** : Côte d'Ivoire (Abengourou en priorité opérationnelle).

**Architecture générale** : `Flutter (mobile + web) → Providers/State → Services Flutter → Cloud Functions (Firebase Functions v2 / Cloud Run) → Firestore/Storage`. Une partie des écritures — historiquement les créations de commande (livraison/courses/restaurant/pharmacie) — se fait encore directement depuis le client Flutter vers Firestore (état hérité documenté comme tel, pas la cible) ; toute la logique financière sensible construite depuis le milieu du projet passe systématiquement par des Cloud Functions.

**Technologies** :
- **Client** : Flutter (Dart), Provider pour l'état global (4 providers), Google Fonts (Urbanist depuis le Master Prompt 120), Google Maps, `speech_to_text`/`flutter_tts` pour la voix.
- **Backend** : Firebase (Cloud Firestore, Cloud Storage, Firebase Auth, Cloud Functions v2 sur Cloud Run, Cloud Scheduler, Cloud Messaging, Crashlytics, Analytics).
- **IA** : Claude (Anthropic, SDK `@anthropic-ai/sdk`) comme moteur unique d'AZ IA aujourd'hui — une architecture multi-fournisseurs existe en embryon (`AIProviderService.js`, clés OpenAI/Gemini/DeepSeek/Mistral/Groq réservées dans `functions/.env` mais **toutes vides** à ce jour) mais n'est utilisée nulle part en dehors de la mise en cache/quota de la vision.
- **Paiement** : FeexPay comme agrégateur unique (Orange Money, MTN MoMo, Moov Money, Wave, plus cash).

**Forces** (vérifiées, pas supposées) :
- Mécanisme de confirmation financière IA (`ai_pending_actions`/`aiConfirmAction`) robuste, jamais à l'origine d'un bug trouvé sur l'ensemble de la session d'audit.
- Historique d'audit exceptionnellement dense : au moins **11 bugs financiers critiques réels** trouvés et corrigés au fil du projet (doubles crédits, remboursements fantômes, mots de passe en clair), documentés avec preuve à chaque fois.
- Design system centralisé (`AppColors`/`AppTypography`/`AppRadius`/`AppShadow`) refondu en profondeur (Master Prompt 120), mode sombre réel pour toute la chrome Material.
- Suite de tests backend réelle et significative : **234 tests** (`functions/test/*.test.js`, runner natif Node).
- Discipline de sécurité constante : collections sensibles (`audit_logs`, `ai_pending_actions`, `rate_limits`...) systématiquement en écriture Cloud-Function-only.

**Limites** (vérifiées, pas supposées) :
- **Aucun test automatisé côté Flutter** au-delà d'un placeholder + 16 tests unitaires du sous-système voix (Master Prompt 119) — zéro test de widget, zéro test d'intégration.
- Mono-ville, mono-devise, mono-langue (français) en dur à plusieurs endroits (tarification, system prompt IA).
- Duplication architecturale récurrente : au moins 4 cas documentés de « deux implémentations indépendantes pour le même besoin » (Immobilier ×2 avant M6, tracking GPS, moteurs de tarification livraison, back-offices admin).
- Aucune Cloud Function n'a de test « golden path » exécuté sur émulateur réel dans cet environnement — vérifié uniquement par `node -c`/`require()`/tests unitaires avec fausse base Firestore.

---

# CHAPITRE 2 — Architecture complète

## Flutter
Structure réelle de `lib/` : `screens/` (115 fichiers, 16 sous-dossiers par rôle), `widgets/` (14, dont un vrai kit de composants partagés `glass_kit.dart`), `services/` (31), `providers/` (1 fichier au niveau racine — `az_ia_provider.dart` — plus 3 providers vivant dans leurs modules `marketplace/`/`ekbine/`), `models/` (13), `theme/`, `l10n/`, `constants/`, `utils/`, `web/` (22 fichiers, application web **entièrement séparée**, son propre routeur `go_router` et son propre thème), et deux modules déjà organisés par feature (`marketplace/`, `ekbine/`, chacun avec ses propres `screens/services/providers/models`) — modèle explicitement documenté comme la cible pour tout nouveau module transverse.

## Firebase
- **Firestore** : ~76 collections top-level identifiées dans `firestore.rules` (détail Chapitre 6/Annexe C).
- **Storage** : règles avec posture par défaut-refus, validation systématique de type/taille par chemin d'upload.
- **Authentication** : Firebase Anonymous par défaut pour les clients mobiles (upgrade optionnel email/mot de passe), email/mot de passe + 2FA SMS conditionnelle pour les admins ; **les pharmacies utilisent un système d'authentification Firestore custom** (`pharmacie_credentials`, pas Firebase Auth) — seule exception connue au modèle standard.
- **Cloud Functions** : 57 fonctions déployées (v2, `europe-west1`, Node 20), confirmées **actives et cohérentes avec le code à 100 %** au 2026-07-15 (Master Prompt 122). Détail complet Chapitre 5/Annexe B.
- **Cloud Run** : couche d'exécution sous-jacente des Cloud Functions v2. Quota CPU régional audité et optimisé au Master Prompt 122 (`Σ(cpu×maxInstances)` réduit de 168 à 119,5 sur les fonctions non critiques).
- **Cloud Scheduler** : 6 fonctions `onSchedule` (nettoyage/réconciliation/expiration — Chapitre 5).
- **Notifications** : Cloud Messaging (FCM), 22 triggers Firestore `notify*` déclenchant des push ciblés (client/livreur/agent/admin selon l'événement).

## Architecture IA
Voir Chapitre 4 (dédié). Résumé : `functions/azia/` — module autonome, boucle d'appel Claude avec tool-calling (plafond 6 tours), mémoire utilisateur (`ai_user_memory`), historique de conversation (`ai_conversations`), confirmation financière serveur (`ai_pending_actions`), réponses structurées par type de carte (`responseBuilder.js`), mode hors ligne côté client, voix premium (`lib/services/voice/`).

## Diagramme logique (texte, faute de rendu graphique dans ce document)

```
[Flutter Mobile/Web]
     │  (Provider: MpProvider, MpFavoritesProvider, EkProvider, AzIaProvider)
     ▼
[Services Flutter]  ──(lecture directe legacy)──▶ [Firestore] ◀── [Firestore Rules]
     │
     ▼ (httpsCallable)
[Cloud Functions v2 / Cloud Run, europe-west1]
     │
     ├──▶ [Firestore] (Admin SDK, contourne les règles)
     ├──▶ [Cloud Storage]
     ├──▶ [FCM] (push notifications)
     ├──▶ [FeexPay API] (paiement mobile money)
     └──▶ [Anthropic API] (Claude, AZ IA uniquement)

[Cloud Scheduler] ──(cron)──▶ [Cloud Functions onSchedule] (nettoyage/expiration/réconciliation)
[Firestore onDocumentCreated/Updated] ──▶ [Cloud Functions triggers] ──▶ [FCM]
```

## Flux des données (exemple représentatif — création + livraison d'une commande)
1. Client crée une commande → écriture directe Firestore (`orders`, legacy) **ou** via un outil AZ IA (Cloud Function, serveur).
2. Trigger `notifyDriversOnNewOrder`/`enforceOrderRateLimit` réagissent à la création.
3. `dispatchOrderToDriver` (Cloud Function) calcule le livreur le plus proche (distance à vol d'oiseau, GeoHash, rayon 2 km puis 5 km) et assigne/diffuse.
4. Livreur accepte (transaction Firestore directe, sécurisée par règles + revérification serveur de son éligibilité).
5. Livraison confirmée → `deliverOrderCF` (Cloud Function) crédite le partenaire/livreur selon le mode de paiement, dans une transaction Firestore atomique.
6. Triggers `notifyClientOnOrderUpdate`/`notifyDriverOnMissionEnd` envoient les push correspondants.

---

# CHAPITRE 3 — Modules

Pour chaque module : Description / État / Fonctionnalités / Acteurs / Écrans / Collections / Cloud Functions / Services / Providers / Modèles / Permissions / Flux utilisateur / Limites / Dette technique / Améliorations possibles / Maturité / Note.

## 3.1 Livraison
**Description** : livraison de colis/courses point à point, cœur historique de l'app.
**État** : **OPÉRATIONNEL**.
**Fonctionnalités** : création de commande, dispatch automatique (2 km puis 5 km), suivi temps réel, preuve de livraison photo + GPS, paiement wallet/cash, annulation, historique.
**Acteurs** : Client, Livreur, Admin.
**Écrans** : `livraison_screen.dart`, `create_order.dart`, `suivi_commande.dart`, `order_wait_screen.dart`, `order_tracking_map.dart`, `customer_tracking_screen.dart`, `driver_dashboard.dart`, `courses_disponibles.dart`, `admin_orders.dart`, `admin_map.dart`, `admin_live_tracking_page.dart`.
**Collections** : `orders`, `dispatch_metrics`, `zones_livraison`.
**Cloud Functions** : `dispatchOrderToDriver`, `cancelOrderCF`, `deliverOrderCF`, `payOrderFromWalletCF`, `autoExpireOrders`, `enforceOrderRateLimit`, 8 triggers `notify*` liés à `orders`.
**Services** : `firestore_service.dart`, `delivery_service.dart`, `tarif_service.dart`, `tracking_service.dart`/`realtime_tracking_service.dart` (dupliqués, voir Dette).
**Providers** : aucun dédié (StreamBuilder direct sur Firestore).
**Modèles** : `order_model.dart`.
**Permissions** : state machine stricte dans `firestore.rules` (`pending→broadcast/assigned→accepted→picked_up→delivered`, ou `cancelled`), 3 branches de transition avaient des failles de sécurité corrigées au Master Prompt 80 (auto-assignation client, falsification `driverId`/`status` par un tiers).
**Flux utilisateur** : commande → recherche livreur (élargissement progressif de rayon) → acceptation → collecte → livraison → preuve photo → paiement → notation.
**Limites** : tarification calculée **côté client uniquement** (`TarifService`, jamais revalidée serveur pour les 5 écrans Flutter directs) — un client modifié pourrait en théorie soumettre un prix manipulé ; le dispatch ne pondère que la distance (pas de score multi-critères : taux d'acceptation, note, ancienneté) ; distance à vol d'oiseau, pas de routage réel au moment du dispatch (coût Google Directions).
**Dette technique** : 2 moteurs de tarification historiquement divergents (`TarifService` vs `DeliveryService`, unifiés au Master Prompt 51 sur `TarifService` comme source officielle) ; 2 services de tracking GPS dupliqués (`TrackingService`/`RealtimeTrackingService`), jamais fusionnés ; champ `deliveryLatitude`/`deliveryLongitude` à sémantique incohérente selon le type de commande (documenté, pas corrigé, champ inerte).
**Améliorations possibles** : score de dispatch multi-critères, tarification server-side, OTP/signature de livraison, réattribution automatique sur perte de connexion du livreur, priorités/livraison programmée.
**Maturité** : élevée (module le plus audité et corrigé de tout le projet).
**Note** : **82/100**.

## 3.2 Courses (achats libres)
**Description** : variante de la livraison pour des achats en magasin par le livreur (« 100f de tomates, 200f de piment... »).
**État** : **PARTIELLEMENT IMPLÉMENTÉ**.
**Fonctionnalités** : description libre + budget consolidé ; items structurés (`items[]`) ajoutés de façon additive pour AZ IA (Master Prompt M4) mais le workflow de négociation prix réel/remplacement/photo n'existe pas.
**Acteurs** : Client, Livreur.
**Écrans** : `courses_screen.dart`, `courses_libres.dart`, `courses_disponibles.dart` (livreur).
**Collections** : `orders` (même collection que Livraison, `type='shopping'`).
**Cloud Functions** : `create_shopping_order` (outil AZ IA), partage le reste avec Livraison.
**Modèles** : `shopping_item.dart`, `shopping_request.dart`.
**Limites** : pas de confirmation de prix réel par article, pas de photo, pas de proposition de remplacement, une seule catégorie par commande (pas de mélange marché/boutique/pharmacie).
**Dette technique** : aucune capacité de négociation livreur↔client, jamais planifiée dans les jalons M0→M8.
**Améliorations possibles** : workflow de négociation complet (chantier non scopé à ce jour).
**Maturité** : moyenne.
**Note** : **58/100**.

## 3.3 Restaurant
**État** : **OPÉRATIONNEL** pour la gestion établissement, **PARTIELLEMENT IMPLÉMENTÉ** pour la découverte.
**Fonctionnalités** : gestion menu (ajout/édition/stock/disponibilité), commandes, stats de vente 7 jours, wallet, abonnement standard/VIP.
**Acteurs** : Client, Restaurateur, Livreur, Admin.
**Écrans** : `restaurant_menu.dart`, `restaurant_list.dart`, `restaurant_owner_dashboard.dart`, `restaurant_owner_login.dart`, `restaurant_register.dart`, `admin_restaurants_page.dart`, `admin_restaurant_requests_page.dart`.
**Collections** : `restaurants`, `restaurant_requests`, `restaurant_owners`, `orders` (`type='restaurant'`).
**Cloud Functions** : `create_restaurant_order` (outil AZ IA), `notifyRestaurantOnOrder`, `deliverOrderCF` (crédit partenaire).
**Permissions** : `restaurants/{id}/menu/{menuId}` conditionné à l'existence de `restaurant_owners/{uid}`.
**Limites** : découverte par nom d'établissement uniquement (pas de recherche par plat), pas de sous-catégories (fast-food/maquis/pâtisserie), notation établissement non alimentée (le champ existe, l'UI ne l'utilise que pour le livreur), pas de variantes de menu (taille/pimenté/suppléments).
**Dette technique** : double-crédit wallet (corrigé Master Prompt 46) — un restaurant était crédité deux fois pour une commande créée par AZ IA.
**Maturité** : élevée côté gestion, faible côté découverte.
**Note** : **71/100**.

## 3.4 Marketplace (Djassa-like, occasion)
**État** : **OPÉRATIONNEL** pour l'essentiel, structurellement limité par conception (pas de panier).
**Fonctionnalités** : recherche/filtre produits, favoris, messagerie acheteur↔vendeur (texte + vocal), signalement d'abus, 0 % de commission (le vendeur reçoit 100 %, monétisation par abonnement).
**Acteurs** : Client (acheteur), Vendeur, Admin.
**Écrans** : `lib/marketplace/screens/*` (mp_home_screen, mp_add_product, mp_product_detail, mp_chat_page, mp_favorites...).
**Collections** : `marketplace_products`, `marketplace_favorites`, `marketplace_chats`, `marketplace_reports`, `orders` (`sellerType='seller'`).
**Cloud Functions** : `create_marketplace_order` (outil AZ IA).
**Providers** : `MpProvider`, `MpFavoritesProvider`.
**Modèles** : `lib/marketplace/models/mp_product.dart` (et consorts).
**Limites** : pas de panier multi-articles/multi-vendeurs, pas de checkout unifié, pas d'avis/notes, pas de profil boutique riche (logo/bannière/horaires), catégories codées en dur (pas Firestore), pas de modération admin dédiée, pas de statut « vendu » (un article à exemplaire unique peut être commandé plusieurs fois via AZ IA — documenté, non corrigé, risque d'intégrité vendeur pas de sécurité).
**Dette technique** : palette de couleurs dupliquée (`mp_constants.dart`), repointée vers `AppColors` au Master Prompt 120.
**Maturité** : bonne pour un marketplace pair-à-pair minimal, loin d'une place de marché complète.
**Note** : **68/100**.

## 3.5 Boutique (AZ Boutique — vendeur unique administré)
**État** : **OPÉRATIONNEL**, mais entièrement piloté par l'admin (pas de compte vendeur).
**Fonctionnalités** : achat wallet ou cash, gestion produits/stock par l'admin, remboursement automatique après 48h sans livraison.
**Acteurs** : Client, Admin, Livreur (livraison uniquement).
**Écrans** : `boutique_page.dart`, `admin_boutique_page.dart`, `admin_cash_settlement_page.dart`.
**Collections** : `boutique_products`, `boutique_orders`, `orders` (trajet de livraison séparé, `type='boutique'`).
**Cloud Functions** : `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`.
**Limites** : deux documents distincts pour une seule commande (le paiement produit dans `boutique_orders`, le trajet de livraison dans `orders`) — source de plusieurs bugs historiques déjà corrigés (remboursement fantôme, double-écriture stock/commande).
**Dette technique** : **5 bugs financiers/fonctionnels réels trouvés et corrigés sur ce seul module** (Master Prompts 28, 46, 48, 48bis, 54) — le module le plus corrigé après Livraison. Traçabilité du cash produit remis au marchand ajoutée au Master Prompt 76.
**Maturité** : élevée après correctifs, architecture à 2 documents reste fragile par conception.
**Note** : **75/100**.

## 3.6 Pharmacie
**État** : **PARTIELLEMENT IMPLÉMENTÉ** (gestion basique, catalogue produit absent).
**Fonctionnalités** : commande texte libre, garde/disponibilité, tableau de bord partenaire (statut/commandes), auto-inscription + approbation admin.
**Acteurs** : Client, Pharmacien, Livreur, Admin.
**Écrans** : `pharmacie_garde.dart`, `pharmacie_dashboard.dart`, `pharmacie_login.dart`, `pharmacie_register.dart`, `pharmacie_change_password.dart`.
**Collections** : `pharmacies`, `pharmacie_requests`, `pharmacie_credentials`, `orders` (`type='pharmacie'`).
**Cloud Functions** : `pharmacieLogin`, `setPharmaciePassword`, `create_pharmacie_order` (outil AZ IA), `notifyPharmacieOnOrder`.
**Limites** : pas de catalogue produit, pas de téléversement d'ordonnance, montant des médicaments réglé après coup (paiement en 2 temps : frais de livraison à la création, montant réel après livraison).
**Dette technique** : authentification par mot de passe en clair dans Firestore (`pharmacie_credentials`) — vulnérabilité connue et documentée, hachage ajouté progressivement mais migration complète non terminée ; bug de double-paiement (livraison payée deux fois) trouvé et corrigé (audit financier strict 2026-07-09). Flux d'inscription était **structurellement cassé à 100 %** (règle Firestore incompatible) jusqu'au Master Prompt 74.
**Maturité** : moyenne.
**Note** : **60/100**.

## 3.7 Boulangerie
**État** : **OPÉRATIONNEL** pour le socle, similaire à Restaurant en plus simple.
**Fonctionnalités** : commande simple + gâteau personnalisé, tableau de bord, abonnement.
**Écrans** : `boulangerie_dashboard.dart`, `boulangerie_login.dart`, `boulangerie_register.dart`, `boulangerie_order_page.dart` (client).
**Collections** : `boulangerie_requests`, `boulangeries`, `orders` (`type='boulangerie'`).
**Cloud Functions** : `notifyBoulangerieOnNewOrder`.
**Maturité** : correcte, jamais identifiée comme source de bug majeur.
**Note** : **70/100**.

## 3.8 Immobilier
**État** : **PARTIELLEMENT IMPLÉMENTÉ**, avec une complication architecturale sérieuse.
**Fonctionnalités** : recherche/annonces (agents vérifiés), demande de visite (workflow `pending→proposed→confirmed/declined/cancelled`), approbation admin des agents.
**Acteurs** : Client, Agent immobilier, Admin.
**Écrans** : `immobilier_home_screen.dart`, `listing_detail_screen.dart`, `agent_dashboard_screen.dart`.
**Collections** : `real_estate_agents`, `real_estate_agent_requests`, `real_estate_listings`, `real_estate_visit_requests`, `real_estate_categories` (déclarée, **jamais utilisée** — code mort, catégories codées en dur côté client comme Marketplace).
**Cloud Functions** : `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `notifyAgentOnVisitRequest`, `notifyClientOnVisitUpdate`.
**Modèles** : `real_estate_agent.dart`, `real_estate_listing.dart`, `real_estate_visit_request.dart`.
**Limites majeures** : **3 systèmes immobiliers coexistent dans l'app** (`locations`/`LocationsPage`, `residences`/`ResidencesPage`, `real_estate_listings`/module Immobilier M6) — chacun avec son propre modèle de permission et son propre catalogue, aucun lien croisé. AZ IA (`search_real_estate`) n'interroge que le 3ᵉ système, le plus récent et probablement le moins peuplé — un utilisateur peut recevoir « aucun bien disponible » d'AZ IA alors que le dashboard affiche des annonces bien réelles ailleurs. Pas de photos/vidéos dans le formulaire agent.
**Dette technique** : consolidation des 3 systèmes documentée et proposée (2 options), jamais tranchée par l'utilisateur — décision produit en attente.
**Maturité** : faible à moyenne, chantier de consolidation nécessaire avant scale.
**Note** : **52/100**.

## 3.9 E-Kbine (moto-taxi / services mobile money)
**État** : **OPÉRATIONNEL**.
**Fonctionnalités** : recharge/retrait mobile money via agent physique (Orange/MTN/Moov/Wave), 0 % de commission (l'agent gagne sur sa marge opérateur — règle produit non négociable, `project_ekbine_no_fee`), suivi et confirmation de commande, chat livreur↔client.
**Acteurs** : Client, Agent E-Kbine, Admin.
**Écrans** : `lib/ekbine/screens/*` (ek_home_screen, ek_order_form, ek_order_tracking, ek_agent_dashboard, ek_agent_register...).
**Collections** : `ekbine_agents`, `ekbine_orders`, `ekbine_chats`.
**Cloud Functions** : `ekClientConfirmOrder`, `create_ekbine_order`/`track_ekbine_order` (outils AZ IA), 6 triggers `notify*Ek*`.
**Providers** : `EkProvider`.
**Permissions** : state machine dédiée, statuts source/cible explicites par transition (jugée mieux scopée que celle de `orders` lors de l'audit sécurité MP80).
**Limites** : identité de sous-marque propre (vert), volontairement non alignée sur la palette orange principale (décision explicite au MP120).
**Maturité** : élevée.
**Note** : **80/100**.

## 3.10 Wallet
**État** : **OPÉRATIONNEL**, avec une dette de vocabulaire connue.
**Fonctionnalités** : solde par rôle (champ scalaire, pas un ledger comptable dédié), historique de transactions append-only pour les non-admins, réconciliation automatique hebdomadaire.
**Collections** : `wallet_transactions` (top-level + sous-collections par utilisateur), `wallet_reconciliation_findings`, `recharge_requests`, `withdrawal_requests`.
**Cloud Functions** : `initiateFeexPayPayment`, `initiateWithdrawal`, `payOrderFromWalletCF`, `feexPayWebhook`, `walletReconciliationCheck` (scheduler hebdomadaire).
**Limites** : **5+ vocabulaires de statut incohérents** entre modules (jamais unifiés, refus explicite de la refonte en « Grand Livre » comptable proposée au Master Prompt 28 — risque jugé trop élevé sur des soldes réels) ; pas de remboursement partiel (toujours total) ; pas de suspension de compte client pour fraude.
**Dette technique** : **le poste le plus corrigé du projet** — au moins 9 bugs financiers critiques trouvés et corrigés rien que sur les flux wallet/paiement (doubles crédits, remboursements fantômes, plafond anti-solde-négatif manquant).
**Maturité** : élevée en pratique (bugs corrigés), mais l'architecture reste un ensemble de champs scalaires, pas un système comptable formel.
**Note** : **78/100**.

## 3.11 Paiements
Voir Chapitre 9 (dédié).
**État global** : **OPÉRATIONNEL** (FeexPay + cash), webhook authentifié/idempotent/anti-rejeu.
**Note** : **80/100**.

## 3.12 AZ IA
Voir Chapitre 4 (dédié).
**État global** : **OPÉRATIONNEL** pour le cœur (chat, outils, confirmation, mémoire, voix), **PARTIELLEMENT IMPLÉMENTÉ** pour la couverture Immobilier croisée et le multilingue.
**Note** : **83/100**.

## 3.13 Administration
**État** : **OPÉRATIONNEL** pour les opérations, **PARTIELLEMENT IMPLÉMENTÉ** pour le reporting unifié.
**Fonctionnalités** : ~38 écrans admin (le plus gros module de l'app), gestion commandes/wallet/zones/dispatch/sécurité/sous-admins, RBAC par section (`admins/{uid}.permissions`).
**Limites majeures** : **le RBAC par section n'est appliqué nulle part dans `firestore.rules`** — un sous-admin actif a en réalité le même accès Firestore complet qu'un admin, seul le filtrage d'écrans côté Flutter le limite visuellement (gap de moindre-privilège documenté, non corrigé). Pas de dashboard unifié multi-verticales (chaque métrique reste dans son propre écran). Un second « Web Admin » existe en parallèle (`lib/web/pages/admin/`), scope différent (leads/SOS), pas un doublon fonctionnel une fois audité.
**Dette technique** : suspension de compte disponible pour les livreurs classiques (ajoutée MP77) et agents E-Kbine, mais pas pour les clients ni la plupart des autres rôles partenaires.
**Maturité** : élevée opérationnellement, RBAC réel à construire.
**Note** : **70/100**.

## 3.14 Notifications
**État** : **OPÉRATIONNEL** pour le push, **NON IMPLÉMENTÉ** pour les préférences utilisateur.
**Fonctionnalités** : push FCM sur 22 événements Firestore, centre de notifications persistant (`clients/{uid}/notifications`), nettoyage hebdomadaire des tokens invalides.
**Limites** : pas de préférences (types/horaires de silence/langue), pas d'outil de diffusion admin, pas de canal email/SMS, un seul jeton FCM par compte (perd les push sur un ancien appareil après connexion sur un nouveau).
**Note** : **65/100**.

## 3.15 Authentification
**État** : **OPÉRATIONNEL**, avec une exception notable (pharmacies).
Voir Chapitre 8 pour le détail sécurité. RBAC par appartenance de collection (pas de champ `role` unique + custom claims).
**Note** : **75/100**.

## 3.16 Profils
**État** : **OPÉRATIONNEL** pour Client (suppression de compte avec ré-authentification), **PARTIELLEMENT IMPLÉMENTÉ** pour les 8 autres rôles (déconnexion/demande de suppression génériques ajoutées MP69-70, mais pas d'édition de profil).
**Note** : **60/100**.

## 3.17 Favoris
**État** : **PARTIELLEMENT IMPLÉMENTÉ** — existe uniquement pour Marketplace (`marketplace_favorites`). Aucun favori pour restaurants/pharmacies/prestataires/adresses au niveau plateforme (les « adresses nommées » d'AZ IA, `ai_user_memory.addresses[]`, sont un mécanisme distinct, propre à la mémoire IA).
**Note** : **40/100**.

## 3.18 Chat
**État** : **OPÉRATIONNEL** pour Client↔Livreur et Marketplace acheteur↔vendeur, **NON IMPLÉMENTÉ** pour Client↔Restaurant/Pharmacie.
**Collections** : `chats`/`messages`, `marketplace_chats`, `ekbine_chats`.
**Note** : **62/100**.

## 3.19 Historique
**État** : **OPÉRATIONNEL** (commandes, wallet, notifications, conversation AZ IA — celle-ci effaçable manuellement par l'utilisateur depuis MP33). Pas d'expiration automatique de l'historique de conversation IA.
**Note** : **68/100**.

## 3.20 Recherche
**État** : **PARTIELLEMENT IMPLÉMENTÉ** — architecture à 3 niveaux pour les adresses (Firestore local → Nominatim → Google Places), mais recherche produit/restaurant limitée au nom d'établissement, pas de recherche par plat/produit transverse.
**Note** : **58/100**.

## 3.21 GPS / Cartographie
**État** : **OPÉRATIONNEL**, déjà bien optimisé.
Throttle GPS livreur (5s + 15m), ForegroundService Android, cache de routage (grille 100m/TTL 5min), Nominatim en priorité sur Google (maîtrise de coût suite à l'incident documenté `project_maps_cost_audit`).
**Note** : **80/100**.

## 3.22 Statistiques / Rapports
**État** : **PARTIELLEMENT IMPLÉMENTÉ** — `admin_geo_stats_page.dart`/`admin_drivers_ranking.dart` calculent zones/routes/heures de pointe/classement livreur, **côté client, sur les commandes brutes non paginées** (risque de coût de lecture croissant avec le volume, documenté MP79). Pas de rapport périodique généré, pas d'export CSV/PDF, pas de détection d'anomalie business, pas d'analytics AZ IA agrégée (les données brutes existent, rien ne les agrège).
**Note** : **45/100**.

---

# CHAPITRE 4 — AZ IA (documentation complète)

**Architecture** : module `functions/azia/` — `index.js` (boucle principale `azIaChat`), `claudeClient.js` (SDK Anthropic, `SYSTEM_PROMPT` avec cache de prompt), `conversationStore.js` (lecture/écriture `ai_conversations`), `toolRegistry.js` (registre nom→schéma/handler/confirmation requise), `pendingActions.js` (mécanique de confirmation partagée), `contextBuilder.js` (contexte utilisateur enrichi), `responseBuilder.js` (réponses structurées par carte), `reminderScheduler.js`, `AIProviderService.js` (cache/quota, multi-fournisseurs en embryon), `tools/*.js` (delivery, courses, wallet, marketplace, restaurants, pharmacies, immobilier, support, memory, reminders, ekbine).

**Mémoire** : `ai_user_memory/{uid}` — nom/prénom/surnom/langue/adresse/quartier/ville/moyen de paiement/favoris/carnet d'adresses nommées (`addresses[]`, fusion par label). **OPÉRATIONNEL**, vérifié en production (une adresse mémorisée est bien réutilisée sans re-demande).

**Contexte** : `buildUserContext()` assemble avant chaque tour — profil, mémoire, position GPS best-effort (jamais de demande de permission depuis le chat), dernière commande réelle, vendeur fréquent (seuil ≥3/10 dernières commandes), solde wallet faible (<500 FCFA). **OPÉRATIONNEL**, non mis en cache (varie par utilisateur).

**Prompt système** : français, statique (`SYSTEM_PROMPT_BLOCKS`, mis en cache côté Anthropic via `cache_control: ephemeral`). Règles non négociables encodées en dur : ne jamais inventer, toujours confirmer les actions sensibles, ne jamais redemander une info déjà connue.

**Tool Registry** : ~19-20 outils recensés (recherche/lecture : `track_order`, `get_wallet_balance`, `get_wallet_transactions`, `search_marketplace`, `search_real_estate`, `track_ekbine_order` ; écriture confirmée : `create_delivery_order`, `create_shopping_order`, `create_restaurant_order`, `create_pharmacie_order`, `create_marketplace_order`, `create_ekbine_order`, `request_property_visit`, `initiate_wallet_recharge`, `cancel_order` ; non-financiers silencieux : `remember_user_info`, `remember_named_address`, `create_reminder`, `create_support_ticket`). Administration : **NON IMPLÉMENTÉ** (aucun outil IA d'administration, périmètre explicitement hors feuille de route M0→M8 actuelle).

**Tool Calls** : boucle multi-tours (plafond 6), plusieurs blocs `tool_use` par tour déjà supportés nativement par Claude (multi-intention en un seul message).

**Confirmations** : `ai_pending_actions/{id}` (uid, toolName, toolInput, summaryFr, amount, status, expiresAt à 5 min), `aiConfirmAction` (onCall) revalide dans une transaction Firestore, empêche le replay. Côté Flutter : `_PendingActionCard` alimentée par `streamLatestPendingAction()` (2 filtres d'égalité, sans `orderBy`, pas de nouvel index requis). **OPÉRATIONNEL**, vérifié bout en bout en production (Master Prompts 113-115).

**Rappels** : `ai_reminders`, outil `create_reminder`, scheduler `aiSendDueReminders` (15 min) envoyant un push FCM. **OPÉRATIONNEL**.

**Mode hors ligne** : `AzIaOfflineEngine` (correspondance par mots-clés côté client), déclenché par `connectivity_plus` avant même de tenter l'appel réseau. **OPÉRATIONNEL** (mécanisme différent volontairement des réponses en ligne — pas un contournement de la règle « pas d'heuristique », un besoin honnêtement différent puisqu'aucune donnée serveur n'est interrogeable hors ligne).

**Voix** : `lib/services/voice/` — `VoiceProvider` (interface), `AndroidTtsProvider` (niveau 1 gratuit, sélection auto du meilleur moteur/voix, débit 0.48), `GoogleCloudTtsProvider`/`OpenAiTtsProvider`/`ElevenLabsProvider` (niveau 2, stubs prêts, `isAvailable:false`, aucune clé API), `VoiceManager` (nettoyage markdown/emoji, segmentation en phrases avec pauses). Reconnaissance vocale : `speech_to_text`, déjà utilisée en production ailleurs avant AZ IA. **OPÉRATIONNEL** pour le niveau 1, **NON IMPLÉMENTÉ** pour le niveau 2 (IA).

**Réponses structurées** : enveloppe `{type, title, message, icon, color, priority, actions, payload}` (`responseBuilder.js`), ~30 types possibles, dérivés déterministiquement de l'outil réellement exécuté (jamais d'un mot-clé re-parsé). Compatibilité descendante testée (repli `type:'generic'`).

**Cartes** : `az_ia_response_widgets.dart` — 11 widgets spécialisés (`WalletCard`, `PaymentCard`, `DeliveryCard`, `TrackingCard`, `RestaurantCard`, `MarketplaceCard`, `PropertyCard`, `ConfirmationCard`, `SupportCard`, `NotificationCard`, `GenericBubble`), dispatchées uniquement sur `response.type`.

**Historique** : `ai_conversations/{uid}/messages` (~40 derniers messages), jamais purgé automatiquement — effaçable manuellement (`clearAiHistory`).

**Sécurité** : jamais d'accès Firestore direct depuis AZ IA, confirmation serveur systématique, rate-limit (`checkRateLimit`), audit (`logAudit`) sur chaque outil d'écriture, observabilité dédiée (`request_logs` — outils utilisés, tours, tokens, durée).

**Limites** : contexte enrichi limité (pas de « quel écran l'utilisateur regarde-t-il »), multilingue runtime **NON IMPLÉMENTÉ** (réponses toujours en français), Immobilier IA ne couvre qu'1 des 3 systèmes de biens.

**Roadmap** : dashboard admin IA construit (`admin_ai_dashboard.dart`, MP118) ; mode voix niveau 2 (IA) et multilingue restent les deux plus gros chantiers ouverts.

---

# CHAPITRE 5 — Cloud Functions

**57 fonctions actives** (`europe-west1`, Node 20, vérifié via `firebase functions:list` le 2026-07-15, cohérence 100 % avec le code). Détail complet en Annexe B. Répartition par déclencheur : 27 `callable`, 22 triggers Firestore (`onDocumentCreated`/`onDocumentUpdated`), 6 `scheduled`, 1 `https` (`feexPayWebhook`, webhook FeexPay externe).

**Classification de criticité** (établie et vérifiée réellement au Master Prompt 122) :
- **Critiques (14, jamais réduites en ressources)** : `azIaChat`, `aiConfirmAction`, `initiateFeexPayPayment`, `feexPayWebhook`, `initiateWithdrawal`, `payOrderFromWalletCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`, `cancelOrderCF`, `deliverOrderCF`, `dispatchOrderToDriver`, `ekClientConfirmOrder`, `enforceOrderRateLimit`.
- **Secondaires utilisateur (6)** : `resetAccountPassword`, `checkClientPhone`, `artisanLogin`, `pharmacieLogin`, `setPharmaciePassword`, `clearAiHistory`.
- **Notifications/admin secondaire (31)** : les 22 triggers `notify*`, `logAuthEvent`, `logAdminAuditEvent`, `createSubAdmin`, `deleteSubAdmin`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `submitRealEstateAgentRequest`, `submitServiceProviderApplication`.
- **Cron/maintenance (6)** : `aiCleanupExpiredPendingActions`, `aiSendDueReminders`, `autoExpireOrders`, `cleanupExpiredRateLimits`, `walletReconciliationCheck`, `fcmTokenCleanupCheck`.

**Performance/ressources** (état réel au 2026-07-15, après optimisation MP122) : mémoire 256MiB pour la quasi-totalité (512MiB pour `azIaChat` seule), `cpu:1` pour les fonctions critiques/secondaires/notifications, `cpu:0.5` pour 5 des 6 schedulers (le 6ᵉ, `autoExpireOrders`, reste à `cpu:1` par prudence financière), `maxInstances` réduit de 3 à 2 (secondaires/notifications) ou 1 (schedulers) selon le groupe, `minInstances:0` partout (aucune instance chaude, cold starts possibles).

**État** : les 57 fonctions sont **ACTIVE** en production, confirmé indépendamment du code par requête directe sur le projet.

Le détail nom-par-nom (type, déclencheur, description, criticité) est en **Annexe B** pour éviter la répétition — chaque module du Chapitre 3 référence déjà les fonctions qui lui appartiennent.

---

# CHAPITRE 6 — Firestore

**~76 collections top-level** identifiées dans `firestore.rules` (liste complète Annexe C). Regroupement par rôle :

- **Comptes par rôle** (pas de collection `users` unique) : `clients`, `livreurs`, `sellers`, `restaurants`, `pharmacies`, `boulangeries`, `ekbine_agents`, `real_estate_agents`, `fleet_owners`, `admins` (champ `role: 'super'|'sub'`).
- **Demandes d'approbation** : `driver_requests`, `seller_requests`, `restaurant_requests`, `pharmacie_requests`, `boulangerie_requests`, `real_estate_agent_requests`, `driver_applications`/`partner_applications` (leads pré-compte du site public, distincts des `*_requests` in-app).
- **Commandes** : `orders` (polymorphe, `type`/`sellerType`), `ekbine_orders`, `boutique_orders`.
- **Wallet/finance** : `wallet_transactions` (+ sous-collections par utilisateur), `wallet_reconciliation_findings`, `recharge_requests`, `withdrawal_requests`, `commissions`.
- **AZ IA** : `ai_conversations`, `ai_pending_actions`, `ai_user_memory`, `ai_reminders`, `ai_cache`, `ai_quotas`, `ai_usage`, `ai_daily_stats`, `ai_logs`.
- **Immobilier (3 systèmes distincts, voir 3.8)** : `real_estate_listings`/`real_estate_visit_requests`/`real_estate_categories` (mort) ; `locations` ; `residences`.
- **Marketplace** : `marketplace_products`, `marketplace_favorites`, `marketplace_chats`, `marketplace_reports`.
- **Sécurité/audit** : `audit_logs`, `security_events`, `rate_limits`, `invalid_fcm_tokens`, `request_logs`.
- **Support** : `support_tickets`, `contact_messages`, `sos_alerts`, `account_deletion_requests`.
- **Configuration** : `config`, `app_config`, `zones_livraison`.

**Sécurité générale** : collections sensibles systématiquement en `allow write: if false` (Cloud-Function-only) — `audit_logs`, `security_events`, `rate_limits`, `ai_conversations`, `ai_pending_actions`, `ai_reminders`. `wallet_transactions` append-only pour les non-admins. `config`/`marketplace_products` (actifs)/`real_estate_listings` (actifs) en lecture publique — décision produit assumée.

**Sous-collections notables** : `orders/{id}` n'a pas de sous-collection propre ; `wallet_transactions` en a une par utilisateur ; `marketplace_chats/{chatId}/messages`, `ekbine_chats/{orderId}/messages`, `ai_conversations/{uid}/messages`.

**Utilisation/relations** : détail exhaustif déjà maintenu dans `FIRESTORE_SCHEMA.md` (fichier séparé à la racine du dépôt, extrait directement de `firestore.rules`/`firestore.indexes.json`) — ce chapitre n'en duplique pas le contenu champ par champ, il en donne la structure de haut niveau.

---

# CHAPITRE 7 — Flutter

**Arborescence réelle** (226 fichiers `.dart` au total) :
```
lib/
  screens/       115 fichiers, 16 sous-dossiers (admin 38, client 26, ai 5, auth 8, driver 7...)
  widgets/       14 fichiers (dont glass_kit.dart, kit de composants partagé)
  services/      31 fichiers
  providers/     1 fichier racine (az_ia_provider.dart)
  models/        13 fichiers
  theme/         app_theme.dart (source de vérité design system)
  marketplace/   13 fichiers (screens/services/providers/models propres)
  ekbine/        11 fichiers (screens/services/providers/models propres)
  web/           22 fichiers (app web séparée, go_router, thème propre)
  l10n/, utils/, constants/
```
**Screens** : voir Annexe A pour la liste complète par module.
**Widgets** : `glass_kit.dart` (9 classes, dont 5 non consommées actuellement mais conservées comme kit de composants), `scale_button.dart`, `partner_account_sheet.dart`, `account_deletion_dialog.dart`, `stream_error_state.dart` (ajouté MP121, réutilisé sur 14 écrans).
**Providers** : 4 globaux enregistrés dans `MultiProvider` (`lib/main.dart`) — `MpProvider`, `MpFavoritesProvider`, `EkProvider`, `AzIaProvider` — plus 5 `ChangeNotifier` non-globaux (`TrackingService`, `RealtimeTrackingService`, 2 gestionnaires de session web, 1 `Listenable` de rafraîchissement `go_router`).
**Services** : 31 fichiers, voir Annexe E.
**Repositories** : `lib/repositories/` existe comme **dossier vide** — 3 repositories morts/dangereux (`WalletRepository`/`OrderRepository`/`UserRepository`) supprimés au Master Prompt 41 après avoir été jugés jamais utilisés et potentiellement dangereux s'ils l'avaient été (crédit wallet cross-user sans passer par Cloud Function). **NON IMPLÉMENTÉ** aujourd'hui — adoption prospective uniquement pour un futur module.
**Helpers/Extensions** : `lib/utils/helpers.dart` (utilitaires génériques), pas de fichier `.dart` d'extensions Dart dédié identifié séparément.
**Theme** : `AppColors`/`AppTypography`/`AppLayout`/`AppRadius`/`AppShadow`/`AppTransitions`/`AppTheme` (`light`+`dark`), refondu Master Prompt 120 — palette Tailwind-like, police Urbanist, mode sombre réel pour la chrome Material.
**Navigation** : mobile = `Navigator.push` direct + `AppTransitions` (pas de routeur nommé/`go_router`) ; web = `go_router` avec redirections/guards. Deux systèmes distincts, jamais unifiés (décision explicite).
**Architecture** : `StatefulWidget`/`setState`/`StreamBuilder` direct sur Firestore dans la majorité des écrans (121 fichiers avec accès Firestore direct confirmés au Master Prompt 41) — pas une architecture en couches strictes (pas de vrai repository pattern adopté), cohérent avec un projet qui a grandi organiquement plutôt que d'après un plan d'architecture initial rigide.

---

# CHAPITRE 8 — Sécurité

**Authentification** : Firebase Anonymous (clients, upgrade optionnel email/mdp), email/mdp + 2FA SMS conditionnelle (admins), authentification Firestore custom en clair puis partiellement hachée (pharmacies — vulnérabilité connue, migration non terminée).

**Permissions** : RBAC par appartenance de collection. Sous-admins ont un tableau `permissions` par section (`admins/{uid}.permissions`) — **jamais appliqué dans `firestore.rules`** (gap de moindre-privilège documenté et non corrigé : un sous-admin actif a un accès Firestore identique à un admin complet, seul le filtrage d'écran Flutter le limite visuellement).

**Firestore Rules** : posture globalement stricte, state machines explicites (`orders`, `ekbine_orders`), collections sensibles verrouillées CF-only. **3 failles réelles trouvées et corrigées au Master Prompt 80** : (1) `deliverOrderCF` pouvait créditer n'importe quel partenaire sans qu'un client n'ait payé (le bug le plus grave de toute la session) ; (2) un livreur pouvait forcer `isPaid:true` par écriture directe ; (3) un client pouvait s'auto-assigner n'importe quel livreur en contournant le dispatch. Les 3 corrigées, testées, redéployées.

**Storage Rules** : posture par défaut-refus, validation type/taille systématique. Selfies/pièces d'identité livreur/flotte lisibles par tout utilisateur authentifié (risque de visibilité documenté, non corrigé — arbitrage assumé).

**Cloud Functions** : `checkRateLimit`/`logAudit` réutilisés systématiquement sur les nouvelles fonctions sensibles. App Check : SDK client activé (Android Play Integrity, iOS DeviceCheck), **enforcement serveur jamais activé** (`enforceAppCheck` non utilisé, décision explicite pour ne pas casser les utilisateurs sur d'anciens builds).

**Paiements/Wallet** : voir Chapitre 9. Webhook FeexPay authentifié par secret, idempotent, anti-rejeu (fenêtre 24h).

**AZ IA** : jamais d'accès Firestore direct, confirmation serveur obligatoire pour toute action financière/destructrice.

**Audit** : `audit_logs`/`security_events` alimentés sur les actions sensibles (pas systématiquement sur 100 % des Cloud Functions — un `withObservability` générique existe mais reste sous-utilisé, documenté MP58).

**Risques résiduels connus, non corrigés, documentés explicitement** : RBAC sous-admin non appliqué en profondeur ; visibilité large de `livreurs.wallet` et des photos KYC ; `pharmacie_credentials` (mot de passe, migration hachage incomplète) ; App Check jamais réellement forcé côté serveur.

---

# CHAPITRE 9 — Paiements

**Moyens de paiement** : Orange Money, MTN MoMo, Moov Money, Wave (tous via FeexPay comme agrégateur unique), Wallet interne, Cash à la livraison.

**Flux** : `initiateFeexPayPayment` (recharge wallet) → webhook FeexPay (`feexPayWebhook`, authentifié par secret d'URL, idempotent, rejette les webhooks vieux de >24h) → crédit wallet dans une transaction Firestore. Retrait : `initiateWithdrawal`.

**Wallet** : champ scalaire par rôle (`clients/{uid}.wallet`, etc.), pas de ledger comptable en partie double formalisé (refus explicite de cette refonte au Master Prompt 28, jugée trop risquée sur des soldes réels). Historique append-only (`wallet_transactions`).

**Cash** : supporté pour Livraison, Boutique, Ekbine — traçabilité du cash produit remis au marchand ajoutée au Master Prompt 76 (`merchantCashSettled`), suivi admin dédié (`admin_cash_settlement_page.dart`).

**Commissions** : livreur uniquement pilotée par Firestore (`config/commission`, paliers 100/200 FCFA) ; Marketplace et Ekbine à 0 % (décisions produit assumées, pas des bugs).

**Sécurité** : transactions Firestore atomiques sur chaque mouvement, plafond anti-solde-négatif systématique après correction, anti-double-tap sur tous les boutons de paiement critiques identifiés, webhook idempotent.

**Historique documenté** : **11 bugs financiers critiques** trouvés et corrigés sur l'ensemble du projet (doubles crédits Restaurant/Marketplace, remboursement fantôme Boutique jamais fonctionnel, double-paiement pharmacie, faille de crédit partenaire sans paiement — la plus grave, MP80).

---

# CHAPITRE 10 — Expérience utilisateur (parcours)

**Client** : inscription (anonyme ou email/mdp) → recherche module (carte dashboard ou AZ IA) → commande → suivi temps réel → paiement → notation → historique.
**Livreur** : inscription + KYC (selfie + pièce d'identité) → approbation admin → mise en ligne → réception de commande (dispatch) → acceptation (revérification serveur d'éligibilité) → collecte → livraison (photo + GPS) → crédit wallet.
**Commerçant** (Restaurant/Pharmacie/Boulangerie/Vendeur) : inscription → approbation admin (sauf Marketplace, self-service direct) → gestion catalogue/menu → réception commande → wallet.
**Agent E-Kbine** : inscription → approbation → réception demande de recharge/retrait → confirmation avec preuve → crédit selon marge opérateur.
**Agent Immobilier** : inscription → approbation admin → publication d'annonce → réception demande de visite → proposition de date → confirmation.
**Administrateur** : connexion email/mdp + 2FA SMS conditionnelle → accès aux ~38 écrans selon permissions (non appliquées côté règles) → gestion opérationnelle complète.
**Sous-admin** : connexion identique, accès filtré côté UI par `permissions[]` (pas par les règles Firestore — voir Chapitre 8).

---

# CHAPITRE 11 — Performances

**Flutter** : pagination incohérente (un seul écran, `admin_orders.dart`, a une vraie pagination par curseur — le reste utilise des `.limit()` fixes) ; régression documentée sur le cache d'images (`Image.network` brut dans 24 fichiers au lieu de `CachedNetworkImage`, connue et volontairement non corrigée en masse) ; skeleton loading existant (`glass_kit.dart`) mais pas utilisé partout.
**Firestore** : la plupart des lectures à fort volume sont déjà bornées par `.limit()` ; `admin_geo_stats_page.dart`/`admin_drivers_ranking.dart` recalculent côté client sur des commandes non paginées (risque de coût croissant, documenté).
**Cloud Functions/Cloud Run** : quota CPU régional optimisé au Master Prompt 122 (168→119,5 sur les fonctions non critiques) ; aucune instance chaude (`minInstances:0` partout), cold starts possibles mais acceptés pour un trafic pilote.
**Images** : compression à l'upload déjà appliquée sur 26 points d'upload (`imageQuality`/`maxWidth`), mais l'affichage n'utilise pas systématiquement de cache disque.
**Cache** : cache Firestore natif (persistance 50 Mo) ; cache de routage GPS (grille 100m/TTL 5min) ; cache de prompt Anthropic (system prompt + dernier outil).
**Mémoire (fuites)** : audit exhaustif au Master Prompt 44 — un seul cas réel de fuite trouvé et corrigé (`agent_dashboard_screen.dart`, contrôleurs de formulaire jamais disposés), le reste de l'app est propre.
**Optimisations réalisées** : Google Maps (Nominatim-first, throttle Directions 120s), cache de prompt IA, réduction CPU Cloud Run (MP122).

---

# CHAPITRE 12 — Faisabilité (fonctionnalités restantes)

| Fonctionnalité | Faisabilité | Pourquoi | Coût | Complexité | Maintenance | Scalabilité |
|---|---|---|---|---|---|---|
| Consolidation des 3 systèmes Immobilier | ★★★☆☆ | Décision produit non tranchée, migration de données réelle nécessaire | Moyen | Moyenne | Faible une fois fait | Bonne |
| RBAC sous-admin réellement appliqué en règles | ★★★☆☆ | Nécessite une règle par collection sensible conditionnée sur `permissions[]` | Moyen | Élevée (risque de casser l'accès existant si mal fait) | Moyenne | Bonne |
| Tarification livraison server-side | ★★★★☆ | `TarifService` déjà porté en Node (`tarifService.js`) pour AZ IA, il « reste » à router les écrans Flutter dessus | Faible-moyen | Moyenne | Faible | Bonne |
| Panier Marketplace + checkout | ★★☆☆☆ | Changement de modèle produit complet (contact direct → achat structuré) | Élevé | Élevée | Moyenne | Bonne |
| Voix IA niveau 2 (ElevenLabs/Google Cloud TTS) | ★★★★☆ | Architecture déjà prête (`VoiceProvider`), ne manque qu'une Cloud Function de synthèse + clé API | Moyen (coût API récurrent) | Faible | Faible | Bonne |
| Multilingue runtime AZ IA | ★★☆☆☆ | System prompt français en dur, nécessite détection de langue + prompts localisés | Moyen | Moyenne | Moyenne | Bonne |
| Dashboard admin unifié multi-verticales | ★★★☆☆ | Données existent déjà par module, agrégation à construire | Moyen | Moyenne | Faible | Bonne |
| Multi-pays/multi-devises | ★☆☆☆☆ | FCFA et tarification centrée Abengourou codés en dur à des dizaines d'endroits | Élevé | Très élevée | Élevée | Nécessite refonte |
| Ledger comptable wallet (partie double) | ★★☆☆☆ | Refus déjà motivé (Master Prompt 28) — risque élevé sur des soldes réels | Élevé | Très élevée | Élevée | Bonne une fois fait |
| Détection d'anomalie business (BI) | ★★☆☆☆ | Aucune base de données/volume suffisant aujourd'hui pour un modèle fiable | Moyen-élevé | Élevée | Moyenne | Incertaine |

---

# CHAPITRE 13 — Roadmap

**Version actuelle (v1.0, ce document)** : plateforme mono-ville (Abengourou) fonctionnelle, 10 modules opérationnels à des degrés divers, AZ IA conversationnelle avec confirmation financière et voix niveau 1, 57 Cloud Functions en production, 234 tests backend.

**Version 2 (priorités courtes, déjà identifiées dans l'historique du projet)** : RBAC sous-admin réellement appliqué ; tarification livraison server-side ; consolidation Immobilier (décision produit requise) ; migration complète du hachage de mot de passe pharmacie ; App Check enforcement serveur (après période de rodage client).

**Version 3** : panier/checkout Marketplace ; voix IA niveau 2 ; dashboard admin unifié ; notation restaurant/pharmacie réellement alimentée ; préférences de notification utilisateur.

**Version 4** : multilingue runtime (AZ IA + UI) ; BI/détection d'anomalie avec volume suffisant ; ledger comptable formel si le volume de transactions le justifie.

**Évolutions possibles hors roadmap actuelle** : multi-pays/multi-devises (chantier pluriannuel, explicitement hors de portée actuelle) ; véhicules autonomes/drones (mentionnés dans des prompts précédents comme horizon 10 ans, aucune action requise aujourd'hui).

**Priorités** (déduites de la fréquence des correctifs documentés) : sécurité RBAC et tarification server-side en tête, car ce sont les deux gaps les plus directement exploitables restants.

---

# CHAPITRE 14 — Business

**Sources de revenus identifiées dans le code** :
- **Commission livreur** (Livraison/Courses) : 100-200 FCFA par palier (`config/commission`), seul flux avec une vraie commission plateforme.
- **Abonnements partenaires** : standard/VIP (1000-2000 FCFA/mois) pour restaurants/boulangeries, mécanisme de monétisation principal pour ces verticales puisque Marketplace/ces commerces ne prennent pas de commission sur les ventes.
- **Marketplace** : 0 % de commission par choix produit — monétisation exclusivement par abonnement vendeur (**PARTIELLEMENT IMPLÉMENTÉ** comme source de revenu, le mécanisme d'abonnement existe mais n'est pas spécifiquement documenté comme obligatoire pour vendre).
- **Immobilier** : aucun modèle de revenu identifié dans le code (pas de commission sur transaction, pas d'abonnement agent visible dans les Cloud Functions).
- **Wallet** : pas de frais sur les mouvements internes ; FeexPay applique ses propres frais côté agrégateur (non visibles côté AZ Express).
- **Publicité** : **NON IMPLÉMENTÉ** — recherche exhaustive confirmée (Master Prompt hardening Android) : aucun SDK publicitaire, `AD_ID` explicitement retiré du manifest Android.
- **Évolutivité du modèle de revenu** : dépend fortement de la levée du plafond mono-ville/mono-devise (Chapitre 1) avant toute expansion géographique.

---

# CHAPITRE 15 — Conclusion

**Forces majeures** : mécanisme de confirmation financière IA exceptionnellement robuste ; discipline d'audit et de correction rare (11+ bugs financiers réels trouvés et corrigés avec preuve) ; design system unifié et mode sombre réel ; suite de tests backend significative (234 tests) ; dispatch/tracking GPS déjà optimisés en coût.

**Faiblesses** : zéro test automatisé Flutter (hors voix) ; RBAC sous-admin non appliqué en profondeur ; 3 systèmes Immobilier non consolidés ; tarification livraison non revalidée serveur ; mono-ville/mono-devise en dur.

**Dette technique** : documentée de façon inhabituellement précise à chaque étape du projet (`CLAUDE.md`) — chaque duplication (tracking, tarification, Immobilier, back-offices) a une trace écrite de sa cause et de la décision de la corriger ou non.

**Risques** : sécurité RBAC sous-admin (le plus concret) ; visibilité large de données KYC/wallet (accepté, documenté) ; absence de tests Flutter (aucun filet de sécurité contre une régression UI).

**Opportunités** : socle AZ IA déjà assez mature pour absorber de nouveaux modules sans reconstruction ; architecture Cloud Functions déjà capable d'être étendue (57 fonctions actives, quota CPU désormais avec de la marge après le Master Prompt 122).

**Préparation à la production** : techniquement viable pour un pilote supervisé mono-ville — verdict déjà documenté dans `AUDIT_FINAL.md` (« READY PILOT EXTENDED »).
**Préparation investisseurs** : le document présent + `AUDIT_FINAL.md` donnent une vision honnête (forces ET limites chiffrées), plus utile à un investisseur sérieux qu'un document uniquement positif.
**Préparation partenaires** : modules commerçants (Restaurant/Pharmacie/Boulangerie/Boutique) suffisamment matures pour un onboarding réel, à condition d'accompagner les gaps connus (pas de catalogue produit pharmacie, pas de notation alimentée).
**Préparation franchise/expansion** : bloquée tant que le mono-ville/mono-devise n'est pas levé — c'est la plus grosse barrière structurelle à toute réplication géographique.

---

# ANNEXES

## Annexe A — Inventaire complet des écrans (115 fichiers)
Répartition par dossier : `admin/` 38, `client/` 26, `ai/` 5, `auth/` 8, `driver/` 7, `restaurant/` 5, `pharmacie/` 4, `boulangerie/` 3, `fleet/` 3, `immobilier/` 3, `seller/` 3, `artisan/` 2, `chat/` 2, `home/` 1, `pro/` 1, `support/` 1, plus les modules `marketplace/screens/` et `ekbine/screens/` organisés séparément. Liste exhaustive fichier par fichier disponible via `find lib/screens -name "*.dart"` — non dupliquée ligne par ligne ici pour éviter la redondance avec le système de fichiers lui-même.

## Annexe B — Inventaire des Cloud Functions (57)
**Callable (27)** : `initiateFeexPayPayment`, `initiateWithdrawal`, `resetAccountPassword`, `checkClientPhone`, `submitServiceProviderApplication`, `artisanLogin`, `pharmacieLogin`, `setPharmaciePassword`, `createSubAdmin`, `deleteSubAdmin`, `ekClientConfirmOrder`, `dispatchOrderToDriver`, `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`, `azIaChat`, `aiConfirmAction`, `clearAiHistory`, `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `logAuthEvent`, `logAdminAuditEvent`.
**Scheduled (6)** : `autoExpireOrders` (1 min), `cleanupExpiredRateLimits` (hebdo), `walletReconciliationCheck` (hebdo), `fcmTokenCleanupCheck` (hebdo), `aiCleanupExpiredPendingActions` (10 min), `aiSendDueReminders` (15 min).
**Firestore triggers (22)** : `notifyClientOnOrderCreated`, `notifyClientOnOrderUpdate`, `notifyBroadcastDrivers`, `notifyDriverOnAssigned`, `notifyDriverLowBalance`, `notifyDriverOnMissionEnd`, `notifyDriverOnOrderCancelled`, `notifyRestaurantOnOrder`, `notifyPharmacieOnOrder`, `notifyBoulangerieOnNewOrder`, `notifySellerOnOrder`, `notifyDriversOnNewOrder`, `notifyEkClientOnOrderCreated`, `notifyEkClientOnStatusChange`, `notifyEkAgentsOnNewOrder`, `notifyEkAgentOnAssigned`, `notifyEkAgentOnCompleted`, `notifyAdminsOnNewDriver`, `notifyAdminsOnNewServiceProvider`, `notifyClientOnRecharge`, `notifyAgentOnVisitRequest`, `notifyClientOnVisitUpdate`, plus `enforceOrderRateLimit` (trigger de garde, pas de notification).
**HTTPS (1)** : `feexPayWebhook`.
Détail ressources (mémoire/cpu/maxInstances/timeout) par fonction : voir Chapitre 5 et `CLAUDE.md` section Master Prompt 122 pour la table complète déjà produite.

## Annexe C — Inventaire des collections Firestore (~76)
Liste complète : `account_deletion_requests`, `admins`, `ai_cache`, `ai_conversations`, `ai_daily_stats`, `ai_logs`, `ai_pending_actions`, `ai_quotas`, `ai_reminders`, `ai_usage`, `ai_user_memory`, `app_config`, `audit_logs`, `blanchisserie_orders`, `boulangerie_requests`, `boulangeries`, `boutique_orders`, `boutique_products`, `chats`, `clients`, `commissions`, `config`, `contact_messages`, `delivery_reports`, `dispatch_metrics`, `driver_applications`, `driver_rankings`, `driver_requests`, `eau_boissons_orders`, `ekbine_agents`, `ekbine_chats`, `ekbine_orders`, `fleet_owners`, `invalid_fcm_tokens`, `livreurs`, `locations`, `marketplace_chats`, `marketplace_favorites`, `marketplace_products`, `marketplace_reports`, `orders`, `partner_applications`, `pharmacie_credentials`, `pharmacie_requests`, `pharmacies`, `places`, `rate_limits`, `real_estate_agent_requests`, `real_estate_agents`, `real_estate_categories`, `real_estate_listings`, `real_estate_visit_requests`, `recharge_requests`, `request_logs`, `residences`, `restaurant_owners`, `restaurant_requests`, `restaurants`, `reviews`, `security_events`, `seller_requests`, `sellers`, `service_providers`, `service_reviews`, `services`, `sos_alerts`, `support_tickets`, `wallet_reconciliation_findings`, `wallet_transactions`, `withdrawal_requests`, `zones_livraison`. Sous-collections notables déjà listées Chapitre 6.

## Annexe D — Inventaire des modèles Flutter (13)
`driver_earnings_summary.dart`, `driver_location_model.dart`, `driver_model.dart`, `feexpay_transaction.dart`, `local_place.dart`, `order_model.dart`, `real_estate_agent.dart`, `real_estate_listing.dart`, `real_estate_visit_request.dart`, `route_model.dart`, `service_provider_model.dart`, `shopping_item.dart`, `shopping_request.dart`. (Modèles supplémentaires propres aux modules : `lib/marketplace/models/`, `lib/ekbine/models/`.)

## Annexe E — Inventaire des Services Flutter (31, `lib/services/`)
`account_deletion_service.dart`, `audio_service.dart`, `auth_service.dart`, `az_ia_service.dart`, `call_service.dart`, `delivery_service.dart`, `driver_location_service.dart`, `driver_service.dart`, `feexpay_service.dart`, `firestore_service.dart`, `google_routes_service.dart`, `location_service.dart`, `notification_service.dart`, `payment_service.dart`, `places_search_service.dart`, `places_service.dart`, `pricing_service.dart`, `real_estate_service.dart`, `realtime_tracking_service.dart`, `send_notification_service.dart`, `subscription_service.dart`, `tarif_service.dart`, `tracking_service.dart`, `user_service.dart`, `wallet_service.dart` (+ `lib/services/voice/` : `voice_provider.dart`, `android_tts_provider.dart`, `google_cloud_tts_provider.dart`, `openai_tts_provider.dart`, `elevenlabs_provider.dart`, `voice_manager.dart`).

## Annexe F — Inventaire des Providers (9 `ChangeNotifier`)
Globaux (`MultiProvider`, `lib/main.dart`) : `MpProvider`, `MpFavoritesProvider`, `EkProvider`, `AzIaProvider`. Non-globaux : `TrackingService`, `RealtimeTrackingService`, `lib/web/admin_auth_service.dart`, `lib/web/web_client_auth.dart`, `lib/web/web_router.dart` (refresh listenable).

## Annexe G — Inventaire des dépendances pubspec.yaml (principales)
`firebase_core`, `cloud_firestore`, `firebase_auth`, `firebase_messaging`, `firebase_storage`, `cloud_functions`, `firebase_crashlytics`, `firebase_analytics`, `firebase_app_check`, `provider`, `go_router`, `google_fonts`, `google_maps_flutter`, `geolocator`, `geoflutterfire_plus`, `flutter_polyline_points`, `speech_to_text`, `flutter_tts`, `flutter_sound`, `record`, `audioplayers`, `image_picker`, `cached_network_image`, `connectivity_plus`, `shared_preferences`, `url_launcher`, `http`, `crypto`, `uuid`, `intl`, `permission_handler`, `path_provider`, `flutter_screenutil`, `flutter_animate`, `flutter_foreground_task`, `flutter_launcher_icons`, `flutter_native_splash`.

## Annexe H — Inventaire des packages npm (`functions/package.json`)
`@anthropic-ai/sdk` (^0.109.0), `axios` (^1.6.0), `firebase-admin` (^12.0.0), `firebase-functions` (^6.0.0).

## Annexe I — Inventaire des variables d'environnement (noms uniquement, jamais les valeurs)
**`functions/.env`** : `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` (vide), `GEMINI_API_KEY` (vide), `DEEPSEEK_API_KEY` (vide), `MISTRAL_API_KEY` (vide), `GROQ_API_KEY` (vide).
**`.env` racine (dart-define, config Firebase multi-plateforme, valeurs non secrètes par nature)** : `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, `FIREBASE_WEB_MEASUREMENT_ID`, `FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID`, `FIREBASE_IOS_API_KEY`, `FIREBASE_IOS_APP_ID`, `FIREBASE_IOS_BUNDLE_ID`, `FIREBASE_WINDOWS_API_KEY`, `FIREBASE_WINDOWS_APP_ID`, `FIREBASE_WINDOWS_MEASUREMENT_ID`.

## Annexe J — Glossaire
- **AZ IA** : assistant conversationnel de la plateforme (Claude/Anthropic).
- **CF** : Cloud Function.
- **Dispatch** : attribution automatique d'une commande à un livreur.
- **E-Kbine** : module de recharge/retrait mobile money via agent physique.
- **FeexPay** : agrégateur de paiement mobile money utilisé par la plateforme.
- **Groupe A/B/C/D** : classification de criticité des Cloud Functions (Master Prompt 122).
- **KYC** : vérification d'identité (selfie + pièce d'identité) des livreurs/flottes.
- **Pending Action** : action IA en attente de confirmation utilisateur (`ai_pending_actions`).
- **RBAC** : contrôle d'accès par rôle.
- **Wallet** : solde interne à la plateforme, par rôle.

---

*Fin — AZ EXPRESS TECHNICAL BIBLE, Version 1.0, 2026-07-16. Document de synthèse : aucune modification de code effectuée pour sa production. Toute mise à jour future doit revérifier chaque affirmation contre l'état réel du code, pas contre ce document lui-même (qui devient obsolète dès le prochain changement).*
