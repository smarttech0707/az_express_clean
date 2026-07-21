# AZ Express — Audit final avant mise en production

**Date** : 2026-07-09 (mise à jour Master Prompt 84 — « Operations Runbook & Post-Launch Monitoring » — voir Section 39 ; manuel d'exploitation complet dans [`OPERATIONS_RUNBOOK.md`](../OPERATIONS_RUNBOOK.md) à la racine du dépôt)

**📖 MANUEL D'EXPLOITATION QUOTIDIENNE CRÉÉ.** Le Prompt 84 a produit `OPERATIONS_RUNBOOK.md` — routine admin matin/journée/soir, surveillance technique, procédures d'incident par rôle, clôture financière quotidienne, signaux de fraude à surveiller, seuils de croissance avant grande échelle. Document séparé de celui-ci (historique d'audit) et de `CLAUDE.md` (doc développeur) — voir Section 39 pour le résumé, le fichier lui-même pour le détail opérationnel complet.

**📋 PLAN D'ACTIVATION PRÊT, EN ATTENTE D'UN DÉBLOCAGE EXTERNE (Prompt 83).** Le Prompt 83 a figé l'ordre exact de déploiement (règles → 4 lots de Cloud Functions, commandes prêtes à copier-coller) et la checklist GO LIVE finale — voir Section 38. Rien n'a été déployé cette passe (code freeze strict, section 1 du prompt demandait explicitement de ne rien déployer). La liste des 23 fonctions manquantes a été recalculée exactement (diff programmatique entre les 53 exports du code et les 30 fonctions réellement live) et répartie dans les 4 lots demandés.

**🎯 VERDICT ACTUEL : NO GO lancement réel tant que la facturation Cloud Build n'est pas débloquée — retesté réellement au Prompt 82 (nouvel essai de déploiement, échec identique), tout le reste est prêt côté code.** Bonne nouvelle indépendante détectée : Flutter est passé sur le canal stable (risque beta du Prompt 63 fermé). Firebase Hosting confirmé live (`/confidentialite` et `/delete-account` répondent 200 OK, utilisables directement pour Play Console). Voir Section 37 pour le détail complet et la checklist opérationnelle restante (données de seed, canal support, assets Play Store, simulation Jour J réelle).

**🎯 VERDICT précédent (Prompt 81) : GO pour le gel de version côté code** — dernier audit avant gel (TODO dangereux, code debug, clés exposées, données sensibles, UX compte supprimé/suspendu, config Play Store) : zéro bug bloquant, zéro faille de sécurité active trouvée, zéro fichier modifié cette passe. Le seul vrai blocage restant est externe au code (facturation Cloud Build/GCP, voir ci-dessous) — voir Section 36 pour le détail complet et la liste des derniers points mineurs non bloquants (clé Maps codée en dur, version applicative non synchronisée avec les tags git).

**🔴 Trouvaille la plus sérieuse de tout ce document en termes de sécurité financière : le Prompt 80 a trouvé et corrigé 3 failles critiques + 1 élevée dans `firestore.rules` qui, combinées, auraient permis de créer de l'argent réel sans qu'aucun client ne paie** (crédit d'un partenaire restaurant/pharmacie sans vérification de paiement dans `deliverOrderCF`, contournement du dispatch serveur par auto-assignation client d'un livreur, flip du statut "payé" par écriture directe du livreur, changement arbitraire du statut de commande par un partenaire) — voir Section 35 pour le détail complet. Les règles corrigées peuvent être déployées indépendamment du blocage Cloud Functions ci-dessous et fermeraient à elles seules 3 des 4 failles ; la 4ᵉ (crédit partenaire) nécessite aussi le déploiement de `deliverOrderCF`, toujours parmi les 23 fonctions non déployées.

**Ce qui a changé depuis la version du Prompt 71 (Prompts 72-80 non résumés ici en tête de document, chacun documenté dans sa propre section numérotée — 27 à 35)** : le Prompt 79 clôt une série d'audits de préparation terrain (données/admin/flux partenaires/lancement business/cash/fraude livreur/support) par un audit de charge/performance. Capacité pilote confirmée suffisante (100 clients/20 livreurs/50 commandes-jour). Deux correctifs sûrs appliqués (`.limit()` sur 2 écrans admin récents, `Image.network`→`CachedNetworkImage` sur un troisième). Trouvaille principale, documentée mais délibérément non corrigée en masse : ~30 écrans admin lisent des collections sans `.limit()`, dont certains (`admin_earnings.dart`, `admin_drivers_ranking.dart`) agrègent côté client — les borner aveuglément fausserait silencieusement des totaux financiers affichés à l'admin. Le blocage de déploiement Cloud Functions (ci-dessous) reste la limitation la plus significative du projet, inchangé par cette passe.

**Historique antérieur (jusqu'au Prompt 71)** :

**🔴 Avertissement le plus important de tout ce document, désormais démontré concrètement au Prompt 71 : le blocage de déploiement Cloud Functions (ci-dessous) n'est pas qu'un chiffre abstrait « 30/53 » — le traçage direct du code de création de commande (Section 26) prouve qu'AUCUNE commande de livraison ne peut aboutir aujourd'hui en production. `dispatchOrderToDriver` n'étant pas déployée, chaque commande créée par un vrai utilisateur expire silencieusement après 10 minutes, quel que soit le nombre de livreurs réellement disponibles. Voir Section 26 pour le parcours complet tracé jusqu'à l'écran utilisateur.**

**🔴 Avertissement précédent, toujours vrai, réaffirmé au Prompt 67 : le blocage Cloud Functions décrit au Prompt 66 est TOUJOURS PRÉSENT — les correctifs annoncés (facturation Google Maps) ne concernaient pas le bon axe de facturation.** Le Prompt 67 affirmait le blocage résolu (clé API Maps recréée, quotas, restrictions Android) — retesté directement (nouvelle tentative réelle du Lot 1, les 6 mêmes fonctions qu'au Prompt 66) plutôt que supposé, et **l'erreur est identique au caractère près** : `HTTP 403, Write access to project 'az-express-clean' was denied: please check billing account associated and retry`. La facturation Google Maps (API Directions/Places/Geocoding/Maps SDK) et la facturation Cloud Build/Cloud Functions (nécessaire à tout déploiement de fonction) sont **deux axes de facturation distincts** sur la Google Cloud Console — corriger l'un ne corrige pas l'autre. Toujours **30 fonctions déployées sur 53** ; les 11 correctifs financiers critiques et les 3 autres blocs (Immobilier, AZ IA, infrastructure) restent absents de la production réelle.

**Ce qui a changé depuis la version du Prompt 66** : nouvelle tentative réelle de déploiement Lot 1 — échec identique, confirmant que le blocage n'a pas été résolu par les actions décrites dans le contexte du Prompt 67 (voir avertissement ci-dessus pour la distinction exacte des deux facturations). Progrès réel, distinct du blocage Functions : les règles Firestore/Storage ont été redéployées réellement, avec cette fois confirmation explicite du déploiement réussi des 37 index Firestore. `flutter analyze`/`npm test` (156/156)/`flutter build apk --release` tous reconfirmés propres. Voir Section 20 pour le détail complet.

**Historique — mise à jour Master Prompt 66 (« Controlled Firebase Production Deployment ») :** Le Prompt 65 avait comparé, via `firebase functions:list` (lecture seule), les fonctions **réellement déployées en production** (30) aux fonctions **du code local** (53) — 23 fonctions jamais déployées, parmi lesquelles la totalité d'AZ IA, la totalité du module Immobilier, et surtout **toutes les Cloud Functions qui corrigent les 11 bugs financiers critiques de cette session**. Le Prompt 66 a **réellement déployé** `firestore.rules`/`storage.rules` en production (confirmé : les deux étaient déjà à jour, probablement déployées lors d'un commit externe entre les Prompts 60 et 65) — **la couche règles de sécurité est donc désormais confirmée à jour**. Mais la tentative de déployer les 23 Cloud Functions manquantes (par lots, comme demandé) a été bloquée dès le premier lot par un problème de facturation Google Cloud (« Write access... denied: please check billing account », HTTP 403) — un blocage d'infrastructure, pas de code, arrêté immédiatement sans contournement. **Tant que ce blocage de facturation n'est pas résolu côté Google Cloud Console, les 23 correctifs (dont les 11 bugs financiers) restent absents de la production réelle** — si des utilisateurs réels utilisent déjà l'app, ils restent exposés aux bugs originaux.

**Ce qui a changé depuis la version du Prompt 65** : cette fois, un déploiement réel a été exécuté (le Prompt 66 était explicite et détaillé sur l'objectif « déployer », contrairement à l'ambiguïté du Prompt 65). `firestore.rules`/`storage.rules` déployés en production pour de vrai — les deux étaient déjà à jour (aucun changement réel nécessaire, probablement déjà poussés lors d'un commit externe entre les Prompts 60 et 65). La tentative de déploiement des 23 Cloud Functions manquantes, préparée en 4 lots exactement comme demandé (infrastructure/modules métier/argent/AZ IA), a été bloquée dès le Lot 1 par un problème de facturation Google Cloud Platform (HTTP 403, `generateUploadUrl` refusé) — arrêtée immédiatement conformément à l'instruction explicite « ne pas continuer si erreur », vérifié qu'aucun dégât n'a eu lieu (30 fonctions toujours présentes, inchangées). Voir Section 19 pour le détail complet.

**Ce qui a changé depuis la version du Prompt 64** : préparation de l'activation Firebase production, sans déploiement réel — l'utilisateur, interrogé explicitement sur l'ambiguïté du prompt (qui demandait un rollout progressif réel sans répéter la mise en garde « ne rien déployer » des Prompts 61-64), a choisi de préparer/valider seulement. Trouvaille majeure ci-dessus (23 fonctions jamais déployées). Par ailleurs : le travail des Prompts 61-64 a été committé et tagué hors de cette conversation (nouveau tag `v0.3-rc3`, 2 nouveaux commits) — l'arbre de travail est désormais propre et synchronisé, contrairement à l'état documenté jusqu'au Prompt 60. Nouvelle trouvaille mineure : le compte Firebase a accès à 2 autres projets (probablement abandonnés), risque de confusion si un mauvais projet était sélectionné avant un déploiement futur.

**Date précédente** : 2026-07-03 (mise à jour Master Prompt 64 — « iOS App Store Release Preparation » — depuis la version Master Prompt 63)

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
- **Wallet, remboursements, commissions** : **11 bugs financiers critiques trouvés et corrigés au total sur toute la session** (3 avant Prompt 40, 6 aux Prompts 46-49, +1 le 2026-07-09 — double débit client/double crédit livreur sur les commandes pharmacie wallet, `pharmacie_garde.dart`↔`payOrderFromWalletCF`↔`deliverOrderCF`) — voir Section 4/9/21. Tous testés (156 tests au total dans `functions/`).
- **Vendeurs/livreurs** : logique de crédit/débit unifiée entre les 3 chemins de chaque opération sensible (app Flutter, expiration automatique, AZ IA) depuis les Prompts 51-52 (tarification, annulation).
- **Double paiement** : les 2 boutons de paiement sans protection anti-double-tap trouvés (Boutique, Pharmacie) sont corrigés (Prompts 48-49) ; aucun autre bouton de paiement critique trouvé non protégé.

### Commandes
- **Création** : tarification livraison unifiée sur un seul moteur (`TarifService`/`tarifService.js`) pour les 3 chemins (Flutter direct, AZ IA) depuis le Prompt 51 — reste ouvert : validation serveur du prix soumis par les 5 écrans Flutter directs (analysé, pas construit).
- **Dispatch** : entièrement côté serveur, verrouillage transactionnel (Prompt 26) ; **acceptation livreur désormais revérifiée en transaction** (`isSuspended`/`isOnline`/`isOnDelivery` re-checkés dans `acceptOrder()`, pas seulement au moment de l'offre — corrigé le 2026-07-09, voir Section 21) ; scan complet des livreurs en ligne sans `.limit()` (`dispatch.js`) documenté 🟡 à surveiller si la flotte grandit (Prompt 59), pas un problème mesurable aujourd'hui.
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
| Paiements wallet | **11 bugs réels au total trouvés et corrigés cette session** (3 avant Prompt 39, 6 aux Prompts 46-49) | **6 nouveaux bugs critiques corrigés** — le progrès le plus significatif de toute la session |
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
- **11 bugs de paiement réels au total trouvés et corrigés sur toute la session** (3 avant Prompt 39, 6 aux Prompts 46-49) — voir section 4. C'est désormais la partie du projet la plus intensément vérifiée et corrigée, alors qu'elle était initialement perçue comme « transactionnellement propre » sur la seule base d'une lecture de code sans traçage complet des flux.
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

**Critique** — aucune restante (les 11 bugs de paiement identifiés au total sont tous corrigés et testés).

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
**Critères d'entrée** : déjà remplis, renforcés par cette mise à jour — les 11 bugs de paiement critiques connus sont désormais tous corrigés et testés (contre 3 à la version précédente), le dispatch est fiable, la conciliation wallet tourne en surveillance passive, les boutons de paiement critiques sont protégés contre le double-tap.
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

Les 11 bugs financiers critiques trouvés sur l'ensemble de la session (paiement wallet cassé sur 3 modules, double-crédit sur 2 modules, non-débit vendeur à l'annulation, solde négatif possible, remboursement automatique Boutique jamais fonctionnel) sont **tous corrigés et couverts par des tests** (155 tests au total, contre 26 au tout début de cette série d'audits). Les 5 outils de création de commande AZ IA les plus critiques financièrement ont été testés directement et ne divergent d'aucune façon du comportement sécurisé de l'app Flutter (Prompt 55). La tarification livraison et la logique d'annulation sont désormais unifiées sur un seul chemin de vérité chacune, y compris pour AZ IA (Prompts 51-52) — plus de double moteur de prix, plus d'implémentation dupliquée de l'annulation. Les deux risques structurels qui semblaient les plus préoccupants en milieu de session (« deux systèmes Immobilier », « deux back-offices ») se sont révélés, après audit complet plutôt que supposition, être des architectures **complémentaires et non dangereuses** — avec, chemin faisant, la découverte et la correction de bugs réels et indépendants (bouton de contact cassé, formulaires publics du site vitrine entièrement non fonctionnels, connexion admin web trop permissive). La surveillance production a été auditée (Crashlytics propre, AZ IA déjà bien instrumentée, deux des six événements métier critiques déjà couverts automatiquement) et un vrai bug d'observabilité corrigé. Le dernier audit performance/coûts n'a trouvé **aucun risque de facturation Firebase explosif au volume pilote actuel**, et a corrigé le seul vrai bug de lectures Firestore répétées trouvé. Le niveau de maturité atteint — bugs financiers connus tous corrigés et testés, architecture comprise plutôt que supposée, surveillance en place, performance validée à l'échelle pilote — justifie d'passer d'un pilote restreint et prudent à un **pilote étendu**, toujours sous supervision humaine active, pas encore un lancement public non supervisé.

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
5. **🔴 (ajouté Prompt 68) Aucune page web publique de suppression de compte** — Google Play exige, pour toute app avec création de compte, un moyen de demander la suppression du compte/données accessible aussi depuis le web sans réinstaller l'app. Seule `/confidentialite`/`/conditions` existent comme routes web publiques ; la suppression in-app (`profil_client.dart`) ne couvre que les clients, aucun autre rôle (livreur/vendeur/restaurant/pharmacie/boulangerie/agent Ekbine). Voir Section 23 pour le détail complet.

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

---

## 18. Firebase Production Activation & Safe Rollout — Master Prompt 65

**Décision préalable** : ce prompt demandait un rollout réel progressif (règles puis 53 Cloud Functions) sans répéter l'instruction « ne rien déployer automatiquement » des Prompts 61-64. Un vrai déploiement en production étant une action à fort impact et difficile à annuler proprement, la question a été posée explicitement à l'utilisateur avant d'agir. **Réponse : préparer/valider seulement, ne pas déployer dans cette passe.** Tout ce qui suit est du dry-run/lecture seule — rien n'a été poussé vers le projet réel.

### Phase 1 — Pre-deploy check

- Git : arbre propre, `master` synchronisé avec `origin/master`. Nouveau tag `v0.3-rc3` + 2 nouveaux commits capturant les Prompts 61-64 (faits hors de cette conversation) — plus de travail non commité à ce jour.
- Firebase CLI 15.18.0, projet actif `az-express-clean` (cohérent avec `.firebaserc`). **Nouveau** : le compte a accès à 2 autres projets (`az-express-e0e2f`, `azexpress-7f8ed`), probablement abandonnés — risque de confusion à garder en tête, pas un risque immédiat (`.firebaserc` fixe déjà le bon projet par défaut).
- `functions/.env` : toujours 3 clés (noms vérifiés uniquement).

**🔴 Trouvaille critique** : `firebase functions:list` (lecture seule) montre **30 fonctions déployées** contre **53 en local** — **23 fonctions jamais déployées**, incluant la totalité d'AZ IA (`azIaChat`, `aiConfirmAction`, `aiCleanupExpiredPendingActions`, `clearAiHistory`), la totalité du module Immobilier, et surtout **toutes les Cloud Functions corrigeant les 11 bugs financiers critiques de cette session** (`payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`), la correction du mot de passe pharmacie en clair (`pharmacieLogin`/`setPharmaciePassword`), et la migration serveur du dispatch (`dispatchOrderToDriver`). Voir l'avertissement en tête de document.

### Phase 2 — Firestore/Storage rules deploy readiness

`firebase deploy --only firestore:rules --dry-run` et `--only storage --dry-run` réussissent tous les deux contre le projet réel. Ordre recommandé confirmé : `firestore:rules` puis `storage` en premier (indépendants du code Functions, rollback immédiat).

### Phase 3 — Cloud Functions deploy readiness

Recommandation de déploiement **progressif**, pas un `firebase deploy --only functions` global d'un coup, vu l'ampleur du rattrapage : (1) fonctions non-financières à faible risque (Immobilier, notifications manquantes) ; (2) fonctions financières (remplacent un comportement déjà cassé en prod — amélioration nette, mais à surveiller de près juste après) ; (3) AZ IA en dernier (le système le plus neuf/complexe). Node 20/dépendances/secrets/région déjà audités (Prompts 61-62), rien de nouveau.

### Phase 4 — Post-deploy validation (plan, pas exécuté)

Ordre recommandé après un vrai déploiement : Auth → Firestore (lecture commande existante) → Storage (upload photo) → Functions (`firebase functions:list`, confirmer 53) → Notifications (push test) → Wallet (`payOrderFromWalletCF` test, petit montant) → Commandes (cycle complet créer/dispatcher/annuler sur compte test) → AZ IA (échange simple).

### Phase 5 — App Check rollout (plan consolidé, rien de nouveau)

Observer les métriques pendant une période de rodage → enregistrer les jetons de debug CI/debug → vérifier Android/iOS/Web séparément → activer `enforceAppCheck` seulement après cette observation, jamais immédiatement.

### Phase 6 — Backup (procédure documentée, rien configuré)

`gcloud` CLI confirmé indisponible dans cet environnement. Recommandation : export planifié quotidien (Console Firebase ou `gcloud firestore backups schedules create`), conservation 7-14 jours pour un pilote, restauration toujours testée sur un projet de copie avant toute restauration réelle en prod.

### Validation exécutée

`flutter analyze` (5 avertissements, inchangé), `npm test` (**155/155**), dry-runs `firestore`/`storage` réussis contre le projet réel, `firebase functions:list` (lecture seule) confirmé 30 vs 53 fonctions — aucun déploiement réel, aucun code modifié.

---

### 🎯 PRODUCTION STATUS : **BLOCKED** (au sens strict de ce prompt : rien n'a été activé)

Le code est prêt (voir Prompts 60-64), mais la production réelle n'a reçu aucun des correctifs de cette session — le statut n'est donc « LIVE READY » que pour le code, jamais encore pour les utilisateurs réels.

#### 1. Ce qui est déployé
30 Cloud Functions (notifications, fonctions les plus anciennes du projet — `autoExpireOrders`, `createSubAdmin`/`deleteSubAdmin`, `feexPayWebhook`, `initiateFeexPayPayment`/`initiateWithdrawal`, `ekClientConfirmOrder`, `cleanupExpiredRateLimits`, `enforceOrderRateLimit`) — probablement datées d'avant cette série d'audits (~Prompt 20-25).

#### 2. Ce qui reste manuel
- Déployer les 23 fonctions manquantes (ordre recommandé en Phase 3).
- Déployer `firestore.rules`/`storage.rules` (dry-run déjà validé).
- Exécuter le plan de validation post-déploiement (Phase 4) sur un compte de test avant tout trafic réel.
- Rollout App Check progressif (Phase 5) — enforcement jamais immédiat.
- Configurer la sauvegarde Firestore planifiée (Phase 6) — action Console/gcloud, jamais faite à ce jour.

#### 3. Risques production
1. **🔴 Si des utilisateurs réels sont déjà actifs, ils utilisent la version non corrigée** de tous les bugs financiers déjà documentés comme résolus dans ce rapport.
2. Confusion possible entre 3 projets Firebase accessibles au même compte (mitigé par `.firebaserc`).
3. Tous les risques déjà documentés Sections 13-17 (App Check enforcement, `livreurs.wallet`, permissions sous-admin, bundle ID iOS, Node 20, contenu privacy policy) restent valides et non affectés par cette passe.

#### 4. Plan premiers utilisateurs Abengourou
Reprend le plan déjà chiffré au Prompt 60 (Section 13) : 100-300 clients, 15-30 livreurs, 10-20 vendeurs/vertical, minimum 2 semaines sans écart de conciliation wallet — **mais ce plan ne peut démarrer qu'après le déploiement réel des 23 fonctions manquantes**, sans quoi les nouveaux utilisateurs seraient exposés aux mêmes bugs déjà corrigés dans le code.

---

## 19. Controlled Firebase Production Deployment — Master Prompt 66

Cette fois, déploiement réel exécuté (instruction explicite et détaillée, contrairement à l'ambiguïté du Prompt 65 où l'utilisateur avait été interrogé et avait choisi de ne pas déployer).

### Phase 1 — Pre-deploy snapshot

`firebase functions:list` recapturé : 30 fonctions, toutes `europe-west1`/`nodejs20`/256MiB (identique au Prompt 65). `git status` propre, tags `v0.2-rc2`/`v0.3-rc3` confirmés, `firebase use` confirme `az-express-clean` actif.

### Phase 2 — Deploy rules (RÉELLEMENT EXÉCUTÉ)

`firebase deploy --only firestore:rules --project az-express-clean` puis `--only storage --project az-express-clean` : **les deux ont réussi** (« Deploy complete! »). Les deux ont répondu *« latest version... already up to date, skipping upload »* — **les règles étaient déjà à jour en production** avant cette passe, probablement déployées lors d'un commit externe entre les Prompts 60 et 65. **La couche règles de sécurité Firestore/Storage est donc confirmée à jour en production dès maintenant.**

### Phase 3 — Functions deploy par lots (arrêté au Lot 1)

Répartition exacte des 23 fonctions manquantes en 4 lots, comme demandé :
- **Lot 1 — infrastructure (6)** : `logAuthEvent`, `logAdminAuditEvent`, `fcmTokenCleanupCheck`, `walletReconciliationCheck`, `pharmacieLogin`, `setPharmaciePassword`.
- **Lot 2 — modules métier (7)** : `submitRealEstateAgentRequest`, `approveRealEstateAgentRequest`, `requestPropertyVisit`, `respondToVisitRequest`, `notifyAgentOnVisitRequest`, `notifyClientOnVisitUpdate`, `dispatchOrderToDriver`.
- **Lot 3 — argent (6)** : `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF`.
- **Lot 4 — AZ IA (4)** : `azIaChat`, `aiConfirmAction`, `aiCleanupExpiredPendingActions`, `clearAiHistory`.

**🔴 Le déploiement du Lot 1 a échoué** : après packaging réussi (176,66 Ko) et activation des API requises, l'upload échoue avec **HTTP 403 : « Write access to project 'az-express-clean' was denied: please check billing account associated and retry »** sur `cloudfunctions.googleapis.com/.../functions:generateUploadUrl`. **Ce n'est pas un problème de code** — Cloud Functions v2 nécessite Cloud Build/Cloud Run en arrière-plan, qui exigent un compte de facturation actif et correctement lié, indépendamment du tier gratuit. **Arrêté immédiatement, conformément à « ne pas continuer si erreur »** — aucune tentative de contournement. Vérifié qu'aucun dégât n'a eu lieu : `firebase functions:list` recompté = toujours exactement 30 fonctions, identiques ; un second dry-run `firestore:rules` confirme que le reste du projet répond normalement (le blocage est spécifique à Cloud Build/Functions, pas une panne générale).

### Phase 4 — Validation argent

**Non exécutée** — le Lot 3 (fonctions financières) n'a jamais pu être déployé, rien à tester en production tant que le blocage de facturation n'est pas résolu.

### Validation exécutée

`flutter analyze` (inchangé), `npm test` (**155/155**, aucun code touché cette passe — uniquement des opérations de déploiement), règles confirmées déployées réellement, Cloud Functions toujours 30/53.

---

### 🎯 PRODUCTION STATUS : **BLOCKED**

Progrès réel réalisé (règles de sécurité désormais confirmées à jour en production), mais l'objectif principal (déployer les 23 Cloud Functions manquantes) est bloqué par un problème d'infrastructure Google Cloud, pas par le code.

**Nombre de Functions en production** : 30/53 (inchangé — le blocage de facturation a empêché toute progression).
**Règles déployées** : ✅ Firestore + Storage, confirmées à jour en production.
**Tests réalisés** : dry-runs de règles, packaging Functions (réussi jusqu'à l'échec de l'upload), aucun test de flux argent (Lot 3 jamais déployé).

**Risques restants** :
1. **🔴 Bloquant absolu pour la suite** : le compte de facturation du projet Google Cloud `az-express-clean` doit être vérifié/réactivé en Console avant toute nouvelle tentative de déploiement de Cloud Functions — action 100% hors de portée du code ou de la CLI.
2. Tant que ce blocage persiste, les 23 correctifs (dont les 11 bugs financiers critiques) restent absents de la production réelle — le risque déjà documenté au Prompt 65 reste entièrement ouvert.
3. Tous les risques déjà documentés aux Sections 13-18 restent valides, non affectés par cette passe.

**Action immédiate recommandée avant le Master Prompt 67** : vérifier dans la Google Cloud Console (`https://console.cloud.google.com/billing/linkedaccount?project=az-express-clean`) qu'un compte de facturation actif est bien lié au projet `az-express-clean`, le réactiver/relier si nécessaire, puis relancer le déploiement du Lot 1 pour confirmer que le blocage est levé avant de poursuivre les Lots 2-4.

---

## 20. Reprise déploiement production après déblocage annoncé — Master Prompt 67

Le prompt affirmait le blocage du Prompt 66 résolu (facturation Google Maps analysée et corrigée, clé API recréée, restrictions Android, quotas). **Retesté directement plutôt que supposé — le blocage persiste, inchangé.**

### Vérifications préalables

`.firebaserc`/`firebase use` confirment `az-express-clean` actif. `firebase functions:list` toujours exactement 30 fonctions (inchangé depuis le Prompt 66).

### Nouvelle tentative Lot 1 — échec identique

`firebase deploy --only functions:logAuthEvent,functions:logAdminAuditEvent,functions:fcmTokenCleanupCheck,functions:walletReconciliationCheck,functions:pharmacieLogin,functions:setPharmaciePassword` — packaging réussi (177,36 Ko), puis :

> **HTTP 403 : "Write access to project 'az-express-clean' was denied: please check billing account associated and retry"**

**Identique au caractère près à l'erreur du Prompt 66.**

### Diagnostic — pourquoi la correction Maps ne pouvait pas résoudre ce blocage

La facturation **Google Maps Platform** (Directions/Places/Geocoding/Maps SDK — ce qui a été corrigé selon le contexte de ce prompt) et la facturation **Cloud Build/Cloud Run** (nécessaire à tout déploiement Cloud Functions v2, indépendamment du code déployé) sont **deux axes de facturation distincts** dans la Google Cloud Console, chacun avec son propre écran de configuration. Corriger le premier n'a aucun effet mécanique sur le second. **Vérifié en confirmant qu'aucun dégât n'a eu lieu** (toujours 30 fonctions après l'échec) et **arrêté immédiatement**, conformément à l'instruction explicite de ce prompt (« ne pas contourner »).

### Progrès réel, distinct du blocage Functions

`firebase deploy --only firestore` / `--only storage` (réel, pas dry-run) : les deux réussissent. **Nouvelle confirmation explicite** cette fois : le déploiement inclut la publication réussie des **37 index Firestore** (`firestore.indexes.json`), pas seulement les règles (les règles elles-mêmes étaient déjà à jour, aucun changement à pousser).

### Validation finale

`flutter analyze` : 5 avertissements préexistants, 0 erreur (inchangé). `npm test` (`functions/`) : **156/156**. `flutter build apk --release` : ✅ réussi, `app-release.apk` (72,4 Mo).

### Commandes exécutées cette passe

```bash
firebase deploy --only functions:logAuthEvent,functions:logAdminAuditEvent,functions:fcmTokenCleanupCheck,functions:walletReconciliationCheck,functions:pharmacieLogin,functions:setPharmaciePassword --project az-express-clean   # ÉCHEC — HTTP 403 billing
firebase deploy --only firestore --project az-express-clean   # ✅ réussi (règles + 37 index)
firebase deploy --only storage --project az-express-clean     # ✅ réussi
flutter analyze                                                 # ✅ 5 avertissements préexistants
npm test (functions/)                                            # ✅ 156/156
flutter build apk --release                                      # ✅ 72,4 Mo
```

---

### 🎯 PRODUCTION STATUS : **PRODUCTION BLOCKED**

**Cause exacte** : le compte de facturation Google Cloud lié au projet `az-express-clean` bloque toujours `cloudfunctions.googleapis.com`/Cloud Build — HTTP 403 sur `functions:generateUploadUrl`, identique au Prompt 66. **Ce n'est pas la même chose que la facturation Google Maps**, déjà corrigée selon le contexte de ce prompt — il s'agit de deux paramètres de facturation séparés dans la Google Cloud Console.

**Déploiements réussis cette passe** : `firestore.rules` (déjà à jour), `firestore.indexes.json` (37 index, déploiement confirmé), `storage.rules` (déjà à jour).

**Fonctions actives** : 30/53 (inchangé — `autoExpireOrders`, `cleanupExpiredRateLimits`, `createSubAdmin`/`deleteSubAdmin`, `feexPayWebhook`, `initiateFeexPayPayment`/`initiateWithdrawal`, `ekClientConfirmOrder`, `enforceOrderRateLimit`, tous les triggers `notify*` de la première vague — liste complète en Section 18).

**Erreurs restantes** : blocage de facturation Cloud Build/Cloud Functions — action Google Cloud Console requise, hors de portée de ce code ou de cette session.

**Commandes exécutées** : voir ci-dessus — 1 tentative de déploiement Functions (échec attendu et diagnostiqué), 2 déploiements réels réussis (Firestore rules+indexes, Storage rules), 3 commandes de validation (`flutter analyze`, `npm test`, `flutter build apk --release`), toutes réussies.

**Action Console exacte requise avant toute nouvelle tentative** : vérifier `https://console.cloud.google.com/billing/linkedaccount?project=az-express-clean` — confirmer qu'un compte de facturation **actif** (pas seulement existant) est lié au projet, distinct de toute configuration de facturation spécifique à l'API Maps. Une fois confirmé, relancer exactement la même commande Lot 1 ci-dessus pour valider le déblocage avant de poursuivre les Lots 2 (modules métier), 3 (argent), 4 (AZ IA).

---

## 21. Audit dispatch livreur temps réel + audit argent production (2026-07-09, deux audits ciblés hors-série)

Deux prompts distincts, tous deux explicitement scopés « ne pas reconstruire, corriger uniquement les failles réelles trouvées » — code uniquement, aucun rapport avec le blocage de déploiement des Sections 18-20 ci-dessus (ces correctifs rejoignent les 23 fonctions déjà en attente de déploiement, ils ne le débloquent pas).

### 21.1 Dispatch livreur temps réel

**Checklist auditée contre le code réel** : filtres de recherche livreur disponible, sélection intelligente (distance/top 5), broadcast, anti-double-acceptation (transaction atomique), expansion progressive du rayon, notifications, sécurité (livreur suspendu/hors-ligne/occupé doit être impossible à accepter). La quasi-totalité était déjà correcte (dispatch déjà migré côté serveur, `dispatchOrder()` filtre déjà suspendu/hors-ligne/occupé **au moment de l'offre**, transaction déjà en place).

**🔴 Faille réelle trouvée et corrigée** : `acceptOrder()` (`lib/services/firestore_service.dart`) ne revérifiait **jamais** l'éligibilité du livreur au moment de l'acceptation — seul le solde wallet était re-vérifié dans la transaction. Un livreur notifié d'un broadcast, puis suspendu / passé hors-ligne / ayant accepté une autre course entre-temps, pouvait donc encore accepter avec succès. Fenêtre étroite mais réelle, correspondant exactement au scénario de test explicitement demandé par le prompt. **Corrigé** : `acceptOrder()` relit désormais `isSuspended`/`isOnline`/`isOnDelivery` du livreur dans la même transaction et lève une exception explicite (déjà gérée par le `catch` générique existant côté UI) si l'une des trois conditions est violée — même schéma que la vérification de solde déjà en place.

**Non traité, hors périmètre d'un correctif ciblé** : l'expansion progressive du rayon (30s/60s) reste orchestrée par des `Timer` **côté client** dans `customer_tracking_screen.dart`, pas par le serveur — si l'app cliente est fermée pendant la recherche, l'expansion s'arrête. Server-orchestrer ça serait un changement architectural, pas une correction de faille, donc non exécuté silencieusement.

Vérifié : `flutter analyze` propre, `flutter build apk --release` réussi.

### 21.2 Audit argent production (wallet/paiements/commissions)

**Checklist auditée** : recharge/débit/remboursement/historique/concurrence multi-device, cohérence méthodes de paiement, commissions par module, mouvement d'argent à la livraison (exactement une fois), annulation à tous les stades, écritures Firestore client dangereuses.

**🔴 Bug critique confirmé et corrigé — double paiement sur les commandes pharmacie wallet, chemin Flutter humain uniquement (pas AZ IA).** Tracé numériquement, pas supposé : `pharmacie_garde.dart` débite déjà le client du montant de livraison **à la création** mais laisse `isPaid: false` (délibérément, le montant des médicaments étant inconnu à ce stade — réglé plus tard via `suivi_commande.dart` → `payOrderFromWalletCF`). Le problème : `payOrderFromWalletCF` ignorait que la livraison était déjà payée et débitait/créditait à nouveau le montant complet — et `deliverOrderCF` créditait déjà le livreur à la livraison, sans jamais vérifier `isPaid`. Résultat chiffré sur une livraison à 500 FCFA : client débité **1000 FCFA**, livreur crédité environ le double de ce qu'il devait recevoir. Bug d'**interaction** entre deux fonctions individuellement correctes, pas un bug isolé dans l'une ou l'autre.

**Vérifié non applicable ailleurs** : `livraison_screen.dart`/`courses_screen.dart`/`restaurant_menu.dart` marquent tous `isPaid: true` immédiatement pour un paiement wallet (pas de fenêtre) ; `create_pharmacie_order` (AZ IA) était déjà correct (`isPaid: paymentMethod === 'wallet'` dès la confirmation) — la divergence était entre le chemin Flutter humain et son équivalent AZ IA, dans le sens le plus sûr pour AZ IA. **Confirmé non exploitable en production réelle** : `payOrderFromWalletCF`/`deliverOrderCF` font partie des 23 Cloud Functions jamais déployées (Section 18-20 ci-dessus) — aucun utilisateur réel n'a pu être affecté.

**Corrigé** : `functions/orderActions.js` (`buildDeliverOrder`) — ajout d'un garde `order.isPaid === true` avant de créditer le livreur dans la branche wallet sans vendeur ; nouvelle branche `else` (`walletTarget: 'driver_pending_payment'`) qui libère `isOnDelivery: false` sans créditer, différant le crédit réel au règlement explicite via `payOrderFromWalletCF`. `pharmacie_garde.dart` : suppression de la transaction de pré-débit, remplacée par une simple vérification de solde en lecture seule (`SOLDE_INSUFFISANT` si insuffisant, aucune écriture), l'écriture de la commande devenant inconditionnelle pour cash et wallet — le débit wallet n'a désormais lieu qu'une seule fois, au règlement. 1 test existant corrigé (fixture manquait `isPaid: true`, validait par erreur l'ancien comportement buggé) + 1 nouveau test de non-régression. Suite de tests : 155→**156**, tous verts.

Vérifié : `flutter analyze` propre, `npm test` **156/156**, Cloud Functions module toujours chargeable sans erreur.

---

## 22. Audit + durcissement Android production (2026-07-09, « Final Android Production Hardening »)

Prompt explicitement scopé « ne pas reconstruire, auditer et durcir l'app Android existante pour une sortie production » — aucun changement architectural, aucune Cloud Function touchée.

**Technique nouvelle utilisée** : `aapt2 dump badging` sur l'APK release réellement compilé, plutôt que la seule lecture du manifest source — révèle les permissions/features injectées par les dépendances lors de la fusion du manifest par le plugin Android Gradle, invisibles dans `AndroidManifest.xml` seul.

**🟡 Trouvé et corrigé — 3 `uses-feature` implicitement requis auraient exclu des appareils du Play Store sans raison réelle.** `geolocator`/`speech_to_text`/`flutter_foreground_task` injectent `android.hardware.location`/`microphone`/`bluetooth` comme fonctionnalités **requises** par défaut, alors qu'aucune n'est strictement indispensable (adresse manuelle possible sans GPS, micro et Bluetooth non essentiels au cœur de l'app). Corrigé par le même pattern `android:required="false"` déjà appliqué à la caméra avant cette passe.

**🟡 Trouvé et corrigé — `AD_ID`/`ACCESS_ADSERVICES_AD_ID` présents malgré l'absence totale d'usage publicitaire.** Injectés transitivement par Google Play Services ; l'app n'utilise ni publicité ni Advertising ID (Analytics présent mais n'envoie aucun événement). Auraient forcé une déclaration Play Console inutile. Retirés via `tools:node="remove"`.

**Vérifié sain, aucun changement** : `proguard-rules.pro` déjà complet et correct (relu en entier) ; aucun secret/clé/token codé en dur dans `android/` ; aucune image lourde embarquée (`assets/` = 316 Ko) ; aucune nouvelle fuite mémoire au-delà de ce que le Prompt 44 avait déjà exhaustivement audité. Identité de l'application confirmée correcte sur l'APK compilé : `com.azexpress.app`, versionCode 1, versionName 1.0.0, minSdk 24, targetSdk 36.

**Hors périmètre, non retouché** : le risque Flutter canal beta et les 2 trouvailles de conformité Play Store (mauvais prestataire de paiement, partage de données Anthropic non déclaré) déjà documentées à la Section 15 (Prompt 63) restent ouvertes — cette passe est manifest/build uniquement, pas une passe de contenu légal.

Vérifié : `flutter analyze` inchangé (5 avertissements préexistants), `npm test` **156/156** (aucune Cloud Function touchée), 3 builds `flutter build apk --release` successifs tous réussis (validation incrémentale de chaque correctif), `aapt2 dump badging` confirme le manifest final correct.

---

### 🎯 PRODUCTION STATUS (inchangé depuis la Section 20) : **PRODUCTION BLOCKED**

Les Sections 21-22 n'ont ni résolu ni aggravé le blocage de facturation Cloud Build/Cloud Functions documenté en Section 20 — elles ajoutent 2 correctifs de code supplémentaires (dispatch, argent) à la pile déjà en attente de déploiement, et durcissent l'APK Android indépendamment de l'état du déploiement serveur. Le compte de facturation Google Cloud reste l'unique bloqueur restant avant de pouvoir déployer les 23 fonctions manquantes (dont désormais 11 correctifs financiers critiques au total).

---

## 23. Google Play Store Release Readiness Audit — Master Prompt 68

Audit-only, explicitement scopé « ne pas reconstruire de module, ne pas ajouter de fonctionnalité, ne pas toucher aux Cloud Functions ». Sans rapport avec le blocage de facturation Cloud Build (Sections 18-22) — cette passe couvre uniquement la préparation Play Store côté build/permissions/contenu.

### Phase 1 — `android/app/build.gradle.kts`

Rien à corriger. `namespace`/`applicationId` = `com.azexpress.app`, `minSdk`/`targetSdk`/`versionCode`/`versionName` dérivés de `flutter.*` (donc de `pubspec.yaml` : `1.0.0+1`, minSdk 24, targetSdk 36 — confirmé sur l'APK compilé). `signingConfigs.release` lit `key.properties`/`release.keystore`, tous deux confirmés présents localement et jamais commités.

### Phase 2 — App Bundle (réellement construit)

`flutter build appbundle --release` → succès, `app-release.aab` réel de **74,0 Mo** (73 990 993 octets). Rappel important pour l'interprétation Play Console : c'est la taille du bundle brut, pas ce qu'un utilisateur télécharge (Play livre dynamiquement seulement l'ABI/densité pertinente par appareil). Même avertissement non-fatal déjà tracé au Prompt 63 (symboles de debug non retirés — toolchain local incomplet, pas un défaut du code). **Nouvel avertissement, jamais vu avant cette passe** : Flutter signale que 14 plugins (`firebase_*`, `flutter_foreground_task`, `speech_to_text`, `google_maps_flutter_android`, etc.) appliquent l'ancien Kotlin Gradle Plugin (KGP) et que « les futures versions de Flutter échoueront à construire » les apps qui en dépendent tant qu'ils n'auront pas migré vers le Kotlin intégré. Pas un blocage aujourd'hui (le build réussit), un risque de maintenance à moyen terme hors du contrôle du code applicatif (dépend des mainteneurs de chaque plugin) — signalé pour suivi.

### Phase 3 — Politique permissions

Recoupe entièrement l'audit hardening déjà fait juste avant ce prompt (Section 22) — rien de nouveau trouvé, pas re-détaillé ici.

### Phase 4 — Data Safety (checklist préparée, formulaire Play Console hors du code)

Catégories de données à déclarer, toutes déjà correctement traitées côté app : identité (nom/téléphone), localisation précise + arrière-plan, informations financières (transactions wallet — jamais de numéro de carte, aucune carte utilisée), photos (selfie/KYC livreur, preuve de livraison, produits), messages (support, chat livreur↔client, chat Marketplace, conversation AZ IA), identifiants d'appareil (jeton FCM). Le vrai gap n'est pas la collecte, c'est sa déclaration publique (voir Phase 6).

### Phase 5 — Paiements et conformité Play Billing (vérifié, conclusion rassurante)

Google Play n'exige son propre système de facturation que pour l'achat de contenu numérique consommé dans l'app — les biens/services du monde réel (livraison, marketplace, restauration) en sont explicitement exemptés, quel que soit le moyen de paiement (même modèle qu'Uber/Bolt/Glovo). Vérifié qu'aucune fonctionnalité ne vend de contenu strictement numérique in-app : le seul abonnement existant (`subscription_service.dart`) est payé par les comptes **partenaires** pour un accès de vente sur la plateforme (outil B2B lié à du réel, pas du contenu numérique consommateur), et le wallet ne finance jamais que des commandes réelles ou ces abonnements partenaires — jamais de contenu numérique isolé. Orange Money/MTN/Moov/Wave/Cash tous réels et fonctionnels via FeexPay (`feexpayOperatorCode()`) — aucune intégration factice trouvée.

### Phase 6 — Confidentialité (3 trouvailles, dont une nouvelle)

**🔴 Trouvailles 1 et 2 (déjà connues, reconfirmées)** : `privacy_page.dart` ET `terms_page.dart` (nouvelle recherche ciblée dans ce second fichier, pas seulement le premier comme documenté au Prompt 63) nomment toujours "CinetPay" comme prestataire de paiement, alors que seul FeexPay est réellement intégré. La politique ne mentionne toujours pas Anthropic/Claude comme tiers destinataire des données de conversation AZ IA. Toujours pas corrigé — contenu légal public, décision explicite requise.

**🔴 Trouvaille 3, nouvelle à cette passe : aucune page web publique de suppression de compte n'existe.** Recherche exhaustive de `web_router.dart` : seules `/confidentialite` et `/conditions` sont déclarées, aucune route de suppression/désinscription. La politique de confidentialité promet pourtant ce droit (section 8 : « Supprimer votre compte et vos données ») et Google Play exige, pour toute app avec création de compte, un moyen de demander la suppression accessible aussi depuis le web sans réinstaller l'app. La suppression in-app existe réellement (`profil_client.dart:806`, avec ré-authentification) mais **uniquement pour les clients** — aucun équivalent pour livreurs/vendeurs/restaurants/pharmacies/boulangeries/agents Ekbine. Pas corrigé : construire une page web de suppression serait une nouvelle fonctionnalité (nouvelle route publique + probablement une nouvelle Cloud Function pour traiter une demande sans session Flutter active), explicitement hors du périmètre de ce prompt.

### Phase 7 — Tests manuels demandés (installation/compte/permissions/fermeture-réouverture/notifications)

Non exécutables depuis cet environnement (pas d'appareil/émulateur disponible — limite déjà actée à chaque audit release précédent). L'AAB se construit et se signe correctement (preuve structurelle), mais le parcours réel de première utilisation reste à valider sur un appareil physique avant soumission.

### Validation exécutée

`flutter analyze` (5 avertissements préexistants, inchangé), `npm test` (`functions/`, **156/156**, non touché), `flutter build appbundle --release` (**réussi**, AAB réel de 74,0 Mo, signature vérifiée de bout en bout).

---

### 🎯 GOOGLE PLAY RELEASE STATUS : **BLOCKED**

Bloqué pour des raisons de **conformité de contenu, pas techniques** — build/signature fonctionnent réellement. Aucun code modifié cette passe (audit-only, conformément à l'instruction explicite).

#### Bloqueurs 🔴
1. **Mauvais prestataire de paiement nommé** ("CinetPay" au lieu de FeexPay) dans `privacy_page.dart`/`terms_page.dart`/`home_page.dart` — décision explicite requise avant correction (contenu légal public).
2. **Anthropic/Claude non déclaré** comme tiers destinataire de données dans la politique de confidentialité — à ajouter avant soumission (Data Safety Play Console).
3. **Aucune page web publique de suppression de compte** — obligatoire pour toute app avec création de compte ; suppression in-app limitée aux clients uniquement (9 autres rôles sans équivalent).

#### Avertissements 🟡
1. Flutter sur canal `beta` — recommandé de repasser sur `stable` avant le build de soumission officiel.
2. Toolchain Android local incomplet (`cmdline-tools`/licences) — cause l'avertissement symboles de debug non retirés, à corriger sur la machine de build final.
3. 14 plugins dépendant de l'ancien Kotlin Gradle Plugin — pas bloquant aujourd'hui, risque de maintenance Flutter à moyen terme.
4. `ACCESS_BACKGROUND_LOCATION` nécessite une déclaration Play Console dédiée (justification + captures/vidéo) — préparation, pas un défaut de code.

#### Corrections faites cette passe
Aucune — audit-only, tous les blocueurs trouvés touchent du contenu légal public ou une nouvelle fonctionnalité (page web), tous deux explicitement hors du périmètre « ne pas ajouter de fonctionnalité » du prompt. Voir Section 22 pour les corrections de code déjà faites lors de l'audit hardening précédent (toujours valides, non re-décrites ici).

#### Fichiers modifiés
Aucun (code). Documentation : `CLAUDE.md`, `AUDIT_FINAL.md`, mémoires projet.

#### Résultat build AAB
✅ Réussi — `app-release.aab`, 74,0 Mo, signé de bout en bout, aucune erreur bloquante (1 avertissement non-fatal déjà tracé à l'environnement local, 1 nouvel avertissement KGP non-bloquant).

---

## 24. Google Play Compliance Fix — Master Prompt 69

Contrairement à la Section 23 (audit-only), ce prompt autorise et demande explicitement de corriger les 3 blocueurs 🔴 qui y avaient été trouvés. Les 3 corrigés. Aucune Cloud Function/dispatch/wallet/paiement serveur touchée, conformément à l'instruction explicite « Ne pas toucher ».

### 1) Paiements légaux — CinetPay → FeexPay

Recherche exhaustive avant correction : 3 fichiers Dart concernés (pas 2 comme précédemment documenté) — `privacy_page.dart`, `terms_page.dart` (×2), et **`home_page.dart`, jamais signalé avant cette passe** (section marchands publique, listait à tort "CinetPay" comme un réseau mobile money séparé de Wave/MTN/Orange/Moov, alors que c'est/c'était un agrégateur). Les 3 corrigés (`FeexPay`, reformulation "via FeexPay" sur `home_page.dart`). `AZ_Express_Documentation.html` (11 occurrences) **volontairement laissé intact** — document technique statique non servi par l'app, décrivant des mécanismes spécifiques à CinetPay (vérification `site_id`, `CinetPay Transfer`) qui ne correspondent pas à la mécanique réelle de FeexPay ; un renommage brut y introduirait des affirmations fausses plutôt que d'en corriger une. Recherche finale (`grep -r CinetPay lib/ functions/ CLAUDE.md`) : **zéro résultat**.

### 2) Section "Assistant intelligent AZ IA" dans la politique de confidentialité

Nouvelle section 9 ajoutée à `privacy_page.dart` (sections suivantes renumérotées 10-13) : déclare le fournisseur IA externe (Anthropic, Claude), la transmission du seul texte nécessaire au traitement, l'absence de vente des données, l'objectif unique d'assistance utilisateur, la règle de confirmation systématique avant toute action sensible, et le droit d'effacer son historique de conversation (fonctionnalité réelle déjà existante, `clearAiHistory`). Section 4 ("Partage des données") gagne aussi une ligne Anthropic explicite. Dates de dernière mise à jour des deux pages légales avancées au 9 juillet 2026.

### 3) AccountDeletionService — flux unique, deux mécanismes selon ce que chaque rôle permet réellement

`lib/services/account_deletion_service.dart` (nouveau). Vérifié avant conception : seul le rôle client a un compte Firebase Auth email/mot de passe **et** une règle Firestore `allow delete` déjà accordée au propriétaire — les 8 autres rôles n'ont ni l'un ni l'autre (ex. les pharmacies utilisent une authentification Firestore custom, pas Firebase Auth). Élargir les règles Firestore pour permettre l'auto-suppression sur ces 8 collections aurait été un changement de posture de sécurité à part entière — explicitement exclu par « ne pas toucher à l'architecture Firebase ».

- `deleteClientAccountNow({password})` — extrait (pas réécrit) du flux déjà en production dans `profil_client.dart` (ré-authentification + suppression Firestore + suppression Auth). `profil_client.dart` délègue désormais à cette méthode — comportement observable inchangé.
- `submitRequest({role, contactPhone, contactEmail?, reason?, requestedVia})` — pour les 9 rôles, écrit dans la nouvelle collection `account_deletion_requests` (Firestore direct, aucune nouvelle Cloud Function), traitée manuellement par un admin (désactivation puis effacement des données personnelles dans le délai déjà annoncé — 30 jours sauf obligation légale). Seul mécanisme disponible pour les 8 rôles partenaires ; fonctionne authentifié (app) et non authentifié (page web) — un seul point d'entrée pour les deux contextes.
- **Câblé concrètement dans un écran** : `driver_profil.dart` gagne une entrée "Supprimer mon compte" via `showAccountDeletionRequestDialog()` (`lib/widgets/account_deletion_dialog.dart`, boîte de dialogue générique réutilisable pour les 9 rôles). **Les 7 autres rôles partenaires (seller/restaurant/pharmacie/boulangerie/ekbine_agent/real_estate_agent/fleet_owner) n'ont pas encore ce bouton dans leurs écrans de profil** — le service et le dialogue génériques sont prêts (un seul appel par écran), mais le câblage dans les 7 dashboards restants n'a pas été fait cette passe (chacun nécessiterait de localiser son propre écran de profil, non audité un par un ici). **La page web `/delete-account` reste un point d'entrée universel déjà fonctionnel pour ces 7 rôles dès maintenant** — l'exigence Google Play (un moyen de demander la suppression, in-app ou web) est donc déjà satisfaite pour tous les rôles.
- `firestore.rules` : nouveau bloc `account_deletion_requests` (écriture publique avec validation stricte de forme, même pattern que `driver_applications`/`partner_applications` du Prompt 57 — lecture/modification/suppression admin uniquement). Validé par `firebase deploy --only firestore:rules --dry-run` contre le projet réel : compile sans erreur.

### 4) Page web publique /delete-account

`lib/web/pages/delete_account_page.dart` (nouveau), route ajoutée dans `web_router.dart`. Même style visuel que `privacy_page.dart`/`contact_page.dart`. Contenu : procédure, délai de traitement (désactivation 48h, effacement 30 jours sauf obligation légale), contact support. Formulaire : rôle (9 options), téléphone (obligatoire), email/raison (optionnels) → `AccountDeletionService.submitRequest(..., requestedVia:'web')` — alimente la **même** collection que le flux in-app, une seule file d'attente admin. Gestion d'erreur explicite en cas d'échec (contrairement au bug déjà connu de `contact_page.dart`/`merchants_page.dart`, Prompt 57, qui échouaient silencieusement — pas corrigé ici, hors périmètre, mais non reproduit dans le nouveau code). Prêt pour Firebase Hosting sans configuration supplémentaire (route `go_router` standard, `firebase.json` sert déjà `build/web`).

### 5) Data Safety Play Console — checklist consolidée

Collecté : nom, téléphone, email (optionnel), localisation précise + arrière-plan, messages (support/chat/AZ IA), photos (selfie KYC, preuve de livraison, produits), données de paiement (transactions wallet, jamais de numéro de carte). Partagé : FeexPay (paiements), Firebase/Google (infrastructure), Anthropic (uniquement pour AZ IA). Recoupe et confirme la checklist déjà préparée en Section 23, désormais alignée avec le contenu réel de la politique après les corrections 1-2.

### Validation exécutée

`flutter analyze` — 5 avertissements préexistants inchangés + 3 nouveaux `info` de style (`prefer_const_constructors`, non bloquants, catégorie distincte des avertissements suivis). `npm test` (`functions/`) — **156/156**, aucune Cloud Function touchée. `firebase deploy --only firestore:rules --dry-run` — compile sans erreur contre le projet réel. `flutter build appbundle --release` — voir résultat ci-dessous.

---

### 🎯 GOOGLE PLAY COMPLIANCE STATUS : les 3 blocueurs 🔴 de la Section 23 sont corrigés

#### Fichiers modifiés/créés
- `lib/web/pages/privacy_page.dart` (CinetPay→FeexPay, nouvelle section AZ IA, date mise à jour)
- `lib/web/pages/terms_page.dart` (CinetPay→FeexPay ×2, date mise à jour)
- `lib/web/pages/home_page.dart` (CinetPay→FeexPay)
- `lib/services/account_deletion_service.dart` (nouveau)
- `lib/widgets/account_deletion_dialog.dart` (nouveau)
- `lib/screens/client/profil_client.dart` (délègue à `AccountDeletionService.deleteClientAccountNow`)
- `lib/screens/driver/driver_profil.dart` (nouvelle entrée "Supprimer mon compte")
- `lib/web/pages/delete_account_page.dart` (nouveau, route `/delete-account`)
- `lib/web/web_router.dart` (nouvelle route)
- `firestore.rules` (nouvelle collection `account_deletion_requests`)

#### Conformité corrigée
1. ✅ Mauvais prestataire de paiement — corrigé sur les 3 fichiers concernés.
2. ✅ Anthropic/Claude non déclaré — nouvelle section dédiée + ligne dans le partage de données.
3. ✅ Aucune page web de suppression de compte — `/delete-account` créée, universelle pour les 9 rôles ; flux in-app câblé pour client (déjà existant) et livreur (nouveau) — 7 rôles partenaires restants couverts par le web uniquement pour l'instant.

#### Erreurs restantes Play Store
- 🟡 Flutter sur canal `beta` (inchangé, Section 23).
- 🟡 Toolchain Android local incomplet (inchangé, Section 23).
- 🟡 14 plugins dépendant de l'ancien Kotlin Gradle Plugin (inchangé, Section 23).
- 🟡 `ACCESS_BACKGROUND_LOCATION` nécessite une déclaration Play Console dédiée (préparation, pas un défaut de code).
- 🟢 (mineur, nouveau) 7 des 9 rôles n'ont pas encore de bouton de suppression in-app dédié — couverts par la page web, mais l'expérience in-app reste à compléter dans un futur passage sur chaque dashboard partenaire.

#### Résultat build AAB
✅ Réussi — `app-release.aab`, **74,0 Mo** (74 012 326 octets), signé de bout en bout. Même avertissement non-fatal déjà tracé à l'environnement local (symboles de debug non retirés, `cmdline-tools` manquants) ; un avertissement Kotlin supplémentaire vu cette fois (API `BluetoothAdapter.getDefaultAdapter()` dépréciée, dans le code du plugin tiers `speech_to_text`, pas dans le code applicatif) — aucun des deux n'est bloquant, le build se termine avec succès (code de sortie 0).

---

## 25. Finalisation comptes partenaires — Master Prompt 70

Audit individuel des 7 dashboards partenaires restants (aucun n'avait de bouton de suppression après le Prompt 69, qui n'avait câblé que client+livreur). Trouvaille principale : 3 des 7 rôles n'avaient aucun moyen de se déconnecter, un bug distinct et plus grave que l'absence de suppression.

### Audit par rôle

| Rôle | Déconnexion avant | Suppression avant | Écran profil |
|---|---|---|---|
| Vendeur | ✅ (icône AppBar) | ❌ | Aucun |
| Restaurant | ✅ (icône AppBar) | ❌ | Aucun |
| Pharmacie | ✅ (icône AppBar) | ❌ | Aucun |
| Boulangerie | ✅ (icône AppBar) | ❌ | Aucun |
| Agent Ekbine | 🔴 **Aucune** (y compris écran "en attente d'approbation") | ❌ | Aucun |
| Agent immobilier | 🔴 **Aucune** | ❌ | Aucun |
| Patron de flotte | 🔴 **Aucune** | ❌ | Aucun |

### Corrections

- **`lib/widgets/partner_account_sheet.dart` (nouveau)** — bottom sheet générique "Mon compte" réutilisable pour les 7 rôles : nom/téléphone en lecture seule, "Se déconnecter" (callback propre à chaque écran), "Supprimer mon compte" (délègue au dialogue déjà existant du Prompt 69).
- **Vendeur/Restaurant/Pharmacie/Boulangerie** : icône "Mon compte" ajoutée dans l'AppBar, à côté de l'icône de déconnexion déjà fonctionnelle (intacte). Données déjà disponibles dans les `Map` passées au constructeur — aucune nouvelle lecture Firestore.
- **Agent Ekbine, Agent immobilier, Patron de flotte** : nouvelle méthode `_logout()` (même pattern `signOut()`+`signInAnonymously()`+retour `HomeScreen()` que les autres rôles) + icônes "Mon compte"/déconnexion ajoutées à leur AppBar respective. Pour l'agent Ekbine, l'icône de déconnexion a aussi été ajoutée à l'écran "candidature en cours" (qui n'avait littéralement aucune sortie).

### Limite assumée

Le nom/téléphone sont désormais **visibles** dans le sheet pour les 7 rôles, mais pas **modifiables** — aucune des 7 collections n'autorise aujourd'hui une auto-édition par le propriétaire dans `firestore.rules`, et l'ajouter aurait été un changement de règles, explicitement exclu par ce prompt (« ne pas toucher... Firebase rules »). Un écran d'édition de profil reste un chantier séparé.

### Validation exécutée

`flutter analyze` — 5 avertissements préexistants inchangés (mêmes infos de dépréciation/style déjà connues, aucun nouveau problème). `npm test` (`functions/`) — **156/156**, confirmé via `git status` qu'aucun fichier `functions/`/`firestore.rules`/`storage.rules` n'a été touché cette passe. `flutter build appbundle --release` — voir résultat ci-dessous.

---

### 🎯 STATUT : les 3 dashboards sans déconnexion sont corrigés ; suppression de compte désormais accessible (in-app ou web) pour les 9 rôles

#### Fichiers modifiés/créés
- `lib/widgets/partner_account_sheet.dart` (nouveau)
- `lib/screens/seller/seller_dashboard.dart`
- `lib/screens/restaurant/restaurant_owner_dashboard.dart`
- `lib/screens/pharmacie/pharmacie_dashboard.dart`
- `lib/screens/boulangerie/boulangerie_dashboard.dart`
- `lib/ekbine/screens/ek_agent_dashboard.dart`
- `lib/screens/immobilier/agent_dashboard_screen.dart`
- `lib/screens/fleet/fleet_dashboard.dart`

#### Rôles corrigés
Les 7 — chacun gagne l'accès "Mon compte" (profil en lecture seule + suppression). 3 (agent Ekbine, agent immobilier, patron de flotte) gagnent aussi une vraie déconnexion, absente avant cette passe.

#### Rôles déjà conformes
Client et livreur (Prompts 69/session antérieure) — inchangés cette passe.

#### Bugs trouvés
🔴 3 dashboards partenaires sans aucun moyen de se déconnecter (agent Ekbine, agent immobilier, patron de flotte) — corrigé.

#### Résultat build AAB
✅ Réussi — `app-release.aab`, **74,0 Mo** (74 011 532 octets), signé de bout en bout. Même avertissement non-fatal déjà tracé à l'environnement local (symboles de debug non retirés) — non bloquant, code de sortie 0.

---

## 26. End to End Real User Flow Audit — Master Prompt 71

Traçage direct du code pour les 7 parcours demandés (cet environnement ne permet toujours pas de test manuel réel sur appareil/émulateur). **Trouvaille la plus importante de cette passe : le traçage exact du parcours "création de commande" démontre, bout en bout, l'impact concret du blocage de déploiement déjà documenté (Sections 18-20) — pas un nouveau bug, la première preuve tracée jusqu'à l'écran utilisateur.**

### 🔴 Parcours 2/3 (commande livraison + dispatch) — aucune commande ne peut aboutir aujourd'hui en production

`FirestoreService.createOrder()` écrit `orders/{id}` (`status:'pending'`) puis appelle `findNearestDriver()`, qui appelle **exclusivement** `httpsCallable('dispatchOrderToDriver')` — aucun chemin alternatif. Cet appel est enveloppé dans un `try{}catch(_){}` muet (défensif, correct en soi). Or `dispatchOrderToDriver` fait partie des 23 Cloud Functions jamais déployées (30/53 en prod, confirmé Prompts 65-67) — l'appel échoue systématiquement (`not-found`), silencieusement avalé. **La commande ne passe jamais en `broadcast`/`assigned`, aucun livreur n'est jamais notifié, quel que soit le nombre de livreurs réellement en ligne.** Le client voit les phases de recherche (déjà bien conçues, 30s/60s, aucun bug d'UI) jusqu'à ce qu'`autoExpireOrders` (déployée) annule et rembourse après 10 minutes.

**Conclusion sans ambiguïté : dans l'état actuel du déploiement, une commande de livraison créée par un vrai utilisateur à Abengourou aujourd'hui échoue toujours après exactement 10 minutes, indépendamment de la disponibilité réelle des livreurs.** Aucun code applicatif en cause — conséquence directe du blocage Cloud Build déjà documenté, maintenant démontrée bout en bout plutôt que déduite. Aucun contournement tenté (pas de fallback client-side, ce qui annulerait la migration serveur déjà actée).

### 🔴 Parcours 4/5 (livreur, après livraison) — même cause racine + 2 bugs UI réels trouvés et corrigés

`deliverOrder()`/`payOrderFromWallet()`/`cancelOrder()` délèguent à `deliverOrderCF`/`payOrderFromWalletCF`/`cancelOrderCF` — les 3 autres membres du Lot 3 jamais déployé. Un livreur confirmant une livraison verrait son appel échouer, la commande resterait bloquée à `picked_up`. Deux bugs UI indépendants trouvés en traçant ce chemin et corrigés :
- `driver_dashboard.dart` : le bouton "Confirmer la livraison" réinitialisait son état de chargement sur échec **sans jamais informer le livreur** — corrigé (SnackBar d'erreur ajouté).
- `suivi_commande.dart` : le bouton "Annuler" d'une commande était un appel fire-and-forget, sans `await` ni `try/catch` — en cas d'échec, le client ne voyait rien du tout. Corrigé (`await` + gestion d'erreur + SnackBar).

`_WalletPayButton` (paiement wallet post-livraison pharmacie) déjà correctement protégé — vérifié, rien à corriger.

### Parcours 5 (historique/notifications) — 2 cas de "chargement infini" trouvés et corrigés

Recherche ciblée du pattern `if (!snapshot.hasData)` sans branche `hasError` (bloque un écran indéfiniment si le stream Firestore émet une erreur) : 2 occurrences trouvées, toutes deux corrigées — `suivi_commande.dart` (liste "Mes commandes") et `chat_page.dart` (messagerie client↔livreur pendant livraison active).

### Parcours 1, 6, 7 — sains ou déjà couverts, rien de nouveau

Inscription/connexion/persistance de session/permissions GPS (`client_map.dart`) déjà robustes, aucun blocage trouvé — `livraison_screen.dart` dégrade silencieusement si le GPS est refusé (mineur, non corrigé). Coupures réseau déjà couvertes par la persistance Firestore existante (Prompt 17, pas ré-audité). Recherche libre d'écrans bloqués limitée aux 4 corrections ci-dessus dans le temps imparti — un balayage exhaustif des ~186 `StreamBuilder` de l'app resterait un chantier séparé.

### Validation exécutée

`flutter analyze` — 5 avertissements préexistants inchangés, aucun nouveau (les 3 fichiers modifiés compilent sans le moindre avertissement). `npm test` (`functions/`) — **156/156**, confirmé via `git status` qu'aucun fichier `functions/`/`firestore.rules`/`storage.rules` n'a été touché. `flutter build appbundle --release` — voir résultat ci-dessous.

---

### 🎯 ÉTAT LANCEMENT TERRAIN ABENGOUROU : **NON PRÊT** — pas pour une raison de code, mais parce que le dispatch (et tout le cycle de paiement post-livraison) est un no-op silencieux tant que les Cloud Functions ne sont pas déployées

#### Parcours réussis
1) Nouveau client (inscription/connexion/profil Firestore/permissions GPS/persistance de session) — sain.
6) Résilience réseau — déjà couverte par la persistance Firestore existante.

#### Bugs trouvés
🔴 Aucune commande de livraison ne peut aboutir en production (dispatch = no-op silencieux, cause : Cloud Functions non déployées, déjà documenté Sections 18-20 — pas un nouveau bug de code).
🔴 Confirmation de livraison livreur et annulation client : échecs silencieux sans feedback utilisateur — corrigé.
🔴 2 écrans à risque de chargement infini en cas d'erreur réseau (liste commandes, chat) — corrigé.
🟡 GPS refusé sur `livraison_screen.dart` : dégradation silencieuse, pas de message explicatif — non corrigé (mineur).

#### Corrections
`lib/screens/client/suivi_commande.dart`, `lib/screens/driver/driver_dashboard.dart`, `lib/screens/chat/chat_page.dart` — 4 correctifs UI narrow, aucune Cloud Function/règle/architecture touchée.

#### Fichiers modifiés
- `lib/screens/client/suivi_commande.dart`
- `lib/screens/driver/driver_dashboard.dart`
- `lib/screens/chat/chat_page.dart`

#### État lancement terrain Abengourou
**Bloqué au même titre que documenté depuis le Prompt 65** — pas une nouvelle régression, mais désormais démontré de façon concrète et traçable jusqu'à l'écran utilisateur final : tant que les 23 Cloud Functions manquantes (dispatch, paiement, annulation, livraison) ne sont pas déployées, un client réel à Abengourou pourrait créer un compte, parcourir l'app, mais **ne pourra jamais recevoir de livraison** — chaque commande expirera après 10 minutes sans jamais atteindre un livreur. Action requise avant tout lancement terrain : débloquer la facturation Cloud Build/GCP (Section 20) et déployer au minimum le Lot 2 (dispatch) et le Lot 3 (paiements/livraison/annulation).

#### Résultat build AAB
✅ Réussi — `app-release.aab`, **74,0 Mo** (74 012 630 octets), signé de bout en bout. Même avertissement non-fatal déjà tracé à l'environnement local — non bloquant, code de sortie 0.

---

## 27. Pre Launch Field Mode Audit — Master Prompt 72

Audit-only (aucun code modifié — ce prompt ne demande aucune correction, contrairement au Prompt 71). « Ne pas contourner le blocage Cloud Functions », « interdit : toucher Cloud Functions, reconstruire dispatch, modifier paiement » — tous respectés.

### 1) Données initiales nécessaires

| Collection | Obligatoire avant ouverture ? | Détail |
|---|---|---|
| `zones_livraison` | 🔴 **Oui** | Lue par `create_order.dart` (sélecteur de quartier sur l'écran "Commander") — si vide, chaque client voit "Aucune zone disponible. L'administrateur doit configurer les zones." Sans lien avec le dispatch lui-même (confirmé toujours non lu par `dispatch.js`). |
| `config/commission` | Non | Valeurs de repli codées en dur (100/200 FCFA) si absent. |
| Catégories Marketplace | Non | `mpCategories` codé en dur en Dart, jamais lu depuis Firestore. |
| Catégories Immobilier | Non | `real_estate_categories` existe dans `firestore.rules` mais n'est lu nulle part — `agent_dashboard_screen.dart` utilise une liste codée en dur. Correction apportée à ce document (l'affirmation inverse était fausse). |
| `livreurs` | 🔴 **Oui** (au moins quelques-uns) | Seul chemin fiable : auto-inscription (`driver_register.dart`) + approbation admin (`driver_requests_page.dart`) — crédite `wallet:500` automatiquement, `isAvailable`/`isSuspended` absents mais non bloquants (dispatch ne filtre que sur valeur explicite `false`/`true`). La création directe via patron de flotte reste probablement cassée (`permission-denied` déjà documenté) — ne pas s'y fier. |
| `sellers` (type `boutique`) | 🔴 **Oui, sinon le module Boutique ne fonctionne pas du tout** | `payBoutiqueOrderCF`/`payBoutiqueOrderCashCF` exigent tous deux un document `sellers` avec `type:'boutique'` (`db.collection('sellers').where('type','==','boutique').limit(1)`) — **jamais créé automatiquement**, `admin_boutique_page.dart` ne gère que produits/commandes, pas le vendeur lui-même. Réalisable via `admin_sellers_page.dart` (type par défaut déjà 'boutique') mais facile à oublier — aucun écran ne le rappelle. |
| `restaurants`/`pharmacies` | Oui (au moins 1 actif avec menu/stock) | Mécanismes déjà documentés (approbation admin / création directe) — sinon écran vide, déjà bien géré avec message explicite. |

### 2) Simulation première journée (10 clients / 5 livreurs / 3 boutiques)

Simulée par traçage de code (pas d'exécution device possible). Écrans de liste vérifiés (restaurant/pharmacie/marketplace/boutique) : tous ont déjà un message d'état vide explicite, aucun écran blanc trouvé. Un risque mineur documenté sans être corrigé (hors périmètre de ce prompt, pas de "corriger" demandé) : `boutique_page.dart` a le même pattern de chargement infini potentiel déjà corrigé ailleurs au Prompt 71 (`ConnectionState.waiting` sans `hasError`) — pas touché cette passe.

### 3) Admin

- **Suspension livreur classique : confirmée toujours absente** — seul Ekbine a `isSuspended` géré côté admin. Seule option punitive aujourd'hui : suppression complète du compte.
- **🔴 Gestion des litiges : gap confirmé, jamais vérifié aussi explicitement avant cette passe.** Aucun écran admin ne lit `support_tickets` — un client qui soumet un ticket pendant le pilote n'a aucun canal admin visible dans l'app. Risque terrain prioritaire, pas corrigé (nouvelle fonctionnalité, hors périmètre audit-only).
- Validation partenaires / suivi commandes : déjà couverts et fonctionnels, rien de nouveau.

### 4) Abengourou

Constantes reconfirmées inchangées : centre `TarifService` (6.7273/-3.4961), refus >10km après 21h, rayon dispatch 2km→5km — sans lien avec `zones_livraison`. Rien de nouveau par rapport aux Prompts 05/26/51.

### Validation exécutée

`flutter analyze` inchangé (5 avertissements préexistants, aucun nouveau, aucun fichier modifié). `npm test` (`functions/`) toujours 156/156. `flutter build appbundle --release` réussi (build incrémental rapide — aucun fichier source touché, AAB identique à celui du Prompt 71).

---

### 🎯 PRÊT PILOTE : **NON** (pour deux raisons indépendantes, pas une seule)

**Raison 1 (déjà connue, inchangée)** : le dispatch et les paiements post-livraison restent des no-op silencieux tant que les Cloud Functions ne sont pas déployées (Sections 18-20, 26).

**Raison 2 (nouvelle, ce prompt) : même une fois les Cloud Functions déployées, le pilote ne peut pas s'ouvrir sans une préparation manuelle de données spécifique — actuellement non documentée nulle part avant cette passe.**

#### Données manquantes (actions Firestore/admin requises avant ouverture)
1. 🔴 Créer au moins 3-5 zones actives dans `admin_zones_page.dart` (couvrant Abengourou) — sinon l'écran "Commander" affiche un avertissement à chaque client.
2. 🔴 Créer au moins 1 vendeur `sellers` avec `type:'boutique'` via `admin_sellers_page.dart` — sinon **aucun achat Boutique n'est possible, pas même une erreur explicite côté client, juste un échec silencieux côté serveur.**
3. Approuver au moins 5 livreurs pilotes via l'auto-inscription + `driver_requests_page.dart` (pas via un patron de flotte — ce chemin est cassé).
4. Approuver/créer au moins 3 boutiques (produits `boutique_products` avec stock réel) + quelques restaurants/pharmacies actifs avec menu non vide.
5. Débloquer la facturation Cloud Build et déployer au minimum les Lots 2 (dispatch) et 3 (paiement/livraison/annulation) — voir Sections 18-20/26.

#### Comptes tests nécessaires
- 3-5 comptes clients réels (inscription email/mot de passe complète, pas juste anonyme) pour tester le parcours de bout en bout.
- 5 comptes livreurs approuvés, avec au moins un test de bascule en ligne/hors ligne et d'acceptation de course.
- 1 compte vendeur boutique (`type:'boutique'`) + 1-3 comptes vendeurs Marketplace.
- 1 compte restaurant actif avec menu, 1 compte pharmacie active.
- 1 compte admin super + éventuellement 1 sous-admin pour tester les permissions.

#### Risques terrain
- 🔴 Aucune commande de livraison n'aboutira tant que les Cloud Functions ne sont pas déployées (répété depuis les Sections 18-20/26, cause n°1 du blocage).
- 🔴 Le module Boutique échouera silencieusement si le vendeur `type:'boutique'` n'est pas créé au préalable.
- 🔴 Un litige client pendant le pilote n'a aujourd'hui aucun canal admin visible — prévoir un canal de secours manuel (WhatsApp/téléphone, déjà la pratique de facto documentée ailleurs) pour la durée du pilote.
- 🟡 Aucune suspension temporaire de livreur classique — seule la suppression complète est possible en cas de comportement problématique pendant le pilote.

#### Actions avant lancement (checklist condensée)
1. Débloquer la facturation Cloud Build (Google Cloud Console) et déployer les 23 Cloud Functions manquantes, en priorité Lots 2-3.
2. Créer les zones Abengourou, le vendeur boutique, et approuver les comptes pilotes (livreurs/restaurants/pharmacies/boutiques) listés ci-dessus.
3. Tester manuellement sur un appareil réel le parcours complet client→dispatch→livreur→livraison→wallet une fois les CF déployées (jamais testé en conditions réelles à ce jour, limite déjà actée).
4. Prévoir un canal de support manuel de secours (WhatsApp/téléphone) pour la durée du pilote, en l'absence d'écran admin de gestion des litiges.
5. Décider si la suspension temporaire des livreurs classiques doit être construite avant ou peut attendre après le pilote (actuellement : suppression complète uniquement).

---

## 28. Admin Panel & Seed Data Readiness — Master Prompt 73

Audit-only avec autorisation explicite « corriger uniquement bugs simples » (contrairement au Prompt 72). Un bug simple, réel, confirmé et corrigé — une règle Firestore manquante, pas un défaut de code applicatif.

### 1) Admin dashboard — capacité de gestion par entité

| Entité | Écran(s) admin | État |
|---|---|---|
| Livreurs | `drivers_page.dart`, `driver_requests_page.dart` | ✅ Fonctionnel |
| Vendeurs | `admin_sellers_page.dart` | ✅ Fonctionnel |
| Restaurants | `admin_restaurants_page.dart`/`admin_restaurant_requests_page.dart` | ✅ Fonctionnel |
| Pharmacies | `admin_pharmacies_page.dart` | ✅ Fonctionnel |
| Boutiques | `admin_boutique_page.dart` | 🔴 Création produit cassée — corrigée cette passe |
| Agents Ekbine | `admin_ekbine_page.dart` | ✅ Fonctionnel |
| **Clients** | Aucun écran général | 🔴 Gap confirmé — seuls 2 écrans étroits (COD, remboursement ponctuel) touchent `clients` |
| **Immobilier** | Aucun | 🔴 Gap déjà connu (M6), reconfirmé — `approveRealEstateAgentRequest` reste sans UI |

### 2) `admin_zones_page.dart` — test des 5 zones demandées

Un bouton "Initialiser les zones" pré-charge déjà 19 zones codées en dur, dont **"Commerce" et "Cafétou" (2 des 5 demandées)**. Les 3 autres ("Agnikro", "Dioulakro", "Indénié") nécessitent un ajout manuel via le formulaire "+" — vérifié fonctionnel (nom/type/ville parente/GPS). Activation/désactivation : fonctionnelle (`_toggleActive`). **Prix/distance : confirmé absents du formulaire et du schéma Firestore** — `zones_livraison` reste un simple sélecteur nominatif pour l'écran "Commander", sans lien avec la tarification (`TarifService`, point central fixe + haversine, déjà documenté). Pas un bug, réponse directe à ce que ce prompt demandait de vérifier. Liste des zones vérifiée contre le risque de chargement infini (Prompt 71/72) — **confirmée saine** (repli sur liste vide, pas de spinner infini).

### 3) Livreurs

Téléphone et statut en ligne/hors ligne affichés par carte (`drivers_page.dart`). Aucune suspension pour les livreurs classiques (déjà documenté, reconfirmé). Validation d'inscription et documents KYC déjà fonctionnels (audités en profondeur les sessions précédentes).

### 🔴 4) Bug confirmé et corrigé — création de produit Boutique depuis l'admin structurellement impossible

Trouvé en préparant le plan de seed Boutique (ci-dessous). `firestore.rules` : `boutique_products` avait `allow create: if isRealUser() && request.resource.data.sellerId == uid();` — **sans clause `isAdmin()`**, contrairement à `update`/`delete` sur la même collection. Le code de création (`admin_boutique_page.dart:_saveProduct`, chemin nouveau produit) n'écrit d'ailleurs jamais de champ `sellerId` du tout. **Conséquence : impossible de créer le moindre produit Boutique depuis l'admin, à 100% des tentatives, permission-denied systématique** — même avec un vendeur `type:'boutique'` déjà créé (Prompt 72), aucun produit n'aurait pu être ajouté. Vérifié que le vrai flux d'achat (`payBoutiqueOrderCF`) ne lit jamais `sellerId` sur le produit (il re-résout le vendeur boutique unique via une requête séparée) — donc ce champ n'est ni requis ni utile fonctionnellement, pas la peine de le faire écrire côté Dart. **Corrigé** : `firestore.rules`, ajout de `isAdmin() ||` à la règle `create` de `boutique_products`, exactement le schéma déjà en place sur `update`/`delete`. Validé par dry-run réel contre le projet — compile sans erreur. Seul fichier modifié cette passe.

### 5) Support pilote — second gap confirmé

`support_tickets` : déjà confirmé sans consommateur admin (Prompt 72). **Nouveau** : `marketplace_reports` (signalements d'abus) suit le même schéma — écrit par le client, lu par aucun écran admin. Seul `admin_sos_page.dart` reste un canal réellement géré des deux côtés.

### 6) Sécurité admin

Rien de nouveau — aucune route mobile n'atteint `AdminDashboard` sans `AdminLogin` (pas de deep-linking mobile), le web bloque déjà `/admin/*` derrière `AdminAuthService.isAdmin`. Le geste "5 taps sur le logo" ouvre uniquement l'écran de connexion, jamais les données.

### Plan de seed Firestore (avant ouverture pilote)

| Collection | Contenu minimum | Comment |
|---|---|---|
| `zones_livraison` | 19 zones du bouton "Initialiser" + Agnikro/Dioulakro/Indénié ajoutées manuellement | `admin_zones_page.dart` |
| `sellers` | Au moins 1 avec `type:'boutique'` + quelques `type:'seller'` (Marketplace) | `admin_sellers_page.dart` |
| `restaurants` | Au moins 1 actif avec menu non vide | `admin_restaurants_page.dart` + sous-collection `menu` |
| `pharmacies` | Au moins 1 active | `admin_pharmacies_page.dart` |
| `boutique_products` | Quelques produits avec stock réel | `admin_boutique_page.dart` (fonctionnera après le correctif de règles ci-dessus) |
| `marketplace_products` | Optionnel pour le pilote (pas de flux d'achat structuré côté app normale, contact direct vendeur) | Vendeurs eux-mêmes via l'app |
| Comptes "users" (pas de collection unique — RBAC par appartenance de collection) | 5 `livreurs` approuvés, 3-5 `clients` réels (pas anonymes), 1 `sellers` boutique | Auto-inscription + approbation admin selon le rôle |

### Validation exécutée

`flutter analyze` inchangé (5 avertissements préexistants, aucun fichier Dart modifié). `npm test` (`functions/`) toujours 156/156 (aucune Cloud Function touchée). `firebase deploy --only firestore:rules --dry-run` compile sans erreur. `flutter build appbundle --release` réussi (build incrémental, AAB inchangé — aucun code Dart/Android modifié).

---

### 🎯 PRÊT OUVERTURE AGENCE : **NON**, mais un blocueur de moins qu'avant cette passe

Toujours bloqué par (1) le déploiement Cloud Functions (Sections 18-20/26) et (2) la préparation de données terrain (Section 27) — **mais le module Boutique, qui aurait échoué silencieusement même avec toutes les données préparées, est désormais réparé au niveau des règles.**

#### Données à créer
Voir le plan de seed ci-dessus — inchangé par rapport à la Section 27, avec la confirmation supplémentaire que 2 des 5 zones demandées existent déjà dans le seed intégré de `admin_zones_page.dart`.

#### Bugs admin trouvés
🔴 Création de produit Boutique impossible depuis l'admin (règle Firestore manquante) — **corrigé**.
🟡 Aucun écran de gestion générale des clients (recherche/vue/commandes) — non corrigé, nouvelle fonctionnalité.
🟡 Aucun écran admin pour `support_tickets` ni `marketplace_reports` — non corrigé, nouvelle fonctionnalité, canal manuel recommandé pour le pilote.
🟡 Aucune suspension temporaire pour les livreurs classiques — non corrigé, déjà documenté.
🟡 Aucun écran admin pour l'Immobilier — non corrigé, déjà documenté depuis le jalon M6.

#### Fichiers modifiés
- `firestore.rules` (règle `create` de `boutique_products`)

---

## 29. Partner Real World Flow Audit — Master Prompt 74

Traçage direct du code pour les 6 rôles partenaires demandés. « Corriger uniquement bugs confirmés » — un seul trouvé, mais critique et jamais détecté par aucun audit précédent.

### 🔴 Pharmacie — bug critique confirmé et corrigé : inscription structurellement impossible à 100%

Contrairement à une affirmation répétée dans ce document depuis le début de la session (« pharmacies créées directement par l'admin, pas de flux d'approbation ») — **fausse, corrigée** : `pharmacie_register.dart`/`admin_pharmacie_requests_page.dart` existent et sont câblés dans la navigation. Mais le formulaire ne pouvait jamais aboutir, pour deux raisons cumulées :
1. La règle `pharmacie_requests` exigeait `isRealUser() && uid == uid()` — mais contrairement à ses 3 cousins fonctionnels (`driver_requests`/`seller_requests`/`restaurant_requests`, qui créent tous un vrai compte Firebase Auth **avant** d'écrire la demande), `pharmacie_register.dart` n'authentifie personne (les pharmacies utilisent une authentification Firestore custom, jamais Firebase Auth) — l'appelant reste sur la session anonyme par défaut, et `isRealUser()` échoue toujours.
2. Le payload écrit ne contenait de toute façon jamais de champ `uid`.
3. **Aggravant** : une lecture de pré-vérification de doublon (`.get()`) précédait même la tentative d'écriture, sur une collection dont la règle de lecture est admin-only — cette lecture échouait aussi systématiquement, bloquant le formulaire dès sa première ligne de logique.

**Corrigé** : `firestore.rules` — `pharmacie_requests` traité comme un formulaire de lead pré-compte (même famille que `driver_applications`/`partner_applications`, Prompt 57), écriture publique avec validation stricte de forme, lecture admin-only. `pharmacie_register.dart` — suppression de la lecture de pré-vérification devenue inutile (`.set()` reste idempotent par téléphone). Validé par dry-run réel.

**Comparaison éclairante avec Ekbine** (même structure de règle en apparence, mais sain) : `ek_agent_register.dart` a le même schéma de risque, mais `ek_home_screen.dart` redirige explicitement vers `ClientAuthPage` si l'utilisateur est encore anonyme, **avant** d'atteindre l'écran d'inscription — garde absente sur le chemin pharmacie. C'est cette garde manquante, pas l'architecture de la règle, qui distingue les deux cas.

### Autres rôles — tous sains, vérifiés (pas supposés)

- **Restaurant** : inscription→approbation→menu→commandes→historique, tout fonctionnel. Point de vigilance vérifié : la règle d'écriture du menu dépend de `restaurant_owners/{uid}`, correctement créé au moment de l'approbation.
- **Boutique** : sain après le correctif du Prompt 73 (création/stock/prix/images). Pas de compte vendeur séparé — entièrement piloté par l'admin, confirmé par design.
- **Marketplace vendeur** : publication/modification/suppression/contact client — tous sains, `sellerId` correctement écrit partout.
- **Agent Ekbine** : inscription (correctement gardée)/validation/commandes/historique — sain.
- **Immobilier** : ajout de bien sain (`agentId` correctement écrit). **Photos confirmées absentes** du formulaire (déjà documenté, pas une régression). Contact client : téléphone affiché en texte non cliquable, mais le vrai mécanisme de contact conçu (bouton "Demander une visite") fonctionne pleinement — pas un bug équivalent au Prompt 56.
- **Écrans vides/chargements infinis** : aucune nouvelle instance du pattern à risque déjà isolé et corrigé au Prompt 71 — les 6 dashboards partenaires vérifiés utilisent tous le repli sûr (`snap.data?.docs ?? []`).

### Corrections de documentation

Deux affirmations fausses dans `CLAUDE.md` (section Restaurants/Pharmacies) corrigées : les pharmacies ont bien un tableau de bord partenaire (2 onglets) et un flux d'inscription (désormais réparé), contrairement à ce qui était écrit depuis le début de la session.

### Validation exécutée

`flutter analyze` inchangé (5 avertissements préexistants, aucun nouveau). `npm test` (`functions/`) toujours 156/156 (aucune Cloud Function touchée). `firebase deploy --only firestore:rules --dry-run` compile sans erreur. `flutter build appbundle --release` réussi.

---

### 🎯 Rôles prêts terrain / bloqués

| Rôle | État |
|---|---|
| Restaurant | ✅ Prêt |
| Pharmacie | ✅ Prêt (après correctif de cette passe — bloqué avant) |
| Boutique | ✅ Prêt (après correctif Prompt 73) |
| Marketplace vendeur | ✅ Prêt |
| Agent Ekbine | ✅ Prêt |
| Immobilier | 🟡 Fonctionnel sans photos (gap déjà connu, pas un blocage dur) |

**Tous les 6 rôles partenaires sont désormais fonctionnels au niveau applicatif** — le blocage de lancement réel reste entièrement celui déjà documenté (Sections 18-20/26/27 : déploiement Cloud Functions + préparation des données terrain), pas un défaut de code partenaire.

#### Corrections
🔴 Inscription pharmacie structurellement impossible — **corrigée** (règle Firestore + suppression d'une lecture bloquante).

#### Fichiers modifiés
- `lib/screens/pharmacie/pharmacie_register.dart`
- `firestore.rules` (règle `pharmacie_requests`)

---

## 30. AZ Express Business Launch Readiness — Master Prompt 75

Audit business/opérationnel, pas un audit de code au sens habituel. Un bug financier critique trouvé et corrigé en creusant la section "argent réel" — le 11ᵉ bug financier critique de toute la session.

### 🔴 Bug critique corrigé — double prélèvement de commission livreur sur chaque commande

Tracé bout en bout : `acceptOrder()` (Dart, à l'acceptation) débite déjà la commission du wallet livreur — remboursable à l'annulation. Mais `deliverOrderCF` (Cloud Function, à la livraison) débitait **une seconde fois** : 100 FCFA fixe pour le cash, et l'équivalent déguisé dans les calculs de crédit pour le wallet (partenaire et livreur). Sur une commande cash à 500 FCFA, le livreur payait 200 FCFA de commission (40%) au lieu de 100 (20%). Chaque fonction était individuellement correcte et déjà testée en isolation — c'est leur **interaction** sur le cycle de vie complet d'une commande qui était fautive, jamais tracée avant cette passe. Même famille exacte que le double-débit pharmacie déjà trouvé cette session.

**Décision utilisateur obtenue avant correction** (architecture financière centrale, ambiguïté réelle sur la bonne solution) : **commission uniquement à l'acceptation**. Corrigé dans `functions/orderActions.js:buildDeliverOrder` — les 3 points de double-prélèvement supprimés (branche cash : plus de débit à la livraison ; branche partenaire : crédit intégral ; branche livreur sans vendeur : crédit intégral). Écritures `wallet_transactions` corrigées en cohérence (plus d'entrée fantôme). Compteurs analytiques purs (`totalCommissions`, `commissions`) inchangés — aucun mouvement d'argent réel n'en dépend. 3 tests réécrits pour refléter le comportement corrigé, suite toujours à 156 tests.

### 1) Premier jour opération — blocages identifiés

- Données déjà identifiées comme obligatoires (Prompts 72-73) : zones actives, vendeur boutique + produits, contenu restaurant/pharmacie réel.
- **Nouveau risque opérationnel identifié en creusant "qui encaisse le cash"** : pour une commande produit (restaurant/pharmacie/boutique) payée en espèces, le livreur collecte du cash couvrant livraison + produit — **aucune trace numérique de la remise de la part "produit" au marchand n'existe dans l'app**. Processus entièrement manuel/de confiance aujourd'hui. Distinct du mécanisme de commission (déjà correctement pré-payé par le wallet livreur, indépendamment du cash).
- Gap déjà connu (Prompts 72-74) : aucun canal admin pour litiges/support_tickets/marketplace_reports — tout passe par un canal manuel externe.

### 2) Livreurs

Inscription/validation/disponibilité déjà sains (audités en profondeur). **Commission AZ : corrigée cette passe** (voir ci-dessus) — collectée une seule fois, à l'acceptation, remboursable à l'annulation. Historique revenus fonctionnel (wallet_transactions du livreur + `admin_earnings.dart`/`admin_commissions_page.dart`). "Problème livraison" : aucun écran dédié — tombe dans le même gap que les litiges généraux, résolution manuelle. Aucune suspension temporaire pour les livreurs classiques (déjà documenté) — risque réel si un livreur pose problème pendant le pilote.

### 3) Argent réel

- **Qui encaisse le cash** : pour une livraison/course pure, le livreur collecte le montant complet du client ; la commission AZ est déjà prise de son wallet à l'acceptation (corrigée cette passe pour n'être prise qu'une fois). Pour un produit (restaurant/pharmacie/boutique) payé cash, le livreur collecte aussi la part "produit" — sans traçabilité numérique de la remise au marchand (voir ci-dessus).
- **Comment AZ récupère sa commission** : via débit du wallet livreur à l'acceptation, recharge via mobile money (FeexPay) — modèle pré-payé propre, pas de "dette" à réclamer après coup pour la commission elle-même.
- **Suivi dette livreur** : ne s'applique pas au sens classique pour la commission (déjà pré-payée). S'applique en revanche, de façon non trackée, à la part "produit" du cash collecté pour compte d'un marchand (voir ci-dessus) — vrai risque opérationnel, pas un défaut de code.
- **Remboursements** : toujours vers le wallet client, jamais en espèces physiques — cohérent, mais signifie qu'un remboursement pour une commande payée cash doit être géré manuellement (l'argent n'a jamais transité par AZ numériquement).

### 4) Support client

`commande retard` : pas d'escalade automatisée au-delà de l'auto-expiration à 10 min (commandes non dispatchées uniquement). `livreur absent` : pas de flux dédié — annulation manuelle ou contact support externe. `produit indisponible` : pas de flux de substitution structuré (déjà documenté, modèle "Courses"). `client mécontent` : `support_tickets` existe mais zéro visibilité admin (déjà documenté) — canal manuel WhatsApp/téléphone requis pour le pilote.

### 5) Tâches admin quotidiennes

**Matin** : vérifier les commandes/alertes SOS de la nuit (`admin_sos_page.dart`), vérifier le nombre de livreurs en ligne, vérifier que restaurants/pharmacies actifs ont bien basculé "ouvert", traiter les nouvelles demandes partenaires arrivées (`driver_requests_page.dart`/`admin_*_requests_page.dart`).

**Journée** : surveiller `admin_orders.dart` en temps réel, suivre `admin_live_tracking_page.dart` pour les livraisons en cours, traiter les demandes de recharge/retrait (`admin_recharge_page.dart`), répondre aux sollicitations support reçues par le canal manuel (WhatsApp/téléphone), approuver les nouvelles demandes partenaires au fil de l'eau.

**Soir** : réconcilier le cash de la journée avec chaque livreur (processus manuel, pas d'outil dédié — voir section 3), consulter `admin_geo_stats_page.dart`/`admin_drivers_ranking.dart` pour la performance du jour, vérifier `admin_security_dashboard.dart` pour les échecs de dispatch/anomalies, documenter tout incident pour ajustement le lendemain.

**Hebdomadaire (rappel)** : `walletReconciliationCheck` tourne automatiquement chaque lundi 4h — consulter `wallet_reconciliation_findings` en cas d'écart signalé.

### 6) Checklist de lancement

**J-7** : débloquer la facturation Cloud Build (Google Cloud Console) et déployer les Lots 2-3 des Cloud Functions manquantes (dispatch, paiements) ; recruter/pré-inscrire les 5 livreurs pilotes (KYC) ; recruter les premiers partenaires (restaurants/pharmacies/vendeurs) et démarrer leurs demandes d'approbation ; former l'équipe admin aux tâches quotidiennes ci-dessus ; préparer le canal de support manuel (WhatsApp/téléphone) ; décider du processus manuel de réconciliation cash driver↔marchand.

**J-3** : créer les zones Abengourou (19 pré-chargées + Agnikro/Dioulakro/Indénié manuelles) ; créer le vendeur boutique (`type:'boutique'`) + produits en stock ; approuver tous les comptes pilotes en attente ; tester le parcours complet sur un vrai appareil (jamais fait à ce jour) ; vérifier que les livreurs pilotes ont un solde wallet suffisant et sont prêts à se mettre en ligne ; vérifier au moins 1 restaurant + 1 pharmacie actifs avec contenu réel.

**Jour J** : admin en ligne dès l'ouverture pour surveiller `admin_orders.dart` en temps réel ; canal de support manuel activement surveillé ; suivre les 10 premières commandes individuellement si possible ; vérifier que chaque livraison se conclut correctement (statut `delivered`, wallet livreur/partenaire cohérent) ; réconcilier le cash en fin de journée avec chaque livreur/marchand ; documenter tout problème rencontré.

### Validation exécutée

`flutter analyze` inchangé (5 avertissements préexistants, aucun fichier Dart modifié — correctif Cloud Functions uniquement). `npm test` (`functions/`) toujours 156/156 (3 tests réécrits). `firebase deploy --only firestore:rules --dry-run` compile sans erreur (aucune règle modifiée cette passe). `flutter build appbundle --release` réussi.

---

### 🎯 PRÊT LANCEMENT : **NON** — mais le code applicatif (client/livreur/partenaires/admin) est maintenant financièrement correct

Le blocage reste entièrement celui déjà documenté (déploiement Cloud Functions + préparation des données terrain) — **avec un risque financier de moins** : la commission AZ est désormais correctement prélevée une seule fois par commande, plutôt que deux.

#### Risques business
🔴 Aucune commande de livraison n'aboutit tant que les Cloud Functions ne sont pas déployées (inchangé, Sections 18-20/26).
🔴 Aucune traçabilité numérique de la remise de cash "produit" du livreur au marchand — processus manuel/de confiance à formaliser avant le pilote.
🟡 Aucun canal admin pour litiges/support pendant le pilote — canal manuel obligatoire.
🟡 Aucune suspension temporaire de livreur classique en cas de problème.

#### Procédures nécessaires (à formaliser avant ouverture, pas du code)
1. Procédure de réconciliation cash quotidienne driver↔marchand↔AZ.
2. Procédure de support manuel (qui répond, sur quel canal, avec quel délai).
3. Liste des tâches admin quotidiennes (matin/journée/soir) ci-dessus, à assigner à une personne responsable.
4. Procédure de remboursement manuel pour les commandes payées cash.

#### Actions obligatoires avant ouverture
Voir checklist J-7/J-3/Jour J ci-dessus — synthèse de tout ce qui a été identifié depuis le Prompt 65 jusqu'à cette passe.

#### Fichiers modifiés
- `functions/orderActions.js` (suppression du double prélèvement de commission)
- `functions/test/orderActions.test.js` (3 tests réécrits)

---

## 31. Cash Flow & Merchant Payout Safety — Master Prompt 76

Suite directe de la trouvaille opérationnelle du Prompt 75 ("aucune traçabilité du cash produit remis au marchand"), avec autorisation explicite de construire une correction minimale. Un second bug fonctionnel trouvé au passage (Boutique cash bloquée indéfiniment), les deux corrigés — additif, sans toucher au wallet.

### Audit précis des 3 scénarios cash

Confirmé en relisant `deliverOrderCF` : pour une commande cash avec un `sellerId` (restaurant/pharmacie), le wallet du marchand n'est **jamais** crédité — la branche cash ne regarde ni `sid` ni `sType`. Le livreur collecte en espèces le montant total (produit + livraison) et doit remettre la part produit au marchand physiquement — sans aucune trace Firestore avant cette passe.

### 🔴 Bug fonctionnel distinct trouvé — Boutique cash bloquée indéfiniment

`payBoutiqueOrderCashCF` crée `boutique_orders` avec `status:'pending_payment'`, mais `admin_boutique_page.dart` ne réagit qu'à `status=='paid'` pour le premier bouton de progression — `pending_payment` n'était dans aucune map de couleur/libellé et n'avait **aucun bouton pour en sortir**. Confirmé qu'aucun code ne fait jamais transitionner ce statut : une commande Boutique cash restait bloquée en permanence, jamais préparée ni livrée, sauf édition manuelle de Firestore.

### Risques confirmés (les 4 du prompt, tous réels)

Livreur garde l'argent produit / oublie la remise / marchand conteste — tous confirmés possibles sans aucun signal Firestore avant cette passe. Client rembourse — déjà correctement isolé (remboursements toujours vers le wallet client, jamais en espèces), sans changement nécessaire.

### Correction minimale implémentée (additive, wallet non touché)

- `functions/orderActions.js:buildDeliverOrder` — nouveau champ `merchantCashSettled: false` sur la commande, uniquement pour cash + `sellerId` présent + type ≠ boutique. Aucune écriture wallet, aucun changement pour les commandes sans vendeur (le livreur garde déjà 100% du cash, Prompt 75).
- `lib/screens/admin/admin_cash_settlement_page.dart` (nouveau) — liste les commandes non réglées (marchand/montant/livreur/date), bouton "Marquer réglé" (écriture directe, admin uniquement — `merchantCashSettledAt`/`merchantCashSettledBy` servent d'historique/preuve, pas de nouvelle collection). Wired dans `admin_dashboard.dart` (nouvelle permission `cash_marchand`, ajoutée aussi à `admin_sub_admins_page.dart`).
- `admin_boutique_page.dart` — `pending_payment` ajouté aux maps + bouton "Confirmer l'espèce reçue" → `'paid'`, débloquant le flux existant et servant de confirmation de règlement en une action.
- Aucune règle Firestore modifiée — `orders`/`boutique_orders` autorisent déjà `isAdmin()` en écriture libre.

### Capacité admin (item 5)

Voir dette livreur : identifiant livreur affiché par commande (pas encore groupé par livreur — limite assumée). Voir argent marchand à payer : couvert directement. Clôturer journée : pas de mécanisme formel construit — la revue quotidienne de l'écran jusqu'à ce qu'il soit vide fait office de clôture pratique.

### Validation exécutée

`flutter analyze` propre sur les 4 fichiers modifiés/créés et complet (5 avertissements préexistants, aucun nouveau). `npm test` (`functions/`) désormais **158/158** (156 + 2 nouveaux tests). `node -c`/`require('./index.js')` toujours 53 exports. `flutter build appbundle --release` réussi.

---

### 🎯 RISQUE DE PERTE D'ARGENT : **Oui, confirmé — désormais tracé et gérable, pas éliminé**

Le risque physique (un livreur qui garde ou oublie de remettre le cash produit) reste réel — aucune app ne peut empêcher un vol pur et simple. Ce qui a changé : ce risque est désormais **visible et traçable** (statut, montant, livreur, horodatage) plutôt qu'invisible, et le second bug trouvé (Boutique cash bloquée) est corrigé.

#### Correction faite
🔴 Boutique cash bloquée indéfiniment — **corrigée** (statut débloqué, bouton de confirmation ajouté).
🟡 Aucune traçabilité du règlement cash marchand (restaurant/pharmacie) — **corrigée** (nouveau champ + écran admin).

#### Fichiers modifiés
- `functions/orderActions.js`
- `functions/test/orderActions.test.js` (2 nouveaux tests)
- `lib/screens/admin/admin_cash_settlement_page.dart` (nouveau)
- `lib/screens/admin/admin_dashboard.dart`
- `lib/screens/admin/admin_boutique_page.dart`
- `lib/screens/admin/admin_sub_admins_page.dart`

#### État pilote cash
Le code applicatif permet désormais de suivre et clôturer le cash marchand quotidiennement. La procédure de réconciliation elle-même (qui vérifie, à quelle fréquence, avec quelle sanction en cas d'écart) reste à formaliser humainement — pas un défaut de code, déjà signalé comme procédure nécessaire au Prompt 75.

---

## 32. Driver Operations & Fraud Safety — Master Prompt 77

La trouvaille la plus significative n'est pas un nouveau bug mais une capacité manquante depuis le Prompt 05 : les livreurs classiques ne pouvaient pas être suspendus, alors que le backend le supportait déjà entièrement.

### 1) Vie livreur — sain, cross-référencé

Inscription/validation/online-offline/réception/historique gains — tous déjà confirmés fonctionnels par les audits précédents.

### 🔴 2) Suspension — capacité manquante confirmée et corrigée

`dispatch.js` exclut déjà `isSuspended===true`, `acceptOrder()` revérifie déjà `isSuspended` à l'acceptation — seule pièce manquante : aucun bouton admin pour écrire `isSuspended:true` sur un livreur classique (`drivers_page.dart` n'avait aucune référence à ce champ, contrairement à `admin_ekbine_page.dart` qui l'a déjà pour les agents Ekbine). **Corrigé** : bouton suspendre/réactiver ajouté à `_DriverCard` (icône pause/play + dialogue de confirmation), badge "SUSPENDU", même schéma exact que Ekbine. Aucune règle Firestore modifiée.

### 3) Fraude — 4 scénarios testés

- *Coupe GPS* : déjà couvert (`admin_live_tracking_page.dart` calcule déjà la fraîcheur GPS par livreur en ligne).
- **🔴 *Garde une commande ouverte / refuse de terminer* : gap confirmé — `autoExpireOrders` ne couvre que `pending`/`broadcast`/`assigned`, jamais `accepted`/`picked_up`.** Une commande acceptée peut rester ouverte indéfiniment sans alerte. **Corrigé côté visibilité uniquement** (pas de prévention automatique, hors périmètre "ne pas toucher dispatch core") : `admin_orders.dart` affiche désormais un signal "en retard" (bordure rouge + avertissement) pour toute commande `accepted`/`picked_up` depuis plus d'1h.
- *Garde cash marchand* : déjà couvert par le Prompt 76.
- **🟡 *Plusieurs comptes* : gap confirmé, documenté, non corrigé.** Firebase Auth empêche les doublons d'email, mais aucune vérification d'unicité téléphone/pièce d'identité n'existe pour les candidatures livreur. Corriger correctement nécessiterait une Cloud Function (inerte tant que le déploiement est bloqué) ou un assouplissement de règles (décision de sécurité, pas une correction minimale) — documenté comme risque réel.

### 4) Preuves livraison

Photo + GPS déjà en place et fonctionnels. **Confirmation client : confirmé absente** (recherche exhaustive) — la livraison reste entièrement attestée par le livreur, jamais par le client. Gap déjà connu, pas construit (trop large pour une correction minimale).

### 5) Fin de journée

Toutes les pièces sont désormais en place après les Prompts 76/77 : cash (Prompt 76), commandes + signal retard (cette passe), performance livreur (déjà existant).

### Validation exécutée

`flutter analyze` propre sur les 2 fichiers modifiés et complet (5 avertissements préexistants, aucun nouveau). `npm test` (`functions/`) toujours 158/158 (aucun fichier touché, confirmé via `git status`). `flutter build appbundle --release` réussi.

---

### 🎯 PRÊT GESTION FLOTTE : **Oui, pour un pilote supervisé** — les deux gaps opérationnels les plus critiques (suspension, commandes bloquées) sont désormais couverts

#### Risques fraude restants
🟡 Plusieurs comptes livreur possibles (aucune vérification d'unicité téléphone/ID) — nécessite une décision de sécurité ou le déblocage du déploiement CF pour être corrigé proprement.
🟡 Aucune confirmation client de la livraison — la preuve reste unilatérale (livreur uniquement).
🟢 Coupe GPS et cash marchand : déjà couverts (cette passe + Prompt 76).
🟢 Commande gardée ouverte / refus de terminer : désormais visible pour l'admin (pas de prévention automatique, mais plus invisible).

#### Corrections appliquées
🔴 Suspension livreur classique — **construite** (backend déjà prêt, UI ajoutée).
🔴 Commandes bloquées après acceptation — **signal de visibilité ajouté** (pas de prévention automatique).

#### Fichiers modifiés
- `lib/screens/admin/drivers_page.dart`
- `lib/screens/admin/admin_orders.dart`

---

## 33. Support Client & Incident Management — Master Prompt 78

Ferme le gap le plus anciennement documenté et le plus souvent reconfirmé de toute la session (Prompts 13/72/74/76 : "support_tickets n'a aucun consommateur admin") en construisant le fil manquant des deux côtés.

### 🔴 Trouvaille clé — la règle Firestore permettait déjà la réponse bidirectionnelle, seule l'UI manquait

`support_tickets` autorisait déjà le propriétaire du ticket à modifier `messages` (tant que `status` ne change pas) et l'admin en accès total — depuis le début. Ni le client ni l'admin n'avaient d'UI pour l'utiliser.

### Corrections apportées (des deux côtés)

- **Client** (`support_screen.dart`) : ticket cliquable → nouvel écran de détail (fil complet + réponse), badge "Réponse du support disponible".
- **Admin** (`admin_support_page.dart`, nouveau) : onglet Tickets (liste triée, détail + réponse + changement de statut) + onglet Signalements produits (`marketplace_reports`, Ignorer/Traité). Wired dans `admin_dashboard.dart`/`admin_sub_admins_page.dart` (permission `support`).
- Aucune règle Firestore modifiée (déjà suffisantes).

### Signalements

"Signaler produit" déjà fonctionnel côté client, juste sans visibilité admin — corrigé. "Signaler livreur"/"vendeur" : pas construits comme boutons séparés — le système de catégories `support_tickets` couvre déjà ce besoin en texte libre, dupliquer aurait été redondant.

### Notifications — gap réel documenté, non corrigé

Client informé : réactif (StreamBuilder), pas de push proactif — nécessiterait une nouvelle Cloud Function (inerte tant que le déploiement reste bloqué). Partenaire informé d'un signalement : absent, nouvelle fonctionnalité hors périmètre.

### Validation exécutée

`flutter analyze` propre sur les 4 fichiers modifiés/créés, complet inchangé (5 avertissements). `npm test` toujours 158/158 (aucun fichier `functions/` touché). `flutter build appbundle --release` réussi.

---

### 🎯 PRÊT SUPPORT PILOTE : **Oui**

#### Risques restants
🟡 Pas de notification push proactive pour les réponses de support (réactif uniquement).
🟡 Pas de notification vendeur en cas de signalement.
🟢 Tickets désormais bidirectionnels et visibles admin. 🟢 Signalements produits désormais traitables.

#### Fichiers modifiés
- `lib/screens/support/support_screen.dart`
- `lib/screens/admin/admin_support_page.dart` (nouveau)
- `lib/screens/admin/admin_dashboard.dart`
- `lib/screens/admin/admin_sub_admins_page.dart`

#### Résultat build
`flutter analyze` inchangé (5 avertissements), `npm test` 158/158, `flutter build appbundle --release` ✅ réussi (74,1 Mo).

## 34. Scale & Performance Pilot Readiness — Master Prompt 79

Audit de stabilité sous charge simulée (100 clients/20 livreurs/50 commandes/jour/plusieurs partenaires). Instruction explicite : « corriger uniquement optimisations sûres », ne pas toucher logique métier/paiement/dispatch.

### Corrections sûres appliquées

- **`admin_cash_settlement_page.dart`** (Prompt 76) et **`admin_support_page.dart`** onglet Signalements (Prompt 78) : requêtes `.snapshots()` sans `.limit()` → `.limit(100)` ajouté aux deux. Aucun risque : listes de travail (cash à régler, signalements en attente), jamais des agrégats sommés.
- **`admin_support_page.dart`** : `Image.network(screenshotUrl)` (capture d'écran de ticket) → `CachedNetworkImage` — un exemplaire de plus de la régression déjà documentée au Prompt 59, introduit par le Prompt 78 lui-même. Correctif narrow, un seul fichier.

### 🔴 Trouvaille principale — ~30 écrans admin lisent une collection/`.where()` sans `.limit()`, PAS corrigé en masse

Recherche exhaustive (pas un échantillon) sur `lib/screens/admin/*.dart` + `web_admin_dashboard.dart` : environ 30 requêtes sans plafond, dont les listes de comptes partenaires complètes (`sellers`/`restaurants`/`boulangeries`/`pharmacies`/`fleet_owners`), les écrans d'approbation (5 fichiers `*_requests_page.dart`), `admin_boutique_page.dart` (produits/commandes/recharges), `admin_recharge_page.dart`, `admin_commissions_page.dart`, `admin_map.dart`, `admin_drivers_ranking.dart`, `admin_cod_page.dart`.

**Raison précise de ne pas corriger en masse, vérifiée et pas supposée** : `admin_earnings.dart:150-174` additionne côté client `totalCommissions` sur TOUTES les commandes `status=='delivered'` lues sans `.limit()`. Ajouter un `.limit(N)` sur ce type de requête **tronquerait silencieusement le total affiché à l'admin** — une régression de correction financière déguisée en optimisation de coût, sans aucune erreur visible. Le même risque s'applique à `admin_drivers_ranking.dart` (classement par nombre de livraisons, calculé sur `orders` livrées lues sans plafond malgré une mention contraire ailleurs dans `CLAUDE.md` — « 500 dernières commandes » — qui n'existe pas dans le code réel de cet écran, corrigé comme trouvaille de documentation).

Distinguer, fichier par fichier, les écrans **liste de travail** (sûrs à borner, comme les 2 déjà corrigés) des écrans **agrégat côté client** (où borner change le résultat affiché) est un vrai chantier d'audit + conception — pas une « optimisation sûre » exécutable en un passage. Documenté comme risque à traiter avant que le volume grandisse significativement, pas corrigé.

### Reste vérifié sain (cross-référencé, pas re-dérivé)

- **Cloud Functions** : aucune nouvelle boucle non bornée ; `dispatch.js:44` (scan livreurs en ligne) reste le seul cas serveur, déjà accepté pour le volume pilote.
- **Storage/compression** : `imageQuality`/`maxWidth` déjà appliqués à 26 fichiers d'upload, y compris les 2 écrans les plus récents — pas de régression à l'upload (contrairement à l'affichage, `Image.network`, toujours non résolu ailleurs).
- **GPS** : `DriverLocationService` throttle 5s+15m inchangé, coût/batterie négligeable à 20 livreurs.
- **Mémoire Flutter** : les contrôleurs des 3 nouveaux écrans (Prompts 76-78) vérifiés un par un, tous disposés correctement — aucune fuite.
- **Google Maps** : cache 100m/5min + Nominatim-first toujours en place, throttle Directions 120s inchangé.

### Validation exécutée

`flutter analyze` complet — **8 avertissements** (pas 5 : baseline jamais recomptée depuis le Prompt 38 — 1 préexistant + 4 `deprecated_member_use` Radio dans `agent_dashboard_screen.dart` [SDK Flutter] + 3 `prefer_const_*` dans `delete_account_page.dart` [Prompt 69] — aucun dans un fichier touché cette passe, correction de comptage documentaire, pas une régression). `npm test` **158/158** (aucun fichier `functions/` touché). `flutter build appbundle --release` ✅ réussi (`app-release.aab`, 71,2 Mo).

---

### 🎯 CAPACITÉ PILOTE ESTIMÉE : largement suffisante pour 100 clients / 20 livreurs / 50 commandes-jour

À ce volume, aucune des lectures non bornées documentées ci-dessus ne constitue un risque de coût réel — c'est un risque à réévaluer avant une **grande échelle** (des centaines de livreurs, des milliers de commandes livrées cumulées), pas avant le pilote.

#### Risques coûts Firebase
🟡 ~30 écrans admin sans `.limit()` — sûrs au volume pilote, à traiter avant grande échelle (avec la distinction liste/agrégat ci-dessus).
🟡 `Image.network` non mis en cache (24 fichiers, Prompt 59, inchangé) — coût de bande passante, pas de lectures Firestore.
🟢 GPS, Google Maps, Storage upload, Cloud Functions : tous déjà optimisés ou acceptables au volume pilote.

#### Fichiers modifiés
- `lib/screens/admin/admin_cash_settlement_page.dart`
- `lib/screens/admin/admin_support_page.dart`

#### Résultat build
`flutter analyze` 8 avertissements préexistants (0 nouveau), `npm test` 158/158, `flutter build appbundle --release` ✅ réussi (71,2 Mo).

## 35. Final Security Attack Audit — Master Prompt 80

Audit d'attaque (pas un audit de gap) sur les 6 catégories demandées : construction d'écritures Firestore concrètes qui violeraient les règles réelles, plutôt qu'une relecture des règles en diagonale. **3 failles critiques + 1 élevée trouvées et corrigées, toutes dans `firestore.rules` — des branches vestigiales laissées depuis avant la migration du dispatch côté serveur (Prompt 26), jamais exercées par l'app légitime mais toujours exploitables via une écriture Firestore brute (hors UI).**

### 🔴 CRITIQUE #1 — `deliverOrderCF` pouvait créditer n'importe quel restaurant/pharmacie sans qu'aucun client n'ait payé

La règle `orders` (`create`) ne valide ni `paymentMethod`, ni `sellerId`, ni `sellerType`. Un client pouvait créer `{paymentMethod:'wallet', sellerId:'<n'importe quel partenaire>', sellerType:'restaurant', budget:999999, isPaid:false}`. Dans `functions/orderActions.js:buildDeliverOrder`, la branche de crédit partenaire ne vérifiait que `payMethod==='wallet' && sid`, **jamais `order.isPaid`** — contrairement à la branche sœur sans vendeur. Une fois la commande livrée par n'importe quel livreur (même non complice), le partenaire visé était crédité intégralement, argent créé à partir de rien. **Corrigé** : garde `order.isPaid === true` ajoutée à la branche de crédit partenaire, même schéma que la branche déjà protégée.

### 🔴 CRITIQUE #2 — un livreur pouvait forcer `isPaid:true` par écriture directe, sans jamais appeler `deliverOrderCF`

La transition `picked_up→delivered` de la branche livreur autorisait `unchanged('isPaid') || isPaid==true` — un livreur pouvait donc marquer sa commande "payée" sans validation serveur. Confirmé : aucun code Flutter légitime n'exerce ce chemin (`deliverOrder()` délègue toujours à `deliverOrderCF`). **Corrigé** : `isPaid` ne peut plus être modifié sur cette transition, hérite de `unchanged('isPaid')`.

### 🔴 CRITIQUE #3 — un client pouvait s'auto-assigner n'importe quel livreur, contournant le dispatch

La branche « client auto-assigne le livreur le plus proche » (vestige d'avant la migration serveur du dispatch) protégeait `budget`/`clientId`/`isPaid`/`paymentMethod` mais **pas `driverId`** — un client pouvait écrire n'importe quel `driverId`. Combiné à #1, un attaquant possédant à la fois un compte client ET un compte livreur pouvait compléter seul toute la chaîne de fraude. **Corrigé** : branche supprimée entièrement (aucun appelant légitime confirmé).

### 🔴 ÉLEVÉ #4 — un partenaire pouvait changer le `status` d'une commande vers n'importe quelle valeur

La branche vendeur protégeait 5 champs mais jamais `status` — un partenaire pouvait court-circuiter toute la state machine de livraison. Confirmé : aucun code Flutter légitime ne modifie `status` depuis ce rôle. **Corrigé** : `unchanged('status')` ajouté.

### Reste vérifié sain, aucune nouvelle faille

- **Client** : ne lit pas les données d'autrui, ne peut qu'appauvrir son propre wallet (jamais l'enrichir), ne peut pas s'auto-promouvoir admin.
- **Livreur** : ne peut modifier que son propre document, ne peut pas gonfler son propre wallet, ne peut pas voler une commande assignée à un autre.
- **Ekbine** (`ekbine_orders`) : comparé en détail — nettement mieux scopé que ne l'étaient les branches `orders` (chaque transition source→cible explicite, `completed` exclu de toute écriture directe).
- **Admin/rôles** : séparation super/sous-admin saine. Gap déjà documenté, non repris (Prompt 57) : `permissions` par section non appliqué dans les règles.
- **Storage** : posture par défaut-refus confirmée, type/taille validés partout. `support_screenshots` trop restrictif (admin ne peut pas lire — sens inverse d'une faille), signalé pas corrigé.

### Validation exécutée

`firebase deploy --only firestore:rules --dry-run` compile sans erreur. `npm test` **159/159** (158 + 1 nouveau test de sécurité, 1 test existant corrigé — sa fixture validait par erreur l'ancien comportement fautif). `flutter analyze` inchangé (8 avertissements, aucun fichier Dart touché). `flutter build appbundle --release` ✅ réussi (AAB byte-identique au Prompt 79).

---

### 🎯 ÉTAT SÉCURITÉ PRODUCTION : failles critiques fermées, verdict inchangé sur le reste

Les 4 failles trouvées étaient toutes dans le même mécanisme (`orders` update rule) et auraient permis, en combinaison, de créer de l'argent réel sans paiement — la plus sérieuse trouvaille financière de toute la session, désormais fermée. Le reste de la posture sécurité (Storage, RBAC admin, Ekbine, wallet livreur/client) était déjà solide et le reste.

#### Failles critiques trouvées
🔴 Crédit partenaire sans vérification de paiement (`deliverOrderCF`).
🔴 Flip `isPaid` par écriture directe livreur (`orders` rule).
🔴 Auto-assignation de livreur par le client (`orders` rule).
🟠 Changement de statut arbitraire par un partenaire (`orders` rule).

#### Attaques bloquées
Money-minting via fausse commande wallet ciblant un partenaire complice ou involontaire ; bypass du dispatch serveur par auto-assignation ; bypass de `deliverOrderCF`/`payOrderFromWalletCF` par écriture directe du statut/isPaid ; court-circuit de la state machine de livraison par un partenaire.

#### Corrections
`firestore.rules` (3 branches `orders` corrigées/supprimées), `functions/orderActions.js` (garde `isPaid` sur le crédit partenaire), `functions/test/orderActions.test.js` (+1 test sécurité, 1 corrigé).

#### État sécurité production
Les correctifs sont dans le code local — comme pour tous les correctifs déjà documentés (Sections 18-20/26), ils ne prennent effet en production qu'après déploiement réel des règles/Cloud Functions concernées (`firestore.rules` + `deliverOrderCF`, cette dernière parmi les 23 fonctions toujours non déployées, blocage facturation Cloud Build inchangé). Priorité de déploiement à revoir à la lumière de cette trouvaille : les règles Firestore, elles, peuvent être déployées indépendamment du blocage Cloud Functions (déjà fait pour d'autres correctifs, Section 19-20) — recommandé de le faire dès que possible, puisque cela ferme à lui seul 3 des 4 failles (#1 nécessite aussi le déploiement de `deliverOrderCF`).

## 36. AZ Express Final Release Freeze Audit — Master Prompt 81

Dernier audit avant gel de version, scopé strictement « ne modifier que : bugs bloquants, sécurité, erreurs évidentes », toute nouvelle fonctionnalité/refonte UI/changement d'architecture explicitement interdits. **2 sous-agents dédiés + vérifications directes sur les 5 catégories demandées — verdict : zéro fichier modifié cette passe**, rien trouvé ne franchissant la barre fixée par le prompt lui-même.

### 1) Cohérence version finale — sain

Recherche exhaustive de `TODO`/`FIXME`/`HACK`/`XXX` dans `lib/`/`functions/*.js` : zéro résultat dangereux. Zéro `print()`/`debugPrint()` dans `lib/`. `kDebugMode` utilisé seulement 2 fois (choix du provider App Check), pas de fuite de comportement debug. `functions/*.js` : ~35 `console.log`/`console.error`, tous limités à des IDs/messages d'erreur/tokens tronqués — aucun objet utilisateur complet ni secret journalisé. Aucun écran de test/debug/bypass accessible.

🟡 **Trouvaille mineure, non corrigée** : `lib/constants/app_constants.dart:171` contient la clé Google Maps en toutes lettres, alors que `firebase_options.dart` documente et applique le pattern inverse (`--dart-define`). Pas une faille nouvelle — une clé Maps est structurellement destinée à être embarquée côté client (déjà documenté), le vrai contrôle est côté Google Cloud Console. Migrer vers `--dart-define` ne changerait rien à l'exposition réelle, seulement à la facilité de rotation — signalé pour cohérence, pas corrigé.

### 2) Environnement production — conforme

`.firebaserc` = `az-express-clean` unique. `applicationId`/`namespace` = `com.azexpress.app`. Clé Maps du manifest injectée via `${MAPS_API_KEY}` au build, jamais en dur. Aucun fichier secret tracké par git (confirmé `git ls-files` vide pour chacun). Règles Firestore/Storage compilent sans erreur en dry-run.

### 3) Données sensibles exposées — aucune nouvelle exposition

Audit dédié de la couche UI (au-delà des règles déjà auditées) : téléphone client visible au livreur seulement après acceptation réelle, jamais dans la liste de courses disponibles ; téléphone vendeur Marketplace délibérément public (mécanisme de contact voulu) ; carte des livreurs en ligne suit le pattern standard "à proximité" (position/nom/véhicule, jamais wallet/téléphone) ; aucun écran partenaire ne lit les données d'un autre partenaire.

### 4) Expérience utilisateur finale

Premier lancement : `Firebase.initializeApp()`/App Check/connexion anonyme tous encapsulés en `try/catch`, aucun risque de crash identifié. **Compte suspendu (livreur)** : pas de bannière proactive sur le toggle "En ligne", mais une tentative d'acceptation déclenche bien un message d'erreur clair (pas un crash, pas un blocage silencieux) — gap UX mineur, pas un bug bloquant. **Compte supprimé (client)** : suppression Firestore puis Auth dans le bon ordre, retombe proprement sur le flux "non connecté" au prochain lancement. **Limite documentée, non corrigée** : aucun listener `authStateChanges()` pour détecter en temps réel une suppression/désactivation pendant une session déjà active (jeton valide jusqu'à expiration naturelle) — construire ça serait une nouvelle fonctionnalité, hors périmètre.

### 5) Configuration Play Store — conforme

Label "AZ Express" correct, icônes présentes dans les 5 densités (vraie icône, pas le placeholder Flutter). 16 permissions déclarées, cohérent avec l'audit de durcissement Android déjà fait. Version `1.0.0+1` toujours désynchronisée des tags git — déjà documenté (Prompts 62/63), décision de processus de release, pas un bug.

### Validation exécutée

`firebase deploy --only firestore:rules --dry-run` ✅. `npm test` **159/159** (aucun fichier `functions/` touché). `flutter analyze` inchangé (8 avertissements préexistants, 0 nouveau). `flutter build appbundle --release` ✅ réussi — AAB byte-identique au Prompt 80 (71,2 Mo), confirmant qu'aucun code n'a changé.

---

### 🎯 GO / NO GO RELEASE : **GO** (pour un pilote supervisé — le blocage de déploiement Cloud Functions reste la seule vraie réserve)

Le code applicatif est propre à ce stade : aucun bug bloquant, aucune faille de sécurité active, aucune donnée sensible exposée au-delà de ce qui est déjà connu et accepté, aucun écran de test accessible, configuration Android/Firebase/Play Store cohérente. Le gel de version peut être déclaré côté code.

#### Derniers blocages
🔴 **Le seul vrai blocage reste externe au code, déjà documenté** : facturation Cloud Build/GCP toujours bloquée (HTTP 403) — 23 Cloud Functions non déployées, dont tous les correctifs financiers critiques (Sections 18-20/26) et le correctif de sécurité #1 du Prompt 80 (`deliverOrderCF`). Sans déblocage, `dispatchOrderToDriver` n'étant pas déployée, aucune commande de livraison réelle n'aboutit — confirmé concrètement au Prompt 71.
🟡 Règles Firestore (correctifs de sécurité du Prompt 80) prêtes à déployer indépendamment du blocage Cloud Build — recommandé en priorité absolue avant tout lancement terrain, ferme 3 des 4 failles à elles seules.
🟡 Version applicative (`1.0.0+1`) non synchronisée avec les tags git (`v0.3-rc3`) — décision de processus à trancher avant publication Play Store.
🟡 Clé Google Maps codée en dur (pas une faille, juste une incohérence de convention) — cohérence de rotation à améliorer si voulu, non bloquant.

#### Fichiers modifiés
Aucun — audit-only, rien ne franchissait la barre "bug bloquant/sécurité/erreur évidente".

#### État final AZ Express
Code applicatif **prêt pour le gel de version**. Le déploiement production reste conditionné au déblocage de la facturation Cloud Build (action Google Cloud Console, hors du code) — une fois débloqué : déployer `firestore.rules` en priorité (ferme 3/4 failles sécurité immédiatement), puis les Cloud Functions par lots déjà planifiés (Sections 18-20), suivre le plan de seed et les checklists de lancement déjà livrés (Prompts 72-78). Le projet a traversé 81 passes d'audit cumulées cette session — 11 bugs financiers critiques et 4 failles de sécurité critiques/élevées trouvés et corrigés dans le code, zéro laissé en suspens dans une catégorie "bug bloquant" à ce jour.

## 37. AZ Express Production Go-Live Checklist Abengourou — Master Prompt 82

Code freeze explicite (« ne plus modifier le code sauf bug bloquant »), objectif de préparation du lancement terrain réel. **Zéro fichier modifié** — la majorité de ce prompt (formation livreurs, procédure argent, canal support, captures d'écran Play Store, simulation Jour J) est opérationnelle/business, hors de portée de cet environnement. Ce qui était vérifiable a été testé réellement plutôt que supposé.

### 1) Google Cloud final

- **Facturation Cloud Build toujours bloquée — retesté réellement, pas supposé.** `firebase functions:list` : 30/53 fonctions, aucune des critiques (`dispatchOrderToDriver`/`deliverOrderCF`/`cancelOrderCF`/`payOrderFromWalletCF`/`azIaChat`) présente. Nouvel essai réel de déploiement (Lot 1, 6 fonctions à faible risque) : échec identique (`HTTP 403, billing account`). Arrêté immédiatement, zéro dégât (toujours 30 fonctions après coup).
- `firestore.rules`/`storage.rules` : correctifs de sécurité du Prompt 80 confirmés présents. 37 index toujours déclarés. Dry-run compile sans erreur.

### 2) Firestore données initiales

- Zones : 4 des 9 zones demandées (**Commerce, Cafétou, Plateau, Château**) déjà dans le seed pré-rempli de `admin_zones_page.dart` ; les 5 autres (**Agnikro, Dioulakro, Indénié 2000, Aviation, Nouveau Quartier**) à ajouter manuellement via le formulaire "+" existant.
- Aucun script de seed livreurs/clients/partenaires dans le dépôt — création à faire via l'app (flux déjà audités et fonctionnels) ou un script Admin SDK dédié, non construit ici (nécessite des données réelles : noms, téléphones, adresses).

### 3-6) Simulation Jour J, organisation livreurs, procédure argent, support

Hors de portée de cet environnement (pas d'accès device/émulateur, pas de données business réelles comme les numéros WhatsApp/téléphone AZ Express) — livrés comme checklist actionnable dans le rapport final, pas exécutés.

### 7) Play Store

- **Bonne nouvelle, changement externe détecté** : Flutter est passé du canal `beta` (risque signalé au Prompt 63) au canal **stable** (`3.44.5`) — risque fermé sans action de cette session.
- Licences Android SDK toujours "unknown" sur cette machine — problème d'environnement local déjà documenté (symboles de debug non retirés), pas un défaut du code.
- **Firebase Hosting confirmé réellement live** (jamais vérifié aussi directement avant) : `https://az-express-clean.web.app/confidentialite` et `/delete-account` répondent **200 OK** avec le vrai contenu de l'app — utilisables tels quels dans le formulaire Play Console.
- `flutter build appbundle --release` re-testé sur le nouveau canal stable — réussit à l'identique (AAB byte-identique, 71,2 Mo).
- Screenshots/description Play Store : pas préparés, action business restante.

### Validation exécutée

`firebase functions:list` (lecture seule) + nouvel essai réel de déploiement Lot 1 (échec confirmé, zéro dégât). `firebase deploy --only firestore:rules --dry-run` ✅. Hosting vérifié live par requêtes HTTP réelles. `flutter build appbundle --release` ✅ réussi sur canal stable.

---

### 🎯 GO / NO GO LANCEMENT ABENGOUROU : **NO GO tant que la facturation Cloud Build n'est pas débloquée** — tout le reste est prêt côté code

#### Fonctions déployées
❌ Non — 30/53, blocage confirmé à nouveau par un vrai essai de déploiement cette passe.

#### Données prêtes
🟡 Partiellement — 4/9 zones pré-remplies, le reste (zones restantes + comptes livreurs/clients/partenaires réels) doit être créé manuellement via l'app une fois le pilote lancé, pas de blocage technique.

#### Partenaires prêts
🟡 Flux d'inscription/approbation restaurant/pharmacie/boutique/marketplace tous audités et fonctionnels (Prompts 73-74) — mais aucun compte réel n'existe encore, à créer.

#### Risques restants
🔴 Blocage facturation Cloud Build (le seul vrai blocage technique).
🟡 Pas de données de seed réelles (zones/comptes) créées.
🟡 Simulation Jour J réelle jamais exécutée sur device (hors de portée de cet environnement).
🟡 Canal support (WhatsApp/téléphone) et assets Play Store (captures/description) pas préparés.

#### Date de lancement pilote possible
Dès que la facturation Cloud Build est débloquée + `firestore.rules` déployées + Lots 2-3 de Cloud Functions déployés + zones/comptes réels créés + une simulation Jour J réelle sur device confirmée — aucune de ces étapes n'a de dépendance technique bloquante restante côté code, le calendrier dépend désormais entièrement d'actions externes au code (Google Cloud Console, création de comptes réels, préparation Play Store).

## 38. Production Activation Plan — Master Prompt 83

Plan d'activation exact pour l'après-déblocage Google Billing, demandé en code freeze strict (« ne modifier aucun code, ne créer aucune fonctionnalité, ne refactoriser aucun fichier »). Section 1 (« avant déblocage ») explicitement « ne rien déployer » — toutes les commandes ci-dessous sont un **plan écrit**, pas des actions exécutées cette passe (aucun déploiement de Cloud Function tenté, contrairement aux Prompts 66/67/82).

### 1) État actuel — vérifié en lecture seule, diff exact calculé

`firebase functions:list` (30 fonctions) diffé programmatiquement contre les 53 exports réels de `functions/index.js` — **23 fonctions manquantes, liste exacte, pas une estimation** :

| Lot | Fonctions manquantes | Risque |
|---|---|---|
| **Lot 1 — système, faible risque (6)** | `fcmTokenCleanupCheck`, `logAdminAuditEvent`, `logAuthEvent`, `pharmacieLogin`, `setPharmaciePassword`, `walletReconciliationCheck` | Faible — déjà le lot testé 3 fois (Prompts 66/67/82), aucune n'engage de fonds |
| **Lot 2 — dispatch (1)** | `dispatchOrderToDriver` | Moyen — sans elle, aucune commande de livraison n'est jamais assignée (confirmé Prompt 71) |
| **Lot 3 — argent (6)** | `deliverOrderCF`, `cancelOrderCF`, `payOrderFromWalletCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF` | Élevé — mouvements de fonds réels, inclut le correctif de sécurité du Prompt 80 |
| **Lot 4 — reste des modules (10)** | AZ IA (4) : `aiCleanupExpiredPendingActions`, `aiConfirmAction`, `azIaChat`, `clearAiHistory` — Immobilier (6) : `approveRealEstateAgentRequest`, `notifyAgentOnVisitRequest`, `notifyClientOnVisitUpdate`, `requestPropertyVisit`, `respondToVisitRequest`, `submitRealEstateAgentRequest` | Faible — modules non critiques au lancement livraison/wallet |

**Checklist pré-déploiement** (tout confirmé prêt, lecture seule, rien déployé cette passe) :
- ✅ `firestore.rules` — correctifs de sécurité du Prompt 80 confirmés présents, `firebase deploy --only firestore:rules,storage --dry-run` compile sans erreur (retesté cette passe).
- ✅ `storage.rules` — compile sans erreur, posture par défaut-refus confirmée (Prompt 80/81).
- ✅ 37 index Firestore (`firestore.indexes.json`) — déjà déployés (Prompt 67), inchangés.
- ✅ Firebase Hosting — confirmé live par requêtes HTTP réelles (Prompt 82), `/confidentialite` et `/delete-account` répondent 200.
- ✅ Suite de tests `functions/` — 159/159, inchangée depuis le Prompt 80.
- ❌ Cloud Build/facturation GCP — toujours bloquée (dernier essai réel au Prompt 82, `HTTP 403`) ; pas re-testé cette passe (section 1 du prompt demande explicitement de ne rien déployer).

### 2) Ordre exact après déblocage — commandes prêtes à copier-coller

**Étape 1 — sécurité, en premier, indépendamment des Cloud Functions :**
```
firebase deploy --only firestore:rules --project az-express-clean
```
Vérifier le succès (`+ cloud.firestore: rules file compiled and released successfully` dans la sortie), puis confirmer dans la Console Firebase que la date de dernière publication des règles a bien changé.

**Étape 2 — Cloud Functions par lots, avec vérification entre chaque lot :**
```
# Lot 1 — système (faible risque)
firebase deploy --only functions:fcmTokenCleanupCheck,functions:logAdminAuditEvent,functions:logAuthEvent,functions:pharmacieLogin,functions:setPharmaciePassword,functions:walletReconciliationCheck --project az-express-clean

# Lot 2 — dispatch
firebase deploy --only functions:dispatchOrderToDriver --project az-express-clean

# Lot 3 — argent (le plus sensible — vérifier le Lot 2 en conditions réelles avant de lancer celui-ci)
firebase deploy --only functions:deliverOrderCF,functions:cancelOrderCF,functions:payOrderFromWalletCF,functions:payBoutiqueOrderCF,functions:payBoutiqueOrderCashCF,functions:refundExpiredBoutiqueOrderCF --project az-express-clean

# Lot 4 — reste des modules (AZ IA + Immobilier)
firebase deploy --only functions:aiCleanupExpiredPendingActions,functions:aiConfirmAction,functions:azIaChat,functions:clearAiHistory,functions:approveRealEstateAgentRequest,functions:notifyAgentOnVisitRequest,functions:notifyClientOnVisitUpdate,functions:requestPropertyVisit,functions:respondToVisitRequest,functions:submitRealEstateAgentRequest --project az-express-clean
```

**Après chaque lot** : `firebase functions:list --project az-express-clean` (confirmer le nouveau total), puis consulter les logs (`firebase functions:log --project az-express-clean` ou Console Cloud Logging) pendant quelques minutes pour repérer une erreur de démarrage à froid, avant de passer au lot suivant. Ne jamais lancer le Lot 3 avant d'avoir confirmé le Lot 2 stable — c'est le lot qui déplace de l'argent réel pour la première fois en production.

### 3) Validation technique finale — checklist post-déploiement complet

- `firebase functions:list --project az-express-clean` → objectif **53/53**.
- Test client : créer une vraie commande de livraison (montant minimal, ex. 500 FCFA) depuis un compte de test.
- Test livreur : confirmer la réception de la notification, l'acceptation, le trajet GPS/Maps, la livraison marquée terminée.
- Test paiement cash : une commande réglée en espèces, confirmer que la commande passe bien à `delivered` et que `merchantCashSettled` apparaît si un marchand est concerné.
- Test paiement wallet : une commande réglée par wallet, confirmer le débit client + le crédit correct du livreur/partenaire (exactement le chemin sécurisé par le correctif du Prompt 80 — **premier test réel en conditions de production de ce correctif**, à ne pas sauter).
- Test admin : `admin_orders.dart` (suivi), `admin_support_page.dart` (support), `admin_cash_settlement_page.dart` (cash marchand) — confirmer que les 3 écrans reflètent bien les données de la commande de test.

### 4) Préparation terrain Abengourou — déjà détaillé au Prompt 82, référencé ici pour ne pas dupliquer

Zones (4/9 déjà pré-remplies dans `admin_zones_page.dart` : Commerce/Cafétou/Plateau/Château — 5 restantes à ajouter manuellement : Agnikro/Dioulakro/Indénié 2000/Aviation/Nouveau Quartier), 5 comptes livreurs minimum + partenaires (restaurant/pharmacie/boutique/marketplace) à créer via les flux d'inscription déjà audités et fonctionnels, canal support WhatsApp/téléphone à définir (numéros réels non fournis à ce jour) — voir Section 37 pour le détail complet, non re-décrit ici.

### 5) Play Store — état des lieux, rien de nouveau à corriger côté code

Prêt : `firestore.rules`/permissions déjà auditées (Sections 22-23), URL politique de confidentialité et suppression de compte déjà live (Section 37, `/confidentialite` et `/delete-account`, 200 OK confirmés). Restant, purement business/marketing, aucune dépendance code : captures d'écran, texte de description, choix de catégorie Play Store, déclaration d'usage de la localisation dans le formulaire Data Safety (contenu déjà préparé/documenté Prompts 63/68/69, jamais soumis dans la console elle-même).

---

### 🎯 STATUT ACTUEL : code et infrastructure prêts, un seul déploiement en attente d'un débloquage externe

#### Commandes exactes à lancer après déblocage billing
Voir Section 38.2 ci-dessus — 1 commande de règles + 4 commandes de fonctions par lot, dans cet ordre précis, avec vérification des logs entre chaque lot.

#### Ordre de lancement
Règles Firestore → Lot 1 (système) → Lot 2 (dispatch) → validation Lot 2 en conditions réelles → Lot 3 (argent) → Lot 4 (IA/Immobilier) → validation technique finale complète (Section 38.3) → seed des données Abengourou (Section 38.4) → simulation Jour J réelle sur device → ouverture support → publication Play Store.

#### Risques restants
🔴 Facturation Cloud Build toujours bloquée — seule vraie dépendance technique.
🟡 Le Lot 3 n'a jamais été testé en conditions réelles de production (seulement en tests unitaires, 159/159) — la validation technique de la Section 38.3 sur le paiement wallet est la première vérification en conditions réelles du correctif de sécurité du Prompt 80, à ne pas sauter le jour du déploiement.
🟡 Données terrain (zones/comptes/partenaires) et canal support toujours à créer avec de vraies informations métier.
🟡 Assets Play Store (captures, description) toujours à préparer.

#### GO LIVE — checklist finale
- [ ] Facturation Cloud Build débloquée (Google Cloud Console)
- [ ] `firestore.rules` déployées, succès confirmé
- [ ] Lot 1 déployé, logs propres
- [ ] Lot 2 déployé, logs propres, une vraie commande testée bout en bout
- [ ] Lot 3 déployé, logs propres, paiement cash ET wallet testés bout en bout
- [ ] Lot 4 déployé
- [ ] `firebase functions:list` confirme 53/53
- [ ] 9 zones Abengourou actives
- [ ] 5 comptes livreurs validés minimum
- [ ] Au moins 1 restaurant + 1 pharmacie + 1 boutique + des vendeurs marketplace actifs
- [ ] Canal support WhatsApp/téléphone communiqué
- [ ] Play Store : captures, description, catégorie, Data Safety soumis

## 39. Operations Runbook & Post-Launch Monitoring — Master Prompt 84

Code freeze, « audit documentation/process uniquement ». **Nouveau document créé : [`OPERATIONS_RUNBOOK.md`](../OPERATIONS_RUNBOOK.md)** (racine du dépôt) — manuel d'exploitation quotidienne pour l'admin/opérateur post-lancement Abengourou, public distinct de ce fichier (historique d'audit) et de `CLAUDE.md` (doc technique développeur).

Contenu du manuel (référence rapide, détail complet dans le fichier lui-même) :
1. **Journée type admin** — routine matin/journée/soir, chaque vérification pointée vers l'écran admin exact qui l'outille déjà (`admin_orders.dart`, `admin_cash_settlement_page.dart`, `admin_live_tracking_page.dart`, `admin_support_page.dart`, `drivers_page.dart`, écrans de demande partenaire).
2. **Surveillance technique** — Firebase Console (Functions Logs/Crashlytics/Firestore/Storage/Auth) et Google Cloud Console (Maps), avec les fréquences exactes des schedulers automatiques vérifiées dans le code (`walletReconciliationCheck` lundi 4h, `fcmTokenCleanupCheck` lundi 5h, `cleanupExpiredRateLimits` lundi 3h, `autoExpireOrders` chaque minute).
3. **Procédures incidents** par rôle (client/livreur/partenaire) — chaque case indique soit la procédure réelle avec l'écran concerné, soit explicitement « pas d'outil dédié, procédure manuelle » là où rien n'existe (ex. réassignation automatique de commande bloquée, remboursement partiel).
4. **Argent & fin de journée** — clôture quotidienne détaillée, avec la distinction exacte entre le contrôle quotidien (cash effectivement remis) et la réconciliation automatique hebdomadaire (`wallet_reconciliation_findings`, lundi 4h).
5. **Sécurité post-lancement** — signal exact à chercher si le type de fraude fermé au Prompt 80 était tenté malgré tout : une commande `delivered` sans crédit partenaire (`walletTarget:'partner_unpaid'` dans les logs de `deliverOrderCF`).
6. **Seuils de croissance** (5→20 livreurs, 50→500 commandes/jour) — construits à partir des limites déjà identifiées par audit dédié cette session (agrégation client-side non bornée `admin_earnings.dart`/`admin_drivers_ranking.dart`, Prompt 79 ; absence de sauvegarde Firestore planifiée, Prompt 61/65 ; absence de `minInstances`, Prompt 37), pas des seuils inventés.

**Zéro fichier de code modifié — un seul fichier créé, de la documentation pure.**
