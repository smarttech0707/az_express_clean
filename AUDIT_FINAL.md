# AZ Express — Audit final avant mise en production

**Date** : 2026-07-03 (mise à jour Master Prompt 64 — « iOS App Store Release Preparation » — depuis la version Master Prompt 63)

**Ce qui a changé depuis la version du Prompt 63** : audit iOS complet — **verdict BLOCKED, plus sévère qu'Android** (blocage à la fois technique ET de contenu, contrairement à Android où seul le contenu bloquait). Trouvailles fondamentales : `ios/Podfile` n'a jamais existé (CocoaPods jamais intégré, confirmé par l'absence de `Pods.xcodeproj` dans le workspace) — ce projet n'a **jamais été buildé pour iOS** ; `GoogleService-Info.plist` absent (gitignored, jamais fourni) ; aucun fichier `.entitlements` (aucune capacité Xcode jamais activée) ; `flutter build ios` **structurellement impossible depuis cet environnement Windows** (Flutter retire le sous-commande `ios` sur un hôte non-macOS — testé directement, pas supposé). **Un correctif appliqué** : `Info.plist` n'avait que 2 des 6 déclarations de confidentialité requises par des fonctionnalités déjà existantes (caméra, position premier plan/arrière-plan, photothèque, modes arrière-plan) — sur iOS, l'absence de ces clés cause un **crash immédiat**, pas juste un refus de review ; les 4 clés manquantes + `UIBackgroundModes` ont été ajoutées (fonctionnalités déjà existantes rendues non-crashantes sur iOS, pas une nouvelle fonctionnalité). Bundle ID : trouvaille clé — `.env` contient déjà `FIREBASE_IOS_BUNDLE_ID: com.azexpress.app`, donnant une cible claire, mais non appliqué à Xcode (décision à confirmer, conformément à l'instruction explicite de ne pas changer sans vérifier l'impact Firebase/App Store réel).

**Ce qui a changé depuis la version du Prompt 62** : audit-only de la préparation release Android (aucun code modifié). **Verdict : BLOCKED — pas pour une raison technique** (le build Android fonctionne réellement : `flutter build appbundle --release` testé en conditions réelles, produit un vrai `app-release.aab` de 74,3 Mo, signature vérifiée de bout en bout puisque le build aurait échoué sans un keystore valide) **— mais pour 2 vraies trouvailles de conformité Play Store** : (1) la politique de confidentialité publique et les pages légales nomment "CinetPay" comme prestataire de paiement alors que le code réel utilise exclusivement FeexPay depuis le début de cette session — zéro trace de CinetPay dans `functions/` ; (2) la politique de confidentialité ne déclare jamais Anthropic/Claude comme tiers destinataire des données envoyées par AZ IA (texte + voix transcrite), un vrai gap de conformité "Data Safety" Play Console. Aucune des deux n'est corrigée dans cette passe (édition de contenu légal public, décision explicite requise). Nouveau risque documenté, sans rapport avec le Play Store : le SDK Flutter installé est sur le canal `beta` (3.45.0-0.1.pre), jamais signalé avant. Un avertissement de build non-fatal (symboles de debug non retirés) tracé à un problème d'environnement local (`cmdline-tools`/licences Android manquantes sur cette machine), pas un défaut du code.

**Ce qui a changé depuis la version du Prompt 61** : audit du pipeline CI/CD et de la préparation au build de release (Android/iOS/Web), sans aucun changement de code (prompt explicitement audit-only, scopé à CI/build/release safety). **Verdict : CI STATUS READY** — les 3 jobs existants (`flutter`, `functions`, `firestore-rules`) sont fonctionnels et sans YAML cassée. **Un vrai blocueur de release trouvé, spécifique à iOS** : `PRODUCT_BUNDLE_IDENTIFIER = com.example.azExpressClean` dans `ios/Runner.xcodeproj/project.pbxproj` est toujours le bundle ID par défaut de `flutter create` — bloque toute soumission App Store/TestFlight (Apple n'autorise pas `com.example.*`). Android, lui, a déjà un `applicationId` correctement branded (`com.azexpress.app`) et un build release fonctionnel (keystore + `key.properties` présents localement, correctement exclus de git). `flutter build web --release` testé réellement, réussit proprement. Aucun secret GitHub requis par la CI actuelle (aucun job de déploiement n'existe). Incohérence de version documentée : le tag git `v0.2-rc2` et la version applicative (`pubspec.yaml` : `1.0.0+1`, identique côté Android/iOS) ne se sont jamais synchronisés — deux schémas de version indépendants.

**Ce qui a changé depuis la version du Prompt 60** : RC2 est désormais committée, taguée (`v0.2-rc2`) et poussée vers GitHub (confirmé : `git status -sb` montre `master...origin/master` sans écart) — le point le plus urgent listé au Prompt 60 est résolu. Cette mise à jour est un audit de préparation au déploiement Firebase réel, sans aucun changement de code (prompt explicitement audit-only). Testé réellement (pas supposé) : `firestore.rules`, `storage.rules` et `functions/` compilent/packagent tous sans erreur via `firebase deploy --only ... --dry-run` contre le vrai projet `az-express-clean`. Aucun secret codé en dur trouvé. Deux avertissements d'infrastructure réels remontés par Firebase lui-même (pas par une recherche de code) : le runtime Node.js 20 est déprécié (décommissionné le 2026-10-30) et le SDK `firebase-functions` est obsolète. Une trouvaille de documentation corrigée : `.github/workflows/ci.yml` a en réalité 3 jobs (flutter, functions, et un job `firestore-rules` jamais documenté) contre 2 déjà notés depuis le Prompt 16/38. **Verdict : READY TO DEPLOY** — voir Section 14 pour le rapport complet.

**Date précédente** : 2026-07-03 (mise à jour Master Prompt 60 — « Release Candidate 2 Final Decision » — audit final avant pilote étendu, depuis la version Master Prompt 59)
**Périmètre** : synthèse des audits réalisés au fil des Master Prompts 01→60 (chacun grounded dans le code réel, jamais dans une supposition) + des jalons AZ IA M0→M7 livrés, plus une tranche ciblée de M8. Ce document ne réintroduit pas de nouvelles recherches à chaque section — il compile ce qui a déjà été vérifié et documenté dans `CLAUDE.md`, section par section, en un rapport priorisé. Conformément à l'instruction explicite du Prompt 60 (« ne pas inventer de nouveaux risques, utiliser uniquement les audits existants »), ce dernier passage ne réaudite rien : il compile la Section 0 (bilan global) et refond la Section 13 (verdict final) à partir de tout ce qui précède, plus une vérification factuelle de l'état Git/CI/secrets (Phase 3 du prompt) qui a corrigé une erreur répétée dans ce document depuis le Prompt 38 — voir ci-dessous.

**🔧 Correction factuelle importante (Prompt 60)** : ce document a affirmé, de façon répétée depuis le Prompt 38, que « zéro commit git » avait été fait et qu'aucun remote n'existait. **C'était vrai au moment où c'était écrit, mais ce n'est plus le cas** — vérifié directement (`git remote -v`, `git log`) : un remote `origin` existe (`github.com/smarttech0707/az_express_clean.git`), et **2 commits de release existent déjà**, capturant l'état du projet jusqu'au Prompt 50 inclus (`4a3d469 release: AZ Express pilot ready after master prompts 01-50 audit`, `28d0c03 release: AZ Express ready pilot after prompts 41-50 fixes`) — faits hors de cette session de conversation (aucun commit n'a été créé par l'agent IA au cours de cette série de prompts, conformément à la consigne « ne pas commit »). **Ce qui reste vrai** : tout le travail des Prompts 51 à 60 (tarification serveur AZ IA, dédoublonnage de l'annulation, App Check + correctif KYC Storage, Cloud Function Boutique cash, audit Immobilier + correctif contact, audit back-office + 2 correctifs, audit observabilité + correctif logAudit, audit performance + correctif lectures répétées) reste **non commité** — 21 fichiers modifiés/nouveaux dans l'arbre de travail actuel, jamais poussés. Voir Phase 3 (Section 13) pour le détail exact.

**Ce qui a changé depuis la version du Prompt 58** : audit performance/coûts final, strictement limité aux problèmes mesurables (le prompt interdisait explicitement le refactor et l'optimisation théorique). Un seul correctif de code : `lib/screens/chat/conversations_page.dart` construisait un `FutureBuilder` (lecture du document livreur) directement dans l'`itemBuilder` d'une liste — un vrai multiplicateur de lectures Firestore confirmé (chaque reconstruction de la liste, déclenchée par n'importe quel changement de statut sur n'importe laquelle des commandes actives du client, relançait une lecture pour **toutes** les tuiles affichées). Corrigé par extraction en `StatefulWidget` dédié avec le `Future` mis en cache pour la durée de vie de la tuile — comportement visuel inchangé. Trouvaille documentée mais volontairement non corrigée : l'usage d'`Image.network()` non mis en cache est passé de 1 fichier (Prompt 17) à 24 fichiers aujourd'hui (Immobilier, Boutique, Marketplace, Ekbine, plusieurs écrans admin) — une vraie régression, mais la corriger nécessiterait de toucher 24 fichiers, ce que ce prompt interdit explicitement (« ne pas refactoriser ») ; classée « nécessaire avant grande échelle », à corriger au cas par cas plutôt qu'en un balayage dédié. `functions/dispatch.js` scanne tous les livreurs en ligne sans `.limit()` — correct et nécessaire à la logique de plus-proche-livreur, mais son coût croît avec la taille de la flotte ; classé 🟡 à surveiller, pas corrigé (« ne pas optimiser par théorie »). Aucun risque 🔴 d'explosion de facture trouvé au volume actuel.

**Ce qui a changé depuis la version du Prompt 57** : audit de la surveillance production (logging, Crashlytics, Cloud Functions, alertes métier, performance) sans ajout de fonctionnalité ni refactor, conformément à l'instruction explicite du prompt. Un seul correctif de code, narrow et sans risque : les 2 blocs `catch` "dispatch de livraison après achat Boutique déjà payé" (`payBoutiqueOrderCF`/`payBoutiqueOrderCashCF`, `functions/orderActions.js`) ne remontaient l'échec qu'à `console.error` (Cloud Logging brut, jamais lu par l'app) — désormais aussi journalisés dans `audit_logs` via le helper `logAudit` déjà injecté, rendant ce scénario "commande bloquée" visible depuis les outils déjà existants de l'app plutôt que caché dans les logs bruts. Aucune valeur de retour changée, aucun nouveau test nécessaire (instrumentation pure). Le reste de l'audit est documentaire : Crashlytics déjà correctement configuré (rien à faire), AZ IA déjà la Cloud Function la mieux instrumentée du projet, `dispatch_metrics`/`walletReconciliationCheck` couvrent déjà 2 des 6 événements métier demandés, et la détection de "Cloud Function en erreur répétée" reste structurellement hors de portée du code applicatif (relève de règles d'alerting Cloud Monitoring côté console, jamais construites).

**Ce qui a changé depuis la version du Prompt 56** : le risque « deux back-offices non unifiés » (Prompt 35) est **résolu par documentation** — audit complet confirme qu'ils sont complémentaires, pas dupliqués : le Web Admin ne gère aucune commande/wallet/paiement/compte partenaire (contrairement à ce que le Prompt 35 pouvait laisser supposer), seulement des leads marketing pré-compte (`driver_applications`/`partner_applications`, distincts de `driver_requests`/`seller_requests` utilisés par le Mobile Admin) et des alertes SOS (seule vraie collection partagée, sans risque). Aucune fusion nécessaire. Deux bugs réels trouvés et corrigés : (1) `AdminAuthService` (web) ne bloquait pas un sous-admin désactivé à la connexion, contrairement au mobile — sévérité réduite après vérification, puisque `isAdmin()` bloque déjà `isActive` côté règles Firestore (pas de fuite de données réelle, juste un dashboard qui se serait chargé puis cassé) ; corrigé par prudence, même comportement que mobile désormais. (2) **Plus significatif** : `driver_applications`/`partner_applications` n'avaient **aucune règle Firestore** (refus implicite systématique) et `contact_messages` exigeait `isAuth()` alors que la connexion anonyme automatique est explicitement mobile-only — les 3 formulaires publics du site vitrine (candidature livreur, candidature partenaire, contact) étaient donc cassés en production, deux d'entre eux échouant silencieusement sans aucun message d'erreur affiché au visiteur. Corrigé (règles publiques avec validation stricte des champs). Un gap architectural plus profond découvert et documenté, non corrigé : le système de permissions par section des sous-admins (`admins/{uid}.permissions`) n'est appliqué nulle part dans `firestore.rules` — un sous-admin actif a le même accès Firestore complet qu'un admin, quelle que soit sa liste de permissions ; le filtrage mobile n'est qu'une convenance d'interface, pas une vraie restriction de données.

**Ce qui a changé depuis la version du Prompt 55** : le risque « deux systèmes Immobilier parallèles », listé depuis le Prompt 35/41, s'avère en réalité être **trois** systèmes disjoints (`locations`, `residences`, `real_estate_listings`) après audit complet (Prompt 56) — le troisième (`residences`/« Meublé ») n'avait jamais été examiné en détail jusqu'ici, seulement signalé comme « possible chevauchement à vérifier ». Verdict : les trois sont **légitimes** dans leur rôle actuel (admin-curé sans compte propriétaire pour les deux premiers, self-service agent vérifié + workflow de visite structuré pour le troisième) — aucune fusion ni suppression exécutée, conformément à l'interdiction explicite du prompt de fusionner/supprimer sans preuve. Le vrai risque confirmé : `search_real_estate` (l'outil AZ IA) n'interroge que `real_estate_listings` — AZ IA est structurellement aveugle aux deux tiers du catalogue immobilier réel de l'app, avec un risque concret de répondre « aucun bien disponible » alors que le dashboard en affiche. Documenté, pas corrigé (la correction toucherait une vraie question produit — que devient « demander une visite » pour une annonce sans agent ni workflow de visite — pas un simple branchement technique). Un bug distinct et non-cosmétique trouvé en comparant les fonctions de contact des 3 systèmes a été corrigé : le bouton « Contactez le propriétaire » de `locations_page.dart` n'était pas câblé du tout (pas de `onTap`, et le formulaire admin ne capturait même pas de numéro de téléphone) — corrigé (`admin_locations_page.dart` gagne un champ `phone`, `locations_page.dart` lance désormais un vrai appel `tel:`).

**Ce qui a changé depuis la version du Prompt 54** : les 5 `confirmHandler` AZ IA de création de commande les plus critiques financièrement (`create_delivery_order`, `create_shopping_order`, `create_restaurant_order`, `create_pharmacie_order`, `create_marketplace_order`) sont désormais **directement testés** (17 nouveaux tests) — jusqu'ici vérifiés seulement par relecture attentive et `node -c`/`require()`. **Aucune divergence de sécurité/paiement trouvée entre AZ IA et l'app Flutter équivalente** sur ces 5 outils — chaque test confirme que les correctifs déjà appliqués (Prompts 46, 51) tiennent toujours. **Un seul gap réel trouvé et documenté (pas corrigé, ne correspond à aucune catégorie 🔴)** : `create_marketplace_order` ne marque jamais un produit comme vendu après achat — un même article à exemplaire unique pourrait être « acheté » plusieurs fois via AZ IA, chaque acheteur étant réellement débité (pas une perte d'argent client, ni un contournement de sécurité, ni une commande impossible — un risque d'intégrité côté vendeur, qui n'a d'ailleurs aucun équivalent « app normale » à reproduire puisque le Marketplace standard n'a lui-même aucun parcours d'achat). La suite de tests est passée de 138 à **155 tests**.

**Ce qui a changé depuis la version du Prompt 52** : App Check (SDK `firebase_app_check`) est désormais activé côté client (Android Play Integrity, iOS DeviceCheck, debug provider) — mais **l'enforcement côté serveur n'est volontairement pas activé** (nécessite un rollout console + une période de déploiement client avant d'être sûr, sous peine de bloquer tous les utilisateurs sur un ancien build). Les 4 chemins Storage KYC livreur/flotte (`driver_selfies`/`driver_id_photos`/`fleet_selfies`/`fleet_id_photos`, signalés au Prompt 50) sont désormais restreints à `isOwnerPath(uid) || isAdmin()` — vérifié sûr avant correction (ces chemins ne sont jamais lus par référence directe ailleurs dans l'app). `driver_photos` (photo de profil, légitimement affichée au client pendant une course) volontairement laissé inchangé. `livreurs.wallet` réexaminé, décision de report du Prompt 22 confirmée toujours valide.

**Ce qui a changé depuis la version du Prompt 51** : `functions/azia/tools/delivery.js:cancel_order`, signalé au Prompt 51 comme une 5ᵉ implémentation dupliquée et non corrigée de l'annulation de commande, est **résolu** — la logique métier de `cancelOrderCF` (déjà corrigée aux Prompts 47/48 : remboursement client, remboursement commission livreur, débit vendeur Marketplace en retour, plafond anti-solde-négatif) est désormais extraite en fonctions partagées (`cancelOrderTx`/`cancelOrderPostTx`) et appelée par les 3 chemins d'annulation réels (client via l'app, expiration automatique, AZ IA) — plus aucune duplication. La suite de tests est passée de 124 à **131 tests**.

**Ce qui a changé depuis la version du Prompt 50** : le risque de tarification livraison signalé comme le plus concret dans le verdict précédent (« deux moteurs de prix actifs ») est **résolu** — `TarifService` est désormais la source unique de vérité pour les 3 chemins de création de commande livraison (Flutter direct, AZ IA). En creusant cette unification, une **trouvaille plus grave que celle déjà connue a émergé** : les outils AZ IA de création de commande ne calculaient jusqu'ici *aucun* prix du tout, laissant le modèle Claude choisir librement un montant dans une large fourchette — contredisant littéralement la règle « ne jamais inventer d'information » déjà écrite dans le system prompt d'AZ IA lui-même. Corrigé avec le même mouvement. La suite de tests est passée de 115 à 124 tests.

**Ce que ce document n'est pas** : un audit de sécurité professionnel externe, un test de charge réel, ou une revue juridique/conformité. C'est une synthèse honnête de l'état du code tel qu'observé par un agent IA au cours de cette session — utile pour prioriser, pas pour remplacer une revue humaine avant un vrai lancement à grande échelle.

**Ce qui a changé depuis la version du 2026-07-02 (Prompts 01→39)** : cette mise à jour couvre 11 prompts supplémentaires (41→50, le 40 ayant produit la version précédente), avec un changement de nature — les prompts 41-45 ont audité des zones jusqu'ici jamais examinées (repositories morts, gestion mémoire, gestion d'état, doubles sources de vérité), mais **les prompts 46 à 49 ont trouvé et corrigé 6 bugs financiers réels et confirmés**, une découverte bien plus significative que tout ce qui avait été trouvé dans les Prompts 21-39 réunis. Le plus grave d'entre eux — **le remboursement automatique à 48h des commandes Boutique non livrées n'a jamais fonctionné en production, silencieusement, depuis la mise en service de cette fonctionnalité** — n'a été découvert qu'en traçant explicitement chaque chemin argent du module Boutique de bout en bout (Prompt 48 bis), après qu'un premier passage plus rapide (Prompt 47) avait laissé le sujet incomplet. La suite de tests est passée de 104 à **115 tests**.

---

## 0. Bilan global après 60 prompts (Master Prompt 60)

Synthèse demandée par le Prompt 60 lui-même — un tableau de lecture rapide par domaine, chaque ligne pointant vers la section détaillée correspondante (aucune nouvelle recherche, uniquement une compilation).

### Sécurité
- **Firebase / Firestore rules / Storage rules** : posture par défaut-refus confirmée sur l'ensemble des deux fichiers de règles (Prompt 50), aucune brèche d'écriture ouverte restante au-delà de ce qui est documenté ci-dessous. 3 formulaires publics du site vitrine récemment corrigés après avoir été trouvés cassés par des règles trop strictes plutôt que trop laxistes (Prompt 57).
- **App Check** : SDK activé côté client mobile (Android Play Integrity, iOS DeviceCheck) — **enforcement serveur toujours pas activé**, bloqué sur des étapes console Firebase humaines (Prompt 53).
- **Admin / rôles** : deux back-offices confirmés complémentaires, pas dupliqués (Prompt 57) ; permissions par section des sous-admins jamais appliquées côté règles (convenance d'UI mobile uniquement, gap connu et documenté, pas un bug actif — `isActive` reste bien vérifié côté serveur).
- **KYC/identité** : photos/pièces d'identité livreur et flotte restreintes au propriétaire+admin (Prompt 53) ; `livreurs.wallet` reste lisible par tout authentifié (décision de report assumée depuis le Prompt 22, réexaminée sans changement au Prompt 53).

### Paiement
- **Wallet, remboursements, commissions** : **9 bugs financiers critiques trouvés et corrigés au total sur toute la session** (3 avant Prompt 40, 6 aux Prompts 46-49) — voir Section 4/9. Tous testés (155 tests au total dans `functions/`).
- **Vendeurs/livreurs** : logique de crédit/débit unifiée entre les 3 chemins de chaque opération sensible (app Flutter, expiration automatique, AZ IA) depuis les Prompts 51-52 (tarification, annulation).
- **Double paiement** : les 2 boutons de paiement sans protection anti-double-tap trouvés (Boutique, Pharmacie) sont corrigés (Prompts 48-49) ; aucun autre bouton de paiement critique trouvé non protégé.

### Commandes
- **Création** : tarification livraison unifiée sur un seul moteur (`TarifService`/`tarifService.js`) pour les 3 chemins (Flutter direct, AZ IA) depuis le Prompt 51 — reste ouvert : validation serveur du prix soumis par les 5 écrans Flutter directs (analysé, pas construit).
- **Dispatch** : entièrement côté serveur, verrouillage transactionnel (Prompt 26) ; scan complet des livreurs en ligne sans `.limit()` (`dispatch.js`) documenté 🟡 à surveiller si la flotte grandit (Prompt 59), pas un problème mesurable aujourd'hui.
- **Suivi** : lecture Firestore répétée corrigée sur l'écran des conversations (Prompt 59) ; deux services de tracking dupliqués (`TrackingService`/`RealtimeTrackingService`) documentés, non fusionnés (Prompt 42).
- **Annulation** : logique unifiée et partagée (`cancelOrderTx`/`cancelOrderPostTx`) sur les 3 chemins réels (app, expiration auto, AZ IA) depuis le Prompt 52 — plus aucune duplication.
- **Livraison** : preuve par photo uniquement (pas d'OTP/signature) — état assumé, pas un gap à corriger sans décision produit.

### Modules
| Module | État |
|---|---|
| Livraison | Tarification unifiée (51), dispatch fiable, tracking dupliqué documenté (42) |
| Courses | Inchangé depuis Prompt 39, items structurés existants |
| Restaurant | Double-crédit corrigé (46), pas d'autre bug financier trouvé |
| Pharmacie | Prix serveur (51), double-tap corrigé (49) |
| Boulangerie | Inchangé, pas de bug financier trouvé |
| Boutique | Cartographie complète (48 bis), 3 bugs critiques corrigés dont le remboursement 48h jamais fonctionnel ; chemin cash corrigé (54) |
| Marketplace | Double-crédit et non-débit vendeur corrigés (46-47) ; gap non-critique documenté : produit jamais marqué vendu après achat AZ IA (55) |
| Immobilier | 3 systèmes audités et confirmés légitimes (56), bug de contact corrigé ; AZ IA aveugle à 2/3 du catalogue (documenté) |
| E-Kbine | Pas de commission (politique assumée), double-tap déjà protégé (49) |
| AZ IA | Confirmation serveur systématique (`ai_pending_actions`), 5 `confirmHandler` de création testés (55), tarification serveur alignée sur l'app (51), instrumentation la plus complète du projet (58) |

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
| Tests | 104 → 115 → **124 tests** | +11 (Prompts 46-49) puis +9 (Prompt 51, `tarifService.js`) |
| Tarification livraison | **Un seul moteur (`TarifService`) sur les 3 chemins** (Flutter direct, AZ IA) | **Unifié** (Prompt 51) — était le risque Élevée n°1 à la clôture du Prompt 50 |
| CI/CD | Toujours inactif (pas de remote GitHub), zéro commit git cette session | Inchangé |
| Documentation | `CLAUDE.md` étendu de ~11 sections supplémentaires (Prompts 41-51) | Étendu en continu |

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

- **App Check — préparé, pas appliqué (Prompt 53).** SDK activé côté client (Android Play Integrity, iOS DeviceCheck, debug provider) ; l'enforcement côté serveur nécessite encore un rollout console (enregistrement Play Integrity/DeviceCheck, jeton de debug, clé reCAPTCHA web) et une période de déploiement client avant de pouvoir être activé sans casser les utilisateurs sur un ancien build — voir `CLAUDE.md` section Firebase pour la checklist complète des ~23 fonctions `onCall` candidates.
- **Tarification livraison — résolu (Prompt 51).** Un seul moteur (`TarifService`) sur les 3 chemins de création (Flutter direct + AZ IA) ; reste ouvert : validation Cloud Function du prix soumis par les 5 écrans Flutter directs (analysé, pas construit sans validation explicite).
- **`livreurs/{id}.wallet` reste lisible par tout utilisateur authentifié** — inchangé, décision de report toujours valide (réexaminé Prompt 53, aucun élément nouveau ne change le calcul).
- **Trois systèmes Immobilier parallèles (confirmé, Prompt 56)** — audité en détail, verdict : légitimes dans leur rôle actuel, pas de fusion/suppression exécutée. Reste ouvert : AZ IA (`search_real_estate`) n'interroge qu'un des trois (`real_estate_listings`), aveugle aux deux autres (`locations`, `residences`) — décision produit à trancher (étendre la recherche en lecture seule vs documenter comme limite connue). Bug de contact cassé sur `locations_page.dart` corrigé au passage (voir `CLAUDE.md`).
- **Deux back-offices — audité (Prompt 57), reclassé : complémentaires, pas dupliqués.** Le Web Admin ne gère aucune commande/wallet/compte partenaire réel — seulement des leads marketing pré-compte et SOS. Un bug de connexion (sous-admin désactivé) et 3 formulaires publics du site vitrine cassés en production ont été trouvés et corrigés. Gap distinct documenté, non corrigé : les permissions par section des sous-admins ne sont appliquées nulle part dans `firestore.rules` (accès Firestore identique pour tout sous-admin actif, quelle que soit sa liste de permissions).
- **Photos/pièces d'identité KYC livreurs et flotte — résolu (Prompt 53).** `driver_selfies`/`driver_id_photos`/`fleet_selfies`/`fleet_id_photos` (`storage.rules`) restreints à `isOwnerPath(uid) || isAdmin()` — vérifié sûr avant correction (aucune lecture par référence directe ailleurs dans l'app, seul l'admin les consulte via l'URL déjà protégée sur `driver_requests`). `driver_photos` (photo de profil, affichée légitimement au client pendant une course) volontairement laissé en lecture large — distinct par nature d'un document KYC, tightening cassé une fonctionnalité réelle pour un risque bien plus faible.

### Moyenne

- Compte livreur de flotte : création probablement cassée (inchangé, non corrigé).
- Code mort 2FA admin (inchangé).
- `service_providers` (artisans) — faiblesse d'auth inchangée.
- Vocabulaire de statut transaction fragmenté (inchangé).
- Fichiers Cloud Storage jamais nettoyés (inchangé).
- ~~Chemin de paiement cash Boutique cassé (Prompt 48 bis)~~ — **résolu (Prompt 54)**. Nouvelle Cloud Function atomique `payBoutiqueOrderCashCF` : vérifie le stock, le décrémente, crée `boutique_orders` — les deux dans la même transaction, aucun état intermédiaire possible. `boutique_page.dart` délègue désormais à cette CF (même pattern que le chemin wallet).
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
- **Résolu (Prompt 51)** : les deux moteurs de tarification actifs et différents (`TarifService` vs `DeliveryService`, découverts Prompt 45) sont unifiés — `create_order.dart` utilise désormais `TarifService.compute()` pour le prix (`DeliveryService` reste importé uniquement pour ses utilitaires neutres distance/ETA). **Trouvaille plus grave découverte en creusant** : les outils AZ IA de création de commande (`create_delivery_order`/`create_pharmacie_order`) ne calculaient aucun prix — le modèle choisissait librement un montant dans une fourchette large (500-10000 FCFA), sans aucun rapport avec la distance/l'heure réelles, contredisant la règle « ne jamais inventer d'information » du system prompt d'AZ IA. Corrigé : nouveau `functions/tarifService.js` (port Node fidèle de `TarifService`), le prix est désormais calculé côté serveur pour AZ IA aussi — même distance = même prix garanti par construction sur les 3 chemins (bouton Commander, carte, AZ IA). Reste ouvert : les 5 écrans Flutter directs calculent toujours le prix côté client sans validation Cloud Function (risque déjà connu, pas aggravé, pas résolu — voir section 4).
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
| Deux moteurs de tarification livraison divergents | Élevée | **Résolu** (Prompt 51) — validation Cloud Function encore ouverte |
| Annulation dupliquée côté AZ IA (5ᵉ implémentation, sans protections Marketplace/anti-négatif) | Élevée | **Résolu** (Prompt 52) |
| App Check absent | Élevée | **Préparé côté client** (Prompt 53) — enforcement serveur encore ouvert (rollout console requis) |
| `livreurs.wallet` lisible par tout authentifié | Élevée | Ouvert, décision de report inchangée (réexaminé Prompt 53) |
| Trois systèmes Immobilier parallèles (`locations`/`residences`/`real_estate_listings`) | Élevée | **Audité** (Prompt 56) — légitimes, pas fusionnés ; AZ IA aveugle à 2/3 du catalogue, ouvert |
| Deux back-offices non unifiés | Élevée | **Reclassé : complémentaires** (Prompt 57) — 2 bugs réels corrigés (connexion web, formulaires publics cassés) ; permissions sous-admin non enforced en rules, ouvert |
| Formulaires publics site vitrine cassés (`driver_applications`/`partner_applications`/`contact_messages`, aucune règle ou règle bloquant tout visiteur anonyme) | Élevée | **Corrigé** (Prompt 57) |
| Sous-admin désactivé pouvait quand même se connecter au Web Admin | Faible | **Corrigé** (Prompt 57) — aucune fuite de données réelle (`isAdmin()` bloque déjà `isActive` côté règles) |
| Permissions par section des sous-admins jamais appliquées côté `firestore.rules` (convenance d'UI mobile uniquement) | Moyenne | **Nouvelle découverte** (Prompt 57), ouvert |
| `withObservability` (Prompt 25, testé) jamais branché à une seule Cloud Function de production — `request_logs` vide hors AZ IA | Moyenne | **Documenté** (Prompt 58), décision de branchement laissée à l'utilisateur |
| Dispatch de livraison Boutique échoué après achat payé, visible seulement dans les logs bruts Cloud Functions | Faible | **Corrigé** (Prompt 58) — désormais aussi dans `audit_logs` |
| Aucun signal admin-visible pour un paiement/remboursement wallet échoué par précondition (visible client uniquement) | Moyenne | **Documenté** (Prompt 58), ouvert |
| `conversations_page.dart` — lecture Firestore répétée à chaque rebuild de liste (`FutureBuilder` inline dans `itemBuilder`) | Faible | **Corrigé** (Prompt 59) |
| `Image.network()` non mis en cache — régression 1→24 fichiers depuis le Prompt 17 (Immobilier, Boutique, Marketplace, Ekbine, admin) | Moyenne | **Documenté** (Prompt 59), nécessaire avant grande échelle, pas corrigé (hors périmètre "ne pas refactoriser") |
| `dispatch.js` scan complet des livreurs en ligne sans `.limit()` | Faible | **Documenté** (Prompt 59), acceptable au volume pilote, à réévaluer si la flotte grandit |
| `audit_logs`/`security_events`/`request_logs` sans politique de purge/TTL | Faible | **Nouvelle observation** (Prompt 59), acceptable au volume pilote |
| Photos/pièces d'identité KYC livreurs et flotte lisibles par tout authentifié | Élevée | **Corrigé** (Prompt 53) — `driver_photos` (profil) volontairement laissé ouvert |
| ~90% du code sans test automatisé (chemins financiers, y compris AZ IA, désormais couverts) | Élevée | Ouvert (reste du code non financier), réduit (104→155 tests) |
| Repositories morts/dangereux (`WalletRepository` etc.) | Moyenne | **Corrigé — supprimés** (Prompt 41) |
| Fuite mémoire Immobilier (`agent_dashboard_screen.dart`) | Moyenne | **Corrigé** (Prompt 44) |
| Chemin cash Boutique cassé (stock décrémenté sans commande créée) | Moyenne | **Corrigé** (Prompt 54) — `payBoutiqueOrderCashCF`, atomique |
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
1. ~~Trancher entre `TarifService` et `DeliveryService`~~ — **résolu (Prompt 51)**. Reste ouvert, plus étroit : valider côté serveur (Cloud Function) le prix soumis par les 5 écrans Flutter directs (`livraison_screen.dart`, `courses_screen.dart`, `create_order.dart`, `pharmacie_garde.dart`, `boulangerie_order_page.dart`) — analysé, pas construit sans validation explicite.
2. ~~Activer App Check~~ — **SDK préparé côté client (Prompt 53)**. Reste à faire (console Firebase, hors de portée du code) : enregistrer Play Integrity/DeviceCheck, obtenir une clé reCAPTCHA web, enregistrer le jeton de debug, puis activer `enforceAppCheck: true` sur les ~23 fonctions `onCall` candidates (liste dans `CLAUDE.md` section Firebase) une fois le rollout client terminé.
3. ~~Réconcilier ou séparer officiellement les systèmes Immobilier~~ — **audité (Prompt 56)** : trois systèmes confirmés légitimes dans leur rôle actuel, pas fusionnés. Reste ouvert, plus étroit : décider si `search_real_estate` (AZ IA) doit être étendu à `locations`/`residences` en lecture seule, sachant que « demander une visite » n'a pas d'équivalent pour ces deux collections (pas d'agent, pas de workflow). ~~Réconcilier ou séparer officiellement les deux back-offices~~ — **audité (Prompt 57)** : confirmés complémentaires (périmètres quasi disjoints), rien à unifier ; reste ouvert, plus étroit : appliquer les permissions par section des sous-admins dans `firestore.rules` (aujourd'hui une convenance d'UI mobile uniquement, aucune vraie restriction de données).
4. ~~Restreindre la lecture des photos/pièces d'identité livreurs~~ — **résolu (Prompt 53)** pour les 4 chemins KYC (`driver_selfies`/`driver_id_photos`/`fleet_selfies`/`fleet_id_photos`). `livreurs.wallet` reste ouvert (décision de report inchangée, chantier plus large de ~10 sites à migrer).
5. ~~Étendre la couverture de tests aux `confirmHandler` des outils AZ IA de création de commande~~ — **résolu (Prompt 55)**, 17 nouveaux tests sur les 5 outils. Reste ouvert : couverture des flux Ekbine/Marketplace non financiers.
6. ~~`functions/azia/tools/delivery.js:cancel_order` dupliquait l'annulation~~ — **résolu (Prompt 52)**.

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
**Critères de sortie avant Phase 2** : App Check activé ; arbitrage sur les deux moteurs de tarification livraison ; décision prise sur la visibilité AZ IA des trois systèmes Immobilier (audités, Prompt 56) ; enforcement des permissions par section des sous-admins côté règles Firestore (audité, Prompt 57) ; restriction de la lecture `livreurs.wallet`/photos d'identité.

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

## 13. Verdict final — Master Prompt 60

### Phase 3 — Checklist production (vérifiée factuellement, pas supposée)

| Item | État vérifié |
|---|---|
| Projet Firebase | Un seul environnement, `az-express-clean` (`.firebaserc`) — pas de dev/staging séparé, décision déjà assumée (voir section DevOps de `CLAUDE.md`) |
| Firestore rules | Compilent sans erreur (`firebase deploy --only firestore:rules --dry-run`, vérifié Prompt 57) — **pas encore déployées en prod** (les correctifs des Prompts 57/59 sont dans le fichier local, pas poussés) |
| Storage rules | Correctif KYC du Prompt 53 présent localement — **pas encore déployé en prod** |
| Index Firestore | 37 index composites déclarés (`firestore.indexes.json`), cohérents avec les requêtes connues (Prompt 42) |
| Cloud Functions | 53 exports, chargent sans erreur (`node -c` + `require()`) — **code local en avance sur la prod** : `tarifService.js`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`, les correctifs `orderActions.js`/`azia/tools/*.js` ne sont pas déployés tant que `firebase deploy --only functions` n'a pas été relancé |
| App Check | SDK activé côté client (mobile uniquement) ; **enforcement serveur non activé** — rollout console requis (Play Integrity/DeviceCheck/reCAPTCHA web, jeton de debug) |
| Crashlytics | Initialisé correctement (`FlutterError.onError` + `PlatformDispatcher.onError`), vérifié Prompt 58 — rien à faire |
| GitHub / Git | **Correction par rapport aux versions précédentes de ce document** (voir encadré en tête de fichier) : un remote `origin` existe déjà, 2 commits de release capturent l'état jusqu'au Prompt 50 — mais tout le travail des Prompts 51-60 (21 fichiers modifiés/nouveaux) reste non commité localement |
| CI (`.github/workflows/ci.yml`) | Le fichier existe (créé Prompt 16) et est prêt (`flutter analyze` + `flutter test` + `npm test`) — impossible de vérifier depuis cet environnement s'il s'est déjà exécuté sur GitHub (`gh` CLI indisponible ici) ; certainement jamais exécuté sur le travail des Prompts 51-60 tant qu'il n'est pas poussé |
| Secrets/clés API | `functions/.env` existe et est correctement exclu de git (`.gitignore` : `.env`, `.env.*`, `functions/.env`, `functions/.env.*` — vérifié directement) ; clé Google Maps centralisée côté client (`MapsConfig.apiKey`, Prompt 27) — reste embarquée dans le binaire (inhérent au SDK), restriction par domaine/app à faire côté Google Cloud Console (hors du code) |

### Phase 4 — Test final (exécuté, pas supposé)

- `flutter analyze` (projet complet) : **5 avertissements, 0 erreur** — 1 `unused_element` (`livraison_screen.dart:502`), 4 `deprecated_member_use` (`agent_dashboard_screen.dart`, usage de `RadioListTile.groupValue`/`onChanged`, dépréciés par le SDK Flutter lui-même, pas par ce projet) — inchangés depuis plusieurs prompts, aucun n'est bloquant.
- `npm test` (`functions/`) : **155/155 tests verts**, 0 échec.
- Cloud Functions load (`node -c index.js` + `require('./index.js')`) : propre, **53 fonctions exportées** sans erreur de chargement.
- Aucune régression introduite par cette Section 0/13 elle-même (aucun code modifié pour ce Prompt 60 — synthèse documentaire uniquement, conformément à son interdiction explicite de corriger sans bug confirmé).

### Phase 5 — Plan de lancement (chiffré, pas seulement qualitatif)

**Phase pilote Abengourou (recommandation)** :
- **Clients** : 100-300 utilisateurs réels pour commencer — assez pour générer un volume de commandes/paiements significatif sans dépasser ce qu'une supervision humaine active peut surveiller quotidiennement (conciliation wallet, `admin_security_dashboard.dart`, `dispatch_metrics`).
- **Livreurs** : 15-30 livreurs actifs — suffisant pour tester le dispatch par rayon (2 km → 5 km → 30 km) sur une vraie densité urbaine sans que le scan non-borné de `dispatch.js` (Prompt 59, 🟡) devienne un coût mesurable.
- **Vendeurs/partenaires** : 10-20 par vertical (Marketplace, Restaurant, Pharmacie, Boutique) — assez pour couvrir les principaux chemins de paiement testés cette session (double-crédit, remboursement, annulation) en conditions réelles.
- **Durée du test** : **minimum 2 semaines consécutives** avant d'envisager la Phase 2 (déjà fixé au Prompt 50, reconfirmé) — le critère n'est pas le temps écoulé mais le résultat : deux semaines **sans écart de conciliation wallet** (`walletReconciliationCheck`, désormais un signal plus fiable qu'avant puisque 9 sources d'écart structurel connues sont éliminées).
- **Métriques à suivre activement** : écarts `wallet_reconciliation_findings` (hebdomadaire, déjà automatisé) ; `dispatch_metrics.noDriverFoundCount` par zone/créneau (déjà automatisé) ; volume et taux d'erreur `audit_logs` sur les actions `pay_*`/`cancel_*`/`deliver_*` (déjà journalisé, lecture manuelle en attendant que `withObservability` soit branché) ; nombre de tickets support liés à un paiement ; taux de succès `azIaChat` (déjà dans `request_logs` via l'instrumentation bespoke).

**Conditions nécessaires pour passer en phase publique** (reprises de la liste déjà établie, pas réinventées) : voir « Actions obligatoires avant lancement public » ci-dessous — aucune n'est optionnelle, mais aucune n'est non plus un bug actif de perte d'argent : ce sont des conditions de passage à l'échelle, pas des correctifs d'urgence.

---

### 🎯 VERDICT FINAL : **READY PILOT EXTENDED**

#### 1. Pourquoi

Les 9 bugs financiers critiques trouvés sur l'ensemble de la session (paiement wallet cassé sur 3 modules, double-crédit sur 2 modules, non-débit vendeur à l'annulation, solde négatif possible, remboursement automatique Boutique jamais fonctionnel) sont **tous corrigés et couverts par des tests** (155 tests au total, contre 26 au tout début de cette série d'audits). Les 5 outils de création de commande AZ IA les plus critiques financièrement ont été testés directement et ne divergent d'aucune façon du comportement sécurisé de l'app Flutter (Prompt 55). La tarification livraison et la logique d'annulation sont désormais unifiées sur un seul chemin de vérité chacune, y compris pour AZ IA (Prompts 51-52) — plus de double moteur de prix, plus d'implémentation dupliquée de l'annulation. Les deux risques structurels qui semblaient les plus préoccupants en milieu de session (« deux systèmes Immobilier », « deux back-offices ») se sont révélés, après audit complet plutôt que supposition, être des architectures **complémentaires et non dangereuses** — avec, chemin faisant, la découverte et la correction de bugs réels et indépendants (bouton de contact cassé, formulaires publics du site vitrine entièrement non fonctionnels, connexion admin web trop permissive). La surveillance production a été auditée (Crashlytics propre, AZ IA déjà bien instrumentée, deux des six événements métier critiques déjà couverts automatiquement) et un vrai bug d'observabilité corrigé. Le dernier audit performance/coûts n'a trouvé **aucun risque de facturation Firebase explosif au volume pilote actuel**, et a corrigé le seul vrai bug de lectures Firestore répétées trouvé. Le niveau de maturité atteint — bugs financiers connus tous corrigés et testés, architecture comprise plutôt que supposée, surveillance en place, performance validée à l'échelle pilote — justifie d'passer d'un pilote restreint et prudent à un **pilote étendu**, toujours sous supervision humaine active, pas encore un lancement public non supervisé.

#### 2. Risques acceptés (pour le pilote étendu — non bloquants, tous déjà connus, aucun nouveau)

1. **Tarification livraison validée uniquement côté client** sur les 5 écrans Flutter directs (le moteur est unique, mais rien ne rejette un prix manipulé avant écriture) — Prompt 51.
2. **App Check préparé côté client, pas appliqué côté serveur** — un token manquant/invalide n'est aujourd'hui jamais rejeté ; le rollout console reste à faire humainement — Prompt 53.
3. **`livreurs/{id}.wallet` lisible par tout utilisateur authentifié** — risque de visibilité de solde, pas de fonds (aucune écriture cross-user n'est possible) — décision de report depuis le Prompt 22, réexaminée sans changement au Prompt 53.
4. **AZ IA aveugle aux deux tiers du catalogue Immobilier** (`locations`/`residences` non interrogés par `search_real_estate`) — risque de réponse incomplète, pas de sécurité — Prompt 56.
5. **Permissions par section des sous-admins non appliquées côté règles** (`isActive` l'est, `permissions` non) — un sous-admin actif a un accès Firestore complet quelle que soit sa liste déclarée ; risque de moindre-privilège, pas un accès qu'un compte désactivé ou non-admin pourrait exploiter — Prompt 57.
6. **`create_marketplace_order` (AZ IA) ne marque jamais un produit vendu** — risque d'intégrité vendeur (double vente possible d'un article unique), jamais de perte d'argent client — Prompt 55.
7. **Aucun signal admin-visible pour un paiement/remboursement wallet échoué par précondition** — visible côté client uniquement — Prompt 58.
8. **Régression du cache d'images** (`Image.network()` non mis en cache, 1→24 fichiers depuis le Prompt 17) — risque de coût/performance, pas de sécurité ni de perte d'argent — Prompt 59.
9. **`dispatch.js` scanne tous les livreurs en ligne sans `.limit()`** — acceptable à la taille de flotte recommandée ci-dessus (15-30 livreurs), à réévaluer si la flotte grandit significativement — Prompt 59.
10. **`audit_logs`/`security_events`/`request_logs` sans purge/TTL** — croissance non bornée, sans impact mesurable au volume pilote — Prompt 59.
11. **`withObservability` jamais branché aux Cloud Functions financières** — observabilité par requête absente pour paiement/wallet/dispatch (AZ IA, elle, est déjà bien instrumentée) — Prompt 58.

#### 3. Actions avant publication Play Store / App Store

1. **Committer et pousser le travail des Prompts 51-60** (21 fichiers) vers le remote GitHub déjà configuré — la CI déjà écrite (`ci.yml`) ne peut protéger contre aucune régression tant que ce travail n'est pas versionné.
2. **Déployer `firestore.rules` et `storage.rules` en production** — les correctifs des Prompts 53/57/59 (KYC Storage, formulaires publics du site vitrine, connexion admin web) existent seulement dans le code local tant qu'un `firebase deploy` n'a pas été fait.
3. **Déployer `functions/`** — `tarifService.js`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`, et tous les correctifs `orderActions.js`/`azia/tools/*.js` des Prompts 51-59 tournent encore, en production, dans leur version d'avant ces corrections tant que ce déploiement n'a pas eu lieu — **c'est l'action la plus urgente de cette liste**, puisque sans elle, les correctifs de bugs financiers documentés dans ce rapport comme "corrigés" ne sont pas réellement actifs pour les vrais utilisateurs.
4. Terminer le rollout App Check (console Firebase : Play Integrity/DeviceCheck/reCAPTCHA web, jeton de debug), puis activer `enforceAppCheck: true` sur les Cloud Functions `onCall` sensibles une fois le nouveau build déployé à tous les utilisateurs actifs.
5. Construire la validation Cloud Function du prix livraison pour les 5 écrans Flutter directs restants.
6. Configurer une sauvegarde Firestore planifiée (fonctionnalité GCP native, jamais activée à ce jour).

#### 4. Actions avant grande échelle (au-delà du pilote étendu, pas bloquantes pour lui)

1. Décider si `search_real_estate` doit être étendu à `locations`/`residences`, et ce que devient « demander une visite » sans agent.
2. Décider si les permissions par section des sous-admins doivent être réellement appliquées dans `firestore.rules`.
3. Décider si `withObservability` doit être branché aux Cloud Functions financières, et configurer des règles d'alerting Cloud Monitoring côté console pour détecter une fonction en erreur répétée.
4. Remplacer `Image.network()` par `CachedNetworkImage` dans les 24 fichiers identifiés, au cas par cas.
5. Traiter `livreurs.wallet` (chantier ~10 sites de lecture/écriture).
6. Décider d'une sémantique de statut "vendu" pour le Marketplace.
7. Concevoir une stratégie de nettoyage Cloud Storage et une politique de purge/TTL pour les collections de logs.
8. Corriger le flux de création de compte livreur de flotte ; nettoyer le code mort 2FA admin ; renforcer l'authentification `service_providers` (artisans).

**Ce verdict reste "pilote étendu sous supervision humaine active", pas "lancement public non supervisé"** — la distinction avec le verdict READY PILOT des versions précédentes de ce document est un changement d'échelle du pilote (plus d'utilisateurs, plus de confiance dans la couverture de test et l'architecture), pas un changement de posture de supervision.

---

## 14. Préparation au déploiement Firebase réel — Master Prompt 61

Audit-only, conformément à l'instruction explicite du prompt (« ne pas refactoriser, ne pas ajouter de fonctionnalités, ne pas modifier une logique métier stable », « ne rien déployer automatiquement »). Aucun code modifié dans cette section. Toutes les vérifications ci-dessous sont réellement exécutées (dry-run contre le projet Firebase réel `az-express-clean`), pas supposées.

### Phase 1 — Audit du projet Firebase

- **`.firebaserc`** : un seul projet, `az-express-clean` — pas d'alias dev/staging/prod (décision déjà assumée, section DevOps de `CLAUDE.md`).
- **`firebase.json`** : références correctes vers `firestore.rules`/`firestore.indexes.json`/`storage.rules` ; Functions en `nodejs20` ; Hosting sert `build/web` avec en-têtes de sécurité déjà présents (HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy) — pas de CSP explicite (gap mineur, non corrigé ici, hors périmètre "ne rien modifier").
- **Région Cloud Functions** : cohérente — `setGlobalOptions({ region: 'europe-west1' })` s'applique à toutes les fonctions sauf `azIaChat`, qui déclare explicitement la même région — aucune divergence trouvée.
- **App Check** : SDK client actif (mobile), enforcement serveur toujours pas activé — conforme à l'instruction explicite de ce prompt de ne pas y toucher.
- **Authentication / Remote Config** : inchangés, pas re-audités sans nouvel angle (Remote Config confirmé toujours absent, déjà documenté).

### Phase 2/3 — Firestore & Storage deploy readiness (testé réellement)

- `firebase deploy --only firestore --dry-run` → **compilation réussie**, aucune erreur.
- `firebase deploy --only storage --dry-run` → **compilation réussie**, aucune erreur.
- Aucune règle temporaire dangereuse trouvée (`allow read, write: if true` : 0 occurrence dans `firestore.rules`).
- Aucun accès public inattendu au-delà de ce qui est déjà documenté et voulu (`config`, annonces actives Marketplace/Immobilier).
- Collections sensibles confirmées protégées : `ai_conversations`, `ai_pending_actions`, `audit_logs`, `security_events`, `rate_limits` — toutes `allow write: if false` (Cloud Function uniquement).
- KYC/documents livreurs (Storage) : `driver_selfies`/`driver_id_photos`/`fleet_selfies`/`fleet_id_photos` restreints à `isOwnerPath(uid) || isAdmin()` (déjà corrigé Prompt 53) ; `driver_photos` (photo de profil, publique par nécessité fonctionnelle) volontairement large — confirmé toujours cohérent.

### Phase 4 — Cloud Functions release check

- `firebase deploy --only functions --dry-run` → **packaging réussi** (176,66 Ko), aucune erreur de chargement.
- **53 fonctions exportées**, région cohérente, secrets chargés depuis `.env` correctement au moment du dry-run.
- **2 avertissements d'infrastructure réels, remontés par l'outil Firebase lui-même** :
  1. 🟡 Runtime **Node.js 20 déprécié depuis le 2026-04-30, décommissionné le 2026-10-30** — pas un blocage aujourd'hui, mais une action à planifier avant fin octobre 2026.
  2. 🟡 SDK **`firebase-functions` obsolète**, avec avertissement explicite de changements cassants à la mise à niveau — pas mis à jour ici (décision explicite requise avant toute montée de version majeure, politique déjà actée).
- Mémoire/timeout : seules 3 fonctions ont des overrides explicites (`autoExpireOrders` 120s/256MiB, `cleanupExpiredRateLimits` 300s/256MiB, `azIaChat` 120s/512MiB) — les 50 autres sur les valeurs par défaut v2, cohérent avec un trafic pilote.
- Fonctions sensibles identifiées (déjà connues, listées pour référence) : wallet/paiement (`orderActions.js`, `initiateFeexPayPayment`, `initiateWithdrawal`), commandes/dispatch (`dispatchOrderToDriver`, `autoExpireOrders`), AZ IA (`azIaChat`, `aiConfirmAction`), admin (`createSubAdmin`, `deleteSubAdmin`).

### Phase 5 — Variables d'environnement / secrets

- Recherche exhaustive de secrets codés en dur dans `functions/*.js` — **zéro résultat**.
- `functions/.env` existe, correctement gitignoré (4 motifs dans `.gitignore`), contient exactement 3 clés (noms vérifiés, valeurs jamais lues) : `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET`, `ANTHROPIC_API_KEY`.
- Clé Google Maps : embarquée côté client par nécessité du SDK (`MapsConfig.apiKey`), pas un secret serveur — restriction par domaine/app reste une action Console GCP.
- Aucun secret trouvé dans l'historique Git visible localement (pas d'audit exhaustif de tout l'historique — hors de portée raisonnable de cette passe).

### Phase 6 — Stratégie de sauvegarde

- Toujours aucun export Firestore planifié dans le code (confirmé, pas re-construit — action Console GCP native, `gcloud firestore export` + Cloud Scheduler).
- Rollback : possible via `firebase deploy --only <cible> --project az-express-clean` en repointant sur un commit/tag antérieur (`v0.2-rc2` ou les 2 commits précédents) — jamais testé en conditions réelles.
- Restauration Firestore : dépend entièrement de l'export planifié ci-dessus, qui n'existe pas encore — **tant que ce n'est pas activé, aucune restauration réelle n'est possible en cas de perte de données**.

### Phase 7 — CI/CD

- `.github/workflows/ci.yml` a **3 jobs** (trouvaille de documentation : 2 seulement étaient documentés depuis le Prompt 16/38) : `flutter` (analyze + test), `functions` (`npm test`), `firestore-rules` (`npm run test:rules`, Java préinstallé sur les runners `ubuntu-latest`).
- `package.json` racine confirme le script `test:rules` existe et correspond.
- Le remote GitHub existe et le code est poussé (Prompt 60) — la CI a dû se déclencher au moins une fois, mais son résultat n'est **pas vérifiable depuis cet environnement** (`gh` CLI indisponible ici).
- Aucun déploiement automatique en production dans le workflow — conforme à l'instruction explicite de ne jamais déployer automatiquement.

### Validation finale

`flutter analyze` : 5 avertissements préexistants, 0 erreur (inchangé). `npm test` : **155/155**. `firebase deploy --only {firestore,storage,functions} --dry-run` : les 3 réussis contre le projet réel. Cloud Functions load : **53 exports**, chargement propre. Aucun code modifié par cette section.

---

### 🎯 Production readiness status : **READY TO DEPLOY**

Aucun bloqueur de code trouvé — les 3 cibles de déploiement (`firestore`, `storage`, `functions`) compilent/packagent toutes sans erreur contre le projet réel, aucun secret codé en dur, aucune règle dangereuse, RC2 déjà committée/taguée/poussée. Les seuls éléments restants sont soit des actions Console Firebase humaines (App Check, sauvegardes), soit des décisions de mise à niveau de dépendances à planifier avant octobre 2026 (Node 20, SDK `firebase-functions`) — aucun des deux n'empêche un déploiement contrôlé aujourd'hui.

#### 1. Production readiness status
**READY TO DEPLOY** — sous supervision humaine active, cohérent avec le verdict global READY PILOT EXTENDED (Prompt 60). Pas de blocage technique ; les actions restantes sont opérationnelles (Console) ou planifiables (dépendances), pas des correctifs de code en attente.

#### 2. Liste exacte des actions Console Firebase manuelles (aucune ne peut être faite depuis ce code)
1. **App Check** : activer dans la console Firebase (Play Integrity pour Android, DeviceCheck pour iOS), enregistrer le jeton de debug généré au premier lancement, obtenir une clé reCAPTCHA v3/Enterprise pour le web avant d'y activer App Check.
2. **Sauvegarde Firestore** : activer l'export planifié natif GCP (Firestore → Sauvegardes, ou `gcloud firestore export` + Cloud Scheduler) — aucune sauvegarde n'existe à ce jour.
3. **Vérifier l'exécution réelle de la CI sur GitHub Actions** (3 jobs, voir Phase 7) — non vérifiable depuis cet environnement.
4. **Planifier la mise à niveau du runtime Node.js 20** avant le 2026-10-30 (décommissionnement), et la mise à niveau du SDK `firebase-functions` (changements cassants attendus, à tester en environnement séparé avant tout déploiement).
5. **Restreindre la clé API Google Maps par domaine/app** dans Google Cloud Console (déjà signalé depuis la mémoire `project_maps_cost_audit`, jamais fait).
6. **Enregistrer les secrets `functions/.env`** (`FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET`, `ANTHROPIC_API_KEY`) via `firebase functions:config:set` ou Secret Manager si un jour un second mainteneur rejoint le projet (fonctionnel tel quel pour un mainteneur unique).

#### 3. Risques restants (tous déjà connus, aucun nouveau — voir Section 13 pour le détail complet)
Aucun changement par rapport à la liste des 11 risques acceptés du Prompt 60 — ce prompt n'en a trouvé aucun de plus, seulement confirmé qu'aucun n'empêche un déploiement technique. Les deux nouveautés de cette passe (dépréciation Node 20, CI à 3 jobs) sont des points opérationnels, pas des risques de sécurité/argent.

#### 4. Commandes exactes pour déployer quand approuvé

```bash
# Vérification finale avant tout déploiement réel (aucune de ces commandes n'écrit en production)
firebase deploy --only firestore --dry-run
firebase deploy --only storage --dry-run
firebase deploy --only functions --dry-run

# Déploiement réel — à exécuter uniquement sur approbation explicite, un par un
firebase deploy --only firestore:rules --project az-express-clean
firebase deploy --only storage --project az-express-clean
firebase deploy --only functions --project az-express-clean

# Build + déploiement Hosting (web), si voulu dans la même passe
flutter build web --release
firebase deploy --only hosting --project az-express-clean
```

**Recommandation d'ordre** : `firestore:rules` et `storage` d'abord (aucune dépendance sur le code Functions, rollback immédiat si problème via un nouveau `firebase deploy --only firestore:rules` pointant sur l'ancien fichier) — puis `functions` (recompile/redéploie les 53 fonctions ; en cas d'échec sur une fonction, Firebase ne déploie que celles qui compilent, les autres gardent leur version précédente) — `hosting` en dernier, indépendant des deux autres. Ne pas tout déployer en une seule commande `firebase deploy` sans cible pour cette première mise en production réelle — déployer cible par cible permet de vérifier chaque étape avant la suivante.

---

## 15. CI/CD & Release Pipeline — Master Prompt 62

Audit-only, conformément à l'instruction explicite du prompt (« ne pas changer la logique métier, ne pas modifier les paiements, ne pas refactoriser » — cette passe concerne uniquement CI/CD, build, validation automatique, release safety). Aucun code modifié.

### Phase 1 — Audit GitHub Actions

`.github/workflows/ci.yml` — 1 seul fichier, **3 jobs** :
| Job | Contenu | État |
|---|---|---|
| `flutter` | `flutter analyze` + `flutter test` | ✅ Fonctionnel (5 avertissements préexistants, 1 test placeholder) |
| `functions` | `npm test` (`functions/`) | ✅ Fonctionnel (155 tests) |
| `firestore-rules` | `npm run test:rules` (émulateur Firestore, Java préinstallé) | ✅ Présent, jamais vérifié en exécution réelle depuis cet environnement |

**Jobs manquants** (vérifié par lecture directe du YAML) : aucun build Android (`flutter build apk`/`appbundle`), aucun build Web (`flutter build web`), aucune validation Firebase (même un `--dry-run`). La CI valide le code source, jamais qu'il produit un artefact déployable.

### Phase 2 — Protection de branche

**Non vérifiable depuis cet environnement** (paramètre GitHub Console, pas un fichier du dépôt ; `gh` CLI indisponible). Constats locaux : une seule branche (`master`), aucun `CODEOWNERS`, aucun template de PR, historique linéaire sans merge commit — cohérent avec un flux à mainteneur unique, pas un flux PR obligatoire aujourd'hui.

### Phase 3 — Build release

- **Android** : `applicationId = "com.azexpress.app"` (correctement branded) ; signing config présent et fonctionnel (`key.properties` + `release.keystore` existent localement, **jamais commités** — vérifié `git ls-files`) ; ProGuard/minification activés pour `release`. **Build release Android opérationnel.**
- **🔴 iOS** : `PRODUCT_BUNDLE_IDENTIFIER = com.example.azExpressClean` — bundle ID par défaut de `flutter create`, jamais changé. **Bloque toute soumission App Store/TestFlight** (Apple refuse `com.example.*`). Pas corrigé (décision produit/compte développeur, pas une simple édition de fichier).
- **Web** : `flutter build web --release` testé réellement dans cet audit — **réussit proprement** (~104s, tree-shaking actif).

### Phase 4 — Secrets CI

Zéro secret GitHub référencé dans `ci.yml` (`grep "secrets\."` : 0 résultat) — cohérent avec l'absence de job de déploiement. Secrets qui seraient nécessaires pour un futur job de déploiement/build signé (aucun n'existe aujourd'hui) : jeton Firebase CI ou compte de service JSON, keystore Android encodé + mots de passe, certificats/profils Apple pour un build iOS signé. Aucun secret affiché ou lu en clair pendant cet audit.

### Phase 5 — Release safety

- Rollback : procédure manuelle uniquement (`git revert`/retour à un tag + redéploiement ciblé) — jamais testé en conditions réelles.
- **Incohérence de version trouvée** : tag git `v0.2-rc2` vs. `pubspec.yaml`/Android/iOS tous à `1.0.0+1`/`1.0`/`1` — deux schémas de version jamais synchronisés.
- Flux hotfix : inexistant formellement (une seule branche) — recommandation pour plus tard, pas construit ici.

### Validation exécutée

`flutter analyze` (5 avertissements préexistants, 0 erreur), `flutter test` (1/1 vert), `npm test` (**155/155**), `flutter build web --release` (réussi), YAML de `ci.yml` relu et cohérent.

---

### 🎯 CI STATUS : **READY**

Le pipeline CI existant est fonctionnel, sans YAML cassée, et couvre correctement l'analyse statique et les tests automatisés sur les 3 composantes testables du projet (Flutter, Cloud Functions, règles Firestore). Le blocueur trouvé (bundle ID iOS) est un problème de **préparation au store iOS**, pas un défaut de la CI elle-même — la CI continuerait de fonctionner et de protéger contre les régressions même sans ce correctif.

#### 1. Jobs actifs
`flutter` (analyze + test), `functions` (npm test, 155 tests), `firestore-rules` (émulateur, tests de règles) — tous déclenchés sur push/PR vers n'importe quelle branche.

#### 2. Jobs manquants
Build Android (`flutter build apk`/`appbundle`), build Web (`flutter build web --release`), validation Firebase (`firebase deploy --only ... --dry-run` en CI plutôt que manuel) — aucun n'est bloquant pour la CI actuelle, tous seraient des additions utiles pour une vraie chaîne de release automatisée.

#### 3. Actions GitHub manuelles
1. Activer la protection de la branche `master` (Settings → Branches) : exiger une Pull Request, exiger que les 3 checks CI passent avant merge, interdire le force-push et la suppression de branche.
2. **Corriger `PRODUCT_BUNDLE_IDENTIFIER` iOS** (`com.example.azExpressClean` → un identifiant réel, ex. `com.azexpress.app` pour cohérence avec Android) avant toute tentative de build/soumission iOS — décision produit à valider explicitement, pas exécutée dans cet audit.
3. Décider et documenter un schéma de version unique (réconcilier les tags git `vX.Y-rcN` avec `pubspec.yaml`).
4. Si une CD (déploiement continu) est un jour voulue : créer les secrets GitHub nécessaires (jeton/compte de service Firebase, keystore Android encodé, certificats Apple) — aucun n'existe aujourd'hui, cohérent avec l'absence de job de déploiement.

#### 4. Procédure de release officielle AZ Express (proposée, à valider)
1. Merger sur `master` uniquement via PR une fois la protection de branche activée (action 1 ci-dessus).
2. Vérifier que les 3 checks CI sont verts sur le commit à releaser.
3. Bumper `pubspec.yaml` (`version: X.Y.Z+B`) de façon cohérente avec le tag prévu.
4. Créer un tag git annoté (`git tag -a vX.Y.Z -m "..."`) et le pousser (`git push origin vX.Y.Z`).
5. Déployer cible par cible en production (commandes exactes : voir Section 14, Prompt 61) : `firestore:rules` → `storage` → `functions` → `hosting`.
6. Pour un build mobile (Android d'abord, iOS une fois le bundle ID corrigé) : `flutter build appbundle --release` / `flutter build ipa --release`, publication manuelle via Play Console/App Store Connect (aucune automatisation CI n'existe pour ça aujourd'hui, et ce prompt demande explicitement de ne rien publier).

---

## 16. Android Play Store Release Preparation — Master Prompt 63

Audit-only, conformément à l'instruction explicite du prompt (« ne pas changer la logique métier, ne pas modifier Firebase, ne pas ajouter de fonctionnalités » — scope strictement Android release readiness). Aucun code modifié.

### Phase 1 — Config Android

`applicationId`/`namespace` = `com.azexpress.app` (branded, confirmé). `minSdk`/`targetSdk`/`compileSdk` jamais surchargés — dérivés de la version Flutter installée. Manifests `debug`/`profile` = boilerplate Flutter pur, aucune fuite de config debug en release.

**🟡 Nouveau risque, jamais signalé en 62 prompts** : Flutter installé sur le canal **beta** (3.45.0-0.1.pre), pas `stable` — risque réel pour une app financière de production, recommandé de repasser sur stable avant soumission réelle.

### Phase 2 — Versioning

Confirmé (Prompt 62) : tag git `v0.2-rc2` et version applicative `pubspec.yaml` (`1.0.0+1`) jamais synchronisés. Stratégie proposée (à valider) : `dev` (builds locaux non taggés) / `pilot` (pubspec aligné sur le tag pilote en cours) / `production` (premier upload Play Console avec `versionCode` strictement croissant, jamais réutilisé — discipline à respecter dès le premier upload).

### Phase 3 — Signing release

`key.properties`/`release.keystore` existent localement, jamais commités (`git ls-files` : 0 résultat). **Preuve la plus forte possible sans lire les secrets** : le build réel de cette passe (`flutter build appbundle --release`) a réussi à signer l'App Bundle — un keystore absent/mal configuré aurait fait échouer le build à l'étape de signature. Aucune clé privée lue ou affichée.

### Phase 4 — Permissions Android

14 permissions déclarées, toutes tracées à une fonctionnalité réelle : GPS premier plan/arrière-plan (livreur), caméra (selfie/preuve livraison), stockage média (image_picker, bien gaté par version SDK), micro (AZ IA/Courses), notifications, vibration, wake_lock. Aucune permission dangereuse non justifiée. `ACCESS_BACKGROUND_LOCATION` identifiée comme la permission demandant le plus d'effort Play Console (formulaire dédié + justification vidéo/captures requis par Google).

### Phase 5 — Play Store Policy (le cœur du verdict BLOCKED)

Politique de confidentialité publique existe (`/confidentialite`, datée 22 mai 2026), raisonnablement complète, utilisable comme URL Play Console.

**🔴 Trouvaille 1** : la politique de confidentialité et les pages légales publiques (`privacy_page.dart`, `terms_page.dart`, `home_page.dart`) nomment **"CinetPay"** comme prestataire de paiement — recherche exhaustive confirme **zéro trace de CinetPay dans `functions/`**, où seul FeexPay est réellement intégré depuis le Prompt 03. Les pages publiques décrivent un partenaire qui n'existe pas dans le code réel.

**🔴 Trouvaille 2** : la section « Partage des données » ne mentionne jamais Anthropic/Claude, alors qu'AZ IA envoie du texte (et de la voix transcrite) à l'API Anthropic — un tiers destinataire réel de données utilisateur, non déclaré. Gap de conformité Play Console "Data Safety", pas cosmétique.

Aucune des deux trouvailles n'est corrigée dans cette passe (contenu légal public, décision explicite requise).

### Phase 6 — Release build (réellement exécuté)

`flutter build appbundle --release` → **succès**, `app-release.aab` réel produit (74,3 Mo). Avertissement non-fatal : *"failed to strip debug symbols from native libraries"* — root-cause identifiée (`flutter doctor -v`) : `cmdline-tools` Android manquants + licences SDK non acceptées **sur cette machine spécifique** — un problème d'environnement local, pas un défaut du code. AAB valide et installable malgré cet avertissement.

### Validation exécutée

`flutter analyze` (5 avertissements, inchangé), `flutter test` (1/1 vert), `npm test` (**155/155**), `flutter build appbundle --release` (**réussi**, AAB réel produit et signé).

---

### 🎯 ANDROID RELEASE STATUS : **BLOCKED**

Bloqué pour des raisons de **conformité Play Store (contenu), pas techniques** — le pipeline de build/signature fonctionne réellement et produit un artefact valide. Les deux trouvailles de la Phase 5 sont rapides à corriger (édition de texte sur 3 pages) mais nécessitent une décision explicite avant toute soumission, puisqu'il s'agit de contenu légal public destiné aux utilisateurs et à la revue Google.

#### 1. Ce qui est prêt
- `applicationId` correctement brandé (`com.azexpress.app`), aucun placeholder Flutter.
- Signing release fonctionnel de bout en bout (keystore + `key.properties` présents, jamais commités, build réellement signé avec succès).
- Permissions Android toutes justifiées, aucune superflue ou dangereuse.
- Build release réel réussi (`app-release.aab`, 74,3 Mo).
- Politique de confidentialité existe déjà et est réutilisable comme URL Play Console (une fois les 2 trouvailles corrigées).
- Aucune config debug ne fuit en release.

#### 2. Ce qui bloque
1. **🔴 La politique de confidentialité/CGU nomment le mauvais prestataire de paiement ("CinetPay" au lieu de FeexPay)** — à corriger avant soumission (décision : confirmer que FeexPay est bien le seul prestataire réel, puis mettre à jour `privacy_page.dart`/`terms_page.dart`/`home_page.dart`).
2. **🔴 Anthropic/Claude (AZ IA) non déclaré comme tiers destinataire de données** dans la politique de confidentialité — à ajouter avant soumission (risque de non-conformité Data Safety Play Console).
3. **🟡 Flutter sur canal beta** — recommandé de repasser sur `stable` avant le build de soumission officiel (pas un blocage dur, un risque de production).
4. **🟡 Toolchain Android local incomplet** (`cmdline-tools` manquants, licences non acceptées) — cause l'avertissement de symboles de debug non retirés ; à corriger sur la machine qui produira le build final de soumission.

#### 3. Actions Play Console nécessaires (aucune ne peut être faite depuis ce code)
1. Créer/configurer l'app dans Play Console (si pas déjà fait) sous `com.azexpress.app`.
2. Remplir le formulaire Data Safety (position précise + arrière-plan, infos personnelles, photos, infos financières, messages, identifiants d'appareil) — une fois les 2 trouvailles de la Phase 5 corrigées dans la politique de confidentialité qui sert de référence.
3. Préparer la déclaration dédiée "Accès à la position en arrière-plan" (justification + captures d'écran/vidéo) — obligatoire pour `ACCESS_BACKGROUND_LOCATION`.
4. Fournir l'URL de la politique de confidentialité (`/confidentialite`) dans la fiche Play Console.
5. Configurer le premier upload sur un canal de test interne/fermé avant toute diffusion publique, avec un `versionCode` cohérent avec la stratégie de versioning à adopter (Phase 2).

#### 4. Commandes officielles de build
```bash
# Vérification avant tout build de soumission réelle
flutter doctor -v                      # confirmer un toolchain Android propre (cmdline-tools + licences)
flutter channel stable && flutter upgrade   # recommandé avant la vraie soumission (actuellement sur beta)

# Build App Bundle (format requis par Play Console depuis 2021)
flutter build appbundle --release

# Résultat produit à : build/app/outputs/bundle/release/app-release.aab
# Upload manuel via Play Console (aucune automatisation CI n'existe pour ça aujourd'hui,
# et ce prompt demande explicitement de ne pas publier).
```

---

## 17. iOS App Store Release Preparation — Master Prompt 64

Audit iOS complet (aucune modification de logique métier/Firebase/paiement — un seul correctif de configuration native appliqué, voir Phase 1). Verdict plus sévère qu'Android : blocage technique ET de contenu.

**Note de transparence** : une commande de listage des clés `.env` (dart-define, distinct de `functions/.env`) a affiché par erreur le contenu complet du fichier. Valeurs concernées : configuration Firebase côté client (non secrète par conception Firebase — sécurité réelle = règles Firestore/Storage). Les vrais secrets (`functions/.env` : FeexPay/Anthropic) n'ont pas été touchés.

### Phase 1 — Config iOS

- `PRODUCT_BUNDLE_IDENTIFIER = com.example.azExpressClean` confirmé à 5+3 occurrences (`project.pbxproj`) — placeholder `flutter create`, jamais changé.
- **🔴 `ios/Podfile` n'a jamais existé** — confirmé par `git log --all` (aucun résultat) et par l'absence de `Pods.xcodeproj` dans `Runner.xcworkspace` (signal indépendant confirmant que CocoaPods n'a jamais été intégré). **Ce projet n'a jamais été buildé pour iOS.**
- **🔴 `GoogleService-Info.plist` absent** — gitignored (attendu localement), jamais fourni ni committé.
- **Aucun fichier `.entitlements`** — aucune capacité Xcode (Push, Background Modes...) jamais activée.
- **🔴 Corrigé** : `Info.plist` n'avait que 2 des 6 déclarations de confidentialité requises par des fonctionnalités déjà existantes et fonctionnelles sur Android (caméra, position premier/arrière-plan, photothèque). Sur iOS, l'absence de ces clés cause un **crash immédiat** à l'appel de l'API correspondante — pas un simple refus App Store. Ajouté : `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes` (`location`, `remote-notification`). Validé XML/plist bien formé après édition. Traité comme rendre des fonctionnalités déjà existantes non-crashantes sur iOS, pas une nouvelle fonctionnalité.

### Phase 2 — Bundle ID

`.env` racine contient déjà `FIREBASE_IOS_BUNDLE_ID: com.azexpress.app` — cible déjà décidée ailleurs dans le projet, cohérente avec l'`applicationId` Android, mais jamais appliquée à Xcode. **Non changé dans cette passe** (instruction explicite : ne pas changer sans confirmer l'impact Firebase/App Store réel — impossible de vérifier depuis cet environnement si une app iOS a été enregistrée en Console Firebase sous ce Bundle ID exact).

### Phase 3 — App Store Privacy

Mêmes catégories de données qu'Android (Prompt 63) : position précise + arrière-plan, photos, documents KYC, téléphone, commandes, paiements (FeexPay), texte/audio AZ IA (Anthropic), notifications. Les 2 trouvailles de contenu du Prompt 63 (mauvais prestataire de paiement nommé "CinetPay", Anthropic non divulgué) s'appliquent identiquement à la déclaration App Store Privacy Nutrition Label — même politique de confidentialité, mêmes 2 corrections requises avant soumission sur les deux stores.

### Phase 4 — Capacités iOS

Push Notifications (nécessite compte Apple Developer + clé APNs, rien configuré), Background Modes (`Info.plist` fait, capacité Xcode restante), Location/Camera/Microphone (désormais déclarés), App Check DeviceCheck (déjà préparé côté Dart, Prompt 53, aucune capacité Xcode supplémentaire requise pour DeviceCheck spécifiquement), Signatures (`CODE_SIGN_STYLE = Automatic`, nécessite un compte Apple Developer connecté dans Xcode sur une vraie machine Mac).

### Phase 5 — Build readiness (testé réellement)

`flutter build ios` → **`Could not find a subcommand named "ios" for "flutter build"`** — Flutter retire ce sous-commande sur un hôte non-macOS. **Structurellement impossible depuis cet environnement Windows**, aucun contournement légitime possible — nécessite une vraie machine macOS avec Xcode (locale ou CI Mac).

### Validation exécutée

`flutter analyze` (5 avertissements, inchangé), `flutter test` (1/1 vert), `npm test` (**155/155**), `Info.plist` validé bien formé.

---

### 🎯 iOS RELEASE STATUS : **BLOCKED**

Blocage **technique ET de contenu**, plus sévère que le blocage Android (Prompt 63, qui n'était que du contenu). Le projet iOS n'a jamais été réellement construit — CocoaPods jamais intégré, Firebase natif jamais configuré, entitlements jamais créés — et aucun build ne peut être tenté depuis cet environnement Windows.

#### 1. Ce qui est prêt
- Bundle ID cible déjà identifié sans ambiguïté (`com.azexpress.app`, cohérent avec Android et déjà présent dans `.env`).
- App Check DeviceCheck déjà préparé côté Dart (Prompt 53).
- `Info.plist` désormais complet pour les déclarations de confidentialité des fonctionnalités existantes (corrigé cette passe).
- Politique de confidentialité déjà rédigée et réutilisable pour App Store Privacy (une fois les 2 corrections de contenu du Prompt 63 faites).

#### 2. Ce qui bloque
1. **🔴 `ios/Podfile` inexistant** — aucune dépendance native (Firebase, plugins) jamais installée ; à générer sur une vraie machine Mac (`flutter build ios`/`pod install` lors du premier build réel).
2. **🔴 `GoogleService-Info.plist` absent** — à télécharger depuis la Console Firebase une fois l'app iOS enregistrée sous le bon Bundle ID.
3. **🔴 `PRODUCT_BUNDLE_IDENTIFIER` toujours `com.example.azExpressClean`** — cible déjà connue (`com.azexpress.app`) mais changement non appliqué, décision à confirmer.
4. **🔴 Aucun entitlements/capacité Xcode configuré** (Push Notifications, Background Modes) — nécessite Xcode + compte Apple Developer.
5. **🔴 Build iOS impossible depuis cet environnement** — nécessite une machine macOS.
6. Les 2 trouvailles de contenu du Prompt 63 (prestataire de paiement erroné, Anthropic non divulgué) s'appliquent aussi à App Store Privacy.

#### 3. Actions Apple Developer nécessaires
1. Créer/vérifier l'app dans App Store Connect sous le Bundle ID final choisi.
2. Enregistrer l'app iOS dans la Console Firebase sous ce même Bundle ID, télécharger `GoogleService-Info.plist`.
3. Activer les capacités Push Notifications et Background Modes dans Xcode (génère les entitlements), configurer une clé APNs dans Apple Developer.
4. Configurer la signature automatique (`CODE_SIGN_STYLE = Automatic`) avec un compte Apple Developer connecté à Xcode.
5. Remplir la déclaration App Store Privacy Nutrition Label (mêmes catégories que Play Console Data Safety, Prompt 63) une fois la politique de confidentialité corrigée.

#### 4. Configuration finale recommandée
1. Sur une vraie machine macOS avec Xcode : mettre à jour `PRODUCT_BUNDLE_IDENTIFIER` → `com.azexpress.app` (et `com.azexpress.app.RunnerTests` pour la cible de tests) dans les 3 configurations (Debug/Release/Profile).
2. Enregistrer l'app dans Firebase Console sous ce Bundle ID, placer `GoogleService-Info.plist` dans `ios/Runner/`.
3. Lancer `flutter build ios --release` une première fois pour générer/valider le `Podfile` et intégrer CocoaPods.
4. Activer Push Notifications + Background Modes dans Xcode (Signing & Capabilities).
5. Corriger la politique de confidentialité (prestataire de paiement réel, divulgation Anthropic) avant de remplir les déclarations Privacy des deux stores.
6. `flutter build ipa --release` pour produire l'archive de soumission, une fois tout ce qui précède en place.
