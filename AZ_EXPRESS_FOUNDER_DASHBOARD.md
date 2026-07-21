# AZ Express — Tableau de bord du fondateur

**Créé** : 2026-07-09 (Master Prompt 89, « Final Founder Control Center »).
**Objet** : document de pilotage personnel — une vue d'ensemble à consulter régulièrement, pas un nouveau manuel. Renvoie vers les documents détaillés existants plutôt que de les redupliquer : `OPERATIONS_RUNBOOK.md` (procédures techniques admin), `AZ_EXPRESS_COMPANY_MANUAL.md` (équipe/formation/plan pilote), `AZ_EXPRESS_INVESTOR_BRIEF.md` (dossier externe), `AZ_EXPRESS_MARKETING_KIT.md` (textes de lancement), `AZ_EXPRESS_LEGAL_ADMIN_PACK.md` (administratif/contrats), `AUDIT_FINAL.md` Section 38 (plan de déploiement technique exact).

---

## 1. État global AZ Express

### Technique

| Terminé ✅ | Bloqué 🔴 |
|---|---|
| Application Flutter (Android/iOS/Web) code freeze | Facturation Google Cloud Billing / Cloud Build (HTTP 403) |
| 53 fonctions serveur écrites, 159/159 tests automatisés passants | → seulement **30/53** fonctions réellement déployées en production |
| Sécurité auditée en profondeur (4 failles critiques/élevées trouvées et corrigées avant tout lancement public) | → `dispatchOrderToDriver`, `deliverOrderCF`, `cancelOrderCF`, `payOrderFromWalletCF` absentes de la production — **aucune commande de livraison réelle ne peut aboutir tant que ce n'est pas résolu** |
| `firestore.rules`/`storage.rules`/37 index déjà déployés et à jour | |
| Flutter passé sur canal stable, AAB Play Store se compile sans erreur | |
| Firebase Hosting live (`/confidentialite`, `/delete-account` répondent 200) | |

### Produit — modules prêts

Livraison, courses, restaurants, pharmacie, boutique AZ, marketplace, Ekbine, wallet (Mobile Money + cash), admin multi-écrans, support client bidirectionnel, AZ IA (assistant conversationnel, 7/8 jalons livrés).

### Produit — limites connues

Pas de panier/paiement in-app pour le marketplace (contact direct acheteur-vendeur), un seul projet Firebase (pas d'environnement de test séparé), certains écrans admin non bornés en lecture (sûr au volume pilote, à corriger avant grande échelle — voir `OPERATIONS_RUNBOOK.md` section 6), pas de sauvegarde Firestore automatique configurée.

### Entreprise — documents disponibles

`OPERATIONS_RUNBOOK.md`, `AZ_EXPRESS_COMPANY_MANUAL.md`, `AZ_EXPRESS_INVESTOR_BRIEF.md`, `AZ_EXPRESS_MARKETING_KIT.md`, `AZ_EXPRESS_LEGAL_ADMIN_PACK.md` — tous rédigés, prêts à l'usage.

### Entreprise — éléments à compléter

Statut légal de l'entreprise (immatriculation à vérifier/obtenir, voir `AZ_EXPRESS_LEGAL_ADMIN_PACK.md`), numéro WhatsApp/téléphone officiel (encore en placeholder dans le kit marketing), les 6 rôles d'équipe pas encore formellement pourvus, contrats partenaires/livreurs pas encore signés (modèles prêts, signature à faire une fois validée juridiquement).

---

## 2. Priorités fondateur

### 🔴 Urgent

1. Résoudre le blocage Google Cloud Billing.
2. Déployer les Cloud Functions restantes, dans l'ordre déjà planifié (`AUDIT_FINAL.md` Section 38 — règles d'abord, puis Lot 1 système → Lot 2 dispatch → Lot 3 argent → Lot 4 reste).
3. Faire un test réel complet (commande → livreur → livraison → paiement) une fois déployé — jamais encore vérifié en conditions de production réelles.

### 🟡 Avant lancement

- Recruter et former au moins 5 livreurs (`AZ_EXPRESS_COMPANY_MANUAL.md` section 2).
- Recruter les premiers partenaires (1 restaurant, 1 pharmacie, boutique approvisionnée, quelques vendeurs marketplace).
- Activer le canal support réel (WhatsApp/téléphone).
- Créer les données terrain (zones restantes, comptes réels) — voir `AZ_EXPRESS_COMPANY_MANUAL.md` section 7.

### 🟢 Après lancement

- Croissance progressive (Phase 2, voir section 6 ci-dessous).
- Amélioration continue guidée par l'usage réel, pas par anticipation (voir règle fondateur, section 7).

---

## 3. Tableau de contrôle quotidien

*(Version condensée pour le fondateur — le détail écran-par-écran est dans `OPERATIONS_RUNBOOK.md` section 1, à suivre par l'admin opération au quotidien.)*

### Chaque matin

- [ ] Commandes en attente depuis la nuit
- [ ] Livreurs disponibles/suspendus
- [ ] Partenaires actifs
- [ ] Tickets support ouverts
- [ ] Argent : cash marchand non réglé de la veille

### Chaque soir

- [ ] Cash marchand réglé (`admin_cash_settlement_page.dart` revenu à zéro)
- [ ] Incidents de la journée traités ou en cours
- [ ] Performances du jour (commandes livrées, commissions, anomalies)

---

## 4. Indicateurs à suivre

**Aucune valeur actuelle n'est indiquée ci-dessous — le service n'a pas encore été lancé publiquement, tous les chiffres réels partent de zéro au jour du lancement.** Ce tableau définit *quoi* suivre dès l'ouverture, pas des résultats déjà obtenus.

| Catégorie | Indicateurs à suivre | Où |
|---|---|---|
| **Clients** | Inscriptions, commandes passées | Firebase Console (Auth) / `admin_orders.dart` |
| **Livreurs** | Comptes actifs, courses terminées | `drivers_page.dart` / `admin_drivers_ranking.dart` |
| **Partenaires** | Comptes actifs, commandes reçues | Écrans admin par type de partenaire |
| **Finance** | Revenus (commissions + abonnements + marge Boutique), écarts wallet | `admin_commissions_page.dart` / `admin_earnings.dart` / `wallet_reconciliation_findings` (auto, hebdo) |

---

## 5. Risques à surveiller

### Technique

- Coûts Firebase/Google Maps à surveiller dès que le volume grandit (voir `OPERATIONS_RUNBOOK.md` section 2 et 6 pour les seuils précis).
- Bugs — suite de tests solide (159/159) mais jamais encore éprouvée en conditions réelles de production.

### Terrain

- Fiabilité et rétention des livreurs.
- Qualité et régularité des partenaires (rupture de stock, retard de préparation).
- Réactivité du support — canal encore à activer réellement.

### Business

- Adoption utilisateurs à construire de zéro (marché non habitué à ce type de service à Abengourou).
- Concurrence potentielle si un acteur déjà présent à Abidjan étend sa couverture.

*(Détail complet et honnête de chaque risque : `AZ_EXPRESS_INVESTOR_BRIEF.md` section 7.)*

---

## 6. Feuille de route

| Phase | Contenu | Statut |
|---|---|---|
| **Phase actuelle** | Pré-lancement — code freeze, documentation complète, en attente du déblocage Google Cloud | 🔴 En cours |
| **Phase suivante** | Pilote Abengourou — démarrage restreint, validation du parcours complet | ⏳ Prêt à démarrer dès déblocage |
| **Après validation** | Extension — croissance sur la ville puis expansion régionale, décision données-driven | ⏳ Non engagée |

---

## 7. Règle fondateur

> **Avant lancement : « Stabilité avant nouvelles fonctionnalités. »**
> Ne rien ajouter au produit tant que le pilote n'a pas prouvé que ce qui existe déjà fonctionne de façon fiable en conditions réelles.

> **Après lancement : « Écouter les utilisateurs avant de construire. »**
> Toute nouvelle fonctionnalité doit répondre à un besoin réel observé sur le terrain, pas à une anticipation — cohérent avec la discipline déjà appliquée tout au long de l'audit technique de ce projet (« ne pas optimiser par théorie »).
