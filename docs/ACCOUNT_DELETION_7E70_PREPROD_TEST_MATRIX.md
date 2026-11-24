# Mission 7E-70 — Matrice de tests de préproduction (suppression de compte)

Date : 2026-11-06 · Projet `az-express-preprod` uniquement. **Plan seulement : aucun compte ni document n'a été créé, aucun test exécuté en préproduction.** Création de comptes, écritures de données de test et activation de la configuration exigent chacune une autorisation distincte (plan de déploiement, phases P4/P5).

## 1. Règles d'exécution

- Préfixe `t7e-del-` pour **tous** les UID, téléphones `+2250700000xxx`, soldes fictifs. Ne jamais utiliser : `t7e-client`, `t7e-intrus`, `t7e-driver`, `t7e-admin`, `t7e-resto`, ni les deux profils livreurs non `t7e-` déjà présents (pilote Restaurant v2, fermé).
- Chaque scénario part d'un compte **neuf** ou explicitement réinitialisé : la limite de 5 demandes/heure (`rate_limits`) et le compteur du dossier persistent.
- Horloge réelle : quarantaine **15 min**, reprise `retryAccountDeletions` toutes les **15 min** → un parcours complet dure ≈ 15 à 45 min. Pas de manipulation d'horloge.
- FeexPay `DISABLED` : le vérificateur serveur échoue fermé, **aucun crédit réel n'est possible** ; aucune API de paiement n'est appelée.
- `held_for_review` : **mécanisme de résolution non terminé** (aucun outil admin). Les essais qui produisent ce statut laissent un document à nettoyer manuellement par l'exploitant préproduction ; la résolution n'est **pas** testée et ne doit pas être présentée comme fonctionnelle.
- Critère global PASS : résultat attendu obtenu **et** aucune écriture hors des comptes `t7e-del-*` **et** invariants financiers intacts (§4).

## 2. Comptes synthétiques

| ID | UID | Contenu |
|---|---|---|
| A1 | `t7e-del-client-ok` | client, `wallet:0`, historique d'`orders` en statut terminal (`delivered`), aucune opération en cours |
| A2 | `t7e-del-client-solde` | client, `wallet:5000` |
| A3 | `t7e-del-client-retrait` | client, `wallet:0`, profil `pendingWithdrawal:2000` **et** document `withdrawal_requests` non terminal (`userId`) |
| A4 | `t7e-del-client-commande` | client, `wallet:0`, une `orders` en `accepted` (non terminal) ; variante : profil `isOnDelivery:true` (livreur) |
| A5 | `t7e-del-multi` | **même UID** dans `clients` et `livreurs` |
| A6 | `t7e-del-client-ia` | client, `wallet:0`, `ai_conversations/{uid}` + sous-collection `messages`, `ai_user_memory/{uid}`, `ai_reminders` (champ `uid`), `ai_pending_actions` au statut `pending` (expiration future), `ai_consents/{uid}` |
| A7 | `t7e-del-admin` | document `admins/{uid}` **+** profil client (jamais `t7e-admin`) |
| A8 | `t7e-del-client-existant` | client avec dossier `account_deletions/{uid}` déjà créé : variante 8a `requestCount:9` ; 8b `reason:'max_attempts_reached'` ; 8c `state:'quarantined'` |
| A9 | `t7e-del-temoin` | client `wallet:5000`, jamais concerné (contrôle d'absence d'effet de bord) |
| A10 | `t7e-del-superadmin`, `t7e-del-soutien` | un super-administrateur actif, un sous-administrateur **sans** permission de suppression |
| A11 | `t7e-del-livreur` | livreur `wallet:0` (variante de A1 pour le chemin livreur, `deletionRequested`) |

Création : script unique, projet fixé en dur à `az-express-preprod`, refus de tout identifiant contenant `b0469` ou `clean`, ajout uniquement des documents ci-dessus. Utilisateurs Auth créés via l'Admin SDK (jeton récent obtenu par connexion de test).

## 3. Scénarios

Légende exécutabilité : **PRÉ** = exécutable de bout en bout en préproduction ; **PAR** = partiel en préproduction (limite précisée) ; **LOC** = non reproductible honnêtement en préproduction, couvert par les tests locaux (émulateur) cités. Phase : P1 = fonctions de suppression, P2 = gardes, P4 = config activée.

| # | Scénario | Données | Action | Résultat attendu | Traces à contrôler | PASS / FAIL | Exéc. / phase |
|---|---|---|---|---|---|---|---|
| 1 | Demande avec réauthentification récente (`auth_time` ≤ 300 s) | A1 | `requestAccountDeletionCF({role:'client', recoveryToken, allProfilesConsent:true})` juste après connexion | `consentVerified:true`, traitement lancé ; **avant P4** : `pending` + `server_rollout_not_enabled`, aucun tombstone ; **après P4** : inspection OK → `quarantined`, tombstone créé, profil `isSuspended:true` | `account_deletions/{uid}`, `account_tombstones/{uid}`, `audit_logs` action `account_deletion_requested` (`reauthenticated:true`) | PASS : états exacts, Auth intact pendant la quarantaine. FAIL : tombstone avant P4, ou suppression Auth immédiate | PRÉ / P1 (+P4 pour la quarantaine) |
| 2 | Demande nécessitant une nouvelle authentification (jeton > 300 s) | A1' (neuf) | même appel avec jeton vieilli ; puis nouvel appel après reconnexion | 1er appel : `pending`, `reason:'reauthentication_required'`, `consentVerified:false`, `nextAttemptAt:null`, **aucun traitement** ; 2e appel (info nouvelle) **non absorbé** → `consentVerified:true`, reprise | dossier avant/après, audit `account_deletion_requested` ×2 | PASS : aucun tombstone tant que non réauthentifié. FAIL : traitement sans réauthentification | PRÉ / P1 |
| 3 | Requête répétée dans les 60 s | A1'' (neuf) | 2 appels identiques à < 60 s d'écart | 2e appel **absorbé** : même état renvoyé, `requestCount` inchangé, audit `account_deletion_request_repeated` | `requestCount`, `lastRequestAt`, audit | PASS : un seul dossier, compteur +0, aucune seconde quarantaine. FAIL : doublon de dossier / tombstone | PRÉ / P1 |
| 4 | Limite de 5 demandes par heure | A1''' (neuf) | 6 appels dans l'heure (espacés > 60 s ou non : le compteur `rate_limits` est incrémenté **avant** l'absorption) | les 5 premiers acceptés (ou absorbés), le 6e refusé `resource-exhausted` par le limiteur | `rate_limits` (action `account_deletion_request`), réponse d'erreur | PASS : refus au 6e. FAIL : 6e traité | PRÉ / P1 |
| 5 | Limite de **10 demandes cumulées par dossier** (distincte des **6 échecs techniques** `MAX_ATTEMPTS`) | A8a (`requestCount:9`) | 2 demandes espacées > 60 s | la 1re passe (`requestCount`→10), la 2e : `resource-exhausted` `ACCOUNT_DELETION_REQUEST_LIMIT` | dossier, réponse | PASS : refus à partir de 10. FAIL : dépassement. Le plafond de 6 échecs est vérifié par 8b + scénario 20 | PRÉ (graine du compteur par écriture : autorisation) / P1 |
| 6 | Compte administrateur refusé | A7 ; variante : dossier pré-existant puis ajout de `admins/{uid}` | demande ; puis `process`/reprise | demande : `failed-precondition` `ADMIN_ACCOUNT_MANUAL_PROCESS`, **aucun dossier créé** ; variante : `state:'blocked'`, `reason:'admin_account_manual_process'`, jamais de quarantaine ni de suppression Auth | absence de dossier, `reviewRequired`, Auth intact | PASS : compte intact. FAIL : tombstone / Auth supprimé | PRÉ / P1+P4 |
| 7 | Solde non nul bloquant | A2 | demande réauthentifiée, config activée | `blocked`, `reason:'balance_regularization_required'`, `reviewRequired:true`, **aucun tombstone**, solde 5000 intact | dossier, `clients/{uid}.wallet`, audit `account_deletion_blocked` | PASS : solde inchangé, Auth intact | PRÉ / P4 |
| 8 | Retrait en attente bloquant | A3 | idem | `blocked` : `balance_regularization_required` (champ profil `pendingWithdrawal`) ou `active_or_unresolved_operation` (`withdrawal_requests` non terminal) ; aucun tombstone | dossier, `withdrawal_requests` inchangé | PASS : retrait non touché. FAIL : tombstone ou suppression | PRÉ / P4 |
| 9 | Commande non terminée bloquante | A4 (+ variante `isOnDelivery`) | idem | `blocked` : `active_or_unresolved_operation` (commande non terminale) / `active_mission_or_reference` (mission) ; aucun tombstone | dossier, `orders/{id}` inchangé | PASS : commande intacte | PRÉ / P4 |
| 10 | Compte multirôle | A5 | idem (rôle `client`) | `blocked`, `reason:'multiple_roles_manual_review'`, aucune suppression Auth (l'identité partagée n'est pas détruite) | dossier, `livreurs/{uid}` intact | PASS : les deux profils intacts | PRÉ / P4 |
| 11 | Nettoyage des données AZ IA | A6, rôle client, config activée, **sans** blocage | demande, quarantaine, reprise jusqu'à `completed` | supprimés : `ai_conversations/{uid}` (+ `messages`), `ai_user_memory/{uid}`, `ai_reminders` du `uid`, `ai_pending_actions` aux statuts effaçables. **Conservés volontairement (à valider juridiquement)** : `ai_consents/{uid}`, `ai_pending_actions` `completed`, `ai_tool_executions`. Une sous-collection inconnue sous `ai_conversations` **bloque** le dossier avant la suppression Auth | présence/absence des documents, audit `account_deletion_completed`, aucun `ai_*` d'un autre UID touché | PASS : exactement ce périmètre. FAIL : donnée d'un autre compte, ou suppression Auth malgré donnée inconnue | PRÉ / P4 |
| 12 | Blocage des opérations pendant la quarantaine | A1 en `quarantined` ; A9 témoin | tentatives : `initiateFeexPayPayment`, `initiateWithdrawal` (A1) ; mêmes opérations pour A9 | A1 : refus « Compte supprime ou en cours de suppression » (`failed-precondition`), **aucun** `wallet_transactions` / `withdrawal_requests` créé ; A9 : fonctionnement normal (la recharge échoue seulement faute de FeexPay, sans lien avec la suppression) | absence de nouveaux documents pour A1, audit | PASS : A1 refusé, A9 non dégradé. FAIL : document créé pour A1, ou A9 bloqué | PRÉ / P2+P4 |
| 13 | Action AZ IA préparée **avant** la quarantaine | A6' : `ai_pending_actions` `pending` créé avant la demande (écriture directe, aucun appel modèle) | demande → quarantaine ; puis `aiConfirmAction` | confirmation **refusée**, action non exécutée, statut non passé à `completed` | `ai_pending_actions/{id}` inchangé, aucune écriture financière | PASS : jamais exécutée après le tombstone | PRÉ / P2+P4 (logique prouvée en local : tests B/B2) |
| 14 | Paiement FeexPay initié **avant** la quarantaine | A1b : `wallet_transactions` `pending` créé **avant** (écriture directe) | quarantaine, puis webhook | FeexPay `DISABLED` ⇒ vérificateur échoue fermé : **aucun crédit**. La branche « crédité puis suppression bloquée (`balance_regularization_required`) » est prouvée **localement uniquement** | réponse du webhook, solde inchangé | PASS : aucun crédit ni solde négatif. **Ne pas présenter la branche crédit comme validée en préproduction** | **PAR** / P2 — LOC : `accountQuarantineGuards`, concurrence C1-C3 |
| 15 | Paiement FeexPay initié **après** la quarantaine | A1c : tombstone existant, `wallet_transactions` créé **après** (écriture directe) | webhook (vérificateur désactivé) | idem 14 en préproduction ; le statut **`held_for_review`** (`needsReview:true`, `credited:false`, événement `webhook_paid_account_in_deletion`) n'est atteignable en préproduction que par écriture directe du statut : à étiqueter « simulé » | audit `payment_held_account_deletion` (local) | **PAR** : critères de rétention prouvés en local. Résolution du statut : **non couverte (outil absent)** | **PAR** / P2 — LOC : `feexpayPayments.test`, `accountQuarantineGuards` |
| 16 | Webhook reçu **après** anonymisation | A1d : profil `isDeleted`, document de paiement antérieur | webhook | local : mise en attente `profile_anonymized`, 200, aucun crédit ; préproduction : même limite que 14 | solde, `wallet_transactions/{id}`, audit (local) | PASS : aucun crédit après anonymisation, aucune écriture sur le profil anonymisé. Branche de mise en attente prouvée en local seulement | **PAR** / P2 — LOC : `accountQuarantineGuards`, `feexpayPayments.test` |
| 17 | Rejeu d'un webhook | document de paiement terminé ou `held_for_review` | 2 webhooks identiques, puis 2 concurrents | un seul effet, 2e = `already_processed`, solde inchangé | solde, `wallet_transactions/{id}` | PASS : aucun double effet. Concurrence réelle non prouvée en émulateur (contention) | **PAR** / P2 — LOC : tests C1-C3 |
| 18 | Échec de lecture du tombstone | — | injection de panne impossible sans modifier la production du service | local : `tombstone_date_unreadable` ⇒ retenue + alerte | — | **Non reproductible en préproduction** ; test local seulement | **LOC** |
| 19 | Réconciliation automatique | A1 en `quarantined` (nextAttemptAt échu) | attendre `retryAccountDeletions` (≤ 15 min après l'échéance) | seconde inspection, puis suppression Auth, nettoyage, anonymisation → `completed` ; ou blocage motivé si une opération non terminale est apparue | `state`, `authDeleted`, `completedAt`, audits `account_deletion_auth_delete` / `account_deletion_completed`, journaux du scheduler | PASS : un seul passage de suppression Auth, ordre respecté (audit AVANT l'étape irréversible). FAIL : double suppression / incohérence | PRÉ / P1+P4 |
| 20 | Reprise après échec | A8b (`max_attempts_reached`) ; A1e dossier `failed` | `manageAccountDeletionCF` (super-admin) `claim` puis `retry` avec `resolution` obligatoire | sans `resolution` : refusé ; avec : compteur remis à zéro, dossier relancé ; le soutien ordinaire (`t7e-del-soutien`) est refusé ; la fonction ne peut pas **terminer** une suppression | `support_events`, dossier, `attempts` | PASS : seul le super-admin agit, motif tracé. Une défaillance technique réelle n'est pas injectée | PRÉ / P1 |
| 21 | Audit des événements | tous les parcours | contrôle à la fin de chaque scénario | `audit_logs` : `account_deletion_requested`, `_request_repeated`, `_blocked`, `_auth_delete`, `_completed`, `_failed` ; `security_events` pour 15-16 (local) ; `support_events` pour 20 ; aucun secret ni donnée personnelle brute | collections `audit_logs`, `security_events`, `support_events` (écriture serveur seulement) | PASS : un événement par transition, UID synthétiques uniquement | PRÉ / P1+P4 |
| 22 | Intégrité des données financières | tous les comptes `t7e-del-*` | `node test-env/snapshot-balances.js` avant/après chaque scénario | somme des `wallet` inchangée sauf opération volontaire ; aucun solde négatif ; `wallet_transactions` conservé après anonymisation ; aucun document `needsReview` ignoré (il bloque la suppression) | instantanés avant/après, comparaison | PASS : écart nul. FAIL : tout écart non expliqué ⇒ arrêt immédiat | PRÉ / toutes |

Scénario complémentaire **S9** (témoin) intégré en 12 : A9 ne doit subir aucune dégradation.

## 4. Invariants vérifiés après chaque scénario

1. Aucun document créé hors des UID `t7e-del-*` ; aucun des comptes existants (`t7e-client`, `t7e-intrus`, `t7e-driver`, `t7e-admin`, `t7e-resto`, deux livreurs non `t7e-`) modifié.
2. Aucun solde négatif ; somme des soldes inchangée sauf action volontaire documentée.
3. Aucun tombstone sans dossier correspondant ; aucune suppression Auth sans audit préalable.
4. Production : `firebase functions:list --project az-express-b0469 --json` identique (lecture).

## 5. Limites déclarées

- Les scénarios 14-17 ne valident en préproduction que le **refus sûr** (FeexPay `DISABLED`) ; la logique de crédit / de mise en attente est prouvée par les tests locaux 7E-68/69 (322 ciblés, 9 de concurrence sous émulateur), pas par un paiement.
- 18 est local uniquement.
- La concurrence réelle (Firestore de production) n'est pas démontrée par l'émulateur.
- Lots comptes / E-Kbine / partenaires non déployés (P3) : leurs gardes ne sont pas testées en préproduction.
- Aucun test sur appareil ou émulateur mobile n'est revendiqué.

*Aucun compte créé, aucune donnée écrite, aucun test exécuté en préproduction. Attendre une autorisation distincte.*
