# Audit de `AdminSellersPage` (comptes vendeurs)

Date : 2026-10-30. Fichier : `lib/screens/admin/admin_sellers_page.dart` (862 lignes). **Non rattachée au menu** (aucune entrée ne l'ouvre) ; rien n'a été modifié.

## 1. Fonctionnalités et chemin d'écriture de chacune

| Fonction de la page | Chemin d'écriture | Protection serveur | Verdict |
|---|---|---|---|
| Lister les vendeurs | lecture `sellers` | règle : super ou `demandes_vendeurs` | OK (mais trop large pour un sous-admin : S1 de l'audit des permissions) |
| **Créer** un vendeur | `AdminPartnerAccountService.create` → Cloud Function `manageAdminPartnerAccount` | `requireAdminPermission('demandes_vendeurs')` ou super ; compte Auth + profil créés côté serveur, reprenable ; mot de passe temporaire affiché une fois | **Sûr** |
| **Modifier** (nom, téléphone, type, activation, coordonnées) | écriture client `sellers/{id}.set(merge)` (6 champs) | règle `sellers` : super ou `demandes_vendeurs`, **sans liste de champs** | **Dangereux côté règle** : la page n'envoie que 6 champs, mais la règle accepte tout (`wallet`, abonnement…) |
| **Activer / suspendre** | écriture client `update({'isActive': …})` | même règle | Même défaut ; aucune trace dans `audit_logs` |
| **Supprimer** un vendeur | écriture client `delete` du document | règle : super seul | **Dangereux** : supprime le profil sans supprimer le compte Auth, les produits ni les commandes liés, sans journal d'audit, sans passer par le flux de suppression de compte du projet (`manualAccountDeletion` / `requestAccountDeletionCF`) |
| **Abonnement** (activer 1 000 F, gratuit, suspendre) et **VIP** (activer 2 000 F, gratuit, retirer) | Cloud Function `manageProfessionalSubscription` (actions admin) | `requireAdminPermission(ADMIN_PERMISSIONS[collection])`, identifiant d'opération idempotent (`requestId`), transaction, débit du wallet côté serveur | **Sûr** |
| Afficher le wallet | lecture seule | — | OK |

## 2. Opérations sur les wallets
- La page **n'écrit jamais** un wallet. À la création, `wallet: 0` n'est plus envoyé depuis le client (le profil est créé par la fonction serveur).
- Les débits liés à l'abonnement/VIP passent par une transaction serveur idempotente, avec écriture de la ligne `wallet_transactions` côté serveur.
- **Mais** la règle `sellers` autoriserait une écriture client directe du `wallet` par un sous-admin porteur de `demandes_vendeurs` : le risque ne vient pas de la page, il vient de la règle (S1).

## 3. Fonctionnalités absentes des autres écrans
Après comparaison avec `AdminSellerRequestsPage` (approbation des candidatures) et `AdminBoutiquePage` (produits/commandes) :
- **Uniques à cette page** : la liste des comptes vendeurs actifs, la modification de leur fiche, l'activation/suspension, et surtout la **gestion de l'abonnement et du VIP d'un vendeur** (les restaurants et boulangeries ont chacun la leur dans leur propre page).
- Elle est donc **encore utile** : sans elle, un super-admin n'a aucun écran pour suspendre un vendeur ou lui activer un abonnement.

## 4. Écritures directes dangereuses identifiées
1. Règle `sellers` sans liste blanche de champs (S1) — **critique**.
2. Suppression client sans nettoyage ni audit — **élevé**.
3. Activation/suspension et modification de fiche sans journal d'audit — moyen.
4. Coordonnées validées côté client uniquement (`PartnerLocationValidator`) ; aucune validation dans la règle — bas.

## 5. Corrections sécurisées proposées (avant rattachement)
1. **Règle `sellers`** : lecture par permission ; création interdite côté client ; mise à jour par `affectedKeys().hasOnly(['name','phone','type','isActive','lat','lng'])` ; `wallet`, `subscription*`, `vip*`, `plan`, `paymentStatus`, `isSuspended`, `status`, `deletionRequested` interdits au client pour les sous-admins.
2. **Nouvelle fonction** `manageSellerAccountCF` (enveloppe `{success, error, message, data, code}`) pour **activer/suspendre** et **modifier la fiche** : `requireAdminPermission('demandes_vendeurs')`, `checkRateLimit`, validation des coordonnées côté serveur, `logAudit`. La page l'appelle à la place des écritures directes.
3. **Suppression** : remplacer le bouton par une demande de suppression via le flux existant (compte, produits, commandes, Auth), ou la réserver au super-admin avec confirmation et audit ; ne plus supprimer le seul document.
4. Garder `manageProfessionalSubscription` tel quel (déjà conforme).
5. **Tests** : règles (sous-admin avec/sans permission, tentative d'écrire `wallet`), fonction (permission, rate-limit, audit), page (aucun appel Firestore direct restant).

## 6. Rattachement
Après validation de ces corrections : entrée « Comptes vendeurs » dans la catégorie *Partenaires et commerces* de `admin_menu.dart`, permission `demandes_vendeurs`. **Pas rattachée tant que vous n'avez pas validé cet audit.**

## 7. Corrections locales (2026-10-30) — page toujours NON rattachée au menu

- **Règle `sellers`** (S1) : l'édition de fiche (6 champs) et l'activation/suspension (`isActive`) restent possibles pour le super-admin et le sous-admin `demandes_vendeurs` ; wallet, abonnement, VIP, suspension, statut, plan : impossibles côté client pour un sous-admin. Création : serveur (`manageAdminPartnerAccount`) ou super-admin.
- **Suppression** : `delete()` retiré de la page. L'entrée de menu devient « Désactiver » (`isActive: false`, réversible, données conservées), avec message renvoyant vers la demande de suppression de compte pour une suppression définitive.
- **Erreurs** : une écriture refusée affiche maintenant un message (avant : `catch (_) {}` silencieux).
- **Tests** : `test/screens/admin/admin_sellers_page_security_test.dart` (pas de `.delete()`, aucun champ financier écrit, création/abonnement par fonctions serveur, 6 champs exactement, erreur visible) + `admin_sellers_wallet_test.dart` inchangé et réussi.
- **Reste avant rattachement** : journal d'audit des modifications/activations (demande une nouvelle fonction `manageSellerAccountCF`, non créée : décision requise), puis entrée de menu `demandes_vendeurs`.
