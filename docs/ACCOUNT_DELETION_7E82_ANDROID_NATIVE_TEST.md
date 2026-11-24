# Mission 7E-82 — Test natif Android du commit 1B

Date : 2026-11-07 · Appareil réel, émulateurs Firebase **locaux uniquement**. Aucun `git add`, `git apply --cached`, commit, push, déploiement ni commande distante. Production `az-express-b0469` jamais utilisée. `operations_control/account_deletion` créé **uniquement dans mon émulateur Firestore local** (détruit avec lui) ; jamais en prod/préprod. Comptes et données synthétiques (`*@az-test.invalid`). Ce rapport est non suivi.

## 1. Environnement de test
| Élément | Valeur |
|---|---|
| Appareil | Samsung SM-A115F, Android 12 (API 31), armeabi-v7a (le second téléphone, Infinix Android 15, était verrouillé : non utilisé) |
| Flutter / SDK | Flutter 3.44.5 ; `cloud_functions` 6.3.2 (platform_interface 6.0.2) |
| APK | build debug du code de l'arbre de travail (commit 1B inclus), `applicationId` `com.azexpress.app.test`, projet `demo-az-express`, garde-fous `FirebaseEmulatorConfig` actifs (refus de tout projet non `demo-`) ; scan d'identifiants de production passé ; `google-services.json` de test retiré après build |
| Backend | Functions/Auth/Firestore émulés, fonctions extraites **de l'archive du commit 65e738b** (copie de staging), ports dédiés 15001 / 18080 / 19099 (distincts des émulateurs de l'utilisateur 5001/8080/9099, laissés intacts) |
| Mode de connexion | USB `adb reverse` (5001→15001, 8080→18080, 9099→19099) vers l'hôte ; l'app vise 127.0.0.2 via `FirebaseEmulatorConfig` |
| Preuve d'isolation | le compte de test n'existe que dans mon émulateur Auth ; la connexion a réussi ; les journaux de mon émulateur montrent chaque appel (`requestAccountDeletionCF`) ; projet `demo-` imposé par l'app ; aucune clé de production dans l'APK de test |
| Limite d'isolation | le blocage réseau au niveau OS (`usb-isolation.ps1`) n'est pas supporté sur Android 12 : l'isolation repose sur la configuration émulateur de l'app (non contournable : refus des projets non `demo-`) et sur le fait que seul le compte local réussit à se connecter. Le téléphone garde son accès Internet normal. |

## 2. Résultats par scénario
| # | Scénario | Résultat | Preuves |
|---|---|---|---|
| A1 | Porte fermée — document de contrôle **absent** | **PASS réel sur appareil** | Message affiché égal, caractère pour caractère, à « Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. » (comparaison programmatique du texte de l'arbre d'accessibilité = `True`) ; capture `A_gate_absent.png` ; l'émulateur a exécuté `requestAccountDeletionCF` ; aucun `account_deletions` / `account_tombstones` / `account_deletion_requests`, aucun audit `account_deletion_requested`, aucun `rate_limits` pour l'UID testé |
| A2 | Porte fermée — `enabled:false, inventoryVersion:1` | **PASS réel sur appareil** | Même message exact (`True`), 2ᵉ appel serveur confirmé ; capture `A2_gate_disabled.png` ; aucune écriture de dossier |
| B | **Ancien reçu local authentique** + porte fermée | **PASS réel sur appareil** | Reçu réel créé par une vraie demande (porte ouverte, compte synthétique n°2, `status: quarantined`) ; stocké dans `SharedPreferences` (`accountDeletionRecovery`, clés `uid`,`token`), valide côté serveur (vérifié par appel direct). Porte refermée, compte n°1 : refus exact affiché, **aucun appel `getAccountDeletionStatusCF` supplémentaire** (compteur inchangé) → l'ancien reçu n'est pas lu ; aucun écran « demande conservée » ; capture `B_old_receipt.png` |
| C | Réseau coupé (tunnel 5001 supprimé, seuls les Functions) | **PASS réel sur appareil** | Message distinct : « Enregistrement non confirme. Verifiez votre connexion ou contactez le support. Aucune suppression confirmee. » ; le message de refus n'apparaît pas ; capture `C_network_cut.png` |
| D | Autres erreurs (`unauthenticated`, `invalid-argument`, `resource-exhausted`, `unknown`, `internal`) | **NON TESTÉ sur appareil** (partiel : `unavailable` observé en C) | Non productibles nativement sans modifier le backend ou la configuration (le dialogue exige une session ; `resource-exhausted` exigerait une porte ouverte, donc une vraie quarantaine du compte). Couverts seulement par tests unitaires/widget (boucle de 5 codes, 31/31 en 7E-79) — **les tests unitaires ne sont pas des tests natifs** |

### Étape préparatoire (hors scénario)
Une vraie demande a été soumise avec la porte **ouverte** (compte n°2) pour obtenir un reçu authentique : dossier, tombstone et audit `account_deletion_requested` existent donc dans l'émulateur **pour cet unique UID** (comportement nominal attendu, `status: quarantined`, l'app a fermé la session). Aucun pour le compte n°1 testé en A/B/C. L'état de l'émulateur est détruit avec lui.

## 3. Ce qui n'est PAS démontré
1. **Forme brute de `e.details`** : l'application n'imprime pas l'exception ; aucune trace dans logcat (0 occurrence de `FAILED_PRECONDITION`/`ACCOUNT_DELETION`). Le comportement affiché prouve que le refus est reconnu **de bout en bout**, mais — le message d'erreur serveur étant lui aussi `ACCOUNT_DELETION_NOT_ENABLED` — **le test ne distingue pas** la reconnaissance via `details['reason']` de la reconnaissance de repli par le texte du message. La forme exacte de `PlatformException.details['additionalData']` reste déduite du code du plugin (non observée).
2. Scénario D hors `unavailable`.
3. iOS non testé ; un seul appareil Android 12.
4. Isolation OS (blocage réseau) non disponible sur ce téléphone.
5. Réserves inchangées : `dispatchRetry.emulator` en échec historique ; couverture financière incomplète avant le commit 2 ; `admin.firestore.FieldValue` sous l'émulateur (la demande « porte ouverte » a pourtant abouti dans cet environnement) ; **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.

## 4. Contrôles finaux
| Contrôle | Résultat |
|---|---|
| HEAD | `65e738b`, branche `finalisation/az-express`, aucun commit ajouté, aucun push |
| Index | vide (0 fichier) |
| Backend / fichiers du commit 1 | inchangés (pas de diff sur les 9 fichiers autres que les hunks P2/P3 préexistants de `functions/index.js`) |
| 4 fichiers du commit 1B | toujours modifiés, non committés, non touchés par cette mission |
| Configuration temporaire | `android/app/google-services.json` = original (projet de production, ignoré par Git, date 14/08/2026, intact) ; copie de test supprimée ; aucun fichier permanent n'a reçu d'identifiant de projet de test ; scripts et captures dans le scratchpad hors dépôt |
| Tunnels ADB | tous supprimés (`reverse --list` vide) |
| Émulateurs | les miens (config `fb82.json`) arrêtés ; ceux de l'utilisateur (5001/8080/9099) toujours actifs |
| Dépôt | seuls fichiers nouveaux : ce rapport (`git status` : 87 entrées = 86 + ce rapport) |
| Application de test | `com.azexpress.app.test` reste installée sur le Samsung (désinstallable : `adb uninstall com.azexpress.app.test`) ; permission micro refusée pendant le test |
| `D:\h75.txt` | non lu, non supprimé |

## Verdict
**TEST PARTIEL — COMMIT 1B SOUS CONDITIONS**

Le comportement de refus de bout en bout est validé sur un vrai téléphone (A1, A2, B, C : message exact, aucun faux reçu, aucune écriture, erreur réseau distincte). Conditions restantes : le scénario D natif et la forme brute de `details` ne sont pas démontrés (acceptation explicite ou test complémentaire), plus les réserves habituelles ci-dessus. Aucun commit créé. En attente d'une nouvelle autorisation humaine distincte.
