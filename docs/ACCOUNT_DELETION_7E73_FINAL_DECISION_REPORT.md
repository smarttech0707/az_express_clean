# Mission 7E-73 — Rapport final de décision (préparation des commits P1)

Date : 2026-11-07 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · Préproduction `az-express-preprod` · Production `az-express-b0469` : jamais touchée.
**Aucun `git add`, commit, push, merge, reset. Aucune commande distante, aucun déploiement, aucune activation de `operations_control/account_deletion`, aucun secret modifié, script jamais lancé en réel.** Seules opérations Git exécutées : lecture (`status`, `diff`, `archive`, `ls-files`, `grep`) et `git apply --cached --check` (vérification sans écriture).

## 1. Verdict

# PRÊT SOUS CONDITIONS

Le commit 1 est cohérent, minimal et vérifié (voir §3), mais ne doit pas être soumis tel quel : l'arbre de travail **ne respecte pas la règle « passerelle fermée ⇒ refus net »** (§4). Conditions avant autorisation du commit 1 :

| # | Condition | Responsable |
|---|---|---|
| A | Décider du correctif « passerelle fermée » (§4) — recommandé : l'inclure dans le commit 1 | vous |
| B | Accepter la scission de l'ancien commit 1 en **1 (P1) + 2 (gardes P2)** et l'usage des patchs de `index.js` | vous |
| C | Prendre note de l'écart de protection si seul le commit 1 est déployé (§3.3) | vous |

Hors commits (inchangé) : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (§7).

## 2. État initial du dépôt

Branche `finalisation/az-express`, HEAD `aa3d1b0`, **aucun fichier indexé** (`git diff --cached` vide avant et après). Arbre non propre (comme attendu) : 24 fichiers suivis modifiés (dont 3 de test de règles, 2 pages légales, 1 cache Hosting, 1 service Dart) et des fichiers non suivis : `functions/accountCleanup.js`, 5 tests (`accountDeletionHardening`, `accountQuarantineConcurrency.emulator`, `accountQuarantineGuards`, `accountQuarantineIndex`, `ekbineQuarantineGuards`), le script de déploiement, les documents `docs/ACCOUNT_DELETION_7E66…7E73_*`, et les éléments étrangers (`.aab`, patch, journaux, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `web/downloads/`, `test-env/.emulators.pid`). Rien n'a été supprimé ni remplacé dans les fichiers du périmètre. Un dossier ignoré, `test-env/runtime/7e73-patches/`, a été créé (4 patchs de travail).

## 3. Commit 1 (moteur P1)

### 3.1 Fichiers exacts
`functions/accountDeletion.js`, `functions/accountCleanup.js` (nouveau), `functions/partnerAccountDeletion.js`, `functions/accountDeletionSupport.js`, `functions/index.js` (**uniquement** le hunk `checkRateLimit, logAudit` — `index_p1.patch`, 13 lignes), `functions/test/accountDeletionHardening.test.js` (nouveau), `rules-tests/account-deletion.test.js`, `rules-tests/account-deletion-lifecycle.test.js`, `rules-tests/account-deletion-real.test.js`.

### 3.2 Dépendances
`accountDeletion` → `accountCleanup`, `accountDeletionIdentity` (HEAD), `partnerAccountDeletion` ; `partnerAccountDeletion` → `accountCleanup`, `accountDeletionScope`, `accountRelatedPersonalData` (HEAD) ; `index.js` → `accountDeletion`. `accountCleanup.js` est le seul module requis non suivi par Git. Rien du moteur P1 n'importe `accountAdmission`, `pilotCap`, `feexpayPayments`, `azia/*` ni `ekbineOrders`.

### 3.3 Exclus de P1 et protections présentes
Exclus : gardes P2 (`initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook`, `aiConfirmAction`) et leurs plafonds préproduction → commit 2 ; E-Kbine → commit 3 ; mots de passe/administration/abonnements → commit 3b. Déjà présent à HEAD : relecture du tombstone dans `adminDriverRecharge`, `adminWalletRequests`, `catalogQuote`, `eventReservations`, `partnerOrderQuote`, outils AZ IA (livraison, marketplace, pharmacies, restaurants), règles Firestore/Storage. **Écart si seul le commit 1 est déployé** : paiement, retrait, webhook, confirmation AZ IA ne relisent pas le tombstone ; compensé par `inspect` (solde nul, rien de pendant) rejoué à chaque passage et dans la transaction finale, par FeexPay `DISABLED` en préproduction, et par des comptes synthétiques. Détail : `…COMMIT1_P1_REVIEW.md`.

### 3.4 Résultats de tests (reconstitution hors dépôt : `git archive HEAD` + fichiers du commit + patch)
| Contrôle | Résultat |
|---|---|
| `index.js` se charge | PASS |
| Suite sans émulateur Node 24 | 2272 tests, 2097 réussis, 8 échecs, 167 ignorés — 8 échecs **identiques** dans les reconstitutions 1, 1+2, 1+2+3 (tests lisant `web/`, `lib/`, `.git` absents d'une extraction partielle ; ils passent dans le dépôt réel) |
| Règles de suppression, 4 fichiers, Auth + Firestore + Storage | **63 / 63** PASS |
| 1 + 2 + 3b équivalent à l'`index.js` actuel | PASS (identique octet à octet hors fins de ligne) |
| 1 + 2 + 3 + 3b : 2315 tests, mêmes 8 échecs d'artefact | PASS (aucune régression) |
| Commit 3 (E-Kbine) sur `HEAD` seul | `index.js` se charge ; **54 / 54** PASS |

## 4. Passerelle fermée (étape 8) — constat, correctif proposé, NON APPLIQUÉ

**Constat** (`accountDeletion.js`, `request`) : la passerelle `operations_control/account_deletion` n'est consultée que dans `process()`. Quand elle est absente ou fermée, `request` crée quand même `account_deletions/{uid}` (état `pending`), écrit un audit `account_deletion_requested`, et pour un **livreur** réauthentifié pose `deletionRequested: true` sur son profil. La réponse est « en attente, `server_rollout_not_enabled` ». Aucune quarantaine ni tombstone n'est créé (le moteur s'arrête avant), mais le dossier et le marqueur existent. **Règle retenue : refus net, aucun état.**

**Diff proposé** (`functions/accountDeletion.js`, après le contrôle `RATE_LIMITER_REQUIRED` et avant `checkRateLimit`) :
```diff
   if(typeof checkRateLimit!=='function')throw new HttpsError('failed-precondition','RATE_LIMITER_REQUIRED');
+  // Mission 7E-73 : passerelle absente ou fermée => refus net AVANT toute écriture (aucun dossier, aucun marqueur
+  // deletionRequested, aucune quarantaine, aucun audit de demande). Même condition que process() ; erreur de lecture => échec.
+  const gate=(await db.collection('operations_control').doc('account_deletion').get()).data();
+  if(gate?.enabled!==true || gate.inventoryVersion!==1)throw new HttpsError('failed-precondition','ACCOUNT_DELETION_NOT_ENABLED');
   await checkRateLimit(uid,'account_deletion_request',RATE_MAX,RATE_WINDOW_S);
```
Patch complet (code + tests) : `test-env/runtime/7e73-patches/gate_closed_proposal.patch`.

**Conséquences**
1. Aucun dossier, aucun `deletionRequested`, aucun tombstone, aucun audit, aucune écriture au rate-limit ni à Auth quand la passerelle est fermée ; erreur de lecture de la configuration ⇒ échec sûr.
2. Le limiteur n'est consommé que passerelle ouverte (un refus ne coûte pas de quota à l'utilisateur).
3. **Comportement visible modifié** : la réponse « demande conservée » (`server_rollout_not_enabled`) n'existe plus pour `request` (elle reste pour `process`/reprises d'un dossier existant). L'application (`lib/services/account_deletion_service.dart`) affiche pour ce motif « Votre demande est conservée » ; avec le correctif elle recevrait une erreur `failed-precondition` `ACCOUNT_DELETION_NOT_ENABLED` non mappée → message générique. À traiter dans une version applicative (fichier exclu des commits ; **non modifié**). La voie manuelle (`account_deletion_requests`) reste disponible.
4. Un dossier déjà créé avant la fermeture n'est pas affecté.
5. Une lecture Firestore de plus par demande (même profil de charge que `process`).
6. Pas d'effet sur `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`.

**Tests**
- Existants à remplacer (ils encodent l'ancien comportement) : `accountDeletionHardening.test.js` « fermé par défaut… » (reconstitution : 1 échec attendu) ; `rules-tests/account-deletion.test.js` « rollout disabled keeps truthful pending request and no tombstone » (1 échec attendu).
- Tests proposés (rédigés et exécutés en reconstitution) : sept configurations (absente, `enabled:false`, `inventoryVersion` absent/2/chaîne, `enabled:'true'`, `{}`) × rôles `client` et `livreur` : la requête est rejetée avec `ACCOUNT_DELETION_NOT_ENABLED`, **le magasin de documents est strictement identique avant/après**, aucun dossier, `deletionRequested` indéfini, aucun tombstone, aucun audit, aucun appel au limiteur ni à Auth ; plus un test « erreur de lecture de la configuration ⇒ échec sûr, aucun dossier » ; côté règles, remplacement du test existant par un refus sans dossier ni tombstone.
- Résultats en reconstitution avec le correctif : unitaires **22 / 22**, règles de suppression **63 / 63**.

**Recommandation** : appliquer ce correctif **avant** le commit 1 (il modifie `accountDeletion.js` et les deux fichiers de test déjà inclus dans le commit 1). Sans votre autorisation, il n'est pas appliqué.

## 5. Corrections E-Kbine et test des 8 appels

- **Conformité à votre décision** : agent en quarantaine ⇒ confirmation refusée sans écriture ; client en quarantaine ⇒ création refusée, avec ou sans wallet ; aucune commande créée après la quarantaine ; commandes terminées/engagées inchangées. 11 tests ; 6 échouent sur `HEAD`. Détail : `…EKBINE_SCOPE_DECISION.md`.
- **Indépendance** : le commit E-Kbine (`ekbineOrders.js` + son test) ne dépend ni du commit 1 ni du commit 2 (vérifié : `HEAD` + ces 2 fichiers → 54/54). Le moteur P1 n'importe pas `ekbineOrders`. Il reste donc **un commit séparé (3)**, indépendant des gardes P3 (3b).
- **Test « E-Kbine création : 8 appels simultanés »** : **laissé actif et inchangé**. Mécanisme : `INVALID_ARGUMENT / Transaction is invalid or closed` de l'émulateur (non relancé par le SDK) contre `ABORTED` de Firestore réel (relancé). Sur `HEAD` : sonde 2 rondes en échec sur 40 ; sur le code actuel : 3 sur 40 ; dans toutes les rondes en échec, solde 4000 et **une seule** commande (aucune conséquence financière observée). En suite complète : 2 échecs sur 5 exécutions ; déclencheur non établi. Limites : émulateur seulement, petits échantillons, pas de test de suite complète sur `HEAD`. Aménagement éventuel du test (options A/B) présenté séparément et **non appliqué**.

## 6. Les commits et leur ordre

| # | Contenu | Dépend de | Tests obligatoires | Report possible |
|---|---|---|---|---|
| 1 | moteur P1 (+ correctif passerelle si autorisé) | HEAD | hardening 21 (22 avec correctif) ; règles suppression 63 ; chargement `index.js` | non |
| 2 | gardes P2 + plafonds préproduction + `accountAdmission` | 1 | guards 17, index 11, pilotCap 10, concurrence 9 (émulateur), paiements 178, AZ IA 174, règles 470 | oui (quota) |
| 3 | E-Kbine (`ekbineOrders` + test) | HEAD | E-Kbine 54 | oui (revue métier) |
| 3b | gardes P3 (`passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`, `setPharmaciePassword`) | 2 | tests de ces modules | oui |
| 4 | `restaurantV2Preprod.test.js` | rien | 12/12 Node 22 et 24 | oui |
| 5 | script de déploiement (jamais exécuté) | rien | syntaxe + simulations | non (requis pour déployer) |
| 6 | documentation | rien | — | oui |

Ordre : 1 → 2 → 3 → 3b → 4 → 5 → 6 (3, 4, 5, 6 libres vis-à-vis de 1 et 2 ; 3b après 2). **Aucun fichier `.env`, secret, APK/AAB, patch, journal ou configuration locale sensible n'est inclus** (vérification faite sur les listes ; commande de contrôle automatisée dans la checklist). Les 4 patchs de travail restent dans un dossier ignoré. Cartes complètes : `…FIVE_COMMITS_DEPENDENCY_MAP.md`. Commandes Git exactes : `ACCOUNT_DELETION_7E72_COMMIT_FINAL_MANIFEST.md` §6 est **périmé pour le commit 1** (à scinder) ; commandes révisées du commit 1 : §9 ci-dessous.

## 7. Quota

> **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**

Quota annoncé 20 vCPU ; usage réel **non confirmé** ; P1 théorique 18,75 vCPU ; P1 + P2 théorique 19,75 vCPU (marge 0,25) ; marge recommandée 1 vCPU. Ces valeurs sont des projections d'un modèle de travail, **pas de la capacité disponible**. Les commits ne changent pas ce statut.

## 8. Validation après chaque commit
`…POST_COMMIT_VALIDATION_CHECKLIST.md` : commandes, critères, niveaux [CRITIQUE]/[NC] et procédure d'arrêt par commit.

## 9. Commandes Git révisées pour le commit 1 (NON exécutées)

À n'exécuter qu'après votre autorisation explicite. Le patch de `index.js` est appliqué **à l'index seulement** (l'arbre de travail garde la version complète).
```bash
git apply --cached test-env/runtime/7e73-patches/index_p1.patch
git add -- \
  functions/accountDeletion.js \
  functions/accountCleanup.js \
  functions/partnerAccountDeletion.js \
  functions/accountDeletionSupport.js \
  functions/test/accountDeletionHardening.test.js \
  rules-tests/account-deletion.test.js \
  rules-tests/account-deletion-lifecycle.test.js \
  rules-tests/account-deletion-real.test.js
git diff --cached --stat        # attendu : 9 fichiers, index.js = 13 lignes (checkRateLimit, logAudit)
git commit -m "feat(account-deletion): P1 deletion engine with quarantine, caps, audit and AI data cleanup" \
  -m "Moteur de suppression pour client et livreur : passerelle fermee par defaut, quarantaine, tombstone, limites de demandes, audit strict avant suppression Auth, administrateurs jamais supprimes automatiquement, nettoyage des donnees AZ IA. Gardes financieres P2 et E-Kbine dans des commits separes." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
Si le correctif « passerelle fermée » est autorisé, l'appliquer d'abord à l'arbre de travail (`patch -p1 < …/gate_closed_proposal.patch`, ou édition manuelle équivalente) puis lancer les tests du §3.4 avant ce `git add`. Commit 2 : `git apply --cached …/index_p2.patch` + `git add --` des fichiers du commit 2 (liste dans la carte des dépendances) ; commit 3b : `index_p3.patch` + fichiers 3b.

## 10. Points encore bloquants / risques ouverts

| Point | Nature |
|---|---|
| Décision sur le correctif « passerelle fermée » | **bloque l'autorisation du commit 1** |
| Quota non confirmé | bloque tout déploiement |
| Arbre non commité | le script refuse l'exécution réelle |
| Écart de protection P2 absente si commit 1 déployé seul | acceptable sous conditions (§3.3) |
| Test E-Kbine « 8 appels » (déclencheur non établi) et `dispatchRetry` | préexistants/non résolus, hors sécurité P1 |
| Message de l'application pour `ACCOUNT_DELETION_NOT_ENABLED` | à traiter dans une version applicative |
| Outil `held_for_review`, revue métier E-Kbine/partenaires/AZ IA, durées légales | bloquent l'activation complète, pas P1 synthétique |
| Chemin d'exécution réelle du script jamais exécuté ; Cloud Build `nodejs22` non vérifié | à observer au premier essai autorisé |

## 11. Décisions qui nécessitent votre autorisation explicite
1. Appliquer (ou non) le correctif « passerelle fermée » et ses tests, avant le commit 1.
2. Autoriser la scission 1 / 2 / 3 / 3b et l'usage de `git apply --cached` pour `index.js`.
3. Autoriser chaque commit séparément (aucun n'est fait).
4. Test des 8 appels : conserver tel quel (défaut) ou autoriser l'option A/B.
5. Quota : relevé humain avant toute demande de déploiement.

*Aucun commit. Aucun push. Aucun merge. Aucun déploiement. Aucune activation. Aucune modification distante. En attente de votre autorisation explicite.*
