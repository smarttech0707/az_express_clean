# Mission 7E-76 — Tests Flutter du contrat d'erreur

> **[Mise à jour 7E-80]** Le §3 distingue désormais le message avant 7E-79 (variante ASCII, historique) et le message implémenté depuis 7E-79. Les résultats « 31/31 » restent valides pour l'état actuel (revérifiés en 7E-80).

Date : 2026-11-07 · Local uniquement.

## 1. Modifications de code (minimales)
- `lib/services/account_deletion_service.dart` : nouvelle fonction statique `resolveCallableFailure(e, lastRequest)` (`@visibleForTesting`) qui porte la politique du `catch` : refus de passerelle → `AccountDeletionUnavailableException` **sans** appeler `lastRequest` ; toute autre `FirebaseFunctionsException` → `lastRequest()` (comportement antérieur). Le `catch` de `submitRequest` appelle `resolveCallableFailure(e, checkLastRequest)` : comportement identique, mais testable. Le design de l'interface n'est pas modifié.
- `test/services/account_deletion_service_test.dart` : +6 tests de contrat, +3 imports (`cloud_functions`, `PlatformException`, convertisseur du plugin avec `ignore_for_file`).

## 2. Cas couverts
| Cas demandé | Test |
|---|---|
| `failed-precondition` avec `details.reason` attendu (format natif converti par le **vrai** convertisseur du plugin, message volontairement reformulé) | « details.reason survives the plugin conversion and is read first » → refus de passerelle |
| même, détails Web (`Map<Object?, Object?>`) | test dédié |
| `failed-precondition` avec une autre raison / sans détails / détails en texte | « other failed-precondition… » → pas un refus de passerelle |
| `unavailable` (réseau) même avec le bon texte/détails | idem → faux ; **repli** `checkLastRequest` conservé |
| réauthentification (`unauthenticated`), `invalid-argument`, `resource-exhausted`, `unknown` | idem → faux ; l'écran de réauthentification est couvert par le test widget existant (7E-74) |
| ancien reçu déjà présent | « closed gateway never reads an older receipt… » : refus de passerelle → `lastRequest` jamais appelée (compteur 0) ; erreur réseau → `lastRequest` appelée une fois et renvoie le reçu |
| demande réellement enregistrée | corps réel reçu de l'émulateur (`quarantined`) : `accessClosed`, message « enregistrée » ; test widget existant de succès |
| absence de faux message de confirmation | tests widget 7E-74 (assertions sur fragments ASCII, remplacées en 7E-79 par une égalité exacte sur le nouveau message) : refus → message « pas disponible / non enregistrée / compte inchangé », aucun « Votre demande est conservee », aucun SnackBar |

## 3. Message affiché
**Formulation retenue pour le message de refus (décision de la revue 7E-78) :**
« Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. »

**Texte présent dans le code avant 7E-79 (historique, remplacé)** (`AccountDeletionUnavailableException.message`, variante ASCII) : « Le service de suppression de compte n est pas disponible pour le moment. Votre demande n a pas ete enregistree et votre compte reste inchange. Reessayez plus tard ou contactez le support. » Les assertions de l'époque (tableau §2, ligne « absence de faux message ») cherchaient des fragments de cette variante (`pas disponible`, `n a pas ete enregistree`, `compte reste inchange`).

**Écart levé par 7E-79** : le code et les tests affichent et vérifient désormais exactement la formulation retenue : « Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support. » Les tests (égalité exacte) sont décrits dans `ACCOUNT_DELETION_7E79_FLUTTER_MESSAGE.md` ; 31/31 en 7E-79 (rapport 7E-79) et revérifiés en 7E-80. Le message n'est affiché que pour `AccountDeletionUnavailableException`, levée uniquement par `resolveCallableFailure` sur un refus de passerelle.

(Correction 7E-78 : une version antérieure de ce paragraphe écrivait « Reessayer plus tard » ; le code dit « Reessayez ».)

## 4. Résultats
`flutter test` des deux fichiers (service + dialogue) : **31/31** ; `flutter analyze` des 4 fichiers : **aucune anomalie**. Suite Flutter complète : non lancée. Aucun test sur appareil.
