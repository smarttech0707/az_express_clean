# Mission 7E-72 — Analyse de l'échec `E-Kbine création : 8 appels simultanés`

Date : 2026-11-07 · Test : `functions/test/financialConcurrency.emulator.test.js:93` · Code testé : `buildEkCreateOrder` (`functions/ekbineOrders.js`) · Émulateur Firestore uniquement, projets `demo-*`. Aucune commande distante.

## 1. Les faits relevés en 7E-71

Suite complète sous émulateurs : `assert.equal(ok(results).length, 8)` a reçu **7**. Rejeu du fichier seul : 12/12, trois fois, émulateur neuf. Le test n'avait pas échoué en 7E-69.

## 2. Ce qui a été examiné

| Point demandé | Constat |
|---|---|
| Test et code de création | Huit appels identiques (même client `e1`, même `idempotencyKey`) → même `orderId` déterministe (`sha256(uid:clé)`). Chaque appel exécute une transaction qui **lit** la commande et le client, puis **débite** le client et **crée** la commande, ou renvoie `alreadyDone`. Aucune garde de quarantaine n'existait dans ce chemin avant 7E-72. |
| Identifiants et données partagées | `clients/e1` n'est écrit que par ce test pour l'émulateur (les autres fichiers qui citent `e1` utilisent le faux Firestore en mémoire). Le test fait `set` du client avant l'appel : aucune dépendance à un état antérieur. La clé `same-key-aaaaaaaaaaaa` n'existe que dans ce fichier. Aucune collision avec mes tests de concurrence (préfixe `qz71_`). |
| Transactions | `db.runTransaction` (Admin SDK `@google-cloud/firestore` 7.11.6), lecture de 2 documents avant toute écriture, `tx.create` pour la commande (échoue si elle existe). Conforme à la règle « lecture avant écriture ». |
| Conflits / retries | Les 8 transactions se disputent les mêmes 2-3 documents. L'Admin SDK relance une transaction pour `ABORTED`, `CANCELLED`, `UNKNOWN`, `DEADLINE_EXCEEDED`, `INTERNAL`, `UNAVAILABLE`, `UNAUTHENTICATED`, `RESOURCE_EXHAUSTED`, et pour `INVALID_ARGUMENT` **seulement si** le message contient « transaction has expired » (`transaction.js`, `isRetryableTransactionError`). |
| Nettoyage entre tests | Aucun nettoyage global : l'émulateur conserve les données de tous les fichiers de la suite ; chaque test utilise ses propres identifiants. Pas de cause de ce côté. |
| Effets de bord avec les tests financiers voisins | Les trois autres tests E-Kbine du fichier utilisent d'autres clients (`e2`…`e4`). Aucune écriture croisée relevée. |

## 3. Reproduction contrôlée

Sonde locale (hors dépôt, dossier temporaire de session) : 40 rondes, chacune avec un client neuf (`pr72_…`), 8 appels simultanés de `ekCreate`, mêmes assertions que le test (8 réussites, solde 4000, une seule commande). Émulateur Auth + Firestore neuf, ports dédiés.

| Version du module testé | Rondes en échec / 40 | Détail |
|---|---|---|
| Fichier actuel (avant les gardes 7E-72) | **3** (rondes 6, 23, 36) | 7 réussites sur 8 ; 3 rejets `3 INVALID_ARGUMENT: Transaction is invalid or closed.` |
| `HEAD:functions/ekbineOrders.js` (aucune modification 7E-68/71/72) | **2** (rondes 4, 28) | rondes à 7 réussites et une ronde à **1** réussite sur 8 ; 8 rejets du même message en tout |

Dans **chaque** ronde en échec : solde final **4000**, **une seule** commande, aucune écriture double. Le défaut est donc un appel qui échoue, jamais une corruption financière.

## 4. Cause

Erreur renvoyée par l'**émulateur** (`Transaction is invalid or closed`) lorsque plusieurs transactions concurrentes sur les mêmes documents s'entre-bloquent : l'émulateur annule la transaction perdante avec `INVALID_ARGUMENT`. Le SDK ne relance pas ce code (seul « transaction has expired » l'est), l'erreur remonte à l'appelant. Le service Firestore réel signale ce conflit par `ABORTED`, que le SDK relance (5 tentatives) : le comportement n'est donc **pas équivalent** et ne peut pas être extrapolé à la production à partir de l'émulateur.

Ce n'est **pas** une régression de 7E-68/71/72 :
1. le module d'avant toute modification présente la même erreur au même ordre de fréquence (≈ 5 % des rondes de 8 appels) ;
2. le diff de `ekbineOrders.js` avant 7E-72 ne touchait pas la création ;
3. l'échec n'apparaissait pas en 7E-69 simplement parce que l'événement est probabiliste, et qu'il est plus probable après ~17 minutes de suite (processus Java chargé).

## 5. Ce qui n'a PAS été fait, volontairement

- Aucun retry supplémentaire ajouté au code ou au test.
- Aucune assertion assouplie (`8 réussites` conservé).
- Le test reste donc **intermittent sur émulateur** : c'est un défaut de l'outil de test, documenté.

## 6. Mesure de la fréquence en suite complète

| Exécution complète (émulateurs Auth + Firestore, `--test-concurrency=1`) | E-Kbine « 8 appels » | Durée du test |
|---|---|---|
| 7E-69, Node 24 | PASS | non relevée |
| 7E-71, Node 24 (code avant 7E-72) | **FAIL** (7 sur 8) | 12,3 s |
| 7E-72, Node 22.23.4 (code avec les gardes 7E-72) | **FAIL** (7 sur 8) | 11,9 s |
| 7E-72, Node 24.22.1, exécution n° 1 | PASS | 3,6 s |
| 7E-72, Node 24.22.1, exécution n° 2 | PASS | 3,6 s |

→ **2 échecs sur 4 exécutions complètes de 7E-71/7E-72.** Les deux échecs durent ≈ 12 s contre ≈ 3,6 s pour les réussites : la durée du test est bimodale, ce qui oriente vers un blocage d'environ 8-10 s dans l'émulateur (verrous) puis une transaction fermée, plutôt que vers un défaut aléatoire d'une seule requête.

Autres essais (Node 22, émulateur neuf) :
- fichier `financialConcurrency` seul : 12/12 ×3 (Node 24, 7E-71) ;
- précédé de `accountQuarantineConcurrency.emulator.test.js` (le fichier précédent de la liste qui s'en approche) : 2 exécutions sur 2 où E-Kbine passe (la 2ᵉ a eu un échec intermittent de mon test C2, même message `INVALID_ARGUMENT … Transaction is invalid or closed`) ; une 3ᵉ exécution a été interrompue volontairement.

**Cause du déclenchement en suite complète : NON ÉTABLIE.** Ni la présence du fichier de concurrence de quarantaine seul, ni le fichier seul ne reproduisent l'échec ; l'état accumulé de l'émulateur après ~80 fichiers, la charge de l'hôte ou une transaction abandonnée par un fichier précédent restent des hypothèses **non vérifiées**. Cet échec n'est donc **pas classé « simple intermittence »** : c'est un défaut de test d'intégration non résolu, sans effet financier constaté.

## 7. Recommandation (non appliquée)

Pour un test d'intégration qui prouve l'idempotence sans dépendre du verrouillage de l'émulateur : exécuter les 8 appels en rafales de 2 à 4, ou accepter explicitement le rejet `INVALID_ARGUMENT/Transaction is invalid or closed` en le comptant à part tout en gardant les assertions d'argent (solde = 4000, une commande, au plus un `alreadyDone:false`). Décision d'équipe : cela change l'assertion `ok(results).length === 8`, donc **hors périmètre de cette mission**.

## 8. Défaut réel trouvé à côté : garde de quarantaine absente dans la création

L'investigation du chemin de création a révélé que `buildEkCreateOrder` ne relisait pas le tombstone (voir `ACCOUNT_DELETION_7E72_EKCLIENTCONFIRMORDER_AUDIT.md` §6). Corrigé localement et testé. Ce correctif n'a aucun lien avec l'échec décrit ici.
