# AZ Express — Dossier de présentation

**Créé** : 2026-07-09 (Master Prompt 86, « Investor & Partner Readiness Package »).
**Public visé** : investisseurs, associés potentiels, partenaires commerciaux, autorités locales.
**Statut du projet à la date de ce document** : pré-lancement, code freeze, application prête côté technique, en attente de la levée d'un blocage d'infrastructure (facturation Google Cloud) avant la mise en production réelle. **Aucun chiffre d'usage réel (utilisateurs, commandes, revenu) n'est cité dans ce document — le produit n'a pas encore été lancé auprès du public.** Chaque affirmation ci-dessous distingue explicitement ce qui est construit et testé de ce qui est projeté.

---

## Résumé exécutif

AZ Express est une super-application ivoirienne conçue pour Abengourou : livraison à la demande, courses, marketplace de petites annonces, commande chez les restaurants/pharmacies/boulangeries locaux, une boutique en ligne propre à AZ Express, et des services de proximité (Ekbine, moto-taxi/services). L'ambition à terme est de faire d'un assistant conversationnel (« AZ IA ») le point d'entrée principal de la plateforme — « Parlez. AZ s'occupe du reste. »

**État réel à ce jour** : l'application est techniquement terminée et auditée en profondeur (53 fonctions serveur, 159 tests automatisés, 11 bugs financiers critiques et 4 failles de sécurité identifiés et corrigés avant tout lancement public — voir section Avantages). Le déploiement final en production est bloqué par un problème de facturation Google Cloud, en cours de résolution, indépendant de la qualité du code. Le pilote terrain à Abengourou peut démarrer dès ce blocage levé.

---

## Pitch en une minute

> « À Abengourou, commander un repas, faire livrer un colis, trouver un produit en pharmacie ou vendre un article d'occasion demande aujourd'hui de passer par le bouche-à-oreille, le téléphone, ou de se déplacer soi-même — aucune application de livraison ou de marketplace n'a été pensée pour cette ville. AZ Express change ça : une seule application qui couvre la livraison, les courses, les restaurants, les pharmacies, une boutique en ligne et un marketplace local, avec un réseau de livreurs locaux et, à terme, un assistant qui comprend une simple phrase et s'occupe du reste. L'application est prête, testée, et auditée — il ne manque qu'un déblocage administratif pour ouvrir le service au public. »

---

## 1. Présentation AZ Express

### Le problème identifié à Abengourou

Les grandes applications de livraison et de VTC qui existent en Côte d'Ivoire se concentrent presque exclusivement sur Abidjan. Une ville de l'intérieur comme Abengourou — carrefour économique de la région, avec un tissu de commerces, restaurants, pharmacies et petits vendeurs actif — n'a pas d'équivalent numérique : pas de service de livraison à la demande structuré, pas de marketplace local en ligne, pas de moyen simple de commander à distance chez un partenaire de quartier. La coordination reste manuelle : appels téléphoniques, déplacement personnel, réseau de connaissances.

### La solution AZ Express

Une seule application mobile qui couvre l'ensemble de ces besoins plutôt que plusieurs outils disparates : livraison de colis, courses (achats délégués), commande chez des restaurants/pharmacies/boulangeries partenaires, une boutique en ligne gérée directement par AZ Express, un marketplace de petites annonces façon Djassa, et des services de proximité (Ekbine). Un réseau de livreurs locaux, recrutés et formés sur place, assure la dernière étape.

### Vision

Devenir le point de contact numérique de référence pour le commerce et les services du quotidien dans les villes moyennes de Côte d'Ivoire — en commençant par Abengourou, preuve de concept avant extension.

### Mission

Simplifier l'accès aux commerces et services locaux pour les habitants d'Abengourou, tout en créant des revenus complémentaires réels pour les livreurs et une nouvelle vitrine de vente pour les commerçants locaux.

### En une phrase

**AZ Express = livraison + marketplace + services locaux, dans une seule application, pensée pour une ville de l'intérieur ivoirien plutôt que copiée d'un modèle abidjanais ou étranger.**

---

## 2. Produit — modules par utilisateur

### Client

- **Livraison** — envoi de colis point à point, tarification calculée selon la distance et l'heure (majoration nuit déjà intégrée).
- **Courses** — un livreur achète pour le compte du client (ex. liste de courses au marché).
- **Restaurants** — commande de plats chez des restaurants partenaires locaux, paiement cash ou wallet.
- **Pharmacie** — commande de médicaments avec livraison, y compris un mode « pharmacie de garde ».
- **Boutique AZ** — catalogue de produits vendus et géré directement par AZ Express, avec paiement cash ou wallet et suivi de stock en temps réel.
- **Marketplace** — petites annonces entre particuliers/vendeurs (téléphones, objets, etc.), avec messagerie intégrée acheteur-vendeur.
- **Wallet intégré** — solde rechargeable via Mobile Money (Orange, MTN, Moov, Wave) pour payer toutes les commandes sans ressaisir d'informations à chaque fois.
- **AZ IA** (assistant conversationnel) — jalon technique déjà largement construit (compréhension du langage, exécution d'actions avec confirmation systématique avant toute action sensible) ; voir section Avantages pour l'état d'avancement réel.

### Livreur

- **Courses disponibles** — réception en temps réel des commandes à proximité (attribution automatique par distance, avec élargissement progressif du rayon si aucun livreur n'accepte).
- **GPS temps réel** — suivi de position partagé avec le client pendant la livraison, optimisé pour la batterie.
- **Revenus** — gains suivis directement dans l'application, historique des transactions, retrait vers Mobile Money.

### Partenaires (restaurants, pharmacies, boulangeries, vendeurs marketplace)

- **Vendre en ligne** — chaque partenaire gère son propre catalogue (produits, prix, disponibilité, stock) depuis son propre tableau de bord.
- **Recevoir des commandes** — notification immédiate à chaque nouvelle commande, suivi de son propre historique de ventes et de son solde.

### Admin (équipe AZ Express)

- **Contrôle de l'activité** — tableau de bord centralisé pour la gestion des livreurs (validation, suspension), des partenaires (approbation, suivi), des commandes en cours, du support client, du cash collecté sur le terrain, et de la sécurité de la plateforme.

---

## 3. Marché

### Cible initiale : Abengourou

Ville de l'intérieur de la Côte d'Ivoire, chef-lieu de région, avec un tissu commercial actif (restaurants, pharmacies, petits commerces, vendeurs informels) et une population jeune, majoritairement équipée en smartphone — un profil cohérent avec l'adoption des super-apps déjà observée à Abidjan, mais un marché non encore couvert par les acteurs existants. **Aucune estimation chiffrée du marché adressable (nombre d'habitants, taux de pénétration smartphone, panier moyen) n'est avancée dans ce document** — ces chiffres nécessitent une étude de marché dédiée, non réalisée à ce stade, plutôt qu'une estimation approximative présentée comme fiable.

### Extension possible — villes voisines

Le modèle (livraison + marketplace + services locaux, opéré par une équipe locale) est conçu pour être reproductible dans d'autres villes moyennes de la région (Moronou/Indénié-Djuablin et au-delà) une fois le pilote Abengourou validé — même logique que l'extension progressive déjà pratiquée par les acteurs présents à Abidjan, à l'échelle d'une ville moyenne plutôt qu'une capitale économique.

### Types d'utilisateurs

- **Clients particuliers** — habitants cherchant à se faire livrer un repas, un colis, des médicaments, ou à acheter/vendre sur le marketplace.
- **Livreurs** — profil de travailleur indépendant local, rémunéré à la course, avec un système de commission transparent.
- **Commerçants partenaires** — restaurants, pharmacies, boulangeries, vendeurs souhaitant une vitrine de vente en ligne sans construire leur propre application.
- **Administration locale** — potentiel partenaire pour la structuration de l'économie informelle locale (traçabilité des transactions, formalisation progressive).

---

## 4. Business model

### Actuel — mécanismes déjà construits, testés, prêts à générer du revenu dès le lancement

| Source | Mécanisme | État |
|---|---|---|
| **Commission livraison** | Prélevée automatiquement à chaque course acceptée par un livreur, par palier (100 ou 200 FCFA selon le montant de la commande, configurable sans redéploiement) | ✅ Construit, testé, jamais encore exercé en production réelle (blocage de déploiement en cours de résolution) |
| **Abonnements partenaires** | Restaurants et boulangeries paient un abonnement mensuel (formule standard/VIP) pour vendre sur la plateforme — le Marketplace lui-même ne prélève aucune commission par vente, la monétisation vient de cet abonnement | ✅ Construit |
| **Boutique AZ** | Marge commerciale directe — AZ Express achète/gère son propre stock et le revend via l'app, pas une commission mais une marge de revente classique | ✅ Construit |

### Honnêteté sur un point de modèle économique déjà tranché

**Ekbine (moto-taxi/services de proximité) ne génère aujourd'hui aucune commission pour AZ Express, par choix de conception délibéré** — le client paie le montant exact du service, l'agent gagne sur sa propre marge opérationnelle. Ce module existe pour compléter l'offre de services locaux, pas comme canal de revenu actuel — une monétisation future y est envisageable (abonnement agent, commission réduite) mais n'a pas été décidée ni construite.

### Prévu futur — pistes identifiées, non construites, à valider avant tout engagement

- **Services premium** — fonctionnalités additionnelles payantes pour les clients (livraison express garantie, priorité de dispatch) : idée explorée, aucun mécanisme construit à ce jour.
- **Publicité/mise en avant marketplace** — mise en avant payante d'une annonce ou d'un produit boutique : non construite.
- **Monétisation Ekbine** — voir ci-dessus.
- **Extension multi-villes** — nouvelle source de croissance du volume de commissions/abonnements existants, pas un nouveau mécanisme de revenu en soi.

---

## 5. Avantages AZ Express

- **Technologie déjà prête, pas un concept sur papier** — application Flutter (Android/iOS/Web) fonctionnelle, 53 fonctions serveur (Cloud Functions) couvrant paiement, dispatch, notifications, sécurité, 159 tests automatisés passants, infrastructure Firebase déjà configurée et sécurisée. Ce n'est pas un prototype à finir de construire — c'est un produit techniquement complet en attente de son premier déploiement public.
- **Un audit de production inhabituellement approfondi pour ce stade** — plus de 85 passes d'audit dédiées ont été menées avant ce dossier : **11 bugs financiers critiques** (risques de perte ou de création d'argent) et **4 failles de sécurité critiques/élevées** ont été identifiés et corrigés avant tout lancement public — un niveau de rigueur rarement atteint avant le premier utilisateur réel, plutôt qu'après un incident.
- **Solution pensée pour le terrain local, pas importée** — tarification, zones de livraison, règles horaires (majoration nuit, restriction de distance après 21h) et méthodes de paiement (Mobile Money local, cash à la livraison) sont calibrées spécifiquement pour Abengourou, pas un modèle générique adapté après coup.
- **Multi-services dans une seule app** — évite la fragmentation (une app par besoin) qui caractérise souvent les marchés secondaires ; un seul compte, un seul wallet, pour tous les services.
- **Connaissance terrain déjà intégrée à la conception** — dispatch par proximité GPS réelle avec élargissement progressif du rayon de recherche, cash collecté avec un mécanisme de traçabilité pour les marchands, formation et règlement livreur déjà rédigés (voir `AZ_EXPRESS_COMPANY_MANUAL.md`) — le produit n'a pas été pensé uniquement comme un logiciel, mais avec l'opération humaine qui l'accompagne.
- **AZ IA, un différenciateur en construction avancée, pas juste annoncé** — l'assistant conversationnel a déjà 7 jalons techniques livrés sur 8 prévus (compréhension du langage, exécution d'actions via des outils sécurisés, confirmation serveur systématique avant toute action financière, support vocal de base) — un investissement technique réel, pas une promesse marketing.

---

## 6. Plan de lancement

### Phase 1 — Pilote Abengourou

Démarrage prudent : un nombre restreint de livreurs formés, quelques partenaires actifs (au moins un restaurant, une pharmacie, la Boutique AZ approvisionnée), une couverture géographique limitée aux quartiers déjà configurés dans l'application. Objectif : valider que l'ensemble du parcours (commande → livraison → paiement) fonctionne de façon fiable en conditions réelles, avant de chercher du volume. Plan détaillé (semaine par semaine) déjà rédigé dans `AZ_EXPRESS_COMPANY_MANUAL.md`.

### Phase 2 — Croissance sur la ville

Une fois le pilote stabilisé (peu d'incidents, retours clients positifs) : élargissement du nombre de livreurs et de partenaires, couverture de l'ensemble des quartiers d'Abengourou, montée en charge progressive du volume de commandes quotidien. Les seuils techniques à surveiller avant cette montée en charge (capacité des écrans admin, sauvegarde des données, coûts d'infrastructure) sont déjà documentés dans `OPERATIONS_RUNBOOK.md`.

### Phase 3 — Expansion

Réplication du modèle vers d'autres villes moyennes de la région une fois Abengourou stabilisée et rentable à l'échelle pilote — décision à prendre sur la base de données réelles issues des Phases 1 et 2, pas anticipée dans ce document.

---

## 7. Risques — honnêtement

- **Blocage de déploiement en cours** — le lancement réel dépend aujourd'hui de la résolution d'un problème de facturation Google Cloud (Cloud Build), une démarche administrative en cours, indépendante de la qualité du produit, mais qui retarde concrètement la date de premier lancement tant qu'elle n'est pas résolue.
- **Adoption utilisateurs à construire de zéro** — Abengourou n'a pas d'historique d'usage d'applications de livraison ; convaincre les premiers clients et partenaires demandera un effort d'acquisition et de pédagogie, pas seulement la disponibilité de l'application.
- **Formation et fidélisation des livreurs** — le modèle dépend d'un réseau de livreurs fiables ; le recrutement, la formation (déjà structurée, `AZ_EXPRESS_COMPANY_MANUAL.md`) et la rétention restent un travail humain continu, pas un problème résolu par la seule technologie.
- **Coûts d'infrastructure évolutifs** — Firebase/Google Cloud facturent à l'usage ; certains points de vigilance sont déjà identifiés avant même le lancement (nettoyage du stockage jamais automatisé, certaines lectures de données non plafonnées à grande échelle) — gérables au volume du pilote, mais à surveiller activement dès que le volume grandit, pas après coup.
- **Concurrence potentielle** — si un acteur déjà présent à Abidjan décide d'étendre sa couverture à Abengourou, AZ Express perd l'avantage de premier entrant sur ce marché précis ; la connaissance terrain et la relation déjà nouée avec les partenaires locaux restent l'avantage défendable dans ce scénario, pas une barrière technologique.
- **Équipe opérationnelle encore à constituer** — les rôles et procédures sont documentés (`AZ_EXPRESS_COMPANY_MANUAL.md`), mais aucune personne n'est encore formellement en poste sur chacun de ces rôles à la date de ce document — un besoin de recrutement/formation réel avant le jour du lancement, pas déjà résolu.

---

## Roadmap — synthèse

| Étape | Contenu | Statut |
|---|---|---|
| Développement produit | Livraison, courses, marketplace, restaurants, pharmacies, boutique, Ekbine, admin | ✅ Terminé, code freeze |
| Audit sécurité & financier | 85+ passes d'audit, 11 bugs financiers + 4 failles de sécurité corrigés | ✅ Terminé |
| Documentation opérationnelle | Manuel technique (`OPERATIONS_RUNBOOK.md`) et manuel d'entreprise (`AZ_EXPRESS_COMPANY_MANUAL.md`) | ✅ Terminé |
| Déblocage infrastructure | Résolution facturation Google Cloud, déploiement final des fonctions serveur | 🔴 En attente, action externe en cours |
| Pilote Abengourou (Phase 1) | Lancement restreint, validation du parcours complet | ⏳ Prêt à démarrer dès déblocage |
| Croissance ville (Phase 2) | Montée en charge, couverture complète Abengourou | ⏳ Conditionnée à la réussite de la Phase 1 |
| Expansion régionale (Phase 3) | Réplication vers d'autres villes | ⏳ Décision future, données-driven |
