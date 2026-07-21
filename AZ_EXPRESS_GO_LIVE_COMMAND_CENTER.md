# AZ Express — Centre de commande du lancement (Go-Live Command Center)

**Créé** : 2026-07-09 (Master Prompt 90, « Final Go-Live Command Center »).
**Objet** : le document unique à ouvrir le jour du déblocage Google Billing et le jour du lancement Abengourou — regroupe la séquence technique exacte et les checklists opérationnelles, pour ne pas avoir à naviguer entre plusieurs fichiers en plein déploiement. S'appuie sur ce qui est déjà planifié ailleurs (`AUDIT_FINAL.md` Section 38 pour le détail technique complet, `OPERATIONS_RUNBOOK.md` pour les procédures quotidiennes, `AZ_EXPRESS_COMPANY_MANUAL.md`/`AZ_EXPRESS_FOUNDER_DASHBOARD.md` pour le contexte humain) sans le redupliquer intégralement — les commandes critiques sont recopiées ici pour un usage direct en conditions réelles, le reste est référencé.

---

## 1. Jour de déblocage Google Billing — procédure minute par minute

### Avant de commencer — vérifications préalables

- [ ] **Compte de facturation actif** — Google Cloud Console → Facturation → confirmer que le compte est bien lié au projet `az-express-clean` et actif (pas juste "ajouté").
- [ ] **Projet Google Cloud correct** — `firebase use` doit pointer sur `az-express-clean` (vérifier `.firebaserc`), pas un des deux autres projets liés au même compte (déjà identifiés comme probablement abandonnés, Prompt 65).
- [ ] **APIs actives** — Cloud Build, Cloud Functions, Artifact Registry, Cloud Scheduler, Eventarc, Pub/Sub, Cloud Run (normalement activées automatiquement au premier déploiement réussi, mais à vérifier si une erreur d'API apparaît).

### Étape 1 — Règles de sécurité Firestore

```
firebase deploy --only firestore:rules --project az-express-clean
```

**Vérifier après** : message `+ cloud.firestore: rules file compiled and released successfully` dans la sortie. Confirmer dans la Console Firebase que la date de dernière publication des règles a changé. **C'est l'étape la plus importante à isoler** — elle ferme à elle seule 3 des 4 failles de sécurité déjà corrigées dans le code (Prompt 80) et ne dépend d'aucune Cloud Function.

### Étape 2 — Cloud Functions, Lot 1 (système, faible risque)

```
firebase deploy --only functions:fcmTokenCleanupCheck,functions:logAdminAuditEvent,functions:logAuthEvent,functions:pharmacieLogin,functions:setPharmaciePassword,functions:walletReconciliationCheck --project az-express-clean
```

**Vérifier après** : `firebase functions:list --project az-express-clean` → total passé de 30 à 36. Consulter les logs (`firebase functions:log --project az-express-clean` ou Console Cloud Logging) pendant 2-3 minutes — aucune erreur de démarrage à froid ne doit apparaître.

### Étape 3 — Cloud Functions, Lot 2 (dispatch)

```
firebase deploy --only functions:dispatchOrderToDriver --project az-express-clean
```

**Vérifier après** : total passé à 37. Logs propres.

### Étape 4 — Test dispatch réel

Créer une commande de test réelle (compte client de test, montant minimal) et confirmer qu'elle passe bien de `pending` à `assigned`/`broadcast` — **c'est la première vérification réelle que le dispatch fonctionne en production**, jamais testé en conditions réelles avant ce moment précis (seulement en tests unitaires). Ne pas passer à l'étape 5 tant que ce test n'est pas concluant.

### Étape 5 — Cloud Functions, Lot 3 (argent — le plus sensible)

```
firebase deploy --only functions:deliverOrderCF,functions:cancelOrderCF,functions:payOrderFromWalletCF,functions:payBoutiqueOrderCF,functions:payBoutiqueOrderCashCF,functions:refundExpiredBoutiqueOrderCF --project az-express-clean
```

**Vérifier après** : total passé à 43. Logs propres. **Ne jamais sauter cette vérification** : ce lot déplace de l'argent réel pour la toute première fois en production.

### Étape 6 — Test paiement réel

Sur la commande de test de l'étape 4 (ou une nouvelle) : faire accepter par un livreur de test, livrer, et tester **les deux modes de paiement** — cash (confirmer le statut `delivered` et l'apparition de `merchantCashSettled` si un marchand est concerné) et wallet (confirmer le débit client + le crédit correct du livreur/partenaire). **Le test wallet est la toute première vérification en conditions réelles du correctif de sécurité du Prompt 80** (garde `isPaid` avant tout crédit partenaire) — obligatoire, pas optionnel.

### Étape 7 — Cloud Functions, Lot 4 (reste des modules)

```
firebase deploy --only functions:aiCleanupExpiredPendingActions,functions:aiConfirmAction,functions:azIaChat,functions:clearAiHistory,functions:approveRealEstateAgentRequest,functions:notifyAgentOnVisitRequest,functions:notifyClientOnVisitUpdate,functions:requestPropertyVisit,functions:respondToVisitRequest,functions:submitRealEstateAgentRequest --project az-express-clean
```

**Vérifier après** : `firebase functions:list --project az-express-clean` → total **53/53**. C'est la confirmation finale que le déploiement est complet.

---

## 2. Validation backend final

**Objectif : 53/53 fonctions actives.** Une fois confirmé, tester chaque catégorie séparément avant d'ouvrir au public :

| Catégorie | Test |
|---|---|
| **Auth** | Connexion client (anonyme + email/mot de passe), connexion livreur, connexion admin (avec 2FA si numéro enregistré) |
| **Firestore** | Lecture d'une commande existante, écriture d'un nouveau document de test |
| **Storage** | Upload d'une photo de livraison (preuve), upload d'un selfie livreur |
| **Notifications** | Un push de test reçu sur un appareil réel (nouvelle commande, statut changé) |
| **Wallet** | `payOrderFromWalletCF` sur un compte de test, petit montant — débit + crédit corrects |
| **Dispatch** | Une commande de test assignée à un livreur réellement en ligne |
| **Livraison** | Cycle complet accepté→picked_up→delivered sur une commande de test |
| **Support** | Un ticket de test créé côté client, une réponse admin visible côté client |

---

## 3. Test réel avant ouverture — scénario complet

À dérouler une fois la Section 2 validée, avant toute annonce publique :

1. **Client test** — inscription complète (pas un compte déjà existant), puis passage d'une vraie commande (livraison simple, montant minimal).
2. **Livreur test** — réception de la notification, acceptation, trajet GPS/Maps réel, livraison marquée terminée avec photo de preuve.
3. **Admin** — suivi de la commande de bout en bout dans `admin_orders.dart`, vérification que l'argent apparaît correctement (`admin_commissions_page.dart`, `admin_cash_settlement_page.dart` si applicable), vérification qu'un ticket support de test est bien visible et traitable.
4. **Partenaire** — si la commande de test inclut un restaurant/pharmacie/boutique, confirmer la réception de la commande dans son propre tableau de bord, avec le bon montant.

**Ne pas ouvrir au public tant que les 4 points ci-dessus n'ont pas fonctionné sans intervention manuelle.**

---

## 4. Jour de lancement Abengourou — checklist

### Avant ouverture

- [ ] Livreurs connectés et en ligne (minimum 5, `AZ_EXPRESS_COMPANY_MANUAL.md`)
- [ ] Partenaires disponibles (`isOpen`/`isActive` confirmés)
- [ ] Support prêt (canal WhatsApp/téléphone réellement surveillé, pas juste configuré)
- [ ] Zones actives confirmées (`admin_zones_page.dart`)

### Pendant la journée

- [ ] Surveiller les commandes en direct (`admin_orders.dart`, bordure rouge = commande bloquée >1h)
- [ ] Surveiller les erreurs (Firebase Console → Functions Logs, Crashlytics)
- [ ] Surveiller les paiements (aucun blocage inhabituel sur le wallet/cash)

### Après la journée

- [ ] Bilan (commandes réalisées, incidents rencontrés)
- [ ] Cash (`admin_cash_settlement_page.dart` revenu à zéro)
- [ ] Incidents consignés pour ajustement du lendemain

*(Détail complet de la routine quotidienne au-delà du premier jour : `OPERATIONS_RUNBOOK.md` section 1.)*

---

## 5. Plan d'urgence

| Situation | Réaction |
|---|---|
| **Erreur Firebase** (Functions/Firestore en panne) | Vérifier Firebase Console → Status Dashboard (panne côté Google) vs Functions Logs (erreur côté code). Si panne Google : communiquer un délai aux clients/partenaires, pas de contournement à improviser. Si erreur de code : ne PAS tenter de correctif à chaud sans revalidation — le code freeze reste la règle, un vrai bug bloquant se corrige avec la même rigueur que le reste de cette session (test avant déploiement), pas en urgence non testée. |
| **Erreur Google Maps** (itinéraire/geocoding indisponible) | L'app dégrade déjà proprement vers une ligne droite si l'API échoue (déjà construit) — vérifier si c'est un quota dépassé (Google Cloud Console → APIs) ou une vraie panne. Pas d'action corrective code en urgence. |
| **Problème de paiement** | Isoler : cash (aucune dépendance technique, problème humain à traiter directement) vs wallet (vérifier `wallet_transactions` de l'utilisateur concerné avant toute promesse au client, voir `AZ_EXPRESS_COMPANY_MANUAL.md` section 5). |
| **Livreur absent** | Suivre la procédure incident déjà définie (`OPERATIONS_RUNBOOK.md` section 3) — vérifier GPS périmé, contacter par un second moyen, réassigner/annuler manuellement. |
| **Trop de commandes** (dépassement de capacité livreurs) | Ne pas désactiver la prise de commande en urgence sans réflexion — vérifier d'abord si des livreurs supplémentaires peuvent être mis en ligne rapidement ; en dernier recours, réduire temporairement la zone couverte plutôt que de laisser des commandes s'accumuler sans livreur. |
| **Partenaire indisponible** (ferme sans prévenir) | Vérifier `isOpen`/`isActive` sur son compte — le désactiver temporairement dans l'app pour éviter que de nouvelles commandes lui soient envoyées, contacter directement pour comprendre la situation. |

---

## 6. Décision GO / NO GO

### Conditions GO (toutes obligatoires)

- [ ] Facturation Google Cloud Billing débloquée et confirmée stable
- [ ] `firestore.rules` déployées avec succès
- [ ] `firebase functions:list` confirme **53/53**
- [ ] Section 2 (validation backend) entièrement passée sans échec
- [ ] Section 3 (test réel de bout en bout) entièrement réussi sans intervention manuelle
- [ ] Au moins 5 livreurs formés et connectés
- [ ] Au moins 1 restaurant + 1 pharmacie + Boutique AZ approvisionnée actifs
- [ ] Canal support réellement surveillé (pas juste configuré)

### Conditions NO GO (une seule suffit à repousser l'ouverture)

- ❌ Facturation Google Cloud toujours bloquée, ou instable (erreurs intermittentes)
- ❌ Un seul des 4 lots de Cloud Functions échoue au déploiement
- ❌ Le test paiement wallet (Section 1, Étape 6) échoue ou produit un montant incorrect — **jamais ouvrir avec ce test non concluant**, c'est le correctif de sécurité financière le plus important de tout le projet
- ❌ Moins de 5 livreurs réellement disponibles
- ❌ Aucun partenaire actif au moment de l'ouverture
- ❌ Canal support non fonctionnel

**En cas de NO GO** : ne pas forcer l'ouverture pour respecter une date annoncée — revenir à la Section 1 à l'étape qui a échoué, corriger, et redérouler la validation depuis cette étape avant de retenter.
