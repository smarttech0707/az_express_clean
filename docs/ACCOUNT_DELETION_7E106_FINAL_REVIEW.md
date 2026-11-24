# 7E-106 — Audit indépendant final de 2D-1

Lecture seule. HEAD `d65c8f0`, index vide. `accountObligations.js` (`9c454d898da109d9`) et son fichier de tests (`971e599acbddf863`) identiques avant et après l'audit. Sondes et mutations exécutées sur une copie dans le dossier temporaire de session. Aucun émulateur, aucune commande distante. Les 100 entrées de travail (97 d'origine + rapports 7E-103, 7E-104, 7E-105) sont préservées, plus ce rapport.

## Verdict

**2D-1 VALIDÉ POUR INTÉGRATION SOUS CONDITIONS EXPLICITES.**

Je n'ai trouvé aucun chemin fail-open sur les points audités. Un seul constat contredit une consigne explicite (N3, §4) ; il est neutralisable sans toucher aux inspecteurs et fait donc partie des conditions d'entrée. Ce verdict **n'autorise pas** 2D-2 : il en fixe les conditions (§10).

Rejoué : module 52/52 ; fichiers voisins 197/197 ; Node 24.22.1 seulement (§9).

## 1. A — R1 requestId (conforme)

- Format : chaîne `[A-Za-z0-9_.:-]{16,128}`. `undefined`, `null`, vide, espaces, court, trop long, non chaîne : bloquant.
- Correspondance : signalement `resolutionRequestId` = `requestId` de la décision = valeur passée à `verifyDecision`. Pour un dossier client, la valeur vient de la décision et doit respecter le même format.
- Unicité : deux décisions du registre avec le même `requestId` sont toutes deux refusées (sonde : décision D1 valide + D2 de même `requestId` → `flag_decision_unverified`).
- **Limite** : l'unicité ne porte que sur le registre **fourni**. Si l'inspecteur ne passe que les décisions du compte, un doublon ailleurs n'est pas vu. À garantir par le writer (clé de document ou index unique sur `requestId`) ; le moteur ne peut pas le faire.

## 2. B — R2 et R3 (conforme, deux points de test)

- `refuted_after_contest` est bien N2 : la matrice est comparée à une table indépendante ; avec le niveau 1 ou sans approbateur, le dossier reste bloquant (sondes et tests).
- Approbateur ≠ demandeur, ≠ décideur initial (`decidedBy`, ou `cashPayment.review.byUid` pour le client). Identité manquante, vide, non conforme, avec espaces : bloquant. Aucune normalisation (le motif exclut espaces et caractères non ASCII ; la casse est conservée, ce qui est correct pour des UID Firebase). Un id `__proto__` dans le registre est traité comme un id ordinaire.
- Sans second responsable, `approvedBy` absent ou égal au demandeur : le dossier reste en attente (bloquant).
- Observation (non défaut) : le **demandeur** peut être le décideur initial ; seul l'approbateur doit être différent, conformément à la décision 3. À confirmer si l'intention est plus stricte.
- **Écart de test** : mutation indépendante, 9 mutants sur les niveaux et l'origine, 7 tués, 2 survivants : la liste `ORIGIN_DECIDER_REQUIRED` n'est testée que pour `cash_shortfall` et le dossier client ; `seller_review` et `driver_advance_unreimbursed` ne le sont pas. Comportement correct, test manquant (condition mineure).

Comparaison aux décisions de 7E-102 (niveaux codés) :

| Type | 7E-102 | Code | |
|---|---|---|---|
| commission_untraced | N1, N1, N3 | 1, 1, 3 | ✓ |
| partner_credit_missing | N1, N2 | 1, 2 | ✓ |
| seller_review | N2 | 2 | ✓ |
| driver_advance_unreimbursed | N1, N2 | 1, 2 | ✓ |
| ekbine_* | « N1 / N2 » pour trois résolutions | 1, 1, 2 | lecture raisonnable, **à confirmer** : `debit_disproved` (preuve d'absence) pourrait être N2 |
| cash_shortfall | N2, N2 (N3 de `waived_by_partner` non codé) | 2, 2 | ✓ |
| beneficiary_account_closed | N1, N2 | 1, 2 | ✓ |
| client espèces | refuted N2, paid_by_client_out_of_system N2 | 2, 2 | ✓ |
| non codés (bloquants) | waived_by_partner/driver, written_off_by_platform, partner_unreachable_held, order_payment_waived_by_platform | absents | ✓ |

## 3. C — R4 preuves N1 (conforme, avec limites de confiance)

Le moteur exige : `evidenceRef` conforme ; un document `evidence` existant (`exists:true`, objet) ; `status:'verified'` ; liaison à la décision (`decisionId`), au sujet (`subjectKind`, `subjectId`) et à la résolution ; `verifiedBy` conforme ; `verifiedAtMs` entier positif. Toute absence, ancienne preuve réutilisée par une autre décision, registre non fourni ou en double : bloquant. La preuve reste exigée si la décision est sur-validée.

**Limites de confiance.** Le module est pur : il ne peut pas savoir si `evidence` et `decisions` viennent d'une lecture serveur ; un appelant qui fabrique ces tableaux contourne tout. Il ne vérifie pas non plus que `verifiedBy` est un administrateur, que la preuve est antérieure ou postérieure à la demande, que le vérificateur diffère du demandeur (sonde : vérificateur = demandeur, preuve datée après la décision : accepté), ni que la preuve décrit réellement le fait allégué. Pour les niveaux N2 et N3, aucune preuve n'est exigée par le moteur (sonde : `paid_out_of_system` N2 sans aucune preuve : fermé).

Garanties à imposer :
- **Inspecteurs (2D-2)** : lire `decisions` et `evidence` par `get` Admin SDK dans la même transaction que le reste (collections en écriture serveur seule), ne transmettre que des documents lus, ne jamais prendre une valeur d'un document client ; une erreur de lecture fait échouer l'inspection, jamais `exists:false` ; passer **toutes** les décisions portant les `requestId` concernés ; construire snapshot et évaluation dans la même fonction.
- **Writer** : preuve créée par le serveur après vérification réelle (ligne de journal, document), `verifiedBy` super-admin réel, horodatages serveur, `decisionId` imposé, preuve immuable et à usage unique, vérificateur ≠ demandeur si l'on veut une séparation (à décider), preuve de paiement hors système exigée aussi pour les résolutions N2 concernées.

## 4. D — N3 et consentement du créancier (**non conforme à la consigne**)

Constat reproduit : une décision `waived_platform_claim` de niveau 3, avec `creditor:'az_express'` et `creditorConsentRef:'a'` (une lettre), ferme le signalement (`blocking:false`, `flag_resolved:commission_untraced`). Aucun document de consentement n'est lu. La seule résolution de niveau 3 est cette renonciation.

Impact réel : elle exige déjà deux personnes distinctes et une décision `executed` dans un registre serveur ; avec un seul super-admin elle ne peut pas aboutir. Mais le moteur l'accepte sur une chaîne quelconque, contrairement à « tant que ces garanties n'existent pas, N3 doit rester bloquant ». **Condition C1** : rendre le niveau 3 bloquant dans le moteur (retirer `waived_platform_claim` de la matrice, ou exiger un document de consentement vérifié) avant l'intégration, avec test négatif.

Contrat futur du consentement (à implémenter par le writer, vérifié par le moteur) :

| Élément | Exigence |
|---|---|
| Document | présent (`exists:true`) dans une collection serveur seule, lu comme `evidence` |
| Créancier | identifié (type + id) et conforme à la créance (`creditor` dérivé du type de signalement par le serveur) |
| Créance | `subjectKind`, `subjectId`, `resolution`, montant renoncé (`amountWaived`) liés à la décision |
| Consentement | explicite (`consent:'granted'`), fourni par le créancier ou son représentant légitime ; pour une créance d'AZ, une autorité nommée à définir |
| Auteur et date | `recordedBy` conforme, `recordedAtMs` serveur, antérieur à `approvedAtMs` |
| Vérification serveur | `status:'verified'`, `verifiedBy`, `verifiedAtMs` |
| Référence | identifiant immuable (hash du contenu), usage unique, non réutilisable par une autre décision |

## 5. E — R5 à R13

| Réf. | État | Vérification |
|---|---|---|
| R5 | corrigé | `limit === 201` ; 1, 100, 200, 202 refusés (test et mutant) |
| R6 | corrigé | ids dédoublonnés ; `requiredQueries('client',['c1','c1'])` = un couple |
| R7 | corrigé | refIds identiques dans le résultat et le snapshot (sonde : `invalid:5fcfc6f5` dans les deux) |
| R8 | limite attribuée | `remaining`, `tier`, lien décision↔compte/montant : à calculer par le **writer** (§3) |
| R9 | corrigé | tests ajoutés ; reste le trou seller_review/driver_advance (§2) |
| R10 | **à clarifier** | Une commande wallet non v2 livrée avec `isPaid:true` est aujourd'hui **non bloquante** (sonde), seule l'absence ou le `false` bloque. La consigne dit qu'elles « restent bloquantes jusqu'à décision explicite ». Je n'ai pas tranché : tout bloquer rendrait inexportables presque tous les clients ayant payé une commande pharmacie par wallet (`isPaid:true` est posé dans la transaction de paiement, `orderActions.js:127`). Décision métier requise : (a) statu quo, (b) exiger un journal pour tout ou partie des commandes non v2. |
| R11 | limite attribuée | correspondance document↔requête non vérifiable par le moteur ; le reçu de couverture de 2D-2 doit la porter |
| R12 | conforme | un signalement Ekbine ne portant que `agentId` est `flag_without_party` (bloquant) pour **tous** les statuts (open, contested, recorded, reviewed, resolved, closed) ; avec `clientId` il est bloquant (`flag_open:…`) et ne se ferme que par une décision vérifiée |
| R13 | limite attribuée | falsification cohérente avant le snapshot indétectable ; évaluer et construire le snapshot dans la même fonction (2D-2) |

## 6. F — Snapshot et clés économiques (conforme)

- Clé `orderId|créance` : calculée seulement avec un identifiant fiable ; sans identifiant fiable aucune clé, élément isolé, bloquant. Commandes distinctes → clés distinctes. Pas de fusion d'obligations distinctes (les symptômes d'une même créance partagent la clé ; les créances différentes d'une même commande restent séparées).
- Un document dont l'identifiant est littéralement `invalid:deadbeef` n'est pas fusionné et reste sans clé (sonde). Il est bloquant s'il porte une obligation.
- Compteurs `orders`, `economic`, `flags` indépendants de la déduplication, qui ne sert qu'à l'affichage. Le snapshot recalcule blocage, code, compteurs et indicateur de revue manuelle depuis les éléments normalisés ; l'incohérence ajoute un élément bloquant.
- Limite connue : empreinte 32 bits, collision théorique sans effet sur les comptes.

## 7. G — Délai de réflexion de 24 h (non approuvé, non implémenté)

Aucune implémentation. Conséquences d'une adoption éventuelle : (1) une règle `approvedAtMs − requestedAtMs ≥ 86 400 000` serait vérifiable par le moteur sans horloge, mais seulement si les deux horodatages sont posés par le serveur ; (2) toute résolution concernée serait différée d'au moins 24 h, donc les comptes concernés resteraient non supprimables plus longtemps (impact support) ; (3) il faut préciser les niveaux visés (7E-102 le proposait pour N3) et une procédure d'urgence ; (4) tests et rapports à mettre à jour ; (5) sans second responsable, aucun effet supplémentaire.

## 8. Autres observations

- `creditorConsentRef`, `evidenceRef` et les identités sont des chaînes ASCII ; les homoglyphes Unicode sont refusés.
- Les statuts terminaux fournis par l'appelant sont validés mais leur égalité avec les ensembles des inspecteurs n'est testée que par présence de chaînes dans les sources (test faible) ; à renforcer en 2D-2 par un test de contrat.

## 9. H — Environnement Node

Node **22.23.4 non disponible** : seule l'installation `C:\Program Files\nodejs\node.exe` (v24.22.1) existe ; aucun autre `node.exe` jusqu'à trois niveaux dans Program Files, LOCALAPPDATA et le profil, aucun gestionnaire de versions. Rien installé ni modifié. Les résultats sous 24.22.1 (52/52 et 197/197) ne valent **pas** validation Node 22. `functions/package.json` exige `"node": "22"`.

## 10. Conditions d'entrée dans 2D-2 (aucune n'est commencée)

1. **C1** : N3 bloquant dans le moteur tant que le contrat de consentement (§4) n'existe pas, avec test négatif.
2. **C2** : décision métier sur R10 (commandes wallet non v2), puis éventuel durcissement.
3. **C3** : confirmation des niveaux Ekbine (`debit_disproved`) et de la lecture « demandeur = décideur initial autorisé ».
4. **C4** : ajouter les tests manquants (origine seller_review/driver_advance ; preuve N2 si exigée).
5. **C5** : exécuter les tests sous Node 22.23.4 (CI ou machine équipée).
6. **C6** : spécifier le writer du registre et des preuves selon §3, §4 et 7E-105 §4, avec unicité des `requestId`.
7. **C7** : contrat de lecture 2D-2 : requêtes (`requiredQueries`), journaux wallet `clients/{uid}/wallet_transactions/order_<id>` par lecture ponctuelle, décisions et preuves, reçu de couverture, snapshot construit dans la même fonction, échec sur toute erreur de lecture.
8. **C8** : budget de lectures à mesurer en préproduction avant tout déploiement.

Je m'arrête ici. 2D-2 n'est pas commencé.
