# AZ Express — Rapport de passation technique (audit Phase 10 → 10.7)

Date : 2026-11-24
Dépôt : `az_express_clean`, branche `finalisation/az-express`
Projet production : `az-express-b0469` (jamais touché dans cet audit)
Projet préproduction : `az-express-preprod` (`306761725053`)

---

## A. Résumé exécutif

L'audit opérationnel du build Android 1.0.10+11 a confirmé un APK Release valide, installé et lancé sans crash sur un appareil réel (Infinix X6728B). Pour valider le fix Catalogue de bout en bout sans toucher à la production, un plan de test sur `az-express-preprod` a été construit étape par étape, avec une prudence maximale (lecture seule à chaque étape tant qu'une autorisation explicite n'était pas donnée).

La dernière étape en cours (Phase 10.7) consiste à réinitialiser le mot de passe Firebase Auth de **deux comptes de test uniquement** (`client.test@az-test.invalid`, `livreur.a@az-test.invalid`) sur `az-express-preprod`, via un script isolé et testé (`test-env/reset-test-passwords.js`). Les précontrôles (code, 15 tests unitaires, Project ID réel, dry-run) sont **CONFIRMÉS PASS**. L'exécution réelle (`--execute`) **n'a pas eu lieu** : aucune preuve d'exécution n'existe, et les credentials Admin SDK nécessaires ne sont pas configurés dans cet environnement. La phase est **BLOQUÉE**, en attente d'une action du propriétaire dans son propre terminal.

Aucune donnée de production n'a été modifiée. Aucun déploiement n'a eu lieu. Aucun mot de passe n'a été vu, stocké ou transmis par un assistant IA.

---

## B. État réel du projet

- Dépôt local, non poussé vers un remote dans le cadre de cet audit.
- `git status --short` : **457 fichiers modifiés/non commités** (confirmé à l'instant, lecture seule). Ce nombre inclut ~455 modifications préexistantes issues d'un travail parallèle (non liées à cet audit) + les 2 fichiers créés pour cet audit (`test-env/reset-test-passwords.js`, `test-env/reset-test-passwords.test.js`).
- Branche active : `finalisation/az-express`.
- 5 derniers commits (aucun lié à cet audit — l'audit n'a produit aucun commit) :
  ```
  d65c8f0 fix(account-deletion): guard financial activity during quarantine
  294332e fix(account-deletion): handle structured deletion gate errors
  65e738b fix(account-deletion): secure P1 deletion request gate
  aa3d1b0 security(restaurant-v2): restrict pilot driver dispatch and disable test FCM
  f32f41d fix(restaurant-v2): clean up Storage without storage.objects.get, reconcile finances, make cleanup resumable
  ```
  **CONFIRMÉ** — aucun de ces commits n'est lié à cet audit (reset-test-passwords.js n'a jamais été commité).

---

## C. Architecture concernée

- `Flutter UI → providers/state → services → Cloud Functions → Firestore/Storage` (architecture cible du projet, cf. `CLAUDE.md`).
- Collections Firestore pertinentes pour cet audit : `clients/{uid}`, `livreurs/{uid}` (solde = champ `wallet`), `orders` (polymorphe), aucune touchée dans cette phase.
- `test-env/` : infrastructure de test isolée, séparée du code applicatif, avec guard-rails dédiés (`test-env/lib/guards.js`).
- `az-express-preprod` : projet Firebase distinct de la production, avec ses propres apps enregistrées et Cloud Functions déployées.

---

## D. État Android — CONFIRMÉ

| Élément | Valeur | Statut |
|---|---|---|
| Package | `com.azexpress.app` | CONFIRMÉ (aapt dump badging) |
| Version | `1.0.10` / versionCode `11` | CONFIRMÉ |
| AAB original | `build/app/outputs/bundle/release/app-release.aab`, SHA-256 `aaa8ad28f47fa641516c78c95883f8580b2234d0b38b1f9115771a633e010ede`, inchangé | CONFIRMÉ |
| APK Release re-construit | `build/app/outputs/flutter-apk/app-release.apk`, SHA-256 `d9fb777c1e3e383e70634304acdc3989b3692f1cded0a82f7cbf051cbb7c358d` | CONFIRMÉ |
| Signature | apksigner v2, RSA 2048, certificat du keystore release réel | CONFIRMÉ |
| Installation | Infinix X6728B, installation neuve (package absent avant) | CONFIRMÉ |
| Lancement | Pas de `FATAL EXCEPTION` dans logcat, cycle de vie normal observé | CONFIRMÉ |
| Tests fonctionnels (paiement, commande réelle, etc.) | Non testés (hors périmètre, nécessitent préprod) | NON VÉRIFIÉ |

APK de test `com.azexpress.app.test` (pré-existant, daté du 18 novembre) : confirmé via `aapt2 dump resources` qu'il embarque `project_id = "az-express-preprod"`. Installé et lancé sans crash constaté. **CONFIRMÉ.**

---

## E. État Firebase préproduction

- `firebase projects:list` (relancé à l'instant, lecture seule) confirme à nouveau la ligne :
  ```
  AZ Express Preprod | az-express-preprod | 306761725053
  ```
  **CONFIRMÉ.**
- `firebase functions:list --project az-express-preprod` relancé à l'instant : **aucune** fonction nommée `quoteCatalogCF` ou `createCatalogOrderFromQuoteCF` trouvée. **CONFIRMÉ** que ces deux fonctions, corrigées et déployées en production dans une phase antérieure de ce chantier, ne sont toujours pas présentes sur préprod. Cela bloque toute validation du fix Catalogue sur préprod tant qu'elles n'y sont pas déployées (déploiement NON autorisé dans cette phase).
- Apps enregistrées sur préprod : "AZ Express Test" et "AZ Express Web Test" (vu en Phase 10.2, non revérifié dans cette passe — **PROBABLE**, pas re-confirmé aujourd'hui).
- `test-env/dart-defines.test.json` configure bien l'APK de test vers `az-express-preprod` (projectId, storage bucket, authDomain tous cohérents). **CONFIRMÉ** (lu intégralement).

---

## F. État Firebase production — vérifications non destructives uniquement

- `.firebaserc` : `default = az-express-b0469`. **CONFIRMÉ**, non modifié.
- Aucune commande de déploiement, aucune lecture/écriture de données de production n'a été exécutée à aucun moment de cet audit. **CONFIRMÉ** par absence totale de toute commande `firebase deploy`, `firestore` write, ou `auth:export` réussie dans l'historique de session.
- Une tentative de `firebase auth:export` en lecture seule sur préprod (Phase 10.2, PAS sur production) a été **bloquée par le classificateur de permissions de l'outil** avant toute exécution — aucune donnée exportée. **CONFIRMÉ.**

---

## G. Travaux d'audit déjà réalisés (à ne pas répéter)

1. Vérification binaire complète de l'AAB/APK Release 1.0.10+11 (package, version, signature, SHA-256) — **fait, ne pas refaire sans raison**.
2. Installation et lancement sur Infinix X6728B, vérification absence de crash — **fait**.
3. Identification et élimination d'un APK obsolète (`app-release.apk` daté du 26 octobre, `versionName='1.0.10-qrtest'`) comme candidat de test — **fait, ne pas réutiliser cet artefact**.
4. Découverte que `az-express-preprod` existe réellement et contient ~90 Cloud Functions déployées, contredisant les mentions obsolètes de `test-env/README.md` ("rien n'est créé") et `docs/ORDER_RELIABILITY_TEST_PROJECT_PROCEDURE.md` ("NON EXÉCUTÉE") — **fait, ces deux documents sont à considérer comme obsolètes sur ce point précis**.
5. Lancement contrôlé de `com.azexpress.app.test` et confirmation visuelle + binaire que le `FirebaseProjectGuard` cible bien `az-express-preprod` — **fait**.
6. Audit exhaustif de `test-env/seed-test-data.js` : confirmé qu'il réécrit inconditionnellement les mots de passe des 5 comptes de test ET 13 documents Firestore (y compris un document de config globale `config/billing`) à chaque exécution, sans option de filtrage par rôle — **fait, conclusion : ne pas utiliser ce script pour un besoin ponctuel de 2 comptes**.
7. Conception, implémentation et test local complet de `test-env/reset-test-passwords.js` — **fait** (détails en section J).

**Ne pas refaire** : l'audit binaire de l'APK/AAB, l'audit de `seed-test-data.js`, la tentative d'export Auth (bloquée, inutile de réessayer sans changer d'approche), la vérification du `FirebaseProjectGuard` sur le device (déjà confirmée).

---

## H. Tests et résultats vérifiés

| Suite | Commande | Résultat | Quand vérifié |
|---|---|---|---|
| `test-env/reset-test-passwords.test.js` | `node --test test-env/reset-test-passwords.test.js` | **15/15 PASS** | Reconfirmé à l'instant (2026-11-24), zéro échec |
| Tests Flutter (3 échecs connus, non liés à ce chantier) | `flutter test` | 3 échecs de type cast, non corrigés (hors périmètre de cette phase) | Vérifié en Phase 9, **non re-vérifié dans cette passe** |
| `functions/test/testEnvGuards.test.js` | `npm test` (functions/) | Couverture confirmée en Phase 10.5 (lecture, pas de ré-exécution dans cette passe) | **PROBABLE** (lu, pas relancé aujourd'hui) |

Aucun test d'intégration réel contre `az-express-preprod` n'a été exécuté (aucun appel réseau réel, uniquement des mocks locaux). **CONFIRMÉ.**

---

## I. Phase 10.7 — analyse détaillée

Objectif de la phase : réinitialiser le mot de passe Auth de `client.test@az-test.invalid` et `livreur.a@az-test.invalid` sur `az-express-preprod`, rien d'autre.

Étapes et statut réel :

| Étape | Statut | Preuve |
|---|---|---|
| 1. Relecture du script | CONFIRMÉ fait | Contenu lu intégralement (126 lignes), reproduit en section J |
| 2. 15 tests unitaires | CONFIRMÉ PASS | Rejoué à l'instant : 15 pass, 0 fail |
| 3. Project ID réel confirmé | CONFIRMÉ | `firebase projects:list` relancé à l'instant, ligne `az-express-preprod / 306761725053` présente |
| 4. Dry-run exécuté | CONFIRMÉ (lors de la session précédente) | Sortie affichait exactement les 2 comptes autorisés + message "DRY-RUN : aucune modification..." + exit code 0. **Non re-rejoué dans cette passe** (aucune raison de le refaire, le code n'a pas changé) |
| 5. Longueur mot de passe ≥ 12 | CONFIRMÉ dans le code (`MIN_PASSWORD_LENGTH = 12`), vérifié par test | — |
| 6. Credentials Admin SDK pour `az-express-preprod` | **BLOQUÉ / NON VÉRIFIÉ** | `GOOGLE_APPLICATION_CREDENTIALS` confirmé **non défini** (revérifié à l'instant) ; aucun fichier de clé de service trouvé dans `test-env/` ; une tentative de vérification complémentaire (`gcloud auth application-default print-access-token`, lecture seule) a été bloquée par le classificateur de permissions de l'outil |
| 7. Exécution réelle `--execute` | **NON EXÉCUTÉE** | Aucune trace, aucune sortie, aucun log ne prouve une exécution. Ne pas supposer qu'elle a eu lieu. |
| 8. Vérification post-exécution | **IMPOSSIBLE** tant que l'étape 7 n'a pas eu lieu | — |

**Conclusion : Phase 10.7 = PARTIELLEMENT TERMINÉE.** Tout ce qui est vérifiable sans toucher à Firebase (code, tests, dry-run, identité du projet) est confirmé correct. L'opération réelle n'a pas eu lieu et reste bloquée par (a) l'absence de credentials confirmés et (b) une contrainte d'outillage : aucun assistant IA dans cette chaîne ne doit recevoir le mot de passe, et le terminal utilisé par l'assistant est non-interactif (toute valeur tapée resterait visible dans la session) — donc l'étape `--execute` doit être lancée par le propriétaire lui-même, dans son propre terminal.

---

## J. Script `reset-test-passwords.js` — analyse de sécurité

Fichier : `test-env/reset-test-passwords.js` (126 lignes, lu intégralement, inchangé depuis sa création).

1. **Project ID autorisé** : un seul, codé en dur — `ALLOWED_PROJECT = g.PREPROD.projectId` → `'az-express-preprod'`. Aucun autre identifiant, même ressemblant (`az-express-test`, `demo-az-test`), n'est accepté : testé explicitement (`validateRequest` lève une erreur `/autorisé/`). **CONFIRMÉ.**
2. **Vérification du Project ID** : double contrôle — (a) rejet explicite si `g.isProductionProject(project)` (liste de production dans `test-env/lib/guards.js` : `az-express-b0469`, `az-express-clean`), (b) rejet si `project !== ALLOWED_PROJECT`. Un `--confirm-project` doit en plus répéter exactement `--project`, sinon rejet. **CONFIRMÉ** par lecture du code et par test (`refuse la production, même nommée explicitement`, `refuse tout projet autre que az-express-preprod`).
3. **Identification des utilisateurs** : par **email**, via `auth.getUserByEmail(email)` — pas de résolution par UID direct. Liste blanche fermée de 2 emails : `client.test@az-test.invalid`, `livreur.a@az-test.invalid`. Tout autre email (y compris les 3 autres comptes de test légitimes comme `admin.test@az-test.invalid`) est rejeté. **CONFIRMÉ** (code + test `refuse tout email hors de la liste blanche fermée`).
4. **Mécanisme UID/email** : email en entrée, UID résolu uniquement via `getUserByEmail` puis utilisé pour `updateUser(uid, {password})`. Aucun UID n'est accepté en argument. **CONFIRMÉ.**
5. **Peut-il modifier un autre utilisateur ?** Non : la validation rejette toute adresse hors liste blanche *avant* tout appel réseau. **CONFIRMÉ.**
6. **Peut-il créer un utilisateur ?** Non : `resetPasswords` appelle uniquement `getUserByEmail` puis `updateUser` ; `createUser` n'est **jamais référencé** dans le fichier. Testé explicitement avec un mock dont `createUser` lève une erreur s'il est appelé — le test passe, confirmant qu'il n'est jamais invoqué. **CONFIRMÉ.**
7. **Peut-il modifier Firestore ?** Non : aucun import Firestore, aucune référence à `firestore()`/`admin.firestore` dans tout le fichier. `buildPlan()` retourne explicitement `firestore: 'Aucune opération Firestore dans cet outil.'`, vérifié par test. **CONFIRMÉ.**
8. **Peut-il viser la production ?** Non, voir point 2 — rejet à deux niveaux avant tout appel SDK. **CONFIRMÉ.**
9. **Précontrôles exécutés par le script lui-même** : validation des arguments (`parseArgs` rejette tout argument inconnu), validation du projet, validation de la confirmation, validation de l'environnement (rejet si une variable d'env pointe vers la production), validation des emails, validation de la longueur du mot de passe — **tout cela avant tout appel réseau**. **CONFIRMÉ.**
10. **Ce que fait le dry-run** : affiche le plan (projet, comptes ciblés, opération prévue, confirmation qu'aucune opération Firestore n'aura lieu) et retourne `{executed: false, plan}` **sans jamais charger le module `firebase-admin`** (le `require('firebase-admin')` est placé à l'intérieur du bloc `if (execute)`, donc totalement absent du chemin dry-run). **CONFIRMÉ** par lecture directe du code (ligne 101-106) et par test (`n'appelle jamais Firebase et ne modifie rien`).
11. **Ce que fait réellement `--execute`** : charge `firebase-admin`, initialise l'app avec `{projectId: validProject}` (donc uniquement `az-express-preprod` après validation), lit `AZ_TEST_PASSWORD` depuis l'environnement, puis pour chaque email validé : `getUserByEmail` → `updateUser(uid, {password})` — **strictement ce seul champ**, confirmé par test (`Object.keys(call.payload)` doit être exactement `['password']`). Affiche en sortie uniquement `"Mot de passe mis à jour pour N compte(s) (valeur jamais affichée)."` — le mot de passe n'apparaît jamais dans aucune sortie console, confirmé par un test dédié qui capture `console.log` et vérifie l'absence de la chaîne du mot de passe injecté. **CONFIRMÉ.**
12. **Méthode de credential attendue** : le script ne gère aucun credential lui-même — il délègue entièrement à `firebase-admin`'s `initializeApp({projectId})`, ce qui implique la résolution standard des Application Default Credentials (ADC) : soit `GOOGLE_APPLICATION_CREDENTIALS` pointant vers une clé de service du projet `az-express-preprod`, soit un `gcloud auth application-default login` préalable. `test-env/README.md` documente explicitement cette attente : *"Authentification : `GOOGLE_APPLICATION_CREDENTIALS` vers une clé de service du projet de test (jamais celle de production)."* **CONFIRMÉ** (ligne 45 de `test-env/README.md`, lue à l'instant). Aucun fichier de clé de service n'a été trouvé dans `test-env/` lors de cette vérification — **NON VÉRIFIÉ** si une clé existe ailleurs sur la machine du propriétaire (hors périmètre d'inspection).
13. **Les tests couvrent-ils les protections critiques ?** Oui — 15 tests couvrent explicitement : acceptation du cas valide, rejet production (2 variantes), rejet projet non-exact même "test-like", rejet confirmation absente/différente, rejet variable d'env de production, rejet email hors liste (3 variantes), rejet liste vide, déduplication, contenu du plan, non-création de compte, payload `updateUser` strict, rejet mot de passe court sans toucher Auth, dry-run sans appel Firebase, dry-run sans fuite du mot de passe, rejet argument CLI inconnu. **CONFIRMÉ** par lecture intégrale du fichier de test.
14. **Risques résiduels** :
    - Le script fait confiance à `firebase-admin` pour résoudre le *bon* projet réel derrière l'ID `az-express-preprod` — si jamais un alias/configuration ADC ambiguë existait sur la machine du propriétaire, ce risque serait hors du contrôle du script (CLAUDE.md impose de toute façon une vérification manuelle du Project ID avant `--execute`, ce qui a été fait).
    - Si `client.test@az-test.invalid` ou `livreur.a@az-test.invalid` n'existent pas (pas encore seedés), `getUserByEmail` échouera et le script ne créera rien — c'est le comportement voulu, mais cela signifie que l'opération peut échouer silencieusement sans modification si les comptes n'ont jamais été créés par `seed-test-data.js`. **NON VÉRIFIÉ** si ces deux comptes existent réellement sur `az-express-preprod` (l'audit n'a jamais exécuté `seed-test-data.js` ni listé les utilisateurs Auth existants).
    - Aucune rotation/suppression de clé de service n'est gérée par le script — relève de l'hygiène de sécurité du propriétaire, hors périmètre.
15. **Commande exacte pour procéder, sans exposer le mot de passe** : voir section M.

---

## K. Blocage actuel

**Double blocage, les deux doivent être levés avant `--execute` :**

1. **Credentials non confirmés.** Aucune clé de service / ADC pour `az-express-preprod` n'a été détectée dans cet environnement (`GOOGLE_APPLICATION_CREDENTIALS` non défini, aucun fichier de clé dans `test-env/`). Si le propriétaire possède une clé de service ailleurs sur sa machine, ce blocage peut déjà être levé de son côté — **à vérifier par le propriétaire**, pas par un assistant IA (éviter toute tentative d'inspection qui s'approcherait de la lecture de secrets).
2. **Contrainte de confidentialité du mot de passe.** Aucun assistant IA dans cette chaîne (ni l'assistant précédent, ni ChatGPT en reprise) ne doit recevoir, afficher, logger ou stocker le mot de passe réel. Le terminal utilisé par un assistant IA automatisé est non-interactif : toute valeur passée en argument de commande reste visible dans la session de l'assistant. **Conséquence : l'étape `--execute` doit être exécutée physiquement par le propriétaire, dans son propre terminal local**, jamais par un assistant IA.

Aucun autre blocage technique n'existe : code, tests et dry-run sont tous validés.

---

## L. Prochaine étape exacte

1. Le propriétaire confirme (ou configure) une clé de service / ADC pour **`az-express-preprod` uniquement** sur sa machine locale (jamais partagée avec un assistant IA).
2. Le propriétaire exécute lui-même, dans son propre terminal, la commande de la section M.
3. Le propriétaire transmet **uniquement la ligne de sortie non sensible** du script (ex. `"Mot de passe mis à jour pour 2 compte(s) (valeur jamais affichée)."` ou un message d'erreur) — jamais le mot de passe.
4. Sur cette base uniquement, le rapport final de Phase 10.7 peut être rédigé de façon honnête (succès ou échec réel, par compte).
5. Aucune Phase 10.8 ne doit démarrer automatiquement — autorisation explicite requise, comme pour toutes les phases précédentes.

---

## M. Commandes à exécuter par le propriétaire (jamais par un assistant IA)

Dans un terminal PowerShell local, depuis la racine du dépôt :

```powershell
# 1. Vérifier une dernière fois le dry-run (sans danger, ne touche rien) :
node test-env\reset-test-passwords.js --project az-express-preprod --confirm-project az-express-preprod --email client.test@az-test.invalid --email livreur.a@az-test.invalid

# 2. Définir le mot de passe localement, sans jamais le taper dans un chat ou le transmettre à un assistant :
$env:AZ_TEST_PASSWORD = Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText

# 3. (si nécessaire) pointer vers une clé de service DU PROJET az-express-preprod UNIQUEMENT :
$env:GOOGLE_APPLICATION_CREDENTIALS = "<chemin local vers la clé de service préprod>"

# 4. Exécution réelle, limitée aux 2 comptes autorisés :
node test-env\reset-test-passwords.js --project az-express-preprod --confirm-project az-express-preprod --email client.test@az-test.invalid --email livreur.a@az-test.invalid --execute
```

Le script n'affichera jamais le mot de passe dans sa sortie (vérifié par test dédié).

---

## N. Actions interdites ou à ne pas répéter

- Ne jamais exécuter `--execute` depuis un terminal piloté par un assistant IA.
- Ne jamais demander au propriétaire de coller son mot de passe dans le chat.
- Ne jamais réutiliser `seed-test-data.js` pour ce besoin ponctuel (il réécrit 13 documents Firestore et 5 mots de passe à chaque exécution).
- Ne jamais tenter `firebase auth:export` (déjà bloqué une fois, inutile de réessayer sans changer d'approche et d'autorisation).
- Ne jamais tenter de lire le contenu d'un fichier de clé de service ou d'une variable d'environnement sensible au-delà de vérifier sa simple présence.
- Ne jamais déployer `quoteCatalogCF`/`createCatalogOrderFromQuoteCF` (ou toute autre fonction) sur `az-express-preprod` sans autorisation explicite distincte — rappel : elles sont absentes à ce jour (vérifié aujourd'hui).
- Ne jamais modifier `.firebaserc`, aucune config Firebase, aucun fichier Android/Flutter dans le cadre de cette phase.
- Ne jamais commiter/pousser les 2 fichiers créés (`test-env/reset-test-passwords.js` et son test) sans demande explicite.
- Ne pas reconstruire l'APK/AAB à nouveau sans raison (déjà vérifié, artefacts stables).
- Ne pas répéter l'audit binaire de l'APK/AAB ni l'audit de `seed-test-data.js` (déjà faits, conclusions stables).

---

## O. Risques résiduels

- Les 2 comptes de test (`client.test@az-test.invalid`, `livreur.a@az-test.invalid`) pourraient ne pas exister encore sur `az-express-preprod` si `seed-test-data.js` n'a jamais été exécuté sur ce projet — **NON VÉRIFIÉ**. Dans ce cas, `--execute` échouera proprement (le script ne crée jamais de compte) et affichera une erreur, sans dommage.
- Les Cloud Functions Catalogue (`quoteCatalogCF`, `createCatalogOrderFromQuoteCF`) restent absentes de préprod — toute validation fonctionnelle du fix Catalogue sur préprod restera bloquée tant qu'un déploiement explicitement autorisé n'aura pas lieu (hors périmètre actuel).
- `test-env/README.md` et `docs/ORDER_RELIABILITY_TEST_PROJECT_PROCEDURE.md` contiennent des affirmations obsolètes ("rien n'est créé", "NON EXÉCUTÉE") contredites par l'état réel de `az-express-preprod` — à ne pas prendre pour argent comptant sans revérification croisée.
- Aucune vérification n'a eu lieu aujourd'hui sur l'existence ou l'absence d'une clé de service locale appartenant au propriétaire — c'est délibéré (éviter toute approche des secrets), mais cela signifie que le blocage de crédentiel pourrait déjà être résolu côté propriétaire sans que cet audit le sache.

---

## P. Fichiers importants avec chemins

- `test-env/reset-test-passwords.js` — outil de reset isolé (126 lignes).
- `test-env/reset-test-passwords.test.js` — 15 tests unitaires locaux (127 lignes).
- `test-env/lib/guards.js` — garde-fous partagés (production vs test, `PREPROD` constant).
- `test-env/seed-test-data.js` — script de seed large, à ne pas réutiliser pour ce besoin.
- `test-env/README.md` — procédure manuelle documentée (ligne 45 : méthode de credential attendue).
- `test-env/dart-defines.test.json` — configuration de build de test pointant vers `az-express-preprod`.
- `functions/test/testEnvGuards.test.js` — tests de `guards.js`.
- `lib/services/firebase_project_guard.dart` — garde embarquée côté app Flutter.
- `.firebaserc` — alias Firebase (`default: az-express-b0469`), non modifié.
- `docs/ORDER_RELIABILITY_TEST_PROJECT_PROCEDURE.md` — procédure historique (statut partiellement obsolète).
- `docs/PROTOCOLE_TESTS_LANCEMENT.md` — protocole de test antérieur, ne mentionne pas `az-express-preprod`.
- `CLAUDE.md` (racine) — charte du projet, règles non négociables (argent, sécurité, schéma Firestore).
- `build/app/outputs/flutter-apk/app-release.apk` — APK Release vérifié (SHA-256 dans section D).
- `build/app/outputs/bundle/release/app-release.aab` — AAB original (SHA-256 dans section D).

---

## Q. Prompt de reprise pour ChatGPT

```
Je reprends un audit technique du projet AZ Express (dépôt Flutter + Firebase, branche
finalisation/az-express). Un rapport de passation complet existe dans le fichier
AZ_EXPRESS_AUDIT_HANDOFF.md à la racine du dépôt — lis-le intégralement avant toute action.

Règles absolues à respecter sans exception :
- Ne jamais toucher à la production (projet Firebase az-express-b0469).
- Ne jamais déployer quoi que ce soit (Cloud Functions, Rules, Hosting, Storage).
- Ne jamais modifier Firestore, ni créer/modifier un compte Firebase Auth au-delà de ce qui
  est explicitement autorisé ci-dessous.
- Ne jamais demander à l'utilisateur de coller un mot de passe dans le chat.
- Ne jamais afficher, logger ou stocker un secret, token, clé ou mot de passe.
- Ne jamais committer ni pousser de code sans autorisation explicite.

État actuel (voir AZ_EXPRESS_AUDIT_HANDOFF.md pour le détail complet) :
- L'APK Android Release 1.0.10+11 est vérifié et fonctionnel sur un appareil réel.
- Le projet az-express-preprod existe et est utilisé comme environnement de test isolé.
- Un outil isolé et testé (test-env/reset-test-passwords.js, 15 tests unitaires PASS) est prêt
  à réinitialiser UNIQUEMENT le mot de passe Auth de client.test@az-test.invalid et
  livreur.a@az-test.invalid sur az-express-preprod. Le code a été entièrement audité : il ne
  peut pas créer de compte, ne touche jamais Firestore, et refuse toute cible hors de ce
  périmètre exact.
- Les précontrôles (code, tests, Project ID réel, dry-run) sont tous confirmés PASS.
- L'exécution réelle (--execute) n'a PAS eu lieu : credentials Admin SDK non confirmés dans
  l'environnement précédent, et contrainte de confidentialité du mot de passe (il doit être
  tapé uniquement par le propriétaire, dans son propre terminal, jamais transmis à un
  assistant IA).

Ta tâche : m'aider à finaliser cette étape en respectant exactement les mêmes contraintes
(précontrôles avant toute action, jamais d'exécution réelle par toi-même, jamais de mot de
passe dans le chat), puis à rédiger le rapport final de Phase 10.7 UNIQUEMENT sur la base du
résultat réel que je te communiquerai (succès ou échec par compte, sans le mot de passe).
Ne suppose jamais qu'une opération a réussi sans preuve. N'entame aucune phase suivante sans
mon autorisation explicite.
```
