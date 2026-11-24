# Proposition B5 — projection d'activation du restaurateur (NON APPLIQUÉE à `functions/`)

Statut : proposition validée en copie de travail (202/202 tests unitaires, e2e émulateurs Auth+Firestore+Storage avec vrais jetons). Les fichiers de `functions/` n'ont PAS été modifiés : autorisation requise.

## Pourquoi
Les règles Storage `restaurant_*` ne peuvent lire que `restaurant_owners/{uid}` (limite de 2 documents Firestore, dont 1 pris par `isAuth()`). `storage.rules` (déjà modifié localement) lit `restaurant_owners/{uid}.mustChangePassword` : s'il est présent il fait foi, sinon la revendication du jeton décide. Tant que les fonctions n'écrivent pas ce champ, le comportement reste celui de B4 (fenêtre ≤ 1 h après réinitialisation).

## Invariant
`partner_provisioning/{uid}` reste la SEULE autorité. `restaurant_owners/{uid}.mustChangePassword` est une projection en lecture seule, écrite par le serveur dans le même lot atomique que le journal, jamais lue par le serveur pour décider. Vérifié : `firestore.rules` (`restaurant_owners`) n'autorise l'écriture qu'à l'admin, le restaurateur ne peut donc pas forcer la projection.

## Fichiers concernés
- `functions/adminPartnerAccounts.js` — création / attribution : `mustChangePassword: true` dans `restaurant_owners` (`adminPartnerAccounts.js.diff`).
- `functions/partnerFirstLogin.js` — activation : journal + projection dans un lot ; mode `statusOnly` : réalignement de la projection sur le journal, sans jamais créer le document (`partnerFirstLogin.js.diff`).
- Tests : `adminPartnerAccounts.test.js.diff`, e2e `restaurantStorageActivation.e2e.emulator.test.js.txt` (à copier dans `functions/test/`, lancer avec `AZ_E2E_STORAGE=1` sous émulateurs auth+firestore+storage).

## Conséquences sur les comptes existants
- Comptes historiques (sans journal, sans champ) : aucun changement, aucune migration ; la revendication du jeton continue de décider.
- Comptes déjà créés par l'admin et encore à activer (champ absent) : retombent sur la revendication jusqu'à leur prochain appel `statusOnly` (réalignement) ou leur activation.
- Aucun solde, montant, tarif ni statut de paiement touché.

## Ordre de déploiement (non exécuté)
fonctions → règles Storage → applications. L'opération de réinitialisation future (étape D) devra écrire journal ET projection dans le même lot, puis reposer la revendication.

## Points à valider avant application
- Aucun point bloquant côté règles (écriture `restaurant_owners` réservée à l'admin, vérifié).
