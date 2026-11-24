# Mission L2.3 — Protection des retraits dans la suppression manuelle

Statut : terminée, arrêt avant toute autorisation. Aucun commit, push ni déploiement ; aucun accès à la production ; L3 non lancée ; writers financiers non branchés ; webhook FeexPay non modifié.

## 1. Branchement réalisé

Fichier modifié : `functions/manualAccountDeletion.js` (+44 / −9), seul fichier de production touché.

- Import de `inspectWithdrawals` depuis `accountObligationsInspector.js` (l'inspecteur de L2.2). **Aucune classification dans ce fichier.**
- `financialBlocker(role, target)` : le contrôle final appelle désormais `withdrawalBlocker(role, target)` pour les trois rôles manuels (artisan, pharmacie historique, prestataire d'événements). Les contrôles existants (soldes, commandes/réservations, moteur pour la pharmacie) sont conservés et passent avant.
- Refactorisation minimale : le `if (!query) return null;` qui sortait avant la fin pour artisan est devenu `if (query) {…}`, sinon l'artisan n'aurait pas atteint le contrôle des retraits. Le comportement des contrôles de commandes est identique.
- `withdrawalBlocker` : une transaction de lecture, un appel de `inspectWithdrawals` par identifiant. Un retrait est rattaché au `userId` de la session de l'appelant (`initiateWithdrawal`), qui n'est pas forcément l'identifiant du profil : sont contrôlés **l'identifiant du profil et l'identifiant de session connu** (`artisanUid` / `currentUid` / `ownerId`), dédoublonnés, chaînes non vides sans `/`. Un retrait rattaché à l'un ou à l'autre bloque (fail-closed).
- Motifs inchangés par rapport à L2.2 : `active_or_unresolved_operation` (ouvert), `financial_regularization_required` (sans preuve / inconnu / incomplet), `history_requires_manual_review` (201 retraits ou couverture incomplète). Le refus met la demande en `blocked` + `reviewRequired`, comme les autres refus.
- Erreur de lecture : l'exception se propage (la transaction échoue) ; la demande n'avance pas, aucun nettoyage, aucun compte Auth supprimé. Autorisation super-admin / ré-authentification / attestation : code non touché, test de non-régression ajouté.

Non modifiés : l'inspecteur, le moteur, `accountDeletion.js`, `accountDeletionScope.js`, `partnerAccountDeletion.js`, `index.js`, webhook, règles, writers de retrait.

## 2. Tests (Node 22.23.4, garde de sortie réseau active)

Nouveau `test/manualAccountDeletionWithdrawals.test.js` (107 tests) : 3 rôles × 2 rattachements (profil / session) × 17 cas :
- autorisés : `sent` confirmé, `processed` confirmé, `failed_refunded` compensé, plusieurs retraits tous réglés (suppression `completed`, retraits conservés) ;
- bloqués : `sent` sans preuve, `processed` sans preuve ou sans `processedBy`, `failed_refunded` sans preuve de compensation, `processing`, `provider_pending`, `pending_manual`, réglé + en attente, statut inconnu, statut absent, montant absent, drapeaux contradictoires, `needsReview` — chacun vérifie le motif, la demande `blocked`, le profil non supprimé, l'absence de suppression Auth ;
- retrait d'un autre compte ignoré ; 201 retraits → `history_requires_manual_review` ; 200 retraits réglés → autorisé ; erreur de lecture (3 rôles) → la demande échoue, rien supprimé ; contrôle d'autorisation (utilisateur inconnu → `permission-denied`, rien supprimé).
- Contrôle par mutation (`withdrawalBlocker` neutralisé) : 80 tests sur 107 échouent ; fichier restauré (identique).

Résultats :
- Suppression manuelle ancienne + nouvelle : 118/118 au premier passage (11 anciens inchangés, aucun modifié).
- Retraits (L2.1, L2.2, L2.3), inspecteur, moteur, protocole de fermeture, suppression durcie, manuelle : 308/308.
- **Suite pure complète : 2673 tests, 2500 réussis, 0 échec, 0 annulé, 173 ignorés** (référence L2.2 : 2566/2393/0/173 ; écart +107 = nouveaux tests).
- Aucun test d'émulateur nécessaire : le chemin manuel n'utilise que le faux Firestore et aucun émulateur n'a été lancé.

## 3. Contrôle des preuves d'exécution et de compensation

Ce que l'inspecteur exige : `sent` → `settlementConfirmed === true`, `compensated !== true`, ni `needsReview` ni `anomaly` ; `processed` → idem + `processedBy` non vide ; `failed_refunded` → `compensated === true`, `settlementConfirmed !== true`, sans `needsReview`/`anomaly`. Ces champs sont ceux que posent les vrais writers (`applyPayoutStatus`, `adminApproveWithdrawalCF`) — vérifié à L2.1 avec ces fonctions.

Suffisance : **insuffisante contre une écriture hostile, suffisante contre les états incohérents ou incomplets.** Le prédicat ne vérifie pas de preuve indépendante : ni la référence fournisseur (`providerReference`) confrontée à FeexPay, ni la présence de l'écriture de journal wallet, ni une entrée `audit_logs` correspondante. Les règles Firestore interdisent la création côté client (`allow create: if false`) mais autorisent `update` à tout administrateur (`allow update: if isAdmin()`), donc un administrateur peut écrire `status:'sent'` + `settlementConfirmed:true` sur un retrait réellement non réglé, ou créer un document par le SDK Admin ; le prédicat l'accepterait. Cette limite n'est **pas résolue** ici, comme demandé. Renforcer le modèle de preuve (ex. rapprochement avec le journal wallet/`audit_logs`, empreinte signée écrite uniquement par les Cloud Functions) ou les writers de retrait nécessite une autorisation distincte.

## 4. Statut de C2

Le parcours manuel n'est pas le chemin de quarantaine T1 utilisé par C2 (celui de `buildAccountDeletion`), ni le webhook : `feexpayPayments.js`, webhook, `accountDeletion.js` et leurs lectures n'ont pas été touchés dans cette mission. Le protocole L0-F n'a donc pas été rejoué. C2 reste **intermittent sur émulateur** (dernier relevé L2.2 : 17/20, échecs `INVALID_ARGUMENT: Transaction is invalid or closed`) et n'est pas déclaré corrigé.

## 5. Préservation

HEAD `d65c8f0` ; branche `finalisation/az-express` inchangée ; index vide ; stash 0 ; **26** fichiers suivis modifiés (inchangé : `manualAccountDeletion.js` l'était déjà ; ses hunks L2 préexistants sont intacts, les changements sont additifs sauf la restructuration du `if (!query)` décrite en §1) ; non suivis : **131** (130 + `manualAccountDeletionWithdrawals.test.js` ; le rapport s'ajoute → 132) ; cinq hashes sensibles inchangés (`21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60`). Aucun émulateur lancé ; ports préexistants non touchés.

## 6. Risques résiduels

- Faux retrait « réglé » écrit par un administrateur : non détectable (§3).
- Le rattachement d'un retrait d'un compte manuel passe par l'identifiant de session conservé sur le profil ; si ce champ a déjà été purgé (reprise `cleanup_pending`) le contrôle n'est pas rejoué à la reprise (comportement existant : les contrôles financiers ne sont faits qu'à la première exécution).
- Les retraits n'entrent pas dans l'empreinte de scellement de la suppression automatique (voir L2.2).
- Writers de retrait (`initiateWithdrawal`, `checkPendingWithdrawals`, `adminApproveWithdrawalCF`) toujours non gardés par le verrou financier : un retrait créé entre le contrôle et le nettoyage manuel n'est pas exclu (la suppression manuelle ne scelle pas de tombstone avant le nettoyage pour artisan/pharmacie).
- `needsReview`/`anomaly` bloquent de façon conservatrice ; ancien statut `pending` bloque.
- C2 intermittent sur émulateur ; aucune preuve de production.

## 7. Travaux encore nécessaires

1. Décision sur le modèle de preuve des retraits (rapprochement avec journal wallet / audit, signature serveur) et sur le verrouillage des writers de retrait — L3 et missions financières.
2. Garde par verrou financier des 16 writers B/C/D restants.
3. Registre de décisions (L7) pour débloquer les signalements « résolus ».
4. Rôles hors moteur (agents E-Kbine, immobilier, flotte) : contrôles historiques + retraits seulement.

Arrêt : en attente de votre autorisation.
