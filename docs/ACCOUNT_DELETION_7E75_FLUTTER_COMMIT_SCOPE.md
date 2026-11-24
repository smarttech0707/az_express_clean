# Mission 7E-75 — Périmètre Flutter du commit P1

Date : 2026-11-07 · Local uniquement.

## 1. Les corrections Flutter sont-elles indispensables à P1 ?
**Oui, pour la garantie « pas de fausse confirmation ».** Sans elles, le refus backend `failed-precondition` est attrapé par `catch (FirebaseFunctionsException)` puis `checkLastRequest()` : si un ancien dossier existe, l'utilisateur voit son ancien reçu comme s'il venait d'être enregistré ; sinon un message générique. Elles sont **additives** et n'affectent pas le backend. Elles forment le commit **1b**, à placer juste après le commit 1 et avant toute diffusion de l'application. La page web (`delete_account_page.dart`, chemin Firestore manuel) n'est pas concernée.

## 2. Vérifications
| Exigence | Code | Preuve |
|---|---|---|
| Refus `ACCOUNT_DELETION_NOT_ENABLED` traité | `isGateClosedRefusal` → `AccountDeletionUnavailableException` | 5 cas de helper + test exception |
| Passerelle fermée ≠ « demande enregistrée » | message « n a pas ete enregistree », « compte reste inchange » ; jamais « Votre demande est conservee » | test widget |
| Erreur réseau distinguée | repli `checkLastRequest()` conservé ; message « Enregistrement non confirme / Aucune suppression confirmee » | test widget |
| Réauthentification | `requires-recent-login`, `unauthenticated`… → « Reauthentification requise » | test widget |
| Demande réellement enregistrée | confirmation existante inchangée | tests existants (25 → 26 verts) |

## 3. Fragilité du texte de message — traitée
Avant : détection par `e.message.contains('ACCOUNT_DELETION_NOT_ENABLED')`. Risque : changement de libellé ou reformulation par la passerelle d'infrastructure. **Correction minimale 7E-75** : le backend ajoute `details: {reason: 'ACCOUNT_DELETION_NOT_ENABLED'}` (3ᵉ argument de l'`HttpsError`, sans changer code ni message) ; Flutter lit `details['reason']` en priorité et garde le texte en **repli** (versions de fonction antérieures sans `details`). La détection exige toujours `code == 'failed-precondition'`, donc `RATE_LIMITER_REQUIRED` (même code) n'est pas pris pour une passerelle fermée (testé). Test backend : le rejet porte `details.reason`.

## 4. Limites
La transmission réelle de `details` par la couche callable de Firebase n'a pas été vérifiée sur un déploiement (les `details` d'`HttpsError` sont une fonctionnalité documentée, mais aucun test réseau n'a été fait) ; le repli sur le message couvre ce cas. Aucun test sur appareil ni émulateur mobile. Les textes sont sans accents, comme le reste du fichier.

## 5. Tests
`flutter test` des deux fichiers : 26/26 ; `flutter analyze` des 4 fichiers : aucune anomalie ; suite Flutter complète : **non lancée**.
