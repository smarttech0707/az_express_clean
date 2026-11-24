# Mission 7E-77 — Revue finale et préparation des commits 1 et 1B

> **[Mise à jour 7E-80]** Ce rapport décrit l'état à la date de 7E-77. Le message de refus a été aligné par 7E-79 : la condition « valider le texte du message » (§10 a) et les mentions « variante ASCII » (§3, §7) sont dépassées ; les autres réserves (§8) sont inchangées. Le manifeste (§4–5) reste exact quant aux listes de fichiers.

Date : 2026-11-07 · Strictement local et préparatoire. **Préparation ≠ autorisation** : aucun commit n'est autorisé par ce document. Aucun `git add`, `git apply --cached`, commit, push, pull, merge, reset, déploiement ni commande distante. `operations_control/account_deletion` non créé. `D:\h75.txt` non lu, non supprimé. Rapports antérieurs non modifiés (les écarts relevés en §3 sont listés, pas corrigés).

## 1. État Git
| | Initial | Final |
|---|---|---|
| HEAD / branche | `aa3d1b0` / `finalisation/az-express` | `aa3d1b0` / `finalisation/az-express` |
| Index | vide (0 fichier) | vide (0 fichier) |
| Entrées | 90 = 27 suivies modifiées + 63 non suivies (dont les 7 rapports 7E76) | 91 = 90 + ce rapport |
| Fichiers parasites dans le dépôt | aucun nouveau (les `.aab`, `.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `qr-release/`, `scripts/*`, `test-env/.emulators.pid`, `web/downloads/`, cache Hosting préexistaient et ne sont pas touchés) | idem |
Différence HEAD / arbre de travail pour le périmètre : 13 fichiers (§4, §5) ; le reste (P2, P3, E-Kbine, tests de garde, script de déploiement, docs, pages légales) est hors des deux commits. Les sept rapports `docs/ACCOUNT_DELETION_7E76_*.md` sont présents.

## 2. Audit des sept rapports 7E-76
Les sept ont été lus intégralement. Le fond est cohérent avec le code et les mesures de cette mission. Les affirmations d'état (HEAD, index, 9 fichiers identiques à 7E-75, 31/31, 86/86, 2280/2328) sont vérifiées ou revérifiées en §6.

## 3. Écarts relevés dans ces rapports (à corriger après autorisation, aucun ne change le verdict)
1. `FLUTTER_CONTRACT_TESTS` §3 cite « Reessayer plus tard » ; le texte réel du code est « **Reessayez** plus tard » (§7 ci-dessous = texte exact).
2. `CALLABLE_ERROR_CONTRACT` §4 : « le code déployé n'est pas concerné d'après les 135 exports et son historique de production, non vérifié ici » est **non étayé** (135 exports ne dit rien sur `FieldValue`). Lire : « non démontré ».
3. `CALLABLE_ERROR_CONTRACT` §1 : « remonte (INTERNAL côté client) » est une inférence ; cette erreur de lecture n'a pas été observée sur le transport réel.
4. `FUNCTIONS_FULL_SUITE` « Durée anormale » : l'explication (machine chargée, émulateurs de l'utilisateur actifs) est une hypothèse, non mesurée.
5. `COMMIT1_REVIEW` §1 renvoie à « §2 » pour la comparaison à la copie reconstruite ; cette comparaison figure dans `FINAL_DECISION` §1, pas dans §2.
6. `FINAL_DECISION` : la formulation du message de refus y est tronquée (« … ») ; le texte complet est en §7 ci-dessous.

## 4. Manifeste du commit 1 — backend (9 fichiers, rien n'est indexé)
| # | Fichier | État | Justification |
|---|---|---|---|
| 1 | `functions/accountDeletion.js` | modifié (+81) | refus de passerelle avant toute écriture, `details.reason`, plafond de tentatives, limiteur/audit injectés |
| 2 | `functions/accountCleanup.js` | nouveau (137 l.) | purge à liste blanche et inspection ; importé par 1 et 3 (absent de HEAD) |
| 3 | `functions/partnerAccountDeletion.js` | modifié (+25) | inspection avant suppression Auth, plafond, purge partagée (périmètre partenaires fermé) ; importé par 1 |
| 4 | `functions/accountDeletionSupport.js` | modifié (+6) | reprise motivée après plafond de tentatives |
| 5 | `functions/index.js` | **hunk 3 seulement** | 1 ligne : `…HttpsError,checkRateLimit,logAudit,` — sans elle le moteur refuse (`RATE_LIMITER_REQUIRED`) |
| 6 | `functions/test/accountDeletionHardening.test.js` | nouveau (471 l., 26 tests) | tests unitaires, dont passerelle fermée/ouverte |
| 7–9 | `rules-tests/account-deletion.test.js`, `…-lifecycle.test.js`, `…-real.test.js` | modifiés | état réel sur émulateur ; les deux derniers : injection du limiteur (1 ligne chacun) |

**Vérifications de cette mission**
- `index.js` : `git diff` donne 9 hunks ; le hunk 3 (`@@ -87 +90 @@`) est identique, ligne pour ligne, au contenu de `index_p1.patch`. Les 8 autres hunks sont P2/P3 et **ne doivent pas** être indexés.
- Les diffs des fichiers 3, 4, 7–9 relus : uniquement des changements de suppression de compte (aucune modification étrangère). Aucun secret, `.env`, clé ni identifiant réel dans les 12 fichiers (les occurrences de « secret » sont des noms de sous-collection de test). `git diff --check` : aucune erreur d'espaces (avertissements LF/CRLF attendus).
- Comportement attendu, appuyé sur les tests : refus avant toute écriture (absente / désactivée / version ≠ 1) ; `details.reason = ACCOUNT_DELETION_NOT_ENABLED` ; limiteur non appelé en cas de refus ; ni dossier, ni tombstone, ni audit ; `deletionRequested` inchangé ; passerelle ouverte inchangée (idempotence, limiteur, audit). Preuves : tests unitaires (Hardening 26/26, comparaison du magasin complet avant/après) et transport callable réel sur émulateur (7E-76 : HTTP 400, état identique).

## 5. Manifeste du commit 1B — Flutter (4 fichiers, rien n'est indexé)
| # | Fichier | Justification |
|---|---|---|
| 1 | `lib/services/account_deletion_service.dart` | `AccountDeletionUnavailableException` ; `isGateClosedRefusal` (lit `e.details` comme `Map`, `details['reason']` en priorité, repli sur le message, `failed-precondition` exigé) ; `resolveCallableFailure` (refus de passerelle → exception sans lire d'ancien reçu ; autre erreur → `checkLastRequest` comme avant) |
| 2 | `lib/widgets/account_deletion_dialog.dart` | affiche le refus ; `unauthenticated` ajouté aux codes de réauthentification |
| 3 | `test/services/account_deletion_service_test.dart` | 6 tests de contrat (convertisseur réel du plugin, Web, autres erreurs, ancien reçu, demande enregistrée) |
| 4 | `test/widgets/account_deletion_dialog_test.dart` | 3 tests widget (refus de passerelle, panne réseau, réauthentification) |
Relu : aucune modification de thème, mise en page ou navigation ; l'absence de faux message de confirmation est testée (aucun « Votre demande est conservee », aucun SnackBar).

**Ordre recommandé : commit 1, puis commit 1B** (1B indépendant du code backend grâce au repli, mais à livrer avant toute diffusion de l'application). Les commandes de staging de `ACCOUNT_DELETION_7E75_COMMIT_COMMANDS.md` ne sont ni reprises ni exécutées ici ; leurs listes de fichiers restent exactes (9 + 4).

## 6. Tests
**Exécutés pendant cette mission (7E-77)**
| Test | Résultat |
|---|---|
| Node 22.23.4 : Hardening + Support + manualAccountDeletion | 51/51 |
| Node 22.23.4 : Hardening seul | 26/26 |
| Node 22.23.4 : chargement de `functions/index.js` de l'arbre de travail (contient aussi P2/P3) | 135 exports |
| `flutter test` service + dialogue | 31/31 |
| `flutter analyze` des 4 fichiers Flutter | aucune anomalie |
| `git diff --check` (fichiers suivis du périmètre) | aucune erreur |
| Comparaison hunk 3 / `index_p1.patch` | identique |

**Non exécutés dans cette mission** (derniers résultats connus, 7E-74/75/76) : suite Functions complète Node 22 (2328 : 2280 OK, 1 échec `dispatchRetry`, 47 ignorés, 94 min) ; règles de suppression 69/69 ; règles Firestore 470 et Storage 128 (7E-74) ; transport callable sur émulateur Functions ; suite Flutter complète ; tout test sur appareil, SDK natif ou Firebase réel ; tout essai de commit/staging.

## 7. Texte exact du message de refus (`AccountDeletionUnavailableException.message`) — **état à la date de 7E-77 ; remplacé par 7E-79**
> **[Mise à jour 7E-80]** Le texte ci-dessous est l'ancienne variante ASCII, historique. Depuis 7E-79, le code affiche : « Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. »

« Le service de suppression de compte n est pas disponible pour le moment. Votre demande n a pas ete enregistree et votre compte reste inchange. Reessayez plus tard ou contactez le support. »
(sans accents ni apostrophes, convention du fichier). La formule proposée dans la mission 7E-76 — « Service de suppression indisponible. Votre demande n'a pas été enregistrée. » — n'est pas celle implémentée ; décision humaine requise. Il n'est affiché que pour cette exception, levée uniquement par `resolveCallableFailure` sur un refus de passerelle.

## 8. Réserves (aucune n'est transformée en validation)
1. **SDK natif Android/iOS non testé** : la forme de `PlatformException.details` est déduite de la lecture du code du plugin `cloud_functions 6.3.2` ; test requis sur appareil (ou acceptation explicite) avant diffusion.
2. **`dispatchRetry.emulator`** (phase 2) échoue encore ; indépendant de P1 d'après imports et état Git, cause racine non analysée ; à traiter séparément ; la suite complète n'est donc pas verte.
3. **Couverture financière incomplète** tant que le commit 2 (P2) n'est pas livré : la quarantaine n'est pas appliquée aux paiements, retraits, webhook, AZ IA.
4. **`admin.firestore.FieldValue`** indéfini sous l'émulateur Functions de cet environnement : cale utilisée uniquement dans la copie de test hors dépôt pour le cas « ouvert » ; cause non élucidée, impact sur le code déployé non démontré.
5. **Firestore illisible** : validé par test unitaire à faux Firestore ; **non** validé sur le transport callable réel.
6. **Quota Cloud Run : QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (18,75 vCPU théoriques ≠ capacité disponible ; vérification humaine dans `az-express-preprod`, `europe-west1`).
7. C2 et E-Kbine « 8 appels » : intermittents d'émulateur, passés dans la dernière suite, non résolus ; suite très lente (94 min).
8. Le test Flutter importe un chemin `src/` du plugin : fragile aux mises à jour du plugin (aucun impact applicatif).

## 9. Fichier `D:\h75.txt` (hors dépôt)
Présent. Sortie de test créée par erreur à la racine du disque D en 7E-75 ; il ne fait pas partie du dépôt et n'est pas lu ici. Procédure manuelle (PowerShell, par vous) :
```powershell
Get-Item D:\h75.txt | Select-Object FullName, Length, LastWriteTime   # vérifier la taille et la date
notepad D:\h75.txt                                                   # optionnel : l'ouvrir pour contrôle
Remove-Item D:\h75.txt                                               # suppression, si vous le souhaitez
```

## 10. Conditions avant autorisation humaine
(a) valider le texte du message (§7) ; (b) décider d'un essai appareil du SDK natif ou l'accepter explicitement ; (c) accepter l'échec `dispatchRetry` comme point séparé ; (d) accepter l'écart de couverture financière avant le commit 2 ; (e) confirmer 1 et 1B en deux commits dans cet ordre ; (f) corriger ensuite les écarts documentaires du §3 ; (g) supprimer `D:\h75.txt` si souhaité ; (h) toute exécution de `git add`/`git apply --cached`/commit demande une autorisation distincte et explicite.

## Verdict
**COMMIT 1 PRÊT — COMMIT 1B SOUS CONDITIONS** (inchangé par rapport à 7E-76). Commit 1 : périmètre exact, hunk 3 vérifié, comportement prouvé localement. Commit 1B : conditionné au texte du message et à l'essai natif.
