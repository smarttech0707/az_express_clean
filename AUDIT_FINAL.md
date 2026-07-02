# AZ Express — Audit final avant mise en production

**Date** : 2026-07-02 (mise à jour — version initiale datée 2026-07-01)
**Périmètre** : synthèse des audits réalisés au fil des Master Prompts 01→39 (chacun grounded dans le code réel, jamais dans une supposition) + des jalons AZ IA M0→M7 livrés, plus une tranche ciblée de M8 (contrôle utilisateur sur l'historique de conversation). Ce document ne réintroduit pas de nouvelles recherches — il compile ce qui a déjà été vérifié et documenté dans `CLAUDE.md`, section par section, en un rapport priorisé.

**Ce que ce document n'est pas** : un audit de sécurité professionnel externe, un test de charge réel, ou une revue juridique/conformité. C'est une synthèse honnête de l'état du code tel qu'observé par un agent IA au cours de cette session — utile pour prioriser, pas pour remplacer une revue humaine avant un vrai lancement à grande échelle.

**Ce qui a changé depuis la version du 2026-07-01** : cette mise à jour couvre 20 prompts supplémentaires (21→39), dont plusieurs ont abouti à des corrections réelles sur du code déjà en production — pas seulement de nouvelles trouvailles documentées. Le changement le plus important : **trois bugs de paiement wallet réels ont été trouvés et corrigés** (paiement/annulation/livraison wallet, puis le module Boutique), tous dans la même famille — des écritures Firestore cross-user lancées directement par le client Flutter, systématiquement rejetées par les règles de sécurité déjà en place, provoquant des échecs de paiement silencieux en production. Aucun de ces bugs n'était connu au moment de la version précédente.

---

## 1. Résumé exécutif

AZ Express est un super-app ivoirien fonctionnellement large (livraison, courses, marketplace, immobilier, restaurants, pharmacies, wallet, Ekbine, AZ IA) avec une base technique **plus mature que ce qu'un audit superficiel suggérerait** : dispatch désormais entièrement côté serveur avec verrouillage transactionnel, wallet transactionnellement propre et append-only avec un moteur de conciliation actif, 2FA admin conditionnelle (vrai Firebase Phone Auth), permissions admin déjà granulaires par section, géo-analytics déjà construites, notification center déjà riche, service de routage Google Maps déjà bien conçu (cache, repli, ETA temps réel), AZ IA désormais vocale (M7) avec contrôle utilisateur sur son historique.

Mais le projet n'est **toujours pas prêt pour une mise en production à grande croissance non supervisée** :
- **Trois bugs de paiement wallet réels ont été trouvés et corrigés cette session** (voir ci-dessus) — la découverte la plus significative depuis la version précédente de ce document, qui ne les connaissait pas.
- Un risque de confiance côté client existe toujours sur la tarification livraison (prix calculé et non validé côté serveur) — inchangé depuis le 01/07.
- La suite de tests est passée de 44 à **104 tests**, mais reste concentrée sur le code touché cette session (paiements, dispatch, identité, wallet, IA) — le reste de l'app (Ekbine, Marketplace legacy, écrans admin) reste sans couverture automatisée.
- Aucune CI ne s'exécute réellement aujourd'hui (le remote GitHub n'existe toujours pas) ; **zéro commit git n'a été fait durant toute la session** (40 prompts) — tout ce travail reste non versionné.
- App Check n'est toujours pas activé — le risque sécurité générique le plus concret restant.
- Deux systèmes "immobilier" parallèles coexistent toujours sans être réconciliés (inchangé).
- **Nouvelle découverte structurelle** : deux back-offices web/mobile déconnectés coexistent (admin mobile riche vs. dashboard web très réduit, 5 onglets), jamais réunifiés.
- **Nouvelle découverte** : le champ `wallet` de `livreurs` reste lisible par tout utilisateur authentifié — la justification historique (dispatch client-side) a disparu cette session, mais la règle elle-même n'a pas été resserrée (décision explicite de reporter ce chantier).
- **Nouvelle découverte** : les fichiers Cloud Storage (photos, selfies, images produit) ne sont quasiment jamais supprimés, même après remplacement ou suppression du document associé — un poste de coût qui grossit silencieusement.

Le produit peut fonctionner en production limitée/pilote dès maintenant sous supervision humaine active — c'est même un cran plus solide qu'au 01/07, puisque les trois bugs de paiement les plus consommateurs de confiance utilisateur sont désormais corrigés. Une croissance forte et non supervisée devrait toujours attendre le traitement des points Élevés ci-dessous.

---

## 2. État général du projet

| Dimension | État (2026-07-02) | Évolution depuis le 01/07 |
|---|---|---|
| Fonctionnalités métier | Larges et globalement fonctionnelles | Inchangé, déjà solide |
| Paiements wallet | 3 bugs réels trouvés et corrigés (paiement/annulation/livraison, Boutique) | **Corrigé** — n'était pas su au 01/07 |
| Dispatch | Entièrement côté serveur, verrouillage transactionnel | **Migré + sécurisé** cette session |
| Wallet — conciliation | Moteur de conciliation hebdomadaire actif | **Construit** cette session |
| AZ IA | 15 outils, voix (M7) livrée, contrôle utilisateur sur l'historique (tranche M8), observabilité IA | **Étendu** — voix + mémoire + observabilité ajoutées |
| Sécurité | 3 bugs financiers corrigés ; App Check toujours absent ; `livreurs.wallet` toujours lisible largement | Progrès réel + gaps connus persistants |
| Tests | 44 → **104 tests**, toujours concentrés sur le code neuf/touché | Doublé, toujours partiel |
| CI/CD | Toujours inactif (pas de remote GitHub), **zéro commit cette session** | Inchangé |
| Documentation | `CLAUDE.md` (~500+ lignes, ~40 sections) documentation technique vivante à jour | Étendu en continu |
| Architecture | Cohérence globale maintenue ; nouvelle dette identifiée (deux back-offices) | Dette connue, pas résolue, un nouvel élément trouvé |

---

## 3. Architecture

**Points forts** : séparation Flutter/Cloud Functions/Firestore respectée pour tout le code écrit cette session (paiements, dispatch, identité, wallet, notifications, IA) ; pattern de fabrique testable généralisé (`orderActions.js`, `authEvents.js`, `walletReconciliation.js`, `fcmTokenCleanup.js` suivent tous le même schéma que `pendingActions.js`) ; 45+ Cloud Functions déjà organisées de façon incrémentale (fichiers séparés pour la logique testable, `index.js` comme manifeste) sans qu'une réorganisation complète en dossiers n'ait été nécessaire.

**Points faibles connus, documentés, et pour la plupart toujours ouverts** :
- Écritures Firestore directes depuis le client pour une partie des flux hérités (`acceptOrder`, `rechargeDriverWallet`, admin) — légitimes sous les règles actuelles, mais pas des Cloud Functions ; la cible (tout passer par CF) n'est toujours pas atteinte partout.
- Pas d'enveloppe de réponse API unifiée entre les Cloud Functions historiques — accepté comme dette non retrofit-able, politique déjà actée (nouvelles fonctions seulement).
- Deux services de tarification livraison coexistent toujours (`tarif_service.dart` actif, `delivery_service.dart` probablement mort).
- **Nouveau** : deux implémentations de back-office coexistent, construites indépendamment (voir section 8, Administration).
- Refus délibérés et documentés de reconstructions demandées par plusieurs prompts (API Gateway, réorganisation Cloud Functions en dossiers, Ledger comptable en partie double, pipeline IA en 9 couches) — dans chaque cas, l'architecture existante s'est révélée déjà adaptée ou la reconstruction aurait été disproportionnée/risquée pour des données réelles.

**Risque** : Moyen. Rien de bloquant, la dette est connue et contenue, mais elle grossira si laissée sans arbitrage (notamment les deux back-offices, qui divergeront davantage à chaque nouvelle fonctionnalité admin ajoutée d'un seul côté).

---

## 4. Sécurité (classée par criticité)

### Critique — trouvées ET corrigées cette session

- **Mot de passe pharmacie en clair** (`pharmacies/{id}.password`) — corrigé le 01/07 (Prompt 12) : hachage scrypt côté serveur, migration paresseuse, règles verrouillées.
- **Paiement wallet livraison cassé silencieusement** — `payOrderFromWallet()`/`cancelOrder()`/`deliverOrder()` tentaient de créditer le wallet d'un autre utilisateur (livreur/partenaire) depuis une transaction Firestore lancée par le client. La règle de sécurité (déjà stricte, correctement conçue) rejetait systématiquement ces écritures — donc **le paiement wallet d'une livraison, son annulation avec remboursement de commission, et la livraison directe payée en wallet ne fonctionnaient pas en production**, indépendamment de tout changement de cette session. Corrigé : portées en Cloud Functions (`payOrderFromWalletCF`/`cancelOrderCF`/`deliverOrderCF`), 18 tests.
- **Paiement wallet Boutique cassé silencieusement, même famille** — `creditSellerWallet()` échouait pour la même raison exacte (règle `sellers/{id}` encore plus stricte). Le client était débité, la commande créée, puis l'échec du crédit vendeur remontait une erreur générique — argent déjà débité, vendeur jamais payé, course de livraison jamais créée. Corrigé : `payBoutiqueOrderCF`, 7 tests.

**Interprétation** : ces trois bugs ne sont pas des vulnérabilités au sens classique (personne ne pouvait voler d'argent) — ce sont des **règles de sécurité correctement strictes qui bloquaient, par effet de bord, des flux métier légitimes**. C'est un signal positif sur la rigueur des règles Firestore déjà en place, et un signal négatif sur l'absence de tests d'intégration qui auraient détecté ces échecs avant la production.

### Élevée — toujours ouvertes

- **App Check absent** — inchangé depuis le 01/07, toujours le risque sécurité générique le plus concret.
- **Tarification livraison non validée côté serveur** — inchangé.
- **`livreurs/{id}.wallet` reste lisible par tout utilisateur authentifié** — la justification historique (le dispatch client-side devait lire le wallet de tous les livreurs en ligne) a disparu cette session (dispatch migré côté serveur), mais la règle n'a pas été resserrée : le restreindre correctement nécessiterait de migrer ~10 sites de lecture/écriture restants (écrans livreur légitimes, 3 écrans admin, dashboard patron de flotte) — décision explicite de reporter, risque résiduel = visibilité de solde, pas sécurité des fonds (les écritures cross-user restent bloquées par la règle).
- **Deux systèmes Immobilier parallèles non réconciliés** — inchangé, `locations` vs `real_estate_listings`.
- **Deux back-offices non unifiés** (nouveau, voir section 8) — pas un risque sécurité en soi, mais une surface d'incohérence RBAC potentielle si les deux évoluent séparément sans les mêmes contrôles de permission.

### Moyenne

- **Compte livreur de flotte : création probablement cassée sur iOS/Android** — `fleet_dashboard.dart` connecte l'app en tant que nouveau compte livreur (via `createUserWithEmailAndPassword`) puis tente d'écrire son propre document, mais la règle `allow create` n'autorise que les admins — semble échouer systématiquement en production. Trouvé, pas corrigé (hors périmètre de la session qui l'a découvert).
- **Code mort dans le mécanisme 2FA admin** — `AuthService.generateAdminOtp`/`verifyAdminOtp` n'ont jamais fonctionné (aucun appelant), coexistant avec le vrai mécanisme (Firebase Phone Auth réel) sans que quiconque ne s'en aperçoive avant cette session. Pas un risque actif (le vrai mécanisme fonctionne), mais un piège pour un futur développeur.
- **`service_providers` (artisans) a la même faiblesse architecturale que l'ancien problème pharmacie** — connexion via `signInAnonymously()`, bloquant `isRealUser()` ; jamais corrigé (identifié Prompt 21).
- Vocabulaire de statut de transaction toujours fragmenté (5+ systèmes incohérents).
- Pas de suspension de compte client pour fraude.
- `fakeOrderCount` détecte l'abus COD mais ne remonte aucune alerte admin.
- **Fichiers Cloud Storage jamais nettoyés** (nouveau, section 9) — pas un risque de sécurité au sens strict, mais un risque de coût qui grossit silencieusement et sans limite naturelle.

### Faible

- Pas de gestion de sessions actives / déconnexion à distance, pas de multi-appareil pour les notifications push (un seul `fcmToken` par compte).
- Pas de MFA au-delà du SMS admin conditionnel.
- CI écrite mais non active (toujours pas de remote GitHub) ; zéro commit git effectué cette session — aucun historique de déploiement possible tant que rien n'est committé.

### Corrections de sécurité/robustesse additionnelles livrées cette session (au-delà des 3 bugs critiques)

- `audit_logs` restreint à la lecture super-admin uniquement (était accessible à tout admin).
- Verrouillage transactionnel du dispatch (fenêtre de course fermée, sans changement de comportement observable).
- Boucle de nettoyage des tokens FCM invalides fermée (détection existait déjà, rien ne la consommait avant).
- Événements d'identité (connexion/déconnexion/changement de permission) désormais journalisés dans `audit_logs`, câblés sur 18 écrans réels.
- 12 726 fichiers `functions/node_modules` déjà suivis par erreur dans git — nettoyés (`.gitignore` corrigé, fichiers untracked).

---

## 5. Performances

**Points forts vérifiés** : GPS livreur déjà bien optimisé (throttle double 5s/15m) ; `cached_network_image` largement adopté ; prompt caching Anthropic appliqué ; persistance Firestore offline activée ; **`GoogleRoutesService` confirmé bien conçu** (Directions API réelle, ETA avec trafic, cache par grille 100m/5min, repli en ligne droite propre, throttle de recalcul à 120s déjà optimisé suite à un incident de coût passé) ; **squelette de chargement (shimmer) déjà construit** (`glass_kit.dart`), pas juste des spinners partout.

**Points faibles** :
- Pagination toujours incohérente — un seul écran a une vraie pagination par curseur.
- Toujours pas de Firebase Performance Monitoring.
- Analytics géographiques toujours recalculées côté client à chaque ouverture d'écran (pas pré-agrégées).
- FCFA toujours codé en dur partout.
- **Nouveau** : le dispatch trie toujours les candidats par distance à vol d'oiseau (choix de coût assumé, pas un oubli — appeler Directions par candidat multiplierait le coût), donc la précision routière ne s'applique qu'au suivi post-attribution, pas à la sélection elle-même.
- **Nouveau** : `Firebase Analytics` instancié mais totalement inutilisé (zéro événement suivi, pas même le tracking d'écran automatique).
- **Nouveau** : aucune configuration `minInstances`/`concurrency` sur les Cloud Functions — cohérent avec l'échelle actuelle (pilote mono-ville), pas un problème aujourd'hui.

**Risque** : Moyen, inchangé dans sa nature — rien ne dégrade l'expérience à l'échelle actuelle, mais plusieurs points (pagination, pré-agrégation, Storage non nettoyé) deviendront des frictions réelles à mesure que le volume grossit.

---

## 6. Qualité du code

Le code écrit cette session suit une discipline cohérente et **vérifiablement appliquée**, pas seulement affirmée : chaque nouvelle Cloud Function critique (paiements, dispatch, identité, wallet, notifications, mémoire IA) a reçu son propre fichier de test — 6 des 10 fichiers de test actuels ont été créés durant cette session, chacun directement lié à une fonction ajoutée. Réutilisation systématique des helpers existants (`checkRateLimit`, `logAudit`), `flutter analyze` vérifié sans régression après chaque changement, code mort supprimé dès qu'identifié comme conséquence directe d'un correctif (`_logCommission`, `_partnerCollection`, `ETAService`, `creditSellerWallet`).

**Dette explicitement documentée, pas cachée** : adoption inégale des tokens `AppLayout`/`AppTypography`, deux services de tarification, deux systèmes immobilier parallèles, deux back-offices, vocabulaire de statut wallet fragmenté.

---

## 7. Documentation

`CLAUDE.md` est passé de 313 lignes/25 sections (01/07) à un document nettement plus étoffé couvrant l'intégralité des 39 prompts de cette session — toujours la documentation technique vivante de référence, mise à jour section par section à chaque nouvelle trouvaille. `FIRESTORE_SCHEMA.md` et `FIRESTORE_RULES.md` s'y sont ajoutés entre-temps comme références dédiées.

**Manque toujours** : documentation par endpoint pour les Cloud Functions individuelles, changelog structuré, guides de formation par rôle, procédures de publication Android/iOS, schémas visuels.

---

## 8. Audit par module

### Livraison
- **Forces** : dispatch désormais entièrement côté serveur avec verrouillage transactionnel (fenêtre de double-attribution fermée) ; GPS bien optimisé ; remboursement wallet conditionné au statut, et désormais fiable (bug de paiement corrigé).
- **Faiblesses** : tarification toujours client-side (risque sécurité inchangé) ; score de dispatch toujours distance-only (12 critères théoriques, 2 réels — pas de note, pas de taux d'acceptation, pas de zone autorisée) ; recherche progressive partiellement orchestrée côté client (les timers vivent dans l'écran de suivi, pas sur le serveur) ; `driver_rankings` toujours un schéma mort.
- **Risque** : Élevé (tarification), Moyen pour le reste — le paiement lui-même n'est plus un risque (corrigé).

### Wallet & Finance
- **Forces** : transactions append-only, **3 bugs de paiement réels corrigés cette session**, **moteur de conciliation hebdomadaire actif** (compare `wallet` et `wallet_transactions`, signale les écarts sans jamais toucher à l'argent), comportement déjà cohérent en partie double dans les faits (chaque CF de paiement débite et crédite dans la même transaction).
- **Faiblesses** : refus justifié de reconstruire en Ledger comptable formel (risque disproportionné sur des soldes réels) ; vocabulaire de statut toujours fragmenté ; remboursement toujours total, jamais partiel ; transferts wallet-à-wallet inexistants ; plusieurs paiements admin restent des écritures client directes (légitimes sous les règles actuelles, pas des Cloud Functions).
- **Risque** : passé de Élevé à Moyen — la découverte et la correction des 3 bugs de paiement est le progrès le plus concret de cette mise à jour.

### AZ IA
- **Forces** : architecture déjà saine à la conception (jamais d'accès direct à Firestore, confirmation server-side systématique), 15 outils fonctionnels, **voix livrée (M7)** — reconnaissance + synthèse vocale sur le contrat texte existant, sans changement serveur, réutilisant un composant déjà éprouvé en production ailleurs dans l'app ; **contrôle utilisateur sur l'historique de conversation livré** (suppression à la demande) ; **observabilité IA construite** (outils utilisés, tours, tokens, durée par conversation).
- **Faiblesses** : pas de contexte ambiant (écran actuel, localisation, préférences) transmis au modèle ; mémoire utilisateur/préférences (M8 complet) toujours non construite ; pas de barge-in vocal réel ; pas de multi-langue des réponses (system prompt français en dur) ; aucun outil d'administration IA (refusé explicitement — pas de volume de données suffisant pour une prévision crédible, périmètre jamais ouvert comme jalon).
- **Risque** : Faible — reste la partie la mieux testée et la plus rigoureusement conçue du projet, le mécanisme de confirmation n'a jamais été la source d'un bug trouvé cette session (contrairement à plusieurs flux de paiement classiques).

### Dispatch & Cloud Functions (architecture transverse)
- **Forces** : 45+ Cloud Functions organisées de façon pragmatique, verrouillage transactionnel ajouté au dispatch, observabilité par requête disponible pour les nouvelles fonctions (`request_logs`).
- **Faiblesses** : aucune configuration de montée en charge (défauts partout, cohérent avec l'échelle actuelle) ; pas d'enveloppe de réponse unifiée (dette acceptée).
- **Risque** : Faible.

### Notifications
- **Forces** : centre de notifications déjà riche, boucle de nettoyage des tokens FCM invalides désormais fermée (des deux côtés : détection ET consommation).
- **Faiblesses** : pas de bus d'événements central (23+ triggers ad hoc) ; un seul niveau de priorité ; un seul appareil par compte ; pas de templates/i18n serveur ; pas de préférences utilisateur.
- **Risque** : Faible à Moyen.

### Maps/GPS
- **Forces** : bien plus solide que supposé — routage réel avec trafic, recherche d'adresse à 3 niveaux (local/Nominatim/Google), les deux avec cache. Clé API centralisée (était dupliquée dans 3 fichiers).
- **Faiblesses** : aucune adresse favorite nulle part dans l'app ; aucune géoclôture ; zones de livraison sans tarifs/horaires par zone.
- **Risque** : Faible.

### Identité / IAM
- **Forces** : Firebase Phone Auth réel déjà intégré (récupération + 2FA admin) ; KYC-lite réel pour les livreurs (selfie + pièce d'identité) ; événements de connexion/déconnexion/permission désormais journalisés.
- **Faiblesses** : KYC absent pour tout autre type de partenaire ; sessions/appareils de confiance inexistants ; code mort dans l'ancien mécanisme 2FA ; bug probable sur la création de compte livreur de flotte (non corrigé).
- **Risque** : Moyen.

### Administration / Back Office
- **Forces** : l'essentiel des fonctionnalités demandées existe déjà comme écrans réels (zones, commandes, stats géo, classement livreurs, sous-admins, sécurité...).
- **Faiblesse structurelle majeure (nouvelle)** : **deux back-offices déconnectés** — l'app mobile a un back-office riche (dizaines d'écrans), le web en a un séparé et bien plus réduit (5 fonctions), construits indépendamment. Pas de compteur temps réel, pas de moteur de recherche dans les journaux d'audit malgré des données déjà indexées.
- **Risque** : Moyen — fonctionnellement présent mais fragmenté, source de divergence future si non arbitré.

### Courses, Marketplace, Immobilier, Restaurants & Pharmacies, Support
- **Inchangés depuis le 01/07** — aucun prompt de cette tranche (21-39) n'a redemandé un audit direct de ces modules ; leurs trouvailles de la version précédente restent valides (pas de panier Marketplace, pas de négociation prix Courses, deux systèmes Immobilier, pas de sous-catégories Restaurants/Pharmacies, support à sens unique).

---

## 9. Risques transverses (résumé mis à jour)

| Risque | Criticité | Statut |
|---|---|---|
| Mot de passe pharmacie en clair | Critique | **Corrigé** (01/07) |
| Paiement wallet livraison cassé (payOrderFromWallet/cancelOrder/deliverOrder) | Critique | **Corrigé** (cette session) |
| Paiement wallet Boutique cassé (creditSellerWallet) | Critique | **Corrigé** (cette session) |
| Tarification livraison non validée serveur | Élevée | Ouvert, inchangé |
| App Check absent | Élevée | Ouvert, inchangé |
| `livreurs.wallet` lisible par tout authentifié | Élevée | Ouvert — justification disparue, règle non resserrée (décision explicite) |
| Deux systèmes Immobilier parallèles | Élevée | Ouvert, inchangé |
| Deux back-offices non unifiés | Élevée | **Nouvelle découverte**, ouvert |
| ~90% du code sans test automatisé | Élevée | Ouvert, réduit (44→104 tests) |
| Fichiers Storage jamais nettoyés | Moyenne | **Nouvelle découverte**, ouvert |
| Compte livreur de flotte probablement cassé | Moyenne | **Nouvelle découverte**, ouvert |
| `service_providers` faiblesse d'auth (artisans) | Moyenne | Identifié Prompt 21, ouvert |
| Vocabulaire de statut transaction fragmenté | Moyenne | Ouvert, accepté comme dette |
| Pas de CI active, zéro commit cette session | Moyenne | Bloqué sur une action utilisateur |
| Pas de sauvegarde Firestore visible | Moyenne | Ouvert |
| Pagination incohérente | Moyenne | Ouvert |
| Firebase Analytics inutilisé | Faible | **Nouvelle découverte**, ouvert |
| Code mort 2FA admin | Faible | **Nouvelle découverte**, ouvert |
| Notation restaurant/pharmacie non fonctionnelle | Faible | Ouvert |
| Pas de suspension client | Faible | Ouvert |

---

## 10. Recommandations prioritaires (mises à jour)

**Critique** — aucune restante (les trois identifiées ont été corrigées).

**Élevée** :
1. Valider server-side la tarification livraison.
2. Activer App Check avec un rollout progressif.
3. Réconcilier ou officiellement séparer les deux systèmes Immobilier.
4. **Nouveau** : décider explicitement de l'avenir des deux back-offices (unifier, ou officiellement séparer les périmètres avec une documentation claire de qui utilise quoi).
5. Terminer la restriction du champ `livreurs.wallet` (le dispatch ne le justifie plus) — chantier scopé, ~10 sites de lecture/écriture à migrer.
6. Étendre la couverture de tests au-delà du code touché cette session, en priorité sur les flux Ekbine/Marketplace non encore audités par des tests.

**Moyenne** :
7. Pousser le dépôt vers GitHub pour activer la CI déjà écrite, puis committer le travail de cette session (actuellement non versionné).
8. Configurer une sauvegarde Firestore planifiée.
9. Corriger le flux de création de compte livreur de flotte (probablement cassé).
10. Migrer l'authentification `service_providers` (artisans) hors de `signInAnonymously()`.
11. Nettoyer le code mort du mécanisme 2FA admin (`generateAdminOtp`/`verifyAdminOtp`).
12. Concevoir une stratégie de nettoyage des fichiers Cloud Storage orphelins (au moins sur les flux à plus fort volume : remplacement de selfie/photo de livraison).
13. Corriger la notation restaurant/pharmacie.
14. Ajouter un chat bidirectionnel visible pour le support client.

**Faible** :
15. Câbler `Firebase Analytics` avec des événements réellement pertinents.
16. Ajouter des préférences de notification.
17. Ajouter la suspension de compte client.
18. Documentation par endpoint pour les Cloud Functions les plus critiques.

---

## 11. Plan de lancement par phases

Cadre proposé, à valider/ajuster par l'équipe produit — les critères de validation sont dérivés directement des risques identifiés ci-dessus, pas de suppositions génériques.

### Phase 1 — Bêta privée (petit groupe contrôlé)
**Critères d'entrée** : déjà remplis aujourd'hui — les 3 bugs de paiement critiques sont corrigés, le dispatch est fiable, la conciliation wallet tourne en surveillance passive.
**Critères de sortie avant Phase 2** : App Check activé ; tarification livraison validée côté serveur au moins pour les nouveaux flux ; décision prise sur les deux systèmes Immobilier et les deux back-offices (même si la décision est « les séparer officiellement », il faut qu'elle soit prise et documentée).

### Phase 2 — Bêta publique (Abengourou, trafic non contrôlé)
**Critères d'entrée** : tout ce qui précède + sauvegardes Firestore planifiées actives + CI réellement exécutée (remote GitHub poussé) + le travail de cette session committé et déployé.
**Critères de sortie** : deux semaines sans incident financier (conciliation wallet sans écart significatif), taux de succès de livraison mesuré et stable.

### Phase 3 — Lancement officiel à Abengourou
**Critères d'entrée** : tout ce qui précède + couverture de tests étendue aux flux Ekbine/Marketplace + flux de création de compte livreur de flotte corrigé (si ce canal de recrutement est utilisé pour le lancement).
**Critères de sortie** : indicateurs de succès (section 12) atteints sur au moins un cycle mensuel complet.

### Phase 4 — Extension aux autres villes de Côte d'Ivoire
**Critères d'entrée** : `TarifService` et `zones_livraison` ne sont aujourd'hui centrés que sur Abengourou (coordonnées GPS fixes) — nécessite une généralisation avant toute deuxième ville, pas un simple changement de configuration.
**Critères de sortie** : reporting financier multi-verticales en place (aujourd'hui limité aux commissions livreur) pour comparer les villes entre elles.

### Phase 5 — Déploiement dans d'autres pays africains
**Critères d'entrée** : c'est explicitement la vision long terme déjà actée dans `CLAUDE.md` (section Multi-pays) — FCFA codé en dur, devise non abstraite, aucune architecture multi-devise/multi-pays construite. Prérequis technique le plus proche déjà identifié : abstraire le formatage de devise avant toute autre chose.
**Critères de sortie** : hors de portée de cette synthèse — nécessite une refonte pluriannuelle déjà qualifiée comme telle dans `CLAUDE.md`.

---

## 12. Indicateurs de succès proposés

| Indicateur | Ce qui existe déjà pour le mesurer | Ce qui manque |
|---|---|---|
| Utilisateurs actifs | `clients`/`livreurs`/etc. comptables par requête Firestore | Pas de dashboard live, pas de définition d'« actif » (session ? commande ?) |
| Commandes (volume) | `orders`/`ekbine_orders`, déjà comptés dans plusieurs écrans admin | Pas agrégé multi-verticales dans un seul endroit |
| Taux de réussite des livraisons | Statuts déjà fiables (state machine stricte) | Pas de KPI calculé automatiquement, à dériver de `orders.status` |
| Disponibilité / stabilité | Crashlytics (client), `audit_logs`/`security_events` | Pas de SLA défini, pas de Cloud Monitoring |
| Temps de réponse | `request_logs` (nouveau, Prompt 25) pour les fonctions instrumentées | Couverture partielle seulement (nouvelles fonctions) |
| Coût moyen par transaction | Commission déjà calculée par commande | Pas de rapprochement coût Firebase réel ÷ nombre de transactions |
| Satisfaction client | `RatingDialog` existe pour le livreur | Notation restaurant/pharmacie cassée, pas de NPS/enquête |

**Recommandation** : ne pas prétendre que ces indicateurs sont suivis tant qu'un tableau de bord réel ne les agrège pas — la donnée brute existe en grande partie, l'agrégation n'existe pas encore (cohérent avec la section BI/Analytics déjà auditée, Prompt 14/34).

---

## 13. Verdict final

AZ Express peut supporter un **lancement pilote/bêta privée dès maintenant**, sous supervision humaine active — un cran plus solide qu'au 01/07/2026 grâce à la correction de trois bugs de paiement réels qui auraient directement affecté la confiance des premiers utilisateurs. Une bêta publique ou un lancement officiel non supervisé devraient attendre le traitement des points Élevés de la section 10, en particulier : App Check, tarification serveur, et une décision explicite sur les deux paires de systèmes dupliqués (Immobilier, Back-office) qui, laissées sans arbitrage, ne feront que diverger davantage à chaque nouvelle fonctionnalité.

Le travail réalisé au fil de cette session de 40 prompts n'est, à ce stade, **versionné nulle part** — aucun commit git n'a été fait. C'est la première action concrète et à très faible risque avant toute suite : committer, pousser vers un remote, activer la CI déjà écrite.
