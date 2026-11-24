# Mission 7E-74 — Rapport final : correction de la passerelle fermée (P1)

Date : 2026-11-07 · Local uniquement. Aucun commit, `git add`, `git apply --cached`, push, merge, déploiement, commande distante, activation de `operations_control/account_deletion`, modification de secret ou de production. Plafonds P2/P3/production inchangés. Détails : `…GATE_CLOSED_BACKEND_REPORT.md`, `…FLUTTER_ERROR_HANDLING_REPORT.md`, `…TEST_RESULTS.md`.

## 1. Fichiers modifiés par 7E-74
- `functions/accountDeletion.js` — 5 lignes (3 de commentaire + lecture de la passerelle + refus), dans `request`, avant `checkRateLimit`.
- `functions/test/accountDeletionHardening.test.js` — 1 test remplacé, 6 tests au total pour la passerelle (26 au lieu de 21).
- `rules-tests/account-deletion.test.js` — 1 test remplacé, tests émulateur sur état réel (69 au lieu de 63).
- `lib/services/account_deletion_service.dart`, `lib/widgets/account_deletion_dialog.dart`, `test/services/account_deletion_service_test.dart`, `test/widgets/account_deletion_dialog_test.dart`.
- 4 rapports `docs/ACCOUNT_DELETION_7E74_*.md` (nouveaux ; aucun ancien rapport remplacé).

## 2. Diff backend
```diff
+  const gate=(await db.collection('operations_control').doc('account_deletion').get()).data();
+  if(gate?.enabled!==true || gate.inventoryVersion!==1)throw new HttpsError('failed-precondition','ACCOUNT_DELETION_NOT_ENABLED');
   await checkRateLimit(uid,'account_deletion_request',RATE_MAX,RATE_WINDOW_S);
```
(+ commentaire). Rien d'autre dans le moteur.

## 3. Diff Flutter
Voir le rapport Flutter : `AccountDeletionUnavailableException`, détection `failed-precondition` + `ACCOUNT_DELETION_NOT_ENABLED` sans repli sur le dernier reçu, branche dédiée dans le dialogue, `unauthenticated` ajouté aux codes de réauthentification (+53/−2 sur 4 fichiers).

## 4. Tests remplacés / nouveaux
Remplacés : « fermé par défaut… » (Hardening) et « rollout disabled keeps truthful pending request… » (rules-tests), qui validaient l'ancien comportement. Nouveaux : matrice rôle × 7 configurations, demande antérieure, `deletionRequested` préexistant, passerelle illisible, ouverte + idempotence, ouverte + limiteur ; côté émulateur absente/désactivée/version 2 × client/livreur et fermeture après première demande ; 4 tests Flutter. Aucune assertion métier affaiblie.

## 5. Résultats
Voir `…TEST_RESULTS.md` : Hardening 26/26 (N24) ; règles de suppression 69/69, Firestore 470/470, Storage 128/128 (N22) ; Flutter 25/25 et analyse propre ; C2 seul 9/9. **Suite Functions complète N22 : 2278/2328 réussis, 47 ignorés, 3 échecs** (C2 d'émulateur, relancé seul OK ; `dispatchRetry` préexistant ; E-Kbine 8 appels intermittent connu). Elle n'est pas annoncée verte.

## 6. Preuve : aucune écriture lorsque la passerelle est fermée
Le refus est levé avant `checkRateLimit`, avant la transaction et avant toute écriture (lecture seule de la passerelle). Preuves : (a) tests faux Firestore comparant le magasin complet avant/après (JSON), absence de dossier, tombstone, audit, `deletionRequested`, appel limiteur et appel Auth, pour absente / désactivée / `enabled` non booléen / version 2 / version `'1'` / `{}` / `null`, clients et livreurs, avec demande antérieure et `deletionRequested` préexistant ; (b) lecture en erreur → rejet sans écriture ; (c) même contrôle sur l'état réel de l'émulateur Firestore ; (d) l'ancien code fait échouer exactement ces tests (4 échecs), le nouveau les passe.

## 7. Preuve : comportement normal avec passerelle ouverte
Tests : dossier, tombstone, `deletionRequested` livreur, audit et limiteur créés comme avant ; répétition absorbée (compteur à 1, audit « repeated ») ; refus du limiteur sans écriture ; ces deux tests passent aussi sur l'ancien code (comportement préservé). Les suites rôles, réauthentification, idempotence, contrôles financiers et quarantaine existantes (2278 tests réussis) n'ont pas régressé.

## 8. Risques restants
- Validation uniquement sur faux Firestore et émulateur ; aucun essai sur Firestore/Functions réels ni sur appareil.
- La détection Flutter dépend du texte du message d'erreur (non vérifiée sur un vrai callable).
- Suite complète non verte : 3 échecs documentés (C2 et 8-appels d'émulateur, `dispatchRetry` préexistant) ; cause du déclenchement en suite complète non établie.
- Composition du commit 1 modifiée : Hardening 21→26 tests et règles de suppression 63→69 (les commandes 7E-72/7E-73 sont obsolètes) ; les fichiers Flutter ne figurent dans aucune liste de commits prévue (à décider).
- `requestAccountDeletionCF` ne retourne plus de reçu lorsque la passerelle est fermée : les clients déjà publiés (anciennes versions de l'application) affichent leur repli générique.
- Quota : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (inchangé).
- Cas non couverts : partenaires (périmètre fermé), voie web manuelle (inchangée).

## 9. Contrôle du diff et de Git
- Aucun fichier P2/P3 modifié par 7E-74 ; `functions/index.js` et `pilotCap.js` non touchés par cette mission ; `pilotLightOptions()` pour `az-express-b0469` = `{}` (production inchangée) ; aucun `.env` touché ; aucun fichier parasite créé dans le dépôt ; aucun ancien rapport remplacé.
- **Avant** : HEAD `aa3d1b0`, index vide. **Après** : HEAD `aa3d1b0`, index vide (`git diff --cached` = 0 fichier), fichiers modifiés/non suivis = ceux d'avant la mission + les fichiers listés au §1. Les `.aab`, patch, `az_splash_log.txt`, `qr-release/`, `scripts/*`, `web/downloads/`, `.firebase/hosting.*.cache` n'ont pas été touchés.

## Verdict
**PRÊT SOUS CONDITIONS** — la correction et ses tests sont validés (backend et Flutter), mais la suite Functions complète comporte 3 échecs (artefacts d'émulateur ou préexistants, non attribuables à 7E-74), et la validation reste locale (pas d'essai réel/appareil). Conditions : revue humaine de ces trois échecs et décision sur la composition du commit 1 (tests 26/69, fichiers Flutter).

Aucune opération Git ou distante ne sera faite sans nouvelle autorisation explicite.
