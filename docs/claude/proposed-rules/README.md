# Règles Firestore PROPOSÉES — activation des partenaires (étape B)

**Statut : proposition, NON appliquée.** `firestore.rules` n'a pas été modifié ; rien n'est déployé.

## Pourquoi
Le serveur impose déjà le changement du mot de passe temporaire (fonction `completePartnerFirstPasswordChange`, drapeau serveur `partner_provisioning/{uid}`). Mais les règles actuelles ne lisent pas la revendication `partnerMustChangePassword` posée sur le compte : avec un client modifié, un partenaire non activé peut encore écrire ses données professionnelles. Un simple contrôle Flutter ne suffit donc pas.

## Contenu (`partner-activation.diff`)
- Nouveau helper `partnerActivated()` : `request.auth.token.get('partnerMustChangePassword', false) != true`.
- Ajouté aux ÉCRITURES du propriétaire sur : `sellers/{id}` (+ `wallet_transactions`), `boulangeries/{id}` (+ `menu_items`), `restaurants/{id}` (2 règles) et `restaurants/{id}/menu`, la branche partenaire de `orders` (2 branches), `marketplace_products` (mise à jour et suppression par le vendeur).
- Les LECTURES ne changent pas (l'écran de première connexion lit son profil).
- Comptes historiques : aucun effet (ils n'ont jamais la revendication).

## Vérification (copie locale + émulateur, sans toucher au vrai fichier)
- `partner-activation.rules.test.js` : 21 tests (9 écritures refusées si non activé / autorisées sinon, lectures conservées, aucun droit supplémentaire).
- Suite existante `rules-tests/firestore.rules.test.js` rejouée contre les règles proposées : 235/235.
- Total : 256/256.

Pour rejouer : copier `firestore.rules` + `partner-activation.diff` appliqué dans un dossier, y placer `rules-tests/` (le test lit `../firestore.rules`) et lancer `npx firebase emulators:exec --only firestore "node --test rules-tests/partner-activation.rules.test.js rules-tests/firestore.rules.test.js"`.

## Limites connues de la proposition
- Autres collections où un partenaire écrit (événements, services simples, boutique, etc.) : non couvertes ici, à passer en revue avant application.
- Un jeton émis avant le changement conserve la revendication jusqu'à son renouvellement (≤ 1 h) ; l'application se reconnecte donc automatiquement après le changement.
- Les fonctions `initiateWithdrawal` et `manageProfessionalSubscription` (paiements/abonnements) doivent aussi refuser la revendication : modification NON faite (périmètre paiements interdit).
