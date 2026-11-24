# Confidentialité des livreurs : plan de migration `driver_public`

**Plan seulement. Rien n'est implémenté ni déployé.** Principe validé : une collection publique minimale `driver_public/{uid}`, puis fermeture de la lecture de `livreurs`. Détail de l'audit des lectures : `docs/ADMIN_SECURITY_S5_S8.md` (S6).

## 1. Problème et objectif

`livreurs/{id}` est lisible par tout utilisateur connecté, anonymes compris. Le document porte `wallet`, `phone`, `fcmToken`, `pendingOrderId`, état administratif, etc. Objectif : plus aucun de ces champs lisible hors propriétaire et administrateurs autorisés, **sans interrompre** GPS, dispatch, suivi, ni les anciennes versions.

## 2. Données : qui voit quoi

| Champ | `driver_public` (tout utilisateur connecté) | `livreurs` après fermeture (propriétaire + admin) | Autres (client, partenaire) |
|---|---|---|---|
| prénom ou nom affiché, photo, véhicule | oui | oui | oui, via `driver_public` |
| `lat`, `lng`, `heading`, `speed`, `updatedAt` | oui | oui | oui, via `driver_public` |
| `isOnline`, `isAvailable`, `isOnDelivery` | oui | oui | oui |
| `avgRating`, `ratingCount` | oui | oui | oui |
| **`wallet`** et sous-collection `wallet_transactions` | **jamais** | oui | non |
| **`phone`** | **jamais** | oui | seulement pour le client dont la commande est assignée (voir §4) |
| **`fcmToken`, `token`, jetons d'appareil** | **jamais** | propriétaire seul | non (envois côté serveur uniquement) |
| `isSuspended`, `deletionRequested`, `ownerId`, KYC, pièces | **jamais** | propriétaire (lecture) + admin | non |
| `pendingOrderId`, `currentCityId` | non | oui | non (dispatch = serveur) |

Règle de conception : `driver_public` est construit par **liste blanche** de clés. Un champ ajouté plus tard à `livreurs` n'y apparaît jamais par défaut.

## 3. Règle cible (étape finale seulement)

```
match /driver_public/{uid} {
  allow read:   if isAuth();                       // carte client, suivi, partenaires
  allow create, update: if isOwner(uid) && isRealUser()
      && request.resource.data.keys().hasOnly([...liste blanche...])
      && <types et bornes de lat/lng/heading/speed>;
  allow delete: if isAdmin();
}
match /livreurs/{id} {
  allow read: if isOwner(id) || isAdmin() || hasAdminPermission('livreurs');
  // écritures inchangées
}
```
La lecture de `driver_public` reste « tout utilisateur connecté » : c'est volontaire (carte des visiteurs anonymes). Ce document ne contient rien de confidentiel.
Écriture par le livreur : la liste blanche interdit `wallet`, téléphone, jetons. Le serveur (Admin SDK) n'est pas concerné par les règles.

## 4. Compatibilité fonctionnelle, point par point

| Fonction | Mécanisme actuel | Impact et traitement |
|---|---|---|
| **GPS livreur** | l'application écrit `livreurs/{id}` (`lat`, `lng`, `heading`, `speed`) toutes les quelques secondes | **Double écriture** : `livreurs` (inchangé, source du dispatch) **et** `driver_public` (copie des seuls champs publics) dans le même appel (batch de 2 documents). Pas de Cloud Function déclenchée à chaque position : coût, latence et quota Cloud Run (déjà serré). Si la copie échoue, `livreurs` est écrit quand même : le dispatch ne dépend jamais de `driver_public` |
| **Dispatch** | Cloud Function (Admin SDK) lit `livreurs` (`isOnline`, `currentCityId`, position) | **Aucun changement** : les règles ne s'appliquent pas au serveur ; il continue de lire `livreurs`. `driver_public` n'est jamais une source du dispatch |
| **Suivi de commande (client)** | `customer_tracking_screen`, `tracking_service`, `realtime_tracking_service` lisent `livreurs/{driverId}` | Lecture de `driver_public/{driverId}` à la place (nom, photo, note, position). Les services de suivi gardent leur contrat d'événements : seul le chemin de lecture change |
| **Téléphone du livreur pour le client** | lu dans `livreurs.phone` | À fournir autrement : champ `driverPhone` posé **par le serveur** sur la commande à l'attribution (champ additif, absent des anciennes commandes), lisible par le client propriétaire de la commande. À implémenter dans la fonction d'attribution après validation ; à vérifier au préalable que l'application n'en a pas déjà une copie |
| **Tableaux de bord partenaires** (vendeur, pharmacie, boulangerie) | lisent `livreurs/{driverId}` (nom, téléphone, en ligne) | `driver_public` pour le nom / l'état ; le téléphone via la commande (même champ serveur) |
| **Carte client / visiteurs anonymes** | `where isOnline == true` sur `livreurs` | requête équivalente sur `driver_public` (index `isOnline` simple) |
| **Estimation de proximité** (`destination_picker`) | idem | idem |
| **Admin** (liste, classement, recharge) | lecture directe | inchangé (`isAdmin` / permission `livreurs`) |
| **Notifications** | envoi serveur avec le jeton lu par l'Admin SDK | inchangé ; le jeton n'est jamais exposé |
| **Notation (R1/F1)** | écrit `livreurs.avgRating/ratingCount` côté serveur | la fonction doit aussi mettre à jour `driver_public` (même transaction) : **à ajouter à `driverRatings.js` avec test** avant l'étape 5. Entre-temps `driver_public` peut porter une note en retard |

## 5. Étapes (chacune réversible, aucune interruption)

| # | Étape | Déploiement | Retour arrière | Casse quelque chose ? |
|---|---|---|---|---|
| 0 | Pré-requis : version minimale (voir §6), mesure de l'adoption des builds | aucun | — | non |
| 1 | Règle **additive** `driver_public` (lecture connectés, écriture propriétaire sur liste blanche). `livreurs` inchangé | règles | retirer le bloc | non (nouvelle collection) |
| 2 | **Rattrapage** (script serveur Admin SDK, une fois, idempotent) : crée `driver_public` pour chaque livreur existant à partir de la liste blanche. Journal du nombre de documents. Exécutable à blanc d'abord (comptage) | script, sans déploiement de fonction | supprimer la collection `driver_public` | non |
| 3 | Nouvelle application livreur : double écriture GPS/état. `driver_public` se met à jour au fil des connexions | version applicative | l'ancienne version continue d'écrire `livreurs` seul | non |
| 4 | Nouvelles applications client / partenaire : lecture de `driver_public` (avec **repli** sur `livreurs` si le document est absent ou si `permission-denied` n'est pas encore appliqué). Champ `driverPhone` serveur sur les commandes | version applicative + fonction d'attribution | revenir à la lecture `livreurs` | non (repli) |
| 5 | **Observation** : mesurer, dans les journaux, le trafic de lecture de `livreurs` par des non-propriétaires / non-admins (instrumentation côté application : compteur d'un événement de repli). Condition de passage : repli < 1 % pendant 14 jours **et** version minimale atteinte | aucun | — | non |
| 6 | Fermeture : `livreurs` en lecture propriétaire + admin (+ permission `livreurs`) | règles | republier l'ancienne règle (immédiat) | **les anciennes versions qui lisent encore `livreurs` perdent suivi / carte** : d'où l'étape 5 |

La fermeture (étape 6) est la seule étape à risque. Elle n'a lieu que lorsque l'étape 5 montre que les anciennes versions ont disparu.

## 6. Anciennes versions Android et iOS

- **Livreurs** : `MinVersionService` existe déjà (`config/app_versions`, rôle `driver`, `minBuild`, `enforce`). Utilisable tel quel : recommandation d'abord, blocage (`enforce: true`) seulement à l'étape 6.
- **Clients et partenaires** : le mécanisme ne couvre que le rôle `driver` aujourd'hui. Il faut l'étendre (rôles `client`, `partner`) avant l'étape 6, ou accepter que les anciens clients perdent le suivi. Extension additive, sans effet tant que le document de configuration ne mentionne pas ces rôles.
- Sur le web (`go_router`), le déploiement d'une nouvelle version est immédiat : pas de problème d'ancienne version.
- iOS : la validation de l'App Store prend du temps ; la fenêtre de l'étape 5 doit en tenir compte (prévoir au moins deux cycles de publication).
- Aucune version déjà publiée n'est modifiée : tout reste valable tant que `livreurs` est lisible.

## 7. Garanties de confidentialité vérifiables (tests à écrire avant l'étape 1)

1. Test de règles : un utilisateur connecté (et un anonyme) lit `driver_public` ; ne peut **pas** y écrire ; un livreur n'écrit que sa propre fiche, sans clé hors liste blanche (`wallet`, `phone`, `fcmToken`, `isSuspended` refusés un par un).
2. Test unitaire : la fonction de projection ne produit jamais une clé hors liste blanche, quelle que soit la forme du document `livreurs` (y compris champs inconnus et imbriqués).
3. Test de règles (étape 6) : client, partenaire, anonyme, autre livreur refusés sur `livreurs/{id}` et sur `wallet_transactions` ; propriétaire, super-admin, sous-admin `livreurs` acceptés.
4. Test source : plus aucune lecture de `livreurs` par client / partenaire dans `lib/` (liste fermée des fichiers autorisés).
5. Test GPS : l'écriture double ne bloque pas l'écriture `livreurs` si `driver_public` échoue.

## 8. Risques et décisions attendues

- **Charge d'écriture** : 2 documents par position au lieu de 1. À mesurer ; si coûteux, n'écrire `driver_public` que toutes les N secondes ou si le déplacement dépasse un seuil (le client ne voit pas mieux qu'une position par ~5 s).
- **Cohérence** : `driver_public` peut être en retard de quelques secondes sur `livreurs`. Acceptable pour l'affichage ; jamais utilisé pour le dispatch ni un calcul d'argent.
- **Livreur non migré** (n'a pas rouvert l'application) : absent de la carte jusqu'à sa prochaine connexion (le rattrapage de l'étape 2 limite ce cas).
- **Numéro de téléphone du livreur** : c'est la seule donnée à re-fournir par un autre canal ; décision attendue sur le champ `driverPhone` serveur (ou un masquage / appel via l'application).
- Rien de ce plan n'est exécuté sans votre autorisation, étape par étape.
