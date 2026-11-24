# Pilote Restaurant v2 — procédure de préproduction (Mission 7E-2)

Document d'exploitation. **Rien ici n'est exécuté automatiquement** : chaque étape est lancée par une personne autorisée, sur le projet de **préproduction** (jamais directement sur `az-express-b0469`). On ne suppose **pas** que fonctions, règles ou index sont déjà déployés en préproduction : chaque étape les vérifie.

Principe : la création de commandes v2 est fermée par défaut. Elle ne s'ouvre que si **trois** conditions sont réunies : variable d'environnement `PARTNER_ORDERS_V2=on`, `config/partnerOrdersV2.creationOpen == true`, restaurant présent dans `pilotPartnerIds`. Fermer l'une d'elles suffit à arrêter les nouvelles commandes.

## 0. Pré-requis

- Un projet Firebase de préproduction distinct (alias dans `.firebaserc`), un compte **super-administrateur** de préproduction, un restaurant de test, un client de test, un livreur de test avec wallet alimenté en monnaie de test.
- Aucun vrai paiement : uniquement des soldes de test.
- Sauvegarde/export Firestore de préproduction avant le premier déploiement (si elle contient des données utiles).

## 1. Quotas Cloud Run (CPU régional)

1. Console GCP → Cloud Run / Quotas, région `europe-west1` : noter le quota « CPU » et l'usage actuel.
2. Calculer Σ(cpu × maxInstances) des fonctions déployées (`firebase functions:list --json` sur le projet de préproduction).
3. Ajouter la charge des fonctions v2 à déployer (`partnerOrderActionCF`, devis et création : 0,5 CPU × 2 instances chacune).
4. **Stop** si le total dépasse le quota : réduire d'abord cpu/maxInstances des fonctions secondaires (jamais AZ IA, paiements, wallet, dispatch). Une fonction qui échoue au déploiement pour quota ne doit pas être relancée en boucle.

## 2. Index Firestore

Ne pas supposer leur présence. Vérifier : `firebase firestore:indexes --project <preprod>` et comparer à `firestore.indexes.json`.

- Requis par les écrans v2 : `orders(amountsVersion, status, partnerAcceptedAtMs)`.
- La liste « Incidents paiement cash » n'exige **aucun** index composite (égalité unique sur `cashPayment.verification`, index mono-champ automatique).
- La liste des reversements livreur (égalités `amountsVersion`, `paymentMethod`, `merchantCashSettled`) n'exige pas d'index composite (égalités seules).
- Déployer les index s'ils manquent, puis **attendre l'état READY** avant la suite.

## 3. Ordre de déploiement (préproduction uniquement, sur décision explicite)

1. `firebase deploy --only firestore:rules --dry-run` puis déploiement des règles.
2. Index (§2), attendre READY.
3. Cloud Functions (les fonctions v2 d'abord, après contrôle du quota §1).
4. Application Flutter (build interne) — **après** le backend, jamais avant.

Après chaque étape : vérifier `firebase functions:list` / console, et lire les journaux de déploiement.

## 4. Variables d'environnement

Dans `functions/.env` du projet de préproduction (fichier gitignoré, jamais committé) :

- `PARTNER_ORDERS_V2=on` — autorise la création v2 (reste sans effet tant que `creationOpen` est faux).
- `PARTNER_ORDERS_V2_MANAGE` : laisser absent ou `on` ; `off` = gel serveur (kill-switch par environnement, redéploiement nécessaire).

Redéployer les fonctions après toute modification de `.env`.

## 5. Versions minimales de l'application

- Vérifier la version minimale exigée (`MinVersionService` / config associée) : les applications restaurant, livreur et client du pilote doivent contenir les écrans v2 (commandes restaurateur, parcours livreur, reversement cash, paiement cash 7D-6).
- Ne pas ouvrir le pilote tant que l'application du restaurant pilote n'est pas à jour sur ses appareils.

## 6. État initial attendu (vérification)

Outil : Administration → **Pilote restaurants v2** (super-administrateur).

- Création : **FERMÉE**, gel : « Aucun gel », aucun restaurant pilote, version 0 (ou valeur existante inchangée).
- Un compte non super-administrateur n'a pas l'entrée de menu ; si l'écran est atteint, le serveur refuse (« Réservé à l'administrateur principal »).

## 7. Ouvrir UN seul restaurant pilote

1. Pilote restaurants v2 → saisir l'identifiant Firestore du restaurant → « Ajouter ce restaurant » → motif (10–300 caractères) → confirmer. La création reste **fermée**.
2. Vérifier que la version a augmenté et que l'audit (`audit_logs`) contient avant/après.
3. « Ouvrir la création » → motif → confirmer.
4. Vérifier : seul ce restaurant peut recevoir une commande v2 ; un autre restaurant reste refusé.

Si « Configuration modifiée entre-temps » (CONFIG_CONFLICT) : l'écran se met à jour, relire puis recommencer ; ne jamais forcer.

## 8. Scénarios de test (préproduction, montants de test)

Wallet :
1. Devis → création (wallet) : un seul débit client du montant total ; `productAmount` → restaurant, `deliveryFee` → livreur ; aucun doublon sur double appui.
2. Restaurant : accepter → préparer → « prête ». Livreur : récupération **refusée avant « prête »** (aussi par QR/PIN) ; acceptée après.
3. Livraison : statuts et soldes cohérents ; `audit_logs` présents.

Cash :
1. Création cash : `isPaid:false`, aucun mouvement de wallet.
2. Livraison « payé » : reversement `pending` → livreur déclare → restaurateur confirme (cas nominal).
3. Contestation du restaurateur → décision administrative (Régulariser) : montant final borné, journalisé.
4. Livraison « non payé » (motif 10–300) : incident visible dans **Incidents paiement cash** ; examen (confirmer/infirmer) par le super-administrateur ; l'incident reste listé tant qu'il n'est pas examiné, **même si le reversement est clos**.
5. Vérifier que l'examen ne modifie aucun montant ni wallet (distinct de la résolution du reversement).
6. Plus de 50 incidents : « Afficher plus d'incidents » élargit la fenêtre.

## 9. Incident : fermer immédiatement

Dans l'ordre, sans attendre l'analyse :
1. Pilote restaurants v2 → **Fermer la création** (motif, par ex. « Fermeture du pilote »). Effet immédiat sur les nouvelles commandes.
2. Si les actions sur commandes en cours posent problème : **Activer le gel d'urgence** (bloque les actions de gestion v2 ; les consultations restent possibles).
3. Option de dernier recours : `PARTNER_ORDERS_V2=off` / `PARTNER_ORDERS_V2_MANAGE=off` puis redéploiement des fonctions.
4. Ne pas supprimer ni modifier de commandes à la main ; traiter les cas ouverts (reversements, incidents) via les outils administrateur.

## 10. Retour à la configuration fermée

1. Créer­tion fermée, gel levé uniquement après analyse, restaurants retirés de la liste (« Retirer »), chaque changement avec motif.
2. Vérifier l'état final : création FERMÉE, aucun pilote, version incrémentée, audits présents.
3. Traiter tous les incidents « à examiner » restants avant de clôturer le test.

## Risques à connaître

- L'ouverture exige les trois conditions ; l'écran ne montre que `config/partnerOrdersV2`, pas la variable d'environnement : vérifier `.env` séparément.
- Les règles actuelles laissent le **super-administrateur** libre sur `orders` (branche `isAdmin`) : l'application n'écrit jamais `cashPayment`, mais ce n'est pas une garantie des règles. Décision de durcissement à prendre séparément.
- Qui supporte la perte d'un non-paiement confirmé reste une décision business ouverte.
- Aucune de ces étapes n'a été exécutée : tout est à valider en préproduction.
