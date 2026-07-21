# Changelog — AZ Express

## Version 1.0 (2026-07-21)

Gel de la Release Candidate 1.0. Voir `RELEASE_1.0.md` pour le détail complet (fonctionnalités, règles métier, modules validés).

### Bugs critiques corrigés (cette passe de gel)

- **Règle Firestore `unchanged()`** — comparait par accès direct (`data[field]`), levant une erreur d'évaluation (refus silencieux d'écriture) dès qu'un champ était absent d'un côté, même sans rapport avec le champ réellement modifié. Corrigé via `.get(field, null)`, élargissement de sécurité sans relâchement.
- **Restaurant — menu jamais visible côté client** — le client lisait une collection top-level `menus` totalement différente de celle où le restaurateur écrivait réellement (`restaurants/{id}/menu`), sans aucune règle Firestore ne couvrant la première. Conséquence : aucun restaurant n'a jamais pu afficher son menu à un client, quel que soit le nombre d'articles ajoutés. Corrigé en unifiant tous les points de lecture/écriture sur la seule source de vérité réellement fonctionnelle.
- **Tarif Express jour/nuit incorrect** — ni le tarif jour (700 FCFA au lieu de 1000) ni le tarif nuit (1000 FCFA au lieu de 1500, identique au tarif Standard donc sans aucune majoration Express) ne respectaient la règle métier officielle. Corrigé à la source unique de vérité (`tarif_service.dart`/`tarifService.js`), verrouillé par 14 tests dédiés.

### Bugs majeurs corrigés (cette passe de gel)

- **Historique Boutique toujours vide** — index Firestore composite manquant sur `boutique_orders` (`clientId`+`createdAt`), requête échouant silencieusement en `FAILED_PRECONDITION`. Index ajouté, déployé et confirmé construit ; achat réel testé de bout en bout sur appareil physique.
- **Chat Marketplace bloqué** — double cause : une regex de règle Firestore supposant qu'un identifiant produit ne contient jamais d'underscore, et surtout une règle vérifiant un champ (`senderId`) qui n'a jamais existé dans le document réel (le code écrit `senderUid`) — bloquait silencieusement tout premier message. Corrigé, testé avec premier message, réouverture de chat, et refus d'un tiers authentifié confirmé (403).

### Bugs mineurs corrigés (cette passe de gel)

- Chips de réponse rapide AZ IA illisibles en mode sombre (fond blanc fixe sans couleur de texte garantie) — corrigé, testé en clair et en sombre sur appareil réel.
- Profil livreur affichant « 0 FCFA »/« 0 livraisons » pendant le chargement au lieu d'un indicateur de progression — corrigé (vérifié par lecture de code, test réel sur device non disponible faute de compte livreur approuvé).

### Nouveaux tests ajoutés (cette passe de gel)

- 6 tests Node (`functions/test/tarifService.test.js`) sur les heures pivots exactes du tarif Express (10h/19h59/20h00/23h30/05h59/06h00), + 2 tests existants corrigés pour refléter les bonnes valeurs.
- 8 tests Dart (nouveau fichier `test/services/tarif_service_test.dart`) : les mêmes 6 heures pivots + 2 tests de cohérence jour/nuit complets.
- 1 test de sécurité Firestore additionnel confirmant le refus d'un tiers sur le chat Marketplace (vérifié en conditions réelles via API REST, pas seulement en test unitaire).

### Chiffres clés de cette version

| Métrique | Valeur |
|---|---|
| Cloud Functions (code = déployé, correspondance exacte vérifiée) | **58** |
| Tests Flutter (`flutter test`) | **59/59** |
| Tests Node (`npm test`, Cloud Functions) | **248/248** |
| Index Firestore actifs en production (tous `READY`) | **42** |
| Index Firestore définis dans `firestore.indexes.json` | 41 (1 index actif en production non rapatrié dans le fichier local — voir Bugs connus dans `RELEASE_1.0.md`) |
| `flutter analyze` | 0 erreur, 8 avertissements préexistants |

### Historique antérieur à cette passe (rappel, non re-vérifié dans ce gel)

Le projet a fait l'objet d'un nombre substantiel d'audits et de corrections avant cette passe de gel (dispatch serveur, sécurité Firestore/Storage, KYC, App Check, paiements Boutique/Marketplace/Restaurant/Pharmacie, conciliation wallet, dédoublonnage de l'annulation de commande, durcissement Android, corrections de sécurité sur les règles `orders`, entre autres) — au dernier audit de synthèse avant cette version, **9 bugs financiers critiques** avaient déjà été trouvés et corrigés au fil de la session de développement. Voir `CLAUDE.md` (historique complet prompt par prompt) et `AUDIT_FINAL.md` (synthèse d'audit) pour le détail.

---

## Tag interne

**`v1.0-rc1`** — « Release Candidate 1.0 », posé sur ce commit. À partir de ce point, toute modification doit être versionnée 1.0.1 / 1.1 / 2.0, jamais republiée comme 1.0.
