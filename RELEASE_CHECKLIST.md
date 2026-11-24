# AZ Express — Release Candidate Checklist

Date de préparation : 2026-07-25  
Périmètre : bêta Google Play — aucune validation ne vaut déploiement Firebase.

## Qualité

- [ ] `flutter analyze` sans erreur
- [x] `flutter test` réussi (59 tests)
- [x] `npm test` réussi (248 tests)

## Firebase et sécurité

- [ ] Cloud Functions vérifiées
- [ ] Tous les appels callable utilisent la région de déploiement correcte
- [ ] Firestore Rules vérifiées
- [ ] Storage Rules vérifiées
- [ ] Notifications validées

## Métier

- [ ] Wallet validé
- [ ] Paiements validés
- [ ] Marketplace validé
- [ ] Restaurant validé
- [ ] Pharmacie validée
- [ ] Boulangerie validée
- [ ] E-Kbine validé
- [ ] AZ IA validée

## Temps réel et performance

- [ ] Tracking Client ↔ Livreur validé sur deux comptes de test
- [ ] Reconnexion réseau et GPS validées
- [ ] Performance vérifiée

## Publication

- [ ] Android Release compilée
- [ ] Projet prêt pour Google Play Beta

## Points bloquants connus avant bêta

- [ ] Corriger ou valider l'appel `artisanLogin` : il utilise actuellement
  `FirebaseFunctions.instance` (région par défaut) alors que les Functions
  de ce projet sont déployées en `europe-west1`.
- [ ] Réaliser l'E2E Tracking avec deux comptes de test dédiés.
