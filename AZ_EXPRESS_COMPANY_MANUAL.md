# AZ Express — Manuel d'entreprise (Abengourou)

**Créé** : 2026-07-09 (Master Prompt 85, « Company Operations & Team Preparation »).
**Objet** : préparer AZ Express comme une vraie entreprise terrain — organisation humaine, formation, règlement, procédures partenaires/support/argent, plan de lancement pilote.
**Distinct de** : `OPERATIONS_RUNBOOK.md` (procédures techniques quotidiennes de l'admin dans l'app) et `CLAUDE.md`/`AUDIT_FINAL.md` (documentation développeur/audit). Ce document est pour les humains qui font tourner l'entreprise, pas pour ceux qui maintiennent le code.
**Portée** : documentation/procédures uniquement — aucun code, aucune configuration Firebase modifiés pour produire ce document. Les accès app mentionnés pour chaque rôle correspondent aux clés de permission réellement définies dans `admin_sub_admins_page.dart` (déjà construites, pas inventées).

---

## 1. Structure équipe AZ Express

Six rôles humains pour le lancement pilote — un seul poste peut couvrir plusieurs rôles au démarrage (l'équipe n'a pas besoin d'être complète dès le jour 1), mais chaque responsabilité listée doit être portée par quelqu'un explicitement, pas laissée sans propriétaire.

### Fondateur / Responsable général

- **Responsabilités** : décisions stratégiques (extension de zone, nouveaux partenaires majeurs, sanctions lourdes contre un livreur), arbitrage final en cas de litige non résolu par l'admin opération, relation avec les partenaires stratégiques, suivi de la santé financière globale.
- **Tâches quotidiennes** : revue rapide des indicateurs de clôture de la veille (voir `OPERATIONS_RUNBOOK.md` section « Indicateurs à suivre »), disponible pour arbitrer les décisions urgentes que l'admin opération ne peut pas prendre seul.
- **Accès app nécessaire** : compte **super-admin** (`admins/{uid}.role = 'super'`) — accès complet à toutes les sections, y compris la gestion des sous-admins et la purge (`purger`), réservée au rôle le plus haut.

### Admin opération (le rôle central au quotidien)

- **Responsabilités** : exécute la routine quotidienne décrite dans `OPERATIONS_RUNBOOK.md` (matin/journée/soir), premier point de contact pour tout incident, coordonne entre livreurs/partenaires/support.
- **Tâches quotidiennes** : vérification matinale (livreurs en ligne, partenaires ouverts, demandes en attente), suivi des commandes en direct, clôture du soir (cash marchand, commissions, anomalies).
- **Accès app nécessaire** : sous-admin avec permissions `livreurs`, `commandes`, `gains`, `classement`, `carte`, `demandes` (+ les 4 variantes `demandes_resto`/`demandes_vendeurs`/`demandes_boulangeries`/`demandes_pharmacies`), `zones`, `cash_marchand`, `sos`, `anti_fraude`.

### Support client

- **Responsabilités** : répondre aux tickets clients (`admin_support_page.dart`), traiter les signalements produits, être le canal humain (WhatsApp/téléphone) pour tout ce que l'app ne couvre pas encore (remboursement partiel, réassignation manuelle — voir `OPERATIONS_RUNBOOK.md` pour la liste exacte des gaps outillage).
- **Tâches quotidiennes** : traiter tous les tickets `open` avant la fin de journée, surveiller les signalements produits Marketplace.
- **Accès app nécessaire** : sous-admin avec permission `support` uniquement (pas besoin d'accès financier pour ce rôle, sauf s'il est aussi l'admin opération).

### Gestion livreurs

- **Responsabilités** : recrutement et validation des nouveaux livreurs, formation (voir section 2), suivi de la performance (`admin_drivers_ranking.dart`), application du règlement (section 3) — avertissements/suspensions.
- **Tâches quotidiennes** : traiter les nouvelles demandes d'inscription (`driver_requests_page.dart`), vérifier les livreurs suspendus/à surveiller.
- **Accès app nécessaire** : sous-admin avec permissions `livreurs`, `demandes`, `classement`, `flottes`, `anti_fraude`.

### Gestion partenaires

- **Responsabilités** : recrutement et validation des restaurants/pharmacies/boutiques/vendeurs marketplace, accompagnement à l'ajout de produits, suivi de la qualité (retards de préparation récurrents, ruptures de stock).
- **Tâches quotidiennes** : traiter les nouvelles demandes de partenariat, vérifier que les partenaires actifs ont bien mis à jour prix/disponibilité.
- **Accès app nécessaire** : sous-admin avec permissions `restaurants`, `pharmacies`, `boutique`, `boulangeries`, `demandes_resto`, `demandes_vendeurs`, `demandes_boulangeries`, `demandes_pharmacies`.

### Comptabilité / Cash

- **Responsabilités** : clôture financière quotidienne (voir section 6), suivi des commissions AZ, réconciliation wallet hebdomadaire (`wallet_reconciliation_findings`, automatique chaque lundi — à consulter, pas à recalculer).
- **Tâches quotidiennes** : vérifier `admin_cash_settlement_page.dart` en fin de journée, s'assurer qu'elle revient à zéro avant la clôture.
- **Accès app nécessaire** : sous-admin avec permissions `cash_marchand`, `gains`, `recharges`.

---

## 2. Formation livreurs — guide pas à pas

À remettre (oralement ou par écrit) à chaque nouveau livreur avant sa première course. Chaque étape correspond à un écran réel de l'app livreur, déjà construit et fonctionnel.

### Avant la première course

1. **Installation de l'app** — télécharger AZ Express (lien fourni par l'admin, ou Play Store une fois publié).
2. **Inscription** — remplir le formulaire d'inscription livreur : nom, téléphone, selfie de vérification, pièce d'identité (photo). L'inscription passe en attente d'approbation admin — expliquer au livreur que ça peut prendre jusqu'à 24-48h.
3. **Connexion** — une fois approuvé, se connecter avec le compte créé.
4. **Activation GPS** — accepter les permissions de localisation demandées par l'app (position précise + arrière-plan) : sans ça, aucune commande ne pourra être proposée. Expliquer pourquoi (le dispatch se base sur la position réelle du livreur).
5. **Mode disponible** — basculer le bouton "En ligne" sur le tableau de bord livreur avant d'attendre des commandes. Rappeler : être "en ligne" sans se déplacer n'a aucun coût, mais rester "hors ligne" signifie ne jamais recevoir de commande.

### Pendant une course

1. **Accepter la commande** — dès qu'une notification arrive, ouvrir l'app et taper "Accepter" avant qu'un autre livreur ne le fasse (en mode diffusion, plusieurs livreurs peuvent être notifiés en même temps — le premier à accepter gagne la course).
2. **Appeler le client** — le numéro du client est visible dans le détail de la commande une fois acceptée, pas avant. Appeler pour confirmer l'adresse/les instructions si besoin.
3. **Récupérer le colis/produit** — au point de collecte (adresse du client pour une livraison colis, ou du restaurant/pharmacie/boutique pour une commande produit).
4. **Preuve de livraison** — à la remise, prendre une photo de preuve directement dans l'app (obligatoire, déjà exigé par l'écran de confirmation de livraison).
5. **Terminer la commande** — taper "Confirmer la livraison" dans l'app. C'est cette action qui déclenche le crédit du livreur (si applicable) — ne jamais considérer une course "faite" tant que ce bouton n'a pas été validé dans l'app, même si la remise physique a eu lieu.

### Règles à connaître dès le départ

- **Argent cash** : pour une commande cash avec un produit (restaurant/pharmacie), le livreur collecte à la fois le prix du produit ET les frais de livraison en espèces — ce n'est PAS le livreur qui garde la part "produit", elle doit être remise au marchand (voir section 3, obligation, et `OPERATIONS_RUNBOOK.md` pour le contrôle admin de ce point précis).
- **Comportement client** : politesse obligatoire, jamais de négociation de prix directement avec le client (le prix est fixé par l'app), jamais de demande d'argent en dehors de ce que l'app affiche.
- **Retard** : prévenir via l'app (chat) ou par téléphone si un retard significatif est prévisible — un client qui ne reçoit aucune nouvelle et voit le suivi GPS ne plus bouger perd confiance plus vite qu'un client prévenu.
- **Annulation** : un livreur peut refuser une commande avant de l'accepter, sans pénalité. Après acceptation, annuler sans raison valable expose à une sanction (voir section 3) — la commission déjà déduite à l'acceptation n'est remboursée que si l'annulation est légitime.

---

## 3. Règlement livreur

### Obligations

| Obligation | Pourquoi |
|---|---|
| Téléphone chargé pendant le service | Un téléphone mort = position GPS périmée, commandes manquées, client sans nouvelles |
| GPS actif en permanence pendant une course | Le suivi temps réel affiché au client dépend uniquement de ça |
| Respect du client | Politesse, ponctualité raisonnable, pas de comportement déplacé |
| Remise intégrale de l'argent marchand collecté en cash | L'argent du produit collecté en espèces appartient au marchand, pas au livreur — le garder au-delà d'un délai raisonnable est une faute grave, pas un simple retard administratif |
| Confirmation réelle de chaque étape dans l'app | Ne jamais marquer une commande "livrée" sans l'avoir réellement livrée |

### Sanctions — graduées

1. **Avertissement** — premier manquement mineur (retard répété non signalé, petite négligence). Communiqué oralement/WhatsApp par le responsable gestion livreurs, noté quelque part (même un simple carnet/tableur au démarrage — pas d'outil dédié dans l'app pour tracer les avertissements, gap à connaître).
2. **Suspension temporaire** — manquement répété après avertissement, ou faute plus sérieuse (cash marchand non remis après relance, comportement inapproprié signalé par un client). Exécutée directement dans l'app (`drivers_page.dart`, bouton suspendre déjà fonctionnel) — le livreur suspendu ne reçoit plus aucune commande tant que le compte n'est pas réactivé, et une tentative d'accepter une commande pendant la suspension affiche déjà un message d'erreur clair.
3. **Désactivation définitive** — faute grave (vol avéré, fraude, mise en danger d'un client). Suppression du compte livreur — vérifier au préalable que son wallet est à zéro ou que le solde restant a été traité, avant suppression (l'app ne bloque pas la suppression d'un compte à solde non-nul, donc c'est une vérification humaine à faire systématiquement avant).

---

## 4. Partenaires — procédure par type

Les 4 types de partenaires (restaurant, pharmacie, boutique, vendeur marketplace) suivent chacun un flux d'inscription légèrement différent, déjà construit et audité — la procédure humaine ci-dessous s'appuie sur ces flux réels.

### Restaurant

1. **Inscription** — le restaurant s'inscrit lui-même via l'app (auto-service), crée son propre compte.
2. **Validation** — l'admin (gestion partenaires) approuve la demande dans `admin_restaurant_requests_page.dart`.
3. **Ajout produits** — une fois approuvé, le restaurant gère son propre menu depuis son tableau de bord (`restaurant_owner_dashboard.dart`) : ajout/édition/suppression de plats, prix, disponibilité, stock.
4. **Réception commandes** — les commandes arrivent directement dans son tableau de bord, notification push automatique.
5. **Gestion stock** — le restaurant marque lui-même un plat "indisponible" temporairement — pas besoin de repasser par l'admin pour ça.

### Pharmacie

1. **Inscription** — auto-service, mais **la pharmacie n'a pas de compte Firebase Auth classique** (authentification par mot de passe géré différemment, technicité invisible pour l'utilisateur final).
2. **Validation** — `admin_pharmacie_requests_page.dart`.
3. **Ajout produits/gestion** — tableau de bord pharmacie, plus limité que celui du restaurant (2 onglets : statut, commandes) — les commandes pharmacie restent en description texte libre plutôt qu'un vrai catalogue produit, à savoir avant de promettre au partenaire une gestion de catalogue avancée.
4. **Réception commandes** — via son tableau de bord.

### Boutique AZ

**Différence structurelle importante à connaître** : contrairement aux 3 autres types, la Boutique n'a **pas de compte partenaire séparé par vendeur** — c'est un module géré directement par l'admin (`admin_boutique_page.dart`). Ne pas promettre à un vendeur externe qu'il aura son propre accès Boutique — ce n'est pas comment le module est construit.

1. **Ajout produits** — fait par l'admin lui-même dans `admin_boutique_page.dart` (photos, prix, stock).
2. **Réception commandes** — visibles dans le même écran admin, avec suivi cash spécifique (statut "Cash à confirmer" pour les achats en espèces).
3. **Gestion stock** — décrémenté automatiquement à chaque achat, à réapprovisionner manuellement par l'admin.

### Vendeur Marketplace

1. **Inscription** — auto-service (`seller_requests`).
2. **Validation** — `admin_seller_requests_page.dart`.
3. **Ajout produits** — le vendeur publie lui-même ses annonces (photos, prix, description) — modèle proche d'une petite annonce classique, pas un vrai panier/checkout (le contact acheteur↔vendeur se fait par appel/message/WhatsApp directement, pas de paiement in-app pour cette catégorie).
4. **Réception commandes** — pas de "commande" au sens livraison classique pour un contact simple ; si le vendeur utilise le flux de commande avec livraison, elle apparaît dans son tableau de bord comme les autres.
5. **Commission** — 0% pour ce type de partenaire (le vendeur garde l'intégralité du prix) — le modèle économique Marketplace repose sur un abonnement, pas une commission par vente, à bien expliquer au vendeur pour éviter toute confusion sur les montants reçus.

---

## 5. Support client — scripts de réponse

À utiliser comme base, à adapter au ton de la conversation réelle — pas à réciter mot pour mot.

### Commande retardée

> « Bonjour, je vois que votre commande est en cours de livraison. Je vérifie tout de suite avec le livreur et je reviens vers vous dans quelques minutes. Merci de votre patience. »

Ensuite : vérifier `admin_orders.dart` (position GPS du livreur, dernière mise à jour), recontacter le client avec une information concrète (temps estimé, raison du retard si connue) plutôt que de laisser sans réponse.

### Livreur introuvable

> « Je suis désolé pour ce désagrément. Je contacte le livreur immédiatement. Si je n'arrive pas à le joindre dans les prochaines minutes, je réorganise votre livraison ou je procède à un remboursement. »

Suivre la procédure incident livreur de `OPERATIONS_RUNBOOK.md` (vérifier GPS périmé, contacter par un second moyen, réassigner ou annuler manuellement si nécessaire).

### Mauvais produit

> « Je suis désolé, ce n'est pas le niveau de service que nous voulons offrir. Pouvez-vous me confirmer ce qui a été reçu à la place ? Je vais régulariser votre dossier rapidement. »

Créer/traiter un ticket support catégorisé "Commande", décision de remboursement/geste commercial au cas par cas (pas de remboursement partiel automatique dans l'app aujourd'hui — traitement manuel).

### Remboursement

> « Votre demande de remboursement est bien prise en compte. Le traitement se fait sous [délai à définir par l'équipe] et le montant sera crédité sur votre wallet AZ Express / restitué selon le moyen de paiement utilisé. »

Distinguer : commande pas encore livrée (annulation classique, déjà automatisée) vs commande déjà livrée avec litige (traitement manuel, décision de l'admin opération ou du responsable).

### Problème de paiement

> « Je comprends votre inquiétude concernant le paiement. Pouvez-vous me confirmer le mode de paiement utilisé (wallet, cash, mobile money) ? Je vérifie immédiatement votre transaction. »

Vérifier `wallet_transactions` (sous-collection du client) pour l'historique réel avant de promettre quoi que ce soit — ne jamais confirmer un remboursement sans avoir vérifié la transaction réelle.

---

## 6. Argent terrain — procédure de clôture quotidienne

**Responsable désigné** : le rôle Comptabilité/Cash (section 1) — en son absence au démarrage du pilote, l'admin opération assure cette tâche, mais un seul nom doit être responsable chaque soir, jamais "personne en particulier".

Chaque soir, avant de clore la journée :

1. **Vérifier les commandes terminées** — `admin_orders.dart`, confirmer qu'aucune commande n'est restée bloquée sans raison (voir `OPERATIONS_RUNBOOK.md` pour le détail — l'app signale déjà visuellement les commandes en cours depuis plus d'1h).
2. **Vérifier le cash marchand** — `admin_cash_settlement_page.dart` doit revenir à zéro : chaque commande cash avec un restaurant/pharmacie y reste tant qu'elle n'est pas marquée "réglée" (déclaration que le livreur a bien remis l'argent au marchand).
3. **Contrôler les livreurs** — croiser les livreurs ayant terminé des courses cash aujourd'hui avec la liste de cash non réglé : un livreur qui apparaît plusieurs jours de suite avec du cash en attente est un signal à traiter (voir section 3, sanctions).
4. **Clôturer la journée** — une fois les 3 points ci-dessus vérifiés, la journée est considérée close. Il n'existe pas de bouton "clôture" formel dans l'app (déjà noté comme gap dans `OPERATIONS_RUNBOOK.md`) — la clôture est une procédure humaine : la liste `admin_cash_settlement_page.dart` vide EST la preuve que la journée est réglée.

---

## 7. Lancement pilote Abengourou — plan par semaine

### Semaine 1 — démarrage prudent

- **Livreurs** : 5 comptes validés minimum (déjà identifié comme le plancher nécessaire, `AUDIT_FINAL.md` Section 38).
- **Partenaires** : 1 restaurant actif, 1 pharmacie active, la Boutique AZ approvisionnée, quelques vendeurs marketplace pour tester le flux.
- **Zone couverte** : les 4 zones déjà pré-remplies dans l'app (Commerce, Cafétou, Plateau, Château) — ajouter les 5 zones restantes (Agnikro, Dioulakro, Indénié 2000, Aviation, Nouveau Quartier) dès que l'équipe a le temps, pas nécessairement avant le jour 1.
- **Objectif de la semaine** : que chaque étape du parcours (commande → dispatch → acceptation → livraison → paiement) fonctionne au moins une fois sans incident bloquant, avec une équipe qui observe de près plutôt que de viser un volume.

### Semaine 2 — objectifs et mesures

- **Objectifs** : passer d'un volume "test" à un volume réel mais modeste — pas de chiffre cible rigide à ce stade, l'objectif est la stabilité, pas la croissance.
- **Mesures à suivre** (voir `OPERATIONS_RUNBOOK.md`, tableau « Indicateurs à suivre ») : commandes bloquées, cash non réglé en fin de journée, tickets support ouverts, zones/créneaux en échec de dispatch (`admin_security_dashboard.dart`).
- **Décision de la semaine** : si les indicateurs restent propres (peu d'incidents, pas de plainte répétée), commencer à élargir prudemment (zones restantes, 1-2 partenaires de plus).

### Semaine 4 — décision d'extension

- **Bilan** : comparer les 4 premières semaines aux seuils de croissance déjà documentés dans `OPERATIONS_RUNBOOK.md` (5→20 livreurs, 50→500 commandes/jour) — pas pour décider d'y aller tout de suite, mais pour savoir si l'app et l'équipe sont prêtes techniquement AVANT de pousser le volume.
- **Décision** : soit continuer à ce rythme et stabiliser encore, soit commencer l'extension (plus de livreurs, plus de zones, plus de partenaires) — dans ce dernier cas, revoir en priorité les points signalés dans `OPERATIONS_RUNBOOK.md` section 6 (agrégation non bornée de `admin_earnings.dart`/`admin_drivers_ranking.dart`, sauvegarde Firestore, etc.) avant d'atteindre le palier 500 commandes/jour, pas après.

---

## Checklist d'ouverture — jour du lancement

- [ ] Au moins un titulaire nommé pour chacun des 6 rôles (section 1) — même une seule personne cumulant plusieurs rôles, mais chaque responsabilité a un nom.
- [ ] 5 livreurs formés (section 2) et validés dans l'app.
- [ ] Règlement livreur (section 3) communiqué à chaque livreur avant sa première course.
- [ ] Au moins 1 restaurant + 1 pharmacie + la Boutique AZ approvisionnée + quelques vendeurs marketplace actifs (section 4).
- [ ] Scripts support (section 5) connus par la personne en charge du support.
- [ ] Responsable de la clôture cash du soir désigné (section 6).
- [ ] Canal support (WhatsApp/téléphone) communiqué aux premiers clients test.
- [ ] Zones actives (au minimum les 4 déjà pré-remplies).
- [ ] Blocage Google Cloud Billing résolu, Cloud Functions déployées (`AUDIT_FINAL.md` Section 38) — prérequis technique absolu avant toute commande réelle, sans quoi aucune livraison ne peut aboutir.
