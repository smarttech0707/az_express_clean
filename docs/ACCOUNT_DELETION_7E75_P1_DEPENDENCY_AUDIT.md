# Mission 7E-75 — Audit des dépendances P1, séparation P1/P2/P3 et sécurité

Date : 2026-11-07 · Local uniquement, aucun accès distant.

## 1. Dépendances réelles du moteur (lecture des `require`)
| Module | Importe | Présent à HEAD ? |
|---|---|---|
| `accountDeletion.js` | `accountCleanup`, `accountDeletionIdentity`, `partnerAccountDeletion`, `node:crypto` | `accountCleanup` **non** (nouveau, dans le commit 1) ; autres oui |
| `accountCleanup.js` | aucun | nouveau |
| `partnerAccountDeletion.js` | `accountCleanup`, `accountDeletionScope`, `accountRelatedPersonalData`, `node:crypto` | oui sauf `accountCleanup` |
| `accountDeletionSupport.js` | `adminGuards` | oui |
| `index.js` (hunk 3) | `checkRateLimit`, `logAudit` déjà définis dans `index.js` | oui |

Aucun de ces modules n'importe `accountAdmission`, `pilotCap`, `feexpayPayments`, `azia/*`, `ekbineOrders`, `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`. **Le commit 1 ne dépend ni de P2, ni de P3, ni d'E-Kbine.**

## 2. Reconstruction depuis HEAD (exécutée hors dépôt)
`git archive HEAD functions` → copie, + 4 modules + test Hardening + `index_p1.patch` (appliqué à la copie avec `git apply`, hors dépôt) :
- `index.js` ne diffère de HEAD que par la ligne `checkRateLimit,logAudit` (comparaison sans CR) ;
- `require('./index.js')` : se charge, 135 exports ;
- `accountDeletionHardening` + `accountDeletionSupport` + `manualAccountDeletion` : **51/51 sous Node 22.23.4 et sous Node 24.22.1**.
La copie de travail (dossier temporaire de session) n'est pas dans le dépôt ; le lien `node_modules` temporaire a été retiré sans toucher au vrai `node_modules`.

## 3. Séparation P1 / P2 / P3 / E-Kbine
| Lot | Fichiers | Dans le commit 1 ? |
|---|---|---|
| P1 | moteur (4 modules), hunk 3, Hardening, 3 `rules-tests` ; Flutter = commit 1b | oui |
| P2 | `accountAdmission`, `feexpayPayments`, `azia/index`, `azia/pendingActions`, `pilotCap`, `index.js` hunks 1, 2, 4–8, tests `accountQuarantine*`, `pilotCap` | non |
| E-Kbine | `ekbineOrders`, `ekbineQuarantineGuards.test` (dépend de HEAD seulement) | non (commit 3) |
| P3 | `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`, `index.js` hunk 9, `passwordReset.test` | non (3b) |
| Autres | `restaurantV2Preprod.test` (4), script de déploiement (5), docs (6), pages légales web | non |

Écart connu (déjà signalé en 7E-73) : tant que le commit 2 n'est pas livré, `accountDeletion` ne s'appuie pas sur les gardes P2 (`assertNewAccountActivity` dans paiements/AZ IA) ; la quarantaine est donc respectée par le moteur mais pas encore par ces chemins financiers. Le quota ne permet pas de les déployer avec P1 (P1+P2 théorique 19,75 vCPU).

## 4. Les trois échecs de la suite Functions (Node 22, 7E-74)
| Échec | Classification | Bloque P1 ? | Reportable ? | Preuve | Limites de la preuve |
|---|---|---|---|---|---|
| `accountQuarantineConcurrency` C2 (webhook vs quarantaine) | artefact d'émulateur : `3 INVALID_ARGUMENT: Transaction is invalid or closed`, non relancé par l'Admin SDK | non : fichier du commit 2, chemin non utilisé par P1 | oui, mais à revalider avant le commit 2 | relancé seul : 9/9 (Node 22) | déclencheur en suite complète non établi ; émulateur ≠ Firestore réel |
| `dispatchRetry.emulator` « trois passes simultanées en phase 2 » | **préexistant** (échoue dans les suites complètes depuis 7E-69) | non : aucun lien avec le moteur de suppression | oui | échec antérieur à 7E-74, mêmes résultats avant la correction | cause racine non analysée dans cette série |
| `financialConcurrency.emulator` E-Kbine 8 appels | artefact d'émulateur intermittent (même erreur `INVALID_ARGUMENT`) | non : appartient au commit 3 | oui | rondes en échec : solde final correct, une seule commande, aucun double débit (également sur `HEAD:ekbineOrders.js`) | échantillon réduit ; cause du déclenchement non établie ; non mesuré sur Firestore réel ; test conservé inchangé |

Aucune assertion modifiée. Suite complète non relancée en 7E-75 ; le résultat 2278/2328 (3 échecs, 47 ignorés) date de 7E-74 et précède l'ajout de `details.reason` (réexécutés depuis : Hardening 26/26, règles de suppression 69/69 sous Node 22, 51/51 reconstruit).

## 5. Contrôle de sécurité P1 (preuves = tests locaux ; non validé sur opérations réelles)
| Contrôle | Évidence | Statut |
|---|---|---|
| Passerelle absente / désactivée / `inventoryVersion` incorrect → refus avant écriture | 6 tests Hardening + tests d'état réel | prouvé en local |
| Passerelle illisible → refus sûr | test dédié | prouvé en local |
| Administrateur jamais supprimé | `admins` listé dans le moteur et décision D3 ; tests `accountDeletionSupport`/`manualAccountDeletion`/règles | couvert en local ; non revérifié nominativement en 7E-75 |
| Solde non nul / retrait en attente / commande non terminée → blocage | tests « late financial change blocks finalization without losing money », « données conservées », « fleet responsibility… », « partner… » | couvert en local |
| Quarantaine | tombstone, `assertTargetNotClosing` : **gardes P2 non incluses** (voir §3) | partiel pour P1 |
| Auth supprimé seulement après tous les contrôles ; anonymisation après réinspection | tests « sous-collection inconnue… bloqué AVANT Auth », « échec du journal d'audit avant l'étape irréversible : Auth NON supprimé » | prouvé en local |
| Idempotence, limitation de débit, audit | tests dédiés (fenêtre 60 s, plafonds, journal sans donnée personnelle) | prouvé en local |
| Nettoyage AZ IA | tests « effacement AZ IA… », « même blocage avant Auth » | prouvé en local |
| Aucune opération réelle | émulateurs et faux Firestore uniquement ; aucun Auth/Firestore/Storage réel | **NON VÉRIFIÉ en réel** |
