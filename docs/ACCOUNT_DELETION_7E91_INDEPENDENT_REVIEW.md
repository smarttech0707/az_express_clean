# Mission 7E-91 — Revue indépendante et consolidation du lot 2B

Date : 2026-11-09 · Strictement local. Aucun `git add`, commit, push, pull/merge/rebase/reset, déploiement, commande distante, changement de secret, activation de FeexPay. Production `az-express-b0469` non touchée ; émulateurs de l'utilisateur (5001/8080/9099) non touchés. Rapport non suivi.

## 1. Revue des modifications 2B (7E-90)
Relecture des diffs : `deliveryQuote.js` (+4/−0), `orderActions.js` (+7/−0), tests `walletDebitQuarantineGuards` et `walletDebitQuarantine.emulator`.
| Point | Constat |
|---|---|
| Garde réellement dans la transaction | **Oui** : `assertNewAccountActivity(tx, …)` est appelée avec l'objet `tx` du callback de `db.runTransaction` dans les trois fonctions (`createOrderFromQuoteCF` après `assertActiveClient` ; `payBoutiqueOrderCF` juste après la lecture du client, partenaire `sellers/{sellerId}` ; `payBoutiqueOrderCashCF` avant la première écriture). Aucune lecture hors transaction. |
| Lectures avant écritures | Respecté : toutes les lectures de la garde précèdent la première écriture (vérifié par un faux Firestore qui lève sur toute lecture après écriture, et par l'émulateur réel). |
| Appels asynchrones | Tous `await`és, séquentiels ; aucune opération lancée sans attente dans les callbacks. |
| Rejeu de devis | Sorti avant la garde (aucune écriture) : reste servi après quarantaine, sans nouveau débit. |
| Premier niveau de défense | Les trois callables passent par le wrapper `onCall` d'`index.js` (contrôle d'entrée `assertAccountEnabled` → `permission-denied` / `ACCOUNT_DELETION_IN_PROGRESS`) ; la garde transactionnelle est le second niveau, indispensable pour la course. |
| `payOrderFromWalletCF`, 2C, 2D | Absents des diffs 2B. |
Aucune anomalie de code trouvée dans les modifications 2B.

## 2. Erreur `Transaction is invalid or closed` (priorité)
**Instrumentation** (script hors dépôt, émulateur `demo-7e91` isolé) : `runTransaction` enveloppé pour tracer chaque tentative (lectures, écritures, exceptions). Sur 40 rondes `createOrderFromQuoteCF` ∥ quarantaine : 24 acceptées, 9 refusées par la garde, **7 erreurs**. Trace identique pour les 7 :
- transaction de l'APPEL : **une seule tentative** : `get(devis) → get(client) → get(commande) → get(account_tombstones/uid)` ⇒ échec `3 INVALID_ARGUMENT: Transaction is invalid or closed` sur cette dernière lecture (CB_THROW, aucune écriture jamais émise) ;
- transaction de QUARANTAINE concurrente : **deux tentatives** (la première rejouée par le SDK), puis validée.
Donc : la transaction de l'appel est invalidée côté serveur au moment où la quarantaine (qui écrit le profil lu) l'emporte ; la **lecture suivante** dans la même transaction reçoit `INVALID_ARGUMENT` au lieu d'un `ABORTED` rejouable, et le SDK Admin ne rejoue pas cette erreur.

**Témoin sans aucun code AZ Express** (SDK pur, 200 rondes chacune, 2 variantes) : transaction A = lire le profil [+ lire un autre document] puis écrire ; transaction B = lire le profil, créer un document, modifier le profil :
| Variante | Erreurs `Transaction is invalid or closed` | Tentatives de la transaction en échec |
|---|---|---|
| A lit le profil **puis un second document** | **14 / 200** | 1 à chaque fois |
| A lit le profil seulement | **0 / 200** | — |
Reproduit sans notre code (même signature : 1 tentative, échec sur la lecture suivant la lecture du profil).

**Conclusion** : les causes côté application sont écartées (pas d'objet transaction réutilisé, pas de lecture après écriture, pas d'opération après fermeture, pas de promesse non attendue, aucune exception masquée : l'erreur remonte telle quelle). La cause est une invalidation de transaction sous contention par le serveur de l'émulateur, déclenchée par toute lecture qui suit la lecture d'un document modifié par la transaction concurrente — ce que la garde ajoute (second document : tombstone), mais aussi tout flux existant qui lit plusieurs documents. **Non prouvé pour Firestore de production** (aucun test distant) : la production retourne en principe `ABORTED` (rejoué par le SDK), mais ce n'est pas démontré ici. Le code n'a pas été modifié pour faire disparaître l'erreur.
**Effet** : échec sans effet (aucun débit, aucune commande, devis non consommé : vérifié dans toutes les rondes) ⇒ fail-closed. Pour l'utilisateur : erreur non-`HttpsError` ⇒ `internal`, traitée côté Flutter comme transitoire (§5).

## 3. Nouveaux scénarios de concurrence (`walletDebitQuarantineOrderings.emulator.test.js`, nouveau)
Quatre ordonnancements par fonction, 74 rondes chacune, données synthétiques isolées (clients, vendeur et produit propres à chaque scénario, `demo-7e91`, `127.0.0.1:18089`) :
- `quarantine_first` : quarantaine validée avant l'appel (12 rondes) ;
- `call_first` : appel validé avant la quarantaine (12) ;
- `during` : la quarantaine démarre **dans la transaction de l'appel**, après la lecture du tombstone puis du dernier document de la garde, la transaction restant ouverte 0-120 ms (25) ;
- `jitter` : décalage aléatoire de la quarantaine sur 0–1,6 × la durée mesurée d'un appel (25).
Invariants à chaque ronde : tombstone toujours créé ; toute commande validée (`createTime`) ≤ tombstone ; refus ⇒ aucune commande et solde intact ; accepté ⇒ exactement un débit et une commande (boutique : achat + course) ; **motif de refus contrôlé** (garde, ou erreur de contention comptée à part ; tout autre motif échoue) ; nouvelle tentative après refus ⇒ toujours refusée sans effet ; quote : rejeu après acceptation ⇒ même commande, aucun nouveau débit ; en fin de scénario : stock retiré = nombre d'acceptations (aucun double retrait), crédit vendeur = débits clients.

Résultats (3/3 PASS, 222 rondes, 286 s) :
| Fonction | quarantine_first | call_first | during | jitter |
|---|---|---|---|---|
| Q1 `createOrderFromQuoteCF` (≈136 ms/appel) | 0 acceptée / 12 garde | 12 / 0 | 19 acceptées / 6 garde / 0 contention | 15 / 6 / **4 contention** |
| Q2 `payBoutiqueOrderCF` (≈180 ms) | 0 / 12 | 12 / 0 | 22 / 3 / 0 | 13 / 12 / 0 |
| Q3 `payBoutiqueOrderCashCF` (≈145 ms) | 0 / 12 | 12 / 0 | 25 / 0 / 0 | 18 / 7 / 0 |
Les deux côtés (accepté et refusé) sont exercés pour les trois fonctions via `during`+`jitter`, contrairement à 7E-90 (boutique : 1/25 et 0/25 acceptées). Lecture : quand la quarantaine démarre après la lecture de la garde, la transaction concurrente attend et la commande est validée AVANT le tombstone (accepté) ; sinon la garde refuse. **Limite** : en `during`, Q3 n'a jamais été refusée (25/25 acceptées) : ce chemin de refus tardif n'est exercé pour l'espèces que par `jitter` (7). Les 7E-90 (Q0–Q5) n'ont pas été affaiblis ; non rejoués après l'ajout d'une branche `else` (voir §6).

## 4. Idempotence
Quote : rejeu d'un devis utilisé ⇒ même `orderId`, solde inchangé (unitaire + émulateur, y compris après quarantaine) ; Q4 (7E-90) : trois appels simultanés ⇒ un seul débit. Boutique : aucune clé d'idempotence (inchangé, hors périmètre 2B) : un second appel réussi crée un second achat, protégé par solde et stock ; Q5 (7E-90) : deux achats pour un solde ⇒ un seul. Après refus de quarantaine : les tentatives répétées restent refusées sans effet.

## 5. Flutter — traitement des refus de `createOrderFromQuoteCF`
Chemin : `CloudDeliveryQuoteGateway` → `DeliveryQuoteService.createOrder` → `QuotedCheckout.run` → `runQuotedCheckoutWithUi` → écrans `livraison_screen` / `courses_screen`. Le flux est **inactif** (`QuotedOrderConfig.enabled = false`, espèces bloquées, wallet seul).
Comportement constaté (inchangé) : une `FirebaseFunctionsException` non transitoire (`failed-precondition`, `permission-denied`) devient `QuotedOrderRefused` → `CheckoutFailed` → snack rouge ; jamais `QuotedOrderCreated`, jamais de commande locale, reprise en attente effacée (le magasin n'est pas conservé pour un refus). `internal`/`unavailable`/réseau ⇒ rejoué 3 fois (idempotent par devis) puis `QuotedOrderUncertain` (« Réponse non reçue… vérifier »), jamais présenté comme un refus.
**Défaut trouvé** : le refus le plus fréquent est celui du wrapper (`permission-denied`, message `ACCOUNT_DELETION_IN_PROGRESS`) : le jeton technique s'affichait tel quel. Le serveur n'envoie pas de `details.reason` pour ces refus (contrat serveur inchangé, comme demandé).
**Adaptation minimale** ([lib/widgets/quoted_checkout_runner.dart](lib/widgets/quoted_checkout_runner.dart), +12/−0) : `isAccountClosingRefusal` (les deux refus connus) et un message clair dans `quotedFailureMessage` : « Votre compte est en cours de suppression : aucune nouvelle commande ne peut être passée. Rien n'a été débité. ». Les autres codes gardent leur message.
**Tests** (`test/quote/quote_account_closing_test.dart`, nouveau, 6 tests) : `failed-precondition` ⇒ refus unique (1 appel, 0 commande, 0 débit, aucune reprise) ; `permission-denied` ⇒ idem, jeton jamais affiché ; autres `permission-denied`/`failed-precondition` non pris pour une suppression de compte ; `internal` ⇒ 3 appels puis incertain (reprise conservée) ; reprise ensuite refusée ⇒ aucune commande, reprise effacée, pas de faux succès ; panne réseau ⇒ incertitude. **Fragilité** : la détection repose sur le texte du serveur (`ACCOUNT_DELETION_IN_PROGRESS` et `Compte supprime ou en cours de suppression`) ; à remplacer par un `details.reason` si le contrat serveur est un jour étendu.

## 6. Tests et non-régression (Node 22.23.4, Flutter)
| Contrôle | Résultat |
|---|---|
| Unitaires 2B (`walletDebitQuarantineGuards`) | 28/28 PASS (dans la suite complète) |
| Émulateur, ordonnancements (nouveau) | 3/3 PASS, 222 rondes |
| Émulateur, diagnostic et témoin SDK | voir §2 (hors dépôt) |
| Functions `node --test test/*.test.js` | **2350 tests : 2182 PASS, 0 FAIL, 168 ignorés**, `index.js` se charge |
| Flutter `flutter test test/quote/` | **55/55 PASS** |
| `flutter analyze` (2 fichiers) | No issues found (un `prefer_const_constructors` signalé puis corrigé dans le nouveau test) |
**Écart de comptage à signaler** par rapport au résultat historique (2349 / 2183 / 0 / 166) : +1 test, −1 réussi, +2 ignorés. Cause : sans émulateur, un fichier de test dont les scénarios sont conditionnels comptait comme **1 « réussi »** (c'était le cas du fichier émulateur de 7E-90 dans les 2183, et du nouveau fichier). J'ai ajouté une branche `else` dans les deux fichiers 2B qui enregistre un test **ignoré** : le faux « réussi » disparaît (2183→2182) et deux ignorés apparaissent (166→168) ; total 2349→2350 (nouveau fichier). Aucune assertion modifiée. Ce n'est pas une régression. L'ajout de cette branche `else` n'a pas été suivi d'un rejeu du fichier émulateur de 7E-90 (le code conditionnel exécuté avec émulateur est inchangé ; le chargement a été vérifié).

**Incident d'environnement** : le disque C: est tombé à ~47 Mo libres ; Flutter a échoué (« Free up space », copie du `.dill`) et deux exécutions se sont bloquées (code 124 après 900 s). J'ai arrêté uniquement mes trois processus Dart (créés à 15:07:56-15:08:02, ma relance) et supprimé quatre dossiers temporaires éphémères `flutter_tools.*` de `%TEMP%` : ~349 Mo libres ensuite, puis exécution propre. Le dossier `%TEMP%\az_build_android` (2,8 Go, provenance non établie) n'a **pas** été touché : à examiner par vous si le disque reste saturé.

## 7. Limites restantes
1. Cause de l'invalidation de transaction démontrée sur l'émulateur et le SDK seuls ; comportement de Firestore de production non prouvé.
2. Le refus tardif de `payBoutiqueOrderCashCF` en mode `during` n'a pas été observé (seul `jitter` l'exerce).
3. Tests d'émulateur : absence de violation sur des entrelacements tirés, pas de preuve d'absence de toute course.
4. Pas d'idempotence pour les achats boutique (existant, hors lot).
5. Détection Flutter basée sur le texte serveur ; flux devis inactif, jamais testé sur appareil/émulateur Android dans cette mission.
6. Lots 2C/2D, commit 3, outil `held_for_review` et quota inchangés : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## 8. Contrôle des lots et état Git
HEAD `294332e42bfb352b71eca861b08d6f36dee6e853`, branche `finalisation/az-express`, index vide, aucun commit supplémentaire, aucun push/déploiement, `git log` inchangé. `functions/index.js` : 8 hunks (7 P2 du lot 2A inchangés + hunk P3 `setPharmaciePassword` distinct) ; `accountAdmission.js`, `feexpayPayments.js` (lot 2A) non modifiés par cette mission ; `payOrderFromWalletCF` absent des diffs 2B ; commits 1/1B et quatre fichiers Flutter du 1B inchangés ; `pubspec.lock` inchangé. Nouveautés de la mission : `lib/widgets/quoted_checkout_runner.dart` (modifié, +12/−0), tests `functions/test/walletDebitQuarantineOrderings.emulator.test.js`, `test/quote/quote_account_closing_test.dart` (nouveaux) ; branche `else` ajoutée à `walletDebitQuarantine.emulator.test.js` (non suivi). `git status` : 99 entrées avant ce rapport. `git diff --check` : uniquement des avertissements LF/CRLF.

## 9. Opérations distantes
Aucune. Émulateur Firestore local isolé (`demo-7e91`, ports 18089/14400/14500/9151) arrêté et libre ; 5001/8080/9099 toujours en écoute (non touchés). `D:\h75.txt` non lu.

## Verdict
**LOT 2B VALIDÉ — PRÊT POUR REVUE FINALE**
Cause de l'erreur de transaction établie et reproduite hors de notre code (effet fail-closed vérifié, production non prouvée) ; concurrence boutique renforcée sur les deux côtés de la course ; traitement Flutter vérifié et corrigé a minima, 55/55. Réserves : §7. Aucun commit créé. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
