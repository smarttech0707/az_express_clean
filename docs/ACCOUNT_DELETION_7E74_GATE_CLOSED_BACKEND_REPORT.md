# Mission 7E-74 — Passerelle fermée : correction backend

Date : 2026-11-07 · HEAD `aa3d1b0` (inchangé) · Local uniquement : aucun commit, `git add`, `git apply --cached`, push, déploiement, commande distante ; `operations_control/account_deletion` jamais créé ; secrets et plafonds (P2, P3, production) inchangés.

## 1. Problème
Dans `requestAccountDeletionCF`, la passerelle n'était lue que dans `process()`. Avec configuration absente ou fermée, `request` créait quand même `account_deletions/{uid}`, un audit `account_deletion_requested`, et, pour un livreur réauthentifié, posait `deletionRequested: true` ; le client recevait « demande conservée ».

## 2. Correction (3 lignes de code, `functions/accountDeletion.js`, fonction `request`)
Placée après le contrôle `RATE_LIMITER_REQUIRED` et **avant** `checkRateLimit` et toute écriture :

```diff
   if(typeof checkRateLimit!=='function')throw new HttpsError('failed-precondition','RATE_LIMITER_REQUIRED');
+  // Mission 7E-74 : passerelle absente, fermée ou illisible => refus net AVANT toute écriture (aucun dossier, aucun marqueur
+  // deletionRequested, aucune quarantaine, aucun audit, aucune écriture du limiteur). Même condition que process() ; une erreur
+  // de lecture se propage : elle n'ouvre jamais la passerelle.
+  const gate=(await db.collection('operations_control').doc('account_deletion').get()).data();
+  if(gate?.enabled!==true || gate.inventoryVersion!==1)throw new HttpsError('failed-precondition','ACCOUNT_DELETION_NOT_ENABLED');
   await checkRateLimit(uid,'account_deletion_request',RATE_MAX,RATE_WINDOW_S);
```
Fins de ligne CRLF préservées. Le reste du fichier (limites, réauthentification, idempotence, audit, contrôles financiers, quarantaine, `process`, `status`, `drain`) est **inchangé**.

## 3. Comportement par cas
| Cas | Résultat | Écriture |
|---|---|---|
| A — document absent | `failed-precondition` / `ACCOUNT_DELETION_NOT_ENABLED` | aucune |
| B — `enabled !== true` ou `inventoryVersion !== 1` (y compris `'true'`, `'1'`, `{}`) | même erreur | aucune |
| C — lecture impossible | l'erreur de lecture se propage (la demande échoue) | aucune ; jamais d'autorisation implicite |
| D — configuration valide | comportement antérieur intact (voir tests) | comme avant |

L'erreur est identifiable : code `failed-precondition`, message `ACCOUNT_DELETION_NOT_ENABLED`.

## 4. Conséquences
- Un refus ne consomme pas le quota du limiteur (qui écrit dans `rate_limits`).
- Une lecture Firestore de plus par demande (même profil que `process`).
- Un dossier créé avant la fermeture n'est pas affecté ; son suivi (`getAccountDeletionStatusCF`) et ses reprises (`process`, `manageAccountDeletionCF`) gardent leur comportement (`server_rollout_not_enabled` y reste vrai, le dossier existe).
- Les rôles partenaires et la voie manuelle `account_deletion_requests` (web/artisan/événementiel) ne passent pas par cette fonction : inchangés.

## 5. Tests remplacés et ajoutés
**Remplacés (ils validaient l'ancien comportement « demande conservée »)** :
1. `functions/test/accountDeletionHardening.test.js` — « fermé par défaut : configuration absente, désactivée ou incorrecte = aucune suppression ».
2. `rules-tests/account-deletion.test.js` — « rollout disabled keeps truthful pending request and no tombstone ».

**Nouveaux (unitaires, faux Firestore)** — 6 tests :
- passerelle fermée × 7 configurations × rôles client et livreur : rejet identifiable ; **comparaison du magasin complet avant/après** (JSON de tous les documents) ; ni dossier, ni tombstone, ni `deletionRequested`, ni `isSuspended`, ni audit, ni appel au limiteur, ni appel Auth ;
- client avec demande antérieure : nouvelle demande refusée, dossier existant strictement identique ;
- livreur avec `deletionRequested: true` déjà présent : refus, valeur et profil inchangés ;
- passerelle illisible (la lecture lève) : échec sûr, magasin identique, aucun audit ni limiteur ;
- passerelle ouverte : dossier, tombstone, `deletionRequested` (livreur), audit, limiteur, puis répétition absorbée (`requestCount` reste 1, audit « repeated ») ;
- passerelle ouverte : refus du limiteur ⇒ aucune écriture.

**Nouveaux (émulateur Firestore/Auth, état réel relu)** — 7 tests dans `rules-tests/account-deletion.test.js` : absente / désactivée / version 2 × client et livreur (état des collections `account_deletions`, `account_tombstones`, `audit_logs`, `rate_limits`, `clients`, `livreurs` comparé avant/après), plus « fermeture après une première demande ».

**Preuve de nécessité** : avec l'ancien `accountDeletion.js`, les 4 tests de passerelle fermée échouent (22 réussis, 4 échecs) et les 2 tests « ouverte » passent (comportement préservé).

## 6. Mapping avec les 15 vérifications demandées
1 absente ✔ · 2 désactivée ✔ · 3 `inventoryVersion` ✔ · 4 erreur de lecture ✔ · 5 demande antérieure ✔ · 6 `deletionRequested` déjà présent ✔ · 7 aucune écriture ✔ · 8 aucun dossier ✔ · 9 aucun audit ✔ · 10 aucun tombstone ✔ · 11 aucune quarantaine ✔ · 12 profil inchangé ✔ · 13 ouverte + demande valide ✔ · 14 répétition/idempotence ✔ · 15 rate limiting ✔.

## 7. Limites
Faux Firestore (en mémoire) et émulateur : pas d'essai sur Firestore réel ; l'erreur de lecture est simulée. Le fichier `account-deletion-lifecycle`/`real`/`new-flows` n'ont pas nécessité de changement (ils ouvrent la passerelle dans `beforeEach`).
